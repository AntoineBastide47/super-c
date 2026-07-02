// Auto-generating borrow-checker suite. The borrow checker is a STATIC analysis, so -- unlike raii_gen,
// which runs each program and checks the freed-byte multiset -- every generated program carries a
// rule-derived VERDICT (accept vs reject), and the oracle asserts the typechecker agrees. Programs are
// compiled only through ST_TYPECHECK (no external cc / run), so the whole matrix is milliseconds and runs
// serially. The verdict for each family is computed from the single-threaded borrow rules the checker
// enforces:
//   * aliasing:  a place has many `&` OR one `&mut`; two borrows conflict iff their places OVERLAP and at
//                least one is `&mut`. Overlap is field-precise: `p.a` and `p.b` are disjoint, but the whole
//                `p` overlaps either field.
//   * use-while-borrowed: reading a place is illegal while an OVERLAPPING `&mut` is live (reads under `&`
//                are fine); moving a value is illegal while any overlapping borrow is live.
//   * NLL: a stored borrow ends at its binding's LAST USE, not at scope exit -- so an operation after the
//                reference is last used never conflicts.
//   * lifetimes: returning a reference that traces to a local or a by-value parameter dangles; returning a
//                reference parameter (or a reborrow of one) is fine.
// If any of these regress (a false accept OR a false reject), the multiset of verdicts diverges and the run
// fails with the offending source printed.

#include "test_harness.h"

#define PRE "struct P { pub a: i32, pub b: i32 }\n"
#define OWN "struct Own { pub id: i32 }\nextend Own as Free { fn free(self: &mut Own) { } }\n"

// Borrow kind spelled after `&`: shared vs mutable. Places over the two-field struct `p`: 0 = whole p (which
// overlaps everything), 1 = p.a, 2 = p.b (the fields are disjoint).
static const char *KIND[2] = {"", "mut "};
static const char *PLACE[3] = {"p", "p.a", "p.b"};

static bool overlap(int i, int j) {
  return i == j || i == 0 || j == 0;
}

// An i32-valued use of reference binding `name` that borrows place `pi`: the whole struct reads a field
// (`name.a`, auto-deref), a field reads through the reference (`*name`). Keeps the borrow alive up to here.
static void use_ref(char *b, size_t cap, const char *name, int pi) {
  snprintf(b, cap, pi == 0 ? "%s.a" : "*%s", name);
}

// Compile through the typechecker only and assert the accept/reject verdict. A rejection must come FROM the
// typechecker (a borrow diagnostic), never an unrelated earlier stage -- otherwise the program is malformed
// for a reason other than the one under test and the case proves nothing.
static void check_case(const char *label, const char *src, bool expect_ok) {
  ScResult r = sc_compile(label, src, ST_TYPECHECK);
  const bool ok = (r.errors == 0);
  CHECK(ok == expect_ok, "%s: expected %s, got %s (%zu %s error%s%s%s)\n----- SRC -----\n%s", label,
        expect_ok ? "ACCEPT" : "REJECT", ok ? "ACCEPT" : "REJECT", r.errors, sc_stage_name(r.err_stage),
        r.errors == 1 ? "" : "s", r.errors ? "; first: " : "", r.errors ? r.first : "", src);
  if (!ok && expect_ok == false)
    CHECK(r.err_stage == ST_TYPECHECK, "%s: rejection came from the %s, expected the typechecker\n----- SRC -----\n%s",
          label, sc_stage_name(r.err_stage), src);
  ast_free(&r.ast);
  free(r.code);
  th_rmtree(r.build_dir);
}

// Family A -- aliasing: two borrows of p, both kept live (each used after the other is taken), so they must
// coexist. Reject iff their places overlap and at least one is `&mut`.
static void gen_aliasing(void) {
  for (int k1 = 0; k1 < 2; k1++)
    for (int k2 = 0; k2 < 2; k2++)
      for (int p1 = 0; p1 < 3; p1++)
        for (int p2 = 0; p2 < 3; p2++) {
          char u1[32], u2[32], src[2048], label[160];
          use_ref(u1, sizeof u1, "b1", p1);
          use_ref(u2, sizeof u2, "b2", p2);
          snprintf(src, sizeof src,
                   PRE "fn main() i32 { let mut p = P { a: 1, b: 2 };\n"
                       "  let b1 = &%s%s;\n  let b2 = &%s%s;\n  let keep = %s + %s; return keep; }\n",
                   KIND[k1], PLACE[p1], KIND[k2], PLACE[p2], u1, u2);
          snprintf(label, sizeof label, "alias &%s%s + &%s%s", KIND[k1], PLACE[p1], KIND[k2], PLACE[p2]);
          check_case(label, src, !(overlap(p1, p2) && (k1 || k2)));
        }
}

