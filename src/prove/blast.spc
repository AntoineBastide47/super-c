// The meaning of terms as clauses, for the SAT refutations. Trusted, like `terms.spc`: the kernel
// checks LRAT proofs against the clauses written here (`Kernel::lrat`), so a wrong clause here can make
// a false proof pass.
//
// Two encodings:
//
// - the skeleton: the boolean structure of formulas (`!`, `&&`, `||`, `==` of booleans), each other
//   formula a variable (an atom). An integer equality `a == b` has two more variables, `a < b`
//   (SEL_LT) and `b < a` (SEL_GT), and the clause that one of the three holds. A branch the theory
//   solvers refute adds the negation of its literals as a clause; the hypotheses imply the goal when
//   these clauses and the skeleton have no model;
// - bits: every integer term as the bits of its exact value in two's complement, wide enough to
//   hold every value it can take (`nat_of`), each operation as its circuit, each comparison of
//   integers as a comparator. An operation whose value is not defined (a zero divisor, a count past
//   the width) is any value of its type. The meaning is the evaluator's (`Eval::apply`).
//
// A literal is `var << 1 | negated`; variable 0 is true (a unit clause).
import prove::terms as *;

pub(package) const L_TRUE: u32 = 0;
pub(package) const L_FALSE: u32 = 1;

// A theory literal: `term << 3 | sel << 1 | positive`.
pub(package) const SEL_ATOM: u64 = 0; // the term itself
pub(package) const SEL_LT: u64 = 1; // of an integer `a == b` or `a != b`: `a < b`
pub(package) const SEL_GT: u64 = 2; // `b < a`

pub(package) const fn tlit(t: u32, sel: u64, pos: bool) u64 {
    return t as u64 << 3 | sel << 1 | pos as u64;
}

// A formula's demand in the work list (an integer's is its width).
const KB: u32 = 0xFFFF;
// The widest bit vector, the literals of one CNF, the demands of one encoding.
const NAT_MAX: u32 = 1024;
const CNF_MAX: usize = 1 << 21;
const WORK_MAX: u32 = 1 << 20;

// Clauses: clause j is [ends[j - 1], ends[j]) of `lits` (from 0 for the first).
pub(package) struct Cnf {
    pub(package) nv: u32,
    pub(package) lits: Vector<u32>,
    pub(package) ends: Vector<u32>,
}

extend Cnf {
    pub(package) fn new() Cnf {
        let mut c = Cnf { nv: 0, lits: Vector::<u32>::new(), ends: Vector::<u32>::new() };
        c.clear();
        return c;
    }

    // No clause but the unit of the true variable.
    pub(package) fn clear(self: &mut Self) {
        self.nv = 1;
        self.lits.clear();
        self.ends.clear();
        self.lits.push(L_TRUE);
        self.ends.push(1);
    }

    pub(package) fn end(self: &mut Self) {
        self.ends.push(self.lits.len() as u32);
    }
}

pub(package) struct Blaster<const B: usize> {
    pub(package) cnf: Cnf,
    pub(package) ok: bool,
    bits: bool,
    gates: Map<u64, u32>, // and2 and xor2 by their inputs
    muxes: Map<u64, u32>, // mux by its inputs, each below 2^21
    fm: Map<u32, u32>, // a formula's literal
    atoms: Map<u64, u32>, // `term << 2 | sel`: an atom's variable
    vk: Map<u64, u32>, // `term << 16 | width`: the start of its bits in `vecs`
    vecs: Vector<u32>,
    nat: Map<u32, u32>,
    pub(package) leaves: Vector<u32>, // the integer terms the bits leave free, in order
    work: Vector<u64>,
    dep: Vector<u64>,
    nstack: Vector<u32>,
    fx: u32, // the width of a float operation's signed exponents (`fx_of`)
    fterms: Vector<u32>, // the float operations built, in order (`float_lemmas`)
    nan_c: u32, // where the float operation being built is NaN (`nan_if`)
    nan_of: Map<u32, u32>, // per float operation built, `nan_c`
    cands: Map<u32, Vector<u64>>, // the constants a float term is compared with (`cands_of`)
    cands_made: bool,
    boxes: Map<u32, Vector<u64>>, // the bounds of a float operation built (`box_lemmas`)
}

