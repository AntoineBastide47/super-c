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
    return optimized_fma(text, bu, false);
}

// `optimized` for a processor with a fused multiply-add when `fma` (`Package.fma`).
fn optimized_fma(text: str, bu: lu::Budgets, fma: bool) (Package, Package) {
    return optimized_fm(text, bu, fma, 0);
}

// `optimized_fma` with the float rewrites `fm` (`FM_*`, `Package.fmath`) allowed.
fn optimized_fm(text: str, bu: lu::Budgets, fma: bool, fm: u8) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.fma = fma;
    after.fmath = fm;
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
const fn count(text: &String, pat: str) u32 {
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

const NO_LOOPS: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 0,
};
const PEEL: lu::Budgets = lu::Budgets {
    peel: 200,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 0,
};
const VERSION: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 200,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 0,
};
const UNSWITCH: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 50,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 0,
};
const ROTATE: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 8,
    vector: 0,
    interleave: 0,
    fin: 0,
};
const VECTOR: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 2,
    interleave: 2,
    fin: 0,
};
const PARTIAL: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 32,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 0,
};

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
        lu::Budgets {
            peel: 40,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
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

// `i <u len` checks on the counter of a loop that runs while `i <u n` hold wherever `i <u min(n, len)`:
// a loop that sums gets a copy without them that runs to that bound (a select of the two), then the loop
// with the checks at its end where `len <u n`, whose check fails there: its back edge is unreachable.
// With `n` past `len` it panics as before, after the same iterations.
@test
fn bounds_checks_clip_a_reduction() {
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
    assert(
        t.contains("select.i64") && t.contains("unreachable") && !t.contains("icmp.ule") && count(&t, "panic") == 1,
        t.as_str(),
    );
    let fits: []u64 = [5, 10];
    same_outcome(&b, &a, "sum", fits, 10, false);
    let exact: []u64 = [5, 5];
    same_outcome(&b, &a, "sum", exact, 10, false);
    let past: []u64 = [5, 3];
    same_outcome(&b, &a, "sum", past, 0, true);
    let none: []u64 = [0, 0];
    same_outcome(&b, &a, "sum", none, 0, false);
}

// A value of the loop that only the failure path reads (a panic message's slot) leaves through the
// normal exit too once the loop is closed, but no final value replaces it there: no round spins on that
// change the walk takes back, and the checks clip the loop. A loop entered where a guard `n <=u
// len` holds is no versioned copy with checks: its signed counter's checks version too.
@test
fn values_only_a_failure_path_reads_leave_the_checks_to_versioning() {
    let src = M"(lir ptr 8
sym @report fn global noinline
sym @sum fn global
sym @signed fn global
fn @report
  sig (ptr) -> void
b0(v0: ptr):
  panic "index out of bounds"
fn @sum
  sig (i64, i64) -> i64
  slot s0 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 7
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b5
b2:
  v8 = slotaddr s0
  v9 = icmp.ult v5, v1
  br v9, b3, b4
b3:
  v10 = xor.i64 v6, v5
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b4: cold
  store v4, v8 align 3
  call @report(v8) : (ptr) -> void
  unreachable
b5:
  ret v6
fn @signed
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ule v0, v1
  br v4, b1, b6
b1:
  jmp b2(v2, v2)
b2(v5: i64, v6: i64):
  v7 = icmp.slt v5, v0
  br v7, b3, b5
b3:
  v8 = icmp.ult v5, v1
  br v8, b4, b7
b4:
  v9 = add.i64 v6, v5
  v10 = add.i64 v5, v3
  jmp b2(v10, v9)
b5:
  ret v6
b6:
  ret v2
b7: cold
  panic "index out of bounds"
)";
    let bu = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 200,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 0,
        interleave: 0,
        fin: 200,
    };
    let (b, a) = optimized(src, bu);
    let t = text_of(&a, "sum");
    assert(t.contains("select.i64") && count(&t, "call @report") == 1, t.as_str());
    let fits: []u64 = [5, 10];
    same_outcome(&b, &a, "sum", fits, 4, false);
    let past: []u64 = [5, 3];
    same_outcome(&b, &a, "sum", past, 0, true);
    let none: []u64 = [0, 0];
    same_outcome(&b, &a, "sum", none, 0, false);
    let s = text_of(&a, "signed");
    assert(!s.contains("panic"), s.as_str());
    let inside: []u64 = [5, 10];
    same_outcome(&b, &a, "signed", inside, 10, false);
    let outside: []u64 = [10, 5];
    same_outcome(&b, &a, "signed", outside, 0, false);
}

// A check of `i - 1 <u len` of a counter from 1 by 1 versions under `n <=u len + 1` (every `i` is at least
// 1); one of a counter from 0 does not (its first `i - 1` wraps); one of `(i + c) - 1`, `c` from before
// the loop, versions as `i + (c - 1)`, wrapping or not: with the checked copy, or (where the walk first
// makes the sum `i + (c - 1)` in the loop) clipped to the iteration that fails, both with a block the
// guard makes unlikely. Each panics or sums as before.
@test
fn checks_of_a_counter_less_a_constant_version() {
    let src = M"(lir ptr 8
sym @neg fn global
sym @zero fn global
sym @base fn global
fn @neg
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  jmp b1(v2, v3)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v0
  br v6, b2, b5
b2:
  v7 = sub.i64 v4, v2
  v8 = icmp.ult v7, v1
  br v8, b3, b4
b3:
  v9 = add.i64 v5, v7
  v10 = add.i64 v4, v2
  jmp b1(v10, v9)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
fn @zero
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 0
  jmp b1(v3, v3)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v0
  br v6, b2, b5
b2:
  v7 = sub.i64 v4, v2
  v8 = icmp.ult v7, v1
  br v8, b3, b4
b3:
  v9 = add.i64 v5, v4
  v10 = add.i64 v4, v2
  jmp b1(v10, v9)
b4: cold
  panic "index out of bounds"
b5:
  ret v5
fn @base
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  jmp b1(v4, v4)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b5
b2:
  v8 = add.i64 v2, v5
  v9 = sub.i64 v8, v3
  v10 = icmp.ult v9, v1
  br v10, b3, b4
b3:
  v11 = add.i64 v6, v5
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b4: cold
  panic "index out of bounds"
b5:
  ret v6
)";
    let (b, a) = optimized(src, VERSION);
    assert(text_of(&a, "neg").contains("novec"), text_of(&a, "neg").as_str());
    assert(!text_of(&a, "zero").contains("novec"), text_of(&a, "zero").as_str());
    assert(text_of(&a, "base").contains("unlikely"), text_of(&a, "base").as_str());
    let fits: []u64 = [6, 5];
    same_outcome(&b, &a, "neg", fits, 10, false);
    let past: []u64 = [7, 5];
    same_outcome(&b, &a, "neg", past, 0, true);
    let none: []u64 = [0, 0];
    same_outcome(&b, &a, "neg", none, 0, false);
    let first: []u64 = [3, 10];
    same_outcome(&b, &a, "zero", first, 0, true);
    let inside: []u64 = [4, 10, 3];
    same_outcome(&b, &a, "base", inside, 6, false);
    let over: []u64 = [5, 6, 3];
    same_outcome(&b, &a, "base", over, 0, true);
    let wraps: []u64 = [4, 10, 0];
    same_outcome(&b, &a, "base", wraps, 0, true);
    let low: []u64 = [4, 10, 1];
    same_outcome(&b, &a, "base", low, 6, false);
}

// A check of `i + c`, `c` from before the loop, of a counter from 3 versions, and from 0 it versions as
// the loop clipped to the iteration that fails. From 3, with `c` past `len` (`c` wraps: -3), `i + c` is
// below `len` again: the loop runs to its end as before, the clip would have taken its first iteration
// for one that fails. So would it for `i + 5` from -2, which wraps to 3. Under a constant exit bound
// (16) no `i + 1` wraps: from any start, the loop is clipped.
@test
fn checks_of_a_counter_plus_a_value_clip_only_where_no_sum_wraps() {
    let src = M"(lir ptr 8
sym @three fn global
sym @zero fn global
sym @far fn global
sym @bound fn global
fn @three
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 3
  v5 = iconst.i64 0
  jmp b1(v4, v5)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b5
b2:
  v9 = add.i64 v6, v2
  v10 = icmp.ult v9, v1
  br v10, b3, b4
b3:
  v11 = add.i64 v7, v9
  v12 = add.i64 v6, v3
  jmp b1(v12, v11)
b4: cold
  panic "index out of bounds"
b5:
  ret v7
fn @zero
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 1
  v4 = iconst.i64 0
  jmp b1(v4, v4)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b5
b2:
  v8 = add.i64 v5, v2
  v9 = icmp.ult v8, v1
  br v9, b3, b4
b3:
  v10 = add.i64 v6, v8
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b4: cold
  panic "index out of bounds"
b5:
  ret v6
fn @far
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 -2
  v4 = iconst.i64 5
  v5 = iconst.i64 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b5
b2:
  v9 = add.i64 v6, v4
  v10 = icmp.ult v9, v1
  br v10, b3, b4
b3:
  v11 = add.i64 v7, v9
  v12 = add.i64 v6, v2
  jmp b1(v12, v11)
b4: cold
  panic "index out of bounds"
b5:
  ret v7
fn @bound
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 16
  v4 = iconst.i64 0
  jmp b1(v0, v4)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v3
  br v7, b2, b5
b2:
  v8 = add.i64 v5, v2
  v9 = icmp.ult v8, v1
  br v9, b3, b4
b3:
  v10 = add.i64 v6, v8
  jmp b1(v8, v10)
b4: cold
  panic "index out of bounds"
b5:
  ret v6
)";
    let (b, a) = optimized(src, VERSION);
    assert(text_of(&a, "bound").contains("unreachable"), text_of(&a, "bound").as_str());
    let room: []u64 = [3, 17];
    same_outcome(&b, &a, "bound", room, 130, false);
    let short: []u64 = [3, 16];
    same_outcome(&b, &a, "bound", short, 0, true);
    let none: []u64 = [20, 5];
    same_outcome(&b, &a, "bound", none, 0, false);
    let early: []u64 = [0, 10];
    same_outcome(&b, &a, "bound", early, 0, true);
    let far: []u64 = [18446744073709551615, 10];
    same_outcome(&b, &a, "far", far, 3, false);
    assert(text_of(&a, "three").contains("novec"), text_of(&a, "three").as_str());
    assert(text_of(&a, "zero").contains("unreachable"), text_of(&a, "zero").as_str());
    let wraps: []u64 = [60, 64, 18446744073709551613];
    same_outcome(&b, &a, "three", wraps, 1596, false);
    let past: []u64 = [70, 64, 18446744073709551613];
    same_outcome(&b, &a, "three", past, 0, true);
    let fits: []u64 = [50, 64, 10];
    same_outcome(&b, &a, "three", fits, 1692, false);
    let over: []u64 = [60, 64, 10];
    same_outcome(&b, &a, "three", over, 0, true);
    let first: []u64 = [5, 3, 18446744073709551615];
    same_outcome(&b, &a, "zero", first, 0, true);
    let inside: []u64 = [3, 10, 2];
    same_outcome(&b, &a, "zero", inside, 9, false);
    let ends: []u64 = [4, 5, 2];
    same_outcome(&b, &a, "zero", ends, 0, true);
}

// A check of an index its form bounds, whatever the counter (`capped`), versions on that bound below
// `len`: `(i * x) & 15` on `15 <u len`, `i & m` on `m <u len`, `i % m` on `m <=u len`, `i % 10` divided by
// its multiplier on `9 <u len`, also under a `!=` exit test with no check of the counter. A multiplier
// that is not the quotient's keeps its checks. Where the guard fails the loop with the checks runs: it
// panics at an index past `len` only.
@test
fn checks_of_an_index_its_form_bounds_version() {
    let src = M"(lir ptr 8
sym @mask fn global
sym @inv fn global
sym @rem fn global
sym @div fn global
sym @wrong fn global
sym @ne fn global
fn @mask
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v5
  v15 = add.i64 v14, v3
  v16 = add.i64 v15, v3
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @inv
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = add.i64 v10, v3
  v14 = add.i64 v13, v3
  v15 = add.i64 v14, v3
  v16 = and.i64 v15, v2
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @rem
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = add.i64 v10, v3
  v14 = add.i64 v13, v3
  v15 = add.i64 v14, v3
  v16 = urem.i64 v15, v2
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @div
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mulhu.i64 v10, v7
  v14 = lshr.i64 v13, v8
  v15 = mul.i64 v14, v6
  v16 = sub.i64 v10, v15
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @wrong
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mulhu.i64 v10, v9
  v14 = lshr.i64 v13, v8
  v15 = mul.i64 v14, v6
  v16 = sub.i64 v10, v15
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @ne
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 10
  v7 = iconst.i64 -3689348814741910323
  v8 = iconst.i64 3
  v9 = iconst.i64 -3689348814741910528
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ne v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v5
  v15 = add.i64 v14, v3
  v16 = add.i64 v15, v3
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
)";
    let (b, a) = optimized(src, VERSION);
    for f in ["mask", "inv", "rem", "div", "ne"] {
        let t = text_of(&a, f);
        assert(t.contains("novec"), t.as_str());
    }
    let w = text_of(&a, "wrong");
    assert(!w.contains("novec"), w.as_str());
    // (len, n, x).
    let fits: []u64 = [16, 40, 7];
    same_outcome(&b, &a, "mask", fits, run_value(&b, "mask", fits), false);
    let short: []u64 = [15, 40, 7];
    same_outcome(&b, &a, "mask", short, 0, true);
    let zero: []u64 = [15, 40, 0];
    same_outcome(&b, &a, "mask", zero, 0, false);
    let below: []u64 = [8, 20, 7];
    same_outcome(&b, &a, "inv", below, run_value(&b, "inv", below), false);
    let at: []u64 = [8, 20, 8];
    same_outcome(&b, &a, "inv", at, 0, true);
    let top: []u64 = [5, 3, 0xFFFF_FFFF_FFFF_FFFF];
    same_outcome(&b, &a, "inv", top, 3, false);
    let whole: []u64 = [5, 20, 5];
    same_outcome(&b, &a, "rem", whole, 40, false);
    let past: []u64 = [5, 20, 6];
    same_outcome(&b, &a, "rem", past, 0, true);
    let few: []u64 = [5, 4, 6];
    same_outcome(&b, &a, "rem", few, 6, false);
    let ten: []u64 = [10, 25, 0];
    same_outcome(&b, &a, "div", ten, 100, false);
    let nine: []u64 = [9, 25, 0];
    same_outcome(&b, &a, "div", nine, 0, true);
    // Its remainder of 10 is 10.
    same_outcome(&b, &a, "wrong", ten, 0, true);
    same_outcome(&b, &a, "ne", fits, run_value(&b, "ne", fits), false);
    same_outcome(&b, &a, "ne", short, 0, true);
}

// With `version_checks` 1 (`-O2`) a loop with one bounds check versions and a loop with two keeps both,
// also two into one failure block (one test against the least of the lengths); with no limit (`-O3`) all
// version. Each sums or panics as before.
@test
fn versioning_takes_loops_of_at_most_its_number_of_checks() {
    let src = M"(lir ptr 8
sym @one fn global
sym @two fn global
sym @merged fn global
fn @one
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = icmp.ult v4, v1
  br v6, b2, b4
b2:
  v7 = icmp.ult v4, v0
  br v7, b3, b5
b3:
  v8 = add.i64 v5, v4
  v9 = add.i64 v4, v3
  jmp b1(v9, v8)
b4:
  ret v5
b5: cold
  panic "index out of bounds"
fn @two
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b5
b2:
  v8 = icmp.ult v5, v0
  br v8, b3, b6
b3:
  v9 = icmp.ult v5, v2
  br v9, b4, b7
b4:
  v10 = add.i64 v6, v5
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b5:
  ret v6
b6: cold
  panic "index out of bounds"
b7: cold
  panic "second index out of bounds"
fn @merged
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b5
b2:
  v8 = icmp.ult v5, v0
  br v8, b3, b6
b3:
  v9 = icmp.ult v5, v2
  br v9, b4, b6
b4:
  v10 = add.i64 v6, v5
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b5:
  ret v6
b6: cold
  panic "index out of bounds"
)";
    // A loop that versions (or clips) differs from the one no versioning budget leaves.
    let mut bu = VERSION;
    bu.version_checks = 1;
    let (b, a) = optimized(src, bu);
    let mut off = VERSION;
    off.version = 0;
    let (_, none) = optimized(src, off);
    let (_, all) = optimized(src, VERSION);
    let o = text_of(&a, "one");
    assert(o.as_str() != text_of(&none, "one").as_str(), o.as_str());
    let t = text_of(&a, "two");
    assert(t.as_str() == text_of(&none, "two").as_str(), t.as_str());
    let t2 = text_of(&all, "two");
    assert(t2.as_str() != text_of(&none, "two").as_str(), t2.as_str());
    // Two checks into one failure block, one test against the least of the lengths (`bound_min`, made
    // before the loop): two checks.
    let m = text_of(&a, "merged");
    assert(m.as_str() == text_of(&none, "merged").as_str(), m.as_str());
    let m2 = text_of(&all, "merged");
    assert(m2.as_str() != text_of(&none, "merged").as_str(), m2.as_str());
    let fits: []u64 = [5, 5];
    same_outcome(&b, &a, "one", fits, 10, false);
    let past: []u64 = [4, 5];
    same_outcome(&b, &a, "one", past, 0, true);
    let both: []u64 = [5, 5, 6];
    same_outcome(&b, &a, "two", both, 10, false);
    let second: []u64 = [6, 5, 4];
    same_outcome(&b, &a, "two", second, 0, true);
    same_outcome(&b, &all, "merged", both, 10, false);
    same_outcome(&b, &all, "merged", second, 0, true);
}

// The remainder by 7 divided with the multiplier one bit wider (`(n - h) >> 1 + h`), the remainder by 10
// of a 32-bit value through its 64-bit product, and `i % m` with `m` from the loop at most 15 (`(y & 15) |
// 1`) bound the index: their checks version. A 64-bit value shifted by 1 bounds it only past 2^32: its
// checks stay; one of 16 bits shifted by 7 bounds it at 511, `(y & 2) | 1` at 3, `14 % m` below `m`. Each
// sums or panics as before.
@test
fn checks_of_a_remainder_or_shift_its_form_bounds_version() {
    let src = M"(lir ptr 8
sym @seven fn global
sym @narrow fn global
sym @inner fn global
sym @wide fn global
sym @low fn global
sym @orr fn global
sym @top fn global
fn @seven
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mulhu.i64 v10, v7
  v14 = sub.i64 v10, v13
  v15 = lshr.i64 v14, v4
  v16 = add.i64 v15, v13
  v17 = lshr.i64 v16, v8
  v18 = mul.i64 v17, v6
  v19 = sub.i64 v10, v18
  v20 = icmp.ult v19, v0
  br v20, b3, b4
b3:
  v21 = add.i64 v11, v19
  v22 = add.i64 v10, v4
  jmp b1(v22, v21)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @narrow
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3435973837
  v6 = iconst.i64 35
  v7 = iconst.i32 10
  jmp b1(v3, v3)
b1(v8: i64, v9: i64):
  v10 = icmp.ult v8, v1
  br v10, b2, b5
b2:
  v11 = trunc.i32 v8
  v12 = zext.i64 v11
  v13 = mul.i64 v12, v5
  v14 = lshr.i64 v13, v6
  v15 = trunc.i32 v14
  v16 = mul.i32 v15, v7
  v17 = sub.i32 v11, v16
  v18 = zext.i64 v17
  v19 = icmp.ult v18, v0
  br v19, b3, b4
b3:
  v20 = add.i64 v9, v18
  v21 = add.i64 v8, v4
  jmp b1(v21, v20)
b4: cold
  panic "index out of bounds"
b5:
  ret v9
fn @inner
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v5
  v15 = or.i64 v14, v4
  v16 = urem.i64 v10, v15
  v17 = icmp.ult v16, v0
  br v17, b3, b4
b3:
  v18 = add.i64 v11, v16
  v19 = add.i64 v10, v4
  jmp b1(v19, v18)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @wide
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = lshr.i64 v13, v4
  v15 = icmp.ult v14, v0
  br v15, b3, b4
b3:
  v16 = add.i64 v11, v14
  v17 = add.i64 v10, v4
  jmp b1(v17, v16)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @low
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v9
  v15 = lshr.i64 v14, v6
  v16 = icmp.ult v15, v0
  br v16, b3, b4
b3:
  v17 = add.i64 v11, v15
  v18 = add.i64 v10, v4
  jmp b1(v18, v17)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @orr
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v8
  v15 = or.i64 v14, v4
  v16 = icmp.ult v15, v0
  br v16, b3, b4
b3:
  v17 = add.i64 v11, v15
  v18 = add.i64 v10, v4
  jmp b1(v18, v17)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
fn @top
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 15
  v6 = iconst.i64 7
  v7 = iconst.i64 2635249153387078803
  v8 = iconst.i64 2
  v9 = iconst.i64 65535
  jmp b1(v3, v3)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v1
  br v12, b2, b5
b2:
  v13 = mul.i64 v10, v2
  v14 = and.i64 v13, v5
  v15 = or.i64 v14, v4
  v16 = add.i64 v6, v6
  v17 = urem.i64 v16, v15
  v18 = icmp.ult v17, v0
  br v18, b3, b4
b3:
  v19 = add.i64 v11, v17
  v20 = add.i64 v10, v4
  jmp b1(v20, v19)
b4: cold
  panic "index out of bounds"
b5:
  ret v11
)";
    let (b, a) = optimized(src, VERSION);
    for f in ["seven", "narrow", "inner", "low", "orr", "top"] {
        let t = text_of(&a, f);
        assert(t.contains("novec"), t.as_str());
    }
    let w = text_of(&a, "wide");
    assert(!w.contains("novec"), w.as_str());
    // (len, n, x).
    let seven: []u64 = [7, 30, 0];
    same_outcome(&b, &a, "seven", seven, run_value(&b, "seven", seven), false);
    let six: []u64 = [6, 30, 0];
    same_outcome(&b, &a, "seven", six, 0, true);
    let ten: []u64 = [10, 25, 0];
    same_outcome(&b, &a, "narrow", ten, 100, false);
    let nine: []u64 = [9, 25, 0];
    same_outcome(&b, &a, "narrow", nine, 0, true);
    let fifteen: []u64 = [15, 40, 3];
    same_outcome(&b, &a, "inner", fifteen, run_value(&b, "inner", fifteen), false);
    let few: []u64 = [3, 40, 3];
    same_outcome(&b, &a, "inner", few, 0, true);
    let small: []u64 = [512, 40, 1700];
    same_outcome(&b, &a, "low", small, run_value(&b, "low", small), false);
    let short: []u64 = [400, 40, 1700];
    same_outcome(&b, &a, "low", short, 0, true);
    let two: []u64 = [512, 2, 1000];
    same_outcome(&b, &a, "wide", two, 500, false);
    same_outcome(&b, &a, "wide", small, 0, true);
    // `(i * x & 2) | 1` reaches 3, past both operands' bounds.
    let four: []u64 = [4, 10, 1];
    same_outcome(&b, &a, "orr", four, run_value(&b, "orr", four), false);
    let three: []u64 = [3, 10, 1];
    same_outcome(&b, &a, "orr", three, 0, true);
    // `14 % m` is 14 where `m` is 15.
    let whole: []u64 = [15, 40, 3];
    same_outcome(&b, &a, "top", whole, run_value(&b, "top", whole), false);
    let fourteen: []u64 = [14, 40, 3];
    same_outcome(&b, &a, "top", fourteen, 0, true);
}

// A rotated loop (the zero-trip test before it, the exit test `i + 1 <u n` at the latch) whose header's
// branch is the check `i <u len` versions on `n <= len` and a start below `n` (the first iteration runs
// before any test): the header's branch is no exit test. It panics or sums as before.
@test
fn a_rotated_loop_whose_header_is_a_check_versions() {
    let src = M"(lir ptr 8
sym @rot fn global
sym @start fn global
fn @rot
  sig (i64, i64) -> i64
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = icmp.ne v1, v2
  br v4, b1(v2, v2), b4(v2)
b1(v5: i64, v6: i64):
  v7 = icmp.uge v5, v0
  br v7, b3, b2
b2:
  v8 = add.i64 v6, v5
  v9 = add.i64 v5, v3
  v10 = icmp.ult v9, v1
  br v10, b1(v9, v8), b4(v8)
b3: cold
  panic "index out of bounds"
b4(v11: i64):
  ret v11
fn @start
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v2, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.uge v5, v0
  br v7, b3, b2
b2:
  v8 = add.i64 v6, v5
  v9 = add.i64 v5, v4
  v10 = icmp.ult v9, v1
  br v10, b1(v9, v8), b4(v8)
b3: cold
  panic "index out of bounds"
b4(v11: i64):
  ret v11
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "rot");
    assert(t.contains("novec") && count(&t, "panic") == 1, t.as_str());
    // (len, n).
    let fits: []u64 = [5, 5];
    same_outcome(&b, &a, "rot", fits, 10, false);
    let short: []u64 = [9, 4];
    same_outcome(&b, &a, "rot", short, 6, false);
    let past: []u64 = [4, 6];
    same_outcome(&b, &a, "rot", past, 0, true);
    let none: []u64 = [0, 0];
    same_outcome(&b, &a, "rot", none, 0, false);
    let st = text_of(&a, "start");
    assert(st.contains("novec"), st.as_str());
    // (len, n, start): a start at or past `n` runs one iteration.
    let from: []u64 = [6, 5, 2];
    same_outcome(&b, &a, "start", from, 9, false);
    let late: []u64 = [6, 5, 7];
    same_outcome(&b, &a, "start", late, 0, true);
    let once: []u64 = [8, 5, 7];
    same_outcome(&b, &a, "start", once, 7, false);
}

// A check of `i - c <u len`, `c` from before the loop, of a counter from `s` by 1 versions under `c <=u s`
// and `n <=u len + c` (the type's greatest value where the sum wraps). Each panics or sums as before.
@test
fn checks_of_a_counter_less_a_value_version() {
    let src = M"(lir ptr 8
sym @val fn global
fn @val
  sig (i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64):
  v4 = iconst.i64 1
  v5 = iconst.i64 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b5
b2:
  v9 = sub.i64 v6, v2
  v10 = icmp.ult v9, v1
  br v10, b3, b4
b3:
  v11 = add.i64 v7, v9
  v12 = add.i64 v6, v4
  jmp b1(v12, v11)
b4: cold
  panic "index out of bounds"
b5:
  ret v7
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "val");
    assert(t.contains("novec") && count(&t, "panic") == 1, t.as_str());
    let fits: []u64 = [7, 5, 2, 2];
    same_outcome(&b, &a, "val", fits, 10, false);
    let late: []u64 = [7, 5, 2, 4];
    same_outcome(&b, &a, "val", late, 9, false);
    let early: []u64 = [7, 5, 2, 1];
    same_outcome(&b, &a, "val", early, 0, true);
    let past: []u64 = [8, 5, 2, 2];
    same_outcome(&b, &a, "val", past, 0, true);
    let top: []u64 = [0xFFFF_FFFF_FFFF_FFFF, 5, 0xFFFF_FFFF_FFFF_FFFD, 0xFFFF_FFFF_FFFF_FFFD];
    same_outcome(&b, &a, "val", top, 1, false);
    let short: []u64 = [0xFFFF_FFFF_FFFF_FFFF, 1, 0xFFFF_FFFF_FFFF_FFFD, 0xFFFF_FFFF_FFFF_FFFD];
    same_outcome(&b, &a, "val", short, 0, true);
    let none: []u64 = [0, 0, 3, 0];
    same_outcome(&b, &a, "val", none, 0, false);
}

// A check of `i * w + c <u len`, `w` and `c` from before the loop, versions under `(n - 1) * w + c <u len`
// with the product and the sum checked. A last index at the length, a product or a sum that wraps
// panic as before.
@test
fn checks_of_a_counter_times_a_value_version() {
    let src = M"(lir ptr 8
sym @col fn global
fn @col
  sig (i64, i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64, v3: i64):
  v4 = iconst.i64 1
  v5 = iconst.i64 0
  jmp b1(v5, v5)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v3
  br v8, b2, b5
b2:
  v9 = mul.i64 v6, v1
  v10 = add.i64 v9, v2
  v11 = icmp.ult v10, v0
  br v11, b3, b4
b3:
  v12 = add.i64 v7, v10
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b4: cold
  panic "index out of bounds"
b5:
  ret v7
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "col");
    assert(t.contains("novec") && t.contains("mulo") && count(&t, "panic") == 1, t.as_str());
    // (len, w, c, n).
    let top: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    let fits: []u64 = [20, 3, 2, 6];
    same_outcome(&b, &a, "col", fits, 57, false);
    let zero: []u64 = [3, 0, 2, 1000];
    same_outcome(&b, &a, "col", zero, 2000, false);
    let none: []u64 = [0, 3, 2, 0];
    same_outcome(&b, &a, "col", none, 0, false);
    let last: []u64 = [17, 3, 2, 6];
    same_outcome(&b, &a, "col", last, 0, true);
    let product: []u64 = [10, 0x8000_0000_0000_0000, 0, 3];
    same_outcome(&b, &a, "col", product, 0, true);
    let sum: []u64 = [10, 1, top - 1, 3];
    same_outcome(&b, &a, "col", sum, 0, true);
}

// The checks of `i + c <u len`, `c` from before the loop, clip a loop that sums at `len > c ? len - c :
// 0`: past it `i + c` is `len`, or `c` past `len` from the start, and the check fails.
@test
fn offset_checks_clip_a_reduction() {
    let src = M"(lir ptr 8
sym @sum fn global
fn @sum
  sig (i64, i64, i64) -> i64
b0(v0: i64, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b5
b2:
  v8 = add.i64 v5, v2
  v9 = icmp.ult v8, v1
  br v9, b3, b4
b3:
  v10 = add.i64 v6, v8
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b4: cold
  panic "index out of bounds"
b5:
  ret v6
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "sum");
    assert(t.contains("unreachable") && count(&t, "panic") == 1, t.as_str());
    let fits: []u64 = [5, 10, 3];
    same_outcome(&b, &a, "sum", fits, 25, false);
    let exact: []u64 = [5, 8, 3];
    same_outcome(&b, &a, "sum", exact, 25, false);
    let past: []u64 = [5, 7, 3];
    same_outcome(&b, &a, "sum", past, 0, true);
    let before: []u64 = [5, 2, 3];
    same_outcome(&b, &a, "sum", before, 0, true);
    let none: []u64 = [0, 0, 9];
    same_outcome(&b, &a, "sum", none, 0, false);
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

// A loop while `i + 4 <=u a && i + 4 <=u b`, by steps of 4, whose range checks of `s[i..i + 4]` branch
// twice into one failure block (`i >u len`, then `len - i <u 4`): the copy without them runs where the
// least bound is at most `len` and at most the type's maximum less a step. Past the maximum `i + 4` wraps
// to a small value, the test holds and the second check fails: the loop with the checks runs and panics.
@test
fn range_checks_under_an_offset_test_version_the_loop() {
    let src = M"(lir ptr 8
sym @sum fn global
fn @sum
  sig (i8, i8, i8) -> i8
b0(v0: i8, v1: i8, v2: i8):
  v3 = iconst.i8 0
  v4 = iconst.i8 4
  jmp b1(v3, v3)
b1(v5: i8, v6: i8):
  v7 = add.i8 v5, v4
  v8 = icmp.ule v7, v0
  v9 = icmp.ule v7, v1
  v10 = and.i8 v8, v9
  br v10, b2, b6
b2:
  v11 = icmp.ugt v5, v2
  br v11, b5, b3
b3:
  v12 = sub.i8 v2, v5
  v13 = icmp.ult v12, v4
  br v13, b5, b4
b4:
  v14 = add.i8 v6, v5
  jmp b1(v7, v14)
b5: cold
  panic "index out of bounds"
b6:
  ret v6
)";
    let (b, a) = optimized(src, VERSION);
    let t = text_of(&a, "sum");
    assert(count(&t, "sub.i8") == 1 && count(&t, "panic") == 1 && t.contains("iconst.i8 -5"), t.as_str());
    let fits: [[u64; 3]; 4] = [[40, 60, 50], [100, 30, 30], [0, 9, 0], [251, 251, 251]];
    for k in 0..4usize {
        let args: []u64 = [unsafe fits[k][0], unsafe fits[k][1], unsafe fits[k][2]];
        same_outcome(&b, &a, "sum", args, run_value(&b, "sum", args), false);
    }
    let past: [[u64; 3]; 3] = [[60, 60, 50], [30, 100, 27], [255, 255, 255]];
    for k in 0..3usize {
        let args: []u64 = [unsafe past[k][0], unsafe past[k][1], unsafe past[k][2]];
        same_outcome(&b, &a, "sum", args, 0, true);
    }
}

