// The SAT refutations of the contract prover: the solver (src/prove/sat.spc) and its LRAT proofs, the
// checker (`Lrat`, src/prove/kernel.spc) that accepts each valid proof and rejects it with one part
// changed, the bits of terms (src/prove/blast.spc) against values computed by hand, and the kernel's
// lemmas and case-split check.
import ast::ast as *;
import prove::terms as *;
import prove::blast as *;
import prove::sat as *;
import prove::kernel as *;
import prove::solver as sv0;

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

// ---- floats: the circuits against the host's IEEE 754 arithmetic --------------------------------

// Zeros, the least and greatest subnormals, the least normal, values near 1, halves of rounding cases,
// the greatest finite value, infinities and NaNs.
const F32_EDGES: [u32; 22] = [
    0,
    0x80000000,
    1,
    0x80000001,
    0x007FFFFF,
    0x00800000,
    0x3F800000,
    0xBF800000,
    0x3F800001,
    0x3FFFFFFF,
    0x40000000,
    0x40400000,
    0x3F000000,
    0x4B800000,
    0x4B800001,
    0xCB7FFFFF,
    0x7F7FFFFF,
    0xFF7FFFFF,
    0x7F800000,
    0xFF800000,
    0x7FC00000,
    0x33800000,
];
const F64_EDGES: [u64; 18] = [
    0,
    0x8000000000000000,
    1,
    0x000FFFFFFFFFFFFF,
    0x0010000000000000,
    0x3FF0000000000000,
    0xBFF0000000000000,
    0x3FF0000000000001,
    0x4000000000000000,
    0x3FE0000000000000,
    0x4340000000000001,
    0x7FEFFFFFFFFFFFFF,
    0xFFEFFFFFFFFFFFFF,
    0x7FF0000000000000,
    0xFFF0000000000000,
    0x7FF8000000000000,
    0x3CA0000000000000,
    0x47EFFFFFE0000000,
];

struct Rng {
    s: u64,
}

extend Rng {
    const fn next(self: &mut Rng) u64 {
        self.s = self.s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        return self.s ^ self.s >> 29;
    }
}

const fn fmask(w: u16) (u64, u64) {
    return if w == 32 {
        (0x7F800000u64, 0x007FFFFFu64)
    } else {
        (0x7FF0000000000000u64, 0x000FFFFFFFFFFFFFu64)
    };
}

const fn is_nan_bits(v: u64, w: u16) bool {
    let (e, f) = fmask(w);
    return (v & e) == e && (v & f) != 0;
}

// Whether the bits give term `t` (an integer of type (w, sg), or a float of width w when `fl`) the value
// `v` (two's complement), or any NaN where `v` is a float's NaN: the bits refute every other value.
fn bits_give(tm: &mut Terms<B>, t: u32, w: u16, sg: bool, fl: bool, v: u64) bool {
    let e = if fl && is_nan_bits(v, w) {
        let (em, fm) = fmask(w);
        let ek = tm.int(u64_val::<B>(em), w, false);
        let fk = tm.int(u64_val::<B>(fm), w, false);
        let z = tm.int(Num::<B>::zero(), w, false);
        let te = tm.arith(T_BAND, t, ek, w, false);
        let tf = tm.arith(T_BAND, t, fk, w, false);
        let c1 = tm.cmp(T_EQ, te, ek);
        let c2 = tm.cmp(T_NE, tf, z);
        tm.and(c1, c2)
    } else {
        let k = if sg {
            wide::<B>(v as i64)
        } else {
            u64_val::<B>(v)
        };
        let c = tm.int(k, w, sg);
        tm.cmp(T_EQ, t, c)
    };
    let mut ls = Vector::<u64>::new();
    ls.push(tlit(e, SEL_ATOM, false));
    let mut yes = Vector::<u64>::new();
    yes.push(tlit(e, SEL_ATOM, true));
    return bits_answer(tm, &ls) == 1 && bits_answer(tm, &yes) == 0;
}

// Operation `op` of floats of width `w` over constant encodings `xs`, made past the folding so the
// circuit computes it; into integer type (`rw`, `rsg`) for T_FTOI, width `rw` for T_FCVT.
fn fterm(tm: &mut Terms<B>, op: u8, w: u16, xs: []u64, rw: u16, rsg: bool) u32 {
    let mut ks = Vector::<u32>::new();
    for j in 0..xs.len() {
        ks.push(tm.int(u64_val::<B>(xs[j]), w, false));
    }
    let fd = hfd(w);
    if op == T_FFMA {
        let a = tm.args.len() as u32;
        tm.args.extend_copy(&ks);
        return tm.make(Term::<B> { k: u64_val::<B>(fd), a: a, b: 3, op: op, w: w, sg: false });
    }
    if op == T_FTOI {
        return tm.make(Term::<B> { k: u64_val::<B>(fd), a: ks[0], b: 0, op: op, w: rw, sg: rsg });
    }
    if op == T_FCVT {
        return tm.make(Term::<B> { k: u64_val::<B>(hfd(rw) | fd << 32), a: ks[0], b: 0, op: op, w: rw, sg: rsg });
    }
    if op == T_FSQRT {
        return tm.make(Term::<B> { k: u64_val::<B>(fd), a: ks[0], b: 0, op: op, w: w, sg: false });
    }
    return tm.make(Term::<B> { k: u64_val::<B>(fd), a: ks[0], b: ks[1], op: op, w: w, sg: false });
}

// The format code of the built-in float of width `w`.
const fn hfd(w: u16) u64 {
    return pick(w == 32, FD32, FD64);
}

