// The certificate checker of the contract prover (src/prove/kernel.spc): it accepts each kind of valid
// proof, and rejects the same proof with one part changed.
import ast::ast as *;
import prove::terms as *;
import prove::kernel as *;

// The checker at the narrow numbers' width.
const B: usize = NUM_NARROW;

// The builders' `which` for the valid proof; another value changes one part of it.
const VALID: u32 = 0;

fn row(st: &mut Stated<B>, terms: &Vector<LinTerm<B>>, k: i64) {
    let start = st.pool.len() as u32;
    st.pool.extend_copy(terms);
    st.rows.push(Row::<B> { k: wide::<B>(k), start: start, len: terms.len() as u32 });
}

// The row `c * x + k <= 0`.
fn row1(st: &mut Stated<B>, c: i64, x: u32, k: i64) {
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: wide::<B>(c), atom: x });
    row(st, &v, k);
}

const fn mult(m: i64, i: u32, kind: u8) Mult<B> {
    return Mult::<B> { m: wide::<B>(m), r: RowRef { i: i, kind: kind } };
}

fn leaf(pf: &mut Proof<B>, ms: &Vector<Mult<B>>) u32 {
    let start = pf.mults.len() as u32;
    pf.mults.extend_copy(ms);
    pf.nodes.push(
        TreeNode::<B> {
            v: i128::zero(),
            atom: NONE,
            left: NONE,
            right: NONE,
            ms: start,
            mn: ms.len() as u32,
            kind: N_LEAF,
        },
    );
    return (pf.nodes.len() - 1) as u32;
}

fn leaf2(pf: &mut Proof<B>, a: Mult<B>, b: Mult<B>) u32 {
    let mut ms = Vector::<Mult<B>>::new();
    ms.push(a);
    ms.push(b);
    return leaf(pf, &ms);
}

// End the proof with a tree over the facts [0, upto).
fn end_tree(pf: &mut Proof<B>, root: u32, upto: u32) {
    pf.trees.push(Tree { root: root, ha: NONE, hb: NONE, upto: upto });
    pf.end = X_LA;
    pf.p = (pf.trees.len() - 1) as u32;
}

fn accepts(tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>) bool {
    let mut k = Kernel::<B>::new();
    return k.check(tm, st, pf);
}

