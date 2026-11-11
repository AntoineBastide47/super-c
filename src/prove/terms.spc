// The terms of the contract prover: a hash-consed table of exact integer values, formulas and
// values of memory and aggregates (`Terms`), their bounds, and the linear form of an integer term.
// The walk (`prove.spc`) builds them, the solvers (`solver.spc`) decide formulas over them, and the
// certificate checker (`kernel.spc`) reads them: their meaning here is trusted by all three.
import ast::ast as *;

// The prover's numbers: exact integers of `B` bits. A prover of `B`-bit numbers reads integer types
// of up to `B - 64` bits (`int_limit`), which leaves room for their sign and sums. A function proves
// with NUM_NARROW numbers when all its integers fit, else with NUM_WIDE ones (`check_kept`): wide
// numbers cost about 2.5 times as much (copies of 72 bytes, 9 limbs per operation).
pub(package) type Num<const B: usize> = Int<B>;

pub(package) const NUM_NARROW: usize = 256;
pub(package) const NUM_WIDE: usize = 576;

// The widest `UInt<N>` and `Int<N>` a prover of `B`-bit numbers reads as integers.
pub(package) const fn int_limit(b: usize) i64 {
    return b as i64 - 64;
}

pub(package) const NONE: u32 = 0xFFFFFFFF;
// The steps of one term walk (linear forms) and the gcd loop (a Euclid over NUM_WIDE bits ends in under
// 830).
pub(package) const LIN_MAX: u32 = 4096;
// The most products of atoms a product of sums expands into (`Terms::product`).
const MUL_TERMS_MAX: usize = 16;
const GCD_MAX: u32 = 900;

// Term operations. Integers are exact (mathematical) values of their type; booleans are formulas.
pub(package) const T_INT: u8 = 0; // k = the value
pub(package) const T_BOOL: u8 = 1; // k = 0 or 1
pub(package) const T_VAR: u8 = 2; // a = the variable's number: an unknown value of its type
pub(package) const T_ADD: u8 = 3;
pub(package) const T_SUB: u8 = 4;
pub(package) const T_MUL: u8 = 5;
pub(package) const T_NEG: u8 = 6;
// Atoms to the solver: their value is exact, the solver knows only their type's range (`bounds`).
pub(package) const T_DIV: u8 = 7;
pub(package) const T_REM: u8 = 8;
pub(package) const T_BAND: u8 = 9;
pub(package) const T_BOR: u8 = 10;
pub(package) const T_BXOR: u8 = 11;
pub(package) const T_SHL: u8 = 12;
pub(package) const T_SHR: u8 = 13;
pub(package) const T_BNOT: u8 = 14;
pub(package) const T_CAST: u8 = 15; // a narrowing or sign-changing cast of `a`
pub(package) const T_CALL: u8 = 16; // a `const fn` call: k = the callee's key, arguments [a, a + b) in `Terms.args`
pub(package) const T_REF: u8 = 17; // a shared reference to the value `a`
// Formulas.
pub(package) const T_LT: u8 = 18;
pub(package) const T_LE: u8 = 19;
pub(package) const T_EQ: u8 = 20;
pub(package) const T_NE: u8 = 21;
pub(package) const T_NOT: u8 = 22;
pub(package) const T_AND: u8 = 23;
pub(package) const T_OR: u8 = 24;
// Values of memory and aggregates.
pub(package) const T_AGG: u8 = 25; // a struct, tuple or array: its members [a, a + b) in `Terms.args`
pub(package) const T_UPD: u8 = 26; // `args[a]` with member `args[a + 1]` (a key) replaced by `args[a + 2]`
pub(package) const T_SEL: u8 = 27; // member `b` (a key) of `a`
pub(package) const T_LOAD: u8 = 28; // the value pointer `a` points to in memory epoch `b`
pub(package) const T_MREF: u8 = 29; // a mutable reference to local `a` of the body (or the caller of a frame)
pub(package) const T_VIEW: u8 = 30; // a view of array `a` of length k
pub(package) const T_DOWN: u8 = 31; // `a` as its variant k
pub(package) const T_ORD: u8 = 32; // the order of integers `a` and `b`: -1, 0 or 1 (a wide integer's `cmp`)
pub(package) const T_TAG: u8 = 33; // the discriminant of enum value `a`, an integer