// The host's result of `op` over encodings `xs` of width `w`.
const fn host(op: u8, w: u16, xs: []u64) u64 {
    if w == 32 {
        let x = f32::from_bits(xs[0] as u32);
        let y = f32::from_bits(xs[pick(xs.len() > 1, 1usize, 0)] as u32);
        let z = f32::from_bits(xs[pick(xs.len() > 2, 2usize, 0)] as u32);
        let r = if op == T_FADD {
            x + y
        } else if op == T_FMUL {
            x * y
        } else if op == T_FDIV {
            x / y
        } else if op == T_FSQRT {
            x.sqrt()
        } else if op == T_FREM {
            x % y
        } else {
            x.mul_add(y, z)
        };
        return r.to_bits();
    }
    let x = f64::from_bits(xs[0]);
    let y = f64::from_bits(xs[pick(xs.len() > 1, 1usize, 0)]);
    let z = f64::from_bits(xs[pick(xs.len() > 2, 2usize, 0)]);
    let r = if op == T_FADD {
        x + y
    } else if op == T_FMUL {
        x * y
    } else if op == T_FDIV {
        x / y
    } else if op == T_FSQRT {
        x.sqrt()
    } else if op == T_FREM {
        x % y
    } else {
        x.mul_add(y, z)
    };
    return r.to_bits();
}

// Operation `op` of width `w` over `xs` gives the host's result; a failure names the operands.
fn check_op(op: u8, w: u16, xs: []u64) {
    let mut tm = Terms::<B>::new();
    let t = fterm(&mut tm, op, w, xs, w, false);
    let v = host(op, w, xs);
    if !bits_give(&mut tm, t, w, false, true, v) {
        let mut msg = format("float op {} of width {} over", op, w);
        for j in 0..xs.len() {
            msg.format_into(" {:x}", xs[j]);
        }
        msg.format_into(": host {:x}", v);
        assert(false, msg.as_str());
    }
}

// A value of width `w`: an edge, or random bits, or near `a` (same exponent, so sums cancel).
const fn pick_value(r: &mut Rng, w: u16, a: u64) u64 {
    let x = r.next();
    let k = x % 4;
    if k == 0 {
        return if w == 32 {
            F32_EDGES[(x >> 8) as usize % 22usize]
        } else {
            F64_EDGES[(x >> 8) as usize % 18usize]
        };
    }
    let (em, fm) = fmask(w);
    if k == 1 {
        return a ^ fsign(w) ^ x >> 20 & fm >> 6;
    }
    // Random bits; or (k 3) an exponent within that of 1 and its neighbors', whose sums keep their bits.
    let v = r.next() & pick(w == 32, 0xFFFFFFFFu64, u64::MAX);
    let near = pick(w == 32, 0x3F800000u64, 0x3FF0000000000000u64);
    return pick(k == 2, v, v & ~em | near);
}

// Edge value `i` of width `w`.
const fn edge(w: u16, i: usize) u64 {
    return if w == 32 {
        F32_EDGES[i]
    } else {
        F64_EDGES[i]
    };
}

// `f` rounded to an integral value, halves to even.
const fn round_even(f: f64) f64 {
    let r = f.round();
    return pick((f - f.trunc()).abs() == 0.5, 2.0 * (f / 2.0).round(), r);
}

@test
fn float_circuits_match_the_host() {
    for wi in 0..2 {
        let w: u16 = pick(wi == 0, 32u16, 64u16);
        let n = pick(w == 32, 22usize, 18usize);
        for i in 0..n {
            check_op(T_FSQRT, w, [edge(w, i)]);
            for j in 0..n {
                if w == 32 {
                    check_op(T_FREM, w, [edge(w, i), edge(w, j)]);
                }
                check_op(T_FADD, w, [edge(w, i), edge(w, j)]);
                check_op(T_FMUL, w, [edge(w, i), edge(w, j)]);
                check_op(T_FDIV, w, [edge(w, i), edge(w, j)]);
            }
        }
        let mut r = Rng { s: 0x5EED + w as u64 };
        for _k in 0..pick(w == 32, 300, 120) {
            let a = pick_value(&mut r, w, 0);
            let b = pick_value(&mut r, w, a);
            let c = pick_value(&mut r, w, a);
            check_op(T_FADD, w, [a, b]);
            check_op(T_FMUL, w, [a, b]);
            check_op(T_FDIV, w, [a, b]);
            check_op(T_FSQRT, w, [a]);
            if w == 32 {
                check_op(T_FREM, w, [a, b]);
            }
            check_op(T_FFMA, w, [a, b, c]);
            check_op(T_FFMA, w, [a, c, b]);
        }
    }
}

// Float `x` of width `w` as integer type (`tw`, `tsg`) by the host's `as`, two's complement.
const fn host_ftoi(w: u16, x0: u64, tw: u16, tsg: bool) u64 {
    let x = pick(w == 32, f32::from_bits(x0 as u32), f64::from_bits(x0));
    return if tw == 8 && !tsg {
        x as u8
    } else if tw == 16 {
        (x as i16) as u64
    } else if tw == 32 {
        (x as i32) as u64
    } else if tsg {
        (x as i64) as u64
    } else {
        x as u64
    };
}

// Integer `v` of type (`iw`, `isg`) as a float of width `w` by the host's `as`.
const fn host_itof(v: u64, iw: u16, isg: bool, w: u16) u64 {
    let s = if iw == 32 && isg {
        (v as i32) as i64
    } else {
        v as i64
    };
    if w == 32 {
        return pick(isg, s as f32, v as f32).to_bits();
    }
    return pick(isg, s as f64, v as f64).to_bits();
}