// `x <= 1` and `x >= 2`: their sum is `1 <= 0`.
fn farkas(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let mut st = Stated::<B>::new();
    row1(&mut st, 1, x, -1);
    row1(&mut st, -1, x, 2);
    let mut pf = Proof::<B>::new();
    let n = leaf2(
        &mut pf,
        mult(pick(which == 1, 2i64, 1), pick(which == 2, 5u32, 0), RW_IN),
        mult(pick(which == 3, -1i64, pick(which == 4, 0i64, 1)), 1, RW_IN),
    );
    end_tree(&mut pf, n, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn farkas_leaves() {
    assert(farkas(VALID), "a sum of rows that is a constant above 0");
    assert(!farkas(1), "a multiplier that leaves an atom");
    assert(!farkas(2), "a row the branch does not have");
    assert(!farkas(3), "a negative multiplier");
    assert(!farkas(4), "a zero multiplier");
}

// The rows of `farkas`, refuted below a split of `x` at 1: each leaf takes its own side's bound.
fn split(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(8, false);
    let flag = tm.var(W_BOOL, false);
    let mut st = Stated::<B>::new();
    row1(&mut st, 1, x, -1);
    row1(&mut st, -1, x, 2);
    let mut pf = Proof::<B>::new();
    pf.nodes.push(
        TreeNode::<B> {
            v: wide::<B>(1),
            atom: pick(which == 3, flag, x),
            left: 1,
            right: 2,
            ms: 0,
            mn: 0,
            kind: N_SPLIT,
        },
    );
    // Left, `x <= 1`, with `x >= 2`; right, `x >= 2`, with `x <= 1`.
    let _ = leaf2(&mut pf, mult(1, 0, RW_SPLIT_LO), mult(1, 1, RW_IN));
    // The left side's bound sums to a constant with `x >= 2` too, but it does not hold on the right.
    if which == 1 {
        let _ = leaf2(&mut pf, mult(1, 0, RW_SPLIT_LO), mult(1, 1, RW_IN));
    } else {
        let _ = leaf2(&mut pf, mult(1, 0, RW_SPLIT_HI), mult(1, 0, RW_IN));
    }
    if which == 2 {
        let mut root = pf.nodes[0];
        root.left = 0;
        pf.nodes.set(0, root);
    }
    end_tree(&mut pf, 0, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn split_trees() {
    assert(split(VALID), "each side refuted with its own bound");
    assert(!split(1), "a bound of the other side");
    assert(!split(2), "a child before its parent");
    assert(!split(3), "a split of a boolean");
}

// `y >= 3`, `y <= 3` and `x * y >= 3 * x + 1`: splits of `y` at 2 and 3 leave the middle leaf `y` 3 only,
// where the product is `3 * x` (`RW_FIX_LE`) and the last row sums with it to `1 <= 0`.
fn fixed_product(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(8, false);
    let y = tm.var(8, false);
    let p = tm.arith(T_MUL, x, y, 16, false);
    let o = pick(tm.at(p).b == y, 1u32, 0);
    let mut st = Stated::<B>::new();
    row1(&mut st, -1, y, 3);
    row1(&mut st, 1, y, -3);
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: p });
    v.push(LinTerm::<B> { c: wide::<B>(3), atom: x });
    row(&mut st, &v, 1);
    let mut pf = Proof::<B>::new();
    pf.nodes.push(TreeNode::<B> { v: wide::<B>(2), atom: y, left: 1, right: 2, ms: 0, mn: 0, kind: N_SPLIT });
    let _ = leaf2(&mut pf, mult(1, 0, RW_SPLIT_LO), mult(1, 0, RW_IN));
    // At 4 the left side leaves `y` 3 or 4.
    pf.nodes.push(
        TreeNode::<B> {
            v: wide::<B>(pick(which == 1, 4i64, 3)),
            atom: y,
            left: 3,
            right: 4,
            ms: 0,
            mn: 0,
            kind: N_SPLIT,
        },
    );
    let fi = if which == 2 {
        p << 1 | 1 - o
    } else if which == 3 {
        x << 1 | 1
    } else {
        p << 1 | o
    };
    let _ = leaf2(&mut pf, mult(1, fi, RW_FIX_LE), mult(1, 2, RW_IN));
    let _ = leaf2(&mut pf, mult(1, 2, RW_SPLIT_HI), mult(1, 1, RW_IN));
    end_tree(&mut pf, 0, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn products_of_fixed_operands() {
    assert(fixed_product(VALID), "the product as 3 times the other operand where the splits fix `y`");
    assert(!fixed_product(1), "an operand the splits leave two values");
    assert(!fixed_product(2), "the operand the splits do not fix");
    assert(!fixed_product(3), "a term that is not a product");
}

// `a <= c`, `b >= 0` and `a * b >= c * b + 1`: the product of the first two rows is `a * b - c * b <= 0`
// (`RW_PROD`), which sums with the last to `1 <= 0`.
fn row_product(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let a = tm.var(8, false);
    let b = tm.var(8, false);
    let c = tm.var(8, false);
    let p1 = tm.arith(T_MUL, a, b, 16, false);
    let p2 = tm.arith(T_MUL, c, b, 16, false);
    let mut st = Stated::<B>::new();
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: wide::<B>(1), atom: a });
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: c });
    row(&mut st, &v, 0);
    row1(&mut st, -1, b, 0);
    v.clear();
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: p1 });
    v.push(LinTerm::<B> { c: wide::<B>(1), atom: p2 });
    row(&mut st, &v, 1);
    let mut pf = Proof::<B>::new();
    pf.monos.push(p1);
    if which != 1 {
        pf.monos.push(p2);
    }
    let first = RowRef { i: 0, kind: pick(which == 2, RW_HYP, RW_IN) };
    pf.prods.push(Prod { a: first, b: RowRef { i: 1, kind: RW_IN }, ms: 0, mn: pf.monos.len() as u32 });
    let n = leaf2(&mut pf, mult(1, pick(which == 3, 1u32, 0), RW_PROD), mult(1, 2, RW_IN));
    end_tree(&mut pf, n, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn products_of_rows() {
    assert(row_product(VALID), "the product of `a <= c` and `b >= 0`");
    assert(!row_product(1), "a product of two atoms that is no product atom of the pool");
    assert(!row_product(2), "a factor that holds on part of the branch only");
    assert(!row_product(3), "a product the proof does not hold");
}

// `x == y` and `f(x) < f(y)`: the congruence `f(x) == f(y)` as rows refutes the branch.
fn congruence(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let y = tm.var(32, false);
    let z = tm.var(32, false);
    let mut xs = Vector::<u32>::new();
    xs.push(x);
    let fx = tm.call(7, &xs, 32, false);
    xs.clear();
    xs.push(y);
    let fy = tm.call(pick(which == 1, 8u64, 7), &xs, 32, false);
    let mut st = Stated::<B>::new();
    st.eqs.push(pick(which == 2, z, x) as u64 << 32 | y as u64);
    // f(x) - f(y) + 1 <= 0
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: i128::one(), atom: fx });
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: fy });
    row(&mut st, &v, 1);
    let mut pf = Proof::<B>::new();
    pf.facts.push(Fact { a: x, b: y, p: 0, q: NONE, kind: F_IN });
    pf.cargs.push(0);
    pf.facts.push(Fact { a: fx, b: fy, p: 0, q: 1, kind: F_CONG });
    // f(x) - f(y) + 1 <= 0 and f(y) - f(x) <= 0.
    let n = leaf2(&mut pf, mult(1, 0, RW_IN), mult(1, 1, RW_EQ_GE));
    end_tree(&mut pf, n, pick(which == 3, 1u32, 2));
    return accepts(&tm, &st, &pf);
}