// Family B -- use-while-borrowed: a stored `&[mut] p<P1>` kept live across a plain READ of p<P2>. Reject iff
// the read overlaps the borrow and the borrow is `&mut` (reading under a shared borrow is allowed).
static void gen_use_while_borrowed(void) {
  for (int k = 0; k < 2; k++)
    for (int p1 = 0; p1 < 3; p1++)
      for (int p2 = 0; p2 < 3; p2++) {
        char ur[32], src[2048], label[160];
        use_ref(ur, sizeof ur, "r", p1);
        // `y` reads p<P2> (triggering the use check) but is otherwise unused; the whole-p read binds a struct,
        // so it must not feed the i32 result -- `keep` (an i32 through the reference) is what we return.
        snprintf(src, sizeof src,
                 PRE "fn main() i32 { let mut p = P { a: 1, b: 2 };\n"
                     "  let r = &%s%s;\n  let y = %s;\n  let keep = %s; return keep; }\n",
                 KIND[k], PLACE[p1], PLACE[p2], ur);
        snprintf(label, sizeof label, "read %s while &%s%s live", PLACE[p2], KIND[k], PLACE[p1]);
        check_case(label, src, !(overlap(p1, p2) && k));
      }
}

// Family C -- NLL: identical to B, but the reference's LAST use precedes the read of p<P2>. Under non-lexical
// lifetimes the borrow is already dead at the read, so EVERY case must be accepted -- a lexical checker would
// wrongly reject the overlapping-`&mut` ones, so this family is the NLL regression guard.
static void gen_nll(void) {
  for (int k = 0; k < 2; k++)
    for (int p1 = 0; p1 < 3; p1++)
      for (int p2 = 0; p2 < 3; p2++) {
        char ur[32], src[2048], label[160];
        use_ref(ur, sizeof ur, "r", p1);
        // `used` is the reference's last use; the later read of p<P2> (bound to an unused `y`) happens after
        // the borrow is dead, so it must be accepted under NLL. `used` (an i32) is what we return.
        snprintf(src, sizeof src,
                 PRE "fn main() i32 { let mut p = P { a: 1, b: 2 };\n"
                     "  let r = &%s%s;\n  let used = %s;\n  let y = %s; return used; }\n",
                 KIND[k], PLACE[p1], ur, PLACE[p2]);
        snprintf(label, sizeof label, "NLL read %s after &%s%s dead", PLACE[p2], KIND[k], PLACE[p1]);
        check_case(label, src, true);
      }
}

// Family D -- moves under a borrow, on a Free type (so a by-value bind is a real move). Reject iff the move
// happens while the shared borrow is still live; accept when NLL has ended the borrow first.
static void gen_moves(void) {
  check_case("move s while &s live",
             OWN "fn main() i32 { let s = Own { id: 1 }; let r = &s; let t = s; let keep = r.id; return t.id + keep; }\n",
             false);
  check_case("move s after &s dead (NLL)",
             OWN "fn main() i32 { let s = Own { id: 1 }; let r = &s; let keep = r.id; let t = s; return t.id + keep; }\n",
             true);
}

// Family E -- lifetimes / dangling returns, and their safe counterparts. Fixed cases with hand-checked verdicts.
static void gen_lifetimes(void) {
  struct {
    const char *label;
    const char *src;
    bool ok;
  } cases[] = {
      {"return &local", "fn f() &i32 { let x = 5; return &x; }\nfn main() i32 { return *f(); }\n", false},
      {"return stored ref to local", "fn f() &i32 { let x = 5; let r = &x; return r; }\nfn main() i32 { return *f(); }\n",
       false},
      {"return ref chained to local",
       "fn f() &i32 { let x = 5; let r = &x; let s = r; return s; }\nfn main() i32 { return *f(); }\n", false},
      {"return &by-value param", "fn f(x: i32) &i32 { return &x; }\nfn main() i32 { return *f(5); }\n", false},
      {"return &field of local",
       "struct Q { pub a: i32 }\nfn f() &i32 { let q = Q { a: 1 }; return &q.a; }\nfn main() i32 { return *f(); }\n",
       false},
      {"return ref param", "fn f(x: &i32) &i32 { return x; }\nfn main() i32 { let v = 5; return *f(&v); }\n", true},
      {"return reborrow of ref param",
       "fn f(x: &i32) &i32 { let r = x; return r; }\nfn main() i32 { let v = 5; return *f(&v); }\n", true},
  };
  for (size_t i = 0; i < sizeof cases / sizeof *cases; i++)
    check_case(cases[i].label, cases[i].src, cases[i].ok);
}