const fn host_cmp(op: u8, w: u16, a: u64, b: u64) bool {
    let (x, y) = if w == 32 {
        (f32::from_bits(a as u32) as f64, f32::from_bits(b as u32) as f64)
    } else {
        (f64::from_bits(a), f64::from_bits(b))
    };
    return if op == T_FLT {
        x < y
    } else if op == T_FLE {
        x <= y
    } else {
        x == y
    };
}

@test
fn float_conversions_and_comparisons_match_the_host() {
    let tws: [u16; 5] = [8, 16, 32, 64, 64];
    let tsgs: [bool; 5] = [false, true, true, true, false];
    let mut r = Rng { s: 0xF10A7 };
    for wi in 0..2 {
        let w: u16 = pick(wi == 0, 32u16, 64u16);
        let n = pick(w == 32, 22usize, 18usize);
        for k in 0..n + 60 {
            let a = if k < n {
                edge(w, k)
            } else {
                pick_value(&mut r, w, 0)
            };
            for j in 0..5 {
                let mut tm = Terms::<B>::new();
                let t = fterm(&mut tm, T_FTOI, w, [a], tws[j], tsgs[j]);
                let v = host_ftoi(w, a, tws[j], tsgs[j]);
                if !bits_give(&mut tm, t, tws[j], tsgs[j], false, v) {
                    assert(false, format("{:x} of width {} as ({}, {}): host {:x}", a, w, tws[j], tsgs[j], v).as_str());
                }
            }
            let mut tm = Terms::<B>::new();
            let ow: u16 = 96 - w;
            let t = fterm(&mut tm, T_FCVT, w, [a], ow, false);
            let v: u64 = if w == 32 {
                (f32::from_bits(a as u32) as f64).to_bits()
            } else {
                (f64::from_bits(a) as f32).to_bits()
            };
            if !bits_give(&mut tm, t, ow, false, true, v) {
                assert(false, format("{:x} of width {} converted: host {:x}", a, w, v).as_str());
            }
            for j in 0..n {
                let b = edge(w, j);
                for op in T_FLT..T_FEQ + 1 {
                    let mut tc = Terms::<B>::new();
                    let x = tc.int(u64_val::<B>(a), w, false);
                    let y = tc.int(u64_val::<B>(b), w, false);
                    let c = tc.make(Term::<B> { k: u64_val::<B>(hfd(w)), a: x, b: y, op: op, w: W_BOOL, sg: false });
                    let mut ls = Vector::<u64>::new();
                    ls.push(tlit(c, SEL_ATOM, !host_cmp(op, w, a, b)));
                    if bits_answer(&tc, &ls) != 1 {
                        assert(false, format("comparison {} of {:x} and {:x} of width {}", op, a, b, w).as_str());
                    }
                }
            }
            // Rounding to integral values, by each mode.
            for md in 0..5u16 {
                let mut tr = Terms::<B>::new();
                let x = tr.int(u64_val::<B>(a), w, false);
                let t = tr.make(
                    Term::<B> { k: u64_val::<B>(hfd(w) | md as u64 << 32), a: x, b: 0, op: T_FRINT, w: w, sg: false },
                );
                let f = pick(w == 32, f32::from_bits(a as u32), f64::from_bits(a));
                let g = if md == FR_ROUND {
                    f.round()
                } else if md == FR_FLOOR {
                    f.floor()
                } else if md == FR_CEIL {
                    f.ceil()
                } else if md == FR_TRUNC {
                    f.trunc()
                } else {
                    round_even(f)
                };
                let hv: u64 = pick(w == 32, (g as f32).to_bits(), g.to_bits());
                if !bits_give(&mut tr, t, w, false, true, hv) {
                    assert(false, format("{:x} of width {} rounded by mode {}: host {:x}", a, w, md, hv).as_str());
                }
            }
        }
        // Halves and values near them, which each mode rounds its own way.
        for k in 0..64 {
            let v = (k as f64 - 32.0) * 0.25 + pick(k % 5 == 0, 1e-9, 0.0);
            for md in 0..5u16 {
                let a = pick(w == 32, (v as f32).to_bits(), v.to_bits());
                let mut tr = Terms::<B>::new();
                let x = tr.int(u64_val::<B>(a), w, false);
                let t = tr.make(
                    Term::<B> { k: u64_val::<B>(hfd(w) | md as u64 << 32), a: x, b: 0, op: T_FRINT, w: w, sg: false },
                );
                let f = pick(w == 32, f32::from_bits(a as u32), f64::from_bits(a));
                let g = if md == FR_ROUND {
                    f.round()
                } else if md == FR_FLOOR {
                    f.floor()
                } else if md == FR_CEIL {
                    f.ceil()
                } else if md == FR_TRUNC {
                    f.trunc()
                } else {
                    round_even(f)
                };
                let hv: u64 = pick(w == 32, (g as f32).to_bits(), g.to_bits());
                if !bits_give(&mut tr, t, w, false, true, hv) {
                    assert(false, format("{} of width {} rounded by mode {}: host {:x}", v, w, md, hv).as_str());
                }
            }
        }
        // Integers into floats: i32, i64 and u64 values, small, rounded and at the ends.
        for k in 0..80 {
            let v0 = r.next();
            let v = pick(k % 3 == 0, v0 >> (v0 & 63), pick(k % 3 == 1, v0 | 0x8000000000000000u64, v0));
            let iws: [u16; 3] = [32, 64, 64];
            let isgs: [bool; 3] = [true, true, false];
            for j in 0..3 {
                let x = pick(iws[j] == 32, v & 0xFFFFFFFF, v);
                let mut tm = Terms::<B>::new();
                let kx = if isgs[j] {
                    wide::<B>(pick(iws[j] == 32, (x as u32) as i32, x as i64))
                } else {
                    u64_val::<B>(x)
                };
                let it = tm.int(kx, iws[j], isgs[j]);
                let t = tm.make(Term::<B> { k: u64_val::<B>(hfd(w)), a: it, b: 0, op: T_ITOF, w: w, sg: false });
                let hv = host_itof(x, iws[j], isgs[j], w);
                if !bits_give(&mut tm, t, w, false, true, hv) {
                    assert(false, format("{:x} of ({}, {}) as width {}: host {:x}", x, iws[j], isgs[j], w, hv).as_str());
                }
            }
        }
    }
}

