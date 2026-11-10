// The meaning of terms as clauses, for the SAT refutations. Trusted, like `terms.spc`: the kernel
// checks LRAT proofs against the clauses written here (`Kernel::lrat`), so a wrong clause here can make
// a false proof pass.
//
// Two encodings:
//
// - the skeleton: the boolean structure of formulas (`!`, `&&`, `||`, `==` of booleans), each other
//   formula a variable (an atom). An integer equality `a == b` has two more variables, `a < b`
//   (SEL_LT) and `b < a` (SEL_GT), and the clause that one of the three holds. A branch the theory
//   solvers refute adds the negation of its literals as a clause; the case split holds when these
//   clauses and the skeleton have no model;
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
    fm: Map<u32, u32>, // a formula's literal
    atoms: Map<u64, u32>, // `term << 2 | sel`: an atom's variable
    vk: Map<u64, u32>, // `term << 16 | width`: the start of its bits in `vecs`
    vecs: Vector<u32>,
    nat: Map<u32, u32>,
    pub(package) leaves: Vector<u32>, // the integer terms the bits leave free, in order
    work: Vector<u64>,
    dep: Vector<u64>,
    nstack: Vector<u32>,
}

extend<const B: usize> Blaster<B> {
    pub(package) fn new() Blaster<B> {
        return Blaster::<B> {
            cnf: Cnf::new(),
            ok: true,
            bits: false,
            gates: Map::<u64, u32>::new(),
            fm: Map::<u32, u32>::new(),
            atoms: Map::<u64, u32>::new(),
            vk: Map::<u64, u32>::new(),
            vecs: Vector::<u32>::new(),
            nat: Map::<u32, u32>::new(),
            leaves: Vector::<u32>::new(),
            work: Vector::<u64>::new(),
            dep: Vector::<u64>::new(),
            nstack: Vector::<u32>::new(),
        };
    }

    // A new CNF: `bits` encodes integers as bits, else each integer comparison is an atom.
    pub(package) fn reset(self: &mut Self, bits: bool) {
        self.cnf.clear();
        self.ok = true;
        self.bits = bits;
        self.gates.clear();
        self.fm.clear();
        self.atoms.clear();
        self.vk.clear();
        self.vecs.clear();
        self.nat.clear();
        self.leaves.clear();
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
        let v = self.fresh();
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
}

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