// Family F -- scope-scoped borrows and disjoint-field mutation: valid patterns the checker must ACCEPT.
static void gen_valid_patterns(void) {
  check_case("scoped &mut released before use",
             "fn main() i32 { let mut x = 5; { let r = &mut x; *r = 1; } let y = x; return y; }\n", true);
  check_case("two disjoint &mut fields coexist",
             PRE "fn add2(x: &mut i32, y: &mut i32) i32 { return *x + *y; }\n"
                 "fn main() i32 { let mut p = P { a: 1, b: 2 }; return add2(&mut p.a, &mut p.b); }\n",
             true);
  check_case("sequential borrows of x",
             "fn main() i32 { let mut x = 5; let a = &mut x; *a = 2; let b = &x; return *b; }\n", true);
  check_case("many shared borrows",
             "fn main() i32 { let x = 5; let a = &x; let b = &x; let c = &x; return *a + *b + *c; }\n", true);
}

#define CDEF                                                                                                            \
  "struct C { pub n: i32 }\n"                                                                                           \
  "extend C { fn bump(self: &mut C) { self.n = self.n + 1; } fn get(self: &C) i32 { return self.n; } }\n"
#define CDEF2                                                                                                           \
  "struct H { pub v: i32 }\n"                                                                                           \
  "extend H { fn geti(self: &H) &i32 { return &self.v; } fn seti(self: &mut H, n: i32) { self.v = n; } }\n"
#define SINK OWN "fn sink(v: Own) i32 { return v.id; }\n"

// Family G -- the gaps that were closed after the first audit: implicit method-receiver borrows (with
// two-phase), assign-while-borrowed, reborrows, conservative returned-reference provenance, and moves across
// a loop back-edge. Each has both the rejecting case and a valid counterpart it must still accept.
static void gen_closed_gaps(void) {
  struct {
    const char *label;
    const char *src;
    bool ok;
  } cases[] = {
      // implicit &mut-self method mutation while a shared borrow is live
      {"method &mut self while &c live", CDEF "fn main() i32 { let mut c = C { n: 0 }; let r = &c; c.bump(); return r.n; }\n",
       false},
      {"method &self read while &mut c live",
       CDEF "fn main() i32 { let mut c = C { n: 0 }; let r = &mut c; let v = c.get(); return v + r.n; }\n", false},
      // two-phase borrow must still be accepted
      {"two-phase v.push(v.len())",
       "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(1); v.push(v.len() as i32); return v.len() as i32; }\n",
       true},
      // method call after the reference is dead (NLL)
      {"method after ref dead (NLL)",
       CDEF "fn main() i32 { let mut c = C { n: 0 }; let r = &c; let v = r.n; c.bump(); return v + c.get(); }\n", true},
      // assignment through the owner while a shared borrow is live, and its valid (NLL) counterpart
      {"assign x while &x live", "fn main() i32 { let mut x = 5; let r = &x; x = 9; return *r; }\n", false},
      {"assign x after &x dead", "fn main() i32 { let mut x = 5; let r = &x; let v = *r; x = 9; return x + v; }\n", true},
      // reborrow `&*r`, then mutate the origin
      {"mutate origin while reborrow live",
       "fn main() i32 { let mut x = 5; let r = &mut x; let s = &*r; x = 9; return *s; }\n", false},
      // conservative returned-reference provenance: r is taken to borrow f's ref argument
      {"assign arg while call-result ref live",
       "fn pick(a: &i32) &i32 { return a; }\nfn main() i32 { let mut x = 5; let r = pick(&x); x = 9; return *r; }\n",
       false},
      // move across a loop back-edge, vs the same loop that reassigns (so the next iteration is fine)
      {"move in loop, no reassign",
       SINK "fn main() i32 { let s = Own { id: 1 }; let mut i = 0; while i < 3 { let k = sink(s); i = i + 1; } return 0; }\n",
       false},
      {"move + reassign in loop",
       SINK "fn main() i32 { let mut s = Own { id: 1 }; let mut i = 0; while i < 3 { let k = sink(s); s = Own { id: 2 }; "
            "i = i + 1; } return 0; }\n",
       true},
      // reassigning a moved binding, then moving again (was a pre-existing false positive)
      {"reassign then move again",
       SINK "fn main() i32 { let mut s = Own { id: 1 }; let a = sink(s); s = Own { id: 2 }; let b = sink(s); return a + "
            "b; }\n",
       true},
      // match binding mode: a by-`&mut` match holds the scrutinee borrowed through the arms and their
      // bindings, so reading the scrutinee while a payload binding is live conflicts; a shared peek is fine.
      {"read scrutinee while &mut payload binding live",
       "enum E { V(i32) }\nfn main() i32 { let mut e = E::V(1); let r = switch &mut e { V(y) => y, }; let z = e; *r = "
       "2; return z; }\n",
       false},
      {"match &e shared peek",
       "enum E { V(i32) }\nfn main() i32 { let e = E::V(1); let n = switch &e { V(y) => *y, }; return n; }\n", true},
      // references destructured from a multi-return tuple: they conservatively borrow the call's ref args, so
      // mutating an arg while a destructured ref is live conflicts; scoping the tuple, or a non-ref tuple, is fine.
      {"assign arg while tuple-destructured ref live",
       "fn split(a: &mut i32, b: &mut i32) (&i32, &i32) { return a, b; }\n"
       "fn main() i32 { let mut x = 5; let mut y = 6; let (r, s) = split(&mut x, &mut y); x = 9; return *r + *s; }\n",
       false},
      {"tuple refs scoped, then assign arg",
       "fn split(a: &mut i32, b: &mut i32) (&i32, &i32) { return a, b; }\n"
       "fn main() i32 { let mut x = 5; let mut y = 6; { let (r, s) = split(&mut x, &mut y); let v = *r + *s; } x = 9; "
       "return x; }\n",
       true},
      {"non-reference tuple destructure",
       "fn dm(a: i32, b: i32) (i32, i32) { return a / b, a % b; }\n"
       "fn main() i32 { let mut x = 5; let (q, r) = dm(17, 5); x = 9; return q + r + x; }\n",
       true},
  };
  for (size_t i = 0; i < sizeof cases / sizeof *cases; i++)
    check_case(cases[i].label, cases[i].src, cases[i].ok);
}

