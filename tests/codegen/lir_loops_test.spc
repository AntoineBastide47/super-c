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
    return (before, after);
}

// The text of function `name` of `p`.
fn text_of(p: &Package, name: str) String {
    let mut all = String::new();
    lprint::print_package(p, &mut all);
    let head = format("fn @{}\n", name);
    let at = all.as_str().find(&head);
    assert(at >= 0, head.as_str());
    let rest = all.as_str().slice(at as usize + head.len(), all.len());
    let f = rest.find("\nfn @");
    return String::from_str(
        rest.slice(
            0,
            if f >= 0 {
                f as usize + 1
            } else {
                rest.len()
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

const NO_LOOPS: lu::Budgets = lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 };
const PEEL: lu::Budgets = lu::Budgets { peel: 200, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 };
const VERSION: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 200,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    fin: 0,
};
const UNSWITCH: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    unswitch: 50,
    rotate: 0,
    vector: 0,
    fin: 0,
};
const ROTATE: lu::Budgets = lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 8, vector: 0, fin: 0 };
const VECTOR: lu::Budgets = lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 2, fin: 0 };
const PARTIAL: lu::Budgets = lu::Budgets { peel: 0, partial: 32, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 };

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
    let (b, a) = optimized(&src, PEEL);
    let t = text_of(&a, "tri");
    assert(!t.contains("icmp"), t.as_str());
    let x: []u64 = [3];
    same_outcome(&b, &a, "tri", x, 30, false);
}

// The budget counts what a copy keeps once its counter is a constant: a loop over the 8 bytes of a word
// whose shift amounts and their checks the counter alone decides peels within 40 instructions, though its
// 9 copies of 10 instructions pass them.
@test
fn a_counted_loop_peels_by_what_its_copies_keep() {
    let src = M"(lir ptr 8
sym @bytes fn global
fn @bytes
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 8
  v4 = iconst.i64 3
  v5 = iconst.i64 255
  v6 = iconst.i64 64
  jmp b1(v1, v1)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v3
  br v9, b2, b5
b2:
  v10 = shl.i64 v7, v4
  v11 = icmp.uge v10, v6
  br v11, b3, b4
b3: cold
  panic "attempt to shift right with overflow"
b4:
  v12 = lshr.i64 v0, v10
  v13 = and.i64 v12, v5
  v14 = add.i64 v8, v13
  v15 = add.i64 v7, v2
  jmp b1(v15, v14)
b5:
  ret v8
)";
    let (b, a) = optimized(
        src,
        lu::Budgets { peel: 40, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 },
    );
    let t = text_of(&a, "bytes");
    assert(!t.contains("icmp") && !t.contains("panic"), t.as_str());
    let x: []u64 = [0x0102030405060708];
    same_outcome(&b, &a, "bytes", x, 36, false);
}

// Past the budget, or without one, the loop stays.
@test
fn a_loop_past_its_budget_stays() {
    let src = counted(1000);
    let (b, a) = optimized(&src, PEEL);
    assert(text_of(&a, "tri").contains("icmp"), "a thousand copies pass the budget");
    let x: []u64 = [2];
    same_outcome(&b, &a, "tri", x, 999000, false);
    let small = counted(5);
    let (b2, a2) = optimized(&small, NO_LOOPS);
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
    assert(count(&t, "icmp.ugt v0") >= 1 && !t.contains("jmp b1("), t.as_str());
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
  v9 = udiv.i64 v8, v0
  jmp b5(v9)
b5(v10: i64):
  v11 = add.i64 v4, v3
  jmp b1(v11, v10)
b6:
  ret v5
)";
    let (b, a) = optimized(src, UNSWITCH);
    let t = text_of(&a, "mix");
    assert(count(&t, "br v1,") == 1 && t.contains("udiv.i64") && t.contains("add.i64"), t.as_str());
    let plus: []u64 = [4, 1];
    same_outcome(&b, &a, "mix", plus, 6, false);
    let minus: []u64 = [4, 0];
    same_outcome(&b, &a, "mix", minus, 0x3FFFFFFFFFFFFFF, false);
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
    // The latch branches back; the exit that passes the sum has a block of its own (`split_exits`).
    assert(count(&t, "icmp.ne v0") == 1 && count(&t, "icmp.ult") == 1 && count(&t, "jmp") == 1, t.as_str());
    let none: []u64 = [0];
    same_outcome(&b, &a, "sum", none, 0, false);
    let four: []u64 = [4];
    same_outcome(&b, &a, "sum", four, 6, false);
    let q = text_of(&a, "squares");
    // The test before the loop folds its `0 * 0`; the body takes the square as a parameter.
    assert(
        count(&q, "icmp.ne v0") == 1 && count(&q, "icmp.ult") == 1 && count(&q, "mul.i64") == 1 && count(&q, "jmp") == 1,
        q.as_str(),
    );
    same_outcome(&b, &a, "squares", four, 14, false);
    let (b2, a2) = optimized(
        src,
        lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 1, vector: 0, fin: 0 },
    );
    let q2 = text_of(&a2, "squares");
    assert(count(&q2, "icmp.ult") == 1 && q2.contains("jmp"), q2.as_str());
    same_outcome(&b2, &a2, "squares", four, 14, false);
}

// A counted loop of unknown trip count unrolls partially: a loop of 4 copies of its body runs while 4
// iterations are left, a signed counter from below zero too, then the loop runs the rest. A body that
// calls, or one past the budget at 2 copies, stays.
@test
fn a_counted_loop_unrolls_partially() {
    let text = M"(lir ptr 8
sym @g fn global noinline
sym @mix fn global
sym @calls fn global
fn @g
  sig (i32) -> i32
b0(v0: i32):
  ret v0
fn @mix
  sig (i32, i32) -> i32
b0(v0: i32, v1: i32):
  jmp b1(v0, v0)
b1(v2: i32, v3: i32):
  v4 = icmp.slt v2, v1
  br v4, b2, b3
b2:
  v5 = mul.i32 v3, v3
  v6 = xor.i32 v5, v2
  v7 = iconst.i32 1
  v8 = add.i32 v2, v7
  jmp b1(v8, v6)
b3:
  ret v3
fn @calls
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  jmp b1(v1, v1)
b1(v2: i32, v3: i32):
  v4 = icmp.ult v2, v0
  br v4, b2, b3
b2:
  v5 = call.i32 @g(v3) : (i32) -> i32
  v6 = add.i32 v5, v2
  v7 = iconst.i32 1
  v8 = add.i32 v2, v7
  jmp b1(v8, v6)
b3:
  ret v3
)";
    let (before, after) = optimized(text, PARTIAL);
    let m = text_of(&after, "mix");
    assert_eq(count(&m, "mul.i32"), 5);
    assert_eq(count(&m, "and.i32"), 1);
    let c = text_of(&after, "calls");
    assert_eq(count(&c, "call.i32"), 1);
    let neg: u64 = 0xFFFFFFFD;
    let starts: [u64; 3] = [0, 2, neg];
    let ends: [u64; 6] = [0, 1, 3, 4, 9, 13];
    for s in starts {
        for n in ends {
            let args: [u64; 2] = [s, n];
            let mut e = leval::Eval::new(&before);
            let want = e.run(before.find_symbol("mix"), args).value;
            same_outcome(&before, &after, "mix", args, want, false);
        }
    }
    let (_, small) = optimized(
        text,
        lu::Budgets { peel: 0, partial: 5, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 },
    );
    let s = text_of(&small, "mix");
    assert_eq(count(&s, "mul.i32"), 1);
}

// A loop whose lanes pick by a comparison vectorizes: a float `max(x, 0)` map (`vcmp` of floats, `vsel`),
// and an integer sum of the values inside a range else the bound (two masks `and`ed, a select into a
// reduction).
@test
fn a_loop_of_selects_vectorizes() {
    let src = M"(lir ptr 8
sym @relu fn global noinline
sym @clamp fn global noinline
sym @fill fn global noinline
sym @drive fn global
sym @drive2 fn global
fn @relu
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = fconst.f32 0x0
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.f32 v8 align 2
  v10 = fcmp.ogt v9, v5
  v11 = select.f32 v10, v9, v5
  v12 = ptradd v0, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @clamp
  sig (ptr, i64, i32) -> i32
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.slt v10, v2
  v12 = icmp.sgt v10, v5
  v13 = and.i8 v11, v12
  v14 = select.i32 v13, v10, v2
  v15 = add.i32 v7, v14
  v16 = add.i64 v6, v4
  jmp b1(v16, v15)
b3:
  ret v7
fn @fill
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 5
  v6 = iconst.i32 100
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v2
  br v8, b2, b3
b2:
  v9 = trunc.i32 v7
  v10 = mul.i32 v9, v5
  v11 = sub.i32 v10, v6
  v12 = ptradd v0, v7 * 4
  store v11, v12 align 2
  v13 = sitofp.f32 v11
  v14 = ptradd v1, v7 * 4
  store v13, v14 align 2
  v15 = add.i64 v7, v4
  jmp b1(v15)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 64
  call @fill(v1, v2, v4) : (ptr, ptr, i64) -> void
  call @relu(v3, v2, v0) : (ptr, ptr, i64) -> void
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  jmp b1(v5, v5)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v0
  br v9, b2, b3
b2:
  v10 = ptradd v3, v7 * 4
  v11 = load.i32 v10 align 2
  v12 = sext.i64 v11
  v13 = mul.i64 v12, v7
  v14 = add.i64 v8, v13
  v15 = add.i64 v7, v6
  jmp b1(v15, v14)
b3:
  ret v8
fn @drive2
  sig (i64, i32) -> i32
  slot s0 size 256 align 3
  slot s1 size 256 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 64
  call @fill(v2, v3, v4) : (ptr, ptr, i64) -> void
  v5 = call.i32 @clamp(v2, v0, v1) : (ptr, i64, i32) -> i32
  ret v5
)";
    let (b, a) = optimized(src, VECTOR);
    let r = text_of(&a, "relu");
    assert(r.contains("vcmp.ogt.v4i32") && r.contains("vsel.v4f32"), r.as_str());
    let c = text_of(&a, "clamp");
    assert(c.contains("and.v4i32") && c.contains("vsel.v4i32"), c.as_str());
    // `drive` sums the bits of the first `n` results, each times its index.
    let lens: [u64; 5] = [0, 3, 8, 13, 64];
    for k in 0..5usize {
        let n = unsafe lens[k];
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        let bounds: [u64; 3] = [50, 0, 0xFFFFFF9C];
        for q in 0..3usize {
            let args2: []u64 = [n, unsafe bounds[q]];
            same_outcome(&b, &a, "drive2", args2, run_value(&b, "drive2", args2), false);
        }
    }
}

// A loop whose body branches vectorizes as one block of selects: each side's float arithmetic runs for
// every lane, the side's value picked by the condition's mask. A side that loads an element no iteration
// reads otherwise keeps the branch, and the loop stays scalar.
@test
fn a_loop_with_a_branch_vectorizes_as_selects() {
    let src = M"(lir ptr 8
sym @f fn global noinline
sym @g fn global noinline
sym @fill fn global noinline
sym @drive fn global
sym @drive2 fn global
fn @f
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = fconst.f32 0x0
  v6 = fconst.f32 0x40000000
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v2
  br v8, b2, b6
b2:
  v9 = ptradd v1, v7 * 4
  v10 = load.f32 v9 align 2
  v11 = fcmp.ogt v10, v5
  br v11, b3, b4
b3:
  v12 = fmul.f32 v10, v6
  jmp b5(v12)
b4:
  v13 = fsub.f32 v5, v10
  jmp b5(v13)
b5(v14: f32):
  v15 = ptradd v0, v7 * 4
  store v14, v15 align 2
  v16 = add.i64 v7, v4
  jmp b1(v16)
b6:
  ret
fn @g
  sig (ptr, ptr, i64) -> i32
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v2
  br v8, b2, b5
b2:
  v9 = ptradd v1, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.ne v10, v5
  br v11, b3, b4(v7)
b3:
  v12 = ptradd v0, v6 * 4
  v13 = load.i32 v12 align 2
  v14 = add.i32 v7, v13
  jmp b4(v14)
b4(v15: i32):
  v16 = add.i64 v6, v4
  jmp b1(v16, v15)
b5:
  ret v7
fn @fill
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 7
  v5 = iconst.i32 30
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v4
  v10 = sub.i32 v9, v5
  v11 = sitofp.f32 v10
  v12 = ptradd v0, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v3
  jmp b1(v13)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 64
  call @fill(v1, v3) : (ptr, i64) -> void
  call @f(v2, v1, v0) : (ptr, ptr, i64) -> void
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4, v4)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v2, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = sext.i64 v10
  v12 = mul.i64 v11, v6
  v13 = add.i64 v7, v12
  v14 = add.i64 v6, v5
  jmp b1(v14, v13)
b3:
  ret v7