// The circuits over unknown operands (their clauses, not their folding): each operand an unknown equal
// to a value.
@test
fn float_circuits_over_unknowns() {
    let cases: [(u8, u16, u64, u64, u64); 9] = [
        (T_FADD, 32, 0x3F800001, 0xBF800000, 0),
        (T_FADD, 32, 0x00000003, 0x80000001, 0),
        (T_FMUL, 32, 0x3FC00000, 0x7F000000, 0),
        (T_FMUL, 32, 0x00800001, 0x3F000000, 0),
        (T_FDIV, 32, 0x3F800000, 0x40400000, 0),
        (T_FSQRT, 32, 0x40000000, 0, 0),
        (T_FFMA, 32, 0x3F800001, 0x3F7FFFFF, 0xBF800000),
        (T_FADD, 64, 0x3FF0000000000001, 0xBFF0000000000000, 0),
        (T_FDIV, 64, 0x3FF0000000000000, 0x4008000000000000, 0),
    ];
    for i in 0..9 {
        let (op, w, a, b, c) = cases[i];
        let xs: [u64; 3] = [a, b, c];
        let mut tm = Terms::<B>::new();
        let mut ls = Vector::<u64>::new();
        let mut vs = Vector::<u32>::new();
        let n = pick(op == T_FSQRT, 1usize, pick(op == T_FFMA, 3usize, 2usize));
        for j in 0..n {
            let x = tm.var(w, false);
            let k = tm.int(u64_val::<B>(xs[j]), w, false);
            let e = tm.cmp(T_EQ, x, k);
            ls.push(tlit(e, SEL_ATOM, true));
            vs.push(x);
        }
        let t = if op == T_FFMA {
            tm.ffma(&vs, w, hfd(w))
        } else if op == T_FSQRT {
            tm.fconv(T_FSQRT, vs[0], w, false, hfd(w))
        } else {
            tm.farith(op, vs[0], vs[1], w, hfd(w))
        };
        let v = host(op, w, [a, b, c]);
        let k = tm.int(u64_val::<B>(v), w, false);
        let e = tm.cmp(T_EQ, t, k);
        ls.push(tlit(e, SEL_ATOM, false));
        assert_eq(bits_answer(&tm, &ls), 1);
        // And the value has a model: the hypotheses do not contradict.
        let _ = ls.pop();
        ls.push(tlit(e, SEL_ATOM, true));
        assert_eq(bits_answer(&tm, &ls), 0);
    }
}

// ---- `Float<E, F, FAMILY>` against std's implementation ------------------------------------------------

// The format code of `Float<E, F, FAMILY>`.
const fn soft_fd(f: usize, fo: bool) u64 {
    return f as u64 | pick(fo, FD_FINITE, 0u64);
}

// Whether encoding `v` of width `w`, format `fd`, is a NaN.
const fn soft_nan(v: u64, w: u16, fd: u64) bool {
    let m = fd & 0xFFFF;
    let mg = (1u64 << (w - 1) as u64) - 1;
    let ef = mg >> m << m;
    let a = v & mg;
    return pick((fd & FD_FINITE) != 0, a == mg, (a & ef) == ef && (a & ~ef) != 0);
}

// Whether the bits give float term `t` (width `w`, format `fd`) the encoding `v`, or any NaN for a NaN `v`:
// they refute every other value, and the facts of the operations (`Blaster::float_lemmas`) leave it.
fn soft_give(tm: &mut Terms<B>, t: u32, w: u16, fd: u64, v: u64) bool {
    let e = soft_is(tm, t, w, fd, v);
    let mut ls = Vector::<u64>::new();
    ls.push(tlit(e, SEL_ATOM, false));
    let mut yes = Vector::<u64>::new();
    yes.push(tlit(e, SEL_ATOM, true));
    return bits_answer(tm, &ls) == 1 && bits_answer(tm, &yes) == 0;
}

// The formula that float term `t` (width `w`, format `fd`) is `v`, or a NaN for a NaN `v`.
fn soft_is(tm: &mut Terms<B>, t: u32, w: u16, fd: u64, v: u64) u32 {
    let e = if soft_nan(v, w, fd) {
        let m = fd & 0xFFFF;
        let mg = (1u64 << (w - 1) as u64) - 1;
        let ef = mg >> m << m;
        let mk = tm.int(u64_val::<B>(mg), w, false);
        let a = tm.arith(T_BAND, t, mk, w, false);
        if (fd & FD_FINITE) != 0 {
            tm.cmp(T_EQ, a, mk)
        } else {
            let ek = tm.int(u64_val::<B>(ef), w, false);
            tm.cmp(T_LT, ek, a)
        }
    } else {
        let c = tm.int(u64_val::<B>(v), w, false);
        tm.cmp(T_EQ, t, c)
    };
    return e;
}

