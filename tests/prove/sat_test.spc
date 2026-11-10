// The SAT refutations of the contract prover: the solver (src/prove/sat.spc) and its LRAT proofs, the
// checker (`Lrat`, src/prove/kernel.spc) that accepts each valid proof and rejects it with one part
// changed, the bits of terms (src/prove/blast.spc) against values computed by hand, and the kernel's
// lemmas and case-split check.
import ast::ast as *;
import prove::terms as *;
import prove::blast as *;
import prove::sat as *;
import prove::kernel as *;

const B: usize = NUM_NARROW;

// Variable `v`'s literal, negated when `neg`.
const fn lit(v: u32, neg: bool) u32 {
    return v << 1 | neg as u32;
}

fn clause(c: &mut Cnf, ls: &Vector<u32>) {
    c.lits.extend_copy(ls);
    c.end();
}

fn clause2(c: &mut Cnf, a: u32, b: u32) {
    c.lits.push(a);
    c.lits.push(b);
    c.end();
}

// Variables 1 (x) and 2 (y), every clause over both: clauses 2 to 5 after the true unit (clause 1).
fn all_four() Cnf {
    let mut c = Cnf::new();
    c.nv = 3;
    clause2(&mut c, lit(1, false), lit(2, false));
    clause2(&mut c, lit(1, true), lit(2, false));
    clause2(&mut c, lit(1, false), lit(2, true));
    clause2(&mut c, lit(1, true), lit(2, true));
    return c;
}

// `y` from clauses 2 and 3, then the empty clause from `y` and clauses 4 and 5; `which` changes one part.
fn handwritten(which: u32) bool {
    let c = all_four();
    let mut p = Vector::<u32>::new();
    let w: [u32; 12] = [6, 1, lit(2, false), 2, 2, 3, 7, 0, 3, 6, 4, 5];
    for j in 0..12 {
        p.push(w[j]);
    }
    if which == 1 {
        // A hint left out: `x` alone does not refute `not y`.
        let _ = p.remove(5);
        p.set(3, 1);
    } else if which == 2 {
        p.set(0, 7);
    } else if which == 3 {
        // A hint that is not unit: clause 4 before `y` has two free literals.
        p.set(9, 4);
        p.set(10, 6);
    } else if which == 4 {
        p.set(9, 7);
    } else if which == 5 {
        p.truncate(6);
    } else if which == 6 {
        // The first step claims `x`, which its hints do not give.
        p.set(2, lit(1, false));
    }
    let mut lr = Lrat::new();
    return lr.check(&c, &p);
}

@test
fn lrat_proofs() {
    assert(handwritten(0), "a valid proof");
    assert(!handwritten(1), "a hint left out");
    assert(!handwritten(2), "a step's id out of order");
    assert(!handwritten(3), "hints out of order");
    assert(!handwritten(4), "a hint naming a later clause");
    assert(!handwritten(5), "no empty clause");
    assert(!handwritten(6), "a clause its hints do not imply");
}

// Pigeon `p` in hole `h` of `holes`: variable `1 + p * holes + h`.
fn pigeons(n: u32, holes: u32) Cnf {
    let mut c = Cnf::new();
    c.nv = 1 + n * holes;
    for p in 0..n {
        let mut ls = Vector::<u32>::new();
        for h in 0..holes {
            ls.push(lit(1 + p * holes + h, false));
        }
        clause(&mut c, &ls);
    }
    for h in 0..holes {
        for p in 0..n {
            for q in p + 1..n {
                clause2(&mut c, lit(1 + p * holes + h, true), lit(1 + q * holes + h, true));
            }
        }
    }
    return c;
}

@test
fn sat_answers_with_checked_proofs() {
    let mut s = Sat::new();
    let mut lr = Lrat::new();
    let php = pigeons(5, 4);
    assert_eq(s.solve(&php, 1000000), SAT_REFUTED);
    assert(lr.check(&php, &s.proof), "five pigeons in four holes: the solver's proof");
    let n = s.proof.len();
    s.proof.truncate(n - 1);
    assert(!lr.check(&php, &s.proof), "the proof without the conflict's hint");
    let c = all_four();
    assert_eq(s.solve(&c, 1000), SAT_REFUTED);
    assert(lr.check(&c, &s.proof), "every clause over two variables");
    // A unit and its negation among the first clauses: the proof's ids still follow every clause.
    let mut e = Cnf::new();
    e.nv = 4;
    e.lits.push(lit(1, false));
    e.end();
    e.lits.push(lit(1, true));
    e.end();
    clause2(&mut e, lit(2, false), lit(3, false));
    assert_eq(s.solve(&e, 1000), SAT_REFUTED);
    assert(lr.check(&e, &s.proof), "a refutation while the clauses load");
    // `x or y`, `not x`, `not y or z`: the only model.
    let mut m = Cnf::new();
    m.nv = 4;
    clause2(&mut m, lit(1, false), lit(2, false));
    m.lits.push(lit(1, true));
    m.end();
    clause2(&mut m, lit(2, true), lit(3, false));
    assert_eq(s.solve(&m, 1000), SAT_MODEL);
    assert(!s.holds(1) && s.holds(2) && s.holds(3), "the model of a satisfiable CNF");
    let hard = pigeons(9, 8);
    assert_eq(s.solve(&hard, 100), SAT_ABORT);
}

