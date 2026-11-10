// The contract prover. After the borrow check, every kept body (`irl::Keep`) with a contract check
// (`ir::ContractSite`) or a call of a function with a `requires` clause runs over symbolic values,
// path by path, and each obligation on the way goes to the solver:
//
// - the body's own `ensures` at each return, and each loop's `invariant` when the loop starts and
//   after each iteration;
// - a callee's `requires` at each call, and a `decreases` measure at each call of the function to
//   itself;
// - in a body with contracts, no overflow in each operation that traps in a debug build and wraps in
//   a release one (`+`, `-`, `*`, negation), so its result is the same in every profile.
//
// The assumptions are the body's own `requires`, the conditions of the branches the path takes, the
// invariants of the loops it is in, and each callee's `ensures` after the call. A contract check is
// one chain of blocks (`ContractSite`): the walk never enters it, it evaluates the chain to one
// formula instead (`chain`), in the body's state or, for a callee, in a frame of the callee's
// locals bound to the call's arguments.
//
// A `@prove_exhaustive` function is not walked: its body runs through the evaluator (`ir::interp`)
// once for each value of its parameters (`exhaustive_job`, `run_inputs`), and each run checks every
// assertion and trap of that input exactly.
//
// Soundness: a value the walk does not model is a fresh unknown of its type (a read through a
// pointer or of a field, a local whose address is taken, a call's result); a loop header gives each
// local the loop writes a fresh value; the solver says "proved" only when its refutation closes every
// branch; each bound (steps, paths, rows, splits) makes the answer "not proved", never "proved".
import ast::ast as *;
import lexer::token as tok;
import lexer::token_type as tt;
import ir::core as ir;
import ir::lower as irl;
import ir::interp as iri;
import atomic;
import std::parallel::data as dpar;
import std::mem::ptr;
import ir::facts as fx;
import ir::layout as lay;
import module::loader as loader;
import utils::errors as diag;
import utils::diag_codes as dc;

const NONE: u32 = 0xFFFFFFFF;
// The blocks, chain blocks and solver rounds one body may spend.
const STEP_BUDGET: u32 = 200000;
// The paths waiting in one body's walk.
const PATHS_MAX: usize = 4096;
// The rows of one elimination round, and the branches of one refutation.
const ROWS_MAX: usize = 2048;
const SPLITS_MAX: u32 = 256;
// The steps of one term walk (linear forms) and the gcd loop (a 128-bit Euclid ends in under 190).
const LIN_MAX: u32 = 4096;
const GCD_MAX: u32 = 200;

// Term operations. Integers are exact (mathematical) values of their type; booleans are formulas.
const T_INT: u8 = 0; // k = the value
const T_BOOL: u8 = 1; // k = 0 or 1
const T_VAR: u8 = 2; // a = the variable's number: an unknown value of its type
const T_ADD: u8 = 3;
const T_SUB: u8 = 4;
const T_MUL: u8 = 5;
const T_NEG: u8 = 6;
// Atoms to the solver: their value is exact, the solver knows only their type's range (`bounds`).
const T_DIV: u8 = 7;
const T_REM: u8 = 8;
const T_BAND: u8 = 9;
const T_BOR: u8 = 10;
const T_BXOR: u8 = 11;
const T_SHL: u8 = 12;
const T_SHR: u8 = 13;
const T_BNOT: u8 = 14;
const T_CAST: u8 = 15; // a narrowing or sign-changing cast of `a`
const T_CALL: u8 = 16; // a `const fn` call: k = the callee's key, arguments [a, a + b) in `Terms.args`
const T_REF: u8 = 17; // a shared reference to the value `a`
// Formulas.
const T_LT: u8 = 18;
const T_LE: u8 = 19;
const T_EQ: u8 = 20;
const T_NE: u8 = 21;
const T_NOT: u8 = 22;
const T_AND: u8 = 23;
const T_OR: u8 = 24;
// Values of memory and aggregates.
const T_AGG: u8 = 25; // a struct, tuple or array: its members [a, a + b) in `Terms.args`
const T_UPD: u8 = 26; // `args[a]` with member `args[a + 1]` (a key) replaced by `args[a + 2]`
const T_SEL: u8 = 27; // member `b` (a key) of `a`
const T_LOAD: u8 = 28; // the value pointer `a` points to in memory epoch `b`
const T_MREF: u8 = 29; // a mutable reference to local `a` of the body (or the caller of a frame)
const T_VIEW: u8 = 30; // a view of array `a` of length k
const T_DOWN: u8 = 31; // `a` as its variant k

// Whether operation `op` keeps its operands in `Terms.args`.
const fn pooled(op: u8) bool {
    return op == T_CALL || op == T_AGG || op == T_UPD;
}

// `Term.w`: an integer's bit width; W_BOOL for a boolean; W_OTHER for any other value.
const W_OTHER: u8 = 0;
const W_BOOL: u8 = 1;

struct Term {
    k: i128,
    a: u32,
    b: u32,
    op: u8,
    w: u8,
    sg: bool,
}

// The hash-consed term table: a term built twice is one term, so equal values compare by index.
struct Terms {
    ts: Vector<Term>,
    ix: Map<u64, u32>,
    args: Vector<u32>,
    nvars: u32,
}

const fn hmix(h: u64, v: u64) u64 {
    return (h ^ v).wrapping_mul(0x100000001B3u64) ^ h >> 29;
}

// The value of an unsigned 64-bit pattern.
fn u64_val(v: u64) i128 {
    let mut x = i128::zero();
    x.set_limb(0, v);
    return x;
}

const fn wide(v: i64) i128 {
    return i128::from_i64(v);
}

