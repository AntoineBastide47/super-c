// The solvers of the contract prover. `implies` splits the hypotheses and the negated goal into
// branches (`close`); each branch is refuted by two theory solvers that exchange equalities:
//
// - congruence closure merges the terms the branch states equal, and every two applications of one
//   operation over equal operands (each operation is an uninterpreted function to it);
// - linear integer arithmetic over the branch's rows and the closure's integer equalities: a simplex
//   over exact rationals in the bounded-variable form (Bland's rule), then branch and bound on an
//   atom with a fractional value;
// - when the arithmetic has an integer model, two applications of one operation whose operands
//   differ only in integers equal in the model ask the arithmetic whether it implies each such
//   equality; an implied one merges, and the round repeats.
//
// With bits (`implies(.., bits)`), a branch whose literals hold a bit operation is first refuted on the
// bits of the literals that share unknowns with the goal's (`blast.spc`) by the SAT solver (`sat.spc`),
// then by the theories.
//
// The solvers are not trusted: each refutation writes a proof (`kernel::Proof`, or LRAT for SAT), a
// branch counts as refuted only when the kernel accepts it, and the split into branches counts only
// when the kernel accepts an LRAT proof that the branches cover every case. Every search has a fixed
// bound; past one, the answer is "not proved".
import ast::ast as *;
import prove::terms as *;
import prove::kernel as *;
import prove::blast as *;
import prove::sat as *;

// The blocks, chain blocks and solver steps one body may spend.
pub(package) const STEP_BUDGET: u32 = 4000000;
// The branches of one refutation.
const SPLITS_MAX: u32 = 256;
// The levels of `and`, `or` and `not` that `refuted` reads.
const REFUTE_DEPTH: u32 = 8;
// The steps of one SAT run (watched clauses visited), and how many make one step of the budget.
const SAT_STEPS: u32 = 4000000;
// The SAT steps of an attempt before a split (`lemma_with`).
const SAT_EARLY_STEPS: u32 = 250000;
const SAT_STEP_COST: u32 = 64;
// The cells of one simplex tableau, and the nodes of one branch-and-bound tree.
const LP_CELLS_MAX: usize = 65536;
const NODES_MAX: usize = 256;
// The terms of one congruence closure, its facts, and the nesting of one explanation.
const CC_MAX: usize = 4096;
const FACTS_MAX: usize = 4096;
const DEPTH_MAX: u32 = 64;
// The rows and the equalities one elimination reads.
const ELIM_ROWS_MAX: usize = 128;
const ELIM_EQS_MAX: usize = 32;
// The combination rounds of one branch, the equalities it may test, and the applications it pairs.
const ROUNDS_MAX: u32 = 8;
const TESTS_MAX: u32 = 32;
const APPS_MAX: usize = 512;
// The products one branch and bound may make linear (`fix`).
const FIXES_MAX: usize = 4;
// The rounds of Gomory cuts at the root of one branch and bound, and the cuts of one round (`gomory`).
// The tableau cells a simplex pivot updates for one step of the budget.
const PIVOT_CELLS: usize = 16;
const GOMORY_ROUNDS: u32 = 8;
const GOMORY_CUTS: u32 = 4;

// ---- exact rationals -----------------------------------------------------------------------------

// Whether `a + b` is 0.
fn opposite<const B: usize>(a: Num<B>, b: Num<B>) bool {
    return switch ck(a.checked_add(&b)) {
        Some(s) => s.is_zero(),
        None => false,
    };
}

// `n / d`, reduced, `d > 0`. An operation whose result leaves B bits sets the overflow flag and
// gives 0: the caller then answers "not proved".
struct Q<const B: usize> {
    n: Num<B>,
    d: Num<B>,
}

const fn q_int<const B: usize>(v: Num<B>) Q<B> {
    return Q::<B> { n: v, d: Num::<B>::one() };
}

fn q_make<const B: usize>(n: Num<B>, d: Num<B>, ovf: &mut bool) Q<B> {
    if d == Num::<B>::one() {
        return q_int(n);
    }
    let (an, ad) = (mag(n), mag(d));
    if an.is_none() || ad.is_none() {
        *ovf = true;
        return q_int(Num::<B>::zero());
    }
    let g = gcd(an.unwrap(), ad.unwrap());
    let mut nn = n.div_euclid(&g);
    let mut dd = d.div_euclid(&g);
    if dd.is_negative() {
        let a = ck(Num::<B>::zero().checked_sub(&nn));
        let b = ck(Num::<B>::zero().checked_sub(&dd));
        if a.is_none() || b.is_none() {
            *ovf = true;
            return q_int(Num::<B>::zero());
        }
        nn = a.unwrap();
        dd = b.unwrap();
    }
    return Q::<B> { n: nn, d: dd };
}

fn q_mul_i<const B: usize>(a: Num<B>, b: Num<B>, ovf: &mut bool) Num<B> {
    switch ck(a.checked_mul(&b)) {
        Some(v) => {
            return v;
        },
        None => {
            *ovf = true;
            return Num::<B>::zero();
        },
    }
}

fn q_add_i<const B: usize>(a: Num<B>, b: Num<B>, ovf: &mut bool) Num<B> {
    switch ck(a.checked_add(&b)) {
        Some(v) => {
            return v;
        },
        None => {
            *ovf = true;
            return Num::<B>::zero();
        },
    }
}

fn q_add<const B: usize>(x: Q<B>, y: Q<B>, ovf: &mut bool) Q<B> {
    if x.d == Num::<B>::one() && y.d == Num::<B>::one() {
        return q_int(q_add_i(x.n, y.n, ovf));
    }
    let n = q_add_i(q_mul_i(x.n, y.d, ovf), q_mul_i(y.n, x.d, ovf), ovf);
    let d = q_mul_i(x.d, y.d, ovf);
    if *ovf {
        return q_int(Num::<B>::zero());
    }
    return q_make(n, d, ovf);
}

fn q_neg<const B: usize>(x: Q<B>, ovf: &mut bool) Q<B> {
    return Q::<B> { n: q_mul_i(x.n, wide::<B>(-1), ovf), d: x.d };
}

fn q_sub<const B: usize>(x: Q<B>, y: Q<B>, ovf: &mut bool) Q<B> {
    return q_add(x, q_neg(y, ovf), ovf);
}

fn q_mul<const B: usize>(x: Q<B>, y: Q<B>, ovf: &mut bool) Q<B> {
    if x.n.is_zero() || y.n.is_zero() {
        return q_int(Num::<B>::zero());
    }
    let n = q_mul_i(x.n, y.n, ovf);
    let d = q_mul_i(x.d, y.d, ovf);
    if *ovf {
        return q_int(Num::<B>::zero());
    }
    return q_make(n, d, ovf);
}

// `x / y`, `y` not 0.
fn q_div<const B: usize>(x: Q<B>, y: Q<B>, ovf: &mut bool) Q<B> {
    let n = q_mul_i(x.n, y.d, ovf);
    let d = q_mul_i(x.d, y.n, ovf);
    if *ovf {
        return q_int(Num::<B>::zero());
    }
    return q_make(n, d, ovf);
}

fn q_lt<const B: usize>(x: Q<B>, y: Q<B>, ovf: &mut bool) bool {
    if x.d == y.d {
        return x.n < y.n;
    }
    return q_mul_i(x.n, y.d, ovf) < q_mul_i(y.n, x.d, ovf);
}

// ---- the simplex ---------------------------------------------------------------------------------

// A row of the simplex: `sum(c * atom) + k <= 0` (terms [start, start + len) of `Solver.lpool`), and
// the row of the proof it stands for.
struct LRow<const B: usize> {
    k: Num<B>,
    start: u32,
    len: u32,
    r: RowRef,
}

// An equality of the elimination: `sum(c * atom) + k == 0` (terms [start, start + len) of
// `Solver.epool`), as the two rows `pos` (`... <= 0`) and `neg` (its negation `<= 0`).
struct ERow<const B: usize> {
    k: Num<B>,
    start: u32,
    len: u32,
    pos: RowRef,
    neg: RowRef,
}

// A multiplier of a row in a conflict, before it is made an integer.
struct QMult<const B: usize> {
    q: Q<B>,
    r: RowRef,
}

// The outcomes of `Lp::check` and of a branch and bound.
const L_FEAS: u8 = 0;
const L_CONFLICT: u8 = 1;
const L_ABORT: u8 = 2;

// A simplex in the bounded-variable form. The variables are the atoms [0, na) and one slack per row
// [na, nv), the slack the row's linear form, bounded above by the row's constant. Each tableau row
// expresses its basic variable as a sum over the nonbasic ones; a nonbasic variable sits within its
// bounds, a basic one may not, and `check` pivots until each one does or a row proves that it cannot.
struct Lp<const B: usize> {
    na: usize,
    nv: usize,
    nr: usize,
    atom: Vector<u32>,
    ix: Map<u32, u32>, // atom term -> variable
    lo: Vector<Num<B>>,
    hi: Vector<Num<B>>,
    has_lo: Vector<bool>,
    has_hi: Vector<bool>,
    lo_r: Vector<RowRef>,
    hi_r: Vector<RowRef>,
    val: Vector<Q<B>>,
    row_of: Vector<u32>, // a variable's tableau row, NONE when it is nonbasic
    var_of: Vector<u32>, // a tableau row's basic variable
    tab: Vector<Q<B>>, // nr x nv
    expl: Vector<QMult<B>>, // the last conflict
    ovf: bool,
    ovf_seen: bool, // a load since `Solver::clear_overflow` ran out of bits
    pivots: u32,
}

const NO_ROW: RowRef = RowRef { i: NONE, kind: RW_IN };

