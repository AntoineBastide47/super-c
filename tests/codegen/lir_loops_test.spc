// The loop transforms (`lir::loops`): after `optimize` each body still verifies and the evaluator gives
// the same outcome, a failing check's panic included; each transform happens within its budget and only
// there.
import lir::ir as *;
import lir::verify as verify;
import lir::print as lprint;
import lir::parse as lparse;
import lir::eval as leval;
import lir::opt as lopt;
import lir::inline as il;
import lir::loops as lu;

// Package text `text` read, then optimized with loop budgets `bu`: each body verifies after.
fn optimized(text: str, bu: lu::Budgets) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    let none = Vector::<bool>::new();
    lopt::optimize(&mut after, &none, lopt::Config { inline: il::SPEED, loops: bu });
    let mut v = verify::Verifier::new();
    for i in 0..after.syms.len() {
        let s = after.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            let b = &after.bodies[s.def as usize];
            assert(v.check(&after, after.spell(s.name), b), v.err.as_str());
        }
    }
    return before, after;
}

// The text of function `name` of `p`.
fn text_of(p: &Package, name: str) String {
    let mut all = String::new();
    lprint::print_package(p, &mut all);
    let head = format("fn @{}\n", name);
    let at = all.as_str().find(head.as_str());
    assert(at >= 0, head.as_str());
    let rest = all.as_str().slice(at as usize + head.len(), all.len());
    let f = rest.find("\nfn @");
    return String::from_str(
        rest.slice(
            0,
            if f >= 0 {
                f as usize + 1;
            } else {
                rest.len();
            },
        ),
    );
}

// The times `text` holds `pat`.
fn count(text: &String, pat: str) u32 {
    let mut n: u32 = 0;
    let mut s = text.as_str();
    let mut at = s.find(pat);
    // Each step moves past one match.
    while at >= 0 {
        n += 1;
        s = s.slice(at as usize + pat.len(), s.len());
        at = s.find(pat);
    }
    return n;
}

// Function `name` of `before` and of `after` on arguments `args` end alike: both return `want`, or with
// `panics` both panic with the same message.
fn same_outcome(before: &Package, after: &Package, name: str, args: []u64, want: u64, panics: bool) {
    let mut e = leval::Eval::new(before);
    let o = e.run(before.find_symbol(name), args);
    let mut e2 = leval::Eval::new(after);
    let o2 = e2.run(after.find_symbol(name), args);
    assert_eq(o.kind, o2.kind);
    assert(o.msg.as_str() == o2.msg.as_str(), o2.msg.as_str());
    assert(panics == (o.kind != leval::EV_OK), o.msg.as_str());
    if !panics {
        assert_eq(o.value, want);
        assert_eq(o2.value, want);
    }
}

const NO_LOOPS: lu::Budgets = lu::Budgets { peel: 0, version: 0, unswitch: 0, rotate: 0, vector: 0 };
const PEEL: lu::Budgets = lu::Budgets { peel: 200, version: 0, unswitch: 0, rotate: 0, vector: 0 };
const VERSION: lu::Budgets = lu::Budgets { peel: 0, version: 200, unswitch: 0, rotate: 0, vector: 0 };
const UNSWITCH: lu::Budgets = lu::Budgets { peel: 0, version: 0, unswitch: 50, rotate: 0, vector: 0 };
const ROTATE: lu::Budgets = lu::Budgets { peel: 0, version: 0, unswitch: 0, rotate: 8, vector: 0 };
const VECTOR: lu::Budgets = lu::Budgets { peel: 0, version: 0, unswitch: 0, rotate: 0, vector: 2 };

// `x` times 0 + 1 + ... + (`bound` - 1), by a loop counted from 0 by 1 while `i <u bound`, the bound the
// text's.
fn counted(bound: u32) String {
    return format(
        M"(lir ptr 8
sym @tri fn global
fn @tri
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 {}
  jmp b1(v1, v1)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v3
  br v6, b2, b3
b2:
  v7 = mul.i64 v4, v0
  v8 = add.i64 v5, v7
  v9 = add.i64 v4, v2
  jmp b1(v9, v8)
b3:
  ret v5
)",
        bound,
    );
}

// A loop whose trip count the constants fix peels that many times: no comparison is left, and the sum
// the exit block reads leaves through the landing block.
@test
fn a_counted_loop_peels_into_straight_code() {
    let src = counted(5);
    let (b, a) = optimized(src.as_str(), PEEL);
    let t = text_of(&a, "tri");
    assert(!t.contains("icmp"), t.as_str());
    let x: []u64 = [3];
    same_outcome(&b, &a, "tri", x, 30, false);
}

// Past the budget, or without one, the loop stays.
@test
fn a_loop_past_its_budget_stays() {
    let src = counted(1000);
    let (b, a) = optimized(src.as_str(), PEEL);
    assert(text_of(&a, "tri").contains("icmp"), "a thousand copies pass the budget");
    let x: []u64 = [2];
    same_outcome(&b, &a, "tri", x, 999000, false);
    let small = counted(5);
    let (b2, a2) = optimized(small.as_str(), NO_LOOPS);
    assert(text_of(&a2, "tri").contains("icmp"), "no budget, no peeling");
    same_outcome(&b2, &a2, "tri", x, 20, false);
}