// Float operation `op` of format (`w`, `fd`) over constant encodings `xs`, past the folding; `md` the
// rounding mode of T_FRINT.
fn soft_term(tm: &mut Terms<B>, op: u8, w: u16, fd: u64, xs: []u64, md: u16) u32 {
    let mut ks = Vector::<u32>::new();
    for j in 0..xs.len() {
        ks.push(tm.int(u64_val::<B>(xs[j]), w, false));
    }
    let k = u64_val::<B>(fd | pick(op == T_FRINT, md as u64 << 32, 0u64));
    if op == T_FFMA {
        let a = tm.args.len() as u32;
        tm.args.extend_copy(&ks);
        return tm.make(Term::<B> { k: k, a: a, b: 3, op: op, w: w, sg: false });
    }
    return tm.make(
        Term::<B> {
            k: k,
            a: ks[0],
            b: pick(xs.len() > 1, ks[pick(xs.len() > 1, 1usize, 0)], 0u32),
            op: op,
            w: pick(op >= T_FLT && op <= T_FEQ, W_BOOL, w),
            sg: false,
        },
    );
}

// std's `Float<E, F, FAMILY>` of encoding `v`.
const fn sf<const E: usize, const F: usize, const FAM: FloatFamily>(v: u64) Float<E, F, FAM> {
    return Float::<E, F, FAM>::from_raw(UInt::<{1 + E + F}>::from_u64(v));
}

// std's result of float operation `op` (mode `md` for T_FRINT) over encodings `xs`: its encoding, or (a
// comparison) 0 or 1.
fn soft_host<const E: usize, const F: usize, const FAM: FloatFamily>(op: u8, xs: []u64, md: u16) u64 {
    let x = sf::<E, F, FAM>(xs[0]);
    let y = sf::<E, F, FAM>(xs[pick(xs.len() > 1, 1usize, 0)]);
    let z = sf::<E, F, FAM>(xs[pick(xs.len() > 2, 2usize, 0)]);
    if op == T_FLT || op == T_FLE || op == T_FEQ {
        return pick(op == T_FLT, x.ieee_lt(&y), pick(op == T_FLE, x.ieee_le(&y), x.ieee_eq(&y))) as u64;
    }
    let r = if op == T_FADD {
        x.add(&y)
    } else if op == T_FMUL {
        x.mul(&y)
    } else if op == T_FDIV {
        x.div(&y)
    } else if op == T_FREM {
        x.rem(&y)
    } else if op == T_FSQRT {
        x.sqrt()
    } else if op == T_FFMA {
        x.fma(&y, &z)
    } else if md == FR_TRUNC {
        x.trunc()
    } else if md == FR_FLOOR {
        x.floor()
    } else if md == FR_CEIL {
        x.ceil()
    } else if md == FR_ROUND {
        x.round()
    } else {
        x.round_ties_even()
    };
    return r.to_raw().to_u64();
}

// The circuit of `op` over `xs` gives std's result; a failure names the format, the operation and the
// operands.
fn soft_case<const E: usize, const F: usize, const FAM: FloatFamily>(fo: bool, op: u8, xs: []u64, md: u16) {
    let w = (1 + E + F) as u16;
    let fd = soft_fd(F, fo);
    let mut tm = Terms::<B>::new();
    let t = soft_term(&mut tm, op, w, fd, xs, md);
    let v = soft_host::<E, F, FAM>(op, xs, md);
    let ok = if op >= T_FLT && op <= T_FEQ {
        let mut ls = Vector::<u64>::new();
        ls.push(tlit(t, SEL_ATOM, v == 0));
        bits_answer(&tm, &ls) == 1
    } else {
        soft_give(&mut tm, t, w, fd, v)
    };
    if !ok {
        let mut msg = format("Float<{}, {}> (finite only {}) op {} mode {} over", E, F, fo, op, md);
        for j in 0..xs.len() {
            msg.format_into(" {:x}", xs[j]);
        }
        msg.format_into(": std {:x}", v);
        assert(false, msg.as_str());
    }
}

// Each operation of `Float<E, F, FAM>`: every operand where `all` (pairs of every two values), else
// `n` random ones besides every unary case.
fn soft_ops<const E: usize, const F: usize, const FAM: FloatFamily>(fo: bool, all: bool, n: usize, seed: u64) {
    let w = 1 + E + F;
    let mask = pick(w == 64, u64::MAX, (1u64 << w as u64) - 1);
    let mut r = Rng { s: seed };
    let unary = pick(w <= 10, 1usize << w, n);
    for i in 0..unary {
        let a = pick(w <= 10, i as u64, r.next() & mask);
        soft_case::<E, F, FAM>(fo, T_FSQRT, [a], 0);
        for md in 0..5u16 {
            soft_case::<E, F, FAM>(fo, T_FRINT, [a], md);
        }
    }
    let pairs = pick(all, 1usize << 2 * w, n);
    let ops: [u8; 8] = [T_FADD, T_FMUL, T_FDIV, T_FREM, T_FLT, T_FLE, T_FEQ, T_FFMA];
    for i in 0..pairs {
        let (a, b) = if all {
            ((i >> w) as u64, i as u64 & mask)
        } else {
            (r.next() & mask, r.next() & mask)
        };
        let c = r.next() & mask;
        for j in 0..8 {
            soft_case::<E, F, FAM>(fo, ops[j], [a, b, c], 0);
        }
    }
}