// An exit test of two comparisons of one value from outside the loop (no counter plus a constant) is no
// offset test: the loop stays as it is.
@test
fn an_exit_test_of_an_outside_value_is_no_offset_test() {
    let src = M"(lir ptr 8
sym @inv fn global
fn @inv
  sig (i8, i8, i8, i8) -> i8
b0(v0: i8, v1: i8, v2: i8, v3: i8):
  v4 = iconst.i8 0
  v5 = iconst.i8 1
  jmp b1(v4, v4)
b1(v6: i8, v7: i8):
  v8 = icmp.ult v0, v1
  v9 = icmp.ult v0, v2
  v10 = and.i8 v8, v9
  br v10, b2, b3(v7)
b2:
  v11 = add.i8 v7, v6
  v12 = add.i8 v6, v5
  v13 = icmp.eq v12, v3
  br v13, b3(v11), b1(v12, v11)
b3(v14: i8):
  ret v14
)";
    let (b, a) = optimized(src, VERSION);
    let cases: [[u64; 4]; 3] = [[1, 5, 6, 4], [7, 5, 9, 4], [0, 1, 1, 10]];
    for k in 0..3usize {
        let args: []u64 = [unsafe cases[k][0], unsafe cases[k][1], unsafe cases[k][2], unsafe cases[k][3]];
        same_outcome(&b, &a, "inv", args, run_value(&b, "inv", args), false);
    }
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
    // The input tests v1 once inside its one loop; unswitched, it tests v1 once before two copies of the
    // loop, each with its own exit test and only its own side.
    let test = t.find("br v1,");
    assert(count(&t, "br v1,") == 1 && test >= 0 && test < t.find("icmp.ult"), t.as_str());
    assert(count(&t, "icmp.ult") == 2 && count(&t, "udiv.i64") == 1, t.as_str());
    let plus: []u64 = [4, 1];
    same_outcome(&b, &a, "mix", plus, 6, false);
    let minus: []u64 = [4, 0];
    same_outcome(&b, &a, "mix", minus, 0x3FFFFFFFFFFFFFF, false);
}

// The sides of a branch on a value the loop does not change whose instructions differ in form (an
// addition, a call) do not merge, and their operands are read by the form of each: the call's signature
// and arguments, past the body's last instruction in its pool (the long call before the loop), are no
// values.
@test
fn sides_of_different_forms_stay_apart() {
    let mut params = String::new();
    let mut types = String::new();
    let mut args = String::new();
    for q in 0..40 {
        params.format_into(
            "{}v{}: i64",
            if q == 0 {
                ""
            } else {
                ", "
            },
            q,
        );
        types.push_str(
            if q == 0 {
                "i64"
            } else {
                ", i64"
            },
        );
        args.push_str(
            if q == 0 {
                "v3"
            } else {
                ", v3"
            },
        );
    }
    let src = format(
        M"(lir ptr 8
sym @mark fn global noinline
sym @next fn global noinline
sym @mix fn global
fn @mark
  sig ({}) -> void
b0({}):
  ret
fn @next
  sig (i64) -> i64
b0(v0: i64):
  v1 = mul.i64 v0, v0
  ret v1
fn @mix
  sig (i64, i64, i8) -> i64
b0(v0: i64, v1: i64, v2: i8):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  call @mark({}) : ({}) -> void
  jmp b1(v3, v0)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b6
b2:
  br v2, b3, b4
b3:
  v8 = add.i64 v6, v4
  jmp b5(v8)
b4:
  v9 = call.i64 @next(v6) : (i64) -> i64
  jmp b5(v9)
b5(v10: i64):
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b6:
  ret v6
)",
        types.as_str(),
        params.as_str(),
        args.as_str(),
        types.as_str(),
    );
    let (b, a) = optimized(&src, UNSWITCH);
    let plus: []u64 = [5, 3, 1];
    same_outcome(&b, &a, "mix", plus, 8, false);
    let squares: []u64 = [2, 2, 0];
    same_outcome(&b, &a, "mix", squares, 16, false);
}

// The sides of a branch on a value the loop does not change that differ in one constant take one side
// over the select of the constants before the loop: `bump` adds 3 or subtracts 3 from each element (each
// side loads the array's address), `scale` multiplies by 3 or 5. Neither branch is left.
@test
fn sides_that_differ_in_a_constant_merge() {
    let src = M"(lir ptr 8
sym @bump fn global
sym @scale fn global
sym @drive fn global
fn @bump
  sig (ptr, i64, i8) -> void
b0(v0: ptr, v1: i64, v2: i8):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b6
b2:
  br v2, b3, b4
b3:
  v8 = load.ptr v0 align 3
  v9 = ptradd v8, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = add.i32 v10, v5
  store v11, v9 align 2
  jmp b5
b4:
  v12 = load.ptr v0 align 3
  v13 = ptradd v12, v6 * 4
  v14 = load.i32 v13 align 2
  v15 = sub.i32 v14, v5
  store v15, v13 align 2
  jmp b5
b5:
  v16 = add.i64 v6, v4
  jmp b1(v16)
b6:
  ret
fn @scale
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 3
  v5 = iconst.i64 5
  jmp b1(v2, v3)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b6
b2:
  br v1, b3, b4
b3:
  v9 = mul.i64 v7, v4
  jmp b5(v9)
b4:
  v10 = mul.i64 v7, v5
  jmp b5(v10)
b5(v11: i64):
  v12 = add.i64 v6, v3
  jmp b1(v12, v11)
b6:
  ret v7
fn @drive
  sig (i64, i8) -> i64
  slot s0 size 256 align 3
  slot s1 size 8 align 3
b0(v0: i64, v1: i8):
  v2 = slotaddr s0
  v3 = slotaddr s1
  store v2, v3 align 3
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 64
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b3
b2:
  v9 = ptradd v2, v7 * 4
  v10 = trunc.i32 v7
  store v10, v9 align 2
  v11 = add.i64 v7, v5
  jmp b1(v11)
b3:
  call @bump(v3, v0, v1) : (ptr, i64, i8) -> void
  jmp b4(v4, v4)
b4(v12: i64, v13: i64):
  v14 = icmp.ult v12, v6
  br v14, b5, b6
b5:
  v15 = ptradd v2, v12 * 4
  v16 = load.i32 v15 align 2
  v17 = sext.i64 v16
  v18 = mul.i64 v17, v12
  v19 = add.i64 v13, v18
  v20 = add.i64 v12, v5
  jmp b4(v20, v19)
b6:
  ret v13
)";
    let (b, a) = optimized(src, UNSWITCH);
    let u = text_of(&a, "bump");
    assert(!u.contains("br v2,") && u.contains("select.i32"), u.as_str());
    let s = text_of(&a, "scale");
    assert(!s.contains("br v1,") && s.contains("select.i64"), s.as_str());
    let up: []u64 = [4, 1];
    same_outcome(&b, &a, "scale", up, 81, false);
    let down: []u64 = [4, 0];
    same_outcome(&b, &a, "scale", down, 625, false);
    let lens: [u64; 3] = [0, 5, 64];
    for k in 0..3usize {
        for f in 0..2u64 {
            let args: []u64 = [unsafe lens[k], f];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
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
    // The latch branches back; the exit passes the sum the back edge passes too, so it keeps it on the branch
    // (`split_exits` gives it no block).
    assert(count(&t, "icmp.ne v0") == 1 && count(&t, "icmp.ult") == 1 && count(&t, "jmp") == 0, t.as_str());
    let none: []u64 = [0];
    same_outcome(&b, &a, "sum", none, 0, false);
    let four: []u64 = [4];
    same_outcome(&b, &a, "sum", four, 6, false);
    let q = text_of(&a, "squares");
    // The test before the loop folds its `0 * 0`; the body takes the square as a parameter.
    assert(
        count(&q, "icmp.ne v0") == 1 && count(&q, "icmp.ult") == 1 && count(&q, "mul.i64") == 1 && count(&q, "jmp") == 0,
        q.as_str(),
    );
    same_outcome(&b, &a, "squares", four, 14, false);
    let (b2, a2) = optimized(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 1,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
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
        lu::Budgets {
            peel: 0,
            partial: 5,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
    );
    let s = text_of(&small, "mix");
    assert_eq(count(&s, "mul.i32"), 1);
}

// A counted loop whose body ends in a second exit test, not a jump back, does not unroll partially (the
// copies would take the back edge's arguments from the branch): it keeps its one copy and its outcome.
@test
fn a_counted_loop_with_an_exit_at_its_end_does_not_unroll() {
    let text = M"(lir ptr 8
sym @scan fn global
fn @scan
  sig (i64, i64) -> i32
b0(v0: i64, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i32 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v2, v3)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v0
  br v8, b2, b3(v7)
b2:
  v9 = trunc.i32 v6
  v10 = xor.i32 v9, v7
  v11 = mul.i32 v10, v5
  v12 = add.i64 v6, v4
  v13 = icmp.ult v12, v1
  br v13, b1(v12, v11), b3(v11)
b3(v14: i32):
  ret v14
)";
    let (before, after) = optimized(text, PARTIAL);
    let s = text_of(&after, "scan");
    assert_eq(count(&s, "mul.i32"), 1);
    let ns: [u64; 5] = [0, 1, 4, 9, 13];
    for n in ns {
        for m in ns {
            let args: [u64; 2] = [n, m];
            let mut e = leval::Eval::new(&before);
            let want = e.run(before.find_symbol("scan"), args).value;
            same_outcome(&before, &after, "scan", args, want, false);
        }
    }
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

// A loop of quotients or remainders by a constant vectorizes: the lanes' high products (`mulhs`, `mulhu`)
// or, by a power of two, shifts; signed and unsigned, of 8, 16 and 32 bits, by positive and negative
// divisors. Each kernel's driver fills its input (the type's extremes, -1 and 0, then a sequence that
// covers both signs), runs it on the first `n` elements and sums them; the sums match the scalar loop's.
@test
fn a_loop_dividing_by_a_constant_vectorizes() {
    // (operation, lane bits, divisor, what the vector loop computes with)
    let cases: [(str, u32, i64, str); 11] = [
        ("sdiv", 32, 7, "mulhs.v4i32"),
        ("sdiv", 32, -7, "mulhs.v4i32"),
        ("srem", 32, -7, "mulhs.v4i32"),
        ("udiv", 32, 7, "mulhu.v4i32"),
        ("urem", 32, 10, "mulhu.v4i32"),
        ("sdiv", 32, 8, "ashr.v4i32"),
        ("sdiv", 16, -3, "mulhs.v8i16"),
        ("udiv", 16, 7, "mulhu.v8i16"),
        ("srem", 8, 5, "mulhs.v16i8"),
        ("udiv", 8, 3, "mulhu.v16i8"),
        ("sdiv", 8, 127, "mulhs.v16i8"),
    ];
    let mut src = String::from_str("lir ptr 8\n");
    let mut body = String::new();
    for c in 0..11usize {
        let (op, w, d, _) = unsafe cases[c];
        let eb = w / 8;
        let al = eb.trailing_zeros();
        src.push_str(format("sym @k{} fn global noinline\nsym @drive{} fn global\n", c, c).as_str());
        body.push_str(
            format(
                "fn @k{}\n  sig (ptr, ptr, i64) -> void\nb0(v0: ptr, v1: ptr, v2: i64):\n  v3 = iconst.i64 0\n  v4 = iconst.i64 1\n  v5 = iconst.i{} {}\n  jmp b1(v3)\nb1(v6: i64):\n  v7 = icmp.ult v6, v2\n  br v7, b2, b3\nb2:\n  v8 = ptradd v1, v6 * {}\n  v9 = load.i{} v8 align {}\n  v10 = {}.i{} v9, v5\n  v11 = ptradd v0, v6 * {}\n  store v10, v11 align {}\n  v12 = add.i64 v6, v4\n  jmp b1(v12)\nb3:\n  ret\n",
                c,
                w,
                d,
                eb,
                w,
                al,
                op,
                w,
                eb,
                al,
            ).as_str(),
        );
        // The driver: the extremes, -1 and 0 in elements 0 to 3, then `x * 0x9E3779B97F4A7C15 + seed`
        // truncated; the kernel on the first `n`; their sum, each zero-extended, times 31 each step.
        let lo = i64::MIN >> (64 - w) as i64;
        let hi = i64::MAX >> (64 - w) as i64;
        body.push_str(
            format(
                "fn @drive{}\n  sig (i64, i64) -> i64\n  slot s0 size 512 align 4\n  slot s1 size 512 align 4\nb0(v0: i64, v1: i64):\n  v2 = slotaddr s0\n  v3 = slotaddr s1\n  v4 = iconst.i64 0\n  v5 = iconst.i64 1\n  v6 = iconst.i64 128\n  v7 = iconst.i64 -7046029254386353131\n  v8 = iconst.i64 31\n  jmp b1(v4, v1)\nb1(v9: i64, v10: i64):\n  v11 = icmp.ult v9, v6\n  br v11, b2, b3\nb2:\n  v12 = mul.i64 v10, v7\n  v13 = add.i64 v12, v1\n  v14 = trunc.i{} v13\n  v15 = ptradd v2, v9 * {}\n  store v14, v15 align {}\n  v16 = add.i64 v9, v5\n  jmp b1(v16, v13)\nb3:\n  v17 = iconst.i{} {}\n  store v17, v2 align {}\n  v18 = iconst.i{} {}\n  store v18, v2+{} align {}\n  v19 = iconst.i{} -1\n  store v19, v2+{} align {}\n  v20 = iconst.i{} 0\n  store v20, v2+{} align {}\n  call @k{}(v3, v2, v0) : (ptr, ptr, i64) -> void\n  jmp b4(v4, v4)\nb4(v21: i64, v22: i64):\n  v23 = icmp.ult v21, v0\n  br v23, b5, b6\nb5:\n  v24 = ptradd v3, v21 * {}\n  v25 = load.i{} v24 align {}\n  v26 = zext.i64 v25\n  v27 = mul.i64 v22, v8\n  v28 = add.i64 v27, v26\n  v29 = add.i64 v21, v5\n  jmp b4(v29, v28)\nb6:\n  ret v22\n",
                c,
                w,
                eb,
                al,
                w,
                lo,
                al,
                w,
                hi,
                eb,
                al,
                w,
                2 * eb,
                al,
                w,
                3 * eb,
                al,
                c,
                eb,
                w,
                al,
            ).as_str(),
        );
    }
    src.push_str(&body);
    let (b, a) = optimized(&src, VECTOR);
    let lens: [u64; 6] = [0, 1, 4, 17, 33, 128];
    let seeds: [u64; 2] = [1, 0x5DEECE66D];
    for c in 0..11usize {
        let (_, _, _, want) = unsafe cases[c];
        let k = text_of(&a, format("k{}", c).as_str());
        assert(k.contains(want), k.as_str());
        for n in lens {
            for s in seeds {
                let args: []u64 = [n, s];
                let name = format("drive{}", c);
                same_outcome(&b, &a, &name, args, run_value(&b, &name, args), false);
            }
        }
    }
}

// A loop's calls of C's `roundf`, which rounds halfway away from zero, widen where the target rounds lanes
// (`Package.vround`): no lane operation, but the truncation of `x + copysign(0.5 - ulp, x)`
// (`ROUND_AWAY`); where the backend rounds halfway away from zero in one instruction
// (`Package.vround_away`), that lane operation (`round_even` with `.num`). On halves of both signs, the
// largest float below 0.5, the halves next to 2^23, -0.0 and a large value, both vector loops give what
// `round` does (the driver sums the results' bits times 31 each step, wrapping; 16 elements, so the scalar
// rest, which calls `roundf`, does not run).
@test
fn calls_of_round_widen_to_a_truncation() {
    let src = M"(lir ptr 8
sym @roundf fn global
sym @rd fn global noinline
sym @drive fn global
fn @rd
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v2)
b1(v4: i64):
  v5 = icmp.ult v4, v1
  br v5, b2, b3
b2:
  v6 = ptradd v0, v4 * 4
  v7 = load.f32 v6 align 2
  v8 = call.f32 @roundf(v7) : (f32) -> f32
  store v8, v6 align 2
  v9 = add.i64 v4, v3
  jmp b1(v9)
b3:
  ret
fn @drive
  sig () -> i64
  slot s0 size 64 align 4
b0:
  v0 = iconst.i64 16
  v1 = iconst.i64 0
  v2 = slotaddr s0
  v3 = iconst.i64 1
  v4 = iconst.i64 31
  v5 = fconst.f32 0x3f000000
  store v5, v2+0 align 2
  v6 = fconst.f32 0xbf000000
  store v6, v2+4 align 2
  v7 = fconst.f32 0x3fc00000
  store v7, v2+8 align 2
  v8 = fconst.f32 0xbfc00000
  store v8, v2+12 align 2
  v9 = fconst.f32 0x40200000
  store v9, v2+16 align 2
  v10 = fconst.f32 0x3effffff
  store v10, v2+20 align 2
  v11 = fconst.f32 0xbeffffff
  store v11, v2+24 align 2
  v12 = fconst.f32 0x4affffff
  store v12, v2+28 align 2
  v13 = fconst.f32 0x4b000000
  store v13, v2+32 align 2
  v14 = fconst.f32 0xc0200000
  store v14, v2+36 align 2
  v15 = fconst.f32 0x40600000
  store v15, v2+40 align 2
  v16 = fconst.f32 0x80000000
  store v16, v2+44 align 2
  v17 = fconst.f32 0x7149f2ca
  store v17, v2+48 align 2
  v18 = fconst.f32 0x3e800000
  store v18, v2+52 align 2
  v19 = fconst.f32 0xbf400000
  store v19, v2+56 align 2
  v20 = fconst.f32 0x40f00000
  store v20, v2+60 align 2
  call @rd(v2, v0) : (ptr, i64) -> void
  jmp b1(v1, v1)
b1(v21: i64, v22: i64):
  v23 = icmp.ult v21, v0
  br v23, b2, b3
b2:
  v24 = ptradd v2, v21 * 4
  v25 = load.i32 v24 align 2
  v26 = zext.i64 v25
  v27 = mul.i64 v22, v4
  v28 = add.i64 v27, v26
  v29 = add.i64 v21, v3
  jmp b1(v29, v28)
b3:
  ret v22
)";
    let (_, a) = optimized(src, VECTOR);
    let k = text_of(&a, "rd");
    assert(k.contains("vop.trunc.v4f32") && k.contains("fadd.v4f32"), k.as_str());
    let ins: [u32; 16] = [
        0x3f000000,
        0xbf000000,
        0x3fc00000,
        0xbfc00000,
        0x40200000,
        0x3effffff,
        0xbeffffff,
        0x4affffff,
        0x4b000000,
        0xc0200000,
        0x40600000,
        0x80000000,
        0x7149f2ca,
        0x3e800000,
        0xbf400000,
        0x40f00000,
    ];
    let mut want: u64 = 0;
    for x in ins {
        want = want.wrapping_mul(31).wrapping_add(f32::from_bits(x).round().to_bits());
    }
    let none: []u64 = [];
    assert_eq(run_value(&a, "drive", none), want);
    let mut err = String::new();
    let mut away = lparse::parse(src, &mut err).unwrap();
    away.vround_away = true;
    let kept = Vector::<bool>::new();
    lopt::optimize(&mut away, &kept, lopt::Config { inline: il::SPEED, loops: VECTOR });
    let ka = text_of(&away, "rd");
    assert(ka.contains("vop.round_even.num.v4f32") && !ka.contains("vop.trunc"), ka.as_str());
    assert_eq(run_value(&away, "drive", none), want);
}

// A float's bits as an integer of one size and back (C's `copysign`: the magnitude's bits, the sign's
// bit) are the vector register's bits: the loop vectorizes. A call of `copysign` or `copysignf` becomes
// those bits (`copysign_bits`), so its loop vectorizes too, and computes what the bits do. Each driver fills 128
// doubles, copies the sign of `-1.0` onto the first `n`, and sums their bits times 31 each step.
@test
fn a_loop_of_float_bits_vectorizes() {
    let src = M"(lir ptr 8
sym @copysign fn global
sym @copysignf fn global
sym @cf fn global
sym @k fn global noinline
sym @kc fn global noinline
sym @drive fn global
sym @drivec fn global
fn @k
  sig (ptr, i64, f64) -> void
b0(v0: ptr, v1: i64, v2: f64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 9223372036854775807
  v6 = iconst.i64 -9223372036854775808
  v7 = bitcast.i64 v2
  v8 = and.i64 v7, v6
  jmp b1(v3)
b1(v9: i64):
  v10 = icmp.ult v9, v1
  br v10, b2, b3
b2:
  v11 = ptradd v0, v9 * 8
  v12 = load.f64 v11 align 3
  v13 = bitcast.i64 v12
  v14 = and.i64 v13, v5
  v15 = or.i64 v14, v8
  v16 = bitcast.f64 v15
  store v16, v11 align 3
  v17 = add.i64 v9, v4
  jmp b1(v17)
b3:
  ret
fn @kc
  sig (ptr, i64, f64) -> void
b0(v0: ptr, v1: i64, v2: f64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 8
  v8 = load.f64 v7 align 3
  v9 = call.f64 @copysign(v8, v2) : (f64, f64) -> f64
  store v9, v7 align 3
  v10 = add.i64 v5, v4
  jmp b1(v10)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 1024 align 4
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i64 -7046029254386353131
  v7 = iconst.i64 31
  v8 = fconst.f64 0xbff0000000000000
  jmp b1(v3, v1)
b1(v9: i64, v10: i64):
  v11 = icmp.ult v9, v5
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v6
  v13 = add.i64 v12, v1
  v14 = ptradd v2, v9 * 8
  store v13, v14 align 3
  v15 = add.i64 v9, v4
  jmp b1(v15, v13)
b3:
  call @k(v2, v0, v8) : (ptr, i64, f64) -> void
  jmp b4(v3, v3)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v5
  br v18, b5, b6
b5:
  v19 = ptradd v2, v16 * 8
  v20 = load.i64 v19 align 3
  v21 = mul.i64 v17, v7
  v22 = add.i64 v21, v20
  v23 = add.i64 v16, v4
  jmp b4(v23, v22)
b6:
  ret v17
fn @cf
  sig (f32, f32) -> f32
b0(v0: f32, v1: f32):
  v2 = call.f32 @copysignf(v0, v1) : (f32, f32) -> f32
  ret v2
fn @drivec
  sig (i64, i64) -> i64
  slot s0 size 1024 align 4
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i64 -7046029254386353131
  v7 = iconst.i64 31
  v8 = fconst.f64 0xbff0000000000000
  jmp b1(v3, v1)
b1(v9: i64, v10: i64):
  v11 = icmp.ult v9, v5
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v6
  v13 = add.i64 v12, v1
  v14 = ptradd v2, v9 * 8
  store v13, v14 align 3
  v15 = add.i64 v9, v4
  jmp b1(v15, v13)
b3:
  call @kc(v2, v0, v8) : (ptr, i64, f64) -> void
  jmp b4(v3, v3)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v5
  br v18, b5, b6
b5:
  v19 = ptradd v2, v16 * 8
  v20 = load.i64 v19 align 3
  v21 = mul.i64 v17, v7
  v22 = add.i64 v21, v20
  v23 = add.i64 v16, v4
  jmp b4(v23, v22)
b6:
  ret v17
)";
    let (b, a) = optimized(src, VECTOR);
    for name in ["k", "kc"] {
        let k = text_of(&a, name);
        assert((k.contains("bitcast.v2i64") || k.contains("bitcast.v4i64")) && !k.contains("call"), k.as_str());
    }
    let lens: [u64; 5] = [0, 1, 5, 17, 128];
    for n in lens {
        let args: []u64 = [n, 0x5DEECE66D];
        let want = run_value(&b, "drive", args);
        same_outcome(&b, &a, "drive", args, want, false);
        assert_eq(run_value(&a, "drivec", args), want);
    }
    // `copysignf`: 1.5 with the sign of -0.0 is -1.5; -1.5 with the sign of 2.0 is 1.5.
    assert(!text_of(&a, "cf").contains("call"), text_of(&a, "cf").as_str());
    let neg: []u64 = [0x3FC00000, 0x80000000];
    let pos: []u64 = [0xBFC00000, 0x40000000];
    assert_eq(run_value(&a, "cf", neg) & 0xFFFFFFFF, 0xBFC00000);
    assert_eq(run_value(&a, "cf", pos) & 0xFFFFFFFF, 0x3FC00000);
}

// A loop of a 32-bit counter vectorizes where it indexes through its extension to 64 bits, which does not
// wrap in the loop: a zero extension under `i <s n` from 0 or under `i <u n`, a sign extension under
// `i <s n`. A sign extension under `i <u n` and a start below 0 keep the loop scalar. Each kernel adds 7 to
// the first `n` elements (the last adds the counter's truncated extension, the counter itself: its lanes);
// the drivers sum them.
@test
fn a_narrow_counter_indexes_through_its_extension() {
    // (start, comparison, extension, an extra use of the extension, vectorizes)
    let cases: [(i64, str, str, bool, bool); 6] = [
        (0, "slt", "zext", false, true),
        (0, "slt", "sext", false, true),
        (0, "ult", "zext", false, true),
        (0, "ult", "sext", false, false),
        (-4, "slt", "sext", false, false),
        (0, "slt", "zext", true, true),
    ];
    let mut src = String::from_str("lir ptr 8\n");
    let mut body = String::new();
    for c in 0..6usize {
        let (st, cmp, ext, extra, _) = unsafe cases[c];
        src.push_str(format("sym @n{} fn global noinline\nsym @dn{} fn global\n", c, c).as_str());
        // The stored value and the step: `v10` or `v11`, then the next value.
        let (val, sv, nx) = if extra {
            ("  v10 = trunc.i32 v7\n  v11 = add.i32 v9, v10\n", 11, 12)
        } else {
            ("  v10 = add.i32 v9, v4\n", 10, 11)
        };
        body.push_str(
            format(
                "fn @n{}\n  sig (ptr, i32) -> void\nb0(v0: ptr, v1: i32):\n  v2 = iconst.i32 {}\n  v3 = iconst.i32 1\n  v4 = iconst.i32 7\n  jmp b1(v2)\nb1(v5: i32):\n  v6 = icmp.{} v5, v1\n  br v6, b2, b3\nb2:\n  v7 = {}.i64 v5\n  v8 = ptradd v0, v7 * 4\n  v9 = load.i32 v8 align 2\n{}  store v{}, v8 align 2\n  v{} = add.i32 v5, v3\n  jmp b1(v{})\nb3:\n  ret\n",
                c,
                st,
                cmp,
                ext,
                val,
                sv,
                nx,
                nx,
            ).as_str(),
        );
        // The driver: 64 elements from 64 bytes into its slot (a start below 0 indexes back to the slot's
        // first), the kernel on `n` of them, their sum.
        body.push_str(
            format(
                "fn @dn{}\n  sig (i32) -> i64\n  slot s0 size 512 align 4\nb0(v0: i32):\n  v1 = slotaddr s0\n  v2 = ptradd v1+64\n  v3 = iconst.i64 0\n  v4 = iconst.i64 1\n  v5 = iconst.i64 112\n  jmp b1(v3)\nb1(v6: i64):\n  v7 = icmp.ult v6, v5\n  br v7, b2, b3\nb2:\n  v8 = ptradd v1, v6 * 4\n  v9 = trunc.i32 v6\n  store v9, v8 align 2\n  v10 = add.i64 v6, v4\n  jmp b1(v10)\nb3:\n  call @n{}(v2, v0) : (ptr, i32) -> void\n  jmp b4(v3, v3)\nb4(v11: i64, v12: i64):\n  v13 = icmp.ult v11, v5\n  br v13, b5, b6\nb5:\n  v14 = ptradd v1, v11 * 4\n  v15 = load.i32 v14 align 2\n  v16 = sext.i64 v15\n  v17 = mul.i64 v16, v11\n  v18 = add.i64 v12, v17\n  v19 = add.i64 v11, v4\n  jmp b4(v19, v18)\nb6:\n  ret v12\n",
                c,
                c,
            ).as_str(),
        );
    }
    src.push_str(&body);
    let (b, a) = optimized(&src, VECTOR);
    let ns: [u64; 5] = [0, 3, 8, 13, 64];
    for c in 0..6usize {
        let (_, _, _, _, vec) = unsafe cases[c];
        let k = text_of(&a, format("n{}", c).as_str());
        assert(k.contains("v4i32") == vec, k.as_str());
        for n in ns {
            let args: []u64 = [n];
            let name = format("dn{}", c);
            same_outcome(&b, &a, &name, args, run_value(&b, &name, args), false);
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

// Loads of every 2nd element vectorize: the vectors from the first field on, their even lanes (`vunzip`) and
// odd lanes (`vunzip.odd`), the two fields' loads one pair per copy, and the loop runs the last iteration,
// so no vector reads past the element it reads; the 2 interleaved copies (4 loads, 2 `vunzip` of each
// parity), whose 8 lanes leave too few for one vector at a time (`EPI_LANES`). A sum through
// indices a load gives (a gather) interleaves scalar copies.
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
    assert(
        count(&m, "vunzip.v4i32") == 2 && count(&m, "vunzip.odd.v4i32") == 2 && count(&m, "load.v4i32") == 4 && m.contains(
            "mul.v4i32",
        ),
        m.as_str(),
    );
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
    let jam = lu::Budgets {
        peel: 0,
        partial: 32,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
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

// Two allocations' blocks are two objects (`Classes.obj`): addresses stay in their objects, so a loop that
// reads one and stores into the other vectorizes without a guard on the two ranges, also when both
// blocks' addresses escape (stored where another pointer reaches them).
@test
fn two_allocations_need_no_overlap_guard() {
    let src = M"(lir ptr 8
sym @malloc fn global
sym @fresh fn global
sym @KEEP data global
fn @fresh
  sig (i64) -> i32
b0(v0: i64):
  v1 = iconst.i64 4
  v2 = mul.i64 v0, v1
  v3 = call.ptr @malloc(v2) : (i64) -> ptr
  v4 = call.ptr @malloc(v2) : (i64) -> ptr
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i32 3
  jmp b1(v5)
b1(v8: i64):
  v9 = icmp.ult v8, v0
  br v9, b2, b3(v5)
b2:
  v10 = ptradd v4, v8 * 4 inbounds
  v11 = trunc.i32 v8
  store v11, v10 align 2
  v12 = add.i64 v8, v6
  jmp b1(v12)
b3(v13: i64):
  v14 = icmp.ult v13, v0
  br v14, b4, b5
b4:
  v15 = ptradd v4, v13 * 4 inbounds
  v16 = load.i32 v15 align 2
  v17 = mul.i32 v16, v7
  v18 = ptradd v3, v13 * 4 inbounds
  v19 = load.i32 v18 align 2
  v20 = add.i32 v17, v19
  store v20, v18 align 2
  v21 = add.i64 v13, v6
  jmp b3(v21)
b5:
  v22 = ptradd v3+8 inbounds
  v23 = load.i32 v22 align 2
  v24 = symaddr @KEEP
  store v3, v24 align 3
  store v4, v24+8 align 3
  ret v23
data @KEEP size 16 align 3
)";
    let (b, a) = optimized(src, VECTOR);
    let g = text_of(&a, "fresh");
    assert(g.contains("mul.v4i32") && !g.contains("icmp.ule"), g.as_str());
    let args: []u64 = [40];
    let r = run_value(&b, "fresh", args);
    same_outcome(&b, &a, "fresh", args, r, false);
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

const FIN: lu::Budgets = lu::Budgets {
    peel: 0,
    partial: 0,
    version: 0,
    version_checks: u32::MAX,
    unswitch: 0,
    rotate: 0,
    vector: 0,
    interleave: 0,
    fin: 512,
};

// A loop whose final values are polynomials of the iteration goes: its body copied for iterations 0 to
// the degree, the copies' differences times the binomials of the trip count.
fn closed(text: str, name: str) (Package, Package) {
    let (b, a) = optimized(text, FIN);
    let t = text_of(&a, name);
    assert(!t.contains("br ") && !t.contains("jmp "), t.as_str());
    return (b, a);
}

// With 128-bit integers split into words (`Package.pairs`, as on the native targets), the closed form a
// sum takes in 128 bits after that split splits too: no 128-bit value is left. The product's cross term by
// the high word of `n - 1`, 0 unless `n` is 0, goes, and the halving joins the words: one product, its
// high half and shifts. Each result is the loop's.
@test
fn closed_forms_split_into_words() {
    let src = M"(lir ptr 8
sym @sum fn global
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
)";
    let mut err = String::new();
    let b = lparse::parse(src, &mut err).unwrap();
    let mut a = lparse::parse(src, &mut err).unwrap();
    a.pairs = true;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: FIN });
    let mut v = verify::Verifier::new();
    assert(v.check(&a, "sum", &a.bodies[a.syms[a.find_symbol("sum") as usize].def as usize]), v.err.as_str());
    let s = text_of(&a, "sum");
    assert(!s.contains("br ") && !s.contains("i128"), s.as_str());
    assert(s.contains("mulhu.i64") && s.find("mul.i64") == s.rfind("mul.i64"), s.as_str());
    let x0: []u64 = [0];
    same_outcome(&b, &a, "sum", x0, 0, false);
    let x1: []u64 = [1];
    same_outcome(&b, &a, "sum", x1, 0, false);
    let x2: []u64 = [10];
    same_outcome(&b, &a, "sum", x2, 45, false);
    let x3: []u64 = [100000];
    same_outcome(&b, &a, "sum", x3, 4999950000, false);
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
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 0,
            interleave: 0,
            fin: 0,
        },
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

// A counter whose constant bound is the type's greatest (or least) value: its last step reaches the
// bound exactly, and its interval is computed without passing it.
@test
fn a_counter_up_to_the_type_extremes_takes_its_closed_form() {
    let src = M"(lir ptr 8
sym @top fn global
sym @bottom fn global
fn @top
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 9223372036854775757
  v2 = iconst.i64 9223372036854775807
  v3 = iconst.i64 1
  jmp b1(v1, v0)
b1(v4: i64, v5: i64):
  v6 = icmp.slt v4, v2
  br v6, b2, b3
b2:
  v7 = add.i64 v5, v4
  v8 = add.i64 v4, v3
  jmp b1(v8, v7)
b3:
  ret v5
fn @bottom
  sig (i64) -> i64
b0(v0: i64):
  v1 = iconst.i64 -9223372036854775758
  v2 = iconst.i64 -9223372036854775808
  v3 = iconst.i64 1
  jmp b1(v1, v0)
b1(v4: i64, v5: i64):
  v6 = icmp.sgt v4, v2
  br v6, b2, b3
b2:
  v7 = add.i64 v5, v4
  v8 = sub.i64 v4, v3
  jmp b1(v8, v7)
b3:
  ret v5
)";
    let (b, a) = closed(src, "top");
    let (bb, ba) = closed(src, "bottom");
    let xs: []u64 = [0, 7, 0xFFFFFFFFFFFFFFFF];
    for k in 0..xs.len() {
        let x: []u64 = [xs[k]];
        let mut e = leval::Eval::new(&b);
        let want = e.run(b.find_symbol("top"), x).value;
        same_outcome(&b, &a, "top", x, want, false);
        let mut e2 = leval::Eval::new(&bb);
        let want2 = e2.run(bb.find_symbol("bottom"), x).value;
        same_outcome(&bb, &ba, "bottom", x, want2, false);
    }
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

// A body with a 64-bit product of two values, which no vector unit of the targets multiplies, runs `vector`
// scalar copies of itself, each instruction's copies together; a load of one place its stores keep apart
// from (the exclusive view's elements) is loaded once before them.
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
  v3 = iconst.i64 11
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
  v12 = mul.i64 v11, v11
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
// through a 32-bit counter (a power) takes twice the copies, the value's fourth power once per iteration
// of the four, squared twice before them; its counter feeds only its step and the exit test, so the copies'
// loop counts its steps left down to 0 (`counter_free`), where the factorial's compares its counter with
// the copies' end. The loop runs the rest.
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
    assert(count(&tp, "mul.i64") == 4 && tp.contains("mul.i64 v0, v0") && tp.contains("novec"), tp.as_str());
    assert(!tp.contains("icmp.ugt") && tf.contains("icmp.ugt"), tp.as_str());
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
    let p20: []u64 = [3, 20];
    let p17: []u64 = [2, 17];
    same_outcome(&b, &a, "pow", p20, 3486784401, false);
    same_outcome(&b, &a, "pow", p17, 131072, false);
}

// Package text `text` read, then optimized with loop budgets `bu` for a target whose accesses step their
// base (`Package.postinc`): each body verifies after.
fn optimized_stepping(text: str, bu: lu::Budgets) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.postinc = true;
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

// A loop over a slot's 4 elements of 16 bytes, its accesses at 0 and 8 of each apart (no pair): its pointer
// to the access at 8 steps, but its value past the last iteration, 72, would lie past the slot's 64 bytes
// (a constant address of a slot lies in it): the counter keeps its exit test. Each body verifies.
@test
fn a_stepped_pointer_leaves_no_slot() {
    let (b, a) = optimized_stepping(
        M"(lir ptr 8
sym @slotpair fn global
fn @slotpair
  sig (i64) -> i64
  slot s0 size 64 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 4
  store v0, v1 align 3
  store v0, v1+8 align 3
  store v0, v1+16 align 3
  store v0, v1+24 align 3
  store v0, v1+32 align 3
  store v0, v1+40 align 3
  store v0, v1+48 align 3
  store v0, v1+56 align 3
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = ptradd v1, v5 * 16
  v8 = load.i64 v7 align 3
  v9 = add.i64 v6, v8
  v10 = load.i64 v7+8 align 3
  v11 = add.i64 v9, v10
  v12 = add.i64 v5, v3
  v13 = icmp.ult v12, v4
  br v13, b1(v12, v11), b2
b2:
  ret v11
)",
        NO_LOOPS,
    );
    let t = text_of(&a, "slotpair");
    assert(t.contains("+16") && t.contains("icmp.ult"), t.as_str());
    let five: []u64 = [5];
    same_outcome(&b, &a, "slotpair", five, 40, false);
}