@test
fn congruence_facts() {
    assert(congruence(VALID), "a call over equal arguments");
    assert(!congruence(1), "calls of two functions");
    assert(!congruence(2), "an equality the branch does not state");
    assert(!congruence(3), "a tree that reads a fact past its prefix");
}

// `x <= y` and `y <= x` imply `x == y` (two trees, one per direction), so `f(x) == f(y)`, against
// `f(x) < f(y)`.
fn implied(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let y = tm.var(32, false);
    let mut xs = Vector::<u32>::new();
    xs.push(x);
    let fx = tm.call(7, &xs, 32, false);
    xs.clear();
    xs.push(y);
    let fy = tm.call(7, &xs, 32, false);
    let mut st = Stated::<B>::new();
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: i128::one(), atom: x });
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: y });
    row(&mut st, &v, 0); // x - y <= 0
    v.clear();
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: x });
    v.push(LinTerm::<B> { c: i128::one(), atom: y });
    row(&mut st, &v, 0); // y - x <= 0
    v.clear();
    v.push(LinTerm::<B> { c: i128::one(), atom: fx });
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: fy });
    row(&mut st, &v, 1); // f(x) - f(y) + 1 <= 0
    let mut pf = Proof::<B>::new();
    // x < y, x - y + 1 <= 0, with y - x <= 0; y < x with x - y <= 0.
    let n1 = leaf2(&mut pf, mult(1, NONE, RW_HYP), mult(1, 1, RW_IN));
    pf.trees.push(Tree { root: n1, ha: x, hb: y, upto: 0 });
    let n2 = leaf2(&mut pf, mult(1, NONE, RW_HYP), mult(1, 0, RW_IN));
    pf.trees.push(Tree { root: n2, ha: pick(which == 1, x, y), hb: pick(which == 1, y, x), upto: 0 });
    pf.facts.push(Fact { a: x, b: y, p: 0, q: 1, kind: F_ARITH });
    pf.cargs.push(0);
    pf.facts.push(Fact { a: fx, b: fy, p: 0, q: 1, kind: F_CONG });
    let n = leaf2(&mut pf, mult(1, 2, RW_IN), mult(1, 1, RW_EQ_GE));
    end_tree(&mut pf, n, 2);
    return accepts(&tm, &st, &pf);
}

@test
fn implied_equalities() {
    assert(implied(VALID), "both directions refuted");
    assert(!implied(1), "one direction twice");
}