@test
fn soft_float_circuits_match_std() {
    soft_ops::<3, 2, IEEE>(false, true, 0, 2);
    soft_ops::<2, 3, IEEE>(false, false, 600, 1);
    soft_ops::<4, 3, FINITE_ONLY>(true, false, 1200, 3);
    soft_ops::<4, 3, IEEE>(false, false, 500, 4);
    soft_ops::<5, 2, IEEE>(false, false, 500, 5);
    soft_ops::<5, 10, IEEE>(false, false, 300, 6);
    soft_ops::<8, 7, IEEE>(false, false, 300, 7);
}

// `Float<E, F, FAM>` encoding `a` converted to `Float<E2, F2, FAM2>` (std's `convert`), to and from `f32`,
// and from the 16-bit integer of its low bits, against the circuits.
fn soft_cvt<
    const E: usize,
    const F: usize,
    const FAM: FloatFamily,
    const E2: usize,
    const F2: usize,
    const FAM2: FloatFamily
>(fo: bool, fo2: bool, a: u64) {
    let w = (1 + E + F) as u16;
    let w2 = (1 + E2 + F2) as u16;
    let fd = soft_fd(F, fo);
    let fd2 = soft_fd(F2, fo2);
    let x = sf::<E, F, FAM>(a);
    let v = a | a << 16 | a << 32;
    let fv = f32::from_bits(v as u32);
    let iv = ((v as u16) as i16) as i64;
    let ix = Int::<16>::from_i64(iv);
    let cases: [(u8, u16, u64, u16, u64, u64, u64, bool); 4] = [
        (T_FCVT, w, fd, w2, fd2, a, Float::<E2, F2, FAM2>::convert(&x).to_raw().to_u64(), false),
        (T_FCVT, w, fd, 32, FD32, a, f32_bits(x.to_f32()) as u64, false),
        (T_FCVT, 32, FD32, w, fd, v & 0xFFFFFFFF, Float::<E, F, FAM>::from_f32(fv).to_raw().to_u64(), false),
        (T_ITOF, 16, 0, w, fd, iv as u64, Float::<E, F, FAM>::from_int(&ix).to_raw().to_u64(), true),
    ];
    for i in 0..4 {
        let (op, sw, sfd, rw, rfd, src, want, int) = cases[i];
        let mut tm = Terms::<B>::new();
        let s = if int {
            tm.int(wide::<B>(src as i64), sw, true)
        } else {
            tm.int(u64_val::<B>(src), sw, false)
        };
        let k = pick(op == T_FCVT, rfd | sfd << 32, rfd);
        let t = tm.make(Term::<B> { k: u64_val::<B>(k), a: s, b: 0, op: op, w: rw, sg: false });
        if !soft_give(&mut tm, t, rw, rfd, want) {
            assert(
                false,
                format("Float<{}, {}> ({}) case {} of {:x} into width {}: std {:x}", E, F, fo, i, src, rw, want).as_str(),
            );
        }
    }
}

// Each encoding of a format of up to 10 bits, else `n` random ones, converted to another format.
fn soft_cvts<
    const E: usize,
    const F: usize,
    const FAM: FloatFamily,
    const E2: usize,
    const F2: usize,
    const FAM2: FloatFamily
>(fo: bool, fo2: bool, n: usize, seed: u64) {
    let w = 1 + E + F;
    let mut r = Rng { s: seed };
    let m = pick(w <= 10, 1usize << w, n);
    for i in 0..m {
        let a = pick(w <= 10, i as u64, r.next() & (1u64 << w as u64) - 1);
        soft_cvt::<E, F, FAM, E2, F2, FAM2>(fo, fo2, a);
    }
}

@test
fn soft_float_conversions_match_std() {
    soft_cvts::<2, 3, IEEE, 3, 4, IEEE>(false, false, 0, 1);
    soft_cvts::<3, 4, IEEE, 2, 3, IEEE>(false, false, 0, 2);
    soft_cvts::<4, 3, FINITE_ONLY, 5, 2, IEEE>(true, false, 0, 3);
    soft_cvts::<5, 2, IEEE, 4, 3, FINITE_ONLY>(false, true, 0, 4);
    soft_cvts::<4, 3, IEEE, 4, 3, FINITE_ONLY>(false, true, 0, 5);
    soft_cvts::<5, 10, IEEE, 8, 7, IEEE>(false, false, 1500, 6);
    soft_cvts::<8, 7, IEEE, 5, 10, IEEE>(false, false, 1500, 7);
}

// Two operations `op` of `Float<E, F, FAM>` (mode `md` for T_FRINT, T_FKEY the total order key) over
// encodings `xs` and `ys` in one encoding, each its std value: the facts of a pair
// (`Blaster::pair_lemmas`) leave the true values.
fn soft_pair<const E: usize, const F: usize, const FAM: FloatFamily>(fo: bool, op: u8, md: u16, xs: []u64, ys: []u64) {
    let w = (1 + E + F) as u16;
    let fd = soft_fd(F, fo);
    let mut tm = Terms::<B>::new();
    let mut ls = Vector::<u64>::new();
    for (vs, j) in [(xs, 0u32), (ys, 1u32)] {
        let (t, rw, v) = if op == T_FKEY {
            let k = tm.int(u64_val::<B>(vs[0]), w, false);
            let t = tm.make(Term::<B> { k: u64_val::<B>(fd), a: k, b: 0, op: op, w: w, sg: false });
            (t, w, Terms::<B>::key_of(u64_val::<B>(vs[0]), w).limb(0))
        } else {
            (soft_term(&mut tm, op, w, fd, vs, md), w, soft_host::<E, F, FAM>(op, vs, md))
        };
        let e = if op == T_FKEY {
            let c = tm.int(u64_val::<B>(v), rw, false);
            tm.cmp(T_EQ, t, c)
        } else {
            soft_is(&mut tm, t, rw, fd, v)
        };
        ls.push(tlit(e, SEL_ATOM, true));
        let _ = j;
    }
    if bits_answer(&tm, &ls) != 0 {
        assert(
            false,
            format(
                "Float<{}, {}> ({}) pair of op {} mode {} over {:x} {:x} and {:x} {:x}",
                E,
                F,
                fo,
                op,
                md,
                xs[0],
                xs[1],
                ys[0],
                ys[1],
            ).as_str(),
        );
    }
}

