// The certificate checker of the contract prover: the solvers (`solver.spc`, `sat.spc`) are not
// trusted, so a refutation counts only when this checker accepts the proofs the solvers wrote for it.
// It shares no code with them but the meaning of terms (`terms.spc`: `bounds`, `lin_form`; `blast.spc`:
// the clauses; `state_lit` here: the rows of a literal), and does its own arithmetic, every step checked
// for overflow. A solver defect can make a proof fail here, never make a false one pass.
//
// A refutation of hypotheses and a negated goal (`begin`) is:
//
// - lemmas: each one a set of theory literals (`blast::tlit`) that cannot all hold, by a proof of the
//   theories below (`lemma`) or by an LRAT proof over their bits (`blast`, `blast_lemma`); its negation
//   is a clause;
// - an LRAT proof that the skeleton of the formulas and the lemmas' clauses (`seal`) have no model
//   (`covered`): the case split covers every case.
//
// An LRAT proof adds clauses one at a time; each one names its hints, clauses that become unit in turn,
// then empty, under the negation of the new clause (reverse unit propagation, `Lrat::check`). It ends
// with the empty clause.
//
// A branch states integer rows (`sum(c * atom) + k <= 0`), equalities and disequalities of terms,
// and boolean literals. A proof is:
//
// - a log of equalities (`Fact`), each from earlier ones: stated by the branch, transitive, congruent
//   (one operation over equal operands), or implied by the rows (two trees, one per direction);
// - trees of branch and bound: a split node divides an atom's values at `v` (`atom <= v` on the left,
//   `atom >= v + 1` on the right); a leaf holds nonnegative integer multipliers of rows whose sum has
//   no atom and a constant above 0 (a Farkas combination: no integer point satisfies the rows);
// - its end: a tree over the branch's rows, or an equality the branch states false (a disequality,
//   a positive and a negative literal, two different constants).
//
// Each row a leaf names is rebuilt here and divided by the gcd of its coefficients with its constant
// rounded up, which keeps every integer solution. A product of two terms is an atom of the rows, but a
// leaf below splits that fix one operand at a value `c` may use the product as `c` times the other. A cut is such a row of its own: a nonnegative
// combination of rows, divided by the gcd (a Chvatal-Gomory cut); it holds at every integer point of
// the branch, so any leaf may use it.
import prove::terms as *;
import prove::blast as *;

// The rows a leaf may name (`RowRef.kind`).
pub(package) const RW_IN: u8 = 0; // `i`: the branch's row
pub(package) const RW_LO: u8 = 1; // `i`: an atom, `lo - atom <= 0` for its lower bound
pub(package) const RW_HI: u8 = 2; // `i`: an atom, `atom - hi <= 0`
pub(package) const RW_SPLIT_LO: u8 = 3; // `i`: a split node above the leaf, its left side `atom - v <= 0`
pub(package) const RW_SPLIT_HI: u8 = 4; // its right side `v + 1 - atom <= 0`
pub(package) const RW_EQ_LE: u8 = 5; // `i`: a fact `a == b` of the tree's prefix, `a - b <= 0`
pub(package) const RW_EQ_GE: u8 = 6; // `b - a <= 0`
pub(package) const RW_HYP: u8 = 7; // the tree's hypothesis `a < b`: `a - b + 1 <= 0`
pub(package) const RW_CUT: u8 = 8; // `i`: a cut of `Proof.cuts`
// `i`: `p << 1 | o`, product `p == x * y` whose operand `y` (`b` when `o` is 1, `a` when 0) the bounds
// and the splits above the leaf fix at `c`: `p - c * x <= 0` (LE) and `c * x - p <= 0` (GE).
pub(package) const RW_FIX_LE: u8 = 9;
pub(package) const RW_FIX_GE: u8 = 10;

pub(package) struct RowRef {
    pub(package) i: u32,
    pub(package) kind: u8,
}

pub(package) struct Mult<const B: usize> {
    pub(package) m: Num<B>,
    pub(package) r: RowRef,
}

// A node of a tree: a split, or a leaf whose multipliers are [ms, ms + mn) of `Proof.mults`.
pub(package) const N_LEAF: u8 = 0;
pub(package) const N_SPLIT: u8 = 1;

pub(package) struct TreeNode<const B: usize> {
    pub(package) v: Num<B>,
    pub(package) atom: u32,
    pub(package) left: u32,
    pub(package) right: u32,
    pub(package) ms: u32,
    pub(package) mn: u32,
    pub(package) kind: u8,
}

// A refutation of the rows: its root node, its hypothesis `ha < hb` (NONE: none), and the facts
// [0, upto) whose equalities it may use as rows.
pub(package) struct Tree {
    pub(package) root: u32,
    pub(package) ha: u32,
    pub(package) hb: u32,
    pub(package) upto: u32,
}