// A loop of one block whose counter indexes a base with one scale for two or more accesses carries a
// pointer to the last access or pair instead, stepped before the back edge: `pairs` (a pair of loads, a
// counter that only meets its bound, which the pointer's exit test then takes, and goes), `spread` (two
// accesses 16 bytes apart, a counter the sum reads, which stays), `down` (a counter that steps down, its
// exit test on the counter itself), `sum` (one load, a counter that only meets its bound: the pointer
// takes its exit test). `fill`'s one store, through a counter its value reads, keeps its indexed address.
@test
fn counted_addresses_become_stepped_pointers() {
    let src = M"(lir ptr 8
sym @fill fn global noinline
sym @pairs fn global noinline
sym @spread fn global noinline
sym @down fn global noinline
sym @sum fn global noinline
sym @drive fn global
fn @fill
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  br v3, b2, b1(v2)
b1(v4: i64):
  v5 = iconst.i64 7
  v6 = mul.i64 v4, v5
  v7 = iconst.i64 3
  v8 = add.i64 v6, v7
  v9 = ptradd v0, v4 * 8
  store v8, v9 align 3
  v10 = iconst.i64 1
  v11 = add.i64 v4, v10
  v12 = icmp.ult v11, v1
  br v12, b1(v11), b2
b2:
  ret
fn @pairs
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  br v3, b2(v2), b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = ptradd v0, v4 * 16
  v7 = load.i64 v6 align 3
  v8 = load.i64 v6+8 align 3
  v9 = mul.i64 v7, v8
  v10 = add.i64 v5, v9
  v11 = iconst.i64 1
  v12 = add.i64 v4, v11
  v13 = icmp.ne v12, v1
  br v13, b1(v12, v10), b2(v10)
b2(v14: i64):
  ret v14
fn @spread
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  br v3, b2(v2), b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = ptradd v0, v4 * 8
  v7 = load.i64 v6 align 3
  v8 = load.i64 v6+16 align 3
  v9 = sub.i64 v8, v7
  v10 = mul.i64 v9, v4
  v11 = add.i64 v5, v10
  v12 = iconst.i64 1
  v13 = add.i64 v4, v12
  v14 = icmp.ult v13, v1
  br v14, b1(v13, v11), b2(v11)
b2(v15: i64):
  ret v15
fn @down
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 1
  v3 = sub.i64 v1, v2
  v4 = iconst.i64 0
  jmp b1(v3, v4)
b1(v5: i64, v6: i64):
  v7 = ptradd v0, v5 * 16
  v8 = load.i64 v7 align 3
  v9 = load.i64 v7+8 align 3
  v10 = mul.i64 v8, v6
  v11 = add.i64 v10, v9
  v12 = sub.i64 v5, v2
  v13 = icmp.ne v5, v4
  br v13, b1(v12, v11), b2(v11)
b2(v14: i64):
  ret v14
fn @sum
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = icmp.eq v1, v2
  br v3, b2(v2), b1(v2, v2)
b1(v4: i64, v5: i64):
  v6 = ptradd v0, v4 * 8
  v7 = load.i64 v6 align 3
  v8 = add.i64 v5, v7
  v9 = iconst.i64 1
  v10 = add.i64 v4, v9
  v11 = icmp.ult v10, v1
  br v11, b1(v10, v8), b2(v8)
b2(v12: i64):
  ret v12
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 128
  call @fill(v1, v2) : (ptr, i64) -> void
  v3 = call.i64 @pairs(v1, v0) : (ptr, i64) -> i64
  v4 = call.i64 @spread(v1, v0) : (ptr, i64) -> i64
  v5 = call.i64 @down(v1, v0) : (ptr, i64) -> i64
  v6 = iconst.i64 3
  v7 = mul.i64 v4, v6
  v8 = add.i64 v3, v7
  v9 = iconst.i64 5
  v10 = mul.i64 v5, v9
  v11 = add.i64 v8, v10
  v12 = call.i64 @sum(v1, v0) : (ptr, i64) -> i64
  v13 = iconst.i64 7
  v14 = mul.i64 v12, v13
  v15 = add.i64 v11, v14
  ret v15
)";
    let (b, a) = optimized_stepping(src, NO_LOOPS);
    let tf = text_of(&a, "fill");
    let tp = text_of(&a, "pairs");
    let ts = text_of(&a, "spread");
    let td = text_of(&a, "down");
    // A loop parameter that is a pointer; the counters `pairs` dropped and `spread` kept.
    assert(!tf.contains("ptr):") && tf.contains(" * 8"), tf.as_str());
    assert(tp.contains("ptr):") && count(&tp, "add.i64") == 1 && tp.contains("+16\n"), tp.as_str());
    assert(ts.contains("ptr):") && count(&ts, "add.i64") == 2 && ts.contains("-16 align"), ts.as_str());
    assert(td.contains("ptr):") && td.contains("-16\n"), td.as_str());
    let tu = text_of(&a, "sum");
    assert(tu.contains("ptr):") && count(&tu, "add.i64") == 1 && tu.contains("+8\n"), tu.as_str());
    let ns: [u64; 5] = [1, 2, 5, 31, 63];
    for k in 0..5usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Package text `text` read, then optimized with loop budgets `bu` for a target of `vector`-byte registers
// that converts vectors and shifts their lanes as `vops` says (`Package.vops`): each body verifies after.
fn optimized_for(text: str, bu: lu::Budgets, vector: u32, vops: u8) (Package, Package) {
    return optimized_with(text, bu, vector, vops, 0);
}

// `optimized_for` with `accs` vector registers for a loop's reductions (`Package.vec_accs`).
fn optimized_with(text: str, bu: lu::Budgets, vector: u32, vops: u8, accs: u32) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.vector = vector;
    after.vops = vops;
    after.vec_accs = accs;
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
    let both = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 200,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
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