// Whether an operand of operation `op` takes a product apart (`Terms::product`): a sum, a difference,
// a negation or a product.
const fn compound(op: u8) bool {
    return op == T_ADD || op == T_SUB || op == T_NEG || op == T_MUL;
}

// Whether terms `x` and `y` are one operation (their operands aside): the same operation of the same
// type, or the same sum, difference, product or negation, whose exact value no type changes.
pub(package) const fn same_op<const B: usize>(x: &Term<B>, y: &Term<B>) bool {
    let ring = x.op >= T_ADD && x.op <= T_NEG;
    return x.op == y.op && x.k == y.k && (ring || x.w == y.w && x.sg == y.sg);
}

// Whether binary operation `op` gives the same value with its operands swapped: congruence then
// pairs them either way (the index order of the operands of `x * y` and `y * x` is the order of
// their own terms, which an equality between operands does not keep).
pub(package) const fn commutes(op: u8) bool {
    return op == T_ADD || op == T_MUL || op == T_BAND || op == T_BOR || op == T_BXOR || op == T_EQ || op == T_NE || op == T_AND || op == T_OR;
}

// Whether operation `op` keeps its operands in `Terms.args`.
pub(package) const fn pooled(op: u8) bool {
    return op == T_CALL || op == T_AGG || op == T_UPD;
}

// `Term.w`: an integer's bit width; W_BOOL for a boolean; W_OTHER for any other value.
pub(package) const W_OTHER: u16 = 0;
pub(package) const W_BOOL: u16 = 1;
// The widths of the exact integers of specifications: `nat` (at least 0) and `int`, without bounds.
// No bits hold them (`Blaster::run`).
pub(package) const W_NAT: u16 = 0xFFFE;
pub(package) const W_INT: u16 = 0xFFFF;

// Whether width `w` is `nat`'s or `int`'s.
pub(package) const fn exact_w(w: u16) bool {
    return w >= W_NAT;
}

pub(package) struct Term<const B: usize> {
    pub(package) k: Num<B>,
    pub(package) a: u32,
    pub(package) b: u32,
    pub(package) op: u8,
    pub(package) w: u16,
    pub(package) sg: bool,
}

// The hash-consed term table: a term built twice is one term, so equal values compare by index.
pub(package) struct Terms<const B: usize> {
    pub(package) ts: Vector<Term<B>>,
    pub(package) ix: Map<u64, u32>,
    pub(package) args: Vector<u32>,
    pub(package) nvars: u32,
    // Per term: whether it holds an operation the arithmetic reads as an atom but the bits define (a
    // bit operation, a shift, a cast, a division, a remainder, an order, a product of two unknowns),
    // under sums, products and formulas.
    pub(package) bitty: Vector<bool>,
}

pub(package) const fn hmix(h: u64, v: u64) u64 {
    return (h ^ v).wrapping_mul(0x100000001B3u64) ^ h >> 29;
}

// The value of an unsigned 64-bit pattern.
pub(package) const fn u64_val<const B: usize>(v: u64) Num<B> {
    let mut x = Num::<B>::zero();
    x.set_limb(0, v);
    return x;
}

pub(package) const fn wide<const B: usize>(v: i64) Num<B> {
    return Num::<B>::from_i64(v);
}