// Whether the literals `lits` have a model in their bits (0), none by a proof the kernel accepts (1),
// or neither (2).
fn bits_answer(tm: &Terms<B>, lits: &Vector<u64>) u32 {
    let mut kn = Kernel::<B>::new();
    let mut s = Sat::new();
    if !kn.blast(tm, lits) {
        return 2;
    }
    let r = s.solve(&kn.bits().cnf, 4000000);
    if r == SAT_MODEL {
        return 0;
    }
    if r == SAT_REFUTED && kn.blast_lemma(&s.proof) {
        return 1;
    }
    return 2;
}

// `t == v` has a model and `t != v` none: the bits give `t` the value `v` (of `t`'s type).
fn value_is(tm: &mut Terms<B>, t: u32, v: i64) bool {
    let x = tm.at(t);
    let c = tm.int(wide::<B>(v), x.w, x.sg);
    let e = tm.cmp(T_EQ, t, c);
    let mut yes = Vector::<u64>::new();
    yes.push(tlit(e, SEL_ATOM, true));
    let mut no = Vector::<u64>::new();
    no.push(tlit(e, SEL_ATOM, false));
    return bits_answer(tm, &yes) == 0 && bits_answer(tm, &no) == 1;
}

// `t == 0` and `t != 0` both have models: the bits leave `t` free.
fn free(tm: &mut Terms<B>, t: u32) bool {
    let x = tm.at(t);
    let z = tm.int(Num::<B>::zero(), x.w, x.sg);
    let e = tm.cmp(T_EQ, t, z);
    let mut yes = Vector::<u64>::new();
    yes.push(tlit(e, SEL_ATOM, true));
    let mut no = Vector::<u64>::new();
    no.push(tlit(e, SEL_ATOM, false));
    return bits_answer(tm, &yes) == 0 && bits_answer(tm, &no) == 0;
}

// Whether `a op b` of type (`w`, `sg`) has the value `v` in its bits (`free`: no value).
fn binary_is(op: u8, a: i64, b: i64, w: u16, sg: bool, v: i64) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.int(wide::<B>(a), w, sg);
    let y = tm.int(wide::<B>(b), w, sg);
    let t = if op == T_ORD {
        tm.ord(x, y, w, sg)
    } else {
        tm.arith(op, x, y, w, sg)
    };
    return value_is(&mut tm, t, v);
}

fn binary_free(op: u8, a: i64, b: i64, w: u16, sg: bool) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.int(wide::<B>(a), w, sg);
    let y = tm.int(wide::<B>(b), w, sg);
    let t = tm.arith(op, x, y, w, sg);
    return free(&mut tm, t);
}

// Whether `op a` of type (`w`, `sg`), `a` of type (`aw`, `asg`), has the value `v`.
fn unary_is(op: u8, a: i64, aw: u16, asg: bool, w: u16, sg: bool, v: i64) bool {
    let mut tm = Terms::<B>::new();
    let x = tm.int(wide::<B>(a), aw, asg);
    let t = tm.unary(op, x, w, sg);
    return value_is(&mut tm, t, v);
}

@test
fn bits_of_operations() {
    assert(binary_is(T_SHR, -7, 1, 32, true, -4), "a signed shift right floors");
    assert(binary_is(T_SHR, 0x80000000, 31, 32, false, 1), "an unsigned shift right fills with zeros");
    assert(binary_is(T_SHL, 0x81, 1, 8, false, 2), "a shift left keeps the low bits");
    assert(binary_is(T_DIV, -7, 2, 32, true, -3), "a division truncates toward zero");
    assert(binary_is(T_REM, -7, 2, 32, true, -1), "a remainder has the dividend's sign");
    assert(binary_is(T_REM, 7, -2, 32, true, 1), "a remainder by a negative divisor");
    assert(binary_is(T_BAND, -1, 5, 8, true, 5), "an and of a negative value");
    assert(binary_is(T_BXOR, 0x0F, 0xFF, 8, false, 0xF0), "an exclusive or");
    assert(binary_is(T_ORD, 3, 5, 32, true, -1), "the order of 3 and 5");
    assert(unary_is(T_BNOT, 0x0F, 8, false, 8, false, 0xF0), "a not of an unsigned value");
    assert(unary_is(T_CAST, 300, 32, false, 8, false, 44), "a narrowing cast keeps the low bits");
    assert(unary_is(T_CAST, 200, 32, false, 8, true, -56), "a cast to a signed type reads the top bit as the sign");
    assert(binary_free(T_SHL, 1, 40, 32, false), "a count past the width is not defined");
    assert(binary_free(T_DIV, 5, 0, 32, false), "a division by zero is not defined");
    assert(binary_free(T_DIV, -2147483648, -1, 32, true), "a quotient outside its type is not defined");
    // A product of unknowns is exact: `x * y` of two `u32` passes 2^32.
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let y = tm.var(32, false);
    let p = tm.arith(T_MUL, x, y, 32, false);
    let big = tm.int(wide::<B>(4294967296), 32, false);
    let lt = tm.cmp(T_LT, big, p);
    let mut ls = Vector::<u64>::new();
    ls.push(tlit(lt, SEL_ATOM, true));
    assert_eq(bits_answer(&tm, &ls), 0);
}