// A cut: the multipliers [ms, ms + mn) of `Proof.mults` over rows that are not a tree's own (no split,
// no hypothesis; facts [0, upto); earlier cuts).
pub(package) struct Cut {
    pub(package) ms: u32,
    pub(package) mn: u32,
    pub(package) upto: u32,
}

// How a fact `a == b` follows (`Fact.kind`).
pub(package) const F_IN: u8 = 0; // `p`: the branch's equality
pub(package) const F_TRANS: u8 = 1; // facts `p` and `q`, which share a term
pub(package) const F_CONG: u8 = 2; // one operation of `a` and `b`; per operand j, `cargs[p + j]` is NONE
// (the same term) or a fact; `q` operands
pub(package) const F_ARITH: u8 = 3; // trees `p` (hypothesis `a < b`) and `q` (`b < a`)

pub(package) struct Fact {
    pub(package) a: u32,
    pub(package) b: u32,
    pub(package) p: u32,
    pub(package) q: u32,
    pub(package) kind: u8,
}

// How the branch ends (`Proof.end`).
pub(package) const X_LA: u8 = 0; // `p`: a tree without a hypothesis over all the facts
pub(package) const X_NEQ: u8 = 1; // fact `p` is the branch's disequality `q`
pub(package) const X_LITS: u8 = 2; // fact `p` joins a positive and a negative literal of the branch
pub(package) const X_CONST: u8 = 3; // fact `p` joins two different constants

pub(package) struct Proof<const B: usize> {
    pub(package) facts: Vector<Fact>,
    pub(package) cargs: Vector<u32>,
    pub(package) nodes: Vector<TreeNode<B>>,
    pub(package) mults: Vector<Mult<B>>,
    pub(package) trees: Vector<Tree>,
    pub(package) cuts: Vector<Cut>,
    pub(package) end: u8,
    pub(package) p: u32,
    pub(package) q: u32,
}

extend<const B: usize> Proof<B> {
    pub(package) fn new() Proof<B> {
        return Proof::<B> {
            facts: Vector::<Fact>::new(),
            cargs: Vector::<u32>::new(),
            nodes: Vector::<TreeNode<B>>::new(),
            mults: Vector::<Mult<B>>::new(),
            trees: Vector::<Tree>::new(),
            cuts: Vector::<Cut>::new(),
            end: X_LA,
            p: NONE,
            q: NONE,
        };
    }

    pub(package) fn clear(self: &mut Self) {
        self.facts.clear();
        self.cargs.clear();
        self.nodes.clear();
        self.mults.clear();
        self.trees.clear();
        self.cuts.clear();
        self.end = X_LA;
        self.p = NONE;
        self.q = NONE;
    }
}

// What a branch states: its rows (terms in `pool`), its equalities and disequalities (`a << 32 | b`),
// and its literals (`term << 1 | polarity`).
pub(package) struct Stated<const B: usize> {
    pub(package) rows: Vector<Row<B>>,
    pub(package) pool: Vector<LinTerm<B>>,
    pub(package) eqs: Vector<u64>,
    pub(package) neqs: Vector<u64>,
    pub(package) lits: Vector<u64>,
}

extend<const B: usize> Stated<B> {
    pub(package) fn new() Stated<B> {
        return Stated::<B> {
            rows: Vector::<Row<B>>::new(),
            pool: Vector::<LinTerm<B>>::new(),
            eqs: Vector::<u64>::new(),
            neqs: Vector::<u64>::new(),
            lits: Vector::<u64>::new(),
        };
    }
}

// The row `a - b + off <= 0` into `st`. False when the form does not fit.
fn add_le<const B: usize>(
    tm: &Terms<B>,
    st: &mut Stated<B>,
    a: u32,
    b: u32,
    off: i64,
    lin: &mut Vector<LinTerm<B>>,
    stack: &mut Vector<LinTerm<B>>,
) bool {
    lin.clear();
    let mut k = wide::<B>(off);
    if !lin_form(tm, a, Num::<B>::one(), &mut k, lin, stack) || !lin_form(tm, b, wide::<B>(-1), &mut k, lin, stack) {
        return false;
    }
    let n = lin.len();
    let e = merge_terms(lin, 0, n);
    let start = st.pool.len() as u32;
    for j in 0..e {
        st.pool.push(lin[j]);
    }
    st.rows.push(Row::<B> { k: k, start: start, len: e as u32 });
    return true;
}