extend<const B: usize> Blaster<B> {
    pub(package) fn new() Blaster<B> {
        return Blaster::<B> {
            cnf: Cnf::new(),
            ok: true,
            bits: false,
            gates: Map::<u64, u32>::new(),
            muxes: Map::<u64, u32>::new(),
            fm: Map::<u32, u32>::new(),
            atoms: Map::<u64, u32>::new(),
            vk: Map::<u64, u32>::new(),
            vecs: Vector::<u32>::new(),
            nat: Map::<u32, u32>::new(),
            leaves: Vector::<u32>::new(),
            work: Vector::<u64>::new(),
            dep: Vector::<u64>::new(),
            nstack: Vector::<u32>::new(),
            fx: 16,
            fterms: Vector::<u32>::new(),
            nan_c: L_FALSE,
            nan_of: Map::<u32, u32>::new(),
            cands: Map::<u32, Vector<u64>>::new(),
            cands_made: false,
            boxes: Map::<u32, Vector<u64>>::new(),
        };
    }

    // The variable of atom `t` (selector `sel`), NONE when the encoding has none.
    pub(package) fn atom_var(self: &Self, t: u32, sel: u64) u32 {
        return switch self.atoms.get(&(t as u64 << 2 | sel)) {
            Some(v) => *v,
            None => NONE,
        };
    }

    // A new CNF: `bits` encodes integers as bits, else each integer comparison is an atom.
    pub(package) fn reset(self: &mut Self, bits: bool) {
        self.cnf.clear();
        self.ok = true;
        self.bits = bits;
        self.gates.clear();
        self.muxes.clear();
        self.fm.clear();
        self.atoms.clear();
        self.vk.clear();
        self.vecs.clear();
        self.nat.clear();
        self.leaves.clear();
        self.fterms.clear();
        self.nan_of.clear();
        self.cands.clear();
        self.cands_made = false;
        self.boxes.clear();
    }

    // Assert formula `t` (`pos`) or its negation.
    pub(package) fn assert(self: &mut Self, tm: &Terms<B>, t: u32, pos: bool) bool {
        let l = self.form(tm, t);
        if l == NONE {
            return false;
        }
        self.unit(l ^ (!pos) as u32);
        return self.ok;
    }

    pub(package) fn unit(self: &mut Self, l: u32) {
        self.cnf.lits.push(l);
        self.cnf.end();
    }

    // The clause of the negations of theory literals `lits`; false when one has no variable.
    pub(package) fn negation(self: &mut Self, tm: &Terms<B>, lits: &Vector<u64>) bool {
        let mut c = Vector::<u32>::with_capacity(lits.len());
        for j in 0..lits.len() {
            let x = self.lit_for(tm, lits[j]);
            if x == NONE {
                return false;
            }
            c.push(x ^ 1);
        }
        self.cnf.lits.extend_copy(&c);
        self.cnf.end();
        return true;
    }

    // The SAT literal of theory literal `l`, NONE when it has none. In the skeleton an atom's
    // variables exist once the formula that holds it is encoded.
    pub(package) fn lit_for(self: &mut Self, tm: &Terms<B>, l: u64) u32 {
        let t = (l >> 3) as u32;
        let sel = l >> 1 & 3;
        let neg = (l & 1) == 0;
        let x = if sel == SEL_ATOM {
            self.form(tm, t)
        } else if !self.bits {
            switch self.atoms.get(&(t as u64 << 2 | sel)) {
                Some(v) => *v << 1,
                None => NONE,
            }
        } else {
            let y = tm.at(t);
            if !(y.op == T_EQ || y.op == T_NE) || !tm.is_int(y.a) || !tm.is_int(y.b) {
                return NONE;
            }
            let (p, q) = pick(sel == SEL_LT, (y.a, y.b), (y.b, y.a));
            self.less(tm, p, q)
        };
        if x == NONE || !self.ok {
            return NONE;
        }
        return x ^ neg as u32;
    }

    // The literal of formula `t`, NONE past a bound.
    fn form(self: &mut Self, tm: &Terms<B>, t: u32) u32 {
        if !self.run(tm, t as u64 << 16 | KB as u64) {
            return NONE;
        }
        return *self.fm.get(&t).unwrap();
    }

    // `p < q` for integers, as a comparator of their bits.
    fn less(self: &mut Self, tm: &Terms<B>, p: u32, q: u32) u32 {
        let n = self.nat_of(tm, p).max(self.nat_of(tm, q));
        if !self.run(tm, p as u64 << 16 | n as u64) || !self.run(tm, q as u64 << 16 | n as u64) {
            return NONE;
        }
        let mut x = Vector::<u32>::new();
        let mut y = Vector::<u32>::new();
        self.get(tm, p, n, &mut x);
        self.get(tm, q, n, &mut y);
        return self.slt(&x, &y);
    }

    // The bits of leaf `t` (its type's width and a sign) into `out`.
    pub(package) fn leaf_bits(self: &Self, t: u32, out: &mut Vector<u32>) {
        out.clear();
        let n = *self.nat.get(&t).unwrap();
        let s = *self.vk.get(&(t as u64 << 16 | n as u64)).unwrap();
        for i in 0..n {
            out.push(self.vecs[(s + i) as usize]);
        }
    }

    // ---- the work list: each demand after the ones it reads -----------------------------------

    fn run(self: &mut Self, tm: &Terms<B>, d0: u64) bool {
        self.work.clear();
        self.work.push(d0);
        for _s in 0..WORK_MAX {
            if !self.ok {
                return false;
            }
            if self.work.len() == 0 {
                return true;
            }
            let d = self.work[self.work.len() - 1];
            // No bits hold an exact integer of a specification.
            if (d & 0xFFFF) as u32 != KB && exact_w(tm.at((d >> 16) as u32).w) {
                self.ok = false;
                return false;
            }
            if self.done(tm, d) {
                let _ = self.work.pop();
                continue;
            }
            self.dep.clear();
            self.deps(tm, d);
            let mut pushed = false;
            for j in 0..self.dep.len() {
                let e = self.dep[j];
                if !self.done(tm, e) {
                    self.work.push(e);
                    pushed = true;
                }
            }
            if pushed {
                continue;
            }
            let _ = self.work.pop();
            self.build(tm, d);
        }
        return false;
    }

    // Whether integer `t`'s bits are cut to the width asked: a sum, difference, negation or product
    // whose high bits are not read is built only to that width.
    const fn cut(op: u8) bool {
        return op == T_ADD || op == T_SUB || op == T_NEG || op == T_MUL;
    }

    // The width the bits of `t` are kept at when `k` are asked.
    fn width(self: &mut Self, tm: &Terms<B>, t: u32, k: u32) u32 {
        let n = self.nat_of(tm, t);
        return if Blaster::<B>::cut(tm.at(t).op) {
            n.min(k)
        } else {
            n
        };
    }

    fn done(self: &mut Self, tm: &Terms<B>, d: u64) bool {
        let t = (d >> 16) as u32;
        let k = (d & 0xFFFF) as u32;
        if k == KB {
            return self.fm.contains_key(&t);
        }
        let kk = self.width(tm, t, k);
        return self.vk.contains_key(&(t as u64 << 16 | kk as u64));
    }

    fn need(self: &mut Self, t: u32, k: u32) {
        self.dep.push(t as u64 << 16 | k as u64);
    }

    const fn is_cmp(tm: &Terms<B>, x: &Term<B>) bool {
        return (x.op == T_LT || x.op == T_LE || x.op == T_EQ || x.op == T_NE) && tm.is_int(x.a) && tm.is_int(x.b);
    }

    fn deps(self: &mut Self, tm: &Terms<B>, d: u64) {
        let t = (d >> 16) as u32;
        let k = (d & 0xFFFF) as u32;
        let x = tm.at(t);
        if k == KB {
            if x.op == T_NOT {
                self.need(x.a, KB);
            } else if x.op == T_AND || x.op == T_OR || (x.op == T_EQ || x.op == T_NE) && tm.is_bool(x.a) && tm.is_bool(
                x.b,
            ) {
                self.need(x.a, KB);
                self.need(x.b, KB);
            } else if self.bits && Blaster::<B>::is_cmp(tm, &x) {
                let n = self.nat_of(tm, x.a).max(self.nat_of(tm, x.b));
                self.need(x.a, n);
                self.need(x.b, n);
            } else if self.bits && float_op(x.op) {
                let wa = tm.at(x.a).w as u32;
                self.need(x.a, wa);
                self.need(x.b, wa);
            }
            return;
        }
        let w = x.w as u32;
        if x.op == T_ADD || x.op == T_SUB || x.op == T_MUL {
            let kk = self.width(tm, t, k);
            self.need(x.a, kk);
            self.need(x.b, kk);
        } else if x.op == T_NEG {
            let kk = self.width(tm, t, k);
            self.need(x.a, kk);
        } else if x.op == T_BAND || x.op == T_BOR || x.op == T_BXOR {
            self.need(x.a, w);
            self.need(x.b, w);
        } else if x.op == T_BNOT || x.op == T_CAST {
            self.need(x.a, w);
        } else if x.op == T_SHL || x.op == T_SHR {
            self.need(x.a, w);
            let nb = self.nat_of(tm, x.b);
            self.need(x.b, nb);
            if x.op == T_SHR && x.sg {
                let na = self.nat_of(tm, x.a);
                self.need(x.a, na.max(w));
            }
        } else if x.op == T_DIV || x.op == T_REM || x.op == T_ORD {
            let n = self.nat_of(tm, x.a).max(self.nat_of(tm, x.b));
            self.need(x.a, n);
            self.need(x.b, n);
        } else if x.op == T_FFMA {
            for j in x.a..x.a + 3 {
                self.need(tm.args[j as usize], w);
            }
        } else if x.op == T_ITOF {
            let n = self.nat_of(tm, x.a);
            self.need(x.a, n);
        } else if float_op(x.op) {
            let wa = tm.at(x.a).w as u32;
            self.need(x.a, wa);
            if !unary_op(x.op) {
                self.need(x.b, wa);
            }
        }
    }

    // ---- widths ---------------------------------------------------------------------------------

    // The bits of `t`'s exact value as a signed number: every value it can take fits. Past NAT_MAX
    // the encoding stops (`ok`).
    fn nat_of(self: &mut Self, tm: &Terms<B>, t0: u32) u32 {
        if let Some(n) = self.nat.get(&t0) {
            return *n;
        }
        self.nstack.clear();
        self.nstack.push(t0);
        for _s in 0..WORK_MAX {
            if self.nstack.len() == 0 {
                break;
            }
            let t = self.nstack[self.nstack.len() - 1];
            if self.nat.contains_key(&t) {
                let _ = self.nstack.pop();
                continue;
            }
            let x = tm.at(t);
            let two = x.op == T_ADD || x.op == T_SUB || x.op == T_MUL || x.op == T_REM;
            let one = two || x.op == T_NEG || x.op == T_SHR && x.sg;
            let na = if one {
                self.nat.get(&x.a)
            } else {
                Option::<&u32>::None
            };
            let nb = if two {
                self.nat.get(&x.b)
            } else {
                Option::<&u32>::None
            };
            if one && na.is_none() || two && nb.is_none() {
                if one && na.is_none() {
                    self.nstack.push(x.a);
                }
                if two && nb.is_none() {
                    self.nstack.push(x.b);
                }
                continue;
            }
            let a = switch na {
                Some(v) => *v,
                None => 0,
            };
            let b = switch nb {
                Some(v) => *v,
                None => 0,
            };
            let w = x.w as u32;
            let mut n = if x.op == T_INT {
                min_bits(x.k)
            } else if x.op == T_ADD || x.op == T_SUB {
                a.max(b) + 1
            } else if x.op == T_NEG {
                a + 1
            } else if x.op == T_MUL {
                a + b
            } else if x.op == T_REM {
                a.min(b)
            } else if x.op == T_SHR && x.sg {
                a.max(w)
            } else if x.op == T_ORD {
                2
            } else {
                w + (!x.sg) as u32
            };
            if n > NAT_MAX {
                self.ok = false;
                n = NAT_MAX;
            }
            self.nat.insert(t, n);
            let _ = self.nstack.pop();
        }
        return switch self.nat.get(&t0) {
            Some(n) => *n,
            None => {
                self.ok = false;
                1
            },
        };
    }

    // The low `k` bits of `t` into `out`, sign-extended past the width they are kept at.
    fn get(self: &mut Self, tm: &Terms<B>, t: u32, k: u32, out: &mut Vector<u32>) {
        out.clear();
        let kk = self.width(tm, t, k);
        let s = *self.vk.get(&(t as u64 << 16 | kk as u64)).unwrap();
        for i in 0..k {
            out.push(self.vecs[(s + i.min(kk - 1)) as usize]);
        }
    }

    fn keep(self: &mut Self, t: u32, v: &Vector<u32>) {
        self.vk.insert(t as u64 << 16 | v.len() as u64, self.vecs.len() as u32);
        self.vecs.extend_copy(v);
    }

    // ---- building one demand ----------------------------------------------------------------------

    fn build(self: &mut Self, tm: &Terms<B>, d: u64) {
        let t = (d >> 16) as u32;
        let k = (d & 0xFFFF) as u32;
        let x = tm.at(t);
        if k == KB {
            let l = self.formula(tm, t, &x);
            self.fm.insert(t, l);
            return;
        }
        let kk = self.width(tm, t, k);
        let w = x.w as u32;
        let mut r = Vector::<u32>::with_capacity(kk as usize);
        let mut p = Vector::<u32>::new();
        let mut q = Vector::<u32>::new();
        if x.op == T_INT {
            for i in 0..kk {
                r.push(pick(num_bit(x.k, i), L_TRUE, L_FALSE));
            }
        } else if x.op == T_ADD || x.op == T_SUB {
            self.get(tm, x.a, kk, &mut p);
            self.get(tm, x.b, kk, &mut q);
            if x.op == T_SUB {
                for i in 0..kk {
                    q.set(i as usize, q[i as usize] ^ 1);
                }
            }
            self.add(&p, &q, pick(x.op == T_SUB, L_TRUE, L_FALSE), &mut r);
        } else if x.op == T_NEG {
            self.get(tm, x.a, kk, &mut q);
            for i in 0..kk {
                p.push(L_FALSE);
                q.set(i as usize, q[i as usize] ^ 1);
            }
            self.add(&p, &q, L_TRUE, &mut r);
        } else if x.op == T_MUL {
            self.get(tm, x.a, kk, &mut p);
            self.get(tm, x.b, kk, &mut q);
            self.mul(&p, &q, &mut r);
        } else if x.op == T_BAND || x.op == T_BOR || x.op == T_BXOR {
            self.get(tm, x.a, w, &mut p);
            self.get(tm, x.b, w, &mut q);
            for i in 0..w as usize {
                r.push(
                    if x.op == T_BAND {
                        self.and2(p[i], q[i])
                    } else if x.op == T_BOR {
                        self.and2(p[i] ^ 1, q[i] ^ 1) ^ 1
                    } else {
                        self.xor2(p[i], q[i])
                    },
                );
            }
            sign_of(&mut r, x.sg);
        } else if x.op == T_BNOT || x.op == T_CAST {
            self.get(tm, x.a, w, &mut p);
            for i in 0..w as usize {
                r.push(p[i] ^ (x.op == T_BNOT) as u32);
            }
            sign_of(&mut r, x.sg);
        } else if x.op == T_SHL || x.op == T_SHR {
            self.shift(tm, &x, &mut r);
        } else if x.op == T_DIV || x.op == T_REM {
            self.divide(tm, &x, &mut r);
        } else if float_op(x.op) {
            self.float_value(tm, &x, &mut r);
            self.keep(t, &r);
            self.float_lemmas(tm, t, &x);
            return;
        } else if x.op == T_ORD {
            let n = self.nat_of(tm, x.a).max(self.nat_of(tm, x.b));
            self.get(tm, x.a, n, &mut p);
            self.get(tm, x.b, n, &mut q);
            let lt = self.slt(&p, &q);
            let eq = self.eqv(&p, &q);
            r.push(eq ^ 1);
            r.push(lt);
        } else {
            // An unknown of its type.
            self.fresh_of(w, x.sg, &mut r);
            self.leaves.push(t);
        }
        self.keep(t, &r);
    }

    fn formula(self: &mut Self, tm: &Terms<B>, t: u32, x: &Term<B>) u32 {
        if x.op == T_BOOL {
            return pick(x.k.is_zero(), L_FALSE, L_TRUE);
        }
        if x.op == T_NOT {
            return *self.fm.get(&x.a).unwrap() ^ 1;
        }
        if x.op == T_AND || x.op == T_OR || x.op == T_EQ || x.op == T_NE {
            if let Some(a0) = self.fm.get(&x.a) {
                let a = *a0;
                if let Some(b0) = self.fm.get(&x.b) {
                    let b = *b0;
                    if x.op == T_AND || x.op == T_OR {
                        let ne = (x.op == T_OR) as u32;
                        return self.and2(a ^ ne, b ^ ne) ^ ne;
                    }
                    if tm.is_bool(x.a) && tm.is_bool(x.b) {
                        return self.xor2(a, b) ^ (x.op == T_EQ) as u32;
                    }
                }
            }
        }
        if self.bits && Blaster::<B>::is_cmp(tm, x) {
            let n = self.nat_of(tm, x.a).max(self.nat_of(tm, x.b));
            let mut p = Vector::<u32>::new();
            let mut q = Vector::<u32>::new();
            self.get(tm, x.a, n, &mut p);
            self.get(tm, x.b, n, &mut q);
            if x.op == T_LT {
                return self.slt(&p, &q);
            }
            if x.op == T_LE {
                return self.slt(&q, &p) ^ 1;
            }
            return self.eqv(&p, &q) ^ (x.op == T_NE) as u32;
        }
        if self.bits && float_op(x.op) {
            return self.float_cmp(tm, x);
        }
        // An atom; an integer equality also has its two orders, one of which holds when it does not.
        let v = self.atom(t, SEL_ATOM);
        if !self.bits && Blaster::<B>::is_cmp(tm, x) && (x.op == T_EQ || x.op == T_NE) {
            let lt = self.atom(t, SEL_LT);
            let gt = self.atom(t, SEL_GT);
            self.cnf.lits.push(v ^ (x.op == T_NE) as u32);
            self.cnf.lits.push(lt);
            self.cnf.lits.push(gt);
            self.cnf.end();
        }
        return v;
    }

    fn atom(self: &mut Self, t: u32, sel: u64) u32 {
        let key = t as u64 << 2 | sel;
        if let Some(v) = self.atoms.get(&key) {
            return *v << 1;
        }
        let l = self.fresh();
        self.atoms.insert(key, l >> 1);
        return l;
    }

    // ---- gates ----------------------------------------------------------------------------------

    const fn fresh(self: &mut Self) u32 {
        let v = self.cnf.nv;
        self.cnf.nv += 1;
        if self.cnf.lits.len() > CNF_MAX {
            self.ok = false;
        }
        return v << 1;
    }

    fn clause(self: &mut Self, a: u32, b: u32, c: u32) {
        self.cnf.lits.push(a);
        self.cnf.lits.push(b);
        if c != NONE {
            self.cnf.lits.push(c);
        }
        self.cnf.end();
    }

    // An unknown of type (`w`, `sg`): `w` fresh bits, and a zero sign when unsigned.
    fn fresh_of(self: &mut Self, w: u32, sg: bool, out: &mut Vector<u32>) {
        out.clear();
        for _i in 0..w {
            out.push(self.fresh());
        }
        sign_of(out, sg);
    }

    fn and2(self: &mut Self, a: u32, b: u32) u32 {
        if a == L_FALSE || b == L_FALSE || a == (b ^ 1) {
            return L_FALSE;
        }
        if a == L_TRUE || a == b {
            return b;
        }
        if b == L_TRUE {
            return a;
        }
        let key = 1u64 << 62 | a.min(b) as u64 << 31 | a.max(b) as u64;
        if let Some(v) = self.gates.get(&key) {
            return *v;
        }
        let v = self.fresh();
        self.clause(v ^ 1, a, NONE);
        self.clause(v ^ 1, b, NONE);
        self.clause(v, a ^ 1, b ^ 1);
        self.gates.insert(key, v);
        return v;
    }

    fn xor2(self: &mut Self, a0: u32, b0: u32) u32 {
        if a0 == L_FALSE {
            return b0;
        }
        if b0 == L_FALSE {
            return a0;
        }
        if a0 == L_TRUE {
            return b0 ^ 1;
        }
        if b0 == L_TRUE {
            return a0 ^ 1;
        }
        if a0 == b0 {
            return L_FALSE;
        }
        if a0 == (b0 ^ 1) {
            return L_TRUE;
        }
        let neg = (a0 ^ b0) & 1;
        let a = a0 & ~1u32;
        let b = b0 & ~1u32;
        let key = 2u64 << 62 | a.min(b) as u64 << 31 | a.max(b) as u64;
        if let Some(v) = self.gates.get(&key) {
            return *v ^ neg;
        }
        let v = self.fresh();
        self.clause(v ^ 1, a, b);
        self.clause(v ^ 1, a ^ 1, b ^ 1);
        self.clause(v, a ^ 1, b);
        self.clause(v, a, b ^ 1);
        self.gates.insert(key, v);
        return v ^ neg;
    }

    // `s ? t : e`.
    fn mux(self: &mut Self, s: u32, t: u32, e: u32) u32 {
        if s == L_TRUE || t == e {
            return t;
        }
        if s == L_FALSE {
            return e;
        }
        if t == (e ^ 1) {
            return self.xor2(s, e);
        }
        if t == L_TRUE || t == s {
            return self.and2(s ^ 1, e ^ 1) ^ 1;
        }
        if t == L_FALSE || t == (s ^ 1) {
            return self.and2(s ^ 1, e);
        }
        if e == L_TRUE || e == (s ^ 1) {
            return self.and2(s, t ^ 1) ^ 1;
        }
        if e == L_FALSE || e == s {
            return self.and2(s, t);
        }
        // One gate per inputs: `s ? t : e` is `!s ? e : t`.
        let (s1, t1, e1) = pick((s & 1) != 0, (s ^ 1, e, t), (s, t, e));
        let key = s1 as u64 << 42 | t1 as u64 << 21 | e1 as u64;
        let small = (s1 | t1 | e1) < 1 << 21;
        if small {
            if let Some(v) = self.muxes.get(&key) {
                return *v;
            }
        }
        let v = self.fresh();
        if small {
            self.muxes.insert(key, v);
        }
        self.clause(s ^ 1, t ^ 1, v);
        self.clause(s ^ 1, t, v ^ 1);
        self.clause(s, e ^ 1, v);
        self.clause(s, e, v ^ 1);
        self.clause(t ^ 1, e ^ 1, v);
        self.clause(t, e, v ^ 1);
        return v;
    }

    // At least two of `a`, `b`, `c`.
    fn maj(self: &mut Self, a: u32, b: u32, c: u32) u32 {
        if a == b || a == c {
            return a;
        }
        if b == c {
            return b;
        }
        if a == (b ^ 1) {
            return c;
        }
        if a == (c ^ 1) {
            return b;
        }
        if b == (c ^ 1) {
            return a;
        }
        // A constant: true makes it `or` of the other two, false `and`.
        let (k, x, y) = if a <= L_FALSE {
            (a, b, c)
        } else if b <= L_FALSE {
            (b, a, c)
        } else {
            (c, a, b)
        };
        if k <= L_FALSE {
            let ne = (k == L_TRUE) as u32;
            return self.and2(x ^ ne, y ^ ne) ^ ne;
        }
        let v = self.fresh();
        self.clause(a ^ 1, b ^ 1, v);
        self.clause(a ^ 1, c ^ 1, v);
        self.clause(b ^ 1, c ^ 1, v);
        self.clause(a, b, v ^ 1);
        self.clause(a, c, v ^ 1);
        self.clause(b, c, v ^ 1);
        return v;
    }

    // ---- circuits over vectors of equal length -------------------------------------------------

    // `x + y + cin` modulo 2^n.
    fn add(self: &mut Self, x: &Vector<u32>, y: &Vector<u32>, cin: u32, out: &mut Vector<u32>) {
        out.clear();
        let mut c = cin;
        for i in 0..x.len() {
            let s = self.xor2(x[i], y[i]);
            out.push(self.xor2(s, c));
            c = self.maj(x[i], y[i], c);
        }
    }

    // `x * y` modulo 2^n: a row of partial products per bit of the operand with fewer unknown bits.
    fn mul(self: &mut Self, x0: &Vector<u32>, y0: &Vector<u32>, out: &mut Vector<u32>) {
        let n = x0.len();
        let mut free_x: usize = 0;
        let mut free_y: usize = 0;
        for i in 0..n {
            free_x += (x0[i] > L_FALSE) as usize;
            free_y += (y0[i] > L_FALSE) as usize;
        }
        let (x, y) = pick(free_y <= free_x, (x0, y0), (y0, x0));
        out.clear();
        for _i in 0..n {
            out.push(L_FALSE);
        }
        let mut pp = Vector::<u32>::with_capacity(n);
        let mut acc = Vector::<u32>::with_capacity(n);
        let mut sum = Vector::<u32>::with_capacity(n);
        for i in 0..n {
            if y[i] == L_FALSE || !self.ok {
                continue;
            }
            pp.clear();
            acc.clear();
            for j in i..n {
                pp.push(self.and2(x[j - i], y[i]));
                acc.push(out[j]);
            }
            self.add(&acc, &pp, L_FALSE, &mut sum);
            for j in i..n {
                out.set(j, sum[j - i]);
            }
        }
    }

    // `x < y` as unsigned numbers.
    fn ult(self: &mut Self, x: &Vector<u32>, y: &Vector<u32>) u32 {
        let mut lt = L_FALSE;
        for i in 0..x.len() {
            let d = self.xor2(x[i], y[i]);
            lt = self.mux(d, y[i], lt);
        }
        return lt;
    }

    // `x < y` as two's-complement numbers: the unsigned order with the sign bits flipped.
    fn slt(self: &mut Self, x: &Vector<u32>, y: &Vector<u32>) u32 {
        let n = x.len();
        let mut p = x.clone();
        let mut q = y.clone();
        p.set(n - 1, x[n - 1] ^ 1);
        q.set(n - 1, y[n - 1] ^ 1);
        return self.ult(&p, &q);
    }

    fn eqv(self: &mut Self, x: &Vector<u32>, y: &Vector<u32>) u32 {
        let mut e = L_TRUE;
        for i in 0..x.len() {
            let d = self.xor2(x[i], y[i]);
            e = self.and2(e, d ^ 1);
        }
        return e;
    }

    // `x` negated when `s` holds, modulo 2^n.
    fn neg_if(self: &mut Self, s: u32, x: &Vector<u32>, out: &mut Vector<u32>) {
        let mut y = Vector::<u32>::with_capacity(x.len());
        let mut z = Vector::<u32>::with_capacity(x.len());
        for i in 0..x.len() {
            y.push(self.xor2(x[i], s));
            z.push(L_FALSE);
        }
        self.add(&y, &z, s, out);
    }

    fn mux_vec(self: &mut Self, s: u32, t: &Vector<u32>, e: &Vector<u32>, out: &mut Vector<u32>) {
        out.clear();
        for i in 0..t.len() {
            out.push(self.mux(s, t[i], e[i]));
        }
    }

    // ---- shifts and division ----------------------------------------------------------------------

    // `a << b` or `a >> b` of type (w, sg) (`Eval::apply`): the low `w` bits of `a` shifted; a signed
    // `>>` of a negative `a` is the floor of `a / 2^b` over `a`'s exact value. A count below 0 or of the
    // width or more is not defined (any value of the type), but a wide shift (`k` 1) of a count past
    // the width gives 0, or -1 for a negative `a` shifted right.
    fn shift(self: &mut Self, tm: &Terms<B>, x: &Term<B>, r: &mut Vector<u32>) {
        let w = x.w as u32;
        let left = x.op == T_SHL;
        let arith = !left && x.sg;
        let mut xa = Vector::<u32>::new();
        let mut cb = Vector::<u32>::new();
        self.get(tm, x.a, w, &mut xa);
        let nb = self.nat_of(tm, x.b);
        self.get(tm, x.b, nb, &mut cb);
        // 0 <= b < w, and b >= w.
        let nw = nb.max(min_bits(wide::<B>(w)));
        let mut bw = Vector::<u32>::new();
        let mut wv = Vector::<u32>::new();
        for i in 0..nw {
            bw.push(cb[i.min(nb - 1) as usize]);
            wv.push(pick(i < 32 && (w >> i & 1) != 0, L_TRUE, L_FALSE));
        }
        let nonneg = cb[(nb - 1) as usize] ^ 1;
        let below = self.slt(&bw, &wv);
        let inr = self.and2(nonneg, below);
        let n = if arith {
            self.nat_of(tm, x.a).max(w)
        } else {
            w
        };
        let mut sh = Vector::<u32>::new();
        self.barrel(&xa, &cb, left, false, &mut sh);
        sign_of(&mut sh, x.sg);
        let mut neg = L_FALSE;
        if arith {
            // The pattern's shift read as signed, against the floor of the exact value.
            let mut aa = Vector::<u32>::new();
            self.get(tm, x.a, n, &mut aa);
            neg = aa[(n - 1) as usize];
            for _i in w..n {
                sh.push(sh[(w - 1) as usize]);
            }
            let mut fl = Vector::<u32>::new();
            self.barrel(&aa, &cb, false, true, &mut fl);
            let mut m = Vector::<u32>::new();
            self.mux_vec(neg, &fl, &sh, &mut m);
            sh = m;
        }
        if inr == L_TRUE {
            r.extend_copy(&sh);
            return;
        }
        let mut other = Vector::<u32>::new();
        self.fresh_of(w, x.sg, &mut other);
        for _i in other.len() as u32..sh.len() as u32 {
            other.push(other[other.len() - 1]);
        }
        if !x.k.is_zero() {
            let big = self.and2(nonneg, below ^ 1);
            let mut past = Vector::<u32>::new();
            for _i in 0..sh.len() {
                past.push(pick(arith, neg, L_FALSE));
            }
            let mut m = Vector::<u32>::new();
            self.mux_vec(big, &past, &other, &mut m);
            other = m;
        }
        self.mux_vec(inr, &sh, &other, r);
    }

    // `v` shifted by the low bits of count `c` (a barrel: one stage per bit below the width): left with
    // zeros, right with zeros or (`fill`) the top bit.
    fn barrel(self: &mut Self, v: &Vector<u32>, c: &Vector<u32>, left: bool, fill: bool, out: &mut Vector<u32>) {
        let n = v.len();
        let mut cur = v.clone();
        let mut nxt = Vector::<u32>::with_capacity(n);
        let mut i: usize = 0;
        for _s in 0..16 {
            if 1usize << i >= n {
                break;
            }
            let s = c[i.min(c.len() - 1)];
            let d = 1usize << i;
            nxt.clear();
            for j in 0..n {
                let moved = if left && j >= d {
                    cur[j - d]
                } else if left {
                    L_FALSE
                } else if j + d < n {
                    cur[j + d]
                } else {
                    pick(fill, cur[n - 1], L_FALSE)
                };
                nxt.push(self.mux(s, moved, cur[j]));
            }
            cur.clear();
            cur.extend_copy(&nxt);
            i += 1;
        }
        out.clear();
        out.extend_copy(&cur);
    }

    // `a / b` or `a % b` of type (w, sg), truncated toward zero, the remainder with `a`'s sign: the
    // magnitudes by restoring division, the signs after. A zero divisor or a quotient outside the type
    // is not defined (any value).
    fn divide(self: &mut Self, tm: &Terms<B>, x: &Term<B>, r: &mut Vector<u32>) {
        let w = x.w as u32;
        let n = self.nat_of(tm, x.a).max(self.nat_of(tm, x.b));
        let mut av = Vector::<u32>::new();
        let mut bv = Vector::<u32>::new();
        self.get(tm, x.a, n, &mut av);
        self.get(tm, x.b, n, &mut bv);
        let sa = av[(n - 1) as usize];
        let sb = bv[(n - 1) as usize];
        let mut ua = Vector::<u32>::new();
        let mut ub = Vector::<u32>::new();
        self.neg_if(sa, &av, &mut ua);
        self.neg_if(sb, &bv, &mut ub);
        // Restoring division of n-bit magnitudes: each step compares the remainder with `ub` over n + 2
        // bits.
        let mut q0 = Vector::<u32>::with_capacity(n as usize);
        let mut rem = Vector::<u32>::with_capacity(n as usize);
        for _i in 0..n {
            q0.push(L_FALSE);
            rem.push(L_FALSE);
        }
        let mut wide_r = Vector::<u32>::new();
        let mut negb = Vector::<u32>::new();
        let mut diff = Vector::<u32>::new();
        let mut pick_r = Vector::<u32>::new();
        for j in 0..n as usize {
            negb.push(ub[j] ^ 1);
        }
        negb.push(L_TRUE);
        negb.push(L_TRUE);
        for s in 0..n {
            if !self.ok {
                return;
            }
            let i = (n - 1 - s) as usize;
            wide_r.clear();
            wide_r.push(ua[i]);
            for j in 0..n as usize {
                wide_r.push(rem[j]);
            }
            wide_r.push(L_FALSE);
            self.add(&wide_r, &negb, L_TRUE, &mut diff);
            let ge = diff[(n + 1) as usize] ^ 1;
            q0.set(i, ge);
            self.mux_vec(ge, &diff, &wide_r, &mut pick_r);
            for j in 0..n as usize {
                rem.set(j, pick_r[j]);
            }
        }
        let mut nz = L_FALSE;
        for j in 0..n as usize {
            nz = self.and2(nz ^ 1, bv[j] ^ 1) ^ 1;
        }
        let mut q = Vector::<u32>::new();
        q0.push(L_FALSE);
        let sq = self.xor2(sa, sb);
        self.neg_if(sq, &q0, &mut q);
        // The quotient lies in the type: lo <= q <= hi over n + 1 bits or the type's width.
        let (lo, hi) = Terms::<B>::range(x.w, x.sg);
        let m = (n + 1).max(w + 1);
        let mut qm = Vector::<u32>::new();
        let mut lv = Vector::<u32>::new();
        let mut hv = Vector::<u32>::new();
        for i in 0..m {
            qm.push(q[i.min(n) as usize]);
            lv.push(pick(num_bit(lo, i), L_TRUE, L_FALSE));
            hv.push(pick(num_bit(hi, i), L_TRUE, L_FALSE));
        }
        let under = self.slt(&qm, &lv);
        let over = self.slt(&hv, &qm);
        let fits = self.and2(under ^ 1, over ^ 1);
        let def = self.and2(nz, fits);
        let mut val = Vector::<u32>::new();
        let mut other = Vector::<u32>::new();
        if x.op == T_DIV {
            let kk = w + (!x.sg) as u32;
            for i in 0..kk {
                val.push(qm[i.min(m - 1) as usize]);
            }
            self.fresh_of(w, x.sg, &mut other);
        } else {
            let kk = self.nat_of(tm, x.a).min(self.nat_of(tm, x.b));
            rem.push(L_FALSE);
            let mut rs = Vector::<u32>::new();
            self.neg_if(sa, &rem, &mut rs);
            for i in 0..kk {
                val.push(rs[i.min(n) as usize]);
                other.push(self.fresh());
            }
        }
        if def == L_TRUE {
            r.extend_copy(&val);
            return;
        }
        self.mux_vec(def, &val, &other, r);
    }
    // ---- floats -----------------------------------------------------------------------------------
    //
    // A float of width w and format code fd (`Terms`) is the bits of its encoding: M = F fraction bits, E =
    // w - 1 - M exponent bits, the sign. Each operation computes its exact result as an integer X times 2^Z
    // (Z a signed exponent of `fx` bits), or X with a last bit that stands for a nonzero rest below it; one
    // rounding (`round_pack`) then gives the encoding. An exact result X with such a rest bit rounds as the
    // exact value when the rounding unit is at least 2 of X's units: the exact value lies strictly between
    // two such units, so it lies on the side of every midpoint that X does.

    // `v`'s low `n` bits as constants.
    fn kbits(v: i64, n: u32, out: &mut Vector<u32>) {
        out.clear();
        for i in 0..n {
            let b = if i < 63 {
                (v >> i as i64 & 1) != 0
            } else {
                v < 0
            };
            out.push(pick(b, L_TRUE, L_FALSE));
        }
    }

    // Whether any of `v[from..to)` holds.
    fn any(self: &mut Self, v: &Vector<u32>, from: usize, to: usize) u32 {
        let mut r = L_FALSE;
        for i in from..to {
            r = self.and2(r ^ 1, v[i] ^ 1) ^ 1;
        }
        return r;
    }

    // Whether all of `v[from..to)` hold.
    fn all(self: &mut Self, v: &Vector<u32>, from: usize, to: usize) u32 {
        let mut r = L_TRUE;
        for i in from..to {
            r = self.and2(r, v[i]);
        }
        return r;
    }

    fn or2(self: &mut Self, a: u32, b: u32) u32 {
        return self.and2(a ^ 1, b ^ 1) ^ 1;
    }

    // `x - y` modulo 2^n.
    fn sub(self: &mut Self, x: &Vector<u32>, y: &Vector<u32>, out: &mut Vector<u32>) {
        let mut ny = Vector::<u32>::with_capacity(y.len());
        for i in 0..y.len() {
            ny.push(y[i] ^ 1);
        }
        self.add(x, &ny, L_TRUE, out);
    }

    // `x - k` of a signed exponent.
    fn sub_k(self: &mut Self, x: &Vector<u32>, k: i64, out: &mut Vector<u32>) {
        let mut kv = Vector::<u32>::new();
        Blaster::<B>::kbits(k, x.len() as u32, &mut kv);
        self.sub(x, &kv, out);
    }

    // The format of width `w` and code `fd`: (E, M, whether it has no infinities).
    const fn fmt(w: u32, fd: u64) (u32, u32, bool) {
        let m = (fd & 0xFFFF) as u32;
        return w - 1 - m, m, (fd & FD_FINITE) != 0;
    }

    // The width of signed exponents that holds every exponent an operation on format (`w`, `fd`) computes:
    // the sum of two biased exponents, less twice the bias and the fraction bits.
    const fn fx_of(w: u32, fd: u64) u32 {
        let (e, _m, _fo) = Blaster::<B>::fmt(w, fd);
        return (e + 4).max(16);
    }

    // The fields of encoding `x` of width `w`, format `fd`.
    fn unpack(self: &mut Self, x: &Vector<u32>, w: u32, fd: u64) Fp {
        let (e, m, fo) = Blaster::<B>::fmt(w, fd);
        let en = self.any(x, m as usize, (m + e) as usize);
        let eall = self.all(x, m as usize, (m + e) as usize);
        let fnz = self.any(x, 0, m as usize);
        // The significand with its hidden bit; the exponent of a subnormal as 1.
        let mut sig = Vector::<u32>::with_capacity((m + 1) as usize);
        for i in 0..m {
            sig.push(x[i as usize]);
        }
        sig.push(en);
        let mut ee = Vector::<u32>::with_capacity(self.fx as usize);
        for i in 0..self.fx {
            ee.push(
                if i == 0 {
                    self.or2(x[m as usize], en ^ 1)
                } else if i < e {
                    x[(m + i) as usize]
                } else {
                    L_FALSE
                },
            );
        }
        let (inf, nan) = if fo {
            let fall = self.all(x, 0, m as usize);
            (L_FALSE, self.and2(eall, fall))
        } else {
            (self.and2(eall, fnz ^ 1), self.and2(eall, fnz))
        };
        return Fp { s: x[(w - 1) as usize], zero: self.and2(en ^ 1, fnz ^ 1), inf: inf, nan: nan, sig: sig, ee: ee };
    }

    // `v` shifted left until its top bit is set, into `out`, and the count of its leading zeros into
    // `lz` (fx bits); a zero `v` gives zeros.
    fn normalize(self: &mut Self, v: &Vector<u32>, out: &mut Vector<u32>, lz: &mut Vector<u32>) {
        let n = v.len();
        let mut cur = v.clone();
        let mut nxt = Vector::<u32>::with_capacity(n);
        lz.clear();
        for _i in 0..self.fx {
            lz.push(L_FALSE);
        }
        let mut j: usize = 0;
        for _s in 0..16 {
            if 1usize << j + 1 >= n {
                break;
            }
            j += 1;
        }
        for s in 0..j + 1 {
            let jj = j - s;
            let k = 1usize << jj;
            if k >= n {
                continue;
            }
            let z = self.any(&cur, n - k, n) ^ 1;
            nxt.clear();
            for i in 0..n {
                let moved = pick(i >= k, cur[i - pick(i >= k, k, 0)], L_FALSE);
                nxt.push(self.mux(z, moved, cur[i]));
            }
            cur.clear();
            cur.extend_copy(&nxt);
            lz.set(jj, z);
        }
        out.clear();
        out.extend_copy(&cur);
    }

    // `v` shifted right by the unsigned `amt`, the bits shifted out ORed into the last bit.
    fn shr_sticky(self: &mut Self, v: &Vector<u32>, amt: &Vector<u32>, out: &mut Vector<u32>) {
        let n = v.len();
        let mut cur = v.clone();
        let mut nxt = Vector::<u32>::with_capacity(n);
        let mut i: usize = 0;
        for _s in 0..32 {
            if 1usize << i >= n || i >= amt.len() {
                break;
            }
            let s = amt[i];
            let d = 1usize << i;
            let st = self.any(&cur, 0, d);
            nxt.clear();
            for j in 0..n {
                let moved = pick(j + d < n, cur[(j + d).min(n - 1)], L_FALSE);
                nxt.push(self.mux(s, moved, cur[j]));
            }
            let lsb = self.and2(s, st);
            nxt.set(0, self.or2(nxt[0], lsb));
            cur.clear();
            cur.extend_copy(&nxt);
            i += 1;
        }
        let big = self.any(amt, i, amt.len());
        let all = self.any(v, 0, n);
        out.clear();
        for j in 0..n {
            out.push(self.mux(big, pick(j == 0, all, L_FALSE), cur[j]));
        }
    }

    // The encoding (w bits, format `fd`) of the exact value `(-1)^s * x * 2^z` rounded to nearest, ties to
    // even (`x` may end in a rest bit); an `x` of zero gives the zero of sign `zs`. Past the largest finite
    // value: infinity, or the largest finite value for a format without infinities. Without `norm` the
    // caller knows that `x`'s top bit is set, or that the value is below half the least subnormal.
    fn round_pack(
        self: &mut Self,
        s: u32,
        x0: &Vector<u32>,
        z0: &Vector<u32>,
        zs: u32,
        w: u32,
        fd: u64,
        norm: bool,
        out: &mut Vector<u32>,
    ) {
        let (e, m, fo) = Blaster::<B>::fmt(w, fd);
        let fx = self.fx;
        let bias = (1i64 << (e - 1) as i64) - 1;
        let mut x = Vector::<u32>::new();
        let mut z = Vector::<u32>::new();
        // At least M + 3 bits: the significand, the guard bit and one below.
        let pad = (m + 3).max(x0.len() as u32) - x0.len() as u32;
        for _i in 0..pad {
            x.push(L_FALSE);
        }
        x.extend_copy(x0);
        self.sub_k(z0, pad, &mut z);
        let n = x.len() as u32;
        let nz = self.any(&x, 0, n as usize);
        let mut xn = Vector::<u32>::new();
        let mut lz = Vector::<u32>::new();
        if norm {
            self.normalize(&x, &mut xn, &mut lz);
        } else {
            xn.extend_copy(&x);
            Blaster::<B>::kbits(0, fx, &mut lz);
        }
        // The biased exponent of the top bit: z + n - 1 + bias - lz.
        let mut t = Vector::<u32>::new();
        let mut be = Vector::<u32>::new();
        let mut kv = Vector::<u32>::new();
        Blaster::<B>::kbits(n as i64 - 1 + bias, fx, &mut kv);
        self.add(&z, &kv, L_FALSE, &mut t);
        self.sub(&t, &lz, &mut be);
        // A biased exponent below 1 is a subnormal: shifted right by 1 - be, at exponent field 0.
        Blaster::<B>::kbits(1, fx, &mut kv);
        let tiny = self.slt(&be, &kv);
        let mut d = Vector::<u32>::new();
        self.sub(&kv, &be, &mut d);
        let mut zero = Vector::<u32>::new();
        Blaster::<B>::kbits(0, fx, &mut zero);
        let mut sh = Vector::<u32>::new();
        self.mux_vec(tiny, &d, &zero, &mut sh);
        let mut y = Vector::<u32>::new();
        self.shr_sticky(&xn, &sh, &mut y);
        let top = (n - m - 1) as usize;
        let g = y[top - 1];
        let st = self.any(&y, 0, top - 1);
        let up0 = self.or2(st, y[top]);
        let up = self.and2(g, up0);
        // The encoding without its sign: (exponent - 1) << M plus the significand, whose top bit then adds
        // the 1 back; a carry of the rounding moves into the exponent.
        let mut em = Vector::<u32>::new();
        let mut bm1 = Vector::<u32>::new();
        self.sub_k(&be, 1, &mut bm1);
        self.mux_vec(tiny, &zero, &bm1, &mut em);
        let mut pb = Vector::<u32>::new();
        let mut ps = Vector::<u32>::new();
        for i in 0..m + fx {
            pb.push(pick(i < m, L_FALSE, em[(i - pick(i < m, 0, m)).min(fx - 1) as usize]));
            ps.push(pick(i <= m, y[(top as u32 + i.min(m)) as usize], L_FALSE));
        }
        let mut p = Vector::<u32>::new();
        self.add(&pb, &ps, up, &mut p);
        let mut phi = Vector::<u32>::new();
        for i in m..m + fx {
            phi.push(p[i as usize]);
        }
        // Past the largest exponent field (or, without infinities, on the NaN encoding): the largest
        // finite value (all ones but the last fraction bit), or infinity (an all-ones exponent).
        let ovf = if fo {
            Blaster::<B>::kbits(1i64 << e as i64, fx, &mut kv);
            let past = self.ult(&phi, &kv) ^ 1;
            Blaster::<B>::kbits((1i64 << e as i64) - 1, fx, &mut kv);
            let top_e = self.eqv(&phi, &kv);
            let fall = self.all(&p, 0, m as usize);
            let slot = self.and2(top_e, fall);
            self.or2(past, slot)
        } else {
            Blaster::<B>::kbits((1i64 << e as i64) - 1, fx, &mut kv);
            self.ult(&phi, &kv) ^ 1
        };
        out.clear();
        for i in 0..e + m {
            let sat = pick(fo, pick(i == 0, L_FALSE, L_TRUE), pick(i >= m, L_TRUE, L_FALSE));
            let v = self.mux(ovf, sat, p[i as usize]);
            out.push(self.and2(nz, v));
        }
        out.push(self.mux(nz, s, zs));
    }

    // A NaN of width `w`, format `fd`: any sign and payload (without infinities, the one payload).
    fn fnan(self: &mut Self, w: u32, fd: u64, out: &mut Vector<u32>) {
        let (e, m, fo) = Blaster::<B>::fmt(w, fd);
        out.clear();
        if fo {
            for _i in 0..m {
                out.push(L_TRUE);
            }
        } else {
            for _i in 0..m {
                out.push(self.fresh());
            }
            self.cnf.lits.extend_copy(out);
            self.cnf.end();
        }
        for _i in 0..e {
            out.push(L_TRUE);
        }
        out.push(self.fresh());
    }

    // The infinity (without infinities, the largest finite value), or (`inf` false) the zero, of width `w`,
    // format `fd` and sign `s`.
    fn fspecial(inf: bool, s: u32, w: u32, fd: u64, out: &mut Vector<u32>) {
        let (_e, m, fo) = Blaster::<B>::fmt(w, fd);
        out.clear();
        for i in 0..w - 1 {
            out.push(pick(inf && (i >= m || fo && i > 0), L_TRUE, L_FALSE));
        }
        out.push(s);
    }

    // `c ? t : v` into `v`.
    fn take_if(self: &mut Self, c: u32, t: &Vector<u32>, v: &mut Vector<u32>) {
        if c == L_FALSE {
            return;
        }
        let mut r = Vector::<u32>::new();
        self.mux_vec(c, t, v, &mut r);
        v.clear();
        v.extend_copy(&r);
    }

    // `v` as a NaN where `c` holds (and `nan_c` with it).
    fn nan_if(self: &mut Self, c: u32, w: u32, fd: u64, v: &mut Vector<u32>) {
        if c == L_FALSE {
            return;
        }
        self.nan_c = self.or2(self.nan_c, c);
        let mut nv = Vector::<u32>::new();
        self.fnan(w, fd, &mut nv);
        self.take_if(c, &nv, v);
    }

    // The exponent `ee` of fx bits plus `k`, minus `lz` when given.
    fn exp_of(self: &mut Self, ee: &Vector<u32>, lz: &Vector<u32>, k: i64, out: &mut Vector<u32>) {
        let mut kv = Vector::<u32>::new();
        let mut t = Vector::<u32>::new();
        Blaster::<B>::kbits(k, self.fx, &mut kv);
        self.add(ee, &kv, L_FALSE, &mut t);
        if lz.len() == 0 {
            out.clear();
            out.extend_copy(&t);
            return;
        }
        self.sub(&t, lz, out);
    }

    // The sum of exact values `(-1)^sa * a * 2^ea` and `(-1)^sb * b * 2^eb`, of `a` and `b` of one width,
    // `a` the greater magnitude, normalized or at the least exponent: X and its exponent. A part of `b`
    // shifted past the guard bits is a rest bit, which happens only where `b` is below a 16th of `a`.
    fn fsum(
        self: &mut Self,
        a: &Vector<u32>,
        ea: &Vector<u32>,
        b: &Vector<u32>,
        eb: &Vector<u32>,
        sub: u32,
        x: &mut Vector<u32>,
        z: &mut Vector<u32>,
    ) {
        let mut d = Vector::<u32>::new();
        self.sub(ea, eb, &mut d);
        let mut av = Vector::<u32>::new();
        let mut bv0 = Vector::<u32>::new();
        for _i in 0..FG {
            av.push(L_FALSE);
            bv0.push(L_FALSE);
        }
        av.extend_copy(a);
        bv0.extend_copy(b);
        av.push(L_FALSE);
        bv0.push(L_FALSE);
        let mut bv = Vector::<u32>::new();
        self.shr_sticky(&bv0, &d, &mut bv);
        for i in 0..bv.len() {
            bv.set(i, self.xor2(bv[i], sub));
        }
        self.add(&av, &bv, sub, x);
        self.sub_k(ea, FG, z);
    }

    // The value of float operation `x` (`Terms::farith`, `fconv`, `frint`, `ffma`) into `r`: its encoding or
    // its integer, then the zero sign bit of an unsigned value.
    fn float_value(self: &mut Self, tm: &Terms<B>, x: &Term<B>, r: &mut Vector<u32>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let hi = x.k.limb(0) >> 32;
        let mut a = Vector::<u32>::new();
        let mut b = Vector::<u32>::new();
        let mut v = Vector::<u32>::new();
        let mut sp = Vector::<u32>::new();
        let none = Vector::<u32>::new();
        self.nan_c = L_FALSE;
        if x.op == T_FTOI {
            self.float_to_int(tm, x, r);
            return;
        }
        self.fx = Blaster::<B>::fx_of(w, fd);
        if x.op == T_ITOF {
            let n = self.nat_of(tm, x.a);
            self.get(tm, x.a, n, &mut a);
            let s = a[(n - 1) as usize];
            self.neg_if(s, &a, &mut b);
            let mut z = Vector::<u32>::new();
            Blaster::<B>::kbits(0, self.fx, &mut z);
            self.round_pack(s, &b, &z, L_FALSE, w, fd, true, &mut v);
        } else if x.op == T_FCVT || x.op == T_FSQRT {
            let k = tm.at(x.a).w as u32;
            let sfd = pick(x.op == T_FCVT, hi, fd);
            self.fx = self.fx.max(Blaster::<B>::fx_of(k, sfd));
            self.get(tm, x.a, k, &mut a);
            let fa = self.unpack(&a, k, sfd);
            let (e, m, _fo) = Blaster::<B>::fmt(k, sfd);
            let (e2, m2, _fo2) = Blaster::<B>::fmt(w, fd);
            let bias = (1i64 << (e - 1) as i64) - 1;
            if x.op == T_FSQRT {
                self.fsqrt(&a, &fa, bias + m as i64, w, fd, &mut v);
            } else {
                let bias2 = (1i64 << (e2 - 1) as i64) - 1;
                if m2 >= m && bias2 >= bias + m as i64 {
                    // Widening, where every value, a subnormal too, is a normal value of the target: the
                    // significand normalized, the exponent rebiased.
                    let mut mn = Vector::<u32>::new();
                    let mut lz = Vector::<u32>::new();
                    self.normalize(&fa.sig, &mut mn, &mut lz);
                    let mut ex = Vector::<u32>::new();
                    self.exp_of(&fa.ee, &lz, (1i64 << (e2 - 1) as i64) - 1 - bias, &mut ex);
                    for i in 0..m2 {
                        v.push(pick(i >= m2 - m, mn[(i - pick(i >= m2 - m, m2 - m, 0)).min(m) as usize], L_FALSE));
                    }
                    for i in 0..e2 {
                        v.push(ex[i as usize]);
                    }
                    v.push(fa.s);
                } else {
                    // Rounding. A source's subnormal below half the target's least one needs no
                    // normalizing: it rounds to zero either way.
                    let low = 1 - bias <= 1 - bias2 - m2 as i64 - 1;
                    let mut z = Vector::<u32>::new();
                    self.exp_of(&fa.ee, &none, -bias - m as i64, &mut z);
                    self.round_pack(fa.s, &fa.sig, &z, fa.s, w, fd, !low, &mut v);
                }
                Blaster::<B>::fspecial(false, fa.s, w, fd, &mut sp);
                self.take_if(fa.zero, &sp, &mut v);
                Blaster::<B>::fspecial(true, fa.s, w, fd, &mut sp);
                self.take_if(fa.inf, &sp, &mut v);
                self.nan_if(fa.nan, w, fd, &mut v);
            }
        } else if x.op == T_FRINT {
            self.frint(tm, x, &mut v);
        } else if x.op == T_FFMA {
            self.ffma(tm, x, &mut v);
        } else if x.op == T_FREM {
            self.frem(tm, x, &mut v);
        } else if x.op == T_FKEY {
            // A positive value's bits with the sign set; a negative value's complemented.
            self.get(tm, x.a, w, &mut a);
            let s = a[(w - 1) as usize];
            for i in 0..w - 1 {
                v.push(self.xor2(a[i as usize], s));
            }
            v.push(s ^ 1);
        } else {
            self.float_arith(tm, x, &mut v);
        }
        r.clear();
        r.extend_copy(&v);
        sign_of(r, false);
    }

    // `a + b`, `a * b` or `a / b` (`Terms::farith`) into `v`.
    fn float_arith(self: &mut Self, tm: &Terms<B>, x: &Term<B>, v: &mut Vector<u32>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let mut a = Vector::<u32>::new();
        let mut b = Vector::<u32>::new();
        let mut sp = Vector::<u32>::new();
        self.get(tm, x.a, w, &mut a);
        self.get(tm, x.b, w, &mut b);
        let fa = self.unpack(&a, w, fd);
        let fb = self.unpack(&b, w, fd);
        let (e, m, fo) = Blaster::<B>::fmt(w, fd);
        let bias = (1i64 << (e - 1) as i64) - 1;
        let s = self.xor2(fa.s, fb.s);
        if x.op == T_FADD {
            // The operand of greater magnitude first: its exponent is the greater too.
            let mut ma = Vector::<u32>::new();
            let mut mb = Vector::<u32>::new();
            for i in 0..w - 1 {
                ma.push(a[i as usize]);
                mb.push(b[i as usize]);
            }
            let swap = self.ult(&ma, &mb);
            let sbig = self.mux(swap, fb.s, fa.s);
            let mut eb = Vector::<u32>::new();
            let mut es = Vector::<u32>::new();
            let mut gb = Vector::<u32>::new();
            let mut gs = Vector::<u32>::new();
            self.mux_vec(swap, &fb.ee, &fa.ee, &mut eb);
            self.mux_vec(swap, &fa.ee, &fb.ee, &mut es);
            self.mux_vec(swap, &fb.sig, &fa.sig, &mut gb);
            self.mux_vec(swap, &fa.sig, &fb.sig, &mut gs);
            let mut xv = Vector::<u32>::new();
            let mut z = Vector::<u32>::new();
            self.fsum(&gb, &eb, &gs, &es, s, &mut xv, &mut z);
            let mut z2 = Vector::<u32>::new();
            self.sub_k(&z, bias + m as i64, &mut z2);
            // An exact zero is +0, but -0 for two -0s.
            let zs = self.and2(s ^ 1, fa.s);
            self.round_pack(sbig, &xv, &z2, zs, w, fd, true, v);
            self.take_if(fb.inf, &b, v);
            self.take_if(fa.inf, &a, v);
            let both = self.and2(fa.inf, fb.inf);
            let opp = self.and2(both, s);
            let n0 = self.or2(fa.nan, fb.nan);
            let nan = self.or2(n0, opp);
            self.nan_if(nan, w, fd, v);
        } else if x.op == T_FMUL {
            let n = 2 * m + 2;
            let mut p = Vector::<u32>::new();
            let mut q = Vector::<u32>::new();
            for i in 0..n {
                p.push(pick(i <= m, fa.sig[i.min(m) as usize], L_FALSE));
                q.push(pick(i <= m, fb.sig[i.min(m) as usize], L_FALSE));
            }
            let mut xv = Vector::<u32>::new();
            self.mul(&p, &q, &mut xv);
            let mut z0 = Vector::<u32>::new();
            let mut z = Vector::<u32>::new();
            self.add(&fa.ee, &fb.ee, L_FALSE, &mut z0);
            self.sub_k(&z0, 2 * bias + 2 * m as i64, &mut z);
            self.round_pack(s, &xv, &z, s, w, fd, true, v);
            let inf = self.or2(fa.inf, fb.inf);
            Blaster::<B>::fspecial(true, s, w, fd, &mut sp);
            self.take_if(inf, &sp, v);
            let n0 = self.or2(fa.nan, fb.nan);
            let i0 = self.and2(fa.inf, fb.zero);
            let i1 = self.and2(fa.zero, fb.inf);
            let n1 = self.or2(i0, i1);
            let nan = self.or2(n0, n1);
            self.nan_if(nan, w, fd, v);
        } else {
            // A quotient of normalized significands, K = M + 3 bits past the point.
            let k = m + 3;
            let mut an = Vector::<u32>::new();
            let mut bn = Vector::<u32>::new();
            let mut la = Vector::<u32>::new();
            let mut lb = Vector::<u32>::new();
            self.normalize(&fa.sig, &mut an, &mut la);
            self.normalize(&fb.sig, &mut bn, &mut lb);
            let mut num = Vector::<u32>::new();
            for _i in 0..k {
                num.push(L_FALSE);
            }
            num.extend_copy(&an);
            let mut q = Vector::<u32>::new();
            let rnz = self.udiv(&num, &bn, &mut q);
            let mut xv = Vector::<u32>::new();
            xv.push(rnz);
            for i in 0..k + 2 {
                xv.push(q[i as usize]);
            }
            let mut ea = Vector::<u32>::new();
            let mut eb = Vector::<u32>::new();
            let mut d = Vector::<u32>::new();
            let mut z = Vector::<u32>::new();
            self.exp_of(&fa.ee, &la, 0, &mut ea);
            self.exp_of(&fb.ee, &lb, 0, &mut eb);
            self.sub(&ea, &eb, &mut d);
            self.sub_k(&d, k as i64 + 1, &mut z);
            self.round_pack(s, &xv, &z, s, w, fd, true, v);
            let zero = self.or2(fa.zero, fb.inf);
            Blaster::<B>::fspecial(false, s, w, fd, &mut sp);
            self.take_if(zero, &sp, v);
            // A finite value over zero: infinity, or NaN without infinities.
            let inf = pick(fo, fa.inf, self.or2(fa.inf, fb.zero));
            Blaster::<B>::fspecial(true, s, w, fd, &mut sp);
            self.take_if(inf, &sp, v);
            let n0 = self.or2(fa.nan, fb.nan);
            let z2 = pick(fo, fb.zero, self.and2(fa.zero, fb.zero));
            let i2 = self.and2(fa.inf, fb.inf);
            let n1 = self.or2(z2, i2);
            let nan = self.or2(n0, n1);
            self.nan_if(nan, w, fd, v);
        }
    }

    // `a % b` (`T_FREM`, C's `fmod`) into `v`: NaN for a NaN operand, an infinite `a` or a zero `b`; `a`
    // where `|a| < |b|` (an infinite `b` too); else `|a| * 2^d mod |b|` of the normalized significands, d
    // the difference of their exponents, by one doubling and subtraction per unit of d, exact, at `b`'s
    // exponent and with `a`'s sign. Where those steps would pass FREM_CELLS, the result is a value that
    // keeps what fmod keeps: below `|b|`, at most `|a|`, of `a`'s sign, not NaN.
    fn frem(self: &mut Self, tm: &Terms<B>, x: &Term<B>, v: &mut Vector<u32>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let (e, m, _fo) = Blaster::<B>::fmt(w, fd);
        let bias = (1i64 << (e - 1) as i64) - 1;
        let mut a = Vector::<u32>::new();
        let mut b = Vector::<u32>::new();
        self.get(tm, x.a, w, &mut a);
        self.get(tm, x.b, w, &mut b);
        let fa = self.unpack(&a, w, fd);
        let fb = self.unpack(&b, w, fd);
        let mut ma = Vector::<u32>::new();
        let mut mb = Vector::<u32>::new();
        for i in 0..w - 1 {
            ma.push(a[i as usize]);
            mb.push(b[i as usize]);
        }
        let less = self.ult(&ma, &mb);
        let keep0 = self.or2(fb.inf, fa.zero);
        let keep = self.or2(keep0, less);
        let n0 = self.or2(fa.nan, fb.nan);
        let n1 = self.or2(fa.inf, fb.zero);
        let nan = self.or2(n0, n1);
        // The steps: one per unit of the greatest exponent difference of normalized values.
        let steps = (1u32 << e) + m;
        if steps as u64 * (m as u64 + 2) <= FREM_CELLS {
            let mut an = Vector::<u32>::new();
            let mut bn = Vector::<u32>::new();
            let mut la = Vector::<u32>::new();
            let mut lb = Vector::<u32>::new();
            self.normalize(&fa.sig, &mut an, &mut la);
            self.normalize(&fb.sig, &mut bn, &mut lb);
            let mut ea = Vector::<u32>::new();
            let mut eb = Vector::<u32>::new();
            let mut d = Vector::<u32>::new();
            self.exp_of(&fa.ee, &la, 0, &mut ea);
            self.exp_of(&fb.ee, &lb, 0, &mut eb);
            self.sub(&ea, &eb, &mut d);
            // R over M + 2 bits, always below 2 * bn; one subtraction first (an < 2 * bn).
            let n = (m + 2) as usize;
            let mut nb = Vector::<u32>::new();
            for i in 0..n + 1 {
                nb.push(pick(i <= m as usize, bn[i.min(m as usize)], L_FALSE) ^ 1);
            }
            let mut rr = Vector::<u32>::new();
            for i in 0..n + 1 {
                rr.push(pick(i <= m as usize, an[i.min(m as usize)], L_FALSE));
            }
            let mut diff = Vector::<u32>::new();
            let mut pk = Vector::<u32>::new();
            self.add(&rr, &nb, L_TRUE, &mut diff);
            let ge0 = diff[n] ^ 1;
            self.mux_vec(ge0, &diff, &rr, &mut pk);
            rr.clear();
            rr.extend_copy(&pk);
            let mut kv = Vector::<u32>::new();
            let mut sh = Vector::<u32>::new();
            for i in 1..steps as i64 + 1 {
                if !self.ok {
                    return;
                }
                // Step i runs where d >= i.
                Blaster::<B>::kbits(i, self.fx, &mut kv);
                let on = self.slt(&d, &kv) ^ 1;
                sh.clear();
                sh.push(L_FALSE);
                for j in 0..n {
                    sh.push(rr[j]);
                }
                self.add(&sh, &nb, L_TRUE, &mut diff);
                let ge = self.and2(diff[n] ^ 1, on);
                self.mux_vec(ge, &diff, &sh, &mut pk);
                for j in 0..n + 1 {
                    rr.set(j, self.mux(on, pk[j], rr[j]));
                }
            }
            let mut z = Vector::<u32>::new();
            self.sub_k(&eb, bias + m as i64, &mut z);
            let mut xr = Vector::<u32>::new();
            for i in 0..m + 1 {
                xr.push(rr[i as usize]);
            }
            self.round_pack(fa.s, &xr, &z, fa.s, w, fd, true, v);
        } else {
            // Where neither `a` nor NaN is the result: |v| < |b|, |v| <= |a|, v not NaN, of a's sign.
            let mut mv = Vector::<u32>::new();
            for _i in 0..w - 1 {
                mv.push(self.fresh());
            }
            let mut vw = mv.clone();
            vw.push(fa.s);
            let fv = self.unpack(&vw, w, fd);
            v.clear();
            v.extend_copy(&vw);
            let c0 = self.ult(&mv, &mb);
            let c1 = self.ult(&ma, &mv) ^ 1;
            let c2 = self.and2(c0, c1);
            let c3 = self.and2(c2, fv.nan ^ 1);
            self.cnf.lits.push(keep);
            self.cnf.lits.push(nan);
            self.cnf.lits.push(c3);
            self.cnf.end();
        }
        self.take_if(keep, &a, v);
        self.nan_if(nan, w, fd, v);
    }

    // The quotient of unsigned `num` by `den` (top bit set) into `q` (num's width), by restoring
    // division; whether the remainder is not zero.
    fn udiv(self: &mut Self, num: &Vector<u32>, den: &Vector<u32>, q: &mut Vector<u32>) u32 {
        let n = num.len();
        let m = den.len();
        let mut rem = Vector::<u32>::new();
        let mut nd = Vector::<u32>::new();
        for i in 0..m + 3 {
            nd.push(pick(i < m, den[i.min(m - 1)], L_FALSE) ^ 1);
            if i < m + 1 {
                rem.push(L_FALSE);
            }
        }
        q.clear();
        for _i in 0..n {
            q.push(L_FALSE);
        }
        let mut sh = Vector::<u32>::new();
        let mut diff = Vector::<u32>::new();
        let mut pk = Vector::<u32>::new();
        for s in 0..n {
            if !self.ok {
                return L_FALSE;
            }
            let i = n - 1 - s;
            sh.clear();
            sh.push(num[i]);
            sh.extend_copy(&rem);
            sh.push(L_FALSE);
            self.add(&sh, &nd, L_TRUE, &mut diff);
            let ge = diff[m + 2] ^ 1;
            q.set(i, ge);
            self.mux_vec(ge, &diff, &sh, &mut pk);
            for j in 0..m + 1 {
                rem.set(j, pk[j]);
            }
        }
        return self.any(&rem, 0, m + 1);
    }

    // The integer square root of `rad` (an even count of bits) into `root`; whether the remainder is not
    // zero.
    fn isqrt(self: &mut Self, rad: &Vector<u32>, root: &mut Vector<u32>) u32 {
        let n = rad.len() / 2;
        let mut rem = Vector::<u32>::new();
        for _i in 0..n + 2 {
            rem.push(L_FALSE);
        }
        root.clear();
        for _i in 0..n {
            root.push(L_FALSE);
        }
        let mut sh = Vector::<u32>::new();
        let mut tr = Vector::<u32>::new();
        let mut diff = Vector::<u32>::new();
        let mut pk = Vector::<u32>::new();
        for s in 0..n {
            if !self.ok {
                return L_FALSE;
            }
            let i = n - 1 - s;
            // rem * 4 + the next two bits against root * 4 + 1, over n + 3 bits.
            sh.clear();
            sh.push(rad[2 * i]);
            sh.push(rad[2 * i + 1]);
            for j in 0..n + 1 {
                sh.push(pick(j < n, rem[j.min(n - 1)], L_FALSE));
            }
            tr.clear();
            tr.push(L_FALSE);
            tr.push(L_TRUE);
            for j in 0..n + 1 {
                tr.push(pick(j < n, root[j.min(n - 1)], L_FALSE) ^ 1);
            }
            self.add(&sh, &tr, L_TRUE, &mut diff);
            let ge = diff[n + 2] ^ 1;
            for j in 0..n - 1 {
                root.set(n - 1 - j, root[n - 2 - j]);
            }
            root.set(0, ge);
            self.mux_vec(ge, &diff, &sh, &mut pk);
            for j in 0..n + 2 {
                rem.set(j, pk[j]);
            }
        }
        return self.any(&rem, 0, n + 2);
    }

    // The square root of `a` (fields `fa`, `sb` its bias plus M), width `w`, format `fd`, into `v`.
    fn fsqrt(self: &mut Self, a: &Vector<u32>, fa: &Fp, sb: i64, w: u32, fd: u64, v: &mut Vector<u32>) {
        let (_e, m, _fo) = Blaster::<B>::fmt(w, fd);
        let fx = self.fx;
        // value = mn * 2^ex; an odd exponent moves one bit into the significand.
        let mut mn = Vector::<u32>::new();
        let mut lz = Vector::<u32>::new();
        self.normalize(&fa.sig, &mut mn, &mut lz);
        let mut ex = Vector::<u32>::new();
        self.exp_of(&fa.ee, &lz, -sb, &mut ex);
        let odd = ex[0];
        let k = (m + 5) / 2;
        let mut rad = Vector::<u32>::new();
        for _i in 0..2 * k {
            rad.push(L_FALSE);
        }
        for i in 0..m + 2 {
            let lo = pick(i >= 1, mn[(i - pick(i >= 1, 1, 0)).min(m) as usize], L_FALSE);
            let hi = pick(i <= m, mn[i.min(m) as usize], L_FALSE);
            rad.push(self.mux(odd, lo, hi));
        }
        if rad.len() % 2 != 0 {
            rad.push(L_FALSE);
        }
        let mut root = Vector::<u32>::new();
        let rnz = self.isqrt(&rad, &mut root);
        let mut xv = Vector::<u32>::new();
        xv.push(rnz);
        xv.extend_copy(&root);
        // z = (ex - odd) / 2 - K - 1.
        let mut e2 = Vector::<u32>::new();
        ex.set(0, L_FALSE);
        for i in 0..fx {
            e2.push(ex[(i + 1).min(fx - 1) as usize]);
        }
        let mut z = Vector::<u32>::new();
        self.sub_k(&e2, k as i64 + 1, &mut z);
        self.round_pack(L_FALSE, &xv, &z, L_FALSE, w, fd, true, v);
        let pinf = self.and2(fa.inf, fa.s ^ 1);
        let keep = self.or2(fa.zero, pinf);
        self.take_if(keep, a, v);
        let neg = self.and2(fa.s, fa.zero ^ 1);
        let nan = self.or2(fa.nan, neg);
        self.nan_if(nan, w, fd, v);
    }

    // `a` rounded to an integral value (`Terms::frint`) into `v`. On the magnitude's encoding, where the
    // value's fraction is its low M - u bits (u the unbiased exponent, 0 <= u < M): a sum that carries into
    // the next binade leaves less than the mask past it, so the mask gives that binade's first value, the
    // right result. Halves to even add one less than the half, and one more where the integral part is
    // odd.
    fn frint(self: &mut Self, tm: &Terms<B>, x: &Term<B>, v: &mut Vector<u32>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let md = (x.k.limb(0) >> 32) as u16;
        let (e, m, _fo) = Blaster::<B>::fmt(w, fd);
        let fx = self.fx;
        let bias = (1i64 << (e - 1) as i64) - 1;
        let n = e + m;
        let mut a = Vector::<u32>::new();
        self.get(tm, x.a, w, &mut a);
        let fa = self.unpack(&a, w, fd);
        let mut mag = Vector::<u32>::new();
        for i in 0..n {
            mag.push(a[i as usize]);
        }
        let mut u = Vector::<u32>::new();
        self.sub_k(&fa.ee, bias, &mut u);
        let mut kv = Vector::<u32>::new();
        Blaster::<B>::kbits(m, fx, &mut kv);
        let big = self.slt(&u, &kv) ^ 1;
        let small = u[(fx - 1) as usize];
        // fb = M - u fraction bits: nm = ~0 << fb, half = 1 << (fb - 1).
        let mut fb = Vector::<u32>::new();
        self.sub(&kv, &u, &mut fb);
        let mut fb1 = Vector::<u32>::new();
        self.sub_k(&fb, 1, &mut fb1);
        let mut ones = Vector::<u32>::new();
        let mut one = Vector::<u32>::new();
        for i in 0..n {
            ones.push(L_TRUE);
            one.push(pick(i == 0, L_TRUE, L_FALSE));
        }
        let mut nm = Vector::<u32>::new();
        let mut half = Vector::<u32>::new();
        self.barrel(&ones, &fb, true, false, &mut nm);
        self.barrel(&one, &fb1, true, false, &mut half);
        let mut mask = Vector::<u32>::new();
        for i in 0..n {
            mask.push(nm[i as usize] ^ 1);
        }
        // Up: round adds half; ceil of a positive and floor of a negative add the mask.
        let up_all = if md == FR_CEIL {
            fa.s ^ 1
        } else if md == FR_FLOOR {
            fa.s
        } else {
            L_FALSE
        };
        let mut addend = Vector::<u32>::new();
        let mut cin = L_FALSE;
        if md == FR_ROUND {
            addend.extend_copy(&half);
        } else if md == FR_EVEN {
            // half - 1 is the mask shifted right; the integral part's last bit is at the half's next bit.
            let mut odd = L_FALSE;
            for i in 0..n {
                addend.push(pick(i + 1 < n, mask[(i + 1).min(n - 1) as usize], L_FALSE));
                if i >= 1 {
                    let at = self.and2(half[(i - 1) as usize], mag[i as usize]);
                    odd = self.or2(odd, at);
                }
            }
            cin = odd;
        } else {
            for i in 0..n {
                addend.push(self.and2(up_all, mask[i as usize]));
            }
        }
        let mut sum = Vector::<u32>::new();
        self.add(&mag, &addend, cin, &mut sum);
        let mut r = Vector::<u32>::new();
        for i in 0..n {
            r.push(self.and2(sum[i as usize], nm[i as usize]));
        }
        // Below 1: 0, or 1 where round meets at least a half (halves to even: past a half), or ceil and
        // floor move a nonzero away from 0.
        let mut onev = Vector::<u32>::new();
        Blaster::<B>::kbits(bias << m as i64, n, &mut onev);
        Blaster::<B>::kbits(-1, fx, &mut kv);
        let to_one = if md == FR_ROUND {
            self.eqv(&u, &kv)
        } else if md == FR_EVEN {
            let h = self.eqv(&u, &kv);
            let fnz = self.any(&a, 0, m as usize);
            self.and2(h, fnz)
        } else if md == FR_TRUNC {
            L_FALSE
        } else {
            self.and2(up_all, fa.zero ^ 1)
        };
        let mut sv = Vector::<u32>::new();
        for i in 0..n {
            sv.push(self.and2(to_one, onev[i as usize]));
        }
        let mut res = Vector::<u32>::new();
        let mut t = Vector::<u32>::new();
        self.mux_vec(small, &sv, &r, &mut t);
        self.mux_vec(big, &mag, &t, &mut res);
        v.clear();
        v.extend_copy(&res);
        v.push(fa.s);
        self.nan_if(fa.nan, w, fd, v);
    }

    // `x * y + z` rounded once (`Terms::ffma`) into `v`.
    fn ffma(self: &mut Self, tm: &Terms<B>, x: &Term<B>, v: &mut Vector<u32>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let (e, m, _fo) = Blaster::<B>::fmt(w, fd);
        let bias = (1i64 << (e - 1) as i64) - 1;
        let mut xa = Vector::<u32>::new();
        let mut ya = Vector::<u32>::new();
        let mut za = Vector::<u32>::new();
        self.get(tm, tm.args[x.a as usize], w, &mut xa);
        self.get(tm, tm.args[(x.a + 1) as usize], w, &mut ya);
        self.get(tm, tm.args[(x.a + 2) as usize], w, &mut za);
        let fx = self.unpack(&xa, w, fd);
        let fy = self.unpack(&ya, w, fd);
        let fz = self.unpack(&za, w, fd);
        let sp = self.xor2(fx.s, fy.s);
        // The exact product, and both values normalized to its 2M + 2 bits.
        let n = 2 * m + 2;
        let mut p0 = Vector::<u32>::new();
        let mut q0 = Vector::<u32>::new();
        for i in 0..n {
            p0.push(pick(i <= m, fx.sig[i.min(m) as usize], L_FALSE));
            q0.push(pick(i <= m, fy.sig[i.min(m) as usize], L_FALSE));
        }
        let mut pr = Vector::<u32>::new();
        self.mul(&p0, &q0, &mut pr);
        let mut ep0 = Vector::<u32>::new();
        let mut ep = Vector::<u32>::new();
        self.add(&fx.ee, &fy.ee, L_FALSE, &mut ep0);
        self.sub_k(&ep0, 2 * bias + 2 * m as i64, &mut ep);
        let mut pn = Vector::<u32>::new();
        let mut lp = Vector::<u32>::new();
        self.normalize(&pr, &mut pn, &mut lp);
        let mut epn = Vector::<u32>::new();
        self.sub(&ep, &lp, &mut epn);
        let mut zv = Vector::<u32>::new();
        for i in 0..n {
            zv.push(pick(i > m, fz.sig[(i - pick(i > m, m + 1, 0)).min(m) as usize], L_FALSE));
        }
        let mut zn = Vector::<u32>::new();
        let mut lzz = Vector::<u32>::new();
        self.normalize(&zv, &mut zn, &mut lzz);
        let mut ezn = Vector::<u32>::new();
        self.exp_of(&fz.ee, &lzz, -bias - 2 * m as i64 - 1, &mut ezn);
        // The greater magnitude first: the greater exponent, then the greater significand.
        let elt = self.slt(&epn, &ezn);
        let eeq = self.eqv(&epn, &ezn);
        let slt0 = self.ult(&pn, &zn);
        let sl = self.and2(eeq, slt0);
        let zbig = self.or2(elt, sl);
        let mut gb = Vector::<u32>::new();
        let mut gs = Vector::<u32>::new();
        let mut eb = Vector::<u32>::new();
        let mut es = Vector::<u32>::new();
        self.mux_vec(zbig, &zn, &pn, &mut gb);
        self.mux_vec(zbig, &pn, &zn, &mut gs);
        self.mux_vec(zbig, &ezn, &epn, &mut eb);
        self.mux_vec(zbig, &epn, &ezn, &mut es);
        let sbig = self.mux(zbig, fz.s, sp);
        let sub = self.xor2(sp, fz.s);
        let mut xs = Vector::<u32>::new();
        let mut zs = Vector::<u32>::new();
        self.fsum(&gb, &eb, &gs, &es, sub, &mut xs, &mut zs);
        self.round_pack(sbig, &xs, &zs, L_FALSE, w, fd, true, v);
        // A zero product: `z`, or a zero of both signs' and; a zero `z`: the product rounded.
        let pz = self.or2(fx.zero, fy.zero);
        let mut alt = Vector::<u32>::new();
        self.round_pack(sp, &pr, &ep, sp, w, fd, true, &mut alt);
        self.take_if(fz.zero, &alt, v);
        let zz = self.and2(sp, fz.s);
        let mut sp0 = Vector::<u32>::new();
        Blaster::<B>::fspecial(false, zz, w, fd, &mut sp0);
        let mut pzv = za.clone();
        self.take_if(fz.zero, &sp0, &mut pzv);
        self.take_if(pz, &pzv, v);
        self.take_if(fz.inf, &za, v);
        let pinf = self.or2(fx.inf, fy.inf);
        Blaster::<B>::fspecial(true, sp, w, fd, &mut sp0);
        self.take_if(pinf, &sp0, v);
        let n0 = self.or2(fx.nan, fy.nan);
        let n1 = self.or2(n0, fz.nan);
        let i0 = self.and2(fx.inf, fy.zero);
        let i1 = self.and2(fx.zero, fy.inf);
        let i2 = self.or2(i0, i1);
        let pi = self.and2(pinf, fz.inf);
        let opp = self.and2(pi, sub);
        let n2 = self.or2(n1, i2);
        let nan = self.or2(n2, opp);
        self.nan_if(nan, w, fd, v);
    }

    // `a as` integer type (w, sg) of float `a` (`Terms::fconv`, its format `k`): truncated toward zero,
    // saturated at the type's ends, NaN 0; its exact value into `r`.
    fn float_to_int(self: &mut Self, tm: &Terms<B>, x: &Term<B>, r: &mut Vector<u32>) {
        let k = tm.at(x.a).w as u32;
        let sfd = x.k.limb(0) & 0xFFFFFFFF;
        self.fx = Blaster::<B>::fx_of(k, sfd);
        let fxw = self.fx;
        let (e, m, _fo) = Blaster::<B>::fmt(k, sfd);
        let bias = (1i64 << (e - 1) as i64) - 1;
        let mut a = Vector::<u32>::new();
        self.get(tm, x.a, k, &mut a);
        let fa = self.unpack(&a, k, sfd);
        // The unbiased exponent u: below 0 the value truncates to 0, from 67 on it saturates.
        let mut u = Vector::<u32>::new();
        self.sub_k(&fa.ee, bias, &mut u);
        let below = u[(fxw - 1) as usize];
        let mut kv = Vector::<u32>::new();
        Blaster::<B>::kbits(67, fxw, &mut kv);
        let big = self.slt(&u, &kv) ^ 1;
        let wt = m + 1 + 67;
        let mut mw = Vector::<u32>::new();
        for i in 0..wt {
            mw.push(pick(i <= m, fa.sig[i.min(m) as usize], L_FALSE));
        }
        let mut amt = Vector::<u32>::new();
        for i in 0..7 {
            amt.push(u[i as usize]);
        }
        let mut sh = Vector::<u32>::new();
        self.barrel(&mw, &amt, true, false, &mut sh);
        // The magnitude floor(sig * 2^u / 2^M) over 68 bits, then the signed value over 70.
        let nb: u32 = 70;
        let mut mag = Vector::<u32>::new();
        for i in 0..nb {
            let t = pick(i < 68, sh[(m + i.min(67)) as usize], L_FALSE);
            let s0 = self.mux(big, pick(i < 68, L_TRUE, L_FALSE), t);
            mag.push(self.and2(below ^ 1, s0));
        }
        let mut sv = Vector::<u32>::new();
        self.neg_if(fa.s, &mag, &mut sv);
        let (lo, hi) = Terms::<B>::range(x.w, x.sg);
        let mut lv = Vector::<u32>::new();
        let mut hv = Vector::<u32>::new();
        for i in 0..nb {
            lv.push(pick(num_bit(lo, i), L_TRUE, L_FALSE));
            hv.push(pick(num_bit(hi, i), L_TRUE, L_FALSE));
        }
        let under = self.slt(&sv, &lv);
        let over = self.slt(&hv, &sv);
        let mut c1 = Vector::<u32>::new();
        let mut c2 = Vector::<u32>::new();
        self.mux_vec(under, &lv, &sv, &mut c1);
        self.mux_vec(over, &hv, &c1, &mut c2);
        let kk = x.w as u32 + (!x.sg) as u32;
        r.clear();
        for i in 0..kk {
            r.push(self.and2(fa.nan ^ 1, c2[i as usize]));
        }
    }

    // The IEEE comparison `x` (T_FLT, T_FLE, T_FEQ) of two floats, as a literal.
    fn float_cmp(self: &mut Self, tm: &Terms<B>, x: &Term<B>) u32 {
        let w = tm.at(x.a).w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        self.fx = Blaster::<B>::fx_of(w, fd);
        let mut a = Vector::<u32>::new();
        let mut b = Vector::<u32>::new();
        self.get(tm, x.a, w, &mut a);
        self.get(tm, x.b, w, &mut b);
        return self.fcmp_bits(x.op, &a, &b, w, fd);
    }

    // ---- facts of rounded operations ------------------------------------------------------------
    //
    // Clauses that hold of every operation `float_value` builds, which a SAT search over the circuits
    // finds only at great cost: each rounds to nearest an exact result that is monotone in its operands,
    // and rounding to nearest is monotone. Where the results are not NaN:
    //
    // - against its operands: a + b >= a for b >= 0 (<= for b <= 0); a * b against a by b >= 1 or b in [0, 1]
    //   and a's sign; a / b against a likewise for b >= 1 or b in (0, 1]; sqrt(a) between 1 and a, or a and 1;
    //   floor(a) <= a <= ceil(a); trunc, round and their halves to even keep a's side of 0 and trunc does
    //   not grow; fmod: |r| <= |a|, |r| < |b|, r of a's sign;
    // - against an earlier operation of one kind and format (FPAIR_MAX of them): sums by their operands'
    //   order, either pairing; products of nonnegative operands likewise, and of one shared operand by
    //   its sign; quotients of one positive divisor by their dividends, and of one dividend by their
    //   positive divisors; one-operand operations (square root, one rounding mode, one conversion) by
    //   their operands' order.

    // The clause `!c[0] || ... || !c[n - 1] || r`.
    fn imply(self: &mut Self, c: &Vector<u32>, r: u32) {
        for j in 0..c.len() {
            if c[j] == L_FALSE {
                return;
            }
        }
        for j in 0..c.len() {
            if c[j] != L_TRUE {
                self.cnf.lits.push(c[j] ^ 1);
            }
        }
        self.cnf.lits.push(r);
        self.cnf.end();
    }

    // The low `w` bits of float `t`.
    fn fbits(self: &mut Self, tm: &Terms<B>, t: u32, w: u32) Vector<u32> {
        let mut v = Vector::<u32>::new();
        self.get(tm, t, w, &mut v);
        return v;
    }

    // The encoding of `k` times 2^`p` (`k` of up to 2 bits) of width `w`, format `fd`: 0 or 1.
    fn fconst(w: u32, fd: u64, one: bool) Vector<u32> {
        let (e, m, _fo) = Blaster::<B>::fmt(w, fd);
        let mut v = Vector::<u32>::new();
        for i in 0..w {
            v.push(pick(one && i >= m && i < m + e - 1, L_TRUE, L_FALSE));
        }
        return v;
    }

    // The facts of float operation `t` (`x`), built.
    fn float_lemmas(self: &mut Self, tm: &Terms<B>, t: u32, x: &Term<B>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let nc = self.nan_c;
        self.nan_of.insert(t, nc);
        let mut c = Vector::<u32>::new();
        if x.op != T_FTOI && x.op != T_FKEY {
            // A result is NaN only where its operation makes one: every other value it takes is not.
            self.fx = Blaster::<B>::fx_of(w, fd);
            let r = self.fbits(tm, t, w);
            let fr = self.unpack(&r, w, fd);
            c.push(fr.nan);
            self.imply(&c, nc);
        }
        if x.op == T_FFMA {
            return;
        }
        if x.op == T_ITOF || x.op == T_FTOI || x.op == T_FKEY || x.op == T_FCVT {
            if x.op == T_FCVT {
                self.box_lemmas(tm, t, x, nc);
            }
            self.pair_lemmas(tm, t, x);
            return;
        }
        self.fx = Blaster::<B>::fx_of(w, fd);
        let r = self.fbits(tm, t, w);
        let a = self.fbits(tm, x.a, w);
        let zero = Blaster::<B>::fconst(w, fd, false);
        let one = Blaster::<B>::fconst(w, fd, true);
        let ok = nc ^ 1;
        let a0 = self.fcmp_bits(T_FLE, &zero, &a, w, fd);
        let a1 = self.fcmp_bits(T_FLE, &a, &zero, w, fd);
        let ra = self.fcmp_bits(T_FLE, &a, &r, w, fd);
        let ar = self.fcmp_bits(T_FLE, &r, &a, w, fd);
        if x.op == T_FADD || x.op == T_FMUL || x.op == T_FDIV || x.op == T_FREM {
            let b = self.fbits(tm, x.b, w);
            let b0 = self.fcmp_bits(T_FLE, &zero, &b, w, fd);
            let b1 = self.fcmp_bits(T_FLE, &b, &zero, w, fd);
            if x.op == T_FADD {
                let rb = self.fcmp_bits(T_FLE, &b, &r, w, fd);
                let br = self.fcmp_bits(T_FLE, &r, &b, w, fd);
                for (p, q, up, dn) in [(b0, b1, ra, ar), (a0, a1, rb, br)] {
                    c.clear();
                    c.push(ok);
                    c.push(p);
                    self.imply(&c, up);
                    c.set(1, q);
                    self.imply(&c, dn);
                }
            } else if x.op == T_FMUL || x.op == T_FDIV {
                for i in 0..pick(x.op == T_FMUL, 2u32, 1) {
                    let (p, q) = if i == 0 {
                        (&a, &b)
                    } else {
                        (&b, &a)
                    };
                    let p0 = self.fcmp_bits(T_FLE, &zero, p, w, fd);
                    let p1 = self.fcmp_bits(T_FLE, p, &zero, w, fd);
                    let rp = self.fcmp_bits(T_FLE, p, &r, w, fd);
                    let pr = self.fcmp_bits(T_FLE, &r, p, w, fd);
                    let q_big = self.fcmp_bits(T_FLE, &one, q, w, fd);
                    let q_lo = self.fcmp_bits(pick(x.op == T_FMUL, T_FLE, T_FLT), &zero, q, w, fd);
                    let q_hi = self.fcmp_bits(T_FLE, q, &one, w, fd);
                    let small = self.and2(q_lo, q_hi);
                    // |r| >= |p| for a product by q >= 1 or a quotient by q in (0, 1]; |r| <= |p| the other way.
                    let (grow, shrink) = if x.op == T_FMUL {
                        (q_big, small)
                    } else {
                        (small, q_big)
                    };
                    for (cond, away) in [(grow, true), (shrink, false)] {
                        c.clear();
                        c.push(ok);
                        c.push(cond);
                        c.push(p0);
                        self.imply(&c, pick(away, rp, pr));
                        c.set(2, p1);
                        self.imply(&c, pick(away, pr, rp));
                    }
                }
            } else {
                // fmod: |r| <= |a|, |r| < |b|, r of a's sign.
                let mut ma = Vector::<u32>::new();
                let mut mb = Vector::<u32>::new();
                let mut mr = Vector::<u32>::new();
                for i in 0..w - 1 {
                    ma.push(a[i as usize]);
                    mb.push(b[i as usize]);
                    mr.push(r[i as usize]);
                }
                c.clear();
                c.push(ok);
                let le_a = self.ult(&ma, &mr) ^ 1;
                self.imply(&c, le_a);
                let lt_b = self.ult(&mr, &mb);
                self.imply(&c, lt_b);
                let same = self.xor2(r[(w - 1) as usize], a[(w - 1) as usize]) ^ 1;
                self.imply(&c, same);
                return;
            }
        } else if x.op == T_FSQRT {
            let a_big = self.fcmp_bits(T_FLE, &one, &a, w, fd);
            let a_hi = self.fcmp_bits(T_FLE, &a, &one, w, fd);
            let r_big = self.fcmp_bits(T_FLE, &one, &r, w, fd);
            let r_hi = self.fcmp_bits(T_FLE, &r, &one, w, fd);
            c.clear();
            c.push(a_big);
            self.imply(&c, r_big);
            self.imply(&c, ar);
            c.clear();
            c.push(a0);
            c.push(a_hi);
            self.imply(&c, ra);
            self.imply(&c, r_hi);
        } else if x.op == T_FRINT {
            let md = (x.k.limb(0) >> 32) as u16;
            let r0 = self.fcmp_bits(T_FLE, &zero, &r, w, fd);
            let r1 = self.fcmp_bits(T_FLE, &r, &zero, w, fd);
            c.clear();
            c.push(ok);
            if md == FR_FLOOR {
                self.imply(&c, ar);
            } else if md == FR_CEIL {
                self.imply(&c, ra);
            } else {
                c.push(a0);
                self.imply(&c, r0);
                if md == FR_TRUNC {
                    self.imply(&c, ar);
                }
                c.set(1, a1);
                self.imply(&c, r1);
                if md == FR_TRUNC {
                    self.imply(&c, ra);
                }
            }
        }
        self.box_lemmas(tm, t, x, nc);
        self.pair_lemmas(tm, t, x);
    }

    // The facts of float operation `t` (`x`) against the earlier operations of its kind and format.
    fn pair_lemmas(self: &mut Self, tm: &Terms<B>, t: u32, x: &Term<B>) {
        let mut seen: u32 = 0;
        let mut j = self.fterms.len();
        for _k in 0..self.fterms.len() {
            if seen >= FPAIR_MAX || !self.ok {
                break;
            }
            j -= 1;
            let u = self.fterms[j];
            let y = tm.at(u);
            if y.op != x.op || !(y.k == x.k) || y.w != x.w || y.sg != x.sg || tm.at(y.a).w != tm.at(x.a).w || tm.at(y.a).sg != tm.at(
                x.a,
            ).sg {
                continue;
            }
            seen += 1;
            self.pair(tm, t, x, u, &y);
        }
        self.fterms.push(t);
    }

    // The facts of two operations `t` (`x`) and `u` (`y`) of one kind and format.
    fn pair(self: &mut Self, tm: &Terms<B>, t: u32, x: &Term<B>, u: u32, y: &Term<B>) {
        let w = x.w as u32;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let mut c = Vector::<u32>::new();
        if x.op == T_FTOI || x.op == T_ITOF {
            // `as` saturates and is monotone, NaN aside; an integer rounds monotonically.
            let (n, fl) = if x.op == T_FTOI {
                (w + (!x.sg) as u32, false)
            } else {
                (self.nat_of(tm, x.a).max(self.nat_of(tm, y.a)), true)
            };
            let sw = tm.at(x.a).w as u32;
            let sfd = x.k.limb(0) & 0xFFFFFFFF;
            let (ta, ua) = if fl {
                let mut p = Vector::<u32>::new();
                let mut q = Vector::<u32>::new();
                self.get(tm, x.a, n, &mut p);
                self.get(tm, y.a, n, &mut q);
                (p, q)
            } else {
                self.fx = Blaster::<B>::fx_of(sw, sfd);
                (self.fbits(tm, x.a, sw), self.fbits(tm, y.a, sw))
            };
            let (tr, ur) = if fl {
                self.fx = Blaster::<B>::fx_of(w, sfd);
                (self.fbits(tm, t, w), self.fbits(tm, u, w))
            } else {
                let mut p = Vector::<u32>::new();
                let mut q = Vector::<u32>::new();
                self.get(tm, t, n, &mut p);
                self.get(tm, u, n, &mut q);
                (p, q)
            };
            for d in 0..2 {
                let (p, q, pr, qr) = pick(d == 0, (&ta, &ua, &tr, &ur), (&ua, &ta, &ur, &tr));
                let le = if fl {
                    self.slt(q, p) ^ 1
                } else {
                    self.fcmp_bits(T_FLE, p, q, sw, sfd)
                };
                let res = if fl {
                    self.fcmp_bits(T_FLE, pr, qr, w, sfd)
                } else {
                    self.slt(qr, pr) ^ 1
                };
                c.clear();
                c.push(le);
                self.imply(&c, res);
            }
            return;
        }
        if x.op == T_FKEY {
            // Of values not NaN, the keys' order is the IEEE order but for -0 below +0.
            self.fx = Blaster::<B>::fx_of(w, fd);
            let xa = self.fbits(tm, x.a, w);
            let ya = self.fbits(tm, y.a, w);
            let kx = self.fbits(tm, t, w);
            let ky = self.fbits(tm, u, w);
            let fa = self.unpack(&xa, w, fd);
            let fb = self.unpack(&ya, w, fd);
            let ok = self.and2(fa.nan ^ 1, fb.nan ^ 1);
            for d in 0..2 {
                let (p, q, kp, kq) = if d == 0 {
                    (&xa, &ya, &kx, &ky)
                } else {
                    (&ya, &xa, &ky, &kx)
                };
                let lt = self.fcmp_bits(T_FLT, p, q, w, fd);
                let le = self.fcmp_bits(T_FLE, p, q, w, fd);
                let klt = self.ult(kp, kq);
                let kle = self.ult(kq, kp) ^ 1;
                c.clear();
                c.push(ok);
                c.push(lt);
                self.imply(&c, klt);
                c.set(1, kle);
                self.imply(&c, le);
            }
            return;
        }
        let sw = tm.at(x.a).w as u32;
        let sfd = pick(x.op == T_FCVT, x.k.limb(0) >> 32, fd);
        self.fx = Blaster::<B>::fx_of(w, fd).max(Blaster::<B>::fx_of(sw, sfd));
        let tr = self.fbits(tm, t, w);
        let ur = self.fbits(tm, u, w);
        let nt = *self.nan_of.get(&t).unwrap();
        let nu = *self.nan_of.get(&u).unwrap();
        let ok = self.and2(nt ^ 1, nu ^ 1);
        let t_le = self.fcmp_bits(T_FLE, &tr, &ur, w, fd);
        let u_le = self.fcmp_bits(T_FLE, &ur, &tr, w, fd);
        let xa = self.fbits(tm, x.a, sw);
        let ya = self.fbits(tm, y.a, sw);
        let le_a = self.fcmp_bits(T_FLE, &xa, &ya, sw, sfd);
        let ge_a = self.fcmp_bits(T_FLE, &ya, &xa, sw, sfd);
        if unary_op(x.op) {
            c.push(ok);
            c.push(le_a);
            self.imply(&c, t_le);
            c.set(1, ge_a);
            self.imply(&c, u_le);
            return;
        }
        let xb = self.fbits(tm, x.b, w);
        let yb = self.fbits(tm, y.b, w);
        let le_b = self.fcmp_bits(T_FLE, &xb, &yb, w, fd);
        let ge_b = self.fcmp_bits(T_FLE, &yb, &xb, w, fd);
        let zero = Blaster::<B>::fconst(w, fd, false);
        if x.op == T_FADD || x.op == T_FMUL {
            // Either pairing of the operands; products only of nonnegative ones.
            let le_ab = self.fcmp_bits(T_FLE, &xa, &yb, w, fd);
            let ge_ab = self.fcmp_bits(T_FLE, &yb, &xa, w, fd);
            let le_ba = self.fcmp_bits(T_FLE, &xb, &ya, w, fd);
            let ge_ba = self.fcmp_bits(T_FLE, &ya, &xb, w, fd);
            let mut pos = L_TRUE;
            if x.op == T_FMUL {
                for v in [&xa, &xb, &ya, &yb] {
                    let nn = self.fcmp_bits(T_FLE, &zero, v, w, fd);
                    pos = self.and2(pos, nn);
                }
            }
            for (p, q, side) in [(le_a, le_b, true), (le_ab, le_ba, true), (ge_a, ge_b, false), (ge_ab, ge_ba, false)] {
                c.clear();
                c.push(ok);
                c.push(pos);
                c.push(p);
                c.push(q);
                self.imply(&c, pick(side, t_le, u_le));
            }
            if x.op == T_FADD {
                return;
            }
        }
        // One shared operand: products by its sign; quotients by a positive divisor or a shared dividend.
        for s in 0..4 {
            let (sx, sy, ox, oy) = if s == 0 {
                (x.a, y.a, &xb, &yb)
            } else if s == 1 {
                (x.b, y.b, &xa, &ya)
            } else if s == 2 {
                (x.a, y.b, &xb, &ya)
            } else {
                (x.b, y.a, &xa, &yb)
            };
            if sx != sy || x.op == T_FDIV && s >= 2 {
                continue;
            }
            let sv = self.fbits(tm, sx, w);
            let o_le = self.fcmp_bits(T_FLE, ox, oy, w, fd);
            let o_ge = self.fcmp_bits(T_FLE, oy, ox, w, fd);
            let (pos, neg) = if x.op == T_FDIV && s == 1 {
                (self.fcmp_bits(T_FLT, &zero, &sv, w, fd), self.fcmp_bits(T_FLT, &sv, &zero, w, fd))
            } else {
                (self.fcmp_bits(T_FLE, &zero, &sv, w, fd), self.fcmp_bits(T_FLE, &sv, &zero, w, fd))
            };
            if x.op == T_FDIV && s == 0 {
                // a / b against a / b' for 0 < b <= b': the greater divisor, the lesser quotient for a >= 0.
                let bx = self.fcmp_bits(T_FLT, &zero, ox, w, fd);
                let by = self.fcmp_bits(T_FLT, &zero, oy, w, fd);
                let both = self.and2(bx, by);
                for (o, side) in [(o_le, false), (o_ge, true)] {
                    c.clear();
                    c.push(ok);
                    c.push(both);
                    c.push(o);
                    c.push(pos);
                    self.imply(&c, pick(side, t_le, u_le));
                    c.set(3, neg);
                    self.imply(&c, pick(side, u_le, t_le));
                }
                continue;
            }
            for (o, side) in [(o_le, true), (o_ge, false)] {
                c.clear();
                c.push(ok);
                c.push(o);
                c.push(pos);
                self.imply(&c, pick(side, t_le, u_le));
                c.set(2, neg);
                self.imply(&c, pick(side, u_le, t_le));
            }
        }
    }

    // ---- bounds of `f32` and `f64` results ------------------------------------------------------------
    //
    // A result of a monotone rounded operation lies between the results at the corners of its operands'
    // bounds (an interval of each): rounding to nearest is monotone, and so is each exact operation in
    // each operand over such a box (a product, a quotient by a divisor of one sign: at a corner). The
    // bounds of a value are the constants the encoding's term table compares it with, a constant's own,
    // and those of the operations below it: the host computes each corner once, and the facts state the
    // results' bounds where the operands' hold. Only the host's formats: it computes their corners.

    // The constants term `t` is compared with, which bound it (`cands`, made once per encoding).
    fn cands_of(self: &mut Self, tm: &Terms<B>, t: u32) Vector<u64> {
        if !self.cands_made {
            self.cands_made = true;
            for u in 0..tm.ts.len() {
                let x = tm.at(u as u32);
                if x.op != T_FLT && x.op != T_FLE && x.op != T_FEQ {
                    continue;
                }
                let (y, z) = (tm.at(x.a), tm.at(x.b));
                let (v, k) = if y.op == T_INT && z.op != T_INT {
                    (x.b, y.k)
                } else if z.op == T_INT && y.op != T_INT {
                    (x.a, z.k)
                } else {
                    continue;
                };
                let mut cs = switch self.cands.get(&v) {
                    Some(c) => c.clone(),
                    None => Vector::<u64>::new(),
                };
                let kv = k.limb(0);
                if !cs.contains(&kv) && cs.len() < BOX_CANDS {
                    cs.push(kv);
                    self.cands.insert(v, cs);
                }
            }
        }
        return switch self.cands.get(&t) {
            Some(c) => c.clone(),
            None => Vector::<u64>::new(),
        };
    }

    // The bounds (lo, hi pairs, encodings) known of float `t` of the host's width `w`: a constant's, a
    // negation's and a magnitude's from their operand's, an operation's (`boxes`), and pairs of the
    // constants `t` is compared with, each alone with an infinity on its other side.
    fn bounds_of(self: &mut Self, tm: &Terms<B>, t: u32, w: u16) Vector<u64> {
        let x = tm.at(t);
        let mut out = Vector::<u64>::new();
        let (sb, mg) = (fsign(w), fsign(w) - 1);
        let inf = pick(w == 32, 0x7F800000u64, 0x7FF0000000000000u64);
        if x.op == T_INT {
            out.push(x.k.limb(0));
            out.push(x.k.limb(0));
            return out;
        }
        if (x.op == T_BXOR || x.op == T_BAND) && tm.at(x.b).op == T_INT && tm.at(x.b).k.limb(0) == pick(
            x.op == T_BXOR,
            sb,
            mg,
        ) {
            let inner = self.bounds_of(tm, x.a, w);
            for j in 0..inner.len() / 2 {
                let (lo, hi) = (inner[2 * j], inner[2 * j + 1]);
                if x.op == T_BXOR {
                    out.push(hi ^ sb);
                    out.push(lo ^ sb);
                } else if !host_lt(lo, 0, w) {
                    out.push(lo);
                    out.push(hi);
                } else if !host_lt(0, hi, w) {
                    out.push(hi & mg);
                    out.push(lo & mg);
                } else {
                    out.push(0);
                    out.push(pick(host_lt(lo & mg, hi, w), hi, lo & mg));
                }
            }
            return out;
        }
        if let Some(bx) = self.boxes.get(&t) {
            out.extend_copy(bx);
        }
        let cs = self.cands_of(tm, t);
        for i in 0..cs.len() {
            for j in 0..cs.len() {
                if out.len() >= 2 * BOX_MAX {
                    return out;
                }
                if i != j && host_lt(cs[i], cs[j], w) {
                    out.push(cs[i]);
                    out.push(cs[j]);
                }
            }
        }
        for i in 0..cs.len() {
            if out.len() >= 2 * BOX_MAX {
                break;
            }
            out.push(inf | sb);
            out.push(cs[i]);
            out.push(cs[i]);
            out.push(inf);
        }
        return out;
    }

    // The constant bits of encoding `k` of width `w`.
    const fn kvec(self: &Self, k: u64, w: u32) Vector<u32> {
        let mut kv = Vector::<u32>::with_capacity(w as usize);
        for i in 0..w {
            kv.push(pick((k >> i as u64 & 1) != 0, L_TRUE, L_FALSE));
        }
        return kv;
    }

    // The literal `k <= v` (`le`) or `v <= k` of float bits `v` and the encoding `k`, width `w`.
    fn kcmp(self: &mut Self, v: &Vector<u32>, k: u64, w: u32, fd: u64, le: bool) u32 {
        let kv = self.kvec(k, w);
        return if le {
            self.fcmp_bits(T_FLE, &kv, v, w, fd)
        } else {
            self.fcmp_bits(T_FLE, v, &kv, w, fd)
        };
    }

    // The bounds of float operation `t` (`x`, of the host's format) from its operands' (`bounds_of`): per
    // pair of their boxes whose corners the host computes without NaN, the clause that the operands in
    // their box put `t` in the corners' hull, and against each constant `t` is compared with that the
    // hull decides; the hull is one of `t`'s boxes.
    fn box_lemmas(self: &mut Self, tm: &Terms<B>, t: u32, x: &Term<B>, nc: u32) {
        let w = x.w;
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        let unary = x.op == T_FSQRT || x.op == T_FRINT || x.op == T_FCVT;
        if !(x.op == T_FADD || x.op == T_FMUL || x.op == T_FDIV || unary) || host_fw(w, fd) == 0 {
            return;
        }
        let sw = tm.at(x.a).w;
        let sfd = pick(x.op == T_FCVT, x.k.limb(0) >> 32, fd);
        if host_fw(sw, sfd) == 0 {
            return;
        }
        let ba = self.bounds_of(tm, x.a, sw);
        let bb = if unary {
            let mut one = Vector::<u64>::new();
            one.push(0);
            one.push(0);
            one
        } else {
            self.bounds_of(tm, x.b, w)
        };
        if ba.len() == 0 || bb.len() == 0 {
            return;
        }
        let r = self.fbits(tm, t, w);
        let a = self.fbits(tm, x.a, sw);
        let b = if unary {
            Vector::<u32>::new()
        } else {
            self.fbits(tm, x.b, w)
        };
        let cs = self.cands_of(tm, t);
        let mut hulls = Vector::<u64>::new();
        let mut c = Vector::<u32>::new();
        for i in 0..ba.len() / 2 {
            for j in 0..bb.len() / 2 {
                if hulls.len() >= 2 * BOX_MAX {
                    break;
                }
                let (la, ha, lb, hb) = (ba[2 * i], ba[2 * i + 1], bb[2 * j], bb[2 * j + 1]);
                let (lo, hi) = match_hull(tm, x, la, ha, lb, hb, sw);
                if lo == NONE64 {
                    continue;
                }
                c.clear();
                c.push(nc ^ 1);
                c.push(self.kcmp(&a, la, sw, sfd, true));
                c.push(self.kcmp(&a, ha, sw, sfd, false));
                if !unary {
                    c.push(self.kcmp(&b, lb, w, fd, true));
                    c.push(self.kcmp(&b, hb, w, fd, false));
                }
                let rl = self.kcmp(&r, lo, w, fd, true);
                let rh = self.kcmp(&r, hi, w, fd, false);
                self.imply(&c, rl);
                self.imply(&c, rh);
                for k in 0..cs.len() {
                    let kv = self.kvec(cs[k], w);
                    if !host_lt(cs[k], hi, w) {
                        let rk = self.fcmp_bits(pick(host_lt(hi, cs[k], w), T_FLT, T_FLE), &r, &kv, w, fd);
                        self.imply(&c, rk);
                        if host_lt(hi, cs[k], w) {
                            let rk2 = self.fcmp_bits(T_FLE, &r, &kv, w, fd);
                            self.imply(&c, rk2);
                        }
                    }
                    if !host_lt(lo, cs[k], w) {
                        let rk = self.fcmp_bits(pick(host_lt(cs[k], lo, w), T_FLT, T_FLE), &kv, &r, w, fd);
                        self.imply(&c, rk);
                        if host_lt(cs[k], lo, w) {
                            let rk2 = self.fcmp_bits(T_FLE, &kv, &r, w, fd);
                            self.imply(&c, rk2);
                        }
                    }
                }
                hulls.push(lo);
                hulls.push(hi);
            }
        }
        if hulls.len() != 0 {
            self.boxes.insert(t, hulls);
        }
    }

    // The IEEE comparison `op` of encodings `a` and `b` (width `w`, format `fd`).
    fn fcmp_bits(self: &mut Self, op: u8, a: &Vector<u32>, b: &Vector<u32>, w: u32, fd: u64) u32 {
        let fa = self.unpack(a, w, fd);
        let fb = self.unpack(b, w, fd);
        let n0 = self.or2(fa.nan, fb.nan);
        let both = self.and2(fa.zero, fb.zero);
        let same = self.eqv(a, b);
        let e0 = self.or2(same, both);
        let eq = self.and2(n0 ^ 1, e0);
        if op == T_FEQ {
            return eq;
        }
        let mut ma = Vector::<u32>::new();
        let mut mb = Vector::<u32>::new();
        for i in 0..w - 1 {
            ma.push(a[i as usize]);
            mb.push(b[i as usize]);
        }
        let lt_m = self.ult(&ma, &mb);
        let gt_m = self.ult(&mb, &ma);
        // Negative below positive; among negatives the greater magnitude is below.
        let neg = self.mux(fb.s, gt_m, L_TRUE);
        let pos = self.mux(fb.s, L_FALSE, lt_m);
        let ord = self.mux(fa.s, neg, pos);
        let ok = self.and2(n0 ^ 1, both ^ 1);
        let lt = self.and2(ok, ord);
        if op == T_FLT {
            return lt;
        }
        return self.or2(lt, eq);
    }
}