extend<const B: usize> Lp<B> {
    fn new() Lp<B> {
        return Lp::<B> {
            na: 0,
            nv: 0,
            nr: 0,
            atom: Vector::<u32>::new(),
            ix: Map::<u32, u32>::new(),
            lo: Vector::<Num<B>>::new(),
            hi: Vector::<Num<B>>::new(),
            has_lo: Vector::<bool>::new(),
            has_hi: Vector::<bool>::new(),
            lo_r: Vector::<RowRef>::new(),
            hi_r: Vector::<RowRef>::new(),
            val: Vector::<Q<B>>::new(),
            row_of: Vector::<u32>::new(),
            var_of: Vector::<u32>::new(),
            tab: Vector::<Q<B>>::new(),
            expl: Vector::<QMult<B>>::new(),
            ovf: false,
            ovf_seen: false,
            pivots: 0,
        };
    }

    // Set up the rows `rows` (terms in `pool`). False when the tableau is over its bound.
    fn load(self: &mut Self, tm: &Terms<B>, rows: &Vector<LRow<B>>, pool: &Vector<LinTerm<B>>) bool {
        self.atom.clear();
        self.ix.clear();
        for j in 0..pool.len() {
            let t = pool[j].atom;
            if !self.ix.contains_key(&t) {
                self.ix.insert(t, self.atom.len() as u32);
                self.atom.push(t);
            }
        }
        self.na = self.atom.len();
        self.nr = rows.len();
        self.nv = self.na + self.nr;
        if self.nr * self.nv > LP_CELLS_MAX {
            return false;
        }
        self.ovf_seen = self.ovf_seen || self.ovf;
        self.ovf = false;
        self.pivots = 0;
        self.lo.clear();
        self.hi.clear();
        self.has_lo.clear();
        self.has_hi.clear();
        self.lo_r.clear();
        self.hi_r.clear();
        self.val.clear();
        self.row_of.clear();
        self.var_of.clear();
        self.tab.clear();
        for j in 0..self.na {
            let t = self.atom[j];
            let lo = tm.low(t);
            let hi = tm.high(t);
            let l = lo.unwrap_or(Num::<B>::zero());
            let h = hi.unwrap_or(Num::<B>::zero());
            self.lo.push(l);
            self.hi.push(h);
            self.has_lo.push(lo.is_some());
            self.has_hi.push(hi.is_some());
            // A start inside the bounds, as near 0 as they allow.
            let v = if lo.is_some() && Num::<B>::zero() < l {
                l
            } else if hi.is_some() && h.is_negative() {
                h
            } else {
                Num::<B>::zero()
            };
            self.val.push(q_int(v));
            self.lo_r.push(RowRef { i: t, kind: RW_LO });
            self.hi_r.push(RowRef { i: t, kind: RW_HI });
            self.row_of.push(NONE);
        }
        for r in 0..self.nr {
            let x = rows[r];
            self.lo.push(Num::<B>::zero());
            self.hi.push(Num::<B>::zero() - x.k);
            self.has_lo.push(false);
            self.has_hi.push(true);
            self.lo_r.push(NO_ROW);
            self.hi_r.push(x.r);
            self.row_of.push(r as u32);
            self.var_of.push((self.na + r) as u32);
            for _j in 0..self.nv {
                self.tab.push(q_int(Num::<B>::zero()));
            }
            let mut s = q_int(Num::<B>::zero());
            for j in x.start..x.start + x.len {
                let e = pool[j as usize];
                let v = (*self.ix.get(&e.atom).unwrap()) as usize;
                self.tab.set(r * self.nv + v, q_int(e.c));
                s = q_add(s, q_mul(q_int(e.c), self.val[v], &mut self.ovf), &mut self.ovf);
            }
            self.val.push(s);
        }
        return !self.ovf;
    }

    const fn at(self: &Self, r: usize, j: usize) Q<B> {
        return self.tab[r * self.nv + j];
    }

    fn below(self: &mut Self, j: usize) bool {
        return self.has_lo[j] && q_lt(self.val[j], q_int(self.lo[j]), &mut self.ovf);
    }

    fn above(self: &mut Self, j: usize) bool {
        return self.has_hi[j] && q_lt(q_int(self.hi[j]), self.val[j], &mut self.ovf);
    }

    // Pivot until every basic variable is within its bounds (L_FEAS), a row shows that one cannot be
    // (L_CONFLICT, its rows in `expl`), or `budget` pivots or B bits run out (L_ABORT).
    fn check(self: &mut Self, budget: u32) u8 {
        for _p in 0..budget {
            if self.ovf {
                return L_ABORT;
            }
            // Bland's rule: the smallest variable out of its bounds, then the smallest one that can move.
            let mut b = NONE;
            let mut low = false;
            for r in 0..self.nr {
                let v = self.var_of[r];
                if v < b {
                    if self.below(v as usize) {
                        b = v;
                        low = true;
                    } else if self.above(v as usize) {
                        b = v;
                        low = false;
                    }
                }
            }
            if b == NONE {
                return pick(self.ovf, L_ABORT, L_FEAS);
            }
            let r = self.row_of[b as usize] as usize;
            let mut enter = NONE;
            for j in 0..self.nv {
                if self.row_of[j] != NONE {
                    continue;
                }
                let a = self.at(r, j);
                if a.n.is_zero() {
                    continue;
                }
                let up = a.n.is_negative() != low;
                let room = if up {
                    !self.has_hi[j] || q_lt(self.val[j], q_int(self.hi[j]), &mut self.ovf)
                } else {
                    !self.has_lo[j] || q_lt(q_int(self.lo[j]), self.val[j], &mut self.ovf)
                };
                if room {
                    enter = j as u32;
                    break;
                }
            }
            if enter == NONE {
                self.explain(r, b as usize, low);
                return pick(self.ovf, L_ABORT, L_CONFLICT);
            }
            let target = q_int(
                if low {
                    self.lo[b as usize]
                } else {
                    self.hi[b as usize]
                },
            );
            self.pivot_to(r, enter as usize, target);
            self.pivots += 1;
        }
        return L_ABORT;
    }

    // The conflict of row `r`, whose basic variable `b` is below (`low`) or above its bound while each
    // nonbasic variable of the row sits at the bound that keeps it there: that bound of `b` with
    // multiplier 1, and the bound of each such variable with the absolute value of its coefficient.
    // Their sum cancels every atom (the row is an identity) and leaves the gap, above 0.
    fn explain(self: &mut Self, r: usize, b: usize, low: bool) {
        self.expl.clear();
        self.expl.push(
            QMult::<B> {
                q: q_int(Num::<B>::one()),
                r: if low {
                    self.lo_r[b]
                } else {
                    self.hi_r[b]
                },
            },
        );
        for j in 0..self.nv {
            if self.row_of[j] != NONE {
                continue;
            }
            let a = self.at(r, j);
            if a.n.is_zero() {
                continue;
            }
            let pos = !a.n.is_negative();
            let m = if pos {
                a
            } else {
                q_neg(a, &mut self.ovf)
            };
            // Below: a positive coefficient holds `j` at its upper bound; above: at its lower one.
            self.expl.push(
                QMult::<B> {
                    q: m,
                    r: if pos == low {
                        self.hi_r[j]
                    } else {
                        self.lo_r[j]
                    },
                },
            );
        }
    }

    // Set basic variable of row `r` to `v` through nonbasic `j`, then swap them.
    fn pivot_to(self: &mut Self, r: usize, j: usize, v: Q<B>) {
        let b = self.var_of[r] as usize;
        let a = self.at(r, j);
        let theta = q_div(q_sub(v, self.val[b], &mut self.ovf), a, &mut self.ovf);
        self.val.set(b, v);
        self.val.set(j, q_add(self.val[j], theta, &mut self.ovf));
        for r2 in 0..self.nr {
            if r2 == r {
                continue;
            }
            let c = self.at(r2, j);
            if !c.n.is_zero() {
                let w = self.var_of[r2] as usize;
                self.val.set(w, q_add(self.val[w], q_mul(c, theta, &mut self.ovf), &mut self.ovf));
            }
        }
        // b = a * x_j + sum c_k x_k, so x_j = b / a - sum (c_k / a) x_k.
        let inv = q_div(q_int(Num::<B>::one()), a, &mut self.ovf);
        let nv = self.nv;
        for k in 0..nv {
            let c = self.tab[r * nv + k];
            if k == j || c.n.is_zero() {
                self.tab.set(r * nv + k, q_int(Num::<B>::zero()));
                continue;
            }
            self.tab.set(r * nv + k, q_neg(q_mul(c, inv, &mut self.ovf), &mut self.ovf));
        }
        self.tab.set(r * nv + b, inv);
        for r2 in 0..self.nr {
            if r2 == r {
                continue;
            }
            let c = self.tab[r2 * nv + j];
            if c.n.is_zero() {
                continue;
            }
            self.tab.set(r2 * nv + j, q_int(Num::<B>::zero()));
            for k in 0..nv {
                let e = self.tab[r * nv + k];
                if !e.n.is_zero() {
                    self.tab.set(r2 * nv + k, q_add(self.tab[r2 * nv + k], q_mul(c, e, &mut self.ovf), &mut self.ovf));
                }
            }
        }
        self.var_of.set(r, j as u32);
        self.row_of.set(j, r as u32);
        self.row_of.set(b, NONE);
    }

    // Move nonbasic `j` to `v`, and the basic variables with it.
    fn shift(self: &mut Self, j: usize, v: Q<B>) {
        let d = q_sub(v, self.val[j], &mut self.ovf);
        for r in 0..self.nr {
            let c = self.at(r, j);
            if !c.n.is_zero() {
                let w = self.var_of[r] as usize;
                self.val.set(w, q_add(self.val[w], q_mul(c, d, &mut self.ovf), &mut self.ovf));
            }
        }
        self.val.set(j, v);
    }

    // Bound atom `j` by `v` from above (`upper`) or below, for reason `r`.
    fn bound(self: &mut Self, j: usize, upper: bool, v: Num<B>, r: RowRef) {
        if upper {
            self.hi.set(j, v);
            self.has_hi.set(j, true);
            self.hi_r.set(j, r);
        } else {
            self.lo.set(j, v);
            self.has_lo.set(j, true);
            self.lo_r.set(j, r);
        }
        if self.row_of[j] == NONE && (upper && self.above(j) || !upper && self.below(j)) {
            self.shift(j, q_int(v));
        }
    }

    // A row over the atoms of `terms[0, n)` with an unbounded slack, basic in the new last tableau
    // row: the slack's variable, or NONE when an atom is not the simplex's or the tableau is over its
    // bound.
    fn add_row(self: &mut Self, terms: &Vector<LinTerm<B>>, n: usize) u32 {
        let nv0 = self.nv;
        if (self.nr + 1) * (nv0 + 1) > LP_CELLS_MAX {
            return NONE;
        }
        for j in 0..n {
            if !self.ix.contains_key(&terms[j].atom) {
                return NONE;
            }
        }
        let mut tab = Vector::<Q<B>>::with_capacity((self.nr + 1) * (nv0 + 1));
        for r in 0..self.nr {
            for k in 0..nv0 {
                tab.push(self.tab[r * nv0 + k]);
            }
            tab.push(q_int(Num::<B>::zero()));
        }
        let base = tab.len();
        for _k in 0..nv0 + 1 {
            tab.push(q_int(Num::<B>::zero()));
        }
        // Over the nonbasic variables: a basic atom contributes its tableau row.
        let mut s = q_int(Num::<B>::zero());
        for j in 0..n {
            let e = terms[j];
            let v = (*self.ix.get(&e.atom).unwrap()) as usize;
            let c = q_int(e.c);
            s = q_add(s, q_mul(c, self.val[v], &mut self.ovf), &mut self.ovf);
            let rv = self.row_of[v];
            if rv == NONE {
                tab.set(base + v, q_add(tab[base + v], c, &mut self.ovf));
                continue;
            }
            for k in 0..nv0 {
                let x = self.tab[rv as usize * nv0 + k];
                if !x.n.is_zero() {
                    tab.set(base + k, q_add(tab[base + k], q_mul(c, x, &mut self.ovf), &mut self.ovf));
                }
            }
        }
        self.tab = tab;
        self.nv = nv0 + 1;
        self.nr += 1;
        self.lo.push(Num::<B>::zero());
        self.hi.push(Num::<B>::zero());
        self.has_lo.push(false);
        self.has_hi.push(false);
        self.lo_r.push(NO_ROW);
        self.hi_r.push(NO_ROW);
        self.val.push(s);
        self.row_of.push((self.nr - 1) as u32);
        self.var_of.push(nv0 as u32);
        return nv0 as u32;
    }
}

// The bounds of an atom before a split, to restore after its subtree.
struct Frame<const B: usize> {
    lo: Num<B>,
    hi: Num<B>,
    lo_r: RowRef,
    hi_r: RowRef,
    node: u32,
    j: u32,
    has_lo: bool,
    has_hi: bool,
    right: bool,
}

// An operand of a product that branch and bound sets to a value: its simplex variable and the value.
struct Fix<const B: usize> {
    j: u32,
    c: Num<B>,
}

// What `fix` did at an integer model: nothing, a product's rows set, or a split to make.
const FX_NONE: u8 = 0;
const FX_ROWS: u8 = 1;
const FX_SPLIT: u8 = 2;

// ---- congruence closure --------------------------------------------------------------------------

// Why two terms of the closure were merged (`Edge.kind`).
const E_IN: u8 = 0; // `p`: the branch's equality
const E_CONG: u8 = 1; // one operation over merged operands
const E_ARITH: u8 = 2; // trees `p` (`u < v`) and `q` (`v < u`) refute the rows

// A merge, between the closure's terms `u` and `v` (not their classes): the edges form a forest whose
// paths explain each equality.
struct Edge {
    u: u32,
    v: u32,
    p: u32,
    q: u32,
    kind: u8,
}

// ---- the branches ----------------------------------------------------------------------------------

// One branch of a refutation: the formulas still to split (`term << 1 | polarity`) and the theory
// literals it states (`blast::tlit`).
struct Branch {
    todo: Vector<u64>,
    lits: Vector<u64>,
    // The formulas that split the branch, put off until the theories fail without them (`close`), and
    // the literal count of the last such attempt.
    split: Vector<u64>,
    tried: usize,
    // The goal's first literal, or NONE_LIT: the bits of the literals that share its unknowns decide the
    // branch (`Solver::cone`).
    root: u64,
}

const NONE_LIT: u64 = 0xFFFFFFFFFFFFFFFF;

extend Branch {
    fn copy(self: &Self) Branch {
        return Branch {
            todo: self.todo.clone(),
            lits: self.lits.clone(),
            split: self.split.clone(),
            tried: self.tried,
            root: self.root,
        };
    }

    // Adds literal `l`, the goal's (`from_goal`) first as the root.
    fn push_lit(self: &mut Self, l: u64, from_goal: bool) {
        if from_goal && self.root == NONE_LIT {
            self.root = l;
        }
        self.lits.push(l);
    }
}

const fn pair(a: u32, b: u32) u64 {
    return a as u64 << 32 | b as u64;
}

pub(package) struct Solver<const B: usize> {
    pub(package) steps: u32, // the steps spent, against `STEP_BUDGET` with the walk's
    // The steps a check may reach: STEP_BUDGET, or fewer for a stage that rarely proves (`Prover::holds_in`).
    pub(package) limit: u32,
    // Whether a number past B bits that the rows of small numbers do not avoid ends the check (`refute`):
    // the wide prover proves the body again (`Prover::oblige`). `gave_up` once it did.
    pub(package) stop_on_ovf: bool,
    pub(package) gave_up: bool,
    // The integer model of the last branch no solver refuted: atom << 32 | its index in `mval`.
    pub(package) model: Vector<u32>,
    pub(package) mval: Vector<Num<B>>,
    lin: Vector<LinTerm<B>>,
    stack: Vector<LinTerm<B>>,
    lrows: Vector<LRow<B>>,
    lpool: Vector<LinTerm<B>>,
    lp: Lp<B>,
    frames: Vector<Frame<B>>,
    fixes: Vector<Fix<B>>, // the operands `fix` set to a value in this branch and bound
    gden: Vector<Num<B>>, // `gomory_row`'s denominators
    pf: Proof<B>,
    kn: Kernel<B>,
    sat: Sat,
    bvisit: Map<u32, bool>,
    uf: Map<u32, u32>, // the sets of unknowns of `cone`, each one's parent
    ufirst: Vector<u32>,
    // The closure: its terms, each one's class (`rep`) and the next member of that class (a cycle),
    // the operands of each term and the terms using each one as an operand (both [start, end) lists),
    // the classes of the applications by signature, the merges waiting and done, and the facts that
    // explain equalities already.
    cc_on: bool,
    cc_term: Vector<u32>,
    cc_ix: Map<u32, u32>,
    rep: Vector<u32>,
    next: Vector<u32>,
    size: Vector<u32>,
    ostart: Vector<u32>,
    olist: Vector<u32>,
    ustart: Vector<u32>,
    ulist: Vector<u32>,
    sig: Map<u64, u32>,
    pend: Vector<Edge>,
    edges: Vector<Edge>,
    ehead: Vector<u32>,
    enext: Vector<u32>,
    memo: Map<u64, u32>,
    eqf: Vector<u32>, // the facts whose equalities the arithmetic takes as rows
    eqk: Map<u64, bool>, // their pairs
    tested: Map<u64, bool>,
    ops: Vector<u32>,
    seen: Vector<u32>, // the explanation search: each term's edge to its parent, stamped by `now`
    sedge: Vector<u32>,
    now: u32,
    queue: Vector<u32>,
    members: Vector<u32>,
    ratoms: Map<u32, bool>, // the atoms of the branch's rows
    // The elimination: its equalities, and the cuts it made for the current rows (`cut_for`: the
    // equality facts they read, NONE when none were made), as simplex rows.
    erows: Vector<ERow<B>>,
    epool: Vector<LinTerm<B>>,
    cut_for: u32,
    crows: Vector<LRow<B>>,
    cpool: Vector<LinTerm<B>>,
}