extend Terms {
    fn new() Terms {
        return Terms { ts: Vector::<Term>::new(), ix: Map::<u64, u32>::new(), args: Vector::<u32>::new(), nvars: 0 };
    }

    fn clear(self: &mut Self) {
        self.ts.clear();
        self.ix.clear();
        self.args.clear();
        self.nvars = 0;
    }

    fn at(self: &Self, t: u32) Term {
        return self.ts[t as usize];
    }

    fn key(self: &Self, t: &Term) u64 {
        let mut h = hmix(0xCBF29CE484222325u64, t.op as u64 << 16 | t.w as u64 << 8 | t.sg as u64);
        // A call's argument list is hashed by content: `a` is only where it lies.
        let pos: u64 = if pooled(t.op) {
            0
        } else {
            t.a
        };
        h = hmix(h, pos << 32 | t.b as u64);
        h = hmix(h, t.k.limb(0));
        h = hmix(h, t.k.limb(1));
        if pooled(t.op) {
            for j in t.a..t.a + t.b {
                h = hmix(h, self.args[j as usize]);
            }
        }
        return h;
    }

    fn same(self: &Self, x: &Term, y: &Term) bool {
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
    fn make(self: &mut Self, t: Term) u32 {
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
        self.ts.push(t);
        if hit == NONE {
            self.ix.insert(h, n);
        }
        return n;
    }

    fn int(self: &mut Self, k: i128, w: u8, sg: bool) u32 {
        return self.make(Term { k: k, a: 0, b: 0, op: T_INT, w: w, sg: sg });
    }

    fn boolean(self: &mut Self, v: bool) u32 {
        return self.make(Term { k: wide(v as i64), a: 0, b: 0, op: T_BOOL, w: W_BOOL, sg: false });
    }

    fn var(self: &mut Self, w: u8, sg: bool) u32 {
        let n = self.nvars;
        self.nvars += 1;
        return self.make(Term { k: i128::zero(), a: n, b: 0, op: T_VAR, w: w, sg: sg });
    }

    fn is_true(self: &Self, t: u32) bool {
        let x = self.ts[t as usize];
        return x.op == T_BOOL && x.k == wide(1);
    }

    fn is_false(self: &Self, t: u32) bool {
        let x = self.ts[t as usize];
        return x.op == T_BOOL && x.k.is_zero();
    }

    fn is_int(self: &Self, t: u32) bool {
        return self.ts[t as usize].w > W_BOOL;
    }

    fn is_bool(self: &Self, t: u32) bool {
        return self.ts[t as usize].w == W_BOOL;
    }

    // An arithmetic or bit operation of type (`w`, `sg`); two constants fold when the exact result fits
    // 128 bits (an arithmetic one only: the atoms keep their node).
    fn arith(self: &mut Self, op: u8, a: u32, b: u32, w: u8, sg: bool) u32 {
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
                Option::<i128>::None
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
        return self.make(Term { k: i128::zero(), a: a, b: b, op: op, w: w, sg: sg });
    }

    fn neg(self: &mut Self, a: u32, w: u8, sg: bool) u32 {
        let x = self.ts[a as usize];
        if x.op == T_INT {
            if let Some(v) = i128::zero().checked_sub(&x.k) {
                return self.int(v, w, sg);
            }
        }
        return self.make(Term { k: i128::zero(), a: a, b: 0, op: T_NEG, w: w, sg: sg });
    }

    fn unary(self: &mut Self, op: u8, a: u32, w: u8, sg: bool) u32 {
        return self.make(Term { k: i128::zero(), a: a, b: 0, op: op, w: w, sg: sg });
    }

    // A comparison of two integers, or (`T_EQ`, `T_NE`) of two booleans or two other values.
    fn cmp(self: &mut Self, op: u8, a: u32, b: u32) u32 {
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
        return self.make(Term { k: i128::zero(), a: a, b: b, op: op, w: W_BOOL, sg: false });
    }

    fn not(self: &mut Self, a: u32) u32 {
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
        return self.make(Term { k: i128::zero(), a: a, b: 0, op: T_NOT, w: W_BOOL, sg: false });
    }

    fn and(self: &mut Self, a: u32, b: u32) u32 {
        if self.is_true(a) || a == b {
            return b;
        }
        if self.is_true(b) {
            return a;
        }
        if self.is_false(a) || self.is_false(b) {
            return self.boolean(false);
        }
        return self.make(Term { k: i128::zero(), a: a, b: b, op: T_AND, w: W_BOOL, sg: false });
    }

    fn or(self: &mut Self, a: u32, b: u32) u32 {
        if self.is_false(a) || a == b {
            return b;
        }
        if self.is_false(b) {
            return a;
        }
        if self.is_true(a) || self.is_true(b) {
            return self.boolean(true);
        }
        return self.make(Term { k: i128::zero(), a: a, b: b, op: T_OR, w: W_BOOL, sg: false });
    }

    // A `const fn` call of the callee keyed `key` over the arguments `xs`, of type (`w`, `sg`).
    fn call(self: &mut Self, key: u64, xs: &Vector<u32>, w: u8, sg: bool) u32 {
        let a = self.args.len() as u32;
        for j in 0..xs.len() {
            self.args.push(xs[j]);
        }
        return self.make(Term { k: u64_val(key), a: a, b: xs.len() as u32, op: T_CALL, w: w, sg: sg });
    }

    fn pool(self: &mut Self, op: u8, xs: &Vector<u32>, k: i128) u32 {
        let a = self.args.len() as u32;
        for j in 0..xs.len() {
            self.args.push(xs[j]);
        }
        return self.make(Term { k: k, a: a, b: xs.len() as u32, op: op, w: W_OTHER, sg: false });
    }

    // `v` with member `key` replaced by `x`.
    fn upd(self: &mut Self, v: u32, key: u32, x: u32) u32 {
        let a = self.args.len() as u32;
        self.args.push(v);
        self.args.push(key);
        self.args.push(x);
        return self.make(Term { k: i128::zero(), a: a, b: 3, op: T_UPD, w: W_OTHER, sg: false });
    }

    // Member `key` of `v`, of type (`w`, `sg`): an aggregate's member, through its updates where the
    // keys are the same term or two different constants.
    fn sel(self: &mut Self, v0: u32, key: u32, w: u8, sg: bool) u32 {
        let mut v = v0;
        let kx = self.ts[key as usize];
        for _s in 0..LIN_MAX {
            let x = self.ts[v as usize];
            if x.op == T_AGG && kx.op == T_INT && !kx.k.is_negative() && kx.k < wide(x.b) {
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
        return self.make(Term { k: i128::zero(), a: v, b: key, op: T_SEL, w: w, sg: sg });
    }

    // The range of type (`w`, `sg`) as (lo, hi).
    fn range(w: u8, sg: bool) (i128, i128) {
        if sg {
            let h = i128::one().shl((w - 1) as usize);
            return i128::zero() - h, h - i128::one();
        }
        return i128::zero(), i128::one().shl(w as usize) - i128::one();
    }

    // Whether integer `t` is in its type's range, as a formula.
    fn in_range(self: &mut Self, t: u32) u32 {
        let x = self.ts[t as usize];
        let (lo, hi) = Terms::range(x.w, x.sg);
        let l = self.int(lo, x.w, x.sg);
        let h = self.int(hi, x.w, x.sg);
        let c1 = self.cmp(T_LE, l, t);
        let c2 = self.cmp(T_LE, t, h);
        return self.and(c1, c2);
    }

    // The bounds the solver knows of atom `t`: its type's range, narrowed for a remainder by a positive
    // constant and a mask of an unsigned value. A product of two unknowns is an exact value, which may
    // lie outside its type (an overflow obligation asks whether it does): it has no bounds.
    fn bounds(self: &Self, t: u32) (i128, i128) {
        let x = self.ts[t as usize];
        if x.w <= W_BOOL || x.op == T_MUL {
            let h = i128::one().shl(100);
            return i128::zero() - h, h;
        }
        let (lo, hi) = Terms::range(x.w, x.sg);
        if !x.sg && (x.op == T_REM || x.op == T_BAND) {
            let y = self.ts[x.b as usize];
            if y.op == T_INT && !y.k.is_negative() && !y.k.is_zero() {
                return lo, if x.op == T_REM {
                    y.k - i128::one()
                } else {
                    y.k
                };
            }
        }
        return lo, hi;
    }
}

// ---- solver --------------------------------------------------------------------------------------

struct LinTerm {
    c: i128,
    atom: u32,
}

// `sum(c * atom) + k <= 0`, its terms [start, start + len) of a pool, sorted by atom.
struct Row {
    k: i128,
    start: u32,
    len: u32,
    id: u32, // its record in `Solver.cert`; NONE for a branch's row
}

// How one row of an elimination was derived: a branch's row, an atom's bound, or a combination
// `m1 * p1 + m2 * p2` (p2 NONE: `m1 * p1`) with nonnegative factors, each then divided by the gcd of
// its coefficients with its constant rounded up. `terms` and `k` are the result.
const C_INPUT: u8 = 0; // p1 = the branch's row
const C_LO: u8 = 1; // `lo - atom <= 0`
const C_HI: u8 = 2; // `atom - hi <= 0`
const C_COMB: u8 = 3;

struct Why {
    m1: i128,
    m2: i128,
    p1: u32,
    p2: u32,
    atom: u32,
    kind: u8,
}

struct Cert {
    why: Why,
    k: i128,
    start: u32, // terms in `Solver.cpool`
    len: u32,
}

// One branch of a refutation: the formulas still to split (`term << 1 | polarity`), the linear rows,
// and the boolean atoms with their polarity.
struct Branch {
    todo: Vector<u64>,
    rows: Vector<Row>,
    pool: Vector<LinTerm>,
    lits: Vector<u64>,
}

extend Branch {
    fn copy(self: &Self) Branch {
        return Branch {
            todo: self.todo.clone(),
            rows: copy_of(&self.rows),
            pool: copy_of(&self.pool),
            lits: self.lits.clone(),
        };
    }
}

struct Solver {
    rows: Vector<Row>,
    pool: Vector<LinTerm>,
    nrows: Vector<Row>,
    npool: Vector<LinTerm>,
    lin: Vector<LinTerm>,
    stack: Vector<LinTerm>,
    atoms: Vector<u32>,
    steps: u32, // the rounds spent, against `STEP_BUDGET` with the walk's
    cert: Vector<Cert>, // the current refutation's derivation, checked by `verify`
    cpool: Vector<LinTerm>,
    bad: u32, // the record of the row without an integer solution
}

fn copy_of<T: Copy>(v: &Vector<T>) Vector<T> {
    let mut out = Vector::<T>::with_capacity(v.len());
    out.extend_copy(v);
    return out;
}

// `v` as `n` entries of NONE.
fn fill(v: &mut Vector<u32>, n: usize) {
    v.clear();
    for _j in 0..n {
        v.push(NONE);
    }
}

fn why(kind: u8, p1: u32, p2: u32) Why {
    return Why { m1: i128::zero(), m2: i128::zero(), p1: p1, p2: p2, atom: NONE, kind: kind };
}

// The greatest common divisor of two non-negative values.
fn gcd(a0: i128, b0: i128) i128 {
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
    return i128::one();
}

// The certificate check's own arithmetic, apart from the solver's: `acc += m * row p` (`k` its
// constant); false when a value leaves 128 bits.
fn cert_scale(cert: &Vector<Cert>, pool: &Vector<LinTerm>, p: u32, m: i128, acc: &mut Vector<LinTerm>, k: &mut i128) bool {
    let c = *cert.at(p as usize);
    for j in c.start..c.start + c.len {
        let t = pool[j as usize];
        switch t.c.checked_mul(&m) {
            Some(v) => acc.push(LinTerm { c: v, atom: t.atom }),
            None => {
                return false;
            },
        }
    }
    switch c.k.checked_mul(&m) {
        Some(v) => {
            switch k.checked_add(&v) {
                Some(s) => *k = s,
                None => {
                    return false;
                },
            }
        },
        None => {
            return false;
        },
    }
    return true;
}

// Order `acc` by atom, add equal atoms, drop zeros, then divide by the gcd with the constant rounded
// up; false when a value leaves 128 bits.
fn cert_tighten(acc: &mut Vector<LinTerm>, k: &mut i128) bool {
    let n = acc.len();
    for j in 1..n {
        let x = acc[j];
        let mut q = j;
        while q > 0 && acc[q - 1].atom > x.atom {
            acc.set(q, acc[q - 1]);
            q -= 1;
        }
        acc.set(q, x);
    }
    let mut out = Vector::<LinTerm>::with_capacity(n);
    for j in 0..n {
        let x = acc[j];
        let last = out.len();
        if last != 0 && out[last - 1].atom == x.atom {
            switch out[last - 1].c.checked_add(&x.c) {
                Some(v) => out.set(last - 1, LinTerm { c: v, atom: x.atom }),
                None => {
                    return false;
                },
            }
        } else {
            out.push(x);
        }
    }
    acc.clear();
    let mut g = i128::zero();
    for j in 0..out.len() {
        if !out[j].c.is_zero() {
            acc.push(out[j]);
            let a = out[j].c.abs();
            g = if g.is_zero() {
                a
            } else {
                gcd(g, a)
            };
        }
    }
    if g.is_zero() {
        return true;
    }
    for j in 0..acc.len() {
        let x = acc[j];
        acc.set(j, LinTerm { c: x.c.div_euclid(&g), atom: x.atom });
    }
    *k = i128::zero() - (i128::zero() - *k).div_euclid(&g);
    return true;
}

// Sort the terms [s, e) of `v` by atom and merge equal atoms, dropping zero coefficients; the new end.
fn merge_terms(v: &mut Vector<LinTerm>, s: usize, e: usize) usize {
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

extend Solver {
    fn new() Solver {
        return Solver {
            rows: Vector::<Row>::new(),
            pool: Vector::<LinTerm>::new(),
            nrows: Vector::<Row>::new(),
            npool: Vector::<LinTerm>::new(),
            lin: Vector::<LinTerm>::new(),
            stack: Vector::<LinTerm>::new(),
            atoms: Vector::<u32>::new(),
            steps: 0,
            cert: Vector::<Cert>::new(),
            cpool: Vector::<LinTerm>::new(),
            bad: NONE,
        };
    }

    // Add `c * t` to the linear form in `lin` (its constant in `k`). False when a coefficient leaves
    // 128 bits or the walk is too long.
    fn linearize(self: &mut Self, tm: &Terms, t: u32, c: i128, k: &mut i128) bool {
        self.stack.clear();
        self.stack.push(LinTerm { c: c, atom: t });
        for _s in 0..LIN_MAX {
            if self.stack.len() == 0 {
                return true;
            }
            let e = self.stack.pop().unwrap();
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
                self.stack.push(LinTerm { c: e.c, atom: x.a });
                let cb = if x.op == T_ADD {
                    Some(e.c)
                } else {
                    i128::zero().checked_sub(&e.c)
                };
                switch cb {
                    Some(v) => self.stack.push(LinTerm { c: v, atom: x.b }),
                    None => {
                        return false;
                    },
                }
            } else if x.op == T_NEG {
                switch i128::zero().checked_sub(&e.c) {
                    Some(v) => self.stack.push(LinTerm { c: v, atom: x.a }),
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
                    Some(v) => self.stack.push(LinTerm { c: v, atom: other }),
                    None => {
                        return false;
                    },
                }
            } else {
                self.lin.push(e);
            }
        }
        return false;
    }

    // The row `a - b + off <= 0` into branch `br`. False when the form does not fit.
    fn add_le(self: &mut Self, tm: &Terms, br: &mut Branch, a: u32, b: u32, off: i64) bool {
        self.lin.clear();
        let mut k = wide(off);
        if !self.linearize(tm, a, i128::one(), &mut k) || !self.linearize(tm, b, wide(-1), &mut k) {
            return false;
        }
        let n = self.lin.len();
        let e = merge_terms(&mut self.lin, 0, n);
        let start = br.pool.len() as u32;
        for j in 0..e {
            br.pool.push(self.lin[j]);
        }
        br.rows.push(Row { k: k, start: start, len: e as u32, id: NONE });
        return true;
    }

    // Append the row `terms + k <= 0` (terms of `src` [s, s + n)) to the next round, divided by the
    // gcd of its coefficients with its constant rounded up: an integer row holds exactly when the
    // tightened one does. False when the row has no integer solution (a constant above 0).
    fn push_row(self: &mut Self, src: &Vector<LinTerm>, s: usize, n: usize, k: i128, why: Why) bool {
        if n == 0 {
            if k <= i128::zero() {
                return true;
            }
            self.bad = self.cert.len() as u32;
            self.cert.push(Cert { why: why, k: k, start: self.cpool.len() as u32, len: 0 });
            return false;
        }
        let mut g = src[s].c.abs();
        for j in s + 1..s + n {
            g = gcd(g, src[j].c.abs());
        }
        let start = self.npool.len() as u32;
        for j in s..s + n {
            let x = src[j];
            self.npool.push(LinTerm { c: x.c.div_euclid(&g), atom: x.atom });
        }
        // k' = ceil(k / g) = -floor(-k / g)
        let kk = i128::zero() - (i128::zero() - k).div_euclid(&g);
        let id = self.cert.len() as u32;
        let cs = self.cpool.len() as u32;
        for j in start as usize..self.npool.len() {
            self.cpool.push(self.npool[j]);
        }
        self.cert.push(Cert { why: why, k: kk, start: cs, len: n as u32 });
        self.nrows.push(Row { k: kk, start: start, len: n as u32, id: id });
        return true;
    }

    // Whether the rows of `br` have no integer solution, with each atom inside its bounds:
    // Fourier-Motzkin elimination over the tightened rows. False when a solution may exist or a
    // bound was hit.
    fn unsat(self: &mut Self, tm: &Terms, br: &Branch) bool {
        self.nrows.clear();
        self.npool.clear();
        self.cert.clear();
        self.cpool.clear();
        self.bad = NONE;
        for r in 0..br.rows.len() {
            let x = br.rows[r];
            if !self.push_row(&br.pool, x.start as usize, x.len as usize, x.k, why(C_INPUT, r as u32, NONE)) {
                return self.verify(tm, br);
            }
        }
        // Each atom's bounds: `lo - x <= 0` and `x - hi <= 0`.
        self.atoms.clear();
        for j in 0..self.npool.len() {
            self.atoms.push(self.npool[j].atom);
        }
        let na = self.atoms.len();
        for j in 1..na {
            let x = self.atoms[j];
            let mut q = j;
            while q > 0 && self.atoms[q - 1] > x {
                self.atoms.set(q, self.atoms[q - 1]);
                q -= 1;
            }
            self.atoms.set(q, x);
        }
        let mut prev = NONE;
        for j in 0..na {
            let x = self.atoms[j];
            if x == prev {
                continue;
            }
            prev = x;
            let (lo, hi) = tm.bounds(x);
            self.lin.clear();
            self.lin.push(LinTerm { c: wide(-1), atom: x });
            let src = replace(&mut self.lin, Vector::<LinTerm>::new());
            let mut wl = why(C_LO, NONE, NONE);
            wl.atom = x;
            let _ = self.push_row(&src, 0, 1, lo, wl);
            self.lin = src;
            self.lin.clear();
            self.lin.push(LinTerm { c: i128::one(), atom: x });
            let src2 = replace(&mut self.lin, Vector::<LinTerm>::new());
            let mut wh = why(C_HI, NONE, NONE);
            wh.atom = x;
            let _ = self.push_row(&src2, 0, 1, i128::zero() - hi, wh);
            self.lin = src2;
        }
        for _round in 0..na + 1 {
            self.steps += 1;
            if self.steps > STEP_BUDGET {
                return false;
            }
            self.rows = replace(&mut self.nrows, Vector::<Row>::new());
            self.pool = replace(&mut self.npool, Vector::<LinTerm>::new());
            // The atom whose elimination makes the fewest rows.
            let mut best = NONE;
            let mut cost: u64 = 0xFFFFFFFFFFFFFFFFu64;
            for r in 0..self.rows.len() {
                let x = self.rows[r];
                for j in x.start..x.start + x.len {
                    let at = self.pool[j as usize].atom;
                    let (np, nn) = self.signs(at);
                    let c = np * nn;
                    if c < cost || c == cost && at < best {
                        cost = c;
                        best = at;
                    }
                }
            }
            if best == NONE {
                return false; // every row is a constant at most 0: a solution exists
            }
            for r in 0..self.rows.len() {
                let x = self.rows[r];
                let c = self.coef(&x, best);
                if c.is_zero() && !self.push_row_own(x) {
                    return self.verify(tm, br);
                }
            }
            for r in 0..self.rows.len() {
                let p = self.rows[r];
                let cp = self.coef(&p, best);
                if !(i128::zero() < cp) {
                    continue;
                }
                for q in 0..self.rows.len() {
                    let n = self.rows[q];
                    let cn = self.coef(&n, best);
                    if !cn.is_negative() {
                        continue;
                    }
                    switch self.combine(&p, cp, &n, cn) {
                        Some(ok) => {
                            if !ok {
                                return self.verify(tm, br);
                            }
                        },
                        None => {
                            return false;
                        },
                    }
                    if self.nrows.len() > ROWS_MAX {
                        return false;
                    }
                }
            }
        }
        return false;
    }

    // The certificate check: replay the recorded derivation (`cert`) from the branch's rows and the
    // atoms' bounds with code of its own (a sum of rows by nonnegative factors, the gcd tightening),
    // compare each row with the record, and accept when the last one is a constant above 0. A solver
    // defect can make a refutation fail here, never make a false one pass.
    fn verify(self: &mut Self, tm: &Terms, br: &Branch) bool {
        if self.bad == NONE {
            return false;
        }
        let mut acc = Vector::<LinTerm>::new();
        for i in 0..self.bad as usize + 1 {
            let c = *self.cert.at(i);
            acc.clear();
            let mut k = i128::zero();
            let w = c.why;
            if w.kind == C_INPUT {
                if w.p1 as usize >= br.rows.len() {
                    return false;
                }
                let r = br.rows[w.p1 as usize];
                for j in r.start..r.start + r.len {
                    acc.push(br.pool[j as usize]);
                }
                k = r.k;
            } else if w.kind == C_LO || w.kind == C_HI {
                let (lo, hi) = tm.bounds(w.atom);
                acc.push(
                    LinTerm {
                        c: if w.kind == C_LO {
                            wide(-1)
                        } else {
                            i128::one()
                        },
                        atom: w.atom,
                    },
                );
                k = if w.kind == C_LO {
                    lo
                } else {
                    i128::zero() - hi
                };
            } else {
                // Both factors positive (the second absent): a sum of valid rows stays valid.
                if w.p1 as usize >= i || !(i128::zero() < w.m1) || w.p2 != NONE && (w.p2 as usize >= i || !(i128::zero() < w.m2)) {
                    return false;
                }
                if !cert_scale(&self.cert, &self.cpool, w.p1, w.m1, &mut acc, &mut k) {
                    return false;
                }
                if w.p2 != NONE && !cert_scale(&self.cert, &self.cpool, w.p2, w.m2, &mut acc, &mut k) {
                    return false;
                }
            }
            if !cert_tighten(&mut acc, &mut k) {
                return false;
            }
            if acc.len() != c.len as usize || k != c.k {
                return false;
            }
            for j in 0..acc.len() {
                let x = self.cpool[c.start as usize + j];
                if x.atom != acc[j].atom || x.c != acc[j].c {
                    return false;
                }
            }
        }
        let last = *self.cert.at(self.bad as usize);
        return last.len == 0 && i128::zero() < last.k;
    }

    // The rows with a positive and with a negative coefficient on `at`.
    fn signs(self: &Self, at: u32) (u64, u64) {
        let mut np: u64 = 0;
        let mut nn: u64 = 0;
        for r in 0..self.rows.len() {
            let c = self.coef(&self.rows[r], at);
            if c.is_negative() {
                nn += 1;
            } else if !c.is_zero() {
                np += 1;
            }
        }
        return np, nn;
    }

    fn coef(self: &Self, x: &Row, at: u32) i128 {
        for j in x.start..x.start + x.len {
            let t = self.pool[j as usize];
            if t.atom == at {
                return t.c;
            }
        }
        return i128::zero();
    }

    // Row `x` of this round into the next one.
    fn push_row_own(self: &mut Self, x: Row) bool {
        let src = replace(&mut self.pool, Vector::<LinTerm>::new());
        let mut wy = why(C_COMB, x.id, NONE);
        wy.m1 = i128::one();
        let ok = self.push_row(&src, x.start as usize, x.len as usize, x.k, wy);
        self.pool = src;
        return ok;
    }

    // `-cn * p + cp * n`, which eliminates the atom, into the next round: whether it has a solution
    // (`Some(false)`: none), None when a coefficient leaves 128 bits.
    fn combine(self: &mut Self, p: &Row, cp: i128, n: &Row, cn: i128) Option<bool> {
        let mp = i128::zero() - cn;
        self.lin.clear();
        for j in p.start..p.start + p.len {
            let t = self.pool[j as usize];
            switch t.c.checked_mul(&mp) {
                Some(v) => self.lin.push(LinTerm { c: v, atom: t.atom }),
                None => {
                    return None;
                },
            }
        }
        for j in n.start..n.start + n.len {
            let t = self.pool[j as usize];
            switch t.c.checked_mul(&cp) {
                Some(v) => self.lin.push(LinTerm { c: v, atom: t.atom }),
                None => {
                    return None;
                },
            }
        }
        let mut k = Option::<i128>::None;
        if let Some(a) = p.k.checked_mul(&mp) {
            if let Some(b) = n.k.checked_mul(&cp) {
                k = a.checked_add(&b);
            }
        }
        let kk = switch k {
            Some(v) => v,
            None => {
                return None;
            },
        };
        let total = self.lin.len();
        let e = merge_terms(&mut self.lin, 0, total);
        let src = replace(&mut self.lin, Vector::<LinTerm>::new());
        let mut wy = why(C_COMB, p.id, n.id);
        wy.m1 = mp;
        wy.m2 = cp;
        let ok = self.push_row(&src, 0, e, kk, wy);
        self.lin = src;
        return Some(ok);
    }

    // Whether the hypotheses `hyps` imply `goal`: the hypotheses and the negated goal have no integer
    // model. Each formula splits into branches; each branch closes on a contradiction of its boolean
    // atoms or of its rows (`unsat`).
    fn implies(self: &mut Self, tm: &Terms, hyps: &Vector<u32>, goal: u32) bool {
        if tm.is_true(goal) {
            return true;
        }
        for j in 0..hyps.len() {
            if hyps[j] == goal || tm.is_false(hyps[j]) {
                return true;
            }
        }
        let mut b0 = Branch {
            todo: Vector::<u64>::new(),
            rows: Vector::<Row>::new(),
            pool: Vector::<LinTerm>::new(),
            lits: Vector::<u64>::new(),
        };
        for j in 0..hyps.len() {
            b0.todo.push(hyps[j] as u64 << 1 | 1);
        }
        b0.todo.push(goal as u64 << 1);
        let mut open = Vector::<Branch>::new();
        open.push(b0);
        let mut splits: u32 = 0;
        for _b in 0..SPLITS_MAX + 1 {
            if open.len() == 0 {
                return true;
            }
            let mut br = open.pop().unwrap();
            switch self.close(tm, &mut br, &mut open, &mut splits) {
                Some(closed) => {
                    if !closed && !self.unsat(tm, &br) {
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

    // Split the formulas of `br` until none is left: Some(true) when a contradiction closed it,
    // Some(false) when only its rows remain to refute, None past the split bound.
    fn close(self: &mut Self, tm: &Terms, br: &mut Branch, open: &mut Vector<Branch>, splits: &mut u32) Option<bool> {
        for _s in 0..LIN_MAX {
            if br.todo.len() == 0 {
                return Some(false);
            }
            let e = br.todo.pop().unwrap();
            let t = (e >> 1) as u32;
            let pos = (e & 1) != 0;
            let x = tm.at(t);
            if x.op == T_BOOL {
                if x.k == wide(1) != pos {
                    return Some(true);
                }
            } else if x.op == T_NOT {
                br.todo.push(x.a as u64 << 1 | (!pos) as u64);
            } else if x.op == T_AND && pos || x.op == T_OR && !pos {
                br.todo.push(x.a as u64 << 1 | pos as u64);
                br.todo.push(x.b as u64 << 1 | pos as u64);
            } else if x.op == T_AND || x.op == T_OR {
                *splits += 1;
                if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                    return None;
                }
                let mut other = br.copy();
                other.todo.push(x.b as u64 << 1 | pos as u64);
                open.push(other);
                br.todo.push(x.a as u64 << 1 | pos as u64);
            } else if (x.op == T_LT || x.op == T_LE) && tm.is_int(x.a) && tm.is_int(x.b) {
                // pos: a - b + (1 or 0) <= 0; else b - a + (0 or 1) <= 0
                let ok = if pos {
                    self.add_le(tm, br, x.a, x.b, pick(x.op == T_LT, 1i64, 0))
                } else {
                    self.add_le(tm, br, x.b, x.a, pick(x.op == T_LT, 0i64, 1))
                };
                if !ok {
                    return None;
                }
            } else if (x.op == T_EQ || x.op == T_NE) && tm.is_int(x.a) && tm.is_int(x.b) {
                if x.op == T_EQ == pos {
                    if !self.add_le(tm, br, x.a, x.b, 0) || !self.add_le(tm, br, x.b, x.a, 0) {
                        return None;
                    }
                } else {
                    *splits += 1;
                    if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                        return None;
                    }
                    let mut other = br.copy();
                    if !self.add_le(tm, &mut other, x.b, x.a, 1) || !self.add_le(tm, br, x.a, x.b, 1) {
                        return None;
                    }
                    open.push(other);
                }
            } else if (x.op == T_EQ || x.op == T_NE) && tm.is_bool(x.a) && tm.is_bool(x.b) {
                // Equal booleans: both hold or neither does.
                *splits += 1;
                if *splits > SPLITS_MAX || open.len() >= SPLITS_MAX as usize {
                    return None;
                }
                let same = x.op == T_EQ == pos;
                let mut other = br.copy();
                other.todo.push(x.a as u64 << 1);
                other.todo.push(x.b as u64 << 1 | (!same) as u64);
                open.push(other);
                br.todo.push(x.a as u64 << 1 | 1);
                br.todo.push(x.b as u64 << 1 | same as u64);
            } else {
                // A boolean atom: closes against its own negation.
                let want = t as u64 << 1 | (!pos) as u64;
                for j in 0..br.lits.len() {
                    if br.lits[j] == want {
                        return Some(true);
                    }
                }
                br.lits.push(t as u64 << 1 | pos as u64);
            }
        }
        return None;
    }
}

// ---- exact evaluation --------------------------------------------------------------------------

// The assignments one enumeration may evaluate (a proof over every value of small domains), and the
// candidate assignments a counterexample search may try.
const ENUM_MAX: u64 = 65536;
const SEARCH_MAX: u64 = 4096;
// The candidate values of one unknown in a counterexample search.
const CANDIDATES_MAX: usize = 8;

// `x`'s low `w` bits as an unsigned pattern.
const fn bits_of(x: i128, w: u8) u64 {
    let b = x.limb(0);
    return if w >= 64 {
        b
    } else {
        b & (1u64 << w as u64) - 1
    };
}

// The value of the `w`-bit pattern `b` in a type of signedness `sg`.
fn val_of(b: u64, w: u8, sg: bool) i128 {
    let v = u64_val(b);
    if sg && w > 0 && (b >> (w - 1) as u64 & 1) != 0 {
        return v - i128::one().shl(w as usize);
    }
    return v;
}

// The values of terms under one assignment of the unknowns (the leaves): `val` for each term whose
// `stamp` is the current one, `ok` false where the value is not defined (an operation that traps).
struct Eval {
    val: Vector<i128>,
    stamp: Vector<u32>,
    ok: Vector<bool>,
    now: u32,
    stack: Vector<u32>,
    leaves: Vector<u32>,
    lo: Vector<i128>,
    hi: Vector<i128>,
    seen: Vector<u32>,
}

extend Eval {
    fn new() Eval {
        return Eval {
            val: Vector::<i128>::new(),
            stamp: Vector::<u32>::new(),
            ok: Vector::<bool>::new(),
            now: 0,
            stack: Vector::<u32>::new(),
            leaves: Vector::<u32>::new(),
            lo: Vector::<i128>::new(),
            hi: Vector::<i128>::new(),
            seen: Vector::<u32>::new(),
        };
    }

    // Size the tables for `n` terms and start a new assignment.
    fn begin(self: &mut Self, n: usize) {
        while self.val.len() < n {
            self.val.push(i128::zero());
            self.stamp.push(0);
            self.ok.push(false);
            self.seen.push(0);
        }
        self.now += 1;
    }

    fn set(self: &mut Self, t: u32, v: i128) {
        self.val.set(t as usize, v);
        self.ok.set(t as usize, true);
        self.stamp.set(t as usize, self.now);
    }

    // Whether term `t` is a leaf of evaluation: an unknown, or a value the walk does not take apart.
    fn leaf(tm: &Terms, t: u32) bool {
        let x = tm.at(t);
        if x.op == T_INT || x.op == T_BOOL {
            return false;
        }
        if x.op >= T_LT && x.op <= T_NE {
            return !(tm.is_int(x.a) && tm.is_int(x.b) || tm.is_bool(x.a) && tm.is_bool(x.b));
        }
        return x.op == T_VAR || x.op == T_CALL || x.op >= T_AGG || x.op == T_REF;
    }

    // The leaves under `roots`, in first-seen order, with their domains.
    fn collect(self: &mut Self, tm: &Terms, roots: &Vector<u32>) bool {
        self.leaves.clear();
        self.lo.clear();
        self.hi.clear();
        self.begin(tm.ts.len());
        self.stack.clear();
        for j in 0..roots.len() {
            self.stack.push(roots[j]);
        }
        for _s in 0..LIN_MAX * 16 {
            if self.stack.len() == 0 {
                return true;
            }
            let t = self.stack.pop().unwrap();
            if self.seen[t as usize] == self.now {
                continue;
            }
            self.seen.set(t as usize, self.now);
            let x = tm.at(t);
            if Eval::leaf(tm, t) {
                if x.w == W_OTHER {
                    return false;
                }
                self.leaves.push(t);
                if x.w == W_BOOL {
                    self.lo.push(i128::zero());
                    self.hi.push(i128::one());
                } else {
                    let (l, h) = tm.bounds(t);
                    self.lo.push(l);
                    self.hi.push(h);
                }
                continue;
            }
            if x.op == T_INT || x.op == T_BOOL {
                continue;
            }
            self.stack.push(x.a);
            if x.op != T_NEG && x.op != T_NOT && x.op != T_BNOT && x.op != T_CAST {
                self.stack.push(x.b);
            }
        }
        return false;
    }

    // The value of `t` under the current assignment of the leaves; None where an operation is not
    // defined (it traps) or leaves 128 bits.
    fn value(self: &mut Self, tm: &Terms, t: u32) Option<i128> {
        self.stack.clear();
        self.stack.push(t);
        for _s in 0..LIN_MAX * 16 {
            if self.stack.len() == 0 {
                break;
            }
            let u = self.stack[self.stack.len() - 1];
            if self.stamp[u as usize] == self.now {
                let _ = self.stack.pop();
                continue;
            }
            let x = tm.at(u);
            if x.op == T_INT || x.op == T_BOOL {
                self.set(u, x.k);
                let _ = self.stack.pop();
                continue;
            }
            let unary = x.op == T_NEG || x.op == T_NOT || x.op == T_BNOT || x.op == T_CAST;
            let need_a = self.stamp[x.a as usize] != self.now;
            let need_b = !unary && self.stamp[x.b as usize] != self.now;
            if need_a || need_b {
                if need_a {
                    self.stack.push(x.a);
                }
                if need_b {
                    self.stack.push(x.b);
                }
                continue;
            }
            let _ = self.stack.pop();
            let okv = self.ok[x.a as usize] && (unary || self.ok[x.b as usize]);
            let r = if okv {
                self.apply(&x)
            } else {
                Option::<i128>::None
            };
            switch r {
                Some(v) => self.set(u, v),
                None => {
                    self.stamp.set(u as usize, self.now);
                    self.ok.set(u as usize, false);
                },
            }
        }
        if self.stamp[t as usize] != self.now || !self.ok[t as usize] {
            return None;
        }
        return Some(self.val[t as usize]);
    }

    fn apply(self: &Self, x: &Term) Option<i128> {
        let a = self.val[x.a as usize];
        let b = self.val[x.b as usize];
        let one = i128::one();
        let z = i128::zero();
        if x.op == T_ADD {
            return a.checked_add(&b);
        }
        if x.op == T_SUB {
            return a.checked_sub(&b);
        }
        if x.op == T_MUL {
            return a.checked_mul(&b);
        }
        if x.op == T_NEG {
            return z.checked_sub(&a);
        }
        if x.op == T_DIV || x.op == T_REM {
            if b.is_zero() {
                return None;
            }
            // Truncated toward zero; the remainder has the dividend's sign.
            let ab = b.abs();
            let q0 = a.abs().div_euclid(&ab);
            let q = if a.is_negative() != b.is_negative() {
                z - q0
            } else {
                q0
            };
            let (lo, hi) = Terms::range(x.w, x.sg);
            if q < lo || hi < q {
                return None;
            }
            return if x.op == T_DIV {
                Some(q)
            } else {
                switch b.checked_mul(&q) {
                    Some(bq) => a.checked_sub(&bq),
                    None => Option::<i128>::None,
                }
            };
        }
        if x.op == T_BAND || x.op == T_BOR || x.op == T_BXOR {
            let p = bits_of(a, x.w);
            let q = bits_of(b, x.w);
            let r = if x.op == T_BAND {
                p & q
            } else if x.op == T_BOR {
                p | q
            } else {
                p ^ q
            };
            return Some(val_of(r, x.w, x.sg));
        }
        if x.op == T_BNOT {
            return Some(val_of(bits_of(a, x.w) ^ bits_of(i128::zero() - one, x.w), x.w, x.sg));
        }
        if x.op == T_SHL || x.op == T_SHR {
            if b.is_negative() || wide(x.w) <= b {
                return None;
            }
            let c = b.to_i64() as u64;
            let p = bits_of(a, x.w);
            if x.op == T_SHL {
                return Some(val_of(bits_of(u64_val(p << c), x.w), x.w, x.sg));
            }
            if x.sg && a.is_negative() {
                // An arithmetic shift: floor division by 2^c.
                let d = one.shl(c as usize);
                return Some(a.div_euclid(&d));
            }
            return Some(val_of(p >> c, x.w, x.sg));
        }
        if x.op == T_CAST {
            return Some(val_of(bits_of(a, x.w), x.w, x.sg));
        }
        if x.op == T_LT {
            return Some(wide((a < b) as i64));
        }
        if x.op == T_LE {
            return Some(wide((a <= b) as i64));
        }
        if x.op == T_EQ {
            return Some(wide((a == b) as i64));
        }
        if x.op == T_NE {
            return Some(wide((a != b) as i64));
        }
        if x.op == T_NOT {
            return Some(wide(a.is_zero() as i64));
        }
        if x.op == T_AND {
            return Some(wide((!a.is_zero() && !b.is_zero()) as i64));
        }
        if x.op == T_OR {
            return Some(wide((!a.is_zero() || !b.is_zero()) as i64));
        }
        return None;
    }

    // Under the current assignment: 1 when every hypothesis holds and the goal does not (a
    // counterexample), 0 when the assignment satisfies the implication, 2 when a value is undefined.
    fn check(self: &mut Self, tm: &Terms, hyps: &Vector<u32>, goal: u32) u8 {
        for j in 0..hyps.len() {
            switch self.value(tm, hyps[j]) {
                Some(v) => {
                    if v.is_zero() {
                        return 0;
                    }
                },
                None => {
                    return 2;
                },
            }
        }
        return switch self.value(tm, goal) {
            Some(v) => {
                if v.is_zero() {
                    1
                } else {
                    0
                }
            },
            None => 2,
        };
    }

    // Assign the leaves the `k`-th combination of their candidate values (`cands`, `cstart` per
    // leaf; or with `cands` empty every value of their domains). False when `k` is past the end.
    fn assign(self: &mut Self, k0: u64, cands: &Vector<i128>, cstart: &Vector<u32>) bool {
        self.now += 1;
        let mut k = k0;
        for j in 0..self.leaves.len() {
            if cands.len() == 0 {
                let span = (self.hi[j] - self.lo[j]).to_i64() as u64 + 1;
                let v = self.lo[j] + u64_val(k % span);
                k = k / span;
                self.set(self.leaves[j], v);
            } else {
                let c0 = cstart[j] as u64;
                let span = cstart[j + 1] as u64 - c0;
                self.set(self.leaves[j], cands[(c0 + k % span) as usize]);
                k = k / span;
            }
        }
        return k == 0;
    }
}

// ---- the walk ------------------------------------------------------------------------------------

// One path of the walk: the block it enters next (from block `from`), the value of each local it
// models (NONE: a fresh unknown at its first read), its conditions, and the body's `decreases` measure.
struct Path {
    state: Vector<u32>,
    pc: Vector<u32>,
    esc: Vector<u32>, // the locals a reference or pointer made on the path may reach
    lm: Vector<u64>, // per loop the path is in: header << 32 | its measure at the iteration's start
    blk: u32,
    from: u32,
    m0: u32,
}

extend Path {
    fn copy(self: &Self) Path {
        return Path {
            state: self.state.clone(),
            pc: self.pc.clone(),
            esc: self.esc.clone(),
            lm: self.lm.clone(),
            blk: self.blk,
            from: self.from,
            m0: self.m0,
        };
    }
}

// One path through a contract chain.
struct Sub {
    state: Vector<u32>,
    conds: Vector<u32>,
    blk: u32,
}

// How a checked operation's result is modeled: OVF_PROVE proves the operation does not overflow and
// takes the exact value (a body with contracts, a contract expression); OVF_KEEP takes the exact
// value only where it fits and a fresh one otherwise.
const OVF_PROVE: u8 = 0;
const OVF_KEEP: u8 = 1;

// `@prove_exhaustive`: the inputs of one function, and the evaluator steps of all its runs: each run
// may take an equal share (`share`), so no split of the inputs changes a report, and the runs of every
// split together take at most PE_STEPS.
const PE_INPUTS_MAX: u64 = 65536;
const PE_STEPS: u64 = 67108864; // 1 << 26
const NO_INPUT: u64 = 0xFFFFFFFFFFFFFFFFu64;
// The workers' share of one function's inputs: at most this many parts per worker.
const PE_PARTS: u64 = 4;

// The kinds of a parameter's values (`PDim.kind`).
const PD_INT: u8 = 0;
const PD_BOOL: u8 = 1;
const PD_ENUM: u8 = 2;

// A parameter of a `@prove_exhaustive` function (local `l`) and its values in order: the `n` integers
// from `lo`, `false` then `true`, or the variants `vars` of enum `decl` of module `em` (discriminants
// `tags`). Its value has type `ty` of module `tm`; `by_ref`: the function takes it by a shared
// reference.
struct PDim {
    l: u32,
    kind: u8,
    by_ref: bool,
    lo: i128,
    n: u64,
    count: i128, // `n`, exact: `n` stops at NO_INPUT
    w: u8,
    sg: bool,
    tm: ModuleId,
    ty: TypeId,
    em: ModuleId,
    decl: NodeId,
    tags: Vector<i64>,
    vars: Vector<NodeId>,
}

// The inputs of kept body `k`, a `@prove_exhaustive` function's: one value of each parameter, `inputs`
// in all. Input `x` takes value `x / (n of the later parameters) % n` of each. `first`: the least
// input whose run failed so far, which the parts of the inputs after it read to stop.
struct PJob {
    k: usize,
    dims: Vector<PDim>,
    inputs: u64,
    first: u64,
}

// What the runs of inputs [`from`, `to`) of job `job` found: the first input whose run failed (`at`,
// NO_INPUT: none) and its report; `cut`: the run took more than its share of the steps.
struct PRes {
    job: u32,
    from: u64,
    to: u64,
    at: u64,
    cut: bool,
    sp: tok::Span,
    msg: String,
    note: String,
    note2: String,
}

// The steps each run of `job` may take.
const fn share(job: &PJob) u64 {
    return PE_STEPS / job.inputs;
}

// The body under proof (`b`, its module `m`) and what its walk reads.
struct Prover {
    p: *const loader::Package,
    keep: *const irl::Keep,
    slice: loader::LookupHit, // the prelude's `Slice`
    tm: Terms,
    sv: Solver,
    fx: fx::Facts,
    pw: u32,
    errs: Vector<diag::Errors>, // per module
    failed: Map<u64, bool>, // the obligations already reported, per body
    pwrites: Map<u64, u64>, // callee -> `param_writes`
    b: *const ir::CoreBody,
    m: ModuleId,
    tracked: Vector<bool>, // the locals the walk models by value
    is_mem: Vector<bool>, // the modeled locals a reference or pointer may change (`scan_tracked`)
    mem_list: Vector<u32>,
    esc: Vector<u32>, // the walked path's `Path.esc`, while `run_block` walks it
    scc: Vector<u32>, // per kept body: its component of the direct-call graph (`ir::recursion`), NONE: none
    me: u32, // the kept index of the body under proof
    fn_dec: bool, // the body's function has a `decreases` measure
    ptr_cast: bool, // the body casts a value to a pointer
    // The state a callee frame's references to the caller's locals read, null outside a frame.
    mem: *const Vector<u32>,
    site_of_chain: Vector<u32>, // block -> the contract site whose chain starts there
    site_of_pred: Vector<u32>, // block -> the contract site it enters
    ovf: u8,
    steps: u32,
    over: bool, // the body spent its budget
    work: Vector<Path>,
    ev: Eval,
    vname: Map<u32, u32>, // a parameter's unknown -> the parameter's local, for counterexamples
    // The contracts of the interfaces' methods without a body (`ir::Lowerer::lower_fn` lowers their
    // clauses only), keyed like `irl::Keep`.
    shells: Vector<ir::CoreBody>,
    shell_ix: Map<u64, u32>,
    // The refinement walk of a conformance's method: only its `OB_REFINE` obligations count, and
    // `refine` holds the interface's contracts (null: the interface's method has none).
    refining: bool,
    refine: *const ir::CoreBody,
    // A worker of the parallel walk reads the main prover's `shells`, `shell_ix` and `scc`; null for
    // the main prover.
    main: *const Prover,
}

// The obligation kinds of `Prover::oblige`, in the report key.
const OB_ENSURES: u64 = 1;
const OB_INV_START: u64 = 2;
const OB_INV_STEP: u64 = 3;
const OB_REQUIRES: u64 = 4;
const OB_DECREASES: u64 = 5;
const OB_OVERFLOW: u64 = 6;
const OB_BUDGET: u64 = 7;
const OB_REFINE: u64 = 8; // a conformance's method against its interface's contracts
const OB_EVAL: u64 = 9; // a `@prove_exhaustive` function: its setup and its runs

extend Prover {
    fn new(p: &loader::Package, keep: &irl::Keep, slice: loader::LookupHit) Prover {
        let mut errs = Vector::<diag::Errors>::with_capacity(p.modules.len());
        for _m in 0..p.modules.len() {
            errs.push(diag::Errors::new());
        }
        return Prover {
            p: p,
            keep: keep,
            slice: slice,
            tm: Terms::new(),
            sv: Solver::new(),
            fx: fx::Facts::new(false),
            pw: lay::target_for(p.arch).ptr as u32 * 8,
            errs: errs,
            failed: Map::<u64, bool>::new(),
            pwrites: Map::<u64, u64>::new(),
            b: null,
            m: 0,
            tracked: Vector::<bool>::new(),
            is_mem: Vector::<bool>::new(),
            mem_list: Vector::<u32>::new(),
            esc: Vector::<u32>::new(),
            scc: Vector::<u32>::new(),
            me: NONE,
            fn_dec: false,
            ptr_cast: false,
            mem: null,
            site_of_chain: Vector::<u32>::new(),
            site_of_pred: Vector::<u32>::new(),
            ovf: OVF_KEEP,
            steps: 0,
            over: false,
            work: Vector::<Path>::new(),
            ev: Eval::new(),
            vname: Map::<u32, u32>::new(),
            shells: Vector::<ir::CoreBody>::new(),
            shell_ix: Map::<u64, u32>::new(),
            refining: false,
            refine: null,
            main: null,
        };
    }

    fn pkg(self: &Self) &loader::Package {
        return unsafe &*self.p;
    }

    fn ast_of(self: &Self, m: ModuleId) &Ast {
        return unsafe &*(&*self.p).module_ast_const(m);
    }

    // The kept body of function `d`, null when none is kept.
    fn kept(self: &Self, d: DefId) *const ir::CoreBody {
        let k = unsafe &*self.keep;
        return switch k.ix.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => &k.kept.at((*v) as usize).body,
            None => null,
        };
    }

    // Whether function `d` has a clause of kind `kind`.
    fn has_clause(self: &Self, d: DefId, kind: u32) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module as usize >= self.pkg().modules.len() || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        let (cs, ce) = a.contracts_of(d.node);
        for j in cs..ce {
            if a.contracts.at(j as usize).kind == kind {
                return true;
            }
        }
        return false;
    }

    // Whether `d` is a `const fn`: its result depends on its arguments alone.
    fn is_const_fn(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && a.ext(d.node).function.is_const();
    }

    // The (width, signed) of type `ty` in module `m`: W_BOOL, an integer's width, or W_OTHER.
    fn ty_of(self: &Self, m: ModuleId, ty: TypeId) (u8, bool) {
        if ty == TYPE_NONE {
            return W_OTHER, false;
        }
        let y = self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return W_OTHER, false;
        }
        let bt = unsafe y.as_data.builtin;
        if bt == BuiltinType::BT_BOOL {
            return W_BOOL, false;
        }
        let sg = bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE;
        let w: u32 = switch bt {
            BT_I8 | BT_U8 => 8,
            BT_I16 | BT_U16 => 16,
            BT_I32 | BT_U32 => 32,
            BT_I64 | BT_U64 => 64,
            BT_ISIZE | BT_USIZE => self.pw,
            _ => 0,
        };
        return w as u8, sg;
    }

    // Whether a value of type `ty` is frozen: a scalar or a shared view (`[]T`), which no shared
    // reference can change and whose elements no write can reach while it lives.
    fn frozen(self: &Self, m: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return true;
        }
        if y.kind != TypeKind::TYPE_INSTANCE || self.slice.node == NODE_NONE {
            return false;
        }
        let inst = a.instance(y.as_data.inst);
        return inst.module == self.slice.mid && inst.decl == self.slice.node;
    }

    // The length of array type `ty`, -1 for another type or a symbolic length.
    fn array_len(self: &Self, m: ModuleId, ty: TypeId) i64 {
        if ty == TYPE_NONE {
            return -1;
        }
        let y = self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_ARRAY || y.qualifier == ARR_SYM {
            return -1;
        }
        return y.as_data.arr.len;
    }

    fn fresh(self: &mut Self, m: ModuleId, ty: TypeId) u32 {
        let (w, sg) = self.ty_of(m, ty);
        return self.tm.var(w, sg);
    }

    fn spend(self: &mut Self) bool {
        self.steps += 1;
        return self.steps + self.sv.steps <= STEP_BUDGET;
    }

    // ---- reports ----------------------------------------------------------------------------------

    fn source_line(self: &Self, m: ModuleId, at: u32) u32 {
        let src = self.pkg().modules.at(m as usize).source.as_str();
        let mut line: u32 = 1;
        let end = pick(at as usize < src.len(), at as usize, src.len());
        for j in 0..end {
            if src.byte_at(j) == b'\n' {
                line += 1;
            }
        }
        return line;
    }

    fn text(self: &Self, m: ModuleId, sp: tok::Span) str {
        return self.pkg().modules.at(m as usize).source.as_str().slice(sp.start as usize, sp.end as usize);
    }

    // Report the failed obligation `key` once per body, with up to two notes.
    fn report(self: &mut Self, key: u64, code: u16, sp: tok::Span, msg: String, note: String) {
        self.report2(key, code, sp, msg, note, String::new());
    }

    fn report2(self: &mut Self, key: u64, code: u16, sp: tok::Span, msg: String, note: String, note2: String) {
        if self.failed.contains_key(&key) {
            return;
        }
        self.failed.insert(key, true);
        let ix = self.errs.index_mut(self.m as usize).emit_ordered(code, 0, sp.start, sp.end - sp.start, msg);
        if ix < diag::ERRORS_MAX {
            if note.len() != 0 {
                self.errs.index_mut(self.m as usize).note_at(ix, note);
            }
            if note2.len() != 0 {
                self.errs.index_mut(self.m as usize).note_at(ix, note2);
            }
        }
    }

    // Every value of the unknowns of `pc` and `goal`, when their domains are small: whether the
    // implication holds for each (a proof); else a search over a few values of each. A counterexample
    // the evaluator confirms goes to `example`.
    fn enumerate(self: &mut Self, pc: &Vector<u32>, goal: u32, example: &mut String) bool {
        let mut roots = pc.clone();
        roots.push(goal);
        if !self.ev.collect(&self.tm, &roots) {
            return false;
        }
        let n = self.ev.leaves.len();
        let mut domain: u64 = 1;
        for j in 0..n {
            let span = self.ev.hi[j] - self.ev.lo[j];
            if span.is_negative() || wide(ENUM_MAX as i64) <= span {
                domain = ENUM_MAX + 1;
                break;
            }
            domain *= span.to_i64() as u64 + 1;
            if domain > ENUM_MAX {
                break;
            }
        }
        let no_cands = Vector::<i128>::new();
        let no_starts = Vector::<u32>::new();
        if domain <= ENUM_MAX {
            let mut complete = true;
            for k in 0..domain {
                self.sv.steps += 1;
                if self.sv.steps > STEP_BUDGET {
                    return false;
                }
                let _ = self.ev.assign(k, &no_cands, &no_starts);
                let r = self.ev.check(&self.tm, pc, goal);
                if r == 1 {
                    self.describe(example);
                    return false;
                }
                complete = complete && r == 0;
            }
            return complete;
        }
        // A few values of each unknown: its ends, zero and its neighbors.
        let mut cands = Vector::<i128>::new();
        let mut starts = Vector::<u32>::new();
        let mut combos: u64 = 1;
        for j in 0..n {
            starts.push(cands.len() as u32);
            let lo = self.ev.lo[j];
            let hi = self.ev.hi[j];
            let picks: [i128; 7] = [
                lo,
                hi,
                i128::zero(),
                i128::one(),
                i128::zero() - i128::one(),
                lo + i128::one(),
                hi - i128::one(),
            ];
            let c0 = cands.len();
            for q in 0..7 {
                let v = picks[q];
                if v < lo || hi < v || cands.len() - c0 >= CANDIDATES_MAX {
                    continue;
                }
                let mut dup = false;
                for r in c0..cands.len() {
                    dup = dup || cands[r] == v;
                }
                if !dup {
                    cands.push(v);
                }
            }
            combos = combos.saturating_mul((cands.len() - c0) as u64);
        }
        starts.push(cands.len() as u32);
        let tries = if combos < SEARCH_MAX {
            combos
        } else {
            SEARCH_MAX
        };
        for k in 0..tries {
            self.sv.steps += 1;
            if self.sv.steps > STEP_BUDGET {
                return false;
            }
            let _ = self.ev.assign(k, &cands, &starts);
            if self.ev.check(&self.tm, pc, goal) == 1 {
                self.describe(example);
                return false;
            }
        }
        return false;
    }

    // The current assignment of the unknowns, by the parameters they stand for, in parameter order.
    fn describe(self: &Self, out: &mut String) {
        let b = unsafe &*self.b;
        let mut named = Vector::<u64>::new(); // local << 32 | leaf
        let mut other: u32 = 0;
        for j in 0..self.ev.leaves.len() {
            let t = self.ev.leaves[j];
            switch self.vname.get(&t) {
                Some(l) => named.push((*l) as u64 << 32 | t as u64),
                None => {
                    other += 1;
                },
            }
        }
        if named.len() == 0 {
            return;
        }
        for j in 1..named.len() {
            let x = named[j];
            let mut q = j;
            while q > 0 && named[q - 1] > x {
                named.set(q, named[q - 1]);
                q -= 1;
            }
            named.set(q, x);
        }
        out.push_str("for example: ");
        for j in 0..named.len() {
            let l = (named[j] >> 32) as u32;
            let t = (named[j] & 0xFFFFFFFFu64) as u32;
            if j != 0 {
                out.push_str(", ");
            }
            out.push_str(self.text(self.m, b.locals.at(l as usize).name()));
            out.push_str(" = ");
            let v = self.ev.val[t as usize];
            if self.tm.at(t).w == W_BOOL {
                out.push_str(
                    if v.is_zero() {
                        "false"
                    } else {
                        "true"
                    },
                );
            } else {
                out.push_str(v.to_string().as_str());
            }
        }
        if other != 0 {
            out.push_str(", with other values the proof cannot name");
        }
    }

    // Prove that the conditions `pc` imply `goal`; report obligation `key` when they do not.
    fn oblige(self: &mut Self, pc: &Vector<u32>, goal: u32, key: u64, sp: tok::Span, msg: String, note: String) {
        if self.over || self.failed.contains_key(&key) || self.refining && key >> 56 != OB_REFINE {
            return;
        }
        if self.sv.implies(&self.tm, pc, goal) {
            return;
        }
        if self.steps + self.sv.steps > STEP_BUDGET {
            self.budget_spent();
            return;
        }
        let mut example = String::new();
        if self.enumerate(pc, goal, &mut example) {
            return;
        }
        self.report2(key, dc::CANNOT_PROVE_CONTRACT, sp, msg, note, example);
    }

    fn budget_spent(self: &mut Self) {
        if self.over {
            return;
        }
        self.over = true;
        let b = unsafe &*self.b;
        let a = self.ast_of(self.m);
        let sp = if a.at_const(b.owner.node).kind == NodeKind::NODE_FUNCTION {
            a.at_const(a.ext_name(b.owner.node)).span
        } else {
            a.at_const(b.owner.node).span
        };
        self.report(
            OB_BUDGET << 56,
            dc::CANNOT_PROVE_CONTRACT,
            sp,
            format("the proof of this function exceeds its step budget"),
            String::from_str("split the function, or state more facts as contracts"),
        );
    }

    // ---- values -----------------------------------------------------------------------------------

    // The value of whole local `l` of body `cb` in `state`, made a fresh unknown at its first read.
    fn local_val(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, l: u32) u32 {
        if state[l as usize] == NONE {
            let v = self.fresh(cm, cb.locals.at(l as usize).ty);
            state.set(l as usize, v);
        }
        return state[l as usize];
    }

    // The value place `pl` of body `cb` holds. `all`: every whole local is modeled (a callee frame).
    // The state's last entry is the memory epoch.
    fn read_place(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, pl: u32, all: bool) u32 {
        let p = *cb.places.at(pl as usize);
        if !all && !self.tracked[p.base as usize] {
            return self.fresh(cm, p.ty);
        }
        return self.read_prefix(cb, cm, state, &p, p.proj_len, all);
    }

    // The value of place `p`'s first `n` projections.
    fn read_prefix(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        p: &ir::Place,
        n: u32,
        all: bool,
    ) u32 {
        let mut v = self.local_val(cb, cm, state, p.base);
        let mut ty = cb.locals.at(p.base as usize).ty;
        for j in p.proj_start..p.proj_start + n {
            let pj = *cb.projections.at(j as usize);
            if pj.kind == ir::PJ_DEREF {
                v = self.deref(state, v, cm, pj.ty);
            } else if pj.kind == ir::PJ_DOWNCAST {
                v = self.tm.make(Term { k: wide(pj.data), a: v, b: 0, op: T_DOWN, w: W_OTHER, sg: false });
            } else {
                let key = self.proj_key(cb, cm, state, &pj, ty, all);
                let (w, sg) = self.ty_of(cm, pj.ty);
                v = self.tm.sel(v, key, w, sg);
            }
            ty = pj.ty;
        }
        return v;
    }

    // The member key of a field or index projection over a value of type `base`: the field's index
    // (from its declaration's place among the struct's members when the projection names only the
    // declaration), or the index's value.
    fn proj_key(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pj: &ir::Projection,
        base: TypeId,
        all: bool,
    ) u32 {
        if pj.kind == ir::PJ_INDEX_OP {
            return self.operand(cb, cm, state, pj.data, all);
        }
        if pj.kind == ir::PJ_FIELD && pj.data == ir::IR_NONE {
            let ix = self.field_index(cm, base, pj.sub);
            if ix >= 0 {
                return self.tm.int(wide(ix), 64, false);
            }
            return self.tm.int(wide(pj.sub) + i128::one().shl(40), 64, false);
        }
        return self.tm.int(wide(pj.data), 64, false);
    }

    // The place of field declaration `sub` among the members of struct type `ty`, -1 when it is not one.
    fn field_index(self: &Self, m: ModuleId, ty: TypeId, sub: NodeId) i64 {
        if ty == TYPE_NONE || sub == NODE_NONE {
            return -1;
        }
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        let mut dm: ModuleId = 0;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            dm = y.module;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = a.instance(y.as_data.inst);
            dm = inst.module;
            dn = inst.decl;
        }
        if dn == NODE_NONE || dm as usize >= self.pkg().modules.len() || !self.pkg().modules.at(dm as usize).has_ast {
            return -1;
        }
        let da = self.ast_of(dm);
        if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return -1;
        }
        let ag = unsafe da.ext(dn).aggregate;
        if ag.is_tuple {
            return -1;
        }
        for j in 0..ag.members.len {
            if unsafe da.list(ag.members)[j as usize] == sub {
                return j;
            }
        }
        return -1;
    }

    // The value reference or pointer `r` points to, of type `ty`: a shared reference's value, a
    // mutable reference's local in the state it refers to, else a load in the current memory epoch.
    fn deref(self: &mut Self, state: &Vector<u32>, r: u32, cm: ModuleId, ty: TypeId) u32 {
        let x = self.tm.at(r);
        if x.op == T_REF {
            return x.a;
        }
        if x.op == T_MREF {
            let ms = if self.mem != null {
                unsafe &*self.mem
            } else {
                state
            };
            if x.a as usize < ms.len() && ms[x.a as usize] != NONE {
                return ms[x.a as usize];
            }
        }
        let (w, sg) = self.ty_of(cm, ty);
        let ep = state[state.len() - 1];
        return self.tm.make(Term { k: i128::zero(), a: r, b: ep, op: T_LOAD, w: w, sg: sg });
    }

    // A memory event (a call, a drop, a write through a pointer): every local a reference or pointer
    // made on the path may reach holds an unknown value, and loads read a new epoch.
    fn mem_event(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>) {
        for j in 0..self.esc.len() {
            self.forget(cb, cm, state, self.esc[j]);
        }
        let n = state.len() - 1;
        state.set(n, self.tm.var(W_OTHER, false));
    }

    // Local `l` may be reached through a reference or pointer from here on.
    fn escape(self: &mut Self, l: u32) {
        if !self.is_mem[l as usize] {
            return;
        }
        for j in 0..self.esc.len() {
            if self.esc[j] == l {
                return;
            }
        }
        self.esc.push(l);
    }

    fn operand(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, opid: u32, all: bool) u32 {
        let op = *cb.operands.at(opid as usize);
        if op.kind != ir::OP_CONST {
            return self.read_place(cb, cm, state, op.data, all);
        }
        return self.constant(cb, cm, op.data, op.ty);
    }

    // The value of constant `cid` of body `cb`, read as type `ty`.
    fn constant(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, cid: u32, ty: TypeId) u32 {
        let c = *cb.constants.at(cid as usize);
        let (w, sg) = self.ty_of(cm, ty);
        if c.kind == ir::CK_BOOL {
            return self.tm.boolean(c.val != 0);
        }
        if c.kind == ir::CK_INT && w > W_BOOL {
            let sm = if c.item.node != NODE_NONE {
                c.item.module
            } else {
                cb.module
            };
            let mut v: i64 = 0;
            if c.int_value(&self.pkg().modules.at(sm as usize).source, &mut v) {
                let k = if !sg && v < 0 {
                    u64_val(v as u64)
                } else {
                    wide(v)
                };
                return self.tm.int(k, w, sg);
            }
        }
        return self.tm.var(w, sg);
    }

    // Write `v` (NONE: an unknown value) to place `pl`: a member path updates its local's value; a
    // write through a mutable reference to a local updates that local, any other one through a
    // reference or pointer is a memory event.
    fn write_place(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pl: u32,
        v: u32,
        all: bool,
    ) {
        let p = *cb.places.at(pl as usize);
        if !all && !self.tracked[p.base as usize] {
            return;
        }
        let mut dr = p.proj_len;
        for j in 0..p.proj_len {
            if dr == p.proj_len && cb.projections.at((p.proj_start + j) as usize).kind == ir::PJ_DEREF {
                dr = j;
            }
        }
        let mut base = p.base;
        let mut from: u32 = 0;
        if dr < p.proj_len {
            let r = self.read_prefix(cb, cm, state, &p, dr, all);
            let x = self.tm.at(r);
            if all || x.op != T_MREF || self.has_deref(cb, &p, dr + 1) {
                self.mem_event(cb, cm, state);
                return;
            }
            base = x.a;
            from = dr + 1;
        }
        if !all && self.is_mem[base as usize] {
            // A load may read this local's storage: it reads a new epoch.
            let n = state.len() - 1;
            state.set(n, self.tm.var(W_OTHER, false));
        }
        if from == p.proj_len {
            if v != NONE {
                state.set(base as usize, v);
            } else {
                self.forget(cb, cm, state, base);
            }
            return;
        }
        let old = self.local_val(cb, cm, state, base);
        let x = if v == NONE {
            self.tm.var(W_OTHER, false)
        } else {
            v
        };
        let nv = self.update(cb, cm, state, &p, from, old, x, all);
        if nv == NONE {
            self.forget(cb, cm, state, base);
        } else {
            state.set(base as usize, nv);
        }
    }

    fn has_deref(self: &Self, cb: &ir::CoreBody, p: &ir::Place, from: u32) bool {
        for j in from..p.proj_len {
            if cb.projections.at((p.proj_start + j) as usize).kind == ir::PJ_DEREF {
                return true;
            }
        }
        return false;
    }

    // `old` with the member path of `p`'s projections from `from` set to `v`; NONE when the path
    // takes a variant.
    fn update(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        p: &ir::Place,
        from: u32,
        old: u32,
        v: u32,
        all: bool,
    ) u32 {
        if from == p.proj_len {
            return v;
        }
        let pj = *cb.projections.at((p.proj_start + from) as usize);
        if pj.kind == ir::PJ_DOWNCAST || pj.kind == ir::PJ_DEREF {
            return NONE;
        }
        let bty = if from == 0 {
            cb.locals.at(p.base as usize).ty
        } else {
            cb.projections.at((p.proj_start + from - 1) as usize).ty
        };
        let key = self.proj_key(cb, cm, state, &pj, bty, all);
        let (w, sg) = self.ty_of(cm, pj.ty);
        let sub = self.tm.sel(old, key, w, sg);
        let inner = self.update(cb, cm, state, p, from + 1, sub, v, all);
        if inner == NONE {
            return NONE;
        }
        return self.tm.upd(old, key, inner);
    }

    // Local `l` of body `cb` holds an unknown value from here on. The value is made now, not at the
    // next read: a chain reads a copy of the state, and the body must read the same value after it.
    fn forget(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, l: u32) {
        let v = self.fresh(cm, cb.locals.at(l as usize).ty);
        state.set(l as usize, v);
    }

    // A checked operation's value `exact` (of a type that fits it only if it does not overflow): with
    // OVF_PROVE the proof that it fits, under `pc`, then the exact value; with OVF_KEEP a fresh value
    // that equals the exact one where it fits.
    fn checked(self: &mut Self, exact: u32, pc: &mut Vector<u32>, ovf: u8, key: u64, sp: tok::Span) u32 {
        let fits = self.tm.in_range(exact);
        if self.tm.is_true(fits) {
            return exact;
        }
        if ovf == OVF_PROVE {
            self.oblige(pc, fits, key, sp, format("cannot prove that this operation does not overflow"), String::new());
            return exact;
        }
        let x = self.tm.at(exact);
        let r = self.tm.var(x.w, x.sg);
        let nf = self.tm.not(fits);
        let eq = self.tm.cmp(T_EQ, r, exact);
        pc.push(self.tm.or(nf, eq));
        return r;
    }

    // The value of rvalue `rid` of body `cb`, in `state`, under `pc` (which a division extends with its
    // nonzero divisor). `key`: the report key of its overflow obligation.
    fn rvalue(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        rid: u32,
        all: bool,
        ovf: u8,
        key: u64,
        sp: tok::Span,
    ) u32 {
        let rv = *cb.rvalues.at(rid as usize);
        let (w, sg) = self.ty_of(cm, rv.target);
        if rv.kind == ir::RV_USE {
            let x = self.operand(cb, cm, state, rv.a, all);
            // An array's view (`b` 1 or 2) has the array's length.
            let n = self.array_len(cm, cb.operands.at(rv.a as usize).ty);
            if rv.b != 0 && n >= 0 {
                return self.tm.make(Term { k: wide(n), a: x, b: 0, op: T_VIEW, w: W_OTHER, sg: false });
            }
            return x;
        }
        if !all && (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE) {
            self.escape(cb.places.at(rv.a as usize).base);
        }
        if !all && rv.kind == ir::RV_CLOSURE {
            for j in rv.a..rv.a + rv.b {
                let op = *cb.operands.at(cb.oper_pool[j as usize] as usize);
                if op.kind != ir::OP_CONST {
                    self.escape(cb.places.at(op.data as usize).base);
                }
            }
        }
        if rv.kind == ir::RV_REF {
            let p = *cb.places.at(rv.a as usize);
            if p.proj_len == 0 && (all || self.tracked[p.base as usize]) {
                let v = self.local_val(cb, cm, state, p.base);
                if rv.b != 0 {
                    return self.tm.make(Term { k: i128::zero(), a: p.base, b: 0, op: T_MREF, w: W_OTHER, sg: false });
                }
                if !self.ptr_cast && self.frozen(cm, cb.locals.at(p.base as usize).ty) {
                    return self.tm.unary(T_REF, v, W_OTHER, false);
                }
            }
            return self.tm.var(W_OTHER, false);
        }
        if rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_ARRAY || rv.c == ir::AGG_STRUCT && rv.item.node != NODE_NONE) {
            let mut xs = Vector::<u32>::with_capacity(rv.b as usize);
            for j in rv.a..rv.a + rv.b {
                let o = cb.oper_pool[j as usize];
                xs.push(
                    if o == ir::IR_NONE {
                        self.tm.var(W_OTHER, false)
                    } else {
                        self.operand(cb, cm, state, o, all)
                    },
                );
            }
            return self.tm.pool(T_AGG, &xs, i128::zero());
        }
        if rv.kind == ir::RV_LEN {
            let n = self.array_len(cm, cb.places.at(rv.a as usize).ty);
            if n >= 0 && w > W_BOOL {
                return self.tm.int(wide(n), w, sg);
            }
        }
        if rv.kind == ir::RV_UNARY {
            let x = self.operand(cb, cm, state, rv.a, all);
            let op = rv.b as u8;
            if op == tt::TokenType::Bang as u8 && self.tm.is_bool(x) {
                return self.tm.not(x);
            }
            if op == tt::TokenType::Minus as u8 && self.tm.is_int(x) && w > W_BOOL {
                let e = self.tm.neg(x, w, sg);
                return self.checked(e, pc, ovf, key, sp);
            }
            if op == tt::TokenType::Tilde as u8 && self.tm.is_int(x) && w > W_BOOL {
                return self.tm.unary(T_BNOT, x, w, sg);
            }
            return self.tm.var(w, sg);
        }
        if rv.kind == ir::RV_BINARY {
            let x = self.operand(cb, cm, state, rv.a, all);
            let y = self.operand(cb, cm, state, rv.b, all);
            let op = rv.c;
            let ints = self.tm.is_int(x) && self.tm.is_int(y);
            let bools = self.tm.is_bool(x) && self.tm.is_bool(y);
            if ints && w > W_BOOL {
                if op == tt::TokenType::Plus as u8 || op == tt::TokenType::Minus as u8 || op == tt::TokenType::Star as u8 {
                    let to = if op == tt::TokenType::Plus as u8 {
                        T_ADD
                    } else if op == tt::TokenType::Minus as u8 {
                        T_SUB
                    } else {
                        T_MUL
                    };
                    let e = self.tm.arith(to, x, y, w, sg);
                    return self.checked(e, pc, ovf, key, sp);
                }
                if op == tt::TokenType::Slash as u8 || op == tt::TokenType::Percent as u8 {
                    // A zero divisor traps in every profile: past the operation it is not zero.
                    let z = self.tm.int(i128::zero(), self.tm.at(y).w, self.tm.at(y).sg);
                    pc.push(self.tm.cmp(T_NE, y, z));
                    return self.tm.arith(
                        if op == tt::TokenType::Slash as u8 {
                            T_DIV
                        } else {
                            T_REM
                        },
                        x,
                        y,
                        w,
                        sg,
                    );
                }
                let bo = if op == tt::TokenType::Ampersand as u8 {
                    T_BAND
                } else if op == tt::TokenType::Pipe as u8 {
                    T_BOR
                } else if op == tt::TokenType::Caret as u8 {
                    T_BXOR
                } else if op == tt::TokenType::LeftShift as u8 {
                    T_SHL
                } else if op == tt::TokenType::RightShift as u8 {
                    T_SHR
                } else {
                    0
                };
                if bo == T_SHL || bo == T_SHR {
                    // A count below 0 or of the width or more traps in every profile.
                    let yx = self.tm.at(y);
                    let z = self.tm.int(i128::zero(), yx.w, yx.sg);
                    let wv = self.tm.int(wide(w), yx.w, yx.sg);
                    pc.push(self.tm.cmp(T_LE, z, y));
                    pc.push(self.tm.cmp(T_LT, y, wv));
                }
                if bo != 0 {
                    return self.tm.arith(bo, x, y, w, sg);
                }
            }
            if ints || bools && (op == tt::TokenType::EqualEqual as u8 || op == tt::TokenType::BangEqual as u8) {
                if op == tt::TokenType::LessThan as u8 {
                    return self.tm.cmp(T_LT, x, y);
                }
                if op == tt::TokenType::LessThanEqual as u8 {
                    return self.tm.cmp(T_LE, x, y);
                }
                if op == tt::TokenType::GreaterThan as u8 {
                    return self.tm.cmp(T_LT, y, x);
                }
                if op == tt::TokenType::GreaterThanEqual as u8 {
                    return self.tm.cmp(T_LE, y, x);
                }
                if op == tt::TokenType::EqualEqual as u8 {
                    return self.tm.cmp(T_EQ, x, y);
                }
                if op == tt::TokenType::BangEqual as u8 {
                    return self.tm.cmp(T_NE, x, y);
                }
            }
            if bools {
                if op == tt::TokenType::Ampersand as u8 {
                    return self.tm.and(x, y);
                }
                if op == tt::TokenType::Pipe as u8 {
                    return self.tm.or(x, y);
                }
                if op == tt::TokenType::Caret as u8 {
                    return self.tm.cmp(T_NE, x, y);
                }
            }
            return self.tm.var(w, sg);
        }
        if rv.kind == ir::RV_CAST && rv.b == ir::CAST_NUMERIC as u32 {
            let x = self.operand(cb, cm, state, rv.a, all);
            let xs = self.tm.at(x);
            if xs.w > W_BOOL && w > W_BOOL {
                // A cast that keeps every value of the source keeps the value.
                let (lo0, hi0) = Terms::range(xs.w, xs.sg);
                let (lo1, hi1) = Terms::range(w, sg);
                if lo1 <= lo0 && hi0 <= hi1 {
                    return x;
                }
                // A value the target type holds keeps its value.
                let c = self.tm.unary(T_CAST, x, w, sg);
                let l = self.tm.int(lo1, xs.w, xs.sg);
                let h = self.tm.int(hi1, xs.w, xs.sg);
                let below = self.tm.cmp(T_LT, x, l);
                let above = self.tm.cmp(T_LT, h, x);
                let eq = self.tm.cmp(T_EQ, c, x);
                let out = self.tm.or(below, above);
                pc.push(self.tm.or(out, eq));
                return c;
            }
        }
        return self.tm.var(w, sg);
    }

    // The effect of statement `sid` of body `cb` on `state` and `pc`.
    fn statement(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        sid: u32,
        all: bool,
        ovf: u8,
    ) {
        let s = *cb.statements.at(sid as usize);
        if s.kind != ir::ST_ASSIGN {
            return;
        }
        let rv = *cb.rvalues.at(s.rvalue as usize);
        if !all && rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_ASM || rv.c == ir::IN_VOLATILE_STORE) {
            self.mem_event(cb, cm, state);
        }
        let v = self.rvalue(cb, cm, state, pc, s.rvalue, all, ovf, OB_OVERFLOW << 56 | sid as u64, s.span);
        self.write_place(cb, cm, state, s.place, v, all);
    }

    // The conditions under which switch `t` of body `cb` takes each edge, as (target, condition)
    // pairs into `out`.
    fn switch_edges(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
        out: &mut Vector<u64>,
    ) {
        let d = self.operand(cb, cm, state, t.a, all);
        let dx = self.tm.at(d);
        let mut other = self.tm.boolean(true);
        for j in t.sw_start..t.sw_start + t.sw_len {
            let pr = cb.switch_pool[j as usize];
            let tgt = (pr & 0xFFFFFFFFu64) as u32;
            let val = (pr >> 32) as u32;
            let c = if dx.w == W_BOOL {
                if val == 0 {
                    self.tm.not(d)
                } else {
                    d
                }
            } else if dx.w > W_BOOL {
                let k = if dx.sg {
                    wide(val as i32)
                } else {
                    wide(val)
                };
                let kv = self.tm.int(k, dx.w, dx.sg);
                self.tm.cmp(T_EQ, d, kv)
            } else {
                self.tm.var(W_BOOL, false)
            };
            out.push(tgt as u64 << 32 | c as u64);
            let nc = self.tm.not(c);
            other = self.tm.and(other, nc);
        }
        out.push(t.t0 as u64 << 32 | other as u64);
    }

    // ---- contract chains --------------------------------------------------------------------------

    // Chain `s` of body `cb` (module `cm`) evaluated in `state` under `pc`: the formula that the check
    // passes (each path through the chain with its conditions, a path that panics left out), and for
    // a `decreases` measure its value (NONE when the chain branches). `all`: `state` is a callee frame.
    // `wsp`: the span of a well-definedness report, or an empty span for the operation's own.
    fn chain(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        s: ir::ContractSite,
        state: &Vector<u32>,
        pc: &Vector<u32>,
        all: bool,
        wsp: tok::Span,
    ) (u32, u32) {
        let mut f = self.tm.boolean(false);
        let mut value = NONE;
        let mut subs = Vector::<Sub>::new();
        subs.push(Sub { state: state.clone(), conds: Vector::<u32>::new(), blk: s.chain });
        let mut leaves: u32 = 0;
        let mut edges = Vector::<u64>::new();
        for _k in 0..STEP_BUDGET {
            if subs.len() == 0 {
                break;
            }
            if !self.spend() {
                self.budget_spent();
                return self.tm.boolean(false), NONE;
            }
            let mut sb = subs.pop().unwrap();
            let bb = *cb.blocks.at(sb.blk as usize);
            let mut full = pc.clone();
            for j in 0..sb.conds.len() {
                full.push(sb.conds[j]);
            }
            let n0 = full.len();
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *cb.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let sp = if wsp.end > wsp.start {
                    wsp
                } else {
                    st.span
                };
                let key = OB_OVERFLOW << 56 | (cm as u64 & 0xFFFF) << 40 | sid as u64;
                let v = self.rvalue(cb, cm, &mut sb.state, &mut full, st.rvalue, all, OVF_PROVE, key, sp);
                self.write_place(cb, cm, &mut sb.state, st.place, v, all);
            }
            for j in n0..full.len() {
                sb.conds.push(full[j]);
            }
            let t = bb.term;
            if sb.blk == s.check {
                let c = self.operand(cb, cm, &mut sb.state, t.a, all);
                let mut path = self.tm.boolean(true);
                for j in 0..sb.conds.len() {
                    path = self.tm.and(path, sb.conds[j]);
                }
                let pc1 = self.tm.and(path, c);
                f = self.tm.or(f, pc1);
                leaves += 1;
                if s.value != ir::IR_NONE {
                    value = if leaves == 1 && sb.conds.len() == 0 {
                        self.operand(cb, cm, &mut sb.state, s.value, all)
                    } else {
                        NONE
                    };
                }
                continue;
            }
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_DROP {
                sb.blk = t.t0;
                subs.push(sb);
            } else if t.kind == ir::TM_ASSERT {
                let c = self.operand(cb, cm, &mut sb.state, t.a, all);
                sb.conds.push(c);
                sb.blk = t.t0;
                subs.push(sb);
            } else if t.kind == ir::TM_SWITCH {
                edges.clear();
                self.switch_edges(cb, cm, &mut sb.state, &t, all, &mut edges);
                for j in 0..edges.len() {
                    let mut cs = sb.conds.clone();
                    cs.push((edges[j] & 0xFFFFFFFFu64) as u32);
                    subs.push(Sub { state: sb.state.clone(), conds: cs, blk: (edges[j] >> 32) as u32 });
                }
            } else if t.kind == ir::TM_CALL {
                self.chain_call(cb, cm, &mut sb.state, &t, all);
                sb.blk = t.t0;
                subs.push(sb);
            }
            // a return or an unreachable end: the chain panics on this path
        }
        return f, value;
    }

    // A call inside a contract chain: a `const fn` call is a value of its arguments; another call (an
    // impure contract, reported apart) is a fresh unknown.
    fn chain_call(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) {
        let r = self.call_value(cb, cm, state, t, all);
        if t.dests_len == 1 {
            self.write_place(cb, cm, state, cb.dest_pool[t.dests_start as usize], r, all);
        } else {
            for j in t.dests_start..t.dests_start + t.dests_len {
                self.write_place(cb, cm, state, cb.dest_pool[j as usize], NONE, all);
            }
        }
    }

    // The result of call `t`: the same value for the same `const fn` over the same arguments (scalars
    // and shared references to modeled values), else a fresh unknown.
    fn call_value(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let rty = if t.dests_len == 1 {
            cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty
        } else {
            TYPE_NONE
        };
        let (w, sg) = self.ty_of(cm, rty);
        if t.callee.node == NODE_NONE || !self.is_const_fn(t.callee) {
            return self.tm.var(w, sg);
        }
        let mut xs = Vector::<u32>::with_capacity(t.args_len as usize);
        for j in t.args_start..t.args_start + t.args_len {
            let oid = cb.oper_pool[j as usize];
            if !all && self.autoref(cb, cm, t, j - t.args_start) {
                return self.tm.var(w, sg);
            }
            let x = self.operand(cb, cm, state, oid, all);
            let xt = self.tm.at(x);
            if xt.w == W_OTHER && xt.op != T_REF && xt.op != T_VIEW && !self.frozen(cm, cb.operands.at(oid as usize).ty) {
                return self.tm.var(w, sg);
            }
            xs.push(x);
        }
        // A view of an array has the array's length.
        if xs.len() == 1 && w > W_BOOL && self.is_slice_len(t.callee) {
            let x = self.tm.at(xs[0]);
            let v = if x.op == T_REF {
                self.tm.at(x.a)
            } else {
                x
            };
            if v.op == T_VIEW {
                return self.tm.int(v.k, w, sg);
            }
        }
        // The type arguments are part of the callee; their ids are read in the body's module, which
        // the key names so that two modules' equal ids never meet.
        let mut key = skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64);
        if t.targs_len != 0 {
            key = skey_mix(key, cm);
            for j in t.targs_start..t.targs_start + t.targs_len {
                key = skey_mix(key, cb.targ_pool[j as usize]);
            }
        }
        return self.tm.call(key, &xs, w, sg);
    }

    // Whether chain `s` of body `cb` only computes its condition: no drop, no call of a function that
    // is not a `const fn`, and no write but into its own temporaries.
    fn pure_chain(self: &Self, cb: &ir::CoreBody, s: ir::ContractSite, expr: tok::Span) bool {
        let mut stack = Vector::<u32>::new();
        let mut seen = Vector::<bool>::with_capacity(cb.blocks.len());
        seen.resize_default(cb.blocks.len());
        stack.push(s.chain);
        for _k in 0..cb.blocks.len() + 1 {
            if stack.len() == 0 {
                return true;
            }
            let blk = stack.pop().unwrap();
            if seen[blk as usize] {
                continue;
            }
            seen.set(blk as usize, true);
            let bb = *cb.blocks.at(blk as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *cb.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let p = *cb.places.at(st.place as usize);
                let ld = cb.locals.at(p.base as usize);
                let own = ld.storage == ir::LS_TEMP || ld.storage == ir::LS_USER && ld.span.start >= expr.start && ld.span.end <= expr.end;
                if p.proj_len != 0 || !own {
                    return false;
                }
            }
            if blk == s.check {
                continue;
            }
            let t = bb.term;
            if t.kind == ir::TM_DROP || t.kind == ir::TM_CALL && !self.is_const_fn(t.callee) && !self.panics(t.callee) {
                return false;
            }
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL {
                stack.push(t.t0);
            } else if t.kind == ir::TM_SWITCH {
                stack.push(t.t0);
                for j in t.sw_start..t.sw_start + t.sw_len {
                    stack.push((cb.switch_pool[j as usize] & 0xFFFFFFFFu64) as u32);
                }
            }
        }
        return true;
    }

    // Whether `d` is the prelude's `Slice::len`.
    fn is_slice_len(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || d.module != self.slice.mid || (d.node & NODE_BODY) != 0 {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let sp = a.at_const(a.ext_name(d.node)).span;
        return self.text(d.module, sp) == "len";
    }

    // Whether `d` never returns (`@noreturn`): a panic a failed check calls.
    fn panics(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        return self.ast_of(d.module).attr_of(d.node, AttrKind::ATTR_NORETURN) != null;
    }

    // ---- the body ---------------------------------------------------------------------------------

    // Whether body `b` has an obligation: a contract check of its own, a call of a function with a
    // `requires` clause, or such a function used as a value (reported here).
    fn needs_proof(self: &mut Self, b: &ir::CoreBody) bool {
        let mut need = b.contracts.len() != 0;
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && self.has_clause(t.callee, CT_REQUIRES) {
                need = true;
            }
        }
        for oi in 0..b.operands.len() {
            let op = *b.operands.at(oi);
            if op.kind == ir::OP_CONST {
                let c = *b.constants.at(op.data as usize);
                if c.kind == ir::CK_ITEM && self.has_clause(c.item, CT_REQUIRES) {
                    let sp = c.raw;
                    self.m = b.module;
                    self.report(
                        oi as u64 | 0xFF00000000000000u64,
                        dc::CANNOT_PROVE_CONTRACT,
                        sp,
                        format("a function with a 'requires' clause cannot be used as a value"),
                        String::from_str(
                            "a call through the value proves no 'requires': call the function directly, or from a closure that proves it",
                        ),
                    );
                }
            }
        }
        return need;
    }

    // Whether body `b` of module `m` casts a value to a pointer.
    fn has_ptr_cast(self: &Self, m: ModuleId, b: &ir::CoreBody) bool {
        let a = self.ast_of(m);
        for r in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(r);
            if rv.kind == ir::RV_CAST && rv.target != TYPE_NONE && a.type_at(rv.target).kind == TypeKind::TYPE_POINTER {
                return true;
            }
        }
        return false;
    }

    // Whether argument `j` of call `t` (in body `cb` of module `cm`) is a place the call borrows
    // implicitly and may change: a parameter of reference or pointer type takes a value of another
    // type, unless a shared reference takes a frozen value. A call whose callee the walk cannot see
    // borrows every argument that is not a reference or a pointer.
    fn autoref(self: &Self, cb: &ir::CoreBody, cm: ModuleId, t: &ir::Terminator, j: u32) bool {
        let op = *cb.operands.at(cb.oper_pool[(t.args_start + j) as usize] as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return false;
        }
        let ok = self.ast_of(cm).type_at(op.ty).kind;
        if ok == TypeKind::TYPE_REFERENCE || ok == TypeKind::TYPE_POINTER {
            return false;
        }
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return true;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return true;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return false;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        if pt == TYPE_NONE {
            return true;
        }
        let py = a.type_at(pt);
        // A shared reference to a frozen value cannot change it: the call reads the value.
        if py.kind == TypeKind::TYPE_REFERENCE && py.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && !self.ptr_cast && self.frozen(
            cm,
            op.ty,
        ) {
            return false;
        }
        return py.kind == TypeKind::TYPE_REFERENCE || py.kind == TypeKind::TYPE_POINTER || py.kind == TypeKind::TYPE_GENERIC;
    }

    // The locals the walk models: every one but a static's reference. A local a pointer, a mutable
    // reference, a slice or a closure may reach (`is_mem`; a shared reference too, unless the local's
    // value is frozen and no reference becomes a pointer) also changes at each memory event.
    fn scan_tracked(self: &mut Self, b: &ir::CoreBody) {
        let nl = b.locals.len();
        self.tracked.clear();
        self.is_mem.clear();
        self.mem_list.clear();
        for l in 0..nl {
            self.tracked.push(b.locals.at(l).storage != ir::LS_STATIC_REF);
            self.is_mem.push(false);
        }
        self.ptr_cast = self.has_ptr_cast(b.module, b);
        for sid in 0..b.statements.len() {
            let s = *b.statements.at(sid);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE {
                let p = *b.places.at(rv.a as usize);
                if rv.kind != ir::RV_REF || rv.b != 0 || self.ptr_cast || !self.frozen(
                    b.module,
                    b.locals.at(p.base as usize).ty,
                ) {
                    self.is_mem.set(p.base as usize, true);
                }
            } else if rv.kind == ir::RV_CLOSURE {
                for j in rv.a..rv.a + rv.b {
                    let op = *b.operands.at(b.oper_pool[j as usize] as usize);
                    if op.kind != ir::OP_CONST {
                        self.is_mem.set(b.places.at(op.data as usize).base as usize, true);
                    }
                }
            }
        }
        // A call's implicit borrow of a place reaches its local.
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL {
                continue;
            }
            for j in 0..t.args_len {
                if self.autoref(b, b.module, &t, j) {
                    let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                    self.is_mem.set(b.places.at(op.data as usize).base as usize, true);
                }
            }
        }
        for l in 0..nl {
            if self.is_mem[l] && self.tracked[l] {
                self.mem_list.push(l as u32);
            }
        }
    }

    // The span of contract site `s` of body `cb` in module `cm`: its condition.
    fn site_span(self: &Self, cm: ModuleId, s: ir::ContractSite) tok::Span {
        let a = self.ast_of(cm);
        return a.at_const(a.contracts.at(s.clause as usize).expr).span;
    }

    // The return a path from block `blk` reaches through jumps, for a report's note.
    fn return_span(self: &Self, b: &ir::CoreBody, blk: u32) tok::Span {
        let mut x = blk;
        for _k in 0..64 {
            let t = b.blocks.at(x as usize).term;
            if t.kind == ir::TM_RETURN {
                return t.span;
            }
            if t.kind != ir::TM_GOTO && t.kind != ir::TM_DROP && t.kind != ir::TM_ASSERT && t.kind != ir::TM_CALL {
                break;
            }
            x = t.t0;
        }
        return tok::Span { start: 0, end: 0 };
    }

    // The kept index of the body of function `d`, NONE when none is kept.
    fn kept_index(self: &Self, d: DefId) u32 {
        if d.node == NODE_NONE {
            return NONE;
        }
        return switch unsafe (&*self.keep).ix.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => (*v) as u32,
            None => NONE,
        };
    }

    // Whether kept body `b` has a function-level `decreases` measure.
    fn has_fn_dec(self: &Self, b: &ir::CoreBody) bool {
        for x in 0..b.contracts.len() {
            if b.contracts[x].kind == CT_DECREASES && !self.loop_site(b, x as u32) {
                return true;
            }
        }
        return false;
    }

    // In a function with a `decreases` measure, each loop needs its own measure, unless it counts
    // over a range with an end or over a collection (`ir::RangeLoop`).
    fn loops_end(self: &mut Self, b: &ir::CoreBody) {
        for j in 0..self.fx.rpo.len() {
            let h = self.fx.rpo[j];
            if !self.fx.is_header(h) {
                continue;
            }
            let mut ok = false;
            for q in 0..b.ranges.len() {
                let r = b.ranges[q];
                ok = ok || r.head == h && (r.end_pl != ir::IR_NONE || r.end_k != ir::IR_NONE);
            }
            let mut x = self.site_of_pred[h as usize];
            for _k in 0..b.contracts.len() {
                if ok || x == NONE || !self.loop_site(b, x) {
                    break;
                }
                ok = b.contracts[x as usize].kind == CT_DECREASES;
                x = self.site_of_pred[b.contracts[x as usize].cont as usize];
            }
            if !ok {
                self.report(
                    0xFD00000000000000u64 | h as u64,
                    dc::CANNOT_PROVE_CONTRACT,
                    b.blocks.at(h as usize).term.span,
                    format("this loop needs a 'decreases' measure: its function has one"),
                    String::from_str("a loop over a range with an end or over a collection needs none"),
                );
            }
        }
    }

    // Lower the contracts of every interface method that has contracts and no body.
    fn lower_shells(self: &mut Self) {
        let p = unsafe &*self.p;
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            for j in 0..a.contracts.len() {
                let o = a.contracts.at(j).owner;
                if a.at_const(o).kind != NodeKind::NODE_FUNCTION || a.ext(o).function.body != NODE_NONE {
                    continue;
                }
                let key = skey_mix(0, m as u64 << 32 | o as u64);
                if self.shell_ix.contains_key(&key) {
                    continue;
                }
                let mut lw = irl::Lowerer::new(self.p, m as ModuleId, o);
                if !lw.lower_fn(o) {
                    continue;
                }
                let b = replace(
                    &mut lw.body,
                    ir::CoreBody::new(DefId { module: m as ModuleId, node: o }, m as ModuleId),
                );
                self.m = m as ModuleId;
                for x in 0..b.contracts.len() {
                    let sp = self.site_span(b.module, b.contracts[x]);
                    if !self.pure_chain(&b, b.contracts[x], sp) {
                        self.report(
                            0xFE00000000000000u64 | m as u64 << 32 | o as u64 << 8 | x as u64,
                            dc::CONTRACT_NOT_PURE,
                            sp,
                            format("a contract must only compute its condition"),
                            String::from_str(
                                "it calls a function that is not a 'const fn', drops a value or writes a variable",
                            ),
                        );
                    }
                }
                self.shell_ix.insert(key, self.shells.len() as u32);
                self.shells.push(b);
            }
        }
        self.failed.clear();
    }

    // The prover that holds the shells and the components: this one, or a worker's main prover.
    fn shared(self: &Self) &Prover {
        return if self.main == null {
            self
        } else {
            unsafe &*self.main
        };
    }

    // Both walks of kept body `k`: its own obligations, then for a conformance's method the
    // refinement of its interface's contracts.
    fn prove_kept(self: &mut Self, k: usize) {
        let kb = unsafe (&*self.keep).kept.at(k);
        self.me = k as u32;
        // A `@prove_exhaustive` function's own obligations are its runs' (`exhaustive_job`).
        if !self.exhaustive(kb.body.owner) {
            self.prove_body(&kb.body, false);
        }
        // A conformance's method runs where a call through the interface proved only the
        // interface's contracts.
        let im = self.iface_member(kb.body.owner);
        if im.node != NODE_NONE && (self.has_clause(im, CT_REQUIRES) || self.has_clause(im, CT_ENSURES) || self.has_clause(
            kb.body.owner,
            CT_REQUIRES,
        )) {
            self.refine = self.contract_body(im);
            self.prove_body(&kb.body, true);
            self.refine = null;
        }
    }

    // Whether function `d` is marked `@prove_exhaustive`.
    fn exhaustive(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module as usize >= self.pkg().modules.len() || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        return self.ast_of(d.module).attr_of(d.node, AttrKind::ATTR_PROVE_EXHAUSTIVE) != null;
    }

    // The inputs of kept body `k`, a `@prove_exhaustive` function's (`PJob`); None after the report of
    // why they cannot run: a generic function, a `decreases` clause, a parameter without a small set of
    // values, or too many inputs. Each integer parameter takes the values its type and the bounds
    // that the `requires` clauses imply allow.
    fn exhaustive_job(self: &mut Self, k: usize) Option<PJob> {
        let bp = (&unsafe (&*self.keep).kept.at(k).body) as *const ir::CoreBody;
        let b = unsafe &*bp;
        self.m = b.module;
        self.b = bp;
        self.me = k as u32;
        self.refining = false;
        self.tm.clear();
        self.sv.steps = 0;
        self.steps = 0;
        self.over = false;
        self.failed.clear();
        let _ = self.needs_proof(b);
        self.begin_sites(b, false);
        let a = self.ast_of(b.module);
        let f = b.owner.node;
        let name_sp = a.at_const(a.ext_name(f)).span;
        let mut ok = true;
        if a.ext(f).function.generics.len != 0 || a.extend_arity(f) > 0 {
            self.report(
                OB_EVAL << 56 | k as u64 << 8,
                dc::PROVE_EXHAUSTIVE_DOMAIN,
                name_sp,
                format("'@prove_exhaustive' cannot evaluate a generic function"),
                String::from_str("its values depend on the types it is instantiated with"),
            );
            return None;
        }
        for j in 0..b.contracts.len() {
            if b.contracts[j].kind == CT_DECREASES {
                ok = false;
                self.report(
                    OB_EVAL << 56 | k as u64 << 8 | 1 | j as u64 << 40,
                    dc::PROVE_EXHAUSTIVE_DECREASES,
                    self.site_span(b.module, b.contracts[j]),
                    format("a '@prove_exhaustive' function takes no 'decreases' measure"),
                    String::from_str("each evaluation of the function ends, which proves that it ends"),
                );
            }
        }
        // The `requires` clauses at the entry, over the parameters' unknowns.
        let mut st = Vector::<u32>::new();
        fill(&mut st, b.locals.len() + 1);
        st.set(b.locals.len(), self.tm.var(W_OTHER, false));
        for l in b.returns..b.returns + b.args {
            self.forget(b, b.module, &mut st, l);
        }
        let mut pc = Vector::<u32>::new();
        let none = tok::Span { start: 0, end: 0 };
        for j in 0..b.contracts.len() {
            if b.contracts[j].kind == CT_REQUIRES {
                let (c, _v) = self.chain(b, b.module, b.contracts[j], &st, &pc, false, none);
                pc.push(c);
            }
        }
        let mut dims = Vector::<PDim>::with_capacity(b.args as usize);
        for l in b.returns..b.returns + b.args {
            switch self.pdim(b, l, &st, &pc) {
                Some(d) => dims.push(d),
                None => {
                    ok = false;
                    self.report(
                        OB_EVAL << 56 | k as u64 << 8 | 2 | l as u64 << 40,
                        dc::PROVE_EXHAUSTIVE_DOMAIN,
                        b.locals.at(l as usize).name(),
                        format(
                            "'@prove_exhaustive' cannot enumerate the values of parameter '{}'",
                            self.text(b.module, b.locals.at(l as usize).name()),
                        ),
                        String::from_str(
                            "a parameter must be a 'bool', an integer, an enum without payloads, or a shared reference to one of them",
                        ),
                    );
                },
            }
        }
        if !ok {
            return None;
        }
        let mut inputs: u64 = 1;
        let mut sizes = String::new();
        for j in 0..dims.len() {
            inputs = inputs.saturating_mul(dims[j].n);
            if j != 0 {
                sizes.push_str(", ");
            }
            sizes.format_into(
                "'{}' takes {} values",
                self.text(b.module, b.locals.at(dims[j].l as usize).name()),
                dims[j].count.to_string().as_str(),
            );
        }
        if inputs > PE_INPUTS_MAX {
            self.report2(
                OB_EVAL << 56 | k as u64 << 8 | 3,
                dc::PROVE_EXHAUSTIVE_DOMAIN,
                name_sp,
                format("'@prove_exhaustive': the parameters take more than {} combinations of values", PE_INPUTS_MAX),
                sizes,
                String::from_str("narrow an integer parameter with 'requires', as 'requires x < 256'"),
            );
            return None;
        }
        return Some(PJob { k: k, dims: dims, inputs: inputs, first: NO_INPUT });
    }

    // Parameter `l` of body `b` as an input dimension (`PDim`), None when it has no small set of
    // values; an integer's range is narrowed to the bounds the conditions `pc` imply of its unknown in
    // `st`.
    fn pdim(self: &mut Self, b: &ir::CoreBody, l: u32, st: &Vector<u32>, pc: &Vector<u32>) Option<PDim> {
        let a = self.ast_of(b.module);
        let mut ty = b.locals.at(l as usize).ty;
        if ty == TYPE_NONE {
            return None;
        }
        let mut by_ref = false;
        let y0 = *a.type_at(ty);
        if y0.kind == TypeKind::TYPE_REFERENCE && y0.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
            by_ref = true;
            ty = y0.as_data.elem;
        }
        let mut d = PDim {
            l: l,
            kind: PD_INT,
            by_ref: by_ref,
            lo: i128::zero(),
            n: 0,
            count: i128::zero(),
            w: 0,
            sg: false,
            tm: b.module,
            ty: ty,
            em: 0,
            decl: NODE_NONE,
            tags: Vector::<i64>::new(),
            vars: Vector::<NodeId>::new(),
        };
        let y = *a.type_at(ty);
        if y.kind == TypeKind::TYPE_ENUM {
            let ea = self.ast_of(y.module);
            let decl = y.as_data.decl;
            if ea.enum_has_payload(decl) {
                return None;
            }
            d.kind = PD_ENUM;
            d.em = y.module;
            d.decl = decl;
            let mut e = iri::interp_new(self.p);
            let ms = ea.ext(decl).aggregate.members;
            let mut cur: i64 = 0 - 1;
            for j in 0..ms.len {
                let vid = unsafe ea.list(ms)[j as usize];
                if !e.discr(y.module, vid, cur, &mut cur) {
                    return None;
                }
                d.tags.push(cur);
                d.vars.push(vid);
            }
            d.n = d.tags.len() as u64;
            d.count = u64_val(d.n);
            return Some(d);
        }
        let (w, sg) = self.ty_of(b.module, ty);
        if w == W_BOOL {
            d.kind = PD_BOOL;
            d.n = 2;
            d.count = u64_val(2);
            return Some(d);
        }
        if w < 8 {
            return None;
        }
        d.w = w;
        d.sg = sg;
        let (lo0, hi0) = Terms::range(w, sg);
        let mut lo = lo0;
        let mut hi = hi0;
        let x = st[l as usize];
        if !by_ref && x != NONE && pc.len() != 0 {
            // The least `hi` with `x <= hi`, then the greatest `lo` with `lo <= x`: each query halves the
            // range left (at most 128 of each).
            let mut a = lo0;
            for _q in 0..130 {
                if a >= hi {
                    break;
                }
                let mid = a + (hi - a).shr(1);
                let c = self.tm.int(mid, w, sg);
                let goal = self.tm.cmp(T_LE, x, c);
                self.sv.steps = 0;
                if self.sv.implies(&self.tm, pc, goal) {
                    hi = mid;
                } else {
                    a = mid + i128::one();
                }
            }
            let mut z = hi;
            for _q in 0..130 {
                if lo >= z {
                    break;
                }
                let mid = z - (z - lo).shr(1);
                let c = self.tm.int(mid, w, sg);
                let goal = self.tm.cmp(T_LE, c, x);
                self.sv.steps = 0;
                if self.sv.implies(&self.tm, pc, goal) {
                    lo = mid;
                } else {
                    z = mid - i128::one();
                }
            }
        }
        d.lo = lo;
        d.count = if hi < lo {
            i128::zero()
        } else {
            hi - lo + i128::one()
        };
        d.n = if wide(iri::I64_MAX) < d.count {
            NO_INPUT
        } else {
            d.count.to_i64() as u64
        };
        return Some(d);
    }

    // Report the first failed run of `job`, from part `r`, which holds the least failed input.
    fn report_part(self: &mut Self, job: &PJob, r: &PRes) {
        let b = unsafe &(&*self.keep).kept.at(job.k).body;
        self.m = b.module;
        let key = OB_EVAL << 56 | job.k as u64 << 8 | 4;
        if !r.cut {
            self.report2(key, dc::CANNOT_PROVE_CONTRACT, r.sp, r.msg.clone(), r.note.clone(), r.note2.clone());
            return;
        }
        self.report2(
            key,
            dc::CANNOT_PROVE_CONTRACT,
            r.sp,
            format("cannot prove that this function ends: its evaluation takes more than {} steps", share(job)),
            r.note.clone(),
            format(
                "each of its {} inputs may take an equal share of {} steps: narrow them with 'requires', or split the function",
                job.inputs,
                PE_STEPS,
            ),
        );
    }

    // The body whose contract sites hold function `d`'s contracts: its kept body, or for an
    // interface's method without a body its lowered contracts; null for neither.
    fn contract_body(self: &Self, d: DefId) *const ir::CoreBody {
        let kb = self.kept(d);
        if kb != null {
            return kb;
        }
        let sh = self.shared();
        return switch sh.shell_ix.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => sh.shells.at((*v) as usize),
            None => null,
        };
    }

    // The interface's method that method `d` of a conformance (`extend T as I`) implements, a
    // NODE_NONE def for another function.
    fn iface_member(self: &Self, d: DefId) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return none;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return none;
        }
        let e = switch a.member_of.get(&d.node) {
            Some(c) => *c,
            None => NODE_NONE,
        };
        if e == NODE_NONE || a.at_const(e).kind != NodeKind::NODE_EXTEND || a.ext(e).extend_def.interface_type == NODE_NONE {
            return none;
        }
        let idef = a.resolution_def(a.ext(e).extend_def.interface_type);
        if idef.node == NODE_NONE || !self.pkg().modules.at(idef.module as usize).has_ast {
            return none;
        }
        let ia = self.ast_of(idef.module);
        if ia.at_const(idef.node).kind != NodeKind::NODE_INTERFACE {
            return none;
        }
        let name = self.text(d.module, a.at_const(a.ext_name(d.node)).span);
        let items = ia.ext(idef.node).interface_def.items;
        for j in 0..items.len {
            let mid = unsafe ia.list(items)[j as usize];
            if ia.at_const(mid).kind == NodeKind::NODE_FUNCTION && self.text(
                idef.module,
                ia.at_const(ia.ext_name(mid)).span,
            ) == name {
                return DefId { module: idef.module, node: mid };
            }
        }
        return none;
    }

    // The frame of contract body `cb` over the parameters of body `b` in `state` (both lay out
    // their results, then their parameters), its result `r`.
    fn shell_frame(self: &mut Self, cb: &ir::CoreBody, b: &ir::CoreBody, state: &Vector<u32>, r: u32) Vector<u32> {
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, cb.locals.len() + 1);
        frame.set(cb.locals.len(), state[state.len() - 1]);
        for l in cb.returns..cb.returns + cb.args {
            if l < b.locals.len() as u32 && l < b.returns + b.args {
                frame.set(l as usize, state[l as usize]);
            }
        }
        if cb.returns == 1 && b.returns == 1 {
            frame.set(0, r);
        }
        return frame;
    }

    // The refinement walk at a return of a conformance's method: the interface's `ensures` hold.
    fn refine_return(self: &mut Self, b: &ir::CoreBody, path: &mut Path, sp: tok::Span) {
        if self.refine == null {
            return;
        }
        let ib = unsafe &*self.refine;
        let r = if b.returns == 1 {
            self.local_val(b, b.module, &mut path.state, 0)
        } else {
            NONE
        };
        let frame = self.shell_frame(ib, b, &path.state, r);
        let none = tok::Span { start: 0, end: 0 };
        self.mem = &path.state;
        for j in 0..ib.contracts.len() {
            let s = ib.contracts[j];
            if s.kind != CT_ENSURES {
                continue;
            }
            let (f, _v) = self.chain(ib, ib.module, s, &frame, &path.pc, true, none);
            let csp = self.site_span(ib.module, s);
            self.oblige(
                &path.pc,
                f,
                OB_REFINE << 56 | 1 << 48 | j as u64 << 32 | sp.start as u64,
                sp,
                format("cannot prove the interface's 'ensures' at this return"),
                format("the clause: {}", self.text(ib.module, csp)),
            );
        }
        self.mem = null;
    }

    fn prove_body(self: &mut Self, bp: *const ir::CoreBody, refining: bool) {
        let b = unsafe &*bp;
        self.m = b.module;
        self.refining = refining;
        if !refining && !self.needs_proof(b) {
            return;
        }
        self.b = bp;
        self.tm.clear();
        self.sv.steps = 0;
        self.steps = 0;
        self.over = false;
        self.failed.clear();
        self.begin_sites(b, refining);
        self.ovf = if b.contracts.len() != 0 {
            OVF_PROVE
        } else {
            OVF_KEEP
        };
        self.fn_dec = self.has_fn_dec(b);
        if self.fn_dec && !refining {
            self.loops_end(b);
        }
        self.work.clear();
        let mut st = Vector::<u32>::new();
        fill(&mut st, b.locals.len() + 1);
        let ne = b.locals.len();
        st.set(ne, self.tm.var(W_OTHER, false));
        self.vname.clear();
        for l in b.returns..b.returns + b.args {
            self.forget(b, b.module, &mut st, l);
            self.vname.insert(st[l as usize], l);
        }
        // The refinement walk starts from the interface's `requires`.
        let mut pc0 = Vector::<u32>::new();
        if refining && self.refine != null {
            let ib = unsafe &*self.refine;
            let frame = self.shell_frame(ib, b, &st, NONE);
            let none = tok::Span { start: 0, end: 0 };
            self.mem = &st;
            for j in 0..ib.contracts.len() {
                if ib.contracts[j].kind == CT_REQUIRES {
                    let (f, _v) = self.chain(ib, ib.module, ib.contracts[j], &frame, &pc0, true, none);
                    pc0.push(f);
                }
            }
            self.mem = null;
        }
        self.work.push(
            Path {
                state: st,
                pc: pc0,
                esc: Vector::<u32>::new(),
                lm: Vector::<u64>::new(),
                blk: b.entry,
                from: NONE,
                m0: NONE,
            },
        );
        for _k in 0..STEP_BUDGET {
            if self.work.len() == 0 || self.over {
                return;
            }
            if !self.spend() {
                self.budget_spent();
                return;
            }
            let path = self.work.pop().unwrap();
            self.run_block(b, path);
        }
        self.budget_spent();
    }

    // Start the walk of body `b`: its facts, the locals it models, and where each contract chain starts
    // and is entered. A chain that does more than compute its condition is reported (not by the
    // refinement walk, the body's second).
    fn begin_sites(self: &mut Self, b: &ir::CoreBody, refining: bool) {
        self.fx.begin(b, self.p);
        self.scan_tracked(b);
        let nb = b.blocks.len();
        fill(&mut self.site_of_chain, nb);
        fill(&mut self.site_of_pred, nb);
        for j in 0..b.contracts.len() {
            let s = b.contracts[j];
            self.site_of_chain.set(s.chain as usize, j as u32);
            self.site_of_pred.set(s.pred as usize, j as u32);
            let sp = self.site_span(b.module, s);
            if !refining && !self.pure_chain(b, s, sp) {
                self.report(
                    0xFE00000000000000u64 | j as u64,
                    dc::CONTRACT_NOT_PURE,
                    sp,
                    format("a contract must only compute its condition"),
                    String::from_str("it calls a function that is not a 'const fn', drops a value or writes a variable"),
                );
            }
        }
    }

    fn push_path(self: &mut Self, path: Path) {
        if self.work.len() >= PATHS_MAX {
            self.budget_spent();
            return;
        }
        self.work.push(path);
    }

    // Enter block `to` from block `from` on `path`: a contract chain is evaluated in place, a loop
    // header cuts the loop at its invariants.
    fn enter(self: &mut Self, b: &ir::CoreBody, mut path: Path, from: u32, to: u32) {
        let s = self.site_of_chain[to as usize];
        if s != NONE && b.contracts[s as usize].pred == from {
            self.own_site(b, path, s);
            return;
        }
        if self.fx.rpo_of.len() > to as usize && self.fx.is_header(to) {
            self.header(b, path, from, to);
            return;
        }
        path.blk = to;
        path.from = from;
        self.push_path(path);
    }

    // Contract site `si` of the body, reached on `path`.
    fn own_site(self: &mut Self, b: &ir::CoreBody, mut path: Path, si: u32) {
        let s = b.contracts[si as usize];
        let sp = self.site_span(b.module, s);
        let none = tok::Span { start: 0, end: 0 };
        let (f, v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
        if s.kind == CT_REQUIRES {
            if self.refining {
                self.oblige(
                    &path.pc,
                    f,
                    OB_REFINE << 56 | si as u64,
                    sp,
                    format("cannot prove this 'requires' from the interface's 'requires'"),
                    String::from_str("a call through the interface proves only the interface's 'requires'"),
                );
            }
            path.pc.push(f);
        } else if s.kind == CT_DECREASES {
            if !self.loop_site(b, si) {
                path.m0 = v;
            }
        } else if s.kind == CT_ENSURES {
            let rs = self.return_span(b, s.cont);
            let note = if rs.end > rs.start {
                format("on a path to the return at line {}", self.source_line(b.module, rs.start))
            } else {
                String::new()
            };
            self.oblige(
                &path.pc,
                f,
                OB_ENSURES << 56 | si as u64,
                sp,
                format("cannot prove this 'ensures' clause"),
                note,
            );
        } else {
            // An invariant of a loop that never repeats: it holds when the loop starts, and after.
            self.oblige(
                &path.pc,
                f,
                OB_INV_START << 56 | si as u64,
                sp,
                format("cannot prove that this 'invariant' holds when the loop starts"),
                String::new(),
            );
            path.pc.push(f);
        }
        path.blk = s.cont;
        path.from = s.check;
        self.push_path(path);
    }

    // Whether contract site `x` of `b` is a loop's clause (its owner is not the body's function).
    fn loop_site(self: &Self, b: &ir::CoreBody, x: u32) bool {
        let c = *self.ast_of(b.module).contracts.at(b.contracts[x as usize].clause as usize);
        return c.owner != b.owner.node && (c.kind == CT_INVARIANT || c.kind == CT_DECREASES);
    }

    // The obligation that measure `v` is at least 0 and below `m` (false when either is unknown).
    fn decrease(self: &mut Self, v: u32, m: u32) u32 {
        if v == NONE || m == NONE || !self.tm.is_int(v) || !self.tm.is_int(m) {
            return self.tm.boolean(false);
        }
        let vx = self.tm.at(v);
        let z = self.tm.int(i128::zero(), vx.w, vx.sg);
        let c1 = self.tm.cmp(T_LE, z, v);
        let c2 = self.tm.cmp(T_LT, v, m);
        return self.tm.and(c1, c2);
    }

    // Loop header `h` entered from `from`: each invariant holds on the way in; past the first entry
    // the path ends (the invariants hold again, so every later iteration is the one the first entry
    // walks); on the first entry every local the loop writes is forgotten and the invariants assumed.
    fn header(self: &mut Self, b: &ir::CoreBody, mut path: Path, from: u32, h: u32) {
        let back = from != NONE && self.fx.rpo_of[from as usize] >= self.fx.rpo_of[h as usize];
        // The loop's own clauses: the chains from the header, invariants then measures.
        let mut invs = Vector::<u32>::new();
        let mut decs = Vector::<u32>::new();
        let mut x = self.site_of_pred[h as usize];
        let mut last = NONE;
        for _k in 0..b.contracts.len() {
            if x == NONE || !self.loop_site(b, x) {
                break;
            }
            last = x;
            if b.contracts[x as usize].kind == CT_INVARIANT {
                invs.push(x);
            } else {
                decs.push(x);
            }
            x = self.site_of_pred[b.contracts[x as usize].cont as usize];
        }
        let none = tok::Span { start: 0, end: 0 };
        if back {
            // Each measure stays at least 0 and is below its value at the iteration's start.
            for j in 0..decs.len() {
                let s = b.contracts[decs[j] as usize];
                let (_f, v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
                let mut m = NONE;
                for q in 0..path.lm.len() {
                    if (path.lm[q] >> 32) as u32 == h {
                        m = (path.lm[q] & 0xFFFFFFFFu64) as u32;
                    }
                }
                let goal = self.decrease(v, m);
                self.oblige(
                    &path.pc,
                    goal,
                    OB_DECREASES << 56 | 1 << 40 | decs[j] as u64,
                    self.site_span(b.module, s),
                    format("cannot prove that this 'decreases' measure decreases in each iteration"),
                    String::from_str("it must stay at least 0 and be smaller than at the iteration's start"),
                );
            }
        }
        for j in 0..invs.len() {
            let s = b.contracts[invs[j] as usize];
            let (f, _v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
            let sp = self.site_span(b.module, s);
            if back {
                self.oblige(
                    &path.pc,
                    f,
                    OB_INV_STEP << 56 | invs[j] as u64,
                    sp,
                    format("cannot prove that this 'invariant' holds after an iteration"),
                    String::new(),
                );
            } else {
                self.oblige(
                    &path.pc,
                    f,
                    OB_INV_START << 56 | invs[j] as u64,
                    sp,
                    format("cannot prove that this 'invariant' holds when the loop starts"),
                    String::new(),
                );
            }
        }
        if back {
            return;
        }
        // A counted range loop's own invariant (`ir::RangeLoop`): its binding is the start, or a
        // value from the start up to the end.
        let mut rg = NONE;
        for j in 0..b.ranges.len() {
            if b.ranges[j].head == h {
                rg = j as u32;
            }
        }
        let mut lo = NONE;
        let mut hi = NONE;
        if rg != NONE {
            let r = b.ranges[rg as usize];
            lo = self.local_val(b, b.module, &mut path.state, r.ind);
            let ity = b.locals.at(r.ind as usize).ty;
            if r.end_pl != ir::IR_NONE {
                hi = self.read_place(b, b.module, &mut path.state, r.end_pl, false);
            } else if r.end_k != ir::IR_NONE {
                hi = self.constant(b, b.module, r.end_k, ity);
            }
        }
        self.fx.loop_scan(h);
        let mut event = false;
        for j in 0..self.fx.lblocks.len() {
            let bb = *b.blocks.at(self.fx.lblocks[j] as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(st.place as usize);
                    event = event || self.has_deref(b, &pl, 0) || self.is_mem[pl.base as usize];
                    self.forget(b, b.module, &mut path.state, pl.base);
                    let rv = *b.rvalues.at(st.rvalue as usize);
                    event = event || rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_ASM || rv.c == ir::IN_VOLATILE_STORE);
                }
            }
            if bb.term.kind == ir::TM_CALL || bb.term.kind == ir::TM_DROP {
                event = true;
                for q in bb.term.dests_start..bb.term.dests_start + bb.term.dests_len {
                    self.forget(b, b.module, &mut path.state, b.places.at(b.dest_pool[q as usize] as usize).base);
                }
            }
        }
        if event {
            // An earlier iteration may have reached any such local.
            self.esc = replace(&mut path.esc, Vector::<u32>::new());
            for j in 0..self.mem_list.len() {
                self.escape(self.mem_list[j]);
            }
            self.mem_event(b, b.module, &mut path.state);
            path.esc = replace(&mut self.esc, Vector::<u32>::new());
        }
        if rg != NONE && self.tm.is_int(lo) {
            let x = self.local_val(b, b.module, &mut path.state, b.ranges[rg as usize].ind);
            path.pc.push(self.tm.cmp(T_LE, lo, x));
            if hi != NONE && self.tm.is_int(hi) {
                let first = self.tm.cmp(T_EQ, x, lo);
                let below = self.tm.cmp(T_LE, x, hi);
                path.pc.push(self.tm.or(first, below));
            }
        }
        for j in 0..invs.len() {
            let s = b.contracts[invs[j] as usize];
            let (f, _v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
            path.pc.push(f);
        }
        for j in 0..decs.len() {
            let s = b.contracts[decs[j] as usize];
            let (_f, v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
            path.lm.push(h as u64 << 32 | v as u64);
        }
        if last != NONE {
            let last = b.contracts[last as usize];
            path.blk = last.cont;
            path.from = last.check;
        } else {
            path.blk = h;
            path.from = from;
        }
        self.push_path(path);
    }

    // Walk block `path.blk`: its statements, then its terminator.
    fn run_block(self: &mut Self, b: &ir::CoreBody, mut path: Path) {
        self.esc = replace(&mut path.esc, Vector::<u32>::new());
        let bb = *b.blocks.at(path.blk as usize);
        let ovf = self.ovf;
        for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
            self.statement(b, b.module, &mut path.state, &mut path.pc, sid, false, ovf);
        }
        let t = bb.term;
        let me = path.blk;
        if t.kind == ir::TM_CALL {
            self.call(b, &mut path, &t);
        } else if t.kind == ir::TM_DROP {
            // A destructor runs code: a memory event.
            self.mem_event(b, b.module, &mut path.state);
        }
        path.esc = replace(&mut self.esc, Vector::<u32>::new());
        if t.kind == ir::TM_GOTO {
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_DROP {
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_ASSERT {
            let c = self.operand(b, b.module, &mut path.state, t.a, false);
            path.pc.push(c);
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_SWITCH {
            let mut edges = Vector::<u64>::new();
            self.switch_edges(b, b.module, &mut path.state, &t, false, &mut edges);
            for j in 0..edges.len() {
                let mut q = path.copy();
                q.pc.push((edges[j] & 0xFFFFFFFFu64) as u32);
                self.enter(b, q, me, (edges[j] >> 32) as u32);
            }
        } else if t.kind == ir::TM_CALL {
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_RETURN && self.refining {
            let sp = if t.span.end > t.span.start {
                t.span
            } else {
                self.ast_of(b.module).at_const(b.owner.node).span
            };
            self.refine_return(b, &mut path, sp);
        }
        // a return or an unreachable end: the path ends
    }

    // Call `t` of a function in the caller's component (kept body `ci`): the callee's measure, over
    // the arguments, is at least 0 and below the caller's at its start.
    fn mutual(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, ci: u32) {
        let cb = unsafe &(&*self.keep).kept.at(ci as usize).body;
        let cm = cb.module;
        let a = self.ast_of(cm);
        let name = String::from_str(self.text(cm, a.at_const(a.ext_name(cb.owner.node)).span));
        let mut site = NONE;
        for x in 0..cb.contracts.len() {
            if cb.contracts[x].kind == CT_DECREASES && !self.loop_site(cb, x as u32) {
                site = x as u32;
            }
        }
        if site == NONE {
            self.report(
                OB_DECREASES << 56 | 2 << 40 | t.span.start as u64,
                dc::CANNOT_PROVE_CONTRACT,
                t.span,
                format("'{}' calls back into this function and has no 'decreases' measure", name.as_str()),
                String::new(),
            );
            return;
        }
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, cb.locals.len() + 1);
        let ne = cb.locals.len();
        frame.set(ne, path.state[path.state.len() - 1]);
        for j in 0..t.args_len {
            if cb.returns + j < cb.locals.len() as u32 {
                let x = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + j) as usize], false);
                frame.set((cb.returns + j) as usize, x);
            }
        }
        self.mem = &path.state;
        let none = tok::Span { start: 0, end: 0 };
        let (_f, v) = self.chain(cb, cm, cb.contracts[site as usize], &frame, &path.pc, true, none);
        self.mem = null;
        let goal = self.decrease(v, path.m0);
        self.oblige(
            &path.pc,
            goal,
            OB_DECREASES << 56 | 3 << 40 | t.span.start as u64,
            t.span,
            format("cannot prove that the 'decreases' measure decreases at this call of '{}'", name.as_str()),
            String::from_str("it must stay at least 0 and be smaller than the caller's at its start"),
        );
    }

    // Call `t` on `path`: the callee's `requires` hold, its `decreases` measure decreases at a call of
    // the body's own function, and its `ensures` hold after it.
    fn call(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        for j in 0..t.args_len {
            if self.autoref(b, b.module, t, j) {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                self.escape(b.places.at(op.data as usize).base);
            }
        }
        let r = self.call_value(b, b.module, &mut path.state, t, false);
        let d = t.callee;
        let own = d.module == b.owner.module && d.node == b.owner.node;
        let cbp = if d.node == NODE_NONE {
            null
        } else if own {
            b as *const ir::CoreBody
        } else {
            self.contract_body(d)
        };
        // A call back into the function's own component must decrease the measure too.
        let ci = self.kept_index(d);
        let scc = &self.shared().scc;
        // A `@prove_exhaustive` callee ends for each argument its `requires` admits: each run ended.
        if self.fn_dec && !own && ci != NONE && self.me != NONE && scc[ci as usize] != NONE && scc[ci as usize] == scc[self.me as usize] && !self.exhaustive(
            d,
        ) {
            self.mutual(b, path, t, ci);
        }
        let has_req = self.has_clause(d, CT_REQUIRES);
        if cbp == null && has_req {
            self.report(
                OB_REQUIRES << 56 | t.span.start as u64,
                dc::CANNOT_PROVE_CONTRACT,
                t.span,
                format("cannot prove the 'requires' of this call: the callee's lowering is not available"),
                String::new(),
            );
        }
        if cbp != null && unsafe (*cbp).contracts.len() != 0 {
            let cb = unsafe &*cbp;
            let cm = d.module;
            // The callee's frame: its parameters are the arguments, its result the call's.
            let mut frame = Vector::<u32>::new();
            fill(&mut frame, cb.locals.len() + 1);
            let ne = cb.locals.len();
            frame.set(ne, path.state[path.state.len() - 1]);
            for j in 0..t.args_len {
                if cb.returns + j < cb.locals.len() as u32 {
                    let oid = b.oper_pool[(t.args_start + j) as usize];
                    let x = if self.autoref(b, b.module, t, j) {
                        let pl = *b.places.at(b.operands.at(oid as usize).data as usize);
                        if pl.proj_len == 0 && self.tracked[pl.base as usize] {
                            let _ = self.local_val(b, b.module, &mut path.state, pl.base);
                            self.tm.make(Term { k: i128::zero(), a: pl.base, b: 0, op: T_MREF, w: W_OTHER, sg: false })
                        } else {
                            self.tm.var(W_OTHER, false)
                        }
                    } else {
                        self.operand(b, b.module, &mut path.state, oid, false)
                    };
                    frame.set((cb.returns + j) as usize, x);
                }
            }
            if cb.returns == 1 && t.dests_len == 1 {
                frame.set(0, r);
            }
            let name = String::from_str(self.text(cm, self.ast_of(cm).at_const(self.ast_of(cm).ext_name(d.node)).span));
            // The frame's references to the caller's locals read the caller's state.
            self.mem = &path.state;
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if s.kind == CT_REQUIRES {
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    let csp = self.site_span(cm, s);
                    self.oblige(
                        &path.pc,
                        f,
                        OB_REQUIRES << 56 | t.span.start as u64 << 16 | j as u64,
                        t.span,
                        format("cannot prove the 'requires' of '{}' at this call", name.as_str()),
                        format("the clause: {}", self.text(cm, csp)),
                    );
                } else if s.kind == CT_DECREASES && own {
                    let (_f, v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    let goal = self.decrease(v, path.m0);
                    self.oblige(
                        &path.pc,
                        goal,
                        OB_DECREASES << 56 | t.span.start as u64,
                        t.span,
                        format("cannot prove that the 'decreases' measure decreases at this call"),
                        String::from_str("it must stay at least 0 and be smaller than at the function's start"),
                    );
                }
            }
            self.mem = null;
            if self.tm.at(r).op != T_CALL {
                self.mem_event(b, b.module, &mut path.state);
            }
            let ne2 = cb.locals.len();
            frame.set(ne2, path.state[path.state.len() - 1]);
            // At the callee's returns, a parameter it writes may hold another value than the argument.
            let wm = self.param_writes(d, cb);
            for l in cb.returns..cb.returns + cb.args {
                if l - cb.returns >= 64 || (wm >> (l - cb.returns) as u64 & 1) != 0 {
                    self.forget(cb, cm, &mut frame, l);
                }
            }
            self.mem = &path.state;
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if s.kind == CT_ENSURES {
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    path.pc.push(f);
                }
            }
            self.mem = null;
        } else if self.tm.at(r).op != T_CALL {
            // A call that may write memory: a const fn call of frozen values writes none.
            self.mem_event(b, b.module, &mut path.state);
        }
        if t.dests_len == 1 {
            self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], r, false);
        } else {
            for j in t.dests_start..t.dests_start + t.dests_len {
                self.write_place(b, b.module, &mut path.state, b.dest_pool[j as usize], NONE, false);
            }
        }
    }

    // The parameters callee `d` (body `cb`) may change, one bit each (the first 64): a write, a call's
    // result, or a borrow or address of the parameter's storage. Scanned once per callee.
    fn param_writes(self: &mut Self, d: DefId, cb: &ir::CoreBody) u64 {
        let key = skey_mix(0, d.module as u64 << 32 | d.node as u64);
        if let Some(m) = self.pwrites.get(&key) {
            return *m;
        }
        let mut m: u64 = 0;
        let ptr_cast = self.has_ptr_cast(d.module, cb);
        for sid in 0..cb.statements.len() {
            let s = *cb.statements.at(sid);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            m |= param_bit(cb, cb.places.at(s.place as usize).base);
            let rv = *cb.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF && (rv.b != 0 || ptr_cast) || rv.kind == ir::RV_SLICE {
                m |= param_bit(cb, cb.places.at(rv.a as usize).base);
            }
        }
        for bi in 0..cb.blocks.len() {
            let t = cb.blocks.at(bi).term;
            if t.kind == ir::TM_CALL {
                for j in t.dests_start..t.dests_start + t.dests_len {
                    m |= param_bit(cb, cb.places.at(cb.dest_pool[j as usize] as usize).base);
                }
            }
        }
        self.pwrites.insert(key, m);
        return m;
    }
}