// The fields of a float (`Blaster::unpack`): sign, whether it is a zero, an infinity, a NaN; the
// significand with its hidden bit (M + 1 bits), the exponent (fx bits, a subnormal's as 1).
struct Fp {
    s: u32,
    zero: u32,
    inf: u32,
    nan: u32,
    sig: Vector<u32>,
    ee: Vector<u32>,
}

// The guard bits of a sum (`Blaster::fsum`), and the most cells (steps times bits) of an exact `fmod`
// circuit (`Blaster::frem`): `f32`'s 279 steps of 25 bits fit, `f64`'s 2100 of 54 do not.
const FG: u32 = 4;
const FREM_CELLS: u64 = 16384;
// The earlier operations of one kind and format each float operation gets facts against.
const FPAIR_MAX: u32 = 16;

// A zero sign bit after the `w` bits of an unsigned value.
fn sign_of(v: &mut Vector<u32>, sg: bool) {
    if !sg {
        v.push(L_FALSE);
    }
}

// Bit `i` of `k`'s two's complement.
const fn num_bit<const B: usize>(k: Num<B>, i: u32) bool {
    if i as usize >= B {
        return k.is_negative();
    }
    return (k.limb((i / 64) as usize) >> (i % 64) as u64 & 1) != 0;
}

// The fewest bits that hold `k` as a signed number.
const fn min_bits<const B: usize>(k: Num<B>) u32 {
    let m = if k.is_negative() {
        Num::<B>::zero() - k - Num::<B>::one()
    } else {
        k
    };
    let mut n: u32 = 0;
    for i in 0..(B / 64) as u32 {
        let l = m.limb(i as usize);
        if l != 0 {
            n = i * 64 + 64 - l.leading_zeros() as u32;
        }
    }
    return n + 1;
}