// `n` random pairs of each operation, a shared operand in half of them.
fn soft_pairs<const E: usize, const F: usize, const FAM: FloatFamily>(fo: bool, n: usize, seed: u64) {
    let w = 1 + E + F;
    let mask = (1u64 << w as u64) - 1;
    let mut r = Rng { s: seed };
    let ops: [u8; 6] = [T_FADD, T_FMUL, T_FDIV, T_FSQRT, T_FRINT, T_FKEY];
    for _i in 0..n {
        let a = r.next() & mask;
        let b = r.next() & mask;
        let c = r.next() & mask;
        let d = r.next() & mask;
        let shared = (r.next() & 1) == 0;
        let (c1, d1) = pick(shared, (a, d), (c, d));
        for j in 0..6 {
            let md = pick(ops[j] == T_FRINT, (r.next() % 5) as u16, 0u16);
            soft_pair::<E, F, FAM>(fo, ops[j], md, [a, b], [c1, d1]);
            soft_pair::<E, F, FAM>(fo, ops[j], md, [a, b], [d1, c1]);
        }
    }
}

@test
fn float_facts_keep_the_true_values() {
    soft_pairs::<3, 2, IEEE>(false, 1500, 11);
    soft_pairs::<4, 3, FINITE_ONLY>(true, 800, 12);
    soft_pairs::<5, 10, IEEE>(false, 300, 13);
    soft_pairs::<8, 23, IEEE>(false, 150, 14);
}

// Operands in boxes the encoding compares them with, at a point inside: the bounds the facts give the
// result (`Blaster::box_lemmas`) leave its true value.
fn box_case(w: u16, op: u8, lo: [u64; 2], hi: [u64; 2], pt: [u64; 2]) {
    let fd = hfd(w);
    let mut tm = Terms::<B>::new();
    let mut ls = Vector::<u64>::new();
    let mut vs = Vector::<u32>::new();
    for j in 0..2 {
        let v = tm.var(w, false);
        let l = tm.int(u64_val::<B>(lo[j]), w, false);
        let h = tm.int(u64_val::<B>(hi[j]), w, false);
        let p = tm.int(u64_val::<B>(pt[j]), w, false);
        ls.push(tlit(tm.fcmp(T_FLE, l, v, fd), SEL_ATOM, true));
        ls.push(tlit(tm.fcmp(T_FLE, v, h, fd), SEL_ATOM, true));
        ls.push(tlit(tm.cmp(T_EQ, v, p), SEL_ATOM, true));
        vs.push(v);
    }
    let t = if op == T_FSQRT {
        tm.fconv(T_FSQRT, vs[0], w, false, fd)
    } else if op == T_FADD + 100 {
        let nb = tm.fneg(vs[1], w);
        tm.farith(T_FADD, vs[0], nb, w, fd)
    } else {
        tm.farith(op, vs[0], vs[1], w, fd)
    };
    let v = if op == T_FADD + 100 {
        host(T_FADD, w, [pt[0], pt[1] ^ fsign(w)])
    } else {
        host(op, w, [pt[0], pt[1]])
    };
    let e = soft_is(&mut tm, t, w, fd, v);
    ls.push(tlit(e, SEL_ATOM, true));
    if bits_answer(&tm, &ls) != 0 {
        assert(
            false,
            format(
                "op {} of width {} over [{:x}, {:x}] [{:x}, {:x}] at {:x} {:x}",
                op,
                w,
                lo[0],
                hi[0],
                lo[1],
                hi[1],
                pt[0],
                pt[1],
            ).as_str(),
        );
    }
}

@test
fn float_bounds_keep_the_true_values() {
    let mut r = Rng { s: 0xB0C5 };
    for wi in 0..2 {
        let w: u16 = pick(wi == 0, 32u16, 64u16);
        let ops: [u8; 5] = [T_FADD, T_FMUL, T_FDIV, T_FSQRT, T_FADD + 100];
        for _k in 0..pick(w == 32, 60, 20) {
            // Three values of an operand, sorted: its box and a point inside.
            let mut lo: [u64; 2] = [0, 0];
            let mut hi: [u64; 2] = [0, 0];
            let mut pt: [u64; 2] = [0, 0];
            for j in 0..2 {
                let mut xs: [f64; 3] = [0.0; 3];
                for q in 0..3 {
                    let v = pick_value(&mut r, w, 0);
                    let f = pick(w == 32, f32::from_bits(v as u32), f64::from_bits(v));
                    xs[q] = pick(f.is_nan(), (r.next() % 9) as f64 - 4.0, f);
                }
                for q in 0..2 {
                    for s in 0..2 - q {
                        if xs[s + 1] < xs[s] {
                            let tmp = xs[s];
                            xs[s] = xs[s + 1];
                            xs[s + 1] = tmp;
                        }
                    }
                }
                lo[j] = pick(w == 32, (xs[0] as f32).to_bits(), xs[0].to_bits());
                pt[j] = pick(w == 32, (xs[1] as f32).to_bits(), xs[1].to_bits());
                hi[j] = pick(w == 32, (xs[2] as f32).to_bits(), xs[2].to_bits());
            }
            for i in 0..5 {
                box_case(w, ops[i], lo, hi, pt);
            }
        }
    }
}