// A bounds check of a row's element `y * w + x` in the loop over `x` versions that loop on
// `w <= (len > y * w ? len - y * w : 0)`, and the copy without it vectorizes through the row's start; a
// row past the length, a product that wraps, and a count past the length panic as before.
@test
fn row_bounds_checks_version_the_inner_loop() {
    let src = M"(lir ptr 8
sym @rows fn global noinline
sym @drive fn global
fn @rows
  sig (ptr, i64, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 0
  jmp b1(v4, v6)
b1(v7: i64, v8: i32):
  v9 = icmp.ult v7, v3
  br v9, b2, b8
b2:
  v10 = mul.i64 v7, v2
  jmp b3(v4, v8)
b3(v11: i64, v12: i32):
  v13 = icmp.ult v11, v2
  br v13, b4, b7
b4:
  v14 = add.i64 v10, v11
  v15 = icmp.uge v14, v1
  br v15, b6, b5
b5:
  v16 = ptradd v0, v14 * 4
  v17 = load.i32 v16 align 2
  v18 = add.i32 v12, v17
  v19 = add.i64 v11, v5
  jmp b3(v19, v18)
b6: cold
  panic "index out of bounds"
b7:
  v20 = add.i64 v7, v5
  jmp b1(v20, v12)
b8:
  v21 = sext.i64 v8
  ret v21
fn @drive
  sig (i64, i64, i64) -> i64
  slot s0 size 256 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 64
  v7 = iconst.i32 7
  jmp b1(v4)
b1(v8: i64):
  v9 = icmp.ult v8, v6
  br v9, b2, b3
b2:
  v10 = trunc.i32 v8
  v11 = mul.i32 v10, v7
  v12 = ptradd v3, v8 * 4
  store v11, v12 align 2
  v13 = add.i64 v8, v5
  jmp b1(v13)
b3:
  v14 = call.i64 @rows(v3, v0, v1, v2) : (ptr, i64, i64, i64) -> i64
  ret v14
)";
    let both = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 200,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
    let (b, a) = optimized(src, both);
    let t = text_of(&a, "rows");
    assert(t.contains("load.v4i32") && count(&t, "panic") == 1, t.as_str());
    // (len, w, h): rows within the 64 elements, then a row past the length, a product that wraps to row 0,
    // and widths past it.
    let fits: [[u64; 3]; 5] = [[64, 8, 8], [64, 13, 4], [60, 30, 2], [64, 0, 9], [5, 64, 0]];
    for k in 0..5usize {
        let args: []u64 = [unsafe fits[k][0], unsafe fits[k][1], unsafe fits[k][2]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let past: [[u64; 3]; 4] = [[64, 13, 5], [59, 30, 2], [64, 0x8000000000000000, 2], [64, 65, 1]];
    for k in 0..4usize {
        let args: []u64 = [unsafe past[k][0], unsafe past[k][1], unsafe past[k][2]];
        same_outcome(&b, &a, "drive", args, 0, true);
    }
}

// A bounds check of `a[i - c]`, `c` from before the loop, versions on `c <=u start` and `n <=u len + c`;
// the copy without it steps through `a - c` (`split_base`) and vectorizes. A start below `c`, a count past
// the length and a length short of a sum that wraps panic as before.
@test
fn checks_less_a_value_version_and_vectorize() {
    let src = M"(lir ptr 8
sym @from fn global noinline
sym @drive fn global
fn @from
  sig (ptr, i64, i64, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64, v3: i64, v4: i64):
  v5 = iconst.i64 1
  v6 = iconst.i32 0
  jmp b1(v3, v6)
b1(v7: i64, v8: i32):
  v9 = icmp.ult v7, v4
  br v9, b2, b5
b2:
  v10 = sub.i64 v7, v2
  v11 = icmp.uge v10, v1
  br v11, b4, b3
b3:
  v12 = ptradd v0, v10 * 4
  v13 = load.i32 v12 align 2
  v14 = add.i32 v8, v13
  v15 = add.i64 v7, v5
  jmp b1(v15, v14)
b4: cold
  panic "index out of bounds"
b5:
  v16 = sext.i64 v8
  ret v16
fn @drive
  sig (i64, i64, i64, i64) -> i64
  slot s0 size 256 align 3
b0(v0: i64, v1: i64, v2: i64, v3: i64):
  v4 = slotaddr s0
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 64
  v8 = iconst.i32 7
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = trunc.i32 v9
  v12 = mul.i32 v11, v8
  v13 = ptradd v4, v9 * 4
  store v12, v13 align 2
  v14 = add.i64 v9, v6
  jmp b1(v14)
b3:
  v15 = call.i64 @from(v4, v0, v1, v2, v3) : (ptr, i64, i64, i64, i64) -> i64
  ret v15
)";
    let both = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 200,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
    let (b, a) = optimized(src, both);
    let t = text_of(&a, "from");
    assert(t.contains("load.v4i32") && count(&t, "panic") == 1, t.as_str());
    // (len, c, start, n).
    let top: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    let fits: [[u64; 4]; 5] = [
        [64, 3, 3, 67],
        [64, 0, 0, 64],
        [64, 5, 9, 40],
        [64, 5, 5, 5],
        [2, top - 2, top - 2, top],
    ];
    for k in 0..5usize {
        let args: []u64 = [unsafe fits[k][0], unsafe fits[k][1], unsafe fits[k][2], unsafe fits[k][3]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let past: [[u64; 4]; 3] = [[64, 3, 3, 68], [64, 5, 4, 40], [1, top - 2, top - 2, top]];
    for k in 0..3usize {
        let args: []u64 = [unsafe past[k][0], unsafe past[k][1], unsafe past[k][2], unsafe past[k][3]];
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

// The slot and symbol addresses an inlined check passes to its failure call leave the loop as constants
// do, so the loop of the check `i & 63 <u len` vectorizes; each count fails or ends as before.
@test
fn a_checks_failure_arguments_leave_its_loop() {
    let src = M"(lir ptr 8
sym @mix fn global noinline
sym @fail fn global noinline
sym @drive fn global
sym @MSG data global
fn @fail
  sig (ptr, ptr) -> void
b0(v0: ptr, v1: ptr):
  panic "index out of bounds"
fn @mix
  sig (ptr, ptr) -> void
  ref p0 4 inner noalias
  ref p1 4 inner readonly
  slot s0 size 16 align 3
  slot s1 size 16 align 3
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v1 align 3
  v5 = load.i64 v1+8 align 3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i64 63
  jmp b1(v6)
b1(v9: i64):
  v10 = icmp.ult v9, v3
  br v10, b2, b5
b2:
  v11 = and.i64 v9, v8
  v12 = slotaddr s0
  v13 = symaddr @MSG
  v14 = slotaddr s1
  v15 = icmp.uge v11, v5
  br v15, b4, b3
b3:
  v16 = ptradd v4, v11 * 4
  v17 = load.i32 v16 align 2
  v18 = ptradd v2, v9 * 4
  v19 = load.i32 v18 align 2
  v20 = add.i32 v19, v17
  store v20, v18 align 2
  v21 = add.i64 v9, v7
  jmp b1(v21)
b4: cold
  store v13, v12 align 3
  store v5, v12+8 align 3
  store v13, v14 align 3
  store v11, v14+8 align 3
  call @fail(v12, v14) : (ptr, ptr) -> void
  unreachable
b5:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i64 128
  jmp b1(v6)
b1(v9: i64):
  v10 = icmp.ult v9, v8
  br v10, b2, b3
b2:
  v11 = trunc.i32 v9
  v12 = ptradd v3, v9 * 4
  store v11, v12 align 2
  v13 = ptradd v2, v9 * 4
  v14 = mul.i32 v11, v11
  store v14, v13 align 2
  v15 = add.i64 v9, v7
  jmp b1(v15)
b3:
  store v2, v4 align 3
  store v1, v4+8 align 3
  store v3, v5 align 3
  store v0, v5+8 align 3
  call @mix(v5, v4) : (ptr, ptr) -> void
  jmp b4(v6, v6)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v8
  br v18, b5, b6
b5:
  v19 = ptradd v3, v16 * 4
  v20 = load.i32 v19 align 2
  v21 = sext.i64 v20
  v22 = mul.i64 v17, v8
  v23 = add.i64 v22, v21
  v24 = add.i64 v16, v7
  jmp b4(v24, v23)
b6:
  ret v17
data @MSG size 16 align 3
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let m = text_of(&a, "mix");
    assert(m.contains("vcmp.uge.v2i64") && m.contains("add.v2i32"), m.as_str());
    let ns: [u64; 6] = [0, 3, 37, 64, 100, 128];
    let lens: [u64; 3] = [40, 64, 128];
    for k in 0..6usize {
        for j in 0..3usize {
            let args: []u64 = [unsafe ns[k], unsafe lens[j]];
            let fails = unsafe ns[k] > unsafe lens[j] && unsafe lens[j] < 64;
            if fails {
                same_outcome(&b, &a, "drive", args, 0, true);
            } else {
                same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
            }
        }
    }
}

// A gather's bounds check is an early exit whose lanes past it load their index too: from a slice that a
// branch before the loop keeps at least as long as the bound (`counted_slice`, `guard_le`), so the loop
// vectorizes. Each count fails at the guard, at the gather or not at all as before.
@test
fn a_gather_loads_its_index_past_its_check_under_a_guard() {
    let src = M"(lir ptr 8
sym @vag fn global noinline
sym @drive fn global
fn @vag
  sig (ptr, ptr, ptr) -> void
  ref p0 4 inner noalias
  ref p1 4 inner readonly
  ref p2 4 inner readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.ptr v0 align 3
  v4 = load.i64 v0+8 align 3
  v5 = load.ptr v1 align 3
  v6 = load.i64 v1+8 align 3
  v7 = load.ptr v2 align 3
  v8 = load.i64 v2+8 align 3
  v9 = iconst.i64 0
  v10 = iconst.i64 1
  v11 = icmp.ule v4, v8
  br v11, b1, b6
b1:
  jmp b2(v9)
b2(v12: i64):
  v13 = icmp.ult v12, v4
  br v13, b3, b7
b3:
  v14 = ptradd v7, v12 * 4
  v15 = load.i32 v14 align 2
  v16 = zext.i64 v15
  v17 = icmp.uge v16, v6
  br v17, b5, b4
b4:
  v18 = ptradd v5, v16 * 4
  v19 = load.i32 v18 align 2
  v20 = ptradd v3, v12 * 4
  store v19, v20 align 2
  v21 = add.i64 v12, v10
  jmp b2(v21)
b5: cold
  panic "index out of bounds"
b6: cold
  panic "assertion failed"
b7:
  ret
fn @drive
  sig (i64, i64, i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 256 align 3
  slot s2 size 512 align 3
  slot s3 size 16 align 3
  slot s4 size 16 align 3
  slot s5 size 16 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  v4 = slotaddr s1
  v5 = slotaddr s2
  v6 = slotaddr s3
  v7 = slotaddr s4
  v8 = slotaddr s5
  v9 = iconst.i64 0
  v10 = iconst.i64 1
  v11 = iconst.i64 128
  v12 = iconst.i64 64
  v13 = iconst.i64 7
  v14 = iconst.i64 63
  jmp b1(v9)
b1(v15: i64):
  v16 = icmp.ult v15, v11
  br v16, b2, b3
b2:
  v17 = mul.i64 v15, v13
  v18 = and.i64 v17, v14
  v19 = trunc.i32 v18
  v20 = ptradd v5, v15 * 4
  store v19, v20 align 2
  v21 = and.i64 v15, v14
  v22 = mul.i64 v21, v21
  v23 = trunc.i32 v22
  v24 = ptradd v4, v21 * 4
  store v23, v24 align 2
  v25 = ptradd v3, v15 * 4
  store v19, v25 align 2
  v26 = add.i64 v15, v10
  jmp b1(v26)
b3:
  store v3, v6 align 3
  store v0, v6+8 align 3
  store v4, v7 align 3
  store v1, v7+8 align 3
  store v5, v8 align 3
  store v2, v8+8 align 3
  call @vag(v6, v7, v8) : (ptr, ptr, ptr) -> void
  jmp b4(v9, v9)
b4(v27: i64, v28: i64):
  v29 = icmp.ult v27, v11
  br v29, b5, b6
b5:
  v30 = ptradd v3, v27 * 4
  v31 = load.i32 v30 align 2
  v32 = sext.i64 v31
  v33 = mul.i64 v28, v11
  v34 = add.i64 v33, v32
  v35 = add.i64 v27, v10
  jmp b4(v35, v34)
b6:
  ret v28
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let g = text_of(&a, "vag");
    assert(g.contains("vcmp.uge.v2i64") && g.contains("vextract"), g.as_str());
    let ns: [u64; 6] = [0, 4, 5, 40, 100, 128];
    let slens: [u64; 3] = [30, 50, 64];
    let ilens: [u64; 2] = [90, 128];
    for k in 0..6usize {
        for j in 0..3usize {
            for q in 0..2usize {
                let n = unsafe ns[k];
                let args: []u64 = [n, unsafe slens[j], unsafe ilens[q]];
                let mut fails = n > unsafe ilens[q];
                for i in 0..n {
                    fails = fails || (i * 7 & 63) >= unsafe slens[j];
                }
                if fails {
                    same_outcome(&b, &a, "drive", args, 0, true);
                } else {
                    same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
                }
            }
        }
    }
}

// A side of a branch may load an element of the slice whose length the header's test counts to
// (`side_counted`): every iteration may read it, so the body runs as selects. Each count runs as before.
@test
fn a_side_loads_an_element_of_the_counted_slice() {
    let src = M"(lir ptr 8
sym @pick fn global noinline
sym @drive fn global
fn @pick
  sig (ptr, ptr, ptr) -> void
  ref p2 4 inner readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = load.ptr v2 align 3
  v4 = load.i64 v2+8 align 3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i32 0
  v8 = iconst.i32 3
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v4
  br v10, b2, b5
b2:
  v11 = ptradd v1, v9 * 4
  v12 = load.i32 v11 align 2
  v13 = icmp.sgt v12, v7
  br v13, b3, b4(v7)
b3:
  v14 = ptradd v3, v9 * 4
  v15 = load.i32 v14 align 2
  v16 = mul.i32 v15, v8
  jmp b4(v16)
b4(v17: i32):
  v18 = ptradd v0, v9 * 4
  store v17, v18 align 2
  v19 = add.i64 v9, v6
  jmp b1(v19)
b5:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
  slot s3 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 128
  v8 = iconst.i64 7
  v9 = iconst.i64 3
  jmp b1(v5)
b1(v10: i64):
  v11 = icmp.ult v10, v7
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v9
  v13 = urem.i64 v12, v8
  v14 = sub.i64 v13, v9
  v15 = trunc.i32 v14
  v16 = ptradd v2, v10 * 4
  store v15, v16 align 2
  v17 = trunc.i32 v10
  v18 = ptradd v3, v10 * 4
  store v17, v18 align 2
  v19 = ptradd v1, v10 * 4
  store v17, v19 align 2
  v20 = add.i64 v10, v6
  jmp b1(v20)
b3:
  store v3, v4 align 3
  store v0, v4+8 align 3
  call @pick(v1, v2, v4) : (ptr, ptr, ptr) -> void
  jmp b4(v5, v5)
b4(v21: i64, v22: i64):
  v23 = icmp.ult v21, v7
  br v23, b5, b6
b5:
  v24 = ptradd v1, v21 * 4
  v25 = load.i32 v24 align 2
  v26 = sext.i64 v25
  v27 = mul.i64 v22, v7
  v28 = add.i64 v27, v26
  v29 = add.i64 v21, v6
  jmp b4(v29, v28)
b6:
  ret v22
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let p = text_of(&a, "pick");
    assert(p.contains("mul.v4i32") && p.contains("vsel.v4i32"), p.as_str());
    let ns: [u64; 6] = [0, 3, 4, 37, 100, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A load of `a[0]` before stores of `a[i]` from `i = 1` (TSVC s113) reads no byte they write
// (`inv_below`): it is loaded once and the loop vectorizes, also when a product of it is the lane value's
// operand (`lane_operands`: on its splat). From `i = 0` the first store writes it, and that loop
// vectorizes only under an overlap check. Each count runs as before.
@test
fn an_invariant_load_below_the_stores_vectorizes() {
    let src = M"(lir ptr 8
sym @from1 fn global noinline
sym @from0 fn global noinline
sym @times fn global noinline
sym @drive fn global
fn @times
  sig (ptr, ptr) -> void
  ref p0 4 inner noalias
  ref p1 4 inner readonly
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v1 align 3
  v5 = iconst.i64 1
  v6 = iconst.i32 3
  jmp b1(v5)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = load.i32 v2 align 2
  v10 = mul.i32 v9, v6
  v11 = ptradd v4, v7 * 4
  v12 = load.i32 v11 align 2
  v13 = add.i32 v10, v12
  v14 = ptradd v2, v7 * 4
  store v13, v14 align 2
  v15 = add.i64 v7, v5
  jmp b1(v15)
b3:
  ret
fn @from1
  sig (ptr, ptr) -> void
  ref p0 4 inner noalias
  ref p1 4 inner readonly
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v1 align 3
  v5 = iconst.i64 1
  jmp b1(v5)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = load.i32 v2 align 2
  v9 = ptradd v4, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = add.i32 v8, v10
  v12 = ptradd v2, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v5
  jmp b1(v13)
b3:
  ret
fn @from0
  sig (ptr, ptr) -> void
  ref p0 4 inner noalias
  ref p1 4 inner readonly
b0(v0: ptr, v1: ptr):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = load.ptr v1 align 3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  jmp b1(v5)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = load.i32 v2 align 2
  v10 = ptradd v4, v7 * 4
  v11 = load.i32 v10 align 2
  v12 = add.i32 v9, v11
  v13 = ptradd v2, v7 * 4
  store v12, v13 align 2
  v14 = add.i64 v7, v6
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 128
  v8 = iconst.i64 3
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = add.i64 v9, v6
  v12 = trunc.i32 v11
  v13 = ptradd v1, v9 * 4
  store v12, v13 align 2
  v14 = mul.i64 v9, v8
  v15 = trunc.i32 v14
  v16 = ptradd v2, v9 * 4
  store v15, v16 align 2
  jmp b1(v11)
b3:
  store v1, v3 align 3
  store v0, v3+8 align 3
  store v2, v4 align 3
  store v7, v4+8 align 3
  call @from1(v3, v4) : (ptr, ptr) -> void
  call @times(v3, v4) : (ptr, ptr) -> void
  call @from0(v3, v4) : (ptr, ptr) -> void
  jmp b4(v5, v5)
b4(v17: i64, v18: i64):
  v19 = icmp.ult v17, v7
  br v19, b5, b6
b5:
  v20 = ptradd v1, v17 * 4
  v21 = load.i32 v20 align 2
  v22 = sext.i64 v21
  v23 = mul.i64 v18, v7
  v24 = add.i64 v23, v22
  v25 = add.i64 v17, v6
  jmp b4(v25, v24)
b6:
  ret v18
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let f1 = text_of(&a, "from1");
    let f0 = text_of(&a, "from0");
    let tm = text_of(&a, "times");
    assert(f1.contains("add.v4i32"), f1.as_str());
    assert(tm.contains("mul.v4i32"), tm.as_str());
    // From 0, only under a check before the loop that the first store misses the load's place (an `or`
    // of two address comparisons); from 1 none.
    assert(f0.contains("v4i32") && f0.contains(" = or.i8") && !f1.contains(" = or.i8"), f0.as_str());
    let ns: [u64; 7] = [0, 1, 2, 5, 37, 100, 128];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A sum into `x[i]` over a row, `x[i] += a[i * m + j]` (a matrix-vector product), whose first pass checks
// the row's index before `x[i]`'s: the guard before the loop makes that check on the entry values
// (`Opt::entry_cmp`), so `x[i]` stays in a register; the checks version away (`cold` reads the block
// storing it back on the way to a failure call) and the sum vectorizes. Each count fails or ends as before.
@test
fn a_row_sum_into_memory_stays_in_a_register_and_vectorizes() {
    let src = M"(lir ptr 8
sym @row fn global noinline
sym @fail fn global noinline cold
sym @drive fn global
fn @fail
  sig (i64) -> void
b0(v0: i64):
  panic "index out of bounds"
fn @row
  sig (ptr, ptr, i64, i64) -> void
  ref p0 8 inner noalias
  ref p1 8 inner readonly
b0(v0: ptr, v1: ptr, v2: i64, v3: i64):
  v4 = load.ptr v0 align 3
  v5 = load.i64 v0+8 align 3
  v6 = load.ptr v1 align 3
  v7 = load.i64 v1+8 align 3
  v8 = iconst.i64 0
  v9 = iconst.i64 1
  v10 = mul.i64 v2, v3
  v11 = icmp.uge v2, v5
  v12 = ptradd v4, v2 * 8
  jmp b1(v8)
b1(v13: i64):
  v14 = icmp.ult v13, v3
  br v14, b2, b5
b2:
  v15 = add.i64 v10, v13
  v16 = icmp.uge v15, v7
  br v16, b6, b3
b3:
  br v11, b7, b4
b4:
  v17 = ptradd v6, v15 * 8
  v18 = load.i64 v17 align 3
  v19 = load.i64 v12 align 3
  v20 = add.i64 v19, v18
  store v20, v12 align 3
  v21 = add.i64 v13, v9
  jmp b1(v21)
b5:
  ret
b6:
  call @fail(v3) : (i64) -> void
  unreachable
b7:
  call @fail(v2) : (i64) -> void
  unreachable
fn @drive
  sig (i64, i64, i64) -> i64
  slot s0 size 64 align 3
  slot s1 size 1024 align 3
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  v4 = slotaddr s1
  v5 = slotaddr s2
  v6 = slotaddr s3
  v7 = iconst.i64 0
  v8 = iconst.i64 1
  v9 = iconst.i64 128
  v10 = iconst.i64 8
  jmp b1(v7)
b1(v11: i64):
  v12 = icmp.ult v11, v9
  br v12, b2, b3
b2:
  v13 = mul.i64 v11, v11
  v14 = ptradd v4, v11 * 8
  store v13, v14 align 3
  v15 = add.i64 v11, v8
  jmp b1(v15)
b3:
  store v7, v3 align 3
  store v8, v3+8 align 3
  store v10, v3+16 align 3
  store v3, v5 align 3
  store v10, v5+8 align 3
  store v4, v6 align 3
  store v2, v6+8 align 3
  call @row(v5, v6, v0, v1) : (ptr, ptr, i64, i64) -> void
  v16 = ptradd v3, v0 * 8
  v17 = load.i64 v16 align 3
  ret v17
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 200,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let r = text_of(&a, "row");
    assert(r.contains("add.v2i64"), r.as_str());
    // Row `i`, `m` columns, `alen` elements of `a`: the access past `a` or row 8 fails.
    let cases: [u64; 21] = [0, 7, 128, 1, 7, 128, 2, 9, 128, 3, 30, 128, 7, 16, 128, 2, 40, 100, 8, 3, 128];
    for k in 0..7usize {
        let i = unsafe cases[3 * k];
        let m = unsafe cases[3 * k + 1];
        let alen = unsafe cases[3 * k + 2];
        let args: []u64 = [i, m, alen];
        let fails = m != 0 && (i * m + m > alen || i >= 8);
        if fails {
            same_outcome(&b, &a, "drive", args, 0, true);
        } else {
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A u32 counter tested through its extension against a 64-bit bound, `while (i as usize) < n`: where `n`
// fits the counter (`n <=u 4294967295`) a copy tests `i <u trunc(n)` (`narrow_head`), which vectorizes;
// the loop as it was runs where it does not. Each count runs as before.
@test
fn a_narrow_counter_against_a_wide_bound_vectorizes_in_a_copy() {
    let src = M"(lir ptr 8
sym @twice fn global noinline
sym @drive fn global
fn @twice
  sig (ptr, i64) -> void
  ref p0 512 noalias
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = iconst.i32 1
  jmp b1(v2)
b1(v4: i32):
  v5 = zext.i64 v4
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = add.i32 v4, v4
  v8 = ptradd v0, v5 * 4
  store v7, v8 align 2
  v9 = add.i32 v4, v3
  jmp b1(v9)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 128
  call @twice(v1, v0) : (ptr, i64) -> void
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = sext.i64 v9
  v11 = mul.i64 v6, v4
  v12 = add.i64 v11, v10
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 200,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "twice");
    assert(t.contains("4294967295") && t.contains("add.v4i32"), t.as_str());
    let ns: [u64; 6] = [0, 1, 3, 4, 37, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
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
// (times a constant past a byte's range: no widening product) widens through 16 bits (interleaved with its
// sign or zeros), a 32-bit lane narrows through 16 (even lanes), and a byte to a float extends, then
// converts. Each count runs as before.
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
  v5 = iconst.i32 300
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
sym @looked data global
sym @own fn global noinline
sym @called fn global noinline
sym @stored fn global noinline
sym @plain fn global noinline
sym @shared fn global noinline
sym @look fn global noinline
fn @look
  sig (ptr) -> void
b0(v0: ptr):
  v1 = symaddr @looked
  store v0, v1 align 3
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
data @looked size 8 align 3
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
// maximum (`vop.max.s`) where the backend computes it in registers: every vector (arm64), up to 32 bytes
// (x86-64); past them the select stays.
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
    assert(u.contains("vop.max.s.v4i32") && !u.contains("vsel"), u.as_str());
    let (_, w) = optimized_for(src, VECTOR, 64, VOPS_SOME);
    let z = text_of(&w, "top");
    assert(z.contains("vsel.v16i32") && !z.contains("vop.max"), z.as_str());
    let lens: [u64; 4] = [0, 5, 37, 128];
    for k in 0..4usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A loop whose header tests a counter carries a pointer the body steps by the element size: the pointer is
// its start plus the iterations done times that size, and a counter down to 0 counts up, so the loop
// vectorizes (a tail recursion over a slice); a pointer the exit reads stays carried.
@test
fn pointers_stepped_with_a_counter_index_the_loop() {
    let (b, a) = optimized(
        M"(lir ptr 8
sym @w data global
sym @down fn global
sym @up fn global
sym @kept fn global
fn @down
  sig (i64) -> i32
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 0
  jmp b1(v1, v0, v4)
b1(v5: ptr, v6: i64, v7: i32):
  v8 = icmp.ne v6, v2
  br v8, b2, b3
b2:
  v9 = load.i32 v5 align 2
  v10 = add.i32 v7, v9
  v11 = ptradd v5+4
  v12 = sub.i64 v6, v3
  jmp b1(v11, v12, v10)
b3:
  ret v7
fn @up
  sig (i64) -> i32
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 0
  jmp b1(v1, v2, v4)
b1(v5: ptr, v6: i64, v7: i32):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = load.i32 v5 align 2
  v10 = add.i32 v7, v9
  v11 = ptradd v5+4
  v12 = add.i64 v6, v3
  jmp b1(v11, v12, v10)
b3:
  ret v7
fn @kept
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  jmp b1(v1, v0)
b1(v4: ptr, v5: i64):
  v6 = icmp.ne v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v4+4
  v8 = sub.i64 v5, v3
  jmp b1(v7, v8)
b3:
  v9 = ptrtoint.i64 v4
  v10 = ptrtoint.i64 v1
  v11 = sub.i64 v9, v10
  ret v11
data @w size 100 align 2 bytes 0100000002000000030000000400000005000000060000000700000008000000090000000a0000000b0000000c0000000d0000000e0000000f00000010000000110000001200000013000000140000001500000016000000170000001800000019000000
)",
        VECTOR,
    );
    let d = text_of(&a, "down");
    assert(d.contains("v4i32"), d.as_str());
    let u = text_of(&a, "up");
    assert(u.contains("v4i32"), u.as_str());
    let ns: [u64; 4] = [0, 3, 17, 25];
    let sums: [u64; 4] = [0, 6, 153, 325];
    for q in 0..4 {
        let x: []u64 = [ns[q]];
        same_outcome(&b, &a, "down", x, sums[q], false);
        same_outcome(&b, &a, "up", x, sums[q], false);
        same_outcome(&b, &a, "kept", x, 4 * ns[q], false);
    }
}

// What an interleaved vector loop of 16 lanes or more leaves vectorizes once more, one vector at a time (an
// epilogue), before the scalar loop: 4 interleaved loads and 1 per iteration; no loop is left to vectorize.
// 2 interleaved vectors of 4 lanes leave at most 7 elements: the scalar loop alone runs them.
@test
fn remainders_of_interleaved_vectors_vectorize() {
    let src = M"(lir ptr 8
sym @w data global
sym @sum fn global
fn @sum
  sig (i64) -> i32
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 0
  jmp b1(v2, v4)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = add.i32 v6, v9
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
data @w size 100 align 2 bytes 0100000002000000030000000400000005000000060000000700000008000000090000000a0000000b0000000c0000000d0000000e0000000f00000010000000110000001200000013000000140000001500000016000000170000001800000019000000
)";
    let four = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 4,
        interleave: 4,
        fin: 0,
    };
    let (b, a) = optimized(src, four);
    let s = text_of(&a, "sum");
    assert(count(&s, "load.v4i32") == 5 && !s.contains(" epi"), s.as_str());
    let (_, a2) = optimized(src, VECTOR);
    let s2 = text_of(&a2, "sum");
    assert(count(&s2, "load.v4i32") == 2 && !s2.contains(" epi"), s2.as_str());
    for n in 0..26u64 {
        let x: []u64 = [n];
        same_outcome(&b, &a, "sum", x, n * (n + 1) / 2, false);
        same_outcome(&b, &a2, "sum", x, n * (n + 1) / 2, false);
    }
}

// Sums in 8-byte lanes of byte lanes: a count of matches widened through 2-, 4- and 8-byte lanes in
// 16-byte registers (each lane mask beside itself, then subtracted); zero and sign extensions; each length
// runs as before.
@test
fn byte_lanes_widen_to_8_bytes() {
    let src = M"(lir ptr 8
sym @cnt fn global
sym @su fn global
sym @ss fn global
sym @w data local
fn @cnt
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 -36
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v4
  v11 = zext.i64 v10
  v12 = add.i64 v6, v11
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
fn @su
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 43
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 1
  v9 = load.i8 v8 align 0
  v10 = iconst.i8 0
  v11 = zext.i64 v9
  v12 = add.i64 v6, v11
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
fn @ss
  sig (i64) -> i64
b0(v0: i64):
  v1 = symaddr @w
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 43
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 1
  v9 = load.i8 v8 align 0
  v10 = iconst.i8 0
  v11 = sext.i64 v9
  v12 = add.i64 v6, v11
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
data @w size 200 align 3 bytes 21c0a9dc5920318c312059dca9c021ccc100895c79e0918cd160395cc98081cc614069dc99a0f18c71a019dce940e1cc0180495cb960518c11e0f95c090041cca1c029dcd920b18cb120d9dc29c0a1cc4100095cf9e0118c5160b95c498001cce140e9dc19a0718cf1a099dc694061cc8180c95c3960d18c91e0795c8900c1cc21c0a9dc5920318c312059dca9c021ccc100895c79e0918cd160395cc98081cc614069dc99a0f18c71a019dce940e1cc0180495cb960518c11e0f95c090041cca1c029dcd920b18c
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let c = text_of(&a, "cnt");
    assert(c.contains("sub.v2i64") && !c.contains("vsel"), c.as_str());
    for n in 0..67u64 {
        let args: []u64 = [n * 3];
        same_outcome(&b, &a, "cnt", args, run_value(&b, "cnt", args), false);
        same_outcome(&b, &a, "su", args, run_value(&b, "su", args), false);
        same_outcome(&b, &a, "ss", args, run_value(&b, "ss", args), false);
    }
}

// A count whose 8-byte lanes take 4 registers per vector of byte lanes interleaves as many copies as hold
// its accumulators in the target's registers for them (`Package.vec_accs`), a power of 2 (the vector
// iterations' count masks the length): 2 of 4 within 8 registers, 2 within 12, 1 within 4, all 4 without
// a bound; each length runs as before.
@test
fn wide_reductions_interleave_within_their_registers() {
    let src = M"(lir ptr 8
sym @cnt fn global
sym @w data local
fn @cnt
  sig (i64, i8) -> i64
b0(v0: i64, v1: i8):
  v2 = symaddr @w
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v2, v5 * 1
  v9 = load.i8 v8 align 0
  v10 = icmp.eq v9, v1
  v11 = zext.i64 v10
  v12 = add.i64 v6, v11
  v13 = add.i64 v5, v4
  jmp b1(v13, v12)
b3:
  ret v6
data @w size 64 align 3 bytes 21c0a9dc5920318c312059dca9c021ccc100895c79e0918cd160395cc98081cc614069dc99a0f18c71a019dce940e1cc0180495cb960518c11e0f95c090041cc
)";
    let four = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 4,
        interleave: 4,
        fin: 0,
    };
    // (registers, vector loads of the first vector loop)
    let cases: [(u32, u32); 4] = [(8, 2), (12, 2), (4, 1), (0, 4)];
    for k in 0..4usize {
        let (accs, loads) = unsafe cases[k];
        let (b, a) = optimized_with(src, four, 16, VOPS_SOME, accs);
        // The block of the first vector load, to its branch.
        let c = text_of(&a, "cnt");
        let at = c.find("load.v8i8");
        assert(at < c.len(), c.as_str());
        let rest = c.as_str().slice(at, c.len());
        let block = String::from_str(rest.slice(0, rest.find("br ") as usize));
        assert(count(&block, "load.v8i8") == loads, c.as_str());
        for n in 0..65u64 {
            let args: []u64 = [n, 0xdc];
            same_outcome(&b, &a, "cnt", args, run_value(&b, "cnt", args), false);
        }
    }
}

// A loop's calls of C's float functions (`floorf`, `fmaf`) widen to vector operations where the target computes
// them in registers (`lane_fn`, `Package.vfloat`; `fmaf` on a processor with a fused multiply-add,
// `Package.fma`); a call of another function stays.
@test
fn calls_of_float_functions_widen() {
    let src = M"(lir ptr 8
sym @floorf fn global
sym @fmaf fn global
sym @cosf fn global
sym @fl fn global
sym @fm fn global
sym @co fn global
fn @fl
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.f32 v7 align 2
  v9 = call.f32 @floorf(v8) : (f32) -> f32
  v10 = ptradd v0, v5 * 4
  store v9, v10 align 2
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @fm
  sig (ptr, ptr, f32, i64) -> void
b0(v0: ptr, v1: ptr, v2: f32, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.f32 v8 align 2
  v10 = call.f32 @fmaf(v9, v2, v9) : (f32, f32, f32) -> f32
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v5
  jmp b1(v12)
b3:
  ret
fn @co
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.f32 v7 align 2
  v9 = call.f32 @cosf(v8) : (f32) -> f32
  v10 = ptradd v0, v5 * 4
  store v9, v10 align 2
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
)";
    let (_, a) = optimized_fma(src, VECTOR, true);
    let f = text_of(&a, "fl");
    assert(f.contains("vop.floor.v4f32"), f.as_str());
    let m = text_of(&a, "fm");
    assert(m.contains("vop.fma.v4f32"), m.as_str());
    let c = text_of(&a, "co");
    assert(!c.contains("v4f32") && c.contains("call.f32 @cosf"), c.as_str());
    let (_, n) = optimized(src, VECTOR);
    let s = text_of(&n, "fm");
    assert(!s.contains("vop.fma") && s.contains("call.f32 @fmaf"), s.as_str());
}

// A sum a branch of the loop adds to (`if s[i] > 0 { t += s[i] }`), if-converted, is the step
// `t + select(c, s[i], 0)` (`cond_step`): a reduction the vectorizer widens.
@test
fn conditional_sums_vectorize() {
    let src = M"(lir ptr 8
sym @cs fn global
fn @cs
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = load.i64 v0 align 3
  jmp b1(v3, v2)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v1
  br v8, b3, b2
b2:
  ret v7
b3:
  v9 = ptradd v0, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.sgt v10, v2
  br v11, b4, b5(v7)
b4:
  v12 = add.i32 v7, v10
  jmp b5(v12)
b5(v13: i32):
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
)";
    let (_, a) = optimized(src, VECTOR);
    let f = text_of(&a, "cs");
    assert(f.contains("vsel.v4i32") && f.contains("add.v4i32"), f.as_str());
}

// A sum of three vectors' worth of terms (loads from consecutive addresses) packs into three vector loads,
// two vector adds and one reduction. With paired accesses (`Package.apairs`) the loads stay together, which
// pairs them; without, each load comes right before its add (`Slp::term`), so one term is live at a time.
@test
fn a_sum_of_several_vectors_of_terms_packs() {
    let src = M"(lir ptr 8
sym @sum12 fn global noinline
sym @drive fn global
fn @sum12
  sig (ptr) -> i32
b0(v0: ptr):
  v1 = load.i32 v0 align 2
  v2 = load.i32 v0+4 align 2
  v3 = load.i32 v0+8 align 2
  v4 = load.i32 v0+12 align 2
  v5 = load.i32 v0+16 align 2
  v6 = load.i32 v0+20 align 2
  v7 = load.i32 v0+24 align 2
  v8 = load.i32 v0+28 align 2
  v9 = load.i32 v0+32 align 2
  v10 = load.i32 v0+36 align 2
  v11 = load.i32 v0+40 align 2
  v12 = load.i32 v0+44 align 2
  v13 = add.i32 v1, v2
  v14 = add.i32 v13, v3
  v15 = add.i32 v14, v4
  v16 = add.i32 v15, v5
  v17 = add.i32 v16, v6
  v18 = add.i32 v17, v7
  v19 = add.i32 v18, v8
  v20 = add.i32 v19, v9
  v21 = add.i32 v20, v10
  v22 = add.i32 v21, v11
  v23 = add.i32 v22, v12
  ret v23
fn @drive
  sig (i64) -> i64
  slot s0 size 48 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = trunc.i32 v0
  v3 = iconst.i32 7
  v4 = mul.i32 v2, v3
  store v4, v1 align 2
  v5 = mul.i32 v4, v3
  store v5, v1+4 align 2
  v6 = mul.i32 v5, v3
  store v6, v1+8 align 2
  v7 = mul.i32 v6, v3
  store v7, v1+12 align 2
  v8 = mul.i32 v7, v3
  store v8, v1+16 align 2
  v9 = mul.i32 v8, v3
  store v9, v1+20 align 2
  v10 = mul.i32 v9, v3
  store v10, v1+24 align 2
  v11 = mul.i32 v10, v3
  store v11, v1+28 align 2
  v12 = mul.i32 v11, v3
  store v12, v1+32 align 2
  v13 = mul.i32 v12, v3
  store v13, v1+36 align 2
  v14 = mul.i32 v13, v3
  store v14, v1+40 align 2
  v15 = mul.i32 v14, v3
  store v15, v1+44 align 2
  v16 = call.i32 @sum12(v1) : (ptr) -> i32
  v17 = sext.i64 v16
  ret v17
)";
    let (b, a) = optimized(src, VECTOR);
    let t = text_of(&a, "sum12");
    assert(count(&t, "load.v4i32") == 3 && count(&t, "add.v4i32") == 2 && t.contains("reduce_add"), t.as_str());
    assert(loads_in_a_row(&t) == 3, t.as_str());
    let mut err = String::new();
    let mut np = lparse::parse(src, &mut err).unwrap();
    np.apairs = false;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut np, &none, lopt::Config { inline: il::SPEED, loops: VECTOR });
    let u = text_of(&np, "sum12");
    assert(count(&u, "load.v4i32") == 3 && loads_in_a_row(&u) == 2, u.as_str());
    let vals: [u64; 3] = [0, 3, 0x7FFFFFFF];
    for k in 0..3usize {
        let args: []u64 = [unsafe vals[k]];
        let want = run_value(&b, "drive", args);
        same_outcome(&b, &a, "drive", args, want, false);
        assert_eq(run_value(&np, "drive", args), want);
    }
}

// The most `load.v4i32` lines of `text` in a row.
const fn loads_in_a_row(text: &String) u32 {
    let mut most: u32 = 0;
    let mut run: u32 = 0;
    for line in text.as_str().split("\n") {
        run = if line.contains("load.v4i32") {
            run + 1
        } else {
            0
        };
        most = most.max(run);
    }
    return most;
}

// Package text `text` read, then optimized with loop budgets `bu` for a target of 16-byte registers that
// converts vectors in registers and computes the saturating sums and absolute differences of the lane sizes
// `sat` and `absd` and the widening sums `sumw` there (`Package.vec_sat`, `vec_absd`, `vec_sumw`).
fn optimized_idioms(text: str, bu: lu::Budgets, sat: u8, absd: u8, sumw: u16) (Package, Package) {
    let mut err = String::new();
    let q = lparse::parse(text, &mut err);
    assert(q.is_some(), err.as_str());
    let before = q.unwrap();
    let mut after = lparse::parse(text, &mut err).unwrap();
    after.vector = 16;
    after.vops = VOPS_SOME;
    after.vec_sat = sat;
    after.vec_absd = absd;
    after.vec_sumw = sumw;
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

// A byte saturating sum (`select(s >u 255, -1, trunc(s))` of the bytes' 16-bit sum, a constant or a value
// from before the loop) and absolute differences of zero- and sign-extended bytes (`select(d <s 0, -d, d)`)
// that a 32-bit sum reads or a truncation stores vectorize at the byte lanes: `saturating_add`, `abs_diff`
// and a widening sum (`vsumw`) into 4-byte lanes, or 8-byte ones where the target widens bytes there alone.
// Without the target's forms the loops vectorize as before, through wider lanes. Each count runs as before.
const IDIOMS: str = M"(lir ptr 8
sym @sat fn global noinline
sym @sat_k fn global noinline
sym @sad fn global noinline
sym @sads fn global noinline
sym @adiff fn global noinline
sym @drive fn global
fn @sat
  sig (ptr, i64, i8) -> void
b0(v0: ptr, v1: i64, v2: i8):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i16 255
  v6 = iconst.i8 -1
  v7 = zext.i16 v2
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v1
  br v9, b2, b3
b2:
  v10 = ptradd v0, v8 * 1
  v11 = load.i8 v10 align 0
  v12 = zext.i16 v11
  v13 = add.i16 v12, v7
  v14 = trunc.i8 v13
  v15 = icmp.ugt v13, v5
  v16 = select.i8 v15, v6, v14
  store v16, v10 align 0
  v17 = add.i64 v8, v4
  jmp b1(v17)
b3:
  ret
fn @sat_k
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 256
  v5 = iconst.i8 -1
  v6 = iconst.i32 200
  jmp b1(v2)
b1(v7: i64):
  v8 = icmp.ult v7, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v7 * 1
  v10 = load.i8 v9 align 0
  v11 = zext.i32 v10
  v12 = add.i32 v6, v11
  v13 = trunc.i8 v12
  v14 = icmp.ult v12, v4
  v15 = select.i8 v14, v13, v5
  store v15, v9 align 0
  v16 = add.i64 v7, v3
  jmp b1(v16)
b3:
  ret
fn @sad
  sig (ptr, ptr, i64) -> i32
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v2
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 1
  v10 = load.i8 v9 align 0
  v11 = zext.i32 v10
  v12 = ptradd v1, v6 * 1
  v13 = load.i8 v12 align 0
  v14 = zext.i32 v13
  v15 = sub.i32 v11, v14
  v16 = sub.i32 v5, v15
  v17 = icmp.slt v15, v5
  v18 = select.i32 v17, v16, v15
  v19 = add.i32 v7, v18
  v20 = add.i64 v6, v4
  jmp b1(v20, v19)
b3:
  ret v7
fn @sads
  sig (ptr, ptr, i64) -> i32
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  v6 = iconst.i32 -1
  jmp b1(v3, v5)
b1(v7: i64, v8: i32):
  v9 = icmp.ult v7, v2
  br v9, b2, b3
b2:
  v10 = ptradd v0, v7 * 1
  v11 = load.i8 v10 align 0
  v12 = sext.i32 v11
  v13 = ptradd v1, v7 * 1
  v14 = load.i8 v13 align 0
  v15 = sext.i32 v14
  v16 = sub.i32 v12, v15
  v17 = neg.i32 v16
  v18 = icmp.sgt v16, v6
  v19 = select.i32 v18, v16, v17
  v20 = add.i32 v8, v19
  v21 = add.i64 v7, v4
  jmp b1(v21, v20)
b3:
  ret v8
fn @adiff
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i16 0
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 1
  v9 = load.i8 v8 align 0
  v10 = zext.i16 v9
  v11 = ptradd v1, v6 * 1
  v12 = load.i8 v11 align 0
  v13 = zext.i16 v12
  v14 = sub.i16 v10, v13
  v15 = sub.i16 v5, v14
  v16 = icmp.slt v14, v5
  v17 = select.i16 v16, v15, v14
  v18 = trunc.i8 v17
  store v18, v8 align 0
  v19 = add.i64 v6, v4
  jmp b1(v19)
b3:
  ret
fn @drive
  sig (i64, i8) -> i64
  slot s0 size 64 align 3
  slot s1 size 64 align 3
b0(v0: i64, v1: i8):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 64
  v7 = iconst.i8 37
  v8 = iconst.i8 11
  v9 = iconst.i8 -59
  jmp b1(v4)
b1(v10: i64):
  v11 = icmp.ult v10, v6
  br v11, b2, b3
b2:
  v12 = trunc.i8 v10
  v13 = mul.i8 v12, v7
  v14 = add.i8 v13, v8
  v15 = ptradd v2, v10 * 1
  store v14, v15 align 0
  v16 = mul.i8 v12, v9
  v17 = ptradd v3, v10 * 1
  store v16, v17 align 0
  v18 = add.i64 v10, v5
  jmp b1(v18)
b3:
  v19 = call.i32 @sad(v2, v3, v0) : (ptr, ptr, i64) -> i32
  v20 = call.i32 @sads(v2, v3, v0) : (ptr, ptr, i64) -> i32
  call @sat(v2, v0, v1) : (ptr, i64, i8) -> void
  call @sat_k(v3, v0) : (ptr, i64) -> void
  call @adiff(v2, v3, v0) : (ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v21: i64, v22: i64):
  v23 = icmp.ult v21, v6
  br v23, b5, b6
b5:
  v24 = ptradd v2, v21 * 1
  v25 = load.i8 v24 align 0
  v26 = zext.i64 v25
  v27 = ptradd v3, v21 * 1
  v28 = load.i8 v27 align 0
  v29 = zext.i64 v28
  v30 = iconst.i64 31
  v31 = mul.i64 v22, v30
  v32 = add.i64 v31, v26
  v33 = mul.i64 v32, v30
  v34 = add.i64 v33, v29
  v35 = add.i64 v21, v5
  jmp b4(v35, v34)
b6:
  v36 = zext.i64 v19
  v37 = zext.i64 v20
  v38 = iconst.i64 32
  v39 = shl.i64 v37, v38
  v40 = add.i64 v36, v39
  v41 = xor.i64 v40, v22
  ret v41
)";

@test
fn byte_idioms_vectorize_at_their_lanes() {
    let four = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
    // (saturating sizes, difference sizes, widening sums, the text each loop's vectors take)
    let (b, a) = optimized_idioms(IDIOMS, four, 7, 7, lu::sumw_bit(1, 4) | lu::sumw_bit(1, 8));
    let wants: [(str, str); 5] = [
        ("sat", "vop.saturating_add.v16i8"),
        ("sat_k", "vop.saturating_add.v16i8"),
        ("sad", "vsumw.v4i32"),
        ("sads", "vop.abs_diff.s.v16i8"),
        ("adiff", "vop.abs_diff.v16i8"),
    ];
    for k in 0..5usize {
        let (f, want) = unsafe wants[k];
        let t = text_of(&a, f);
        assert(t.contains(want), t.as_str());
    }
    // Bytes widened into 8-byte lanes alone: the 32-bit sums take them.
    let (b8, a8) = optimized_idioms(IDIOMS, four, 7, 7, lu::sumw_bit(1, 8));
    let t8 = text_of(&a8, "sad");
    assert(t8.contains("vsumw.v2i64") && t8.contains("vop.abs_diff.v16i8"), t8.as_str());
    // Without the forms: no idiom, the wider lanes.
    let (b0, a0) = optimized_idioms(IDIOMS, four, 0, 0, 0);
    let fs: [str; 5] = ["sat", "sat_k", "sad", "sads", "adiff"];
    for k in 0..5usize {
        let t = text_of(&a0, unsafe fs[k]);
        assert(!t.contains("saturating_add") && !t.contains("abs_diff") && !t.contains("vsumw"), t.as_str());
    }
    assert(text_of(&a0, "sad").contains("load.v8i8"), text_of(&a0, "sad").as_str());
    for n in 0..65u64 {
        for kk in 0..4u64 {
            let args: []u64 = [n, kk * 85];
            let want = run_value(&b, "drive", args);
            same_outcome(&b, &a, "drive", args, want, false);
            same_outcome(&b8, &a8, "drive", args, want, false);
            same_outcome(&b0, &a0, "drive", args, want, false);
        }
    }
}

// Bit counts and byte swaps the target computes in registers (`Package.vec_bits`) vectorize as lane
// operations: a sum of 32-bit population counts, 16-bit leading zeros stored, 64-bit swapped bytes stored.
// Without the target's forms the loops stay scalar, but a count by bit-parallel sums or, where the target
// looks up bytes by indices (`Package.vtbl`), by a table of nibbles, and narrow leading zeros by a count of
// the bits below the top one where the target counts bits. Each count runs as before.
const BITS: str = M"(lir ptr 8
sym @pop fn global noinline
sym @lz fn global noinline
sym @swap fn global noinline
sym @drive fn global
fn @pop
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i32 0
  v4 = iconst.i64 1
  jmp b1(v2, v3)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = popcnt.i32 v9
  v11 = add.i32 v6, v10
  v12 = add.i64 v5, v4
  jmp b1(v12, v11)
b3:
  ret v6
fn @lz
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 2
  v8 = load.i16 v7 align 1
  v9 = clz.i16 v8
  v10 = ptradd v0, v5 * 2
  store v9, v10 align 1
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @swap
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
  v7 = load.i64 v6 align 3
  v8 = bswap.i64 v7
  store v8, v6 align 3
  v9 = add.i64 v4, v3
  jmp b1(v9)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 8
  slot s1 size 256 align 8
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 64
  v6 = iconst.i64 -7046029254386353131
  v7 = iconst.i64 31
  jmp b1(v3, v0)
b1(v8: i64, v9: i64):
  v10 = icmp.ult v8, v5
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v6
  v12 = lshr.i64 v11, v7
  v13 = ptradd v1, v8 * 8
  store v12, v13 align 3
  v14 = add.i64 v8, v4
  jmp b1(v14, v11)
b3:
  v15 = call.i32 @pop(v1, v0) : (ptr, i64) -> i32
  call @lz(v2, v1, v0) : (ptr, ptr, i64) -> void
  call @swap(v1, v0) : (ptr, i64) -> void
  jmp b4(v3, v3)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v0
  br v18, b5, b6
b5:
  v19 = ptradd v1, v16 * 8
  v20 = load.i64 v19 align 3
  v21 = ptradd v2, v16 * 2
  v22 = load.i16 v21 align 1
  v23 = zext.i64 v22
  v24 = mul.i64 v17, v7
  v25 = xor.i64 v24, v20
  v26 = add.i64 v25, v23
  v27 = add.i64 v16, v4
  jmp b4(v27, v26)
b6:
  v28 = zext.i64 v15
  v29 = xor.i64 v28, v17
  ret v29
)";

@test
fn bit_counts_and_byte_swaps_vectorize_where_the_target_has_them() {
    let four = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
    let mut err = String::new();
    let b = lparse::parse(BITS, &mut err).unwrap();
    let mut a = lparse::parse(BITS, &mut err).unwrap();
    a.vector = 16;
    a.vops = VOPS_ALL;
    a.vec_bits = 0x0E0F07;
    let mut a0 = lparse::parse(BITS, &mut err).unwrap();
    a0.vector = 16;
    a0.vops = VOPS_ALL;
    a0.vec_bits = 0;
    // A target with a scalar count in one instruction (x86-64-v2's `popcnt`, wasm32's): a 4-byte count stays.
    let mut a1 = lparse::parse(BITS, &mut err).unwrap();
    a1.vector = 16;
    a1.vops = VOPS_ALL;
    a1.vec_bits = 0;
    a1.popcnt = true;
    // One that looks up bytes by indices (x86-64's SSSE3 `pshufb`): the counts by a table of nibbles,
    // also of 4-byte lanes beside the scalar count, where the cost model finds them cheaper.
    let mut a2 = lparse::parse(BITS, &mut err).unwrap();
    a2.vector = 16;
    a2.vops = VOPS_ALL;
    a2.vec_bits = 0;
    a2.popcnt = true;
    a2.vtbl = true;
    // One that counts set bits but no leading zeros in registers (wasm32): 16-bit leading zeros by the bits
    // below the top one set, then their count.
    let mut a3 = lparse::parse(BITS, &mut err).unwrap();
    a3.vector = 16;
    a3.vops = VOPS_ALL;
    a3.vec_bits = 0x000700;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: four });
    lopt::optimize(&mut a0, &none, lopt::Config { inline: il::SPEED, loops: four });
    lopt::optimize(&mut a1, &none, lopt::Config { inline: il::SPEED, loops: four });
    lopt::optimize(&mut a2, &none, lopt::Config { inline: il::SPEED, loops: four });
    lopt::optimize(&mut a3, &none, lopt::Config { inline: il::SPEED, loops: four });
    let tl3 = text_of(&a3, "lz");
    assert(
        tl3.contains("vop.count_ones.v8i16") && tl3.contains("or.v8i16") && !tl3.contains("leading_zeros"),
        tl3.as_str(),
    );
    let tp2 = text_of(&a2, "pop");
    assert(tp2.contains("vop.swizzle_or_zero.v16i8") && !tp2.contains("lshr.v2i64"), tp2.as_str());
    // Without one, the count of 4-byte lanes by shifts, masks and adds (`swar_count`).
    let tp = text_of(&a0, "pop");
    assert(tp.contains("lshr.v2i64") && tp.contains("lshr.v4i32") && !tp.contains("popcnt.v"), tp.as_str());
    let tp1 = text_of(&a1, "pop");
    assert(!tp1.contains("vop.") && tp1.contains("popcnt"), tp1.as_str());
    let wants: [(str, str); 3] = [
        ("pop", "vop.count_ones.v4i32"),
        ("lz", "vop.leading_zeros.v8i16"),
        ("swap", "vop.swap_bytes.v2i64"),
    ];
    for k in 0..3usize {
        let (f, want) = unsafe wants[k];
        let t = text_of(&a, f);
        assert(t.contains(want), t.as_str());
        let t0 = text_of(&a0, f);
        assert(k == 0 || !t0.contains("vop."), t0.as_str());
    }
    for n in 0..65u64 {
        let args: []u64 = [n];
        let want = run_value(&b, "drive", args);
        same_outcome(&b, &a, "drive", args, want, false);
        same_outcome(&b, &a0, "drive", args, want, false);
        same_outcome(&b, &a1, "drive", args, want, false);
        same_outcome(&b, &a2, "drive", args, want, false);
        same_outcome(&b, &a3, "drive", args, want, false);
    }
}

// Products of two sign-extended or two zero-extended values (or of one and a constant its narrow type
// holds) vectorize as the narrow lanes' widening products (`O_VMULW`, `Package.vec_mulw`): a 64-bit sum of
// 32-bit products, a square of a 32-bit unsigned value, a 64-bit product of 16-bit values (a 32-bit
// widening product extended), and a product beside a byte extension, whose vectors split (`lir::wide`: the
// high halves' products). A sign extension times a zero extension stays scalar; without the target's forms
// the products stay as they were. Each runs as before.
const WIDENED: str = M"(lir ptr 8
sym @dot fn global noinline
sym @sq fn global noinline
sym @mixed fn global noinline
sym @mix8 fn global noinline
sym @wide4 fn global noinline
sym @fold fn global noinline
sym @drive fn global
fn @dot
  sig (ptr, ptr, i64) -> i64
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v2
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = sext.i64 v9
  v11 = ptradd v1, v5 * 4
  v12 = load.i32 v11 align 2
  v13 = sext.i64 v12
  v14 = mul.i64 v10, v13
  v15 = add.i64 v6, v14
  v16 = add.i64 v5, v4
  jmp b1(v16, v15)
b3:
  ret v6
fn @sq
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = zext.i64 v8
  v10 = mul.i64 v9, v9
  v11 = ptradd v0, v5 * 8
  store v10, v11 align 3
  v12 = add.i64 v5, v4
  jmp b1(v12)
b3:
  ret
fn @mixed
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 4
  v8 = load.i32 v7 align 2
  v9 = zext.i64 v8
  v10 = sext.i64 v8
  v11 = mul.i64 v9, v10
  v12 = ptradd v0, v5 * 8
  store v11, v12 align 3
  v13 = add.i64 v5, v4
  jmp b1(v13)
b3:
  ret
fn @mix8
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 -5
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = ptradd v1, v7 * 4
  v10 = load.i32 v9 align 2
  v11 = sext.i64 v10
  v12 = mul.i64 v11, v6
  v13 = ptradd v2, v7 * 1
  v14 = load.i8 v13 align 0
  v15 = zext.i64 v14
  v16 = add.i64 v12, v15
  v17 = ptradd v0, v7 * 8
  store v16, v17 align 3
  v18 = add.i64 v7, v5
  jmp b1(v18)
b3:
  ret
fn @wide4
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 2
  v8 = load.i16 v7 align 1
  v9 = sext.i64 v8
  v10 = ptradd v1, v5 * 2
  v11 = load.i16 v10+128 align 1
  v12 = sext.i64 v11
  v13 = mul.i64 v9, v12
  v14 = ptradd v0, v5 * 8
  store v13, v14 align 3
  v15 = add.i64 v5, v4
  jmp b1(v15)
b3:
  ret
fn @fold
  sig (ptr, i64, i64) -> i64
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 31
  jmp b1(v3, v2)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 8
  v10 = load.i64 v9 align 3
  v11 = mul.i64 v7, v5
  v12 = xor.i64 v11, v10
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b3:
  ret v7
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 8
  slot s1 size 512 align 8
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 64
  v6 = iconst.i64 -7046029254386353131
  v7 = iconst.i64 23
  jmp b1(v3, v0)
b1(v8: i64, v9: i64):
  v10 = icmp.ult v8, v5
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v6
  v12 = add.i64 v11, v8
  v13 = lshr.i64 v12, v7
  v14 = xor.i64 v12, v13
  v15 = ptradd v1, v8 * 8
  store v14, v15 align 3
  v16 = add.i64 v8, v4
  jmp b1(v16, v12)
b3:
  v17 = ptradd v1+256
  v18 = call.i64 @dot(v1, v17, v0) : (ptr, ptr, i64) -> i64
  call @sq(v2, v1, v0) : (ptr, ptr, i64) -> void
  v19 = call.i64 @fold(v2, v0, v18) : (ptr, i64, i64) -> i64
  call @mixed(v2, v17, v0) : (ptr, ptr, i64) -> void
  v20 = call.i64 @fold(v2, v0, v19) : (ptr, i64, i64) -> i64
  call @mix8(v2, v1, v17, v0) : (ptr, ptr, ptr, i64) -> void
  v21 = call.i64 @fold(v2, v0, v20) : (ptr, i64, i64) -> i64
  call @wide4(v2, v1, v0) : (ptr, ptr, i64) -> void
  v22 = call.i64 @fold(v2, v0, v21) : (ptr, i64, i64) -> i64
  ret v22
)";

@test
fn widening_products_vectorize_as_the_narrow_lanes_products() {
    let two = lu::Budgets {
        peel: 0,
        partial: 0,
        version: 0,
        version_checks: u32::MAX,
        unswitch: 0,
        rotate: 0,
        vector: 2,
        interleave: 2,
        fin: 0,
    };
    let mut err = String::new();
    let b = lparse::parse(WIDENED, &mut err).unwrap();
    let mut a = lparse::parse(WIDENED, &mut err).unwrap();
    a.vector = 16;
    a.vops = VOPS_ALL;
    a.vec_mulw = 0x707;
    let mut a0 = lparse::parse(WIDENED, &mut err).unwrap();
    a0.vector = 16;
    a0.vops = VOPS_ALL;
    a0.vec_mulw = 0;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: two });
    lopt::optimize(&mut a0, &none, lopt::Config { inline: il::SPEED, loops: two });
    let wants: [(str, str); 4] = [
        ("dot", "vmulw.s.v2i64"),
        ("sq", "vmulw.v2i64"),
        ("mix8", "vmulw.s.hi.v2i64"),
        ("wide4", "vmulw.s.v4i32"),
    ];
    for k in 0..4usize {
        let (f, want) = unsafe wants[k];
        let t = text_of(&a, f);
        assert(t.contains(want), t.as_str());
        let t0 = text_of(&a0, f);
        assert(!t0.contains("vmulw"), t0.as_str());
    }
    let tm = text_of(&a, "mixed");
    assert(!tm.contains("vmulw") && !tm.contains("mul.v"), tm.as_str());
    for n in 0..65u64 {
        let args: []u64 = [n];
        let want = run_value(&b, "drive", args);
        same_outcome(&b, &a, "drive", args, want, false);
        same_outcome(&b, &a0, "drive", args, want, false);
    }
}