// The bit of local `l` of `cb` in a parameter mask: none for another local or past the 64th.
const fn param_bit(cb: &ir::CoreBody, l: u32) u64 {
    if l < cb.returns || l >= cb.returns + cb.args || l - cb.returns >= 64 {
        return 0;
    }
    return 1u64 << (l - cb.returns) as u64;
}

/// Whether a module of `p` states a contract or marks a function `@prove_exhaustive`: else there is
/// nothing to prove.
pub(package) fn any_contracts(p: &loader::Package) bool {
    for m in 0..p.modules.len() {
        if p.modules.at(m).has_ast && (unsafe (&*p.module_ast_const(m as ModuleId)).contracts.len() != 0 || any_exhaustive_in(
            p,
            m,
        )) {
            return true;
        }
    }
    return false;
}

/// Whether a module of `p` marks a function `@prove_exhaustive`: its proofs run the evaluator.
pub(package) fn any_exhaustive(p: &loader::Package) bool {
    for m in 0..p.modules.len() {
        if p.modules.at(m).has_ast && any_exhaustive_in(p, m) {
            return true;
        }
    }
    return false;
}

fn any_exhaustive_in(p: &loader::Package, m: usize) bool {
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    for j in 0..a.attrs.len() {
        if a.attrs.at(j).kind == AttrKind::ATTR_PROVE_EXHAUSTIVE as u8 {
            return true;
        }
    }
    return false;
}