fn @drive2
  sig (i64) -> i32
  slot s0 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 64
  call @fill(v1, v2) : (ptr, i64) -> void
  v3 = call.i32 @g(v1, v1, v0) : (ptr, ptr, i64) -> i32
  ret v3
)";
    let (b, a) = optimized(src, VECTOR);
    let f = text_of(&a, "f");
    assert(f.contains("vsel.v4f32") && f.contains("fmul.v4f32") && f.contains("fsub.v4f32"), f.as_str());
    let g = text_of(&a, "g");
    assert(!g.contains("v4i32"), g.as_str());
    let lens: [u64; 5] = [0, 3, 8, 13, 64];
    for k in 0..5usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        same_outcome(&b, &a, "drive2", args, run_value(&b, "drive2", args), false);
    }
}

// Loads of every 2nd element vectorize: the vectors from each field on, their even lanes (`vunzip`), and
// the loop runs the last iteration, so no vector reads past the element it reads. A sum through indices
// a load gives (a gather) interleaves scalar copies.
@test
fn strided_and_gathered_loads_vectorize() {
    let src = M"(lir ptr 8
sym @mag fn global noinline
sym @gsum fn global noinline
sym @fill fn global noinline
sym @drive fn global
sym @drive2 fn global
fn @mag
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 8
  v8 = load.i32 v7 align 2
  v9 = load.i32 v7+4 align 2
  v10 = mul.i32 v8, v8
  v11 = mul.i32 v9, v9
  v12 = add.i32 v10, v11
  v13 = ptradd v0, v5 * 4
  store v12, v13 align 2
  v14 = add.i64 v5, v4
  jmp b1(v14)
b3:
  ret
fn @gsum
  sig (ptr, ptr, i64) -> i64
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = sext.i64 v9
  v11 = ptradd v0, v10 * 8
  v12 = load.i64 v11 align 3
  v13 = add.i64 v6, v12
  v14 = add.i64 v5, v4
  jmp b1(v14, v13)
b3:
  ret v6
fn @fill
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 63
  v6 = iconst.i32 3
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v2
  br v8, b2, b3
b2:
  v9 = mul.i64 v7, v7
  v10 = ptradd v0, v7 * 8
  store v9, v10 align 3
  v11 = sub.i64 v5, v7
  v12 = trunc.i32 v11
  v13 = ptradd v1, v7 * 4
  store v12, v13 align 2
  v14 = add.i64 v7, v4
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 64
  call @fill(v1, v2, v3) : (ptr, ptr, i64) -> void
  call @mag(v2, v1, v0) : (ptr, ptr, i64) -> void
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4, v4)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v2, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = sext.i64 v10
  v12 = mul.i64 v11, v6
  v13 = add.i64 v7, v12
  v14 = add.i64 v6, v5
  jmp b1(v14, v13)
b3:
  ret v7
fn @drive2
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 64
  call @fill(v1, v2, v3) : (ptr, ptr, i64) -> void
  v4 = call.i64 @gsum(v1, v2, v0) : (ptr, ptr, i64) -> i64
  ret v4
)";
    let (b, a) = optimized(src, VECTOR);
    let m = text_of(&a, "mag");
    assert(count(&m, "vunzip.v4i32") == 4 && m.contains("mul.v4i32"), m.as_str());
    let g = text_of(&a, "gsum");
    assert_eq(count(&g, "load.i64"), 3);
    // `mag` reads 64 words as 32 pairs.
    let lens: [u64; 6] = [0, 1, 3, 8, 9, 32];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        same_outcome(&b, &a, "drive2", args, run_value(&b, "drive2", args), false);
    }
    let all: []u64 = [64];
    same_outcome(&b, &a, "drive2", all, run_value(&b, "drive2", all), false);
}

// A loop around an inner loop that does not vectorize (it reads a column: a stride the call gives) unrolls
// and jams: 4 iterations of the outer loop run their inner loops as one, and the 4 sums and their
// stores pack into vectors. The output (`noalias`) is apart from what the loops read; without that the
// loops stay as they are. Each count runs as before (0, fewer than 4, not a multiple of 4).
@test
fn an_outer_loop_unrolls_and_jams_into_vectors() {
    let body = M"(  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i32 0
  jmp b1(v5)
b1(v8: i64):
  v9 = icmp.ult v8, v3
  br v9, b2, b6
b2:
  v10 = ptradd v0, v8 * 4
  jmp b3(v5, v7)
b3(v11: i64, v12: i32):
  v13 = icmp.ult v11, v4
  br v13, b4, b5
b4:
  v14 = mul.i64 v11, v3
  v15 = ptradd v10, v14 * 4
  v16 = load.i32 v15 align 2
  v17 = ptradd v1, v11 * 4
  v18 = load.i32 v17 align 2
  v19 = mul.i32 v16, v18
  v20 = add.i32 v12, v19
  v21 = add.i64 v11, v6
  jmp b3(v21, v20)
b5:
  v22 = ptradd v2, v8 * 4
  store v12, v22 align 2
  v23 = add.i64 v8, v6
  jmp b1(v23)
b6:
  ret
)";
    let drive = M"(fn @drive
  sig (i64, i64) -> i64
  slot s0 size 4096 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 1024
  v8 = iconst.i32 7
  v9 = iconst.i32 300
  v10 = iconst.i64 63
  jmp b1(v5)
b1(v11: i64):
  v12 = icmp.ult v11, v7
  br v12, b2, b3
b2:
  v13 = trunc.i32 v11
  v14 = mul.i32 v13, v8
  v15 = sub.i32 v14, v9
  v16 = ptradd v2, v11 * 4
  store v15, v16 align 2
  v17 = and.i64 v11, v10
  v18 = ptradd v3, v17 * 4
  store v13, v18 align 2
  v19 = add.i64 v11, v6
  jmp b1(v19)
b3:
  call @mv(v2, v3, v4, v0, v1) : (ptr, ptr, ptr, i64, i64) -> void
  jmp b4(v5, v5)
b4(v20: i64, v21: i64):
  v22 = icmp.ult v20, v0
  br v22, b5, b6
b5:
  v23 = ptradd v4, v20 * 4
  v24 = load.i32 v23 align 2
  v25 = sext.i64 v24
  v26 = add.i64 v20, v6
  v27 = mul.i64 v25, v26
  v28 = add.i64 v21, v27
  jmp b4(v26, v28)
b6:
  ret v21
)";
    let jam = lu::Budgets { peel: 0, partial: 32, version: 0, unswitch: 0, rotate: 0, vector: 2, fin: 0 };
    for excl in 0..2usize {
        let src = format(
            "lir ptr 8\nsym @mv fn global noinline\nsym @drive fn global\nfn @mv\n  sig (ptr, ptr, ptr, i64, i64) -> void\n{}b0(v0: ptr, v1: ptr, v2: ptr, v3: i64, v4: i64):\n{}{}",
            if excl == 1 {
                "  ref p2 256 noalias\n"
            } else {
                ""
            },
            body,
            drive,
        );
        let mut err = String::new();
        let q = lparse::parse(&src, &mut err);
        assert(q.is_some(), err.as_str());
        let b = q.unwrap();
        let mut a = lparse::parse(&src, &mut err).unwrap();
        let none = Vector::<bool>::new();
        lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: jam });
        let mut v = verify::Verifier::new();
        for i in 0..a.syms.len() {
            let s = a.syms[i];
            if s.def != NONE && s.kind == SK_FUNC {
                assert(v.check(&a, a.spell(s.name), &a.bodies[s.def as usize]), v.err.as_str());
            }
        }
        let m = text_of(&a, "mv");
        assert(excl == 1 == (m.contains("mul.v4i32") && m.contains("add.v4i32") && m.contains("store v")), m.as_str());
        let ns: [u64; 5] = [0, 3, 4, 13, 64];
        let ms: [u64; 3] = [0, 1, 9];
        for x in 0..5usize {
            for y in 0..3usize {
                let args: []u64 = [unsafe ns[x], unsafe ms[y]];
                same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
            }
        }
    }
}

// A target with 32-byte vectors (`Package.vector`, AVX2) takes 8 lanes of 4 bytes: the sum of selected
// values and the strided map vectorize as with 16 bytes, the strided loads 32 bytes apart.
@test
fn a_target_with_32_byte_vectors_takes_them() {
    let src = M"(lir ptr 8
sym @clamp fn global noinline
sym @mag fn global noinline
sym @fill fn global noinline
sym @drive fn global
fn @clamp
  sig (ptr, i64, i32) -> i32
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.slt v10, v2
  v12 = select.i32 v11, v10, v2
  v13 = add.i32 v7, v12
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
b3:
  ret v7
fn @mag
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 8
  v8 = load.i32 v7 align 2
  v9 = load.i32 v7+4 align 2
  v10 = mul.i32 v8, v9
  v11 = ptradd v0, v5 * 4
  store v10, v11 align 2
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @fill
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 7
  v5 = iconst.i32 300
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v4
  v10 = sub.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v3
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64, i32) -> i64
  slot s0 size 1024 align 3
  slot s1 size 512 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 256
  call @fill(v2, v4) : (ptr, i64) -> void
  v5 = call.i32 @clamp(v2, v0, v1) : (ptr, i64, i32) -> i32
  call @mag(v3, v2, v0) : (ptr, ptr, i64) -> void
  v6 = sext.i64 v5
  v7 = iconst.i64 0
  v8 = iconst.i64 1
  jmp b1(v7, v6)
b1(v9: i64, v10: i64):
  v11 = icmp.ult v9, v0
  br v11, b2, b3
b2:
  v12 = ptradd v3, v9 * 4
  v13 = load.i32 v12 align 2
  v14 = sext.i64 v13
  v15 = mul.i64 v14, v9
  v16 = add.i64 v10, v15
  v17 = add.i64 v9, v8
  jmp b1(v17, v16)
b3:
  ret v10
)";
    let mut err = String::new();
    let b = lparse::parse(src, &mut err).unwrap();
    let mut a = lparse::parse(src, &mut err).unwrap();
    a.vector = 32;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: VECTOR });
    let mut v = verify::Verifier::new();
    for i in 0..a.syms.len() {
        let s = a.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&a, a.spell(s.name), &a.bodies[s.def as usize]), v.err.as_str());
        }
    }
    let c = text_of(&a, "clamp");
    assert(c.contains("vcmp.slt.v8i32") && c.contains("add.v8i32"), c.as_str());
    let m = text_of(&a, "mag");
    assert(m.contains("vunzip.v8i32") && m.contains("+32 align"), m.as_str());
    let lens: [u64; 5] = [0, 7, 16, 33, 128];
    for k in 0..5usize {
        let args: []u64 = [unsafe lens[k], 100];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
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

// A by-value `[]mut T` parameter (`ref inner noalias`) is the only path to its elements: a loop that
// stores through it and loads through another view vectorizes without a guard on the two ranges. When
// the element pointer escapes (stored to memory another pointer reaches), the guard stays.
@test
fn an_exclusive_view_needs_no_overlap_guard() {
    let src = M"(lir ptr 8
sym @axv fn global noinline
sym @leak fn global noinline
sym @drive fn global
fn @axv
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i32, l0, l0, i64) -> void
  ref p1 0 inner noalias
b0(v0: i32, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = load.ptr v1 align 3
  v7 = load.ptr v2 align 3
  jmp b1(v4)
b1(v8: i64):
  v9 = icmp.ult v8, v3
  br v9, b2, b3
b2:
  v10 = ptradd v7, v8 * 4
  v11 = load.i32 v10 align 2
  v12 = mul.i32 v0, v11
  v13 = ptradd v6, v8 * 4
  v14 = load.i32 v13 align 2
  v15 = add.i32 v12, v14
  store v15, v13 align 2
  v16 = add.i64 v8, v5
  jmp b1(v16)
b3:
  ret
fn @leak
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i32, l0, l0, i64, ptr) -> void
  ref p1 0 inner noalias
b0(v0: i32, v1: ptr, v2: ptr, v3: i64, v4: ptr):
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = load.ptr v1 align 3
  v8 = load.ptr v2 align 3
  store v7, v4 align 3
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v3
  br v10, b2, b3
b2:
  v11 = ptradd v8, v9 * 4
  v12 = load.i32 v11 align 2
  v13 = mul.i32 v0, v12
  v14 = ptradd v7, v9 * 4
  v15 = load.i32 v14 align 2
  v16 = add.i32 v13, v15
  store v16, v14 align 2
  v17 = add.i64 v9, v6
  jmp b1(v17)
b3:
  ret
fn @drive
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 16 align 3
  slot s2 size 16 align 3
  slot s3 size 8 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 32
  v8 = iconst.i32 3
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = ptradd v1, v9 * 8
  store v9, v11 align 3
  v12 = add.i64 v9, v6
  jmp b1(v12)
b3:
  v13 = ptradd v1+128
  store v1, v2 align 3
  store v0, v2+8 align 3
  store v13, v3 align 3
  store v0, v3+8 align 3
  call @axv(v8, v2, v3, v0) : (i32, l0, l0, i64) -> void
  call @leak(v8, v2, v3, v0, v4) : (i32, l0, l0, i64, ptr) -> void
  v14 = load.i64 v1 align 3
  v15 = load.i64 v1+40 align 3
  v16 = add.i64 v14, v15
  ret v16
)";
    let (b, a) = optimized(src, VECTOR);
    let g = text_of(&a, "axv");
    assert(g.contains("mul.v4i32") && !g.contains("icmp.ule"), g.as_str());
    let l = text_of(&a, "leak");
    assert(l.contains("mul.v4i32") && l.contains("icmp.ule"), l.as_str());
    let args: []u64 = [20];
    let r = run_value(&b, "drive", args);
    same_outcome(&b, &a, "drive", args, r, false);
}