extend<const B: usize> Terms<B> {
    pub(package) fn new() Terms<B> {
        return Terms::<B> {
            ts: Vector::<Term<B>>::new(),
            ix: Map::<u64, u32>::new(),
            args: Vector::<u32>::new(),
            nvars: 0,
            bitty: Vector::<bool>::new(),
        };
    }

    pub(package) fn clear(self: &mut Self) {
        self.ts.clear();
        self.ix.clear();
        self.args.clear();
        self.nvars = 0;
        self.bitty.clear();
    }

    pub(package) const fn at(self: &Self, t: u32) Term<B> {
        return self.ts[t as usize];
    }

    pub(package) const fn key(self: &Self, t: &Term<B>) u64 {
        let mut h = hmix(0xCBF29CE484222325u64, t.op as u64 << 24 | t.w as u64 << 1 | t.sg as u64);
        // A call's argument list is hashed by content: `a` is only where it lies.
        let pos: u64 = if pooled(t.op) {
            0
        } else {
            t.a
        };
        h = hmix(h, pos << 32 | t.b as u64);
        h = hmix(h, t.k.limb(0));
        h = hmix(h, t.k.limb(1));
        h = hmix(h, t.k.limb(2));
        h = hmix(h, t.k.limb(3));
        if pooled(t.op) {
            for j in t.a..t.a + t.b {
                h = hmix(h, self.args[j as usize]);
            }
        }
        return h;
    }

    pub(package) const fn same(self: &Self, x: &Term<B>, y: &Term<B>) bool {
        if x.op != y.op || x.w != y.w || x.sg != y.sg || x.k != y.k || x.b != y.b {
            return false;
        }
        if !pooled(x.op) {
            return x.a == y.a;
        }
        for j in 0..x.b {
            if self.args[(x.a + j) as usize] != self.args[(y.a + j) as usize] {
                return false;
            }
        }
        return true;
    }

    // The index of term `t`: the earlier one when it was built before.
    pub(package) fn make(self: &mut Self, t: Term<B>) u32 {
        let h = self.key(&t);
        let hit = switch self.ix.get(&h) {
            Some(x) => *x,
            None => NONE,
        };
        if hit != NONE && self.same(&self.ts[hit as usize], &t) {
            if pooled(t.op) {
                self.args.truncate(t.a as usize);
            }
            return hit;
        }
        let n = self.ts.len() as u32;
        let own = t.op >= T_DIV && t.op <= T_CAST || t.op == T_ORD || t.op == T_MUL && self.ts[t.a as usize].op != T_INT && self.ts[t.b as usize].op != T_INT;
        let under = t.op >= T_ADD && t.op <= T_NEG || t.op >= T_LT && t.op <= T_OR;
        let unary = t.op == T_NEG || t.op == T_NOT;
        self.bitty.push(own || under && (self.bitty[t.a as usize] || !unary && self.bitty[t.b as usize]));
        self.ts.push(t);
        if hit == NONE {
            self.ix.insert(h, n);
        }
        return n;
    }

    pub(package) fn int(self: &mut Self, k: Num<B>, w: u16, sg: bool) u32 {
        return self.make(Term::<B> { k: k, a: 0, b: 0, op: T_INT, w: w, sg: sg });
    }

    pub(package) fn boolean(self: &mut Self, v: bool) u32 {
        return self.make(Term::<B> { k: wide::<B>(v as i64), a: 0, b: 0, op: T_BOOL, w: W_BOOL, sg: false });
    }

    pub(package) fn var(self: &mut Self, w: u16, sg: bool) u32 {
        let n = self.nvars;
        self.nvars += 1;
        return self.make(Term::<B> { k: Num::<B>::zero(), a: n, b: 0, op: T_VAR, w: w, sg: sg });
    }

    pub(package) const fn is_true(self: &Self, t: u32) bool {
        let x = self.ts[t as usize];
        return x.op == T_BOOL && x.k == wide::<B>(1);
    }

    pub(package) const fn is_false(self: &Self, t: u32) bool {
        let x = self.ts[t as usize];
        return x.op == T_BOOL && x.k.is_zero();
    }

    pub(package) const fn is_int(self: &Self, t: u32) bool {
        return self.ts[t as usize].w > W_BOOL;
    }

    pub(package) const fn is_bool(self: &Self, t: u32) bool {
        return self.ts[t as usize].w == W_BOOL;
    }

    // An arithmetic or bit operation of type (`w`, `sg`); two constants fold when the exact result fits
    // B bits (an arithmetic one only: the atoms keep their node).
    pub(package) fn arith(self: &mut Self, op: u8, a: u32, b: u32, w: u16, sg: bool) u32 {
        let x = self.ts[a as usize];
        let y = self.ts[b as usize];
        if x.op == T_INT && y.op == T_INT {
            let r = if op == T_ADD {
                x.k.checked_add(&y.k)
            } else if op == T_SUB {
                x.k.checked_sub(&y.k)
            } else if op == T_MUL {
                x.k.checked_mul(&y.k)
            } else {
                Option::<Num<B>>::None
            };
            if let Some(v) = r {
                return self.int(v, w, sg);
            }
        }
        if (op == T_ADD || op == T_SUB) && y.op == T_INT && y.k.is_zero() {
            return a;
        }
        if op == T_ADD && x.op == T_INT && x.k.is_zero() {
            return b;
        }
        if op == T_MUL && x.op != T_INT && y.op != T_INT && (compound(x.op) || compound(y.op)) {
            let r = self.product(a, b, w, sg);
            if r != NONE {
                return r;
            }
        }
        // A commutative operation keeps its operands in index order, so `x + y` and `y + x` are one term.
        if a > b && (op == T_ADD || op == T_MUL || op == T_BAND || op == T_BOR || op == T_BXOR) {
            return self.make(Term::<B> { k: Num::<B>::zero(), a: b, b: a, op: op, w: w, sg: sg });
        }
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: b, op: op, w: w, sg: sg });
    }

    // `a * b` as a sum of products of atoms with constant coefficients, each product's factors in
    // index order: `(x - 1) * y` is `x * y - y`, `x * (y * z)` is `(x * y) * z`. NONE past
    // MUL_TERMS_MAX products or B-bit coefficients: the caller keeps the plain product.
    fn product(self: &mut Self, a: u32, b: u32, w: u16, sg: bool) u32 {
        let mut la = Vector::<LinTerm<B>>::new();
        let mut lb = Vector::<LinTerm<B>>::new();
        let mut st = Vector::<LinTerm<B>>::new();
        let mut ka = Num::<B>::zero();
        let mut kb = Num::<B>::zero();
        if !lin_form(self, a, Num::<B>::one(), &mut ka, &mut la, &mut st) || !lin_form(
            self,
            b,
            Num::<B>::one(),
            &mut kb,
            &mut lb,
            &mut st,
        ) {
            return NONE;
        }
        let na = merge_terms(&mut la, 0, la.len());
        la.truncate(na);
        let nb = merge_terms(&mut lb, 0, lb.len());
        lb.truncate(nb);
        let ca = na + (!ka.is_zero()) as usize;
        let cb = nb + (!kb.is_zero()) as usize;
        if ca * cb > MUL_TERMS_MAX {
            return NONE;
        }
        let mut out = Vector::<LinTerm<B>>::with_capacity(ca * cb);
        for i in 0..na {
            for j in 0..nb {
                let m = self.monomial(la[i].atom, lb[j].atom, w, sg);
                switch la[i].c.checked_mul(&lb[j].c) {
                    Some(c) => out.push(LinTerm::<B> { c: c, atom: m }),
                    None => {
                        return NONE;
                    },
                }
            }
            if !kb.is_zero() {
                switch la[i].c.checked_mul(&kb) {
                    Some(c) => out.push(LinTerm::<B> { c: c, atom: la[i].atom }),
                    None => {
                        return NONE;
                    },
                }
            }
        }
        if !ka.is_zero() {
            for j in 0..nb {
                switch lb[j].c.checked_mul(&ka) {
                    Some(c) => out.push(LinTerm::<B> { c: c, atom: lb[j].atom }),
                    None => {
                        return NONE;
                    },
                }
            }
        }
        let k = switch ka.checked_mul(&kb) {
            Some(v) => v,
            None => {
                return NONE;
            },
        };
        let n = merge_terms(&mut out, 0, out.len());
        let mut r = self.int(k, w, sg);
        for j in 0..n {
            let e = out[j];
            let neg = e.c.is_negative();
            let m = switch mag(e.c) {
                Some(v) => v,
                None => {
                    return NONE;
                },
            };
            let t = if m == Num::<B>::one() {
                e.atom
            } else {
                let c = self.int(m, w, sg);
                self.arith(T_MUL, c, e.atom, w, sg)
            };
            r = self.arith(pick(neg, T_SUB, T_ADD), r, t, w, sg);
        }
        return r;
    }

    // The product of atoms `x` and `y` (each an atom or such a product): their factors in index order,
    // nested from the left.
    fn monomial(self: &mut Self, x: u32, y: u32, w: u16, sg: bool) u32 {
        let mut fs = Vector::<u32>::new();
        let mut st = Vector::<u32>::new();
        st.push(x);
        st.push(y);
        for _s in 0..LIN_MAX {
            if st.len() == 0 {
                break;
            }
            let t = st.pop().unwrap();
            let v = self.ts[t as usize];
            if v.op == T_MUL && self.ts[v.a as usize].op != T_INT && self.ts[v.b as usize].op != T_INT {
                st.push(v.a);
                st.push(v.b);
            } else {
                fs.push(t);
            }
        }
        fs.sort_stable_in_place();
        let mut p = fs[0];
        for j in 1..fs.len() {
            let (l, r) = if p < fs[j] {
                (p, fs[j])
            } else {
                (fs[j], p)
            };
            p = self.make(Term::<B> { k: Num::<B>::zero(), a: l, b: r, op: T_MUL, w: w, sg: sg });
        }
        return p;
    }

    pub(package) fn neg(self: &mut Self, a: u32, w: u16, sg: bool) u32 {
        let x = self.ts[a as usize];
        if x.op == T_INT {
            if let Some(v) = Num::<B>::zero().checked_sub(&x.k) {
                return self.int(v, w, sg);
            }
        }
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: 0, op: T_NEG, w: w, sg: sg });
    }

    pub(package) fn unary(self: &mut Self, op: u8, a: u32, w: u16, sg: bool) u32 {
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: 0, op: op, w: w, sg: sg });
    }

    // A comparison of two integers, or (`T_EQ`, `T_NE`) of two booleans or two other values.
    pub(package) fn cmp(self: &mut Self, op: u8, a: u32, b: u32) u32 {
        let x = self.ts[a as usize];
        let y = self.ts[b as usize];
        if x.op == T_INT && y.op == T_INT || x.op == T_BOOL && y.op == T_BOOL {
            let r = if op == T_LT {
                x.k < y.k
            } else if op == T_LE {
                x.k <= y.k
            } else if op == T_EQ {
                x.k == y.k
            } else {
                x.k != y.k
            };
            return self.boolean(r);
        }
        if a == b {
            return self.boolean(op == T_LE || op == T_EQ);
        }
        // An order against a constant is a comparison of its operands.
        if x.op == T_ORD && y.op == T_INT {
            return self.ord_vs(op, x, y.k, false);
        }
        if y.op == T_ORD && x.op == T_INT {
            return self.ord_vs(op, y, x.k, true);
        }
        if a > b && (op == T_EQ || op == T_NE) {
            return self.make(Term::<B> { k: Num::<B>::zero(), a: b, b: a, op: op, w: W_BOOL, sg: false });
        }
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: b, op: op, w: W_BOOL, sg: false });
    }

    // `s op c` for the order `s` of `o.a` and `o.b` (-1, 0 or 1) and constant `c`; `flip`: `c op s`.
    fn ord_vs(self: &mut Self, op: u8, o: Term<B>, c: Num<B>, flip: bool) u32 {
        let m1 = wide::<B>(-1);
        let one = Num::<B>::one();
        // s < c and s <= c by c; c < s is not s <= c, c <= s is not s < c.
        if flip && (op == T_LT || op == T_LE) {
            let r = self.ord_vs(pick(op == T_LT, T_LE, T_LT), o, c, false);
            return self.not(r);
        }
        if op == T_NE {
            let r = self.ord_vs(T_EQ, o, c, false);
            return self.not(r);
        }
        let lt = op == T_LT;
        if op == T_EQ {
            if c == m1 {
                return self.cmp(T_LT, o.a, o.b);
            }
            if c.is_zero() {
                return self.cmp(T_EQ, o.a, o.b);
            }
            if c == one {
                return self.cmp(T_LT, o.b, o.a);
            }
            return self.boolean(false);
        }
        // s < c is s <= c - 1.
        let d = if lt {
            c - one
        } else {
            c
        };
        if d < m1 {
            return self.boolean(false);
        }
        if d == m1 {
            return self.cmp(T_LT, o.a, o.b);
        }
        if d.is_zero() {
            return self.cmp(T_LE, o.a, o.b);
        }
        return self.boolean(true);
    }

    // The order of integers `a` and `b` (-1, 0 or 1), of type (`w`, `sg`).
    pub(package) fn ord(self: &mut Self, a: u32, b: u32, w: u16, sg: bool) u32 {
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: b, op: T_ORD, w: w, sg: sg });
    }

    pub(package) fn not(self: &mut Self, a: u32) u32 {
        let x = self.ts[a as usize];
        if x.op == T_BOOL {
            return self.boolean(x.k.is_zero());
        }
        if x.op == T_NOT {
            return x.a;
        }
        if x.op == T_LT {
            return self.cmp(T_LE, x.b, x.a);
        }
        if x.op == T_LE {
            return self.cmp(T_LT, x.b, x.a);
        }
        if x.op == T_EQ {
            return self.cmp(T_NE, x.a, x.b);
        }
        if x.op == T_NE {
            return self.cmp(T_EQ, x.a, x.b);
        }
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: 0, op: T_NOT, w: W_BOOL, sg: false });
    }

    pub(package) fn and(self: &mut Self, a: u32, b: u32) u32 {
        if self.is_true(a) || a == b {
            return b;
        }
        if self.is_true(b) {
            return a;
        }
        if self.is_false(a) || self.is_false(b) {
            return self.boolean(false);
        }
        return self.make(
            Term::<B> {
                k: Num::<B>::zero(),
                a: pick(a < b, a, b),
                b: pick(a < b, b, a),
                op: T_AND,
                w: W_BOOL,
                sg: false,
            },
        );
    }

    pub(package) fn or(self: &mut Self, a: u32, b: u32) u32 {
        if self.is_false(a) || a == b {
            return b;
        }
        if self.is_false(b) {
            return a;
        }
        if self.is_true(a) || self.is_true(b) {
            return self.boolean(true);
        }
        return self.make(
            Term::<B> {
                k: Num::<B>::zero(),
                a: pick(a < b, a, b),
                b: pick(a < b, b, a),
                op: T_OR,
                w: W_BOOL,
                sg: false,
            },
        );
    }

    // A `const fn` call of the callee keyed `key` over the arguments `xs`, of type (`w`, `sg`).
    pub(package) fn call(self: &mut Self, key: u64, xs: &Vector<u32>, w: u16, sg: bool) u32 {
        let a = self.args.len() as u32;
        for j in 0..xs.len() {
            self.args.push(xs[j]);
        }
        return self.make(Term::<B> { k: u64_val::<B>(key), a: a, b: xs.len() as u32, op: T_CALL, w: w, sg: sg });
    }

    pub(package) fn pool(self: &mut Self, op: u8, xs: &Vector<u32>, k: Num<B>) u32 {
        let a = self.args.len() as u32;
        for j in 0..xs.len() {
            self.args.push(xs[j]);
        }
        return self.make(Term::<B> { k: k, a: a, b: xs.len() as u32, op: op, w: W_OTHER, sg: false });
    }

    // `v` with member `key` replaced by `x`.
    pub(package) fn upd(self: &mut Self, v: u32, key: u32, x: u32) u32 {
        let a = self.args.len() as u32;
        self.args.push(v);
        self.args.push(key);
        self.args.push(x);
        return self.make(Term::<B> { k: Num::<B>::zero(), a: a, b: 3, op: T_UPD, w: W_OTHER, sg: false });
    }

    // Member `key` of `v`, of type (`w`, `sg`): an aggregate's member, through its updates where the
    // keys are the same term or two different constants.
    pub(package) fn sel(self: &mut Self, v0: u32, key: u32, w: u16, sg: bool) u32 {
        let mut v = v0;
        let kx = self.ts[key as usize];
        for _s in 0..LIN_MAX {
            let x = self.ts[v as usize];
            if x.op == T_AGG && kx.op == T_INT && !kx.k.is_negative() && kx.k < wide::<B>(x.b) {
                return self.args[(x.a + kx.k.to_i64() as u32) as usize];
            }
            if x.op != T_UPD {
                break;
            }
            let k2 = self.args[(x.a + 1) as usize];
            if k2 == key {
                return self.args[(x.a + 2) as usize];
            }
            if kx.op != T_INT || self.ts[k2 as usize].op != T_INT {
                break;
            }
            v = self.args[x.a as usize];
        }
        return self.make(Term::<B> { k: Num::<B>::zero(), a: v, b: key, op: T_SEL, w: w, sg: sg });
    }

    // The range of type (`w`, `sg`) as (lo, hi).
    pub(package) const fn range(w: u16, sg: bool) (Num<B>, Num<B>) {
        if sg {
            let h = Num::<B>::one().shl((w - 1) as usize);
            return Num::<B>::zero() - h, h - Num::<B>::one();
        }
        return Num::<B>::zero(), Num::<B>::one().shl(w as usize) - Num::<B>::one();
    }

    // The value of the low `w` bits of non-negative `v` in a type of signedness `sg`.
    pub(package) fn wrap(v: Num<B>, w: u16, sg: bool) Num<B> {
        let m = Num::<B>::one().shl(w as usize);
        let r = v.rem_euclid(&m);
        if sg && !(r < Num::<B>::one().shl((w - 1) as usize)) {
            return r - m;
        }
        return r;
    }

    // Whether integer `t` is in its type's range, as a formula.
    pub(package) fn in_range(self: &mut Self, t: u32) u32 {
        let x = self.ts[t as usize];
        if exact_w(x.w) {
            if x.w == W_INT {
                return self.boolean(true);
            }
            let z = self.int(Num::<B>::zero(), x.w, x.sg);
            return self.cmp(T_LE, z, t);
        }
        let (lo, hi) = Terms::<B>::range(x.w, x.sg);
        let l = self.int(lo, x.w, x.sg);
        let h = self.int(hi, x.w, x.sg);
        let c1 = self.cmp(T_LE, l, t);
        let c2 = self.cmp(T_LE, t, h);
        return self.and(c1, c2);
    }

    // The bounds of atom `t`, None where it has none: its type's range, narrowed for a remainder by a
    // positive constant and a mask of an unsigned value. A product of two unknowns is an exact value,
    // which may lie outside its type (an overflow obligation asks whether it does): its bounds are the
    // products of its operands' ranges, None when one leaves B bits or an operand is such a product.
    pub(package) fn bounds(self: &Self, t: u32) Option<(Num<B>, Num<B>)> {
        let x = self.ts[t as usize];
        if x.w <= W_BOOL || exact_w(x.w) {
            return None;
        }
        if x.op == T_ORD {
            return Some((wide::<B>(-1), Num::<B>::one()));
        }
        if x.op == T_MUL {
            let p = self.ts[x.a as usize];
            let q = self.ts[x.b as usize];
            if p.w <= W_BOOL || q.w <= W_BOOL || exact_w(p.w) || exact_w(q.w) || p.op == T_MUL || q.op == T_MUL {
                return None;
            }
            let (pl, ph) = Terms::<B>::range(p.w, p.sg);
            let (ql, qh) = Terms::<B>::range(q.w, q.sg);
            let ends: [Num<B>; 4] = [pl, ph, ql, qh];
            let mut lo = Num::<B>::zero();
            let mut hi = Num::<B>::zero();
            for j in 0..4 {
                switch ends[j / 2].checked_mul(&ends[2 + j % 2]) {
                    Some(v) => {
                        if j == 0 || v < lo {
                            lo = v;
                        }
                        if j == 0 || hi < v {
                            hi = v;
                        }
                    },
                    None => {
                        return None;
                    },
                }
            }
            return Some((lo, hi));
        }
        let (lo, hi) = Terms::<B>::range(x.w, x.sg);
        if !x.sg && (x.op == T_REM || x.op == T_BAND) {
            let y = self.ts[x.b as usize];
            if y.op == T_INT && !y.k.is_negative() && !y.k.is_zero() {
                let top = if x.op == T_REM {
                    y.k - Num::<B>::one()
                } else {
                    y.k
                };
                return Some((lo, top));
            }
        }
        return Some((lo, hi));
    }

    // The least value of atom `t`: its bounds' (`bounds`), 0 for a `nat`, None where it has none.
    pub(package) fn low(self: &Self, t: u32) Option<Num<B>> {
        if self.ts[t as usize].w == W_NAT {
            return Some(Num::<B>::zero());
        }
        return switch self.bounds(t) {
            Some((l, _h)) => Some(l),
            None => None,
        };
    }

    // The greatest value of atom `t` (`bounds`), None where it has none.
    pub(package) fn high(self: &Self, t: u32) Option<Num<B>> {
        return switch self.bounds(t) {
            Some((_l, h)) => Some(h),
            None => None,
        };
    }

    // The operands of term `t` that are terms, in order, into `out` (cleared first).
    pub(package) fn operands(self: &Self, t: u32, out: &mut Vector<u32>) {
        out.clear();
        let x = self.ts[t as usize];
        if pooled(x.op) {
            for j in x.a..x.a + x.b {
                out.push(self.args[j as usize]);
            }
            return;
        }
        if x.op == T_INT || x.op == T_BOOL || x.op == T_VAR || x.op == T_MREF {
            return;
        }
        out.push(x.a);
        if !(x.op == T_NEG || x.op == T_BNOT || x.op == T_CAST || x.op == T_REF || x.op == T_NOT || x.op == T_VIEW || x.op == T_DOWN || x.op == T_TAG) {
            out.push(x.b);
        }
    }
}