// The position of input `x`'s value of parameter `j` of `job` among the parameter's values.
fn input_index(job: &PJob, x: u64, j: usize) u64 {
    let mut q = x;
    let mut i = job.dims.len();
    for _k in 0..job.dims.len() {
        i -= 1;
        if i == j {
            break;
        }
        q /= job.dims[i].n;
    }
    return q % job.dims[j].n;
}

// The arguments of input `x` of `job`, as evaluator values.
fn input_args(job: &PJob, x: u64, out: &mut Vector<iri::IVal>) {
    out.clear();
    for j in 0..job.dims.len() {
        let d = &job.dims[j];
        let i = input_index(job, x, j);
        let v = if d.kind == PD_BOOL {
            iri::IVal { kind: iri::IV_BOOL, tm: d.tm, ty: d.ty, i: i as i64, f: 0.0 }
        } else if d.kind == PD_ENUM {
            iri::IVal { kind: iri::IV_INT, tm: d.tm, ty: d.ty, i: d.tags[i as usize], f: 0.0 }
        } else {
            let bits = bits_of(d.lo + u64_val(i), d.w);
            let sh = 64 - d.w as u64;
            let iv = if d.sg {
                (bits << sh) as i64 >> sh as i64
            } else {
                bits as i64
            };
            iri::IVal { kind: iri::IV_INT, tm: d.tm, ty: d.ty, i: iv, f: 0.0 }
        };
        out.push(v);
    }
}