extend<const B: usize> Solver<B> {
    pub(package) fn new() Solver<B> {
        return Solver::<B> {
            steps: 0,
            limit: STEP_BUDGET,
            stop_on_ovf: false,
            gave_up: false,
            model: Vector::<u32>::new(),
            mval: Vector::<Num<B>>::new(),
            lin: Vector::<LinTerm<B>>::new(),
            stack: Vector::<LinTerm<B>>::new(),
            lrows: Vector::<LRow<B>>::new(),
            lpool: Vector::<LinTerm<B>>::new(),
            lp: Lp::<B>::new(),
            frames: Vector::<Frame<B>>::new(),
            fixes: Vector::<Fix<B>>::new(),
            gden: Vector::<Num<B>>::new(),
            pf: Proof::<B>::new(),
            kn: Kernel::<B>::new(),
            sat: Sat::new(),
            bvisit: Map::<u32, bool>::new(),
            uf: Map::<u32, u32>::new(),
            ufirst: Vector::<u32>::new(),
            cc_on: false,
            cc_term: Vector::<u32>::new(),
            cc_ix: Map::<u32, u32>::new(),
            rep: Vector::<u32>::new(),
            next: Vector::<u32>::new(),
            size: Vector::<u32>::new(),
            ostart: Vector::<u32>::new(),
            olist: Vector::<u32>::new(),
            ustart: Vector::<u32>::new(),
            ulist: Vector::<u32>::new(),
            sig: Map::<u64, u32>::new(),
            pend: Vector::<Edge>::new(),
            edges: Vector::<Edge>::new(),
            ehead: Vector::<u32>::new(),
            enext: Vector::<u32>::new(),
            memo: Map::<u64, u32>::new(),
            eqf: Vector::<u32>::new(),
            eqk: Map::<u64, bool>::new(),
            tested: Map::<u64, bool>::new(),
            ops: Vector::<u32>::new(),
            seen: Vector::<u32>::new(),
            sedge: Vector::<u32>::new(),
            now: 0,
            queue: Vector::<u32>::new(),
            members: Vector::<u32>::new(),
            ratoms: Map::<u32, bool>::new(),
            erows: Vector::<ERow<B>>::new(),
            epool: Vector::<LinTerm<B>>::new(),
            cut_for: NONE,
            crows: Vector::<LRow<B>>::new(),
            cpool: Vector::<LinTerm<B>>::new(),
        };
    }

    const fn spend(self: &mut Self, n: u32) bool {
        self.steps = self.steps.saturating_add(n);
        return self.steps <= self.limit && !self.gave_up;
    }

    // Whether the hypotheses `hyps` imply `goal`: the hypotheses and the negated goal have no integer
    // model. Each formula splits into branches; each branch closes on a contradiction of its boolean
    // literals, or its theory literals are a lemma: the theory solvers refute them (`refute`), or, with
    // `bits`, a SAT refutation of their bits does when they hold a bit operation. Then the skeleton of
    // the formulas and the lemmas' clauses must have no model: the kernel checks that the split covers
    // every case.
    // Whether a simplex ran out of the numbers' bits since `clear_overflow`: wider numbers may prove what
    // these did not.
    pub(package) const fn overflowed(self: &Self) bool {
        return self.lp.ovf_seen || self.lp.ovf;
    }

    // A value of the proof that leaves B bits.
    pub(package) const fn note_overflow(self: &mut Self) {
        self.lp.ovf_seen = true;
    }

    pub(package) const fn clear_overflow(self: &mut Self) {
        self.lp.ovf_seen = false;
        self.lp.ovf = false;
    }

    pub(package) fn implies(self: &mut Self, tm: &Terms<B>, hyps: &Vector<u32>, goal: u32, bits: bool) bool {
        self.model.clear();
        self.mval.clear();
        if tm.is_true(goal) {
            return true;
        }
        for j in 0..hyps.len() {
            if hyps[j] == goal || tm.is_false(hyps[j]) {
                return true;
            }
        }
        self.kn.begin();
        let mut b0 = Branch {
            todo: Vector::<u64>::new(),
            lits: Vector::<u64>::new(),
            split: Vector::<u64>::new(),
            tried: 0,
            root: NONE_LIT,
        };
        // Each formula to do: its term, whether the goal's (2), its polarity (1).
        for j in 0..hyps.len() {
            b0.todo.push(hyps[j] as u64 << 2 | 1);
        }
        b0.todo.push(goal as u64 << 2 | 2);
        let mut open = Vector::<Branch>::new();
        open.push(b0);
        let mut splits: u32 = 0;
        for _b in 0..SPLITS_MAX + 1 {
            if open.len() == 0 {
                return self.kn.seal(tm, hyps, goal) && self.covered();
            }
            let mut br = open.pop().unwrap();
            switch self.close(tm, &mut br, &mut open, &mut splits, bits) {
                Some(closed) => {
                    if !closed && !self.lemma(tm, &br.lits, br.root, bits) {
                        return false;
                    }
                },
                None => {
                    return false;
                },
            }
        }
        return false;
    }

    // Whether the theory literals `lits` cannot all hold, by a proof the kernel accepts. With `bits`, a
    // SAT refutation of the bits of the literals that share unknowns with the goal's (`cone`) first,
    // when they hold a bit operation; then the theory solvers.
    fn lemma(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>, root: u64, bits: bool) bool {
        return self.lemma_with(tm, lits, root, bits, true);
    }

    // `lemma`; without `guess` the theories test only the equalities of one linear form (`refute`).
    fn lemma_with(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>, root: u64, bits: bool, guess: bool) bool {
        // The theories first: where they decide, they cost a fraction of a SAT search.
        if let Some(built) = self.kn.state(tm, lits) {
            if self.refute(tm, built.get(), guess) && self.kn.lemma(tm, built, &self.pf) {
                return true;
            }
        }
        let mut sub = Vector::<u64>::new();
        if bits && Solver::<B>::has_bits(tm, lits) {
            self.cone(tm, lits, root, &mut sub);
        }
        if sub.len() != 0 && Solver::<B>::has_bits(tm, &sub) && self.kn.blast(tm, &sub) {
            // An attempt before a split (no `guess`) has a smaller SAT search: its literals often have a
            // model the split then removes, and a search for that model can take all the steps.
            let r = self.sat.solve(&self.kn.bits().cnf, self.sat_budget(pick(guess, SAT_STEPS, SAT_EARLY_STEPS)));
            let _ = self.spend(self.sat.steps / SAT_STEP_COST);
            if r == SAT_REFUTED {
                return self.kn.blast_lemma(&self.sat.proof);
            }
            if r == SAT_MODEL {
                // The goal's literals have a model; the others share none of its unknowns.
                self.sat_model();
            }
        }
        return false;
    }

    // Whether formula `t` taken with polarity `pos` (a side of a split: an `or` that holds, an `and` that
    // fails) is false by the literals `lits` alone: a constant, an atom whose opposite literal they hold, a
    // conjunction with such a part, a disjunction of such parts; `depth` levels deep.
    fn refuted(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>, t: u32, pos: bool, depth: u32) bool {
        let x = tm.at(t);
        if x.op == T_BOOL {
            return x.k == wide::<B>(1) != pos;
        }
        if x.op == T_NOT {
            return depth != 0 && self.refuted(tm, lits, x.a, !pos, depth - 1);
        }
        if x.op == T_AND || x.op == T_OR {
            if depth == 0 {
                return false;
            }
            let ra = self.refuted(tm, lits, x.a, pos, depth - 1);
            // A conjunction that holds (a disjunction that fails) is false where one part is.
            if x.op == T_AND == pos {
                return ra || self.refuted(tm, lits, x.b, pos, depth - 1);
            }
            return ra && self.refuted(tm, lits, x.b, pos, depth - 1);
        }
        // A boolean compared with a constant is that boolean or its negation.
        if (x.op == T_EQ || x.op == T_NE) && tm.is_bool(x.a) && depth != 0 {
            let (k, v) = pick(tm.at(x.b).op == T_BOOL, (x.b, x.a), (x.a, x.b));
            if tm.at(k).op == T_BOOL {
                let same = tm.at(k).k == wide::<B>(1) == (x.op == T_EQ);
                return self.refuted(tm, lits, v, pos == same, depth - 1);
            }
        }
        if (x.op == T_EQ || x.op == T_NE) && (tm.is_bool(x.a) || tm.is_int(x.a) && x.op == T_EQ != pos) {
            return false;
        }
        // `v == k` is false where the literals state `v == k2` for another constant `k2`.
        if (x.op == T_EQ || x.op == T_NE) && x.op == T_EQ == pos && tm.is_int(x.a) {
            let (k, v) = pick(tm.at(x.b).op == T_INT, (x.b, x.a), (x.a, x.b));
            if tm.at(k).op == T_INT && tm.at(v).op != T_INT {
                for j in 0..lits.len() {
                    let l = lits[j];
                    if (l >> 1 & 3) != SEL_ATOM {
                        continue;
                    }
                    let y = tm.at((l >> 3) as u32);
                    if y.op == T_EQ != ((l & 1) == 1) || y.op != T_EQ && y.op != T_NE {
                        continue;
                    }
                    let (k2, v2) = pick(tm.at(y.b).op == T_INT, (y.b, y.a), (y.a, y.b));
                    if v2 == v && tm.at(k2).op == T_INT && tm.at(k2).k != tm.at(k).k {
                        // A lemma the kernel accepts, for the skeleton (`covered`).
                        let mut two = Vector::<u64>::with_capacity(2);
                        two.push(l);
                        two.push(tlit(t, SEL_ATOM, pos));
                        return self.lemma_with(tm, &two, NONE_LIT, false, false);
                    }
                }
            }
        }
        // An order its operands' types decide: `256 <= b` for a byte `b` is false.
        if (x.op == T_LT || x.op == T_LE) && tm.is_int(x.a) && tm.is_int(x.b) {
            let strict = x.op == T_LT;
            if pos {
                // False where `a`'s least value exceeds (or reaches) `b`'s greatest.
                if let Some(al) = tm.low(x.a) {
                    if let Some(bh) = tm.high(x.b) {
                        if bh < al || strict && bh == al {
                            return true;
                        }
                    }
                }
            } else if let Some(ah) = tm.high(x.a) {
                if let Some(bl) = tm.low(x.b) {
                    if ah < bl || !strict && ah == bl {
                        return true;
                    }
                }
            }
        }
        let want = tlit(t, SEL_ATOM, !pos);
        for j in 0..lits.len() {
            if lits[j] == want {
                return true;
            }
        }
        return false;
    }

    // Whether the skeleton and the lemmas have no model, by a proof the kernel accepts.
    fn covered(self: &mut Self) bool {
        let r = self.sat.solve(self.kn.skeleton(), self.sat_budget(SAT_STEPS));
        let _ = self.spend(self.sat.steps / SAT_STEP_COST);
        return r == SAT_REFUTED && self.kn.covered(&self.sat.proof);
    }

    // The SAT steps one run may take: SAT_STEPS, and no more than the steps left.
    const fn sat_budget(self: &Self, cap: u32) u32 {
        return cap.min((self.limit + 1 - self.steps.min(self.limit)).saturating_mul(SAT_STEP_COST));
    }

    // The literals of `lits` that share an unknown with `root` (the goal's first, `Branch.root`; the
    // first literal when the goal has none), directly or through other literals: the rest hold none of
    // their unknowns, so they cannot help refute it. A union of the unknowns of each literal.
    fn cone(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>, root: u64, out: &mut Vector<u64>) {
        out.clear();
        self.uf.clear();
        self.ufirst.clear();
        let mut r = 0usize;
        for j in 0..lits.len() {
            let f = self.unknowns(tm, (lits[j] >> 3) as u32);
            self.ufirst.push(f);
            if lits[j] == root {
                r = j;
            }
        }
        let r0 = self.find(self.ufirst[r]);
        for j in 0..lits.len() {
            if j == r || r0 != NONE && self.find(self.ufirst[j]) == r0 {
                out.push(lits[j]);
            }
        }
    }

    // Join the unknowns under formula `t` (the terms the bits leave free) into one set: one of them,
    // NONE when there is none.
    fn unknowns(self: &mut Self, tm: &Terms<B>, t: u32) u32 {
        self.bvisit.clear();
        self.queue.clear();
        self.queue.push(t);
        let mut first = NONE;
        for _s in 0..LIN_MAX * 16 {
            if self.queue.len() == 0 {
                break;
            }
            let u = self.queue.pop().unwrap();
            if self.bvisit.contains_key(&u) {
                continue;
            }
            self.bvisit.insert(u, true);
            let x = tm.at(u);
            if x.op == T_INT || x.op == T_BOOL {
                continue;
            }
            let unary = x.op == T_NEG || x.op == T_BNOT || x.op == T_CAST || x.op == T_NOT;
            if x.op >= T_ADD && x.op <= T_CAST || x.op >= T_LT && x.op <= T_OR || x.op == T_ORD {
                self.queue.push(x.a);
                if !unary {
                    self.queue.push(x.b);
                }
                continue;
            }
            if first == NONE {
                first = u;
            } else {
                let a = self.find(first);
                let b = self.find(u);
                if a != b {
                    self.uf.insert(b, a);
                }
            }
        }
        return first;
    }

    // The set of unknown `u` (`uf`): its root, NONE for NONE.
    fn find(self: &mut Self, u: u32) u32 {
        if u == NONE {
            return NONE;
        }
        let mut x = u;
        for _k in 0..self.uf.len() + 1 {
            let p = switch self.uf.get(&x) {
                Some(v) => *v,
                None => {
                    self.uf.insert(x, x);
                    x
                },
            };
            if p == x {
                break;
            }
            let g = *self.uf.get(&p).unwrap();
            self.uf.insert(x, g);
            x = g;
        }
        return x;
    }

    // Whether a literal of `lits` holds an operation the bits define and the arithmetic does not
    // (`Terms.bitty`).
    const fn has_bits(tm: &Terms<B>, lits: &Vector<u64>) bool {
        for j in 0..lits.len() {
            if tm.bitty[(lits[j] >> 3) as usize] {
                return true;
            }
        }
        return false;
    }

    // The values of the integer unknowns in the SAT model of the bits, as the model.
    fn sat_model(self: &mut Self) {
        self.model.clear();
        self.mval.clear();
        let bl = self.kn.bits();
        let mut v = Vector::<u32>::new();
        for j in 0..bl.leaves.len() {
            let t = bl.leaves[j];
            bl.leaf_bits(t, &mut v);
            let n = v.len();
            let mut x = Num::<B>::zero();
            for i in 0..n {
                x = x + x + wide::<B>(self.bit_of(v[n - 1 - i]) as i64);
            }
            if n > 0 && self.bit_of(v[n - 1]) {
                x = x - Num::<B>::one().shl(n);
            }
            self.model.push(t);
            self.mval.push(x);
        }
    }

    // Whether literal `l` holds in the SAT model.
    const fn bit_of(self: &Self, l: u32) bool {
        return l == L_TRUE || l != L_FALSE && self.sat.holds(l >> 1) == ((l & 1) == 0);
    }

    // Split the formulas of `br` until none is left: Some(true) when a contradiction of its boolean
    // literals closed it, Some(false) when its theory literals remain to refute, None past the split
    // bound.
    fn close(self: &mut Self, tm: &Terms<B>, br: &mut Branch, open: &mut Vector<Branch>, splits: &mut u32, bits: bool) Option<
        bool
    > {
        for _s in 0..LIN_MAX {
            let mut deferred = false;
            if br.todo.len() == 0 {
                if br.split.len() == 0 {
                    return Some(false);
                }
                // The literals so far may conflict already: then no split is needed. The model's guesses
                // wait for the leaves.
                if br.lits.len() > br.tried {
                    br.tried = br.lits.len();
                    if self.lemma_with(tm, &br.lits, br.root, bits, false) {
                        return Some(true);
                    }
                }
                // The goal's own cases first: its literals are what the hypotheses' cases close against.
                let mut at = br.split.len() - 1;
                for j in 0..br.split.len() {
                    if (br.split[j] & 2) != 0 {
                        at = j;
                    }
                }
                br.todo.push(br.split.remove(at).unwrap());
                deferred = true;
            }
            let e = br.todo.pop().unwrap();
            let t = (e >> 2) as u32;
            let g = e & 2;
            let pos = (e & 1) != 0;
            let x = tm.at(t);
            let splitting = (x.op == T_AND || x.op == T_OR) && !(x.op == T_AND && pos || x.op == T_OR && !pos) || (x.op == T_EQ || x.op == T_NE) && (tm.is_int(
                x.a,
            ) && tm.is_int(x.b) && x.op == T_EQ != pos || tm.is_bool(x.a) && tm.is_bool(x.b));
            // Every split waits for the literals: a side they already refute needs none (`refuted`).
            if splitting && !deferred {
                br.split.push(e);
                continue;
            }
            if x.op == T_BOOL {
                if x.k == wide::<B>(1) != pos {
                    return Some(true);
                }
            } else if x.op == T_NOT {
                br.todo.push(x.a as u64 << 2 | g | (!pos) as u64);
            } else if x.op == T_AND && pos || x.op == T_OR && !pos {
                br.todo.push(x.a as u64 << 2 | g | pos as u64);
                br.todo.push(x.b as u64 << 2 | g | pos as u64);
            } else if x.op == T_AND || x.op == T_OR {
                // A side the branch's literals already make true satisfies the formula, which then states
                // nothing the branch does not: no split.
                if self.refuted(tm, &br.lits, x.a, !pos, REFUTE_DEPTH) || self.refuted(
                    tm,
                    &br.lits,
                    x.b,
                    !pos,
                    REFUTE_DEPTH,
                ) {
                    continue;
                }
                // A side the branch's literals already make false leaves the other alone: no split.
                if self.refuted(tm, &br.lits, x.a, pos, REFUTE_DEPTH) {
                    br.todo.push(x.b as u64 << 2 | g | pos as u64);
                    continue;
                }
                if self.refuted(tm, &br.lits, x.b, pos, REFUTE_DEPTH) {
                    br.todo.push(x.a as u64 << 2 | g | pos as u64);
                    continue;
                }
                *splits += 1;
                if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                    return None;
                }
                let mut other = br.copy();
                other.todo.push(x.b as u64 << 2 | g | pos as u64);
                open.push(other);
                br.todo.push(x.a as u64 << 2 | g | pos as u64);
            } else if (x.op == T_EQ || x.op == T_NE) && tm.is_int(x.a) && tm.is_int(x.b) && x.op == T_EQ != pos {
                // A disequality of integers: one of its orders.
                *splits += 1;
                if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                    return None;
                }
                let mut other = br.copy();
                other.push_lit(tlit(t, SEL_GT, true), g != 0);
                open.push(other);
                br.push_lit(tlit(t, SEL_LT, true), g != 0);
            } else if (x.op == T_EQ || x.op == T_NE) && tm.is_bool(x.a) && tm.is_bool(x.b) {
                // Equal booleans: both hold or neither does.
                *splits += 1;
                if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                    return None;
                }
                let same = x.op == T_EQ == pos;
                // The equality stays a literal of both sides: the closure merges the two booleans, so
                // that `f(a)` and `f(b)` are one value (the skeleton spells it by its operands).
                if same {
                    br.push_lit(tlit(t, SEL_ATOM, pos), g != 0);
                }
                let mut other = br.copy();
                other.todo.push(x.a as u64 << 2 | g);
                other.todo.push(x.b as u64 << 2 | g | (!same) as u64);
                open.push(other);
                br.todo.push(x.a as u64 << 2 | g | 1);
                br.todo.push(x.b as u64 << 2 | g | same as u64);
            } else {
                // An atom: closes against its own negation.
                let want = tlit(t, SEL_ATOM, !pos);
                for j in 0..br.lits.len() {
                    if br.lits[j] == want {
                        return Some(true);
                    }
                }
                br.push_lit(tlit(t, SEL_ATOM, pos), g != 0);
            }
        }
        return None;
    }

    // Whether the theory solvers refute what branch `st` states; the proof is in `pf`, for the kernel.
    // When they do not, an integer model they found is kept (`model`).
    fn refute(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, guess: bool) bool {
        if st.rows.len() == 0 && st.eqs.len() == 0 {
            return false;
        }
        self.pf.clear();
        self.cc_on = false;
        self.cut_for = NONE;
        // The atoms of the rows, but of the rows of a stated equality of two atoms: the closure takes
        // that one, and its atoms need no row of the class (`eq_rows`).
        self.ratoms.clear();
        let mut stated = Map::<u64, bool>::new();
        for j in 0..st.eqs.len() {
            stated.insert(st.eqs[j], true);
        }
        for r in 0..st.rows.len() {
            let x = st.rows[r];
            if x.len == 2 && x.k.is_zero() && opposite(st.pool[x.start as usize].c, st.pool[x.start as usize + 1].c) {
                let (u, v) = (st.pool[x.start as usize].atom, st.pool[x.start as usize + 1].atom);
                if stated.contains_key(&pair(u, v)) || stated.contains_key(&pair(v, u)) {
                    continue;
                }
            }
            for j in x.start..x.start + x.len {
                self.ratoms.insert(st.pool[j as usize].atom, true);
            }
        }
        // The atoms of a product's operands too: an equality that fixes one (`a == 0`) reaches the
        // simplex, which then fixes the product (`fix`).
        for j in 0..st.pool.len() {
            let x = tm.at(st.pool[j].atom);
            if x.op != T_MUL || tm.at(x.a).op == T_INT || tm.at(x.b).op == T_INT {
                continue;
            }
            for side in 0..2 {
                self.lin.clear();
                let mut k = Num::<B>::zero();
                if lin_form(tm, pick(side == 0, x.a, x.b), Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) {
                    for q in 0..self.lin.len() {
                        self.ratoms.insert(self.lin[q].atom, true);
                    }
                }
            }
        }
        self.eqf.clear();
        self.eqk.clear();
        self.tested.clear();
        if st.eqs.len() != 0 {
            if !self.cc_build(tm, st) {
                return false;
            }
            for j in 0..st.eqs.len() {
                let e = st.eqs[j];
                let u = *self.cc_ix.get(&((e >> 32) as u32)).unwrap();
                let v = *self.cc_ix.get(&(e as u32)).unwrap();
                self.pend.push(Edge { u: u, v: v, p: j as u32, q: NONE, kind: E_IN });
            }
            switch self.cc_run(tm, st) {
                Some(c) => {
                    if c {
                        return true;
                    }
                },
                None => {
                    return false;
                },
            }
            if self.class_row(tm, st) {
                return true;
            }
        }
        let mut tests: u32 = 0;
        for _round in 0..ROUNDS_MAX {
            if self.cc_on && !self.eq_rows(tm) {
                return false;
            }
            self.rows_of(tm, st, NONE, NONE);
            let upto = self.pf.facts.len() as u32;
            let (mut r, mut root) = self.bb(tm);
            // A number past B bits stops the simplex: the rows of small numbers alone may conflict still
            // (`x <= 1`, `1 <= x`, `x <= 0` beside a row of 2^200), first those below the size whose
            // products fit B bits, then those below a quarter of B bits.
            for shift in [B / 2 - 8, B / 4] {
                if r == L_ABORT && self.lp.ovf && self.keep_small_rows(shift) {
                    let again = self.bb(tm);
                    r = again.0;
                    root = again.1;
                }
            }
            if r == L_ABORT {
                self.gave_up = self.gave_up || self.stop_on_ovf && self.lp.ovf;
                return false;
            }
            if r == L_CONFLICT {
                self.pf.trees.push(Tree { root: root, ha: NONE, hb: NONE, upto: upto });
                self.pf.end = X_LA;
                self.pf.p = (self.pf.trees.len() - 1) as u32;
                return true;
            }
            self.keep_model();
            // An integer model: try the equalities it suggests between the operands of applications.
            if !self.cc_on && !self.cc_build(tm, st) {
                return false;
            }
            // The congruences the build found merge too.
            let mut merged = self.pend.len() != 0;
            let mut cands = Vector::<u64>::new();
            let mut sure = Vector::<bool>::new();
            if !self.suggest(tm, &mut cands, &mut sure) {
                return false;
            }
            // The pairs of one linear form first: the model's guesses only when those merge nothing.
            for pass in 0..2u32 {
                if pass == 1 && (merged || !guess) {
                    break;
                }
                for k in 0..cands.len() {
                    if sure[k] != (pass == 0) || self.tested.contains_key(&cands[k]) {
                        continue;
                    }
                    if tests >= TESTS_MAX {
                        break;
                    }
                    tests += 1;
                    self.tested.insert(cands[k], true);
                    let u = (cands[k] >> 32) as u32;
                    let v = cands[k] as u32;
                    if self.rep[u as usize] == self.rep[v as usize] {
                        continue;
                    }
                    let a = self.cc_term[u as usize];
                    let b = self.cc_term[v as usize];
                    let t1 = self.implied(tm, st, a, b);
                    if t1 == NONE {
                        continue;
                    }
                    let t2 = self.implied(tm, st, b, a);
                    if t2 == NONE {
                        continue;
                    }
                    self.pend.push(Edge { u: u, v: v, p: t1, q: t2, kind: E_ARITH });
                    merged = true;
                }
            }
            if !merged {
                return false;
            }
            switch self.cc_run(tm, st) {
                Some(c) => {
                    if c {
                        return true;
                    }
                },
                None => {
                    return false;
                },
            }
        }
        return false;
    }

    // Whether a row of `st` over atoms of one class, whose coefficients cancel and whose constant is
    // positive (`a < b` with `a == b`), refutes the branch: it and the class's equalities alone, a few
    // rows where the whole branch's may not fit the tableau (`LP_CELLS_MAX`).
    fn class_row(self: &mut Self, tm: &Terms<B>, st: &Stated<B>) bool {
        for r in 0..st.rows.len() {
            let x = st.rows[r];
            if x.len < 2 || !(Num::<B>::zero() < x.k) {
                continue;
            }
            let u0 = switch self.cc_ix.get(&st.pool[x.start as usize].atom) {
                Some(u) => *u,
                None => {
                    continue;
                },
            };
            let mut sum = Num::<B>::zero();
            let mut one = true;
            for j in x.start..x.start + x.len {
                let t = st.pool[j as usize];
                switch ck(sum.checked_add(&t.c)) {
                    Some(s) => sum = s,
                    None => {
                        one = false;
                    },
                }
                switch self.cc_ix.get(&t.atom) {
                    Some(u) => {
                        one = one && self.rep[(*u) as usize] == self.rep[u0 as usize];
                    },
                    None => {
                        one = false;
                    },
                }
            }
            if !one || !sum.is_zero() {
                continue;
            }
            let mut fs = Vector::<u32>::new();
            for j in x.start + 1..x.start + x.len {
                let u = *self.cc_ix.get(&st.pool[j as usize].atom).unwrap();
                let f = if u == u0 {
                    NONE
                } else {
                    self.explain(u0, u, 0)
                };
                if u != u0 && f == NONE {
                    fs.clear();
                    break;
                }
                if f != NONE {
                    fs.push(f);
                }
            }
            if fs.len() == 0 {
                continue;
            }
            self.lrows.clear();
            self.lpool.clear();
            self.lin.clear();
            for j in x.start..x.start + x.len {
                self.lin.push(st.pool[j as usize]);
            }
            self.push_lrow(x.k, RowRef { i: r as u32, kind: RW_IN });
            for j in 0..fs.len() {
                let f = self.pf.facts[fs[j] as usize];
                for d in 0..2 {
                    let (a, b) = pick(d == 0, (f.a, f.b), (f.b, f.a));
                    self.lin.clear();
                    let mut k = Num::<B>::zero();
                    if lin_form(tm, a, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) && lin_form(
                        tm,
                        b,
                        wide::<B>(-1),
                        &mut k,
                        &mut self.lin,
                        &mut self.stack,
                    ) {
                        self.push_lrow(k, RowRef { i: fs[j], kind: pick(d == 0, RW_EQ_LE, RW_EQ_GE) });
                    }
                }
            }
            let upto = self.pf.facts.len() as u32;
            let (res, root) = self.bb(tm);
            if res == L_CONFLICT {
                self.pf.trees.push(Tree { root: root, ha: NONE, hb: NONE, upto: upto });
                self.pf.end = X_LA;
                self.pf.p = (self.pf.trees.len() - 1) as u32;
                return true;
            }
        }
        return false;
    }

    // The tree that refutes the rows with the hypothesis `a < b`, NONE when there is none.
    fn implied(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, a: u32, b: u32) u32 {
        self.rows_of(tm, st, a, b);
        let upto = self.pf.facts.len() as u32;
        let (r, root) = self.bb(tm);
        if r != L_CONFLICT {
            return NONE;
        }
        self.pf.trees.push(Tree { root: root, ha: a, hb: b, upto: upto });
        return (self.pf.trees.len() - 1) as u32;
    }

    // The simplex rows: the branch's, two per equality fact of `eqf`, and the hypothesis `ha < hb`
    // when `ha` is not NONE; each divided by the gcd of its coefficients.
    // Whether `p + q` is `a - b` (or `b - a`) for two atoms `a` and `b` the closure merged.
    fn same_class(self: &Self, p: &LinTerm<B>, q: &LinTerm<B>) bool {
        if !opposite(p.c, q.c) || !(p.c == Num::<B>::one() || q.c == Num::<B>::one()) {
            return false;
        }
        let (u, v) = (self.cc_ix.get(&p.atom), self.cc_ix.get(&q.atom));
        if u.is_none() || v.is_none() {
            return false;
        }
        return self.rep[(*u.unwrap()) as usize] == self.rep[(*v.unwrap()) as usize];
    }

    fn rows_of(self: &mut Self, tm: &Terms<B>, st: &Stated<B>, ha: u32, hb: u32) {
        self.lrows.clear();
        self.lpool.clear();
        for r in 0..st.rows.len() {
            let x = st.rows[r];
            // Half of a stated equality of two atoms of one class: the class's own rows (`eq_rows`)
            // state it, and a second copy only widens the tableau.
            if self.cc_on && x.len == 2 && x.k.is_zero() && self.same_class(
                &st.pool[x.start as usize],
                &st.pool[x.start as usize + 1],
            ) {
                continue;
            }
            self.lin.clear();
            for j in x.start..x.start + x.len {
                self.lin.push(st.pool[j as usize]);
            }
            self.push_lrow(x.k, RowRef { i: r as u32, kind: RW_IN });
        }
        for j in 0..self.eqf.len() {
            let f = self.pf.facts[self.eqf[j] as usize];
            for d in 0..2 {
                let (a, b) = if d == 0 {
                    (f.a, f.b)
                } else {
                    (f.b, f.a)
                };
                self.lin.clear();
                let mut k = Num::<B>::zero();
                if lin_form(tm, a, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) && lin_form(
                    tm,
                    b,
                    wide::<B>(-1),
                    &mut k,
                    &mut self.lin,
                    &mut self.stack,
                ) {
                    self.push_lrow(k, RowRef { i: self.eqf[j], kind: pick(d == 0, RW_EQ_LE, RW_EQ_GE) });
                }
            }
        }
        // The cuts of the equalities among these rows, made once for each set of equality facts.
        if self.cut_for != self.eqf.len() as u32 {
            self.eliminate();
            self.cut_for = self.eqf.len() as u32;
        }
        for j in 0..self.crows.len() {
            let x = self.crows[j];
            let start = self.lpool.len() as u32;
            for q in x.start..x.start + x.len {
                self.lpool.push(self.cpool[q as usize]);
            }
            self.lrows.push(LRow::<B> { k: x.k, start: start, len: x.len, r: x.r });
        }
        if ha != NONE {
            self.lin.clear();
            let mut k = Num::<B>::one();
            if lin_form(tm, ha, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) && lin_form(
                tm,
                hb,
                wide::<B>(-1),
                &mut k,
                &mut self.lin,
                &mut self.stack,
            ) {
                self.push_lrow(k, RowRef { i: NONE, kind: RW_HYP });
            }
        }
    }

    // Integer elimination over the equalities among the simplex rows (two rows of opposite forms):
    // an atom with coefficient 1 or -1 in one equality leaves every other one, each new equality the
    // sum of the old one and a multiple of the first, divided by the gcd of its coefficients. Each new
    // row is a cut (a combination of rows, divided by the gcd), so a gcd that does not divide the
    // constant leaves two cuts that sum to a constant above 0: `x == 2 * y + 1, x == 2 * z` has no
    // integer point, which branch and bound alone would not find within its bounds. The new rows go to
    // `crows`.
    fn eliminate(self: &mut Self) {
        self.crows.clear();
        self.cpool.clear();
        self.erows.clear();
        self.epool.clear();
        let n = self.lrows.len();
        if n > ELIM_ROWS_MAX {
            return;
        }
        for i in 0..n {
            let x = self.lrows[i];
            if x.len == 0 {
                continue;
            }
            for j in i + 1..n {
                let y = self.lrows[j];
                if y.len != x.len || !opposite(x.k, y.k) || self.erows.len() >= ELIM_EQS_MAX {
                    continue;
                }
                let mut opp = true;
                for q in 0..x.len {
                    let a = self.lpool[(x.start + q) as usize];
                    let b = self.lpool[(y.start + q) as usize];
                    opp = opp && a.atom == b.atom && opposite(a.c, b.c);
                }
                if opp {
                    let start = self.epool.len() as u32;
                    for q in x.start..x.start + x.len {
                        self.epool.push(self.lpool[q as usize]);
                    }
                    self.erows.push(ERow::<B> { k: x.k, start: start, len: x.len, pos: x.r, neg: y.r });
                    break;
                }
            }
        }
        let ne = self.erows.len();
        let upto = self.pf.facts.len() as u32;
        let mut changed = Vector::<bool>::with_capacity(ne);
        for _e in 0..ne {
            changed.push(false);
        }
        for e in 0..ne {
            let ex = self.erows[e];
            // The pivot: the first atom of coefficient 1 or -1.
            let mut piv = NONE;
            let mut pc = Num::<B>::zero();
            for q in ex.start..ex.start + ex.len {
                let t = self.epool[q as usize];
                if t.c == Num::<B>::one() || t.c == wide::<B>(-1) {
                    piv = t.atom;
                    pc = t.c;
                    break;
                }
            }
            if piv == NONE {
                continue;
            }
            for f in 0..ne {
                if f == e {
                    continue;
                }
                let fx = self.erows[f];
                let mut c = Num::<B>::zero();
                for q in fx.start..fx.start + fx.len {
                    if self.epool[q as usize].atom == piv {
                        c = self.epool[q as usize].c;
                    }
                }
                if c.is_zero() || !self.spend(1) {
                    continue;
                }
                // f - m * e cancels the pivot: c - m * pc == 0 with pc * pc == 1.
                let mo = if pc.is_negative() {
                    ck(Num::<B>::zero().checked_sub(&c))
                } else {
                    Some(c)
                };
                if mo.is_none() || mag(mo.unwrap()).is_none() {
                    continue;
                }
                let m = mo.unwrap();
                let am = mag(m).unwrap();
                // f.pos + |m| * (the side of e that is `-m * e`), and its negation from f.neg.
                let (sp, sn) = if m.is_negative() {
                    (ex.pos, ex.neg)
                } else {
                    (ex.neg, ex.pos)
                };
                self.lin.clear();
                let mut ok = true;
                for q in fx.start..fx.start + fx.len {
                    self.lin.push(self.epool[q as usize]);
                }
                for q in ex.start..ex.start + ex.len {
                    let t = self.epool[q as usize];
                    switch ck(t.c.checked_mul(&m)) {
                        Some(v) => self.lin.push(LinTerm::<B> { c: Num::<B>::zero() - v, atom: t.atom }),
                        None => {
                            ok = false;
                        },
                    }
                }
                let mut k = fx.k;
                switch ck(ex.k.checked_mul(&m)) {
                    Some(v) => {
                        switch ck(k.checked_sub(&v)) {
                            Some(d) => k = d,
                            None => {
                                ok = false;
                            },
                        }
                    },
                    None => {
                        ok = false;
                    },
                }
                let len0 = self.lin.len();
                let len = switch merge_terms(&mut self.lin, 0, len0) {
                    Some(v) if ok => v,
                    _ => {
                        self.lp.ovf_seen = true;
                        continue;
                    },
                };
                self.lin.truncate(len);
                let cp = self.add_cut(fx.pos, sp, am, upto);
                let cn = self.add_cut(fx.neg, sn, am, upto);
                if cp == NONE || cn == NONE {
                    return;
                }
                let g = switch coef_gcd(&self.lin, 0, len) {
                    Some(x) => x,
                    None => {
                        return;
                    },
                };
                if g.is_zero() || !k.rem_euclid(&g).is_zero() {
                    // No integer point: the two cuts refute the rows by themselves.
                    self.push_cut_rows(cp, cn, k);
                    return;
                }
                for q in 0..len {
                    let t = self.lin[q];
                    self.lin.set(q, LinTerm::<B> { c: t.c.div_euclid(&g), atom: t.atom });
                }
                let start = self.epool.len() as u32;
                self.epool.extend_copy(&self.lin);
                self.erows.set(
                    f,
                    ERow::<B> {
                        k: k.div_euclid(&g),
                        start: start,
                        len: len as u32,
                        pos: RowRef { i: cp, kind: RW_CUT },
                        neg: RowRef { i: cn, kind: RW_CUT },
                    },
                );
                changed.set(f, true);
            }
        }
        for f in 0..ne {
            if !changed[f] {
                continue;
            }
            let fx = self.erows[f];
            for d in 0..2 {
                self.lin.clear();
                for q in fx.start..fx.start + fx.len {
                    let t = self.epool[q as usize];
                    self.lin.push(LinTerm::<B> { c: pick(d == 0, t.c, Num::<B>::zero() - t.c), atom: t.atom });
                }
                let start = self.cpool.len() as u32;
                self.cpool.extend_copy(&self.lin);
                self.crows.push(
                    LRow::<B> {
                        k: pick(d == 0, fx.k, Num::<B>::zero() - fx.k),
                        start: start,
                        len: fx.len,
                        r: pick(d == 0, fx.pos, fx.neg),
                    },
                );
            }
        }
    }

    // The cut `row a + m * row b`, NONE past a bound.
    fn add_cut(self: &mut Self, a: RowRef, b: RowRef, m: Num<B>, upto: u32) u32 {
        if self.pf.cuts.len() >= FACTS_MAX {
            return NONE;
        }
        let ms = self.pf.mults.len() as u32;
        self.pf.mults.push(Mult::<B> { m: Num::<B>::one(), r: a });
        self.pf.mults.push(Mult::<B> { m: m, r: b });
        self.pf.cuts.push(Cut { ms: ms, mn: 2, upto: upto });
        return (self.pf.cuts.len() - 1) as u32;
    }

    // The cuts `cp` and `cn` of an equality `lin + k == 0` whose gcd does not divide `k`, as simplex
    // rows: `lin / g + ceil(k / g) <= 0` and `-lin / g + ceil(-k / g) <= 0`, which sum to 1 <= 0.
    fn push_cut_rows(self: &mut Self, cp: u32, cn: u32, k: Num<B>) {
        let g = switch coef_gcd(&self.lin, 0, self.lin.len()) {
            Some(x) => x,
            None => {
                return;
            },
        };
        let one = Num::<B>::one();
        let gg = pick(g.is_zero(), one, g);
        for d in 0..2 {
            let start = self.cpool.len() as u32;
            for q in 0..self.lin.len() {
                let t = self.lin[q];
                let c = t.c.div_euclid(&gg);
                self.cpool.push(LinTerm::<B> { c: pick(d == 0, c, Num::<B>::zero() - c), atom: t.atom });
            }
            let kk = pick(d == 0, k, Num::<B>::zero() - k);
            let kc = Num::<B>::zero() - (Num::<B>::zero() - kk).div_euclid(&gg);
            self.crows.push(
                LRow::<B> {
                    k: kc,
                    start: start,
                    len: self.lin.len() as u32,
                    r: RowRef { i: pick(d == 0, cp, cn), kind: RW_CUT },
                },
            );
        }
    }

    // The row `lin + k <= 0`, merged and divided by the gcd of its coefficients (its constant rounded
    // up), into the simplex rows. Dropped when a value leaves B bits: fewer rows refute less.
    fn push_lrow(self: &mut Self, k0: Num<B>, r: RowRef) {
        let n0 = self.lin.len();
        let n = switch merge_terms(&mut self.lin, 0, n0) {
            Some(v) => v,
            None => {
                self.lp.ovf_seen = true;
                return;
            },
        };
        let g = switch coef_gcd(&self.lin, 0, n) {
            Some(x) => x,
            None => {
                return;
            },
        };
        let mut k = k0;
        if !g.is_zero() && g != Num::<B>::one() {
            for j in 0..n {
                let x = self.lin[j];
                self.lin.set(j, LinTerm::<B> { c: x.c.div_euclid(&g), atom: x.atom });
            }
            k = Num::<B>::zero() - (Num::<B>::zero() - k0).div_euclid(&g);
        }
        let start = self.lpool.len() as u32;
        for j in 0..n {
            self.lpool.push(self.lin[j]);
        }
        self.lrows.push(LRow::<B> { k: k, start: start, len: n as u32, r: r });
    }

    // Branch and bound over the simplex rows (`lrows`): L_CONFLICT with the root of a tree that
    // refutes them, L_FEAS with an integer model in `lp.val`, or L_ABORT past a bound.
    // Drop the simplex rows that hold a number of at least 2^`shift` in magnitude; whether some rows go
    // and some stay.
    fn keep_small_rows(self: &mut Self, shift: usize) bool {
        let big = Num::<B>::one().shl(shift);
        let nbig = Num::<B>::zero() - big;
        let small = |x: Num<B>| x < big && nbig < x;
        let mut w: usize = 0;
        for i in 0..self.lrows.len() {
            let x = self.lrows[i];
            let mut keep = small(x.k);
            for j in x.start..x.start + x.len {
                keep = keep && small(self.lpool[j as usize].c);
            }
            if keep {
                self.lrows.set(w, x);
                w += 1;
            }
        }
        let dropped = w < self.lrows.len();
        self.lrows.truncate(w);
        return dropped && w != 0;
    }

    fn bb(self: &mut Self, tm: &Terms<B>) (u8, u32) {
        if !self.lp.load(tm, &self.lrows, &self.lpool) {
            return L_ABORT, NONE;
        }
        self.frames.clear();
        self.fixes.clear();
        let mut rounds: u32 = 0;
        let root = self.new_node();
        let mut cur = root;
        let mut made: usize = 1;
        for _it in 0..2 * NODES_MAX + 2 {
            if !self.spend(1) {
                return L_ABORT, NONE;
            }
            // A pivot updates every cell of the tableau: it costs a step per PIVOT_CELLS cells.
            let cost = 1 + (self.lp.nr * self.lp.nv / PIVOT_CELLS) as u32;
            let room = (self.limit + 1 - self.steps.min(self.limit)) / cost + 1;
            let p0 = self.lp.pivots;
            let r = self.lp.check(room);
            let _ = self.spend((self.lp.pivots - p0).saturating_mul(cost));
            if r == L_ABORT {
                return L_ABORT, NONE;
            }
            if r == L_CONFLICT {
                if !self.leaf(cur) {
                    return L_ABORT, NONE;
                }
                // Back to the nearest split whose right side is still open.
                let mut next = NONE;
                for _f in 0..NODES_MAX + 1 {
                    if self.frames.len() == 0 {
                        break;
                    }
                    let f = self.frames[self.frames.len() - 1];
                    self.restore(&f);
                    if f.right {
                        let _ = self.frames.pop();
                        continue;
                    }
                    let last = self.frames.len() - 1;
                    let mut g = f;
                    g.right = true;
                    self.frames.set(last, g);
                    let rt = self.new_node();
                    made += 1;
                    let mut nd = self.pf.nodes[f.node as usize];
                    nd.right = rt;
                    self.pf.nodes.set(f.node as usize, nd);
                    let v1 = nd.v + Num::<B>::one();
                    self.lp.bound(f.j as usize, false, v1, RowRef { i: f.node, kind: RW_SPLIT_HI });
                    next = rt;
                    break;
                }
                if next == NONE {
                    return L_CONFLICT, root;
                }
                cur = next;
                continue;
            }
            // Feasible: split on the smallest atom with a fractional value; at an integer model, make a
            // product linear (`fix`) or stop.
            let mut j = NONE;
            let mut v = Num::<B>::zero();
            for a in 0..self.lp.na {
                let x = self.lp.val[a];
                if x.d != Num::<B>::one() {
                    j = a as u32;
                    v = x.n.div_euclid(&x.d);
                    break;
                }
            }
            // At the root, cut the fractional point off first: a split of one atom cannot end a slab
            // of rational points with no integer one (`1 <= 7 * (x - y) <= 6`), a cut does.
            if j != NONE && self.frames.len() == 0 && rounds < GOMORY_ROUNDS {
                rounds += 1;
                if self.gomory() {
                    continue;
                }
            }
            if j == NONE {
                let (fx, fj, fv) = self.fix(tm, cur);
                if fx == FX_NONE {
                    return L_FEAS, NONE;
                }
                if fx == FX_ROWS {
                    continue;
                }
                j = fj;
                v = fv;
            }
            if made + 2 > NODES_MAX {
                return L_ABORT, NONE;
            }
            self.frames.push(
                Frame::<B> {
                    lo: self.lp.lo[j as usize],
                    hi: self.lp.hi[j as usize],
                    lo_r: self.lp.lo_r[j as usize],
                    hi_r: self.lp.hi_r[j as usize],
                    node: cur,
                    j: j,
                    has_lo: self.lp.has_lo[j as usize],
                    has_hi: self.lp.has_hi[j as usize],
                    right: false,
                },
            );
            let lt = self.new_node();
            made += 1;
            self.pf.nodes.set(
                cur as usize,
                TreeNode::<B> {
                    v: v,
                    atom: self.lp.atom[j as usize],
                    left: lt,
                    right: NONE,
                    ms: 0,
                    mn: 0,
                    kind: N_SPLIT,
                },
            );
            self.lp.bound(j as usize, true, v, RowRef { i: cur, kind: RW_SPLIT_LO });
            cur = lt;
        }
        return L_ABORT, NONE;
    }

    // At an integer model that gives a product `p == x * y` (two terms that are not constants) another
    // value than its operands' product: set `y`, an atom of value `c` in the model, to `c` with splits
    // (`y <= c` and `y >= c`, FX_SPLIT with the atom and the split value), then, below splits that
    // leave `y` only `c`, add the rows `p - c * x <= 0` and `c * x - p <= 0` (FX_ROWS). A `y` the rows
    // force to `c` (`requires k == 3`) makes the other sides of the splits conflicts at once. At most
    // FIXES_MAX values per branch and bound, so a `y` the rows leave free stops at an integer model
    // as before.
    fn fix(self: &mut Self, tm: &Terms<B>, cur: u32) (u8, u32, Num<B>) {
        for a in 0..self.lp.na {
            let p = self.lp.atom[a];
            let x = tm.at(p);
            if x.op != T_MUL || tm.at(x.a).op == T_INT || tm.at(x.b).op == T_INT {
                continue;
            }
            // An operand at 0 makes the product 0, whatever the other's value.
            let oa = self.lp_value(tm, x.a);
            let ob = self.lp_value(tm, x.b);
            let za = oa.is_some() && oa.unwrap().is_zero();
            let zb = ob.is_some() && ob.unwrap().is_zero();
            if (oa.is_none() || ob.is_none()) && !za && !zb {
                continue;
            }
            let vb = ob.unwrap_or(Num::<B>::zero());
            let m = if za || zb {
                Some(Num::<B>::zero())
            } else {
                ck(oa.unwrap().checked_mul(&vb))
            };
            if m.is_some() && m.unwrap() == self.lp.val[a].n {
                continue;
            }
            for side in 0..2u32 {
                let o = 1 - side;
                let y = pick(o == 1, x.b, x.a);
                // With an operand at 0, that one is fixed.
                if (za || zb) && !pick(o == 1, zb, za) {
                    continue;
                }
                let yj = switch self.lp.ix.get(&y) {
                    Some(v) => *v,
                    None => {
                        continue;
                    },
                };
                let c = self.lp.val[yj as usize].n;
                let mut known = false;
                for f in 0..self.fixes.len() {
                    known = known || self.fixes[f].j == yj && self.fixes[f].c == c;
                }
                if !known {
                    if self.fixes.len() >= FIXES_MAX {
                        continue;
                    }
                    self.fixes.push(Fix::<B> { j: yj, c: c });
                }
                let y0 = yj as usize;
                let at_hi = self.lp.has_hi[y0] && self.lp.hi[y0] == c;
                if !at_hi {
                    return FX_SPLIT, yj, c;
                }
                if !self.lp.has_lo[y0] || self.lp.lo[y0] != c {
                    return FX_SPLIT, yj, c - Num::<B>::one();
                }
                if self.fix_rows(tm, a, o, c, cur) {
                    return FX_ROWS, NONE, Num::<B>::zero();
                }
            }
        }
        return FX_NONE, NONE, Num::<B>::zero();
    }

    // The rows `p - c * x <= 0` and `c * x - p <= 0` of product atom `a` with operand `o` at `c`, as one
    // new simplex row whose slack both bounds hold, undone with the subtree (a frame). False when an
    // atom of `x` is not the simplex's or the tableau is full.
    fn fix_rows(self: &mut Self, tm: &Terms<B>, a: usize, o: u32, c: Num<B>, cur: u32) bool {
        let p = self.lp.atom[a];
        let x = tm.at(p);
        let other = pick(o == 1, x.a, x.b);
        self.lin.clear();
        let mut k = Num::<B>::zero();
        if !lin_form(tm, p, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) || !lin_form(
            tm,
            other,
            Num::<B>::zero() - c,
            &mut k,
            &mut self.lin,
            &mut self.stack,
        ) {
            return false;
        }
        let n = switch merge_terms(&mut self.lin, 0, self.lin.len()) {
            Some(v) => v,
            None => {
                self.lp.ovf_seen = true;
                return false;
            },
        };
        let g = switch coef_gcd(&self.lin, 0, n) {
            Some(v) => v,
            None => {
                return false;
            },
        };
        if n == 0 || g.is_zero() {
            return false;
        }
        for j in 0..n {
            let e = self.lin[j];
            self.lin.set(j, LinTerm::<B> { c: e.c.div_euclid(&g), atom: e.atom });
        }
        // The kernel's rows, each divided by `g` with its constant rounded up: `s + ceil(k / g) <= 0`
        // and `-s + ceil(-k / g) <= 0` for the slack `s` of the divided form.
        let hi = (Num::<B>::zero() - k).div_euclid(&g);
        let lo = Num::<B>::zero() - k.div_euclid(&g);
        let sj = self.lp.add_row(&self.lin, n);
        if sj == NONE {
            return false;
        }
        let ri = p << 1 | o;
        self.keep_row(n, Num::<B>::zero() - hi, RowRef { i: ri, kind: RW_FIX_LE });
        let s0 = sj as usize;
        self.frames.push(
            Frame::<B> {
                lo: self.lp.lo[s0],
                hi: self.lp.hi[s0],
                lo_r: self.lp.lo_r[s0],
                hi_r: self.lp.hi_r[s0],
                node: cur,
                j: sj,
                has_lo: false,
                has_hi: false,
                right: true,
            },
        );
        self.lp.bound(s0, true, hi, RowRef { i: ri, kind: RW_FIX_LE });
        self.lp.bound(s0, false, lo, RowRef { i: ri, kind: RW_FIX_GE });
        return true;
    }

    // The row of the simplex row `add_row` just made from `lin[0, n)`, with constant `k` and reason
    // `r`, after the loaded rows (`lrows`): slack `na + q` is the row `lrows[q]`.
    fn keep_row(self: &mut Self, n: usize, k: Num<B>, r: RowRef) {
        let start = self.lpool.len() as u32;
        for j in 0..n {
            self.lpool.push(self.lin[j]);
        }
        self.lrows.push(LRow::<B> { k: k, start: start, len: n as u32, r: r });
    }

    // Gomory cuts of the simplex's point at the root: for up to GOMORY_CUTS basic variables of a
    // fractional value `b`, a cut that point breaks. Whether one was added.
    //
    // A tableau row is `x = b + sum(a_j * t_j)`, `t_j >= 0` the distance of nonbasic `j` from the bound
    // it sits at, whose row is `-t_j <= 0`. The rows with multipliers `frac(a_j)` sum to
    // `-x + sum(floor(a_j) * t_j) + b <= 0`, integer coefficients but `b`; scaled to integers, the
    // checker divides them by their gcd and rounds the constant up, which keeps every integer point
    // and drops this one (`kernel::Cut`). A row of a split, a product or the hypothesis holds on part
    // of the branch only: a tableau row that needs one gives no cut.
    fn gomory(self: &mut Self) bool {
        let nr = self.lp.nr;
        let mut added: u32 = 0;
        for r in 0..nr {
            if added >= GOMORY_CUTS {
                break;
            }
            let b = self.lp.var_of[r] as usize;
            if self.lp.val[b].d != Num::<B>::one() && self.gomory_row(r) {
                added += 1;
            }
        }
        return added != 0;
    }

    fn gomory_row(self: &mut Self, r: usize) bool {
        let nv = self.lp.nv;
        let one = Num::<B>::one();
        // The multipliers' common denominator, then each nonbasic's fractional part and bound row.
        let mut l = one;
        let ms = self.pf.mults.len();
        for j in 0..nv {
            if self.lp.row_of[j] != NONE {
                continue;
            }
            let a = self.lp.at(r, j);
            if a.n.is_zero() {
                continue;
            }
            let x = self.lp.val[j];
            let at_lo = self.lp.has_lo[j] && x.d == one && x.n == self.lp.lo[j];
            let at_hi = self.lp.has_hi[j] && x.d == one && x.n == self.lp.hi[j];
            let an = pick(at_lo || !at_hi, a.n, Num::<B>::zero() - a.n);
            let f = an.rem_euclid(&a.d);
            if f.is_zero() {
                continue;
            }
            let rr = pick(at_lo, self.lp.lo_r[j], self.lp.hi_r[j]);
            let global = rr.i != NONE && (rr.kind == RW_IN || rr.kind == RW_LO || rr.kind == RW_HI || rr.kind == RW_EQ_LE || rr.kind == RW_EQ_GE || rr.kind == RW_CUT);
            if !at_lo && !at_hi || !global || self.pf.cuts.len() >= FACTS_MAX {
                self.pf.mults.truncate(ms);
                return false;
            }
            let g = gcd(l, a.d);
            switch ck(l.div_euclid(&g).checked_mul(&a.d)) {
                Some(v) => l = v,
                None => {
                    self.pf.mults.truncate(ms);
                    return false;
                },
            }
            // The fraction `f / d` for now; scaled by `l` below.
            self.pf.mults.push(Mult::<B> { m: f, r: rr });
            self.gden.push(a.d);
        }
        let mn = self.pf.mults.len() - ms;
        let dens = self.gden.len() - mn;
        // The combination of the bound rows, each as the checker rebuilds it.
        self.lin.clear();
        let mut k = Num::<B>::zero();
        let mut ok = mn != 0;
        for q in 0..mn {
            if !ok {
                break;
            }
            let mut e = self.pf.mults[ms + q];
            let d = self.gden[dens + q];
            let scale = l.div_euclid(&d);
            let m = switch ck(e.m.checked_mul(&scale)) {
                Some(v) => v,
                None => {
                    ok = false;
                    continue;
                },
            };
            e.m = m;
            self.pf.mults.set(ms + q, e);
            ok = self.add_bound_row(e.r, m, &mut k);
        }
        self.gden.truncate(dens);
        if !ok {
            self.pf.mults.truncate(ms);
            return false;
        }
        let n = switch merge_terms(&mut self.lin, 0, self.lin.len()) {
            Some(v) => v,
            None => {
                self.pf.mults.truncate(ms);
                self.lp.ovf_seen = true;
                return false;
            },
        };
        self.lin.truncate(n);
        let g = switch coef_gcd(&self.lin, 0, n) {
            Some(v) => v,
            None => {
                self.pf.mults.truncate(ms);
                return false;
            },
        };
        if n == 0 || g.is_zero() {
            self.pf.mults.truncate(ms);
            return false;
        }
        for j in 0..n {
            let e = self.lin[j];
            self.lin.set(j, LinTerm::<B> { c: e.c.div_euclid(&g), atom: e.atom });
        }
        let kc = Num::<B>::zero() - (Num::<B>::zero() - k).div_euclid(&g);
        // Only a cut the point breaks.
        let mut v = q_int(kc);
        for j in 0..n {
            let e = self.lin[j];
            let x = switch self.lp.ix.get(&e.atom) {
                Some(i) => self.lp.val[(*i) as usize],
                None => {
                    self.pf.mults.truncate(ms);
                    return false;
                },
            };
            v = q_add(v, q_mul(q_int(e.c), x, &mut self.lp.ovf), &mut self.lp.ovf);
        }
        if self.lp.ovf || !q_lt(q_int(Num::<B>::zero()), v, &mut self.lp.ovf) {
            self.pf.mults.truncate(ms);
            return false;
        }
        let sj = self.lp.add_row(&self.lin, n);
        if sj == NONE {
            self.pf.mults.truncate(ms);
            return false;
        }
        self.pf.cuts.push(Cut { ms: ms as u32, mn: mn as u32, upto: self.pf.facts.len() as u32 });
        let ci = (self.pf.cuts.len() - 1) as u32;
        let rr = RowRef { i: ci, kind: RW_CUT };
        self.keep_row(n, kc, rr);
        self.lp.bound(sj as usize, true, Num::<B>::zero() - kc, rr);
        return true;
    }

    // `m` times the row `rr` names (a loaded row, an atom's bound), added to `lin` and `k`.
    fn add_bound_row(self: &mut Self, rr: RowRef, m: Num<B>, k: &mut Num<B>) bool {
        let mut terms = Vector::<LinTerm<B>>::new();
        let mut rk = Num::<B>::zero();
        if rr.kind == RW_LO || rr.kind == RW_HI {
            let j = switch self.lp.ix.get(&rr.i) {
                Some(v) => (*v) as usize,
                None => {
                    return false;
                },
            };
            if rr.kind == RW_LO {
                terms.push(LinTerm::<B> { c: wide::<B>(-1), atom: rr.i });
                rk = self.lp.lo[j];
            } else {
                terms.push(LinTerm::<B> { c: Num::<B>::one(), atom: rr.i });
                rk = Num::<B>::zero() - self.lp.hi[j];
            }
        } else {
            let mut found = false;
            for q in 0..self.lrows.len() {
                let x = self.lrows[q];
                if x.r.i == rr.i && x.r.kind == rr.kind {
                    for t in x.start..x.start + x.len {
                        terms.push(self.lpool[t as usize]);
                    }
                    rk = x.k;
                    found = true;
                    break;
                }
            }
            if !found {
                return false;
            }
        }
        for t in 0..terms.len() {
            let e = terms[t];
            switch ck(e.c.checked_mul(&m)) {
                Some(c) => self.lin.push(LinTerm::<B> { c: c, atom: e.atom }),
                None => {
                    return false;
                },
            }
        }
        return switch ck(rk.checked_mul(&m)) {
            Some(v) => {
                switch ck(k.checked_add(&v)) {
                    Some(s) => {
                        *k = s;
                        true
                    },
                    None => false,
                }
            },
            None => false,
        };
    }

    // The value of integer term `t` at the simplex's point, None when an atom of it is not the
    // simplex's.
    fn lp_value(self: &mut Self, tm: &Terms<B>, t: u32) Option<Num<B>> {
        switch self.lp.ix.get(&t) {
            Some(v) => {
                return Some(self.lp.val[(*v) as usize].n);
            },
            None => {},
        }
        self.stack.clear();
        let mut lin = Vector::<LinTerm<B>>::new();
        let mut k = Num::<B>::zero();
        if !lin_form(tm, t, Num::<B>::one(), &mut k, &mut lin, &mut self.stack) {
            return None;
        }
        let mut s = k;
        for j in 0..lin.len() {
            let e = lin[j];
            let v = switch self.lp.ix.get(&e.atom) {
                Some(v) => self.lp.val[(*v) as usize].n,
                None => {
                    return None;
                },
            };
            switch ck(e.c.checked_mul(&v)) {
                Some(m) => {
                    switch ck(s.checked_add(&m)) {
                        Some(r) => s = r,
                        None => {
                            return None;
                        },
                    }
                },
                None => {
                    return None;
                },
            }
        }
        return Some(s);
    }

    fn new_node(self: &mut Self) u32 {
        self.pf.nodes.push(
            TreeNode::<B> { v: Num::<B>::zero(), atom: NONE, left: NONE, right: NONE, ms: 0, mn: 0, kind: N_LEAF },
        );
        return (self.pf.nodes.len() - 1) as u32;
    }

    fn restore(self: &mut Self, f: &Frame<B>) {
        let j = f.j as usize;
        self.lp.lo.set(j, f.lo);
        self.lp.hi.set(j, f.hi);
        self.lp.lo_r.set(j, f.lo_r);
        self.lp.hi_r.set(j, f.hi_r);
        self.lp.has_lo.set(j, f.has_lo);
        self.lp.has_hi.set(j, f.has_hi);
    }

    // TreeNode `n` as the leaf of the simplex's last conflict, its multipliers made integers (scaled by the
    // least common multiple of their denominators). False when a value leaves B bits.
    fn leaf(self: &mut Self, n: u32) bool {
        let mut l = Num::<B>::one();
        for j in 0..self.lp.expl.len() {
            let d = self.lp.expl[j].q.d;
            let g = gcd(l, d);
            switch ck(l.div_euclid(&g).checked_mul(&d)) {
                Some(v) => l = v,
                None => {
                    return false;
                },
            }
        }
        let ms = self.pf.mults.len() as u32;
        for j in 0..self.lp.expl.len() {
            let e = self.lp.expl[j];
            let scale = l.div_euclid(&e.q.d);
            switch ck(e.q.n.checked_mul(&scale)) {
                Some(m) => self.pf.mults.push(Mult::<B> { m: m, r: e.r }),
                None => {
                    return false;
                },
            }
        }
        let mn = self.pf.mults.len() as u32 - ms;
        self.pf.nodes.set(
            n as usize,
            TreeNode::<B> { v: Num::<B>::zero(), atom: NONE, left: NONE, right: NONE, ms: ms, mn: mn, kind: N_LEAF },
        );
        return true;
    }

    // The integer model of the simplex into `model` and `mval`.
    fn keep_model(self: &mut Self) {
        self.model.clear();
        self.mval.clear();
        for j in 0..self.lp.na {
            self.model.push(self.lp.atom[j]);
            self.mval.push(self.lp.val[j].n);
        }
    }

    // The value of integer term `t` in the simplex's model, None when an atom of it has none.
    fn model_value(self: &mut Self, tm: &Terms<B>, t: u32) Option<Num<B>> {
        self.lin.clear();
        let mut k = Num::<B>::zero();
        if !lin_form(tm, t, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) {
            return None;
        }
        let mut s = k;
        for j in 0..self.lin.len() {
            let e = self.lin[j];
            let v = switch self.lp.ix.get(&e.atom) {
                Some(x) => self.lp.val[(*x) as usize],
                None => {
                    return None;
                },
            };
            if v.d != Num::<B>::one() {
                return None;
            }
            switch ck(e.c.checked_mul(&v.n)) {
                Some(p) => {
                    switch ck(s.checked_add(&p)) {
                        Some(q) => s = q,
                        None => {
                            return None;
                        },
                    }
                },
                None => {
                    return None;
                },
            }
        }
        return Some(s);
    }

    // ---- the closure ---------------------------------------------------------------------------

    // The closure over the terms of `st` and their operands, each term its own class. False past
    // CC_MAX terms.
    fn cc_build(self: &mut Self, tm: &Terms<B>, st: &Stated<B>) bool {
        self.cc_on = true;
        self.cc_term.clear();
        self.cc_ix.clear();
        self.queue.clear();
        for j in 0..st.eqs.len() {
            self.queue.push((st.eqs[j] >> 32) as u32);
            self.queue.push(st.eqs[j] as u32);
        }
        for j in 0..st.neqs.len() {
            self.queue.push((st.neqs[j] >> 32) as u32);
            self.queue.push(st.neqs[j] as u32);
        }
        for j in 0..st.lits.len() {
            self.queue.push((st.lits[j] >> 1) as u32);
        }
        for j in 0..st.pool.len() {
            self.queue.push(st.pool[j].atom);
        }
        // Each term, then its operands, in first-seen order: a term takes its index when first queued,
        // so one shared by many others is queued once.
        let roots = self.queue.len();
        let mut q: usize = 0;
        for j in 0..roots {
            let t = self.queue[j];
            if !self.cc_ix.contains_key(&t) {
                self.cc_ix.insert(t, self.cc_term.len() as u32);
                self.cc_term.push(t);
            }
        }
        for _s in 0..CC_MAX + 1 {
            if q == self.cc_term.len() || self.cc_term.len() > CC_MAX {
                break;
            }
            let t = self.cc_term[q];
            q += 1;
            tm.operands(t, &mut self.ops);
            for j in 0..self.ops.len() {
                let o = self.ops[j];
                if !self.cc_ix.contains_key(&o) {
                    self.cc_ix.insert(o, self.cc_term.len() as u32);
                    self.cc_term.push(o);
                }
            }
        }
        if q != self.cc_term.len() || self.cc_term.len() > CC_MAX {
            return false;
        }
        let n = self.cc_term.len();
        if !self.spend(n as u32) {
            return false;
        }
        self.rep.clear();
        self.next.clear();
        self.size.clear();
        self.ehead.clear();
        self.ostart.clear();
        self.olist.clear();
        self.seen.clear();
        self.sedge.clear();
        for i in 0..n {
            self.rep.push(i as u32);
            self.next.push(i as u32);
            self.size.push(1);
            self.ehead.push(NONE);
            self.seen.push(0);
            self.sedge.push(NONE);
            self.ostart.push(self.olist.len() as u32);
            tm.operands(self.cc_term[i], &mut self.ops);
            for j in 0..self.ops.len() {
                self.olist.push(*self.cc_ix.get(&self.ops[j]).unwrap());
            }
        }
        self.ostart.push(self.olist.len() as u32);
        // The users of each term: counted, then placed.
        self.ustart.clear();
        self.ulist.clear();
        for _i in 0..n + 1 {
            self.ustart.push(0);
        }
        for j in 0..self.olist.len() {
            let o = self.olist[j] as usize;
            self.ustart.set(o + 1, self.ustart[o + 1] + 1);
        }
        for i in 0..n {
            self.ustart.set(i + 1, self.ustart[i + 1] + self.ustart[i]);
        }
        for _j in 0..self.olist.len() {
            self.ulist.push(0);
        }
        let mut fillp = self.ustart.clone();
        for i in 0..n {
            for j in self.ostart[i]..self.ostart[i + 1] {
                let o = self.olist[j as usize] as usize;
                self.ulist.set(fillp[o] as usize, i as u32);
                fillp.set(o, fillp[o] + 1);
            }
        }
        self.sig.clear();
        self.pend.clear();
        self.edges.clear();
        self.enext.clear();
        self.memo.clear();
        for i in 0..n {
            if self.ostart[i] != self.ostart[i + 1] || tm.at(self.cc_term[i]).op == T_INT {
                let h = self.sig_of(tm, i as u32);
                // Two terms of one value at two types (`same_op`) are congruent from the start.
                let hit = switch self.sig.get(&h) {
                    Some(v) => *v,
                    None => NONE,
                };
                if hit != NONE && self.congruent(tm, i as u32, hit) {
                    self.pend.push(Edge { u: i as u32, v: hit, p: NONE, q: NONE, kind: E_CONG });
                } else {
                    self.sig.insert(h, i as u32);
                }
            }
        }
        return true;
    }

    // The signature of application `u`: its operation and its operands' classes.
    const fn sig_of(self: &Self, tm: &Terms<B>, u: u32) u64 {
        let x = tm.at(self.cc_term[u as usize]);
        // A constant, sum, difference, product, negation, quotient or remainder of any type is one
        // operation (`same_op`).
        let ty = if exact_op(x.op) || x.op == T_INT {
            0u64
        } else {
            x.w as u64 << 1 | x.sg as u64
        };
        let mut h = hmix(0x9E3779B97F4A7C15u64, x.op as u64 << 24 | ty);
        h = hmix(h, x.k.limb(0));
        h = hmix(h, x.k.limb(1));
        h = hmix(h, x.k.limb(2));
        h = hmix(h, x.k.limb(3));
        let s = self.ostart[u as usize];
        let n = self.ostart[u as usize + 1] - s;
        h = hmix(h, n);
        if n == 2 && commutes(x.op) {
            let p = self.rep[self.olist[s as usize] as usize];
            let q = self.rep[self.olist[s as usize + 1] as usize];
            return hmix(hmix(h, p.min(q)), p.max(q));
        }
        for j in s..s + n {
            h = hmix(h, self.rep[self.olist[j as usize] as usize]);
        }
        return h;
    }

    // Whether applications `u` and `v` are one operation over operands of the same classes.
    const fn congruent(self: &Self, tm: &Terms<B>, u: u32, v: u32) bool {
        let x = tm.at(self.cc_term[u as usize]);
        let y = tm.at(self.cc_term[v as usize]);
        let nu = self.ostart[u as usize + 1] - self.ostart[u as usize];
        let nv = self.ostart[v as usize + 1] - self.ostart[v as usize];
        if !same_op(&x, &y) || nu != nv || nu == 0 && x.op != T_INT {
            return false;
        }
        return nu == 0 || self.paired(u, v, false) || nu == 2 && commutes(x.op) && self.paired(u, v, true);
    }

    // Whether each operand of application `u` is in the class of `v`'s at its place, or with `swap` at
    // the other place of two.
    const fn paired(self: &Self, u: u32, v: u32, swap: bool) bool {
        let nu = self.ostart[u as usize + 1] - self.ostart[u as usize];
        for j in 0..nu {
            let a = self.olist[(self.ostart[u as usize] + j) as usize];
            let b = self.olist[(self.ostart[v as usize] + pick(swap, nu - 1 - j, j)) as usize];
            if self.rep[a as usize] != self.rep[b as usize] {
                return false;
            }
        }
        return true;
    }

    // Do the waiting merges and the congruences they cause, then look for a conflict: Some(true) with
    // its proof's end set, Some(false) for none, None past a bound.
    fn cc_run(self: &mut Self, tm: &Terms<B>, st: &Stated<B>) Option<bool> {
        let mut q: usize = 0;
        for _s in 0..CC_MAX * 8 {
            if q == self.pend.len() {
                break;
            }
            let e = self.pend[q];
            q += 1;
            let ru = self.rep[e.u as usize];
            let rv = self.rep[e.v as usize];
            if ru == rv {
                continue;
            }
            if !self.spend(1) {
                return None;
            }
            // The edge, between the terms themselves, joins two trees of the forest.
            let ei = self.edges.len() as u32;
            self.edges.push(e);
            self.enext.push(self.ehead[e.u as usize]);
            self.ehead.set(e.u as usize, ei * 2);
            self.enext.push(self.ehead[e.v as usize]);
            self.ehead.set(e.v as usize, ei * 2 + 1);
            // The smaller class joins the larger.
            let (small, big) = if self.size[ru as usize] < self.size[rv as usize] {
                (ru, rv)
            } else {
                (rv, ru)
            };
            self.members.clear();
            let mut m = small;
            for _k in 0..self.cc_term.len() {
                self.members.push(m);
                self.rep.set(m as usize, big);
                m = self.next[m as usize];
                if m == small {
                    break;
                }
            }
            let nb = self.next[big as usize];
            self.next.set(big as usize, self.next[small as usize]);
            self.next.set(small as usize, nb);
            self.size.set(big as usize, self.size[big as usize] + self.size[small as usize]);
            // The applications over a member of the smaller class have new signatures.
            for x in 0..self.members.len() {
                let m = self.members[x];
                for j in self.ustart[m as usize]..self.ustart[m as usize + 1] {
                    let u = self.ulist[j as usize];
                    let h = self.sig_of(tm, u);
                    let hit = switch self.sig.get(&h) {
                        Some(v) => *v,
                        None => NONE,
                    };
                    if hit != NONE && hit != u && self.rep[hit as usize] != self.rep[u as usize] && self.congruent(
                        tm,
                        u,
                        hit,
                    ) {
                        self.pend.push(Edge { u: u, v: hit, p: NONE, q: NONE, kind: E_CONG });
                    } else {
                        self.sig.insert(h, u);
                    }
                }
            }
        }
        if q != self.pend.len() {
            return None;
        }
        self.pend.clear();
        switch self.conflict(tm) {
            Some(c) => {
                if c {
                    return Some(true);
                }
            },
            None => {
                return None;
            },
        }
        return self.conflict_st(st);
    }

    // A merged pair the branch states unequal, opposite literals in one class, or two different
    // constants in one class: Some(true) with the proof's end set.
    fn conflict(self: &mut Self, tm: &Terms<B>) Option<bool> {
        // The constants of each class, by their first member.
        let n = self.cc_term.len();
        let mut konst = Vector::<u32>::with_capacity(n);
        for _i in 0..n {
            konst.push(NONE);
        }
        for i in 0..n {
            let x = tm.at(self.cc_term[i]);
            if x.op != T_INT && x.op != T_BOOL {
                continue;
            }
            let r = self.rep[i] as usize;
            let c = konst[r];
            if c == NONE {
                konst.set(r, i as u32);
            } else if tm.at(self.cc_term[c as usize]).k != x.k {
                return self.end_with(X_CONST, c, i as u32, NONE);
            }
        }
        return Some(false);
    }

    // The branch-level conflicts, which need the branch: its disequalities and literals.
    fn conflict_st(self: &mut Self, st: &Stated<B>) Option<bool> {
        for j in 0..st.neqs.len() {
            let e = st.neqs[j];
            let u = *self.cc_ix.get(&((e >> 32) as u32)).unwrap();
            let v = *self.cc_ix.get(&(e as u32)).unwrap();
            if self.rep[u as usize] == self.rep[v as usize] {
                return self.end_with(X_NEQ, u, v, j as u32);
            }
        }
        for i in 0..st.lits.len() {
            let a = st.lits[i];
            if (a & 1) == 0 {
                continue;
            }
            let u = *self.cc_ix.get(&((a >> 1) as u32)).unwrap();
            for j in 0..st.lits.len() {
                let b = st.lits[j];
                if (b & 1) != 0 {
                    continue;
                }
                let v = *self.cc_ix.get(&((b >> 1) as u32)).unwrap();
                if u != v && self.rep[u as usize] == self.rep[v as usize] {
                    return self.end_with(X_LITS, u, v, NONE);
                }
            }
        }
        return Some(false);
    }

    // End the proof with conflict `kind` on the equality of closure terms `u` and `v`.
    fn end_with(self: &mut Self, kind: u8, u: u32, v: u32, q: u32) Option<bool> {
        let f = self.explain(u, v, 0);
        if f == NONE {
            return None;
        }
        self.pf.end = kind;
        self.pf.p = f;
        self.pf.q = q;
        return Some(true);
    }

    // The fact that proves closure terms `u` and `v` equal, from the path between them in the forest of
    // merges; NONE past a bound.
    fn explain(self: &mut Self, u: u32, v: u32, depth: u32) u32 {
        if depth > DEPTH_MAX {
            return NONE;
        }
        let key = pair(pick(u < v, u, v), pick(u < v, v, u));
        if let Some(f) = self.memo.get(&key) {
            return *f;
        }
        // The path from `v` back to `u`: a search from `u` that records each term's edge.
        self.now += 1;
        self.queue.clear();
        self.queue.push(u);
        self.seen.set(u as usize, self.now);
        self.sedge.set(u as usize, NONE);
        let mut q: usize = 0;
        for _s in 0..self.cc_term.len() + 1 {
            if q == self.queue.len() || self.seen[v as usize] == self.now {
                break;
            }
            let x = self.queue[q];
            q += 1;
            let mut h = self.ehead[x as usize];
            for _e in 0..2 * self.edges.len() + 1 {
                if h == NONE {
                    break;
                }
                let ed = self.edges[(h / 2) as usize];
                let y = if (h & 1) == 0 {
                    ed.v
                } else {
                    ed.u
                };
                if self.seen[y as usize] != self.now {
                    self.seen.set(y as usize, self.now);
                    self.sedge.set(y as usize, h);
                    self.queue.push(y);
                }
                h = self.enext[h as usize];
            }
        }
        if self.seen[v as usize] != self.now {
            return NONE;
        }
        let mut path = Vector::<u32>::new(); // edge halves from `v` back to `u`
        let mut x = v;
        for _s in 0..self.cc_term.len() + 1 {
            if x == u {
                break;
            }
            let h = self.sedge[x as usize];
            path.push(h);
            let ed = self.edges[(h / 2) as usize];
            x = if (h & 1) == 0 {
                ed.u
            } else {
                ed.v
            };
        }
        // Walk it from `u`: each edge's fact, chained by transitivity.
        let mut cur = NONE;
        let mut j = path.len();
        while j > 0 {
            j -= 1;
            let h = path[j];
            let g = self.edge_fact(h / 2, depth);
            if g == NONE {
                return NONE;
            }
            if cur == NONE {
                cur = g;
                continue;
            }
            let ed = self.edges[(h / 2) as usize];
            let far = if (h & 1) == 0 {
                ed.v
            } else {
                ed.u
            };
            cur = self.add_fact(
                Fact { a: self.cc_term[u as usize], b: self.cc_term[far as usize], p: cur, q: g, kind: F_TRANS },
            );
            if cur == NONE {
                return NONE;
            }
        }
        self.memo.insert(key, cur);
        return cur;
    }

    // The fact of merge `e`.
    fn edge_fact(self: &mut Self, e: u32, depth: u32) u32 {
        let ed = self.edges[e as usize];
        let a = self.cc_term[ed.u as usize];
        let b = self.cc_term[ed.v as usize];
        if ed.kind == E_IN {
            return self.add_fact(Fact { a: a, b: b, p: ed.p, q: NONE, kind: F_IN });
        }
        if ed.kind == E_ARITH {
            return self.add_fact(Fact { a: a, b: b, p: ed.p, q: ed.q, kind: F_ARITH });
        }
        let n = self.ostart[ed.u as usize + 1] - self.ostart[ed.u as usize];
        let swap = !self.paired(ed.u, ed.v, false);
        let mut args = Vector::<u32>::with_capacity(n as usize);
        for j in 0..n {
            let x = self.olist[(self.ostart[ed.u as usize] + j) as usize];
            let y = self.olist[(self.ostart[ed.v as usize] + pick(swap, n - 1 - j, j)) as usize];
            if x == y {
                args.push(NONE);
                continue;
            }
            let f = self.explain(x, y, depth + 1);
            if f == NONE {
                return NONE;
            }
            args.push(f);
        }
        let p = self.pf.cargs.len() as u32;
        self.pf.cargs.extend_copy(&args);
        return self.add_fact(Fact { a: a, b: b, p: p, q: n, kind: F_CONG });
    }

    fn add_fact(self: &mut Self, f: Fact) u32 {
        if self.pf.facts.len() >= FACTS_MAX || !self.spend(1) {
            return NONE;
        }
        self.pf.facts.push(f);
        return (self.pf.facts.len() - 1) as u32;
    }

    // The facts that give the arithmetic each class's integer equalities: in each class, its first
    // member that is an atom of the rows or a constant, joined to each later one. False past a bound.
    fn eq_rows(self: &mut Self, tm: &Terms<B>) bool {
        let n = self.cc_term.len();
        let mut first = Vector::<u32>::with_capacity(n);
        for _i in 0..n {
            first.push(NONE);
        }
        for i in 0..n {
            let t = self.cc_term[i];
            if !tm.is_int(t) || !(tm.at(t).op == T_INT || self.ratoms.contains_key(&t)) {
                continue;
            }
            let r = self.rep[i] as usize;
            let f0 = first[r];
            if f0 == NONE {
                first.set(r, i as u32);
                continue;
            }
            let key = pair(f0, i as u32);
            if self.eqk.contains_key(&key) {
                continue;
            }
            let f = self.explain(f0, i as u32, 0);
            if f == NONE {
                return false;
            }
            self.eqk.insert(key, true);
            self.eqf.push(f);
        }
        return true;
    }

    // The operand pairs of applications `u` and `v` (with `swap`, the second's two operands swapped) in
    // different classes, into `cand` (cleared first), and into `sure` whether each pair has one linear
    // form: true when each pair has one linear form or is of integers of one value in the model.
    fn pairs_equal(
        self: &mut Self,
        tm: &Terms<B>,
        u: u32,
        v: u32,
        swap: bool,
        cand: &mut Vector<u64>,
        sure: &mut Vector<bool>,
    ) bool {
        cand.clear();
        sure.clear();
        let n = self.ostart[u as usize + 1] - self.ostart[u as usize];
        for j in 0..n {
            let a = self.olist[(self.ostart[u as usize] + j) as usize];
            let b = self.olist[(self.ostart[v as usize] + pick(swap, n - 1 - j, j)) as usize];
            if self.rep[a as usize] == self.rep[b as usize] {
                continue;
            }
            let ta = self.cc_term[a as usize];
            let tb = self.cc_term[b as usize];
            if !tm.is_int(ta) || !tm.is_int(tb) {
                return false;
            }
            let va = self.model_value(tm, ta);
            let vb = self.model_value(tm, tb);
            let same = self.same_form(tm, ta, tb);
            if !same && (va.is_none() || vb.is_none() || va.unwrap() != vb.unwrap()) {
                return false;
            }
            cand.push(pair(pick(a < b, a, b), pick(a < b, b, a)));
            sure.push(same);
        }
        return true;
    }

    // Whether integers `a` and `b` have one linear form (`(x + y) - 1` and `x + (y - 1)`), whatever
    // their atoms' values.
    fn same_form(self: &mut Self, tm: &Terms<B>, a: u32, b: u32) bool {
        self.lin.clear();
        let mut k = Num::<B>::zero();
        if !lin_form(tm, a, Num::<B>::one(), &mut k, &mut self.lin, &mut self.stack) || !lin_form(
            tm,
            b,
            wide::<B>(-1),
            &mut k,
            &mut self.lin,
            &mut self.stack,
        ) {
            return false;
        }
        return k.is_zero() && merge_terms(&mut self.lin, 0, self.lin.len()) == Some(0);
    }

    // The equalities to test: for two applications of one operation in different classes, each pair
    // of operands in different classes (`pairs_equal`), not tested before, into `out`, and into
    // `outsure` whether the pair has one linear form. Only pairs of applications where every
    // differing operand is such a pair. False past a bound.
    fn suggest(self: &mut Self, tm: &Terms<B>, out: &mut Vector<u64>, outsure: &mut Vector<bool>) bool {
        let mut apps = Vector::<u32>::new();
        for i in 0..self.cc_term.len() {
            if self.ostart[i] != self.ostart[i + 1] {
                apps.push(i as u32);
            }
        }
        if apps.len() > APPS_MAX {
            return true;
        }
        let mut cand = Vector::<u64>::new();
        let mut sure = Vector::<bool>::new();
        for x in 0..apps.len() {
            let u = apps[x];
            let tu = tm.at(self.cc_term[u as usize]);
            for y in x + 1..apps.len() {
                let v = apps[y];
                if self.rep[u as usize] == self.rep[v as usize] {
                    continue;
                }
                let tv = tm.at(self.cc_term[v as usize]);
                let n = self.ostart[u as usize + 1] - self.ostart[u as usize];
                if !same_op(&tu, &tv) || n != self.ostart[v as usize + 1] - self.ostart[v as usize] {
                    continue;
                }
                if !self.spend(1) {
                    return false;
                }
                if !self.pairs_equal(tm, u, v, false, &mut cand, &mut sure) && !(n == 2 && commutes(tu.op) && self.pairs_equal(
                    tm,
                    u,
                    v,
                    true,
                    &mut cand,
                    &mut sure,
                )) {
                    continue;
                }
                for j in 0..cand.len() {
                    if !self.tested.contains_key(&cand[j]) {
                        out.push(cand[j]);
                        outsure.push(sure[j]);
                    }
                }
            }
        }
        return true;
    }
}