// The greatest common divisor of two non-negative values.
pub(package) fn gcd<const B: usize>(a0: Num<B>, b0: Num<B>) Num<B> {
    let mut a = a0;
    let mut b = b0;
    for _s in 0..GCD_MAX {
        if b.is_zero() {
            return a;
        }
        let r = a.rem_euclid(&b);
        a = b;
        b = r;
    }
    return Num::<B>::one();
}

// |x|, None for the one value whose magnitude leaves B bits.
pub(package) fn mag<const B: usize>(x: Num<B>) Option<Num<B>> {
    if x.is_negative() {
        return Num::<B>::zero().checked_sub(&x);
    }
    return Some(x);
}

// The gcd of the coefficients [s, e) of `v` (0 for none), None when one has no B-bit magnitude.
pub(package) fn coef_gcd<const B: usize>(v: &Vector<LinTerm<B>>, s: usize, e: usize) Option<Num<B>> {
    let mut g = Num::<B>::zero();
    for j in s..e {
        let a = switch mag(v[j].c) {
            Some(x) => x,
            None => {
                return None;
            },
        };
        g = if g.is_zero() {
            a
        } else {
            gcd(g, a)
        };
    }
    return Some(g);
}

pub(package) struct LinTerm<const B: usize> {
    pub(package) c: Num<B>,
    pub(package) atom: u32,
}