// Input `x` of `job` by the parameters of body `b`: `for example: x = 3, c = Color::Red`.
fn describe_input(p: &loader::Package, b: &ir::CoreBody, job: &PJob, x: u64, out: &mut String) {
    let src = p.modules.at(b.module as usize).source.as_str();
    out.push_str("for example: ");
    for j in 0..job.dims.len() {
        let d = &job.dims[j];
        let i = input_index(job, x, j);
        if j != 0 {
            out.push_str(", ");
        }
        let nm = b.locals.at(d.l as usize).name();
        out.push_str(src.slice(nm.start as usize, nm.end as usize));
        out.push_str(" = ");
        if d.kind == PD_BOOL {
            out.push_str(pick(i == 0, "false", "true"));
        } else if d.kind == PD_ENUM {
            let ea = unsafe &*p.module_ast_const(d.em);
            let es = p.modules.at(d.em as usize).source.as_str();
            let en = ea.at_const(ea.ext_name(d.decl)).span;
            out.push_str(es.slice(en.start as usize, en.end as usize));
            out.push_str("::");
            let vn = ea.at_const(ea.at_const(d.vars[i as usize]).as_data.variant.name).span;
            out.push_str(es.slice(vn.start as usize, vn.end as usize));
        } else {
            out.push_str((d.lo + u64_val(i)).to_string().as_str());
        }
    }
}