// A loop that its outer loop's branch enters gets a preheader (LLVM's LoopSimplify), so a nest of
// counted loops peels from the inside out: the 4 x 4 sum over a matrix leaves no comparison.
@test
fn a_counted_nest_peels_through_its_preheaders() {
    let src = M"(lir ptr 8
sym @grid fn global noinline
sym @top fn global
fn @grid
  sig (ptr) -> i64
  ref p0 128
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 4
  v4 = iconst.i64 2
  jmp b1(v1, v1)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v3
  br v7, b2(v1, v6), b4
b2(v8: i64, v9: i64):
  v10 = icmp.ult v8, v3
  br v10, b3, b5
b3:
  v11 = shl.i64 v5, v4
  v12 = add.i64 v11, v8
  v13 = ptradd v0, v12 * 8
  v14 = load.i64 v13 align 3
  v15 = add.i64 v9, v14
  v16 = add.i64 v8, v2
  jmp b2(v16, v15)
b4:
  ret v6
b5:
  v17 = add.i64 v5, v2
  jmp b1(v17, v9)
fn @top
  sig (i64) -> i64
  slot s0 size 128 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 16
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v4
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 8
  v8 = mul.i64 v5, v0
  store v8, v7 align 3
  v9 = add.i64 v5, v3
  jmp b1(v9)
b3:
  v10 = call.i64 @grid(v1) : (ptr) -> i64
  ret v10
)";
    let (b, a) = optimized(src, PEEL);
    let t = text_of(&a, "grid");
    assert(!t.contains("icmp"), t.as_str());
    let x: []u64 = [3];
    same_outcome(&b, &a, "top", x, 360, false);
}

const FIN: lu::Budgets = lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 512 };

// A loop whose final values are polynomials of the iteration goes: its body copied for iterations 0 to
// the degree, the copies' differences times the binomials of the trip count.
fn closed(text: str, name: str) (Package, Package) {
    let (b, a) = optimized(text, FIN);
    let t = text_of(&a, name);
    assert(!t.contains("br ") && !t.contains("jmp "), t.as_str());
    return (b, a);
}

// Sums of the counter, of its square through a second accumulator, of a nested loop's sums: each
// accumulator steps by itself plus what does not read it, so their degrees resolve in turn. The nested
// loop's closed form reads the outer counter as a polynomial (a start past the bound never happens: the
// counter's interval decides it), so the outer loop goes too: the sum of the triangle numbers below `n`.
@test
fn nested_and_chained_sums_take_their_closed_forms() {
    let src = M"(lir ptr 8
sym @tri fn global
sym @chain fn global
fn @tri
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.slt v3, v0
  br v5, b3(v1, v4), b2
b2:
  ret v4
b3(v6: i64, v7: i64):
  v8 = icmp.slt v6, v3
  br v8, b4, b5
b4:
  v9 = add.i64 v7, v6
  v10 = add.i64 v6, v2
  jmp b3(v10, v9)
b5:
  v11 = add.i64 v3, v2
  jmp b1(v11, v7)
fn @chain
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = iconst.i32 7
  jmp b1(v1, v3, v2)
b1(v4: i32, v5: i32, v6: i32):
  v7 = icmp.slt v4, v0
  br v7, b2, b3
b2:
  v8 = mul.i32 v4, v4
  v9 = add.i32 v5, v8
  v10 = sub.i32 v6, v9
  v11 = add.i32 v4, v2
  jmp b1(v11, v9, v10)
b3:
  v12 = mul.i32 v6, v3
  v13 = add.i32 v12, v5
  ret v13
)";
    let (b, a) = closed(src, "tri");
    let (cb, ca) = closed(src, "chain");
    let xs: []u64 = [0, 1, 2, 3, 10, 1000, 0xFFFFFFFFFFFFFFFB];
    let tri: []u64 = [0, 0, 0, 1, 120, 166167000, 0];
    for k in 0..xs.len() {
        let x: []u64 = [xs[k]];
        same_outcome(&b, &a, "tri", x, tri[k], false);
    }
    // The chain's values wrap in 32 bits; the evaluator of the loop is the reference.
    let ns: []u64 = [0, 1, 5, 100, 70000, 0xFFFFFFFB];
    for k in 0..ns.len() {
        let x: []u64 = [ns[k]];
        let mut e = leval::Eval::new(&cb);
        let want = e.run(cb.find_symbol("chain"), x).value;
        same_outcome(&cb, &ca, "chain", x, want, false);
    }
}

// Counters that step down by 2 (behind a guard that the bound leaves room for the last step), test
// inequality, or test in the latch, accumulators that wrap through wider arithmetic (`zext`, `trunc`) or
// pick a side on a flag the loop does not change: all go.
@test
fn counters_and_accumulators_of_every_shape_take_their_closed_forms() {
    let src = M"(lir ptr 8
sym @down fn global
sym @ne fn global
sym @latch fn global
sym @wrap fn global
sym @pick fn global
fn @down
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 2
  jmp b1(v0, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.sgt v4, v1
  br v6, b2, b3
b2:
  v7 = sub.i64 v4, v3
  v8 = mul.i64 v7, v7
  v9 = add.i64 v5, v8
  jmp b1(v7, v9)
b3:
  v10 = add.i64 v5, v4
  ret v10
fn @ne
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v0, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ne v4, v1
  br v6, b2, b3
b2:
  v7 = add.i64 v4, v3
  v8 = add.i64 v5, v7
  jmp b1(v7, v8)
b3:
  ret v5
fn @latch
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 5
  jmp b1(v1, v1)
b1(v4: i64, v5: i64):
  v6 = mul.i64 v4, v3
  v7 = add.i64 v5, v6
  v8 = add.i64 v4, v2
  v9 = icmp.slt v8, v0
  br v9, b1(v8, v7), b2
b2:
  v10 = mul.i64 v7, v3
  v11 = add.i64 v10, v8
  ret v11
fn @wrap
  sig (i32) -> i8
b0(v0: i32):
  v1 = iconst.i8 0
  v2 = iconst.i32 0
  v3 = iconst.i64 3
  v4 = iconst.i32 1
  jmp b1(v2, v1)
b1(v5: i32, v6: i8):
  v7 = icmp.slt v5, v0
  br v7, b2, b3
b2:
  v8 = trunc.i8 v5
  v9 = zext.i64 v8
  v10 = mul.i64 v9, v3
  v11 = zext.i64 v6
  v12 = add.i64 v11, v10
  v13 = trunc.i8 v12
  v14 = add.i32 v5, v4
  jmp b1(v14, v13)
b3:
  ret v6
fn @pick
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.slt v4, v0
  br v6, b2, b3
b2:
  v7 = shl.i64 v4, v3
  v8 = select.i64 v1, v4, v7
  v9 = add.i64 v5, v8
  v10 = add.i64 v4, v3
  jmp b1(v10, v9)
b3:
  ret v5
)";
    let names: []str = ["down", "ne", "latch", "wrap", "pick"];
    let (b, a) = optimized(src, FIN);
    for f in 1..names.len() {
        let t = text_of(&a, names[f]);
        assert(!t.contains("br ") && !t.contains("jmp "), t.as_str());
    }
    let d = text_of(&a, "down");
    assert(d.contains("icmp.sge v1, v") && d.contains("iconst.i64 -9223372036854775807"), d.as_str());
    // Argument pairs; the one-argument functions take the first.
    let args: []u64 = [20, 0, 7, 0xFFFFFFFFFFFFFFF7, 3, 3, 0xFFFFFFFFFFFFFFFE, 9, 0xFFFFFFFFFFFFFFFB, 4, 1000, 1, 0, 1];
    for f in 0..names.len() {
        for k in 0..args.len() / 2 {
            let x: []u64 = [args[2 * k], args[2 * k + 1]];
            let one: []u64 = [x[0]];
            let use_one = names[f] == "latch" || names[f] == "wrap";
            if use_one && x[0] > 100000 && x[0] < 0x8000000000000000 {
                continue;
            }
            let mut e = leval::Eval::new(&b);
            let o = if use_one {
                e.run(b.find_symbol(names[f]), one)
            } else {
                e.run(b.find_symbol(names[f]), x)
            };
            if o.kind != leval::EV_OK {
                continue;
            }
            same_outcome(
                &b,
                &a,
                names[f],
                if use_one {
                    one
                } else {
                    x
                },
                o.value,
                false,
            );
        }
    }
}

// A counter stepping by 4 to a bound whose bits keep it 4 below the type's top (`n & -4`, `n >> 2`, `n &
// 1023`): no guard, the closed form alone, unsigned and signed.
@test
fn a_bound_its_bits_keep_off_the_top_takes_no_guard() {
    let src = M"(lir ptr 8
sym @mask fn global
sym @shr fn global
sym @low fn global
fn @mask
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 4
  v3 = iconst.i64 -4
  v4 = and.i64 v0, v3
  jmp b1(v1, v1)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v4
  br v7, b2, b3
b2:
  v8 = add.i64 v6, v5
  v9 = add.i64 v5, v2
  jmp b1(v9, v8)
b3:
  ret v6
fn @shr
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 4
  v3 = iconst.i64 2
  v4 = lshr.i64 v0, v3
  jmp b1(v1, v1)
b1(v5: i64, v6: i64):
  v7 = icmp.slt v5, v4
  br v7, b2, b3
b2:
  v8 = add.i64 v6, v5
  v9 = add.i64 v5, v2
  jmp b1(v9, v8)
b3:
  ret v6
fn @low
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 4
  v3 = iconst.i32 1023
  v4 = and.i32 v0, v3
  jmp b1(v1, v1)
b1(v5: i32, v6: i32):
  v7 = icmp.sle v5, v4
  br v7, b2, b3
b2:
  v8 = add.i32 v6, v5
  v9 = add.i32 v5, v2
  jmp b1(v9, v8)
b3:
  ret v6
)";
    let (b, a) = optimized(src, FIN);
    let names: []str = ["mask", "shr", "low"];
    for n in 0..names.len() {
        let t = text_of(&a, names[n]);
        assert(!t.contains("br ") && !t.contains("jmp "), t.as_str());
    }
    // Bounds the evaluator runs the loops to; `low`'s mask keeps all ones small.
    let ns: []u64 = [0, 1, 3, 4, 5, 100, 1001, 4099, 0xFFFFFFFF];
    for n in 0..names.len() {
        for k in 0..ns.len() - (n != 2) as usize {
            let x: []u64 = [ns[k]];
            let mut e = leval::Eval::new(&b);
            let want = e.run(b.find_symbol(names[n]), x).value;
            same_outcome(&b, &a, names[n], x, want, false);
        }
    }
}

// A counter stepping by 3 to a bound the loop does not know could wrap past it: a guard runs the closed
// form when the bound leaves room for one more step, the loop otherwise. A constant bound decides it.
@test
fn a_stepped_counter_takes_a_guard_on_its_bound() {
    let src = M"(lir ptr 8
sym @step fn global
fn @step
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 3
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.slt v3, v0
  br v5, b2, b3
b2:
  v6 = add.i64 v4, v3
  v7 = add.i64 v3, v2
  jmp b1(v7, v6)
b3:
  v8 = add.i64 v4, v3
  ret v8
)";
    let (b, a) = optimized(src, FIN);
    let t = text_of(&a, "step");
    assert(t.contains("icmp.sle v0") && t.contains("udiv") || t.contains("mulhu"), t.as_str());
    let ns: []u64 = [0, 1, 3, 4, 100, 1001, (-7i64) as u64];
    for k in 0..ns.len() {
        let x: []u64 = [ns[k]];
        let mut e = leval::Eval::new(&b);
        let want = e.run(b.find_symbol("step"), x).value;
        same_outcome(&b, &a, "step", x, want, false);
    }
}