// Family J -- reference-binding semantics (the second-audit fixes): reassigning a reference rebinds its
// borrow (A1), copying a `&mut` moves it while a `&` copies it (A2), a reborrow freezes its origin (A3), a
// field reached THROUGH a `&mut` reference is borrow-tracked (A4), and distinct constant array slots are
// disjoint (B5). Each rejection must come from the borrow checker, and each has a valid counterpart.
static void gen_ref_semantics(void) {
  struct {
    const char *label;
    const char *src;
    bool ok;
  } cases[] = {
      // A1: reassigning r to borrow y makes reading y illegal; the old target x is freed and readable again.
      {"A1 reassigned ref aliases new target",
       "fn main() i32 { let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let b = y; return *r + b; }\n",
       false},
      {"A1 reassigned ref frees old target",
       "fn main() i32 { let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let a = x; return *r + a; }\n",
       true},
      // A1 must not depend on the count of prior borrows: a reference initialized from a (untracked) parameter
      // has zero tracked borrows, yet reassigning it to alias a local must still register that borrow.
      {"A1 reassign ref that had no prior borrow",
       "fn g(p: &mut i32) i32 { let mut y = 0; let mut r = p; r = &mut y; let b = y; return *r + b; }\n"
       "fn main() i32 { let mut x = 0; return g(&mut x); }\n",
       false},
      // A2: `let r2 = r1` moves a `&mut` (using r1 after is a use-after-move) but copies a `&` (both stay live).
      {"A2 copy of &mut moves it",
       "fn main() i32 { let mut x = 0; let r1 = &mut x; let r2 = r1; *r1 = 1; *r2 = 2; return x; }\n", false},
      {"A2 copy of & duplicates it",
       "fn main() i32 { let x = 0; let r1 = &x; let r2 = r1; let a = *r1; let b = *r2; return a + b; }\n", true},
      {"A2 copied & keeps origin tracked",
       "fn main() i32 { let mut x = 0; let r1 = &x; let r2 = r1; x = 9; return *r1 + *r2; }\n", false},
      // A3: reborrow `&mut *r`, then using the ORIGIN r (through `*r`) while the reborrow is live is illegal;
      // scoping the reborrow releases it (NLL / lexical), so the later use of r is fine.
      {"A3 use origin while reborrow live",
       "fn main() i32 { let mut x = 0; let r = &mut x; let r2 = &mut *r; *r = 1; return *r2; }\n", false},
      {"A3 reborrow scoped, then use origin",
       "fn main() i32 { let mut x = 0; let r = &mut x; { let r2 = &mut *r; *r2 = 1; } *r = 2; return *r; }\n", true},
      // A4: two `&mut` to the SAME field through a `&mut` reference conflict; disjoint fields coexist; reading a
      // field through r while it is `&mut`-borrowed conflicts; a whole reborrow overlaps a field reborrow.
      {"A4 two &mut same field through ref",
       PRE "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.a; return "
           "*x + *y; }\n",
       false},
      {"A4 disjoint fields through ref",
       PRE "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.b; return "
           "*x + *y; }\n",
       true},
      {"A4 read field through ref while &mut field live",
       PRE "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let v = r.a; return *x + v; }\n",
       false},
      {"A4 whole reborrow overlaps field reborrow",
       PRE "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let z = &mut *r; return *x "
           "+ z.a; }\n",
       false},
      // B5: distinct constant array slots are disjoint, so two `&mut` to them coexist and a disjoint read is fine;
      // the same constant slot conflicts, and variable indices stay conservative (cannot be disproved equal).
      {"B5 distinct constant slots coexist",
       "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[1]; return *x + *y; }\n", true},
      {"B5 read disjoint slot while &mut other slot",
       "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let v = a[1]; return *x + v; }\n", true},
      {"B5 same constant slot conflicts",
       "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[0]; return *x + *y; }\n", false},
      {"B5 variable indices conservative",
       "fn main() i32 { let mut a = [1, 2, 3]; let i = 0; let j = 1; let x = &mut a[i]; let y = &mut a[j]; return *x + "
       "*y; }\n",
       false},
  };
  for (size_t i = 0; i < sizeof cases / sizeof *cases; i++)
    check_case(cases[i].label, cases[i].src, cases[i].ok);
}

