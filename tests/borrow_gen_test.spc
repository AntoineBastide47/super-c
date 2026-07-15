// Self-hosted port of tests/borrow_gen_test.c: an auto-generating borrow-checker oracle. The borrow
// checker is a STATIC analysis, so each generated/fixed program carries a rule-derived VERDICT
// (accept vs reject); every program is compiled only through the typechecker (STAGE_TYPECHECK) and the
// oracle asserts the checker agrees. A rejection must come FROM the typechecker (a borrow/type error),
// never an unrelated earlier stage. Drives the real pipeline in-process through tests::harness.
import tests::harness as h;
import stdio;
import string as cstring;

// Scratch buffers (there is no `[v; N]` repeat literal, so wrap the array in a struct and `{}`-zero it).
struct Buf64 {
    pub b: [char; 64],
}
struct Buf2048 {
    pub b: [char; 2048],
}
struct Buf8192 {
    pub b: [char; 8192],
}
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

// Make a `str` view over a filled, NUL-terminated buffer.
fn buf_str(p: *const char) str {
    return str::from_raw(p as *const u8, unsafe cstring::strlen(p));
}

// Two borrow-place overlap rules: whole `p` (index 0) overlaps everything; `p.a` (1) and `p.b` (2) are disjoint.
fn overlap(i: i32, j: i32) bool {
    return i == j || i == 0 || j == 0;
}

// An i32-valued use of reference binding `name` that borrows place `pi`: `name.a` (whole, auto-deref) or `*name`.
fn use_ref(out: *mut char, name: str, pi: i32) {
    let mut fmt = "*%s";
    if pi == 0 {
        fmt = "%s.a";
    }
    unsafe stdio::snprintf(out, 64, fmt.ptr() as *const char, name.ptr() as *const char);
}

// Compile through the typechecker only and assert the accept/reject verdict; a rejection must be a
// typecheck (borrow/type) error, not an earlier-stage failure.
fn check_case(label: str, src: str, expect_ok: bool) {
    let c = h::compile(src, h::STAGE_TYPECHECK);
    assert(c.ok() == expect_ok, label);
    if !c.ok() && !expect_ok {
        assert(c.stage == h::STAGE_TYPECHECK, label);
    }
}

// Splice a prefix macro `pre` before a `body` snippet and check the verdict (the analog of the C
// `snprintf(PREFIX ...)` in the fixed-case families).
fn case_pre(pre: str, body: str, label: str, ok: bool) {
    let mut src = Buf2048 {};
    unsafe stdio::snprintf(
        &mut src.b[0],
        2048,
        "%s%s".ptr() as *const char,
        pre.ptr() as *const char,
        body.ptr() as *const char,
    );
    check_case(label, buf_str(&src.b[0]), ok);
}

// Family A -- aliasing: two borrows of p, both kept live. Reject iff their places overlap and at least
// one is `&mut`.
@test
fn aliasing() {
    let kinds: [str; 2] = ["", "mut "];
    let places: [str; 3] = ["p", "p.a", "p.b"];
    for k1 in 0..2 {
        for k2 in 0..2 {
            for p1 in 0..3 {
                for p2 in 0..3 {
                    let mut u1 = Buf64 {};
                    let mut u2 = Buf64 {};
                    use_ref(&mut u1.b[0], "b1", p1);
                    use_ref(&mut u2.b[0], "b2", p2);
                    let mut src = Buf2048 {};
                    unsafe stdio::snprintf(
                        &mut src.b[0],
                        2048,
                        "%sfn main() i32 { let mut p = P { a: 1, b: 2 };\n  let b1 = &%s%s;\n  let b2 = &%s%s;\n  let keep = %s + %s; return keep; }\n".ptr() as *const char,
                        PRE.ptr() as *const char,
                        kinds[k1].ptr() as *const char,
                        places[p1].ptr() as *const char,
                        kinds[k2].ptr() as *const char,
                        places[p2].ptr() as *const char,
                        &u1.b[0],
                        &u2.b[0],
                    );
                    let want = !(overlap(p1, p2) && (k1 != 0 || k2 != 0));
                    check_case("aliasing", buf_str(&src.b[0]), want);
                }
            }
        }
    }
}