// An evaluator for `@prove_exhaustive` runs, its budgets fixed: the build's `--const-eval-*` do not
// change a proof.
fn engine(p: &loader::Package) iri::Interp {
    let mut e = iri::interp_new(p);
    e.all_typed = true;
    return e;
}

// The name of function `d`, as its source spells it.
fn fn_name(p: &loader::Package, d: DefId) str {
    let a = unsafe &*p.module_ast_const(d.module);
    if (d.node & NODE_BODY) != 0 || a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
        return "<closure>";
    }
    let sp = a.at_const(a.ext_name(d.node)).span;
    return p.modules.at(d.module as usize).source.as_str().slice(sp.start as usize, sp.end as usize);
}

// Run inputs [`r.from`, `r.to`) of `job` in order, to the first that fails (`PRes`), or to one after a
// failed input another part found: an input whose own `requires` fails is skipped.
fn run_inputs(p: &loader::Package, keep: &irl::Keep, job: &PJob, r: &mut PRes) {
    let b = &keep.kept.at(job.k).body;
    // The parts of the job share `first` through atomic operations only.
    let first = ptr::cast_mut(&job.first);
    let mut e = engine(p);
    let mut args = Vector::<iri::IVal>::with_capacity(job.dims.len());
    let mut refs: u64 = 0;
    for j in 0..job.dims.len() {
        if job.dims[j].by_ref && j < 64 {
            refs |= 1u64 << j as u64;
        }
    }
    for x in r.from..r.to {
        if unsafe atomic::load_u64(first, 0) < x {
            return;
        }
        input_args(job, x, &mut args);
        let k = e.prove_run(b, &args, refs, share(job) as u32);
        if k == iri::PR_OK || k == iri::PR_ASSERT && e.pa_depth == 1 && e.pa_kind == CT_REQUIRES {
            continue;
        }
        r.at = x;
        r.cut = k == iri::PR_TRAP && e.trap_kind_get() == iri::IT_TRAP_BUDGET_STEPS;
        if job.dims.len() != 0 {
            describe_input(p, b, job, x, &mut r.note);
        }
        if !r.cut {
            fail_report(p, b, &mut e, k, r);
        } else {
            let a = unsafe &*p.module_ast_const(b.module);
            r.sp = a.at_const(a.ext_name(b.owner.node)).span;
        }
        for _q in 0..64 {
            let f = unsafe atomic::load_u64(first, 0);
            if f <= x || unsafe atomic::cas_u64(first, f, x, false, 0, 0) {
                break;
            }
        }
        return;
    }
}