// Family K -- the third-audit fixes: binding-scoped borrow regions (rebinds in inner scopes), dangling
// stored references, method-returned reference tracking, flow-accurate return-escape, `move`-wrapper
// transparency, loop-aware definite-init, free-through-reference, places through reference parameters,
// union member aliasing, tuple-let/loop-binding roots, same-call double use, unaddressable temporaries,
// defer replay semantics, sub-statement NLL, and `&mut`-out-param initialization. Each rejection is paired
// with the closest valid program the checker must still accept.
static void gen_third_audit(void) {
  struct {
    const char *label;
    const char *src;
    bool ok;
  } cases[] = {
      // K1: a rebind in an INNER scope stores the borrow for r's (outer) scope, so the aliasing persists;
      // once r is dead (NLL) the same shape is fine.
      {"K1 inner-scope rebind keeps borrow",
       "fn main() i32 { let mut x = 1; let y = 2; let mut r = &y; { r = &x; } let m = &mut x; return *r + *m; }\n",
       false},
      {"K1 inner-scope rebind, ref dead",
       "fn main() i32 { let mut x = 1; let y = 2; let mut r = &y; { r = &x; } let v = *r; let m = &mut x; *m = 3; "
       "return v; }\n",
       true},
      // K2: rebinding an outer reference to an inner-scope local dangles when the block ends; rebinding to
      // something that outlives r is fine.
      {"K2 stored ref outlives referent",
       "fn main() i32 { let x = 1; let mut r = &x; { let y = 2; r = &y; } return *r; }\n", false},
      {"K2 stored ref to longer-lived value",
       "fn main() i32 { let y = 2; let x = 1; let mut r = &x; { r = &y; } return *r; }\n", true},
      // K3: a reference RETURNED BY A METHOD borrows its receiver while held; deref-and-copy ends it (NLL).
      {"K3 mutate while method-returned ref live",
       CDEF2 "fn main() i32 { let mut h = H { v: 1 }; let r = h.geti(); h.seti(5); return *r; }\n", false},
      {"K3 method ref deref'd before mutate",
       CDEF2 "fn main() i32 { let mut h = H { v: 1 }; let v = *h.geti(); h.seti(5); return v + h.v; }\n", true},
      // K4: return-escape follows the LIVE borrows, not the initializer: reassigned-to-param is safe,
      // reassigned-to-local dangles.
      {"K4 return ref reassigned to local",
       "fn f(p: &i32) &i32 { let mut r = p; let x = 1; r = &x; return r; }\n"
       "fn main() i32 { let v = 5; return *f(&v); }\n",
       false},
      {"K4 return ref reassigned to param",
       "fn f(p: &i32) &i32 { let x = 1; let mut r = &x; r = p; return r; }\n"
       "fn main() i32 { let v = 5; return *f(&v); }\n",
       true},
      // K5: `move x` is transparent to move tracking.
      {"K5 move keyword still moves", OWN "fn main() i32 { let s = Own { id: 1 }; let t = move s; let u = s; return "
                                          "t.id + u.id; }\n",
       false},
      {"K5 move keyword, no reuse", OWN "fn main() i32 { let s = Own { id: 1 }; let t = move s; return t.id; }\n", true},
      // K6: a while body may run zero times, so its initialization is not definite; a do-while body runs once.
      {"K6 init only inside while",
       "fn main() i32 { let mut x: i32; let c = false; while c { x = 1; } return x; }\n", false},
      {"K6 init inside do-while",
       "fn main() i32 { let mut x: i32; do { x = 1; } while false; return x; }\n", true},
      // K7: freeing through a reference to a locally-owned value double-frees (the owner frees again at scope
      // exit); through a reference PARAMETER the referent is caller-owned -- the normal destructor pattern.
      {"K7 free through local ref",
       OWN "fn main() i32 { let mut s = Own { id: 1 }; let r = &mut s; r.free(); return 0; }\n", false},
      {"K7 free through param ref",
       OWN "fn kill(o: &mut Own) { o.free(); }\nfn main() i32 { let mut s = Own { id: 1 }; kill(&mut s); return 0; }\n",
       true},
      // K8: places THROUGH a reference parameter are tracked like local-reference places.
      {"K8 overlapping reborrows through param",
       "fn f(p: &mut i32) i32 { let a = &mut *p; let b = &mut *p; return *a + *b; }\n"
       "fn main() i32 { let mut x = 0; return f(&mut x); }\n",
       false},
      {"K8 disjoint fields through param",
       PRE "fn f(p: &mut P) i32 { let a = &mut p.a; let b = &mut p.b; return *a + *b; }\n"
           "fn main() i32 { let mut q = P { a: 1, b: 2 }; return f(&mut q); }\n",
       true},
      // K9: an untagged union's members alias -- field-name disjointness does not apply.
      {"K9 union members alias",
       "union U { pub a: i32, pub b: f32 }\n"
       "fn main() i32 { let mut u = U { a: 1 }; let r = &u.a; let m = &mut u.b; *m = 2.0; return *r; }\n",
       false},
      {"K9 union shared+shared ok",
       "union U { pub a: i32, pub b: f32 }\n"
       "fn main() i32 { let u = U { a: 1 }; let r = &u.a; let s = &u.a; return *r + *s; }\n",
       true},
      // K10: tuple-let elements are borrow roots.
      {"K10 tuple element double &mut",
       "fn two() (i32, i32) { return 1, 2; }\n"
       "fn main() i32 { let mut (a, b) = two(); let r = &a; let m = &mut a; *m = 9; return *r + b; }\n",
       false},
      {"K10 tuple element sequential borrows",
       "fn two() (i32, i32) { return 1, 2; }\n"
       "fn main() i32 { let mut (a, b) = two(); let r = &a; let v = *r; let m = &mut a; *m = 9; return v + b; }\n",
       true},
      // K11: the same call may not move a value AND alias it (or move it twice); separate values are fine.
      {"K11 move + &mut same value in one call",
       OWN "fn g(v: Own, m: &mut Own) i32 { return v.id + m.id; }\n"
           "fn main() i32 { let mut s = Own { id: 1 }; return g(s, &mut s); }\n",
       false},
      {"K11 move same value twice in one call",
       OWN "fn g(v: Own, w: Own) i32 { return v.id + w.id; }\n"
           "fn main() i32 { let s = Own { id: 1 }; return g(s, s); }\n",
       false},
      {"K11 move two distinct values",
       OWN "fn g(v: Own, w: Own) i32 { return v.id + w.id; }\n"
           "fn main() i32 { let s = Own { id: 1 }; let u = Own { id: 2 }; return g(s, u); }\n",
       true},
      // K12: the address of an unmaterializable temporary (a call result of aggregate type) has no C spelling.
      {"K12 address of call result",
       PRE "fn make() P { return P { a: 1, b: 2 }; }\nfn main() i32 { let r = &make(); return r.a; }\n", false},
      {"K12 address of struct literal",
       PRE "fn main() i32 { let r = &P { a: 1, b: 2 }; return r.a; }\n", true},
      // K13: defer runs at scope EXIT: uses before it are fine; two defers freeing one value still collide.
      {"K13 use before deferred free",
       OWN "fn main() i32 { let mut s = Own { id: 1 }; defer s.free(); let v = s.id; return v; }\n", true},
      {"K13 two defers free one value",
       OWN "fn main() i32 { let mut s = Own { id: 1 }; defer s.free(); defer s.free(); return 0; }\n", false},
      // K14: sub-statement NLL -- a borrow whose binding's last use precedes the conflicting operation in the
      // SAME statement has expired; a use after keeps it live.
      {"K14 last use before &mut in one call",
       "fn f(v: i32, m: &mut i32) { *m = v; }\n"
       "fn main() i32 { let mut x = 1; let r = &x; f(*r, &mut x); return x; }\n",
       true},
      {"K14 assign from own borrow",
       "fn main() i32 { let mut x = 5; let r = &x; x = *r + 1; return x; }\n", true},
      {"K14 use after keeps borrow live",
       "fn f(v: i32, m: &mut i32) i32 { *m = v; return *m; }\n"
       "fn main() i32 { let mut x = 1; let r = &x; let v = f(*r, &mut x); return v + *r; }\n",
       false},
      // K15: `&mut x` on a deferred binding is out-parameter initialization.
      {"K15 out-param init via &mut",
       "fn init(p: &mut i32) { *p = 42; }\nfn main() i32 { let mut x: i32; init(&mut x); return x; }\n", true},
      {"K15 shared borrow does not init",
       "fn peek(p: &i32) i32 { return *p; }\nfn main() i32 { let mut x: i32; let v = peek(&x); return x + v; }\n",
       false},
  };
  for (size_t i = 0; i < sizeof cases / sizeof *cases; i++)
    check_case(cases[i].label, cases[i].src, cases[i].ok);
}