// What theory literal `l` (`blast::tlit`) states, into `st`: an order of integers is a row, an
// equality of integers two rows and an equality, its orders (SEL_LT, SEL_GT) a row each; an equality
// of other values an equality or a disequality; every other atom a literal. False when a row does not
// fit. `lin` and `stack` are scratch.
pub(package) fn state_lit<const B: usize>(
    tm: &Terms<B>,
    st: &mut Stated<B>,
    l: u64,
    lin: &mut Vector<LinTerm<B>>,
    stack: &mut Vector<LinTerm<B>>,
) bool {
    let t = (l >> 3) as u32;
    let sel = l >> 1 & 3;
    let pos = (l & 1) != 0;
    let x = tm.at(t);
    let ints = tm.is_int(x.a) && tm.is_int(x.b);
    if sel != SEL_ATOM {
        if !(x.op == T_EQ || x.op == T_NE) || !ints || sel > SEL_GT {
            return false;
        }
        // `a < b` (SEL_LT) or `b < a`, or (negative) `b <= a` or `a <= b`.
        let (p, q) = pick(sel == SEL_LT, (x.a, x.b), (x.b, x.a));
        return if pos {
            add_le(tm, st, p, q, 1, lin, stack)
        } else {
            add_le(tm, st, q, p, 0, lin, stack)
        };
    }
    if (x.op == T_LT || x.op == T_LE) && ints {
        // pos: a - b + (1 or 0) <= 0; else b - a + (0 or 1) <= 0
        return if pos {
            add_le(tm, st, x.a, x.b, pick(x.op == T_LT, 1i64, 0), lin, stack)
        } else {
            add_le(tm, st, x.b, x.a, pick(x.op == T_LT, 0i64, 1), lin, stack)
        };
    }
    if (x.op == T_EQ || x.op == T_NE) && ints {
        if x.op == T_EQ == pos {
            if !add_le(tm, st, x.a, x.b, 0, lin, stack) || !add_le(tm, st, x.b, x.a, 0, lin, stack) {
                return false;
            }
            st.eqs.push(pair(x.a, x.b));
        }
        return true;
    }
    if x.op == T_EQ || x.op == T_NE {
        if x.op == T_EQ == pos {
            st.eqs.push(pair(x.a, x.b));
        } else {
            st.neqs.push(pair(x.a, x.b));
        }
    }
    st.lits.push(t as u64 << 1 | pos as u64);
    return true;
}

// What theory literals state, built by the kernel only (`Kernel::state`): the solvers read it (`get`)
// and hand it back with their proof (`Kernel::lemma`), so the rows the kernel checks are the literals'.
pub(package) struct Built<const B: usize> {
    st: Stated<B>,
    lits: Vector<u64>,
}

extend<const B: usize> Built<B> {
    pub(package) const fn get(self: &Self) &Stated<B> {
        return &self.st;
    }
}

// The LRAT checker's clauses (those a proof adds) and assignment.
pub(package) struct Lrat {
    start: Vector<u32>,
    pool: Vector<u32>,
    val: Vector<bool>, // by literal: true when it holds
    touched: Vector<u32>,
}

extend Lrat {
    pub(package) fn new() Lrat {
        return Lrat {
            start: Vector::<u32>::new(),
            pool: Vector::<u32>::new(),
            val: Vector::<bool>::new(),
            touched: Vector::<u32>::new(),
        };
    }

    // Whether `proof` (steps `id, n, n literals, m, m hints`) derives the empty clause from `cnf`. The
    // clauses of `cnf` have ids 1 to its count; each step adds the next id. A step holds when its hints,
    // each an earlier clause, become unit in turn and then empty under the negation of its literals.
    pub(package) fn check(self: &mut Self, cnf: &Cnf, proof: &Vector<u32>) bool {
        let m = cnf.ends.len() as u32;
        self.start.clear();
        self.pool.clear();
        self.start.push(0);
        self.val.clear();
        for _j in 0..2 * cnf.nv {
            self.val.push(false);
        }
        let mut p: usize = 0;
        for _s in 0..proof.len() {
            if p + 2 > proof.len() {
                return false;
            }
            let id = proof[p];
            let n = proof[p + 1] as usize;
            if id != m + self.start.len() as u32 || p + 3 + n > proof.len() {
                return false;
            }
            let ls = p + 2;
            let nh = proof[ls + n] as usize;
            let hs = ls + n + 1;
            if hs + nh > proof.len() {
                return false;
            }
            p = hs + nh;
            self.touched.clear();
            let mut holds = false;
            for j in ls..ls + n {
                let l = proof[j];
                if l >= 2 * cnf.nv {
                    self.undo();
                    return false;
                }
                // A literal and its negation: the clause holds by itself.
                holds = holds || self.val[l as usize];
                self.set(l ^ 1);
            }
            for j in hs..hs + nh {
                if holds {
                    break;
                }
                let h = proof[j];
                if h == 0 || h >= id {
                    self.undo();
                    return false;
                }
                let (cs, ce, own) = if h == 1 {
                    (0u32, cnf.ends[0], false)
                } else if h <= m {
                    (cnf.ends[(h - 2) as usize], cnf.ends[(h - 1) as usize], false)
                } else {
                    let q = (h - m) as usize;
                    (self.start[q - 1], self.start[q], true)
                };
                let mut free = NONE;
                let mut sat = false;
                for q in cs..ce {
                    let l = if own {
                        self.pool[q as usize]
                    } else {
                        cnf.lits[q as usize]
                    };
                    if self.val[l as usize] {
                        sat = true;
                        break;
                    }
                    if !self.val[(l ^ 1) as usize] && l != free {
                        if free != NONE {
                            sat = true;
                            break;
                        }
                        free = l;
                    }
                }
                if sat {
                    self.undo();
                    return false;
                }
                if free == NONE {
                    holds = true;
                } else {
                    self.set(free);
                }
            }
            self.undo();
            if !holds {
                return false;
            }
            if n == 0 {
                return true;
            }
            for j in ls..ls + n {
                self.pool.push(proof[j]);
            }
            self.start.push(self.pool.len() as u32);
        }
        return false;
    }

    fn set(self: &mut Self, l: u32) {
        if !self.val[l as usize] {
            self.val.set(l as usize, true);
            self.touched.push(l);
        }
    }

    fn undo(self: &mut Self) {
        for j in 0..self.touched.len() {
            self.val.set(self.touched[j] as usize, false);
        }
        self.touched.clear();
    }
}