// A loop with a check that panics leaves through two exits: the sum leaves into the one block that
// returns it; the checks of each copy keep their panics.
@test
fn a_loop_with_two_exits_peels() {
    let src = M"(lir ptr 8
sym @sum fn global
fn @sum
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 4
  jmp b1(v1, v1)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v3
  br v6, b2, b5
b2:
  v7 = icmp.ult v4, v0
  br v7, b3, b4
b3:
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v2
  jmp b1(v9, v8)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
)";
    let (b, a) = optimized(src, PEEL);
    let t = text_of(&a, "sum");
    assert(count(&t, "icmp.ult v") >= 1 && !t.contains("jmp b1("), t.as_str());
    let ok: []u64 = [10];
    same_outcome(&b, &a, "sum", ok, 6, false);
    let short: []u64 = [2];
    same_outcome(&b, &a, "sum", short, 0, true);
}

// `i <u len` checks on the counter of a loop that runs while `i <u n` hold wherever `n <=u len`: the
// loop gets a copy without them, which a test before it enters; with `n` past `len` the loop runs and
// panics as before.
@test
fn bounds_checks_version_the_loop() {
    let src = M"(lir ptr 8
sym @sum fn global
fn @sum
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v0
  br v6, b2, b5
b2:
  v7 = icmp.ult v4, v1
  br v7, b3, b4
b3:
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "sum");
    assert(t.contains("icmp.ule") && count(&t, "panic") == 1, t.as_str());
    let fits: []u64 = [5, 10];
    same_outcome(&b, &a, "sum", fits, 10, false);
    let exact: []u64 = [5, 5];
    same_outcome(&b, &a, "sum", exact, 10, false);
    let past: []u64 = [5, 3];
    same_outcome(&b, &a, "sum", past, 0, true);
}

// A signed loop test versions only from a start of at least 0 by steps of 1: from -1 its counter would
// pass `i <u len` as a huge value.
@test
fn a_signed_counter_from_below_zero_does_not_version() {
    let src = M"(lir ptr 8
sym @sum fn global
fn @sum
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 -1
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.slt v4, v0
  br v6, b2, b5
b2:
  v7 = icmp.ult v4, v1
  br v7, b3, b4
b3:
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
)";
    let (b, a) = optimized(src, VERSION);
    assert(!text_of(&a, "sum").contains("icmp.ule"), "no guard");
    let args: []u64 = [3, 10];
    same_outcome(&b, &a, "sum", args, 0, true);
}

// A branch on a value the loop does not change splits the loop in two, one per side, the test before
// them.
@test
fn an_invariant_branch_unswitches_the_loop() {
    let src = M"(lir ptr 8
sym @mix fn global
fn @mix
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v0
  br v6, b2, b6
b2:
  br v1, b3, b4
b3:
  v7 = add.i64 v5, v4
  jmp b5(v7)
b4:
  v8 = sub.i64 v5, v4
  jmp b5(v8)
b5(v9: i64):
  v10 = add.i64 v4, v3
  jmp b1(v10, v9)
b6:
  ret v5
)";
    let (b, a) = optimized(src, UNSWITCH);
    let t = text_of(&a, "mix");
    assert(count(&t, "br v1,") == 1 && t.contains("sub.i64") && t.contains("add.i64"), t.as_str());
    let plus: []u64 = [4, 1];
    same_outcome(&b, &a, "mix", plus, 6, false);
    let minus: []u64 = [4, 0];
    same_outcome(&b, &a, "mix", minus, 0xFFFFFFFFFFFFFFFA, false);
}

// A loop whose header tests before each iteration rotates: the test runs once before the loop and again
// at the end of each iteration, which branches back into the body; a value the header computes that the
// body reads enters the body from both tests. A header longer than the budget stays.
@test
fn a_loop_rotates_its_header_test_to_the_latch() {
    let src = M"(lir ptr 8
sym @sum fn global
sym @squares fn global
fn @sum
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.ult v3, v0
  br v5, b2, b3
b2:
  v6 = add.i64 v4, v3
  v7 = add.i64 v3, v2
  jmp b1(v7, v6)
b3:
  ret v4
fn @squares
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = mul.i64 v3, v3
  v6 = icmp.ult v3, v0
  br v6, b2, b3
b2:
  v7 = add.i64 v4, v5
  v8 = add.i64 v3, v2
  jmp b1(v8, v7)
b3:
  ret v4
)";
    let (b, a) = optimized(src, ROTATE);
    let t = text_of(&a, "sum");
    assert(count(&t, "icmp.ult") == 2 && !t.contains("jmp"), t.as_str());
    let none: []u64 = [0];
    same_outcome(&b, &a, "sum", none, 0, false);
    let four: []u64 = [4];
    same_outcome(&b, &a, "sum", four, 6, false);
    let q = text_of(&a, "squares");
    // The test before the loop folds its `0 * 0`; the body takes the square as a parameter.
    assert(count(&q, "icmp.ult") == 2 && count(&q, "mul.i64") == 1 && !q.contains("jmp"), q.as_str());
    same_outcome(&b, &a, "squares", four, 14, false);
    let (b2, a2) = optimized(src, lu::Budgets { peel: 0, version: 0, unswitch: 0, rotate: 1, vector: 0 });
    let q2 = text_of(&a2, "squares");
    assert(count(&q2, "icmp.ult") == 1 && q2.contains("jmp"), q2.as_str());
    same_outcome(&b2, &a2, "squares", four, 14, false);
}