// Family B -- use-while-borrowed: a stored `&[mut] p<P1>` kept live across a plain READ of p<P2>.
// Reject iff the read overlaps the borrow and the borrow is `&mut`.
@test
fn use_while_borrowed() {
    let kinds: [str; 2] = ["", "mut "];
    let places: [str; 3] = ["p", "p.a", "p.b"];
    for k in 0..2 {
        for p1 in 0..3 {
            for p2 in 0..3 {
                let mut ur = Buf64 {};
                use_ref(&mut ur.b[0], "r", p1);
                let mut src = Buf2048 {};
                unsafe stdio::snprintf(
                    &mut src.b[0],
                    2048,
                    "%sfn main() i32 { let mut p = P { a: 1, b: 2 };\n  let r = &%s%s;\n  let y = %s;\n  let keep = %s; return keep; }\n".ptr() as *const char,
                    PRE.ptr() as *const char,
                    kinds[k].ptr() as *const char,
                    places[p1].ptr() as *const char,
                    places[p2].ptr() as *const char,
                    &ur.b[0],
                );
                let want = !(overlap(p1, p2) && k != 0);
                check_case("use while borrowed", buf_str(&src.b[0]), want);
            }
        }
    }
}

// Family C -- NLL: identical to B but the reference's LAST use precedes the read, so EVERY case accepts.
@test
fn nll() {
    let kinds: [str; 2] = ["", "mut "];
    let places: [str; 3] = ["p", "p.a", "p.b"];
    for k in 0..2 {
        for p1 in 0..3 {
            for p2 in 0..3 {
                let mut ur = Buf64 {};
                use_ref(&mut ur.b[0], "r", p1);
                let mut src = Buf2048 {};
                unsafe stdio::snprintf(
                    &mut src.b[0],
                    2048,
                    "%sfn main() i32 { let mut p = P { a: 1, b: 2 };\n  let r = &%s%s;\n  let used = %s;\n  let y = %s; return used; }\n".ptr() as *const char,
                    PRE.ptr() as *const char,
                    kinds[k].ptr() as *const char,
                    places[p1].ptr() as *const char,
                    &ur.b[0],
                    places[p2].ptr() as *const char,
                );
                check_case("nll", buf_str(&src.b[0]), true);
            }
        }
    }
}

// Family D -- moves under a borrow on a Free type. Reject iff the move happens while the borrow is live.
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

// Family E -- lifetimes / dangling returns and their safe counterparts (no prefix macro).
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

// Family F -- scope-scoped borrows and disjoint-field mutation: valid patterns the checker must ACCEPT.
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

// Family G -- the gaps closed after the first audit: implicit method-receiver borrows, assign-while-borrowed,
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
        "enum E { V(i32) }\nfn main() i32 { let mut e = E::V(1); let r = switch &mut e { V(y) => y, }; let z = e; *r = 2; return z; }\n",
        false,
    );
    check_case(
        "match &e shared peek",
        "enum E { V(i32) }\nfn main() i32 { let e = E::V(1); let n = switch &e { V(y) => *y, }; return n; }\n",
        true,
    );
    check_case(
        "assign arg while tuple-destructured ref live",
        "fn split(a: &mut i32, b: &mut i32) (&i32, &i32) { return a, b; }\nfn main() i32 { let mut x = 5; let mut y = 6; let (r, s) = split(&mut x, &mut y); x = 9; return *r + *s; }\n",
        false,
    );
    check_case(
        "tuple refs scoped, then assign arg",
        "fn split(a: &mut i32, b: &mut i32) (&i32, &i32) { return a, b; }\nfn main() i32 { let mut x = 5; let mut y = 6; { let (r, s) = split(&mut x, &mut y); let v = *r + *s; } x = 9; return x; }\n",
        true,
    );
    check_case(
        "non-reference tuple destructure",
        "fn dm(a: i32, b: i32) (i32, i32) { return a / b, a % b; }\nfn main() i32 { let mut x = 5; let (q, r) = dm(17, 5); x = 9; return q + r + x; }\n",
        true,
    );
}

// Family J -- reference-binding semantics (second-audit fixes): reassign rebinds (A1), &mut moves / & copies
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
        "fn main() i32 { let mut a = [1, 2, 3]; let i = 0; let j = 1; let x = &mut a[i]; let y = &mut a[j]; return *x + *y; }\n",
        false,
    );
}