// The checker's scratch.
pub(package) struct Kernel<const B: usize> {
    acc: Vector<LinTerm<B>>,
    row: Vector<LinTerm<B>>,
    stack: Vector<LinTerm<B>>,
    ops_a: Vector<u32>,
    ops_b: Vector<u32>,
    path: Vector<u64>, // the split sides above a node: node << 1 | right
    todo: Vector<Visit>,
    // The cuts built so far, in order: [0, ncut) of `Proof.cuts`, each one's row or its failure.
    ncut: u32,
    cut_ok: Vector<bool>,
    cut_rows: Vector<Row<B>>,
    cut_pool: Vector<LinTerm<B>>,
    cacc: Vector<LinTerm<B>>,
    // The lemmas accepted (`lems`, each one ending at `lend`), the skeleton with their clauses (`seal`),
    // the bits of the last literals blasted (`blits`), the LRAT scratch.
    lems: Vector<u64>,
    lend: Vector<u32>,
    sk: Blaster<B>,
    bl: Blaster<B>,
    blits: Vector<u64>,
    lr: Lrat,
}

// A node of a tree to check: the length of the path above its parent, and its parent's side
// (NO_MARK for the root).
struct Visit {
    node: u32,
    depth: u32,
    mark: u64,
}

const NO_MARK: u64 = 0xFFFFFFFFFFFFFFFFu64;

const fn pair(a: u32, b: u32) u64 {
    return a as u64 << 32 | b as u64;
}

const fn same_pair(x: u64, a: u32, b: u32) bool {
    return x == pair(a, b) || x == pair(b, a);
}