// The report of the run of body `b` that ended `k` (`iri::PR_*`) in `e`.
fn fail_report(p: &loader::Package, b: &ir::CoreBody, e: &mut iri::Interp, k: u8, r: &mut PRes) {
    let a = unsafe &*p.module_ast_const(b.module);
    r.sp = a.at_const(a.ext_name(b.owner.node)).span;
    if k == iri::PR_ASSERT {
        let owner = String::from_str(fn_name(p, e.pa_owner));
        let ca = unsafe &*p.module_ast_const(e.pa_owner.module);
        let clause = if e.pa_kind != iri::PA_PLAIN {
            let sp = ca.at_const(ca.contracts.at(e.pa_clause as usize).expr).span;
            String::from_str(
                p.modules.at(e.pa_owner.module as usize).source.as_str().slice(sp.start as usize, sp.end as usize),
            )
        } else {
            String::new()
        };
        if e.pa_depth == 1 {
            r.sp = if e.pa_kind != iri::PA_PLAIN {
                ca.at_const(ca.contracts.at(e.pa_clause as usize).expr).span
            } else {
                e.pa_span
            };
            r.msg = if e.pa_kind == CT_ENSURES {
                String::from_str("this 'ensures' clause does not hold")
            } else if e.pa_kind == CT_INVARIANT {
                String::from_str("this 'invariant' does not hold")
            } else {
                String::from_str("this assertion fails")
            };
        } else {
            r.sp = e.pa_top;
            r.msg = if e.pa_kind == CT_REQUIRES && e.pa_depth == 2 {
                format("the 'requires' of '{}' does not hold at this call", owner.as_str())
            } else if e.pa_kind == CT_REQUIRES {
                format("the 'requires' of '{}' does not hold in this call", owner.as_str())
            } else if e.pa_kind == CT_ENSURES {
                format("the 'ensures' of '{}' does not hold in this call", owner.as_str())
            } else if e.pa_kind == CT_INVARIANT {
                format("an 'invariant' of '{}' does not hold in this call", owner.as_str())
            } else {
                format("an assertion of '{}' fails in this call", owner.as_str())
            };
            if clause.len() != 0 {
                r.note2 = format("the clause: {}", clause.as_str());
            }
        }
    } else if k == iri::PR_TRAP {
        let tk = e.trap_kind_get();
        let mut detail = String::from_str(e.trap);
        let mut calls = String::new();
        // A panic's innermost frame is the panic itself.
        e.trap_frames(pick(tk == iri::IT_TRAP_PANIC, 1u32, 0), &mut calls);
        if calls.len() != 0 {
            detail.format_into(" (in {})", calls.as_str());
        }
        let top = e.trap_span.end > e.trap_span.start;
        if top {
            r.sp = e.trap_span;
        }
        r.msg = if iri::it_trap_is_ub(tk) && top {
            format("this statement is undefined behavior for some arguments: {}", detail.as_str())
        } else if tk == iri::IT_TRAP_PANIC && top {
            format("this statement panics for some arguments: {}", detail.as_str())
        } else {
            format("the evaluation of this function fails for some arguments: {}", detail.as_str())
        };
    } else {
        if e.top_span.end > e.top_span.start {
            r.sp = e.top_span;
        }
        r.msg = String::from_str("'@prove_exhaustive' cannot evaluate this at compile time");
        let mut why = String::new();
        e.refused_text(&mut why);
        if why.len() != 0 {
            r.note2 = format("it reaches {}", why.as_str());
        } else if e.ffi {
            r.note2 = String::from_str("it reaches a call of an external function");
        }
    }
}