// `c` where `ok` holds, else an unknown boolean: `(ok && c) || (!ok && u)`.
fn known_if(tm: &mut Terms<B>, ok: u32, c: u32) u32 {
    let u = tm.var(W_BOOL, false);
    let k = tm.and(ok, c);
    let nok = tm.not(ok);
    let o = tm.and(nok, u);
    return tm.or(k, o);
}

// An `f32` comparison `op` of `a` and `b` that is unknown where one is NaN.
fn ordered(tm: &mut Terms<B>, op: u8, a: u32, b: u32) u32 {
    let fd = hfd(32);
    let c = tm.fcmp(op, a, b, fd);
    let na = tm.fcmp(T_FEQ, a, a, fd);
    let nb = tm.fcmp(T_FEQ, b, b, fd);
    let ok = tm.and(na, nb);
    return known_if(tm, ok, c);
}

// A comparison of a choice splits into comparisons of its values, under an unknown boolean that roots no
// cone: `x / 2` or `x * 0.5` for `x` in [0, 1] is at most 0.5 and not NaN. A boolean cast to an integer
// is 1 where it holds.
@test
fn choices_compare_by_their_values() {
    let mut tm = Terms::<B>::new();
    let fd = hfd(32);
    let x = tm.var(32, false);
    let zero = tm.int(u64_val::<B>(0), 32, false);
    let one = tm.int(u64_val::<B>(0x3F800000), 32, false);
    let half = tm.int(u64_val::<B>(0x3F000000), 32, false);
    let two = tm.int(u64_val::<B>(0x40000000), 32, false);
    let mut hy = Vector::<u32>::new();
    hy.push(tm.fcmp(T_FLE, zero, x, fd));
    hy.push(tm.fcmp(T_FLE, x, one, fd));
    let b = tm.var(W_BOOL, false);
    let e = tm.farith(T_FDIV, x, two, 32, fd);
    let alt = tm.farith(T_FMUL, x, half, 32, fd);
    let r = tm.choose(b, e, alt, 32);
    let le = tm.fcmp(T_FLE, r, half, fd);
    let num = tm.fcmp(T_FEQ, r, r, fd);
    let more = tm.fcmp(T_FLT, half, r, fd);
    for (g, holds) in [(le, true), (num, true), (more, false)] {
        let mut sv = sv0::Solver::<B>::new();
        assert(sv.implies(&tm, &hy, g, true) == holds, "a comparison of a choice");
    }
    let lt = tm.fcmp(T_FLT, x, half, fd);
    let c1 = tm.unary(T_CAST, lt, 32, false);
    let k1 = tm.int(u64_val::<B>(1), 32, false);
    let is1 = tm.cmp(T_EQ, c1, k1);
    let mut ls = Vector::<u64>::new();
    ls.push(tlit(lt, SEL_ATOM, true));
    ls.push(tlit(is1, SEL_ATOM, false));
    assert(bits_answer(&tm, &ls) == 1, "a true boolean as an integer is 1");
    ls.set(0, tlit(lt, SEL_ATOM, false));
    ls.set(1, tlit(is1, SEL_ATOM, true));
    assert(bits_answer(&tm, &ls) == 1, "a false boolean as an integer is 0");
}

// The skeleton may take the side of a hypothesis that the theories refute apart from the goal ("`top` is
// NaN" against `top.is_finite()`): the literals outside the goal's cone refute it, and `r` in (0, top)
// with `top` below 1000 then fits a `u32`.
@test
fn literals_apart_from_the_goal_refute_a_side() {
    let mut tm = Terms::<B>::new();
    let fd = hfd(32);
    let r = tm.var(32, false);
    let top = tm.var(32, false);
    let zero = tm.int(u64_val::<B>(0), 32, false);
    let k1000 = tm.int(u64_val::<B>(0x447A0000), 32, false);
    let inf = tm.int(u64_val::<B>(0x7F800000), 32, false);
    let p32 = tm.int(u64_val::<B>(0x4F800000), 32, false);
    let m1 = tm.int(u64_val::<B>(0xBF800000), 32, false);
    let mut hy = Vector::<u32>::new();
    let mag = tm.fabs(top, 32);
    hy.push(tm.fcmp(T_FLT, mag, inf, fd));
    hy.push(ordered(&mut tm, T_FLE, zero, top));
    hy.push(ordered(&mut tm, T_FLT, top, k1000));
    hy.push(tm.fcmp(T_FEQ, r, r, fd));
    let ge = ordered(&mut tm, T_FLE, top, r);
    hy.push(tm.not(ge));
    hy.push(ordered(&mut tm, T_FLT, zero, r));
    let nn = tm.fcmp(T_FEQ, r, r, fd);
    let below = tm.fcmp(T_FLT, r, p32, fd);
    let above = tm.fcmp(T_FLT, m1, r, fd);
    let g0 = tm.and(nn, below);
    let g = tm.and(g0, above);
    let mut sv = sv0::Solver::<B>::new();
    assert(sv.implies(&tm, &hy, g, true), "r fits");
    let k100 = tm.int(u64_val::<B>(0x42C80000), 32, false);
    let small = tm.fcmp(T_FLT, r, k100, fd);
    let mut sv2 = sv0::Solver::<B>::new();
    assert(!sv2.implies(&tm, &hy, small, true), "r may be 100 or more");
}