// Sort the terms [s, e) of `v` by atom and merge equal atoms, dropping zero coefficients; the new end.
pub(package) fn merge_terms<const B: usize>(v: &mut Vector<LinTerm<B>>, s: usize, e: usize) usize {
    for j in s + 1..e {
        let x = v[j];
        let mut q = j;
        while q > s && v[q - 1].atom > x.atom {
            v.set(q, v[q - 1]);
            q -= 1;
        }
        v.set(q, x);
    }
    let mut o = s;
    let mut j = s;
    while j < e {
        let mut x = v[j];
        j += 1;
        while j < e && v[j].atom == x.atom {
            x.c = x.c + v[j].c;
            j += 1;
        }
        if !x.c.is_zero() {
            v.set(o, x);
            o += 1;
        }
    }
    return o;
}

// `sum(c * atom) + k <= 0`, its terms [start, start + len) of a pool, sorted by atom.
pub(package) struct Row<const B: usize> {
    pub(package) k: Num<B>,
    pub(package) start: u32,
    pub(package) len: u32,
}

// Add `c * t` to the linear form in `out` (its constant in `k`): sums, differences, negations and
// products by a constant are taken apart, every other term is an atom. False when a coefficient
// leaves B bits or the walk passes LIN_MAX steps. `stack` is scratch.
pub(package) fn lin_form<const B: usize>(
    tm: &Terms<B>,
    t: u32,
    c: Num<B>,
    k: &mut Num<B>,
    out: &mut Vector<LinTerm<B>>,
    stack: &mut Vector<LinTerm<B>>,
) bool {
    stack.clear();
    stack.push(LinTerm::<B> { c: c, atom: t });
    for _s in 0..LIN_MAX {
        if stack.len() == 0 {
            return true;
        }
        let e = stack.pop().unwrap();
        let x = tm.at(e.atom);
        if x.op == T_INT {
            let mut ok = false;
            if let Some(v) = e.c.checked_mul(&x.k) {
                if let Some(sum) = k.checked_add(&v) {
                    *k = sum;
                    ok = true;
                }
            }
            if !ok {
                return false;
            }
        } else if x.op == T_ADD || x.op == T_SUB {
            stack.push(LinTerm::<B> { c: e.c, atom: x.a });
            let cb = if x.op == T_ADD {
                Some(e.c)
            } else {
                Num::<B>::zero().checked_sub(&e.c)
            };
            switch cb {
                Some(v) => stack.push(LinTerm::<B> { c: v, atom: x.b }),
                None => {
                    return false;
                },
            }
        } else if x.op == T_NEG {
            switch Num::<B>::zero().checked_sub(&e.c) {
                Some(v) => stack.push(LinTerm::<B> { c: v, atom: x.a }),
                None => {
                    return false;
                },
            }
        } else if x.op == T_MUL && (tm.at(x.a).op == T_INT || tm.at(x.b).op == T_INT) {
            let (kc, other) = if tm.at(x.a).op == T_INT {
                (tm.at(x.a).k, x.b)
            } else {
                (tm.at(x.b).k, x.a)
            };
            switch e.c.checked_mul(&kc) {
                Some(v) => stack.push(LinTerm::<B> { c: v, atom: other }),
                None => {
                    return false;
                },
            }
        } else {
            out.push(e);
        }
    }
    return false;
}