// The `@prove_exhaustive` functions of `keep` outside the modules `skip` marks: their inputs split into
// parts that run in parallel, and each function reports the run of its least failed input, whatever
// the split.
fn prove_exhaustive(pv: &mut Prover, p: &loader::Package, keep: &irl::Keep, skip: &Vector<bool>) {
    let mut jobs = Vector::<PJob>::new();
    for k in 0..keep.kept.len() {
        let kb = keep.kept.at(k);
        if kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] && pv.exhaustive(kb.body.owner) {
            switch pv.exhaustive_job(k) {
                Some(j) => {
                    if j.inputs != 0 {
                        jobs.push(j);
                    }
                },
                None => {},
            }
        }
    }
    let mut parts = Vector::<PRes>::new();
    let workers: u64 = pick(p.jobs == 0, 1, p.jobs);
    for j in 0..jobs.len() {
        let n = jobs[j].inputs;
        let np = if workers == 1 || n < 2 {
            1
        } else {
            n.min(workers * PE_PARTS)
        };
        for c in 0..np {
            parts.push(
                PRes {
                    job: j as u32,
                    from: c * n / np,
                    to: (c + 1) * n / np,
                    at: NO_INPUT,
                    cut: false,
                    sp: tok::Span { start: 0, end: 0 },
                    msg: String::new(),
                    note: String::new(),
                    note2: String::new(),
                },
            );
        }
    }
    if parts.len() == 0 {
        return;
    }
    if workers == 1 || parts.len() < 2 {
        for c in 0..parts.len() {
            run_inputs(p, keep, &jobs[parts[c].job as usize], parts.index_mut(c));
        }
    } else {
        let pa = (p as *const loader::Package) as usize;
        let ka = (keep as *const irl::Keep) as usize;
        let ja = jobs.as_ptr() as usize;
        let ra = parts.as_mut_ptr() as usize;
        // A part's cost is its function's: each worker claims one part at a time.
        dpar::range_with(
            0..parts.len(),
            dpar::Options { schedule: dpar::Schedule::Dynamic, grain_size: 1 },
            |c: usize| {
                let pk = unsafe &*ptr::from_addr_mut::<loader::Package>(pa);
                let kp = unsafe &*ptr::from_addr_mut::<irl::Keep>(ka);
                let r = unsafe &mut *(ptr::from_addr_mut::<PRes>(ra) + c);
                let job = unsafe &*(ptr::from_addr_mut::<PJob>(ja) + r.job as usize);
                run_inputs(pk, kp, job, r);
            },
        );
    }
    // The parts of a job lie in input order: its first part with a failed run holds the least one.
    let mut c: usize = 0;
    for j in 0..jobs.len() {
        let mut done = false;
        while c < parts.len() && parts[c].job as usize == j {
            if !done && parts[c].at != NO_INPUT {
                done = true;
                pv.report_part(&jobs[j], &parts[c]);
            }
            c += 1;
        }
    }
}

/// Prove the contracts of every kept body of `keep` outside the modules `skip` marks, and print the
/// failures; `comp` holds each kept body's component of the direct calls (`ir::recursion::check_kept`).
/// `held[m]`: no obligation of module `m` failed. True when every obligation holds.
pub(package) fn check_kept(
    p: &loader::Package,
    keep: &irl::Keep,
    comp: &Vector<u32>,
    skip: &Vector<bool>,
    held: &mut Vector<bool>,
) bool {
    let mut pv = Prover::new(p, keep, p.prelude_lookup("Slice", true));
    pv.lower_shells();
    pv.scc = comp.clone();
    let n = keep.kept.len();
    if p.jobs == 1 || n < 2 {
        for k in 0..n {
            let kb = keep.kept.at(k);
            if kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] {
                pv.prove_kept(k);
            }
        }
    } else {
        // One prover per chunk of bodies, each body's reports in a container of its own; a walk
        // reads only the package, the keep and the main prover. The reports merge in body order and
        // then by position, as one prover orders them (`Errors::emit_ordered`).
        let mut outs = Vector::<diag::Errors>::with_capacity(n);
        for _k in 0..n {
            outs.push(diag::Errors::new());
        }
        let chunks = if n < p.jobs as usize * 4 {
            n
        } else {
            p.jobs as usize * 4
        };
        let pa = (p as *const loader::Package) as usize;
        let ka = (keep as *const irl::Keep) as usize;
        let ma = ((&pv) as *const Prover) as usize;
        let sa = (skip as *const Vector<bool>) as usize;
        let oa = outs.as_mut_ptr() as usize;
        // A chunk's cost is its bodies': each worker claims one chunk at a time.
        dpar::range_with(
            0..chunks,
            dpar::Options { schedule: dpar::Schedule::Dynamic, grain_size: 1 },
            |c: usize| {
                let pk = unsafe &*ptr::from_addr_mut::<loader::Package>(pa);
                let kp = unsafe &*ptr::from_addr_mut::<irl::Keep>(ka);
                let main = unsafe &*ptr::from_addr_mut::<Prover>(ma);
                let sk = unsafe &*ptr::from_addr_mut::<Vector<bool>>(sa);
                let mut w = Prover::new(pk, kp, main.slice);
                w.main = main;
                for k in c * n / chunks..(c + 1) * n / chunks {
                    let kb = kp.kept.at(k);
                    if kb.body.blocks.len() == 0 || sk[kb.body.module as usize] {
                        continue;
                    }
                    w.prove_kept(k);
                    let m = kb.body.module as usize;
                    unsafe *(ptr::from_addr_mut::<diag::Errors>(oa) + k) = replace(
                        w.errs.index_mut(m),
                        diag::Errors::new(),
                    );
                }
            },
        );
        for k in 0..n {
            let m = keep.kept.at(k).body.module as usize;
            if outs.at(k).errors.len() != 0 {
                pv.errs.index_mut(m).append(outs.index_mut(k));
            }
        }
        for m in 0..p.modules.len() {
            if pv.errs.at(m).errors.len() > 1 {
                pv.errs.index_mut(m).errors.sort_stable_in_place_by(
                    |x: &diag::Diagnostic, y: &diag::Diagnostic| {
                        return if x.start < y.start {
                            -1
                        } else if x.start > y.start {
                            1
                        } else {
                            0
                        };
                    },
                );
            }
        }
    }
    prove_exhaustive(&mut pv, p, keep, skip);
    let mut ok = true;
    for m in 0..p.modules.len() {
        held.set(m, pv.errs.at(m).errors.len() == 0);
        if pv.errs.at(m).errors.len() != 0 {
            ok = false;
            pv.errs.index_mut(m).finalize(&p.modules.at(m).source, &p.modules.at(m).file);
            pv.errs.at(m).log();
        }
    }
    return ok;
}