// Scans: a last-index search counting down from a slice's length with an early exit reads every element
// below the counter (`counted_down`), not one from another slice's length; a scan with no bound (a NUL-terminated string through an index, a
// 32-bit one through a stepping pointer) enters a vector loop of aligned block loads (`aligned_scan`,
// MEM_BLOCK) once its address is aligned. The strings end at every position, and at the last byte of a
// 100-byte slot, whose last aligned block reaches past it. Each runs as before.
const SCANS: str = M"(lir ptr 8
sym @slen fn global noinline
sym @slen32 fn global noinline
sym @rfind fn global noinline
sym @rfrom fn global noinline
sym @drive fn global
fn @slen
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i64 0
  v2 = iconst.i8 0
  v3 = iconst.i64 1
  jmp b1(v1)
b1(v4: i64):
  v5 = ptradd v0, v4 * 1
  v6 = load.i8 v5 align 0
  v7 = icmp.ne v6, v2
  br v7, b2, b3
b2:
  v8 = add.i64 v4, v3
  jmp b1(v8)
b3:
  ret v4
fn @slen32
  sig (ptr) -> i64
b0(v0: ptr):
  v1 = iconst.i32 0
  jmp b1(v0)
b1(v2: ptr):
  v3 = load.i32 v2 align 2
  v4 = icmp.ne v3, v1
  br v4, b2, b3
b2:
  v5 = ptradd v2+4
  jmp b1(v5)
b3:
  v6 = ptrtoint.i64 v2
  v7 = ptrtoint.i64 v0
  v8 = sub.i64 v6, v7
  ret v8
fn @rfind
  sig (ptr, i8) -> i64
b0(v0: ptr, v1: i8):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 -1
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ne v7, v4
  br v8, b2, b3
b2:
  v9 = sub.i64 v7, v5
  v10 = ptradd v2, v7 * 1
  v11 = load.i8 v10-1 align 0
  v12 = icmp.eq v11, v1
  br v12, b4, b1(v9)
b3:
  ret v6
b4:
  ret v9
fn @rfrom
  sig (ptr, ptr, i8) -> i64
b0(v0: ptr, v1: ptr, v2: i8):
  v3 = load.ptr v0 align 3
  v4 = load.i64 v1+8 align 3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 -1
  jmp b1(v4)
b1(v8: i64):
  v9 = icmp.ne v8, v5
  br v9, b2, b3
b2:
  v10 = sub.i64 v8, v6
  v11 = ptradd v3, v8 * 1
  v12 = load.i8 v11-1 align 0
  v13 = icmp.eq v12, v2
  br v13, b4, b1(v10)
b3:
  ret v7
b4:
  ret v10
fn @drive
  sig (i64) -> i64
  slot s0 size 100 align 4
  slot s1 size 100 align 4
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 100
  v7 = iconst.i64 -7046029254386353131
  v8 = iconst.i64 29
  v9 = iconst.i8 1
  jmp b1(v4, v0)
b1(v10: i64, v11: i64):
  v12 = icmp.ult v10, v6
  br v12, b2, b3
b2:
  v13 = mul.i64 v11, v7
  v14 = add.i64 v13, v5
  v15 = lshr.i64 v14, v8
  v16 = trunc.i8 v15
  v17 = or.i8 v16, v9
  v18 = ptradd v1, v10 * 1
  store v17, v18 align 0
  v19 = ptradd v2, v10 * 1
  store v17, v19 align 0
  v20 = add.i64 v10, v5
  jmp b1(v20, v14)
b3:
  v21 = iconst.i8 0
  v22 = ptradd v1, v0 * 1
  store v21, v22 align 0
  store v21, v1+99 align 0
  v23 = iconst.i64 25
  v24 = urem.i64 v0, v23
  v25 = iconst.i32 0
  v26 = ptradd v2, v24 * 4
  store v25, v26 align 2
  store v25, v2+96 align 2
  store v1, v3 align 3
  store v6, v3+8 align 3
  v27 = call.i64 @slen(v1) : (ptr) -> i64
  v28 = call.i64 @slen32(v2) : (ptr) -> i64
  v29 = iconst.i64 37
  v30 = mul.i64 v0, v29
  v31 = iconst.i64 97
  v32 = urem.i64 v30, v31
  v33 = ptradd v1, v32 * 1
  v34 = load.i8 v33 align 0
  v35 = call.i64 @rfind(v3, v34) : (ptr, i8) -> i64
  v36 = iconst.i64 1000
  v37 = mul.i64 v28, v36
  v38 = mul.i64 v35, v36
  v39 = mul.i64 v38, v36
  v40 = add.i64 v27, v37
  v41 = add.i64 v40, v39
  v42 = slotaddr s3
  store v1, v42 align 3
  store v6, v42+8 align 3
  v43 = call.i64 @rfrom(v42, v3, v34) : (ptr, ptr, i8) -> i64
  v44 = xor.i64 v41, v43
  ret v44
)";

@test
fn scans_vectorize_counting_down_and_without_a_bound() {
    let (b, a) = optimized_for(
        SCANS,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let ts = text_of(&a, "slen");
    assert(ts.contains("load.v16i8") && ts.contains(" block"), ts.as_str());
    let tw = text_of(&a, "slen32");
    assert(tw.contains("load.v4i32") && tw.contains(" block"), tw.as_str());
    let tr = text_of(&a, "rfind");
    assert(tr.contains("vcmp.eq.v16i8") && !tr.contains(" block"), tr.as_str());
    // From another slice's length: the lanes below the exit may lie before the slice.
    let tf = text_of(&a, "rfrom");
    assert(!tf.contains("vcmp"), tf.as_str());
    for k in 0..100u64 {
        let args: []u64 = [k];
        let want = run_value(&b, "drive", args);
        same_outcome(&b, &a, "drive", args, want, false);
    }
}

// A counted loop of 64 iterations, within the peeling budget, that fills two vectors or more vectorizes
// first: its product of an invariant and the counter reads the counter's lanes (the counter in every lane
// plus the lane's iteration). The stores then are vector stores, not 64 scalar ones. The vector iterations
// divide the count, so the vector loop ends with them (no overlapping last one) and peels: 16 stores, no
// branch, and each iteration's counter lanes a constant.
@test
fn a_loop_that_fills_vectors_vectorizes_before_it_peels() {
    let (b, a) = optimized_for(
        M"(lir ptr 8
sym @fill fn global
fn @fill
  sig (ptr, i32) -> void
  ref p0 256 noalias
b0(v0: ptr, v1: i32):
  v2 = iconst.i32 0
  v3 = iconst.i32 64
  v4 = iconst.i32 1
  jmp b1(v2)
b1(v5: i32):
  v6 = icmp.slt v5, v3
  br v6, b3, b2
b2:
  ret
b3:
  v7 = mul.i32 v1, v5
  v8 = zext.i64 v5
  v9 = ptradd v0, v8 * 4 inbounds
  store v7, v9 align 2
  v10 = add.i32 v5, v4
  jmp b1(v10)
)",
        lu::Budgets {
            peel: 300,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 1,
            interleave: 1,
            fin: 0,
        },
        16,
        0,
    );
    let f = text_of(&a, "fill");
    assert(
        f.contains("mul.v4i32") && count(&f, "store") == 16 && !f.contains("br ") && !f.contains("add.v4i32"),
        f.as_str(),
    );
    let _ = b;
}

// Reductions of a select or a C call: a `fmaxf` call's lanes start at the start value (each lane may take
// it again), not at 0, which would be the maximum of negative elements; a float min whose select keeps the
// accumulator when the comparison holds (`s < x ? s : x`) widens where the build has no NaN (`FM_FINITE`,
// with `FM_NSZ`), and stays scalar with NaNs; an update a select takes or skips (`s = c ? s op x : s`)
// takes the operand where the condition holds and the operation's identity elsewhere (`cond_red`): an
// integer sum, an `and` on the other side, a product, and a float sum where the build reassociates.
const SELECTED: str = M"(lir ptr 8
sym @fmaxf fn global
sym @mx fn global noinline
sym @smin fn global noinline
sym @csum fn global noinline
sym @cand fn global noinline
sym @cmul fn global noinline
sym @cfadd fn global noinline
sym @drive fn global
fn @mx
  sig (ptr, i64) -> f32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = fconst.f32 0xff800000
  jmp b1(v2, v4)