extend<const B: usize> Kernel<B> {
    pub(package) fn new() Kernel<B> {
        return Kernel::<B> {
            acc: Vector::<LinTerm<B>>::new(),
            row: Vector::<LinTerm<B>>::new(),
            stack: Vector::<LinTerm<B>>::new(),
            ops_a: Vector::<u32>::new(),
            ops_b: Vector::<u32>::new(),
            path: Vector::<u64>::new(),
            todo: Vector::<Visit>::new(),
            ncut: 0,
            cut_ok: Vector::<bool>::new(),
            cut_rows: Vector::<Row<B>>::new(),
            cut_pool: Vector::<LinTerm<B>>::new(),
            cacc: Vector::<LinTerm<B>>::new(),
            lems: Vector::<u64>::new(),
            lend: Vector::<u32>::new(),
            sk: Blaster::<B>::new(),
            bl: Blaster::<B>::new(),
            blits: Vector::<u64>::new(),
            lr: Lrat::new(),
        };
    }

    // Start a refutation: no lemma yet.
    pub(package) fn begin(self: &mut Self) {
        self.lems.clear();
        self.lend.clear();
    }

    fn accept(self: &mut Self, lits: &Vector<u64>) {
        self.lems.extend_copy(lits);
        self.lend.push(self.lems.len() as u32);
    }

    // What the theory literals `lits` state (`state_lit`), None when a row does not fit.
    pub(package) fn state(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>) Option<Built<B>> {
        let mut st = Stated::<B>::new();
        for j in 0..lits.len() {
            if !state_lit(tm, &mut st, lits[j], &mut self.row, &mut self.stack) {
                return None;
            }
        }
        return Some(Built::<B> { st: st, lits: lits.clone() });
    }

    // Whether `pf` refutes what `b` states; then its literals are a lemma.
    pub(package) fn lemma(self: &mut Self, tm: &Terms<B>, b: Built<B>, pf: &Proof<B>) bool {
        if !self.check(tm, &b.st, pf) {
            return false;
        }
        self.accept(&b.lits);
        return true;
    }

    // The skeleton of `hyps` and the negation of `goal`, and the negation of each lemma, as clauses
    // (`skeleton`) for `covered`. False past a bound.
    pub(package) fn seal(self: &mut Self, tm: &Terms<B>, hyps: &Vector<u32>, goal: u32) bool {
        self.sk.reset(false);
        for j in 0..hyps.len() {
            if !self.sk.assert(tm, hyps[j], true) {
                return false;
            }
        }
        if !self.sk.assert(tm, goal, false) {
            return false;
        }
        let mut c = Vector::<u64>::new();
        let mut s: u32 = 0;
        for j in 0..self.lend.len() {
            c.clear();
            for q in s..self.lend[j] {
                c.push(self.lems[q as usize]);
            }
            s = self.lend[j];
            if !self.sk.negation(tm, &c) {
                return false;
            }
        }
        return true;
    }

    // The bits of the theory literals `lits`, as clauses (`bits`), for a SAT refutation.
    pub(package) fn blast(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>) bool {
        self.bl.reset(true);
        self.blits.clear();
        self.blits.extend_copy(lits);
        for j in 0..lits.len() {
            let x = self.bl.lit_for(tm, lits[j]);
            if x == NONE {
                return false;
            }
            self.bl.unit(x);
        }
        return self.bl.ok;
    }

    // Whether `proof` refutes the clauses of `blast`; then their literals are a lemma.
    pub(package) fn blast_lemma(self: &mut Self, proof: &Vector<u32>) bool {
        if !self.lr.check(&self.bl.cnf, proof) {
            return false;
        }
        let ls = self.blits.clone();
        self.accept(&ls);
        return true;
    }

    // Whether `proof` refutes the clauses of `seal`: then the hypotheses imply the goal.
    pub(package) fn covered(self: &mut Self, proof: &Vector<u32>) bool {
        return self.lr.check(&self.sk.cnf, proof);
    }

    pub(package) const fn skeleton(self: &Self) &Cnf {
        return &self.sk.cnf;
    }

    pub(package) const fn bits(self: &Self) &Blaster<B> {
        return &self.bl;
    }

    // Whether proof `pf` refutes the branch `st`: every fact and every tree it uses is valid.
    pub(package) fn check(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>) bool {
        self.ncut = 0;
        self.cut_ok.clear();
        self.cut_rows.clear();
        self.cut_pool.clear();
        for i in 0..pf.facts.len() {
            if !self.fact(tm, st, pf, i as u32) {
                return false;
            }
        }
        let nf = pf.facts.len() as u32;
        if pf.end == X_LA {
            if pf.p as usize >= pf.trees.len() {
                return false;
            }
            let t = pf.trees[pf.p as usize];
            return t.ha == NONE && t.upto <= nf && self.tree(tm, st, pf, pf.p);
        }
        if pf.p >= nf {
            return false;
        }
        let f = pf.facts[pf.p as usize];
        if pf.end == X_NEQ {
            return pf.q as usize < st.neqs.len() && same_pair(st.neqs[pf.q as usize], f.a, f.b);
        }
        if pf.end == X_LITS {
            let mut ap = false;
            let mut an = false;
            let mut bp = false;
            let mut bn = false;
            for j in 0..st.lits.len() {
                let l = st.lits[j];
                ap = ap || l == (f.a as u64 << 1 | 1);
                an = an || l == f.a as u64 << 1;
                bp = bp || l == (f.b as u64 << 1 | 1);
                bn = bn || l == f.b as u64 << 1;
            }
            return ap && bn || an && bp;
        }
        if pf.end == X_CONST {
            let x = tm.at(f.a);
            let y = tm.at(f.b);
            return (x.op == T_INT && y.op == T_INT || x.op == T_BOOL && y.op == T_BOOL) && x.k != y.k;
        }
        return false;
    }

    // Whether fact `i` follows from the branch and the facts before it.
    fn fact(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>, i: u32) bool {
        let f = pf.facts[i as usize];
        let n = tm.ts.len() as u32;
        if f.a >= n || f.b >= n {
            return false;
        }
        if f.kind == F_IN {
            return f.p as usize < st.eqs.len() && same_pair(st.eqs[f.p as usize], f.a, f.b);
        }
        if f.kind == F_TRANS {
            if f.p >= i || f.q >= i {
                return false;
            }
            let x = pf.facts[f.p as usize];
            let y = pf.facts[f.q as usize];
            // x joins a with s, y joins s with b.
            let s = if x.a == f.a {
                x.b
            } else if x.b == f.a {
                x.a
            } else {
                return false;
            };
            return same_pair(pair(y.a, y.b), s, f.b);
        }
        if f.kind == F_CONG {
            let x = tm.at(f.a);
            let y = tm.at(f.b);
            if x.op != y.op || x.w != y.w || x.sg != y.sg || x.k != y.k || pooled(x.op) && x.b != y.b {
                return false;
            }
            tm.operands(f.a, &mut self.ops_a);
            tm.operands(f.b, &mut self.ops_b);
            if self.ops_a.len() == 0 || self.ops_a.len() != self.ops_b.len() || f.q as usize != self.ops_a.len() {
                return false;
            }
            // An operation without term operands (a variable, a local's reference) has none to join.
            if f.p as usize + f.q as usize > pf.cargs.len() {
                return false;
            }
            for j in 0..self.ops_a.len() {
                let oa = self.ops_a[j];
                let ob = self.ops_b[j];
                let g = pf.cargs[f.p as usize + j];
                if g == NONE {
                    if oa != ob {
                        return false;
                    }
                } else if g >= i || !same_pair(pair(pf.facts[g as usize].a, pf.facts[g as usize].b), oa, ob) {
                    return false;
                }
            }
            return true;
        }
        if f.kind == F_ARITH {
            if f.p as usize >= pf.trees.len() || f.q as usize >= pf.trees.len() {
                return false;
            }
            let t1 = pf.trees[f.p as usize];
            let t2 = pf.trees[f.q as usize];
            if !tm.is_int(f.a) || !tm.is_int(f.b) || t1.ha != f.a || t1.hb != f.b || t2.ha != f.b || t2.hb != f.a {
                return false;
            }
            return t1.upto <= i && t2.upto <= i && self.tree(tm, st, pf, f.p) && self.tree(tm, st, pf, f.q);
        }
        return false;
    }

    // Whether tree `ti` refutes the rows: every leaf's combination is a constant above 0.
    fn tree(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>, ti: u32) bool {
        let t = pf.trees[ti as usize];
        if t.root as usize >= pf.nodes.len() {
            return false;
        }
        self.path.clear();
        self.todo.clear();
        self.todo.push(Visit { node: t.root, depth: 0, mark: NO_MARK });
        for _s in 0..pf.nodes.len() + 1 {
            if self.todo.len() == 0 {
                return true;
            }
            let e = self.todo.pop().unwrap();
            self.path.truncate(e.depth as usize);
            if e.mark != NO_MARK {
                self.path.push(e.mark);
            }
            let depth = self.path.len() as u32;
            let nd = pf.nodes[e.node as usize];
            if nd.kind == N_SPLIT {
                // Children come after their parent, so the walk ends.
                if nd.left <= e.node || nd.right <= e.node || nd.left as usize >= pf.nodes.len() || nd.right as usize >= pf.nodes.len() || !tm.is_int(
                    nd.atom,
                ) {
                    return false;
                }
                self.todo.push(Visit { node: nd.right, depth: depth, mark: e.node as u64 << 1 | 1 });
                self.todo.push(Visit { node: nd.left, depth: depth, mark: e.node as u64 << 1 });
                continue;
            }
            if nd.kind != N_LEAF || !self.leaf(tm, st, pf, &t, &nd, depth as usize) {
                return false;
            }
        }
        return false;
    }

    // Whether leaf `nd`, below the splits [0, depth) of the path, sums to a constant above 0.
    fn leaf(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>, t: &Tree, nd: &TreeNode<B>, depth: usize) bool {
        if nd.ms as usize + nd.mn as usize > pf.mults.len() || nd.mn == 0 {
            return false;
        }
        self.acc.clear();
        let mut total = Num::<B>::zero();
        for j in nd.ms..nd.ms + nd.mn {
            let m = pf.mults[j as usize];
            if !(Num::<B>::zero() < m.m) {
                return false;
            }
            let mut k = Num::<B>::zero();
            if !self.row_of(tm, st, pf, t, m.r, depth, &mut k) || !tighten(&mut self.row, &mut k) {
                return false;
            }
            for q in 0..self.row.len() {
                let x = self.row[q];
                switch x.c.checked_mul(&m.m) {
                    Some(v) => self.acc.push(LinTerm::<B> { c: v, atom: x.atom }),
                    None => {
                        return false;
                    },
                }
            }
            switch k.checked_mul(&m.m) {
                Some(v) => {
                    switch total.checked_add(&v) {
                        Some(s) => total = s,
                        None => {
                            return false;
                        },
                    }
                },
                None => {
                    return false;
                },
            }
        }
        if !sum_up(&mut self.acc) {
            return false;
        }
        return self.acc.len() == 0 && Num::<B>::zero() < total;
    }

    // Row `r` into `row` and `k`, as a leaf below the splits [0, depth) of the path sees it.
    fn row_of(
        self: &mut Self,
        tm: &Terms<B>,
        st: &Stated<B>,
        pf: &Proof<B>,
        t: &Tree,
        r: RowRef,
        depth: usize,
        k: &mut Num<B>,
    ) bool {
        self.row.clear();
        if r.kind == RW_IN {
            if r.i as usize >= st.rows.len() {
                return false;
            }
            let x = st.rows[r.i as usize];
            for j in x.start..x.start + x.len {
                self.row.push(st.pool[j as usize]);
            }
            *k = x.k;
            return true;
        }
        if r.kind == RW_LO || r.kind == RW_HI {
            if r.i as usize >= tm.ts.len() || !tm.is_int(r.i) {
                return false;
            }
            switch tm.bounds(r.i) {
                Some((lo, hi)) => {
                    if r.kind == RW_LO {
                        self.row.push(LinTerm::<B> { c: wide::<B>(-1), atom: r.i });
                        *k = lo;
                    } else {
                        self.row.push(LinTerm::<B> { c: Num::<B>::one(), atom: r.i });
                        *k = Num::<B>::zero() - hi;
                    }
                    return true;
                },
                None => {
                    return false;
                },
            }
        }
        if r.kind == RW_CUT {
            if r.i as usize >= pf.cuts.len() || pf.cuts[r.i as usize].upto > t.upto || !self.cuts_to(tm, st, pf, r.i) {
                return false;
            }
            let x = self.cut_rows[r.i as usize];
            self.row.clear();
            for j in x.start..x.start + x.len {
                self.row.push(self.cut_pool[j as usize]);
            }
            *k = x.k;
            return true;
        }
        if r.kind == RW_SPLIT_LO || r.kind == RW_SPLIT_HI {
            let want = r.i as u64 << 1 | (r.kind == RW_SPLIT_HI) as u64;
            let mut on = false;
            for j in 0..depth {
                on = on || self.path[j] == want;
            }
            if !on {
                return false;
            }
            let nd = pf.nodes[r.i as usize];
            if r.kind == RW_SPLIT_LO {
                self.row.push(LinTerm::<B> { c: Num::<B>::one(), atom: nd.atom });
                *k = Num::<B>::zero() - nd.v;
                return true;
            }
            self.row.push(LinTerm::<B> { c: wide::<B>(-1), atom: nd.atom });
            let one = Num::<B>::one();
            switch nd.v.checked_add(&one) {
                Some(v) => *k = v,
                None => {
                    return false;
                },
            }
            return true;
        }
        if r.kind == RW_FIX_LE || r.kind == RW_FIX_GE {
            let p = r.i >> 1;
            if p as usize >= tm.ts.len() || !tm.is_int(p) || tm.at(p).op != T_MUL {
                return false;
            }
            let x = tm.at(p);
            let (y, o) = if (r.i & 1) == 1 {
                (x.b, x.a)
            } else {
                (x.a, x.b)
            };
            if !tm.is_int(y) || !tm.is_int(o) {
                return false;
            }
            let c = switch self.fixed(tm, pf, y, depth) {
                Some(v) => v,
                None => {
                    return false;
                },
            };
            let le = r.kind == RW_FIX_LE;
            *k = Num::<B>::zero();
            return lin_form(tm, p, pick(le, Num::<B>::one(), wide::<B>(-1)), k, &mut self.row, &mut self.stack) && lin_form(
                tm,
                o,
                pick(le, Num::<B>::zero() - c, c),
                k,
                &mut self.row,
                &mut self.stack,
            ) && sum_up(&mut self.row);
        }
        let (a, b, off) = if r.kind == RW_EQ_LE || r.kind == RW_EQ_GE {
            if r.i >= t.upto || r.i as usize >= pf.facts.len() {
                return false;
            }
            let f = pf.facts[r.i as usize];
            if r.kind == RW_EQ_LE {
                (f.a, f.b, 0i64)
            } else {
                (f.b, f.a, 0i64)
            }
        } else if r.kind == RW_HYP && t.ha != NONE {
            (t.ha, t.hb, 1i64)
        } else {
            return false;
        };
        if !tm.is_int(a) || !tm.is_int(b) {
            return false;
        }
        *k = wide::<B>(off);
        if !lin_form(tm, a, Num::<B>::one(), k, &mut self.row, &mut self.stack) || !lin_form(
            tm,
            b,
            wide::<B>(-1),
            k,
            &mut self.row,
            &mut self.stack,
        ) {
            return false;
        }
        return sum_up(&mut self.row);
    }
}