// Family K -- third-audit fixes: binding-scoped borrow regions, dangling stored refs, method-returned ref
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
    case_pre(
        PRE,
        "fn make() P { return P { a: 1, b: 2 }; }\nfn main() i32 { let r = &make(); return r.a; }\n",
        "K12 address of call result",
        false,
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

// Family H -- THREE simultaneous borrows of one variable, all kept live. Valid iff every overlapping pair
// is shared+shared (no overlapping pair includes a `&mut`).
@test
fn aliasing3() {
    let kinds: [str; 2] = ["", "mut "];
    let places: [str; 3] = ["p", "p.a", "p.b"];
    for k1 in 0..2 {
        for k2 in 0..2 {
            for k3 in 0..2 {
                for p1 in 0..3 {
                    for p2 in 0..3 {
                        for p3 in 0..3 {
                            let mut u1 = Buf64 {};
                            let mut u2 = Buf64 {};
                            let mut u3 = Buf64 {};
                            use_ref(&mut u1.b[0], "b1", p1);
                            use_ref(&mut u2.b[0], "b2", p2);
                            use_ref(&mut u3.b[0], "b3", p3);
                            let mut src = Buf2048 {};
                            unsafe stdio::snprintf(
                                &mut src.b[0],
                                2048,
                                "%sfn main() i32 { let mut p = P { a: 1, b: 2 };\n  let b1 = &%s%s;\n  let b2 = &%s%s;\n  let b3 = &%s%s;\n  let keep = %s + %s + %s; return keep; }\n".ptr() as *const char,
                                PRE.ptr() as *const char,
                                kinds[k1].ptr() as *const char,
                                places[p1].ptr() as *const char,
                                kinds[k2].ptr() as *const char,
                                places[p2].ptr() as *const char,
                                kinds[k3].ptr() as *const char,
                                places[p3].ptr() as *const char,
                                &u1.b[0],
                                &u2.b[0],
                                &u3.b[0],
                            );
                            let bad = overlap(p1, p2) && (k1 != 0 || k2 != 0) || overlap(p1, p3) && (k1 != 0 || k3 != 0) || overlap(
                                p2,
                                p3,
                            ) && (k2 != 0 || k3 != 0);
                            check_case("aliasing3", buf_str(&src.b[0]), !bad);
                        }
                    }
                }
            }
        }
    }
}

// Self-contained scenario bodies (each a function body returning i32) with a known verdict, drawn from the
// tricky valid cases and the closed-gap rejections. N_SNIPPET = 16.
fn snippet_body(i: i32) str {
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
fn snippet_ok(i: i32) bool {
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
    let mut src = Buf8192 {};
    let mut calls = Buf2048 {};
    let mut at: i32 = unsafe stdio::snprintf(&mut src.b[0], 8192, "%s".ptr() as *const char, PRE.ptr() as *const char);
    let mut cat: i32 = 0;
    let mut ok = true;
    unsafe calls.b[0] = 0 as char;
    for i in 0..n {
        let bi = unsafe idx[i as usize];
        at = at + unsafe stdio::snprintf(
            &mut src.b[at as usize],
            (8192 - at) as usize,
            "fn s%d() i32 { %s }\n".ptr() as *const char,
            i,
            snippet_body(bi).ptr() as *const char,
        );
        let mut sep = "";
        if i != 0 {
            sep = " + ";
        }
        cat = cat + unsafe stdio::snprintf(
            &mut calls.b[cat as usize],
            (2048 - cat) as usize,
            "%ss%d()".ptr() as *const char,
            sep.ptr() as *const char,
            i,
        );
        ok = ok && snippet_ok(bi);
    }
    let mut tail = "0".ptr() as *const char;
    if n != 0 {
        tail = &calls.b[0];
    }
    unsafe stdio::snprintf(
        &mut src.b[at as usize],
        (8192 - at) as usize,
        "fn main() i32 { return %s; }\n".ptr() as *const char,
        tail,
    );
    check_case(label, buf_str(&src.b[0]), ok);
}

// Family I -- composition: independent scenarios must not interfere, an invalid one must not be masked by
// valids, and per-function borrow state must not leak between them.
@test
fn composition() {
    // All valids bundled -> accept.
    let mut av = IdxBuf {};
    let mut nv: i32 = 0;
    for i in 0..16 {
        if snippet_ok(i) {
            av.b[nv as usize] = i;
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
                idx.b[k as usize] = av.b[t as usize];
                k = k + 1;
            }
            idx.b[k as usize] = j;
            k = k + 1;
            let mut lbuf = Buf2048 {};
            unsafe stdio::snprintf(&mut lbuf.b[0], 2048, "bundle: valids + invalid #%d".ptr() as *const char, j);
            bundle(&idx.b[0], k, buf_str(&lbuf.b[0]));
        }
    }

    // Every ordered pair of scenarios -> accept iff both are valid.
    for a in 0..16 {
        for b in 0..16 {
            let mut pair = IdxBuf {};
            pair.b[0] = a;
            pair.b[1] = b;
            let mut lbuf = Buf2048 {};
            unsafe stdio::snprintf(&mut lbuf.b[0], 2048, "bundle pair (%d,%d)".ptr() as *const char, a, b);
            bundle(&pair.b[0], 2, buf_str(&lbuf.b[0]));
        }
    }
}