b1(v5: i64, v6: f32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.f32 v8 align 2
  v10 = call.f32 @fmaxf(v6, v9) : (f32, f32) -> f32
  v11 = add.i64 v5, v3
  jmp b1(v11, v10)
b3:
  ret v6
fn @smin
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
  v10 = fcmp.olt v6, v9
  v11 = select.f32 v10, v6, v9
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b3:
  ret v6
fn @csum
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
  v11 = icmp.sgt v10, v2
  v12 = add.i32 v7, v10
  v13 = select.i32 v11, v12, v7
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
b3:
  ret v7
fn @cand
  sig (ptr, i64) -> i8
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i8 -1
  v5 = iconst.i8 16
  jmp b1(v2, v4)
b1(v6: i64, v7: i8):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 1
  v10 = load.i8 v9 align 0
  v11 = icmp.slt v10, v5
  v12 = and.i8 v10, v7
  v13 = select.i8 v11, v7, v12
  v14 = add.i64 v6, v3
  jmp b1(v14, v13)
b3:
  ret v7
fn @cmul
  sig (ptr, i64) -> i16
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i16 1
  v5 = iconst.i16 3
  jmp b1(v2, v4)
b1(v6: i64, v7: i16):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 2
  v10 = load.i16 v9 align 1
  v11 = and.i16 v10, v5
  v12 = icmp.eq v11, v4
  v13 = mul.i16 v7, v10
  v14 = select.i16 v12, v13, v7
  v15 = add.i64 v6, v3
  jmp b1(v15, v14)
b3:
  ret v7
fn @cfadd
  sig (ptr, i64) -> f32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = fconst.f32 0x0
  jmp b1(v2, v4)
b1(v5: i64, v6: f32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.f32 v8 align 2
  v10 = fcmp.ogt v9, v4
  v11 = fadd.f32 v6, v9
  v12 = select.f32 v10, v11, v6
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
fn @drive
  sig (i64, i32) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 64
  v7 = iconst.i32 37
  v8 = iconst.i32 85
  v9 = iconst.i32 101
  v10 = iconst.i32 50
  jmp b1(v4)
b1(v11: i64):
  v12 = icmp.ult v11, v6
  br v12, b2, b3
b2:
  v13 = trunc.i32 v11
  v14 = mul.i32 v13, v7
  v15 = xor.i32 v14, v8
  v16 = srem.i32 v15, v9
  v17 = sub.i32 v16, v10
  v18 = ptradd v2, v11 * 4
  store v17, v18 align 2
  v19 = sitofp.f32 v17
  v20 = ptradd v3, v11 * 4
  store v19, v20 align 2
  v21 = add.i64 v11, v5
  jmp b1(v21)
b3:
  v22 = call.i32 @csum(v2, v0, v1) : (ptr, i64, i32) -> i32
  v23 = call.i8 @cand(v2, v0) : (ptr, i64) -> i8
  v24 = call.i16 @cmul(v2, v0) : (ptr, i64) -> i16
  v25 = call.f32 @smin(v3, v0) : (ptr, i64) -> f32
  v26 = call.f32 @cfadd(v3, v0) : (ptr, i64) -> f32
  v27 = sext.i64 v22
  v28 = zext.i64 v23
  v29 = iconst.i64 32
  v30 = shl.i64 v28, v29
  v31 = xor.i64 v27, v30
  v32 = zext.i64 v24
  v33 = iconst.i64 40
  v34 = shl.i64 v32, v33
  v35 = xor.i64 v31, v34
  v36 = bitcast.i32 v25
  v37 = zext.i64 v36
  v38 = iconst.i64 7
  v39 = shl.i64 v37, v38
  v40 = xor.i64 v35, v39
  v41 = bitcast.i32 v26
  v42 = zext.i64 v41
  v43 = iconst.i64 13
  v44 = shl.i64 v42, v43
  v45 = xor.i64 v40, v44
  ret v45
)";

@test
fn selected_and_called_reductions_vectorize() {
    let (b, a) = optimized_fm(SELECTED, VECTOR, false, FM_FINITE | FM_NSZ | FM_ASSOC);
    let m = text_of(&a, "mx");
    assert(m.contains("max.num.v4f32") && !m.contains("wconst.v4f32 0x0, 0x0"), m.as_str());
    let s = text_of(&a, "smin");
    assert(s.contains("vsel.v4f32") && s.contains("reduce_min"), s.as_str());
    let c = text_of(&a, "csum");
    assert(c.contains("vsel.v4i32") && c.contains("add.v4i32") && c.contains("reduce_add"), c.as_str());
    let d = text_of(&a, "cand");
    assert(d.contains("vsel.v16i8") && d.contains("and.v16i8") && d.contains("reduce_and"), d.as_str());
    let p = text_of(&a, "cmul");
    assert(p.contains("vsel.v8i16") && p.contains("mul.v8i16") && p.contains("reduce_mul"), p.as_str());
    let f = text_of(&a, "cfadd");
    assert(f.contains("vsel.v4f32") && f.contains("fadd.v4f32") && f.contains("reduce_add"), f.as_str());
    // Counts below, at and past the vector loops' iterations; bounds below, inside and above the data.
    let lens: [u64; 9] = [0, 1, 3, 4, 15, 16, 17, 33, 64];
    let bounds: [u64; 3] = [0xFFFFFF9C, 7, 60];
    for k in 0..9usize {
        for q in 0..3usize {
            let args: []u64 = [unsafe lens[k], unsafe bounds[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
    // With NaNs the select's negation keeps them: the float min stays scalar.
    let (_, e) = optimized_fm(SELECTED, VECTOR, false, FM_NSZ);
    let s2 = text_of(&e, "smin");
    assert(!s2.contains("v4f32"), s2.as_str());
}

// A group of fields a loop loads and stores in place (`p[i] = (3 * p[i].y, p[i].x ^ 85)`) vectorizes: its
// loads unzip before the group's interleaved store, and an access at another field of each step touches no
// byte the other field's store writes (`distance_ok`). A load of the previous group's field (`p[i - 1].y`)
// reads what the last iteration stored: that loop stays scalar.
const GROUPS: str = M"(lir ptr 8
sym @swap fn global noinline
sym @prevy fn global noinline
sym @drive fn global
fn @swap
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 3
  v5 = iconst.i32 85
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 8
  v9 = load.i32 v8 align 2
  v10 = load.i32 v8+4 align 2
  v11 = mul.i32 v10, v4
  store v11, v8 align 2
  v12 = xor.i32 v9, v5
  store v12, v8+4 align 2
  v13 = add.i64 v6, v3
  jmp b1(v13)
b3:
  ret
fn @prevy
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 1
  jmp b1(v2)
b1(v3: i64):
  v4 = icmp.ult v3, v1
  br v4, b2, b3
b2:
  v5 = ptradd v0, v3 * 8
  v6 = load.i32 v5-4 align 2
  v7 = load.i32 v5 align 2
  v8 = add.i32 v7, v6
  store v8, v5+4 align 2
  store v6, v5 align 2
  v9 = add.i64 v3, v2
  jmp b1(v9)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 128
  v5 = iconst.i32 -1640531535
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v4
  br v7, b2, b6
b2:
  v8 = trunc.i32 v6
  v9 = mul.i32 v8, v5
  v10 = ptradd v1, v6 * 4
  store v9, v10 align 2
  v11 = add.i64 v6, v3
  jmp b1(v11)
b3(v12: i64, v13: i64):
  v14 = icmp.ult v12, v4
  br v14, b4, b5
b4:
  v15 = ptradd v1, v12 * 4
  v16 = load.i32 v15 align 2
  v17 = zext.i64 v16
  v18 = iconst.i64 1000003
  v19 = mul.i64 v13, v18
  v20 = xor.i64 v19, v17
  v21 = add.i64 v12, v3
  jmp b3(v21, v20)
b5:
  ret v13
b6:
  call @swap(v1, v0) : (ptr, i64) -> void
  call @prevy(v1, v0) : (ptr, i64) -> void
  jmp b3(v2, v2)
)";

@test
fn a_group_loaded_and_stored_in_place_vectorizes() {
    let (b, a) = optimized(GROUPS, VECTOR);
    let s = text_of(&a, "swap");
    assert(s.contains("vunzip.v4i32") && s.contains("vziplo.v4i32") && s.contains("mul.v4i32"), s.as_str());
    let p = text_of(&a, "prevy");
    assert(!p.contains("v4i32"), p.as_str());
    let lens: [u64; 8] = [0, 1, 2, 7, 8, 9, 17, 64];
    for k in 0..8usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A counter stepping by a power of 2 is a lane value too (`vector_ctr`: its lanes `i + k * step`): sums of
// every 2nd element combined with the counter's truncation, and with the counter itself from 1.
const STEPPED: str = M"(lir ptr 8
sym @two fn global noinline
sym @four fn global noinline
sym @drive fn global
fn @two
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
  v10 = trunc.i32 v5
  v11 = xor.i32 v9, v10
  v12 = add.i32 v6, v11
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
fn @four
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 1
  v3 = iconst.i64 2
  v4 = iconst.i64 0
  jmp b1(v2, v4)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 8
  v9 = load.i64 v8 align 3
  v10 = xor.i64 v9, v5
  v11 = add.i64 v6, v10
  v12 = add.i64 v5, v3
  jmp b1(v12, v11)
b3:
  ret v6
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 128
  v5 = iconst.i64 -7046029254386353131
  jmp b1(v2)
b1(v6: i64):
  v7 = icmp.ult v6, v4
  br v7, b2, b3
b2:
  v8 = mul.i64 v6, v5
  v9 = ptradd v1, v6 * 8
  store v8, v9 align 3
  v10 = add.i64 v6, v3
  jmp b1(v10)
b3:
  v11 = call.i32 @two(v1, v0) : (ptr, i64) -> i32
  v12 = call.i64 @four(v1, v0) : (ptr, i64) -> i64
  v13 = sext.i64 v11
  v14 = iconst.i64 17
  v15 = shl.i64 v12, v14
  v16 = xor.i64 v13, v15
  ret v16
)";

@test
fn a_counter_stepping_by_a_power_of_two_is_a_lane_value() {
    let (b, a) = optimized(STEPPED, VECTOR);
    let t = text_of(&a, "two");
    assert(t.contains("vunzip.v4i32") && t.contains("xor.v4i32"), t.as_str());
    let f = text_of(&a, "four");
    assert(f.contains("xor.v2i64") && f.contains("reduce_add"), f.as_str());
    let lens: [u64; 10] = [0, 1, 2, 3, 8, 9, 16, 17, 33, 128];
    for k in 0..10usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A value stepping by a constant beside the counter (an induction, `j += k`) is a lane value: its value
// at the counter's iteration plus each lane's iterations times the step (`ind_at`, `vector_ramp`), and
// the loop that runs the rest starts from its value where the vectors stop: before and after its update,
// stepping down, wrapping, and with the counter stepping by 2.
const INDUCTIONS: str = M"(lir ptr 8
sym @up fn global noinline
sym @down fn global noinline
sym @every2 fn global noinline
sym @drive fn global
fn @up
  sig (ptr, ptr, i64, i32) -> i32
b0(v0: ptr, v1: ptr, v2: i64, v3: i32):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 3
  jmp b1(v4, v3)
b1(v7: i64, v8: i32):
  v9 = icmp.ult v7, v2
  br v9, b2, b3
b2:
  v10 = ptradd v1, v7 * 4
  v11 = load.i32 v10 align 2
  v12 = xor.i32 v11, v8
  v13 = ptradd v0, v7 * 4
  store v12, v13 align 2
  v14 = add.i32 v8, v6
  v15 = add.i64 v7, v5
  jmp b1(v15, v14)
b3:
  ret v8
fn @down
  sig (ptr, i64) -> i16
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i16 7
  v5 = iconst.i16 -32760
  jmp b1(v2, v5)
b1(v6: i64, v7: i16):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = sub.i16 v7, v4
  v10 = ptradd v0, v6 * 2
  store v9, v10 align 1
  v11 = add.i64 v6, v3
  jmp b1(v11, v9)
b3:
  ret v7
fn @every2
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 2
  v4 = iconst.i32 0
  v5 = iconst.i32 5
  v6 = iconst.i32 1000
  jmp b1(v2, v4, v6)
b1(v7: i64, v8: i32, v9: i32):
  v10 = icmp.ult v7, v1
  br v10, b2, b3
b2:
  v11 = ptradd v0, v7 * 4
  v12 = load.i32 v11 align 2
  v13 = xor.i32 v12, v9
  v14 = add.i32 v8, v13
  v15 = add.i32 v9, v5
  v16 = add.i64 v7, v3
  jmp b1(v16, v14, v15)
b3:
  v17 = xor.i32 v8, v9
  ret v17
fn @drive
  sig (i64, i32) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 256 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 128
  v8 = iconst.i32 -1640531535
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = trunc.i32 v9
  v12 = mul.i32 v11, v8
  v13 = ptradd v2, v9 * 4
  store v12, v13 align 2
  v14 = add.i64 v9, v6
  jmp b1(v14)
b3:
  v15 = call.i32 @up(v3, v2, v0, v1) : (ptr, ptr, i64, i32) -> i32
  v16 = call.i16 @down(v4, v0) : (ptr, i64) -> i16
  v17 = call.i32 @every2(v2, v0) : (ptr, i64) -> i32
  v18 = sext.i64 v15
  v19 = zext.i64 v16
  v20 = iconst.i64 32
  v21 = shl.i64 v19, v20
  v22 = xor.i64 v18, v21
  v23 = sext.i64 v17
  v24 = iconst.i64 11
  v25 = shl.i64 v23, v24
  v26 = xor.i64 v22, v25
  jmp b4(v5, v26)
b4(v27: i64, v28: i64):
  v29 = icmp.ult v27, v7
  br v29, b5, b6
b5:
  v30 = ptradd v3, v27 * 4
  v31 = load.i32 v30 align 2
  v32 = ptradd v4, v27 * 2
  v33 = load.i16 v32 align 1
  v34 = sext.i64 v31
  v35 = zext.i64 v33
  v36 = iconst.i64 1000003
  v37 = mul.i64 v28, v36
  v38 = xor.i64 v37, v34
  v39 = xor.i64 v38, v35
  v40 = add.i64 v27, v6
  jmp b4(v40, v39)
b6:
  ret v28
)";

@test
fn inductions_beside_the_counter_vectorize() {
    let (b, a) = optimized(INDUCTIONS, VECTOR);
    let u = text_of(&a, "up");
    assert(u.contains("xor.v4i32") && u.contains("splat.v4i32"), u.as_str());
    let d = text_of(&a, "down");
    assert(d.contains("v8i16"), d.as_str());
    let e = text_of(&a, "every2");
    assert(e.contains("vunzip.v4i32") && e.contains("reduce_add"), e.as_str());
    let lens: [u64; 10] = [0, 1, 2, 3, 8, 9, 16, 17, 33, 128];
    let starts: [u64; 3] = [0, 0x7FFFFFFF, 0xFFFFFFF0];
    for k in 0..10usize {
        for q in 0..3usize {
            let args: []u64 = [unsafe lens[k], unsafe starts[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A branch on the counter (`if i < m { c[i] = a[i] + 2 }`, the element loaded before it) linearizes: the
// counter's lanes compared (`vector_ctr`) into the mask of the store, on both of the test's forms.
const COUNTER_BRANCH: str = M"(lir ptr 8
sym @below fn global noinline
sym @from fn global noinline
sym @drive fn global
fn @below
  sig (ptr, ptr, i64, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 2
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b5
b2:
  v9 = ptradd v1, v7 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.ult v7, v2
  br v11, b3, b4
b3:
  v12 = add.i32 v10, v6
  v13 = ptradd v0, v7 * 4
  store v12, v13 align 2
  jmp b4
b4:
  v14 = add.i64 v7, v5
  jmp b1(v14)
b5:
  ret
fn @from
  sig (ptr, ptr, i64, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b5
b2:
  v8 = ptradd v1, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.ugt v2, v6
  br v10, b4, b3
b3:
  v11 = ptradd v0, v6 * 4
  store v9, v11 align 2
  jmp b4
b4:
  v12 = add.i64 v6, v5
  jmp b1(v12)
b5:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 128
  v7 = iconst.i32 -1640531535
  v8 = iconst.i32 9
  jmp b1(v4)
b1(v9: i64):
  v10 = icmp.ult v9, v6
  br v10, b2, b3
b2:
  v11 = trunc.i32 v9
  v12 = mul.i32 v11, v7
  v13 = ptradd v2, v9 * 4
  store v12, v13 align 2
  v14 = ptradd v3, v9 * 4
  store v8, v14 align 2
  v15 = add.i64 v9, v5
  jmp b1(v15)
b3:
  call @below(v3, v2, v1, v0) : (ptr, ptr, i64, i64) -> void
  v16 = ptradd v3+256
  call @from(v16, v2, v1, v0) : (ptr, ptr, i64, i64) -> void
  jmp b4(v4, v4)
b4(v17: i64, v18: i64):
  v19 = icmp.ult v17, v6
  br v19, b5, b6
b5:
  v20 = ptradd v3, v17 * 4
  v21 = load.i32 v20 align 2
  v22 = zext.i64 v21
  v23 = iconst.i64 1000003
  v24 = mul.i64 v18, v23
  v25 = xor.i64 v24, v22
  v26 = add.i64 v17, v5
  jmp b4(v26, v25)
b6:
  ret v18
)";

@test
fn a_branch_on_the_counter_linearizes() {
    let (b, a) = optimized_for(COUNTER_BRANCH, VECTOR, 16, VOPS_ALL);
    let w = text_of(&a, "below");
    assert(w.contains("store_masked_ptr") && w.contains("add.v2i64"), w.as_str());
    let f = text_of(&a, "from");
    assert(f.contains("store_masked_ptr"), f.as_str());
    let lens: [u64; 7] = [0, 1, 3, 4, 9, 17, 64];
    let bounds: [u64; 5] = [0, 1, 6, 63, 1000];
    for k in 0..7usize {
        for q in 0..5usize {
            let args: []u64 = [unsafe lens[k], unsafe bounds[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A count beside a masked store (`if c[i] > k { c[i] = k; n += 1 }`): the count's step is a select of 1
// and the body's constant 0 (`cond_step`), which is no load a store may write (`vchecks`).
const COUNTED_STORE: str = M"(lir ptr 8
sym @clamp fn global noinline
sym @drive fn global
fn @clamp
  sig (ptr, i64, i32) -> i64
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v3)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v1
  br v7, b2, b5
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.sgt v9, v2
  br v10, b3, b4(v6)
b3:
  store v2, v8 align 2
  v11 = add.i64 v6, v4
  jmp b4(v11)
b4(v12: i64):
  v13 = add.i64 v5, v4
  jmp b1(v13, v12)
b5:
  ret v6
fn @drive
  sig (i64, i32) -> i64
  slot s0 size 512 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i32 37
  v7 = iconst.i32 101
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v5
  br v9, b2, b3
b2:
  v10 = trunc.i32 v8
  v11 = mul.i32 v10, v6
  v12 = srem.i32 v11, v7
  v13 = ptradd v2, v8 * 4
  store v12, v13 align 2
  v14 = add.i64 v8, v4
  jmp b1(v14)
b3:
  v15 = call.i64 @clamp(v2, v0, v1) : (ptr, i64, i32) -> i64
  jmp b4(v3, v15)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v5
  br v18, b5, b6
b5:
  v19 = ptradd v2, v16 * 4
  v20 = load.i32 v19 align 2
  v21 = sext.i64 v20
  v22 = iconst.i64 1000003
  v23 = mul.i64 v17, v22
  v24 = xor.i64 v23, v21
  v25 = add.i64 v16, v4
  jmp b4(v25, v24)
b6:
  ret v17
)";

@test
fn a_count_beside_a_masked_store_vectorizes() {
    let (b, a) = optimized_for(COUNTED_STORE, VECTOR, 16, VOPS_ALL);
    let c = text_of(&a, "clamp");
    assert(c.contains("store_masked_ptr") && c.contains("reduce_add"), c.as_str());
    let lens: [u64; 7] = [0, 1, 3, 4, 9, 17, 128];
    let bounds: [u64; 4] = [0, 50, 100, 0xFFFFFFFF];
    for k in 0..7usize {
        for q in 0..4usize {
            let args: []u64 = [unsafe lens[k], unsafe bounds[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A reduction by std's `f32::maximum`, its selects (NaN when either is NaN, of equal values the `and` of
// the bits): lanes of `maximum` (`ieee_red`), from the start value in every lane. Each count and NaN
// position gives the bits it gave.
@test
fn a_maximum_reduction_keeps_maximum_lanes() {
    let src = M"(lir ptr 8
sym @maxr fn global noinline
sym @drive fn global
fn @maxr
  sig (ptr, i64, f32) -> f32
  ref p0 256 readonly
b0(v0: ptr, v1: i64, v2: f32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v2)
b1(v5: i64, v6: f32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.f32 v8 align 2
  v10 = bitcast.i32 v6
  v11 = bitcast.i32 v9
  v12 = and.i32 v10, v11
  v13 = bitcast.f32 v12
  v14 = fcmp.ogt v6, v9
  v15 = select.f32 v14, v6, v9
  v16 = fcmp.oeq v6, v9
  v17 = select.f32 v16, v13, v15
  v18 = fadd.f32 v6, v9
  v19 = fcmp.une v6, v6
  v20 = select.f32 v19, v18, v17
  v21 = fcmp.une v9, v9
  v22 = select.f32 v21, v18, v20
  v23 = add.i64 v5, v4
  jmp b1(v23, v22)
b3:
  ret v6
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 256 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 13
  v6 = iconst.i64 6
  v7 = fconst.f32 0x7fc00000
  v8 = fconst.f32 0x80000000
  jmp b1(v3)
b1(v9: i64):
  v10 = icmp.ult v9, v0
  br v10, b2, b3
b2:
  v11 = urem.i64 v9, v5
  v12 = sub.i64 v11, v6
  v13 = sitofp.f32 v12
  v14 = ptradd v2, v9 * 4
  v15 = icmp.eq v9, v1
  v16 = select.f32 v15, v7, v13
  store v16, v14 align 2
  v17 = add.i64 v9, v4
  jmp b1(v17)
b3:
  v18 = call.f32 @maxr(v2, v0, v8) : (ptr, i64, f32) -> f32
  v19 = bitcast.i32 v18
  v20 = zext.i64 v19
  ret v20
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "maxr");
    assert(t.contains("vop.maximum.v4f32"), t.as_str());
    let ns: [u64; 5] = [0, 1, 7, 8, 37];
    for k in 0..5usize {
        for at in 0u64..9 {
            let args: []u64 = [unsafe ns[k], at * 5];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// An else-if chain (TSVC s441) whose inner sides the optimizer merged into a load through a select of two
// slices' pointers: if-conversion loads from both slices, each at least as long as the loop's bound, and
// selects (`split_all`), so the loop vectorizes. Each count gives the elements it gave.
@test
fn a_load_through_a_select_of_two_slices_vectorizes() {
    let src = M"(lir ptr 8
sym @f fn global noinline
sym @drive fn global
fn @f
  sig (ptr, ptr, ptr) -> void
  ref p0 16 noalias
  ref p1 16 readonly
  ref p2 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = fconst.f32 0x0
  v6 = fconst.f32 0x3f800000
  v7 = load.i64 v0+8 align 3
  v8 = load.ptr v0 align 3
  v9 = load.i64 v1+8 align 3
  v10 = load.ptr v1 align 3
  v11 = load.i64 v2+8 align 3
  v12 = load.ptr v2 align 3
  v13 = icmp.ule v7, v9
  v14 = icmp.ule v7, v11
  v15 = and.i8 v13, v14
  br v15, b1(v3), b6
b1(v16: i64):
  v17 = icmp.ult v16, v7
  br v17, b2, b6
b2:
  v18 = ptradd v8, v16 * 4
  v19 = load.f32 v18 align 2
  v20 = fcmp.olt v19, v5
  br v20, b3, b4
b3:
  v21 = ptradd v10, v16 * 4
  v22 = load.f32 v21 align 2
  store v22, v18 align 2
  jmp b5
b4:
  v23 = fcmp.ogt v19, v6
  v24 = select.ptr v23, v10, v12
  v25 = ptradd v24, v16 * 4
  v26 = load.f32 v25 align 2
  v27 = fadd.f32 v26, v19
  store v27, v18 align 2
  jmp b5
b5:
  v28 = add.i64 v16, v4
  jmp b1(v28)
b6:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 256 align 3
  slot s2 size 256 align 3
  slot s3 size 48 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 5
  v8 = iconst.i64 2
  v9 = iconst.i64 64
  v10 = iconst.i64 3
  v11 = iconst.i64 131
  store v1, v4 align 3
  store v0, v4+8 align 3
  store v2, v4+16 align 3
  store v9, v4+24 align 3
  store v3, v4+32 align 3
  store v9, v4+40 align 3
  jmp b1(v5)
b1(v12: i64):
  v13 = icmp.ult v12, v9
  br v13, b2, b3
b2:
  v14 = urem.i64 v12, v7
  v15 = sub.i64 v14, v8
  v16 = sitofp.f32 v15
  v17 = ptradd v1, v12 * 4
  store v16, v17 align 2
  v18 = mul.i64 v12, v10
  v19 = sitofp.f32 v18
  v20 = ptradd v2, v12 * 4
  store v19, v20 align 2
  v21 = sub.i64 v5, v12
  v22 = sitofp.f32 v21
  v23 = ptradd v3, v12 * 4
  store v22, v23 align 2
  v24 = add.i64 v12, v6
  jmp b1(v24)
b3:
  v25 = ptradd v4+16
  v26 = ptradd v4+32
  call @f(v4, v25, v26) : (ptr, ptr, ptr) -> void
  jmp b4(v5, v5)
b4(v27: i64, v28: i64):
  v29 = icmp.ult v27, v9
  br v29, b5, b6
b5:
  v30 = ptradd v1, v27 * 4
  v31 = load.f32 v30 align 2
  v32 = fptosi.i64 v31
  v33 = mul.i64 v28, v11
  v34 = add.i64 v33, v32
  v35 = add.i64 v27, v6
  jmp b4(v35, v34)
b6:
  ret v28
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "f");
    assert(t.contains("fadd.v4f32"), t.as_str());
    let ns: [u64; 6] = [0, 1, 3, 4, 9, 37];
    for k in 0..6usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A loop counting down over pairs, `while i != 0 { i -= 1; (p[i].x, p[i].y) = (p[i].y + 1, p[i].x) }`:
// each vector holds its pairs in order, the group loaded from each pair's first field (`group_start`)
// and stored back, the copies' groups from the highest down. Each count gives the elements it gave.
@test
fn a_group_of_fields_counting_down_vectorizes() {
    let src = M"(lir ptr 8
sym @swap fn global noinline
sym @drive fn global
fn @swap
  sig (ptr, i64) -> void
  ref p0 512 noalias
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 1
  jmp b1(v1)
b1(v5: i64):
  v6 = icmp.ne v5, v2
  br v6, b2, b3
b2:
  v7 = sub.i64 v5, v3
  v8 = ptradd v0, v7 * 8
  v9 = load.i32 v8 align 2
  v10 = load.i32 v8+4 align 2
  v11 = add.i32 v10, v4
  store v11, v8 align 2
  store v9, v8+4 align 2
  jmp b1(v7)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 131
  v5 = iconst.i32 7
  v6 = add.i64 v0, v0
  jmp b1(v2)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b3
b2:
  v9 = ptradd v1, v7 * 4
  v10 = trunc.i32 v7
  v11 = mul.i32 v10, v5
  store v11, v9 align 2
  v12 = add.i64 v7, v3
  jmp b1(v12)
b3:
  call @swap(v1, v0) : (ptr, i64) -> void
  jmp b4(v2, v2)
b4(v13: i64, v14: i64):
  v15 = icmp.ult v13, v6
  br v15, b5, b6
b5:
  v16 = ptradd v1, v13 * 4
  v17 = load.i32 v16 align 2
  v18 = sext.i64 v17
  v19 = mul.i64 v14, v4
  v20 = add.i64 v19, v18
  v21 = add.i64 v13, v3
  jmp b4(v21, v20)
b6:
  ret v14
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "swap");
    assert(t.contains("add.v4i32") && t.contains("vziplo"), t.as_str());
    let ns: [u64; 8] = [0, 1, 3, 4, 7, 8, 9, 37];
    for k in 0..8usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// An early exit that returns the running sum, `for i in 0..a.len() { if a[i] == 0 { return s } s += b[i] }`
// with `b[i]` checked: in the copy without the check (`clip`) the exit passes the sum, which the vector loop
// hands, as the iteration a lane leaves in found it, to the loop, which takes the exit itself
// (`exit_reads`). Each count, zero position and length of `b` gives the sum or the failure it gave.
@test
fn an_early_exit_that_returns_the_running_sum_vectorizes() {
    let src = M"(lir ptr 8
sym @upto fn global noinline
sym @fail fn global noinline cold
sym @drive fn global
fn @fail
  sig (i64) -> void
b0(v0: i64):
  panic "index out of bounds"
fn @upto
  sig (ptr, ptr) -> i32
  ref p0 16 readonly
  ref p1 16 readonly
b0(v0: ptr, v1: ptr):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 0
  v5 = load.i64 v0+8 align 3
  v6 = load.ptr v0 align 3
  v7 = load.i64 v1+8 align 3
  v8 = load.ptr v1 align 3
  jmp b1(v2, v4)
b1(v9: i64, v10: i32):
  v11 = icmp.ult v9, v5
  br v11, b2, b6
b2:
  v12 = ptradd v6, v9 * 4
  v13 = load.i32 v12 align 2
  v14 = icmp.eq v13, v4
  br v14, b5, b3
b3:
  v15 = icmp.uge v9, v7
  br v15, b7, b4
b4:
  v16 = ptradd v8, v9 * 4
  v17 = load.i32 v16 align 2
  v18 = add.i32 v10, v17
  v19 = add.i64 v9, v3
  jmp b1(v19, v18)
b5:
  ret v10
b6:
  v20 = sub.i32 v4, v10
  ret v20
b7:
  call @fail(v9) : (i64) -> void
  unreachable
fn @drive
  sig (i64, i64, i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 32 align 3
b0(v0: i64, v1: i64, v2: i64):
  v3 = slotaddr s0
  v4 = slotaddr s1
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 7
  v8 = iconst.i32 0
  store v3, v4 align 3
  store v0, v4+8 align 3
  store v3, v4+16 align 3
  store v2, v4+24 align 3
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v0
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v7
  v12 = add.i64 v11, v6
  v13 = trunc.i32 v12
  v14 = icmp.eq v9, v1
  v15 = select.i32 v14, v8, v13
  v16 = ptradd v3, v9 * 4
  store v15, v16 align 2
  v17 = add.i64 v9, v6
  jmp b1(v17)
b3:
  v18 = ptradd v4+16
  v19 = call.i32 @upto(v4, v18) : (ptr, ptr) -> i32
  v20 = sext.i64 v19
  ret v20
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 200,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "upto");
    assert(t.contains("add.v4i32"), t.as_str());
    let ns: [u64; 6] = [0, 1, 4, 8, 13, 37];
    for k in 0..6usize {
        for at in 0u64..9 {
            // `b` as long as `a`, or shorter: the check fails before or after the zero.
            for cut in 0u64..2 {
                let n = unsafe ns[k];
                let z = at * 4 + at % 3;
                let bl = n - n / 3 * cut;
                let args: []u64 = [n, z, bl];
                let fails = bl < n && z > bl;
                if fails {
                    same_outcome(&b, &a, "drive", args, 0, true);
                } else {
                    same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
                }
            }
        }
    }
}

// An induction that steps by a parameter, `a[i] = j; j -= k`: its lanes from the counter's iterations
// times `k`, the lane offsets built from `k` per bit of the lane index (`vector_ramp_by`). Each count and
// step gives the elements it gave.
@test
fn an_induction_by_a_value_from_before_the_loop_vectorizes() {
    let src = M"(lir ptr 8
sym @ramp fn global noinline
sym @drive fn global
fn @ramp
  sig (ptr, i64, i32) -> void
  ref p0 512 noalias
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 11
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  store v7, v9 align 2
  v10 = sub.i32 v7, v2
  v11 = add.i64 v6, v4
  jmp b1(v11, v10)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 512 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 131
  v6 = trunc.i32 v1
  call @ramp(v2, v0, v6) : (ptr, i64, i32) -> void
  jmp b1(v3, v3)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v0
  br v9, b2, b3
b2:
  v10 = ptradd v2, v7 * 4
  v11 = load.i32 v10 align 2
  v12 = sext.i64 v11
  v13 = mul.i64 v8, v5
  v14 = add.i64 v13, v12
  v15 = add.i64 v7, v4
  jmp b1(v15, v14)
b3:
  ret v8
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "ramp");
    assert(t.contains("splat.v4i32"), t.as_str());
    let ns: [u64; 6] = [0, 1, 4, 7, 8, 37];
    let ks: [u64; 4] = [0, 3, 0xFFFFFFFB, 0x7FFFFFFF];
    for k in 0..6usize {
        for q in 0..4usize {
            let args: []u64 = [unsafe ns[k], unsafe ks[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A flag that a comparison sets for good (`f = f || x > k`, from 0) or clears for good (`f = f && x < k`,
// from 1) is a reduction (`bool_red`): the comparisons' masks or'ed or and'ed into its lanes, reduced and
// and'ed with 1 after the loop. An i64 comparison's mask narrows to the flag's i8 lanes, an i8 load extends
// to i64 and an i64 one truncates to i8 (8 times the width, `vconv_ok`), each in steps of twice or half the
// width (`vconv`, `vmask`), which split by parts in registers (`lir::wide`): no slot in any loop.
const FLAGS_AND_WIDTHS: str = M"(lir ptr 8
sym @any64 fn global noinline
sym @allf fn global noinline
sym @widen fn global noinline
sym @narrow fn global noinline
sym @drive fn global
fn @any64
  sig (ptr, i64, i64) -> i8
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i8 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i8):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 8
  v10 = load.i64 v9 align 3
  v11 = icmp.sgt v10, v2
  v12 = select.i8 v7, v7, v11
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b3:
  ret v7
fn @allf
  sig (ptr, i64, f32) -> i8
b0(v0: ptr, v1: i64, v2: f32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i8 1
  jmp b1(v3, v5)
b1(v6: i64, v7: i8):
  v8 = icmp.ult v6, v1
  br v8, b2, b3
b2:
  v9 = ptradd v0, v6 * 4
  v10 = load.f32 v9 align 2
  v11 = fcmp.olt v10, v2
  v12 = select.i8 v7, v11, v7
  v13 = add.i64 v6, v4
  jmp b1(v13, v12)
b3:
  ret v7
fn @widen
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v1, v5 * 1
  v8 = load.i8 v7 align 0
  v9 = sext.i64 v8
  v10 = ptradd v0, v5 * 8
  store v9, v10 align 3
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @narrow
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
  v9 = trunc.i8 v8
  v10 = ptradd v0, v5 * 1
  store v9, v10 align 0
  v11 = add.i64 v5, v4
  jmp b1(v11)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 512 align 3
  slot s2 size 1024 align 3
  slot s3 size 128 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i64 128
  v9 = iconst.i64 2654435761
  v10 = iconst.i64 101
  jmp b1(v6)
b1(v11: i64):
  v12 = icmp.ult v11, v8
  br v12, b2, b3
b2:
  v13 = mul.i64 v11, v9
  v14 = ptradd v2, v11 * 8
  store v13, v14 align 3
  v15 = srem.i64 v13, v10
  v16 = sitofp.f32 v15
  v17 = ptradd v3, v11 * 4
  store v16, v17 align 2
  v18 = add.i64 v11, v7
  jmp b1(v18)
b3:
  v19 = call.i8 @any64(v2, v0, v1) : (ptr, i64, i64) -> i8
  v20 = sitofp.f32 v1
  v21 = call.i8 @allf(v3, v0, v20) : (ptr, i64, f32) -> i8
  call @widen(v4, v2, v0) : (ptr, ptr, i64) -> void
  call @narrow(v5, v2, v0) : (ptr, ptr, i64) -> void
  v22 = zext.i64 v19
  v23 = zext.i64 v21
  v24 = iconst.i64 1000003
  v25 = mul.i64 v22, v24
  v26 = add.i64 v25, v23
  jmp b4(v6, v26)
b4(v27: i64, v28: i64):
  v29 = icmp.ult v27, v0
  br v29, b5, b6
b5:
  v30 = ptradd v4, v27 * 8
  v31 = load.i64 v30 align 3
  v32 = ptradd v5, v27 * 1
  v33 = load.i8 v32 align 0
  v34 = sext.i64 v33
  v35 = mul.i64 v28, v24
  v36 = xor.i64 v35, v31
  v37 = mul.i64 v36, v24
  v38 = xor.i64 v37, v34
  v39 = add.i64 v27, v7
  jmp b4(v39, v38)
b6:
  ret v28
)";

@test
fn flags_and_eightfold_conversions_vectorize_in_registers() {
    let (b, a) = optimized_for(FLAGS_AND_WIDTHS, VECTOR, 16, VOPS_ALL);
    let any = text_of(&a, "any64");
    assert(any.contains("vcmp.sgt.v2i64") && any.contains("or.v") && !any.contains("slotaddr"), any.as_str());
    let all = text_of(&a, "allf");
    assert(all.contains("vcmp.olt.v4i32") && all.contains("and.v") && !all.contains("slotaddr"), all.as_str());
    let w = text_of(&a, "widen");
    assert(w.contains(".v2i64") && !w.contains("slotaddr"), w.as_str());
    let n = text_of(&a, "narrow");
    assert(n.contains("load.v2i64") && n.contains("vunzip") && !n.contains("slotaddr"), n.as_str());
    let lens: [u64; 7] = [0, 1, 3, 9, 17, 64, 128];
    let ks: [u64; 4] = [0, 50, 200, 1099511627776];
    for q in 0..7usize {
        for j in 0..4usize {
            let args: []u64 = [unsafe lens[q], unsafe ks[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A count of byte matches in 2- and 4-byte counters (`n += (x == k) as u16`, `as u32`): the flag extended
// is the mask at the counter's width, negated (`vclass`), not a lane conversion of a flag, which would
// leave the loop scalar.
@test
fn counts_of_matches_in_wider_counters_vectorize() {
    let src = M"(lir ptr 8
sym @c16 fn global
sym @c32 fn global
sym @w data local
fn @c16
  sig (i64, i8) -> i16
b0(v0: i64, v1: i8):
  v2 = symaddr @w
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i16 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i16):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v2, v6 * 1
  v10 = load.i8 v9 align 0
  v11 = icmp.eq v10, v1
  v12 = zext.i16 v11
  v13 = add.i16 v7, v12
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
b3:
  ret v7
fn @c32
  sig (i64, i8) -> i32
b0(v0: i64, v1: i8):
  v2 = symaddr @w
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 0
  jmp b1(v3, v5)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v2, v6 * 1
  v10 = load.i8 v9 align 0
  v11 = icmp.slt v10, v1
  v12 = zext.i32 v11
  v13 = add.i32 v7, v12
  v14 = add.i64 v6, v4
  jmp b1(v14, v13)
b3:
  ret v7
data @w size 128 align 3 bytes 21c0a9dc5920318c312059dca9c021ccc100895c79e0918cd160395cc98081cc614069dc99a0f18c71a019dce940e1cc0180495cb960518c11e0f95c090041cca1c029dcd920b18cb120d9dc29c0a1cc4100095cf9e0118c5160b95c498001cce140e9dc19a0718cf1a099dc694061cc8180c95c3960d18c91e0795c8900c1cc
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let c16 = text_of(&a, "c16");
    assert(c16.contains("vcmp.eq.v8i8") && c16.contains("sub.v8i16"), c16.as_str());
    let c32 = text_of(&a, "c32");
    assert(c32.contains("vcmp.slt.v8i8") && c32.contains("sub.v4i32"), c32.as_str());
    let ks: [u64; 3] = [0x21, 0, 0xC0];
    for n in 0..129u64 {
        for q in 0..3usize {
            let args: []u64 = [n, unsafe ks[q]];
            same_outcome(&b, &a, "c16", args, run_value(&b, "c16", args), false);
            same_outcome(&b, &a, "c32", args, run_value(&b, "c32", args), false);
        }
    }
}

// A first-order recurrence (`prev = x` for the next iteration, `c[i] = x - prev`) vectorizes
// (`first_order`): each copy's lanes of the value one iteration back are the lanes in a row from the last
// of the copy before (the loop's carried vector for the first), a `shuffle` the backends make in
// registers (`lv::lane_slide`); the loop after takes the last lane. Of an i32 load, and of a byte load
// widened to i32 (vectors two registers wide, which `lir::wide` slides by parts, no slot). Each count and
// start runs as before.
const RECURRENCES: str = M"(lir ptr 8
sym @diff fn global noinline
sym @wdiff fn global noinline
sym @drive fn global
fn @diff
  sig (ptr, ptr, i64, i32) -> i32
b0(v0: ptr, v1: ptr, v2: i64, v3: i32):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4, v3)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v2
  br v8, b2, b3
b2:
  v9 = ptradd v1, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = sub.i32 v10, v7
  v12 = ptradd v0, v6 * 4
  store v11, v12 align 2
  v13 = add.i64 v6, v5
  jmp b1(v13, v10)
b3:
  ret v7
fn @wdiff
  sig (ptr, ptr, i64, i32) -> i32
b0(v0: ptr, v1: ptr, v2: i64, v3: i32):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4, v3)
b1(v6: i64, v7: i32):
  v8 = icmp.ult v6, v2
  br v8, b2, b3
b2:
  v9 = ptradd v1, v6 * 1
  v10 = load.i8 v9 align 0
  v11 = zext.i32 v10
  v12 = mul.i32 v11, v7
  v13 = sub.i32 v12, v7
  v14 = ptradd v0, v6 * 4
  store v13, v14 align 2
  v15 = add.i64 v6, v5
  jmp b1(v15, v11)
b3:
  ret v7
fn @drive
  sig (i64, i32) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 128
  v7 = iconst.i32 -1640531535
  jmp b1(v4)
b1(v8: i64):
  v9 = icmp.ult v8, v6
  br v9, b2, b3
b2:
  v10 = trunc.i32 v8
  v11 = mul.i32 v10, v7
  v12 = ptradd v2, v8 * 4
  store v11, v12 align 2
  v13 = add.i64 v8, v5
  jmp b1(v13)
b3:
  v14 = call.i32 @diff(v3, v2, v0, v1) : (ptr, ptr, i64, i32) -> i32
  v15 = iconst.i64 1000003
  v16 = sext.i64 v14
  jmp b4(v4, v16)
b4(v17: i64, v18: i64):
  v19 = icmp.ult v17, v0
  br v19, b5, b6
b5:
  v20 = ptradd v3, v17 * 4
  v21 = load.i32 v20 align 2
  v22 = sext.i64 v21
  v23 = mul.i64 v18, v15
  v24 = xor.i64 v23, v22
  v25 = add.i64 v17, v5
  jmp b4(v25, v24)
b6:
  v26 = call.i32 @wdiff(v3, v2, v0, v1) : (ptr, ptr, i64, i32) -> i32
  v27 = sext.i64 v26
  v28 = mul.i64 v18, v15
  v29 = xor.i64 v28, v27
  jmp b7(v4, v29)
b7(v30: i64, v31: i64):
  v32 = icmp.ult v30, v0
  br v32, b8, b9
b8:
  v33 = ptradd v3, v30 * 4
  v34 = load.i32 v33 align 2
  v35 = sext.i64 v34
  v36 = mul.i64 v31, v15
  v37 = xor.i64 v36, v35
  v38 = add.i64 v30, v5
  jmp b7(v38, v37)
b9:
  ret v31
)";

@test
fn first_order_recurrences_vectorize() {
    let (b, a) = optimized_for(RECURRENCES, VECTOR, 16, VOPS_ALL);
    let d = text_of(&a, "diff");
    assert(d.contains("vop.shuffle.v4i32") && d.contains("sub.v4i32") && d.contains("vextract"), d.as_str());
    let w = text_of(&a, "wdiff");
    assert(w.contains("vop.shuffle.v4i32") && w.contains("mul.v4i32") && !w.contains("slotaddr"), w.as_str());
    let lens: [u64; 9] = [0, 1, 3, 4, 7, 16, 17, 33, 128];
    let starts: [u64; 3] = [0, 5, 0xFFFFFFF0];
    for k in 0..9usize {
        for q in 0..3usize {
            let args: []u64 = [unsafe lens[k], unsafe starts[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A load ahead of a store through its base that the body runs after the store (TSVC s212, `a[i] *= c[i];
// b[i] += a[i + 1]`): iteration `i` reads `a[i + 1]` before iteration `i + 1` writes it, so the vector loop
// loads before it stores (`ahead_load`, `vlord`). Each count gives the elements it gave.
@test
fn a_load_ahead_of_an_earlier_store_moves_before_it() {
    let src = M"(lir ptr 8
sym @fwd fn global noinline
sym @drive fn global
fn @fwd
  sig (ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 noalias
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 3
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v0, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v9, v5
  store v10, v8 align 2
  v11 = load.i32 v8+4 align 2
  v12 = ptradd v1, v6 * 4
  v13 = load.i32 v12 align 2
  v14 = add.i32 v13, v11
  store v14, v12 align 2
  v15 = add.i64 v6, v4
  jmp b1(v15)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 131
  v6 = iconst.i32 7
  v7 = add.i64 v0, v4
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v7
  br v9, b2, b3
b2:
  v10 = trunc.i32 v8
  v11 = mul.i32 v10, v6
  v12 = ptradd v1, v8 * 4
  store v11, v12 align 2
  v13 = ptradd v2, v8 * 4
  store v10, v13 align 2
  v14 = add.i64 v8, v4
  jmp b1(v14)
b3:
  call @fwd(v1, v2, v0) : (ptr, ptr, i64) -> void
  jmp b4(v3, v3)
b4(v15: i64, v16: i64):
  v17 = icmp.ult v15, v7
  br v17, b5, b6
b5:
  v18 = ptradd v1, v15 * 4
  v19 = load.i32 v18 align 2
  v20 = ptradd v2, v15 * 4
  v21 = load.i32 v20 align 2
  v22 = add.i32 v19, v21
  v23 = sext.i64 v22
  v24 = mul.i64 v16, v5
  v25 = add.i64 v24, v23
  v26 = add.i64 v15, v4
  jmp b4(v26, v25)
b6:
  ret v16
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "fwd");
    assert(t.contains("mul.v4i32"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// TSVC s124: `j += 1; a[j] = ..` on both sides of a branch, `j` from -1 beside the counter from 0. The
// sum both sides compute moves before the branch (`opt::hoist_common`), so `j` steps by 1 on every edge
// and is the counter minus 1 (`opt::offset_params`); the sides' stores of one address are one store of a
// select (`linearize`), and the loop vectorizes. Each count gives the elements it gave.
@test
fn an_index_stepped_on_both_sides_vectorizes_as_one_store() {
    let src = M"(lir ptr 8
sym @s124 fn global noinline
sym @drive fn global
fn @s124
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 readonly
  ref p2 512 readonly
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 -1
  v7 = iconst.i32 0
  jmp b1(v4, v6)
b1(v8: i64, v9: i64):
  v10 = icmp.ult v8, v3
  br v10, b2, b6
b2:
  v11 = ptradd v1, v8 * 4
  v12 = load.i32 v11 align 2
  v13 = icmp.sgt v12, v7
  v14 = ptradd v2, v8 * 4
  v15 = load.i32 v14 align 2
  br v13, b3, b4
b3:
  v16 = add.i64 v9, v5
  v17 = ptradd v0, v16 * 4
  store v12, v17 align 2
  jmp b5(v16)
b4:
  v18 = add.i64 v9, v5
  v19 = ptradd v0, v18 * 4
  v20 = mul.i32 v15, v15
  store v20, v19 align 2
  jmp b5(v18)
b5(v21: i64):
  v22 = add.i64 v8, v5
  jmp b1(v22, v21)
b6:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 131
  v7 = iconst.i32 7
  v8 = iconst.i32 3
  v9 = iconst.i64 64
  jmp b1(v4)
b1(v10: i64):
  v11 = icmp.ult v10, v9
  br v11, b2, b3
b2:
  v12 = trunc.i32 v10
  v13 = mul.i32 v12, v7
  v14 = and.i32 v13, v8
  v15 = sub.i32 v14, v8
  v16 = ptradd v2, v10 * 4
  store v15, v16 align 2
  v17 = mul.i32 v12, v8
  v18 = ptradd v3, v10 * 4
  store v17, v18 align 2
  v19 = ptradd v1, v10 * 4
  store v12, v19 align 2
  v20 = add.i64 v10, v5
  jmp b1(v20)
b3:
  call @s124(v1, v2, v3, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v21: i64, v22: i64):
  v23 = icmp.ult v21, v9
  br v23, b5, b6
b5:
  v24 = ptradd v1, v21 * 4
  v25 = load.i32 v24 align 2
  v26 = sext.i64 v25
  v27 = mul.i64 v22, v6
  v28 = add.i64 v27, v26
  v29 = add.i64 v21, v5
  jmp b4(v29, v28)
b6:
  ret v22
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "s124");
    assert(t.contains("vsel.v4i32") && !t.contains("store_masked"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// An integer difference from the accumulator (`s = s - a[i]`) is a reduction: its lanes take away from 0,
// their sums add to the start value (`red_op`). Each count and start runs as before.
@test
fn a_difference_from_the_accumulator_is_a_reduction() {
    let src = M"(lir ptr 8
sym @subs fn global noinline
sym @drive fn global
fn @subs
  sig (ptr, i64, i32) -> i32
b0(v0: ptr, v1: i64, v2: i32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3, v2)
b1(v5: i64, v6: i32):
  v7 = icmp.ult v5, v1
  br v7, b2, b3
b2:
  v8 = ptradd v0, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = sub.i32 v6, v9
  v11 = add.i64 v5, v4
  jmp b1(v11, v10)
b3:
  ret v6
fn @drive
  sig (i64, i32) -> i32
  slot s0 size 512 align 3
b0(v0: i64, v1: i32):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i32 -1640531535
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
  v13 = call.i32 @subs(v2, v0, v1) : (ptr, i64, i32) -> i32
  ret v13
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let s = text_of(&a, "subs");
    assert(s.contains("sub.v4i32") && s.contains("reduce_add"), s.as_str());
    let lens: [u64; 7] = [0, 1, 3, 4, 9, 33, 128];
    let starts: [u64; 3] = [0, 7, 0x80000000];
    for k in 0..7usize {
        for q in 0..3usize {
            let args: []u64 = [unsafe lens[k], unsafe starts[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// 8-byte lanes multiply by a constant of one or two powers of 2 as shifts and an add or a subtraction
// (`mul_split`: 3 = 2 + 1, 2^62 - 8, 8): the targets have no 64-bit lane product. Each count runs as before.
@test
fn eight_byte_products_by_two_powers_vectorize() {
    let src = M"(lir ptr 8
sym @mk fn global noinline
sym @drive fn global
fn @mk
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 3
  v6 = iconst.i64 4611686018427387896
  v7 = iconst.i64 8
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v2
  br v9, b2, b3
b2:
  v10 = ptradd v1, v8 * 8
  v11 = load.i64 v10 align 3
  v12 = mul.i64 v11, v5
  v13 = mul.i64 v11, v6
  v14 = mul.i64 v11, v7
  v15 = xor.i64 v12, v13
  v16 = add.i64 v15, v14
  v17 = ptradd v0, v8 * 8
  store v16, v17 align 3
  v18 = add.i64 v8, v4
  jmp b1(v18)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i64 -7046029254386353131
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = mul.i64 v7, v6
  v10 = ptradd v1, v7 * 8
  store v9, v10 align 3
  v11 = add.i64 v7, v4
  jmp b1(v11)
b3:
  call @mk(v2, v1, v0) : (ptr, ptr, i64) -> void
  v12 = iconst.i64 1000003
  jmp b4(v3, v3)
b4(v13: i64, v14: i64):
  v15 = icmp.ult v13, v0
  br v15, b5, b6
b5:
  v16 = ptradd v2, v13 * 8
  v17 = load.i64 v16 align 3
  v18 = mul.i64 v14, v12
  v19 = xor.i64 v18, v17
  v20 = add.i64 v13, v4
  jmp b4(v20, v19)
b6:
  ret v14
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let m = text_of(&a, "mk");
    assert(m.contains("shl.v2i64") && m.contains("sub.v2i64") && !m.contains("mul.v2i64"), m.as_str());
    let lens: [u64; 6] = [0, 1, 2, 5, 17, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A comparison's flag stored (`c[i] = a[i] > k` into bools) vectorizes: the mask's lanes narrowed to bytes
// (`vmask`), negated to 0 or 1. Of i64 and of i32 lanes; each count and bound runs as before.
@test
fn stored_comparison_flags_vectorize() {
    let src = M"(lir ptr 8
sym @flags fn global noinline
sym @drive fn global
fn @flags
  sig (ptr, ptr, ptr, i64, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64, v4: i64):
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = trunc.i32 v4
  jmp b1(v5)
b1(v8: i64):
  v9 = icmp.ult v8, v3
  br v9, b2, b3
b2:
  v10 = ptradd v2, v8 * 8
  v11 = load.i64 v10 align 3
  v12 = icmp.sgt v11, v4
  v13 = ptradd v0, v8 * 1
  store v12, v13 align 0
  v14 = trunc.i32 v11
  v15 = icmp.ult v14, v7
  v16 = ptradd v1, v8 * 1
  store v15, v16 align 0
  v17 = add.i64 v8, v6
  jmp b1(v17)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 128 align 3
  slot s2 size 128 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i64 128
  v8 = iconst.i64 -7046029254386353131
  jmp b1(v5)
b1(v9: i64):
  v10 = icmp.ult v9, v7
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v8
  v12 = ptradd v2, v9 * 8
  store v11, v12 align 3
  v13 = add.i64 v9, v6
  jmp b1(v13)
b3:
  call @flags(v3, v4, v2, v0, v1) : (ptr, ptr, ptr, i64, i64) -> void
  v14 = iconst.i64 3
  jmp b4(v5, v5)
b4(v15: i64, v16: i64):
  v17 = icmp.ult v15, v0
  br v17, b5, b6
b5:
  v18 = ptradd v3, v15 * 1
  v19 = load.i8 v18 align 0
  v20 = ptradd v4, v15 * 1
  v21 = load.i8 v20 align 0
  v22 = zext.i64 v19
  v23 = zext.i64 v21
  v24 = mul.i64 v16, v14
  v25 = add.i64 v24, v22
  v26 = mul.i64 v25, v14
  v27 = add.i64 v26, v23
  v28 = add.i64 v15, v6
  jmp b4(v28, v27)
b6:
  ret v16
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let f = text_of(&a, "flags");
    assert(f.contains("vcmp.sgt.v2i64") && f.contains("neg.v") && !f.contains("slotaddr"), f.as_str());
    let lens: [u64; 6] = [0, 1, 7, 16, 33, 128];
    let ks: [u64; 3] = [0, 0x7FFFFFFF00000000, 0xFFFFFFFFFFFFFF00];
    for k in 0..6usize {
        for q in 0..3usize {
            let args: []u64 = [unsafe lens[k], unsafe ks[q]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// A float to a narrower integer converts to the integer of its width (saturating, NaN 0), clamps to the
// narrow range by lane maximum and minimum, then cuts (`vconv`); f32 to i64 goes through f64. Out-of-range
// values, infinities and NaN saturate as the scalar loop's.
@test
fn floats_to_narrow_and_wide_integers_vectorize() {
    let src = M"(lir ptr 8
sym @cv fn global noinline
sym @drive fn global
fn @cv
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v2, v6 * 4
  v9 = load.f32 v8 align 2
  v10 = fptosi.i8 v9
  v11 = ptradd v0, v6 * 1
  store v10, v11 align 0
  v12 = fptosi.i64 v9
  v13 = ptradd v1, v6 * 8
  store v12, v13 align 3
  v14 = add.i64 v6, v5
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 128 align 3
  slot s2 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 128
  v7 = iconst.i64 -7046029254386353131
  v8 = iconst.i64 40
  jmp b1(v4)
b1(v9: i64):
  v10 = icmp.ult v9, v6
  br v10, b2, b3
b2:
  v11 = mul.i64 v9, v7
  v12 = ashr.i64 v11, v8
  v13 = sitofp.f32 v12
  v14 = ptradd v1, v9 * 4
  store v13, v14 align 2
  v15 = add.i64 v9, v5
  jmp b1(v15)
b3:
  v16 = fconst.f32 0x7fc00000
  store v16, v1+8 align 2
  v17 = fconst.f32 0x7f800000
  store v17, v1+12 align 2
  v18 = fconst.f32 0xff800000
  store v18, v1+20 align 2
  call @cv(v2, v3, v1, v0) : (ptr, ptr, ptr, i64) -> void
  v19 = iconst.i64 1000003
  jmp b4(v4, v4)
b4(v20: i64, v21: i64):
  v22 = icmp.ult v20, v0
  br v22, b5, b6
b5:
  v23 = ptradd v2, v20 * 1
  v24 = load.i8 v23 align 0
  v25 = sext.i64 v24
  v26 = ptradd v3, v20 * 8
  v27 = load.i64 v26 align 3
  v28 = mul.i64 v21, v19
  v29 = xor.i64 v28, v25
  v30 = mul.i64 v29, v19
  v31 = xor.i64 v30, v27
  v32 = add.i64 v20, v5
  jmp b4(v32, v31)
b6:
  ret v21
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let c = text_of(&a, "cv");
    assert(
        c.contains("fptosi.v4i32") && c.contains("vop.max.s.v4i32") && c.contains("vop.min.s.v4i32") && c.contains(
            "fpext.v2f64",
        ) && !c.contains("slotaddr"),
        c.as_str(),
    );
    let lens: [u64; 6] = [0, 1, 6, 16, 33, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A checked sum or difference saturated on its overflow flag (`select(ovf, bound, r)` of `addo`, `subo`)
// is a saturating lane operation (`sat_ovf`): unsigned, the bound all ones or 0; signed, MAX or MIN by the
// second operand's sign (`(b >>s 15) ^ MAX`). Each count runs as before.
@test
fn checked_operations_saturated_on_overflow_vectorize() {
    let src = M"(lir ptr 8
sym @sat fn global noinline
sym @drive fn global
fn @sat
  sig (ptr, ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: ptr, v4: i64):
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  v7 = iconst.i16 15
  v8 = iconst.i16 32767
  v9 = iconst.i16 0
  jmp b1(v5)
b1(v10: i64):
  v11 = icmp.ult v10, v4
  br v11, b2, b3
b2:
  v12 = ptradd v2, v10 * 2
  v13 = load.i16 v12 align 1
  v14 = ptradd v3, v10 * 2
  v15 = load.i16 v14 align 1
  v16 = ashr.i16 v15, v7
  v17 = xor.i16 v16, v8
  v18, v19 = addo.s.i16 v13, v15
  v20 = select.i16 v19, v17, v18
  v21 = ptradd v0, v10 * 2
  store v20, v21 align 1
  v22, v23 = subo.u.i16 v13, v15
  v24 = select.i16 v23, v9, v22
  v25 = ptradd v1, v10 * 2
  store v24, v25 align 1
  v26 = add.i64 v10, v6
  jmp b1(v26)
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
  v7 = iconst.i64 128
  v8 = iconst.i64 -7046029254386353131
  v9 = iconst.i64 48
  jmp b1(v5)
b1(v10: i64):
  v11 = icmp.ult v10, v7
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v8
  v13 = trunc.i16 v12
  v14 = lshr.i64 v12, v9
  v15 = trunc.i16 v14
  v16 = ptradd v3, v10 * 2
  store v13, v16 align 1
  v17 = ptradd v4, v10 * 2
  store v15, v17 align 1
  v18 = add.i64 v10, v6
  jmp b1(v18)
b3:
  call @sat(v1, v2, v3, v4, v0) : (ptr, ptr, ptr, ptr, i64) -> void
  v19 = iconst.i64 1000003
  jmp b4(v5, v5)
b4(v20: i64, v21: i64):
  v22 = icmp.ult v20, v0
  br v22, b5, b6
b5:
  v23 = ptradd v1, v20 * 2
  v24 = load.i16 v23 align 1
  v25 = sext.i64 v24
  v26 = ptradd v2, v20 * 2
  v27 = load.i16 v26 align 1
  v28 = zext.i64 v27
  v29 = mul.i64 v21, v19
  v30 = xor.i64 v29, v25
  v31 = mul.i64 v30, v19
  v32 = xor.i64 v31, v28
  v33 = add.i64 v20, v6
  jmp b4(v33, v32)
b6:
  ret v21
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let s = text_of(&a, "sat");
    assert(s.contains("vop.saturating_add.s.v8i16") && s.contains("vop.saturating_sub.v8i16"), s.as_str());
    let lens: [u64; 6] = [0, 1, 7, 16, 33, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Loads of every 8th element vectorize (three `vunzip` levels of 8 vectors): the loop runs the last
// iteration, so no vector reads past the last element read, which ends the slot here. Each count runs as
// before.
@test
fn loads_of_every_eighth_element_vectorize() {
    let src = M"(lir ptr 8
sym @s8 fn global noinline
sym @drive fn global
fn @s8
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i32 1
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 32
  v9 = load.i32 v8 align 2
  v10 = add.i32 v9, v5
  v11 = ptradd v0, v6 * 4
  store v10, v11 align 2
  v12 = add.i64 v6, v4
  jmp b1(v12)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 4068 align 3
  slot s1 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 1017
  v6 = iconst.i32 -1640531535
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = trunc.i32 v7
  v10 = mul.i32 v9, v6
  v11 = ptradd v1, v7 * 4
  store v10, v11 align 2
  v12 = add.i64 v7, v4
  jmp b1(v12)
b3:
  call @s8(v2, v1, v0) : (ptr, ptr, i64) -> void
  v13 = iconst.i64 1000003
  jmp b4(v3, v3)
b4(v14: i64, v15: i64):
  v16 = icmp.ult v14, v0
  br v16, b5, b6
b5:
  v17 = ptradd v2, v14 * 4
  v18 = load.i32 v17 align 2
  v19 = sext.i64 v18
  v20 = mul.i64 v15, v13
  v21 = xor.i64 v20, v19
  v22 = add.i64 v14, v4
  jmp b4(v22, v21)
b6:
  ret v15
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let s = text_of(&a, "s8");
    assert(count(&s, "vunzip.v4i32") >= 7, s.as_str());
    let lens: [u64; 7] = [0, 1, 5, 9, 33, 100, 128];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// The cost model counts a strided group's vectors once for the loads through its address (`cheaper`): two
// fields of every 4th i64 and four lane operations cost 17 per vector iteration against 18 for its two
// scalar ones, so the loop vectorizes; each count runs as before.
@test
fn a_strided_groups_vectors_count_once() {
    let src = M"(lir ptr 8
sym @g4 fn global noinline
sym @drive fn global
fn @g4
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 7
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 32
  v9 = load.i64 v8 align 3
  v10 = load.i64 v8+8 align 3
  v11 = xor.i64 v9, v10
  v12 = add.i64 v11, v5
  v13 = shl.i64 v9, v4
  v14 = xor.i64 v12, v13
  v15 = ptradd v0, v6 * 8
  store v14, v15 align 3
  v16 = add.i64 v6, v4
  jmp b1(v16)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 4096 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 512
  v6 = iconst.i64 -7046029254386353131
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = mul.i64 v7, v6
  v10 = ptradd v1, v7 * 8
  store v9, v10 align 3
  v11 = add.i64 v7, v4
  jmp b1(v11)
b3:
  call @g4(v2, v1, v0) : (ptr, ptr, i64) -> void
  v12 = iconst.i64 1000003
  jmp b4(v3, v3)
b4(v13: i64, v14: i64):
  v15 = icmp.ult v13, v0
  br v15, b5, b6
b5:
  v16 = ptradd v2, v13 * 8
  v17 = load.i64 v16 align 3
  v18 = mul.i64 v14, v12
  v19 = xor.i64 v18, v17
  v20 = add.i64 v13, v4
  jmp b4(v20, v19)
b6:
  ret v14
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let g = text_of(&a, "g4");
    assert(g.contains("vunzip.v2i64") && g.contains("xor.v2i64"), g.as_str());
    let lens: [u64; 6] = [0, 1, 2, 5, 33, 128];
    for k in 0..6usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// An inner loop of a convolution (TSVC s176), `a[i] += b[i + m - j - 1] * c[j]`: the index's invariant
// part regroups (`opt::invariant_sum`: `i + (m - j - 1)`), and the check of the outer index `j`, which the
// loop does not compute, joins the guard (`checks`, `ginv`), so the copy has no check and vectorizes.
// Each count, offset and length gives the sum or the failure it gave.
@test
fn an_inner_loop_with_an_invariant_offset_and_an_outer_check_vectorizes() {
    let src = M"(lir ptr 8
sym @conv fn global noinline
sym @fail fn global noinline cold
sym @drive fn global
fn @fail
  sig (i64) -> void
b0(v0: i64):
  panic "index out of bounds"
fn @conv
  sig (ptr, ptr, ptr, i64, i64, i64) -> void
  ref p0 512 noalias
  ref p1 16 readonly
  ref p2 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64, v4: i64, v5: i64):
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = load.i64 v1+8 align 3
  v9 = load.ptr v1 align 3
  v10 = load.i64 v2+8 align 3
  v11 = load.ptr v2 align 3
  v12 = icmp.uge v5, v10
  jmp b1(v6)
b1(v13: i64):
  v14 = icmp.ult v13, v3
  br v14, b2, b5
b2:
  v15 = add.i64 v13, v4
  v16 = sub.i64 v15, v5
  v17 = icmp.uge v16, v8
  br v17, b6, b3
b3:
  br v12, b7, b4
b4:
  v18 = ptradd v9, v16 * 4
  v19 = load.i32 v18 align 2
  v20 = ptradd v11, v5 * 4
  v21 = load.i32 v20 align 2
  v22 = mul.i32 v19, v21
  v23 = ptradd v0, v13 * 4
  v24 = load.i32 v23 align 2
  v25 = add.i32 v24, v22
  store v25, v23 align 2
  v26 = add.i64 v13, v7
  jmp b1(v26)
b5:
  ret
b6:
  call @fail(v16) : (i64) -> void
  unreachable
b7:
  call @fail(v5) : (i64) -> void
  unreachable
fn @drive
  sig (i64, i64, i64, i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 32 align 3
b0(v0: i64, v1: i64, v2: i64, v3: i64):
  v4 = slotaddr s0
  v5 = slotaddr s1
  v6 = slotaddr s2
  v7 = iconst.i64 0
  v8 = iconst.i64 1
  v9 = iconst.i64 131
  v10 = iconst.i32 7
  v11 = iconst.i64 100
  v12 = iconst.i64 8
  store v5, v6 align 3
  store v11, v6+8 align 3
  store v5, v6+16 align 3
  store v12, v6+24 align 3
  jmp b1(v7)
b1(v13: i64):
  v14 = icmp.ult v13, v11
  br v14, b2, b3
b2:
  v15 = trunc.i32 v13
  v16 = mul.i32 v15, v10
  v17 = ptradd v5, v13 * 4
  store v16, v17 align 2
  v18 = ptradd v4, v13 * 4
  store v15, v18 align 2
  v19 = add.i64 v13, v8
  jmp b1(v19)
b3:
  v20 = ptradd v6+16
  call @conv(v4, v6, v20, v0, v1, v2) : (ptr, ptr, ptr, i64, i64, i64) -> void
  jmp b4(v7, v7)
b4(v21: i64, v22: i64):
  v23 = icmp.ult v21, v0
  br v23, b5, b6
b5:
  v24 = ptradd v4, v21 * 4
  v25 = load.i32 v24 align 2
  v26 = sext.i64 v25
  v27 = mul.i64 v22, v9
  v28 = add.i64 v27, v26
  v29 = add.i64 v21, v8
  jmp b4(v29, v28)
b6:
  ret v22
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 200,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "conv");
    assert(t.contains("mul.v4i32"), t.as_str());
    // (count, m, j): within both slices; past `b` (100 elements) at an iteration; `j` past `c` (8).
    let cases: [[u64; 3]; 8] = [
        [0, 5, 1],
        [1, 5, 1],
        [7, 20, 3],
        [37, 40, 7],
        [64, 30, 0],
        [90, 20, 5],
        [37, 40, 8],
        [5, 0, 1],
    ];
    for k in 0..8usize {
        let cs = unsafe cases[k];
        let (n, m, j) = (cs[0], cs[1], cs[2]);
        let args: []u64 = [n, m, j];
        let mut fails = false;
        for i in 0..n {
            let x = (i + m).wrapping_sub(j);
            fails = fails || x >= 100 || j >= 8;
        }
        let args4: []u64 = [n, m, j, 0];
        if fails {
            same_outcome(&b, &a, "drive", args4, 0, true);
        } else {
            same_outcome(&b, &a, "drive", args4, run_value(&b, "drive", args4), false);
        }
        let _ = args;
    }
}

// A triangular solve's row, `for j in 0..i { x[i] -= l[j] * x[j] }`: the loads `x[j]` share the place's
// base, and the header keeps `j` below `i`, so they read other elements (`opt::below_place`); `x[i]` stays
// in a register and the loop vectorizes; with `j` up to `i` (`row2`) the last load reads the place, which
// stays in memory. Each row and length gives the elements it gave.
@test
fn a_row_of_a_triangular_solve_keeps_its_element_in_a_register() {
    let src = M"(lir ptr 8
sym @row fn global noinline
sym @row2 fn global noinline
sym @drive fn global
fn @row
  sig (ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = ptradd v0, v2 * 4 inbounds
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 4 inbounds
  v9 = load.i32 v8 align 2
  v10 = ptradd v0, v6 * 4 inbounds
  v11 = load.i32 v10 align 2
  v12 = mul.i32 v9, v11
  v13 = load.i32 v5 align 2
  v14 = sub.i32 v13, v12
  store v14, v5 align 2
  v15 = add.i64 v6, v4
  jmp b1(v15)
b3:
  ret
fn @row2
  sig (ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = ptradd v0, v2 * 4 inbounds
  v6 = add.i64 v2, v4
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v6
  br v8, b2, b3
b2:
  v9 = ptradd v1, v7 * 4 inbounds
  v10 = load.i32 v9 align 2
  v11 = ptradd v0, v7 * 4 inbounds
  v12 = load.i32 v11 align 2
  v13 = mul.i32 v10, v12
  v14 = load.i32 v5 align 2
  v15 = sub.i32 v14, v13
  store v15, v5 align 2
  v16 = add.i64 v7, v4
  jmp b1(v16)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 131
  v6 = iconst.i32 7
  v7 = iconst.i64 64
  v8 = iconst.i32 3
  v9 = iconst.i64 128
  v10 = ptradd v1+256
  jmp b1(v3)
b1(v11: i64):
  v12 = icmp.ult v11, v9
  br v12, b2, b3
b2:
  v13 = trunc.i32 v11
  v14 = mul.i32 v13, v6
  v15 = ptradd v1, v11 * 4
  store v14, v15 align 2
  v16 = sub.i32 v13, v8
  v17 = ptradd v2, v11 * 4
  store v16, v17 align 2
  v18 = add.i64 v11, v4
  jmp b1(v18)
b3:
  call @row(v1, v2, v0) : (ptr, ptr, i64) -> void
  call @row2(v10, v2, v0) : (ptr, ptr, i64) -> void
  jmp b4(v3, v3)
b4(v19: i64, v20: i64):
  v21 = icmp.ult v19, v9
  br v21, b5, b6
b5:
  v22 = ptradd v1, v19 * 4
  v23 = load.i32 v22 align 2
  v24 = sext.i64 v23
  v25 = mul.i64 v20, v5
  v26 = add.i64 v25, v24
  v27 = add.i64 v19, v4
  jmp b4(v27, v26)
b6:
  ret v20
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "row");
    assert(t.contains("mul.v4i32"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A branch inside a side (TSVC s279, `if a[i] > 0 { b[i] *= 2; if b[i] > a[i] { c[i] += a[i] } } else {
// c[i] = 7 }`): the inner block's store takes the lanes both conditions pick (`lin_nest`, `lcc2`), the
// other stores their side's lanes, and the loop vectorizes. Each count gives the elements it gave.
@test
fn a_branch_inside_a_side_if_converts() {
    let src = M"(lir ptr 8
sym @nest fn global noinline
sym @drive fn global
fn @nest
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 noalias
  ref p2 512 noalias
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 0
  v7 = iconst.i32 7
  jmp b1(v4)
b1(v8: i64):
  v9 = icmp.ult v8, v3
  br v9, b2, b7
b2:
  v10 = ptradd v0, v8 * 4
  v11 = load.i32 v10 align 2
  v12 = ptradd v1, v8 * 4
  v13 = load.i32 v12 align 2
  v14 = ptradd v2, v8 * 4
  v15 = load.i32 v14 align 2
  v16 = icmp.sgt v11, v6
  br v16, b3, b5
b3:
  v17 = add.i32 v13, v13
  store v17, v12 align 2
  v18 = icmp.sgt v17, v11
  br v18, b4, b6
b4:
  v19 = add.i32 v15, v11
  store v19, v14 align 2
  jmp b6
b5:
  store v7, v14 align 2
  jmp b6
b6:
  v20 = add.i64 v8, v5
  jmp b1(v20)
b7:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 131
  v7 = iconst.i32 7
  v8 = iconst.i32 5
  v9 = iconst.i64 128
  v10 = iconst.i32 2
  jmp b1(v4)
b1(v11: i64):
  v12 = icmp.ult v11, v9
  br v12, b2, b3
b2:
  v13 = trunc.i32 v11
  v14 = mul.i32 v13, v7
  v15 = and.i32 v14, v8
  v16 = sub.i32 v15, v10
  v17 = ptradd v1, v11 * 4
  store v16, v17 align 2
  v18 = and.i32 v13, v8
  v19 = sub.i32 v18, v10
  v20 = ptradd v2, v11 * 4
  store v19, v20 align 2
  v21 = ptradd v3, v11 * 4
  store v13, v21 align 2
  v22 = add.i64 v11, v5
  jmp b1(v22)
b3:
  call @nest(v1, v2, v3, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v23: i64, v24: i64):
  v25 = icmp.ult v23, v9
  br v25, b5, b6
b5:
  v26 = ptradd v2, v23 * 4
  v27 = load.i32 v26 align 2
  v28 = ptradd v3, v23 * 4
  v29 = load.i32 v28 align 2
  v30 = add.i32 v27, v29
  v31 = sext.i64 v30
  v32 = mul.i64 v24, v6
  v33 = add.i64 v32, v31
  v34 = add.i64 v23, v5
  jmp b4(v34, v33)
b6:
  ret v24
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "nest");
    assert(t.contains("store_masked") && t.contains("v4i32"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A side's load of a slice whose length is one of three a loop counts to the least of (`a.len().min(b.len())
// .min(n)`): the least of the least reads no element past the slice's end (`counted_at`, `min_of_len`), so
// the side may load in every lane and the loop vectorizes. Each count gives the elements it gave.
@test
fn a_side_load_under_the_least_of_three_lengths_vectorizes() {
    let src = M"(lir ptr 8
sym @side fn global noinline
sym @drive fn global
fn @side
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 16 readonly
  ref p2 16 readonly
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 0
  v7 = load.ptr v1 align 3
  v8 = load.i64 v1+8 align 3
  v9 = load.ptr v2 align 3
  v10 = load.i64 v2+8 align 3
  v11 = icmp.ult v8, v10
  v12 = select.i64 v11, v8, v10
  v13 = icmp.ult v12, v3
  v14 = select.i64 v13, v12, v3
  jmp b1(v4)
b1(v15: i64):
  v16 = icmp.ult v15, v14
  br v16, b2, b4
b2:
  v17 = ptradd v7, v15 * 4
  v18 = load.i32 v17 align 2
  v19 = icmp.sgt v18, v6
  br v19, b3, b5
b3:
  v20 = ptradd v9, v15 * 4
  v21 = load.i32 v20 align 2
  v22 = add.i32 v21, v18
  v23 = ptradd v0, v15 * 4
  store v22, v23 align 2
  jmp b5
b4:
  ret
b5:
  v24 = add.i64 v15, v5
  jmp b1(v24)
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
  slot s3 size 32 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i64 131
  v9 = iconst.i32 7
  v10 = iconst.i32 3
  v11 = iconst.i64 128
  store v3, v5 align 3
  store v0, v5+8 align 3
  store v4, v5+16 align 3
  store v1, v5+24 align 3
  jmp b1(v6)
b1(v12: i64):
  v13 = icmp.ult v12, v11
  br v13, b2, b3
b2:
  v14 = trunc.i32 v12
  v15 = mul.i32 v14, v9
  v16 = and.i32 v15, v10
  v17 = sub.i32 v10, v16
  v18 = ptradd v3, v12 * 4
  store v17, v18 align 2
  v19 = ptradd v4, v12 * 4
  store v15, v19 align 2
  v20 = ptradd v2, v12 * 4
  store v14, v20 align 2
  v21 = add.i64 v12, v7
  jmp b1(v21)
b3:
  v22 = ptradd v5+16
  call @side(v2, v5, v22, v11) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v6, v6)
b4(v23: i64, v24: i64):
  v25 = icmp.ult v23, v11
  br v25, b5, b6
b5:
  v26 = ptradd v2, v23 * 4
  v27 = load.i32 v26 align 2
  v28 = sext.i64 v27
  v29 = mul.i64 v24, v8
  v30 = add.i64 v29, v28
  v31 = add.i64 v23, v7
  jmp b4(v31, v30)
b6:
  ret v24
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "side");
    assert(t.contains("store_masked") && t.contains("v4i32"), t.as_str());
    // (a.len, b.len): either the least, at and past a vector's width.
    let cs: [[u64; 2]; 6] = [[0, 9], [9, 0], [3, 17], [17, 3], [37, 40], [128, 64]];
    for k in 0..6usize {
        let c = unsafe cs[k];
        let args: []u64 = [c[0], c[1]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A body of one block that stores through a select of two pointers (TSVC s278 once `opt` merged its two
// sides): the copy stores each pointer's element under the lanes the select picks it in (`linearize`,
// `split_store`); the accesses keep the alias classes of the pointers' other accesses
// (`base_access`), so no overlap check is needed. Each count gives the elements it gave.
@test
fn a_store_through_a_select_of_two_pointers_vectorizes_as_two_masked_stores() {
    let src = M"(lir ptr 8
sym @pick fn global noinline
sym @drive fn global
fn @pick
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 noalias
  ref p2 512 noalias
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 0
  jmp b1(v4)
b1(v7: i64):
  v8 = icmp.ult v7, v3
  br v8, b2, b3
b2:
  v9 = ptradd v0, v7 * 4
  v10 = load.i32 v9 align 2
  v11 = icmp.sgt v10, v6
  v12 = select.ptr v11, v1, v2
  v13 = ptradd v12, v7 * 4
  v14 = add.i32 v10, v10
  v15 = sub.i32 v14, v6
  store v15, v13 align 2
  v16 = ptradd v1, v7 * 4
  v17 = load.i32 v16 align 2
  v18 = ptradd v2, v7 * 4
  v19 = load.i32 v18 align 2
  v20 = add.i32 v17, v19
  store v20, v9 align 2
  v21 = add.i64 v7, v5
  jmp b1(v21)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 131
  v7 = iconst.i32 7
  v8 = iconst.i32 5
  v9 = iconst.i64 128
  v10 = iconst.i32 2
  jmp b1(v4)
b1(v11: i64):
  v12 = icmp.ult v11, v9
  br v12, b2, b3
b2:
  v13 = trunc.i32 v11
  v14 = mul.i32 v13, v7
  v15 = and.i32 v14, v8
  v16 = sub.i32 v15, v10
  v17 = ptradd v1, v11 * 4
  store v16, v17 align 2
  v18 = ptradd v2, v11 * 4
  store v14, v18 align 2
  v19 = ptradd v3, v11 * 4
  store v13, v19 align 2
  v20 = add.i64 v11, v5
  jmp b1(v20)
b3:
  call @pick(v1, v2, v3, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v21: i64, v22: i64):
  v23 = icmp.ult v21, v9
  br v23, b5, b6
b5:
  v24 = ptradd v1, v21 * 4
  v25 = load.i32 v24 align 2
  v26 = ptradd v2, v21 * 4
  v27 = load.i32 v26 align 2
  v28 = ptradd v3, v21 * 4
  v29 = load.i32 v28 align 2
  v30 = mul.i32 v27, v7
  v31 = xor.i32 v30, v29
  v32 = add.i32 v31, v25
  v33 = sext.i64 v32
  v34 = mul.i64 v22, v6
  v35 = add.i64 v34, v33
  v36 = add.i64 v21, v5
  jmp b4(v36, v35)
b6:
  ret v22
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "pick");
    // No overlap check (an `or` of two address comparisons): the noalias classes hold.
    assert(t.contains("store_masked") && t.contains("v4i32") && !t.contains(" = or.i8"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A switch on a lane value whose every case stores one place (TSVC s442): one block whose stored value
// and latch argument are chains of selects on the cases' comparisons, the first case outermost
// (`linearize_switch`), so the loop vectorizes. Each count gives the elements it gave, and a value two
// cases name takes the first's.
@test
fn a_switch_whose_cases_store_one_place_vectorizes_as_selects() {
    let src = M"(lir ptr 8
sym @sw fn global noinline
sym @drive fn global
fn @sw
  sig (ptr, ptr, ptr, i64) -> void
  ref p0 512 noalias
  ref p1 512 noalias
  ref p2 512 readonly
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i32 3
  v7 = iconst.i32 5
  v8 = iconst.i32 7
  jmp b1(v4)
b1(v9: i64):
  v10 = icmp.ult v9, v3
  br v10, b2, b7
b2:
  v11 = ptradd v2, v9 * 4
  v12 = load.i32 v11 align 2
  v13 = and.i32 v12, v6
  v14 = ptradd v0, v9 * 4
  switch v13 [1 -> b3, 2 -> b4, 1 -> b5] else b6
b3:
  v15 = mul.i32 v12, v6
  store v15, v14 align 2
  jmp b8(v12)
b4:
  v16 = sub.i32 v12, v7
  store v16, v14 align 2
  jmp b8(v16)
b5:
  store v7, v14 align 2
  jmp b8(v8)
b6:
  v17 = xor.i32 v12, v8
  store v17, v14 align 2
  jmp b8(v6)
b7:
  ret
b8(v18: i32):
  v19 = ptradd v1, v9 * 4
  store v18, v19 align 2
  v20 = add.i64 v9, v5
  jmp b1(v20)
fn @drive
  sig (i64) -> i64
  slot s0 size 512 align 3
  slot s1 size 512 align 3
  slot s2 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 131
  v7 = iconst.i32 7
  v8 = iconst.i64 128
  v9 = iconst.i32 11
  jmp b1(v4)
b1(v10: i64):
  v11 = icmp.ult v10, v8
  br v11, b2, b3
b2:
  v12 = trunc.i32 v10
  v13 = mul.i32 v12, v7
  v14 = xor.i32 v13, v9
  v15 = ptradd v3, v10 * 4
  store v14, v15 align 2
  v16 = ptradd v1, v10 * 4
  store v12, v16 align 2
  v17 = ptradd v2, v10 * 4
  store v13, v17 align 2
  v18 = add.i64 v10, v5
  jmp b1(v18)
b3:
  call @sw(v1, v2, v3, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v19: i64, v20: i64):
  v21 = icmp.ult v19, v8
  br v21, b5, b6
b5:
  v22 = ptradd v1, v19 * 4
  v23 = load.i32 v22 align 2
  v24 = ptradd v2, v19 * 4
  v25 = load.i32 v24 align 2
  v26 = mul.i32 v25, v7
  v27 = xor.i32 v26, v23
  v28 = sext.i64 v27
  v29 = mul.i64 v20, v6
  v30 = add.i64 v29, v28
  v31 = add.i64 v19, v5
  jmp b4(v31, v30)
b6:
  ret v20
)";
    let (b, a) = optimized_for(
        src,
        lu::Budgets {
            peel: 0,
            partial: 0,
            version: 0,
            version_checks: u32::MAX,
            unswitch: 0,
            rotate: 0,
            vector: 2,
            interleave: 2,
            fin: 0,
        },
        16,
        VOPS_ALL,
    );
    let t = text_of(&a, "sw");
    assert(t.contains("vsel.v4i32"), t.as_str());
    let ns: [u64; 7] = [0, 1, 3, 4, 8, 9, 37];
    for k in 0..7usize {
        let args: []u64 = [unsafe ns[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A counter that counts down and whose next value the body reads (`i -= 1; c[i] = 3 * i`) vectorizes: the
// lanes, in the elements' order, the counter's from copy c's lowest up (`vector_ctr`), stepped. A truncated
// next value counts in its own lanes (`vector_ind`), a 64-bit one in the counter's (`vstepv`). Each count
// runs as before.
@test
fn a_counter_counting_down_is_a_lane_value() {
    let src = M"(lir ptr 8
sym @down fn global noinline
sym @down64 fn global noinline
sym @drive fn global
fn @down
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 3
  jmp b1(v1)
b1(v5: i64):
  v6 = icmp.ne v5, v2
  br v6, b2, b3
b2:
  v7 = sub.i64 v5, v3
  v8 = trunc.i32 v7
  v9 = mul.i32 v8, v4
  v10 = ptradd v0, v7 * 4
  store v9, v10 align 2
  jmp b1(v7)
b3:
  ret
fn @down64
  sig (ptr, i64) -> void
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i64 5
  jmp b1(v1)
b1(v5: i64):
  v6 = icmp.ne v5, v2
  br v6, b2, b3
b2:
  v7 = sub.i64 v5, v3
  v8 = xor.i64 v7, v4
  v9 = ptradd v0, v7 * 8
  store v8, v9 align 3
  jmp b1(v7)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  call @down64(v1, v0) : (ptr, i64) -> void
  call @down(v1, v0) : (ptr, i64) -> void
  v4 = iconst.i64 1000003
  jmp b1(v2, v2)
b1(v5: i64, v6: i64):
  v7 = icmp.ult v5, v0
  br v7, b2, b3
b2:
  v8 = ptradd v1, v5 * 4
  v9 = load.i32 v8 align 2
  v10 = sext.i64 v9
  v11 = mul.i64 v6, v4
  v12 = xor.i64 v11, v10
  v13 = add.i64 v5, v3
  jmp b1(v13, v12)
b3:
  ret v6
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let d = text_of(&a, "down");
    assert(d.contains("mul.v4i32") && d.contains("sub.v4i32"), d.as_str());
    let e = text_of(&a, "down64");
    assert(e.contains("xor.v2i64") && e.contains("sub.v2i64"), e.as_str());
    let lens: [u64; 7] = [0, 1, 2, 5, 8, 17, 128];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let args: []u64 = [127];
    same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
}

// A 64-bit product by a constant of more than two powers of 2 vectorizes in 32-byte vectors of its 32-bit
// lanes' products (`mul_by_halves`): by 11 (a low word alone), by 11 << 32 (a high word alone) and by
// 0x9E3779B97F4A7C15 (both). Each count runs as before; in 16-byte vectors such a product alone costs more
// than its scalar iterations.
@test
fn eight_byte_products_by_any_constant_vectorize() {
    let src = M"(lir ptr 8
sym @mk fn global noinline
sym @drive fn global
fn @mk
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 11
  v6 = iconst.i64 47244640256
  v7 = iconst.i64 -7046029254386353131
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v2
  br v9, b2, b3
b2:
  v10 = ptradd v1, v8 * 8
  v11 = load.i64 v10 align 3
  v12 = mul.i64 v11, v5
  v13 = mul.i64 v11, v6
  v14 = mul.i64 v11, v7
  v15 = xor.i64 v12, v13
  v16 = add.i64 v15, v14
  v17 = ptradd v0, v8 * 8
  store v16, v17 align 3
  v18 = add.i64 v8, v4
  jmp b1(v18)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 128
  v6 = iconst.i64 -4658895280553007687
  jmp b1(v3, v3)
b1(v7: i64, v8: i64):
  v9 = icmp.ult v7, v5
  br v9, b2, b3
b2:
  v10 = add.i64 v8, v6
  v11 = ptradd v1, v7 * 8
  store v10, v11 align 3
  v12 = add.i64 v7, v4
  v13 = mul.i64 v10, v6
  jmp b1(v12, v13)
b3:
  call @mk(v2, v1, v0) : (ptr, ptr, i64) -> void
  v14 = iconst.i64 1000003
  jmp b4(v3, v3)
b4(v15: i64, v16: i64):
  v17 = icmp.ult v15, v0
  br v17, b5, b6
b5:
  v18 = ptradd v2, v15 * 8
  v19 = load.i64 v18 align 3
  v20 = mul.i64 v16, v14
  v21 = xor.i64 v20, v19
  v22 = add.i64 v15, v4
  jmp b4(v22, v21)
b6:
  ret v16
)";
    let (b, a) = optimized_for(src, VECTOR, 32, VOPS_ALL);
    let m = text_of(&a, "mk");
    assert(m.contains("mulhu.v8i32") && m.contains("mul.v8i32") && m.contains("shl.v4i64"), m.as_str());
    let lens: [u64; 7] = [0, 1, 3, 4, 9, 64, 127];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let (_, n) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let s = text_of(&n, "mk");
    assert(!s.contains("mulhu.v4i32"), s.as_str());
}

// A load the loop does not change through an address from before it, which its stores may write, versions
// the loop on it (`vchecks`, `vrange`): the vector loop reads it once when its bytes lie apart from the
// stores' range, the scalar loop runs when they do not. Each count runs as before with the place outside
// the stores, in their range, at their first and last element, and just past them.
@test
fn an_invariant_load_a_store_may_write_versions_the_loop() {
    let src = M"(lir ptr 8
sym @addk fn global noinline
sym @drive fn global
fn @addk
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
  v8 = ptradd v0, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = mul.i32 v9, v5
  v11 = load.i32 v1 align 2
  v12 = add.i32 v10, v11
  store v12, v8 align 2
  v13 = add.i64 v6, v4
  jmp b1(v13)
b3:
  ret
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 1024 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 256
  v6 = iconst.i32 7
  jmp b1(v3)
b1(v7: i64):
  v8 = icmp.ult v7, v5
  br v8, b2, b3
b2:
  v9 = trunc.i32 v7
  v10 = xor.i32 v9, v6
  v11 = ptradd v2, v7 * 4
  store v10, v11 align 2
  v12 = add.i64 v7, v4
  jmp b1(v12)
b3:
  v13 = ptradd v2+64
  v14 = ptradd v2, v1 * 4
  call @addk(v13, v14, v0) : (ptr, ptr, i64) -> void
  v15 = iconst.i64 1000003
  jmp b4(v3, v3)
b4(v16: i64, v17: i64):
  v18 = icmp.ult v16, v5
  br v18, b5, b6
b5:
  v19 = ptradd v2, v16 * 4
  v20 = load.i32 v19 align 2
  v21 = sext.i64 v20
  v22 = mul.i64 v17, v15
  v23 = xor.i64 v22, v21
  v24 = add.i64 v16, v4
  jmp b4(v24, v23)
b6:
  ret v17
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let f = text_of(&a, "addk");
    assert(f.contains("mul.v4i32") && f.contains("icmp.ule"), f.as_str());
    // The stores write elements 16 up to 16 + n of the slot; the place is element `at`.
    let lens: [u64; 4] = [3, 8, 37, 100];
    let ats: [u64; 6] = [0, 15, 16, 30, 52, 116];
    for k in 0..4usize {
        for j in 0..6usize {
            let args: []u64 = [unsafe lens[k], unsafe ats[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// An extreme with its first index vectorizes (`arg_pair`): each lane keeps its value and the counter where
// `x REL value` holds, the exit takes of all lanes the preferred value, of equal ones the lowest index
// (`arg_exit`). Integers with ties (the least value first at 5, in a lane the exit reads after the lane of
// the next one, at 32), floats with NaNs (never taken) and both zeros, from a start value and from a NaN
// (nothing taken); each count runs as before.
@test
fn an_extreme_and_its_first_index_vectorize() {
    let src = M"(lir ptr 8
sym @am fn global noinline
sym @fm fn global noinline
sym @drive fn global
fn @am
  sig (ptr, i64) -> i64
b0(v0: ptr, v1: i64):
  v2 = iconst.i64 0
  v3 = iconst.i64 1
  v4 = iconst.i32 3
  v5 = iconst.i64 77
  jmp b1(v2, v4, v5)
b1(v6: i64, v7: i32, v8: i64):
  v9 = icmp.ult v6, v1
  br v9, b2, b3
b2:
  v10 = ptradd v0, v6 * 4
  v11 = load.i32 v10 align 2
  v12 = icmp.slt v11, v7
  v13 = select.i32 v12, v11, v7
  v14 = select.i64 v12, v6, v8
  v15 = add.i64 v6, v3
  jmp b1(v15, v13, v14)
b3:
  v16 = sext.i64 v7
  v17 = iconst.i64 1000003
  v18 = mul.i64 v16, v17
  v19 = add.i64 v18, v8
  ret v19
fn @fm
  sig (ptr, i64, f32) -> i64
b0(v0: ptr, v1: i64, v2: f32):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 5
  jmp b1(v3, v2, v5)
b1(v6: i64, v7: f32, v8: i64):
  v9 = icmp.ult v6, v1
  br v9, b2, b3
b2:
  v10 = ptradd v0, v6 * 4
  v11 = load.f32 v10 align 2
  v12 = fcmp.ogt v7, v11
  v13 = select.f32 v12, v11, v7
  v14 = select.i64 v12, v6, v8
  v15 = add.i64 v6, v4
  jmp b1(v15, v13, v14)
b3:
  v16 = bitcast.i32 v7
  v17 = zext.i64 v16
  v18 = iconst.i64 1000003
  v19 = mul.i64 v17, v18
  v20 = add.i64 v19, v8
  ret v20
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 256
  v6 = iconst.i64 9
  v7 = iconst.i64 4
  v8 = iconst.i64 11
  v9 = iconst.i64 13
  v10 = iconst.i32 2143289344
  v11 = iconst.i32 -2147483648
  v12 = iconst.i64 7
  jmp b1(v3)
b1(v13: i64):
  v14 = icmp.ult v13, v5
  br v14, b2, b3
b2:
  v15 = add.i64 v13, v7
  v16 = mul.i64 v15, v12
  v17 = urem.i64 v16, v6
  v18 = sub.i64 v17, v7
  v19 = trunc.i32 v18
  v20 = ptradd v1, v13 * 4
  store v19, v20 align 2
  v21 = sitofp.f32 v19
  v22 = bitcast.i32 v21
  v23 = urem.i64 v13, v8
  v24 = icmp.eq v23, v7
  v25 = select.i32 v24, v10, v22
  v26 = urem.i64 v13, v9
  v27 = icmp.eq v26, v7
  v28 = select.i32 v27, v11, v25
  v29 = ptradd v2, v13 * 4
  store v28, v29 align 2
  v30 = add.i64 v13, v4
  jmp b1(v30)
b3:
  v31 = call.i64 @am(v1, v0) : (ptr, i64) -> i64
  v32 = fconst.f32 0x40400000
  v33 = call.i64 @fm(v2, v0, v32) : (ptr, i64, f32) -> i64
  v34 = fconst.f32 0x7fc00000
  v35 = call.i64 @fm(v2, v0, v34) : (ptr, i64, f32) -> i64
  v36 = xor.i64 v31, v33
  v37 = mul.i64 v36, v12
  v38 = xor.i64 v37, v35
  ret v38
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let m = text_of(&a, "am");
    assert(m.contains("vcmp.slt.v2i32") && m.contains("vsel.v2i64"), m.as_str());
    let f = text_of(&a, "fm");
    assert(f.contains("vcmp.olt.v2i32") && f.contains("vsel.v2i64"), f.as_str());
    for n in 0..90u64 {
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// `while p < end`, `while end > p` and `while p != end`: loops that step pointers and no counter take one
// and vectorize: an end the pointer reaches by whole elements (`p + n`), an end some bytes past the start
// that are no whole number of elements, a start past the end, which runs no iteration (also an end
// `p + m` with `m` negative), and a search that leaves with the pointer at the match.
@test
fn loops_that_step_pointers_take_a_counter_and_vectorize() {
    let src = M"(lir ptr 8
sym @psum fn global noinline
sym @pxor fn global noinline
sym @pbytes fn global noinline
sym @pnear fn global noinline
sym @pfind fn global noinline
sym @drive fn global
fn @psum
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = ptradd v0, v1 * 4 inbounds
  jmp b1(v0, v2)
b1(v4: ptr, v5: i32):
  v6 = icmp.ult v4, v3
  br v6, b2, b3
b2:
  v7 = load.i32 v4 align 2
  v8 = add.i32 v5, v7
  v9 = ptradd v4+4 inbounds
  jmp b1(v9, v8)
b3:
  ret v5
fn @pxor
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = ptradd v0, v2 * 4 inbounds
  v4 = iconst.i32 1365
  jmp b1(v0, v1)
b1(v5: ptr, v6: ptr):
  v7 = icmp.ne v5, v3
  br v7, b2, b3
b2:
  v8 = load.i32 v6 align 2
  v9 = xor.i32 v8, v4
  store v9, v5 align 2
  v10 = ptradd v5+4 inbounds
  v11 = ptradd v6+4 inbounds
  jmp b1(v10, v11)
b3:
  ret
fn @pbytes
  sig (ptr, i64, i64) -> i32
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i32 0
  v4 = ptradd v0, v1 * 4 inbounds
  v5 = ptradd v0, v2 * 1 inbounds
  jmp b1(v4, v3)
b1(v6: ptr, v7: i32):
  v8 = icmp.ugt v5, v6
  br v8, b2, b3
b2:
  v9 = load.i32 v6 align 2
  v10 = add.i32 v7, v9
  v11 = ptradd v6+4 inbounds
  jmp b1(v11, v10)
b3:
  ret v7
fn @pnear
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = ptradd v0, v1 * 2+2 inbounds
  jmp b1(v0, v2)
b1(v4: ptr, v5: i32):
  v6 = icmp.ult v4, v3
  br v6, b2, b3
b2:
  v7 = load.i32 v4 align 2
  v8 = xor.i32 v5, v7
  v9 = ptradd v4+4 inbounds
  jmp b1(v9, v8)
b3:
  ret v5
fn @pfind
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i32) -> i64
b0(v0: ptr, v1: i32):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = ptradd v2, v3 * 4 inbounds
  v5 = iconst.i64 2
  v6 = iconst.i64 -1
  jmp b1(v2)
b1(v7: ptr):
  v8 = icmp.ult v7, v4
  br v8, b2, b5
b2:
  v9 = load.i32 v7 align 2
  v10 = icmp.eq v9, v1
  br v10, b4, b3
b3:
  v11 = ptradd v7+4 inbounds
  jmp b1(v11)
b4:
  v12 = ptrtoint.i64 v7
  v13 = ptrtoint.i64 v2
  v14 = sub.i64 v12, v13
  v15 = lshr.i64 v14, v5
  ret v15
b5:
  ret v6
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
  slot s2 size 16 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 256
  v6 = iconst.i64 9
  v7 = iconst.i64 4
  v8 = iconst.i64 7
  v9 = iconst.i64 3
  jmp b1(v3)
b1(v10: i64):
  v11 = icmp.ult v10, v5
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v8
  v13 = urem.i64 v12, v6
  v14 = sub.i64 v13, v7
  v15 = trunc.i32 v14
  v16 = ptradd v1, v10 * 4
  store v15, v16 align 2
  v17 = add.i64 v10, v4
  jmp b1(v17)
b3:
  v18 = call.i32 @psum(v1, v0) : (ptr, i64) -> i32
  call @pxor(v2, v1, v0) : (ptr, ptr, i64) -> void
  v19 = call.i32 @psum(v2, v0) : (ptr, i64) -> i32
  v20 = urem.i64 v0, v8
  v21 = mul.i64 v0, v7
  v22 = urem.i64 v0, v9
  v23 = sub.i64 v21, v22
  v24 = call.i32 @pbytes(v1, v20, v23) : (ptr, i64, i64) -> i32
  v25 = zext.i64 v18
  v26 = zext.i64 v19
  v27 = zext.i64 v24
  v28 = mul.i64 v25, v8
  v29 = xor.i64 v28, v26
  v30 = mul.i64 v29, v8
  v31 = xor.i64 v30, v27
  v32 = trunc.i32 v20
  v33 = slotaddr s2
  store v1, v33 align 3
  store v0, v33+8 align 3
  v34 = call.i64 @pfind(v33, v32) : (ptr, i32) -> i64
  v35 = mul.i64 v31, v8
  v36 = xor.i64 v35, v34
  v37 = ptradd v1+16
  v38 = iconst.i64 -2
  v39 = call.i32 @psum(v37, v38) : (ptr, i64) -> i32
  v40 = zext.i64 v39
  v41 = mul.i64 v36, v8
  v42 = xor.i64 v41, v40
  v43 = iconst.i64 2
  v44 = mul.i64 v0, v43
  v45 = sub.i64 v44, v22
  v46 = call.i32 @pnear(v1, v45) : (ptr, i64) -> i32
  v47 = zext.i64 v46
  v48 = mul.i64 v42, v8
  v49 = xor.i64 v48, v47
  ret v49
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    for f in ["psum", "pxor", "pbytes", "pfind", "pnear"] {
        let t = text_of(&a, f);
        assert(t.contains("load.v4i32"), t.as_str());
    }
    for n in 0..90u64 {
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// `while p > begin { p -= 1; .. }` and `while p != begin`: loops that step pointers down take a counter
// down to 0 and vectorize: a sum from `begin + n`, a copy through two pointers stepping down, and a start
// some bytes from an unrelated base, which may lie below `begin` (no iteration) or not a whole number of
// elements above it.
@test
fn loops_that_step_pointers_down_take_a_counter_and_vectorize() {
    let src = M"(lir ptr 8
sym @dsum fn global noinline
sym @dcopy fn global noinline
sym @dgen fn global noinline
sym @drive fn global
fn @dsum
  sig (ptr, i64) -> i32
b0(v0: ptr, v1: i64):
  v2 = iconst.i32 0
  v3 = ptradd v0, v1 * 4 inbounds
  jmp b1(v3, v2)
b1(v4: ptr, v5: i32):
  v6 = icmp.ugt v4, v0
  br v6, b2, b3
b2:
  v7 = ptradd v4-4 inbounds
  v8 = load.i32 v7 align 2
  v9 = add.i32 v5, v8
  jmp b1(v7, v9)
b3:
  ret v5
fn @dcopy
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = ptradd v0, v2 * 4 inbounds
  v4 = ptradd v1, v2 * 4 inbounds
  v5 = iconst.i32 1365
  jmp b1(v3, v4)
b1(v6: ptr, v7: ptr):
  v8 = icmp.ne v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v6-4 inbounds
  v10 = ptradd v7-4 inbounds
  v11 = load.i32 v10 align 2
  v12 = xor.i32 v11, v5
  store v12, v9 align 2
  jmp b1(v9, v10)
b3:
  ret
fn @dgen
  sig (ptr, i64, i64) -> i32
b0(v0: ptr, v1: i64, v2: i64):
  v3 = iconst.i32 0
  v4 = ptradd v0, v1 * 1 inbounds
  v5 = ptradd v0, v2 * 4+8 inbounds
  jmp b1(v4, v3)
b1(v6: ptr, v7: i32):
  v8 = icmp.ult v5, v6
  br v8, b2, b3
b2:
  v9 = ptradd v6-4 inbounds
  v10 = load.i32 v9 align 2
  v11 = xor.i32 v7, v10
  jmp b1(v9, v11)
b3:
  ret v7
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 256
  v6 = iconst.i64 9
  v7 = iconst.i64 4
  v8 = iconst.i64 7
  v9 = iconst.i64 3
  jmp b1(v3)
b1(v10: i64):
  v11 = icmp.ult v10, v5
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v8
  v13 = urem.i64 v12, v6
  v14 = sub.i64 v13, v7
  v15 = trunc.i32 v14
  v16 = ptradd v1, v10 * 4
  store v15, v16 align 2
  v17 = add.i64 v10, v4
  jmp b1(v17)
b3:
  v18 = call.i32 @dsum(v1, v0) : (ptr, i64) -> i32
  call @dcopy(v2, v1, v0) : (ptr, ptr, i64) -> void
  v19 = call.i32 @dsum(v2, v0) : (ptr, i64) -> i32
  v20 = mul.i64 v0, v7
  v21 = urem.i64 v0, v9
  v22 = add.i64 v20, v21
  v23 = urem.i64 v0, v6
  v24 = call.i32 @dgen(v1, v22, v23) : (ptr, i64, i64) -> i32
  v25 = zext.i64 v18
  v26 = zext.i64 v19
  v27 = zext.i64 v24
  v28 = mul.i64 v25, v8
  v29 = xor.i64 v28, v26
  v30 = mul.i64 v29, v8
  v31 = xor.i64 v30, v27
  ret v31
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    for f in ["dsum", "dcopy", "dgen"] {
        let t = text_of(&a, f);
        assert(t.contains("load.v4i32"), t.as_str());
    }
    for n in 0..90u64 {
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A search that carries nothing but its counter and has no effect leaves its vector loop at the first
// lane that matches, the least lane index over the copies, and the loop runs that iteration alone: a byte
// search (64 lanes a vector iteration) and the end of a run (it leaves where a lane stops holding).
@test
fn an_early_exit_goes_on_at_the_first_lane_that_leaves() {
    let src = M"(lir ptr 8
sym @find fn global noinline
sym @span fn global noinline
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
fn @span
  layout l0 size 16 align 3 [0 ptr, 8 i64]
  sig (l0, i32) -> i64
b0(v0: ptr, v1: i32):
  v2 = load.ptr v0 align 3
  v3 = load.i64 v0+8 align 3
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b4
b2:
  v8 = ptradd v2, v6 * 4
  v9 = load.i32 v8 align 2
  v10 = icmp.eq v9, v1
  br v10, b3, b4
b3:
  v11 = add.i64 v6, v5
  jmp b1(v11)
b4:
  ret v6
fn @drive
  sig (i64, i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 1024 align 3
  slot s2 size 16 align 3
  slot s3 size 16 align 3
b0(v0: i64, v1: i64):
  v2 = slotaddr s0
  v3 = slotaddr s1
  v4 = slotaddr s2
  v5 = slotaddr s3
  v6 = iconst.i64 0
  v7 = iconst.i64 1
  v8 = iconst.i64 127
  v9 = iconst.i32 5
  jmp b1(v6)
b1(v10: i64):
  v11 = iconst.i64 256
  v12 = icmp.ult v10, v11
  br v12, b2, b3
b2:
  v13 = and.i64 v10, v8
  v14 = trunc.i8 v13
  v15 = ptradd v2, v10 * 1
  store v14, v15 align 0
  v16 = ptradd v3, v10 * 4
  store v9, v16 align 2
  v17 = add.i64 v10, v7
  jmp b1(v17)
b3:
  v18 = iconst.i8 -1
  v19 = ptradd v2, v1 * 1
  store v18, v19 align 0
  v20 = iconst.i32 6
  v21 = ptradd v3, v1 * 4
  store v20, v21 align 2
  store v2, v4 align 3
  store v0, v4+8 align 3
  store v3, v5 align 3
  store v0, v5+8 align 3
  v22 = call.i64 @find(v4, v18) : (ptr, i8) -> i64
  v23 = call.i64 @span(v5, v9) : (ptr, i32) -> i64
  v24 = iconst.i64 20
  v25 = shl.i64 v22, v24
  v26 = add.i64 v25, v23
  ret v26
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let f = text_of(&a, "find");
    assert(f.contains("vcmp.eq.v16i8") && f.contains("reduce_min.i8"), f.as_str());
    let s = text_of(&a, "span");
    assert(s.contains("vcmp.eq.v4i32") && s.contains("reduce_min.i32"), s.as_str());
    let lens: [u64; 6] = [0, 15, 64, 100, 200, 256];
    let at: [u64; 9] = [0, 15, 16, 47, 63, 64, 100, 199, 255];
    for k in 0..6usize {
        for j in 0..9usize {
            let args: []u64 = [unsafe lens[k], unsafe at[j]];
            same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
        }
    }
}

// An array of structs of two `i32` copied element by element through a slot that changes a field
// (`let mut t = a[i]; t.y += t.x; b[i] = t`): the copies move the fields, so the loop loads every second
// element and stores the pairs back interleaved, in vectors.
@test
fn a_struct_copied_through_a_slot_vectorizes_by_its_fields() {
    let src = M"(lir ptr 8
sym @upd fn global noinline
sym @drive fn global
fn @upd
  sig (ptr, ptr, i64) -> void
  slot s0 size 8 align 2
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = slotaddr s0
  v4 = iconst.i64 8
  v5 = iconst.i64 0
  v6 = iconst.i64 1
  jmp b1(v5)
b1(v7: i64):
  v8 = icmp.ult v7, v2
  br v8, b2, b3
b2:
  v9 = ptradd v1, v7 * 8
  memcpy v3, v9, v4
  v10 = load.i32 v3 align 2
  v11 = load.i32 v3+4 align 2
  v12 = add.i32 v10, v11
  store v12, v3+4 align 2
  v13 = ptradd v0, v7 * 8
  memcpy v13, v3, v4
  v14 = add.i64 v7, v6
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i64 256
  v6 = iconst.i64 7
  v7 = iconst.i64 31
  jmp b1(v3)
b1(v8: i64):
  v9 = icmp.ult v8, v5
  br v9, b2, b3
b2:
  v10 = mul.i64 v8, v6
  v11 = trunc.i32 v10
  v12 = ptradd v1, v8 * 4
  store v11, v12 align 2
  v13 = ptradd v2, v8 * 4
  store v11, v13 align 2
  v14 = add.i64 v8, v4
  jmp b1(v14)
b3:
  call @upd(v2, v1, v0) : (ptr, ptr, i64) -> void
  jmp b4(v3, v3)
b4(v15: i64, v16: i64):
  v17 = icmp.ult v15, v5
  br v17, b5, b6
b5:
  v18 = ptradd v2, v15 * 4
  v19 = load.i32 v18 align 2
  v20 = zext.i64 v19
  v21 = mul.i64 v16, v7
  v22 = add.i64 v21, v20
  v23 = add.i64 v15, v4
  jmp b4(v23, v22)
b6:
  ret v16
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let u = text_of(&a, "upd");
    assert(u.contains("vunzip.v4i32") && u.contains("vziplo.v4i32") && !u.contains("lshr"), u.as_str());
    let lens: [u64; 7] = [0, 1, 3, 4, 9, 64, 127];
    for k in 0..7usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Triples of bytes (RGB pixels): the loads of each third byte take every third lane of three vectors and
// the stores of a whole triple interleave three vectors, both as shuffles of three vectors (`vperm3`): a
// gray value of each pixel and the pixels with two channels swapped and one changed.
@test
fn groups_of_every_third_element_vectorize() {
    let src = M"(lir ptr 8
sym @gray fn global noinline
sym @swap fn global noinline
sym @drive fn global
fn @gray
  sig (ptr, ptr, i64) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i8 1
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 3
  v9 = load.i8 v8 align 0
  v10 = load.i8 v8+1 align 0
  v11 = load.i8 v8+2 align 0
  v12 = lshr.i8 v9, v5
  v13 = lshr.i8 v10, v5
  v14 = add.i8 v12, v13
  v15 = xor.i8 v14, v11
  v16 = ptradd v0, v6 * 1
  store v15, v16 align 0
  v17 = add.i64 v6, v4
  jmp b1(v17)
b3:
  ret
fn @swap
  sig (ptr, ptr, i64) -> void
  ref p0 0 noalias
  ref p1 0 readonly
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  v5 = iconst.i8 7
  jmp b1(v3)
b1(v6: i64):
  v7 = icmp.ult v6, v2
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 3
  v9 = load.i8 v8 align 0
  v10 = load.i8 v8+1 align 0
  v11 = load.i8 v8+2 align 0
  v12 = add.i8 v10, v5
  v13 = ptradd v0, v6 * 3
  store v11, v13 align 0
  store v12, v13+1 align 0
  store v9, v13+2 align 0
  v14 = add.i64 v6, v4
  jmp b1(v14)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
  slot s2 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  v6 = iconst.i64 1024
  v7 = iconst.i64 37
  v8 = iconst.i64 31
  v9 = iconst.i64 3
  jmp b1(v4)
b1(v10: i64):
  v11 = icmp.ult v10, v6
  br v11, b2, b3
b2:
  v12 = mul.i64 v10, v7
  v13 = xor.i64 v12, v10
  v14 = trunc.i8 v13
  v15 = ptradd v1, v10 * 1
  store v14, v15 align 0
  v16 = add.i64 v10, v5
  jmp b1(v16)
b3:
  call @gray(v3, v1, v0) : (ptr, ptr, i64) -> void
  call @swap(v2, v1, v0) : (ptr, ptr, i64) -> void
  jmp b4(v4, v4)
b4(v17: i64, v18: i64):
  v19 = icmp.ult v17, v0
  br v19, b5, b6
b5:
  v20 = ptradd v3, v17 * 1
  v21 = load.i8 v20 align 0
  v22 = zext.i64 v21
  v23 = ptradd v2, v17 * 3
  v24 = load.i8 v23 align 0
  v25 = load.i8 v23+1 align 0
  v26 = load.i8 v23+2 align 0
  v27 = zext.i64 v24
  v28 = zext.i64 v25
  v29 = zext.i64 v26
  v30 = mul.i64 v18, v8
  v31 = add.i64 v30, v22
  v32 = mul.i64 v31, v8
  v33 = add.i64 v32, v27
  v34 = mul.i64 v33, v8
  v35 = add.i64 v34, v28
  v36 = mul.i64 v35, v8
  v37 = add.i64 v36, v29
  v38 = add.i64 v17, v5
  jmp b4(v38, v37)
b6:
  ret v18
)";
    let (b, a) = optimized_for(src, VECTOR, 16, VOPS_ALL);
    let g = text_of(&a, "gray");
    assert(g.contains("vop.shuffle.v16i8 (") && g.contains("lanes [0, 3, 6, 9"), g.as_str());
    let s = text_of(&a, "swap");
    assert(s.contains("vop.shuffle.v16i8 (") && s.contains("lanes [0, 16, 32, 1, 17"), s.as_str());
    let lens: [u64; 9] = [0, 1, 15, 16, 17, 32, 63, 100, 170];
    for k in 0..9usize {
        let args: []u64 = [unsafe lens[k]];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// Pairs of elements whose even one is one operation of two inputs' even elements and whose odd one another
// of their odd ones (`o[2i] = a[2i] - b[2i]`, `o[2i + 1] = a[2i + 1] + b[2i + 1]`) vectorize as both
// operations of the inputs' vectors, the lanes chosen by a constant mask (`vsel`), not as the even and
// odd lanes split and zipped again; a pair of one operation is that operation alone; a pair whose odd
// element reads other inputs keeps the split. Each runs as before, of 0 to 64 pairs.
const ALTERNATE: str = M"(lir ptr 8
sym @as fn global noinline
sym @asf fn global noinline
sym @same fn global noinline
sym @cross fn global noinline
sym @fill fn global noinline
sym @drive fn global
fn @as
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 8
  v9 = load.i32 v8 align 2
  v10 = load.i32 v8+4 align 2
  v11 = ptradd v2, v6 * 8
  v12 = load.i32 v11 align 2
  v13 = load.i32 v11+4 align 2
  v14 = sub.i32 v9, v12
  v15 = add.i32 v10, v13
  v16 = ptradd v0, v6 * 8
  store v14, v16 align 2
  store v15, v16+4 align 2
  v17 = add.i64 v6, v5
  jmp b1(v17)
b3:
  ret
fn @asf
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 16
  v9 = load.f64 v8 align 3
  v10 = load.f64 v8+8 align 3
  v11 = ptradd v2, v6 * 16
  v12 = load.f64 v11 align 3
  v13 = load.f64 v11+8 align 3
  v14 = fsub.f64 v9, v12
  v15 = fadd.f64 v10, v13
  v16 = ptradd v0, v6 * 16
  store v14, v16 align 3
  store v15, v16+8 align 3
  v17 = add.i64 v6, v5
  jmp b1(v17)
b3:
  ret
fn @same
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 8
  v9 = load.i32 v8 align 2
  v10 = load.i32 v8+4 align 2
  v11 = ptradd v2, v6 * 8
  v12 = load.i32 v11 align 2
  v13 = load.i32 v11+4 align 2
  v14 = xor.i32 v9, v12
  v15 = xor.i32 v10, v13
  v16 = ptradd v0, v6 * 8
  store v14, v16 align 2
  store v15, v16+4 align 2
  v17 = add.i64 v6, v5
  jmp b1(v17)
b3:
  ret
fn @cross
  sig (ptr, ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: ptr, v3: i64):
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  jmp b1(v4)
b1(v6: i64):
  v7 = icmp.ult v6, v3
  br v7, b2, b3
b2:
  v8 = ptradd v1, v6 * 8
  v9 = load.i32 v8 align 2
  v10 = load.i32 v8+4 align 2
  v11 = ptradd v2, v6 * 8
  v12 = load.i32 v11 align 2
  v13 = load.i32 v11+4 align 2
  v14 = sub.i32 v9, v12
  v15 = add.i32 v10, v9
  v16 = ptradd v0, v6 * 8
  store v14, v16 align 2
  store v15, v16+4 align 2
  v17 = add.i64 v6, v5
  jmp b1(v17)
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
  slot s0 size 1024 align 3
  slot s1 size 1024 align 3
  slot s2 size 1024 align 3
  slot s3 size 1024 align 3
  slot s4 size 2048 align 3
  slot s5 size 2048 align 3
  slot s6 size 2048 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = slotaddr s2
  v4 = slotaddr s3
  v5 = slotaddr s4
  v6 = slotaddr s5
  v7 = slotaddr s6
  v8 = iconst.i64 256
  v9 = iconst.i32 1000003
  v10 = iconst.i32 -77777
  call @fill(v1, v8, v9) : (ptr, i64, i32) -> void
  call @fill(v2, v8, v10) : (ptr, i64, i32) -> void
  v11 = iconst.i64 0
  v12 = iconst.i64 1
  jmp b1(v11)
b1(v13: i64):
  v14 = icmp.ult v13, v8
  br v14, b2, b3
b2:
  v15 = ptradd v1, v13 * 4
  v16 = load.i32 v15 align 2
  v17 = sitofp.f64 v16
  v18 = ptradd v5, v13 * 8
  store v17, v18 align 3
  v19 = ptradd v2, v13 * 4
  v20 = load.i32 v19 align 2
  v21 = sitofp.f64 v20
  v22 = ptradd v6, v13 * 8
  store v21, v22 align 3
  v23 = add.i64 v13, v12
  jmp b1(v23)
b3:
  call @as(v3, v1, v2, v0) : (ptr, ptr, ptr, i64) -> void
  call @same(v4, v1, v2, v0) : (ptr, ptr, ptr, i64) -> void
  call @asf(v5, v5, v6, v0) : (ptr, ptr, ptr, i64) -> void
  call @cross(v7, v1, v2, v0) : (ptr, ptr, ptr, i64) -> void
  jmp b4(v11, v11)
b4(v24: i64, v25: i64):
  v26 = icmp.ult v24, v8
  br v26, b5, b6
b5:
  v27 = ptradd v3, v24 * 4
  v28 = load.i32 v27 align 2
  v29 = ptradd v4, v24 * 4
  v30 = load.i32 v29 align 2
  v31 = ptradd v5, v24 * 8
  v32 = load.i64 v31 align 3
  v33 = ptradd v7, v24 * 4
  v34 = load.i32 v33 align 2
  v35 = sext.i64 v28
  v36 = mul.i64 v25, v8
  v37 = add.i64 v36, v35
  v38 = sext.i64 v30
  v39 = xor.i64 v37, v38
  v40 = add.i64 v39, v32
  v41 = sext.i64 v34
  v42 = sub.i64 v40, v41
  v43 = add.i64 v24, v12
  jmp b4(v43, v42)
b6:
  ret v25
)";

@test
fn alternating_pairs_vectorize_as_both_operations_and_a_select() {
    let (b, a) = optimized(ALTERNATE, VECTOR);
    let ta = text_of(&a, "as");
    assert(
        ta.contains("vsel.v4i32") && ta.contains("sub.v4i32") && ta.contains("add.v4i32") && !ta.contains("vunzip") && !ta.contains(
            "vzip",
        ),
        ta.as_str(),
    );
    let tf = text_of(&a, "asf");
    assert(
        tf.contains("vsel.v2f64") && tf.contains("fsub.v2f64") && !tf.contains("vunzip") && !tf.contains("vzip"),
        tf.as_str(),
    );
    let ts = text_of(&a, "same");
    assert(ts.contains("xor.v4i32") && !ts.contains("vsel") && !ts.contains("vunzip"), ts.as_str());
    let tc = text_of(&a, "cross");
    assert(!tc.contains("vsel"), tc.as_str());
    for n in 0..65u64 {
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
}

// A count of 2-byte lanes stored as 4-byte ones: vectors of 8 bytes, whose byte lookups hold 8 of the 16
// nibbles' counts, count by bit-parallel sums, not by the table (`by_table`); each count as before.
const NARROW_POP: str = M"(lir ptr 8
sym @pop fn global noinline
sym @fill fn global noinline
sym @drive fn global
fn @pop
  sig (ptr, ptr, i64) -> void
b0(v0: ptr, v1: ptr, v2: i64):
  v3 = iconst.i64 0
  v4 = iconst.i64 1
  jmp b1(v3)
b1(v5: i64):
  v6 = icmp.ult v5, v2
  br v6, b2, b3
b2:
  v7 = ptradd v0, v5 * 2
  v8 = load.i16 v7 align 1
  v9 = popcnt.i16 v8
  v10 = zext.i32 v9
  v11 = ptradd v1, v5 * 4
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
  v4 = iconst.i16 -24575
  jmp b1(v2)
b1(v5: i64):
  v6 = icmp.ult v5, v1
  br v6, b2, b3
b2:
  v7 = trunc.i16 v5
  v8 = mul.i16 v7, v4
  v9 = ptradd v0, v5 * 2
  store v8, v9 align 1
  v10 = add.i64 v5, v3
  jmp b1(v10)
b3:
  ret
fn @drive
  sig (i64) -> i64
  slot s0 size 256 align 3
  slot s1 size 512 align 3
b0(v0: i64):
  v1 = slotaddr s0
  v2 = slotaddr s1
  v3 = iconst.i64 128
  v4 = iconst.i64 0
  v5 = iconst.i64 1
  call @fill(v1, v3) : (ptr, i64) -> void
  call @pop(v1, v2, v0) : (ptr, ptr, i64) -> void
  jmp b1(v4, v4)
b1(v6: i64, v7: i64):
  v8 = icmp.ult v6, v0
  br v8, b2, b3
b2:
  v9 = ptradd v2, v6 * 4
  v10 = load.i32 v9 align 2
  v11 = zext.i64 v10
  v12 = mul.i64 v7, v3
  v13 = add.i64 v12, v11
  v14 = add.i64 v6, v5
  jmp b1(v14, v13)
b3:
  ret v7
)";

@test
fn narrow_counts_of_8_byte_vectors_take_no_byte_lookups() {
    let mut err = String::new();
    let b = lparse::parse(NARROW_POP, &mut err).unwrap();
    let mut a = lparse::parse(NARROW_POP, &mut err).unwrap();
    a.vector = 16;
    a.vops = VOPS_ALL;
    a.vec_bits = 0;
    a.vtbl = true;
    let none = Vector::<bool>::new();
    lopt::optimize(&mut a, &none, lopt::Config { inline: il::SPEED, loops: VECTOR });
    for n in 0..100u64 {
        let args: []u64 = [n];
        same_outcome(&b, &a, "drive", args, run_value(&b, "drive", args), false);
    }
    let t = text_of(&a, "pop");
    assert(t.contains(".v4i16") && !t.contains("swizzle_or_zero.v8i8"), t.as_str());
}