// A header parameter that steps by an exclusive or with an invariant alternates between two values: the
// loop leaves with its value on the iteration the trip count's parity gives, and a value of it and
// invariants (`sel`) alternates too.
@test
fn a_value_toggled_by_an_invariant_exclusive_or_takes_its_closed_form() {
    let src = M"(lir ptr 8
sym @tog fn global
sym @sel fn global
fn @tog
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 5
  jmp b1(v2, v4)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = xor.i64 v6, v1
  v9 = add.i64 v5, v3
  jmp b1(v9, v8)
b3:
  ret v6
fn @sel
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = iconst.i8 1
  v4 = iconst.i8 0
  v5 = iconst.i32 10
  v6 = iconst.i32 20
  jmp b1(v0, v4)
b1(v7: i32, v8: i8):
  v9 = icmp.ne v8, v4
  v10 = select.i32 v9, v6, v5
  v11 = icmp.ne v7, v1
  br v11, b2, b3
b2:
  v12 = xor.i8 v8, v3
  v13 = sub.i32 v7, v2
  jmp b1(v13, v12)
b3:
  v14 = zext.i32 v8
  v15 = add.i32 v14, v10
  ret v15
)";
    let (b, a) = closed(src, "tog");
    let (sb, sa) = closed(src, "sel");
    let ns: []u64 = [0, 1, 2, 7, 1000];
    let tog: []u64 = [5, 5 ^ 0x36, 5, 5 ^ 0x36, 5];
    let sel: []u64 = [10, 21, 10, 21, 10];
    for k in 0..ns.len() {
        let x: []u64 = [ns[k], 0x36];
        same_outcome(&b, &a, "tog", x, tog[k], false);
        let y: []u64 = [ns[k]];
        same_outcome(&sb, &sa, "sel", y, sel[k], false);
    }
}

// A loop that runs while a value is not 0, the value losing its lowest set bit (`pop`, tested at the
// header) or shifting right by 1 (`len`, tested at the latch on the shifted value, a counter from 5 beside
// it), counts its iterations by `popcnt` or `clz`; an arithmetic shift (`neg`, which never reaches 0 from a
// negative value) stays.
@test
fn a_loop_counting_bits_takes_popcnt_or_clz() {
    let src = M"(lir ptr 8
sym @pop fn global
sym @len fn global
sym @neg fn global
fn @pop
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v0, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.ne v3, v1
  br v5, b2, b3
b2:
  v6 = sub.i64 v3, v2
  v7 = and.i64 v3, v6
  v8 = add.i64 v4, v2
  jmp b1(v7, v8)
b3:
  ret v4
fn @len
  sig (i8) -> i32
b0(v0: i8):
  v1 = iconst.i8 0
  v2 = iconst.i8 1
  v3 = iconst.i32 5
  v4 = iconst.i32 1
  jmp b1(v0, v3)
b1(v5: i8, v6: i32):
  v7 = lshr.i8 v5, v2
  v8 = add.i32 v6, v4
  v9 = icmp.ne v7, v1
  br v9, b1(v7, v8), b2
b2:
  ret v8
fn @neg
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 0
  v2 = iconst.i32 1
  v3 = icmp.sgt v0, v1
  br v3, b1(v0, v1), b2(v1)
b1(v4: i32, v5: i32):
  v6 = ashr.i32 v4, v2
  v7 = add.i32 v5, v2
  v8 = icmp.ne v6, v1
  br v8, b1(v6, v7), b2(v7)
b2(v9: i32):
  ret v9
)";
    let (b, a) = closed(src, "pop");
    assert(text_of(&a, "pop").contains("popcnt.i64"), text_of(&a, "pop").as_str());
    let (lb, la) = closed(src, "len");
    assert(text_of(&la, "len").contains("clz.i8"), text_of(&la, "len").as_str());
    let (_, na) = optimized(src, FIN);
    assert(text_of(&na, "neg").contains("br "), text_of(&na, "neg").as_str());
    let xs: []u64 = [0, 1, 6, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF, 0x123456789];
    let pop: []u64 = [0, 1, 2, 1, 64, 15];
    for k in 0..xs.len() {
        let x: []u64 = [xs[k]];
        same_outcome(&b, &a, "pop", x, pop[k], false);
    }
    // The latch tests the shifted value: the body runs once for 0 and 1, then once per bit.
    let ys: []u64 = [0, 1, 2, 3, 0x40, 0x80, 0xFF];
    let len: []u64 = [6, 6, 7, 7, 12, 13, 13];
    for k in 0..ys.len() {
        let y: []u64 = [ys[k]];
        same_outcome(&lb, &la, "len", y, len[k], false);
    }
}

// A loop stays when a value it leaves with is no polynomial (an exclusive or, a product of itself), or
// when it reads memory.
@test
fn a_loop_without_a_closed_form_stays() {
    let src = M"(lir ptr 8
sym @xor fn global
sym @geo fn global
sym @mem fn global
fn @xor
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  jmp b1(v1, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.slt v3, v0
  br v5, b2, b3
b2:
  v6 = xor.i64 v4, v3
  v7 = add.i64 v3, v2
  jmp b1(v7, v6)
b3:
  ret v4
fn @geo
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 0
  v2 = iconst.i64 1
  v3 = iconst.i64 3
  jmp b1(v1, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.slt v4, v0
  br v6, b2, b3
b2:
  v7 = mul.i64 v5, v3
  v8 = add.i64 v4, v2
  jmp b1(v8, v7)
b3:
  ret v5
fn @mem
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.slt v4, v1
  br v6, b2, b3
b2:
  v7 = load.i64 v0 align 3
  v8 = add.i64 v5, v7
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b3:
  ret v5
)";
    let (b, a) = optimized(src, FIN);
    // Each loop keeps its blocks too: the tests that fail leave no block behind (`close_plan`).
    let (_, z) = optimized(
        src,
        lu::Budgets { peel: 0, partial: 0, version: 0, unswitch: 0, rotate: 0, vector: 0, fin: 0 },
    );
    let names: []str = ["xor", "geo", "mem"];
    for f in 0..names.len() {
        let t = text_of(&a, names[f]);
        assert(t.contains("br "), t.as_str());
        let k = text_of(&z, names[f]);
        assert(t.equals(&k), t.as_str());
    }
    let x: []u64 = [10];
    same_outcome(&b, &a, "xor", x, 1, false);
    same_outcome(&b, &a, "geo", x, 59049, false);
}

// A loop that stores stays, but the sum it leaves with goes: the block its exit enters computes it from
// the trip count, so the loop no longer adds.
@test
fn a_loop_with_effects_leaves_its_sums_to_its_exit() {
    let src = M"(lir ptr 8
sym @f fn global
fn @f
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.slt v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 8
  store v5, v8 align 3
  v9 = mul.i64 v5, v2
  v10 = add.i64 v6, v9
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b3:
  ret v6
)";
    let (b, a) = optimized(src, FIN);
    let t = text_of(&a, "f");
    assert(count(&t, "mul.i64") == 1 && t.contains("store"), t.as_str());
    let _ = b;
}

// A body with a 64-bit product, which no vector unit of the targets multiplies, runs `vector` scalar
// copies of itself, each instruction's copies together; a load of one place its stores keep apart from
// (the exclusive view's elements) is loaded once before them.
@test
fn a_loop_without_vector_lanes_interleaves_scalar_copies() {
    let src = M"(lir ptr 8
sym @f fn global
fn @f
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, ptr) -> i64
  ref p0 0 inner noalias
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i64 3
  v4 = iconst.i64 1
  v5 = load.i64 v0+8 align 3 tbaa 4
  v6 = load.ptr v0 align 3 tbaa 8
  jmp b1(v2, v2)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v5
  br v9, b2, b3
b2:
  v10 = ptradd v6, v7 * 8
  v11 = load.i64 v10 align 3 tbaa 4
  v12 = mul.i64 v11, v3
  store v12, v10 align 3 tbaa 4
  v13 = load.i64 v1 align 3 tbaa 4
  v14 = add.i64 v8, v13
  v15 = add.i64 v7, v4
  jmp b1(v15, v14)
b3:
  ret v8
)";
    let (b, a) = optimized(src, VECTOR);
    let t = text_of(&a, "f");
    // Two copies and the loop for the rest; the place loaded once before the copies, and in the rest.
    assert(count(&t, "mul.i64") == 3 && count(&t, "load.i64 v1 ") == 2 && t.contains("novec"), t.as_str());
    let _ = b;
}

// Scalar copies of a loop that counts down to 0 while it multiplies: each copy reads its own counter (a
// factorial), the copies' products combined after them; a product by a value from before the loop
// through a 32-bit counter (a power) takes that value's square once per iteration of the two copies,
// squared before them. The loop runs the rest.
@test
fn a_product_counting_down_interleaves_scalar_copies() {
    let src = M"(lir ptr 8
sym @fact fn global
sym @pow fn global
fn @fact
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 1
  v2 = iconst.i64 0
  jmp b1(v0, v1)
b1(v3: i64, v4: i64):
  v5 = icmp.eq v3, v2
  br v5, b3, b2
b2:
  v6 = mul.i64 v4, v3
  v7 = sub.i64 v3, v1
  jmp b1(v7, v6)
b3:
  ret v4
fn @pow
  sig (i64, i32) -> i64
b0(v0: i64, v1: i32):
  v2 = iconst.i64 1
  v3 = iconst.i32 0
  v4 = iconst.i32 1
  jmp b1(v1, v2)
b1(v5: i32, v6: i64):
  v7 = icmp.eq v5, v3
  br v7, b3, b2
b2:
  v8 = mul.i64 v6, v0
  v9 = sub.i32 v5, v4
  jmp b1(v9, v8)
b3:
  ret v6
)";
    let (b, a) = optimized(src, VECTOR);
    let tf = text_of(&a, "fact");
    let tp = text_of(&a, "pow");
    assert(count(&tf, "mul.i64") == 4 && tf.contains("novec"), tf.as_str());
    assert(count(&tp, "mul.i64") == 3 && tp.contains("mul.i64 v0, v0") && tp.contains("novec"), tp.as_str());
    let n0: []u64 = [0];
    let n5: []u64 = [5];
    let n7: []u64 = [7];
    same_outcome(&b, &a, "fact", n0, 1, false);
    same_outcome(&b, &a, "fact", n5, 120, false);
    same_outcome(&b, &a, "fact", n7, 5040, false);
    let p0: []u64 = [3, 0];
    let p5: []u64 = [3, 5];
    let p7: []u64 = [2, 7];
    same_outcome(&b, &a, "pow", p0, 1, false);
    same_outcome(&b, &a, "pow", p5, 243, false);
    same_outcome(&b, &a, "pow", p7, 128, false);
}

// Package text `text` read, then optimized with loop budgets `bu` for a target of `vector`-byte registers
// that converts vectors and shifts their lanes as `vops` says (`Package.vops`): each body verifies after.
fn optimized_for(text: str, bu: lu::Budgets, vector: u32, vops: u8) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.vector = vector;
    after.vops = vops;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut after, &none, lopt::Config { inline: il::SPEED, loops: bu });
    let mut v = verify::Verifier::new();
    for i in 0..after.syms.len() {
        let s = after.syms[i];
        if s.def != NONE && s.kind == SK_FUNC {
            assert(v.check(&after, after.spell(s.name), &after.bodies[s.def as usize]), v.err.as_str());
        }
    }
    return (before, after);
}

// The stores of a group through one address at every element of its step (`o[2i]` and `o[2i + 1]`)
// interleave their vectors (`vziplo`, `vziphi`); a select of a lane value and the accumulator on their
// comparison is a max reduction; the counter truncated is a lane value (a splat plus each lane's
// iteration); a square root is one per vector. Each count runs as before.
const SHAPES: str = M"(lir ptr 8
sym @il fn global noinline
sym @mx fn global noinline
sym @iota fn global noinline
sym @rt fn global noinline
sym @fill fn global noinline
sym @drive fn global
fn @il
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = ptradd v2, v6 * 4
  v11 = load.i32 v10 align 2
  v12 = ptradd v0, v6 * 8
  store v9, v12 align 2
  store v11, v12+4 align 2
  v13 = add.i64 v6, v5
  jmp b1(v13)
b3:
  ret
fn @mx
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 -2147483648
  jmp b1(v2, v4)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.sgt v9, v6
  v11 = select.i32 v10, v9, v6
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b3:
  ret v6
fn @iota
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 3
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = trunc.i32 v5
  v8 = mul.i32 v7, v4
  v9 = ptradd v0, v5 * 4
  store v8, v9 align 2
  v10 = add.i64 v5, v3
  jmp b1(v10)
b3:
  ret
fn @rt
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
  v7 = load.f64 v6 align 3
  v8 = fsqrt.f64 v7
  store v8, v6 align 3
  v9 = add.i64 v4, v3
  jmp b1(v9)
b3:
  ret
fn @fill
  sig (ptr, i64, i32) -> void
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 -7
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v2
  v10 = xor.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 512 align 3
  slot s3 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 64
  v6 = iconst.i32 13
  v7 = iconst.i32 29
  call @fill(v1, v5, v6) : (ptr, i64, i32) -> void
  call @fill(v2, v5, v7) : (ptr, i64, i32) -> void
  call @il(v3, v1, v2, v0) : (ptr, ptr, ptr, i64) -> void
  v8 = call.i32 @mx(v3, v0) : (ptr, i64) -> i32
  call @iota(v1, v0) : (ptr, i64) -> void
  v9 = iconst.i32 7
  v10 = iconst.i64 128
  call @fill(v4, v10, v9) : (ptr, i64, i32) -> void
  call @rt(v4, v0) : (ptr, i64) -> void
  v11 = load.i64 v4+8 align 3
  v12 = iconst.i64 0
  v13 = iconst.i64 1
  jmp b1(v12, v12)
