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
    let (b, a) = optimized(src.as_str(), PEEL);
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
                "  ref p2 256 noalias\n";
            } else {
                "";
            },
            body,
            drive,
        );
        let mut err = String::new();
        let q = lparse::parse(src.as_str(), &mut err);
        assert(q.is_some(), err.as_str());
        let b = q.unwrap();
        let mut a = lparse::parse(src.as_str(), &mut err).unwrap();
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
    return b, a;
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
    assert(d.contains("icmp.sge v1, v4"), d.as_str());
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
                e.run(b.find_symbol(names[f]), one);
            } else {
                e.run(b.find_symbol(names[f]), x);
            };
            if o.kind != leval::EV_OK {
                continue;
            }
            same_outcome(
                &b,
                &a,
                names[f],
                if use_one {
                    one;
                } else {
                    x;
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
    let names: []str = ["xor", "geo", "mem"];
    for f in 0..names.len() {
        let t = text_of(&a, names[f]);
        assert(t.contains("br "), t.as_str());
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