// Family H -- THREE simultaneous borrows of one variable, all kept live: exercises COMBINATIONS of borrows
// interacting on the same storage (the earlier aliasing family only pairs two). Valid iff every overlapping
// pair is shared+shared -- i.e. no overlapping pair includes a `&mut` (field-precise, so `&mut p.a` coexists
// with `&mut p.b` and any number of `&p.*`).
static void gen_aliasing3(void) {
  for (int k1 = 0; k1 < 2; k1++)
    for (int k2 = 0; k2 < 2; k2++)
      for (int k3 = 0; k3 < 2; k3++)
        for (int p1 = 0; p1 < 3; p1++)
          for (int p2 = 0; p2 < 3; p2++)
            for (int p3 = 0; p3 < 3; p3++) {
              char u1[32], u2[32], u3[32], src[2048], label[200];
              use_ref(u1, sizeof u1, "b1", p1);
              use_ref(u2, sizeof u2, "b2", p2);
              use_ref(u3, sizeof u3, "b3", p3);
              snprintf(src, sizeof src,
                       PRE "fn main() i32 { let mut p = P { a: 1, b: 2 };\n  let b1 = &%s%s;\n  let b2 = &%s%s;\n"
                           "  let b3 = &%s%s;\n  let keep = %s + %s + %s; return keep; }\n",
                       KIND[k1], PLACE[p1], KIND[k2], PLACE[p2], KIND[k3], PLACE[p3], u1, u2, u3);
              const bool bad = (overlap(p1, p2) && (k1 || k2)) || (overlap(p1, p3) && (k1 || k3)) ||
                               (overlap(p2, p3) && (k2 || k3));
              snprintf(label, sizeof label, "alias3 &%s%s &%s%s &%s%s", KIND[k1], PLACE[p1], KIND[k2], PLACE[p2],
                       KIND[k3], PLACE[p3]);
              check_case(label, src, !bad);
            }
}