// The most constants of one term (`Blaster::cands_of`) and boxes of one term (`bounds_of`, `box_lemmas`).
const BOX_CANDS: usize = 4;
const BOX_MAX: usize = 4;
const NONE64: u64 = u64::MAX;

// Whether encoding `a` is below encoding `b`, floats of the host's width `w` (IEEE: a NaN is neither).
const fn host_lt(a: u64, b: u64, w: u16) bool {
    return if w == 32 {
        f32::from_bits(a as u32) < f32::from_bits(b as u32)
    } else {
        f64::from_bits(a) < f64::from_bits(b)
    };
}

// Whether encoding `v` of width `w` is an infinity.
const fn host_inf(v: u64, w: u16) bool {
    let mg = fsign(w) - 1;
    return (v & mg) == pick(w == 32, 0x7F800000u64, 0x7FF0000000000000u64);
}

// The host's square root or rounding (`x.op`) of encoding `v` of width `w`; NONE64 for a NaN.
const fn host_unary<const B: usize>(x: &Term<B>, v: u64) u64 {
    let w = x.w;
    let f = pick(w == 32, f32::from_bits(v as u32), f64::from_bits(v));
    let md = (x.k.limb(0) >> 32) as u16;
    let r = if x.op == T_FSQRT {
        pick(w == 32, (f as f32).sqrt(), f.sqrt())
    } else if md == FR_ROUND {
        f.round()
    } else if md == FR_FLOOR {
        f.floor()
    } else if md == FR_CEIL {
        f.ceil()
    } else if md == FR_TRUNC {
        f.trunc()
    } else if (f - f.trunc()).abs() == 0.5 {
        2.0 * (f / 2.0).round()
    } else {
        f.round()
    };
    if r.is_nan() {
        return NONE64;
    }
    return pick(w == 32, (r as f32).to_bits(), r.to_bits());
}