extend<const B: usize> Kernel<B> {
    // The value of integer `y` when its bounds and the splits [0, depth) of the path leave it one;
    // None else.
    fn fixed(self: &Self, tm: &Terms<B>, pf: &Proof<B>, y: u32, depth: usize) Option<Num<B>> {
        let mut lo = Num::<B>::zero();
        let mut hi = Num::<B>::zero();
        let mut hl = false;
        let mut hh = false;
        switch tm.bounds(y) {
            Some((l, h)) => {
                lo = l;
                hi = h;
                hl = true;
                hh = true;
            },
            None => {},
        }
        for j in 0..depth {
            let m = self.path[j];
            let nd = pf.nodes[(m >> 1) as usize];
            if nd.atom != y {
                continue;
            }
            if (m & 1) == 0 {
                if !hh || nd.v < hi {
                    hi = nd.v;
                    hh = true;
                }
                continue;
            }
            let one = Num::<B>::one();
            let v1 = switch nd.v.checked_add(&one) {
                Some(v) => v,
                None => {
                    return None;
                },
            };
            if !hl || lo < v1 {
                lo = v1;
                hl = true;
            }
        }
        if hl && hh && lo == hi {
            return Some(lo);
        }
        return None;
    }

    // Build the cuts up to `c`, in order; whether cut `c` is valid.
    fn cuts_to(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, pf: &Proof<B>, c: u32) bool {
        for x in self.ncut..c + 1 {
            let cut = pf.cuts[x as usize];
            // Its own rows see no split and no hypothesis: a tree of no node, over the facts it may use.
            let t = Tree { root: NONE, ha: NONE, hb: NONE, upto: cut.upto };
            let mut ok = cut.mn != 0 && cut.ms as usize + cut.mn as usize <= pf.mults.len();
            self.cacc.clear();
            let mut total = Num::<B>::zero();
            if ok {
                for j in cut.ms..cut.ms + cut.mn {
                    let m = pf.mults[j as usize];
                    let mut k = Num::<B>::zero();
                    // A cut names only earlier cuts.
                    if !(Num::<B>::zero() < m.m) || m.r.kind == RW_CUT && m.r.i >= x || !self.row_of(
                        tm,
                        st,
                        pf,
                        &t,
                        m.r,
                        0,
                        &mut k,
                    ) || !tighten(&mut self.row, &mut k) {
                        ok = false;
                        break;
                    }
                    for q in 0..self.row.len() {
                        let e = self.row[q];
                        switch e.c.checked_mul(&m.m) {
                            Some(v) => self.cacc.push(LinTerm::<B> { c: v, atom: e.atom }),
                            None => {
                                ok = false;
                            },
                        }
                    }
                    switch k.checked_mul(&m.m) {
                        Some(v) => {
                            switch total.checked_add(&v) {
                                Some(s) => total = s,
                                None => {
                                    ok = false;
                                },
                            }
                        },
                        None => {
                            ok = false;
                        },
                    }
                    if !ok {
                        break;
                    }
                }
            }
            ok = ok && tighten(&mut self.cacc, &mut total);
            let start = self.cut_pool.len() as u32;
            if ok {
                self.cut_pool.extend_copy(&self.cacc);
            }
            self.cut_rows.push(Row::<B> { k: total, start: start, len: self.cut_pool.len() as u32 - start });
            self.cut_ok.push(ok);
            self.ncut = x + 1;
        }
        return self.cut_ok[c as usize];
    }
}