// Self-contained scenario bodies (each a function body returning i32, using only its own locals) with a known
// verdict, drawn from the tricky valid cases and the closed-gap rejections. Family I bundles several into one
// program to test COMBINATIONS: independent scenarios must not interfere, an invalid one must not be masked by
// valid ones, and the per-function borrow state must not leak between them.
static const struct {
  const char *body;
  bool ok;
} SNIPPET[] = {
    {"let mut x = 0; let a = &x; let b = &x; return *a + *b;", true},                       // many shared
    {"let mut x = 0; let r = &mut x; *r = 1; let y = x; return y;", true},                  // NLL: use after last use
    {"let mut p = P { a: 1, b: 2 }; let ra = &mut p.a; let rb = &mut p.b; return *ra + *rb;", true}, // disjoint fields
    {"let mut x = 0; { let r = &mut x; *r = 1; } let y = x; return y;", true},              // scoped release
    {"let mut v = Vector::<i32>::new(); v.push(1); v.push(v.len() as i32); return v.len() as i32;", true}, // two-phase
    {"let mut x = 0; let r = &x; let s = &mut x; return *r + *s;", false},                  // aliasing conflict
    {"let mut x = 0; let r = &mut x; let y = x; return *r + y;", false},                    // use while mut-borrowed
    {"let mut x = 0; let r = &x; x = 9; return *r;", false},                                // assign while borrowed
    {"let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let a = x; return *r + a;", true}, // A1 reassign frees old
    {"let x = 0; let r1 = &x; let r2 = r1; return *r1 + *r2;", true},                       // A2 shared copy
    {"let mut x = 0; let r = &mut x; { let r2 = &mut *r; *r2 = 1; } *r = 2; return *r;", true}, // A3 scoped reborrow
    {"let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.b; return *x + *y;", true}, // A4 disjoint through ref
    {"let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[1]; return *x + *y;", true}, // B5 distinct slots
    {"let mut x = 0; let r1 = &mut x; let r2 = r1; *r1 = 1; return *r2;", false},           // A2 &mut copy -> use after move
    {"let mut x = 0; let r = &mut x; let r2 = &mut *r; *r = 1; return *r2;", false},        // A3 reborrow freezes origin
    {"let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.a; return *x + *y;", false}, // A4 same field twice
};
enum { N_SNIPPET = (int)(sizeof SNIPPET / sizeof *SNIPPET) };