b1(v14: i64, v15: i64):
  v16 = icmp.ult v14, v10
  br v16, b2, b3
b2:
  v17 = ptradd v3, v14 * 4
  v18 = load.i32 v17 align 2
  v19 = sext.i64 v18
  v20 = mul.i64 v19, v14
  v21 = add.i64 v15, v20
  v22 = ptradd v1, v14 * 1
  v23 = load.i8 v22 align 0
  v24 = sext.i64 v23
  v25 = add.i64 v21, v24
  v26 = add.i64 v14, v13
  jmp b1(v26, v25)
b3:
  v27 = sext.i64 v8
  v28 = add.i64 v15, v27
  v29 = add.i64 v28, v11
  ret v29
)";

@test
fn groups_extremes_counters_and_roots_vectorize() {
    let (b, a) = optimized(SHAPES, VECTOR);
    let l = text_of(&a, "il");
    assert(l.contains("vziplo.v4i32") && l.contains("vziphi.v4i32"), l.as_str());
    let m = text_of(&a, "mx");
    assert(m.contains("vcmp.sgt.v4i32") && m.contains("vsel.v4i32") && m.contains("reduce_max"), m.as_str());
    let i = text_of(&a, "iota");
    assert(i.contains("wconst.v4i32") && i.contains("mul.v4i32"), i.as_str());
    let r = text_of(&a, "rt");
    assert(r.contains("fsqrt.v2f64"), r.as_str());
    let lens: [u64; 6] = [0, 1, 3, 8, 33, 64];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A bounds check of `2i` and one of `2i + 1` (an `or`, an `add`) version the loop on
// `n <= ((len - c - 1) >> 1) + 1`: the copy without them interleaves its stores, and a count past the
// length panics as before, at the same store.
@test
fn affine_bounds_checks_version_the_loop() {
    let src = M"(lir ptr 8
sym @dup fn global noinline
sym @drive fn global
fn @dup
  sig (ptr, i64, ptr, i64) -> i64
b0(v0: ptr, v1: i64, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b6
b2:
  v8 = ptradd v2, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = shl.i64 v6, v5
  v11 = icmp.uge v10, v1
  br v11, b5, b3
b3:
  v12 = ptradd v0, v10 * 4
  store v9, v12 align 2
  v13 = or.i64 v10, v5
  v14 = icmp.uge v13, v1
  br v14, b5, b4
b4:
  v15 = ptradd v0, v13 * 4
  v16 = add.i32 v9, v9
  store v16, v15 align 2
  v17 = add.i64 v6, v5
  jmp b1(v17)
b5: cold
  panic "index out of bounds"
b6:
  v18 = load.i32 v0+4 align 2
  v19 = sext.i64 v18
  ret v19
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 128 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 32
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b3
b2:
  v9 = trunc.i32 v7
  v10 = ptradd v3, v7 * 4
  store v9, v10 align 2
  v11 = add.i64 v7, v5
  jmp b1(v11)
b3:
  v12 = call.i64 @dup(v2, v1, v3, v0) : (ptr, i64, ptr, i64) -> i64
  ret v12
)";
    let both = lu::Budgets { peel: 0, partial: 0, version: 200, unswitch: 0, rotate: 0, vector: 2, fin: 0 };
    let (b, a) = optimized(src, both);
    let t = text_of(&a, "dup");
    assert(t.contains("vziplo.v4i32") && count(&t, "panic") == 1, t.as_str());
    // Counts within the output's 64 elements, then counts past its length.
    let fits: [[u64; 2]; 4] = [[1, 2], [8, 16], [13, 64], [32, 64]];
    for k in 0..4usize {
        let args: []u64 = [unsafe fits[k][0], unsafe fits[k][1]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let past: [[u64; 2]; 3] = [[9, 16], [9, 17], [32, 63]];
    for k in 0..3usize {
        let args: []u64 = [unsafe past[k][0], unsafe past[k][1]];
        same_outcome(&b, &a, "drive", args, 0, true);
    }
}

// With conversions and shifts in registers (`vops`): a narrower lane widened, a lane shifted by an
// invariant and an integer converted to a float vectorize in one plan, the narrow vectors half a register.
@test
fn conversions_and_shifts_vectorize_with_vops() {
    let src = M"(lir ptr 8
sym @mixw fn global noinline
sym @drive fn global
fn @mixw
  sig (ptr, ptr, i64, i32) -> void
b0(v0: ptr, v1: ptr, v2: i64, v3: i32):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 2
  v9 = load.i16 v8 align 1
  v10 = zext.i32 v9
  v11 = shl.i32 v10, v3
  v12 = sitofp.f32 v11
  v13 = ptradd v0, v6 * 4
  store v12, v13 align 2
  v14 = add.i64 v6, v5
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i16 -3
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = trunc.i16 v7
  v10 = mul.i16 v9, v6
  v11 = ptradd v1, v7 * 2
  store v10, v11 align 1
  v12 = add.i64 v7, v4
  jmp b1(v12)
b3:
  v13 = iconst.i32 3
  call @mixw(v2, v1, v0, v13) : (ptr, ptr, i64, i32) -> void
  v14 = load.f32 v2+20 align 2
  v15 = fptosi.i64 v14
  ret v15
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let t = text_of(&a, "mixw");
    assert(
        t.contains("zext.v4i32") && t.contains("shl.v4i32") && t.contains("sitofp.v4f32") && t.contains("load.v4i16"),
        t.as_str(),
    );
    let (_, n) = optimized_for(src, VECTOR, 16, 0);
    let u = text_of(&n, "mixw");
    assert(!u.contains("v4i32"), u.as_str());
    let lens: [u64; 4] = [6, 8, 33, 128];
    for k in 0..4usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A vector wider than a register splits into register-wide parts (`lir::wide`): its loads, its lane-wise
// operations and its stores by parts, a splat once. A comparison's lane mask splits as the parts' masks,
// which a choice and an `or` take by parts; the mask returned joins them by shifts.
@test
fn wide_vectors_split_into_registers() {
    let src = M"(lir ptr 8
sym @axpy fn global noinline
sym @pick fn global noinline
sym @drive fn global
fn @pick
  sig (ptr, ptr) -> i64
b0(v0: ptr, v1: ptr):
  v2 = load.v8f32 v0 align 2
  v3 = load.v8f32 v1 align 2
  v4 = vop.gt.i8 (v2, v3)
  v5 = vop.lt.i8 (v2, v3)
  v6 = or.i8 v4, v5
  v7 = vop.choose.v8f32 (v4, v2, v3)
  store v7, v0 align 2
  v8 = zext.i64 v6
  ret v8
fn @axpy
  sig (ptr, ptr, f32) -> void
b0(v0: ptr, v1: ptr, v2: f32):
  v3 = splat.v16f32 v2
  v4 = load.v16f32 v1 align 2
  v5 = load.v16f32 v0 align 2
  v6 = fmul.v16f32 v3, v4
  v7 = fadd.v16f32 v6, v5
  store v7, v0 align 2
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 64 align 4
  slot s1 size 64 align 4
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 16
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v5
  br v7, b2, b3
b2:
  v8 = add.i64 v6, v0
  v9 = sitofp.f32 v8
  v10 = ptradd v1, v6 * 4
  store v9, v10 align 2
  v11 = ptradd v2, v6 * 4
  store v9, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  v13 = fconst.f32 0x40000000
  call @axpy(v1, v2, v13) : (ptr, ptr, f32) -> void
  v14 = load.f32 v1+60 align 2
  v15 = fptosi.i64 v14
  v16 = ptradd v2, v0 * 4
  v17 = fconst.f32 0x41000000
  store v17, v16 align 2
  v18 = call.i64 @pick(v1, v2) : (ptr, ptr) -> i64
  v19 = iconst.i64 8
  v20 = shl.i64 v18, v19
  v21 = load.f32 v1+12 align 2
  v22 = fptosi.i64 v21
  v23 = add.i64 v15, v20
  v24 = add.i64 v23, v22
  ret v24
)";
    let (b, a) = optimized_for(src, NO_LOOPS, 16, 0);
    let t = text_of(&a, "axpy");
    assert(
        count(&t, "load.v4f32") == 8 && count(&t, "fadd.v4f32") == 4 && count(&t, "splat.v4f32") == 1 && !t.contains(
            "v16f32",
        ),
        t.as_str(),
    );
    let p = text_of(&a, "pick");
    assert(count(&p, "vop.gt.i8") == 2 && count(&p, "vop.choose.v4f32") == 2, p.as_str());
    assert(count(&p, "or.i8") == 3 && !p.contains("v8f32"), p.as_str());
    let ks: [u64; 3] = [0, 3, 6];
    for k in 0..3usize {
        let args: []u64 = [unsafe ks[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Reductions the build may not reorder keep their order: a float sum takes each lane of the products in
// turn (`vextract`), a float minimum with signed zeros keeps each lane's and runs the loop again from its
// start when the result is zero, whose sign the order of equal values decides; an integer product
// multiplies lanes. A counter tested by `!=` and one counting down to 0 vectorize, and a load a fixed
// distance ahead of a store through the same base, or a vector loop's iterations behind it. Each count
// and each place of a zero (none, -0.0 before 0.0, 0.0 before -0.0) runs as before.
const KEPT: str = M"(lir ptr 8
sym @dot fn global noinline
sym @prod fn global noinline
sym @fmin fn global noinline
sym @nef fn global noinline
sym @rev fn global noinline
sym @ahead fn global noinline
sym @behind fn global noinline
sym @fill fn global noinline
sym @ffill fn global noinline
sym @drive fn global
fn @ffill
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v1
  br v5, b2, b3
b2:
  v6 = add.i64 v4, v3
  v7 = sitofp.f32 v6
  v8 = ptradd v0, v4 * 4
  store v7, v8 align 2
  jmp b1(v6)
b3:
  ret
fn @dot
  sig (ptr, ptr, i64) -> f32
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = fconst.f32 0x80000000
  jmp b1(v3, v5)
b1(v6: i64, v7: f32):
  v8 = icmp.ult v6, v2
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  v10 = load.f32 v9 align 2
  v11 = ptradd v1, v6 * 4
  v12 = load.f32 v11 align 2
  v13 = fmul.f32 v10, v12
  v14 = fadd.f32 v7, v13
  v15 = add.i64 v6, v4
  jmp b1(v15, v14)
b3:
  ret v7
fn @prod
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 1
  v5 = iconst.i32 3
  jmp b1(v2, v4)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = or.i32 v10, v5
  v12 = mul.i32 v7, v11
  v13 = add.i64 v6, v3
  jmp b1(v13, v12)
b3:
  ret v7
fn @fmin
  sig (ptr, i64) -> f32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = fconst.f32 0x7f800000
  jmp b1(v2, v4)
b1(v5: i64, v6: f32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.f32 v8 align 2
  v10 = fcmp.olt v9, v6
  v11 = select.f32 v10, v9, v6
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b3:
  ret v6
fn @nef
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 3
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ne v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = mul.i32 v8, v4
  store v9, v7 align 2
  v10 = add.i64 v5, v3
  jmp b1(v10)
b3:
  ret
fn @rev
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ne v5, v3
  br v6, b2, b3
b2:
  v7 = sub.i64 v5, v4
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8-4 align 2
  v10 = ptradd v1, v5 * 4
  v11 = load.i32 v10-4 align 2
  v12 = sub.i32 v9, v11
  store v12, v8-4 align 2
  jmp b1(v7)
b3:
  ret
fn @ahead
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 5
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 4
  v8 = load.i32 v7+4 align 2
  v9 = add.i32 v8, v4
  store v9, v7 align 2
  v10 = add.i64 v5, v3
  jmp b1(v10)
b3:
  ret
fn @behind
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 8
  v3 = iconst.i64 1
  v4 = iconst.i32 7
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 4
  v8 = load.i32 v7-32 align 2
  v9 = xor.i32 v8, v4
  store v9, v7 align 2
  v10 = add.i64 v5, v3
  jmp b1(v10)
b3:
  ret
fn @fill
  sig (ptr, i64, i32) -> void
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 -7
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v2
  v10 = xor.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 64
  v6 = iconst.i32 13
  v7 = iconst.i32 29
  call @fill(v2, v5, v6) : (ptr, i64, i32) -> void
  call @fill(v3, v5, v7) : (ptr, i64, i32) -> void
  call @ffill(v4, v5) : (ptr, i64) -> void
  v8 = iconst.i64 0
  v9 = iconst.i32 0
  v10 = iconst.i32 -2147483648
  v11 = iconst.i64 1
  v12 = icmp.eq v1, v11
  v13 = select.i32 v12, v10, v9
  v14 = select.i32 v12, v9, v10
  v15 = iconst.i64 2
  v16 = icmp.ult v1, v15
  br v16, b1, b2
b1:
  v17 = ptradd v4, v8 * 4
  store v13, v17+4 align 2
  store v14, v17+12 align 2
  v18 = ptradd v4, v8 * 4
  store v14, v18+36 align 2
  jmp b2
b2:
  v19 = call.f32 @fmin(v4, v0) : (ptr, i64) -> f32
  v20 = bitcast.i32 v19
  v21 = zext.i64 v20
  v22 = call.f32 @dot(v2, v3, v0) : (ptr, ptr, i64) -> f32
  v23 = bitcast.i32 v22
  v24 = zext.i64 v23
  v25 = call.i32 @prod(v2, v0) : (ptr, i64) -> i32
  v26 = zext.i64 v25
  call @nef(v2, v0) : (ptr, i64) -> void
  call @rev(v3, v2, v0) : (ptr, ptr, i64) -> void
  call @ahead(v2, v0) : (ptr, i64) -> void
  call @behind(v3, v0) : (ptr, i64) -> void
  v27 = xor.i64 v21, v24
  v28 = iconst.i64 32
  v29 = shl.i64 v26, v28
  v30 = xor.i64 v27, v29
  jmp b3(v8, v30)
b3(v31: i64, v32: i64):
  v33 = icmp.ult v31, v5
  br v33, b4, b5
b4:
  v34 = ptradd v2, v31 * 4
  v35 = load.i32 v34 align 2
  v36 = ptradd v3, v31 * 4
  v37 = load.i32 v36 align 2
  v38 = sext.i64 v35
  v39 = sext.i64 v37
  v40 = mul.i64 v38, v31
  v41 = add.i64 v32, v40
  v42 = xor.i64 v41, v39
  v43 = add.i64 v31, v11
  jmp b3(v43, v42)
b5:
  ret v32
)";

@test
fn ordered_reductions_counters_and_distances_vectorize() {
    let (b, a) = optimized(KEPT, VECTOR);
    let d = text_of(&a, "dot");
    assert(d.contains("fmul.v4f32") && d.contains("vextract.3.f32") && !d.contains("reduce_add"), d.as_str());
    let p = text_of(&a, "prod");
    assert(p.contains("mul.v4i32") && p.contains("reduce_mul"), p.as_str());
    let m = text_of(&a, "fmin");
    assert(m.contains("vcmp.olt.v4i32") && m.contains("fcmp.oeq"), m.as_str());
    let n = text_of(&a, "nef");
    assert(n.contains("mul.v4i32"), n.as_str());
    let r = text_of(&a, "rev");
    assert(r.contains("sub.v4i32"), r.as_str());
    let h = text_of(&a, "ahead");
    assert(h.contains("add.v4i32"), h.as_str());
    let w = text_of(&a, "behind");
    assert(w.contains("xor.v4i32"), w.as_str());
    // Counts below, at and past a vector loop's iterations (`ahead` reads one element past the count); a
    // zero at index 1 or 3 first, or none.
    let lens: [u64; 7] = [0, 1, 7, 8, 9, 33, 63];
    for k in 0..7usize {
        for z in 0..3u64 {
            let args: []u64 = [unsafe lens[k], z];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A loop that may leave early over the elements of a slice it counts to (`i < len` of the same slice)
// vectorizes: a vector iteration tests every lane, and when one would leave hands its iterations to the
// loop, which leaves at the first. A sum taken until then hands over the sum before that iteration. Each
// place of the element sought (first, in a later vector, in the rest, none) runs as before.
@test
fn an_early_exit_vectorizes() {
    let src = M"(lir ptr 8
sym @find fn global noinline
sym @upto fn global noinline
sym @drive fn global
fn @find
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i8) -> i64
b0(v0: ptr, v1: i8):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b4
b2:
  v8 = ptradd v2, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v1
  br v10, b5, b3
b3:
  v11 = add.i64 v6, v5
  jmp b1(v11)
b4:
  ret v3
b5:
  ret v6
fn @upto
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0) -> i64
b0(v0: ptr):
  v1 = load.ptr v0 align 3
  v2 = load.i64 v0+8 align 3
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v3)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v2
  br v8, b2, b4(v7)
b2:
  v9 = ptradd v1, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.slt v10, v5
  br v11, b4(v7), b3
b3:
  v12 = sext.i64 v10
  v13 = add.i64 v7, v12
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
b4(v15: i64):
  ret v15
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 64 align 3
  slot s1 size 256 align 3
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  jmp b1(v6)
b1(v8: i64):
  v9 = iconst.i64 64
  v10 = icmp.ult v8, v9
  br v10, b2, b3
b2:
  v11 = trunc.i8 v8
  v12 = ptradd v2, v8 * 1
  store v11, v12 align 0
  v13 = trunc.i32 v8
  v14 = ptradd v3, v8 * 4
  store v13, v14 align 2
  v15 = add.i64 v8, v7
  jmp b1(v15)
b3:
  v16 = ptradd v3, v1 * 4
  v17 = iconst.i32 -1
  store v17, v16 align 2
  store v2, v4 align 3
  store v0, v4+8 align 3
  store v3, v5 align 3
  store v0, v5+8 align 3
  v18 = trunc.i8 v1
  v19 = call.i64 @find(v4, v18) : (ptr, i8) -> i64
  v20 = call.i64 @upto(v5) : (ptr) -> i64
  v21 = iconst.i64 20
  v22 = shl.i64 v19, v21
  v23 = add.i64 v22, v20
  ret v23
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let f = text_of(&a, "find");
    assert(f.contains("vcmp.eq.v16i8") && f.contains("reduce_or"), f.as_str());
    let u = text_of(&a, "upto");
    assert(u.contains("vcmp.slt.v2i32") && u.contains("add.v2i64"), u.as_str());
    let lens: [u64; 5] = [0, 5, 16, 40, 64];
    let at: [u64; 6] = [0, 3, 17, 33, 50, 63];
    for k in 0..5usize {
        for j in 0..6usize {
            let args: []u64 = [unsafe lens[k], unsafe at[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A store on one side of a branch stores the lanes its condition picks (`store_masked_ptr`; the other side
// the complement), so no element the loop leaves is written; the loop runs the rest with its branch. Each
// count runs as before.
@test
fn a_conditional_store_vectorizes_masked() {
    let src = M"(lir ptr 8
sym @clip fn global noinline
sym @drive fn global
fn @clip
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b5
b2:
  v8 = ptradd v0, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.slt v9, v5
  br v10, b3, b4
b3:
  store v5, v8 align 2
  jmp b4
b4:
  v11 = ptradd v1, v6 * 4
  v12 = add.i32 v9, v9
  store v12, v11 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b5:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 64
  v6 = iconst.i32 7
  v7 = iconst.i32 200
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v5
  br v9, b2, b3
b2:
  v10 = trunc.i32 v8
  v11 = mul.i32 v10, v6
  v12 = urem.i32 v11, v7
  v13 = iconst.i32 100
  v14 = sub.i32 v12, v13
  v15 = ptradd v1, v8 * 4
  store v14, v15 align 2
  v16 = ptradd v2, v8 * 4
  store v13, v16 align 2
  v17 = add.i64 v8, v4
  jmp b1(v17)
b3:
  call @clip(v1, v2, v0) : (ptr, ptr, i64) -> void
  jmp b4(v3, v3)
b4(v18: i64, v19: i64):
  v20 = icmp.ult v18, v5
  br v20, b5, b6
b5:
  v21 = ptradd v1, v18 * 4
  v22 = load.i32 v21 align 2
  v23 = ptradd v2, v18 * 4
  v24 = load.i32 v23 align 2
  v25 = sext.i64 v22
  v26 = sext.i64 v24
  v27 = mul.i64 v25, v18
  v28 = add.i64 v19, v27
  v29 = xor.i64 v28, v26
  v30 = add.i64 v18, v4
  jmp b4(v30, v29)
b6:
  ret v19
)";
    let (b, a) = optimized(src, VECTOR);
    let c = text_of(&a, "clip");
    assert(c.contains("store_masked_ptr") && c.contains("vop.lt.s.i8"), c.as_str());
    let lens: [u64; 6] = [0, 1, 7, 8, 33, 64];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A counter that steps by a power of 2 vectorizes: through `base + i * size` its loads read every k-th
// element (`vunzip`), and through a byte offset stepping by the element's size they read in a row. The
// vectors run the iterations below the bound, the loop the rest. Each count runs as before.
@test
fn a_counter_stepping_by_k_vectorizes() {
    let src = M"(lir ptr 8
sym @evens fn global noinline
sym @words fn global noinline
sym @drive fn global
fn @evens
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 2
  v4 = iconst.i32 0
  jmp b1(v2, v4)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = add.i32 v6, v9
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
fn @words
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 4
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v9, v5
  v11 = ptradd v0, v6 * 1
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 260 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 65
  v6 = iconst.i32 7
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = trunc.i32 v7
  v10 = mul.i32 v9, v6
  v11 = ptradd v2, v7 * 4
  store v10, v11 align 2
  v12 = add.i64 v7, v4
  jmp b1(v12)
b3:
  v13 = call.i32 @evens(v2, v0) : (ptr, i64) -> i32
  v14 = iconst.i64 2
  v15 = shl.i64 v0, v14
  call @words(v1, v2, v15) : (ptr, ptr, i64) -> void
  v16 = sext.i64 v13
  jmp b4(v3, v16)
b4(v17: i64, v18: i64):
  v19 = icmp.ult v17, v0
  br v19, b5, b6
b5:
  v20 = ptradd v1, v17 * 4
  v21 = load.i32 v20 align 2
  v22 = sext.i64 v21
  v23 = mul.i64 v22, v17
  v24 = add.i64 v18, v23
  v25 = add.i64 v17, v4
  jmp b4(v25, v24)
b6:
  ret v18
)";
    let (b, a) = optimized(src, VECTOR);
    let e = text_of(&a, "evens");
    assert(e.contains("vunzip.v4i32") && e.contains("add.v4i32"), e.as_str());
    let w = text_of(&a, "words");
    assert(w.contains("mul.v4i32"), w.as_str());
    let lens: [u64; 7] = [0, 1, 2, 9, 16, 33, 64];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Straight-line packing takes the target's register width: eight 4-byte stores of sums pack into one
// 32-byte vector on a target of 32-byte registers, into two 16-byte vectors on one of 16-byte registers.
@test
fn straight_line_packs_take_the_register_width() {
    let src = M"(lir ptr 8
sym @add8 fn global noinline
sym @drive fn global
fn @add8
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = load.i32 v1 align 2
  v4 = load.i32 v1+4 align 2
  v5 = load.i32 v1+8 align 2
  v6 = load.i32 v1+12 align 2
  v7 = load.i32 v1+16 align 2
  v8 = load.i32 v1+20 align 2
  v9 = load.i32 v1+24 align 2
  v10 = load.i32 v1+28 align 2
  v11 = trunc.i32 v2
  v12 = add.i32 v3, v11
  v13 = add.i32 v4, v11
  v14 = add.i32 v5, v11
  v15 = add.i32 v6, v11
  v16 = add.i32 v7, v11
  v17 = add.i32 v8, v11
  v18 = add.i32 v9, v11
  v19 = add.i32 v10, v11
  store v12, v0 align 2
  store v13, v0+4 align 2
  store v14, v0+8 align 2
  store v15, v0+12 align 2
  store v16, v0+16 align 2
  store v17, v0+20 align 2
  store v18, v0+24 align 2
  store v19, v0+28 align 2
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 32 align 3
  slot s1 size 32 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 8
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v5
  br v7, b2, b3
b2:
  v8 = mul.i64 v6, v6
  v9 = trunc.i32 v8
  v10 = ptradd v2, v6 * 4
  store v9, v10 align 2
  v11 = add.i64 v6, v4
  jmp b1(v11)
b3:
  call @add8(v1, v2, v0) : (ptr, ptr, i64) -> void
  v12 = load.i64 v1 align 3
  v13 = load.i64 v1+24 align 3
  v14 = xor.i64 v12, v13
  ret v14
)";
    let (b, a) = optimized_for(src, VECTOR, 32, 0);
    let t = text_of(&a, "add8");
    assert(t.contains("add.v8i32") && count(&t, "store") == 1, t.as_str());
    let (_, a16) = optimized_for(src, VECTOR, 16, 0);
    let t16 = text_of(&a16, "add8");
    assert(count(&t16, "add.v4i32") == 2, t16.as_str());
    let args: []u64 = [5];
    same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
}

// The four terms of a sum (products of consecutive loads) pack into one vector multiply and one reduction.
@test
fn a_sum_of_four_terms_packs_into_one_reduction() {
    let src = M"(lir ptr 8
sym @dot4 fn global noinline
sym @drive fn global
fn @dot4
  sig (ptr, ptr) -> i32
b0(v0: ptr, v1: ptr):
  v2 = load.i32 v0 align 2
  v3 = load.i32 v0+4 align 2
  v4 = load.i32 v0+8 align 2
  v5 = load.i32 v0+12 align 2
  v6 = load.i32 v1 align 2
  v7 = load.i32 v1+4 align 2
  v8 = load.i32 v1+8 align 2
  v9 = load.i32 v1+12 align 2
  v10 = mul.i32 v2, v6
  v11 = mul.i32 v3, v7
  v12 = mul.i32 v4, v8
  v13 = mul.i32 v5, v9
  v14 = add.i32 v10, v11
  v15 = add.i32 v14, v12
  v16 = add.i32 v15, v13
  ret v16
fn @drive
  sig (i64) -> i64
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = trunc.i32 v0
  v4 = iconst.i32 3
  v5 = mul.i32 v3, v4
  store v3, v1 align 2
  store v5, v1+4 align 2
  store v4, v1+8 align 2
  store v3, v1+12 align 2
  store v5, v2 align 2
  store v5, v2+4 align 2
  store v3, v2+8 align 2
  store v4, v2+12 align 2
  v6 = call.i32 @dot4(v1, v2) : (ptr, ptr) -> i32
  v7 = sext.i64 v6
  ret v7
)";
    let (b, a) = optimized(src, VECTOR);
    let t = text_of(&a, "dot4");
    assert(t.contains("mul.v4i32") && t.contains("reduce_add"), t.as_str());
    let vals: [u64; 3] = [0, 7, 100000];
    for k in 0..3usize {
        let args: []u64 = [unsafe vals[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A map (no reduction, no store through a base it loads through) runs its last vector iteration at
// `n - k`, over elements an earlier iteration wrote with the same values, and leaves the loop nothing:
// the vector loop runs while below `n - k`, then a block past it runs the loop once more at `n - k`
// when elements are left, so the counter's chain in the loop stays an add (no `select`). Each count runs
// as before.
@test
fn a_map_ends_with_an_overlapping_vector_iteration() {
    let src = M"(lir ptr 8
sym @triple fn global noinline
sym @drive fn global
fn @triple
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 64
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v5
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = ptradd v2, v6 * 4
  store v8, v9 align 2
  v10 = ptradd v1, v6 * 4
  store v8, v10 align 2
  v11 = add.i64 v6, v4
  jmp b1(v11)
b3:
  call @triple(v1, v2, v0) : (ptr, ptr, i64) -> void
  jmp b4(v3, v3)
b4(v12: i64, v13: i64):
  v14 = icmp.ult v12, v5
  br v14, b5, b6
b5:
  v15 = ptradd v1, v12 * 4
  v16 = load.i32 v15 align 2
  v17 = sext.i64 v16
  v18 = mul.i64 v17, v12
  v19 = add.i64 v13, v18
  v20 = add.i64 v12, v4
  jmp b4(v20, v19)
b6:
  ret v13
)";
    let (b, a) = optimized(src, VECTOR);
    let t = text_of(&a, "triple");
    assert(t.contains("mul.v4i32") && !t.contains("select.i64"), t.as_str());
    let lens: [u64; 7] = [0, 1, 7, 8, 9, 33, 64];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// The cost model: a load of every 4th element costs four loads and three unzips. Over the four 4-byte
// lanes of a vector that saves instructions; over the two 8-byte lanes it does not, and the loop stays
// scalar.
@test
fn the_cost_model_keeps_a_costly_loop_scalar() {
    let src = M"(lir ptr 8
sym @every4_i32 fn global noinline
sym @every4_i64 fn global noinline
fn @every4_i32
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 16
  v9 = load.i32 v8 align 2
  v10 = add.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @every4_i64
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 32
  v9 = load.i64 v8 align 3
  v10 = add.i64 v9, v5
  v11 = ptradd v0, v6 * 8
  store v10, v11 align 3
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
)";
    let (_, a) = optimized(src, VECTOR);
    let w = text_of(&a, "every4_i32");
    assert(w.contains("add.v4i32"), w.as_str());
    let d = text_of(&a, "every4_i64");
    assert(!d.contains("v2i64"), d.as_str());
}

// A target that converts an i64 to f64 lane by lane (`Package.vops` VOPS_SOME, x86-64) gains nothing from
// a loop of such conversions over two lanes, and the loop stays scalar; one that converts it in registers
// (VOPS_ALL) vectorizes it.
@test
fn lane_by_lane_conversions_cost_their_lanes() {
    let src = M"(lir ptr 8
sym @tof fn global noinline
fn @tof
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 8
  v8 = load.i64 v7 align 3
  v9 = sitofp.f64 v8
  v10 = ptradd v0, v5 * 8
  store v9, v10 align 3
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
)";
    let (_, all) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let ta = text_of(&all, "tof");
    assert(ta.contains("sitofp.v2f64"), ta.as_str());
    let (_, some) = optimized_for(src, VECTOR, 16, VOPS_SOME);
    let ts = text_of(&some, "tof");
    assert(!ts.contains("v2f64"), ts.as_str());
}

// Lanes of 4 times another's width: with conversions in registers (`vops`) the vectors hold 8 lanes, the
// bytes in 8, the 16-bit lanes in 16, the 32-bit ones in two registers, which `lir::wide` splits: a byte
// widens through 16 bits (interleaved with its sign or zeros), a 32-bit lane narrows through 16 (even
// lanes), and a byte to a float extends, then converts. Each count runs as before.
@test
fn lanes_of_4_times_the_width_vectorize() {
    let src = M"(lir ptr 8
sym @widen fn global noinline
sym @narrow fn global noinline
sym @tofloat fn global noinline
sym @drive fn global
fn @widen
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = sext.i32 v9
  v11 = mul.i32 v10, v5
  v12 = ptradd v0, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @narrow
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 7
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = add.i32 v9, v5
  v11 = trunc.i8 v10
  v12 = ptradd v0, v6 * 1
  store v11, v12 align 0
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @tofloat
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = fconst.f32 0x3f000000
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = uitofp.f32 v9
  v11 = fmul.f32 v10, v5
  v12 = ptradd v0, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
  slot s3 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 64
  v8 = iconst.i64 2654435761
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v8
  v12 = trunc.i32 v11
  v13 = ptradd v1, v9 * 4
  store v12, v13 align 2
  v14 = add.i64 v9, v6
  jmp b1(v14)
b3:
  call @widen(v2, v1, v0) : (ptr, ptr, i64) -> void
  call @narrow(v3, v1, v0) : (ptr, ptr, i64) -> void
  call @tofloat(v4, v1, v0) : (ptr, ptr, i64) -> void
  jmp b4(v5, v5)
b4(v15: i64, v16: i64):
  v17 = icmp.ult v15, v0
  br v17, b5, b6
b5:
  v18 = ptradd v2, v15 * 4
  v19 = load.i32 v18 align 2
  v20 = ptradd v3, v15 * 1
  v21 = load.i8 v20 align 0
  v22 = ptradd v4, v15 * 4
  v23 = load.i32 v22 align 2
  v24 = mul.i64 v16, v8
  v25 = sext.i64 v19
  v26 = sext.i64 v21
  v27 = zext.i64 v23
  v28 = xor.i64 v24, v25
  v29 = add.i64 v28, v26
  v30 = xor.i64 v29, v27
  v31 = add.i64 v15, v6
  jmp b4(v31, v30)
b6:
  ret v16
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let w = text_of(&a, "widen");
    assert(w.contains("vziplo.v8i16") && w.contains("mul.v4i32") && !w.contains("v8i32"), w.as_str());
    let n = text_of(&a, "narrow");
    assert(n.contains("vunzip.v8i16") && n.contains("trunc.v8i8"), n.as_str());
    let f = text_of(&a, "tofloat");
    assert(f.contains("sitofp.v4f32") && f.contains("fmul.v4f32"), f.as_str());
    let lens: [u64; 7] = [0, 1, 7, 8, 9, 33, 61];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Gathers and scatters in vectors: a load through `base + idx[i] * size` takes each lane's element (an
// extract of the index, a scalar load, an insert), and a store through it writes each lane's element in
// lane order, so of two lanes with one index the later one's value stays. A scattered store's place is
// apart from every other access (an exclusive parameter's). Each count runs as before.
@test
fn gathers_and_scatters_vectorize() {
    let src = M"(lir ptr 8
sym @gather fn global noinline
sym @scatter fn global noinline
sym @drive fn global
fn @gather
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 256 noalias
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 1
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = ptradd v2, v7 * 4
  v10 = load.i32 v9 align 2
  v11 = sext.i64 v10
  v12 = ptradd v1, v11 * 4
  v13 = load.i32 v12 align 2
  v14 = add.i32 v13, v6
  v15 = ptradd v0, v7 * 4
  store v14, v15 align 2
  v16 = add.i64 v7, v5
  jmp b1(v16)
b3:
  ret
fn @scatter
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 256 noalias
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 5
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = ptradd v2, v7 * 4
  v10 = load.i32 v9 align 2
  v11 = ptradd v1, v7 * 4
  v12 = load.i32 v11 align 2
  v13 = mul.i32 v12, v6
  v14 = zext.i64 v10
  v15 = ptradd v0, v14 * 4
  store v13, v15 align 2
  v16 = add.i64 v7, v5
  jmp b1(v16)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
  slot s3 size 256 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 64
  v8 = iconst.i32 37
  v9 = iconst.i32 64
  jmp b1(v5)
b1(v10: i64):
  v11 = icmp.ult v10, v7
  br v11, b2, b3
b2:
  v12 = trunc.i32 v10
  v13 = mul.i32 v12, v8
  v14 = urem.i32 v13, v9
  v15 = ptradd v1, v10 * 4
  store v14, v15 align 2
  v16 = ptradd v2, v10 * 4
  store v13, v16 align 2
  v17 = ptradd v3, v10 * 4
  store v12, v17 align 2
  v18 = ptradd v4, v10 * 4
  store v12, v18 align 2
  v19 = add.i64 v10, v6
  jmp b1(v19)
b3:
  call @gather(v3, v2, v1, v0) : (ptr, ptr, ptr, i64) -> void
  call @scatter(v4, v2, v1, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v5, v5)
b4(v20: i64, v21: i64):
  v22 = icmp.ult v20, v7
  br v22, b5, b6
b5:
  v23 = ptradd v3, v20 * 4
  v24 = load.i32 v23 align 2
  v25 = ptradd v4, v20 * 4
  v26 = load.i32 v25 align 2
  v27 = sext.i64 v24
  v28 = sext.i64 v26
  v29 = mul.i64 v21, v7
  v30 = add.i64 v29, v27
  v31 = xor.i64 v30, v28
  v32 = add.i64 v20, v6
  jmp b4(v32, v31)
b6:
  ret v21
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let g = text_of(&a, "gather");
    assert(g.contains("vinsert.1.v2i32") && g.contains("add.v2i32"), g.as_str());
    let s = text_of(&a, "scatter");
    assert(s.contains("mul.v2i32") && s.contains("vextract.1.i32"), s.as_str());
    let lens: [u64; 6] = [0, 1, 7, 8, 33, 64];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// An early exit tested before the rest of its iteration: the vector loop tests every lane's index before
// it gathers through it and stores, and runs that rest only when no lane leaves; else the scalar loop,
// with its own branch, runs the iterations from the vector iteration's first, stores up to the leaving
// one and leaves there. Each count and bound runs as before.
@test
fn an_early_exit_guards_the_rest_of_its_iteration() {
    let src = M"(lir ptr 8
sym @take fn global noinline
sym @drive fn global
fn @take
  sig (ptr, ptr, ptr, i64) -> i64
  ref p0 256 noalias
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = load.ptr v2 align 3
  v5 = load.i64 v2+8 align 3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i32 1
  jmp b1(v6)
b1(v9: i64):
  v10 = icmp.ult v9, v5
  br v10, b2, b4(v5)
b2:
  v11 = ptradd v4, v9 * 4
  v12 = load.i32 v11 align 2
  v13 = zext.i64 v12
  v14 = icmp.uge v13, v3
  br v14, b4(v9), b3
b3:
  v15 = ptradd v1, v13 * 4
  v16 = load.i32 v15 align 2
  v17 = add.i32 v16, v8
  v18 = ptradd v0, v9 * 4
  store v17, v18 align 2
  v19 = add.i64 v9, v7
  jmp b1(v19)
b4(v20: i64):
  ret v20
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
  slot s3 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 64
  v8 = iconst.i32 37
  v9 = iconst.i32 64
  v10 = iconst.i32 3
  v11 = iconst.i32 -1
  jmp b1(v5)
b1(v12: i64):
  v13 = icmp.ult v12, v7
  br v13, b2, b3
b2:
  v14 = trunc.i32 v12
  v15 = mul.i32 v14, v8
  v16 = urem.i32 v15, v9
  v17 = ptradd v4, v12 * 4
  store v16, v17 align 2
  v18 = mul.i32 v14, v10
  v19 = ptradd v3, v12 * 4
  store v18, v19 align 2
  v20 = ptradd v2, v12 * 4
  store v11, v20 align 2
  v21 = add.i64 v12, v6
  jmp b1(v21)
b3:
  v22 = slotaddr s3
  store v4, v22 align 3
  store v0, v22+8 align 3
  v23 = call.i64 @take(v2, v3, v22, v1) : (ptr, ptr, ptr, i64) -> i64
  jmp b4(v5, v23)
b4(v24: i64, v25: i64):
  v26 = icmp.ult v24, v7
  br v26, b5, b6
b5:
  v27 = ptradd v2, v24 * 4
  v28 = load.i32 v27 align 2
  v29 = sext.i64 v28
  v30 = mul.i64 v25, v7
  v31 = add.i64 v30, v29
  v32 = add.i64 v24, v6
  jmp b4(v32, v31)
b6:
  ret v25
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let t = text_of(&a, "take");
    assert(t.contains("reduce_or") && t.contains("vinsert.1.v2i32") && t.contains("store v"), t.as_str());
    let lens: [u64; 6] = [0, 1, 7, 8, 33, 64];
    let bounds: [u64; 4] = [64, 40, 1, 0];
    for k in 0..6usize {
        for j in 0..4usize {
            let args: []u64 = [unsafe lens[k], unsafe bounds[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A read-only view (`ref p1 0 inner readonly`, a `[]T` of a `T` without `UnsafeCell`) keeps its elements
// unchanged during the call: a loop that loads through it and stores through any other pointer
// vectorizes without a guard on the two ranges. Without the flag the guard stays.
@test
fn a_read_only_view_needs_no_overlap_guard() {
    let src = M"(lir ptr 8
sym @addto fn global noinline
sym @plain fn global noinline
fn @addto
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, l0, i64) -> void
  ref p1 0 inner readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = load.ptr v1 align 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v5, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = ptradd v0, v6 * 4
  v11 = load.i32 v10 align 2
  v12 = add.i32 v11, v9
  store v12, v10 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @plain
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (ptr, l0, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = load.ptr v1 align 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v5, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = ptradd v0, v6 * 4
  v11 = load.i32 v10 align 2
  v12 = add.i32 v11, v9
  store v12, v10 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
)";
    let (_, a) = optimized(src, VECTOR);
    let t = text_of(&a, "addto");
    assert(t.contains("add.v4i32") && !t.contains("icmp.ule"), t.as_str());
    let p = text_of(&a, "plain");
    assert(p.contains("add.v4i32") && p.contains("icmp.ule"), p.as_str());
}

// An early exit from a loop whose header passes its test's value to the exit block (`while j < n &&
// s[j] == b' '`, then `j < n && s[j] == b'['`): the vector loop leaves to the scalar loop, which leaves
// the loop with its own values. Each start and length runs as before.
@test
fn an_early_exit_beside_a_header_exit_with_arguments() {
    let src = M"(lir ptr 8
sym @skip fn global noinline
sym @drive fn global
fn @skip
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i64) -> i8
  ref p0 0 inner readonly
b0(v0: ptr, v1: i64):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = iconst.i8 32
  v5 = iconst.i8 91
  v6 = iconst.i64 1
  jmp b1(v1)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b5(v8)
b2:
  v9 = ptradd v2, v7 * 1
  v10 = load.i8 v9 align 0
  v11 = icmp.eq v10, v4
  br v11, b3, b4
b3:
  v12 = add.i64 v7, v6
  jmp b1(v12)
b4:
  v13 = icmp.eq v10, v5
  jmp b5(v13)
b5(v14: i8):
  ret v14
fn @drive
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (i64, i64) -> i64
  slot s0 size 128 align 3
  slot s1 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 100
  v7 = iconst.i8 32
  v8 = iconst.i8 91
  jmp b1(v4)
b1(v9: i64):
  v10 = icmp.ult v9, v6
  br v10, b2, b3
b2:
  v11 = ptradd v2, v9 * 1
  store v7, v11 align 0
  v12 = add.i64 v9, v5
  jmp b1(v12)
b3:
  v13 = ptradd v2, v1 * 1
  store v8, v13 align 0
  store v2, v3 align 3
  store v0, v3+8 align 3
  v14 = iconst.i64 3
  v15 = call.i8 @skip(v3, v14) : (l0, i64) -> i8
  v16 = zext.i64 v15
  ret v16
)";
    let (b, a) = optimized(src, VECTOR);
    let t = text_of(&a, "skip");
    assert(t.contains("reduce_and"), t.as_str());
    let lens: [u64; 5] = [0, 3, 17, 70, 99];
    let at: [u64; 4] = [3, 20, 69, 98];
    for k in 0..5usize {
        for j in 0..4usize {
            let args: []u64 = [unsafe lens[k], unsafe at[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// Two stores of constants to adjacent bytes merge into one twice as wide, which is untagged: its bytes
// hold two values of the narrower type, and a tag names the stored type alone (the verifier checks it).
@test
fn adjacent_constant_stores_merge_untagged() {
    let src = M"(lir ptr 8
sym @reset fn global noinline
fn @reset
  sig (ptr) -> void
  ref p0 56 noalias
b0(v0: ptr):
  v1 = iconst.i32 0
  store v1, v0+32 align 2 tbaa 3
  store v1, v0+36 align 2 tbaa 3
  store v1, v0+40 align 2 tbaa 3
  ret
)";
    let (_, a) = optimized(src, NO_LOOPS);
    let t = text_of(&a, "reset");
    assert(count(&t, "store") == 2 && t.contains("iconst.i64 0"), t.as_str());
}

// Two data symbols the package defines are two objects, and a slot whose address only addresses
// accesses (private) is reached by no other pointer: a loop between such accesses vectorizes without an
// overlap guard. Two unknown pointers keep it.
@test
fn data_symbols_and_private_slots_need_no_overlap_guard() {
    let src = M"(lir ptr 8
sym @src data global
sym @dst data global
sym @copy fn global noinline
sym @fill fn global noinline
sym @plain fn global noinline
sym @drive fn global
data @src size 256 align 3
data @dst size 256 align 3
fn @copy
  sig (i64) -> void
b0(v0: i64):
  v1 = symaddr @src
  v2 = symaddr @dst
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v0
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = ptradd v2, v5 * 4
  store v8, v9 align 2
  v10 = add.i64 v5, v4
  jmp b1(v10)
b3:
  ret
fn @fill
  sig (ptr, i64) -> i32
  slot s0 size 256 align 2
b0(v0: ptr, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = ptradd v2, v5 * 4
  store v8, v9 align 2
  v10 = add.i64 v5, v4
  jmp b1(v10)
b3:
  v11 = load.i32 v2+4 align 2
  ret v11
fn @plain
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = ptradd v1, v5 * 4
  store v8, v9 align 2
  v10 = add.i64 v5, v4
  jmp b1(v10)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 2
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 64
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v4
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = trunc.i32 v5
  store v8, v7 align 2
  v9 = add.i64 v5, v3
  jmp b1(v9)
b3:
  v10 = call.i32 @fill(v1, v0) : (ptr, i64) -> i32
  v11 = zext.i64 v10
  ret v11
)";
    let (b, a) = optimized(src, VECTOR);
    let c = text_of(&a, "copy");
    assert(c.contains("v4i32") && !c.contains("icmp.ule"), c.as_str());
    let f = text_of(&a, "fill");
    assert(f.contains("v4i32") && !f.contains("icmp.ule"), f.as_str());
    let p = text_of(&a, "plain");
    assert(p.contains("v4i32") && p.contains("icmp.ule"), p.as_str());
    let ns: [u64; 3] = [2, 17, 64];
    for k in 0..3usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, 1, false);
    }
}

// An `@owned` pointer field (`owned p0 <offset>`) of an exclusive parameter's referent: the buffer it
// points to is its own class, apart from another owned field's, so a loop between the two buffers
// vectorizes without an overlap guard. Not when the parameter goes to a call, which could reach the field
// another way, nor when the body stores the field. Through a read-only parameter, the buffer is read-only:
// apart from a store through any other pointer.
@test
fn owned_buffers_need_no_overlap_guard() {
    let body = M"(
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.ptr v0+8 align 3
  v4 = load.i64 v0+16 align 3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  jmp b1(v5)
b1(v7: i64):
  v8 = icmp.ult v7, v4
  br v8, b2, b3
b2:
  v9 = ptradd v3, v7 * 8
  v10 = load.i64 v9 align 3
  v11 = add.i64 v10, v6
  v12 = ptradd v2, v7 * 8
  store v11, v12 align 3
  v13 = add.i64 v7, v6
  jmp b1(v13)
b3:
)";
    let mut src = String::from_str(
        M"(lir ptr 8
sym @own fn global noinline
sym @called fn global noinline
sym @stored fn global noinline
sym @plain fn global noinline
sym @shared fn global noinline
sym @look fn global noinline
fn @look
  sig (ptr) -> void
b0(v0: ptr):
  ret
fn @own
  sig (ptr, ptr) -> void
  ref p0 24 noalias
  owned p0 0
  owned p0 8)",
    );
    src.push_str(body);
    src.push_str(M"(  ret
fn @called
  sig (ptr, ptr) -> void
  ref p0 24 noalias
  owned p0 0
  owned p0 8)");
    src.push_str(body);
    src.push_str(
        M"(  call @look(v0) : (ptr) -> void
  ret
fn @stored
  sig (ptr, ptr) -> void
  ref p0 24 noalias
  owned p0 0
  owned p0 8)",
    );
    src.push_str(body);
    src.push_str(M"(  store v3, v0 align 3
  ret
fn @plain
  sig (ptr, ptr) -> void
  ref p0 24 noalias)");
    src.push_str(body);
    src.push_str(
        M"(  ret
fn @shared
  sig (ptr, ptr) -> void
  ref p0 24 readonly
  owned p0 8
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0+8 align 3
  v3 = load.i64 v0+16 align 3
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v2, v6 * 8
  v9 = load.i64 v8 align 3
  v10 = ptradd v1, v6 * 8
  store v9, v10 align 3
  v11 = add.i64 v6, v5
  jmp b1(v11)
b3:
  ret
)",
    );
    let (_, a) = optimized(&src, VECTOR);
    let names: [str; 2] = ["own", "shared"];
    for k in 0..2usize {
        let t = text_of(&a, unsafe names[k]);
        assert(t.contains("v2i64") && !t.contains("icmp.ule"), t.as_str());
    }
    let kept: [str; 3] = ["called", "stored", "plain"];
    for k in 0..3usize {
        let t = text_of(&a, unsafe kept[k]);
        assert(t.contains("v2i64") && t.contains("icmp.ule"), t.as_str());
    }
}

// A loop whose counter starts at a constant and shifts right (`x.pow(5)`'s square and multiply) runs a
// count of iterations its evaluation gives: fully unrolled, no loop is left.
@test
fn a_counter_that_shifts_right_unrolls_fully() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @pow5 fn global
fn @pow5
  sig (i32) -> i32
b0(v0: i32):
  v1 = iconst.i32 5
  v2 = iconst.i32 1
  jmp b1(v1, v2, v0)
b1(v3: i32, v4: i32, v5: i32):
  v6 = and.i32 v3, v2
  v7 = icmp.eq v6, v2
  v8 = mul.i32 v4, v5
  v9 = select.i32 v7, v8, v4
  v10 = lshr.i32 v3, v2
  v11 = mul.i32 v5, v5
  v12 = icmp.ugt v10, v2
  br v12, b1(v10, v9, v11), b2
b2:
  v13 = mul.i32 v9, v11
  ret v13
)",
        PEEL,
    );
    let t = text_of(&a, "pow5");
    assert(!t.contains("br ") && !t.contains("jmp ") && count(&t, "mul.") == 3, t.as_str());
    let xs: [u64; 4] = [0, 1, 3, 7];
    for i in 0..4 {
        let x: []u64 = [xs[i]];
        let want = xs[i] * xs[i] * xs[i] * xs[i] * xs[i];
        same_outcome(&b, &a, "pow5", x, want, false);
    }
}

// A vectorized maximum (a select of the lane or the accumulator by their comparison) is the lanes'
// maximum (`vop.max.s`) where every vector operation is in registers; elsewhere the select stays.
@test
fn a_vectorized_maximum_takes_the_lanes_maximum() {
    let src = M"(lir ptr 8
sym @top fn global noinline
sym @drive fn global
fn @top
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 -2147483648
  jmp b1(v2, v4)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.sgt v9, v6
  v11 = select.i32 v10, v9, v6
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b3:
  ret v6
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 128
  v5 = iconst.i32 -7919
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v4
  br v7, b2, b3
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v5
  v10 = ptradd v1, v6 * 4
  store v9, v10 align 2
  v11 = add.i64 v6, v3
  jmp b1(v11)
b3:
  v12 = call.i32 @top(v1, v0) : (ptr, i64) -> i32
  v13 = sext.i64 v12
  ret v13
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let t = text_of(&a, "top");
    assert(t.contains("vop.max.s.v4i32") && !t.contains("vsel"), t.as_str());
    let (_, n) = optimized_for(src, VECTOR, 16, VOPS_SOME);
    let u = text_of(&n, "top");
    assert(!u.contains("vop.max.s.v4i32"), u.as_str());
    let lens: [u64; 4] = [0, 5, 37, 128];
    for k in 0..4usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}