// Order `v` by atom, add the terms of one atom and drop zeros; false when a value leaves B bits.
fn sum_up<const B: usize>(v: &mut Vector<LinTerm<B>>) bool {
    let n = v.len();
    for j in 1..n {
        let x = v[j];
        let mut q = j;
        while q > 0 && v[q - 1].atom > x.atom {
            v.set(q, v[q - 1]);
            q -= 1;
        }
        v.set(q, x);
    }
    let mut o: usize = 0;
    let mut j: usize = 0;
    while j < n {
        let mut x = v[j];
        j += 1;
        while j < n && v[j].atom == x.atom {
            switch x.c.checked_add(&v[j].c) {
                Some(s) => x.c = s,
                None => {
                    return false;
                },
            }
            j += 1;
        }
        if !x.c.is_zero() {
            v.set(o, x);
            o += 1;
        }
    }
    v.truncate(o);
    return true;
}

// Divide row `v + k <= 0` by the gcd of its coefficients, its constant rounded up: an integer point
// satisfies the row exactly when it satisfies the result. False when a value leaves B bits.
fn tighten<const B: usize>(v: &mut Vector<LinTerm<B>>, k: &mut Num<B>) bool {
    if !sum_up(v) {
        return false;
    }
    let g = switch coef_gcd(v, 0, v.len()) {
        Some(x) => x,
        None => {
            return false;
        },
    };
    if g.is_zero() || g == Num::<B>::one() {
        return true;
    }
    for j in 0..v.len() {
        let x = v[j];
        v.set(j, LinTerm::<B> { c: x.c.div_euclid(&g), atom: x.atom });
    }
    // ceil(k / g) = -floor(-k / g)
    *k = Num::<B>::zero() - (Num::<B>::zero() - *k).div_euclid(&g);
    return true;
}