// Bundle snippets `idx[0..n)` into one program (each its own function, main sums them) and assert the verdict:
// accepted iff EVERY bundled snippet is individually valid.
static void bundle(const int *idx, int n, const char *label) {
  char src[8192], calls[1024];
  int at = snprintf(src, sizeof src, PRE), cat = 0;
  bool ok = true;
  calls[0] = '\0';
  for (int i = 0; i < n; i++) {
    at += snprintf(src + at, sizeof src - at, "fn s%d() i32 { %s }\n", i, SNIPPET[idx[i]].body);
    cat += snprintf(calls + cat, sizeof calls - cat, "%ss%d()", i ? " + " : "", i);
    ok = ok && SNIPPET[idx[i]].ok;
  }
  snprintf(src + at, sizeof src - at, "fn main() i32 { return %s; }\n", n ? calls : "0");
  check_case(label, src, ok);
}

static void gen_composition(void) {
  // All valids bundled -> accept (many independent valid scenarios coexist without false positives).
  int all_valid[N_SNIPPET], nv = 0;
  for (int i = 0; i < N_SNIPPET; i++)
    if (SNIPPET[i].ok)
      all_valid[nv++] = i;
  bundle(all_valid, nv, "bundle: all valid scenarios");

  // Every invalid snippet, surrounded by all the valids -> reject (an invalid case is never masked).
  for (int j = 0; j < N_SNIPPET; j++)
    if (!SNIPPET[j].ok) {
      int idx[N_SNIPPET + 1], k = 0;
      for (int i = 0; i < nv; i++)
        idx[k++] = all_valid[i];
      idx[k++] = j;
      char label[64];
      snprintf(label, sizeof label, "bundle: valids + invalid #%d", j);
      bundle(idx, k, label);
    }

  // Every ordered pair of scenarios -> accept iff both are valid (exhaustive 2-combinations, both orders).
  for (int i = 0; i < N_SNIPPET; i++)
    for (int j = 0; j < N_SNIPPET; j++) {
      const int idx[2] = {i, j};
      char label[64];
      snprintf(label, sizeof label, "bundle pair (%d,%d)", i, j);
      bundle(idx, 2, label);
    }
}

int main(void) {
  gen_aliasing();
  gen_use_while_borrowed();
  gen_nll();
  gen_moves();
  gen_lifetimes();
  gen_valid_patterns();
  gen_closed_gaps();
  gen_ref_semantics();
  gen_third_audit();
  gen_aliasing3();
  gen_composition();
  if (failures) {
    fprintf(stderr, "%d borrow-gen test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("borrow-gen tests passed");
  return 0;
}