// A counted loop over slices vectorizes: a sum (a reduction), and a map with a value from before the loop
// (a splat) that updates in place; the loop runs the iterations past the last whole group of vectors,
// and a guard keeps the vectors off a store range that overlaps a range the loop reads through another
// base. A float sum vectorizes only when reassociation is allowed; a loop that reads its counter as a
// value stays.
@test
fn a_counted_loop_over_slices_vectorizes() {
    let src = M"(lir ptr 8
sym @sum fn global noinline
sym @axpy fn global noinline
sym @fsum fn global noinline
sym @iota fn global noinline
sym @drive fn global
sym @drive2 fn global
fn @sum
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v4 * 8
  v8 = load.i64 v7 align 3
  v9 = add.i64 v5, v8
  v10 = add.i64 v4, v3
  jmp b1(v10, v9)
b3:
  ret v5
fn @axpy
  sig (i32, ptr, ptr, i64) -> void
b0(v0: i32, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v0, v9
  v11 = ptradd v2, v6 * 4
  v12 = load.i32 v11 align 2
  v13 = add.i32 v10, v12
  store v13, v11 align 2
  v14 = add.i64 v6, v5
  jmp b1(v14)
b3:
  ret
fn @fsum
  sig (ptr, i64) -> f64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = fconst.f64 0x0
  jmp b1(v2, v4)
b1(v5: i64, v6: f64):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 8
  v9 = load.f64 v8 align 3
  v10 = fadd.f64 v6, v9
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
fn @iota
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v1
  br v5, b2, b3
b2:
  v6 = ptradd v0, v4 * 8
  store v4, v6 align 3
  v7 = add.i64 v4, v3
  jmp b1(v7)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 64
  call @iota(v1, v2) : (ptr, i64) -> void
  v3 = call.i64 @sum(v1, v0) : (ptr, i64) -> i64
  ret v3
fn @drive2
  sig (i64, i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 64
  call @iota(v2, v3) : (ptr, i64) -> void
  v4 = iconst.i32 3
  v5 = ptradd v2, v1 * 4
  call @axpy(v4, v2, v5, v0) : (i32, ptr, ptr, i64) -> void
  v6 = call.i64 @sum(v2, v3) : (ptr, i64) -> i64
  ret v6
)";
    let (b, a) = optimized(src, VECTOR);
    let s = text_of(&a, "sum");
    assert(s.contains("load.v2i64") && s.contains("vop") && s.contains("add.v2i64"), s.as_str());
    let g = text_of(&a, "axpy");
    assert(g.contains("mul.v4i32") && g.contains("icmp.ule"), g.as_str());
    let f = text_of(&a, "fsum");
    assert(!f.contains("v2f64"), f.as_str());
    let t = text_of(&a, "iota");
    assert(!t.contains("v2i64"), t.as_str());
    // The sums of the first 0, 3, 4, 13 and 64 of 0, 1, 2, ...
    let lens: [u64; 5] = [0, 3, 4, 13, 64];
    for k in 0..5usize {
        let n = unsafe lens[k];
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, n * (n - (n != 0) as u64) / 2, false);
    }
    // `axpy` over the words as 128 i32 halves: apart (offset 64 halves), overlapping (offset 2), in
    // place (offset 0).
    let apart: []u64 = [40, 64];
    let r1 = run_value(&b, "drive2", apart);
    same_outcome(&b, &a, "drive2", apart, r1, false);
    let close: []u64 = [40, 2];
    let r2 = run_value(&b, "drive2", close);
    same_outcome(&b, &a, "drive2", close, r2, false);
    let same: []u64 = [37, 0];
    let r3 = run_value(&b, "drive2", same);
    same_outcome(&b, &a, "drive2", same, r3, false);
    let (b2, a2) = optimized(src, NO_LOOPS);
    let _ = b2;
    assert(!text_of(&a2, "sum").contains("v2i64"), "no vectors without the budget");
}

// The value function `name` of `p` returns on `args`.
fn run_value(p: &Package, name: str, args: []u64) u64 {
    let mut e = leval::Eval::new(p);
    let o = e.run(p.find_symbol(name), args);
    assert_eq(o.kind, leval::EV_OK);
    return o.value;
}