// The hull (lo, hi) of the results of float operation `x` over the operand boxes [la, ha] and [lb, hb]
// (encodings; the first operand of width `sw`): the least and greatest of the host's results at the
// corners; (NONE64, NONE64) where a NaN may lie inside (a corner's, an infinity against a zero factor or
// another infinity, a divisor's zero).
fn match_hull<const B: usize>(tm: &Terms<B>, x: &Term<B>, la: u64, ha: u64, lb: u64, hb: u64, sw: u16) (u64, u64) {
    let _ = tm;
    let w = x.w;
    let none = (NONE64, NONE64);
    let mut cs = Vector::<u64>::with_capacity(4);
    if x.op == T_FSQRT || x.op == T_FRINT {
        if x.op == T_FSQRT && host_lt(la, 0, w) {
            return none;
        }
        cs.push(host_unary(x, la));
        cs.push(host_unary(x, ha));
    } else if x.op == T_FCVT {
        for v in [la, ha] {
            cs.push(
                switch fold_float(T_FCVT, w, false, x.k.limb(0), sw, u64_val::<B>(v), Num::<B>::zero()) {
                    Some(r) => r.limb(0),
                    None => NONE64,
                },
            );
        }
    } else {
        let a_inf = host_inf(la, w) || host_inf(ha, w);
        let b_inf = host_inf(lb, w) || host_inf(hb, w);
        let a_zero = !host_lt(0, la, w) && !host_lt(ha, 0, w);
        let b_zero = !host_lt(0, lb, w) && !host_lt(hb, 0, w);
        if x.op == T_FMUL && (a_zero && b_inf || b_zero && a_inf) || x.op == T_FDIV && (b_zero || a_inf && b_inf) {
            return none;
        }
        for (p, q) in [(la, lb), (la, hb), (ha, lb), (ha, hb)] {
            cs.push(
                switch fold_float(x.op, w, false, x.k.limb(0), w, u64_val::<B>(p), u64_val::<B>(q)) {
                    Some(r) => r.limb(0),
                    None => NONE64,
                },
            );
        }
    }
    let mut lo = cs[0];
    let mut hi = cs[0];
    for j in 0..cs.len() {
        if cs[j] == NONE64 {
            return none;
        }
        if host_lt(cs[j], lo, w) {
            lo = cs[j];
        }
        if host_lt(hi, cs[j], w) {
            hi = cs[j];
        }
    }
    return lo, hi;
}