// `x == 2 * y + 1` and `x == 2 * z`: each cut, the sum of one row of each equality divided by 2, and
// the two cuts sum to `1 <= 0`.
fn cuts(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let y = tm.var(32, false);
    let z = tm.var(32, false);
    let mut st = Stated::<B>::new();
    let mut v = Vector::<LinTerm<B>>::new();
    v.push(LinTerm::<B> { c: i128::one(), atom: x });
    v.push(LinTerm::<B> { c: wide::<B>(-2), atom: y });
    row(&mut st, &v, -1); // x - 2y - 1 <= 0
    v.clear();
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: x });
    v.push(LinTerm::<B> { c: wide::<B>(2), atom: y });
    row(&mut st, &v, 1); // -x + 2y + 1 <= 0
    v.clear();
    v.push(LinTerm::<B> { c: i128::one(), atom: x });
    v.push(LinTerm::<B> { c: wide::<B>(-2), atom: z });
    row(&mut st, &v, 0); // x - 2z <= 0
    v.clear();
    v.push(LinTerm::<B> { c: wide::<B>(-1), atom: x });
    v.push(LinTerm::<B> { c: wide::<B>(2), atom: z });
    row(&mut st, &v, 0); // -x + 2z <= 0
    let mut pf = Proof::<B>::new();
    // 2y - 2z + 1 <= 0, so y - z + 1 <= 0; -2y + 2z - 1 <= 0, so -y + z <= 0.
    pf.mults.push(mult(1, 2, RW_IN));
    pf.mults.push(mult(pick(which == 1, -1i64, 1), 1, RW_IN));
    pf.cuts.push(Cut { ms: 0, mn: 2, upto: 0 });
    pf.mults.push(mult(1, 3, RW_IN));
    pf.mults.push(mult(1, pick(which == 2, 1u32, 0), pick(which == 2, RW_CUT, RW_IN)));
    pf.cuts.push(Cut { ms: 2, mn: 2, upto: 0 });
    let n = leaf2(&mut pf, mult(1, 0, RW_CUT), mult(1, 1, RW_CUT));
    end_tree(&mut pf, n, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn chvatal_gomory_cuts() {
    assert(cuts(VALID), "two cuts of an odd and an even value");
    assert(!cuts(1), "a cut with a negative multiplier");
    assert(!cuts(2), "a cut that names itself");
}

// Ends on an equality the branch states false: a disequality, opposite literals, two constants.
fn ends(which: u32) bool {
    let mut tm = Terms::<B>::new();
    let p = tm.var(W_OTHER, false);
    let q = tm.var(W_OTHER, false);
    let b1 = tm.var(W_BOOL, false);
    let b2 = tm.var(W_BOOL, false);
    let one = tm.int(wide::<B>(1), 32, false);
    let two = tm.int(wide::<B>(pick(which == 4, 1i64, 2)), 32, false);
    let mut st = Stated::<B>::new();
    st.eqs.push(p as u64 << 32 | q as u64);
    st.eqs.push(b1 as u64 << 32 | b2 as u64);
    st.eqs.push(one as u64 << 32 | two as u64);
    st.neqs.push(q as u64 << 32 | p as u64);
    st.lits.push(b1 as u64 << 1 | 1);
    st.lits.push(b2 as u64 << 1 | pick(which == 5, 1u64, 0));
    let mut pf = Proof::<B>::new();
    let k = if which <= 1 {
        0u32
    } else if which <= 2 || which == 5 {
        1
    } else {
        2
    };
    let (a, b) = if k == 0 {
        (p, q)
    } else if k == 1 {
        (b1, b2)
    } else {
        (one, two)
    };
    pf.facts.push(Fact { a: a, b: b, p: k, q: NONE, kind: F_IN });
    pf.end = if k == 0 {
        X_NEQ
    } else if k == 1 {
        X_LITS
    } else {
        X_CONST
    };
    pf.p = 0;
    pf.q = pick(which == 1, 1u32, 0);
    return accepts(&tm, &st, &pf);
}

@test
fn conflict_ends() {
    assert(ends(VALID), "an equality the branch states false");
    assert(!ends(1), "a disequality the branch does not have");
    assert(ends(2), "a positive and a negative literal joined");
    assert(!ends(5), "two positive literals joined");
    assert(ends(3), "two different constants joined");
    assert(!ends(4), "a constant joined to itself");
}