@test
fn bit_lemmas_and_the_case_split() {
    let mut tm = Terms::<B>::new();
    let x = tm.var(32, false);
    let y = tm.var(32, false);
    let xy = tm.arith(T_BXOR, x, y, 32, false);
    let back = tm.arith(T_BXOR, xy, y, 32, false);
    let goal = tm.cmp(T_EQ, back, x);
    let none = Vector::<u32>::new();
    let mut kn = Kernel::<B>::new();
    let mut s = Sat::new();
    kn.begin();
    assert(kn.seal(&tm, &none, goal), "the skeleton of `not (x ^ y ^ y == x)`");
    assert_eq(s.solve(kn.skeleton(), 1000), SAT_MODEL);
    // Each order of the disequality is a lemma by its bits; then the split covers every case.
    let sels: [u64; 2] = [SEL_LT, SEL_GT];
    for j in 0..2 {
        let mut ls = Vector::<u64>::new();
        ls.push(tlit(goal, sels[j], true));
        assert(kn.blast(&tm, &ls), "the bits of one order");
        assert_eq(s.solve(&kn.bits().cnf, 4000000), SAT_REFUTED);
        if j == 0 {
            let n = s.proof.len();
            let mut cut = s.proof.clone();
            cut.truncate(n - 1);
            assert(!kn.blast_lemma(&cut), "a bit lemma whose proof lost a hint");
        }
        assert(kn.blast_lemma(&s.proof), "a bit lemma");
    }
    assert(kn.seal(&tm, &none, goal), "the skeleton and both lemmas");
    assert_eq(s.solve(kn.skeleton(), 1000), SAT_REFUTED);
    let p = s.proof.clone();
    assert(kn.covered(&p), "the lemmas cover the skeleton");
    // A proof of another CNF does not cover this one.
    let c = all_four();
    assert_eq(s.solve(&c, 1000), SAT_REFUTED);
    let q = s.proof.clone();
    assert(!kn.covered(&q), "the proof of another CNF");
    // A theory lemma: `a < b` and `not (a <= b)` sum to `2 <= 0`.
    let a = tm.var(32, true);
    let b = tm.var(32, true);
    let lt = tm.cmp(T_LT, a, b);
    let le = tm.cmp(T_LE, a, b);
    let mut hyps = Vector::<u32>::new();
    hyps.push(lt);
    kn.begin();
    let mut ls = Vector::<u64>::new();
    ls.push(tlit(lt, SEL_ATOM, true));
    ls.push(tlit(le, SEL_ATOM, false));
    let mut pf = Proof::<B>::new();
    pf.mults.push(Mult::<B> { m: Num::<B>::one(), r: RowRef { i: 0, kind: RW_IN } });
    pf.mults.push(Mult::<B> { m: Num::<B>::one(), r: RowRef { i: 1, kind: RW_IN } });
    pf.nodes.push(
        TreeNode::<B> { v: Num::<B>::zero(), atom: NONE, left: NONE, right: NONE, ms: 0, mn: 2, kind: N_LEAF },
    );
    pf.trees.push(Tree { root: 0, ha: NONE, hb: NONE, upto: 0 });
    pf.end = X_LA;
    pf.p = 0;
    let mut half = Vector::<u64>::new();
    half.push(ls[0]);
    let hb = kn.state(&tm, &half).unwrap();
    assert(!kn.lemma(&tm, hb, &pf), "a lemma whose proof names a row its literals do not state");
    assert(kn.seal(&tm, &hyps, le), "the skeleton of `a < b` and `not (a <= b)`");
    assert_eq(s.solve(kn.skeleton(), 1000), SAT_MODEL);
    let lb = kn.state(&tm, &ls).unwrap();
    assert(kn.lemma(&tm, lb, &pf), "a theory lemma");
    assert(kn.seal(&tm, &hyps, le), "the skeleton and the lemma");
    assert_eq(s.solve(kn.skeleton(), 1000), SAT_REFUTED);
    let r = s.proof.clone();
    assert(kn.covered(&r), "the theory lemma covers the skeleton");
}
