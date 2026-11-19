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
import std::collections::heap as hp;
import ir::facts as fx;
import ir::layout as lay;
import ir::tailcall as tcl;
import module::loader as loader;
import build_system::manifest as bman;
import utils::errors as diag;
import utils::diag_codes as dc;
import prove::terms as *;
import prove::solver as *;

// The paths waiting in one body's walk.
const PATHS_MAX: usize = 4096;

// `v` as `n` entries of NONE.
fn fill(v: &mut Vector<u32>, n: usize) {
    v.clear();
    for _j in 0..n {
        v.push(NONE);
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
const fn bits_of<const B: usize>(x: Num<B>, w: u16) u64 {
    let b = x.limb(0);
    return if w >= 64 {
        b
    } else {
        b & (1u64 << w as u64) - 1
    };
}

// The value of the `w`-bit pattern `b` in a type of signedness `sg`.
const fn val_of<const B: usize>(b: u64, w: u16, sg: bool) Num<B> {
    let v = u64_val::<B>(b);
    if sg && w > 0 && (b >> (w - 1) as u64 & 1) != 0 {
        return v - Num::<B>::one().shl(w as usize);
    }
    return v;
}

// The values of terms under one assignment of the unknowns (the leaves): `val` for each term whose
// `stamp` is the current one, `ok` false where the value is not defined (an operation that traps).
struct Eval<const B: usize> {
    val: Vector<Num<B>>,
    stamp: Vector<u32>,
    ok: Vector<bool>,
    now: u32,
    stack: Vector<u32>,
    leaves: Vector<u32>,
    lo: Vector<Num<B>>,
    hi: Vector<Num<B>>,
    seen: Vector<u32>,
}

extend<const B: usize> Eval<B> {
    fn new() Eval<B> {
        return Eval::<B> {
            val: Vector::<Num<B>>::new(),
            stamp: Vector::<u32>::new(),
            ok: Vector::<bool>::new(),
            now: 0,
            stack: Vector::<u32>::new(),
            leaves: Vector::<u32>::new(),
            lo: Vector::<Num<B>>::new(),
            hi: Vector::<Num<B>>::new(),
            seen: Vector::<u32>::new(),
        };
    }

    // Size the tables for `n` terms and start a new assignment.
    fn begin(self: &mut Self, n: usize) {
        while self.val.len() < n {
            self.val.push(Num::<B>::zero());
            self.stamp.push(0);
            self.ok.push(false);
            self.seen.push(0);
        }
        self.now += 1;
    }

    const fn set(self: &mut Self, t: u32, v: Num<B>) {
        self.val.set(t as usize, v);
        self.ok.set(t as usize, true);
        self.stamp.set(t as usize, self.now);
    }

    // Whether term `t` is a leaf of evaluation: an unknown, or a value the walk does not take apart.
    const fn leaf(tm: &Terms<B>, t: u32) bool {
        let x = tm.at(t);
        if x.op == T_INT || x.op == T_BOOL {
            return false;
        }
        if x.op >= T_LT && x.op <= T_NE {
            return !(tm.is_int(x.a) && tm.is_int(x.b) || tm.is_bool(x.a) && tm.is_bool(x.b));
        }
        return x.op == T_VAR || x.op == T_CALL || x.op >= T_AGG && x.op != T_ORD && (!float_op(x.op) || x.op == T_FFMA || x.op == T_FMID || !Eval::<
            B
        >::host_op(tm, &x)) || x.op == T_REF;
    }

    // Whether float operation `x` reads and makes only `f32` and `f64` values, which the host computes.
    const fn host_op(tm: &Terms<B>, x: &Term<B>) bool {
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        if x.op == T_FKEY {
            return true;
        }
        let sw = tm.at(x.a).w;
        return if x.op == T_FLT || x.op == T_FLE || x.op == T_FEQ || x.op == T_FTOI {
            host_fw(sw, fd) != 0
        } else if x.op == T_FCVT {
            host_fw(x.w, fd) != 0 && host_fw(sw, x.k.limb(0) >> 32) != 0
        } else {
            host_fw(x.w, fd) != 0
        };
    }

    // The leaves under `roots`, in first-seen order, with their domains.
    fn collect(self: &mut Self, tm: &Terms<B>, roots: &Vector<u32>) bool {
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
            if Eval::<B>::leaf(tm, t) {
                if x.w == W_OTHER {
                    return false;
                }
                self.leaves.push(t);
                if x.w == W_BOOL {
                    self.lo.push(Num::<B>::zero());
                    self.hi.push(Num::<B>::one());
                } else {
                    switch tm.bounds(t) {
                        Some((l, h)) => {
                            self.lo.push(l);
                            self.hi.push(h);
                        },
                        None => {
                            return false;
                        },
                    }
                }
                continue;
            }
            if x.op == T_INT || x.op == T_BOOL {
                continue;
            }
            self.stack.push(x.a);
            if !unary_op(x.op) {
                self.stack.push(x.b);
            }
        }
        return false;
    }

    // The value of `t` under the current assignment of the leaves; None where an operation is not
    // defined (it traps) or leaves B bits.
    fn value(self: &mut Self, tm: &Terms<B>, t: u32) Option<Num<B>> {
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
            let unary = unary_op(x.op);
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
                Option::<Num<B>>::None
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

    fn apply(self: &Self, x: &Term<B>) Option<Num<B>> {
        let a = self.val[x.a as usize];
        let b = self.val[x.b as usize];
        // A float operation by the host's arithmetic; a NaN result has no one value.
        // (`leaf` keeps the other formats' operations.)
        let fd = x.k.limb(0) & 0xFFFFFFFF;
        if x.op == T_FKEY {
            return Some(Terms::<B>::key_of(a, x.w));
        }
        if x.op == T_FLT || x.op == T_FLE || x.op == T_FEQ {
            return switch fold_fcmp(x.op, pick(fd == FD32, 32u16, 64u16), fd, a.limb(0), b.limb(0)) {
                Some(v) => Some(wide::<B>(v as i64)),
                None => None,
            };
        }
        if x.op == T_FSQRT {
            let r = if x.w == 32 {
                f32::from_bits(a.limb(0) as u32).sqrt() as f64
            } else {
                f64::from_bits(a.limb(0)).sqrt()
            };
            return pick(
                r.is_nan(),
                Option::<Num<B>>::None,
                Some(u64_val::<B>(pick(x.w == 32, (r as f32).to_bits(), r.to_bits()))),
            );
        }
        if x.op == T_FRINT {
            let md = (x.k.limb(0) >> 32) as u16;
            let f = pick(x.w == 32, f32::from_bits(a.limb(0) as u32), f64::from_bits(a.limb(0)));
            let r = if md == FR_ROUND {
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
            return pick(
                r.is_nan(),
                Option::<Num<B>>::None,
                Some(u64_val::<B>(pick(x.w == 32, (r as f32).to_bits(), r.to_bits()))),
            );
        }
        if float_op(x.op) {
            let sf = pick(x.op == T_FCVT, x.k.limb(0) >> 32, fd);
            return fold_float(x.op, x.w, x.sg, x.k.limb(0), pick(sf == FD32, 32u16, 64u16), a, b);
        }
        let one = Num::<B>::one();
        let z = Num::<B>::zero();
        if x.op == T_ADD {
            return ck(a.checked_add(&b));
        }
        if x.op == T_SUB {
            return ck(a.checked_sub(&b));
        }
        if x.op == T_MUL {
            return ck(a.checked_mul(&b));
        }
        if x.op == T_NEG {
            return ck(z.checked_sub(&a));
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
            if !exact_w(x.w) {
                let (lo, hi) = Terms::<B>::range(x.w, x.sg);
                if q < lo || hi < q {
                    return None;
                }
            }
            return if x.op == T_DIV {
                Some(q)
            } else {
                switch ck(b.checked_mul(&q)) {
                    Some(bq) => ck(a.checked_sub(&bq)),
                    None => Option::<Num<B>>::None,
                }
            };
        }
        if x.w > 64 && (x.op == T_BAND || x.op == T_BOR || x.op == T_BXOR || x.op == T_BNOT || x.op == T_SHL || x.op == T_SHR) {
            return self.apply_wide(x, a, b);
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
            return Some(val_of::<B>(r, x.w, x.sg));
        }
        if x.op == T_BNOT {
            return Some(val_of::<B>(bits_of(a, x.w) ^ bits_of(Num::<B>::zero() - one, x.w), x.w, x.sg));
        }
        if x.op == T_SHL || x.op == T_SHR {
            if !x.k.is_zero() && !b.is_negative() && wide::<B>(x.w) <= b {
                // A wide shift past the width: 0, or -1 for a negative value shifted right.
                return Some(pick(x.op == T_SHR && x.sg && a.is_negative(), wide::<B>(-1), Num::<B>::zero()));
            }
            if b.is_negative() || wide::<B>(x.w) <= b {
                return None;
            }
            let c = b.to_i64() as u64;
            let p = bits_of(a, x.w);
            if x.op == T_SHL {
                return Some(val_of::<B>(bits_of(u64_val::<B>(p << c), x.w), x.w, x.sg));
            }
            if x.sg && a.is_negative() {
                // An arithmetic shift: floor division by 2^c.
                let d = one.shl(c as usize);
                return Some(a.div_euclid(&d));
            }
            return Some(val_of::<B>(p >> c, x.w, x.sg));
        }
        if x.op == T_CAST {
            return Some(val_of::<B>(bits_of(a, x.w), x.w, x.sg));
        }
        if x.op == T_ORD {
            return Some(wide::<B>(pick(a < b, -1i64, pick(a == b, 0i64, 1))));
        }
        if x.op == T_LT {
            return Some(wide::<B>((a < b) as i64));
        }
        if x.op == T_LE {
            return Some(wide::<B>((a <= b) as i64));
        }
        if x.op == T_EQ {
            return Some(wide::<B>((a == b) as i64));
        }
        if x.op == T_NE {
            return Some(wide::<B>((a != b) as i64));
        }
        if x.op == T_NOT {
            return Some(wide::<B>(a.is_zero() as i64));
        }
        if x.op == T_AND {
            return Some(wide::<B>((!a.is_zero() && !b.is_zero()) as i64));
        }
        if x.op == T_OR {
            return Some(wide::<B>((!a.is_zero() || !b.is_zero()) as i64));
        }
        return None;
    }

    // A bit operation or shift of `x`, wider than 64 bits, on the values `a` and `b`: on the
    // two's-complement patterns of `x.w` bits.
    fn apply_wide(self: &Self, x: &Term<B>, a: Num<B>, b: Num<B>) Option<Num<B>> {
        let m = Num::<B>::one().shl(x.w as usize);
        let p = a.rem_euclid(&m);
        let q = b.rem_euclid(&m);
        let r = if x.op == T_BAND {
            p & q
        } else if x.op == T_BOR {
            p | q
        } else if x.op == T_BXOR {
            p ^ q
        } else if x.op == T_BNOT {
            m - Num::<B>::one() - p
        } else {
            if b.is_negative() {
                return None;
            }
            if wide::<B>(x.w) <= b {
                if x.k.is_zero() {
                    return None;
                }
                return Some(pick(x.op == T_SHR && x.sg && a.is_negative(), wide::<B>(-1), Num::<B>::zero()));
            }
            let c = b.to_i64() as usize;
            if x.op == T_SHL {
                p.shl(c).rem_euclid(&m)
            } else if x.sg && a.is_negative() {
                // An arithmetic shift: floor division by 2^c.
                let d = Num::<B>::one().shl(c);
                return Some(a.div_euclid(&d));
            } else {
                p.shr(c)
            }
        };
        return Some(Terms::<B>::wrap(r, x.w, x.sg));
    }

    // Under the current assignment: 1 when every hypothesis holds and the goal does not (a
    // counterexample), 0 when the assignment satisfies the implication, 2 when a value is undefined.
    fn check(self: &mut Self, tm: &Terms<B>, hyps: &Vector<u32>, goal: u32) u8 {
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
    const fn assign(self: &mut Self, k0: u64, cands: &Vector<Num<B>>, cstart: &Vector<u32>) bool {
        self.now += 1;
        let mut k = k0;
        for j in 0..self.leaves.len() {
            if cands.len() == 0 {
                let span = (self.hi[j] - self.lo[j]).to_i64() as u64 + 1;
                let v = self.lo[j] + u64_val::<B>(k % span);
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

// Whether every element of `a` is one of `b`: a set of facts that leaves none of `a` out.
const fn within(a: &Vector<u32>, b: &Vector<u32>) bool {
    for j in 0..a.len() {
        if !b.contains(&a[j]) {
            return false;
        }
    }
    return true;
}

// Whether every element of sorted `a` is one of sorted `b`.
const fn sorted_within(a: &Vector<u32>, b: &Vector<u32>) bool {
    let mut k: usize = 0;
    for j in 0..a.len() {
        while k < b.len() && b[k] < a[j] {
            k += 1;
        }
        if k == b.len() || b[k] != a[j] {
            return false;
        }
    }
    return true;
}

// One path of the walk: the block it enters next (from block `from`), the value of each local it
// models (NONE: a fresh unknown at its first read), its conditions, and the body's `decreases` measure.
struct Path {
    state: Vector<u32>,
    pc: Vector<u32>,
    esc: Vector<u32>, // the locals a reference or pointer made on the path may reach
    aesc: Vector<u32>, // references to the inline arrays such a pointer may reach, those alone (`leak`)
    views: Vector<u64>, // escaped vectors lent only as `[]mut` views: local << 32 | the view
    lm: Vector<u64>, // per loop the path is in: header << 32 | its measure at the iteration's start
    pend: Vector<u64>, // the blocks of allocators' results no field holds yet: pointer << 32 | block
    ov: u32, // the path's ownership version (`held_atom`)
    mi: Vector<u32>, // the structs in memory the path opened across an allocator's call (`mi_dirty`)
    fresh: Vector<u32>, // the allocators' results the path has not written whole yet (`mi_fresh`)
    wrote: Vector<u32>, // the pointers the path wrote a struct with an invariant through (`mi_wrote`)
    ens: Vector<u32>, // the `ensures` clauses the path proved on its way to the return (`inv_return`)
    blk: u32,
    from: u32,
    m0: u32,
}

extend Path {
    // A path that holds nothing: a free slot of the walk's queue.
    fn empty() Path {
        return Path {
            state: Vector::<u32>::new(),
            pc: Vector::<u32>::new(),
            esc: Vector::<u32>::new(),
            aesc: Vector::<u32>::new(),
            views: Vector::<u64>::new(),
            lm: Vector::<u64>::new(),
            pend: Vector::<u64>::new(),
            ov: 0,
            mi: Vector::<u32>::new(),
            fresh: Vector::<u32>::new(),
            wrote: Vector::<u32>::new(),
            ens: Vector::<u32>::new(),
            blk: NONE,
            from: NONE,
            m0: NONE,
        };
    }

    fn copy(self: &Self) Path {
        return Path {
            state: self.state.clone(),
            pc: self.pc.clone(),
            esc: self.esc.clone(),
            aesc: self.aesc.clone(),
            views: self.views.clone(),
            lm: self.lm.clone(),
            pend: self.pend.clone(),
            ov: self.ov,
            mi: self.mi.clone(),
            fresh: self.fresh.clone(),
            wrote: self.wrote.clone(),
            ens: self.ens.clone(),
            blk: self.blk,
            from: self.from,
            m0: self.m0,
        };
    }
}

// A quantifier the walk reached (`Prover::quantifier`): its atom `q` stands for its truth, and its
// instances walk `E` again over the state it was reached in, with the binding set to a term.
struct QClo {
    cb: *const ir::CoreBody,
    cm: ModuleId,
    qi: u32, // the index in `cb.quants`
    state: Vector<u32>,
    mem: Vector<u32>, // the caller state of the frame it was reached in, when `has_mem`
    has_mem: bool,
    all: bool,
    lo: u32,
    hi: u32,
    k: u32, // the witness
    trig: Vector<u32>, // the terms of `E(k)` that take `k` as an operand (`triggers`)
    w: u16,
    sg: bool,
}

// The prover's own functions over sequences (`Prover::sqk`) and the modeled container methods.
const SQ_EMPTY: u64 = 1;
const SQ_LEN: u64 = 2; // a sequence's length, a `nat`
const SQ_AT: u64 = 3; // a sequence's element
const SQ_PUSH: u64 = 4;
const SQ_UPD: u64 = 5;
const SQ_SUB: u64 = 6;
const SQ_CAT: u64 = 7;
const SQ_VIEWV: u64 = 8; // the view of a vector's, a string's or a `str`'s value
const SQ_VIEWS: u64 = 9; // the view of a slice's value in a memory epoch
const SQ_VIEWA: u64 = 10; // the view of an array (its value, its length)
const SQ_VLEN: u64 = 11; // the length of a vector's or a string's value, a `usize`
const SQ_SLEN: u64 = 12; // the length of a slice, a `usize`
const SQ_EREF: u64 = 14; // a reference to an element of a vector (`T_MREF` of its local or slot, the index)
const SQ_SEREF: u64 = 15; // a reference to an element of a `[]mut T` (the slice, the index)
const SQ_VIEW: u64 = 16; // a `view()` call (`sq_kind`)
const SQ_STRV: u64 = 17; // a string literal's value: a function of its bytes (their sequence)
const SQ_BLOCK: u64 = 18; // `block(p)`: the block of an `@owned` field (`sq_kind`)
const SQ_TAKE: u64 = 19; // `s.take(n)`: `s.subrange(0, n)` (SQ_SUB)
const SQ_SKIP: u64 = 20; // `s.skip(n)`: `s.subrange(n, s.len())` (SQ_SUB)
const VK_LEN: u64 = 32;
const VK_INDEX: u64 = 34;
const VK_INDEX_MUT: u64 = 40;
const VK_AS_SLICE: u64 = 42;
const VK_SINDEX_MUT: u64 = 43;
const VK_SLEN: u64 = 44; // a view's `len`
const VK_SINDEX: u64 = 45; // a view's element read (`index`, `get`, `at`)
const VK_SHARE: u64 = 46; // `[]mut`'s `as_slice`
const VK_RANGE: u64 = 47; // a vector's or a view's `index_range` (`v[lo..hi]`), a shared view
const VK_RANGE_MUT: u64 = 48; // its `index_range_mut`, a `[]mut` view
const VK_SPTR: u64 = 57; // a `str`'s `ptr`: its pointer member

// The rounds of quantifier instances a goal gets (an instance may name a nested quantifier), and the
// terms each round instantiates a quantifier with.
const QUANT_ROUNDS: u32 = 3;
// The terms `op_facts` states facts of, and the terms of one operation and second operand it orders each
// one against.
const OP_TERMS: usize = 48;
// Why a check of a body with contracts is an obligation.
const NO_PANIC_NOTE: str = "a function with contracts proves that no operation of its body panics";
// The structs within structs `frozen` reads.
const FROZEN_DEPTH: u32 = 4;
// The members and the depth of the frozen aggregates an unknown value of is spelled as (`eta`).
const ETA_MAX: u64 = 32;
// The kinds of `add_defs_of`.
const DEFS_ALL: u8 = 0;
const DEFS_QUANTS: u8 = 1;
const DEFS_NEAR: u8 = 2;
const DEFS_REC: u8 = 3;
const DEFS_OPEN: u8 = 4; // DEFS_NEAR, but none of a term without unknowns (`max_cap()`): a bound's cases
// The most elements of an aggregate a read at an unknown index gets one case each of (`sel`).
const SEL_CASES: u32 = 32;
// The most disjunctions over a conjunction one goal splits (`holds_in`).
const SPLIT_PARTS: u32 = 16;
// The walk steps (blocks entered, over every path) of the exact walk of a body walked only for facts,
// before the merged walk (`prove_body`). In the compiler's build the exact walks for facts take at most
// 21,529 steps, but one that takes 161,043 (`memcmp_eq`), whose fact the merged walk keeps too.
const FACTS_WALK: u32 = 32768;
// The same for a body with obligations: ML-KEM's largest takes 49,213.
const PROOF_WALK: u32 = 262144;
// The walk steps per block of the merged walk (`merge_paths`): it visits each block about once (the
// compiler's build: at most 2.3 per block where it gives facts).
const MERGED_PER_BLOCK: u32 = 4;
// The most steps a stage of `holds_in` that most goals pass at once takes (`capped`).
const STAGE_STEPS: u32 = 200000;
// The solver steps of a check's fact (`note_check`): in the compiler build each one that holds takes at
// most 3.4k, and the 21 that fail took 25M, half of the build's solver steps.
const FACT_STEPS: u32 = 50000;
// The fact sets of the paths that proved one goal (`oblige`) that a later path's facts are checked
// against: each check scans them all, so a body of many paths (a merge after the exact walk's cap) would
// scan a list as long as its paths.
const PROVED_SETS: usize = 8;
// The solver steps of the check that an operation of a body without contracts cannot panic, which spares
// its unwind the invariants (`statement_in`): in the compiler build each one that holds takes at most 25k,
// and the 36 that fail at STAGE_STEPS took 6M, a quarter of the build's solver steps.
const PANIC_STEPS: u32 = 50000;
// The solver steps of an equality of sequences from its terms' definitions alone (`holds_at`): one that
// holds takes at most 47k in the compiler build and 3k in ML-KEM, where the ones that fail took 53M.
const SEQ_DEFS_STEPS: u32 = 50000;
// The steps of the last attempt at a goal over sequences (`holds`).
const SEQ_STEPS: u32 = 50000;
// The most steps a set of operation facts takes (`ops_imply`): the casts and remainders it states need
// more than a plain stage.
const OPS_STEPS: u32 = 800000;
// The terms `has_product` reads.
const PRODUCT_SCAN: u32 = 4096;
// The levels of a definition's disjunctions and conjunctions `prune_def` reads.
const PRUNE_DEPTH: u32 = 8;
// The steps of the check whether a path refutes a case of a call's pointer result (`ptr_split`).
const SPLIT_STEPS: u32 = 4000;
// The most parts of one fact `stated` reads.
const STATED_PARTS: u32 = 256;
// The most distinct subterms of a spec value that stands for its call (`small`).
const EXACT_TERMS: usize = 256;
const ETA_DEPTH: u32 = 3;
// The equalities with a constant `op_facts` reads per term (a type's masks: four).
const CONST_EQS: usize = 8;
const PEERS_MAX: usize = 8;
const QUANT_TERMS: usize = 32;
// The terms `instantiate` takes: those a trigger matches, every integer term, or those the last model
// puts in range; and the rounds of model-based instances (`model_instances`).
const QI_TRIG: u8 = 0;
const QI_WIDE: u8 = 1;
const QI_MODEL: u8 = 2;
const MODEL_ROUNDS: u32 = 4;
// The triggers of one quantifier (`triggers`), and the pairs of subterms one match or test reads
// (`matched`, `mentions`).
const TRIGGERS_MAX: usize = 16;
const MATCH_WORK: u32 = 256;

// One path through a contract chain.
// An integer leaf of a union member (`union_leaves`): its byte offset in the union, its bytes, its width,
// and its member keys from the union value, [k0, k0 + kn) of the key pool.
@derive(Copy)
struct UnionLeaf {
    off: i64,
    size: u32,
    w: u16,
    k0: u32,
    kn: u32,
}

struct Sub {
    state: Vector<u32>,
    conds: Vector<u32>,
    blk: u32,
}

// How a checked operation's result is modeled: OVF_PROVE proves the operation does not overflow and
// takes the exact value (a body with contracts, a contract expression); OVF_KEEP takes the exact
// value only where it fits and a fresh one otherwise; OVF_EXACT takes it with no proof (a spec
// function's definition, whose own proof covered each check on a path its `requires` admits).
const OVF_PROVE: u8 = 0;
const OVF_KEEP: u8 = 1;
const OVF_EXACT: u8 = 2;

// The integer operations the walk reads as terms (`wide_kind`): the wide integers', then the
// built-in integers' wrapping and rotating methods.
const WK_FROM: u8 = 1;
const WK_EQ: u8 = 2;
const WK_CMP: u8 = 3;
const WK_ADD: u8 = 4;
const WK_SUB: u8 = 5;
const WK_MUL: u8 = 6;
const WK_DIV: u8 = 7;
const WK_REM: u8 = 8;
const WK_AND: u8 = 9;
const WK_OR: u8 = 10;
const WK_XOR: u8 = 11;
const WK_NOT: u8 = 12;
const WK_SHL: u8 = 13;
const WK_SHR: u8 = 14;
const WK_WADD: u8 = 15;
const WK_WSUB: u8 = 16;
const WK_WMUL: u8 = 17;
const WK_WNEG: u8 = 18;
const WK_ROTL: u8 = 19;
const WK_ROTR: u8 = 20;
const WK_CLZ: u8 = 21;
// A float's classifications (`Prover::float_class`).
const FC_NAN: u8 = 1;
const FC_INF: u8 = 2;
const FC_FINITE: u8 = 3;
const FC_ZERO: u8 = 4;
const FC_NORMAL: u8 = 5;
const FC_SUB: u8 = 6;
const FC_NEG: u8 = 7;
const FC_POS: u8 = 8;

// The methods of `Float<E, F, FAMILY>` the walk reads as operations (`Prover::soft_kind`); a
// classification is SK_CLASS plus its FC_* code.
const SK_ADD: u8 = 1;
const SK_SUB: u8 = 2;
const SK_MUL: u8 = 3;
const SK_DIV: u8 = 4;
const SK_REM: u8 = 5;
const SK_SQRT: u8 = 6;
const SK_FMA: u8 = 7;
const SK_NEG: u8 = 8;
const SK_ABS: u8 = 9;
const SK_COPYSIGN: u8 = 10;
const SK_TRUNC: u8 = 11;
const SK_FLOOR: u8 = 12;
const SK_CEIL: u8 = 13;
const SK_ROUND: u8 = 14;
const SK_EVEN: u8 = 15;
const SK_EQ: u8 = 16;
const SK_CMP: u8 = 17;
const SK_IEQ: u8 = 18;
const SK_ILT: u8 = 19;
const SK_ILE: u8 = 20;
const SK_TO_RAW: u8 = 21;
const SK_FROM_RAW: u8 = 22;
const SK_FROM_F32: u8 = 23;
const SK_FROM_F64: u8 = 24;
const SK_TO_F32: u8 = 25;
const SK_TO_F64: u8 = 26;
const SK_CONVERT: u8 = 27;
const SK_FROM_UINT: u8 = 28;
const SK_FROM_INT: u8 = 29;
const SK_ZERO: u8 = 30;
const SK_NEG_ZERO: u8 = 31;
const SK_ONE: u8 = 32;
const SK_INF: u8 = 33;
const SK_NAN: u8 = 34;
const SK_MAX: u8 = 35;
const SK_MIN_POS: u8 = 36;
const SK_CLASS: u8 = 64;

// The SK_* operation of `Float`'s method named `n`, 0 for another name.
const fn soft_of(n: str) u8 {
    let names: [str; 36] = [
        "add",
        "sub",
        "mul",
        "div",
        "rem",
        "sqrt",
        "fma",
        "neg",
        "abs",
        "copysign",
        "trunc",
        "floor",
        "ceil",
        "round",
        "round_ties_even",
        "eq",
        "cmp",
        "ieee_eq",
        "ieee_lt",
        "ieee_le",
        "to_raw",
        "from_raw",
        "from_f32",
        "from_f64",
        "to_f32",
        "to_f64",
        "convert",
        "from_uint",
        "from_int",
        "zero",
        "neg_zero",
        "one",
        "infinity",
        "nan",
        "max_finite",
        "min_positive",
    ];
    for i in 0..36 {
        if names[i] == n {
            return (i + 1) as u8;
        }
    }
    let c = class_of(n);
    return pick(c != 0 && c != FC_NORMAL && c != FC_SUB && c != FC_POS, SK_CLASS + c, 0u8);
}

// The classification a float method named `n` asks (FC_*), 0 for another name.
const fn class_of(n: str) u8 {
    return if n == "is_nan" {
        FC_NAN
    } else if n == "is_infinite" {
        FC_INF
    } else if n == "is_finite" {
        FC_FINITE
    } else if n == "is_zero" {
        FC_ZERO
    } else if n == "is_normal" {
        FC_NORMAL
    } else if n == "is_subnormal" {
        FC_SUB
    } else if n == "is_sign_negative" || n == "is_negative" {
        FC_NEG
    } else if n == "is_sign_positive" {
        FC_POS
    } else {
        0
    };
}

// The value of encoding `bits` of a float of width `w` (at most 64) and format `fd` with at most 52
// fraction bits and 11 exponent bits, as an `f64`, which holds it exactly.
const fn soft_value(bits: u64, w: u16, fd: u64) f64 {
    let m = fd & 0xFFFF;
    let e = w as u64 - 1 - m;
    let bias = (1i64 << (e - 1) as i64) - 1;
    let ex = (bits >> m & (1u64 << e) - 1) as i64;
    let fr = bits & (1u64 << m) - 1;
    let neg = (bits >> (w - 1) as u64 & 1) != 0;
    let fo = (fd & FD_FINITE) != 0;
    let top = ex == (1i64 << e as i64) - 1;
    let mut v = if fo && top && fr == (1u64 << m) - 1 || !fo && top && fr != 0 {
        f64::NAN
    } else if !fo && top {
        f64::INFINITY
    } else {
        // (hidden bit + fraction) * 2^(exponent - bias - m), the subnormals' exponent being 1.
        let sig = pick(ex == 0, fr, fr | 1u64 << m) as f64;
        let k = ex.max(1) - bias - m as i64;
        let mut p = sig;
        for _i in 0..k.abs() {
            p = pick(k < 0, p * 0.5, p * 2.0);
        }
        p
    };
    if neg {
        v = -v;
    }
    return v;
}

// The format code (`Terms`) of the built-in float of width `fw`.
const fn host_fd(fw: u16) u64 {
    return pick(fw == 32, FD32, FD64);
}
// Whether the blocks of body `cb` reachable from its entry hold a cycle (a loop): a depth-first walk
// meets a block still on its stack. Block numbers follow no order.
fn has_cycle(cb: &ir::CoreBody) bool {
    let n = cb.blocks.len();
    // 0 unseen, 1 on the stack, 2 done.
    let mut mark = Vector::<u8>::with_capacity(n);
    mark.resize_default(n);
    // Each entry: a block and the index of its next successor.
    let mut stack = Vector::<u64>::with_capacity(n);
    let mut succ = Vector::<u32>::new();
    stack.push(cb.entry as u64 << 32);
    mark.set(cb.entry as usize, 1);
    // Each block enters once and each successor edge is taken once.
    for _k in 0..n * 4 + cb.switch_pool.len() * 2 + 2 {
        if stack.len() == 0 {
            return false;
        }
        let top = stack[stack.len() - 1];
        let (blk, at) = ((top >> 32) as u32, (top & 0xFFFFFFFFu64) as u32);
        let t = cb.blocks.at(blk as usize).term;
        succ.clear();
        if t.kind == ir::TM_GOTO || t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP || t.kind == ir::TM_SWITCH {
            succ.push(t.t0);
        }
        if t.kind == ir::TM_SWITCH {
            for j in t.sw_start..t.sw_start + t.sw_len {
                succ.push((cb.switch_pool[j as usize] & 0xFFFFFFFFu64) as u32);
            }
        }
        if at as usize >= succ.len() {
            mark.set(blk as usize, 2);
            let _ = stack.pop();
            continue;
        }
        stack.set(stack.len() - 1, top + 1);
        let nx = succ[at as usize];
        if nx as usize >= n {
            continue;
        }
        if mark[nx as usize] == 1 {
            return true;
        }
        if mark[nx as usize] == 0 {
            mark.set(nx as usize, 1);
            stack.push(nx as u64 << 32);
        }
    }
    // The walk ran out of steps: treat the body as one that may loop.
    return true;
}

// The integer leaves of one union member `union_leaves` reads.
const UNION_LEAVES: usize = 64;
// The terms `call_congruence` visits, and the pairs of applications it tries.
const CONG_NODES: u32 = 4096;
const CONG_PAIRS: u32 = 8;
// The pointer offsets (`p + n`) and the aggregates down a pointer's target is found through (`ptr_target`).
const PTR_DEPTH: u32 = 8;
// The depth `decide` rewrites a goal to, and the equalities of booleans `bool_stated` follows.
const DECIDE_DEPTH: u32 = 16;
const BOOL_STATED: u32 = 3;
// The definition `defs` anchors on term `t` (`def_of`), NONE for none.
fn match_def(def_of: &Map<u32, u32>, defs: &Vector<u32>, t: u32) u32 {
    return switch def_of.get(&t) {
        Some(i) => defs[(*i) as usize],
        None => NONE,
    };
}

// Ownership versions (`Prover::ov`): their kinds, and the versions of blocks no body holds: a value's
// outside its struct's file (`inv_fact`), memory's (a struct read through a raw pointer).
const OV_BASE: u8 = 0;
const OV_REMOVE: u8 = 1;
const OV_ADD: u8 = 2;
const OV_VALUE: u32 = 0xFFFFFFF0;
const OV_MEM: u32 = 0xFFFFFFF1;
// The key of `held` atoms beside the implementor's type key, and of a version beside a spec call's key.
const HELD_KEY: u64 = 0x48454C4400000000;
// `rc_share(p, k, n)` atoms, the unit counts `nsh(p, k, v)`, and the per-entry terms of a count's step.
const SHARE_KEY: u64 = 0x5348415200000000;
const NSH_KEY: u64 = 0x4E53480000000000;
const DSH_KEY: u64 = 0x4453480000000000;
const OV_KEY: u64 = 0x4F56000000000000;
const SRC_REF: u32 = 0x80000000;
const SRC_REQ: u32 = 0x40000000;
const SRC_RES: u32 = 0x20000000;
const SRC_LOC: u32 = 0x10000000;
// A value a call is given from memory (`arg_foreign`): its claims are distinct from each other alone, as a
// raw pointer may reach a value another source holds.
const SRC_MEM: u32 = 0x08000000;
// A loop's invariants at its header: their claims are distinct (`loop_apart` proved it where they were
// established), but any other source's may be among them, as memory's.
const SRC_LOOP: u32 = SRC_MEM | 0x04000000;

// The nesting of the branch splits `factor_parts` makes.
const FACTOR_DEPTH: u32 = 16;
const WK_CTZ: u8 = 22;

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
struct PDim<const B: usize> {
    l: u32,
    kind: u8,
    by_ref: bool,
    lo: Num<B>,
    n: u64,
    count: Num<B>, // `n`, exact: `n` stops at NO_INPUT
    w: u16,
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
struct PJob<const B: usize> {
    k: usize,
    dims: Vector<PDim<B>>,
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
const fn share<const B: usize>(job: &PJob<B>) u64 {
    return PE_STEPS / job.inputs;
}

// The body under proof (`b`, its module `m`) and what its walk reads.
struct Prover<const B: usize> {
    p: *const loader::Package,
    keep: *const irl::Keep,
    slice: loader::LookupHit, // the prelude's `Slice`
    wuint: loader::LookupHit, // the prelude's `UInt` and `Int` (`ty_of`, `wide_kind`)
    wint: loader::LookupHit,
    wcore: loader::LookupHit, // an item of the prelude's `core` module, which extends the built-in integers
    wflt: loader::LookupHit, // the prelude's `Float` (`soft_fmt`, `soft_kind`)
    walloc: loader::LookupHit, // the prelude's `Allocator` interface (`is_owns`)
    wshare: loader::LookupHit, // the prelude's `rc_share` and `rc_units` (`share_atom`, `nsh`)
    wunits: loader::LookupHit,
    wpre: loader::LookupHit, // the prelude's `pre_of` and `pre_any` (`pre_value`)
    wpre_any: loader::LookupHit,
    // The function items the walk named as values: term -> index; per index the item and its generic
    // bindings (`fn_item`).
    fn_items: Map<u32, u32>,
    fn_defs: Vector<DefId>,
    fn_binds: Vector<Vector<u64>>,
    // Counted shares. `sh_p`: share atom -> block << 32 | version (as `held_p`); `sh_kn`: atom -> counter
    // << 32 | units; `sh_mode`: the atom walks (`held_g_at`, `held_in`) find share atoms, not held ones;
    // `ov_take_sh`: the share atoms a call takes, with claim guards; `sh_seen`: the units a call gives
    // (block, counter, units); per version, the units its REMOVE took (`sh_tk`: atom, guard) and its ADD
    // gave (`sh_gv`); the counts made before their version's units were known (`nsh_wait`).
    sh_p: Map<u32, u64>,
    sh_kn: Map<u32, u64>,
    ctr_tmp: Map<u32, u32>, // a temporary that holds a counter field's address: that place (`ctr_scan`)
    ctr_ty: Map<u64, bool>, // module << 32 | struct type: whether it has counter fields (`counted`)
    sh_mode: bool,
    ov_take_sh: Vector<u32>,
    sh_seen: Vector<u32>,
    sh_tk: Map<u32, Vector<u32>>,
    // Per removal, that the blocks it took were held where their clauses claim them (`ov_remove`): the
    // facts that reach the versions before it, for a goal that fails without them (`holds_at`).
    ov_had: Vector<u32>,
    sh_gv: Map<u32, Vector<u32>>, // (atom, guard) pairs as `sh_tk`
    nsh_wait: Vector<u32>,
    line_mod: u32, // the module whose line starts `line_starts` holds (`source_line`), NONE before one
    line_starts: Vector<u32>,
    tm: Terms<B>,
    sv: Solver<B>,
    // The facts the walk derives for a division or a shift by a constant (`quotient`, `shifted`),
    // which `holds` adds to a goal's facts only when it fails without them.
    derived: Map<u32, bool>,
    fx: fx::Facts,
    pw: u16, // the width of `usize`, which lengths have
    // The sizes of element types (`len_cap`).
    lsv: lay::Svc,
    errs: Vector<diag::Errors>, // per module
    failed: Map<u64, bool>, // the obligations already reported, per body
    proved: Map<u32, Vector<Vector<u32>>>, // per goal, the facts (sorted) of each path that proved it
    held_alt: Map<u32, Vector<u32>>, // an allocator's held atom: the inner allocators' atoms it falls back from
    pwrites: Map<u64, u64>, // callee -> `param_writes`
    // The functions whose kept bodies the current job read (`kept`, `param_writes`, `mutual`), as `module
    // << 32 | node`, in order (`take_reads`); `rd_memo` keeps the ones an answer of `ends` or
    // `mentions_owns` read, which a later job's memo hit reads again.
    rd: UnsafeCell<Vector<u64>>,
    rd_on: bool, // whether `note_read` records: `check_kept`'s jobs, whose reads it takes
    rd_memo: Map<u64, Vector<u64>>,
    b: *const ir::CoreBody,
    m: ModuleId,
    // The place each `&mut T` parameter of the body under proof refers to: a local of its own past the
    // body's locals (a slot), of type `slot_ty[j]` for slot `nlocals + j`; the parameter holds its
    // `T_MREF`. The reference is exclusive: only it reaches the place, until it leaks (`leak`).
    slot_ty: Vector<TypeId>,
    slot_of: Vector<u32>, // per local of the body: its slot when it is such a parameter, else NONE
    // The references to members (`T_PREF`, `place_ref`), per entry: the local or slot, its type and that
    // type's module, and the members' keys, types and the types' modules in `pref_key`, `pref_ty` and
    // `pref_km` from `pref_at`, `pref_n` of them.
    pref_tg: Vector<u32>,
    pref_tgty: Vector<TypeId>,
    pref_m: Vector<ModuleId>,
    pref_at: Vector<u32>,
    pref_n: Vector<u32>,
    pref_key: Vector<u32>,
    pref_ty: Vector<TypeId>,
    pref_km: Vector<ModuleId>,
    pref_by: Map<u64, u32>, // an entry per hash of its local or slot and keys (`pref_new`)
    nlocals: u32,
    // Per local: a temporary read once, as an argument of a call that cannot keep a reference (its
    // results and its other arguments hold none that could): a `&mut` of a local it holds lends the
    // local for the call only (`scan_tracked`). `dest_tmp`: the whole local the statement under walk
    // writes, NONE else.
    scoped: Vector<bool>,
    scoped_in: Map<u32, u32>, // a struct temporary lent to one call: the local its scoped `&mut` borrows
    lazy: Vector<bool>, // the locals of member references the walk follows, whose target escapes only with them (`scan_lazy`)
    dest_tmp: u32,
    tracked: Vector<bool>, // the locals the walk models by value
    is_mem: Vector<bool>, // the modeled locals a reference or pointer may change (`scan_tracked`)
    cell_tmp: Vector<bool>, // the shared borrows of a struct that one call reads alone (`cell_read`)
    conf_memo: Map<u64, u64>,
    refine_subst: Vector<u64>, // `Self` of the interface `refine` holds, as the conformance's type
    havoc_idx: bool, // `update` writes any element where a place indexes (`havoc_write`)
    cohd: Map<u32, bool>, // the union values whose facts `union_coherence` made
    in_cong: bool, // `call_congruence` runs: its operand proofs try no congruence // (interface spec function, type declaration) -> its conformance's definition (`spec_conf`)
    vborrow: Map<u32, bool>, // the borrows only a container's view call reads (`sq_effect` escapes them)
    in_vborrow: bool, // the statement walked is one of `vborrow`
    mem_list: Vector<u32>,
    esc: Vector<u32>, // the walked path's `Path.esc`, while `run_block` walks it
    aesc: Vector<u32>, // the walked path's `Path.aesc`
    views: Vector<u64>, // the walked path's `Path.views`
    pend: Vector<u64>, // the walked path's `Path.pend`
    me: u32, // the kept index of the body under proof
    owner: DefId, // the function of the body under proof: its type parameters name types (`rigid`)
    skip_recv: bool, // `call_event`: the call's receiver reaches no memory (`alloc_event`)
    fn_dec: bool, // the body's function has a `decreases` measure
    ptr_cast: bool, // the body casts a value to a pointer
    // The state a callee frame's references to the caller's locals read, null outside a frame.
    mem: *const Vector<u32>,
    site_of_chain: Vector<u32>, // block -> the contract site whose chain starts there
    site_of_pred: Vector<u32>, // block -> the contract site it enters
    // Ghost code: the body is a spec function's or a lemma's (`ghost_fn`), a block lies in a ghost site
    // (`gblk`, `ir::is_ghost_site`), the walk is in either (`in_ghost`). Ghost code never runs: each
    // of its checks is an obligation, and nothing follows from one passing.
    ghost_fn: bool,
    gblk: Vector<bool>,
    in_ghost: bool,
    // A `define` of a `const fn` over constants (`call_value`): only the value of one returning path
    // counts, as the body may panic where a spec function may not.
    closed_def: bool,
    // The body has contract clauses: each check of its own walk is an obligation (no operation panics).
    no_panic: bool,
    // The accesses to `@owned` blocks the walk read since the last check (`own_check`): the index's term,
    // the block's and the element size's, three entries each.
    own_chk: Vector<u32>,
    // The prelude's `Allocator`; the allocations of the body's walk: per result term (`alloc_of`), its
    // record in `alloc_rec` (the kind AK_*, the size's term, the block it moves for a `realloc`).
    allocl: loader::LookupHit,
    globall: loader::LookupHit, // the prelude's `Global` (`global_alloc`)
    // The prelude's `Free` interface: its `free` ends its receiver's life (`inv_scan`).
    freel: loader::LookupHit,
    alloc_of: Map<u32, u32>,
    alloc_rec: Vector<u32>, // per allocator call: kind, size, old block, direction, and the size's product (`size_product`)
    // A call of the allocator's: its memory event leaves the `@owned` blocks (`mem_event_of`).
    keep_own: bool,
    // The locals and slots of the body under proof whose type has an invariant its file proves (`inv_scan`).
    inv_locs: Vector<u32>,
    inv_dead: Vector<u32>, // the locals whose storage starts in the loop: at its back edge they hold no value
    // The slot of the receiver of the `Free::free` body under proof, else NONE (`inv_scan`).
    inv_end: u32,
    // The body's `panics if` conditions at its entry, or'ed (`own_site`), NONE without one: its no-panic
    // obligations hold where it is false.
    pan_cond: u32,
    // In a refinement walk, the interface method's `panics if` at the entry, NONE without one.
    refine_pan: u32,
    // Per local and slot of the body under proof: its code reads the pointer of an `@owned` field of it
    // (`own_scan`), so a memory event may reach the block.
    own_exp: Vector<bool>,
    // The definitions of the spec function calls the body's walk made (`define`), facts of every
    // obligation; the calls defined; the depth of definition walks, whose calls stay opaque.
    defs: Vector<u32>,
    def_of: Map<u32, u32>, // a defined call -> its index in `defs`
    res_of: Map<u32, bool>, // the calls' results: a member of one left a body, so it satisfies its invariant
    defined: Map<u32, bool>,
    unfold: u32,
    // The quantifiers the body's walk reached: per atom its closure (`qclo`, by `qof`); the instances
    // made, (atom << 32 | term) -> the fact.
    qclo: Vector<QClo>,
    qof: Map<u32, u32>,
    qinst: Map<u64, u32>,
    qdef: Map<u32, bool>, // the witnesses' facts
    seld: Map<u32, bool>, // the terms whose facts `sel`, `index_key` and the sequences made
    // Whether no value of a type holds a cell (`no_cell`), by module << 32 | type, for the build: the
    // struct whose generic parameters the type may name (NODE_NONE for none) << 1 | the result. A type's
    // members do not change while the proofs run.
    cell_free: Map<u64, u64>,
    ptrd: Map<u32, bool>, // the pointers whose null and address facts are made (`ptr_addr`, `ptr_offset`)
    seqeqs: Vector<u32>, // each equality of sequences `seq_ext` made: the equality, then its two sides
    seqwit: Map<u32, u32>, // each equality of sequences no goal named yet: its witness (`goal_witnesses`)
    seq_inst: bool, // `instantiate` adds the elements' equalities of the equalities of sequences (`holds_in`)
    ends_memo: Map<u64, bool>, // `ends` of each function asked
    sref: Vector<u32>, // the values of the body's shared reference parameters (`deref`)
    inv_goal: bool, // the goal under proof is a struct's invariant (`inv_need`, `holds`)
    inv_terms: Map<u32, bool>, // the terms of struct invariants (`inv_of`)
    // The views of the containers' values the modeled methods made (`view_v`), and of slices per
    // memory epoch (`view_s`, key slice << 32 | epoch).
    vdef: Map<u32, u32>,
    // The type arguments of the generic spec function being unfolded (`define`): pairs (parameter's
    // module << 32 | its declaration, the argument's module << 32 | its type).
    subst: Vector<u64>,
    // The spec functions being unfolded (`define`), module << 32 | node; per definition with one path and
    // no `requires`, its value (`exact`): the call is that value.
    unfolding: Vector<u64>,
    exact: Map<u32, u32>,
    // Per such call whose value names a quantifier (which stays the call: each call has its own atom),
    // that value: the quantifier stages read it where the call stands (`instantiate`).
    qvalue: Map<u32, u32>,
    // Per aggregate `eta` spelled, the unknown value it spells: a member at an unknown place is that
    // value's.
    eta_src: Map<u32, u32>,
    // The lengths `len_cap` bounded.
    capd: Map<u32, bool>,
    // The spec function calls `define` gave a definition.
    specd: Map<u32, bool>,
    // The calls of recursive spec functions (a `decreases` clause) `define` met.
    recd: Map<u32, bool>,
    parts: u32, // the disjunctions `holds_in` split for the current goal
    // The sequences a spec function's result `r` may equal (its body's returns, `define`): r -> start
    // << 32 | count in `alias_pool`. An element read of `r` reads them too (`seq_at`).
    alias: Map<u32, u64>,
    alias_pool: Vector<u32>,
    // The paths of a spec function's sequence or number `r` (`define`): r -> start << 32 | count in
    // `spec_pool`, each path << 32 | the value it returns (`decide`).
    spec_leaves: Map<u32, u64>,
    spec_pool: Vector<u64>,
    seqw: Map<u32, u32>, // each equality of sequences `seq_ext` made: its elements' width << 1 | signed
    deciding: bool, // `decide` runs: the checks of its paths decide no goal of their own
    // The pointer a call returns, by its `ensures` (`ptr_defs`): guard << 32 | pointer per case; the
    // call's escapes start at `pdef_esc` (`esc` << 32 | `aesc` lengths).
    pdef: Vector<u64>,
    pdef_esc: u64,
    // The structs with an invariant this block wrote through a raw pointer, to prove before its terminator
    // (`mi_close`): pointer, the type's module, the type; `mi_next`: the write `write_place` forwards.
    mi_dirty: Vector<u32>,
    // The walked path's `Path.fresh`: blocks of uninitialized bytes, whose value satisfies no invariant
    // until a write of the whole value.
    mi_fresh: Vector<u32>,
    // The walked path's `Path.wrote`: a write through one of them opened its struct and gave its blocks,
    // so its `dealloc` opens it no more (`AK_DEALLOC`).
    mi_wrote: Vector<u32>,
    // The path condition and span of the assignment `write_place` writes (`mi_close_at`), null for another
    // write.
    wpc: *mut Vector<u32>,
    wsp: tok::Span,
    mi_next: Vector<u32>,
    // Linear ownership: an `Allocator::owns` atom also holds `held` in the walked path's ownership version
    // `ov` (`held_atom`). A version is BASE (unknown), REMOVE (`ov_prev` without the blocks of the pointers
    // `ov_ps[ov_pst..+ov_psn]`) or ADD (`ov_prev` with those blocks, `ov_psn` NONE until a call's clauses
    // are made); `ov_col`: the version whose atoms a call's clauses name are gathered (`ov_seen`).
    ov: u32,
    ov_col: u32,
    ov_seen: Vector<u32>,
    ov_kind: Vector<u8>,
    ov_prev: Vector<u32>,
    ov_pst: Vector<u32>,
    ov_psn: Vector<u32>,
    ov_ps: Vector<u32>,
    held_p: Map<u32, u64>, // a held atom: its pointer << 32 | its version
    held_k: Map<u32, u64>, // a held atom: its allocator's key (`alloc_key`)
    ov_defd: Map<u32, bool>,
    ov_pre: u32, // the version before the walked call's or drop's (`inv_resume`)
    recv_pre: u32, // `free`'s receiver before the walked call or drop (`inv_resume`), else NONE
    ov_terms: Map<u64, u32>,
    ov_fr: Map<u32, u64>, // a framed term: the term of its earlier version << 32 | the side (`ov_frame`)
    fr_depth: u32,
    inv_split: u32, // the depth of the invariant goals proved by conjuncts (`holds_at`)
    ptr_apart: Map<u32, Vector<u32>>, // a pointer: the distinctness facts of its blocks (`src_mark`)
    held_by_ptr: Map<u32, Vector<u32>>, // a pointer: its held atoms (`held_atom`)
    claims_of: Map<u32, Vector<u32>>, // a stated fact: `guard ==> atom` of each atom it claims (`claims`) // a version-keyed term by its key without the version, and the version (`ov_frame`)
    ov_take: Vector<u32>, // the held atoms a call's `requires` and arguments' invariants name (`held_in`)
    own_alloc: u64, // the type key of the allocator whose conformance's method is under proof, else 0
    // The source of the held atoms the entry assumes (`ov_src`: a parameter, SRC_REF set for a shared one,
    // or SRC_REQ and a `requires` clause): atoms of two sources hold distinct blocks (`held_atom`).
    ov_src: u32,
    src_tab: Map<u32, Vector<u32>>, // per version, its sourced claimed atoms: atom, guard, source
    // A call's taken atoms with their sources (`ov_name`): a `requires` clause's must be distinct from
    // the others' (`ov_apart`).
    tk_atoms: Vector<u32>,
    tk_src: Vector<u32>,
    // The atoms a call gives (its ADD version's, `ov_col`) with their sources: the clauses and the result
    // (SRC_RES), or an argument's value.
    owns_d: Map<u64, bool>, // memo of `is_owns`
    owns_m: Map<u64, u8>, // memo of `mentions_owns`: 1 no, 2 yes, 3 being computed
    mi_seen: Map<u32, bool>, // the loads `read_prefix` gave their struct's invariant
    // The statics with an invariant the walk read or wrote: address term (`static_addr`) -> module << 32 |
    // its invariant's function; the writes of another file's ones (`st_err`), to report at the statement.
    // The shared parameters of struct types with invariants, each with its source: the blocks they lend
    // are the caller's (`lent_now`, `lent_take`).
    ent_ref: Vector<u32>,
    st_inv: Map<u32, u64>,
    st_decl: Map<u32, NodeId>, // address -> the static's declaration
    st_err: Vector<u32>,
    st_list: Vector<u32>, // the statics of this file the body read or wrote: address, the local's type
    mi_lds: Vector<u32>, // the block's loads of such structs: pointer, module, type, value
    mi_fwd: Map<u32, u32>, // a load a write through its pointer forwards: the written value (`deref`)
    sdef: Map<u64, u32>,
    // `std::spec::seq` (-1 when the build has not loaded it) and its `Seq`; the prelude's containers.
    seqm: i32,
    // `std::spec::quant::trigger` (NODE_NONE when the build has not loaded it), and the triggers its calls
    // give the quantifier whose body the walk evaluates (`utrig_on`).
    trigm: i32,
    trigd: NodeId,
    utrig: Vector<u32>,
    utrig_on: bool,
    seqd: NodeId,
    // `std::crypto::secret` (-1 when the build has not loaded it) and its `Secret`.
    secm: i32,
    secd: NodeId,
    vecl: loader::LookupHit,
    strl: loader::LookupHit,
    smut: loader::LookupHit,
    strv: loader::LookupHit, // the prelude's `str`
    chain_ovf: u8, // the overflow model of a chain walk: OVF_PROVE, or OVF_EXACT in a definition
    chain_depth: u32, // the depth of chain walks (a clause, a definition): `derive` anchors their facts
    exact_body: bool, // the body under proof has a local of type `int` or `nat`
    ovf: u8,
    steps: u32,
    over: bool, // the body spent its budget
    // The paths to walk (`push_path`, `pop_path`): the exact walk's stack (depth first); while `merging`,
    // the slots of a max-heap of keys, the inverted reverse postorder of the path's block << 32 | the
    // push count's low 20 bits << 12 | the slot, so the walk takes the earliest block first and every
    // path into a join reaches it before the join is walked; the free slots; the slot of the latest
    // path queued per block, which an arriving path merges into (`merge_paths`); the paths queued; the
    // pushes.
    work: Vector<Path>,
    work_q: hp::BinaryHeap<u64>,
    work_free: Vector<u32>,
    work_at: Map<u32, u32>,
    work_n: u32,
    work_seq: u32,
    merging: bool, // the walk after the exact one spent its budget: it merges paths (`push_path`)
    walk_cap: u32, // the walk steps of a walk for facts or a merged walk (`spend`): FACTS_WALK, or MERGED_PER_BLOCK per block
    ev: Eval<B>,
    vname: Map<u32, u32>, // a parameter's unknown -> the parameter's local, for counterexamples
    pvars: Map<u64, u32>, // a const generic parameter (module << 32 | node) -> its unknown
    // The facts for the build (`check_kept`): the bounds checks of the body under proof that held on
    // each path the walk reached them (`chk_ok`) and those that did not on one (`chk_dead`), by rvalue;
    // `facts_on`: the body may give facts. `facts`: kept index << 32 | rvalue of each proved check.
    chk_ok: Map<u32, bool>,
    chk_dead: Map<u32, bool>,
    facts_on: bool,
    // The walk only gathers facts: the body has nothing to prove, so a spent budget gives no facts, no error.
    facts_only: bool,
    facts: Vector<u64>,
    // The refinement walk of a conformance's method: only its `OB_REFINE` obligations count, and
    // `refine` holds the interface's contracts (null: the interface's method has none).
    refining: bool,
    refine_all: bool, // the refinement walk is the method's only one: every obligation is its (`prove_kept`)
    refine: *const ir::CoreBody,
    sh: *const Shared, // the package's, which `check_kept` holds
}

// What every prover of a package reads: the contracts of the interfaces' methods without a body
// (`ir::Lowerer::lower_fn` lowers their clauses only), keyed like `irl::Keep`, and per kept body its
// component of the direct-call graph (`ir::recursion`), NONE: none.
struct Shared {
    shells: Vector<ir::CoreBody>,
    shell_ix: Map<u64, u32>,
    scc: Vector<u32>,
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
const OB_GHOST: u64 = 10; // a check of ghost code
const OB_PATTERN: u64 = 11; // a conversion into a pattern type
const OB_PANIC: u64 = 12; // a check of a body with contracts, which proves that none of its operations panics
const OB_TYPE_INV: u64 = 13; // a struct's invariant where its value leaves a body of the struct's file
const OB_BLOCK: u64 = 14; // an index into an `@owned` field's block
const OB_COUNTER: u64 = 15; // a step of an `@counter` field (`count_step`)

// The operations of a counter step (`count_step`): a plain store, an atomic add, sub, compare-and-swap
// or store, and the write of a whole struct.
const CS_PLAIN: u8 = 0;
const CS_ADD: u8 = 1;
const CS_SUB: u8 = 2;
const CS_CAS: u8 = 3;
const CS_STORE: u8 = 4;
const CS_INIT: u8 = 5;

// The counter a lock's unit counts: LOCK_UNIT + the locked counter (`count_step`).
const LOCK_UNIT: u32 = 64;
// A projection that indexes a raw pointer (`ptr_index`): none, the block of an `@owned` field, memory.
const PI_NONE: u8 = 0;
const PI_OWNED: u8 = 1;
const PI_MEM: u8 = 2;
// A call of an allocator's method (`alloc_call`): none, `alloc`, `realloc`, `dealloc`.
const AK_NONE: u32 = 0;
const AK_ALLOC: u32 = 1;
const AK_REALLOC: u32 = 2;
const AK_DEALLOC: u32 = 3;
// The depth of definitions of spec function calls over constants (`call_value`).
const UNFOLD_MAX: u32 = 64;
// The depth to which a spec function's body unfolds the calls of other spec functions (none that is being
// unfolded: recursion unfolds once).
const NEST_MAX: u32 = 8;

extend<const B: usize> Prover<B> {
    fn new(p: &loader::Package, keep: &irl::Keep, slice: loader::LookupHit) Prover<B> {
        let mut errs = Vector::<diag::Errors>::with_capacity(p.modules.len());
        for _m in 0..p.modules.len() {
            errs.push(diag::Errors::new());
        }
        return Prover::<B> {
            p: p,
            keep: keep,
            slice: slice,
            wuint: p.prelude_lookup("UInt", true),
            wint: p.prelude_lookup("Int", true),
            wcore: p.prelude_lookup("UnsafeCell", true),
            wflt: p.prelude_lookup("Float", true),
            walloc: p.prelude_lookup("Allocator", true),
            wshare: p.prelude_lookup("rc_share", false),
            wunits: p.prelude_lookup("rc_units", false),
            wpre: p.prelude_lookup("pre_of", false),
            wpre_any: p.prelude_lookup("pre_any", false),
            fn_items: Map::<u32, u32>::new(),
            fn_defs: Vector::<DefId>::new(),
            fn_binds: Vector::<Vector<u64>>::new(),
            sh_p: Map::<u32, u64>::new(),
            sh_kn: Map::<u32, u64>::new(),
            ctr_tmp: Map::<u32, u32>::new(),
            ctr_ty: Map::<u64, bool>::new(),
            sh_mode: false,
            ov_take_sh: Vector::<u32>::new(),
            sh_seen: Vector::<u32>::new(),
            sh_tk: Map::<u32, Vector<u32>>::new(),
            ov_had: Vector::<u32>::new(),
            sh_gv: Map::<u32, Vector<u32>>::new(),
            nsh_wait: Vector::<u32>::new(),
            line_mod: NONE,
            line_starts: Vector::<u32>::new(),
            tm: Terms::<B>::new(),
            sv: Solver::<B>::new(),
            derived: Map::<u32, bool>::new(),
            fx: fx::Facts::new(false),
            pw: lay::target_for(p.arch).ptr as u16 * 8,
            lsv: lay::Svc::new(p),
            errs: errs,
            failed: Map::<u64, bool>::new(),
            proved: Map::<u32, Vector<Vector<u32>>>::new(),
            held_alt: Map::<u32, Vector<u32>>::new(),
            pwrites: Map::<u64, u64>::new(),
            rd: UnsafeCell::<Vector<u64>>::new(Vector::<u64>::new()),
            rd_on: false,
            rd_memo: Map::<u64, Vector<u64>>::new(),
            b: null,
            m: 0,
            slot_ty: Vector::<TypeId>::new(),
            slot_of: Vector::<u32>::new(),
            pref_tg: Vector::<u32>::new(),
            pref_tgty: Vector::<TypeId>::new(),
            pref_m: Vector::<ModuleId>::new(),
            pref_at: Vector::<u32>::new(),
            pref_n: Vector::<u32>::new(),
            pref_key: Vector::<u32>::new(),
            pref_by: Map::<u64, u32>::new(),
            pref_ty: Vector::<TypeId>::new(),
            pref_km: Vector::<ModuleId>::new(),
            nlocals: 0,
            scoped: Vector::<bool>::new(),
            scoped_in: Map::<u32, u32>::new(),
            lazy: Vector::<bool>::new(),
            dest_tmp: NONE,
            tracked: Vector::<bool>::new(),
            is_mem: Vector::<bool>::new(),
            cell_tmp: Vector::<bool>::new(),
            conf_memo: Map::<u64, u64>::new(),
            refine_subst: Vector::<u64>::new(),
            havoc_idx: false,
            cohd: Map::<u32, bool>::new(),
            in_cong: false,
            vborrow: Map::<u32, bool>::new(),
            in_vborrow: false,
            mem_list: Vector::<u32>::new(),
            esc: Vector::<u32>::new(),
            aesc: Vector::<u32>::new(),
            views: Vector::<u64>::new(),
            pend: Vector::<u64>::new(),
            me: NONE,
            owner: DefId { module: 0, node: NODE_NONE },
            skip_recv: false,
            fn_dec: false,
            ptr_cast: false,
            mem: null,
            site_of_chain: Vector::<u32>::new(),
            site_of_pred: Vector::<u32>::new(),
            ghost_fn: false,
            no_panic: false,
            own_chk: Vector::<u32>::new(),
            allocl: p.prelude_lookup("Allocator", true),
            globall: p.prelude_lookup("Global", true),
            freel: p.prelude_lookup("Free", true),
            alloc_of: Map::<u32, u32>::new(),
            alloc_rec: Vector::<u32>::new(),
            inv_locs: Vector::<u32>::new(),
            inv_dead: Vector::<u32>::new(),
            inv_end: NONE,
            pan_cond: NONE,
            refine_pan: NONE,
            own_exp: Vector::<bool>::new(),
            gblk: Vector::<bool>::new(),
            in_ghost: false,
            closed_def: false,
            defs: Vector::<u32>::new(),
            def_of: Map::<u32, u32>::new(),
            res_of: Map::<u32, bool>::new(),
            defined: Map::<u32, bool>::new(),
            qclo: Vector::<QClo>::new(),
            qof: Map::<u32, u32>::new(),
            qinst: Map::<u64, u32>::new(),
            qdef: Map::<u32, bool>::new(),
            seld: Map::<u32, bool>::new(),
            cell_free: Map::<u64, u64>::new(),
            ptrd: Map::<u32, bool>::new(),
            seqeqs: Vector::<u32>::new(),
            seqwit: Map::<u32, u32>::new(),
            seq_inst: false,
            ends_memo: Map::<u64, bool>::new(),
            sref: Vector::<u32>::new(),
            inv_goal: false,
            inv_terms: Map::<u32, bool>::new(),
            vdef: Map::<u32, u32>::new(),
            subst: Vector::<u64>::new(),
            unfolding: Vector::<u64>::new(),
            exact: Map::<u32, u32>::new(),
            qvalue: Map::<u32, u32>::new(),
            eta_src: Map::<u32, u32>::new(),
            capd: Map::<u32, bool>::new(),
            specd: Map::<u32, bool>::new(),
            recd: Map::<u32, bool>::new(),
            parts: 0,
            alias: Map::<u32, u64>::new(),
            alias_pool: Vector::<u32>::new(),
            spec_leaves: Map::<u32, u64>::new(),
            spec_pool: Vector::<u64>::new(),
            seqw: Map::<u32, u32>::new(),
            deciding: false,
            pdef: Vector::<u64>::new(),
            pdef_esc: 0,
            mi_dirty: Vector::<u32>::new(),
            mi_fresh: Vector::<u32>::new(),
            mi_wrote: Vector::<u32>::new(),
            wpc: null,
            wsp: tok::Span { start: 0, end: 0 },
            mi_next: Vector::<u32>::new(),
            ov: 0,
            ov_col: NONE,
            ov_seen: Vector::<u32>::new(),
            ov_kind: Vector::<u8>::new(),
            ov_prev: Vector::<u32>::new(),
            ov_pst: Vector::<u32>::new(),
            ov_psn: Vector::<u32>::new(),
            ov_ps: Vector::<u32>::new(),
            held_p: Map::<u32, u64>::new(),
            held_k: Map::<u32, u64>::new(),
            ov_defd: Map::<u32, bool>::new(),
            ov_pre: 0,
            recv_pre: NONE,
            ov_terms: Map::<u64, u32>::new(),
            ov_fr: Map::<u32, u64>::new(),
            fr_depth: 0,
            inv_split: 0,
            ptr_apart: Map::<u32, Vector<u32>>::new(),
            held_by_ptr: Map::<u32, Vector<u32>>::new(),
            claims_of: Map::<u32, Vector<u32>>::new(),
            ov_take: Vector::<u32>::new(),
            own_alloc: 0,
            ov_src: 0,
            src_tab: Map::<u32, Vector<u32>>::new(),
            tk_atoms: Vector::<u32>::new(),
            tk_src: Vector::<u32>::new(),
            owns_d: Map::<u64, bool>::new(),
            owns_m: Map::<u64, u8>::new(),
            mi_seen: Map::<u32, bool>::new(),
            ent_ref: Vector::<u32>::new(),
            st_inv: Map::<u32, u64>::new(),
            st_decl: Map::<u32, NodeId>::new(),
            st_err: Vector::<u32>::new(),
            st_list: Vector::<u32>::new(),
            mi_lds: Vector::<u32>::new(),
            mi_fwd: Map::<u32, u32>::new(),
            sdef: Map::<u64, u32>::new(),
            seqm: p.find("std::spec::seq"),
            trigm: p.find("std::spec::quant"),
            trigd: if p.find("std::spec::quant") >= 0 {
                p.lookup(loader::FROM_ANY, p.find("std::spec::quant") as ModuleId, "trigger", false)
            } else {
                NODE_NONE
            },
            utrig: Vector::<u32>::new(),
            utrig_on: false,
            seqd: if p.find("std::spec::seq") >= 0 {
                p.lookup(loader::FROM_ANY, p.find("std::spec::seq") as ModuleId, "Seq", true)
            } else {
                NODE_NONE
            },
            secm: p.find("std::crypto::secret"),
            secd: if p.find("std::crypto::secret") >= 0 {
                p.lookup(loader::FROM_ANY, p.find("std::crypto::secret") as ModuleId, "Secret", true)
            } else {
                NODE_NONE
            },
            vecl: p.prelude_lookup("Vector", true),
            strl: p.prelude_lookup("String", true),
            smut: p.prelude_lookup("SliceMut", true),
            strv: p.prelude_lookup("str", true),
            pvars: Map::<u64, u32>::new(),
            chk_ok: Map::<u32, bool>::new(),
            chk_dead: Map::<u32, bool>::new(),
            facts_on: false,
            facts_only: false,
            facts: Vector::<u64>::new(),
            unfold: 0,
            chain_ovf: OVF_PROVE,
            chain_depth: 0,
            exact_body: false,
            ovf: OVF_KEEP,
            steps: 0,
            over: false,
            work: Vector::<Path>::new(),
            work_q: hp::BinaryHeap::<u64>::new(),
            work_free: Vector::<u32>::new(),
            work_at: Map::<u32, u32>::new(),
            work_n: 0,
            work_seq: 0,
            merging: false,
            walk_cap: FACTS_WALK,
            ev: Eval::<B>::new(),
            vname: Map::<u32, u32>::new(),
            refining: false,
            refine_all: false,
            refine: null,
            sh: null,
        };
    }

    const fn pkg(self: &Self) &loader::Package {
        return unsafe &*self.p;
    }

    fn ast_of(self: &Self, m: ModuleId) &Ast {
        return unsafe &*(&*self.p).module_ast_const(m);
    }

    // The kept body of function `d`, null when none is kept; a read of the job (`rd`).
    fn kept(self: &Self, d: DefId) *const ir::CoreBody {
        self.note_read(d);
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

    // The current job read function `d`'s body (`rd`); a closure's counts as its whole module's (NODE_NONE),
    // in the body arena or in a pinned body past the declarations.
    fn note_read(self: &Self, d: DefId) {
        if !self.rd_on {
            return;
        }
        let mut node = d.node;
        if (d.node & NODE_BODY) != 0 {
            node = NODE_NONE;
        } else if d.module as usize < self.pkg().modules.len() && self.pkg().modules.at(d.module as usize).has_ast {
            let a = self.ast_of(d.module);
            if a.past_decls(d.node) && a.valid(d.node) && a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
                node = NODE_NONE;
            }
        }
        unsafe (*self.rd.get()).push(d.module as u64 << 32 | node as u64);
    }

    /// The functions whose bodies the jobs since the last call read (`rd`), each once, sorted.
    pub(package) fn take_reads(self: &mut Self) Vector<u64> {
        let mut v = replace(self.rd.get_mut(), Vector::<u64>::new());
        v.sort();
        v.dedup();
        return v;
    }

    // Memo `tag` (`rd_memo`) answered: what its answer read, read again; else, when the call computed
    // it (`computed`), what the reads since mark `mk` hold.
    fn memo_reads(self: &mut Self, tag: u64, mk: usize, computed: bool) {
        if !computed {
            if let Some(v) = self.rd_memo.get(&tag) {
                let ds = v.clone();
                self.rd.get_mut().extend_copy(&ds);
            }
            return;
        }
        let r = self.rd.get_mut();
        let mut ds = Vector::<u64>::with_capacity(r.len() - mk);
        for i in mk..r.len() {
            ds.push(r[i]);
        }
        ds.sort();
        ds.dedup();
        self.rd_memo.insert(tag, ds);
    }

    // Whether `d` is a `const fn`: its result depends on its arguments alone.
    fn is_const_fn(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        // A spec function is a function of its arguments too.
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && (a.ext(d.node).function.is_const() || a.ext(d.node).function.is_spec());
    }

    // The (width, signed) of type `ty` in module `m`: W_BOOL, an integer's width, or W_OTHER.
    // The width of `UInt<N>` or `Int<N>` type `ty` and whether it is signed; 0 for another type.
    fn wide_bits(self: &Self, m: ModuleId, ty: TypeId) (i64, bool) {
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return 0, false;
        }
        let inst = a.instance(y.as_data.inst);
        let wu = inst.module == self.wuint.mid && inst.decl == self.wuint.node;
        if inst.n != 1 || inst.decl == NODE_NONE || !wu && (inst.module != self.wint.mid || inst.decl != self.wint.node) {
            return 0, false;
        }
        let n = a.type_at(inst.args[0]);
        if n.kind != TypeKind::TYPE_CONST || n.as_data.value <= 0 {
            return 0, false;
        }
        return n.as_data.value, !wu;
    }

    // Whether kept body `k` has a local of an integer type wider than `int_limit(B)` bits.
    fn needs_wide(self: &Self, k: usize) bool {
        let b = unsafe &(&*self.keep).kept.at(k).body;
        for l in 0..b.locals.len() {
            let (n, _sg) = self.wide_bits(b.module, b.locals.at(l).ty);
            if n > int_limit(B) {
                return true;
            }
        }
        return false;
    }

    fn ty_of(self: &Self, m0: ModuleId, ty0: TypeId) (u16, bool) {
        if ty0 == TYPE_NONE {
            return W_OTHER, false;
        }
        let (m, ty) = self.resolve(m0, ty0);
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if y.kind == TypeKind::TYPE_INSTANCE {
            // `UInt<N>` and `Int<N>` up to `int_limit` bits (`u128`, `i128`, `UInt<256>`) are integers of
            // N bits.
            let (n, sg) = self.wide_bits(m, ty);
            if n > 0 && n <= int_limit(B) {
                return n as u16, sg;
            }
            // `Float<E, F, FAMILY>` is the integer of its encoding, as a built-in float.
            let (fw, _fd) = self.soft_fmt(m, ty);
            if fw != 0 {
                return fw, false;
            }
            return W_OTHER, false;
        }
        if y.kind != TypeKind::TYPE_BUILTIN {
            return W_OTHER, false;
        }
        let bt = unsafe y.as_data.builtin;
        if bt == BuiltinType::BT_BOOL {
            return W_BOOL, false;
        }
        if bt == BuiltinType::BT_INT || bt == BuiltinType::BT_NAT {
            return pick(bt == BuiltinType::BT_INT, W_INT, W_NAT), bt == BuiltinType::BT_INT;
        }
        let sg = bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE;
        let w: u32 = switch bt {
            BT_I8 | BT_U8 => 8,
            BT_I16 | BT_U16 => 16,
            BT_I32 | BT_U32 => 32,
            BT_I64 | BT_U64 => 64,
            BT_ISIZE | BT_USIZE => self.pw,
            // A character is its code point; a float the integer of its encoding (`T_FADD`).
            BT_CHAR | BT_F32 => 32,
            BT_F64 => 64,
            _ => 0,
        };
        return w as u16, sg;
    }

    // The (width, format code) of `Float<E, F, FAMILY>` type `ty` of module `m` (`Terms`: F, FD_FINITE for the
    // FINITE_ONLY family); a width of 0 for another type, or one past `int_limit` bits.
    fn soft_fmt(self: &Self, m0: ModuleId, ty0: TypeId) (u16, u64) {
        if ty0 == TYPE_NONE || self.wflt.node == NODE_NONE {
            return 0, 0;
        }
        let (m, ty) = self.resolve(m0, ty0);
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return 0, 0;
        }
        let inst = a.instance(y.as_data.inst);
        if inst.module != self.wflt.mid || inst.decl != self.wflt.node || inst.n < 2 || inst.n > 3 {
            return 0, 0;
        }
        let mut v: [i64; 3] = [0, 0, 0];
        for j in 0..inst.n {
            let c = a.type_at(inst.args[j as usize]);
            if c.kind != TypeKind::TYPE_CONST {
                return 0, 0;
            }
            v[j as usize] = c.as_data.value;
        }
        let w = 1 + v[0] + v[1];
        if v[0] < 2 || v[0] > 30 || v[1] < 1 || w > int_limit(B) {
            return 0, 0;
        }
        return w as u16, v[1] as u64 | pick(v[2] != 0, FD_FINITE, 0u64);
    }

    // The width of float type `ty` of module `m`: 32 or 64, 0 for another type.
    fn float_w(self: &Self, m0: ModuleId, ty0: TypeId) u16 {
        if ty0 == TYPE_NONE {
            return 0;
        }
        let (m, ty) = self.resolve(m0, ty0);
        let y = self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return 0;
        }
        let bt = unsafe y.as_data.builtin;
        return pick(bt == BuiltinType::BT_F32, 32u16, pick(bt == BuiltinType::BT_F64, 64u16, 0u16));
    }

    // The float rewrites the build lets the optimizer make (`bman::CG_FAST_MATH`'s flags). `float_binary`
    // and `float_call` give each operation every value they allow.
    const fn fmath(self: &Self) u64 {
        return self.pkg().cg & bman::CG_FAST_MATH;
    }

    // Whether the float sums and products of body `cb` keep their meaning: `-fassociative-math` and
    // `@associative_math` let them reassociate.
    fn float_sums_exact(self: &Self, cb: &ir::CoreBody) bool {
        let o = cb.owner;
        return (self.fmath() & bman::CG_ASSOC_MATH) == 0 && (o.node == NODE_NONE || self.ast_of(o.module).attr_of(
            o.node,
            AttrKind::ATTR_ASSOCIATIVE_MATH,
        ) == null);
    }

    // Type `ty` of module `m` with the type arguments of the unfolding under way (`subst`) in place of
    // its type parameter: (module, type).
    fn resolve(self: &Self, m: ModuleId, ty: TypeId) (ModuleId, TypeId) {
        if self.subst.len() == 0 || ty == TYPE_NONE {
            return m, ty;
        }
        let y = self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_GENERIC {
            return m, ty;
        }
        let k = y.module as u64 << 32 | y.as_data.decl as u64;
        let mut j: usize = 0;
        while j < self.subst.len() {
            if self.subst[j] == k {
                return (self.subst[j + 1] >> 32) as ModuleId, (self.subst[j + 1] & 0xFFFFFFFFu64) as TypeId;
            }
            j += 2;
        }
        return m, ty;
    }

    // The types of call `t`'s arguments unified with the parameters' of function `d`'s contracts (`d`: the
    // callee, or the interface's method whose clauses it has, `contract_of`) into `out`; false when `d`
    // has no contract body.
    fn bind_params(self: &Self, cb: &ir::CoreBody, cm: ModuleId, t: &ir::Terminator, d: DefId, out: &mut Vector<u64>) bool {
        let cbc = self.contract_body(d);
        if cbc == null {
            return false;
        }
        let callee = unsafe &*cbc;
        for j in 0..t.args_len {
            if callee.returns + j < callee.locals.len() as u32 {
                let oid = cb.oper_pool[(t.args_start + j) as usize];
                self.unify(
                    d.module,
                    callee.locals.at((callee.returns + j) as usize).ty,
                    cm,
                    cb.operands.at(oid as usize).ty,
                    out,
                    0,
                );
            }
        }
        return true;
    }

    // The bindings that read contract `c` (`contract_of`) of call `t`'s callee into `out`: the call's
    // (`call_binds`; none when one is unbound), and an interface's `Self` from the arguments' types.
    fn contract_binds(self: &Self, cb: &ir::CoreBody, cm: ModuleId, t: &ir::Terminator, c: DefId, out: &mut Vector<u64>) {
        if !self.call_binds(cb, cm, t, out) {
            out.clear();
        }
        if c.module != t.callee.module || c.node != t.callee.node {
            let _ = self.bind_params(cb, cm, t, c, out);
        }
    }

    // The type arguments of call `t` (in body `cb` of module `cm`) as `subst` pairs into `out`: the
    // callee's `extend` block's type parameters, then its own. Whether every one is bound: the call names
    // one argument per parameter, none of which still names a type parameter of an outer unfolding.
    fn call_binds(self: &Self, cb: &ir::CoreBody, cm: ModuleId, t: &ir::Terminator, out: &mut Vector<u64>) bool {
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return t.targs_len == 0;
        }
        let a = self.ast_of(d.module);
        let c = a.container_of(d.node);
        let eg = if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND {
            a.ext(c).extend_def.generics
        } else {
            NodeList { start: 0, len: 0 }
        };
        let fg = a.ext(d.node).function.generics;
        // An interface's member: its arguments' types bind `Self` (the receiver's type) for its clauses.
        if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_INTERFACE && eg.len + fg.len == 0 {
            let _ = self.bind_params(cb, cm, t, d, out);
            return t.targs_len == 0;
        }
        // A method call names no type arguments: its arguments' types bind the parameters' types.
        if t.targs_len == 0 && eg.len + fg.len != 0 {
            if !self.bind_params(cb, cm, t, d, out) {
                return false;
            }
            for j in 0..eg.len + fg.len {
                let pn = if j < eg.len {
                    unsafe a.list(eg)[j as usize]
                } else {
                    unsafe a.list(fg)[(j - eg.len) as usize]
                };
                if !out.contains(&(d.module as u64 << 32 | pn as u64)) {
                    return false;
                }
            }
            return true;
        }
        if t.targs_len != eg.len + fg.len {
            return false;
        }
        for j in 0..t.targs_len {
            let t0 = cb.targ_pool[(t.targs_start + j) as usize];
            let (m2, t2) = self.resolve(cm, t0);
            if self.subst.len() != 0 && !self.bound_generic(cm, t0) && self.mentions_generic(m2, t2, 0) {
                return false;
            }
            let pn = if j < eg.len {
                unsafe a.list(eg)[j as usize]
            } else {
                unsafe a.list(fg)[(j - eg.len) as usize]
            };
            out.push(d.module as u64 << 32 | pn as u64);
            out.push(m2 as u64 << 32 | t2 as u64);
        }
        return true;
    }

    // The `subst` pairs that make type `pt` (module `pm`) the type `at` (module `am`): each type parameter
    // `pt` names, bound to the part of `at` in its place, into `out` (once each); `depth` levels deep. A
    // reference parameter takes a value argument too (an automatic reference).
    fn unify(self: &Self, pm: ModuleId, pt: TypeId, am: ModuleId, at: TypeId, out: &mut Vector<u64>, depth: u32) {
        if depth > 8 || pt == TYPE_NONE || at == TYPE_NONE {
            return;
        }
        let (xm, xt) = self.resolve(am, at);
        let p = *self.ast_of(pm).type_at(pt);
        let x = *self.ast_of(xm).type_at(xt);
        if p.kind == TypeKind::TYPE_GENERIC {
            let k = p.module as u64 << 32 | p.as_data.decl as u64;
            let mut j: usize = 0;
            while j < out.len() {
                if out[j] == k {
                    return;
                }
                j += 2;
            }
            out.push(k);
            out.push(xm as u64 << 32 | xt as u64);
            return;
        }
        if p.kind == TypeKind::TYPE_REFERENCE && x.kind != TypeKind::TYPE_REFERENCE {
            self.unify(pm, p.as_data.elem, xm, xt, out, depth + 1);
            return;
        }
        if p.kind != x.kind {
            return;
        }
        if p.kind == TypeKind::TYPE_REFERENCE || p.kind == TypeKind::TYPE_POINTER {
            self.unify(pm, p.as_data.elem, xm, x.as_data.elem, out, depth + 1);
        } else if p.kind == TypeKind::TYPE_ARRAY && !p.arr_sym() && !x.arr_sym() {
            self.unify(pm, p.as_data.arr.elem, xm, x.as_data.arr.elem, out, depth + 1);
        } else if p.kind == TypeKind::TYPE_INSTANCE {
            let pi = *self.ast_of(pm).instance(p.as_data.inst);
            let xi = *self.ast_of(xm).instance(x.as_data.inst);
            if pi.module == xi.module && pi.decl == xi.decl && pi.n == xi.n {
                for j in 0..pi.n {
                    self.unify(pm, pi.args[j as usize], xm, xi.args[j as usize], out, depth + 1);
                }
            }
        }
    }

    // Whether type `ty` (module `m`) names a type parameter, or is a type this walk does not take apart.
    // Whether `ty` (module `m`) is a type parameter `subst` binds: its type, which `resolve` gives, names
    // the outer body's types, whose parameters are that body's own.
    fn bound_generic(self: &Self, m: ModuleId, ty: TypeId) bool {
        if self.subst.len() == 0 || ty == TYPE_NONE {
            return false;
        }
        let y = self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_GENERIC {
            return false;
        }
        let k = y.module as u64 << 32 | y.as_data.decl as u64;
        let mut j: usize = 0;
        while j < self.subst.len() {
            if self.subst[j] == k {
                return true;
            }
            j += 2;
        }
        return false;
    }

    fn mentions_generic(self: &Self, m: ModuleId, ty: TypeId, depth: u32) bool {
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if depth > 8 {
            return true;
        }
        if y.kind == TypeKind::TYPE_BUILTIN || y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return false;
        }
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            return self.mentions_generic(m, y.as_data.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            return self.mentions_generic(m, y.as_data.arr.elem, depth + 1);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = a.instance(y.as_data.inst);
            for j in 0..inst.n {
                if self.mentions_generic(m, inst.args[j as usize], depth + 1) {
                    return true;
                }
            }
            return false;
        }
        return !(y.kind == TypeKind::TYPE_GENERIC && self.rigid(y.module, y.as_data.decl));
    }

    // Whether type parameter `p` (module `m`) is one of the function under proof or of its `extend`: one
    // type throughout the proof, which an unfolding's type argument may name.
    fn rigid(self: &Self, m: ModuleId, p: NodeId) bool {
        let d = self.owner;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || m != d.module || !self.pkg().modules.at(m as usize).has_ast {
            return false;
        }
        let a = self.ast_of(m);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let fg = a.ext(d.node).function.generics;
        for j in 0..fg.len {
            if unsafe a.list(fg)[j as usize] == p {
                return true;
            }
        }
        let c = a.container_of(d.node);
        if c == NODE_NONE || a.at_const(c).kind != NodeKind::NODE_EXTEND {
            return false;
        }
        let eg = a.ext(c).extend_def.generics;
        for j in 0..eg.len {
            if unsafe a.list(eg)[j as usize] == p {
                return true;
            }
        }
        return false;
    }

    // Whether a value of type `ty` is frozen: a scalar or a shared view (`[]T`), which no shared
    // reference can change and whose elements no write can reach while it lives.
    fn frozen(self: &Self, m: ModuleId, ty: TypeId) bool {
        return self.frozen_d(m, ty, 0, false);
    }

    // Whether a value of type `ty`, a call's result, can hold no borrow the call takes: `frozen`, where a
    // type parameter of the body counts as frozen. Its lifetimes outlive the body's parameters, so none is
    // a borrow the body makes of a parameter's target.
    fn holds_no_borrow(self: &Self, m: ModuleId, ty: TypeId) bool {
        return self.frozen_d(m, ty, 0, true);
    }

    // `frozen`, `depth` structs deep; with `gen`, `holds_no_borrow`.
    fn frozen_d(self: &Self, m: ModuleId, ty: TypeId, depth: u32, gen: bool) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if gen && y.kind == TypeKind::TYPE_GENERIC {
            return true;
        }
        // A raw pointer is its address, which no shared reference changes; its target is memory (an
        // `@owned` field's block only its struct's `&mut` writes).
        if y.kind == TypeKind::TYPE_BUILTIN {
            return true;
        }
        // A struct whose members are all frozen (a member of a type parameter's type: the argument's), or an
        // array of a fixed length of frozen elements, is the value of its members.
        if (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE) && depth < FROZEN_DEPTH && self.frozen_struct(
            m,
            ty,
            depth,
            gen,
        ) {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() && depth < FROZEN_DEPTH {
            return self.frozen_d(m, y.as_data.arr.elem, depth + 1, gen);
        }
        // An enum whose payloads are all frozen is its discriminant and their values.
        if (y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_INSTANCE) && depth < FROZEN_DEPTH && self.frozen_enum(
            m,
            ty,
            depth,
            gen,
        ) {
            return true;
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        // A wide integer is a value of limbs, as a built-in integer is; a sequence a mathematical value.
        let (w, _sg) = self.ty_of(m, ty);
        if w > W_BOOL {
            return true;
        }
        let inst = a.instance(y.as_data.inst);
        if self.seqd != NODE_NONE && inst.module == self.seqm as ModuleId && inst.decl == self.seqd {
            return true;
        }
        if self.slice.node == NODE_NONE {
            return false;
        }
        return inst.module == self.slice.mid && inst.decl == self.slice.node;
    }

    // Whether enum type `ty` (module `m`) holds frozen payloads only (`frozen_d`, `depth` levels deep).
    fn frozen_enum(self: &Self, m: ModuleId, ty: TypeId, depth: u32, gen: bool) bool {
        let y = self.ast_of(m).type_at(ty);
        let (dm, dn, inst) = if y.kind == TypeKind::TYPE_ENUM {
            (y.module, y.as_data.decl, TyInstance { module: 0, decl: NODE_NONE, n: 0, args: [TYPE_NONE; 8], lts: 0 })
        } else {
            let it = *self.ast_of(m).instance(y.as_data.inst);
            (it.module, it.decl, it)
        };
        if dn == NODE_NONE || dm as usize >= self.pkg().modules.len() || !self.pkg().modules.at(dm as usize).has_ast {
            return false;
        }
        let da = self.ast_of(dm);
        if da.at_const(dn).kind != NodeKind::NODE_ENUM {
            return false;
        }
        let ag = unsafe da.ext(dn).aggregate;
        for j in 0..ag.members.len {
            let vn = *da.at_const(unsafe da.list(ag.members)[j as usize]);
            if vn.kind != NodeKind::NODE_VARIANT {
                continue;
            }
            for k in 0..vn.as_data.variant.payload.len {
                let pid = unsafe da.list(vn.as_data.variant.payload)[k as usize];
                let pt = da.type_of(da.member_type_node(pid, true));
                if pt == TYPE_NONE {
                    return false;
                }
                let py = da.type_at(pt);
                if py.kind != TypeKind::TYPE_GENERIC {
                    if !self.frozen_d(dm, pt, depth + 1, gen) {
                        return false;
                    }
                    continue;
                }
                let mut found = false;
                for i in 0..ag.generics.len {
                    if py.module == dm && unsafe da.list(ag.generics)[i as usize] == py.as_data.decl && i as u8 < inst.n {
                        found = self.frozen_d(m, inst.args[i as usize], depth + 1, gen);
                    }
                }
                if !found {
                    return false;
                }
            }
        }
        return true;
    }

    // Whether struct type `ty` (module `m`, a struct or an instance of one) has only frozen members.
    fn frozen_struct(self: &Self, m: ModuleId, ty: TypeId, depth: u32, gen: bool) bool {
        let y = self.ast_of(m).type_at(ty);
        let (dm, dn, inst) = if y.kind == TypeKind::TYPE_STRUCT {
            (y.module, y.as_data.decl, TyInstance { module: 0, decl: NODE_NONE, n: 0, args: [TYPE_NONE; 8], lts: 0 })
        } else {
            let it = *self.ast_of(m).instance(y.as_data.inst);
            (it.module, it.decl, it)
        };
        if dn == NODE_NONE || dm as usize >= self.pkg().modules.len() || !self.pkg().modules.at(dm as usize).has_ast {
            return false;
        }
        let da = self.ast_of(dm);
        if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        let ag = unsafe da.ext(dn).aggregate;
        if ag.is_union || ag.is_extern || ag.members.len == 0 {
            return false;
        }
        for j in 0..ag.members.len {
            let mt = da.member_ty(unsafe da.list(ag.members)[j as usize]);
            if mt == TYPE_NONE {
                return false;
            }
            let my = da.type_at(mt);
            if my.kind != TypeKind::TYPE_GENERIC {
                if !self.frozen_d(dm, mt, depth + 1, gen) {
                    return false;
                }
                continue;
            }
            let mut found = false;
            for i in 0..ag.generics.len {
                if my.module == dm && unsafe da.list(ag.generics)[i as usize] == my.as_data.decl && i as u8 < inst.n {
                    found = self.frozen_d(m, inst.args[i as usize], depth + 1, gen);
                }
            }
            if !found {
                return false;
            }
        }
        return true;
    }

    // The `invariant` method of struct type `ty` of module `m` (`Parser::expand_invariants`), its
    // extend's parameters bound to `ty`'s arguments in `binds`; NODE_NONE for a type without one.
    fn inv_method(self: &Self, m: ModuleId, ty: TypeId, binds: &mut Vector<u64>) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        if ty == TYPE_NONE {
            return none;
        }
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return none;
        }
        let (dm, dn) = self.decl_of(rm, rt);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast {
            return none;
        }
        let a = self.ast_of(dm);
        let (cs, ce) = a.contracts_of(dn);
        if cs == ce || a.contracts.at(cs as usize).binder == NODE_NONE {
            return none;
        }
        let gs = a.ext(dn).aggregate.generics;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(rm).instance(y.as_data.inst);
            if it.n as u32 != gs.len {
                return none;
            }
            for j in 0..gs.len {
                let (am, at) = self.resolve(rm, it.args[j as usize]);
                if self.subst.len() != 0 && !self.bound_generic(rm, it.args[j as usize]) && self.mentions_generic(
                    am,
                    at,
                    0,
                ) {
                    return none;
                }
                binds.push(dm as u64 << 32 | (unsafe a.list(gs)[j as usize]) as u64);
                binds.push(am as u64 << 32 | at as u64);
            }
        } else if gs.len != 0 {
            return none;
        }
        return DefId { module: dm, node: a.contracts.at(cs as usize).binder };
    }

    // The invariant of value `v` of type `ty` (module `m`) in `state`: the call `S::invariant(&v)`,
    // defined by its body once (`define`); NONE for a type without one.
    fn inv_of(self: &mut Self, m: ModuleId, ty: TypeId, v: u32, state: &Vector<u32>) u32 {
        let mut binds = Vector::<u64>::new();
        let d = self.inv_method(m, ty, &mut binds);
        if d.node == NODE_NONE || v == NONE {
            return NONE;
        }
        let arg = self.tm.unary(T_REF, v, W_OTHER, false);
        return self.inv_term(d, binds, arg, v, state);
    }

    // The invariant term of function `d` (generic bindings `binds`) of value `v`, passed as `arg`: keyed
    // by the ownership version where it names `owns`, with its frames (`ov_frame`), defined.
    fn inv_term(self: &mut Self, d: DefId, binds: Vector<u64>, arg: u32, v: u32, state: &Vector<u32>) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(arg);
        let ik0 = skey_mix(0, d.module as u64 << 32 | d.node as u64);
        let vk = self.mentions_owns(d);
        let ik = pick(vk, skey_mix(ik0, OV_KEY | self.ov as u64), ik0);
        let r = self.tm.call(ik, &xs, W_BOOL, false);
        self.inv_terms.insert(r, true);
        let ck = d.module as u64 << 32 | d.node as u64;
        if self.unfold < NEST_MAX && !self.unfolding.contains(&ck) {
            let outer = replace(&mut self.subst, binds);
            self.unfolding.push(ck);
            self.define(r, d, &xs, state, false);
            let _ = self.unfolding.pop();
            self.subst = outer;
        }
        if vk {
            self.ov_frame(ik0, v, r);
        }
        return r;
    }

    // The address of static local `l` of body `cb` where the static has an invariant (`static mut G: T = V
    // invariant E;`): memory there holds its value, and the invariant of it; NONE for another local.
    fn static_addr(self: &mut Self, cb: &ir::CoreBody, l: u32) u32 {
        let f = self.static_inv_fn(cb, l);
        if f == NODE_NONE {
            return NONE;
        }
        let d = cb.locals.at(l as usize).item;
        let none = Vector::<u32>::new();
        let r = self.tm.call(skey_mix(20, d.module as u64 << 32 | d.node as u64), &none, W_OTHER, false);
        if !self.st_inv.contains_key(&r) {
            self.st_inv.insert(r, d.module as u64 << 32 | f as u64);
            self.st_decl.insert(r, d.node);
        }
        return r;
    }

    // The invariant's function of static local `l` of body `cb` (`expand_static_invariants`), NODE_NONE for
    // another local or a slot (a `&mut` parameter's value, past the locals).
    fn static_inv_fn(self: &Self, cb: &ir::CoreBody, l: u32) NodeId {
        if l as usize >= cb.locals.len() {
            return NODE_NONE;
        }
        let ld = cb.locals.at(l as usize);
        let d = ld.item;
        if ld.storage != ir::LS_STATIC_REF || d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return NODE_NONE;
        }
        let a = self.ast_of(d.module);
        let n = a.at_const(d.node);
        if n.kind != NodeKind::NODE_CONST || !unsafe n.as_data.const_def.is_static_mut {
            return NODE_NONE;
        }
        let (cs, ce) = a.contracts_of(d.node);
        if cs == ce {
            return NODE_NONE;
        }
        return a.contracts.at(cs as usize).binder;
    }

    // Whether static local `l` of body `cb` is of a type with an invariant. No proof states its first value:
    // a read of it assumes nothing, and no reference to it may reach a callee, which would assume it.
    fn static_tinv(self: &Self, cb: &ir::CoreBody, l: u32) bool {
        if l as usize >= cb.locals.len() {
            return false;
        }
        let ld = cb.locals.at(l as usize);
        let d = ld.item;
        if ld.storage != ir::LS_STATIC_REF || d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        let n = self.ast_of(d.module).at_const(d.node);
        return n.kind == NodeKind::NODE_CONST && unsafe n.as_data.const_def.is_static_mut && self.mi_type(
            cb.module,
            ld.ty,
        );
    }

    // The invariant of value `v` of the static at address `r` (`static_addr`).
    fn st_inv_of(self: &mut Self, r: u32, v: u32, state: &Vector<u32>) u32 {
        let e = *self.st_inv.get(&r).unwrap();
        let d = DefId { module: (e >> 32) as ModuleId, node: (e & 0xFFFFFFFFu64) as u32 };
        return self.inv_term(d, Vector::<u64>::new(), v, v, state);
    }

    // The value of static local `l` (address `r`, `static_addr`) in the walk's memory: the invariant of a
    // value memory holds is a fact (at OV_MEM: memory's blocks) until a write opens it.
    fn static_val(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &Vector<u32>, l: u32, r: u32) u32 {
        let ty = cb.locals.at(l as usize).ty;
        let x = self.deref(state, r, cm, ty);
        let mut listed = false;
        for q in 0..self.st_list.len() / 2 {
            listed = listed || self.st_list[2 * q] == r;
        }
        if !listed {
            self.st_list.push(r);
            self.st_list.push(ty);
        }
        let mut open = false;
        for q in 0..self.mi_dirty.len() / 3 {
            open = open || self.mi_dirty[3 * q] == r;
        }
        if !open && self.tm.at(x).op == T_LOAD && !self.mi_seen.contains_key(&x) {
            self.mi_seen.insert(x, true);
            let ov0 = replace(&mut self.ov, OV_MEM);
            let f = self.st_inv_of(r, x, state);
            self.ov = ov0;
            self.anchor(x, f);
        }
        return x;
    }

    // Whether static local `l` of body `cb` has an invariant its file keeps: its address, else NONE.
    fn static_here(self: &mut Self, cb: &ir::CoreBody, l: u32) u32 {
        let r = self.static_addr(cb, l);
        if r == NONE || (*self.st_inv.get(&r).unwrap() >> 32) as ModuleId != cb.module {
            return NONE;
        }
        return r;
    }

    // A term `r` keyed on the walk's ownership version (`id` its key without it): the same term of an
    // earlier version `u` of its chain implies it where no block it holds there was taken since
    // (`inv_u && (!h || !c || p != q).. ==> r`, each held atom `h` of `inv_u` at pointer `p`, each atom `c`
    // a REMOVE took at pointer `q`). An owns atom stands positively in an invariant: holding more blocks
    // keeps it.
    fn ov_frame(self: &mut Self, ik0: u64, x: u64, r: u32) {
        let v = self.ov;
        if v as usize >= self.ov_kind.len() {
            return;
        }
        let k = skey_mix(skey_mix(ik0, x), 0x5645);
        // The terms of this key by version: the latest made first.
        let mut w = v;
        let mut taken = Vector::<u32>::new();
        let mut found = NONE;
        for _s in 0..64 {
            if w as usize >= self.ov_kind.len() || self.ov_kind[w as usize] == OV_BASE {
                break;
            }
            if self.ov_kind[w as usize] == OV_REMOVE {
                // Pairs: the atom taken, its claim guard.
                let st = self.ov_pst[w as usize] as usize;
                for j in st..st + self.ov_psn[w as usize] as usize {
                    taken.push(self.ov_ps[j]);
                }
            } else if self.ov_psn[w as usize] == NONE {
                break;
            }
            w = self.ov_prev[w as usize];
            if let Some(t) = self.ov_terms.get(&skey_mix(k, w)) {
                found = *t;
                break;
            }
        }
        self.ov_terms.insert(skey_mix(k, v), r);
        if found == NONE {
            return;
        }
        let mut hg = Vector::<u64>::new();
        self.held_g(found, w, &mut hg);
        let mut side = self.tm.boolean(true);
        for i in 0..hg.len() {
            let h = (hg[i] >> 32) as u32;
            let gh = self.guard_or(h, (hg[i] & 0xFFFFFFFFu64) as u32);
            let ph = (*self.held_p.get(&h).unwrap() >> 32) as u32;
            let mut j: usize = 0;
            while j < taken.len() {
                let pc = (*self.held_p.get(&taken[j]).unwrap() >> 32) as u32;
                let d = self.apart(gh, ph, taken[j + 1], pc);
                side = self.tm.and(side, d);
                j += 2;
            }
        }
        let a = self.tm.and(found, side);
        let na = self.tm.not(a);
        let f = self.tm.or(na, r);
        self.anchor(r, f);
        self.ov_fr.insert(r, found as u64 << 32 | side as u64);
    }

    // The claims of stated fact `f`: `guard ==> atom` and the atom's pointer, for each held atom of any
    // version its definitions name (`held_g_at`), memoized.
    fn claims(self: &mut Self, f: u32) Vector<u32> {
        if let Some(cs) = self.claims_of.get(&f) {
            return cs.clone();
        }
        let mut raw = Vector::<u64>::new();
        let mut budget: u32 = 4096;
        let t = self.tm.boolean(true);
        self.held_g_at(f, t, NONE, &mut raw, &mut budget, 0);
        let mut out = Vector::<u64>::new();
        self.merge_guards(&raw, &mut out);
        let mut cs = Vector::<u32>::new();
        for j in 0..out.len() {
            let h = (out[j] >> 32) as u32;
            let g = (out[j] & 0xFFFFFFFFu64) as u32;
            if g == NONE {
                continue;
            }
            let ng = self.tm.not(g);
            cs.push(self.tm.or(ng, h));
            cs.push((*self.held_p.get(&h).unwrap() >> 32) as u32);
        }
        self.claims_of.insert(f, cs.clone());
        return cs;
    }

    // Whether fact `f` names a held atom of one of pointers `ps`, or compares two of them.
    fn on_ptrs(self: &Self, f: u32, ps: &Vector<u32>) bool {
        let mut stack = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(f);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return false;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if let Some(pv) = self.held_p.get(&t) {
                if ps.contains(&((*pv >> 32) as u32)) {
                    return true;
                }
                continue;
            }
            let x = self.tm.at(t);
            if (x.op == T_EQ || x.op == T_NE) && ps.contains(&x.a) && ps.contains(&x.b) {
                return true;
            }
            if x.op == T_AND || x.op == T_OR || x.op == T_NOT {
                ops.clear();
                self.tm.operands(t, &mut ops);
                stack.extend_copy(&ops);
            }
        }
        return false;
    }

    // The operands of the distinctness conclusions of formula `f` (`p != q` under connectives, of pointers
    // with held atoms).
    fn compared(self: &Self, f: u32, out: &mut Vector<u32>, depth: u32) {
        let x = self.tm.at(f);
        if depth > 48 {
            return;
        }
        if x.op == T_AND || x.op == T_OR {
            self.compared(x.a, out, depth + 1);
            self.compared(x.b, out, depth + 1);
        } else if x.op == T_NOT {
            self.compared(x.a, out, depth + 1);
        } else if x.op == T_NE && self.held_by_ptr.contains_key(&x.a) && self.held_by_ptr.contains_key(&x.b) {
            if !out.contains(&x.a) {
                out.push(x.a);
            }
            if !out.contains(&x.b) {
                out.push(x.b);
            }
        }
    }

    // Formula `t` with each framed term (`ov_fr`) and held atom it names under `&&` and `||` replaced by
    // its earlier version's term where path `pc` and context `ctx` prove the frame's side: a formula that
    // implies `t`. The context grows: under `a || b`, `b` with `!a` and `a` with `!b`; under `a && b`, `b`
    // with `a` (the replaced `a` implies it).
    fn frame_back(self: &mut Self, pc: &Vector<u32>, ctx: &mut Vector<u32>, t: u32, visits: &mut u32) u32 {
        *visits += 1;
        if *visits > 256 {
            return t;
        }
        let x = self.tm.at(t);
        if self.ov_fr.contains_key(&t) {
            let parts = *self.ov_fr.get(&t).unwrap();
            let (found, side) = ((parts >> 32) as u32, (parts & 0xFFFFFFFFu64) as u32);
            if self.side_holds(pc, ctx, side) {
                return found;
            }
            return t;
        }
        if self.held_p.contains_key(&t) {
            return self.held_back(pc, ctx, t);
        }
        if x.op != T_AND && x.op != T_OR {
            return t;
        }
        let other_b = if x.op == T_OR {
            self.tm.not(x.b)
        } else {
            NONE
        };
        if other_b != NONE {
            ctx.push(other_b);
        }
        let a = self.frame_back(pc, ctx, x.a, visits);
        if other_b != NONE {
            let _ = ctx.pop();
        }
        let other_a = if x.op == T_OR {
            self.tm.not(x.a)
        } else {
            x.a
        };
        ctx.push(other_a);
        let b = self.frame_back(pc, ctx, x.b, visits);
        let _ = ctx.pop();
        if a == x.a && b == x.b {
            return t;
        }
        if x.op == T_AND {
            return self.tm.and(a, b);
        }
        return self.tm.or(a, b);
    }

    // Whether facts `ctx` prove distinctness goal `side` with the facts on its pointers (`apart_holds`),
    // else with path `pc` too.
    fn side_holds(self: &mut Self, pc: &Vector<u32>, ctx: &Vector<u32>, side: u32) bool {
        if self.tm.is_true(side) || self.apart_holds(ctx, side) {
            return true;
        }
        let mut all = pc.clone();
        all.extend_copy(ctx);
        return self.apart_holds(&all, side);
    }

    // Held atom `h`'s block in the earliest version its definitions reach (`held_def`), where path `pc`
    // and context `ctx` prove that no removal since took it: that atom implies `h`. Each removal's side is proved with the
    // atoms of the versions before it, which hold where the earliest does (an ADD gave none of their
    // blocks). `h` where a side fails.
    fn held_back(self: &mut Self, pc: &Vector<u32>, ctx: &Vector<u32>, h: u32) u32 {
        let pv = *self.held_p.get(&h).unwrap();
        let p = (pv >> 32) as u32;
        let k = *self.held_k.get(&h).unwrap();
        let mut xs = Vector::<u32>::new();
        self.tm.operands(h, &mut xs);
        // The versions from `h`'s back to the earliest with a definition.
        let mut vs = Vector::<u32>::new();
        let mut w = (pv & 0xFFFFFFFFu64) as u32;
        for _s in 0..64 {
            if w as usize >= self.ov_kind.len() || self.ov_kind[w as usize] == OV_BASE || self.ov_psn[w as usize] == NONE {
                break;
            }
            vs.push(w);
            w = self.ov_prev[w as usize];
        }
        if vs.len() == 0 {
            return h;
        }
        let ov0 = replace(&mut self.ov, w);
        let first = self.held_atom(k, p, xs[1], xs[2]);
        self.ov = ov0;
        let mut hy = ctx.clone();
        hy.push(first);
        let mut i = vs.len();
        while i > 0 {
            i -= 1;
            let u = vs[i];
            if self.ov_kind[u as usize] == OV_REMOVE {
                let mut side = self.tm.boolean(true);
                let st = self.ov_pst[u as usize] as usize;
                let mut j = st;
                while j < st + self.ov_psn[u as usize] as usize {
                    let px = (*self.held_p.get(&self.ov_ps[j]).unwrap() >> 32) as u32;
                    let ng = self.tm.not(self.ov_ps[j + 1]);
                    let e = self.tm.cmp(T_EQ, p, px);
                    let ne = self.tm.not(e);
                    let d = self.tm.or(ng, ne);
                    side = self.tm.and(side, d);
                    j += 2;
                }
                if !self.side_holds(pc, &hy, side) {
                    return h;
                }
            }
            if i > 0 {
                let ov1 = replace(&mut self.ov, u);
                let hu = self.held_atom(k, p, xs[1], xs[2]);
                self.ov = ov1;
                hy.push(hu);
            }
        }
        return first;
    }

    // Whether path `pc` proves framed term `goal` (`ov_fr`): its side, from the held atoms' definitions
    // (`held_def`) and the distinctness facts of the pointers it compares (`ptr_apart`), then its earlier
    // version's term, which the path states or proves.
    fn frame_holds(self: &mut Self, pc: &Vector<u32>, goal: u32) bool {
        if self.fr_depth > 8 {
            return false;
        }
        let parts = *self.ov_fr.get(&goal).unwrap();
        let (found, side) = ((parts >> 32) as u32, (parts & 0xFFFFFFFFu64) as u32);
        if !self.tm.is_true(side) && !self.apart_holds(pc, side) {
            return false;
        }
        if pc.contains(&found) || self.stated_part(pc, found) {
            return true;
        }
        self.fr_depth += 1;
        let ok = self.holds(pc, found);
        self.fr_depth -= 1;
        return ok;
    }

    // Whether path `pc` proves `goal`, a formula of guards and pointer comparisons (a frame's side, a
    // distinctness check): from the claims of its facts (`claims`), the definitions of the compared
    // pointers' held atoms (`held_def`) and their distinctness facts (`ptr_apart`).
    fn apart_holds(self: &mut Self, pc: &Vector<u32>, goal: u32) bool {
        let mut hyps = pc.clone();
        // The pointers the goal compares: the claims of the facts on them alone.
        let mut ptrs = Vector::<u32>::new();
        self.compared(goal, &mut ptrs, 0);
        for j in 0..pc.len() {
            let cs = self.claims(pc[j]);
            let mut q: usize = 0;
            while q < cs.len() {
                if ptrs.contains(&cs[q + 1]) && !hyps.contains(&cs[q]) {
                    hyps.push(cs[q]);
                }
                q += 2;
            }
        }
        let mut stack = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(goal);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                break;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if self.held_p.contains_key(&t) {
                let f = match_def(&self.def_of, &self.defs, t);
                if f != NONE {
                    if !hyps.contains(&f) {
                        hyps.push(f);
                    }
                    stack.push(f);
                }
                // Its size's and alignment's definitions: two atoms of one block whose sizes are spelled
                // apart (`array_bytes::<T>(4)` and `32`) are one atom where their values are equal.
                ops.clear();
                self.tm.operands(t, &mut ops);
                for j in 1..ops.len() {
                    if let Some(d) = self.def_of.get(&ops[j]) {
                        let fd = self.defs[(*d) as usize];
                        if !hyps.contains(&fd) {
                            hyps.push(fd);
                        }
                    }
                }
                continue;
            }
            let op = self.tm.at(t).op;
            if op == T_AND || op == T_OR || op == T_NOT || op == T_EQ || op == T_NE {
                ops.clear();
                self.tm.operands(t, &mut ops);
                stack.extend_copy(&ops);
            }
            if let Some(ds) = self.ptr_apart.get(&t) {
                let dl = ds.clone();
                for j in 0..dl.len() {
                    if !hyps.contains(&dl[j]) {
                        hyps.push(dl[j]);
                        stack.push(dl[j]);
                    }
                }
            }
            // A pointer's held atoms: their versions' definitions relate its blocks.
            if let Some(hs) = self.held_by_ptr.get(&t) {
                let hl = hs.clone();
                stack.extend_copy(&hl);
            }
        }
        // First each part alone, with the facts on its compared pointers and their distinctness facts
        // (a frame's side compares a pointer with one a version took): the path's other cases only add
        // splits.
        let mut parts = Vector::<u32>::new();
        self.conjuncts(goal, &mut parts, 0);
        let mut all = true;
        for q in 0..parts.len() {
            if !all {
                break;
            }
            let mut pq = Vector::<u32>::new();
            self.compared(parts[q], &mut pq, 0);
            let mut few = Vector::<u32>::new();
            for j in 0..hyps.len() {
                if self.on_ptrs(hyps[j], &pq) {
                    few.push(hyps[j]);
                }
            }
            for j in 0..pq.len() {
                if let Some(ds) = self.ptr_apart.get(&pq[j]) {
                    for i in 0..ds.len() {
                        if !few.contains(&ds[i]) {
                            few.push(ds[i]);
                        }
                    }
                }
            }
            all = self.capped(&few, parts[q]);
        }
        if all {
            return true;
        }
        let ok = self.sv.implies(&self.tm, &hyps, goal, false);
        return ok;
    }

    // Whether `t` is a conjunct of a fact the path states, or of the definition of a call it states (an
    // invariant's part).
    fn stated_part(self: &Self, pc: &Vector<u32>, t: u32) bool {
        let mut parts = Vector::<u32>::new();
        for j in 0..pc.len() {
            parts.clear();
            self.conjuncts(pc[j], &mut parts, 0);
            if parts.contains(&t) {
                return true;
            }
            if self.tm.at(pc[j]).op != T_CALL {
                continue;
            }
            let body = self.def_body(pc[j]);
            if body == NONE {
                continue;
            }
            parts.clear();
            self.conjuncts(body, &mut parts, 0);
            if parts.contains(&t) {
                return true;
            }
        }
        return false;
    }

    // Whether struct type `ty` (module `m`) has an invariant its own file's bodies prove (`inv_method`):
    // the module of the body under proof declares it.
    fn inv_here(self: &Self, m: ModuleId, ty: TypeId) bool {
        let mut binds = Vector::<u64>::new();
        let d = self.inv_method(m, ty, &mut binds);
        return d.node != NODE_NONE && d.module == self.m;
    }

    // A value of a struct type with an invariant satisfies it, a fact anchored on the value, except in
    // the struct's own file: there a value may break it until it leaves the body (`inv_exit`), and the
    // walk assumes it where a value enters (`inv_enter`).
    fn inv_fact(self: &mut Self, m: ModuleId, ty: TypeId, v: u32) {
        let mut binds = Vector::<u64>::new();
        let d = self.inv_method(m, ty, &mut binds);
        if d.node == NODE_NONE || d.module == self.m || v == NONE {
            return;
        }
        let mut st = Vector::<u32>::new();
        st.push(self.tm.var(W_OTHER, false));
        // Its blocks are the value's, not the body's: no call takes them from the body.
        let ov0 = replace(&mut self.ov, OV_VALUE);
        let f = self.inv_of(m, ty, v, &st);
        self.ov = ov0;
        if f == NONE {
            return;
        }
        if let Some(i) = self.def_of.get(&v) {
            let j = (*i) as usize;
            let g = self.tm.and(self.defs[j], f);
            self.defs.set(j, g);
            return;
        }
        self.def_of.insert(v, self.defs.len() as u32);
        self.defs.push(f);
    }

    // In a body of a struct's own file (`inv_here`): the obligation that value `v` of type `ty` satisfies
    // the struct's invariant where it leaves the body or a panic may unwind past it (`what` names where).
    // Not in ghost code: it changes no value. The invariant where it holds, NONE where it does not.
    fn inv_need(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &Vector<u32>,
        pc: &Vector<u32>,
        ty: TypeId,
        v: u32,
        key: u64,
        sp: tok::Span,
        what: str,
    ) u32 {
        if self.ghost_fn || v == NONE || !self.inv_here(b.module, ty) {
            return NONE;
        }
        let f = self.inv_of(b.module, ty, v, state);
        if f == NONE || pc.contains(&f) {
            return f;
        }
        let ok0 = !self.over && !(self.refining && !self.refine_all);
        let (dm, dn) = self.decl_of(b.module, ty);
        let a = self.ast_of(dm);
        let name = String::from_str(self.text(dm, a.at_const(a.ext_name(dn)).span));
        self.inv_goal = true;
        self.oblige(
            pc,
            f,
            OB_TYPE_INV << 56 | key,
            sp,
            format("cannot prove the invariant of '{}' {}", name.as_str(), what),
            String::from_str(
                "the code of a struct's file proves its invariant wherever a value leaves a body, and where a panic may unwind past it",
            ),
        );
        self.inv_goal = false;
        // Proved: a fact of the path from here (`inv_proved`).
        return pick(ok0 && !self.over && !self.failed.contains_key(&(OB_TYPE_INV << 56 | key)), f, NONE);
    }

    // The values of body `b` a panic at `sp` would leave to the code that unwinds: each local and
    // `&mut` parameter of a struct type with an invariant (`inv_locs`) satisfies it (a value the walk
    // assumed it of takes no proof: `inv_need`).
    fn inv_unwind(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &Vector<u32>,
        pc: &Vector<u32>,
        key: u64,
        sp: tok::Span,
        what: str,
        skip: u32,
    ) Vector<u32> {
        let mut out = Vector::<u32>::new();
        if self.ghost_fn {
            return out;
        }
        // An operation or a check of a body with contracts panics only where its `panics if` holds (keys 7
        // and 6); a call or a drop runs code that may panic anywhere.
        let mut pcp = Vector::<u32>::new();
        let own = key >> 52 == 6 || key >> 52 == 7;
        let cond = own && self.no_panic && self.pan_cond != NONE;
        if cond {
            pcp = pc.clone();
            pcp.push(self.pan_cond);
        }
        let pu = pick(cond, &pcp, pc);
        // At a call or a drop: the blocks of the values left to unwind, by local, which must be distinct
        // (the unwinding frees each value's), and are after it (`inv_resume`).
        let sep = key >> 52 == 3 || key >> 52 == 8 || key >> 52 == 9;
        let mut ats = Vector::<u32>::new(); // atom, claim guard, local
        for j in 0..self.inv_locs.len() {
            let l = self.inv_locs[j] as usize;
            if l as u32 == skip || self.inv_dead.contains(&(l as u32)) {
                continue;
            }
            let v = state[l];
            let ty = self.loc_ty(b, l);
            let f = self.inv_need(b, state, pu, ty, v, key | l as u64 << 32, sp, what);
            // Proved under the path's facts alone (no `panics if`): a fact of the path from here.
            if f != NONE && !cond {
                out.push(f);
            }
            if sep && f != NONE {
                let ov = self.ov;
                let mut hg = Vector::<u64>::new();
                self.held_g(f, ov, &mut hg);
                for q in 0..hg.len() {
                    let h = (hg[q] >> 32) as u32;
                    let g = self.guard_or(h, (hg[q] & 0xFFFFFFFFu64) as u32);
                    ats.push(h);
                    ats.push(g);
                    ats.push(l as u32);
                }
            }
        }
        // The blocks the shared parameters lend: no value left holds one (`lent_claims`).
        let mut pl = pu.clone();
        if sep && ats.len() != 0 {
            self.lent_claims(b, state, &mut pl, &mut ats);
        }
        if sep && ats.len() > 3 {
            let mut g = self.tm.boolean(true);
            let mut i: usize = 0;
            while i < ats.len() {
                let mut j = i + 3;
                while j < ats.len() {
                    let refs = (ats[i + 2] & SRC_REF) != 0 && (ats[j + 2] & SRC_REF) != 0;
                    if (ats[i] != ats[j] || ats[i + 2] != ats[j + 2]) && !refs {
                        let p = (*self.held_p.get(&ats[i]).unwrap() >> 32) as u32;
                        let p2 = (*self.held_p.get(&ats[j]).unwrap() >> 32) as u32;
                        let d = self.apart_need(ats[i + 1], p, ats[j + 1], p2);
                        g = self.tm.and(g, d);
                    }
                    j += 3;
                }
                i += 3;
            }
            if !self.tm.is_true(g) && !self.apart_holds(&pl, g) {
                self.oblige(
                    &pl,
                    g,
                    OB_TYPE_INV << 56 | key | 0xFFFFFu64 << 32,
                    sp,
                    format("cannot prove that the values left {} hold distinct blocks", what),
                    String::from_str("each block has one holder: two values that hold one block free it twice"),
                );
            }
        }
        return out;
    }

    // The invariants a check proved, facts of path `pc` from here: a later check of the same value is stated.
    fn inv_proved(pc: &mut Vector<u32>, fs: &Vector<u32>) {
        for j in 0..fs.len() {
            if !pc.contains(&fs[j]) {
                pc.push(fs[j]);
            }
        }
    }

    // The condition under which operation `rv` panics in `state`: never for a pointer offset; an integer
    // `+`, `-` or `*` whose exact result is outside its type; an unsigned division or remainder by 0. NONE
    // for another operation, which may panic anywhere.
    fn op_panics(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, rv: &ir::Rvalue) u32 {
        if rv.kind != ir::RV_BINARY {
            return NONE;
        }
        let op = rv.c;
        let xty = cb.operands.at(rv.a as usize).ty;
        if xty != TYPE_NONE && self.raw_ptr_ty(cm, xty) {
            return self.tm.boolean(false);
        }
        // A float operation never panics.
        if self.float_w(cm, xty) != 0 {
            return self.tm.boolean(false);
        }
        let x = self.operand(cb, cm, state, rv.a, false);
        let y = self.operand(cb, cm, state, rv.b, false);
        if !self.tm.is_int(x) || !self.tm.is_int(y) {
            return NONE;
        }
        let xt = self.tm.at(x);
        if xt.w <= W_BOOL || exact_w(xt.w) || self.tm.at(y).w != xt.w || self.tm.at(y).sg != xt.sg {
            return NONE;
        }
        let to = if op == tt::TokenType::Plus as u8 {
            T_ADD
        } else if op == tt::TokenType::Minus as u8 {
            T_SUB
        } else if op == tt::TokenType::Star as u8 {
            T_MUL
        } else {
            0
        };
        if to != 0 {
            let e = self.tm.arith(to, x, y, xt.w, xt.sg);
            let fits = self.tm.in_range(e);
            return self.tm.not(fits);
        }
        if (op == tt::TokenType::Slash as u8 || op == tt::TokenType::Percent as u8) && !xt.sg {
            let z = self.tm.int(Num::<B>::zero(), xt.w, false);
            return self.tm.cmp(T_EQ, y, z);
        }
        return NONE;
    }

    // Whether rvalue `rv` may panic: arithmetic that may overflow, a division or a remainder, a shift, a
    // negation, a library conversion, a check.
    const fn may_panic(rv: &ir::Rvalue) bool {
        if rv.kind == ir::RV_BINARY {
            let op = rv.c;
            return op == tt::TokenType::Plus as u8 || op == tt::TokenType::Minus as u8 || op == tt::TokenType::Star as u8 || op == tt::TokenType::Slash as u8 || op == tt::TokenType::Percent as u8 || op == tt::TokenType::LeftShift as u8 || op == tt::TokenType::RightShift as u8;
        }
        if rv.kind == ir::RV_UNARY {
            return rv.b as u8 == tt::TokenType::Minus as u8;
        }
        if rv.kind == ir::RV_CAST {
            return rv.b == ir::CAST_COERCE_FROM as u32;
        }
        return rv.kind == ir::RV_INTRINSIC && ir::is_check(rv.c);
    }

    // The type of local or slot `l` of body `b`.
    const fn loc_ty(self: &Self, b: &ir::CoreBody, l: usize) TypeId {
        return if l < b.locals.len() {
            b.locals.at(l).ty
        } else {
            self.slot_ty[l - b.locals.len()]
        };
    }

    // The locals and slots of body `b` of a struct type with an invariant its file proves (`inv_here`).
    fn inv_scan(self: &mut Self, b: &ir::CoreBody) {
        self.inv_locs.clear();
        self.inv_end = NONE;
        if self.ghost_fn {
            return;
        }
        // `Free::free` ends its receiver's life: nothing reads the receiver after it, also not after its
        // panic, so the invariant holds only at its entry.
        let ends = self.iface_method(b.owner, &self.freel) == "free" && b.args != 0;
        let recv = b.returns as usize;
        let recv_slot = if ends {
            self.slot_of[recv]
        } else {
            NONE
        };
        self.inv_end = recv_slot;
        for l in 0..b.locals.len() + self.slot_ty.len() {
            if ends && (l == recv || l as u32 == recv_slot) {
                continue;
            }
            if self.inv_here(b.module, self.loc_ty(b, l)) {
                self.inv_locs.push(l as u32);
            }
        }
    }

    // The value argument `j` of call `t` passes (the target of a reference), and its type.
    fn arg_target(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, j: u32) (TypeId, u32) {
        let oid = b.oper_pool[(t.args_start + j) as usize];
        let op = *b.operands.at(oid as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return TYPE_NONE, NONE;
        }
        let x = self.operand(b, b.module, &mut path.state, oid, false);
        if self.autoref(b, b.module, t, j) {
            return op.ty, x;
        }
        let y = *self.ast_of(b.module).type_at(op.ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return y.as_data.elem, self.deref(&path.state, x, b.module, y.as_data.elem);
        }
        return op.ty, x;
    }

    // Whether pointer value `x` reaches memory outside the body's locals and `&mut` parameters: memory a
    // raw pointer, a call's reference or a shared parameter reaches, whose values left a body.
    const fn foreign(self: &Self, x: u32) bool {
        if x == NONE {
            return false;
        }
        let op = self.tm.at(x).op;
        return op != T_MREF && op != T_PREF && op != T_REF;
    }

    // The first dereference of place `p` of body `b` that reads foreign memory (`foreign`): its projection
    // index, or the projection count for none.
    fn foreign_deref(self: &mut Self, b: &ir::CoreBody, state: &mut Vector<u32>, p: &ir::Place) u32 {
        for k in 0..p.proj_len {
            if b.projections.at((p.proj_start + k) as usize).kind == ir::PJ_DEREF && self.foreign(
                self.read_prefix(b, b.module, state, p, k, false),
            ) {
                return k;
            }
        }
        return p.proj_len;
    }

    // Whether argument `j` of call `t` passes foreign memory (`foreign`): a place through such a
    // dereference, or such a reference.
    fn arg_foreign(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, j: u32) bool {
        let oid = b.oper_pool[(t.args_start + j) as usize];
        let op = *b.operands.at(oid as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return false;
        }
        if self.autoref(b, b.module, t, j) {
            let p = *b.places.at(op.data as usize);
            return self.foreign_deref(b, &mut path.state, &p) < p.proj_len;
        }
        if self.ast_of(b.module).type_at(op.ty).kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        let x = self.operand(b, b.module, &mut path.state, oid, false);
        return self.foreign(x);
    }

    // Assume the invariant of the value argument `j` of call `t` passes, which foreign memory holds: every
    // value there left a body that proved it, and a write there keeps it (`stmt`).
    fn inv_assume_arg(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, j: u32) u32 {
        let (ty, v) = self.arg_target(b, path, t, j);
        if v == NONE || !self.inv_here(b.module, ty) {
            return NONE;
        }
        let f = self.inv_of(b.module, ty, v, &path.state);
        if f != NONE && !path.pc.contains(&f) {
            path.pc.push(f);
        }
        return f;
    }

    // Before call `t` of body `b`: the callee assumes the invariant of each value it receives, and a panic
    // in it unwinds past the body's values (`inv_unwind`).
    fn inv_call(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        if self.ghost_fn || self.is_ghost(t.callee) || self.exits(t.callee) {
            return;
        }
        for j in 0..t.args_len {
            // A shared borrow lends the value's blocks: the callee takes none (`inv_lent`).
            let shared = self.arg_shared(b, t, j);
            if self.arg_foreign(b, path, t, j) {
                let f = self.inv_assume_arg(b, path, t, j);
                self.src_mark(f, 1 + j | SRC_MEM);
                self.ov_name_as(f, 1 + j | pick(shared, SRC_REF, 0u32), !shared);
                continue;
            }
            let (ty, v) = self.arg_target(b, path, t, j);
            let f = self.inv_need(
                b,
                &path.state,
                &path.pc,
                ty,
                v,
                2 << 52 | j as u64 << 32 | t.span.start as u64,
                t.span,
                "at this call",
            );
            self.ov_name_as(f, 1 + j | pick(shared, SRC_REF, 0u32), !shared);
            if f != NONE && !path.pc.contains(&f) {
                path.pc.push(f);
            }
        }
        let fs = self.inv_unwind(
            b,
            &path.state,
            &path.pc,
            3 << 52 | t.span.start as u64,
            t.span,
            "where this call may panic",
            NONE,
        );
        Self::inv_proved(&mut path.pc, &fs);
    }

    // After call `t` of body `b`: each local and `&mut` parameter of a struct type with an invariant
    // satisfies it. Each did before the call (`inv_unwind`); the call changes one only through a `&mut`,
    // and the callee proves it again there, or returns a value it proved it of.
    // Whether argument `j` of call `t` is a shared borrow: the callee's parameter is a `&` reference (a
    // `&mut` the caller holds is lent as `&`), or the argument is one.
    fn arg_shared(self: &Self, b: &ir::CoreBody, t: &ir::Terminator, j: u32) bool {
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return false;
        }
        if self.shared_param(t, j) {
            return true;
        }
        let oy = *self.ast_of(b.module).type_at(op.ty);
        return !self.autoref(b, b.module, t, j) && oy.kind == TypeKind::TYPE_REFERENCE && oy.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
    }

    // The values call `t` borrowed shared keep their invariants, in the version after the call: it took
    // none of their blocks, and no clause's (`ov_apart`).
    fn inv_lent(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        if self.ghost_fn || self.is_ghost(t.callee) {
            return;
        }
        for j in 0..t.args_len {
            if !self.arg_shared(b, t, j) {
                continue;
            }
            if self.arg_foreign(b, path, t, j) {
                let f = self.inv_assume_arg(b, path, t, j);
                self.src_mark(f, 1 + j | SRC_REF);
                continue;
            }
            let lk = OB_TYPE_INV << 56 | 2 << 52 | j as u64 << 32 | t.span.start as u64;
            let (ty, v) = self.arg_target(b, path, t, j);
            if v != NONE && !self.failed.contains_key(&lk) && self.inv_here(b.module, ty) {
                let f = self.inv_of(b.module, ty, v, &path.state);
                self.src_mark(f, 1 + j | SRC_REF);
                if f != NONE && !path.pc.contains(&f) {
                    path.pc.push(f);
                }
            }
        }
    }

    fn inv_called(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        if self.ghost_fn || self.is_ghost(t.callee) {
            return;
        }
        for j in 0..t.args_len {
            // A shared borrow's value keeps its blocks, in the version after the call (`inv_lent`).
            let shared = self.arg_shared(b, t, j);
            if self.arg_foreign(b, path, t, j) {
                if !shared {
                    let _ = self.inv_assume_arg(b, path, t, j);
                }
                continue;
            }
            // A value the call borrowed: it needed the invariant (`inv_call`), and the callee proves it
            // again at its return (`free`'s receiver too, which `inv_locs` leaves out). A value the call
            // took is the callee's, its blocks too.
            let lk = OB_TYPE_INV << 56 | 2 << 52 | j as u64 << 32 | t.span.start as u64;
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            let oy = *self.ast_of(b.module).type_at(op.ty);
            let auto = self.autoref(b, b.module, t, j);
            if !auto && (op.ty == TYPE_NONE || oy.kind != TypeKind::TYPE_REFERENCE) {
                continue;
            }
            if shared {
                continue;
            }
            let (ty, v) = self.arg_target(b, path, t, j);
            if v != NONE && !self.failed.contains_key(&lk) && self.inv_here(b.module, ty) {
                let sj = 1 + j;
                let s0 = replace(&mut self.ov_src, sj);
                let f = self.inv_of(b.module, ty, v, &path.state);
                self.src_mark(f, sj);
                self.sh_give(f);
                self.ov_src = s0;
                if f != NONE && !path.pc.contains(&f) {
                    path.pc.push(f);
                }
            }
        }
        // The values the call did not reach keep their invariants (`inv_unwind`), with no source of their
        // own (`ov_src`).
        // The call's result: its value left the callee, which proved its invariant, in the version after.
        let mut dest = NONE;
        if t.dests_len == 1 {
            let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
            if dp.proj_len == 0 && self.inv_locs.contains(&dp.base) {
                dest = dp.base;
                let v = path.state[dest as usize];
                if v != NONE {
                    let s1 = replace(&mut self.ov_src, SRC_RES);
                    let f = self.inv_of(b.module, self.loc_ty(b, dest as usize), v, &path.state);
                    self.src_mark(f, SRC_RES);
                    self.sh_give(f);
                    self.ov_src = s1;
                    if f != NONE && !path.pc.contains(&f) {
                        path.pc.push(f);
                    }
                }
            }
        }
        let s0 = replace(&mut self.ov_src, 0);
        self.inv_resume(b, path, 3 << 52 | t.span.start as u64, dest);
        self.ov_src = s0;
    }

    // After the code a call or a drop runs (unwind check `key`): each local but `dead`, and each target of a
    // shared reference parameter, satisfies its invariant again.
    fn inv_resume(self: &mut Self, b: &ir::CoreBody, path: &mut Path, key: u64, dead: u32) {
        // In the version the check proved them in: a block the call or the drop took may be one a local
        // holds, and the later versions' facts follow from these where it is not (`ov_frame`).
        let ov0 = replace(&mut self.ov, self.ov_pre);
        self.inv_resume_at(b, path, key, dead);
        self.ov = ov0;
    }

    // The value of `free`'s receiver (`inv_end`) in `state`, NONE in another body.
    const fn recv_val(self: &Self, state: &Vector<u32>) u32 {
        return if self.inv_end == NONE {
            NONE
        } else {
            state[self.inv_end as usize]
        };
    }

    fn inv_resume_at(self: &mut Self, b: &ir::CoreBody, path: &mut Path, key: u64, dead: u32) {
        // `free`'s receiver, which `inv_locs` leaves out: memory holds the invariant of a value (code of the
        // struct's file writes it, and proves it), so it holds after the call or the drop where it held
        // before.
        let rs = self.inv_end;
        let r1 = self.recv_val(&path.state);
        // Not where a reference reaches a member of it (`aesc`): through one, code of another file may write
        // a member the invariant reads. A reference to the whole value writes none of its private members
        // but by a method of its file, which keeps the invariant.
        let mut reached = false;
        for j in 0..self.aesc.len() {
            reached = reached || self.ref_target(self.aesc[j]) == rs;
        }
        if r1 != NONE && self.recv_pre != NONE && r1 != self.recv_pre && !reached {
            let rty = self.loc_ty(b, rs as usize);
            let f0 = self.inv_of(b.module, rty, self.recv_pre, &path.state);
            let f1 = self.inv_of(b.module, rty, r1, &path.state);
            if f0 != NONE && f1 != NONE {
                let nf0 = self.tm.not(f0);
                path.pc.push(self.tm.or(nf0, f1));
            }
        }
        for j in 0..self.inv_locs.len() {
            let l = self.inv_locs[j] as usize;
            let v = path.state[l];
            // A local whose invariant the check could not prove keeps its facts: assuming it would hide the
            // errors after it.
            let lk = OB_TYPE_INV << 56 | key | l as u64 << 32;
            if v != NONE && l as u32 != dead && !self.failed.contains_key(&lk) {
                let s0 = replace(&mut self.ov_src, SRC_LOC | l as u32);
                let f = self.inv_of(b.module, self.loc_ty(b, l), v, &path.state);
                self.src_mark(f, SRC_LOC | l as u32);
                self.ov_src = s0;
                if f != NONE && !path.pc.contains(&f) {
                    path.pc.push(f);
                }
            }
        }
        // A shared reference parameter's target: nothing changes the fields its invariant reads while the
        // body runs (they hold no cell), and it held at the entry.
        for l in b.returns..b.returns + b.args {
            let y = *self.ast_of(b.module).type_at(b.locals.at(l as usize).ty);
            if y.kind != TypeKind::TYPE_REFERENCE || y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 || !self.inv_here(
                b.module,
                y.as_data.elem,
            ) {
                continue;
            }
            let v = self.deref(&path.state, path.state[l as usize], b.module, y.as_data.elem);
            if v != NONE {
                let f = self.inv_of(b.module, y.as_data.elem, v, &path.state);
                if f != NONE && !path.pc.contains(&f) {
                    path.pc.push(f);
                }
            }
        }
    }

    // At the entry of body `b` of a struct's own file: the invariant of each parameter of the struct's type
    // or a reference to it, into `pc`; a spec function's and a lemma's too, but the invariant's own method.
    fn inv_enter(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pc: &mut Vector<u32>) {
        self.ent_ref.clear();
        for l in b.returns..b.returns + b.args {
            let sl = self.slot_of[l as usize];
            let (ty, v) = if sl != NONE {
                (self.slot_ty[sl as usize - b.locals.len()], state[sl as usize])
            } else {
                let lt = b.locals.at(l as usize).ty;
                let y = *self.ast_of(b.module).type_at(lt);
                if y.kind == TypeKind::TYPE_REFERENCE {
                    (y.as_data.elem, self.deref(state, state[l as usize], b.module, y.as_data.elem))
                } else {
                    (lt, state[l as usize])
                }
            };
            // Not in the invariant's own method, which defines it.
            let mut binds = Vector::<u64>::new();
            let im = self.inv_method(b.module, ty, &mut binds);
            if v != NONE && self.inv_here(b.module, ty) && !(im.node == b.owner.node && im.module == b.owner.module) {
                let lt = *self.ast_of(b.module).type_at(b.locals.at(l as usize).ty);
                let shared = lt.kind == TypeKind::TYPE_REFERENCE && lt.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
                self.ov_src = l + 1 | pick(shared, SRC_REF, 0u32);
                let f = self.inv_of(b.module, ty, v, state);
                let s1 = self.ov_src;
                self.src_mark(f, s1);
                self.ov_src = 0;
                if f != NONE {
                    pc.push(f);
                    if shared {
                        self.ent_ref.push(l);
                        self.ent_ref.push(s1);
                    }
                }
            }
        }
    }

    // At a return of body `b`: its results and its `&mut` parameters' values satisfy their invariants, and
    // the blocks they and the `ensures` clauses give the caller are distinct (the caller assumes it).
    fn inv_return(self: &mut Self, b: &ir::CoreBody, path: &Path, sp: tok::Span) {
        let mut ats = Vector::<u32>::new(); // atom, claim guard, source
        let mut facts = path.ens.clone(); // the facts that give the caller blocks or units
        let v0 = self.ov;
        self.ov = path.ov;
        for j in 0..path.ens.len() {
            self.claims_at(path.ens[j], SRC_RES, &mut ats);
        }
        for l in 0..b.returns {
            let v = path.state[l as usize];
            let f = self.inv_need(
                b,
                &path.state,
                &path.pc,
                b.locals.at(l as usize).ty,
                v,
                1 << 52 | l as u64 << 32 | sp.start as u64,
                sp,
                "at this return",
            );
            self.claims_at(f, SRC_RES, &mut ats);
            facts.push(f);
        }
        for k in 0..self.slot_ty.len() {
            if (b.locals.len() + k) as u32 == self.inv_end {
                continue;
            }
            let v = path.state[b.locals.len() + k];
            let ty = self.slot_ty[k];
            let f = self.inv_need(
                b,
                &path.state,
                &path.pc,
                ty,
                v,
                4 << 52 | k as u64 << 32 | sp.start as u64,
                sp,
                "at this return",
            );
            self.claims_at(f, 1 + k as u32, &mut ats);
            facts.push(f);
        }
        // The blocks a shared parameter lends: no result or `&mut` parameter may claim one too. The units
        // all of them claim: the body holds them all.
        let mut pc = path.pc.clone();
        let mut sh = Vector::<u32>::new();
        for j in 0..facts.len() {
            self.sh_claims(facts[j], path.ov, &mut sh);
        }
        let mut lsh = Vector::<u32>::new();
        self.lent_claims_sh(b, &path.state, &mut pc, &mut ats, &mut lsh);
        let g0 = self.apart_all(&ats);
        let g = if sh.len() != 0 {
            let f = self.sh_fit(&sh, &lsh);
            self.tm.and(g0, f)
        } else {
            g0
        };
        if !self.tm.is_true(g) && !self.apart_holds(&pc, g) {
            self.oblige(
                &pc,
                g,
                OB_TYPE_INV << 56 | 10 << 52 | sp.start as u64,
                sp,
                String::from_str("cannot prove that the blocks this return gives are distinct"),
                String::from_str(
                    "each block has one holder: the results, the '&mut' parameters and the 'ensures' clauses name distinct blocks",
                ),
            );
        }
        self.ov = v0;
    }

    // The shared parameters' invariants in the walk's version, facts of `pc` and sources (`src_mark`): their
    // blocks are the caller's, lent to the body, which takes none of them (`lent_take`), so every version
    // holds them. Their claims (atom, guard, source) appended to `out`.
    fn lent_claims(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pc: &mut Vector<u32>, out: &mut Vector<u32>) {
        let mut sh = Vector::<u32>::new();
        self.lent_claims_sh(b, state, pc, out, &mut sh);
    }

    // `lent_claims`, and their units claims (share atom, guard) appended to `sh`.
    fn lent_claims_sh(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &Vector<u32>,
        pc: &mut Vector<u32>,
        out: &mut Vector<u32>,
        sh: &mut Vector<u32>,
    ) {
        let mut q: usize = 0;
        while q < self.ent_ref.len() {
            let (l, src) = (self.ent_ref[q], self.ent_ref[q + 1]);
            q += 2;
            let lt = *self.ast_of(b.module).type_at(b.locals.at(l as usize).ty);
            let v = self.deref(state, state[l as usize], b.module, lt.as_data.elem);
            if v == NONE {
                continue;
            }
            let f = self.inv_of(b.module, lt.as_data.elem, v, state);
            if f == NONE {
                continue;
            }
            self.src_mark(f, src);
            if !pc.contains(&f) {
                pc.push(f);
            }
            self.claims_at(f, src, out);
            let v0 = self.ov;
            self.sh_claims(f, v0, sh);
        }
    }

    // The atoms a removal takes (`tk`: atom, claim guard pairs) at `sp`: none is a block a shared parameter
    // lends (`lent_claims`).
    fn lent_take(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &Vector<u32>,
        pc: &mut Vector<u32>,
        tk: &Vector<u32>,
        sp: tok::Span,
    ) {
        if self.ent_ref.len() == 0 || tk.len() == 0 && self.ov_take_sh.len() == 0 || self.ghost_fn {
            return;
        }
        let mut ats = Vector::<u32>::new();
        let tsh = self.ov_take_sh.clone();
        let mut lsh = Vector::<u32>::new();
        self.lent_claims_sh(b, state, pc, &mut ats, &mut lsh);
        // The units taken and those lent: the body holds them all.
        let mut g = if tsh.len() != 0 && lsh.len() != 0 {
            self.sh_fit(&tsh, &lsh)
        } else {
            self.tm.boolean(true)
        };
        let mut i: usize = 0;
        while i < tk.len() {
            let p = (*self.held_p.get(&tk[i]).unwrap() >> 32) as u32;
            let mut j: usize = 0;
            while j < ats.len() {
                let p2 = (*self.held_p.get(&ats[j]).unwrap() >> 32) as u32;
                let d = self.apart_need(tk[i + 1], p, ats[j + 1], p2);
                g = self.tm.and(g, d);
                j += 3;
            }
            i += 2;
        }
        if !self.tm.is_true(g) && !self.apart_holds(pc, g) {
            self.oblige(
                pc,
                g,
                OB_TYPE_INV << 56 | 13 << 52 | sp.start as u64,
                sp,
                String::from_str("cannot prove that this takes no block a shared parameter lends"),
                String::from_str("a shared borrow's blocks are the caller's: the body frees or moves none of them"),
            );
        }
    }

    // Append the claimed held atoms of the walk's version that fact `f` names (`held_g`), each as atom,
    // claim guard, `src`.
    fn claims_at(self: &mut Self, f: u32, src: u32, out: &mut Vector<u32>) {
        if f == NONE {
            return;
        }
        let v = self.ov;
        let mut hg = Vector::<u64>::new();
        self.held_g(f, v, &mut hg);
        for q in 0..hg.len() {
            let h = (hg[q] >> 32) as u32;
            out.push(h);
            out.push(self.guard_or(h, (hg[q] & 0xFFFFFFFFu64) as u32));
            out.push(src);
        }
    }

    // That the claims `ats` lists (atom, guard, source) are pairwise distinct blocks: one atom claimed
    // twice by one source is one claim, and two shared borrows may be one value.
    fn apart_all(self: &mut Self, ats: &Vector<u32>) u32 {
        let mut g = self.tm.boolean(true);
        let mut i: usize = 0;
        while i < ats.len() {
            let mut j = i + 3;
            while j < ats.len() {
                let refs = ats[i + 2] != ats[j + 2] && (ats[i + 2] & SRC_REF) != 0 && (ats[j + 2] & SRC_REF) != 0;
                if (ats[i] != ats[j] || ats[i + 2] != ats[j + 2]) && !refs {
                    let p = (*self.held_p.get(&ats[i]).unwrap() >> 32) as u32;
                    let p2 = (*self.held_p.get(&ats[j]).unwrap() >> 32) as u32;
                    let d = self.apart_need(ats[i + 1], p, ats[j + 1], p2);
                    let e = self.held_apart(ats[i], ats[j], d);
                    g = self.tm.and(g, e);
                }
                j += 3;
            }
            i += 3;
        }
        return g;
    }

    // `d`, the distinctness of the blocks of held atoms `h` and `h2`, where both hold: the obligations
    // that name them prove that they hold, and their definitions say which versions gave the blocks
    // (an ADD's are no block held before it).
    fn held_apart(self: &mut Self, h: u32, h2: u32, d: u32) u32 {
        if self.tm.is_true(d) {
            return d;
        }
        let nh = self.tm.not(h);
        let nh2 = self.tm.not(h2);
        let o = self.tm.or(nh2, d);
        return self.tm.or(nh, o);
    }

    // Whether body `b`, outside ghost code, holds a value of a struct type with an invariant its own file
    // proves (`inv_here`), or a reference to one: its walk proves the invariant where the value leaves.
    fn inv_body(self: &Self, b: &ir::CoreBody) bool {
        if self.is_ghost(b.owner) {
            return false;
        }
        for l in 0..b.locals.len() {
            let lt = b.locals.at(l).ty;
            if lt == TYPE_NONE {
                continue;
            }
            let y = *self.ast_of(b.module).type_at(lt);
            let ty = pick(y.kind == TypeKind::TYPE_REFERENCE, y.as_data.elem, lt);
            if self.inv_here(b.module, ty) {
                return true;
            }
        }
        return false;
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
        return self.fresh_in(m, ty, false);
    }

    // `fresh`; one term, not the aggregate of its members (`eta`), `in_union`: a value below a union's
    // member, whose bytes the union's value is (`union_coherence`).
    fn fresh_in(self: &mut Self, m: ModuleId, ty: TypeId, in_union: bool) u32 {
        let (w, sg) = self.ty_of(m, ty);
        let v = self.tm.var(w, sg);
        self.pat_fact(m, ty, v);
        self.len_cap(m, ty, v);
        return pick(in_union, v, self.eta(m, ty, v, 0));
    }

    // Whether a projection of place `p` from `from` on selects a union's member.
    const fn union_below(self: &Self, cb: &ir::CoreBody, p: &ir::Place, from: u32) bool {
        for j in from..p.proj_len {
            let pj = cb.projections.at((p.proj_start + j) as usize);
            if pj.kind == ir::PJ_FIELD && pj.data == ir::PJ_UNION_FIELD {
                return true;
            }
        }
        return false;
    }

    // Whether reference `r` (`T_PREF`) reaches a member below a union's member.
    fn pref_union(self: &Self, r: u32) bool {
        let e = self.tm.at(r).a as usize;
        for q in 0..self.pref_n[e] {
            let (cm, cty) = self.pref_cty(e, q);
            if self.is_union_ty(cm, cty) {
                return true;
            }
        }
        return false;
    }

    // The bound on the length of `v`, a slice or vector of type `ty` (module `m`, or a reference to
    // one) whose element has a size: at most `isize::MAX` over that size, since no object is larger.
    fn len_cap(self: &mut Self, m: ModuleId, ty: TypeId, v: u32) {
        if ty == TYPE_NONE {
            return;
        }
        let (m0, t0) = self.resolve(m, ty);
        let y0 = *self.ast_of(m0).type_at(t0);
        let (m1, t1) = if y0.kind == TypeKind::TYPE_REFERENCE {
            self.resolve(m0, y0.as_data.elem)
        } else {
            (m0, t0)
        };
        let y = *self.ast_of(m1).type_at(t1);
        let (view, et) = if y.kind == TypeKind::TYPE_SLICE {
            (true, y.as_data.elem)
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(m1).instance(y.as_data.inst);
            let view = it.module == self.slice.mid && it.decl == self.slice.node || it.module == self.smut.mid && it.decl == self.smut.node;
            let vec = it.module == self.vecl.mid && it.decl == self.vecl.node;
            if !view && !vec || it.decl == NODE_NONE || it.n < 1 {
                return;
            }
            (view, it.args[0])
        } else {
            return;
        };
        let l = self.lsv.layout(m1, et);
        if l.ok && l.size == 0 {
            return;
        }
        let n = self.sq1(pick(view, SQ_SLEN, SQ_VLEN), v, self.pw, false);
        if self.capd.contains_key(&n) {
            return;
        }
        self.capd.insert(n, true);
        let imax = self.tm.int(wide::<B>(((1u64 << self.pw - 1) - 1) as i64), self.pw, false);
        let f = if l.ok {
            let cap = self.tm.int(wide::<B>((((1u64 << self.pw - 1) - 1) / l.size) as i64), self.pw, false);
            self.tm.cmp(T_LE, n, cap)
        } else {
            // A size known per instance: `isize::MAX / sizeof(T)` where the size is not 0, as
            // `Vector::max_len` spells it.
            let sz = self.size_term(m1, et);
            let z = self.tm.int(Num::<B>::zero(), self.pw, false);
            let zs = self.tm.cmp(T_EQ, sz, z);
            let cap = self.tm.arith(T_DIV, imax, sz, self.pw, false);
            let le = self.tm.cmp(T_LE, n, cap);
            self.tm.or(zs, le)
        };
        self.anchor(n, f);
    }

    // Value `v` of type `ty` (module `m`) as the aggregate of its members where `ty` is a small frozen
    // struct or array (at most ETA_MAX members, ETA_DEPTH deep): an unknown value of `[Secret<u32>; 16]`
    // is the array of its sixteen members, so two values of the type are equal where their members are
    // (`Terms::cmp`).
    // The types of the members of struct type `ty` (module `m`), in order, as `module << 32 | type` (a
    // type parameter's argument in `m`'s instance); none for another type.
    fn member_types(self: &Self, m: ModuleId, ty: TypeId, out: &mut Vector<u64>) {
        if ty == TYPE_NONE {
            return;
        }
        let (m1, t1) = self.resolve(m, ty);
        let y = *self.ast_of(m1).type_at(t1);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return;
        }
        let (dm, dn, inst) = if y.kind == TypeKind::TYPE_STRUCT {
            (y.module, y.as_data.decl, TyInstance { module: 0, decl: NODE_NONE, n: 0, args: [TYPE_NONE; 8], lts: 0 })
        } else {
            let it = *self.ast_of(m1).instance(y.as_data.inst);
            (it.module, it.decl, it)
        };
        let da = self.ast_of(dm);
        if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return;
        }
        let ag = unsafe da.ext(dn).aggregate;
        for j in 0..ag.members.len {
            let mt = da.member_ty(unsafe da.list(ag.members)[j as usize]);
            let my = da.type_at(mt);
            if my.kind != TypeKind::TYPE_GENERIC {
                out.push(dm as u64 << 32 | mt as u64);
                continue;
            }
            let mut at = TYPE_NONE;
            for i in 0..ag.generics.len {
                if unsafe da.list(ag.generics)[i as usize] == my.as_data.decl && i as u8 < inst.n {
                    at = inst.args[i as usize];
                }
            }
            out.push(m1 as u64 << 32 | at as u64);
        }
    }

    // The zero value of type `ty` (module `m`), which an omitted member of a literal holds: an integer 0,
    // `false`, `null`, or a struct or an array of at most ETA_MAX members of zero values; NONE for
    // another type.
    fn zero_value(self: &mut Self, m: ModuleId, ty: TypeId, depth: u32) u32 {
        if depth >= ETA_DEPTH || ty == TYPE_NONE {
            return NONE;
        }
        let (m1, t1) = self.resolve(m, ty);
        let y = *self.ast_of(m1).type_at(t1);
        if y.kind == TypeKind::TYPE_POINTER {
            return self.null_ptr();
        }
        let (w, sg) = self.ty_of(m1, t1);
        if w == W_BOOL {
            return self.tm.boolean(false);
        }
        if w > W_BOOL {
            return self.tm.int(Num::<B>::zero(), w, sg);
        }
        let mut xs = Vector::<u32>::new();
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() && y.as_data.arr.len as u64 <= ETA_MAX {
            let z = self.zero_value(m1, y.as_data.arr.elem, depth + 1);
            if z == NONE {
                return NONE;
            }
            for _k in 0..y.as_data.arr.len {
                xs.push(z);
            }
            return self.tm.pool(T_AGG, &xs, Num::<B>::zero());
        }
        let mut mtys = Vector::<u64>::new();
        self.member_types(m1, t1, &mut mtys);
        if mtys.len() == 0 || mtys.len() as u64 > ETA_MAX {
            return NONE;
        }
        for j in 0..mtys.len() {
            let z = self.zero_value((mtys[j] >> 32) as ModuleId, (mtys[j] & 0xFFFFFFFFu64) as TypeId, depth + 1);
            if z == NONE {
                return NONE;
            }
            xs.push(z);
        }
        return self.tm.pool(T_AGG, &xs, Num::<B>::zero());
    }

    fn eta(self: &mut Self, m: ModuleId, ty: TypeId, v: u32, depth: u32) u32 {
        // A value the walk reads as a number (a wide integer's struct) stays one term, and so does an array
        // a byte copy wrote (`mem_copy`): its elements are read where a formula names them.
        let vx = self.tm.at(v);
        if depth >= ETA_DEPTH || ty == TYPE_NONE || vx.op == T_AGG || vx.w != W_OTHER || vx.op == T_CALL && vx.k == u64_val::<
            B
        >(skey_mix(19, 0)) || !self.frozen(m, ty) {
            return v;
        }
        let (m1, t1) = self.resolve(m, ty);
        let y = *self.ast_of(m1).type_at(t1);
        let mut tys = Vector::<u64>::new();
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() && y.as_data.arr.len >= 1 && y.as_data.arr.len as u64 <= ETA_MAX {
            for _k in 0..y.as_data.arr.len {
                tys.push(m1 as u64 << 32 | y.as_data.arr.elem as u64);
            }
        } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE {
            let (dm, dn, inst) = if y.kind == TypeKind::TYPE_STRUCT {
                (
                    y.module,
                    y.as_data.decl,
                    TyInstance { module: 0, decl: NODE_NONE, n: 0, args: [TYPE_NONE; 8], lts: 0 }
                )
            } else {
                let it = *self.ast_of(m1).instance(y.as_data.inst);
                (it.module, it.decl, it)
            };
            let da = self.ast_of(dm);
            if da.at_const(dn).kind != NodeKind::NODE_STRUCT {
                return v;
            }
            let ag = unsafe da.ext(dn).aggregate;
            // A union's value is its bytes (`union_coherence`): its members stay terms of their own.
            if ag.is_tuple || ag.is_union || ag.members.len as u64 > ETA_MAX {
                return v;
            }
            for j in 0..ag.members.len {
                let mt = da.member_ty(unsafe da.list(ag.members)[j as usize]);
                let my = da.type_at(mt);
                // A handle (`Seq`'s pointer) is a value the walk models by its own term.
                if my.kind == TypeKind::TYPE_POINTER || my.kind == TypeKind::TYPE_REFERENCE {
                    return v;
                }
                if my.kind != TypeKind::TYPE_GENERIC {
                    tys.push(dm as u64 << 32 | mt as u64);
                    continue;
                }
                let mut at = TYPE_NONE;
                for i in 0..ag.generics.len {
                    if unsafe da.list(ag.generics)[i as usize] == my.as_data.decl && i as u8 < inst.n {
                        at = inst.args[i as usize];
                    }
                }
                let ak = pick(at == TYPE_NONE, TypeKind::TYPE_POINTER, self.ast_of(m1).type_at(at).kind);
                if ak == TypeKind::TYPE_POINTER || ak == TypeKind::TYPE_REFERENCE {
                    return v;
                }
                tys.push(m1 as u64 << 32 | at as u64);
            }
        } else {
            return v;
        }
        let mut xs = Vector::<u32>::with_capacity(tys.len());
        for j in 0..tys.len() {
            let em = (tys[j] >> 32) as ModuleId;
            let et = (tys[j] & 0xFFFFFFFFu64) as TypeId;
            let (ew, esg) = self.ty_of(em, et);
            let key = self.tm.int(wide::<B>(j as i64), 64, false);
            let e = self.tm.sel(v, key, ew, esg);
            xs.push(self.eta(em, et, e, depth + 1));
        }
        let agg = self.tm.pool(T_AGG, &xs, Num::<B>::zero());
        self.eta_src.insert(agg, v);
        return agg;
    }

    // The value const generic parameter `d` (of type `ty` of module `m`) is bound to in `subst` (a call's
    // const argument, an instance's), NONE where it is bound to none.
    fn const_arg(self: &mut Self, d: DefId, m: ModuleId, ty: TypeId) u32 {
        let key = d.module as u64 << 32 | d.node as u64;
        let mut j: usize = 0;
        while j < self.subst.len() {
            if self.subst[j] == key {
                let (m2, t2) = ((self.subst[j + 1] >> 32) as ModuleId, (self.subst[j + 1] & 0xFFFFFFFFu64) as TypeId);
                let y = *self.ast_of(m2).type_at(t2);
                // Bound to another parameter (`PoolClass<K>` in an `extend<const K: usize>`): that one's term.
                if y.kind == TypeKind::TYPE_GENERIC {
                    return self.param_var(DefId { module: y.module, node: y.as_data.decl }, m, ty);
                }
                if y.kind != TypeKind::TYPE_CONST {
                    return NONE;
                }
                let c = y.cval();
                let mut n = Num::<B>::zero();
                n.set_limb(0, c.limb(0));
                n.set_limb(1, c.limb(1));
                let (w, sg) = self.ty_of(m, ty);
                return self.tm.int(Terms::<B>::wrap(n, 128, true), w, sg);
            }
            j += 2;
        }
        return NONE;
    }

    // The unknown of const generic parameter `d` of type `ty` (of module `m`): one per body, so a
    // pattern's bound and each read of the parameter are one term.
    fn param_var(self: &mut Self, d: DefId, m: ModuleId, ty: TypeId) u32 {
        let key = d.module as u64 << 32 | d.node as u64;
        if let Some(v) = self.pvars.get(&key) {
            return *v;
        }
        let (w, sg) = self.ty_of(m, ty);
        let v = self.tm.var(w, sg);
        self.pvars.insert(key, v);
        return v;
    }

    // Value `v` of type `ty` (of module `m`) matches the pattern of a pattern type: the fact joins each
    // obligation whose terms reach `v`, as a spec function's definition does (`add_defs`). A range is
    // linear; a variant fixes the discriminant (`T_TAG`), the tag it carries.
    fn pat_fact(self: &mut Self, m: ModuleId, ty: TypeId, v: u32) {
        if ty == TYPE_NONE {
            return;
        }
        self.inv_fact(m, ty, v);
        let a = self.ast_of(m);
        let y = *a.type_at(ty);
        if !y.has_pat() {
            return;
        }
        let p = *a.type_at(y.pat());
        let mut f = NONE;
        if (p.qualifier & PK_VARIANT) != 0 {
            let mut dm = y.module;
            let mut dn = y.as_data.decl;
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *a.instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
            }
            // The tag the variant carries and the type a discriminant reads as (`lay::variant_tag`).
            let mut k = a.type_at(p.as_data.arr.elem).as_data.value;
            let mut neg = false;
            if self.ast_of(dm).enum_explicit(dn) && !lay::variant_tag(self.pkg(), dm, dn, k, &mut k, &mut neg) {
                return;
            }
            let t = self.tm.make(Term::<B> { k: Num::<B>::zero(), a: v, b: 0, op: T_TAG, w: 32, sg: neg });
            let kt = self.tm.int(wide::<B>(k), 32, neg);
            f = self.tm.cmp(T_EQ, t, kt);
        } else {
            if !self.tm.is_int(v) {
                return;
            }
            let (xw, xsg) = (self.tm.at(v).w, self.tm.at(v).sg);
            let base = self.pat_base_of(m, ty);
            for j in 0..2 {
                let bt = pick(j == 0, p.as_data.arr.elem, p.as_data.arr.len);
                if bt == TYPE_NONE {
                    continue;
                }
                let by = *self.ast_of(m).type_at(bt);
                let bv = if by.kind == TypeKind::TYPE_CONST {
                    let c = by.cval();
                    let mut n = Num::<B>::zero();
                    n.set_limb(0, c.limb(0));
                    n.set_limb(1, c.limb(1));
                    self.tm.int(Terms::<B>::wrap(n, 128, true), xw, xsg)
                } else if by.kind == TypeKind::TYPE_GENERIC {
                    self.param_var(DefId { module: by.module, node: by.as_data.decl }, m, base)
                } else {
                    NONE
                };
                if bv == NONE {
                    continue;
                }
                let c = if j == 0 {
                    self.tm.cmp(T_LE, bv, v)
                } else if (p.qualifier & PK_HI_EXCL) != 0 {
                    self.tm.cmp(T_LT, v, bv)
                } else {
                    self.tm.cmp(T_LE, v, bv)
                };
                f = if f == NONE {
                    c
                } else {
                    self.tm.and(f, c)
                };
            }
        }
        if f == NONE {
            return;
        }
        if let Some(d) = self.def_of.get(&v) {
            let i = (*d) as usize;
            let g = self.tm.and(self.defs[i], f);
            self.defs.set(i, g);
            return;
        }
        self.def_of.insert(v, self.defs.len() as u32);
        self.defs.push(f);
    }

    // The base of pattern type `ty` of module `m`: the type of a bound.
    fn pat_base_of(self: &Self, m: ModuleId, ty: TypeId) TypeId {
        let y = *self.ast_of(m).type_at(ty);
        return if y.kind == TypeKind::TYPE_BUILTIN {
            Ast::builtin(unsafe y.as_data.builtin)
        } else {
            ty
        };
    }

    fn spend(self: &mut Self) bool {
        self.steps += 1;
        return !(self.sv.polling && self.sv.tick(1)) && self.steps + self.sv.steps <= STEP_BUDGET && self.steps <= self.walk_cap;
    }

    // ---- reports ----------------------------------------------------------------------------------

    fn source_line(self: &mut Self, m: ModuleId, at: u32) u32 {
        if self.line_mod != m as u32 {
            self.line_mod = m;
            self.line_starts = diag::line_starts_of(&self.pkg().modules.at(m as usize).source);
        }
        return diag::line_in(&self.line_starts, at);
    }

    const fn text(self: &Self, m: ModuleId, sp: tok::Span) str {
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
            if span.is_negative() || wide::<B>(ENUM_MAX as i64) <= span {
                domain = ENUM_MAX + 1;
                break;
            }
            domain *= span.to_i64() as u64 + 1;
            if domain > ENUM_MAX {
                break;
            }
        }
        let no_cands = Vector::<Num<B>>::new();
        let no_starts = Vector::<u32>::new();
        if domain <= ENUM_MAX {
            let mut complete = true;
            for k in 0..domain {
                // Within the solver's limit: a capped check (`holds_within`) stops here too.
                self.sv.steps += 1;
                if self.sv.steps > self.sv.limit {
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
        // A few values of each unknown: its value in the solver's model, its ends, zero and its
        // neighbors.
        let mut cands = Vector::<Num<B>>::new();
        let mut starts = Vector::<u32>::new();
        let mut combos: u64 = 1;
        for j in 0..n {
            starts.push(cands.len() as u32);
            let lo = self.ev.lo[j];
            let hi = self.ev.hi[j];
            let mut mv = lo;
            for q in 0..self.sv.model.len() {
                if self.sv.model[q] == self.ev.leaves[j] {
                    mv = self.sv.mval[q];
                }
            }
            let picks: [Num<B>; 8] = [
                mv,
                lo,
                hi,
                Num::<B>::zero(),
                Num::<B>::one(),
                Num::<B>::zero() - Num::<B>::one(),
                lo + Num::<B>::one(),
                hi - Num::<B>::one(),
            ];
            let c0 = cands.len();
            for q in 0..8 {
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
            if self.sv.steps > self.sv.limit {
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
            let fw = self.float_w(self.m, b.locals.at(l as usize).ty);
            let (sw, sfd) = self.soft_fmt(self.m, b.locals.at(l as usize).ty);
            if fw != 0 {
                let bits = v.limb(0);
                if fw == 32 {
                    out.format_into("{}", f32::from_bits(bits as u32));
                } else {
                    out.format_into("{}", f64::from_bits(bits));
                }
            } else if sw != 0 && sw <= 64 && (sfd & 0xFFFF) <= 52 {
                out.format_into("{}", soft_value(v.limb(0), sw, sfd));
            } else if self.tm.at(t).w == W_BOOL {
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

    // Whether the facts `pc` imply `goal`: first without the facts derived for a division or a shift
    // by a constant, which most goals do not need and which make each simplex larger (on code with
    // many divisions, about 40% more instructions to prove all goals with them), then with them, then
    // without them again but refuting a branch by its bits (a SAT refutation), which costs more again
    // and needs no derived fact: the bits define a division and a shift.
    // Whether `q` is a quantifier (an `exists` where `ex`, else a `forall`) whose range its constant bounds
    // leave empty.
    fn vacuous(self: &Self, q: u32, ex: bool) bool {
        let ci = switch self.qof.get(&q) {
            Some(c) => *c,
            None => {
                return false;
            },
        };
        let c = &self.qclo[ci as usize];
        let flags = unsafe (&*c.cb).quants[c.qi as usize].flags;
        let (lo, hi) = (self.tm.at(c.lo), self.tm.at(c.hi));
        if (flags & ir::QF_EXISTS) != 0 != ex || lo.op != T_INT || hi.op != T_INT {
            return false;
        }
        return if (flags & ir::QF_INCLUSIVE) != 0 {
            hi.k < lo.k
        } else {
            !(lo.k < hi.k)
        };
    }

    // Push onto `out` the `bool` calls `pc` states, whole or as parts of conjunctions (at most
    // STATED_PARTS parts read for each fact), that share an argument with call `goal`, and their
    // definitions.
    // The body of the definition of call `t` (`t == body`), NONE when it has another form (a definition
    // of several paths).
    // The disjuncts of `f`, ORs `depth` deep flattened.
    fn disjuncts(self: &Self, f: u32, out: &mut Vector<u32>, depth: u32) {
        let x = self.tm.at(f);
        if x.op == T_OR && depth < 8 {
            self.disjuncts(x.a, out, depth + 1);
            self.disjuncts(x.b, out, depth + 1);
            return;
        }
        out.push(f);
    }

    fn def_body(self: &Self, t: u32) u32 {
        let d = switch self.def_of.get(&t) {
            Some(d) => self.defs[(*d) as usize],
            None => {
                return NONE;
            },
        };
        // `t == body`, or a conjunct of the facts anchored with it (an ownership frame, `ov_frame`).
        return self.def_body_of(d, t);
    }

    // Call goal `goal` against a call of the same function that `pc` states (a conjunct of a fact):
    // into `rest`, the conjuncts of the goal's definition body that the stated call's body does not
    // have. False when no such call is stated or a definition has another form.
    fn frame_rest(self: &Self, pc: &Vector<u32>, goal: u32, rest: &mut Vector<u32>, olds: &mut Vector<u32>) bool {
        let g = self.tm.at(goal);
        let gb = self.def_body(goal);
        if gb == NONE {
            return false;
        }
        let mut stack = Vector::<u32>::new();
        let mut have = Vector::<u32>::new();
        for j in 0..pc.len() {
            stack.push(pc[j]);
            for _s in 0..STATED_PARTS {
                if stack.len() == 0 {
                    break;
                }
                let t = stack.pop().unwrap();
                let x = self.tm.at(t);
                if x.op == T_AND {
                    stack.push(x.b);
                    stack.push(x.a);
                    continue;
                }
                if x.op != T_CALL || t == goal || x.k != g.k || x.b != g.b {
                    continue;
                }
                let hb = self.def_body(t);
                if hb != NONE {
                    self.conjuncts(hb, &mut have, 0);
                }
            }
            stack.clear();
        }
        if have.len() == 0 {
            return false;
        }
        let mut parts = Vector::<u32>::new();
        self.conjuncts(gb, &mut parts, 0);
        rest.clear();
        for q in 0..parts.len() {
            if !have.contains(&parts[q]) {
                rest.push(parts[q]);
            }
        }
        olds.clear();
        for q in 0..have.len() {
            if !parts.contains(&have[q]) {
                olds.push(have[q]);
            }
        }
        return rest.len() < parts.len();
    }

    fn stated_preds(self: &Self, pc: &Vector<u32>, goal: u32, out: &mut Vector<u32>) {
        let g = self.tm.at(goal);
        if g.op != T_CALL {
            return;
        }
        let mut stack = Vector::<u32>::new();
        for j in 0..pc.len() {
            stack.push(pc[j]);
            for _s in 0..STATED_PARTS {
                if stack.len() == 0 {
                    break;
                }
                let t = stack.pop().unwrap();
                let x = self.tm.at(t);
                if x.op == T_AND {
                    stack.push(x.b);
                    stack.push(x.a);
                    continue;
                }
                if x.op != T_CALL || t == goal {
                    continue;
                }
                let d = switch self.def_of.get(&t) {
                    Some(d) => self.defs[(*d) as usize],
                    None => {
                        continue;
                    },
                };
                let mut shared = false;
                for a in x.a..x.a + x.b {
                    for b in g.a..g.a + g.b {
                        shared = shared || self.tm.args[a as usize] == self.tm.args[b as usize];
                    }
                }
                if shared && !out.contains(&d) {
                    out.push(t);
                    out.push(d);
                }
            }
            stack.clear();
        }
    }

    // Whether `c` is a part of conjunction `f`, at most STATED_PARTS parts read.
    fn conjunct(self: &Self, f: u32, c: u32) bool {
        let mut stack = Vector::<u32>::new();
        stack.push(f);
        for _s in 0..STATED_PARTS {
            if stack.len() == 0 {
                break;
            }
            let t = stack.pop().unwrap();
            if t == c {
                return true;
            }
            let x = self.tm.at(t);
            if x.op == T_AND {
                stack.push(x.b);
                stack.push(x.a);
            }
        }
        return false;
    }

    // Whether `hyps` imply `goal` within STAGE_STEPS: for a stage that proves most goals at once, and
    // the rest with the facts of a later one.
    fn capped(self: &mut Self, hyps: &Vector<u32>, goal: u32) bool {
        return self.capped_at(hyps, goal, STAGE_STEPS);
    }

    // `capped` within `steps`.
    fn capped_at(self: &mut Self, hyps: &Vector<u32>, goal: u32, steps: u32) bool {
        let limit = self.sv.limit;
        self.sv.limit = limit.min(self.sv.steps.saturating_add(steps));
        let ok = self.sv.implies(&self.tm, hyps, goal, false);
        self.sv.limit = limit;
        return ok;
    }

    // Whether formula `goal` is one of `pc`, a part of a conjunction of `pc`, or a part of the body of a
    // spec function call `pc` states (`times19(g, h)` states `h[9] == 19 * g[9]`): at most STATED_PARTS
    // parts read for each fact. Each entry pairs a part with the call known to hold whose definition it
    // is a part of, the equality of the call and its body.
    fn stated(self: &Self, pc: &Vector<u32>, goal: u32) bool {
        let mut stack = Vector::<u64>::new();
        for j in 0..pc.len() {
            stack.push(NONE as u64 << 32 | pc[j] as u64);
            for _s in 0..STATED_PARTS {
                if stack.len() == 0 {
                    break;
                }
                let e = stack.pop().unwrap();
                let (call, t) = ((e >> 32) as u32, e as u32);
                if t == goal {
                    return true;
                }
                let x = self.tm.at(t);
                if x.op == T_AND {
                    stack.push(call as u64 << 32 | x.b as u64);
                    stack.push(call as u64 << 32 | x.a as u64);
                } else if x.op == T_EQ && call != NONE && (x.a == call || x.b == call) {
                    stack.push(NONE as u64 << 32 | pick(x.a == call, x.b, x.a) as u64);
                } else if call == NONE {
                    if let Some(d) = self.def_of.get(&t) {
                        stack.push(t as u64 << 32 | self.defs[(*d) as usize] as u64);
                    }
                }
            }
            stack.clear();
        }
        return false;
    }

    // Whether `goal` or a fact of `pc` names a product of two terms that are not constants.
    fn has_product(self: &Self, goal: u32, pc: &Vector<u32>) bool {
        let mut stack = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        stack.push(goal);
        stack.extend_copy(pc);
        let mut ops = Vector::<u32>::new();
        for _s in 0..PRODUCT_SCAN {
            if stack.len() == 0 {
                return false;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            let x = self.tm.at(t);
            if x.op == T_MUL && self.tm.at(x.a).op != T_INT && self.tm.at(x.b).op != T_INT {
                return true;
            }
            self.tm.operands(t, &mut ops);
            stack.extend_copy(&ops);
        }
        return false;
    }

    fn holds(self: &mut Self, pc0: &Vector<u32>, goal: u32) bool {
        // A version-keyed term the facts state in an earlier version (`ov_frame`): its frames and the held
        // atoms' definitions alone, no invariant's body.
        if self.ov_fr.contains_key(&goal) && self.frame_holds(pc0, goal) {
            return true;
        }
        // A conjunct of an invariant (`holds_at`) that names such terms or held atoms under `&&` and `||`
        // (a claim, `cap == 0 || owns(..)`): each in its earliest version where its frame's side holds,
        // which implies it.
        if self.inv_split != 0 && self.fr_depth <= 8 && self.tm.at(goal).op == T_OR {
            let mut ctx = Vector::<u32>::new();
            let mut visits: u32 = 0;
            let g2 = self.frame_back(pc0, &mut ctx, goal, &mut visits);
            if g2 != goal {
                self.fr_depth += 1;
                let ok = self.holds_staged(pc0, g2);
                self.fr_depth -= 1;
                if ok {
                    return true;
                }
            }
        }
        // A spec function's sequence of several paths whose path the facts decide: its value there, so
        // the goal names neither the other paths nor their facts.
        if self.spec_leaves.len() != 0 && !self.deciding && self.names_spec_seq(goal) {
            self.deciding = true;
            let mut memo = Map::<u32, u32>::new();
            let g2 = self.decide(pc0, goal, &mut memo, 0);
            // The path's facts in the same terms.
            let mut pc2 = Vector::<u32>::with_capacity(pc0.len());
            let mut changed = g2 != goal;
            for j in 0..pc0.len() {
                let f = self.decide(pc0, pc0[j], &mut memo, 0);
                changed = changed || f != pc0[j];
                pc2.push(f);
            }
            self.deciding = false;
            if changed && self.holds_at(&pc2, g2) {
                return true;
            }
        }
        return self.holds_at(pc0, goal);
    }

    // Whether path `pc` states `c`: as a fact or a part of one, or as the equal of a value it states
    // (`r == c` and `r`, a call's result its `ensures` defines), BOOL_STATED equalities down.
    fn bool_stated(self: &mut Self, pc: &Vector<u32>, c: u32, depth: u32) bool {
        if self.stated(pc, c) {
            return true;
        }
        if depth >= BOOL_STATED {
            return false;
        }
        // A conjunction: each part.
        let cx = self.tm.at(c);
        if cx.op == T_AND {
            return self.bool_stated(pc, cx.a, depth) && self.bool_stated(pc, cx.b, depth);
        }
        // `o == c` with `o` stated, or `o == !c` with `!o` stated.
        let nc = self.tm.not(c);
        let mut parts = Vector::<u32>::new();
        let mut alts = Vector::<u32>::new();
        for j in 0..pc.len() {
            parts.clear();
            self.conjuncts(pc[j], &mut parts, 0);
            for q in 0..parts.len() {
                let e = self.tm.at(parts[q]);
                if e.op != T_EQ || !self.tm.is_bool(e.a) {
                    continue;
                }
                if e.a == c || e.b == c {
                    alts.push(pick(e.a == c, e.b, e.a));
                }
                if e.a == nc || e.b == nc {
                    let o = pick(e.a == nc, e.b, e.a);
                    alts.push(self.tm.not(o));
                }
            }
        }
        for j in 0..alts.len() {
            if alts[j] != c && self.bool_stated(pc, alts[j], depth + 1) {
                return true;
            }
        }
        return false;
    }

    // Whether goal `t` names a spec function's sequence of `spec_leaves`.
    fn names_spec_seq(self: &Self, t: u32) bool {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(t);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return false;
            }
            let x = stack.pop().unwrap();
            if seen.contains_key(&x) {
                continue;
            }
            seen.insert(x, true);
            if self.tm.at(x).w == W_OTHER && self.spec_leaves.contains_key(&x) {
                return true;
            }
            self.tm.operands(x, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
        return false;
    }

    // Goal `t` with each spec function's sequence or number (`spec_leaves`) whose path `pc` decides
    // replaced by that path's value, through equalities, connectives and sequence operations (a new
    // equality of sequences extensional as the old, `seqw`); `t` where none is.
    fn decide(self: &mut Self, pc: &Vector<u32>, t: u32, memo: &mut Map<u32, u32>, depth: u32) u32 {
        if depth >= DECIDE_DEPTH {
            return t;
        }
        if let Some(d) = memo.get(&t) {
            return *d;
        }
        let mut r = t;
        if let Some(e) = self.spec_leaves.get(&t) {
            let (st, n) = (*e >> 32, *e & 0xFFFFFFFFu64);
            for j in st..st + n {
                let l = self.spec_pool[j as usize];
                let (path, v) = ((l >> 32) as u32, (l & 0xFFFFFFFFu64) as u32);
                // One path: its value where a path below it is decided, else the call (a term the facts
                // name as it is).
                if self.tm.is_true(path) && n == 1 {
                    let dv = self.decide(pc, v, memo, depth + 1);
                    if dv != v {
                        r = dv;
                    }
                    break;
                }
                if self.bool_stated(pc, path, 0) {
                    r = self.decide(pc, v, memo, depth + 1);
                    break;
                }
            }
            memo.insert(t, r);
            return r;
        }
        let x = self.tm.at(t);
        if x.op == T_EQ && self.tm.at(x.a).w == W_OTHER {
            let a = self.decide(pc, x.a, memo, depth + 1);
            let b = self.decide(pc, x.b, memo, depth + 1);
            if a != x.a || b != x.b {
                r = self.tm.cmp(T_EQ, a, b);
                if let Some(ws) = self.seqw.get(&t) {
                    let ws0 = *ws;
                    self.seq_ext(r, a, b, (ws0 >> 1) as u16, (ws0 & 1) != 0);
                }
            }
        } else if x.op == T_AND || x.op == T_OR {
            let a = self.decide(pc, x.a, memo, depth + 1);
            let b = self.decide(pc, x.b, memo, depth + 1);
            if a != x.a || b != x.b {
                r = pick(x.op == T_AND, self.tm.and(a, b), self.tm.or(a, b));
            }
        } else if x.op == T_NOT {
            let a = self.decide(pc, x.a, memo, depth + 1);
            if a != x.a {
                r = self.tm.not(a);
            }
        } else if x.op == T_EQ || x.op == T_NE || x.op == T_LE || x.op == T_LT || x.op == T_ADD || x.op == T_SUB {
            let a = self.decide(pc, x.a, memo, depth + 1);
            let b = self.decide(pc, x.b, memo, depth + 1);
            if a != x.a || b != x.b {
                r = if x.op == T_ADD || x.op == T_SUB {
                    self.tm.arith(x.op, a, b, x.w, x.sg)
                } else {
                    self.tm.cmp(x.op, a, b)
                };
            }
        } else {
            let op = self.sq_of(t);
            if op == SQ_LEN || op == SQ_AT {
                let s0 = self.tm.args[x.a as usize];
                let sv = self.decide(pc, s0, memo, depth + 1);
                if sv != s0 {
                    r = if op == SQ_LEN {
                        self.seq_len(sv)
                    } else {
                        self.seq_at(sv, self.tm.args[(x.a + 1) as usize], x.w, x.sg)
                    };
                }
            } else if op == SQ_CAT || op == SQ_PUSH || op == SQ_SUB || op == SQ_UPD {
                let mut xs = Vector::<u32>::new();
                let mut changed = false;
                for j in x.a..x.a + x.b {
                    let a0 = self.tm.args[j as usize];
                    let a = self.decide(pc, a0, memo, depth + 1);
                    changed = changed || a != a0;
                    xs.push(a);
                }
                if changed {
                    r = self.seq_make(op, &xs);
                }
            }
        }
        memo.insert(t, r);
        return r;
    }

    fn holds_at(self: &mut Self, pc0: &Vector<u32>, goal: u32) bool {
        self.parts = 0;
        if self.seqwit.len() != 0 {
            self.goal_witnesses(goal);
        }
        // A struct's invariant (`inv_need`): each conjunct of its definition alone, as a bound needs none
        // of the cases the others add (a block's claim beside the fields' ranges).
        if self.inv_goal && self.inv_split < 2 && self.tm.at(goal).op == T_CALL {
            let d = match_def(&self.def_of, &self.defs, goal);
            let body = if d == NONE {
                NONE
            } else {
                self.def_body_of(d, goal)
            };
            let mut parts = Vector::<u32>::new();
            if body != NONE {
                self.conjuncts(body, &mut parts, 0);
            }
            if parts.len() > 1 {
                self.inv_split += 1;
                let mut all = true;
                for q in 0..parts.len() {
                    if all && !self.holds(pc0, parts[q]) {
                        all = false;
                    }
                }
                self.inv_split -= 1;
                self.parts = 0;
                if all {
                    return true;
                }
            }
        }
        // A struct's invariant (`inv_need`): first without the path's equalities of sequences, whose
        // extensionality only adds cases to it (a view's facts beside the struct's fields).
        if (self.inv_goal || self.names_inv(goal)) && self.seqeqs.len() != 0 && !self.names_seq_eq(goal, 0) {
            let mut few = Vector::<u32>::with_capacity(pc0.len());
            let mut parts = Vector::<u32>::new();
            let mut dropped = false;
            for j in 0..pc0.len() {
                parts.clear();
                self.conjuncts(pc0[j], &mut parts, 0);
                for q in 0..parts.len() {
                    if self.names_seq_eq(parts[q], 0) {
                        dropped = true;
                    } else {
                        few.push(parts[q]);
                    }
                }
            }
            if dropped && self.holds_staged(&few, goal) {
                return true;
            }
            self.parts = 0;
        }
        // An equality of sequences its terms' definitions decide (their elements): first without the
        // path's facts, whose arithmetic only adds cases to it, within SEQ_DEFS_STEPS, then with its
        // bounds alone, within STAGE_STEPS.
        if self.names_seq_eq(goal, 0) && pc0.len() != 0 {
            let none = Vector::<u32>::new();
            let lim = self.sv.limit;
            self.sv.limit = lim.min(self.sv.steps.saturating_add(SEQ_DEFS_STEPS));
            let mut ok = self.holds_in(&none, goal);
            // Then with the path's bounds on its unknowns (an index range).
            if !ok {
                self.parts = 0;
                let near = self.near_atoms(goal, pc0);
                if near.len() != 0 && !within(pc0, &near) {
                    self.sv.limit = lim.min(self.sv.steps.saturating_add(STAGE_STEPS));
                    ok = self.holds_in(&near, goal);
                }
            }
            self.sv.limit = lim;
            self.parts = 0;
            if ok {
                return true;
            }
        }
        // An equality of sequences: first without the path's struct invariants, whose bounds and bytes
        // only add cases to it.
        if !self.inv_goal && self.names_seq_eq(goal, 0) && !self.names_inv(goal) {
            let mut few = Vector::<u32>::with_capacity(pc0.len());
            let mut parts = Vector::<u32>::new();
            let mut dropped = false;
            for j in 0..pc0.len() {
                parts.clear();
                self.conjuncts(pc0[j], &mut parts, 0);
                for q in 0..parts.len() {
                    if self.names_inv(parts[q]) {
                        dropped = true;
                    } else {
                        few.push(parts[q]);
                    }
                }
            }
            if dropped && self.holds_staged(&few, goal) {
                return true;
            }
            self.parts = 0;
        }
        if self.holds_in(pc0, goal) {
            return true;
        }
        // A block a removal took was held before it: the facts of the versions before, where two blocks
        // the body held apart are distinct.
        if self.ov_had.len() != 0 && self.steps + self.sv.steps <= STEP_BUDGET && self.names_held(goal) {
            let mut pc1 = pc0.clone();
            pc1.extend_copy(&self.ov_had);
            self.parts = 0;
            if self.holds_staged(&pc1, goal) {
                return true;
            }
        }
        // Two applications of one opaque predicate whose operands the path proves equal are equal: the
        // solver merges them where its arithmetic implies the operands equal, not where the bits do
        // (`A::owns(p, (n | LB) << 1 >> 1, 1)` beside `A::owns(p, n, 1)`, `n < LB`).
        if self.steps + self.sv.steps <= STEP_BUDGET && !self.in_cong {
            self.in_cong = true;
            let eqs = self.call_congruence(pc0, goal);
            self.in_cong = false;
            if eqs.len() != 0 {
                let mut pc1 = pc0.clone();
                pc1.extend_copy(&eqs);
                self.parts = 0;
                if self.holds_in(&pc1, goal) {
                    return true;
                }
            }
        }
        // A goal over sequences the stages did not prove: the path's bounds on its unknowns, the
        // definitions of its terms and the elements' equalities of the equalities of sequences that share
        // an unknown with it (`instantiate`).
        if self.seqeqs.len() != 0 && self.steps + self.sv.steps <= STEP_BUDGET && self.names_seq(goal) {
            let mut seqf = Vector::<u32>::new();
            for j in 0..pc0.len() {
                if self.names_seq(pc0[j]) {
                    seqf.push(pc0[j]);
                }
            }
            let mut few = self.near_atoms(goal, pc0);
            let near = self.cone(goal, &seqf);
            for j in 0..near.len() {
                if !few.contains(&near[j]) {
                    few.push(near[j]);
                }
            }
            self.add_defs(goal, &mut few);
            self.seq_inst = true;
            let _ = self.instantiate(goal, &mut few, QI_TRIG);
            self.seq_inst = false;
            return self.capped_at(&few, goal, SEQ_STEPS);
        }
        return false;
    }

    // The equalities of two applications of one opaque predicate (a boolean call without a definition)
    // under `goal`, `pc` and their definitions whose operands `pc` proves equal pairwise, each operand
    // pair within STAGE_STEPS; at most CONG_PAIRS pairs tried.
    fn call_congruence(self: &mut Self, pc: &Vector<u32>, goal: u32) Vector<u32> {
        let mut out = Vector::<u32>::new();
        let mut roots = pc.clone();
        self.add_defs(goal, &mut roots);
        roots.push(goal);
        let mut calls = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut stack = roots.clone();
        let mut ops = Vector::<u32>::new();
        for _k in 0..CONG_NODES {
            if stack.len() == 0 {
                break;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            let x = self.tm.at(t);
            if x.op == T_CALL && x.w == W_BOOL && !self.def_of.contains_key(&t) {
                calls.push(t);
            }
            ops.clear();
            self.tm.operands(t, &mut ops);
            stack.extend_copy(&ops);
        }
        let mut tried: u32 = 0;
        for i in 0..calls.len() {
            for j in i + 1..calls.len() {
                let (a, b) = (self.tm.at(calls[i]), self.tm.at(calls[j]));
                if a.k != b.k || tried >= CONG_PAIRS {
                    continue;
                }
                let mut xa = Vector::<u32>::new();
                let mut xb = Vector::<u32>::new();
                self.tm.operands(calls[i], &mut xa);
                self.tm.operands(calls[j], &mut xb);
                if xa.len() != xb.len() {
                    continue;
                }
                tried += 1;
                let mut all = true;
                for q in 0..xa.len() {
                    if all && xa[q] != xb[q] {
                        let e = self.tm.cmp(T_EQ, xa[q], xb[q]);
                        all = self.holds_within(&roots, e, STAGE_STEPS);
                    }
                }
                if all {
                    out.push(self.tm.cmp(T_EQ, calls[i], calls[j]));
                }
            }
        }
        return out;
    }

    // The witness of each equality of sequences goal `goal` names joins the equality's definition
    // (`seq_ext`): only an equality to prove needs one.
    fn goal_witnesses(self: &mut Self, goal: u32) {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(goal);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return;
            }
            let x = stack.pop().unwrap();
            if seen.contains_key(&x) {
                continue;
            }
            seen.insert(x, true);
            if let Some(f) = self.seqwit.get(&x) {
                let w = *f;
                let _ = self.seqwit.remove(&x);
                self.anchor(x, w);
            }
            self.tm.operands(x, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
    }

    // `holds_in` within STAGE_STEPS: a stage with some of the facts, which the whole facts follow.
    fn holds_staged(self: &mut Self, pc0: &Vector<u32>, goal: u32) bool {
        let lim = self.sv.limit;
        self.sv.limit = lim.min(self.sv.steps.saturating_add(STAGE_STEPS));
        let ok = self.holds_in(pc0, goal);
        self.sv.limit = lim;
        return ok;
    }

    fn holds_in(self: &mut Self, pc0: &Vector<u32>, goal: u32) bool {
        // A goal the path states, whole or as a part of a conjunction it states, holds; so does a
        // `forall` over a range its constant bounds leave empty, and the negation of such an `exists`.
        if self.stated(pc0, goal) || self.vacuous(goal, false) || self.tm.at(goal).op == T_NOT && self.vacuous(
            self.tm.at(goal).a,
            true,
        ) {
            return true;
        }
        // A conjunction holds where each part does: each is proved alone, with the facts it names.
        let g = self.tm.at(goal);
        if g.op == T_AND {
            return self.holds_in(pc0, g.a) && self.holds_in(pc0, g.b);
        }
        // `x || (y && z)` holds where `x || y` and `x || z` do: a conjunction a path merge put under a
        // disjunction (`(a ==> b) && (c ==> d)`) splits as one at the top does. At most SPLIT_PARTS
        // parts, so a merge of many paths does not multiply the goals.
        if g.op == T_OR && self.parts < SPLIT_PARTS {
            let (x, y) = if self.tm.at(g.b).op == T_AND {
                (g.a, g.b)
            } else {
                (g.b, g.a)
            };
            let yt = self.tm.at(y);
            if yt.op == T_AND {
                self.parts += 1;
                let l = self.tm.or(x, yt.a);
                let r = self.tm.or(x, yt.b);
                return self.holds_in(pc0, l) && self.holds_in(pc0, r);
            }
        }
        // A goal that holds by itself (`0 <= b as int`): no case of the path's facts to split.
        if self.tm.is_true(goal) {
            return true;
        }
        // A call goal with the predicates the path states on its arguments and the definitions of both:
        // `carried(x)` proves `loose(x)`.
        if g.op == T_CALL && self.def_of.contains_key(&goal) {
            let mut own = Vector::<u32>::new();
            self.add_defs_of(goal, &mut own, DEFS_ALL);
            let n = own.len();
            self.stated_preds(pc0, goal, &mut own);
            if own.len() > n && self.sv.implies(&self.tm, &own, goal, false) {
                return true;
            }
            // A call of a function the path states of another value (an invariant before an update of a
            // member): the parts of the goal's definition that the stated call's definition has hold;
            // each other part is proved alone.
            let mut rest = Vector::<u32>::new();
            let mut olds = Vector::<u32>::new();
            if self.frame_rest(pc0, goal, &mut rest, &mut olds) {
                let mut pc1 = pc0.clone();
                pc1.extend_copy(&olds);
                let mut all = true;
                for j in 0..rest.len() {
                    all = all && self.holds_in(&pc1, rest[j]);
                }
                if all {
                    return true;
                }
            } else if self.inv_terms.contains_key(&goal) && self.def_body(goal) != NONE {
                // A struct's invariant no call of it stated before frames: each part of its definition alone.
                let mut parts = Vector::<u32>::new();
                self.conjuncts(self.def_body(goal), &mut parts, 0);
                let mut all = parts.len() > 1;
                for j in 0..parts.len() {
                    all = all && self.holds_in(pc0, parts[j]);
                }
                if all {
                    return true;
                }
                // An invariant of cases (a union's representations): the case the path is in, alone, with
                // the definitions it names; the other cases' blocks only add case splits.
                if parts.len() == 1 && self.tm.at(parts[0]).op == T_OR {
                    let mut cases = Vector::<u32>::new();
                    self.disjuncts(parts[0], &mut cases, 0);
                    for j in 0..cases.len() {
                        let mut hy = pc0.clone();
                        self.add_defs_of(cases[j], &mut hy, DEFS_ALL);
                        if self.capped(&hy, cases[j]) {
                            return true;
                        }
                    }
                }
            }
        }
        let none = Vector::<u32>::new();
        if pc0.len() > 2 && self.sv.implies(&self.tm, &none, goal, false) {
            return true;
        }
        // The path's bounds that name an unknown of the goal, with the definitions of the terms with
        // unknowns they name: a bound (`i < 10`, a length's) proves most range goals, and the large
        // facts beside it only add cases. Not for an equality, which bounds rarely decide.
        let mut near = self.near_atoms(goal, pc0);
        if g.op != T_EQ && near.len() != 0 && !within(pc0, &near) && pc0.len() > 2 {
            if self.defs.len() != 0 {
                let t = self.tm.boolean(true);
                self.add_defs_of(t, &mut near, DEFS_OPEN);
            }
            if self.capped(&near, goal) {
                return true;
            }
        }
        // The definitions of the spec function calls the formulas name hold on every path.
        let mut withdefs = Vector::<u32>::new();
        if self.defs.len() != 0 {
            withdefs.extend_copy(pc0);
            self.add_defs(goal, &mut withdefs);
        }
        let more = withdefs.len() > pc0.len();
        // An equality of scalars a chain of equalities proves (`a == b`, `b + 1 == c`): the path's
        // equalities of scalars, with the definitions of the terms they and the goal name, alone; the
        // path's other facts only add cases.
        if more {
            // First the path's facts alone: a composition of facts (`a == b`, `b == c`) needs no
            // unfolding, and the definitions only add cases.
            if self.capped(pc0, goal) {
                return true;
            }
            // Then the definitions of the calls the formulas name, without those of the calls the
            // definitions name: a step of a recursion needs the one level, and the levels below only
            // fill the closure.
            if g.op == T_EQ {
                // An equality of calls one side's unfolding proves by congruence (`f(x) == g(y)` where `f`
                // spells `g`): each side's definition alone first, without those of the calls it names,
                // and without the instances of the quantifiers.
                for side in [g.a, g.b] {
                    if let Some(d) = self.def_of.get(&side) {
                        let mut one = pc0.clone();
                        one.push(self.defs[(*d) as usize]);
                        if self.capped(&one, goal) {
                            return true;
                        }
                    }
                }
            }
            if self.qclo.len() == 0 {
                // A goal a spec function states (`below(h, 4)`) needs its own unfolding, and the
                // definitions of the calls the facts name only add cases: first the goal's alone.
                let mut own = Vector::<u32>::new();
                self.add_defs_of(goal, &mut own, DEFS_ALL);
                if own.len() != 0 && pc0.len() + own.len() < withdefs.len() {
                    own.extend_copy(pc0);
                    if self.capped(&own, goal) {
                        return true;
                    }
                }
                // A step of a recursion needs its unfolding alone, and the other calls' definitions
                // only add cases: first the recursive calls' definitions.
                let mut rec = Vector::<u32>::new();
                rec.extend_copy(pc0);
                self.add_defs_of(goal, &mut rec, DEFS_REC);
                if rec.len() > pc0.len() && rec.len() < withdefs.len() && self.capped(&rec, goal) {
                    return true;
                }
                let mut one = Vector::<u32>::new();
                one.extend_copy(pc0);
                self.add_defs_of(goal, &mut one, DEFS_NEAR);
                if one.len() > pc0.len() && one.len() < withdefs.len() && self.capped(&one, goal) {
                    return true;
                }
            }
        }
        let pc = if more {
            &withdefs
        } else {
            pc0
        };
        if self.qclo.len() != 0 {
            // The quantifiers the formulas name: their instances at the witnesses, then at the terms.
            // The facts that share no unknown with the goal only add case splits: first without them.
            // Each set without bits first: the bits of the definitions' operations rarely decide an
            // instance and cost the most. First the instances with the definitions of the terms they and
            // the goal name, then with those of all but the spec functions' calls: a step that moves a
            // fact from one index to another needs no deeper unfolding.
            if self.defs.len() != 0 {
                let mut first = Vector::<u32>::new();
                first.extend_copy(pc0);
                if self.instantiate(goal, &mut first, QI_TRIG) {
                    let mut near = first.clone();
                    self.add_defs_of(goal, &mut near, DEFS_NEAR);
                    if self.sv.implies(&self.tm, &near, goal, false) {
                        return true;
                    }
                }
                let mut inst = Vector::<u32>::new();
                inst.extend_copy(pc0);
                self.add_defs_of(goal, &mut inst, DEFS_QUANTS);
                if self.instantiate(goal, &mut inst, QI_TRIG) && self.sv.implies(&self.tm, &inst, goal, false) {
                    return true;
                }
            }
            // The facts that share an unknown with the goal, with the instances at its terms, first: the
            // others only add case splits.
            let mut inst0 = Vector::<u32>::new();
            inst0.extend_copy(pc0);
            self.add_defs(goal, &mut inst0);
            let _ = self.instantiate(goal, &mut inst0, QI_TRIG);
            let c0 = self.cone(goal, &inst0);
            if c0.len() < inst0.len() && self.sv.implies(&self.tm, &c0, goal, false) {
                return true;
            }
            if self.sv.implies(&self.tm, pc, goal, false) {
                return true;
            }
            // The terms the model of that check puts in range, before every integer term.
            if self.model_instances(goal, pc0) {
                return true;
            }
            for bits in 0..2 {
                for wide in 0..2 {
                    let mut inst = Vector::<u32>::new();
                    inst.extend_copy(pc0);
                    self.add_defs(goal, &mut inst);
                    let more = self.instantiate(goal, &mut inst, pick(wide == 1, QI_WIDE, QI_TRIG));
                    // The facts that share an unknown with the goal first: fewer case splits (the first
                    // set's were tried before).
                    if (more || wide == 0) && (bits == 1 || wide == 1) {
                        let c = self.cone(goal, &inst);
                        if c.len() < inst.len() && self.sv.implies(&self.tm, &c, goal, bits == 1) {
                            return true;
                        }
                    }
                    if more && self.sv.implies(&self.tm, &inst, goal, bits == 1) {
                        return true;
                    }
                }
                if bits == 0 && self.sv.implies(&self.tm, pc, goal, true) {
                    return true;
                }
            }
            return false;
        }
        let mut n: usize = 0;
        for j in 0..pc.len() {
            n += self.derived.contains_key(&pc[j]) as usize;
        }
        // A goal of bit operations: their bits decide it, where their facts add only cases. The theories
        // still try each branch first (`Solver::lemma_with`).
        let bitty = self.names_bit_op(goal);
        if n == 0 {
            return self.sv.implies(&self.tm, pc, goal, bitty) || self.ops_imply(pc, pc, goal) || !bitty && self.sv.implies(
                &self.tm,
                pc,
                goal,
                true,
            );
        }
        let mut base = Vector::<u32>::with_capacity(pc.len() - n);
        for j in 0..pc.len() {
            if !self.derived.contains_key(&pc[j]) {
                base.push(pc[j]);
            }
        }
        // Last, the bits of every fact: a derived one's (a bit count's) can decide a goal of no bit operation.
        return self.sv.implies(&self.tm, &base, goal, bitty) || self.sv.implies(&self.tm, pc, goal, false) || self.ops_imply(
            &base,
            pc,
            goal,
        ) || self.sv.implies(&self.tm, pc, goal, true);
    }

    // Whether term `t` names a bit operation (`&`, `|`, `^`, `!`, a shift) among its first OP_TERMS terms.
    fn names_bit_op(self: &Self, t: u32) bool {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(t);
        for _k in 0..OP_TERMS {
            if stack.len() == 0 {
                return false;
            }
            let u = stack.pop().unwrap();
            if seen.contains_key(&u) {
                continue;
            }
            seen.insert(u, true);
            let op = self.tm.at(u).op;
            if op == T_BAND || op == T_BOR || op == T_BXOR || op == T_BNOT || op == T_SHL || op == T_SHR {
                return true;
            }
            self.tm.operands(u, &mut ops);
            stack.extend_copy(&ops);
        }
        return false;
    }

    // Whether `goal` follows by the theories from `near` with the facts of the operations the goal names, or
    // from `all` with those of the operations it and `all` name, each first without the deep facts
    // (`op_facts`): tried before any search of the bits, which can take every step.
    fn ops_imply(self: &mut Self, near: &Vector<u32>, all: &Vector<u32>, goal: u32) bool {
        // The goal's terms, then every term; the plain facts, then the deep ones. Each set within
        // OPS_STEPS: the bits of the operations, the next stage, decide what their facts do not.
        let mut last = Vector::<u32>::new();
        for k in 0..4u32 {
            let goal_only = k < 2;
            let base = pick(goal_only, near, all);
            let mut hs = base.clone();
            self.op_facts(goal, &mut hs, goal_only, (k & 1) != 0);
            if hs.len() > base.len() && hs != last && self.capped_at(&hs, goal, OPS_STEPS) {
                return true;
            }
            last = hs;
        }
        return false;
    }
    // The order atoms of `hyps` (their conjuncts `a < b`, `a <= b` and their negations) that name an
    // unknown `goal` names, in their order.
    // Whether `t` is an unknown or a member of one, through members only.
    const fn member_of(self: &Self, t: u32) bool {
        let mut u = t;
        for _k in 0..64 {
            let x = self.tm.at(u);
            if x.op == T_VAR {
                return true;
            }
            if x.op != T_SEL {
                return false;
            }
            u = x.a;
        }
        return false;
    }

    fn near_atoms(self: &Self, goal: u32, hyps: &Vector<u32>) Vector<u32> {
        let mut out = Vector::<u32>::new();
        let mut want = Map::<u32, bool>::new();
        self.leaves_into(goal, &mut want);
        if want.len() == 0 {
            return out;
        }
        let mut stack = Vector::<u32>::new();
        for j in 0..hyps.len() {
            stack.push(hyps[j]);
            for _s in 0..LIN_MAX * 16 {
                if stack.len() == 0 {
                    break;
                }
                let t = stack.pop().unwrap();
                let x = self.tm.at(t);
                if x.op == T_AND {
                    stack.push(x.b);
                    stack.push(x.a);
                    continue;
                }
                // A predicate that holds (an invariant's call): the conjuncts of its definition hold.
                if x.op == T_CALL && x.w == W_BOOL {
                    let d = match_def(&self.def_of, &self.defs, t);
                    if d != NONE {
                        let body = self.def_body_of(d, t);
                        if body != NONE {
                            stack.push(body);
                        }
                    }
                    continue;
                }
                // Bounds and equalities of `int` and `nat` values, and of members (`self.head ==
                // r.head`): an equality of other values brings the definitions of its operations, which a
                // range or index goal does not need.
                let y = if x.op == T_NOT {
                    self.tm.at(x.a)
                } else {
                    x
                };
                let int_eq = y.op == T_EQ && x.op != T_NOT && (exact_w(self.tm.at(y.a).w) || self.member_of(y.a) && self.member_of(
                    y.b,
                ));
                if y.op != T_LT && y.op != T_LE && !int_eq || out.contains(&t) {
                    continue;
                }
                let mut ls = Map::<u32, bool>::new();
                self.leaves_into(t, &mut ls);
                let mut hit = false;
                for (k, _v) in ls.iter() {
                    hit = hit || want.contains_key(k);
                }
                if hit {
                    out.push(t);
                }
            }
            stack.clear();
        }
        return out;
    }

    // Add the unknowns term `t` names to `out`, within LIN_MAX * 16 terms.
    fn leaves_into(self: &Self, t: u32, out: &mut Map<u32, bool>) {
        let mut ops = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        stack.push(t);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return;
            }
            let u = stack.pop().unwrap();
            if seen.contains_key(&u) {
                continue;
            }
            seen.insert(u, true);
            if self.tm.at(u).op == T_VAR {
                out.insert(u, true);
                continue;
            }
            self.tm.operands(u, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
    }

    // The facts of `hyps` that share an unknown with `goal`, or with a fact that does, in their order.
    fn cone(self: &Self, goal: u32, hyps: &Vector<u32>) Vector<u32> {
        let mut leaves = Vector::<Vector<u32>>::with_capacity(hyps.len() + 1);
        let mut ops = Vector::<u32>::new();
        for k in 0..hyps.len() + 1 {
            let root = if k == 0 {
                goal
            } else {
                hyps[k - 1]
            };
            let mut ls = Vector::<u32>::new();
            let mut seen = Map::<u32, bool>::new();
            let mut stack = Vector::<u32>::new();
            stack.push(root);
            for _s in 0..LIN_MAX * 16 {
                if stack.len() == 0 {
                    break;
                }
                let t = stack.pop().unwrap();
                if seen.contains_key(&t) {
                    continue;
                }
                seen.insert(t, true);
                if self.tm.at(t).op == T_VAR {
                    ls.push(t);
                    continue;
                }
                self.tm.operands(t, &mut ops);
                for j in 0..ops.len() {
                    stack.push(ops[j]);
                }
            }
            leaves.push(ls);
        }
        let mut want = Map::<u32, bool>::new();
        for j in 0..leaves[0].len() {
            want.insert(leaves[0][j], true);
        }
        let mut keep = Vector::<bool>::with_capacity(hyps.len());
        keep.resize_default(hyps.len());
        for _round in 0..hyps.len() + 1 {
            let mut changed = false;
            for k in 0..hyps.len() {
                if keep[k] {
                    continue;
                }
                let mut hit = false;
                for j in 0..leaves[k + 1].len() {
                    hit = hit || want.contains_key(&leaves[k + 1][j]);
                }
                if hit {
                    keep.set(k, true);
                    changed = true;
                    for j in 0..leaves[k + 1].len() {
                        want.insert(leaves[k + 1][j], true);
                    }
                }
            }
            if !changed {
                break;
            }
        }
        let mut out = Vector::<u32>::new();
        for k in 0..hyps.len() {
            if keep[k] {
                out.push(hyps[k]);
            }
        }
        return out;
    }

    // Append to `hyps` the instances of the quantifiers under `goal` and `hyps` (design rule 2: no
    // matching, one bounded round over the ground terms): a `forall` the facts state, or an `exists` the
    // goal states, over the terms of its binding's type: the witnesses of the other quantifiers, and with
    // `mode` QI_WIDE the integer terms under the goal, then under the facts, and with QI_MODEL those the
    // model of the last failed check (`Solver::model`) puts in the quantifier's range, one term per
    // value: an instance outside the range, or at a value another instance has, holds in that model too;
    // at most QUANT_TERMS each. Rounds for the quantifiers the instances name, at most QUANT_ROUNDS.
    // Whether any instance was added.
    fn instantiate(self: &mut Self, goal: u32, hyps: &mut Vector<u32>, mode: u8) bool {
        let wide = mode != QI_TRIG;
        let mut mv = Map::<u32, Num<B>>::new();
        if mode == QI_MODEL {
            for j in 0..self.sv.model.len() {
                mv.insert(self.sv.model[j], self.sv.mval[j]);
            }
        }
        let mut added = false;
        let mut done = Map::<u32, bool>::new();
        let mut ops = Vector::<u32>::new();
        let mut extra = Vector::<u32>::new();
        for _r in 0..QUANT_ROUNDS {
            // The quantifiers by polarity (1: stated, 2: denied), and the integer terms, the goal's first.
            let mut pol = Map::<u32, u8>::new();
            let mut seen = Map::<u32, bool>::new();
            let mut ints = Vector::<u32>::new();
            let mut reach = Vector::<u32>::new();
            let mut stack = Vector::<u64>::new();
            for k in 0..hyps.len() + 1 {
                let root = if k == 0 {
                    goal
                } else {
                    hyps[hyps.len() - k]
                };
                stack.push(root as u64 << 2 | pick(k == 0, 2u64, 1u64));
                for _s in 0..LIN_MAX * 16 {
                    if stack.len() == 0 {
                        break;
                    }
                    let e = stack.pop().unwrap();
                    let t = (e >> 2) as u32;
                    let p = (e & 3) as u8;
                    if p != 0 {
                        let old = switch pol.get(&t) {
                            Some(x) => *x,
                            None => 0u8,
                        };
                        if (old | p) == old && seen.contains_key(&t) {
                            continue;
                        }
                        pol.insert(t, old | p);
                    } else if seen.contains_key(&t) {
                        continue;
                    }
                    let first = !seen.contains_key(&t);
                    seen.insert(t, true);
                    if first {
                        reach.push(t);
                    }
                    if first && wide && self.tm.is_int(t) && ints.len() < QUANT_TERMS * 8 {
                        ints.push(t);
                    }
                    // A call whose value names a quantifier states it with the call's polarity, and its
                    // definition joins the facts.
                    if first {
                        if let Some(v) = self.qvalue.get(&t) {
                            if let Some(i) = self.def_of.get(&t) {
                                stack.push((*v) as u64 << 2 | p as u64);
                                let d = self.defs[(*i) as usize];
                                if !hyps.contains(&d) && !extra.contains(&d) {
                                    extra.push(d);
                                }
                            }
                        }
                    }
                    let x = self.tm.at(t);
                    // A witness's fact names its quantifier: no statement of it.
                    let sk = self.qdef.contains_key(&t);
                    self.tm.operands(t, &mut ops);
                    for j in 0..ops.len() {
                        let cp = if sk || p == 0 {
                            0u8
                        } else if x.op == T_NOT {
                            3 - p
                        } else if x.op == T_AND || x.op == T_OR {
                            p
                        } else if (x.op == T_EQ || x.op == T_NE) && self.tm.is_bool(ops[j]) {
                            3
                        } else {
                            0
                        };
                        stack.push(ops[j] as u64 << 2 | cp as u64);
                    }
                }
                stack.clear();
            }
            // An equality of sequences in the formulas: the equality of their elements at each index the
            // formulas read of either side, with the definitions of those elements.
            let mut seqadd = false;
            let mut sfacts = Vector::<u32>::new();
            for q in 0..pick(self.seq_inst, self.seqeqs.len() / 3, 0) {
                let (e, x, y) = (self.seqeqs[3 * q], self.seqeqs[3 * q + 1], self.seqeqs[3 * q + 2]);
                let stated = switch pol.get(&e) {
                    Some(v) => (*v & 1) != 0,
                    None => false,
                };
                if !stated {
                    continue;
                }
                for r in 0..reach.len() {
                    let t = reach[r];
                    if self.sq_of(t) != SQ_AT {
                        continue;
                    }
                    let tx = self.tm.at(t);
                    let sq = self.tm.args[tx.a as usize];
                    if sq != x && sq != y {
                        continue;
                    }
                    let i = self.tm.args[(tx.a + 1) as usize];
                    let ax = self.seq_at(x, i, tx.w, tx.sg);
                    let ay = self.seq_at(y, i, tx.w, tx.sg);
                    let eq = self.tm.cmp(T_EQ, ax, ay);
                    let f = self.imp(e, eq);
                    if !self.tm.is_true(f) && !hyps.contains(&f) && !sfacts.contains(&f) {
                        sfacts.push(f);
                        seqadd = true;
                    }
                }
            }
            if seqadd {
                // The definitions of the new elements only.
                let t0 = self.tm.boolean(true);
                let mut nd = sfacts.clone();
                self.add_defs_of(t0, &mut nd, DEFS_ALL);
                for j in 0..nd.len() {
                    if !hyps.contains(&nd[j]) && !extra.contains(&nd[j]) {
                        extra.push(nd[j]);
                    }
                }
            }
            for j in 0..extra.len() {
                hyps.push(extra[j]);
                added = true;
            }
            extra.clear();
            let mut qs = Vector::<u32>::new();
            for (t, _v) in self.qof.iter() {
                if pol.contains_key(t) && !done.contains_key(t) {
                    qs.push(*t);
                }
            }
            qs.sort();
            if qs.len() == 0 {
                if seqadd {
                    continue;
                }
                return added;
            }
            for j in 0..qs.len() {
                let q = qs[j];
                done.insert(q, true);
                let ci = *self.qof.get(&q).unwrap();
                let c = &self.qclo[ci as usize];
                let (w, sg, own) = (c.w, c.sg, c.k);
                let ex = ((unsafe &*c.cb).quants[c.qi as usize].flags & ir::QF_EXISTS) != 0;
                let p = *pol.get(&q).unwrap();
                if (p & pick(ex, 2u8, 1u8)) == 0 {
                    continue;
                }
                // The terms a trigger matches in the formulas, or with `wide` every integer term.
                let mut cands = Vector::<u32>::new();
                if wide {
                    // With QI_MODEL none where QI_WIDE takes them all.
                    if mode != QI_MODEL || ints.len() > QUANT_TERMS {
                        cands.extend_copy(&ints);
                    }
                } else {
                    let trig = self.qclo[ci as usize].trig.clone();
                    for g in 0..trig.len() {
                        for x in 0..reach.len() {
                            let t = self.matched(trig[g], own, reach[x]);
                            if t != NONE && !cands.contains(&t) {
                                cands.push(t);
                            }
                        }
                    }
                }
                let mut n: usize = 0;
                let mut vals = Vector::<Num<B>>::new();
                let lo_v = self.model_value(&mv, self.qclo[ci as usize].lo);
                let hi_v = self.model_value(&mv, self.qclo[ci as usize].hi);
                let incl = ((unsafe &*self.qclo[ci as usize].cb).quants[self.qclo[ci as usize].qi as usize].flags & ir::QF_INCLUSIVE) != 0;
                for x in 0..cands.len() {
                    let mut t = cands[x];
                    if mode == QI_MODEL {
                        let v = switch self.model_value(&mv, t) {
                            Some(v) => v,
                            None => {
                                continue;
                            },
                        };
                        let below = lo_v.is_some() && v < lo_v.unwrap();
                        let above = hi_v.is_some() && (hi_v.unwrap() < v || !incl && hi_v.unwrap() == v);
                        if below || above || vals.contains(&v) {
                            continue;
                        }
                        vals.push(v);
                    }
                    let tt = self.tm.at(t);
                    // A constant of another integer type is the binding's constant of its value.
                    if tt.op == T_INT && (tt.w != w || tt.sg != sg) && w > W_BOOL {
                        let (lo, hi) = Terms::<B>::range(w, sg);
                        if !exact_w(w) && (tt.k < lo || hi < tt.k) || w == W_NAT && tt.k.is_negative() {
                            continue;
                        }
                        t = self.tm.int(tt.k, w, sg);
                    }
                    // Any integer term stands for an `int` binding, and for a `nat` one where it is at least 0
                    // (`k as int` is `k`'s own term).
                    let tt2 = self.tm.at(t);
                    let other = tt2.w != w || tt2.sg != sg;
                    if other && (!exact_w(w) || tt2.w <= W_BOOL) || t == own || n >= QUANT_TERMS {
                        continue;
                    }
                    n += 1;
                    let mut f = self.instance(q, ci, t);
                    if other && w != W_INT {
                        let fits = self.tm.in_type(t, w, sg);
                        f = self.imp(fits, f);
                    }
                    if !self.tm.is_true(f) && !hyps.contains(&f) {
                        hyps.push(f);
                        added = true;
                    }
                }
                if !self.spend() {
                    return added;
                }
            }
        }
        return added;
    }

    // The instances at the terms the model of each failed check puts in range (QI_MODEL), first that of
    // the check that just failed, then each round's, at most MODEL_ROUNDS: whether `pc0` and they imply
    // `goal`. None where the wide stage takes every integer term (`instantiate`).
    fn model_instances(self: &mut Self, goal: u32, pc0: &Vector<u32>) bool {
        let mut inst = Vector::<u32>::new();
        inst.extend_copy(pc0);
        self.add_defs(goal, &mut inst);
        for _r in 0..MODEL_ROUNDS {
            if self.sv.model.len() == 0 || !self.instantiate(goal, &mut inst, QI_MODEL) {
                return false;
            }
            if self.sv.implies(&self.tm, &inst, goal, false) {
                return true;
            }
        }
        return false;
    }

    // The value of integer term `t` in model `mv` (atom to value), None when an atom of it has none.
    fn model_value(self: &Self, mv: &Map<u32, Num<B>>, t: u32) Option<Num<B>> {
        if mv.len() == 0 {
            return None;
        }
        if let Some(v) = mv.get(&t) {
            return Some(*v);
        }
        let mut lin = Vector::<LinTerm<B>>::new();
        let mut stack = Vector::<LinTerm<B>>::new();
        let mut k = Num::<B>::zero();
        if !self.tm.is_int(t) || !lin_form(&self.tm, t, Num::<B>::one(), &mut k, &mut lin, &mut stack) {
            return None;
        }
        let mut s = k;
        for j in 0..lin.len() {
            let v = switch mv.get(&lin[j].atom) {
                Some(x) => *x,
                None => {
                    return None;
                },
            };
            switch ck(lin[j].c.checked_mul(&v)) {
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

    // The term `u` gives in place of `k` when it is trigger `g` with another term in place of `k`, NONE
    // when it is not.
    fn matched(self: &Self, g: u32, k: u32, u: u32) u32 {
        if g == u {
            return NONE;
        }
        let mut t = NONE;
        let mut work: u32 = 0;
        return pick(self.match_at(g, k, u, &mut t, &mut work), t, NONE);
    }

    // Whether `u` is `g` with `*t` in place of `k` (`*t` NONE: any term, then set), within MATCH_WORK
    // pairs of subterms.
    fn match_at(self: &Self, g: u32, k: u32, u: u32, t: &mut u32, work: &mut u32) bool {
        if g == k {
            if *t != NONE && *t != u {
                return false;
            }
            *t = u;
            return true;
        }
        *work += 1;
        if g == u && !self.mentions(g, k) {
            return true;
        }
        let gx = self.tm.at(g);
        let ux = self.tm.at(u);
        if *work > MATCH_WORK || gx.op != ux.op || gx.w != ux.w || gx.sg != ux.sg || gx.k != ux.k || !self.mentions(
            g,
            k,
        ) {
            return false;
        }
        let mut go = Vector::<u32>::new();
        let mut uo = Vector::<u32>::new();
        self.tm.operands(g, &mut go);
        self.tm.operands(u, &mut uo);
        if go.len() != uo.len() {
            return false;
        }
        for j in 0..go.len() {
            if !self.match_at(go[j], k, uo[j], t, work) {
                return false;
            }
        }
        return true;
    }

    // Whether term `t` holds `k` (operands are older terms than the terms they make, so a term older
    // than `k` holds none), within MATCH_WORK subterms; past them, true.
    fn mentions(self: &Self, t: u32, k: u32) bool {
        if t == k {
            return true;
        }
        if t < k {
            return false;
        }
        let mut stack = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(t);
        for _s in 0..MATCH_WORK {
            if stack.len() == 0 {
                return false;
            }
            let u = stack.pop().unwrap();
            if u == k {
                return true;
            }
            if u < k || seen.contains_key(&u) {
                continue;
            }
            seen.insert(u, true);
            self.tm.operands(u, &mut ops);
            stack.extend_copy(&ops);
        }
        return true;
    }

    // The instance of quantifier `q` (closure `ci`) at term `t`: `!q || !(lo <= t < hi) || E(t)` for
    // `forall`, `q || !(lo <= t < hi) || !E(t)` for `exists`.
    fn instance(self: &mut Self, q: u32, ci: u32, t: u32) u32 {
        let key = q as u64 << 32 | t as u64;
        if let Some(f) = self.qinst.get(&key) {
            return *f;
        }
        let none = Vector::<u32>::new();
        let co = replace(&mut self.chain_ovf, OVF_EXACT);
        let oo = replace(&mut self.utrig_on, false);
        let e = self.quant_body(ci, t, &none);
        self.utrig_on = oo;
        self.chain_ovf = co;
        let ex = ((unsafe &*self.qclo[ci as usize].cb).quants[self.qclo[ci as usize].qi as usize].flags & ir::QF_EXISTS) != 0;
        let inr = self.quant_range(ci, t);
        let out = self.tm.not(inr);
        let f = if ex {
            let ne = self.tm.not(e);
            let a = self.tm.or(out, ne);
            self.tm.or(q, a)
        } else {
            let nq = self.tm.not(q);
            let a = self.tm.or(out, e);
            self.tm.or(nq, a)
        };
        self.qinst.insert(key, f);
        return f;
    }

    // `lo <= t < hi` (`<= hi` for an inclusive range) of quantifier closure `ci`.
    fn quant_range(self: &mut Self, ci: u32, t: u32) u32 {
        let c = &self.qclo[ci as usize];
        let (lo, hi) = (c.lo, c.hi);
        let incl = ((unsafe &*c.cb).quants[c.qi as usize].flags & ir::QF_INCLUSIVE) != 0;
        let a = self.tm.cmp(T_LE, lo, t);
        let b = self.tm.cmp(pick(incl, T_LE, T_LT), t, hi);
        return self.tm.and(a, b);
    }

    // `E` of quantifier closure `ci` with its binding `t`, under `pc` (the range included): the paths
    // to its value, a clause's condition (its own checks are part of it).
    fn quant_body(self: &mut Self, ci: u32, t: u32, pc: &Vector<u32>) u32 {
        let cbp = self.qclo[ci as usize].cb;
        let cb = unsafe &*cbp;
        let cm = self.qclo[ci as usize].cm;
        let all = self.qclo[ci as usize].all;
        let qs = cb.quants[self.qclo[ci as usize].qi as usize];
        let mut st = self.qclo[ci as usize].state.clone();
        st.set(qs.var as usize, t);
        let site = ir::ContractSite {
            pred: 0,
            chain: qs.body,
            check: qs.check,
            cont: 0,
            clause: 0,
            kind: CT_INVARIANT,
            value: ir::IR_NONE,
        };
        let mem = if self.qclo[ci as usize].has_mem {
            (&self.qclo[ci as usize].mem) as *const Vector<u32>
        } else {
            null
        };
        let om = replace(&mut self.mem, mem);
        let ig = replace(&mut self.in_ghost, false);
        self.chain_depth += 1;
        let none = tok::Span { start: 0, end: 0 };
        let mut no = Vector::<u64>::new();
        let (f, _v) = self.chain_in(cb, cm, site, &st, pc, all, none, &mut no);
        self.chain_depth -= 1;
        self.in_ghost = ig;
        self.mem = om;
        return f;
    }

    // Quantifier `qi` of body `cb`, reached in `state` under `pc`: a fresh atom `q` with its closure, and
    // the fact of its witness `k` (the value where a `forall` fails, or an `exists` holds), anchored on
    // `q`: `q || (lo <= k < hi && !E(k))`, or `!q || (lo <= k < hi && E(k))`. `E(k)` is walked with the
    // walk's obligations (each check of `E` defined for every value in the range).
    fn quantifier(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        qi: u32,
        state: &mut Vector<u32>,
        pc: &Vector<u32>,
        all: bool,
    ) u32 {
        let qs = cb.quants[qi as usize];
        let lo = self.operand(cb, cm, state, qs.lo, all);
        let hi = self.operand(cb, cm, state, qs.hi, all);
        let (w, sg) = self.ty_of(cm, cb.locals.at(qs.var as usize).ty);
        let q = self.tm.var(W_BOOL, false);
        if !self.tm.is_int(lo) || !self.tm.is_int(hi) {
            return q;
        }
        let has_mem = self.mem != null;
        let mem = if has_mem {
            (unsafe &*self.mem).clone()
        } else {
            Vector::<u32>::new()
        };
        let ci = self.qclo.len() as u32;
        self.qclo.push(
            QClo {
                cb: cb,
                cm: cm,
                qi: qi,
                state: state.clone(),
                mem: mem,
                has_mem: has_mem,
                all: all,
                lo: lo,
                hi: hi,
                k: NONE,
                trig: Vector::<u32>::new(),
                w: w,
                sg: sg,
            },
        );
        self.qof.insert(q, ci);
        let k = self.tm.var(w, sg);
        self.qclo.index_mut(ci as usize).k = k;
        let inr = self.quant_range(ci, k);
        let mut pck = pc.clone();
        pck.push(inr);
        let ou = replace(&mut self.utrig, Vector::<u32>::new());
        let oo = replace(&mut self.utrig_on, true);
        let e = self.quant_body(ci, k, &pck);
        let mine = replace(&mut self.utrig, ou);
        self.utrig_on = oo;
        let f = if (qs.flags & ir::QF_EXISTS) != 0 {
            let nq = self.tm.not(q);
            let a = self.tm.and(inr, e);
            self.tm.or(nq, a)
        } else {
            let ne = self.tm.not(e);
            let a = self.tm.and(inr, ne);
            self.tm.or(q, a)
        };
        self.qdef.insert(f, true);
        self.anchor(q, f);
        // The user's triggers that hold the binding, else the body's own.
        let mut tr = Vector::<u32>::new();
        for j in 0..mine.len() {
            if mine[j] != k && self.mentions(mine[j], k) {
                tr.push(mine[j]);
            }
        }
        if tr.len() == 0 {
            tr = self.triggers(e, k);
        }
        self.qclo.index_mut(ci as usize).trig = tr;
        return q;
    }

    // The terms under `e` (through the witnesses' facts of the quantifiers it names) that hold `k` and
    // are no formula: a term the facts name of one of these shapes with another term in place of `k`
    // gives the instance term (`instantiate`, `matched`).
    fn triggers(self: &Self, e: u32, k: u32) Vector<u32> {
        let mut out = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(e);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                break;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if let Some(d) = self.def_of.get(&t) {
                if self.qof.contains_key(&t) {
                    stack.push(self.defs[(*d) as usize]);
                }
            }
            let x = self.tm.at(t);
            self.tm.operands(t, &mut ops);
            let formula = x.op >= T_LT && x.op <= T_OR;
            if !formula && t != k && out.len() < TRIGGERS_MAX && self.mentions(t, k) {
                out.push(t);
            }
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
        return out;
    }

    // The quantifier of body `cb` whose loop starts at block `blk`, NONE when none does.
    const fn quant_at(cb: &ir::CoreBody, blk: u32) u32 {
        for j in 0..cb.quants.len() {
            if cb.quants[j].entry == blk {
                return j as u32;
            }
        }
        return NONE;
    }

    // Append to `hyps` (the path) the definitions of the spec function calls under `goal` and `hyps`,
    // and of the calls under those definitions.
    fn add_defs(self: &mut Self, goal: u32, hyps: &mut Vector<u32>) {
        self.add_defs_of(goal, hyps, DEFS_ALL);
    }

    // The disjunction of `alts` with the conjuncts every one of them holds taken out: `a && b && (c || d)`
    // for `(a && b && c) || (a && b && d)`, whose common parts the solver takes as facts, not cases.
    fn factor_or(self: &mut Self, alts: &Vector<u32>) u32 {
        let mut ps = Vector::<Vector<u32>>::with_capacity(alts.len());
        for j in 0..alts.len() {
            let mut parts = Vector::<u32>::new();
            self.conjuncts(alts[j], &mut parts, 0);
            ps.push(parts);
        }
        return self.factor_parts(&mut ps, 0);
    }

    // `factor_or` of the alternatives `ps`, each a list of conjuncts. Past the common conjuncts, the
    // alternatives split on a condition `c` each of them tests (a branch of the paths), `c && x || !c && y`,
    // and the conjuncts both sides share come out again: the paths of `(a || b) && (c || d)` give that
    // conjunction, not its four products.
    fn factor_parts(self: &mut Self, ps: &mut Vector<Vector<u32>>, depth: u32) u32 {
        if ps.len() == 0 {
            return self.tm.boolean(false);
        }
        // One order of the conjuncts: equal lists build one term.
        for j in 0..ps.len() {
            ps.index_mut(j).sort();
        }
        let mut common = ps[0].clone();
        for j in 1..ps.len() {
            let mut q: usize = 0;
            while q < common.len() {
                if ps[j].contains(&common[q]) {
                    q += 1;
                } else {
                    let _ = common.remove(q);
                }
            }
        }
        let mut g = self.tm.boolean(true);
        for q in 0..common.len() {
            g = self.tm.and(common[q], g);
        }
        let mut any_true = false;
        for j in 0..ps.len() {
            let p = ps.index_mut(j);
            let mut q: usize = 0;
            while q < p.len() {
                if common.contains(&p[q]) {
                    let _ = p.remove(q);
                } else {
                    q += 1;
                }
            }
            any_true = any_true || p.len() == 0;
        }
        if any_true {
            return g;
        }
        // The split condition: a conjunct of the first alternative that every other one holds or denies.
        let mut c = NONE;
        if ps.len() > 1 && depth < FACTOR_DEPTH {
            for q in 0..ps[0].len() {
                let x = ps[0][q];
                let nx = self.tm.not(x);
                let mut all = true;
                for j in 1..ps.len() {
                    all = all && (ps[j].contains(&x) || ps[j].contains(&nx));
                }
                if all {
                    c = x;
                    break;
                }
            }
        }
        if c == NONE {
            let mut rest = self.tm.boolean(false);
            for j in 0..ps.len() {
                let mut a = self.tm.boolean(true);
                for q in 0..ps[j].len() {
                    a = self.tm.and(a, ps[j][q]);
                }
                rest = self.tm.or(rest, a);
            }
            return self.tm.and(g, rest);
        }
        let nc = self.tm.not(c);
        let mut yes = Vector::<Vector<u32>>::new();
        let mut no = Vector::<Vector<u32>>::new();
        for j in 0..ps.len() {
            let mut p = ps[j].clone();
            let k = if p.contains(&c) {
                c
            } else {
                nc
            };
            for q in 0..p.len() {
                if p[q] == k {
                    let _ = p.remove(q);
                    break;
                }
            }
            if k == c {
                yes.push(p);
            } else {
                no.push(p);
            }
        }
        let ry = self.factor_parts(&mut yes, depth + 1);
        let rn = self.factor_parts(&mut no, depth + 1);
        let ay = self.tm.and(c, ry);
        let an = self.tm.and(nc, rn);
        let mut two = Vector::<Vector<u32>>::with_capacity(2);
        for a in [ay, an] {
            let mut parts = Vector::<u32>::new();
            self.conjuncts(a, &mut parts, 0);
            two.push(parts);
        }
        let h = self.factor_parts(&mut two, FACTOR_DEPTH);
        return self.tm.and(g, h);
    }

    // The conjuncts of `f` into `out`, `depth` levels of `&&` deep.
    fn conjuncts(self: &Self, f: u32, out: &mut Vector<u32>, depth: u32) {
        let x = self.tm.at(f);
        if x.op == T_AND && depth < 16 {
            self.conjuncts(x.a, out, depth + 1);
            self.conjuncts(x.b, out, depth + 1);
        } else if !self.tm.is_true(f) && !out.contains(&f) {
            out.push(f);
        }
    }

    // Whether term `t` has at most EXACT_TERMS distinct subterms, no call of a recursive spec function
    // (`recd`) and no quantifier (each call's own atom): a value that can stand for the call that returns
    // it (`exact`). Another stays the call,
    // and its definition joins only the goals that need it: congruence relates two such calls, where
    // their values would unfold each recursion into every goal.
    fn small(self: &Self, t: u32) bool {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(t);
        while stack.len() != 0 {
            let u = stack.pop().unwrap();
            if seen.contains_key(&u) {
                continue;
            }
            if seen.len() >= EXACT_TERMS || self.recd.contains_key(&u) || self.qof.contains_key(&u) {
                return false;
            }
            seen.insert(u, true);
            self.tm.operands(u, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
        return true;
    }

    // Definition `f` where facts `base` hold: a disjunct one of them refutes (`refuted`) dropped, in the
    // disjunctions and conjunctions `depth` levels deep at most (a callee's `ensures` by its cases: the
    // path's case alone).
    fn prune_def(self: &mut Self, base: &Vector<u32>, f: u32, depth: u32) u32 {
        let x = self.tm.at(f);
        if depth >= PRUNE_DEPTH || x.op != T_OR && x.op != T_AND {
            return f;
        }
        let a = self.prune_def(base, x.a, depth + 1);
        let b = self.prune_def(base, x.b, depth + 1);
        if x.op == T_AND {
            return pick(a == x.a && b == x.b, f, self.tm.and(a, b));
        }
        if self.refuted(base, a, 0) {
            return b;
        }
        if self.refuted(base, b, 0) {
            return a;
        }
        return pick(a == x.a && b == x.b, f, self.tm.or(a, b));
    }

    // Whether facts `base` state the negation of `c`, or of a part of conjunction `c` (`bool_stated`).
    fn refuted(self: &mut Self, base: &Vector<u32>, c: u32, depth: u32) bool {
        let x = self.tm.at(c);
        if x.op == T_AND && depth < PRUNE_DEPTH {
            return self.refuted(base, x.a, depth + 1) || self.refuted(base, x.b, depth + 1);
        }
        let nc = self.tm.not(c);
        return self.tm.is_false(c) || self.bool_stated(base, nc, 0);
    }

    // `add_defs` of the kind `mode` names: DEFS_ALL; DEFS_QUANTS, without the definitions of spec
    // function calls (`specd`); DEFS_NEAR, only those of the terms `goal` and `hyps` name, not of the
    // terms the definitions name; DEFS_REC, only those of the recursive calls (`recd`) these name.
    fn add_defs_of(self: &mut Self, goal: u32, hyps: &mut Vector<u32>, mode: u8) {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(goal);
        for j in 0..hyps.len() {
            stack.push(hyps[j]);
        }
        // A definition without the cases these facts refute (`prune_def`).
        let base = hyps.clone();
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if mode == DEFS_QUANTS && self.specd.contains_key(&t) {
                self.tm.operands(t, &mut ops);
                for j in 0..ops.len() {
                    stack.push(ops[j]);
                }
                continue;
            }
            if let Some(d) = self.def_of.get(&t) {
                let mut open = true;
                if mode == DEFS_OPEN {
                    let mut ls = Map::<u32, bool>::new();
                    self.leaves_into(t, &mut ls);
                    open = ls.len() != 0;
                }
                let f0 = self.defs[(*d) as usize];
                let f = self.prune_def(&base, f0, 0);
                if open && !hyps.contains(&f) && (mode != DEFS_REC || self.recd.contains_key(&t)) {
                    hyps.push(f);
                }
                if mode != DEFS_NEAR && mode != DEFS_REC && mode != DEFS_OPEN {
                    stack.push(f);
                }
            }
            self.tm.operands(t, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
    }

    // Whether a conjunct of goal `g` is a struct's invariant (`inv_terms`).
    fn names_inv(self: &Self, g: u32) bool {
        let mut parts = Vector::<u32>::new();
        self.conjuncts(g, &mut parts, 0);
        for j in 0..parts.len() {
            if self.inv_terms.contains_key(&parts[j]) {
                return true;
            }
        }
        return false;
    }

    // Whether formula `f` names an equality of sequences (`seq_ext`) through its connectives, `depth`
    // levels deep.
    fn names_seq_eq(self: &Self, f: u32, depth: u32) bool {
        let x = self.tm.at(f);
        if (x.op == T_AND || x.op == T_OR) && depth < 16 {
            return self.names_seq_eq(x.a, depth + 1) || self.names_seq_eq(x.b, depth + 1);
        }
        if x.op == T_NOT && depth < 16 {
            return self.names_seq_eq(x.a, depth + 1);
        }
        let mut j: usize = 0;
        while j < self.seqeqs.len() {
            if self.seqeqs[j] == f {
                return true;
            }
            j += 3;
        }
        return false;
    }

    // Prove that the conditions `pc` imply `goal`; report obligation `key` when they do not.
    fn oblige(self: &mut Self, pc: &Vector<u32>, goal0: u32, key: u64, sp: tok::Span, msg: String, note: String) {
        if self.over || self.failed.contains_key(&key) || self.refining && !self.refine_all && key >> 56 != OB_REFINE {
            return;
        }
        // A body with a `panics if` may panic where it holds: a check, a panic or an overflow of its own
        // code is an obligation only where it is false.
        let kind = key >> 56;
        let goal = if self.pan_cond != NONE && !self.in_ghost && self.chain_depth == 0 && (kind == OB_PANIC || kind == OB_OVERFLOW) {
            self.tm.or(self.pan_cond, goal0)
        } else {
            goal0
        };
        // With constants of half the narrow width, an overflow sends the body to the wide prover at once:
        // one already seen fails this obligation unproved.
        if B == NUM_NARROW && self.tm.big_seen && self.sv.overflowed() {
            self.report2(key, dc::CANNOT_PROVE_CONTRACT, sp, msg, note, String::new());
            self.over = true;
            return;
        }
        // A goal another path proved from facts this path states too.
        let mut sorted = pc.clone();
        sorted.sort();
        if let Some(ps) = self.proved.get(&goal) {
            for j in 0..ps.len() {
                if sorted_within(ps.at(j), &sorted) {
                    return;
                }
            }
        }
        self.sv.stop_on_ovf = B == NUM_NARROW && self.tm.big_seen;
        self.sv.gave_up = false;
        let mut ok = self.holds(pc, goal);
        // A goal over products of unknowns: once more with the products of rows (`Solver::nla_attempt`).
        if !ok && !self.sv.gave_up && self.steps + self.sv.steps <= STEP_BUDGET && self.has_product(goal, pc) {
            self.sv.nla_allowed = true;
            ok = self.holds(pc, goal);
            self.sv.nla_allowed = false;
        }
        self.sv.stop_on_ovf = false;
        self.sv.gave_up = false;
        if self.sv.halted {
            return;
        }
        if ok {
            if !self.proved.contains_key(&goal) {
                self.proved.insert(goal, Vector::<Vector<u32>>::new());
            }
            let ps = self.proved.get_mut(&goal).unwrap();
            if ps.len() < PROVED_SETS {
                ps.push(sorted);
            }
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
        if self.facts_only {
            return;
        }
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
        // A static with an invariant: memory's value now, never kept as the local's.
        let sr = self.static_here(cb, l);
        if sr != NONE {
            return self.static_val(cb, cm, state, l, sr);
        }
        if state[l as usize] == NONE {
            let ld = cb.locals.at(l as usize);
            let d = ld.item;
            let v = if d.node != NODE_NONE && (d.node & NODE_BODY) == 0 && self.ast_of(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
                let c = self.const_arg(d, cm, ld.ty);
                if c != NONE {
                    c
                } else {
                    self.param_var(d, cm, ld.ty)
                }
            } else if self.const_local(cb, l) {
                // A named constant: an integer or a boolean is its value (the evaluator's), another
                // (`const K: [u32; 64]`) one unknown wherever it is read, in a body or a clause.
                let (w, sg) = self.ty_of(cm, ld.ty);
                let cev = self.pkg().cir as *mut iri::Interp;
                let cv = if w != W_OTHER && cev != null {
                    unsafe (*cev).eval(d.module, d.node)
                } else {
                    iri::IVal { kind: iri::IV_NONE, tm: 0, ty: TYPE_NONE, i: 0, f: 0.0 }
                };
                if cv.kind == iri::IV_INT && w > W_BOOL {
                    let k = if !sg && cv.i < 0 {
                        u64_val::<B>(cv.i as u64)
                    } else {
                        wide::<B>(cv.i)
                    };
                    self.tm.int(k, w, sg)
                } else if cv.kind == iri::IV_BOOL && w == W_BOOL {
                    self.tm.boolean(cv.i != 0)
                } else {
                    let none = Vector::<u32>::new();
                    self.tm.call(skey_mix(6, d.module as u64 << 32 | d.node as u64), &none, w, sg)
                }
            } else {
                self.fresh(cm, ld.ty)
            };
            state.set(l as usize, v);
        }
        return state[l as usize];
    }

    // Whether local `l` of body `cb` names a `const` item, a value nothing writes.
    fn const_local(self: &Self, cb: &ir::CoreBody, l: u32) bool {
        let ld = cb.locals.at(l as usize);
        let d = ld.item;
        return ld.storage == ir::LS_STATIC_REF && d.node != NODE_NONE && (d.node & NODE_BODY) == 0 && self.pkg().modules.at(
            d.module as usize,
        ).has_ast && self.ast_of(d.module).at_const(d.node).kind == NodeKind::NODE_CONST;
    }

    // The value place `pl` of body `cb` holds. `all`: every whole local is modeled (a callee frame).
    // The state's last entry is the memory epoch.
    fn read_place(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, pl: u32, all: bool) u32 {
        let p = *cb.places.at(pl as usize);
        if !all && !self.tracked[p.base as usize] && !self.const_local(cb, p.base) && !self.generic_local(cb, p.base) && self.static_here(
            cb,
            p.base,
        ) == NONE {
            return self.fresh(cm, p.ty);
        }
        return self.read_prefix(cb, cm, state, &p, p.proj_len, all);
    }

    // Whether local `l` names a const generic parameter: one term per body (`param_var`), or the
    // constant `subst` binds it to (`const_arg`).
    fn generic_local(self: &Self, cb: &ir::CoreBody, l: u32) bool {
        let d = cb.locals.at(l as usize).item;
        return d.node != NODE_NONE && (d.node & NODE_BODY) == 0 && self.pkg().modules.at(d.module as usize).has_ast && self.ast_of(
            d.module,
        ).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM;
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
        let mut in_union = false;
        for j in p.proj_start..p.proj_start + n {
            let pj = *cb.projections.at(j as usize);
            // A member of a call's result (`Some(b)` of `v.pop()`) left a body with it: in the struct's own
            // file too, it satisfies its invariant, as the result itself does (`inv_called`).
            let res = (pj.kind == ir::PJ_FIELD || pj.kind == ir::PJ_DOWNCAST) && self.res_of.contains_key(&v);
            let pk = self.ptr_index(cb, cm, p, j - p.proj_start);
            if pj.kind == ir::PJ_DEREF {
                let vo = self.tm.at(v).op;
                let pr = if !all && vo != T_MREF && vo != T_PREF && vo != T_REF && self.raw_ptr_ty(cm, ty) {
                    self.ptr_read(cb, cm, state, v, NONE, pj.ty)
                } else {
                    NONE
                };
                v = if pr != NONE {
                    pr
                } else {
                    let raw = vo != T_MREF && vo != T_PREF && vo != T_REF && self.raw_ptr_ty(cm, ty);
                    let x = self.deref(state, v, cm, pj.ty);
                    // A struct behind a pointer keeps its invariant, where no write of this block is unproved:
                    // a read in an assignment proves those at other pointers first (`mi_close_at`).
                    if raw && self.tm.at(x).op == T_LOAD && self.mi_type(cm, pj.ty) {
                        self.mi_ld(v, cm, pj.ty, x);
                        if !self.mi_fresh.contains(&v) {
                            self.mi_close_at(cb, state, v);
                        }
                    }
                    if raw && self.mi_dirty.len() == 0 && self.tm.at(x).op == T_LOAD && !self.mi_seen.contains_key(&x) && self.mi_type(
                        cm,
                        pj.ty,
                    ) && !self.mi_fresh.contains(&v) {
                        self.mi_seen.insert(x, true);
                        // Memory holds its blocks until a write opens it.
                        let ov0 = replace(&mut self.ov, OV_MEM);
                        let f = self.inv_of(cm, pj.ty, x, state);
                        self.ov = ov0;
                        if f != NONE {
                            self.anchor(x, f);
                        }
                    }
                    x
                };
            } else if pj.kind == ir::PJ_DOWNCAST {
                let vx = self.tm.at(v);
                v = if vx.op == T_AGG && vx.k == wide::<B>(pj.data as i64 + 1) {
                    // A literal of that variant: its members.
                    let mut ms = Vector::<u32>::new();
                    self.tm.operands(v, &mut ms);
                    self.tm.pool(T_AGG, &ms, Num::<B>::zero())
                } else {
                    self.tm.make(Term::<B> { k: wide::<B>(pj.data), a: v, b: 0, op: T_DOWN, w: W_OTHER, sg: false })
                };
            } else if j + 1 < p.proj_start + n && self.ptr_index(cb, cm, p, j + 1 - p.proj_start) == PI_OWNED {
                // An `@owned` field an index follows: the block, which holds the elements.
                let k = self.own_key(cm, ty, &pj);
                v = self.sel(v, k, W_OTHER, false);
                ty = pj.ty;
                continue;
            } else if pk == PI_OWNED {
                // An element of the block: the sequence's, at an index below its length (`own_check`).
                let key = self.proj_key(cb, cm, state, &pj, ty, all);
                let (w, sg) = self.ty_of(cm, pj.ty);
                if !all {
                    self.own_chk.push(key);
                    self.own_chk.push(v);
                    self.own_chk.push(self.size_term(cm, pj.ty));
                }
                v = self.seq_at(v, key, w, sg);
                if w == W_OTHER {
                    v = self.eta(cm, pj.ty, v, 0);
                }
            } else if pk == PI_MEM {
                // An element of memory a raw pointer reaches: of the block or the inline array it points
                // into (`ptr_read`), else a load in this epoch.
                let key = self.proj_key(cb, cm, state, &pj, ty, all);
                let pr = if all {
                    NONE
                } else {
                    self.ptr_read(cb, cm, state, v, key, pj.ty)
                };
                if pr != NONE {
                    v = pr;
                } else {
                    let addr = self.elem_addr(v, key);
                    v = self.deref(state, addr, cm, pj.ty);
                }
            } else if pj.kind == ir::PJ_FIELD && pj.data == ir::IR_NONE && self.is_slice_ty(cm, ty) {
                let sa = self.ast_of(self.slice.mid);
                let len = self.text(self.slice.mid, sa.at_const(sa.at_const(pj.sub).as_data.field.name).span) == "len";
                v = self.slice_field(v, len);
            } else {
                if pj.kind == ir::PJ_FIELD && pj.data == ir::PJ_UNION_FIELD {
                    self.union_coherence(cm, ty, v);
                }
                let key = self.proj_key(cb, cm, state, &pj, ty, all);
                let (w, sg) = self.ty_of(cm, pj.ty);
                v = self.sel(v, key, w, sg);
                // A small aggregate member is the aggregate of its own members (`eta`), as a call's result
                // is: `g[c]` of a long array of secrets and `Secret::new(x)` are one term where their
                // values are. Not below a union's member, whose bytes its value is.
                in_union = in_union || pj.kind == ir::PJ_FIELD && pj.data == ir::PJ_UNION_FIELD;
                if w == W_OTHER && !in_union {
                    v = self.eta(cm, pj.ty, v, 0);
                }
            }
            self.pat_fact(cm, pj.ty, v);
            if res && v != NONE {
                self.res_of.insert(v, true);
                // Its blocks are the result's, apart from the other sources' (`inv_called`).
                if !all && self.inv_here(cm, pj.ty) {
                    let s1 = replace(&mut self.ov_src, SRC_RES);
                    let f = self.inv_of(cm, pj.ty, v, state);
                    self.src_mark(f, SRC_RES);
                    self.sh_give(f);
                    self.ov_src = s1;
                    if f != NONE {
                        self.anchor(v, f);
                    }
                }
            }
            ty = pj.ty;
        }
        return v;
    }

    // Whether type `ty` of module `m` is a slice (`[]T`, `[]mut T`).
    // Whether `ty` (module `m`) is a raw pointer type.
    fn raw_ptr_ty(self: &Self, m: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let (rm, rt) = self.resolve(m, ty);
        return self.ast_of(rm).type_at(rt).kind == TypeKind::TYPE_POINTER;
    }

    fn is_slice_ty(self: &Self, m: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let (rm, rt) = self.resolve(m, ty);
        if self.ast_of(rm).type_at(rt).kind == TypeKind::TYPE_SLICE {
            return true;
        }
        let (dm, dd) = self.decl_of(m, ty);
        return dd != NODE_NONE && (dm == self.slice.mid && dd == self.slice.node || dm == self.smut.mid && dd == self.smut.node);
    }

    // A field of slice `v`: its length (`len`) is the sequence's, and its pointer is not null where the
    // length is not 0, as it points at that many elements.
    fn slice_field(self: &mut Self, v: u32, len: bool) u32 {
        let n = self.sq1(SQ_SLEN, v, self.pw, false);
        // A literal `Slice { ptr, len }`: its length is its member.
        let x = self.tm.at(v);
        if x.op == T_AGG && x.b == 2 && !self.ptrd.contains_key(&n) {
            self.ptrd.insert(n, true);
            let m1 = self.sel(v, self.tm.int(Num::<B>::one(), 64, false), self.pw, false);
            let e = self.tm.cmp(T_EQ, n, m1);
            self.anchor(n, e);
        }
        if len {
            return n;
        }
        let p = self.sel(v, self.tm.int(Num::<B>::zero(), 64, false), W_OTHER, false);
        if !self.ptrd.contains_key(&p) {
            self.ptrd.insert(p, true);
            let z = self.tm.int(Num::<B>::zero(), self.pw, false);
            let e = self.tm.cmp(T_EQ, n, z);
            let nl = self.null_ptr();
            let nn = self.tm.cmp(T_NE, p, nl);
            let f = self.tm.or(e, nn);
            self.anchor(p, f);
        }
        return p;
    }

    // Member `key` of `v`, of type (`w`, `sg`) (`Terms::sel`). A key that is no constant reads a member
    // the fact of the read names, anchored on the read: through an update `(key == k && r == x) ||
    // (key != k && r == v'[key])`; of an aggregate of at most 64 members `!(0 <= key < n) ||
    // (key == 0 && r == m0) || ..`.
    fn sel(self: &mut Self, v: u32, key: u32, w: u16, sg: bool) u32 {
        if self.tm.at(key).op != T_INT {
            if let Some(src) = self.eta_src.get(&v) {
                return self.sel(*src, key, w, sg);
            }
        }
        let r = self.tm.sel(v, key, w, sg);
        let rt = self.tm.at(r);
        if rt.op != T_SEL || self.seld.contains_key(&r) {
            return r;
        }
        self.seld.insert(r, true);
        // An element of an array a copy wrote (`mem_copy`): the source's within the copied range, else the
        // old array's.
        let ex = self.tm.at(v);
        if ex.op == T_CALL && ex.b == 4 && ex.k == u64_val::<B>(skey_mix(19, 0)) {
            let old = self.tm.args[ex.a as usize];
            let at = self.key_int(self.tm.args[(ex.a + 1) as usize]);
            let part = self.tm.args[(ex.a + 2) as usize];
            let n = self.key_int(self.tm.args[(ex.a + 3) as usize]);
            let wk = self.key_int(key);
            if at != NONE && n != NONE && wk != NONE {
                let lo = self.tm.cmp(T_LE, at, wk);
                let end = self.tm.arith(T_ADD, at, n, W_INT, true);
                let up = self.tm.cmp(T_LT, wk, end);
                let inr = self.tm.and(lo, up);
                let d = self.tm.arith(T_SUB, wk, at, W_INT, true);
                let e1 = self.seq_at(part, d, w, sg);
                let e2 = self.sel(old, key, w, sg);
                let a1 = self.tm.and(inr, self.tm.cmp(T_EQ, r, e1));
                let ninr = self.tm.not(inr);
                let a2 = self.tm.and(ninr, self.tm.cmp(T_EQ, r, e2));
                let f = self.tm.or(a1, a2);
                self.anchor(r, f);
            }
            return r;
        }
        // A member of an element read at an index of an update (`a'[k].f`): the case split of the element
        // read (below), taken to the member, as a fact needs no equality of the two elements' members.
        if self.tm.at(key).op == T_INT && ex.op == T_SEL && self.tm.at(ex.b).op != T_INT && self.tm.at(ex.a).op == T_UPD {
            let ux = self.tm.at(ex.a);
            let base = self.tm.args[ux.a as usize];
            let k2 = self.tm.args[(ux.a + 1) as usize];
            let x = self.tm.args[(ux.a + 2) as usize];
            let rx = self.sel(x, key, w, sg);
            let be = self.sel(base, ex.b, ex.w, ex.sg);
            let inner = self.sel(be, key, w, sg);
            let same = self.tm.cmp(T_EQ, ex.b, k2);
            let e1 = self.tm.cmp(T_EQ, r, rx);
            let e2 = self.tm.cmp(T_EQ, r, inner);
            let a1 = self.tm.and(same, e1);
            let nsame = self.tm.not(same);
            let a2 = self.tm.and(nsame, e2);
            let f = self.tm.or(a1, a2);
            self.anchor(r, f);
            return r;
        }
        // Of an element read at an index of a small aggregate (`[c0, c1][k].f`): one case per member.
        if self.tm.at(key).op == T_INT && ex.op == T_SEL && self.tm.at(ex.b).op != T_INT && self.tm.is_int(ex.b) && self.tm.at(
            ex.a,
        ).op == T_AGG && self.tm.at(ex.a).b <= SEL_CASES {
            let ax = self.tm.at(ex.a);
            let k = ex.b;
            let (kw, ksg) = (self.tm.at(k).w, self.tm.at(k).sg);
            let z = self.tm.int(Num::<B>::zero(), kw, ksg);
            let n = self.tm.int(wide::<B>(ax.b), kw, ksg);
            let c1 = self.tm.cmp(T_LE, z, k);
            let c2 = self.tm.cmp(T_LT, k, n);
            let inr = self.tm.and(c1, c2);
            let mut f = self.tm.not(inr);
            for j in 0..ax.b {
                let kj = self.tm.int(wide::<B>(j), kw, ksg);
                let at = self.tm.cmp(T_EQ, k, kj);
                let mj = self.sel(self.tm.args[(ax.a + j) as usize], key, w, sg);
                let e = self.tm.cmp(T_EQ, r, mj);
                let one = self.tm.and(at, e);
                f = self.tm.or(f, one);
            }
            self.anchor(r, f);
            return r;
        }
        if self.tm.at(key).op == T_INT || !self.tm.is_int(key) {
            return r;
        }
        let vx = self.tm.at(rt.a);
        let (kw, ksg) = (self.tm.at(key).w, self.tm.at(key).sg);
        if vx.op == T_UPD {
            let base = self.tm.args[vx.a as usize];
            let k2 = self.tm.args[(vx.a + 1) as usize];
            let x = self.tm.args[(vx.a + 2) as usize];
            let inner = self.sel(base, key, w, sg);
            let same = self.tm.cmp(T_EQ, key, k2);
            let e1 = self.tm.cmp(T_EQ, r, x);
            let e2 = self.tm.cmp(T_EQ, r, inner);
            let a1 = self.tm.and(same, e1);
            let nsame = self.tm.not(same);
            let a2 = self.tm.and(nsame, e2);
            let f = self.tm.or(a1, a2);
            self.anchor(r, f);
        } else if vx.op == T_AGG && vx.b > 0 && self.tm.is_int(r) {
            self.table_bounds(r, key, kw, ksg);
        }
        if vx.op == T_AGG && vx.b <= SEL_CASES {
            let z = self.tm.int(Num::<B>::zero(), kw, ksg);
            let n = self.tm.int(wide::<B>(vx.b), kw, ksg);
            let c1 = self.tm.cmp(T_LE, z, key);
            let c2 = self.tm.cmp(T_LT, key, n);
            let inr = self.tm.and(c1, c2);
            let mut f = self.tm.not(inr);
            for j in 0..vx.b {
                let kj = self.tm.int(wide::<B>(j), kw, ksg);
                let at = self.tm.cmp(T_EQ, key, kj);
                let e = self.tm.cmp(T_EQ, r, self.tm.args[(vx.a + j) as usize]);
                let one = self.tm.and(at, e);
                f = self.tm.or(f, one);
            }
            self.anchor(r, f);
        }
        return r;
    }

    // A read `r` at key `key` of an aggregate of integer constants (a table) lies between its least and
    // its greatest member for a key in range: `!(0 <= key < n) || (lo <= r && r <= hi)`.
    fn table_bounds(self: &mut Self, r: u32, key: u32, kw: u16, ksg: bool) {
        let vx = self.tm.at(self.tm.at(r).a);
        let first = self.tm.at(self.tm.args[vx.a as usize]);
        if first.op != T_INT {
            return;
        }
        let (mut lo, mut hi) = (first.k, first.k);
        for j in 1..vx.b {
            let m = self.tm.at(self.tm.args[(vx.a + j) as usize]);
            if m.op != T_INT {
                return;
            }
            lo = pick(m.k < lo, m.k, lo);
            hi = pick(hi < m.k, m.k, hi);
        }
        let (w, sg) = (self.tm.at(r).w, self.tm.at(r).sg);
        let z = self.tm.int(Num::<B>::zero(), kw, ksg);
        let n = self.tm.int(wide::<B>(vx.b), kw, ksg);
        let c1 = self.tm.cmp(T_LE, z, key);
        let c2 = self.tm.cmp(T_LT, key, n);
        let inr = self.tm.and(c1, c2);
        let lot = self.tm.int(lo, w, sg);
        let hit = self.tm.int(hi, w, sg);
        let b1 = self.tm.cmp(T_LE, lot, r);
        let b2 = self.tm.cmp(T_LE, r, hit);
        let inb = self.tm.and(b1, b2);
        let f = self.imp(inr, inb);
        self.anchor(r, f);
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
            let x = self.operand(cb, cm, state, pj.data, all);
            return self.index_key(x);
        }
        // A union's members are distinct members too: a write of one makes the others unknown, but for
        // the bytes they share with it (`union_coherence`).
        if pj.kind == ir::PJ_FIELD && (pj.data == ir::IR_NONE || pj.data == ir::PJ_UNION_FIELD) {
            let ix = self.field_index(cm, base, pj.sub);
            if ix >= 0 {
                return self.tm.int(wide::<B>(ix), 64, false);
            }
            return self.tm.int(wide::<B>(pj.sub) + Num::<B>::one().shl(40), 64, false);
        }
        return self.tm.int(wide::<B>(pj.data), 64, false);
    }

    // Index `x` as a member key: a 64-bit unsigned integer, as the constant indexes are (the check
    // compares it as `usize`): a constant at least 0 its value, another type a cast `c` with the fact
    // `c == x` where `x` is at least 0, anchored on `c`.
    fn index_key(self: &mut Self, x: u32) u32 {
        let t = self.tm.at(x);
        if t.w <= W_BOOL || t.w == 64 && !t.sg {
            return x;
        }
        if t.op == T_INT && !t.k.is_negative() {
            return self.tm.int(t.k, 64, false);
        }
        if exact_w(t.w) {
            return x;
        }
        let c = self.tm.unary(T_CAST, x, 64, false);
        if !self.seld.contains_key(&c) {
            self.seld.insert(c, true);
            let nn = self.nonneg(x);
            let neg = self.tm.not(nn);
            let eq = self.tm.cmp(T_EQ, c, x);
            let f = self.tm.or(neg, eq);
            self.anchor(c, f);
        }
        return c;
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
    // A reference to place `p` of body `cb` (`&p`, `&mut p`, an implicit borrow): `T_MREF` of its local,
    // or of the local or slot that the `&mut` its first dereference reads refers to; with members after
    // that, a `T_PREF` (its keys read now; a union's member is its bytes, `union_coherence`). NONE where
    // it reaches memory otherwise: through another reference or a raw pointer, or into a variant.
    fn place_ref(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, p: &ir::Place) u32 {
        return self.place_ref_in(cb, cm, state, p, false);
    }

    // `place_ref`; in a callee's or a clause's `frame`, only through a parameter's reference (to a local
    // or slot of the body the frame is in, of the parameter's referent type).
    fn place_ref_in(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        p: &ir::Place,
        frame: bool,
    ) u32 {
        let deref0 = p.proj_len != 0 && cb.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF;
        if if frame {
            !deref0
        } else {
            !self.tracked[p.base as usize]
        } {
            return NONE;
        }
        let mut tg = p.base;
        let mut tgty = cb.locals.at(p.base as usize).ty;
        let mut from: u32 = 0;
        let mut inner = NONE;
        if deref0 {
            let r = self.local_val(cb, cm, state, p.base);
            let x = self.tm.at(r);
            let ly = *self.ast_of(cm).type_at(tgty);
            if x.op == T_MREF && frame && ly.kind == TypeKind::TYPE_REFERENCE {
                tg = x.a;
                tgty = ly.as_data.elem;
            } else if x.op == T_MREF && !frame {
                tg = x.a;
                tgty = self.target_ty(cb, x.a);
            } else if x.op == T_PREF {
                inner = x.a;
                tg = self.pref_tg[x.a as usize];
                tgty = self.pref_tgty[x.a as usize];
            } else {
                return NONE;
            }
            from = 1;
        }
        if self.has_deref(cb, p, from) {
            return NONE;
        }
        if from == p.proj_len {
            return if inner != NONE {
                self.tm.make(Term::<B> { k: Num::<B>::zero(), a: inner, b: 0, op: T_PREF, w: W_OTHER, sg: false })
            } else {
                self.tm.make(Term::<B> { k: Num::<B>::zero(), a: tg, b: 0, op: T_MREF, w: W_OTHER, sg: false })
            };
        }
        let start = self.pref_key.len() as u32;
        if inner != NONE {
            let (a0, n0) = (self.pref_at[inner as usize], self.pref_n[inner as usize]);
            for q in a0..a0 + n0 {
                self.pref_key.push(self.pref_key[q as usize]);
                self.pref_ty.push(self.pref_ty[q as usize]);
                self.pref_km.push(self.pref_km[q as usize]);
            }
        }
        for j in from..p.proj_len {
            let pj = *cb.projections.at((p.proj_start + j) as usize);
            if pj.kind == ir::PJ_DOWNCAST {
                self.pref_key.truncate(start as usize);
                self.pref_ty.truncate(start as usize);
                self.pref_km.truncate(start as usize);
                return NONE;
            }
            if self.ptr_index(cb, cm, p, j) == PI_MEM {
                self.pref_key.truncate(start as usize);
                self.pref_ty.truncate(start as usize);
                self.pref_km.truncate(start as usize);
                return NONE;
            }
            let bty = self.proj_base_ty(cb, p, j);
            let key = if self.ptr_index(cb, cm, p, j + 1) == PI_OWNED {
                self.own_key(cm, bty, &pj)
            } else {
                self.proj_key(cb, cm, state, &pj, bty, false)
            };
            self.pref_key.push(key);
            self.pref_ty.push(pj.ty);
            self.pref_km.push(cm);
        }
        return self.pref_new(start, tg, tgty, cm);
    }

    // The reference to the member of local or slot `tg` (type `tgty` of module `m`) whose keys `pref_key`
    // holds from `start` to its end: one term per member (the keys of an equal entry dropped).
    fn pref_new(self: &mut Self, start: u32, tg: u32, tgty: TypeId, m: ModuleId) u32 {
        let n = self.pref_key.len() as u32 - start;
        let mut h = (tg as u64 + 1).wrapping_mul(0x9E3779B97F4A7C15u64) ^ n as u64;
        for q in start..start + n {
            h = (h ^ self.pref_key[q as usize] as u64).wrapping_mul(0x100000001B3u64);
        }
        if let Some(e) = self.pref_by.get(&h) {
            let ei = (*e) as usize;
            let mut same = self.pref_tg[ei] == tg && self.pref_n[ei] == n;
            let a0 = self.pref_at[ei];
            for q in 0..n {
                same = same && self.pref_key[(a0 + q) as usize] == self.pref_key[(start + q) as usize];
            }
            if same {
                self.pref_key.truncate(start as usize);
                self.pref_ty.truncate(start as usize);
                self.pref_km.truncate(start as usize);
                return self.tm.make(
                    Term::<B> { k: Num::<B>::zero(), a: ei as u32, b: 0, op: T_PREF, w: W_OTHER, sg: false },
                );
            }
        }
        let idx = self.pref_tg.len() as u32;
        self.pref_tg.push(tg);
        self.pref_tgty.push(tgty);
        self.pref_m.push(m);
        self.pref_at.push(start);
        self.pref_n.push(n);
        if !self.pref_by.contains_key(&h) {
            self.pref_by.insert(h, idx);
        }
        return self.tm.make(Term::<B> { k: Num::<B>::zero(), a: idx, b: 0, op: T_PREF, w: W_OTHER, sg: false });
    }

    // The type of local or slot `l` of body `cb`.
    const fn target_ty(self: &Self, cb: &ir::CoreBody, l: u32) TypeId {
        return if l as usize >= cb.locals.len() {
            self.slot_ty[l as usize - cb.locals.len()]
        } else {
            cb.locals.at(l as usize).ty
        };
    }

    // The local or slot reference `r` (`T_MREF`, `T_PREF`) reaches.
    const fn ref_target(self: &Self, r: u32) u32 {
        let x = self.tm.at(r);
        if x.op == T_PREF {
            return self.pref_tg[x.a as usize];
        }
        return x.a;
    }

    // The type of the value reference `r` (`T_MREF`, `T_PREF`) refers to, and its module.
    const fn ref_ty(self: &Self, cb: &ir::CoreBody, r: u32) (ModuleId, TypeId) {
        let x = self.tm.at(r);
        if x.op == T_PREF {
            let e = x.a as usize;
            let q = (self.pref_at[e] + self.pref_n[e] - 1) as usize;
            return self.pref_km[q], self.pref_ty[q];
        }
        return cb.module, self.target_ty(cb, x.a);
    }

    // The value reference `r` (`T_MREF`, `T_PREF`) refers to in state `ms`; NONE when `ms` holds none for
    // its local.
    fn ref_get(self: &mut Self, ms: &Vector<u32>, r: u32) u32 {
        let x = self.tm.at(r);
        let tg = self.ref_target(r);
        if tg as usize >= ms.len() || ms[tg as usize] == NONE {
            return NONE;
        }
        let mut v = ms[tg as usize];
        if x.op == T_PREF {
            let e = x.a as usize;
            let a0 = self.pref_at[e];
            let mut in_union = false;
            for q in a0..a0 + self.pref_n[e] {
                let (m, ty) = (self.pref_km[q as usize], self.pref_ty[q as usize]);
                let (w, sg) = self.ty_of(m, ty);
                let (cm, cty) = self.pref_cty(e, q - a0);
                self.union_coherence(cm, cty, v);
                v = self.sel(v, self.pref_key[q as usize], w, sg);
                in_union = in_union || self.is_union_ty(cm, cty);
                if w == W_OTHER && !in_union {
                    v = self.eta(m, ty, v, 0);
                }
            }
        }
        return v;
    }

    // The type of the value step `q` of reference entry `e`'s member path selects from, and its module.
    // Whether reference `v` is a `T_PREF` to a field of a struct: each type on its path a struct's.
    fn pref_fields(self: &Self, v: u32) bool {
        let x = self.tm.at(v);
        if x.op != T_PREF {
            return false;
        }
        let e = x.a as usize;
        let n = self.pref_n[e];
        if n == 0 {
            return false;
        }
        for q in 0..n {
            let (cm, cty) = self.pref_cty(e, q);
            let (m1, t1) = self.resolve(cm, cty);
            let k = self.ast_of(m1).type_at(t1).kind;
            if k != TypeKind::TYPE_STRUCT && k != TypeKind::TYPE_INSTANCE {
                return false;
            }
        }
        return true;
    }

    const fn pref_cty(self: &Self, e: usize, q: u32) (ModuleId, TypeId) {
        if q == 0 {
            return self.pref_m[e], self.pref_tgty[e];
        }
        let k = (self.pref_at[e] + q - 1) as usize;
        return self.pref_km[k], self.pref_ty[k];
    }

    // Reference `r` (`T_MREF`, `T_PREF`) of body `cb` now refers to value `nv`: its local or slot changes
    // in that member only. A local a load may read (`is_mem`, and a pointer or reference of the path reaches
    // it) makes a new epoch, as `write_place` does: no other load reads a `&mut` parameter's referent.
    fn ref_set(self: &mut Self, cb: &ir::CoreBody, state: &mut Vector<u32>, r: u32, nv: u32) {
        let x = self.tm.at(r);
        let tg = self.ref_target(r);
        if x.op == T_PREF {
            let e = x.a as usize;
            let (a0, n) = (self.pref_at[e], self.pref_n[e]);
            if state[tg as usize] == NONE {
                let f = self.fresh(self.pref_m[e], self.pref_tgty[e]);
                state.set(tg as usize, f);
            }
            let mut vals = Vector::<u32>::with_capacity(n as usize + 1);
            vals.push(state[tg as usize]);
            for q in 0..n {
                let (w, sg) = self.ty_of(self.pref_km[(a0 + q) as usize], self.pref_ty[(a0 + q) as usize]);
                let prev = vals[q as usize];
                let (cm, cty) = self.pref_cty(e, q);
                self.union_coherence(cm, cty, prev);
                vals.push(self.sel(prev, self.pref_key[(a0 + q) as usize], w, sg));
            }
            // A union's member: the other members are what its bytes make of them (`update`), but for a
            // write of a block (an `@owned` field's key below), which changes no byte.
            let mut cur = nv;
            let mut blk = false;
            for q0 in 0..n {
                let q = n - 1 - q0;
                let (cm, cty) = self.pref_cty(e, q);
                let kx = self.tm.at(self.pref_key[(a0 + q) as usize]);
                blk = blk || kx.op == T_INT && kx.k.shr(41) == Num::<B>::one();
                if self.is_union_ty(cm, cty) && !blk {
                    let fr = self.tm.var(W_OTHER, false);
                    cur = self.tm.upd(fr, self.pref_key[(a0 + q) as usize], cur);
                    self.union_coherence(cm, cty, cur);
                } else {
                    cur = self.tm.upd(vals[q as usize], self.pref_key[(a0 + q) as usize], cur);
                }
            }
            state.set(tg as usize, cur);
        } else {
            state.set(tg as usize, nv);
        }
        if tg as usize < self.is_mem.len() && self.is_mem[tg as usize] && self.reached(tg) {
            let k = state.len() - 1;
            let ep0 = state[k];
            state.set(k, self.tm.var(W_OTHER, false));
            self.keep_param_views(cb, cb.module, state, ep0, 0);
        }
    }

    fn deref(self: &mut Self, state: &Vector<u32>, r: u32, cm: ModuleId, ty: TypeId) u32 {
        let x = self.tm.at(r);
        if x.op == T_REF {
            return x.a;
        }
        // A reference to an element of a container: the element of its view.
        let sk = self.sq_of(r);
        if sk == SQ_EREF || sk == SQ_SEREF {
            let (w, sg) = self.ty_of(cm, ty);
            let a0 = self.tm.args[x.a as usize];
            let i = self.tm.args[(x.a + 1) as usize];
            let view = if sk == SQ_EREF {
                let ms = if self.mem != null {
                    unsafe &*self.mem
                } else {
                    state
                };
                let cv = self.ref_get(ms, a0);
                if cv == NONE {
                    return self.tm.var(w, sg);
                }
                self.view_v(cv)
            } else {
                self.view_s(a0, state[state.len() - 1])
            };
            return self.seq_at(view, i, w, sg);
        }
        if x.op == T_MREF || x.op == T_PREF {
            let ms = if self.mem != null {
                unsafe &*self.mem
            } else {
                state
            };
            let v = self.ref_get(ms, r);
            if v != NONE {
                return v;
            }
        }
        let (w, sg) = self.ty_of(cm, ty);
        let ep = state[state.len() - 1];
        let now = self.tm.make(Term::<B> { k: Num::<B>::zero(), a: r, b: ep, op: T_LOAD, w: w, sg: sg });
        // A struct a write through this pointer gave its value in this epoch (`mi_forward`).
        if let Some(fv) = self.mi_fwd.get(&now) {
            return *fv;
        }
        // A shared reference the body was passed: no write changes its referent while the call runs (a
        // write needs `&mut` or an `UnsafeCell`), but in the members that may hold a cell, read now.
        if !self.sref.contains(&r) {
            return now;
        }
        let f = self.tm.boolean(false);
        let fixed = self.tm.make(Term::<B> { k: Num::<B>::zero(), a: r, b: f, op: T_LOAD, w: w, sg: sg });
        return self.cell_members(cm, ty, fixed, now);
    }

    // Value `fixed` of type `ty` (module `m`) with each member that may hold an `UnsafeCell` (`no_cell`)
    // taken from `now`: `now` when the type itself may.
    fn cell_members(self: &mut Self, m: ModuleId, ty: TypeId, fixed: u32, now: u32) u32 {
        if self.cell_free_of(m, ty, NODE_NONE) {
            return fixed;
        }
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        let (dm, dn) = self.decl_of(rm, rt);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE || dn == NODE_NONE || !self.pkg().modules.at(
            dm as usize,
        ).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT || dm == self.wcore.mid && dn == self.wcore.node {
            return now;
        }
        let ag = unsafe self.ast_of(dm).ext(dn).aggregate;
        if ag.is_union {
            return now;
        }
        let mut out = fixed;
        for j in 0..ag.members.len {
            let mt = self.ast_of(dm).member_ty(unsafe self.ast_of(dm).list(ag.members)[j as usize]);
            let my = *self.ast_of(dm).type_at(mt);
            // A member of a type parameter: the instance's argument.
            let (am, at) = if my.kind == TypeKind::TYPE_GENERIC && y.kind == TypeKind::TYPE_INSTANCE {
                let it = *self.ast_of(rm).instance(y.as_data.inst);
                let mut a = TYPE_NONE;
                for i in 0..ag.generics.len {
                    if unsafe self.ast_of(dm).list(ag.generics)[i as usize] == my.as_data.decl && i as u8 < it.n {
                        a = it.args[i as usize];
                    }
                }
                (rm, a)
            } else {
                (dm, mt)
            };
            // A pointer's value is the member's; what it points to is not part of it.
            let ay = if at == TYPE_NONE {
                TypeKind::TYPE_GENERIC
            } else {
                self.ast_of(am).type_at(at).kind
            };
            if ay == TypeKind::TYPE_POINTER || ay == TypeKind::TYPE_REFERENCE || at != TYPE_NONE && my.kind != TypeKind::TYPE_GENERIC && self.cell_free_of(
                dm,
                mt,
                dn,
            ) || at != TYPE_NONE && my.kind == TypeKind::TYPE_GENERIC && self.cell_free_of(am, at, NODE_NONE) {
                continue;
            }
            let key = self.tm.int(wide::<B>(j), 64, false);
            let (ew, esg) = self.ty_of(am, at);
            let e = self.tm.sel(now, key, ew, esg);
            out = self.tm.upd(out, key, e);
        }
        return out;
    }

    // A memory event (a call, a drop, a write through a pointer): every local a reference or pointer
    // made on the path may reach holds an unknown value, and loads read a new epoch.
    fn mem_event(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>) {
        self.mem_event_of(cb, cm, state, true);
    }

    // `mem_event`; with `keep`, a vector lent as a view (`views`) not in `vx` keeps its value.
    fn mem_event_keep(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        keep: bool,
        vx: &Vector<u32>,
    ) {
        let n = state.len() - 1;
        state.set(n, self.tm.var(W_OTHER, false));
        let ep = state[n];
        for j in 0..self.esc.len() {
            let l = self.esc[j];
            let mut q0 = NONE;
            for q in 0..self.views.len() {
                if (self.views[q] >> 32) as u32 == l {
                    q0 = q as u32;
                    break;
                }
            }
            if keep && q0 != NONE && !vx.contains(&(self.views[q0 as usize] as u32)) {
                continue;
            }
            if q0 != NONE {
                self.relink(cb, cm, state, l, self.views[q0 as usize] as u32, ep);
            } else {
                self.forget(cb, cm, state, l);
            }
        }
    }

    // Vector local `l`, lent as `[]mut` view `xs`, after a memory event of epoch `ep` (`link_view`). In
    // the vector's own module its fields stay, its block's elements are unknown (`own_forget`), and its
    // view (`vec_fields`) is the view's in epoch `ep`.
    fn relink(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, l: u32, xs: u32, ep: u32) {
        let ty = if l as usize < cb.locals.len() {
            cb.locals.at(l as usize).ty
        } else {
            self.slot_ty[l as usize - cb.locals.len()]
        };
        let (dm, dd) = self.decl_of(cm, ty);
        if self.m != self.vecl.mid || state[l as usize] == NONE || dd == NODE_NONE || dm != self.vecl.mid || dd != self.vecl.node || !self.vec_inv() {
            self.forget(cb, cm, state, l);
            self.link_view(state, l, xs, ep);
            return;
        }
        let nv = self.own_forget(cm, ty, state[l as usize], 0);
        state.set(l as usize, nv);
        self.vec_fields(nv);
        if let Some(fv) = self.vdef.get(&nv) {
            let f = *fv;
            let sv = self.view_s(xs, ep);
            let e = self.tm.cmp(T_EQ, f, sv);
            self.anchor(f, e);
        }
    }

    // Vector local `l`, lent as view `xs`: its length the view's, and its elements the view's in epoch `ep`
    // (a view writes elements only).
    fn link_view(self: &mut Self, state: &Vector<u32>, l: u32, xs: u32, ep: u32) {
        let v = state[l as usize];
        let sv = self.view_s(xs, ep);
        self.vdef.insert(v, sv);
        let n = self.seq_len(sv);
        let k = self.sq1(SQ_SLEN, xs, self.pw, false);
        let f = self.tm.cmp(T_EQ, n, k);
        self.anchor(n, f);
    }

    // `mem_event`; the locals a reference reaches change only with `locals` (a call given no reference
    // reaches none).
    fn mem_event_of(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, locals: bool) {
        // A block no field holds yet (`pend`) may be any bytes after it.
        self.pend.clear();
        // The inline arrays a pointer reaches (`aesc`): unknown elements, the rest of their local kept.
        if locals {
            for j in 0..self.aesc.len() {
                let r = self.aesc[j];
                if !self.esc.contains(&self.ref_target(r)) {
                    let (am, aty) = self.ref_ty(cb, r);
                    let f = self.fresh_in(am, aty, self.pref_union(r));
                    self.ref_set(cb, state, r, f);
                }
            }
        }
        let n = state.len() - 1;
        state.set(n, self.tm.var(W_OTHER, false));
        let ep = state[n];
        // The blocks of `@owned` fields are memory: a copy of the field may reach them (`own_exp`). An
        // allocator's call writes none it does not move (`realloc`: `own_after`).
        for l in 0..n {
            if state[l] != NONE && !self.keep_own && l < self.own_exp.len() && self.own_exp[l] {
                let ty = if l < cb.locals.len() {
                    cb.locals.at(l).ty
                } else {
                    self.slot_ty[l - cb.locals.len()]
                };
                let nv = self.own_forget(cm, ty, state[l], 0);
                state.set(l, nv);
            }
        }
        if !locals {
            return;
        }
        for j in 0..self.esc.len() {
            let l = self.esc[j];
            // A vector lent only as `[]mut` views keeps their length, and its elements are theirs in the
            // new epoch (`relink`).
            let mut q0 = NONE;
            for q in 0..self.views.len() {
                if (self.views[q] >> 32) as u32 == l {
                    q0 = q as u32;
                    break;
                }
            }
            if q0 != NONE {
                self.relink(cb, cm, state, l, self.views[q0 as usize] as u32, ep);
            } else {
                self.forget(cb, cm, state, l);
            }
        }
    }

    // Local `l` may be reached through a reference or pointer from here on: through what it was lent as,
    // which may change its length (`views` keeps none of it).
    fn escape(self: &mut Self, l: u32) {
        self.escape_as(l, NONE);
    }

    // `escape`, through `[]mut` view `xs` of vector `l` when `xs` is not NONE (`views`).
    // Local `l` no longer escaped, with no view lent.
    const fn unescape(self: &mut Self, l: u32) {
        let mut q: usize = 0;
        while q < self.aesc.len() {
            if self.ref_target(self.aesc[q]) == l {
                let _ = self.aesc.swap_remove(q);
            } else {
                q += 1;
            }
        }
        q = 0;
        while q < self.views.len() {
            if (self.views[q] >> 32) as u32 == l {
                let _ = self.views.swap_remove(q);
            } else {
                q += 1;
            }
        }
        q = 0;
        while q < self.esc.len() {
            if self.esc[q] == l {
                let _ = self.esc.swap_remove(q);
            } else {
                q += 1;
            }
        }
    }

    // Whether a reference or pointer made on the path may reach local `l`'s storage (`esc`, `aesc`): a
    // load may read it.
    const fn reached(self: &Self, l: u32) bool {
        if self.esc.contains(&l) {
            return true;
        }
        for j in 0..self.aesc.len() {
            if self.ref_target(self.aesc[j]) == l {
                return true;
            }
        }
        return false;
    }

    fn escape_as(self: &mut Self, l: u32, xs: u32) {
        if xs == NONE {
            let mut q: usize = 0;
            while q < self.views.len() {
                if (self.views[q] >> 32) as u32 == l {
                    let _ = self.views.swap_remove(q);
                } else {
                    q += 1;
                }
            }
        } else {
            // A new view ends the borrow of the one before: the vector's elements are the new view's.
            let mut had = false;
            for q in 0..self.views.len() {
                if (self.views[q] >> 32) as u32 == l {
                    self.views.set(q, l as u64 << 32 | xs as u64);
                    had = true;
                    break;
                }
            }
            if !had && !self.esc.contains(&l) {
                self.views.push(l as u64 << 32 | xs as u64);
            }
        }
        if l as usize < self.slot_of.len() && self.slot_of[l as usize] != NONE {
            self.escape(self.slot_of[l as usize]);
        }
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
    // Float constant `c` of width `fw`: its encoding as the build makes it (`lir::lower`'s `constant`): a
    // literal rounded once from its text, a folded call's bits, an integer literal through `f64`.
    fn float_const(self: &mut Self, cb: &ir::CoreBody, c: &ir::Constant, fw: u16) u32 {
        let sm = pick(c.item.node != NODE_NONE, c.item.module, cb.module);
        let src = self.pkg().modules.at(sm as usize).source.as_str();
        let mut v: i64 = c.val;
        let f = if c.kind == ir::CK_FLOAT {
            float_literal_value(src, c.raw, fw == 32)
        } else if c.kind == ir::CK_INT && c.int_value(src, &mut v) {
            Some(v as f64)
        } else {
            Option::<f64>::None
        };
        let bits: u64 = if c.kind == ir::CK_FBITS {
            pick(fw == 32, c.val as u64 & 0xFFFFFFFF, c.val as u64)
        } else if let Some(x) = f {
            pick(fw == 32, (x as f32).to_bits(), x.to_bits())
        } else {
            return self.tm.var(fw, false);
        };
        return self.tm.int(u64_val::<B>(bits), fw, false);
    }

    fn constant(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, cid: u32, ty: TypeId) u32 {
        let c = *cb.constants.at(cid as usize);
        if c.kind == ir::CK_ITEM {
            let r = self.fn_item(cb, cm, &c);
            if r != NONE {
                return r;
            }
        }
        let (w, sg) = self.ty_of(cm, ty);
        if c.kind == ir::CK_BOOL {
            return self.tm.boolean(c.val != 0);
        }
        let fw = self.float_w(cm, ty);
        if fw != 0 {
            return self.float_const(cb, &c, fw);
        }
        // A null pointer: one value (`null_ptr`).
        if c.kind == ir::CK_INT && c.val == 0 && self.null_const(cb, cm, &c, ty) {
            return self.null_ptr();
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
                    u64_val::<B>(v as u64)
                } else {
                    wide::<B>(v)
                };
                return self.tm.int(k, w, sg);
            }
        }
        // A string literal without escapes: a function of its bytes, whose view is those bytes.
        if c.kind == ir::CK_STR && c.raw.end > c.raw.start && c.raw.end - c.raw.start <= 64 {
            let sm = if c.item.node != NODE_NONE {
                c.item.module
            } else {
                cb.module
            };
            let src = self.pkg().modules.at(sm as usize).source.as_str();
            if c.raw.end as usize <= src.len() {
                let text = src.slice(c.raw.start as usize, c.raw.end as usize);
                let mut plain = true;
                for j in 0..text.len() {
                    plain = plain && text.byte_at(j) != 92;
                }
                if plain {
                    let mut seq = self.seq_make1(SQ_EMPTY, NONE);
                    for j in 0..text.len() {
                        let mut xs = Vector::<u32>::new();
                        xs.push(seq);
                        xs.push(self.tm.int(wide::<B>(text.byte_at(j)), 8, false));
                        seq = self.seq_make(SQ_PUSH, &xs);
                    }
                    let v = self.sq1(SQ_STRV, seq, W_OTHER, false);
                    self.vdef.insert(v, seq);
                    return v;
                }
            }
        }
        // A literal wider than 64 bits of a wide integer: its stored limbs, two's complement in `w` bits.
        if c.kind == ir::CK_WIDE && w > 64 && !exact_w(w) {
            let sm = if c.item.node != NODE_NONE {
                c.item.module
            } else {
                cb.module
            };
            let lits = &self.ast_of(sm).wide_lits;
            if c.val >= 0 && c.val as usize < lits.len() {
                let wl = *lits.at(c.val as usize);
                let mut k = Num::<B>::zero();
                for j in 0..(w as usize + 63) / 64 {
                    k.set_limb(j, wl.limbs[j]);
                }
                k = Terms::<B>::wrap(k, w, sg);
                return self.tm.int(k, w, sg);
            }
        }
        // An `int` or `nat` literal past 64 bits: its limbs, two's complement in 1024 bits, when the value
        // fits the prover's numbers (every limb past them repeats the sign); else an unknown value, and
        // the proof runs again with wider numbers.
        if c.kind == ir::CK_WIDE && exact_w(w) {
            let sm = if c.item.node != NODE_NONE {
                c.item.module
            } else {
                cb.module
            };
            let lits = &self.ast_of(sm).wide_lits;
            if c.val >= 0 && c.val as usize < lits.len() {
                let wl = *lits.at(c.val as usize);
                let n = B / 64;
                let fill = if wl.limbs[n - 1] >> 63 != 0 {
                    ~0u64
                } else {
                    0u64
                };
                let mut fits = true;
                for j in n..16 {
                    fits = fits && wl.limbs[j] == fill;
                }
                if fits {
                    let mut k = Num::<B>::zero();
                    for j in 0..n {
                        k.set_limb(j, wl.limbs[j]);
                    }
                    return self.tm.int(k, w, sg);
                }
                self.sv.note_overflow();
            }
        }
        return self.tm.var(w, sg);
    }

    // Write `v` (NONE: an unknown value) to place `pl`: a member path updates its local's value; a
    // write through a mutable reference to a local updates that local, any other one through a
    // reference or pointer is a memory event (`write_at`).
    fn write_place(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pl: u32,
        v: u32,
        all: bool,
    ) {
        self.mi_next.clear();
        // A write reaches no static of this file but its own (`static_write`, forwarded after).
        let sv = self.st_save(state, all);
        if self.write_at(cb, cm, state, pl, v, all) {
            self.mem_event(cb, cm, state);
            self.st_carry(cm, state, &sv);
            if self.mi_next.len() == 4 {
                self.mi_forward(state);
            }
        } else {
            self.st_carry(cm, state, &sv);
        }
    }

    // The values of the statics of this file the walk read (`st_list`) in memory `state`, none in a frame
    // (`all`).
    fn st_save(self: &mut Self, state: &Vector<u32>, all: bool) Vector<u32> {
        let mut sv = Vector::<u32>::new();
        if all {
            return sv;
        }
        for q in 0..self.st_list.len() / 2 {
            sv.push(self.deref(state, self.st_list[2 * q], self.m, self.st_list[2 * q + 1]));
        }
        return sv;
    }

    // The statics `sv` saved (`st_save`) keep those values in the epoch of `state`: an event that writes
    // none of them.
    fn st_carry(self: &mut Self, cm: ModuleId, state: &Vector<u32>, sv: &Vector<u32>) {
        let ep = state[state.len() - 1];
        for q in 0..sv.len() {
            let (w, sg) = self.ty_of(cm, self.st_list[2 * q + 1]);
            let now = self.tm.make(
                Term::<B> { k: Num::<B>::zero(), a: self.st_list[2 * q], b: ep, op: T_LOAD, w: w, sg: sg },
            );
            if now != sv[q] {
                self.mi_fwd.insert(now, sv[q]);
            }
        }
    }

    // A new ownership version of kind `k` after `prev`.
    fn ov_new(self: &mut Self, k: u8, prev: u32) u32 {
        self.ov_kind.push(k);
        self.ov_prev.push(prev);
        self.ov_pst.push(self.ov_ps.len() as u32);
        self.ov_psn.push(pick(k == OV_ADD, NONE, 0u32));
        return (self.ov_kind.len() - 1) as u32;
    }

    // Version `v`'s pointers: those `ps` names.
    fn ov_fin(self: &mut Self, v: u32, ps: &Vector<u32>) {
        self.ov_pst.set(v as usize, self.ov_ps.len() as u32);
        for j in 0..ps.len() {
            self.ov_ps.push(ps[j]);
        }
        self.ov_psn.set(v as usize, ps.len() as u32);
    }

    // `held(K, p, n, a)` in the walk's ownership version: implementor key `k` holds block `p` of `n` bytes
    // at alignment `a` for the walked body. Its version's definition is anchored on it (`held_def`).
    fn held_atom(self: &mut Self, k: u64, p: u32, n: u32, a: u32) u32 {
        let v = self.ov;
        let vt = self.tm.int(wide::<B>(v), 32, false);
        let mut xs = Vector::<u32>::with_capacity(4);
        xs.push(p);
        xs.push(n);
        xs.push(a);
        xs.push(vt);
        // An allocator's own methods define its ownership: there its blocks are held.
        if k == self.own_alloc {
            return self.tm.boolean(true);
        }
        let h = self.tm.call(skey_mix(HELD_KEY, k), &xs, W_BOOL, false);
        if !self.held_p.contains_key(&h) {
            self.held_p.insert(h, p as u64 << 32 | v as u64);
            self.held_k.insert(h, k);
            let mut l = switch self.held_by_ptr.get(&p) {
                Some(x) => x.clone(),
                None => Vector::<u32>::new(),
            };
            l.push(h);
            self.held_by_ptr.insert(p, l);
        }
        if v == self.ov_col && self.ov_kind[v as usize] == OV_ADD && self.ov_psn[v as usize] == NONE {
            self.ov_seen.push(p);
        }
        self.held_def(h, k, p, n, a, v);
        return h;
    }

    // The value of function item constant `c` of body `cb` (module `cm`): one term per item and type
    // arguments, whose `requires` `pre_of` reads (`fn_items`); NONE for another item, or one whose type
    // arguments it cannot bind.
    fn fn_item(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, c: &ir::Constant) u32 {
        let d = c.item;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return NONE;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION || a.ext(d.node).function.is_ghost() {
            return NONE;
        }
        let ct = a.container_of(d.node);
        let eg = if ct != NODE_NONE && a.at_const(ct).kind == NodeKind::NODE_EXTEND {
            a.ext(ct).extend_def.generics
        } else {
            NodeList { start: 0, len: 0 }
        };
        let fg = a.ext(d.node).function.generics;
        let (start, len) = ((c.val & 0xFFFFFFFF) as u32, (c.val >> 32) as u32);
        if len != eg.len + fg.len {
            return NONE;
        }
        let mut binds = Vector::<u64>::new();
        let mut key = skey_mix(21, d.module as u64 << 32 | d.node as u64);
        for j in 0..len {
            let t0 = cb.targ_pool[(start + j) as usize];
            let (m2, t2) = self.resolve(cm, t0);
            if self.subst.len() != 0 && !self.bound_generic(cm, t0) && self.mentions_generic(m2, t2, 0) {
                return NONE;
            }
            let pn = if j < eg.len {
                unsafe a.list(eg)[j as usize]
            } else {
                unsafe a.list(fg)[(j - eg.len) as usize]
            };
            binds.push(d.module as u64 << 32 | pn as u64);
            binds.push(m2 as u64 << 32 | t2 as u64);
            key = skey_mix(key, self.type_key(m2, t2, 0));
        }
        let none = Vector::<u32>::new();
        let r = self.tm.call(key, &none, W_OTHER, false);
        if !self.fn_items.contains_key(&r) {
            self.fn_items.insert(r, self.fn_defs.len() as u32);
            self.fn_defs.push(d);
            self.fn_binds.push(binds);
        }
        return r;
    }

    // Whether `d` is the prelude's `pre_of` (`want` 0) or `pre_any` (1).
    const fn is_pre(self: &Self, d: DefId, want: u32) bool {
        let w = if want == 0 {
            self.wpre
        } else {
            self.wpre_any
        };
        return w.node != NODE_NONE && d.module == w.mid && d.node == w.node;
    }

    // `pre_of(f, x)`: the `requires` of function item `f` (`fn_item`) of argument `x`, in memory `state`;
    // true for one without them; NONE for a function value the walk does not know.
    fn pre_value(self: &mut Self, f: u32, x: u32, state: &Vector<u32>) u32 {
        let i = switch self.fn_items.get(&f) {
            Some(k) => (*k) as usize,
            None => {
                return NONE;
            },
        };
        let d = self.fn_defs[i];
        let c = self.contract_of(d);
        let cbp = self.contract_body(c);
        if cbp == null {
            return pick(self.has_clause(c, CT_REQUIRES), NONE, self.tm.boolean(true));
        }
        let cb = unsafe &*cbp;
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, cb.locals.len() + 1);
        frame.set(cb.locals.len(), state[state.len() - 1]);
        if cb.args >= 1 {
            frame.set(cb.returns as usize, x);
        }
        let outer = replace(&mut self.subst, self.fn_binds[i].clone());
        let none = Vector::<u32>::new();
        let sp = tok::Span { start: 0, end: 0 };
        let mut g = self.tm.boolean(true);
        for j in 0..cb.contracts.len() {
            let s = cb.contracts[j];
            if s.kind == CT_REQUIRES {
                let (r, _v) = self.chain(cb, c.module, s, &frame, &none, true, sp);
                g = self.tm.and(g, r);
            }
        }
        self.subst = outer;
        return g;
    }

    // Whether `d` is the prelude's `rc_share` (`want` 0) or `rc_units` (1).
    const fn is_shares(self: &Self, d: DefId, want: u32) bool {
        let w = if want == 0 {
            self.wshare
        } else {
            self.wunits
        };
        return w.node != NODE_NONE && d.module == w.mid && d.node == w.node;
    }

    // The constant `x` (an integer literal term) as an `int`, NONE for another term.
    fn int_const(self: &mut Self, x: u32) u32 {
        if !self.tm.is_int(x) {
            return NONE;
        }
        let k = self.tm.at(x).k;
        return self.tm.int(k, W_INT, true);
    }

    // ---- counters (`@counter`) ----------------------------------------------------------------------

    // Whether struct type `ty` of module `m` has counter fields (`counters_of`), cached per type.
    fn counted(self: &mut Self, m: ModuleId, ty: TypeId) bool {
        let k = m as u64 << 32 | ty as u64;
        if let Some(x) = self.ctr_ty.get(&k) {
            return *x;
        }
        let mut fs = Vector::<u32>::new();
        self.counters_of(m, ty, &mut fs);
        self.ctr_ty.insert(k, fs.len() != 0);
        return fs.len() != 0;
    }

    // The member indexes of the counter fields of struct type `ty` (module `m`), in order: counter k is
    // `out[k]`.
    fn counters_of(self: &Self, m: ModuleId, ty: TypeId, out: &mut Vector<u32>) {
        let (dm, dn) = self.decl_of(m, ty);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return;
        }
        let a = self.ast_of(dm);
        let ag = unsafe a.ext(dn).aggregate;
        for j in 0..ag.members.len {
            if a.attr_of(unsafe a.list(ag.members)[j as usize], AttrKind::ATTR_COUNTER) != null {
                out.push(j);
            }
        }
    }

    // The counter of member `fi` of struct type `ty` (module `m`): its index among the counter fields,
    // its guard's spec function, and whether it locks (`@counter_lock`); NONE as the index for another
    // member.
    fn counter_field(self: &Self, m: ModuleId, ty: TypeId, fi: u32) (u32, DefId, bool) {
        let none = DefId { module: 0, node: NODE_NONE };
        let mut fs = Vector::<u32>::new();
        self.counters_of(m, ty, &mut fs);
        for k in 0..fs.len() {
            if fs[k] != fi {
                continue;
            }
            let (dm, dn) = self.decl_of(m, ty);
            let a = self.ast_of(dm);
            let f = unsafe a.list(a.ext(dn).aggregate.members)[fi as usize];
            let at = a.attr_of(f, AttrKind::ATTR_COUNTER);
            let name = self.text(dm, unsafe (*at).str_span);
            let gn = self.pkg().lookup_own(dm, name, false);
            let lock = a.attr_of(f, AttrKind::ATTR_COUNTER_LOCK) != null;
            return k as u32, DefId { module: dm, node: gn }, lock;
        }
        return NONE, none, false;
    }

    // The member index of the counter field place `pl` names (`... (*q).f`, `q` a raw pointer to a
    // struct with `@counter` fields): (struct type, member index); TYPE_NONE for another place. With
    // `whole`, the place of the whole struct (`*q`): its member index NONE.
    fn counter_place(self: &Self, cb: &ir::CoreBody, cm: ModuleId, pl: &ir::Place, whole: bool) (TypeId, u32) {
        let n = pl.proj_len;
        let d = pick(whole, 1u32, 2u32);
        if n < d {
            return TYPE_NONE, NONE;
        }
        let dj = *cb.projections.at((pl.proj_start + n - d) as usize);
        if dj.kind != ir::PJ_DEREF {
            return TYPE_NONE, NONE;
        }
        let pty = if n - d == 0 {
            cb.locals.at(pl.base as usize).ty
        } else {
            cb.projections.at((pl.proj_start + n - d - 1) as usize).ty
        };
        if pty == TYPE_NONE || self.ast_of(cm).type_at(pty).kind != TypeKind::TYPE_POINTER {
            return TYPE_NONE, NONE;
        }
        let sty = dj.ty;
        let mut fs = Vector::<u32>::new();
        self.counters_of(cm, sty, &mut fs);
        if fs.len() == 0 {
            return TYPE_NONE, NONE;
        }
        if whole {
            return sty, NONE;
        }
        let fj = *cb.projections.at((pl.proj_start + n - 1) as usize);
        if fj.kind != ir::PJ_FIELD {
            return TYPE_NONE, NONE;
        }
        let fi = if fj.sub != NODE_NONE {
            self.field_index(cm, sty, fj.sub)
        } else {
            fj.data as i64
        };
        if fi < 0 || !fs.contains(&(fi as u32)) {
            return TYPE_NONE, NONE;
        }
        return sty, fi as u32;
    }

    // The members of struct type `ty` the guards of its counters read through the block's pointer: they
    // keep their values while a counter lives, so a write of one goes only with the struct's start (a
    // write of the whole struct, `count_start`).
    fn guard_fields(self: &Self, m: ModuleId, ty: TypeId, out: &mut Vector<u32>) {
        let mut fs = Vector::<u32>::new();
        self.counters_of(m, ty, &mut fs);
        for k in 0..fs.len() {
            let (_k, gd, _l) = self.counter_field(m, ty, fs[k]);
            if gd.node == NODE_NONE {
                continue;
            }
            let gp = self.kept(gd);
            if gp == null {
                continue;
            }
            let gb = unsafe &*gp;
            if gb.args == 0 {
                continue;
            }
            for pi in 0..gb.places.len() {
                let pl = *gb.places.at(pi);
                if pl.base != gb.returns || pl.proj_len < 2 || gb.projections.at(pl.proj_start as usize).kind != ir::PJ_DEREF {
                    continue;
                }
                let fj = *gb.projections.at((pl.proj_start + 1) as usize);
                if fj.kind != ir::PJ_FIELD {
                    continue;
                }
                let fi = if fj.sub != NODE_NONE {
                    self.field_index(gd.module, gb.projections.at(pl.proj_start as usize).ty, fj.sub)
                } else {
                    fj.data as i64
                };
                if fi >= 0 && !out.contains(&(fi as u32)) {
                    out.push(fi as u32);
                }
            }
        }
    }

    // Whether place `pl` (module `cm`) is a member a counter's guard reads (`guard_fields`) of a struct
    // through its block's pointer.
    fn guard_place(self: &Self, cb: &ir::CoreBody, cm: ModuleId, pl: &ir::Place) bool {
        let n = pl.proj_len;
        if n < 2 || cb.projections.at((pl.proj_start + n - 2) as usize).kind != ir::PJ_DEREF {
            return false;
        }
        let fj = *cb.projections.at((pl.proj_start + n - 1) as usize);
        if fj.kind != ir::PJ_FIELD {
            return false;
        }
        let sty = cb.projections.at((pl.proj_start + n - 2) as usize).ty;
        let mut gf = Vector::<u32>::new();
        self.guard_fields(cm, sty, &mut gf);
        if gf.len() == 0 {
            return false;
        }
        let fi = if fj.sub != NODE_NONE {
            self.field_index(cm, sty, fj.sub)
        } else {
            fj.data as i64
        };
        return fi >= 0 && gf.contains(&(fi as u32));
    }

    // The atomic operation callee `c` is (`atomic::add_usize`, ..): CS_ADD, CS_SUB, CS_CAS, CS_STORE, 9 for
    // a load, NONE as u8 for another callee.
    fn atomic_op(self: &Self, c: DefId) u8 {
        if c.node == NODE_NONE || (c.node & NODE_BODY) != 0 || self.pkg().modules.at(c.module as usize).path.as_str() != "atomic" {
            return 255;
        }
        let a = self.ast_of(c.module);
        if a.at_const(c.node).kind != NodeKind::NODE_FUNCTION {
            return 255;
        }
        let nm = self.text(c.module, a.at_const(a.ext_name(c.node)).span);
        return if nm.starts_with("add_") {
            CS_ADD
        } else if nm.starts_with("sub_") {
            CS_SUB
        } else if nm.starts_with("cas_") {
            CS_CAS
        } else if nm.starts_with("store_") {
            CS_STORE
        } else if nm.starts_with("load_") {
            9
        } else {
            255
        };
    }

    // The temporaries of body `b` that hold a counter field's address (`ctr_tmp`). Such an address goes
    // only to an atomic operation (the first argument of `atomic::add_usize`, ..), which steps the counter
    // there (`count_step`): any other use of it is an error.
    fn ctr_scan(self: &mut Self, b: &ir::CoreBody) {
        self.ctr_tmp.clear();
        self.m = b.module;
        let mut tsp = Map::<u32, u64>::new();
        if self.ghost_fn {
            return;
        }
        for sid in 0..b.statements.len() {
            let st = *b.statements.at(sid);
            if st.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            if rv.kind != ir::RV_ADDR && rv.kind != ir::RV_REF {
                continue;
            }
            if (rv.kind == ir::RV_ADDR || rv.b != 0) && self.guard_place(b, b.module, b.places.at(rv.a as usize)) {
                self.report(
                    OB_COUNTER << 56 | 5 << 40 | sid as u64,
                    dc::COUNTER_STEP,
                    st.span,
                    format("a member a counter's guard reads is written only where its struct starts"),
                    String::from_str("write the whole struct (`*p = S { .. }`) where the body holds the guard"),
                );
                continue;
            }
            let (sty, _fi) = self.counter_place(b, b.module, b.places.at(rv.a as usize), false);
            if sty == TYPE_NONE {
                continue;
            }
            let dp = *b.places.at(st.place as usize);
            if dp.proj_len != 0 {
                self.report(
                    OB_COUNTER << 56 | 1 << 40 | sid as u64,
                    dc::COUNTER_STEP,
                    st.span,
                    format("a counter field's address goes only to an atomic operation"),
                    String::from_str("an '@counter' field changes only at the steps the prover counts"),
                );
                continue;
            }
            self.ctr_tmp.insert(dp.base, rv.a);
            tsp.insert(dp.base, st.span.start as u64 << 32 | st.span.end as u64);
        }
        if self.ctr_tmp.len() == 0 {
            return;
        }
        // The operands an atomic operation's first argument is, and the copies and casts of such an
        // address into another temporary: the uses allowed.
        let mut ok = Map::<u32, bool>::new();
        for _r in 0..4 {
            let n0 = self.ctr_tmp.len();
            for sid in 0..b.statements.len() {
                let st = *b.statements.at(sid);
                if st.kind != ir::ST_ASSIGN || b.places.at(st.place as usize).proj_len != 0 {
                    continue;
                }
                let rv = *b.rvalues.at(st.rvalue as usize);
                if rv.kind != ir::RV_USE && rv.kind != ir::RV_CAST {
                    continue;
                }
                let op = *b.operands.at(rv.a as usize);
                if op.kind == ir::OP_CONST || b.places.at(op.data as usize).proj_len != 0 {
                    continue;
                }
                if let Some(cp) = self.ctr_tmp.get(&b.places.at(op.data as usize).base) {
                    let c = *cp;
                    let dl = b.places.at(st.place as usize).base;
                    ok.insert(rv.a, true);
                    if !self.ctr_tmp.contains_key(&dl) {
                        self.ctr_tmp.insert(dl, c);
                        tsp.insert(dl, st.span.start as u64 << 32 | st.span.end as u64);
                    }
                }
            }
            if self.ctr_tmp.len() == n0 {
                break;
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && t.args_len != 0 && self.atomic_op(t.callee) != 255 {
                ok.insert(b.oper_pool[t.args_start as usize], true);
            }
        }
        let mut bad = Vector::<u32>::new();
        for oi in 0..b.operands.len() {
            let op = *b.operands.at(oi);
            if op.kind == ir::OP_CONST {
                continue;
            }
            let pl = *b.places.at(op.data as usize);
            if self.ctr_tmp.contains_key(&pl.base) && (pl.proj_len != 0 || !ok.contains_key(&(oi as u32))) {
                bad.push(pl.base);
            }
        }
        for pi in 0..b.places.len() {
            let pl = *b.places.at(pi);
            if self.ctr_tmp.contains_key(&pl.base) && pl.proj_len != 0 {
                bad.push(pl.base);
            }
        }
        bad.sort();
        for j in 0..bad.len() {
            if j > 0 && bad[j] == bad[j - 1] {
                continue;
            }
            let l = &bad[j];
            let e = *tsp.get(l).unwrap();
            let sp = tok::Span { start: (e >> 32) as u32, end: e as u32 };
            self.report(
                OB_COUNTER << 56 | 2 << 40 | (*l) as u64,
                dc::COUNTER_STEP,
                sp,
                format("a counter field's address goes only to an atomic operation"),
                String::from_str("an '@counter' field changes only at the steps the prover counts"),
            );
        }
    }

    // The guard of counter field `gd` (`@counter`'s spec function) of block `p` of struct type `ty`: the
    // call `gd(p)` with the struct's type arguments as its own, defined; NONE where they are unknown.
    fn counter_guard(self: &mut Self, m: ModuleId, ty: TypeId, gd: DefId, p: u32, state: &Vector<u32>) u32 {
        if gd.node == NODE_NONE {
            return NONE;
        }
        let ga = self.ast_of(gd.module);
        if ga.at_const(gd.node).kind != NodeKind::NODE_FUNCTION {
            return NONE;
        }
        let fg = ga.ext(gd.node).function.generics;
        let mut binds = Vector::<u64>::new();
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(rm).instance(y.as_data.inst);
            if it.n as u32 != fg.len {
                return NONE;
            }
            for j in 0..fg.len {
                let (am, at) = self.resolve(rm, it.args[j as usize]);
                if self.subst.len() != 0 && !self.bound_generic(rm, it.args[j as usize]) && self.mentions_generic(
                    am,
                    at,
                    0,
                ) {
                    return NONE;
                }
                binds.push(gd.module as u64 << 32 | (unsafe self.ast_of(gd.module).list(fg)[j as usize]) as u64);
                binds.push(am as u64 << 32 | at as u64);
            }
        } else if fg.len != 0 {
            return NONE;
        }
        return self.inv_term(gd, binds, p, p, state);
    }

    // The units of counter `k` of block `p` that formula `g` (a guard) claims, in the walk's version.
    fn guard_units(self: &mut Self, g: u32, p: u32, k: u32) i64 {
        if g == NONE {
            return 0;
        }
        let mut sg = Vector::<u64>::new();
        let v = self.ov;
        self.sh_g(g, v, &mut sg);
        let mut n: i64 = 0;
        for j in 0..sg.len() {
            let h = (sg[j] >> 32) as u32;
            let pv = *self.sh_p.get(&h).unwrap();
            let kn = *self.sh_kn.get(&h).unwrap();
            let (kc, nc) = ((kn >> 32) as u32, kn as u32);
            if (pv >> 32) as u32 == p && self.tm.at(kc).k.to_i64() == k as i64 {
                n += self.tm.at(nc).k.to_i64();
            }
        }
        return n;
    }

    // `n` units of counter `k` of block `p` (`share_atom`), in the walk's version.
    fn unit_atom(self: &mut Self, p: u32, k: u32, n: i64) u32 {
        let kt = self.tm.int(wide::<B>(k), W_INT, true);
        let nt = self.tm.int(wide::<B>(n), W_INT, true);
        return self.share_atom(p, kt, nt);
    }

    // `c(x) >= r`, `x` a counter's value and `xi` it as an `int`: a lock's all-ones value `a1` counts 1.
    fn count_ge(self: &mut Self, x: u32, xi: u32, lock: bool, a1: u32, r: u32) u32 {
        let ge = self.tm.cmp(T_LE, r, xi);
        if !lock {
            return ge;
        }
        let one = self.tm.int(Num::<B>::one(), W_INT, true);
        let isl = self.tm.cmp(T_EQ, x, a1);
        let nl = self.tm.not(isl);
        let a = self.tm.or(isl, ge);
        let b = self.tm.or(nl, self.tm.cmp(T_LE, r, one));
        return self.tm.and(a, b);
    }

    // A step of counter field `fi` of struct type `ty` of block `p`: operation `op` with old value `o`
    // (NONE: unknown) and new value `n`, `d` an add's or a sub's operand, `g` a compare-and-swap's success
    // (else true), at `sp`. The count is the field's value (a lock's all-ones value counts 1); it counts
    // the units of the counter that exist, and a live counter holds its guard. The step takes and gives
    // units as a lemma call would (`call`): an increase by the holder of a unit of the block gives one,
    // a decrease takes one and gives the guard where the count reaches 0, a lock gives the lock's unit
    // (LOCK_UNIT) and the store that unlocks takes it, and a start (the guard held: the counter is not
    // live) takes the guard and gives the count's units. Another change is an error.
    fn count_step(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        ty: TypeId,
        fi: u32,
        p: u32,
        o: u32,
        n: u32,
        d: u32,
        g: u32,
        op: u8,
        sp: tok::Span,
        key: u64,
    ) {
        let (k, gd, lock) = self.counter_field(cm, ty, fi);
        if k == NONE || p == NONE || n == NONE {
            return;
        }
        let mut mts = Vector::<u64>::new();
        self.member_types(cm, ty, &mut mts);
        let (w, sg) = self.ty_of((mts[fi as usize] >> 32) as ModuleId, (mts[fi as usize] & 0xFFFFFFFFu64) as TypeId);
        let a1 = if sg {
            self.tm.int(wide::<B>(-1), w, sg)
        } else {
            let (_lo, hi) = Terms::<B>::range(w, sg);
            self.tm.int(hi, w, sg)
        };
        let one = self.tm.int(Num::<B>::one(), w, sg);
        let one_i = self.tm.int(Num::<B>::one(), W_INT, true);
        let zero_i = self.tm.int(Num::<B>::zero(), W_INT, true);
        let v = self.ov;
        let mut fs = Vector::<u32>::new();
        self.counters_of(cm, ty, &mut fs);
        let oi = if o == NONE {
            NONE
        } else {
            self.widened(o, W_INT, true)
        };
        let ni = self.widened(n, W_INT, true);
        // The count before the step: at least the units the body holds or a shared parameter lends it
        // (`lent_claims`, in this version), and those the guards of the counters it holds units of claim
        // (the guard of a live counter is the counter's).
        let mut lc = Vector::<u32>::new();
        self.lent_claims(cb, state, pc, &mut lc);
        let kt = self.tm.int(wide::<B>(k), W_INT, true);
        let nk = self.nsh(p, kt, v);
        let mut alive = self.tm.boolean(false);
        for j in 0..fs.len() {
            let jt = self.tm.int(wide::<B>(j as i64), W_INT, true);
            let nj = self.nsh(p, jt, v);
            alive = self.tm.or(alive, self.tm.cmp(T_LE, one_i, nj));
            if oi == NONE || j as u32 == k {
                continue;
            }
            let (_kj, gj, _lj) = self.counter_field(cm, ty, fs[j]);
            let gt = self.counter_guard(cm, ty, gj, p, state);
            let mk = self.guard_units(gt, p, k);
            if mk > 0 {
                let live = self.tm.cmp(T_LE, one_i, nj);
                let s0 = self.tm.arith(T_ADD, nk, self.tm.int(wide::<B>(mk), W_INT, true), W_INT, true);
                let f = self.tm.or(self.tm.not(live), self.count_ge(o, oi, lock, a1, s0));
                pc.push(self.tm.or(self.tm.not(g), f));
            }
        }
        // A compare-and-swap's old value is the count where it succeeds.
        if oi != NONE {
            let f = self.count_ge(o, oi, lock, a1, nk);
            pc.push(self.tm.or(self.tm.not(g), f));
        }
        // Which step: by the operation, then by what the path proves of the values.
        let mut pg = pc.clone();
        pg.push(g);
        let gt0 = self.counter_guard(cm, ty, gd, p, state);
        if gt0 == NONE {
            self.report(
                OB_COUNTER << 56 | 4 << 40 | key,
                dc::COUNTER_STEP,
                sp,
                format("cannot find this counter's guard: the '@counter' spec function of the struct's file"),
                String::from_str("the guard takes the block's pointer and has the struct's type parameters"),
            );
            return;
        }
        let mut excl = true;
        for j in 0..fs.len() {
            excl = excl && self.guard_units(gt0, p, j as u32) == 0;
        }
        // 1 inc, 2 dec, 3 lock, 4 unlock, 5 start, 0 none.
        let mut kind: u8 = 0;
        if op == CS_INIT {
            kind = 5;
        } else if op == CS_STORE {
            kind = pick(lock, 4u8, 0u8);
        } else if op == CS_ADD || op == CS_SUB {
            if self.holds(&pg, self.tm.cmp(T_EQ, d, one)) {
                kind = pick(op == CS_ADD, 1u8, 2u8);
            }
        } else if o != NONE && lock && self.holds(&pg, self.tm.cmp(T_EQ, n, a1)) {
            kind = 3;
        } else if o != NONE && self.holds(&pg, self.tm.cmp(T_EQ, n, self.tm.arith(T_ADD, o, one, w, sg))) {
            kind = 1;
        } else if o != NONE && self.holds(&pg, self.tm.cmp(T_EQ, n, self.tm.arith(T_SUB, o, one, w, sg))) {
            kind = 2;
        } else if op == CS_PLAIN && excl {
            kind = 5;
        }
        let nlit = if self.tm.is_int(n) {
            self.tm.at(n).k.to_i64()
        } else {
            0
        };
        if kind == 0 || kind == 5 && nlit < 1 || (kind == 1 || kind == 2) && oi == NONE || ni == NONE {
            self.report(
                OB_COUNTER << 56 | key,
                dc::COUNTER_STEP,
                sp,
                format("cannot prove that this write changes the counter by one, or starts it"),
                String::from_str(
                    "an '@counter' field steps by one (a plain or atomic add, sub or compare-and-swap), or starts at a positive literal where the body holds its guard",
                ),
            );
            return;
        }
        let ng = self.tm.not(g);
        let (req, pre, msg) = if kind == 1 {
            let ge1 = self.count_ge(o, oi, lock, a1, one_i);
            (
                NONE,
                self.tm.and(alive, self.tm.or(ng, ge1)),
                "cannot prove that the body holds a unit of this counter's block, and the count is at least 1"
            )
        } else if kind == 2 {
            (self.unit_atom(p, k, 1), self.tm.boolean(true), "cannot prove that the body holds a unit of this counter")
        } else if kind == 3 {
            (NONE, self.tm.or(ng, self.tm.cmp(T_EQ, o, one)), "cannot prove that this lock finds the count at 1")
        } else if kind == 4 {
            (
                self.unit_atom(p, LOCK_UNIT + k, 1),
                self.tm.cmp(T_EQ, n, one),
                "cannot prove that the body holds this counter's lock, and stores 1"
            )
        } else {
            (gt0, self.tm.boolean(true), "cannot prove that the body holds this counter's guard where it starts")
        };
        // The step as a lemma call: it takes `req`'s claims, then gives its own. A null block has no count:
        // its write faults, so past the step the block is not null.
        let nl = self.null_ptr();
        let isn = self.tm.cmp(T_EQ, p, nl);
        self.ov_take.clear();
        self.ov_take_sh.clear();
        self.tk_atoms.clear();
        self.tk_src.clear();
        self.ov_pre = self.ov;
        self.recv_pre = self.recv_val(state);
        let ob = if req == NONE {
            self.tm.or(isn, pre)
        } else {
            let rq = self.tm.or(isn, req);
            self.ov_name(rq, SRC_REQ);
            self.tm.or(isn, self.tm.and(req, pre))
        };
        self.oblige(pc, ob, OB_COUNTER << 56 | 1 << 39 | key, sp, String::from_str(msg), String::new());
        self.ov_apart(pc, sp);
        let tk = self.ov_take.clone();
        self.lent_take(cb, state, pc, &tk, sp);
        self.ov_switch();
        let lockok = if lock && o != NONE {
            self.tm.and(self.tm.cmp(T_NE, o, a1), self.tm.cmp(T_NE, n, a1))
        } else {
            self.tm.boolean(true)
        };
        let ens = if kind == 1 {
            let st = self.tm.cmp(T_EQ, ni, self.tm.arith(T_ADD, oi, one_i, W_INT, true));
            let c = self.tm.and(g, self.tm.and(st, lockok));
            self.tm.or(self.tm.not(c), self.unit_atom(p, k, 1))
        } else if kind == 2 {
            let st = self.tm.cmp(T_EQ, ni, self.tm.arith(T_SUB, oi, one_i, W_INT, true));
            let z = self.tm.and(g, self.tm.and(st, self.tm.and(lockok, self.tm.cmp(T_EQ, ni, zero_i))));
            let gt1 = self.counter_guard(cm, ty, gd, p, state);
            let e0 = self.tm.or(self.tm.not(z), pick(gt1 == NONE, self.tm.boolean(true), gt1));
            if op == CS_CAS {
                self.tm.and(e0, self.tm.or(g, self.unit_atom(p, k, 1)))
            } else {
                e0
            }
        } else if kind == 3 {
            self.tm.or(ng, self.unit_atom(p, LOCK_UNIT + k, 1))
        } else if kind == 4 {
            self.tm.boolean(true)
        } else {
            self.unit_atom(p, k, nlit)
        };
        pc.push(self.tm.not(isn));
        pc.push(ens);
        self.src_mark(ens, SRC_RES);
        self.sh_give(ens);
        self.ov_end();
    }

    // The start of the counters of the struct `x` written whole through block pointer `p` (`*p = S {..}`,
    // struct type `ty`): first the counters whose guards claim no unit of the block, then the others, which
    // may claim the units the first ones gave.
    fn count_start(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        ty: TypeId,
        p: u32,
        x: u32,
        sp: tok::Span,
        key: u64,
    ) {
        let mut fs = Vector::<u32>::new();
        self.counters_of(cm, ty, &mut fs);
        let xa = self.tm.at(x);
        for pass in 0..2u32 {
            for k in 0..fs.len() {
                let (_k, gd, _l) = self.counter_field(cm, ty, fs[k]);
                let gt = self.counter_guard(cm, ty, gd, p, state);
                let mut shared = false;
                for j in 0..fs.len() {
                    shared = shared || self.guard_units(gt, p, j as u32) != 0;
                }
                if shared != (pass == 1) {
                    continue;
                }
                let n = if xa.op == T_AGG && fs[k] < xa.b {
                    self.tm.args[(xa.a + fs[k]) as usize]
                } else {
                    NONE
                };
                if n == NONE {
                    self.report(
                        OB_COUNTER << 56 | key | 3 << 40,
                        dc::COUNTER_STEP,
                        sp,
                        format("cannot prove that this write starts the counters at positive literals"),
                        String::new(),
                    );
                    return;
                }
                self.count_step(
                    cb,
                    cm,
                    state,
                    pc,
                    ty,
                    fs[k],
                    p,
                    NONE,
                    n,
                    NONE,
                    self.tm.boolean(true),
                    CS_INIT,
                    sp,
                    key | k as u64 << 44,
                );
            }
        }
    }

    // `rc_share(p, k, n)` in the walk's version: an atom true where the body holds `n` units of counter `k`
    // of block `p` (`nsh`). Made in a collecting version (`ov_col`), its units are given (`sh_seen`). A
    // counter or a count that is no literal holds nothing the proofs may use: an unknown.
    fn share_atom(self: &mut Self, p: u32, k: u32, n: u32) u32 {
        let (kc, nc) = (self.int_const(k), self.int_const(n));
        if kc == NONE || nc == NONE {
            return self.tm.var(W_BOOL, false);
        }
        let v = self.ov;
        let vt = self.tm.int(wide::<B>(v), 32, false);
        let mut xs = Vector::<u32>::with_capacity(4);
        xs.push(p);
        xs.push(kc);
        xs.push(nc);
        xs.push(vt);
        let h = self.tm.call(SHARE_KEY, &xs, W_BOOL, false);
        if !self.sh_p.contains_key(&h) {
            self.sh_p.insert(h, p as u64 << 32 | v as u64);
            self.sh_kn.insert(h, kc as u64 << 32 | nc as u64);
            let c = self.nsh(p, kc, v);
            let ge = self.tm.cmp(T_LE, nc, c);
            let nh = self.tm.not(h);
            let nge = self.tm.not(ge);
            let a = self.tm.or(nh, ge);
            let b = self.tm.or(h, nge);
            let f = self.tm.and(a, b);
            self.anchor(h, f);
        }
        return h;
    }

    // `nsh(p, k, v)`: the units of counter `k` (an `int` literal term) of block `p` the body holds in
    // version `v`, at least 0, defined from the version before by the units its step took or gave
    // (`nsh_def`); in a version still collecting what it gives, once it is known (`nsh_wait`: count,
    // block, counter, version).
    fn nsh(self: &mut Self, p: u32, k: u32, v: u32) u32 {
        let vt = self.tm.int(wide::<B>(v), 32, false);
        let mut xs = Vector::<u32>::with_capacity(3);
        xs.push(p);
        xs.push(k);
        xs.push(vt);
        let c = self.tm.call(NSH_KEY, &xs, W_INT, true);
        if self.ov_defd.contains_key(&c) {
            return c;
        }
        self.ov_defd.insert(c, true);
        let z = self.tm.int(Num::<B>::zero(), W_INT, true);
        let f = self.tm.cmp(T_LE, z, c);
        self.anchor(c, f);
        if v as usize >= self.ov_kind.len() || self.ov_kind[v as usize] == OV_BASE {
            return c;
        }
        if self.ov_psn[v as usize] == NONE {
            self.nsh_wait.push(c);
            self.nsh_wait.push(p);
            self.nsh_wait.push(k);
            self.nsh_wait.push(v);
            return c;
        }
        self.nsh_def(c, p, k, v);
        return c;
    }

    // The step of count `c` (`nsh(p, k, v)`) from version `v`'s previous one: less the units its REMOVE
    // took of the counter (each taken atom where its claim guard holds and its block is `p`), plus those
    // its ADD gave. One unknown per entry (`DSH_KEY`), its value by cases.
    // Block `r` an allocator gave in the walked call is none whose units the body held before the call: a
    // unit is a share of a block no holder may free (`rc_share`), and `r` is not null. A fact of the path
    // where the body holds one or the pointer is null: the count terms that compare the blocks are far
    // from `r`.
    fn fresh_apart(self: &mut Self, pc: &mut Vector<u32>, r: u32) {
        let mut cs = Vector::<u64>::new();
        for (h, pv) in self.sh_p.iter() {
            let pk = *pv >> 32 << 32 | *self.sh_kn.get(h).unwrap() >> 32;
            if !cs.contains(&pk) {
                cs.push(pk);
            }
        }
        cs.sort();
        let one = self.tm.int(Num::<B>::one(), W_INT, true);
        for j in 0..cs.len() {
            let (p, k) = ((cs[j] >> 32) as u32, cs[j] as u32);
            let c = self.nsh(p, k, self.ov_pre);
            let live = self.tm.cmp(T_LE, one, c);
            let nl = self.null_ptr();
            let isn = self.tm.cmp(T_EQ, p, nl);
            let e = self.tm.cmp(T_EQ, r, p);
            if self.holds(pc, self.tm.or(isn, live)) {
                pc.push(self.tm.not(e));
            }
        }
    }

    fn nsh_def(self: &mut Self, c: u32, p: u32, k: u32, v: u32) {
        let prev = self.ov_prev[v as usize];
        let c0 = self.nsh(p, k, prev);
        let rem = self.ov_kind[v as usize] == OV_REMOVE;
        let es = if rem {
            switch self.sh_tk.get(&v) {
                Some(x) => x.clone(),
                None => Vector::<u32>::new(),
            }
        } else {
            switch self.sh_gv.get(&v) {
                Some(x) => x.clone(),
                None => Vector::<u32>::new(),
            }
        };
        let mut sum = self.tm.int(Num::<B>::zero(), W_INT, true);
        let z = sum;
        let mut j: usize = 0;
        while j < es.len() {
            // The entry's block, counter, units and the condition it applies under.
            let x = es[j];
            let kn = *self.sh_kn.get(&x).unwrap();
            let (pj, kj, nj, g) = (
                (*self.sh_p.get(&x).unwrap() >> 32) as u32,
                (kn >> 32) as u32,
                (kn & 0xFFFFFFFFu64) as u32,
                es[j + 1]
            );
            j += 2;
            if kj != k {
                continue;
            }
            let mut ys = Vector::<u32>::with_capacity(2);
            ys.push(c);
            ys.push(self.tm.int(wide::<B>(j as i64), 32, false));
            let d = self.tm.call(DSH_KEY, &ys, W_INT, true);
            let same = self.tm.cmp(T_EQ, p, pj);
            let on = self.tm.and(g, same);
            let dn = self.tm.cmp(T_EQ, d, nj);
            let dz = self.tm.cmp(T_EQ, d, z);
            let non = self.tm.not(on);
            let a = self.tm.or(non, dn);
            let b = self.tm.or(on, dz);
            let fd = self.tm.and(a, b);
            self.anchor(d, fd);
            sum = self.tm.arith(T_ADD, sum, d, W_INT, true);
        }
        let rhs = if rem {
            self.tm.arith(T_SUB, c0, sum, W_INT, true)
        } else {
            self.tm.arith(T_ADD, c0, sum, W_INT, true)
        };
        let f = self.tm.cmp(T_EQ, c, rhs);
        self.anchor(c, f);
    }

    // The units fact `f` gives the body in the collecting version (`ov_col`): a callee's `ensures`, the
    // invariants of the values it gives, a value memory gives up (`mi_open`), each with its claim guard.
    fn sh_give(self: &mut Self, f: u32) {
        if self.ov_col == NONE {
            return;
        }
        let v = self.ov_col;
        let mut out = Vector::<u32>::new();
        self.sh_claims(f, v, &mut out);
        self.sh_seen.extend_copy(&out);
    }

    // A collecting version `v` (an ADD) is closed with the blocks `e` it gives: the units it gives too
    // (`sh_seen`: atom, guard), and the counts that waited for them are defined.
    fn ov_close(self: &mut Self, v: u32, e: &Vector<u32>) {
        self.ov_fin(v, e);
        let g = replace(&mut self.sh_seen, Vector::<u32>::new());
        if g.len() != 0 {
            self.sh_gv.insert(v, g);
        }
        let w = replace(&mut self.nsh_wait, Vector::<u32>::new());
        let mut keep = Vector::<u32>::new();
        let mut j: usize = 0;
        while j < w.len() {
            if w[j + 3] == v {
                self.nsh_def(w[j], w[j + 1], w[j + 2], v);
            } else {
                for q in 0..4usize {
                    keep.push(w[j + q]);
                }
            }
            j += 4;
        }
        self.nsh_wait = keep;
    }

    // That the units claims `cs0` (share atom, claim guard; one version's) name fit in the units the body
    // holds: per counter, the claims of it sum to at most its count. One unknown per pair (`DSH_KEY`):
    // claim j's units where it claims counter i's block. The lent claims `ls`, which two shared borrows of
    // one value may make twice, count once per counter: the most units one of them claims, where any
    // claims it.
    fn sh_fit(self: &mut Self, cs0: &Vector<u32>, ls: &Vector<u32>) u32 {
        let mut cs = cs0.clone();
        cs.extend_copy(ls);
        let nown = cs0.len();
        let mut g = self.tm.boolean(true);
        let z = self.tm.int(Num::<B>::zero(), W_INT, true);
        let f0 = self.tm.boolean(false);
        let mut i: usize = 0;
        while i < cs.len() {
            let pv = *self.sh_p.get(&cs[i]).unwrap();
            let (p, v) = ((pv >> 32) as u32, (pv & 0xFFFFFFFFu64) as u32);
            let ki = (*self.sh_kn.get(&cs[i]).unwrap() >> 32) as u32;
            let mut sum = z;
            let mut lany = f0;
            let mut lmax: i64 = 0;
            let mut j: usize = 0;
            while j < cs.len() {
                let kn = *self.sh_kn.get(&cs[j]).unwrap();
                if (kn >> 32) as u32 == ki && j >= nown {
                    let pj = (*self.sh_p.get(&cs[j]).unwrap() >> 32) as u32;
                    let same = self.tm.cmp(T_EQ, p, pj);
                    let on = self.tm.and(cs[j + 1], same);
                    lany = self.tm.or(lany, on);
                    let nv = self.tm.at((kn & 0xFFFFFFFFu64) as u32).k.to_i64();
                    if nv > lmax {
                        lmax = nv;
                    }
                } else if (kn >> 32) as u32 == ki {
                    let pj = (*self.sh_p.get(&cs[j]).unwrap() >> 32) as u32;
                    let nj = (kn & 0xFFFFFFFFu64) as u32;
                    let mut ys = Vector::<u32>::with_capacity(2);
                    ys.push(cs[i]);
                    ys.push(cs[j]);
                    ys.push(cs[j + 1]);
                    let d = self.tm.call(DSH_KEY | 1, &ys, W_INT, true);
                    let same = self.tm.cmp(T_EQ, p, pj);
                    let on = self.tm.and(cs[j + 1], same);
                    let dn = self.tm.cmp(T_EQ, d, nj);
                    let dz = self.tm.cmp(T_EQ, d, z);
                    let non = self.tm.not(on);
                    let a = self.tm.or(non, dn);
                    let b = self.tm.or(on, dz);
                    let fd = self.tm.and(a, b);
                    self.anchor(d, fd);
                    sum = self.tm.arith(T_ADD, sum, d, W_INT, true);
                }
                j += 2;
            }
            if lmax != 0 {
                let mut ys = Vector::<u32>::with_capacity(1);
                ys.push(cs[i]);
                let d = self.tm.call(DSH_KEY | 2, &ys, W_INT, true);
                let nl = self.tm.int(wide::<B>(lmax), W_INT, true);
                let dn = self.tm.cmp(T_EQ, d, nl);
                let dz = self.tm.cmp(T_EQ, d, z);
                let nany = self.tm.not(lany);
                let a = self.tm.or(nany, dn);
                let b = self.tm.or(lany, dz);
                let fd = self.tm.and(a, b);
                self.anchor(d, fd);
                sum = self.tm.arith(T_ADD, sum, d, W_INT, true);
            }
            let c = self.nsh(p, ki, v);
            let le = self.tm.cmp(T_LE, sum, c);
            g = self.tm.and(g, le);
            i += 2;
        }
        return g;
    }

    // The share atoms version `v` of fact `f` claims, each with its claim guard (true for an inexact one),
    // appended to `out` as atom, guard pairs.
    fn sh_claims(self: &mut Self, f: u32, v: u32, out: &mut Vector<u32>) {
        if f == NONE {
            return;
        }
        let mut sg = Vector::<u64>::new();
        self.sh_g(f, v, &mut sg);
        for j in 0..sg.len() {
            let g = (sg[j] & 0xFFFFFFFFu64) as u32;
            out.push((sg[j] >> 32) as u32);
            out.push(pick(g == NONE, self.tm.boolean(true), g));
        }
    }

    // The share atoms version `v` of fact `f` claims, each with its claim guard (`held_g` in `sh_mode`).
    fn sh_g(self: &mut Self, f: u32, v: u32, out: &mut Vector<u64>) {
        let m0 = replace(&mut self.sh_mode, true);
        self.held_g(f, v, out);
        self.sh_mode = m0;
    }

    // Blocks of two sources in one version are distinct (`src_tab`): the entry's parameters and clauses
    // (the caller proved it, `ov_apart`), the values a call gives, the locals a call or a drop leaves (the
    // unwinding check proved it, `inv_unwind`). Two shared references may be one value, and a value from
    // memory any other source's (`SRC_MEM`). Register the claimed held atoms of version `ov` fact `f`
    // (`held_g`) as of source `src`, each with its distinctness from the other sources' atoms.
    fn src_mark(self: &mut Self, f: u32, src: u32) {
        if f == NONE || src == 0 {
            return;
        }
        let v = self.ov;
        let mut hg = Vector::<u64>::new();
        self.held_g(f, v, &mut hg);
        let mut tab = switch self.src_tab.get(&v) {
            Some(x) => x.clone(),
            None => Vector::<u32>::new(),
        };
        for q in 0..hg.len() {
            let h = (hg[q] >> 32) as u32;
            let g = (hg[q] & 0xFFFFFFFFu64) as u32;
            // A guard the walk could not state claims nothing it may assume.
            if g == NONE {
                continue;
            }
            let mut known = false;
            let mut j: usize = 0;
            while j < tab.len() {
                known = known || tab[j] == h && tab[j + 1] == g && tab[j + 2] == src;
                j += 3;
            }
            if known {
                continue;
            }
            let p = (*self.held_p.get(&h).unwrap() >> 32) as u32;
            j = 0;
            while j < tab.len() {
                let (h2, g2, s2) = (tab[j], tab[j + 1], tab[j + 2]);
                j += 3;
                // One source's claims are distinct too (a separating conjunction, proved where the fact
                // was transferred).
                if h2 == h || s2 != src && ((s2 & SRC_REF) != 0 && (src & SRC_REF) != 0 || ((s2 | src) & SRC_MEM) != 0) {
                    continue;
                }
                let p2 = (*self.held_p.get(&h2).unwrap() >> 32) as u32;
                let d = self.apart(g, p, g2, p2);
                self.anchor(h, d);
                self.ptr_apart_add(p, d);
                self.ptr_apart_add(p2, d);
            }
            tab.push(h);
            tab.push(g);
            tab.push(src);
        }
        self.src_tab.insert(v, tab);
    }

    fn ptr_apart_add(self: &mut Self, p: u32, d: u32) {
        let mut l = switch self.ptr_apart.get(&p) {
            Some(x) => x.clone(),
            None => Vector::<u32>::new(),
        };
        if !l.contains(&d) {
            l.push(d);
            self.ptr_apart.insert(p, l);
        }
    }

    // The held atoms of version `v` fact `f` claims, each with its guard: the condition under which `f`
    // needs it (the other cases of each `||` on the way false), through the definitions of the calls it
    // names; NONE for an atom at another place (under a `!`, in an equality), which may hold anywhere.
    fn held_g(self: &mut Self, f: u32, v: u32, out: &mut Vector<u64>) {
        let mut budget: u32 = 4096;
        let t = self.tm.boolean(true);
        let mut raw = Vector::<u64>::new();
        self.held_g_at(f, t, v, &mut raw, &mut budget, 0);
        self.merge_guards(&raw, out);
    }

    // One entry per atom: an atom the walk met at several places is claimed where any of its guards holds
    // (in the walk's order, so that two walks of one definition give one guard term).
    fn merge_guards(self: &mut Self, raw: &Vector<u64>, out: &mut Vector<u64>) {
        let mut atoms = Vector::<u32>::new();
        let mut guards = Vector::<u32>::new();
        for j in 0..raw.len() {
            let h = (raw[j] >> 32) as u32;
            let g = (raw[j] & 0xFFFFFFFFu64) as u32;
            let mut k = atoms.len();
            for q in 0..atoms.len() {
                if atoms[q] == h {
                    k = q;
                }
            }
            if k == atoms.len() {
                atoms.push(h);
                guards.push(g);
            } else if guards[k] != NONE && g != NONE {
                let o = self.tm.or(guards[k], g);
                guards.set(k, o);
            } else {
                guards.set(k, NONE);
            }
        }
        for q in 0..atoms.len() {
            out.push(atoms[q] as u64 << 32 | guards[q] as u64);
        }
    }

    fn held_g_at(self: &mut Self, t: u32, g: u32, v: u32, out: &mut Vector<u64>, budget: &mut u32, depth: u32) {
        if t == NONE || *budget == 0 {
            return;
        }
        *budget -= 1;
        if let Some(pv) = self.atom_pv(t) {
            if v == NONE || (pv & 0xFFFFFFFFu64) as u32 == v {
                let e = t as u64 << 32 | g as u64;
                if !out.contains(&e) {
                    out.push(e);
                }
            }
            return;
        }
        let x = self.tm.at(t);
        if x.op == T_AND && depth < 32 {
            self.held_g_at(x.a, g, v, out, budget, depth + 1);
            self.held_g_at(x.b, g, v, out, budget, depth + 1);
            return;
        }
        // A call's or an invariant's definition (`t == body`, beside the frames anchored with it).
        if x.op == T_CALL && depth < 32 {
            let d = match_def(&self.def_of, &self.defs, t);
            let body = if d == NONE {
                NONE
            } else {
                self.def_body_of(d, t)
            };
            if body != NONE {
                self.held_g_at(body, g, v, out, budget, depth + 1);
            }
            return;
        }
        // Any other formula `t` (cases): an atom of it is claimed where `t` needs it, `!t[h := false]`.
        let mut hs = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        self.held_in(t, v, &mut hs, &mut seen);
        for j in 0..hs.len() {
            let mut memo = Map::<u32, u32>::new();
            let mut exact = true;
            let f0 = self.subst_false(t, hs[j], &mut memo, &mut exact, 0);
            let gh = if exact && g != NONE {
                let nf = self.tm.not(f0);
                self.tm.and(g, nf)
            } else {
                NONE
            };
            let e = hs[j] as u64 << 32 | gh as u64;
            if !out.contains(&e) {
                out.push(e);
            }
        }
    }

    // Formula `t` with held atom `h` false, through the definitions of the calls it names; `exact` false
    // where `h` stands elsewhere than under connectives (its value there is not known false).
    fn subst_false(self: &mut Self, t: u32, h: u32, memo: &mut Map<u32, u32>, exact: &mut bool, depth: u32) u32 {
        if t == h {
            return self.tm.boolean(false);
        }
        if let Some(r) = memo.get(&t) {
            return *r;
        }
        let x = self.tm.at(t);
        let r = if depth > 48 {
            *exact = false;
            t
        } else if x.op == T_AND {
            let a = self.subst_false(x.a, h, memo, exact, depth + 1);
            let b = self.subst_false(x.b, h, memo, exact, depth + 1);
            self.tm.and(a, b)
        } else if x.op == T_OR {
            let a = self.subst_false(x.a, h, memo, exact, depth + 1);
            let b = self.subst_false(x.b, h, memo, exact, depth + 1);
            self.tm.or(a, b)
        } else if x.op == T_NOT {
            let a = self.subst_false(x.a, h, memo, exact, depth + 1);
            self.tm.not(a)
        } else if x.op == T_CALL && self.reaches_h(t, h) {
            let d = match_def(&self.def_of, &self.defs, t);
            let body = if d == NONE {
                NONE
            } else {
                self.def_body_of(d, t)
            };
            if body == NONE {
                *exact = false;
                t
            } else {
                self.subst_false(body, h, memo, exact, depth + 1)
            }
        } else if x.op != T_CALL && self.reaches_h(t, h) {
            *exact = false;
            t
        } else {
            t
        };
        memo.insert(t, r);
        return r;
    }

    // Whether term `t` reaches held atom `h`, through definitions.
    fn reaches_h(self: &mut Self, t: u32, h: u32) bool {
        let mut hs = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let pv = self.atom_pv(h).unwrap();
        self.held_in(t, (pv & 0xFFFFFFFFu64) as u32, &mut hs, &mut seen);
        return hs.contains(&h);
    }

    // The body of definition `d` of term `t` (`t == body`, a conjunct of `d`), NONE for none.
    fn def_body_of(self: &Self, d: u32, t: u32) u32 {
        let mut stack = Vector::<u32>::new();
        stack.push(d);
        for _k in 0..64 {
            if stack.len() == 0 {
                return NONE;
            }
            let f = stack.pop().unwrap();
            let x = self.tm.at(f);
            if x.op == T_EQ && x.a == t {
                return x.b;
            }
            if x.op == T_EQ && x.b == t {
                return x.a;
            }
            if x.op == T_AND {
                stack.push(x.a);
                stack.push(x.b);
            }
        }
        return NONE;
    }

    // The guard of a claimed atom `h` (`held_g`): its own, or the atom where the walk had none.
    const fn guard_or(self: &Self, h: u32, g: u32) u32 {
        return pick(g == NONE, h, g);
    }

    // `apart(g, p, g2, p2)`, or true where it is a fact (`ptr_apart`): an obligation on values the path
    // has not changed since their distinctness was stated.
    // Whether held atom `hi` is one an allocator's atom `h` falls back from: one block, one holder.
    fn held_alt_of(self: &Self, h: u32, hi: u32) bool {
        if let Some(alts) = self.held_alt.get(&h) {
            return alts.contains(&hi);
        }
        return false;
    }

    fn apart_need(self: &mut Self, g: u32, p: u32, g2: u32, p2: u32) u32 {
        let d = self.apart(g, p, g2, p2);
        let d2 = self.apart(g2, p2, g, p);
        if let Some(ds) = self.ptr_apart.get(&p) {
            if ds.contains(&d) || ds.contains(&d2) {
                return self.tm.boolean(true);
            }
        }
        return d;
    }

    // Where `h` and `h2` (claim guards or held atoms of pointers `p`, `p2`) both hold, the blocks differ.
    fn apart(self: &mut Self, h: u32, p: u32, h2: u32, p2: u32) u32 {
        let n1 = self.tm.not(h);
        let n2 = self.tm.not(h2);
        let e = self.tm.cmp(T_EQ, p, p2);
        let ne = self.tm.not(e);
        let o = self.tm.or(n2, ne);
        return self.tm.or(n1, o);
    }

    // The definition of held atom `h` (`held_atom`) in version `v`, from the version before: REMOVE's
    // `held_prev(q) && (!c || q != p).. ==> held_v(q)` for each atom `c` taken, of pointer `p`; ADD's
    // `held_prev(q) ==> q != p.. && held_v(q)`; none for BASE or an ADD the walk is still making (its atoms
    // are the blocks it gives).
    fn held_def(self: &mut Self, h: u32, k: u64, p: u32, n: u32, a: u32, v: u32) {
        if v as usize >= self.ov_kind.len() || self.ov_defd.contains_key(&h) {
            return;
        }
        let kd = self.ov_kind[v as usize];
        if kd == OV_BASE {
            return;
        }
        self.ov_defd.insert(h, true);
        if self.ov_psn[v as usize] == NONE {
            return;
        }
        let ov0 = self.ov;
        self.ov = self.ov_prev[v as usize];
        let hp = self.held_atom(k, p, n, a);
        self.ov = ov0;
        let mut ne = self.tm.boolean(true);
        let st = self.ov_pst[v as usize] as usize;
        let mut j = st;
        while j < st + self.ov_psn[v as usize] as usize {
            // REMOVE's entries are the atoms taken and their claim guards (`held_g`): a block is taken
            // where its clause or invariant claims it.
            let x = self.ov_ps[j];
            let (px, gx) = if kd == OV_REMOVE {
                ((*self.held_p.get(&x).unwrap() >> 32) as u32, self.ov_ps[j + 1])
            } else {
                (x, NONE)
            };
            j += pick(kd == OV_REMOVE, 2usize, 1usize);
            let e = self.tm.cmp(T_EQ, p, px);
            let ne1 = self.tm.not(e);
            let ne2 = if kd == OV_REMOVE {
                let nx = self.tm.not(gx);
                self.tm.or(nx, ne1)
            } else {
                ne1
            };
            ne = self.tm.and(ne, ne2);
        }
        // Facts flow from earlier versions to later ones: `held_prev(q) && q != p.. ==> held_v(q)`. An ADD's
        // blocks given were no block the body held (one holder per block): `held_prev(q) ==> q != p..`.
        let nhp = self.tm.not(hp);
        let f = if kd == OV_REMOVE {
            let nne = self.tm.not(ne);
            let o = self.tm.or(nne, h);
            self.tm.or(nhp, o)
        } else {
            let a = self.tm.and(ne, h);
            self.tm.or(nhp, a)
        };
        self.anchor(h, f);
    }

    // The blocks clause or invariant `f` (of source `src`, as `ov_src`) names in the walk's version: a call
    // takes them (`ov_switch`).
    fn ov_name(self: &mut Self, f: u32, src: u32) {
        self.ov_name_as(f, src, true);
    }

    // `ov_name`; without `take`, the blocks are only a source of the call's distinctness check (a shared
    // borrow lends them).
    fn ov_name_as(self: &mut Self, f: u32, src: u32, take: bool) {
        if f == NONE {
            return;
        }
        let v = self.ov;
        // The units it claims, taken as its blocks are (`ov_remove`).
        if take {
            let mut sg = Vector::<u64>::new();
            self.sh_g(f, v, &mut sg);
            for j in 0..sg.len() {
                let h = (sg[j] >> 32) as u32;
                let g = (sg[j] & 0xFFFFFFFFu64) as u32;
                let g1 = pick(g == NONE, self.tm.boolean(true), g);
                self.ov_take_sh.push(h);
                self.ov_take_sh.push(g1);
            }
        }
        let mut hg = Vector::<u64>::new();
        self.held_g(f, v, &mut hg);
        for j in 0..hg.len() {
            let h = (hg[j] >> 32) as u32;
            let g = self.guard_or(h, (hg[j] & 0xFFFFFFFFu64) as u32);
            let mut known = !take;
            let mut q: usize = 0;
            while q < self.ov_take.len() {
                known = known || self.ov_take[q] == h && self.ov_take[q + 1] == g;
                q += 2;
            }
            if !known {
                self.ov_take.push(h);
                self.ov_take.push(g);
            }
            if src != 0 {
                self.tk_atoms.push(h);
                self.tk_atoms.push(g);
                self.tk_src.push(src);
            }
        }
    }

    // The blocks a `requires` clause of the call at `sp` takes are none of the other clauses' or
    // arguments' (`tk_atoms`): the callee assumes them distinct (`held_atom`).
    fn ov_apart(self: &mut Self, pc: &Vector<u32>, sp: tok::Span) {
        let mut g = self.tm.boolean(true);
        for i in 0..self.tk_src.len() {
            for j in i + 1..self.tk_src.len() {
                let (si, sj) = (self.tk_src[i], self.tk_src[j]);
                // Two arguments are two values (their blocks are distinct: `inv_unwind`); two shared
                // borrows may be one value. A clause's blocks, and one value's, are proved distinct.
                let clause = (si & SRC_REQ) != 0 || (sj & SRC_REQ) != 0;
                if si != sj && !clause || si != sj && (si & SRC_REF) != 0 && (sj & SRC_REF) != 0 {
                    continue;
                }
                let (h, g1, h2, g2) = (
                    self.tk_atoms[2 * i],
                    self.tk_atoms[2 * i + 1],
                    self.tk_atoms[2 * j],
                    self.tk_atoms[2 * j + 1]
                );
                if h == h2 && si == sj || self.held_alt_of(h, h2) || self.held_alt_of(h2, h) {
                    continue;
                }
                let p = (*self.held_p.get(&h).unwrap() >> 32) as u32;
                let p2 = (*self.held_p.get(&h2).unwrap() >> 32) as u32;
                let d = self.apart_need(g1, p, g2, p2);
                g = self.tm.and(g, d);
            }
        }
        self.tk_atoms.clear();
        self.tk_src.clear();
        if self.tm.is_true(g) || self.apart_holds(pc, g) {
            return;
        }
        self.oblige(
            pc,
            g,
            OB_REQUIRES << 56 | 1 << 55 | sp.start as u64,
            sp,
            String::from_str("cannot prove that the blocks this call takes are distinct"),
            String::from_str(
                "each block has one holder: the 'owns' of the callee's clauses and of an argument's invariant name distinct blocks",
            ),
        );
    }

    // Where a loop's invariants `fs` are established (the loop's start, the end of an iteration): the blocks
    // they name are distinct, which the header assumes (SRC_LOOP).
    fn loop_apart(self: &mut Self, pc: &Vector<u32>, fs: &Vector<u32>, sp: tok::Span, key: u64) {
        let mut all = self.tm.boolean(true);
        for j in 0..fs.len() {
            all = self.tm.and(all, fs[j]);
        }
        let mut hg = Vector::<u64>::new();
        let v = self.ov;
        self.held_g(all, v, &mut hg);
        let mut g = self.tm.boolean(true);
        for i in 0..hg.len() {
            for j in i + 1..hg.len() {
                let (h, g1) = ((hg[i] >> 32) as u32, (hg[i] & 0xFFFFFFFFu64) as u32);
                let (h2, g2) = ((hg[j] >> 32) as u32, (hg[j] & 0xFFFFFFFFu64) as u32);
                if g1 == NONE || g2 == NONE || h == h2 || self.held_alt_of(h, h2) || self.held_alt_of(h2, h) {
                    continue;
                }
                let p = (*self.held_p.get(&h).unwrap() >> 32) as u32;
                let p2 = (*self.held_p.get(&h2).unwrap() >> 32) as u32;
                let d = self.apart_need(g1, p, g2, p2);
                let e = self.held_apart(h, h2, d);
                g = self.tm.and(g, e);
            }
        }
        if self.tm.is_true(g) || self.apart_holds(pc, g) {
            return;
        }
        self.oblige(
            pc,
            g,
            key,
            sp,
            String::from_str("cannot prove that the blocks the loop's invariants name are distinct"),
            String::from_str("each block has one holder: the 'owns' of the invariants name distinct blocks"),
        );
    }

    // A REMOVE version after the walk's for the blocks and units taken (`ov_take`, `ov_take_sh`), if any.
    fn ov_remove(self: &mut Self) {
        if self.ov_take.len() == 0 && self.ov_take_sh.len() == 0 {
            return;
        }
        let x = self.ov_new(OV_REMOVE, self.ov);
        let tk = replace(&mut self.ov_take, Vector::<u32>::new());
        let mut j: usize = 0;
        while j + 1 < tk.len() {
            let ng = self.tm.not(tk[j + 1]);
            let f = self.tm.or(ng, tk[j]);
            if !self.tm.is_true(f) {
                self.ov_had.push(f);
            }
            j += 2;
        }
        self.ov_fin(x, &tk);
        let ts = replace(&mut self.ov_take_sh, Vector::<u32>::new());
        if ts.len() != 0 {
            self.sh_tk.insert(x, ts);
        }
        self.ov = x;
    }

    // The callee takes the blocks its clauses named (`ov_take`), and the version after gives it the blocks
    // the clauses and invariants made from here name (`ov_end`).
    fn ov_switch(self: &mut Self) {
        self.ov_pre = self.ov;
        self.ov_remove();
        let v2 = self.ov_new(OV_ADD, self.ov);
        self.sh_seen.clear();
        self.ov = v2;
        self.ov_col = v2;
        self.ov_seen.clear();
        self.ov_src = SRC_RES;
    }

    fn ov_end(self: &mut Self) {
        if self.ov_col == NONE {
            return;
        }
        let e = replace(&mut self.ov_seen, Vector::<u32>::new());
        let v2 = self.ov_col;
        // A call that took and gave no block changes no version: the facts after it are the ones before.
        if e.len() == 0 && self.sh_seen.len() == 0 && self.ov_prev[v2 as usize] == self.ov_pre && self.ov == v2 {
            self.ov = self.ov_pre;
            self.ov_col = NONE;
            self.ov_src = 0;
            return;
        }
        self.ov_close(v2, &e);
        self.ov_col = NONE;
        self.ov_src = 0;
    }

    // The held atoms of version `v` term `f` reaches, its definitions included: the blocks a call's
    // `requires` take (`call`).
    // The block << 32 | version of atom `t`: a held atom's, or in `sh_mode` a share atom's.
    fn atom_pv(self: &Self, t: u32) Option<u64> {
        let m = if self.sh_mode {
            &self.sh_p
        } else {
            &self.held_p
        };
        return switch m.get(&t) {
            Some(x) => Some(*x),
            None => None,
        };
    }

    // Whether term `g` names a held atom, not through definitions.
    fn names_held(self: &mut Self, g: u32) bool {
        let mut stack = Vector::<u32>::new();
        let mut seen = Map::<u32, bool>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(g);
        while stack.len() != 0 {
            let t = stack.pop().unwrap();
            if t == NONE || seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if self.held_p.contains_key(&t) {
                return true;
            }
            ops.clear();
            self.tm.operands(t, &mut ops);
            stack.extend_copy(&ops);
        }
        return false;
    }

    fn held_in(self: &mut Self, f: u32, v: u32, out: &mut Vector<u32>, seen: &mut Map<u32, bool>) {
        let mut stack = Vector::<u32>::new();
        stack.push(f);
        let mut ops = Vector::<u32>::new();
        while stack.len() != 0 {
            let t = stack.pop().unwrap();
            if t == NONE || seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if let Some(pv) = self.atom_pv(t) {
                if v == NONE || (pv & 0xFFFFFFFFu64) as u32 == v {
                    out.push(t);
                }
                continue;
            }
            // A predicate's definition is its meaning; a value's (a loaded struct's invariant) is a fact of
            // the value's own source, whose blocks a formula that reads the value does not claim.
            if self.tm.at(t).w == W_BOOL {
                if let Some(i) = self.def_of.get(&t) {
                    stack.push(self.defs[(*i) as usize]);
                }
            }
            ops.clear();
            self.tm.operands(t, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
    }

    // Whether `d` is the prelude's `forget`.
    fn is_forget(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module != self.wcore.mid {
            return false;
        }
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && a.container_of(d.node) == NODE_NONE && self.text(
            d.module,
            a.at_const(a.ext_name(d.node)).span,
        ) == "forget";
    }

    // Whether `d` is `Allocator::owns` or a conformance's `owns`.
    fn is_owns(self: &mut Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module as usize >= self.pkg().modules.len() || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        let key = d.module as u64 << 32 | d.node as u64;
        if let Some(r) = self.owns_d.get(&key) {
            return *r;
        }
        let a = self.ast_of(d.module);
        let mut r = false;
        if a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && self.text(
            d.module,
            a.at_const(a.ext_name(d.node)).span,
        ) == "owns" {
            let c = a.container_of(d.node);
            if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_INTERFACE {
                r = d.module == self.walloc.mid && c == self.walloc.node;
            } else if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND {
                let it = a.ext(c).extend_def.interface_type;
                r = it != NODE_NONE && self.iface_named_allocator(d.module, it);
            }
        }
        self.owns_d.insert(key, r);
        return r;
    }

    // The type key of `T` where `d` is a method of an `extend T as Allocator`, else 0.
    fn alloc_conf_key(self: &Self, d: DefId) u64 {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return 0;
        }
        let a = self.ast_of(d.module);
        let c = a.container_of(d.node);
        if c == NODE_NONE || a.at_const(c).kind != NodeKind::NODE_EXTEND {
            return 0;
        }
        let it = a.ext(c).extend_def.interface_type;
        if it == NODE_NONE || !self.iface_named_allocator(d.module, it) {
            return 0;
        }
        return self.alloc_key(d.module, a.type_of(a.ext(c).extend_def.target_type));
    }

    // The key of allocator type `ty`'s blocks: its declaration (a type parameter's for a generic one).
    // The `owns` of an allocator has no receiver: two values of one type share their blocks' key.
    fn alloc_key(self: &Self, m: ModuleId, ty: TypeId) u64 {
        if ty == TYPE_NONE {
            return 0;
        }
        let (dm, dn) = self.decl_of(m, ty);
        if dn == NODE_NONE {
            return skey_mix(1, self.type_key(m, ty, 0));
        }
        return skey_mix(2, dm as u64 << 32 | dn as u64);
    }

    // Whether type node `it` of module `m` names the prelude's `Allocator` interface.
    fn iface_named_allocator(self: &Self, m: ModuleId, it: NodeId) bool {
        let idef = self.ast_of(m).resolution_def(it);
        return idef.module == self.walloc.mid && idef.node == self.walloc.node;
    }

    // Whether spec function or invariant method `d` reaches an `owns` atom through its body's calls: its
    // value depends on the ownership version (a call of it is keyed on the version).
    fn mentions_owns(self: &mut Self, d: DefId) bool {
        let key = d.module as u64 << 32 | d.node as u64;
        let pre = self.owns_m.contains_key(&key);
        let mk = self.rd.get_mut().len();
        let r = self.mentions_owns_run(d);
        self.memo_reads(1u64 << 62 | key, mk, !pre && self.owns_m.contains_key(&key));
        return r;
    }

    fn mentions_owns_run(self: &mut Self, d: DefId) bool {
        if d.node == NODE_NONE {
            return false;
        }
        let key = d.module as u64 << 32 | d.node as u64;
        if let Some(r) = self.owns_m.get(&key) {
            return *r == 2;
        }
        self.owns_m.insert(key, 3);
        let mut cbp = self.kept(d);
        if cbp == null && (d.node & NODE_BODY) == 0 && self.pkg().modules.at(d.module as usize).has_ast && self.ast_of(
            d.module,
        ).at_const(d.node).kind == NodeKind::NODE_FUNCTION && self.ast_of(d.module).ext(d.node).function.body == NODE_NONE {
            cbp = self.contract_body(d);
        }
        let mut r = false;
        if cbp != null {
            let cb = unsafe &*cbp;
            for k in 0..cb.blocks.len() {
                let t = cb.blocks.at(k).term;
                if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE {
                    continue;
                }
                if self.is_owns(t.callee) || self.is_shares(t.callee, 0) || self.is_shares(t.callee, 1) || self.is_ghost(
                    t.callee,
                ) && self.mentions_owns(t.callee) {
                    r = true;
                    break;
                }
            }
        }
        self.owns_m.insert(key, pick(r, 2u8, 1u8));
        return r;
    }

    // Whether the loop `fx.lblocks` lists may take or give a block (`ov_switch`): a call whose clauses name
    // `owns`, or a call or a drop of a value whose invariant (this file's) does.
    fn loop_owns(self: &mut Self, b: &ir::CoreBody) bool {
        for j in 0..self.fx.lblocks.len() {
            let bb = *b.blocks.at(self.fx.lblocks[j] as usize);
            // A write through a raw pointer to a struct whose invariant names blocks gives and takes them
            // (`mi_open`, `mi_close`).
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let pl = *b.places.at(st.place as usize);
                for q in 0..pl.proj_len {
                    let pj = *b.projections.at((pl.proj_start + q) as usize);
                    if pj.kind == ir::PJ_DEREF && self.raw_ptr_ty(b.module, self.proj_base_ty(b, &pl, q)) && self.inv_owns(
                        b.module,
                        pj.ty,
                    ) {
                        return true;
                    }
                }
            }
            let t = bb.term;
            if t.kind == ir::TM_DROP {
                if self.inv_owns(b.module, b.places.at(t.a as usize).ty) {
                    return true;
                }
                continue;
            }
            if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE || self.is_ghost(t.callee) {
                continue;
            }
            if self.clauses_own(t.callee) {
                return true;
            }
            for q in 0..t.args_len {
                let op = *b.operands.at(b.oper_pool[(t.args_start + q) as usize] as usize);
                // A shared borrow lends its value's blocks: the call moves none of them.
                if op.kind == ir::OP_CONST || op.ty == TYPE_NONE || self.arg_shared(b, &t, q) {
                    continue;
                }
                let y = *self.ast_of(b.module).type_at(op.ty);
                let ty = pick(y.kind == TypeKind::TYPE_REFERENCE, y.as_data.elem, op.ty);
                if self.inv_owns(b.module, ty) {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether type `ty` has an invariant this file proves that reaches `owns` (`mentions_owns`).
    fn inv_owns(self: &mut Self, m: ModuleId, ty: TypeId) bool {
        let mut binds = Vector::<u64>::new();
        let d = self.inv_method(m, ty, &mut binds);
        return d.node != NODE_NONE && d.module == self.m && self.mentions_owns(d);
    }

    // Whether the clauses of function `d` (its interface's for a conformance's method without its own)
    // reach `owns`.
    fn clauses_own(self: &mut Self, d: DefId) bool {
        let c = self.contract_of(d);
        let key = skey_mix(9, c.module as u64 << 32 | c.node as u64);
        if let Some(r) = self.owns_m.get(&key) {
            return *r == 2;
        }
        self.owns_m.insert(key, 1);
        let cbp = self.contract_body(c);
        let mut r = false;
        if cbp != null {
            let cb = unsafe &*cbp;
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if s.kind != CT_REQUIRES && s.kind != CT_ENSURES || r {
                    continue;
                }
                // The clause's chain: the blocks from its start to its check.
                let mut stack = Vector::<u32>::new();
                let mut seen = Map::<u32, bool>::new();
                stack.push(s.chain);
                for _k in 0..cb.blocks.len() + 1 {
                    if stack.len() == 0 || r {
                        break;
                    }
                    let blk = stack.pop().unwrap();
                    if blk == NONE || blk as usize >= cb.blocks.len() || seen.contains_key(&blk) {
                        continue;
                    }
                    seen.insert(blk, true);
                    let t = cb.blocks.at(blk as usize).term;
                    if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && (self.is_owns(t.callee) || self.is_ghost(
                        t.callee,
                    ) && self.mentions_owns(t.callee)) {
                        r = true;
                    }
                    if blk == s.check {
                        continue;
                    }
                    if t.kind == ir::TM_GOTO || t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP {
                        stack.push(t.t0);
                    } else if t.kind == ir::TM_SWITCH {
                        stack.push(t.t0);
                        for q in t.sw_start..t.sw_start + t.sw_len {
                            stack.push((cb.switch_pool[q as usize] & 0xFFFFFFFFu64) as u32);
                        }
                    }
                }
            }
        }
        self.owns_m.insert(key, pick(r, 2u8, 1u8));
        return r;
    }

    // Whether a value of struct type `ty` (module `m`) has an invariant (`inv_method`): one behind a raw
    // pointer holds it too, where every write through a pointer restores it (`mi_close`).
    fn mi_type(self: &Self, m: ModuleId, ty: TypeId) bool {
        let mut binds = Vector::<u64>::new();
        return ty != TYPE_NONE && self.inv_method(m, ty, &mut binds).node != NODE_NONE;
    }

    // After the memory event of write `mi_next`: the struct the pointer points to is the written value now
    // (`T_LOAD` of the new epoch), and dirty until its invariant is proved (`mi_close`).
    fn mi_forward(self: &mut Self, state: &Vector<u32>) {
        let (r, nv, m, ty) = (self.mi_next[0], self.mi_next[1], self.mi_next[2], self.mi_next[3]);
        self.mi_next.clear();
        if nv != NONE {
            let (w, sg) = self.ty_of(m as ModuleId, ty);
            let ep = state[state.len() - 1];
            let now = self.tm.make(Term::<B> { k: Num::<B>::zero(), a: r, b: ep, op: T_LOAD, w: w, sg: sg });
            self.mi_fwd.insert(now, nv);
        }
        // A struct of another file was proved at the write (`statement`); a type without an invariant
        // has none to prove.
        let mut seen = !self.st_inv.contains_key(&r) && (!self.mi_type(m as ModuleId, ty) || self.decl_of(
            m as ModuleId,
            ty,
        ).0 != self.m);
        for q in 0..self.mi_dirty.len() / 3 {
            seen = seen || self.mi_dirty[3 * q] == r;
        }
        if !seen {
            self.mi_dirty.push(r);
            self.mi_dirty.push(m);
            self.mi_dirty.push(ty);
        }
    }

    // Whether terminator `t` of body `b` leads to a loop's header.
    const fn to_header(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if self.fx.rpo_of.len() > t.t0 as usize && self.fx.is_header(t.t0) {
            return true;
        }
        if t.kind == ir::TM_SWITCH {
            for j in t.sw_start..t.sw_start + t.sw_len {
                let to = (b.switch_pool[j as usize] & 0xFFFFFFFFu64) as u32;
                if self.fx.rpo_of.len() > to as usize && self.fx.is_header(to) {
                    return true;
                }
            }
        }
        return false;
    }

    // Record the block's load `x` of a struct with an invariant at pointer `r` (`mi_lds`).
    fn mi_ld(self: &mut Self, r: u32, m: ModuleId, ty: TypeId, x: u32) {
        for q in 0..self.mi_lds.len() / 4 {
            if self.mi_lds[4 * q + 3] == x {
                return;
            }
        }
        self.mi_lds.push(r);
        self.mi_lds.push(m);
        self.mi_lds.push(ty);
        self.mi_lds.push(x);
    }

    // An allocator's call `t` that takes a value read from a struct the block loaded opens the struct
    // (`mi_open`): the block it frees or moves is the body's.
    fn mi_alloc_open(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        // The arguments' values: their reads record the loads (`mi_ld`).
        let mut args = Vector::<u32>::new();
        for j in 0..t.args_len {
            let oid = b.oper_pool[(t.args_start + j) as usize];
            if b.operands.at(oid as usize).kind == ir::OP_CONST {
                continue;
            }
            args.push(self.operand(b, b.module, &mut path.state, oid, false));
        }
        // A static of this file whose value an argument names (`static_val`).
        for q in 0..self.st_list.len() / 2 {
            let r = self.st_list[2 * q];
            let x = self.deref(&path.state, r, b.module, self.st_list[2 * q + 1]);
            let mut hit = false;
            for j in 0..args.len() {
                hit = hit || self.mentions_term(args[j], x, 6);
            }
            let mut open = false;
            for k in 0..self.mi_dirty.len() / 3 {
                open = open || self.mi_dirty[3 * k] == r;
            }
            if hit && !open {
                self.st_open(r, x, &path.state);
                self.mi_dirty.push(r);
                self.mi_dirty.push(b.module);
                self.mi_dirty.push(self.st_list[2 * q + 1]);
            }
        }
        let lds = self.mi_lds.clone();
        for q in 0..lds.len() / 4 {
            let (r, m, ty, x) = (lds[4 * q], lds[4 * q + 1] as ModuleId, lds[4 * q + 2], lds[4 * q + 3]);
            // Its value now: no memory event since the load.
            if self.deref(&path.state, r, m, ty) != x {
                continue;
            }
            let mut hit = false;
            for j in 0..args.len() {
                hit = hit || self.mentions_term(args[j], x, 6);
            }
            if hit {
                self.mi_open(r, m, ty, x, &path.state);
                let mut seen = false;
                for k in 0..self.mi_dirty.len() / 3 {
                    seen = seen || self.mi_dirty[3 * k] == r;
                }
                if !seen {
                    self.mi_dirty.push(r);
                    self.mi_dirty.push(m);
                    self.mi_dirty.push(ty);
                }
            }
        }
    }

    // Whether term `t` reaches term `x` within `depth` operands.
    fn mentions_term(self: &Self, t: u32, x: u32, depth: u32) bool {
        if t == x {
            return true;
        }
        if depth == 0 {
            return false;
        }
        let mut ops = Vector::<u32>::new();
        self.tm.operands(t, &mut ops);
        for j in 0..ops.len() {
            if self.mentions_term(ops[j], x, depth - 1) {
                return true;
            }
        }
        return false;
    }

    // The first write of the block to the struct at `r` (`old`, its value before, which holds its
    // invariant: memory's) opens it: its blocks are the body's until `mi_close`.
    fn mi_open(self: &mut Self, r: u32, m: ModuleId, ty: TypeId, old: u32, state: &Vector<u32>) {
        if self.st_inv.contains_key(&r) {
            self.st_open(r, old, state);
            return;
        }
        for q in 0..self.mi_dirty.len() / 3 {
            if self.mi_dirty[3 * q] == r {
                return;
            }
        }
        if self.decl_of(m, ty).0 != self.m {
            return;
        }
        // A block's bytes before its first write hold no value, so no blocks.
        if self.mi_fresh.contains(&r) {
            return;
        }
        let col = self.ov_col;
        let seen = replace(&mut self.ov_seen, Vector::<u32>::new());
        let shs = replace(&mut self.sh_seen, Vector::<u32>::new());
        let v1 = self.ov_new(OV_ADD, self.ov);
        self.ov = v1;
        self.ov_col = v1;
        let f = self.inv_of(m, ty, old, state);
        if f != NONE {
            self.anchor(old, f);
            // One value's blocks are distinct.
            self.src_mark(f, SRC_RES);
            self.sh_give(f);
        }
        let e = replace(&mut self.ov_seen, seen);
        self.ov_close(v1, &e);
        self.sh_seen = shs;
        self.ov_col = col;
    }

    // The dirty structs (`mi_dirty`): each one's invariant, of its value in memory now, an obligation at
    // `sp` (a terminator, or a write outside the struct's file), and a fact from there.
    // Before an assignment's write through pointer `r`, which ends the values the writes before it gave
    // the structs at other pointers (a new epoch): those structs (`mi_close`), at the assignment.
    fn mi_close_at(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, r: u32) {
        if self.wpc == null || self.mi_dirty.len() == 0 {
            return;
        }
        let mut keep = Vector::<u32>::new();
        let mut other = Vector::<u32>::new();
        for q in 0..self.mi_dirty.len() / 3 {
            let e = self.mi_dirty[3 * q..3 * q + 3];
            if self.mi_dirty[3 * q] == r || self.st_inv.contains_key(&self.mi_dirty[3 * q]) {
                keep.extend_from_slice(e);
            } else {
                other.extend_from_slice(e);
            }
        }
        if other.len() == 0 {
            return;
        }
        self.mi_dirty = other;
        let sp = self.wsp;
        self.mi_close(b, state, unsafe &mut *self.wpc, sp);
        self.mi_dirty = keep;
    }

    fn mi_close(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pc: &mut Vector<u32>, sp: tok::Span) {
        let ds = replace(&mut self.mi_dirty, Vector::<u32>::new());
        for q in 0..ds.len() / 3 {
            let (r, m, ty) = (ds[3 * q], ds[3 * q + 1] as ModuleId, ds[3 * q + 2]);
            let v = self.deref(state, r, m, ty);
            let f = if self.st_inv.contains_key(&r) {
                self.st_need(pc, r, v, state, 7 << 52 | sp.start as u64 << 8 | q as u64, sp)
            } else {
                self.inv_need(
                    b,
                    state,
                    pc,
                    ty,
                    v,
                    6 << 52 | sp.start as u64 << 8 | q as u64,
                    sp,
                    "after the writes through a pointer",
                )
            };
            // Memory holds the new value's blocks again.
            self.ov_take.clear();
            self.ov_take_sh.clear();
            self.ov_name(f, 0);
            let tk0 = self.ov_take.clone();
            self.lent_take(b, state, pc, &tk0, sp);
            self.ov_remove();
            if f != NONE {
                pc.push(f);
            }
        }
    }

    // A write of `v` to place `p` of static local `p.base` with an invariant (no dereference on its path):
    // its file opens it (`mi_open`) and closes it at the next call, drop, return or loop header
    // (`mi_close`); another file's write is an error (`st_err`). Whether it is a memory event.
    fn static_write(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, p: &ir::Place, v: u32) bool {
        for j in 0..p.proj_len {
            if cb.projections.at((p.proj_start + j) as usize).kind == ir::PJ_DEREF {
                return false;
            }
        }
        let r = self.static_addr(cb, p.base);
        if r == NONE {
            return false;
        }
        if (*self.st_inv.get(&r).unwrap() >> 32) as ModuleId != cb.module {
            self.st_err.push(r);
            return false;
        }
        let ty = cb.locals.at(p.base as usize).ty;
        let old = self.static_val(cb, cm, state, p.base, r);
        self.st_open(r, old, state);
        let nv = if p.proj_len == 0 {
            v
        } else {
            self.update(cb, cm, state, p, 0, old, pick(v == NONE, self.fresh(cm, p.ty), v), false)
        };
        self.mi_next.clear();
        self.mi_next.push(r);
        self.mi_next.push(nv);
        self.mi_next.push(cm);
        self.mi_next.push(ty);
        return true;
    }

    // The first write of the block to the static at `r` (`old`, its value before) opens it: the blocks
    // its invariant names are the body's until `mi_close`.
    fn st_open(self: &mut Self, r: u32, old: u32, state: &Vector<u32>) {
        for q in 0..self.mi_dirty.len() / 3 {
            if self.mi_dirty[3 * q] == r {
                return;
            }
        }
        let col = self.ov_col;
        let seen = replace(&mut self.ov_seen, Vector::<u32>::new());
        let shs = replace(&mut self.sh_seen, Vector::<u32>::new());
        let v1 = self.ov_new(OV_ADD, self.ov);
        self.ov = v1;
        self.ov_col = v1;
        let f = self.st_inv_of(r, old, state);
        self.anchor(old, f);
        self.src_mark(f, SRC_RES);
        self.sh_give(f);
        let e = replace(&mut self.ov_seen, seen);
        self.ov_close(v1, &e);
        self.sh_seen = shs;
        self.ov_col = col;
    }

    // The writes of statics of other files the last write found (`st_err`): errors at `sp`, as is any
    // reference to such a static (`static_ref`).
    fn st_report(self: &mut Self, pc: &Vector<u32>, sp: tok::Span) {
        if self.st_err.len() == 0 {
            return;
        }
        self.st_err.clear();
        let f = self.tm.boolean(false);
        self.oblige(
            pc,
            f,
            OB_TYPE_INV << 56 | 11 << 52 | sp.start as u64,
            sp,
            String::from_str("a static with an invariant is written in its own file"),
            String::from_str("its file proves the invariant after each write, and each read there assumes it"),
        );
    }

    // A reference to (or the address of) place `p` of a static with an invariant: an error at `sp`, since
    // a write through it would skip the invariant's check.
    fn static_ref(self: &mut Self, cb: &ir::CoreBody, pc: &Vector<u32>, p: &ir::Place, sp: tok::Span) {
        for j in 0..p.proj_len {
            if cb.projections.at((p.proj_start + j) as usize).kind == ir::PJ_DEREF {
                return;
            }
        }
        if self.static_addr(cb, p.base) == NONE && !self.static_tinv(cb, p.base) {
            return;
        }
        let f = self.tm.boolean(false);
        self.oblige(
            pc,
            f,
            OB_TYPE_INV << 56 | 12 << 52 | sp.start as u64,
            sp,
            String::from_str("a static with an invariant, or of a type with one, is read and written by name"),
            String::from_str(
                "a write through a reference would skip the invariant's check, and a callee given one assumes it",
            ),
        );
    }

    // The invariant of value `v` of the static at `r`, an obligation at `sp` after its writes (`mi_close`):
    // the fact, or NONE where it failed.
    fn st_need(self: &mut Self, pc: &Vector<u32>, r: u32, v: u32, state: &Vector<u32>, key: u64, sp: tok::Span) u32 {
        if self.ghost_fn || v == NONE {
            return NONE;
        }
        let f = self.st_inv_of(r, v, state);
        if pc.contains(&f) {
            return f;
        }
        let ok0 = !self.over && !(self.refining && !self.refine_all);
        let dm = (*self.st_inv.get(&r).unwrap() >> 32) as ModuleId;
        let a = self.ast_of(dm);
        let name = String::from_str(
            self.text(dm, a.at_const(a.at_const(*self.st_decl.get(&r).unwrap()).as_data.const_def.name).span),
        );
        self.inv_goal = true;
        self.oblige(
            pc,
            f,
            OB_TYPE_INV << 56 | key,
            sp,
            format("cannot prove the invariant of static '{}' here", name.as_str()),
            String::from_str(
                "a static's file proves its invariant after the code changes it (a write, an allocator's call on its blocks), at the next call, drop, return or loop header",
            ),
        );
        self.inv_goal = false;
        return pick(ok0 && !self.over && !self.failed.contains_key(&(OB_TYPE_INV << 56 | key)), f, NONE);
    }

    // `write_place` but for the memory event: whether the write is one. A loop's header forgets what an
    // iteration may write with it (`havoc_write`).
    fn write_at(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, pl: u32, v: u32, all: bool) bool {
        let p = *cb.places.at(pl as usize);
        if !all && !self.tracked[p.base as usize] {
            return self.static_write(cb, cm, state, &p, v);
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
            let sk = self.sq_of(r);
            if !all && (sk == SQ_EREF || sk == SQ_SEREF) {
                self.leak(v);
                self.elem_write(cb, cm, state, &p, dr, r, v);
                return false;
            }
            // Through a reference to a member: that member of its local or slot.
            if !all && x.op == T_PREF && !self.has_deref(cb, &p, dr + 1) && !self.mem_from(cb, &p, dr + 1) {
                let old = self.ref_get(state, r);
                let y = if v == NONE {
                    self.fresh_in(cm, p.ty, self.pref_union(r) || self.union_below(cb, &p, dr + 1))
                } else {
                    v
                };
                let nv = if old == NONE {
                    NONE
                } else {
                    self.update(cb, cm, state, &p, dr + 1, old, y, all)
                };
                if nv == NONE {
                    self.forget(cb, cm, state, self.ref_target(r));
                } else {
                    self.ref_set(cb, state, r, nv);
                }
                return false;
            }
            // Through a raw pointer into a block or an inline array: its element (`ptr_write`).
            if !all && dr + 1 == p.proj_len && x.op != T_MREF && x.op != T_REF && self.raw_ptr_ty(
                cm,
                self.proj_base_ty(cb, &p, dr),
            ) && self.ptr_write(cb, cm, state, r, NONE, v, p.ty) {
                return false;
            }
            if all || x.op != T_MREF || self.has_deref(cb, &p, dr + 1) {
                if !all {
                    self.leak(v);
                    // A value written through a raw pointer: its value after the write, which the memory
                    // event forwards (`write_place`); for a struct with an invariant, an invariant to prove.
                    let pty = cb.projections.at((p.proj_start + dr) as usize).ty;
                    let rty = if dr == 0 {
                        cb.locals.at(p.base as usize).ty
                    } else {
                        cb.projections.at((p.proj_start + dr - 1) as usize).ty
                    };
                    if self.raw_ptr_ty(cm, rty) && x.op != T_MREF && x.op != T_PREF && x.op != T_REF && !self.has_deref(
                        cb,
                        &p,
                        dr + 1,
                    ) && !self.mem_from(cb, &p, dr + 1) {
                        self.mi_close_at(cb, state, r);
                        let old = self.deref(state, r, cm, pty);
                        if self.mi_type(cm, pty) {
                            self.mi_open(r, cm, pty, old, state);
                            if !self.mi_wrote.contains(&r) {
                                self.mi_wrote.push(r);
                            }
                        }
                        if dr + 1 == p.proj_len {
                            self.unfresh(r);
                        }
                        let nv = if dr + 1 == p.proj_len {
                            v
                        } else {
                            self.update(cb, cm, state, &p, dr + 1, old, pick(v == NONE, self.fresh(cm, p.ty), v), all)
                        };
                        self.mi_next.clear();
                        self.mi_next.push(r);
                        self.mi_next.push(nv);
                        self.mi_next.push(cm);
                        self.mi_next.push(pty);
                    }
                }
                return true;
            }
            base = x.a;
            from = dr + 1;
        }
        // A write through a raw pointer that is no `@owned` field's: memory, but for an element of a block
        // or an inline array the pointer points into (`ptr_write`).
        for j in from..p.proj_len {
            if self.ptr_index(cb, cm, &p, j) == PI_MEM {
                if !all && j + 1 == p.proj_len {
                    let pv = self.read_prefix(cb, cm, state, &p, j, all);
                    let pj = *cb.projections.at((p.proj_start + j) as usize);
                    let bty = self.proj_base_ty(cb, &p, j);
                    let i = self.proj_key(cb, cm, state, &pj, bty, all);
                    if self.ptr_write(cb, cm, state, pv, i, v, p.ty) {
                        return false;
                    }
                    // The element's value after the write, as for a write through a dereference.
                    let addr = self.elem_addr(pv, i);
                    self.mi_close_at(cb, state, addr);
                    let old = self.deref(state, addr, cm, p.ty);
                    if self.mi_type(cm, p.ty) {
                        self.mi_open(addr, cm, p.ty, old, state);
                        if !self.mi_wrote.contains(&addr) {
                            self.mi_wrote.push(addr);
                        }
                    }
                    self.unfresh(addr);
                    self.mi_next.clear();
                    self.mi_next.push(addr);
                    self.mi_next.push(v);
                    self.mi_next.push(cm);
                    self.mi_next.push(p.ty);
                }
                if !all {
                    self.leak(v);
                }
                return true;
            }
        }
        if !all && self.is_mem[base as usize] && self.reached(base) {
            // A load may read this local's storage: it reads a new epoch.
            let n = state.len() - 1;
            let ep0 = state[n];
            state.set(n, self.tm.var(W_OTHER, false));
            self.keep_param_views(cb, cm, state, ep0, 0);
        }
        if from == p.proj_len {
            if v != NONE {
                state.set(base as usize, v);
            } else {
                self.forget(cb, cm, state, base);
            }
            return false;
        }
        let old = self.local_val(cb, cm, state, base);
        let x = if v == NONE {
            self.fresh_in(cm, p.ty, self.union_below(cb, &p, from))
        } else {
            v
        };
        let nv = self.update(cb, cm, state, &p, from, old, x, all);
        if nv == NONE {
            self.forget(cb, cm, state, base);
        } else {
            state.set(base as usize, nv);
        }
        return false;
    }

    // A write of `v` (NONE: unknown) to place `p` through element reference `r` (its prefix of `dr`
    // projections): the container's new view updates the element (an unknown one for a member of it).
    fn elem_write(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        p: &ir::Place,
        dr: u32,
        r: u32,
        v: u32,
    ) {
        let rt = self.tm.at(r);
        let a0 = self.tm.args[rt.a as usize];
        let i = self.tm.args[(rt.a + 1) as usize];
        let ety = cb.projections.at((p.proj_start + dr) as usize).ty;
        let (w, sg) = self.ty_of(cm, ety);
        let x = if v == NONE || dr + 1 != p.proj_len {
            self.tm.var(w, sg)
        } else {
            v
        };
        let mut xs = Vector::<u32>::new();
        if self.sq_of(r) == SQ_EREF {
            let cv = self.ref_get(state, a0);
            if cv == NONE {
                self.mem_event(cb, cm, state);
                return;
            }
            xs.push(self.view_v(cv));
            xs.push(i);
            xs.push(x);
            let nview = self.seq_make(SQ_UPD, &xs);
            let (tm0, ty) = self.ref_ty(cb, a0);
            let nv = self.fresh(tm0, ty);
            self.vdef.insert(nv, nview);
            self.ref_set(cb, state, a0, nv);
            return;
        }
        // Through a `[]mut T`: memory changes, and the slice's view in the new epoch is the update. Through
        // a `[]mut` parameter, the other parameters' views stay: no two exclusive borrows overlap.
        let ep0 = state[state.len() - 1];
        xs.push(self.view_s(a0, ep0));
        xs.push(i);
        xs.push(x);
        let nview = self.seq_make(SQ_UPD, &xs);
        self.mem_event(cb, cm, state);
        let mut own: u64 = 0;
        for l in cb.returns..cb.returns + cb.args {
            if state[l as usize] == a0 {
                own |= param_bit(cb, l);
            }
        }
        if own != 0 {
            self.keep_param_views(cb, cm, state, ep0, own);
        }
        let ep1 = state[state.len() - 1];
        self.sdef.insert(a0 as u64 << 32 | ep1 as u64, nview);
    }

    // Whether projection `pj` of a value of type `bty` (module `m`) is an `@owned` raw pointer field.
    fn owned_field(self: &Self, m: ModuleId, bty: TypeId, pj: &ir::Projection) bool {
        if pj.kind != ir::PJ_FIELD || pj.data == ir::PJ_UNION_FIELD || pj.sub == NODE_NONE || bty == TYPE_NONE {
            return false;
        }
        let y = *self.ast_of(m).type_at(bty);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(m, bty);
        return dn != NODE_NONE && self.pkg().modules.at(dm as usize).has_ast && self.ast_of(dm).attr_of(
            pj.sub,
            AttrKind::ATTR_OWNED,
        ) != null;
    }

    // The type place `p` of body `cb` has before its projection `j`.
    const fn proj_base_ty(self: &Self, cb: &ir::CoreBody, p: &ir::Place, j: u32) TypeId {
        return if j == 0 {
            cb.locals.at(p.base as usize).ty
        } else {
            cb.projections.at((p.proj_start + j - 1) as usize).ty
        };
    }

    // Whether a projection of place `p` from `from` on indexes a raw pointer that is no `@owned` field's
    // (PI_MEM): the place is memory, not its local.
    fn mem_from(self: &Self, cb: &ir::CoreBody, p: &ir::Place, from: u32) bool {
        for j in from..p.proj_len {
            if self.ptr_index(cb, cb.module, p, j) == PI_MEM {
                return true;
            }
        }
        return false;
    }

    // Projection `j` of place `p` indexes a raw pointer: PI_OWNED when the pointer is an `@owned` field
    // the projection before names (the element is a member of the struct's block, `own_key`), PI_MEM for
    // another pointer (memory); PI_NONE for another projection.
    // A write of the whole value at `r`: its bytes hold a value from here on.
    fn unfresh(self: &mut Self, r: u32) {
        for q in 0..self.mi_fresh.len() {
            if self.mi_fresh[q] == r {
                let _ = self.mi_fresh.swap_remove(q);
                return;
            }
        }
    }

    // The address of element `i` of raw pointer `p`: `p` itself for element 0.
    fn elem_addr(self: &mut Self, p: u32, i: u32) u32 {
        let x = self.tm.at(i);
        if x.op == T_INT && x.k.is_zero() {
            return p;
        }
        let mut xs = Vector::<u32>::with_capacity(2);
        xs.push(p);
        xs.push(i);
        return self.tm.call(skey_mix(7, 0), &xs, W_OTHER, false);
    }

    fn ptr_index(self: &Self, cb: &ir::CoreBody, cm: ModuleId, p: &ir::Place, j: u32) u8 {
        if j >= p.proj_len {
            return PI_NONE;
        }
        let pj = *cb.projections.at((p.proj_start + j) as usize);
        if pj.kind != ir::PJ_INDEX_OP && pj.kind != ir::PJ_INDEX_CONST {
            return PI_NONE;
        }
        let bty = self.proj_base_ty(cb, p, j);
        if bty == TYPE_NONE || self.ast_of(cm).type_at(bty).kind != TypeKind::TYPE_POINTER {
            return PI_NONE;
        }
        if j > 0 && self.owned_field(
            cm,
            self.proj_base_ty(cb, p, j - 1),
            cb.projections.at((p.proj_start + j - 1) as usize),
        ) {
            return PI_OWNED;
        }
        return PI_MEM;
    }

    // The member key of the block of `@owned` field `pj` of a value of type `bty`: the struct's ghost
    // member that holds the elements the field points to, apart from the pointer's own value.
    fn own_key(self: &mut Self, cm: ModuleId, bty: TypeId, pj: &ir::Projection) u32 {
        let ix = self.field_index(cm, bty, pj.sub);
        return self.tm.int(wide::<B>(pick(ix >= 0, ix, pj.sub)) + Num::<B>::one().shl(41), 64, false);
    }

    // The name of method `d` when it is a method of interface `hit` or of a conformance to it, else "".
    fn iface_method(self: &Self, d: DefId, hit: &loader::LookupHit) str {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || hit.node == NODE_NONE || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return "";
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return "";
        }
        let c = a.container_of(d.node);
        if c == NODE_NONE {
            return "";
        }
        let mut ours = d.module == hit.mid && c == hit.node;
        if !ours && a.at_const(c).kind == NodeKind::NODE_EXTEND {
            let it = a.ext(c).extend_def.interface_type;
            if it != NODE_NONE {
                let r = a.resolution_def(it);
                ours = r.module == hit.mid && r.node == hit.node;
            }
        }
        if !ours {
            return "";
        }
        return self.text(d.module, a.at_const(a.ext_name(d.node)).span);
    }

    // The definition of interface spec function `d` in the conformance of type `t` (module `m`, a type that
    // names no parameter) to `d`'s interface, with the bindings of that `extend`'s parameters into `binds`;
    // none where no conformance of the type's declaration defines it. Memoized (`conf_memo`).
    fn spec_conf(self: &mut Self, d: DefId, m: ModuleId, t: TypeId, binds: &mut Vector<u64>) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return none;
        }
        let ia = self.ast_of(d.module);
        let ic = ia.container_of(d.node);
        if ic == NODE_NONE || ia.at_const(ic).kind != NodeKind::NODE_INTERFACE || ia.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return none;
        }
        let (dm, dn) = self.decl_of(m, t);
        if dn == NODE_NONE {
            return none;
        }
        let mk = skey_mix(skey_mix(0, d.module as u64 << 32 | d.node as u64), dm as u64 << 32 | dn as u64);
        let found = if let Some(v) = self.conf_memo.get(&mk) {
            DefId { module: (*v >> 32) as ModuleId, node: (*v & 0xFFFFFFFFu64) as NodeId }
        } else {
            let f = self.find_conf(d, ic, dm, dn);
            self.conf_memo.insert(mk, f.module as u64 << 32 | f.node as u64);
            f
        };
        if found.node == NODE_NONE {
            return none;
        }
        // The extend's parameters from the type: `extend<A> P<A> as I` at `P<Global>`.
        let fa = self.ast_of(found.module);
        let e = fa.container_of(found.node);
        let eg = fa.ext(e).extend_def.generics;
        if eg.len != 0 {
            let tt = fa.type_of(fa.ext(e).extend_def.target_type);
            if tt == TYPE_NONE {
                return none;
            }
            self.unify(found.module, tt, m, t, binds, 0);
            for j in 0..eg.len {
                if !binds.contains(&(found.module as u64 << 32 | (unsafe fa.list(eg)[j as usize]) as u64)) {
                    return none;
                }
            }
        }
        return found;
    }

    // The function named as interface member `d` (of interface `ic`) in an `extend` of declaration
    // `(dm, dn)` as that interface, in any module.
    fn find_conf(self: &Self, d: DefId, ic: NodeId, dm: ModuleId, dn: NodeId) DefId {
        let ia = self.ast_of(d.module);
        let name = self.text(d.module, ia.at_const(ia.ext_name(d.node)).span);
        let p = self.pkg();
        for mi in 0..p.modules.len() {
            if !p.modules.at(mi).has_ast {
                continue;
            }
            let a = self.ast_of(mi as ModuleId);
            for k in p.idx().mod_items[mi]..p.idx().mod_items[mi + 1] {
                let it = *p.idx().items.at(k as usize);
                if it.owner == loader::ITEM_NONE {
                    continue;
                }
                let e = p.idx().items.at(it.owner as usize).node;
                if a.at_const(e).kind != NodeKind::NODE_EXTEND || a.ext(e).extend_def.interface_type == NODE_NONE || a.at_const(
                    it.node,
                ).kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let idef = a.resolution_def(a.ext(e).extend_def.interface_type);
                if idef.module != d.module || idef.node != ic {
                    continue;
                }
                let tdef = a.resolution_def(a.ext(e).extend_def.target_type);
                if tdef.module != dm || tdef.node != dn {
                    continue;
                }
                if self.text(mi as ModuleId, a.at_const(a.ext_name(it.node)).span) == name {
                    return DefId { module: mi as ModuleId, node: it.node };
                }
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // The kind of an allocator method `d` is (AK_*): `alloc`, `realloc` or `dealloc` of the `Allocator`
    // interface, or of a conformance to it.
    // Whether allocator call `t` of body `b` is a method of the prelude's `Global`: through its own
    // conformance or the interface at that receiver.
    fn global_alloc(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let g = self.globall;
        if g.node == NODE_NONE {
            return false;
        }
        if t.recv != TYPE_NONE {
            let (m2, t2) = self.resolve(b.module, t.recv);
            let (dm, dd) = self.decl_of(m2, t2);
            if dm == g.mid && dd == g.node {
                return true;
            }
        }
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        let c = a.container_of(d.node);
        if c == NODE_NONE || a.at_const(c).kind != NodeKind::NODE_EXTEND {
            return false;
        }
        let (dm, dd) = self.decl_of(d.module, a.type_of(a.ext(c).extend_def.target_type));
        return dm == g.mid && dd == g.node;
    }

    fn alloc_call(self: &Self, d: DefId) u32 {
        let nm = self.iface_method(d, &self.allocl);
        return if nm == "alloc" {
            AK_ALLOC
        } else if nm == "realloc" {
            AK_REALLOC
        } else if nm == "dealloc" {
            AK_DEALLOC
        } else {
            AK_NONE
        };
    }

    // Whether constant `c` (operand type `ty`) of body `cb` is `null`: of a pointer type, or the literal,
    // which keeps no type of its own.
    fn null_const(self: &Self, cb: &ir::CoreBody, cm: ModuleId, c: &ir::Constant, ty: TypeId) bool {
        let cty = pick(ty != TYPE_NONE, ty, c.ty);
        if cty != TYPE_NONE {
            return self.ast_of(cm).type_at(cty).kind == TypeKind::TYPE_POINTER;
        }
        let sm = pick(c.item.node != NODE_NONE, c.item.module, cb.module);
        return c.raw.end == c.raw.start + 4 && self.text(sm, c.raw) == "null";
    }

    // `sizeof(ty)`, a `usize`: its value where the layout knows it, else one unknown per type.
    fn size_term(self: &mut Self, m: ModuleId, ty: TypeId) u32 {
        let (rm, rt) = self.resolve(m, ty);
        let l = self.lsv.layout(rm, rt);
        if l.ok {
            return self.tm.int(wide::<B>(l.size as i64), self.pw, false);
        }
        let none = Vector::<u32>::new();
        let key = skey_mix(9, self.type_key(rm, rt, 0));
        let t = self.tm.call(key, &none, self.pw, false);
        // No type is larger than `isize::MAX` bytes.
        if !self.seld.contains_key(&t) {
            self.seld.insert(t, true);
            let imax = self.tm.int(wide::<B>(((1u64 << self.pw - 1) - 1) as i64), self.pw, false);
            let f = self.tm.cmp(T_LE, t, imax);
            self.anchor(t, f);
        }
        return t;
    }

    // `alignof(ty)` (module `m`): the layout's where it is known, else a term per type that is a power of
    // two (at least 1, no bit in common with itself minus 1).
    fn align_term(self: &mut Self, m: ModuleId, ty: TypeId) u32 {
        let (rm, rt) = self.resolve(m, ty);
        let l = self.lsv.layout(rm, rt);
        if l.ok {
            return self.tm.int(wide::<B>(l.align as i64), self.pw, false);
        }
        let none = Vector::<u32>::new();
        let key = skey_mix(15, self.type_key(rm, rt, 0));
        let t = self.tm.call(key, &none, self.pw, false);
        if !self.seld.contains_key(&t) {
            self.seld.insert(t, true);
            // At least the alignment of each member whose layout is known (a pointer in a generic struct).
            let mut lo: u64 = 1;
            let mut mts = Vector::<u64>::new();
            self.member_types(rm, rt, &mut mts);
            for j in 0..mts.len() {
                let ml = self.lsv.layout((mts[j] >> 32) as ModuleId, (mts[j] & 0xFFFFFFFFu64) as TypeId);
                if ml.ok && ml.align > lo {
                    lo = ml.align;
                }
            }
            let lo_t = self.tm.int(wide::<B>(lo as i64), self.pw, false);
            let mut f = self.tm.cmp(T_LE, lo_t, t);
            // In the program's arithmetic and in a clause's exact one.
            for wi in 0..2 {
                let (w, sg) = if wi == 0 {
                    (self.pw, false)
                } else {
                    (W_INT, true)
                };
                let one_w = self.tm.int(Num::<B>::one(), w, sg);
                let t1 = self.tm.arith(T_SUB, t, one_w, w, sg);
                let low = self.tm.arith(T_BAND, t, t1, w, sg);
                let z = self.tm.int(Num::<B>::zero(), w, sg);
                f = self.tm.and(f, self.tm.cmp(T_EQ, low, z));
            }
            self.anchor(t, f);
        }
        return t;
    }

    // The address of pointer `p` (`p as usize`): 0 exactly for null.
    fn ptr_addr(self: &mut Self, p: u32) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(p);
        let r = self.tm.call(skey_mix(18, 0), &xs, self.pw, false);
        if !self.ptrd.contains_key(&r) {
            self.ptrd.insert(r, true);
            let nl = self.null_ptr();
            let isn = self.tm.cmp(T_EQ, p, nl);
            let z = self.tm.int(Num::<B>::zero(), self.pw, false);
            let az = self.tm.cmp(T_EQ, r, z);
            let mut f = self.tm.cmp(T_EQ, isn, az);
            // A pointer is its address: the pointer at this address (`ptr_at`) is `p`, so a pointer at an
            // address equal to this one is `p` too. The term is made here, as `ptr_at` folds it to `p`.
            let px = self.tm.at(p);
            if px.op != T_CALL || px.b != 1 || px.k != u64_val::<B>(skey_mix(17, 0)) {
                let mut ys = Vector::<u32>::new();
                ys.push(r);
                let back = self.tm.call(skey_mix(17, 0), &ys, W_OTHER, false);
                f = self.tm.and(f, self.tm.cmp(T_EQ, back, p));
            }
            self.anchor(r, f);
        }
        return r;
    }

    // Pointer `p` moved by `n` elements of `es` bytes (`op` T_ADD or T_SUB). Arithmetic stays inside its
    // object (operations.md: else undefined), and no object is at address 0: a pointer that is not null
    // moves to one that is not, by `n * es` bytes with no wrap.
    fn ptr_offset(self: &mut Self, op: u8, p: u32, n: u32, es: u32) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(p);
        xs.push(n);
        xs.push(es);
        let r = self.tm.call(skey_mix(16, op), &xs, W_OTHER, false);
        if !self.ptrd.contains_key(&r) {
            self.ptrd.insert(r, true);
            let nl = self.null_ptr();
            let a = self.tm.cmp(T_EQ, p, nl);
            let c = self.tm.cmp(T_NE, r, nl);
            let nn = self.tm.or(a, c);
            let ar = self.ptr_addr(r);
            let ap = self.ptr_addr(p);
            let wr = self.widened(ar, W_INT, true);
            let wp = self.widened(ap, W_INT, true);
            let wn = self.widened(n, W_INT, true);
            let we = self.widened(es, W_INT, true);
            let mut f = if wr != NONE && wp != NONE && wn != NONE && we != NONE {
                let d = self.tm.arith(T_MUL, wn, we, W_INT, true);
                let s = self.tm.arith(op, wp, d, W_INT, true);
                let at = self.tm.cmp(T_EQ, wr, s);
                self.tm.and(nn, at)
            } else {
                nn
            };
            // The same address in the pointer's width, whose bits the SAT refutations take (they take no
            // exact integer): a terms' value is exact at every width, and an offset in bounds does not wrap.
            let xn = self.tm.at(n);
            let xe = self.tm.at(es);
            if xn.w == self.pw && !xn.sg && xe.w == self.pw && !xe.sg {
                let d = self.tm.arith(T_MUL, n, es, self.pw, false);
                let s = self.tm.arith(op, ap, d, self.pw, false);
                f = self.tm.and(f, self.tm.cmp(T_EQ, ar, s));
            }
            self.anchor(r, f);
        }
        return r;
    }

    // The pointer at address `a` (`std::mem::ptr::from_addr_mut`): `p` at the address of `p`, where the
    // address comes from.
    fn ptr_at(self: &mut Self, a: u32) u32 {
        let x = self.tm.at(a);
        if x.op == T_CALL && x.b == 1 && x.k == u64_val::<B>(skey_mix(18, 0)) {
            return self.tm.args[x.a as usize];
        }
        let mut xs = Vector::<u32>::new();
        xs.push(a);
        let r = self.tm.call(skey_mix(17, 0), &xs, W_OTHER, false);
        if !self.ptrd.contains_key(&r) {
            self.ptrd.insert(r, true);
            let ar = self.ptr_addr(r);
            let f = self.tm.cmp(T_EQ, ar, a);
            self.anchor(r, f);
        }
        return r;
    }

    // The identity of type `ty` of module `m` (`subst` applied) in a term's key: a type parameter by its
    // declaration, an instance, a pointer, a reference, a view or an array by its parts, so that the ids
    // that name one type are one key; another type by its id. `depth` levels deep.
    fn type_key(self: &Self, m: ModuleId, ty: TypeId, depth: u32) u64 {
        let (rm, rt) = self.resolve(m, ty);
        if rt == TYPE_NONE || depth > 6 {
            return skey_mix(rm, rt);
        }
        let y = *self.ast_of(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_GENERIC {
            return skey_mix(10, y.module as u64 << 32 | y.as_data.decl as u64);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(rm).instance(y.as_data.inst);
            let mut k = skey_mix(11, it.module as u64 << 32 | it.decl as u64);
            for i in 0..it.n {
                k = skey_mix(k, self.type_key(rm, it.args[i as usize], depth + 1));
            }
            return k;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE {
            return skey_mix(
                skey_mix(12, y.kind as u64 << 8 | y.qualifier as u64),
                self.type_key(rm, y.as_data.elem, depth + 1),
            );
        }
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            return skey_mix(skey_mix(13, y.as_data.arr.len), self.type_key(rm, y.as_data.arr.elem, depth + 1));
        }
        // A builtin by its kind (`*mut void` of two modules is one type), a struct or an enum by its
        // declaration; a pattern type by its id.
        if !y.has_pat() && y.kind == TypeKind::TYPE_BUILTIN {
            return skey_mix(skey_mix(14, 0), (unsafe y.as_data.builtin) as u64);
        }
        if !y.has_pat() && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM) {
            return skey_mix(skey_mix(15, 0), y.module as u64 << 32 | y.as_data.decl as u64);
        }
        return skey_mix(rm, rt);
    }

    // The null pointer: one term, whatever its pointee type.
    fn null_ptr(self: &mut Self) u32 {
        let none = Vector::<u32>::new();
        return self.tm.call(skey_mix(8, 0), &none, W_OTHER, false);
    }

    // The block an `@owned` field holds once it is set to pointer `v`, of elements of type `et` (module
    // `m`): none for null; for an allocator's result one of the size it asked over the element's
    // (`alloc_of`); else unknown.
    fn own_after(self: &mut Self, m: ModuleId, et: TypeId, v: u32) u32 {
        if v == self.null_ptr() {
            let none = Vector::<u32>::new();
            return self.seq_make(SQ_EMPTY, &none);
        }
        // A block a copy wrote before a field held it (`mem_copy`).
        let pb = self.pend_get(v);
        if pb != NONE {
            return pb;
        }
        let s = self.tm.var(W_OTHER, false);
        let ix = switch self.alloc_of.get(&v) {
            Some(i) => (*i) as usize,
            None => {
                return self.zst_block(m, et, s);
            },
        };
        let (kind, size, old, dir, prod) = (
            self.alloc_rec[ix],
            self.alloc_rec[ix + 1],
            self.alloc_rec[ix + 2],
            self.alloc_rec[ix + 3],
            self.alloc_rec[ix + 4]
        );
        if size == NONE || et == TYPE_NONE {
            return s;
        }
        let sz = self.widened(size, W_INT, true);
        if sz == NONE {
            return s;
        }
        let k = self.widened(self.size_term(m, et), W_INT, true);
        // A `realloc` of a known block keeps its elements: the old block and new ones after it, or its first
        // elements, as the call's path decided (`adir`).
        let blk = if kind == AK_REALLOC && old != NONE && dir == 1 {
            self.cat_seq(old, s)
        } else if kind == AK_REALLOC && old != NONE && dir == 2 {
            let z = self.tm.int(Num::<B>::zero(), W_INT, true);
            let n0 = self.tm.var(W_NAT, false);
            let nb = self.tm.arith(T_MUL, n0, k, W_INT, true);
            let f0 = self.tm.cmp(T_EQ, nb, sz);
            self.anchor(n0, f0);
            self.sub_seq(old, z, n0)
        } else {
            s
        };
        // A size `sizeof(T)` holds one element, `x * sizeof(T)` holds `x` (any number of zero-sized ones),
        // another size its length times the element's.
        let n = self.seq_len(blk);
        let st = self.tm.at(size);
        let et_size = self.size_term(m, et);
        let f = if size == et_size {
            let one = self.tm.int(Num::<B>::one(), W_INT, true);
            self.tm.cmp(T_EQ, n, one)
        } else if st.op == T_MUL && (st.b == et_size || st.a == et_size) {
            let x = self.widened(pick(st.b == et_size, st.a, st.b), W_INT, true);
            if x == NONE {
                self.tm.boolean(true)
            } else {
                self.tm.cmp(T_EQ, n, x)
            }
        } else if self.product_count(prod, k) != NONE {
            self.tm.cmp(T_EQ, n, self.product_count(prod, k))
        } else {
            let bytes = self.tm.arith(T_MUL, n, k, W_INT, true);
            self.tm.cmp(T_EQ, bytes, sz)
        };
        self.anchor(blk, f);
        // A goal over the moved block names the parts of its length (`seq_len` of a concatenation): the
        // fact rides on the new elements too.
        if blk != s {
            self.anchor(s, f);
        }
        return blk;
    }

    // The product `x * y` that a fact of path `pc` equates with allocation size `size` (as an `int`: the
    // `ensures` of a function that computes a byte size); NONE where none does.
    fn size_product(self: &mut Self, pc: &Vector<u32>, size: u32) u32 {
        if size == NONE {
            return NONE;
        }
        let sz = self.widened(size, W_INT, true);
        if sz == NONE {
            return NONE;
        }
        let mut parts = Vector::<u32>::new();
        for j in 0..pc.len() {
            parts.clear();
            self.conjuncts(pc[j], &mut parts, 0);
            for q in 0..parts.len() {
                let e = self.tm.at(parts[q]);
                if e.op != T_EQ {
                    continue;
                }
                let o = if e.a == sz {
                    e.b
                } else if e.b == sz {
                    e.a
                } else {
                    NONE
                };
                if o != NONE && self.tm.at(o).op == T_MUL && self.tm.at(o).w == W_INT {
                    return o;
                }
            }
        }
        return NONE;
    }

    // The other factor of product `prod` (`size_product`) when one factor is `k`; NONE otherwise.
    const fn product_count(self: &Self, prod: u32, k: u32) u32 {
        if prod == NONE || k == NONE {
            return NONE;
        }
        let x = self.tm.at(prod);
        return if x.a == k {
            x.b
        } else if x.b == k {
            x.a
        } else {
            NONE
        };
    }

    // Block `s` of another pointer, of elements of type `et`: unknown, of `usize::MAX` elements when they
    // are zero-sized (an access to one reads no memory).
    fn zst_block(self: &mut Self, m: ModuleId, et: TypeId, s: u32) u32 {
        if et == TYPE_NONE {
            return s;
        }
        let es = self.size_term(m, et);
        let z = self.tm.int(Num::<B>::zero(), self.tm.at(es).w, false);
        let nz = self.tm.cmp(T_NE, es, z);
        let (_lo, hi) = Terms::<B>::range(self.pw, false);
        let mx = self.tm.int(hi, W_INT, true);
        let n = self.seq_len(s);
        let full = self.tm.cmp(T_EQ, n, mx);
        let f = self.tm.or(nz, full);
        self.anchor(s, f);
        return s;
    }

    // The accesses to `@owned` blocks since the last check: each index is below its block's length, an
    // obligation of a body the walk proves (an access outside the block is undefined), and a fact of the
    // path from here on (a write keeps the block's length: `seq_make`'s guard holds).
    fn own_check(self: &mut Self, pc: &mut Vector<u32>, sp: tok::Span) {
        if self.facts_only || self.ghost_fn && !self.in_ghost {
            self.own_chk.clear();
            return;
        }
        let mut j: usize = 0;
        while j + 2 < self.own_chk.len() {
            let i = self.sq_index(self.own_chk[j]);
            let n = self.seq_len(self.own_chk[j + 1]);
            let z = self.tm.int(Num::<B>::zero(), W_INT, true);
            let lo = self.tm.cmp(T_LE, z, i);
            let hi = self.tm.cmp(T_LT, i, n);
            // An element of no bytes occupies no memory: any index of it is inside the block.
            let es = self.own_chk[j + 2];
            let zs = self.tm.int(Num::<B>::zero(), self.tm.at(es).w, false);
            let none = self.tm.cmp(T_EQ, es, zs);
            let inb = self.tm.and(lo, hi);
            let g = self.tm.or(inb, none);
            // An element of an inline array a raw pointer points into (`ptr_elem`): its view's.
            let arr = self.sq_of(self.own_chk[j + 1]) == SQ_VIEWA;
            self.oblige(
                pc,
                g,
                OB_BLOCK << 56 | (j / 3) as u64 << 32 | sp.start as u64,
                sp,
                format(
                    "{}",
                    pick(
                        arr,
                        "cannot prove that this index is inside the array the pointer points into",
                        "cannot prove that this index is inside the block of the '@owned' field",
                    ),
                ),
                String::from_str(
                    pick(
                        arr,
                        "the pointer is the address of an element of the array: the index must stay below its length",
                        "the elements of the block are 'std::spec::seq::block(ptr)': the index must be below its length",
                    ),
                ),
            );
            pc.push(g);
            j += 3;
        }
        self.own_chk.clear();
    }

    // The locals and slots of body `b` whose code, outside its contracts and its ghost code, reads the
    // pointer of an `@owned` field of theirs as a value (`own_exp`): a copy of it may reach the block. Under
    // the field's promise no other pointer does while a reference to the struct lives.
    fn own_scan(self: &mut Self, b: &ir::CoreBody) {
        self.own_exp.clear();
        self.own_exp.resize_default(b.locals.len() + self.slot_ty.len());
        let nb = b.blocks.len();
        let mut spec = Vector::<u64>::new();
        spec.resize_default((nb + 63) / 64);
        for j in 0..b.contracts.len() {
            ir::site_mark(b, b.contracts[j], &mut spec);
        }
        let mut ops = Vector::<u32>::new();
        for bi in 0..nb {
            if ir::in_blocks(&spec, bi as u32) {
                continue;
            }
            let bb = *b.blocks.at(bi);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let rv = *b.rvalues.at(st.rvalue as usize);
                if tcl::rv_place(&rv) {
                    self.own_mark(b, rv.a);
                }
                // A borrow of an element of an `@owned` block reaches the block, not the struct.
                if (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR) && self.owned_elem(b, b.places.at(rv.a as usize)) {
                    self.own_expose(b, rv.a);
                }
                tcl::rv_operands(b, &rv, &mut ops);
                for k in 0..ops.len() {
                    self.own_mark_op(b, ops[k]);
                }
            }
            let t = bb.term;
            if (t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT) && t.a != ir::IR_NONE {
                self.own_mark_op(b, t.a);
            } else if t.kind == ir::TM_CALL {
                for k in 0..t.args_len {
                    self.own_mark_op(b, b.oper_pool[(t.args_start + k) as usize]);
                }
            }
        }
    }

    fn own_mark_op(self: &mut Self, b: &ir::CoreBody, o: u32) {
        if o != ir::IR_NONE && b.operands.at(o as usize).kind != ir::OP_CONST {
            self.own_mark(b, b.operands.at(o as usize).data);
        }
    }

    // Place `pl` of body `b` reads an `@owned` field's pointer (no index of its block follows): its local,
    // or the slot of the `&mut` parameter it goes through, is `own_exp`.
    fn own_mark(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let p = *b.places.at(pl as usize);
        for j in 0..p.proj_len {
            let pj = *b.projections.at((p.proj_start + j) as usize);
            if self.owned_field(b.module, self.proj_base_ty(b, &p, j), &pj) && self.ptr_index(b, b.module, &p, j + 1) != PI_OWNED {
                let deref0 = p.proj_len != 0 && b.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF;
                let sl = self.slot_of[p.base as usize];
                let at = if deref0 && sl != NONE {
                    sl as usize
                } else {
                    p.base as usize
                };
                self.own_exp.set(at, true);
                return;
            }
        }
    }

    // The local, or the slot of the `&mut` parameter it goes through, of owned element place `pl`
    // (`owned_elem`): its blocks are `own_exp`.
    const fn own_expose(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let p = *b.places.at(pl as usize);
        let deref0 = p.proj_len != 0 && b.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF;
        let sl = self.slot_of[p.base as usize];
        self.own_exp.set(pick(deref0 && sl != NONE, sl as usize, p.base as usize), true);
    }

    // Value `v` of type `ty` with the blocks of its `@owned` fields, and of its members', unknown: a write
    // through another pointer, or code the walk does not see, may have changed them.
    fn own_forget(self: &mut Self, m: ModuleId, ty: TypeId, v: u32, depth: u32) u32 {
        if v == NONE || ty == TYPE_NONE || depth > 2 {
            return v;
        }
        let y = *self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return v;
        }
        let (dm, dn) = self.decl_of(m, ty);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return v;
        }
        let ag = unsafe self.ast_of(dm).ext(dn).aggregate;
        if ag.is_tuple {
            return v;
        }
        let mut mts = Vector::<u64>::new();
        self.member_types(m, ty, &mut mts);
        let mut out = v;
        for j in 0..ag.members.len {
            let f = unsafe self.ast_of(dm).list(ag.members)[j as usize];
            if self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) != null {
                // A write through a copy of the field changes the elements; only an allocator, whose calls
                // keep the blocks, changes the length.
                let k = self.tm.int(wide::<B>(j) + Num::<B>::one().shl(41), 64, false);
                let old = self.sel(out, k, W_OTHER, false);
                out = self.tm.upd(out, k, self.same_len(old));
            } else if j as usize < mts.len() && self.holds_owned(
                (mts[j as usize] >> 32) as ModuleId,
                (mts[j as usize] & 0xFFFFFFFFu64) as TypeId,
                depth + 1,
            ) {
                // A member that holds such a field (`String`'s union): its blocks too, which are no bytes of a
                // union (its other members stay).
                let (fm, ft) = ((mts[j as usize] >> 32) as ModuleId, (mts[j as usize] & 0xFFFFFFFFu64) as TypeId);
                let fk = self.tm.int(wide::<B>(j), 64, false);
                let sub = self.sel(out, fk, W_OTHER, false);
                let ns = self.own_forget(fm, ft, sub, depth + 1);
                out = self.tm.upd(out, fk, ns);
            }
        }
        return out;
    }

    // Whether a value of type `ty` (module `m`) holds an `@owned` field, `depth` levels of members deep at
    // most (`own_forget`).
    fn holds_owned(self: &Self, m: ModuleId, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE || depth > 2 {
            return false;
        }
        let y = *self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(m, ty);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        let ag = unsafe self.ast_of(dm).ext(dn).aggregate;
        let mut mts = Vector::<u64>::new();
        self.member_types(m, ty, &mut mts);
        for j in 0..ag.members.len {
            let f = unsafe self.ast_of(dm).list(ag.members)[j as usize];
            if self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) != null {
                return true;
            }
            if j as usize < mts.len() && self.holds_owned(
                (mts[j as usize] >> 32) as ModuleId,
                (mts[j as usize] & 0xFFFFFFFFu64) as TypeId,
                depth + 1,
            ) {
                return true;
            }
        }
        return false;
    }

    // A block of the length of block `old` whose elements are unknown.
    fn same_len(self: &mut Self, old: u32) u32 {
        let s = self.tm.var(W_OTHER, false);
        let n0 = self.seq_len(old);
        let n1 = self.seq_len(s);
        let f = self.tm.cmp(T_EQ, n1, n0);
        self.anchor(s, f);
        return s;
    }

    // An iteration of the loop the header scans may write place `pl` (`write_at` with an unknown value,
    // any element where it indexes): whether the write is a memory event.
    fn havoc_write(self: &mut Self, b: &ir::CoreBody, state: &mut Vector<u32>, pl: u32) bool {
        self.havoc_idx = true;
        let m = self.write_at(b, b.module, state, pl, NONE, false);
        self.havoc_idx = false;
        return m;
    }

    const fn has_deref(self: &Self, cb: &ir::CoreBody, p: &ir::Place, from: u32) bool {
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
        let bty = self.proj_base_ty(cb, p, from);
        // A loop's write (`havoc_write`): the index one iteration computes is another's, so any element of
        // the array, or of the `@owned` block (its length kept), may change.
        if self.havoc_idx && self.ptr_index(cb, cm, p, from) == PI_OWNED {
            return self.same_len(old);
        }
        if self.havoc_idx && pj.kind == ir::PJ_INDEX_OP {
            return self.fresh_in(cm, bty, self.union_below(cb, p, 0));
        }
        // An element of an `@owned` block: the sequence with it replaced, at an index below its length.
        if self.ptr_index(cb, cm, p, from) == PI_OWNED {
            let i = self.proj_key(cb, cm, state, &pj, bty, all);
            let (w, sg) = self.ty_of(cm, pj.ty);
            if !all {
                self.own_chk.push(i);
                self.own_chk.push(old);
                self.own_chk.push(self.size_term(cm, pj.ty));
            }
            let e = self.seq_at(old, i, w, sg);
            let inner = self.update(cb, cm, state, p, from + 1, e, v, all);
            if inner == NONE {
                return NONE;
            }
            let mut xs = Vector::<u32>::new();
            xs.push(old);
            xs.push(self.sq_index(i));
            xs.push(inner);
            return self.seq_make(SQ_UPD, &xs);
        }
        let own = self.ptr_index(cb, cm, p, from + 1) == PI_OWNED;
        // The pointer of an `@owned` field: its block changes with it (`own_after`).
        if from + 1 == p.proj_len && self.owned_field(cm, bty, &pj) {
            let fk = self.proj_key(cb, cm, state, &pj, bty, all);
            let ok = self.own_key(cm, bty, &pj);
            let et = self.ast_of(cm).type_at(pj.ty).as_data.elem;
            let no = self.own_after(cm, et, v);
            let nv = self.tm.upd(old, fk, v);
            return self.tm.upd(nv, ok, no);
        }
        let key = if own {
            self.own_key(cm, bty, &pj)
        } else {
            self.proj_key(cb, cm, state, &pj, bty, all)
        };
        let (w, sg) = if own {
            (W_OTHER, false)
        } else {
            self.ty_of(cm, pj.ty)
        };
        let sub = self.sel(old, key, w, sg);
        let inner = self.update(cb, cm, state, p, from + 1, sub, v, all);
        if inner == NONE {
            return NONE;
        }
        // A union member: the other members are what its bytes make of them (`union_coherence`); a write
        // into the block of one of its `@owned` fields changes none of its bytes.
        let mut blk = false;
        for j in from + 1..p.proj_len {
            blk = blk || self.ptr_index(cb, cm, p, j) == PI_OWNED;
        }
        if pj.kind == ir::PJ_FIELD && pj.data == ir::PJ_UNION_FIELD && !blk {
            let fresh = self.tm.var(W_OTHER, false);
            let nu = self.tm.upd(fresh, key, inner);
            self.union_coherence(cm, bty, nu);
            return nu;
        }
        return self.tm.upd(old, key, inner);
    }

    // `forget` each local of `ls`.
    fn forget_all(self: &mut Self, cb: &ir::CoreBody, state: &mut Vector<u32>, ls: &Vector<u32>) {
        for j in 0..ls.len() {
            self.forget(cb, cb.module, state, ls[j]);
        }
    }

    // Local `l` of body `cb` holds an unknown value from here on. The value is made now, not at the
    // next read: a chain reads a copy of the state, and the body must read the same value after it.
    fn forget(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, l: u32) {
        let ty = if l as usize >= cb.locals.len() {
            self.slot_ty[l as usize - cb.locals.len()]
        } else {
            cb.locals.at(l as usize).ty
        };
        let v = self.fresh(cm, ty);
        state.set(l as usize, v);
    }

    // Whether reference `v` (`T_PREF`) goes through the block of an `@owned` field (`own_key`).
    const fn pref_in_block(self: &Self, v: u32) bool {
        let x = self.tm.at(v);
        if x.op != T_PREF {
            return false;
        }
        let e = x.a as usize;
        let (a0, n) = (self.pref_at[e], self.pref_n[e]);
        let ob = Num::<B>::one().shl(41);
        for q in a0..a0 + n {
            let k = self.tm.at(self.pref_key[q as usize]);
            if k.op == T_INT && !(k.k < ob) {
                return true;
            }
        }
        return false;
    }

    // The reference to the inline array member whose element reference `v` (`T_PREF`) names; NONE for
    // another reference, or for an element of a whole local (which `escape` covers).
    fn pref_array(self: &mut Self, v: u32) u32 {
        let x = self.tm.at(v);
        if x.op != T_PREF {
            return NONE;
        }
        let e = x.a as usize;
        let n = self.pref_n[e];
        if n < 2 {
            return NONE;
        }
        let (am, aty) = self.pref_cty(e, n - 1);
        let (m1, t1) = self.resolve(am, aty);
        if self.ast_of(m1).type_at(t1).kind != TypeKind::TYPE_ARRAY {
            return NONE;
        }
        let start = self.pref_key.len() as u32;
        let a0 = self.pref_at[e];
        for q in a0..a0 + n - 1 {
            self.pref_key.push(self.pref_key[q as usize]);
            self.pref_ty.push(self.pref_ty[q as usize]);
            self.pref_km.push(self.pref_km[q as usize]);
        }
        return self.pref_new(start, self.pref_tg[e], self.pref_tgty[e], self.pref_m[e]);
    }

    // Value `v` may reach memory or a callee from here on: the local or slot a `T_MREF` names escapes. A
    // reference to an element of an `@owned` block reaches the block alone (`own_exp`), one to an element
    // of an inline array member that array alone (`aesc`).
    // A borrow of place `p`: what it reaches. The place's own reference (`leak`), a member of an inline
    // array that array alone; a borrow through a reference or a raw pointer (`p[i]` of a pointer local)
    // reaches what the last indirection points to (`&mut (*self.ptr).value` reaches the block, not
    // `self`'s slot); else the local.
    fn borrow_reach(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, p: &ir::Place) {
        let pr = self.place_ref(cb, cm, state, p);
        if pr != NONE {
            self.leak(pr);
            return;
        }
        let mut j = p.proj_len;
        while j > 0 {
            j -= 1;
            if cb.projections.at((p.proj_start + j) as usize).kind == ir::PJ_DEREF || self.ptr_index(cb, cm, p, j) == PI_MEM {
                let r = self.read_prefix(cb, cm, state, p, j, false);
                self.leak(r);
                return;
            }
        }
        self.escape(p.base);
    }

    // A borrow of place `p` through a raw pointer, its last indirection: the memory it points to is what
    // the borrow reaches (`leak` of the pointer). False for another place.
    fn raw_reach(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, p: &ir::Place) bool {
        let mut j = p.proj_len;
        while j > 0 {
            j -= 1;
            let k = cb.projections.at((p.proj_start + j) as usize).kind;
            if k == ir::PJ_DEREF && self.raw_ptr_ty(cm, self.proj_base_ty(cb, p, j)) || self.ptr_index(cb, cm, p, j) == PI_MEM {
                let r = self.read_prefix(cb, cm, state, p, j, false);
                self.leak(r);
                return true;
            }
            if k == ir::PJ_DEREF {
                return false;
            }
        }
        return false;
    }

    fn leak(self: &mut Self, v: u32) {
        if v != NONE && (self.tm.at(v).op == T_MREF || self.tm.at(v).op == T_PREF) && self.ref_target(v) as usize < self.is_mem.len() && !self.pref_in_block(
            v,
        ) {
            // A reference to an element of an inline array member: a pointer made from it reaches that
            // array alone (C defines no arithmetic past it).
            // A reference to a field of a struct (no index, no dereference on its path) reaches that field
            // alone, as an array's does: no pointer arithmetic leaves a field.
            let ar = self.pref_array(v);
            let fr = ar == NONE && self.pref_fields(v);
            if ar == NONE && !fr {
                self.escape(self.ref_target(v));
            } else if self.is_mem[self.ref_target(v) as usize] {
                let r = pick(fr, v, ar);
                if !self.aesc.contains(&r) {
                    self.aesc.push(r);
                }
            }
        }
        if v != NONE && self.sq_of(v) == SQ_EREF {
            self.leak(self.tm.args[self.tm.at(v).a as usize]);
        }
    }

    // Binary operator `op` over floats `x` and `y` of width `fw`, its result of type (`w`, `sg`): IEEE 754
    // arithmetic (`a - b` is `a + -b`), C's `fmod` for `%`, and comparisons, with every value the build's
    // float rewrites allow (`fmath`); a sum or product the build may reassociate is an unknown value.
    fn float_binary(self: &mut Self, cb: &ir::CoreBody, op: u8, x: u32, y: u32, fw: u16, w: u16, sg: bool) u32 {
        let fd = host_fd(fw);
        if op == tt::TokenType::Plus as u8 || op == tt::TokenType::Minus as u8 {
            let y2 = if op == tt::TokenType::Minus as u8 {
                self.tm.fneg(y, fw)
            } else {
                y
            };
            let r0 = self.fsum(x, y2, fw, fd);
            let r = self.reassoc(cb, T_FADD, r0, x, y2, fw, fd);
            let e = self.tm.farith(T_FADD, x, y2, fw, fd);
            self.tm.set_shape(r, e);
            return r;
        }
        if op == tt::TokenType::Star as u8 {
            let e = self.tm.farith(T_FMUL, x, y, fw, fd);
            let v = self.finite_only(e, x, y, true, fw, fd);
            let r0 = if (self.fmath() & bman::CG_FINITE_MATH) != 0 {
                self.zero_sign(v, fw, fd)
            } else {
                v
            };
            let r = self.reassoc(cb, T_FMUL, r0, x, y, fw, fd);
            self.tm.set_shape(r, e);
            return r;
        }
        if op == tt::TokenType::Slash as u8 {
            let r = self.fquot(x, y, fw, fd);
            let e = self.tm.farith(T_FDIV, x, y, fw, fd);
            self.tm.set_shape(r, e);
            return r;
        }
        if op == tt::TokenType::Percent as u8 {
            return self.tm.farith(T_FREM, x, y, fw, fd);
        }
        if op == tt::TokenType::LessThan as u8 || op == tt::TokenType::LessThanEqual as u8 || op == tt::TokenType::GreaterThan as u8 || op == tt::TokenType::GreaterThanEqual as u8 {
            let less = op == tt::TokenType::LessThan as u8 || op == tt::TokenType::LessThanEqual as u8;
            let strict = op == tt::TokenType::LessThan as u8 || op == tt::TokenType::GreaterThan as u8;
            let (a, b) = pick(less, (x, y), (y, x));
            let c = self.tm.fcmp(pick(strict, T_FLT, T_FLE), a, b, fd);
            if (self.fmath() & bman::CG_FINITE_MATH) == 0 {
                return c;
            }
            // `-ffinite-math-only` lets a min or max loop take `!(a < b)` for `a >= b`: an ordered comparison
            // of a NaN is unknown.
            let na = self.float_class(FC_NAN, a, fw, fd);
            let nb = self.float_class(FC_NAN, b, fw, fd);
            let nn = self.tm.or(na, nb);
            let ok = self.tm.not(nn);
            return self.known_if(ok, c);
        }
        if op == tt::TokenType::EqualEqual as u8 || op == tt::TokenType::BangEqual as u8 {
            let e = self.tm.fcmp(T_FEQ, x, y, fd);
            return pick(op == tt::TokenType::EqualEqual as u8, e, self.tm.not(e));
        }
        return self.tm.var(w, sg);
    }

    // Value `e` where `c` holds, else an unknown value of its type.
    fn known_if(self: &mut Self, c: u32, e: u32) u32 {
        if self.tm.is_true(c) {
            return e;
        }
        let x = self.tm.at(e);
        let u = self.tm.var(x.w, x.sg);
        if x.w == W_BOOL {
            let k = self.tm.and(c, e);
            let nc = self.tm.not(c);
            let o = self.tm.and(nc, u);
            return self.tm.or(k, o);
        }
        return self.tm.choose(c, e, u, x.w);
    }

    // Result `e` of the product (`mul`) or sum of floats `x` and `y`. With `-ffinite-math-only` and
    // `-fno-signed-zeros` the optimizer makes `x * 0` and `x - x` zero for any `x` (`x * 1` and `x / 1` are
    // `x` either way): unknown for the product of a zero and a value that is not finite, and for the sum of
    // two values that are not finite.
    fn finite_only(self: &mut Self, e: u32, x: u32, y: u32, mul: bool, fw: u16, fd: u64) u32 {
        let both = bman::CG_FINITE_MATH | bman::CG_NO_SIGNED_ZEROS;
        if (self.fmath() & both) != both {
            return e;
        }
        let fx = self.float_class(FC_FINITE, x, fw, fd);
        let fy = self.float_class(FC_FINITE, y, fw, fd);
        let ok = if mul {
            let zx = self.float_class(FC_ZERO, x, fw, fd);
            let zy = self.float_class(FC_ZERO, y, fw, fd);
            let nzy = self.tm.not(zy);
            let nzx = self.tm.not(zx);
            let ox = self.tm.or(fx, nzy);
            let oy = self.tm.or(fy, nzx);
            self.tm.and(ox, oy)
        } else {
            self.tm.or(fx, fy)
        };
        return self.known_if(ok, e);
    }

    // Result `x` of an operation `-fno-signed-zeros` lets the optimizer rewrite into a zero of the other
    // sign (`x + 0` is `x`, and with `-ffinite-math-only` `x * 0` is +0): a zero of either sign where it is
    // one. The min or max loops it reorders end in values a loop's invariants define, which say nothing
    // of a zero's sign (each reading of the sign here is of such a result, or of a value no rewrite makes).
    fn zero_sign(self: &mut Self, x: u32, fw: u16, fd: u64) u32 {
        if (self.fmath() & bman::CG_NO_SIGNED_ZEROS) == 0 {
            return x;
        }
        let zero = self.tm.int(Num::<B>::zero(), fw, false);
        let zx = self.tm.fcmp(T_FEQ, x, zero, fd);
        if self.tm.is_false(zx) {
            return x;
        }
        let (sb, _mg) = Terms::<B>::fsign_num(fw);
        let u = self.tm.var(fw, false);
        let m = self.tm.int(sb, fw, false);
        let z = self.tm.arith(T_BAND, u, m, fw, false);
        return self.tm.choose(zx, z, x, fw);
    }

    // `x / y`: `-freciprocal-math` lets it be `x` times the rounded reciprocal of `y` (the optimizer does it
    // for a constant divisor, which inlining can make of any).
    fn fquot(self: &mut Self, x: u32, y: u32, fw: u16, fd: u64) u32 {
        let e = self.tm.farith(T_FDIV, x, y, fw, fd);
        let mut r = e;
        if (self.fmath() & bman::CG_RECIP_MATH) != 0 {
            let one = self.tm.int(u64_val::<B>(pick(fw == 32, 1.0f32.to_bits(), 1.0f64.to_bits())), fw, false);
            let rc = self.tm.farith(T_FDIV, one, y, fw, fd);
            let alt = self.tm.farith(T_FMUL, x, rc, fw, fd);
            let b = self.tm.var(W_BOOL, false);
            r = self.tm.choose(b, e, alt, fw);
        }
        return r;
    }

    // `x + y`. `-ffp-contract=fast` lets an operand that is a product `a * b` fuse: the sum is then
    // `fma(a, b, other)`. A product term fuses as such; a value that is no operation here (a parameter, a
    // call's result, a load) may hold one after inlining or forwarding, and its sum lies between the sums
    // with its two neighbors (`fneighbor`), which hold its exact product.
    fn fsum(self: &mut Self, x: u32, y: u32, fw: u16, fd: u64) u32 {
        let e = self.tm.farith(T_FADD, x, y, fw, fd);
        let mut r = e;
        if (self.fmath() & bman::CG_FP_CONTRACT) != 0 {
            let mut alt = NONE;
            for side in 0..2 {
                let (p, o) = pick(side == 0, (x, y), (y, x));
                if self.may_fuse(p) {
                    let f = self.fused(p, o, fw, fd);
                    alt = if alt == NONE {
                        f
                    } else {
                        let b = self.tm.var(W_BOOL, false);
                        self.tm.choose(b, alt, f, fw)
                    };
                }
            }
            if alt != NONE {
                let b = self.tm.var(W_BOOL, false);
                r = self.tm.choose(b, e, alt, fw);
            }
        }
        let v = self.finite_only(r, x, y, false, fw, fd);
        return self.zero_sign(v, fw, fd);
    }

    // Sum or product (`op`) `r` of floats `x` and `y` where the build reassociates (`float_sums_exact`): the
    // optimizer folds `(a op c1) op c2` into `a op (c1 op c2)` for constants (which inlining can make of any
    // value) and computes a loop's running sum or product in another order. Where an operand may be such
    // a partial result (`may_chain`), the result is `r` or a value with the order every association keeps:
    // `x + y` against `x` by the sign of `y`; `x * y` against `x` by the magnitude of `y`, with the sign of
    // their product. A loop's value takes the steps one by one, so these steps reach every order too.
    fn reassoc(self: &mut Self, cb: &ir::CoreBody, op: u8, r: u32, x: u32, y: u32, fw: u16, fd: u64) u32 {
        if self.float_sums_exact(cb) {
            return r;
        }
        let mut alt = NONE;
        for side in 0..2 {
            let (p, o) = pick(side == 0, (x, y), (y, x));
            if self.may_chain(op, p) {
                let f = self.chained(op, p, o, fw, fd);
                alt = if alt == NONE {
                    f
                } else {
                    let b = self.tm.var(W_BOOL, false);
                    self.tm.choose(b, alt, f, fw)
                };
            }
        }
        if alt == NONE {
            return r;
        }
        let b = self.tm.var(W_BOOL, false);
        return self.tm.choose(b, r, alt, fw);
    }

    // Whether float `p` may be a partial result of operation `op` the optimizer reassociates: an operation
    // `op`, its negation, or no operation here (a parameter, a call's result, a load, a choice). A model's
    // value is its IEEE operation's (`Terms::shape`).
    fn may_chain(self: &Self, op: u8, p0: u32) bool {
        let p = self.tm.shape(p0);
        let t = self.tm.at(p);
        if t.op == T_BXOR {
            return self.may_chain(op, t.a) || self.may_chain(op, t.b);
        }
        return t.op == op || self.tm.is_choice(p) || t.op != T_INT && !float_op(t.op) && t.op != T_BAND && t.op != T_BOR;
    }

    // `p op o` with `p` a partial result `a op c` whose operation the optimizer reassociates into
    // `a op (c op o)`: a value with the order facts of `reassoc`, else (a NaN `p`, an infinite `p` against an
    // `o` of the other sign, where `c op o` may overflow into the opposite infinity; for a product, a zero or
    // infinite `p` or `o`) an unknown value. A value that breaks them is taken as the IEEE result, which
    // keeps them; a NaN `o` constrains nothing.
    fn chained(self: &mut Self, op: u8, p: u32, o: u32, fw: u16, fd: u64) u32 {
        let e = self.tm.farith(op, p, o, fw, fd);
        let zero = self.tm.int(Num::<B>::zero(), fw, false);
        let u = self.tm.var(fw, false);
        let mut ok = if op == T_FADD {
            self.sum_kept(p, o, fw, fd)
        } else {
            let fp = self.float_class(FC_FINITE, p, fw, fd);
            let fo = self.float_class(FC_FINITE, o, fw, fd);
            self.tm.and(fp, fo)
        };
        let keeps = if op == T_FADD {
            // o >= 0: u >= p; o <= 0: u <= p.
            let up = self.tm.fcmp(T_FLE, zero, o, fd);
            let dn = self.tm.fcmp(T_FLE, o, zero, fd);
            let ge = self.tm.fcmp(T_FLE, p, u, fd);
            let le = self.tm.fcmp(T_FLE, u, p, fd);
            let nup = self.tm.not(up);
            let ndn = self.tm.not(dn);
            let c1 = self.tm.or(nup, ge);
            let c2 = self.tm.or(ndn, le);
            self.tm.and(c1, c2)
        } else {
            // |o| >= 1: |u| >= |p|; |o| <= 1: |u| <= |p|; the sign of u that of p times o.
            let pz = self.float_class(FC_ZERO, p, fw, fd);
            let npz = self.tm.not(pz);
            ok = self.tm.and(ok, npz);
            let one = self.tm.int(u64_val::<B>(pick(fw == 32, 1.0f32.to_bits(), 1.0f64.to_bits())), fw, false);
            let ma = self.tm.fabs(o, fw);
            let mp = self.tm.fabs(p, fw);
            let mu = self.tm.fabs(u, fw);
            let big = self.tm.fcmp(T_FLE, one, ma, fd);
            let small = self.tm.fcmp(T_FLE, ma, one, fd);
            let ge = self.tm.fcmp(T_FLE, mp, mu, fd);
            let le = self.tm.fcmp(T_FLE, mu, mp, fd);
            let nbig = self.tm.not(big);
            let nsmall = self.tm.not(small);
            let c1 = self.tm.or(nbig, ge);
            let c2 = self.tm.or(nsmall, le);
            let sp = self.float_class(FC_NEG, p, fw, fd);
            let so = self.float_class(FC_NEG, o, fw, fd);
            let su = self.float_class(FC_NEG, u, fw, fd);
            let sx = self.tm.cmp(T_NE, sp, so);
            let sign = self.tm.cmp(T_EQ, su, sx);
            let c12 = self.tm.and(c1, c2);
            self.tm.and(c12, sign)
        };
        let nok = self.tm.not(ok);
        let take = self.tm.or(nok, keeps);
        return self.tm.choose(take, u, e, fw);
    }

    // Where a sum `p + o` whose `p` stands for a real it rounds (a product, or a partial sum) keeps the order
    // of `p` and `o`: `p` is no NaN, and no infinity against an `o` of the other sign, where that real
    // plus `o` may be anything.
    fn sum_kept(self: &mut Self, p: u32, o: u32, fw: u16, fd: u64) u32 {
        let zero = self.tm.int(Num::<B>::zero(), fw, false);
        let inf = pick(fw == 32, 0x7F800000u64, 0x7FF0000000000000u64);
        let pinf = self.tm.int(u64_val::<B>(inf), fw, false);
        let ninf = self.tm.int(u64_val::<B>(inf | fsign(fw)), fw, false);
        let ip = self.tm.cmp(T_EQ, p, pinf);
        let in0 = self.tm.cmp(T_EQ, p, ninf);
        let olt = self.tm.fcmp(T_FLT, o, zero, fd);
        let ogt = self.tm.fcmp(T_FLT, zero, o, fd);
        let b1 = self.tm.and(ip, olt);
        let b2 = self.tm.and(in0, ogt);
        let bad = self.tm.or(b1, b2);
        let np = self.float_class(FC_NAN, p, fw, fd);
        let bad2 = self.tm.or(bad, np);
        return self.tm.not(bad2);
    }

    // Whether float `p` may be a product the optimizer fuses into a sum: not a constant, and no operation
    // other than a product, a product's negation or a choice (a value the build's rewrites leave open). A
    // model's value is its IEEE operation's (`Terms::shape`).
    fn may_fuse(self: &Self, p0: u32) bool {
        let p = self.tm.shape(p0);
        let t = self.tm.at(p);
        if t.op == T_BXOR {
            return self.may_fuse(t.a) || self.may_fuse(t.b);
        }
        return t.op == T_FMUL || self.tm.is_choice(p) || t.op != T_INT && !float_op(t.op) && t.op != T_BAND && t.op != T_BOR;
    }

    // `p + o` with `p`'s product fused: `fma(a, b, o)` of a product term `a * b` (or of its negation,
    // `-a * b`), else, where `sum_kept` and `o` is no NaN, a value between the sums of `o` with the least and
    // the greatest reals that round to `p` (T_FMID), each rounded once, and an unknown value where not.
    fn fused(self: &mut Self, p: u32, o: u32, fw: u16, fd: u64) u32 {
        let t = self.tm.at(self.tm.shape(p));
        let mut xs = Vector::<u32>::with_capacity(3);
        let (ta, tb) = if t.op == T_BXOR {
            (self.tm.shape(t.a), self.tm.shape(t.b))
        } else {
            (NONE, NONE)
        };
        if t.op == T_FMUL {
            xs.push(t.a);
            xs.push(t.b);
        } else if t.op == T_BXOR && (self.tm.at(ta).op == T_FMUL || self.tm.at(tb).op == T_FMUL) {
            let m = self.tm.at(pick(self.tm.at(ta).op == T_FMUL, ta, tb));
            xs.push(self.tm.fneg(m.a, fw));
            xs.push(m.b);
        }
        if xs.len() == 2 {
            xs.push(o);
            return self.tm.ffma(&xs, fw, fd);
        }
        let lo = self.tm.fmid(p, o, false, fw, fd);
        let hi = self.tm.fmid(p, o, true, fw, fd);
        let no = self.float_class(FC_NAN, o, fw, fd);
        let nno = self.tm.not(no);
        let kept = self.sum_kept(p, o, fw, fd);
        let ok = self.tm.and(kept, nno);
        let u = self.tm.var(fw, false);
        let l = self.tm.fcmp(T_FLE, lo, u, fd);
        let h = self.tm.fcmp(T_FLE, u, hi, fd);
        let inside = self.tm.and(l, h);
        let nok = self.tm.not(ok);
        let take = self.tm.or(nok, inside);
        return self.tm.choose(take, u, lo, fw);
    }

    // Conversion `rv` of `x` into or out of a float, into type (`w`, `sg`): between floats, from an integer
    // of up to 64 bits (rounded), into one (`as`: truncated and saturated, NaN 0; `to_int_unchecked`: the
    // same where the value is not NaN and its truncation fits, which is an obligation). Another is an
    // unknown value.
    fn float_cast(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        pc: &mut Vector<u32>,
        rv: &ir::Rvalue,
        x: u32,
        w: u16,
        sg: bool,
        ovf: u8,
        key: u64,
        sp: tok::Span,
    ) u32 {
        let sf = self.float_w(cm, cb.operands.at(rv.a as usize).ty);
        let tf = self.float_w(cm, rv.target);
        let xs = self.tm.at(x);
        if sf != 0 && tf != 0 {
            return self.tm.fconv(T_FCVT, x, tf, false, host_fd(tf) | host_fd(sf) << 32);
        }
        if tf != 0 {
            return if xs.w > W_BOOL && xs.w <= 64 {
                self.tm.fconv(T_ITOF, x, tf, false, host_fd(tf))
            } else {
                self.tm.var(w, sg)
            };
        }
        if w <= W_BOOL || w > 64 {
            return self.tm.var(w, sg);
        }
        let sfd = host_fd(sf);
        let v = self.tm.fconv(T_FTOI, x, w, sg, sfd);
        if rv.b == ir::CAST_UNCHECKED as u32 {
            // Not NaN, and lo <= trunc(x) <= hi: x below hi + 1, a power of two, and above lo - 1 (-1, or
            // -(2^(w-1) + 1)); at least lo where lo - 1 is no float, since then no float lies between them.
            let nn = self.tm.fcmp(T_FEQ, x, x, sfd);
            let top = self.float_pow2(w as i64 - sg as i64, false, false, sf);
            let below = self.tm.fcmp(T_FLT, x, top, sfd);
            let k = pick(sg, w as i64 - 1, 0i64);
            let above = if sg && k > pick(sf == 32, 23i64, 52i64) {
                let lo = self.float_pow2(k, false, true, sf);
                self.tm.fcmp(T_FLE, lo, x, sfd)
            } else {
                let lo1 = self.float_pow2(k, sg, true, sf);
                self.tm.fcmp(T_FLT, lo1, x, sfd)
            };
            let r0 = self.tm.and(nn, below);
            let fits = self.tm.and(r0, above);
            if ovf != OVF_EXACT {
                self.oblige(
                    pc,
                    fits,
                    key,
                    sp,
                    format("cannot prove that this value is not NaN and that its truncation fits the integer type"),
                    String::from_str("'to_int_unchecked' of NaN or of a value outside the type is undefined"),
                );
            }
            pc.push(fits);
        }
        return v;
    }

    // The float `2^k`, plus 1 when `one` (k at most the fraction width), negated when `neg`, of width `fw`.
    fn float_pow2(self: &mut Self, k: i64, one: bool, neg: bool, fw: u16) u32 {
        let (bias, m) = pick(fw == 32, (127i64, 23i64), (1023i64, 52i64));
        let frac = if one {
            1u64 << (m - k) as u64
        } else {
            0u64
        };
        let bits = (k + bias) as u64 << m as u64 | frac | pick(neg, fsign(fw), 0u64);
        return self.tm.int(u64_val::<B>(bits), fw, false);
    }

    // A checked operation's value `exact` (of a type that fits it only if it does not overflow): with
    // OVF_PROVE the proof that it fits, under `pc`, then the exact value; with OVF_KEEP a fresh value
    // that equals the exact one where it fits.
    fn checked(self: &mut Self, exact: u32, pc: &mut Vector<u32>, ovf: u8, key: u64, sp: tok::Span) u32 {
        let fits = self.tm.in_range(exact);
        if self.tm.is_true(fits) || ovf == OVF_EXACT {
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
        let r = self.rvalue_in(cb, cm, state, pc, rid, all, ovf, key, sp);
        // An address of a place is never null.
        if cb.rvalues.at(rid as usize).kind == ir::RV_ADDR && r != NONE && self.tm.at(r).w == W_OTHER && !self.ptrd.contains_key(
            &r,
        ) {
            self.ptrd.insert(r, true);
            let nl = self.null_ptr();
            let f = self.tm.cmp(T_NE, r, nl);
            self.anchor(r, f);
        }
        return r;
    }

    fn rvalue_in(
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
        if rv.kind == ir::RV_DISCRIMINANT && w > W_BOOL && w <= 64 {
            let x = self.read_place(cb, cm, state, rv.a, all);
            // A variant literal's: its variant's tag.
            let xt = self.tm.at(x);
            if xt.op == T_AGG && !xt.k.is_zero() {
                let (dm, dn) = self.decl_of(cm, cb.places.at(rv.a as usize).ty);
                let vi = (xt.k - Num::<B>::one()).to_i64();
                let mut tag = vi;
                let mut neg = false;
                if dn != NODE_NONE && (!self.ast_of(dm).enum_explicit(dn) || lay::variant_tag(
                    self.pkg(),
                    dm,
                    dn,
                    vi,
                    &mut tag,
                    &mut neg,
                )) {
                    return self.tm.int(wide::<B>(tag), w, sg);
                }
            }
            return self.tm.make(Term::<B> { k: Num::<B>::zero(), a: x, b: 0, op: T_TAG, w: w, sg: sg });
        }
        if rv.kind == ir::RV_USE {
            let x = self.operand(cb, cm, state, rv.a, all);
            // An array's view (`b` 1 or 2) has the array's length.
            let n = self.array_len(cm, cb.operands.at(rv.a as usize).ty);
            if rv.b != 0 && n >= 0 {
                return self.tm.make(Term::<B> { k: wide::<B>(n), a: x, b: 0, op: T_VIEW, w: W_OTHER, sg: false });
            }
            return x;
        }
        if !all && (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE) {
            let p = *cb.places.at(rv.a as usize);
            self.static_ref(cb, pc, &p, sp);
        }
        // A `&mut` of a local or of a member lent to one call escapes at the call (`call`), for the call.
        let lent = !all && rv.kind == ir::RV_REF && (rv.b != 0 && member_place(cb, cb.places.at(rv.a as usize)) && self.dest_tmp != NONE && self.scoped[self.dest_tmp as usize] || self.in_vborrow);
        let lazy = rv.kind == ir::RV_REF && self.dest_tmp != NONE && self.lazy[self.dest_tmp as usize];
        // A shared borrow of a cell-free place (`no_cell`) lets nothing write it, where the body makes no
        // pointer from a reference (`ptr_cast`).
        let ro = !all && rv.kind == ir::RV_REF && rv.b == 0 && !self.ptr_cast && (self.cell_free_of(
            cm,
            cb.places.at(rv.a as usize).ty,
            NODE_NONE,
        ) || self.dest_tmp != NONE && self.cell_tmp[self.dest_tmp as usize]);
        if !all && !lent && !lazy && !ro && (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE) && !self.owned_elem(
            cb,
            cb.places.at(rv.a as usize),
        ) {
            let p = *cb.places.at(rv.a as usize);
            self.borrow_reach(cb, cm, state, &p);
        }
        if !all && rv.kind == ir::RV_CAST {
            let x = self.operand(cb, cm, state, rv.a, all);
            self.leak(x);
        }
        if !all && rv.kind == ir::RV_CLOSURE {
            for j in rv.a..rv.a + rv.b {
                let op = *cb.operands.at(cb.oper_pool[j as usize] as usize);
                if op.kind != ir::OP_CONST {
                    self.escape(cb.places.at(op.data as usize).base);
                }
            }
        }
        if rv.kind == ir::RV_SLICE && !all {
            return self.slice_of(cb, cm, state, pc, &rv);
        }
        // A raw address of a member of a local, or through the `&mut` of a local or a slot: the reference to
        // it (`place_ref`), which a write through the pointer finds (`ptr_target`).
        if rv.kind == ir::RV_ADDR {
            let p = *cb.places.at(rv.a as usize);
            let pr = self.place_ref_in(cb, cm, state, &p, all);
            if pr != NONE {
                return pr;
            }
        }
        if rv.kind == ir::RV_REF {
            let p = *cb.places.at(rv.a as usize);
            if p.proj_len == 0 && (all || self.tracked[p.base as usize]) {
                let v = self.local_val(cb, cm, state, p.base);
                if rv.b != 0 {
                    return self.tm.make(
                        Term::<B> { k: Num::<B>::zero(), a: p.base, b: 0, op: T_MREF, w: W_OTHER, sg: false },
                    );
                }
                if !self.ptr_cast && (self.frozen(cm, cb.locals.at(p.base as usize).ty) || self.container(
                    cm,
                    cb.locals.at(p.base as usize).ty,
                )) {
                    return self.tm.unary(T_REF, v, W_OTHER, false);
                }
            }
            // A shared reference to a member of a frozen local (`&s[7]`, `&p.x`) refers to the member's value.
            if rv.b == 0 && p.proj_len != 0 && !self.ptr_cast && (all || self.tracked[p.base as usize]) && self.frozen(
                cm,
                cb.locals.at(p.base as usize).ty,
            ) {
                let mut direct = true;
                for j in 0..p.proj_len {
                    direct = direct && cb.projections.at((p.proj_start + j) as usize).kind != ir::PJ_DEREF;
                }
                if direct {
                    let v = self.read_place(cb, cm, state, rv.a, all);
                    return self.tm.unary(T_REF, v, W_OTHER, false);
                }
            }
            // A shared reborrow `&*x` of a reference to a frozen value is that reference.
            if rv.b == 0 && p.proj_len == 1 && cb.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF && (all || self.tracked[p.base as usize]) {
                let v = self.local_val(cb, cm, state, p.base);
                if v != NONE && self.tm.at(v).op == T_REF {
                    return v;
                }
            }
            // A reference to a member of a local, or through the `&mut` of a local or a slot.
            let pr = self.place_ref_in(cb, cm, state, &p, all);
            if pr != NONE {
                return pr;
            }
            return self.tm.var(W_OTHER, false);
        }
        if rv.kind == ir::RV_AGGREGATE && !all {
            for j in rv.a..rv.a + rv.b {
                let o = cb.oper_pool[j as usize];
                if o != ir::IR_NONE && cb.operands.at(o as usize).kind != ir::OP_CONST {
                    let x = self.operand(cb, cm, state, o, all);
                    self.leak(x);
                }
            }
        }
        // A variant literal: the value of its variant and its members (`T_AGG` marked with the variant's
        // index plus one), whose downcast to that variant is its members (`read_prefix`) and whose
        // discriminant is the variant's tag (RV_DISCRIMINANT).
        if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_VARIANT {
            let vi = self.variant_index(rv.item);
            if vi >= 0 {
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
                return self.tm.pool(T_AGG, &xs, wide::<B>(vi + 1));
            }
        }
        // A struct literal the lowering made (a range `lo..hi`) names no declaration: a value of its members
        // where its type is a value.
        if rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_ARRAY || rv.c == ir::AGG_STRUCT && (rv.item.node != NODE_NONE || self.frozen(
            cm,
            rv.target,
        ))) {
            // A constant element of an array is a value of the element type, whatever type the literal
            // kept: `[0x61707865, k]` of `[u32; 2]` holds a `u32` constant, one term with every other.
            let ay = *self.ast_of(cm).type_at(rv.target);
            let ety = if rv.c == ir::AGG_ARRAY && ay.kind == TypeKind::TYPE_ARRAY {
                ay.as_data.arr.elem
            } else {
                TYPE_NONE
            };
            let mut xs = Vector::<u32>::with_capacity(rv.b as usize);
            let mut mtys = Vector::<u64>::new();
            if rv.c == ir::AGG_STRUCT {
                self.member_types(cm, rv.target, &mut mtys);
            }
            let un = rv.c == ir::AGG_STRUCT && self.is_union_ty(cm, rv.target);
            for j in rv.a..rv.a + rv.b {
                let o = cb.oper_pool[j as usize];
                // An omitted member holds zero: the lowering zero-fills it. A union's other members hold the
                // given one's bytes (`union_coherence`).
                let z = if o != ir::IR_NONE || un {
                    NONE
                } else if rv.c == ir::AGG_ARRAY {
                    self.zero_value(cm, ety, 0)
                } else if (j - rv.a) as usize < mtys.len() {
                    let mt = mtys[(j - rv.a) as usize];
                    self.zero_value((mt >> 32) as ModuleId, (mt & 0xFFFFFFFFu64) as TypeId, 0)
                } else {
                    NONE
                };
                xs.push(
                    if o == ir::IR_NONE {
                        pick(z != NONE, z, self.tm.var(W_OTHER, false))
                    } else if ety != TYPE_NONE && cb.operands.at(o as usize).kind == ir::OP_CONST {
                        self.constant(cb, cm, cb.operands.at(o as usize).data, ety)
                    } else {
                        self.operand(cb, cm, state, o, all)
                    },
                );
            }
            let agg = self.tm.pool(T_AGG, &xs, Num::<B>::zero());
            if un {
                self.union_coherence(cm, rv.target, agg);
            }
            // A slice made of a pointer to known elements (`src_bytes`): those are its view.
            if !all && rv.c == ir::AGG_STRUCT && xs.len() == 2 && mtys.len() == 2 && self.is_slice_ty(cm, rv.target) {
                let (pm, pt) = self.resolve((mtys[0] >> 32) as ModuleId, (mtys[0] & 0xFFFFFFFFu64) as TypeId);
                let py = *self.ast_of(pm).type_at(pt);
                if py.kind == TypeKind::TYPE_POINTER {
                    let es = self.size_term(pm, py.as_data.elem);
                    let (ss, si) = self.src_bytes(cb, state, xs[0], es);
                    let wi = if ss != NONE {
                        self.key_int(si)
                    } else {
                        NONE
                    };
                    let wn = self.widened(xs[1], W_INT, true);
                    if wi != NONE && wn != NONE {
                        let hi = self.tm.arith(T_ADD, wi, wn, W_INT, true);
                        let sub = self.sub_seq(ss, wi, hi);
                        let ep = self.slice_ep(cm, rv.target, state);
                        self.sdef.insert(agg as u64 << 32 | ep as u64, sub);
                    }
                }
            }
            return if rv.c == ir::AGG_STRUCT {
                self.literal_blocks(cb, cm, &rv, &xs, agg)
            } else {
                agg
            };
        }
        if rv.kind == ir::RV_LEN {
            let at = cb.places.at(rv.a as usize).ty;
            let n = self.array_len(cm, at);
            if n >= 0 && w > W_BOOL {
                return self.tm.int(wide::<B>(n), w, sg);
            }
            // `[T; N]`: the length is const parameter N, the one unknown each read of N is.
            let ay = *self.ast_of(cm).type_at(at);
            if w > W_BOOL && ay.kind == TypeKind::TYPE_ARRAY && ay.arr_sym() && self.ast_of(cm).type_at(
                ay.as_data.arr.len,
            ).kind == TypeKind::TYPE_GENERIC {
                let ly = *self.ast_of(cm).type_at(ay.as_data.arr.len);
                return self.param_var(DefId { module: ly.module, node: ly.as_data.decl }, cm, rv.target);
            }
        }
        if rv.kind == ir::RV_UNARY {
            let x = self.operand(cb, cm, state, rv.a, all);
            let op = rv.b as u8;
            let fw = self.float_w(cm, cb.operands.at(rv.a as usize).ty);
            if fw != 0 {
                return if op == tt::TokenType::Minus as u8 {
                    self.tm.fneg(x, fw)
                } else {
                    self.tm.var(w, sg)
                };
            }
            if op == tt::TokenType::Bang as u8 && self.tm.is_bool(x) {
                return self.tm.not(x);
            }
            if op == tt::TokenType::Minus as u8 && self.tm.is_int(x) && w > W_BOOL {
                let e = self.tm.neg(x, w, sg);
                return self.checked(e, pc, ovf, key, sp);
            }
            if op == tt::TokenType::Tilde as u8 && self.tm.is_int(x) && w > W_BOOL && !exact_w(w) {
                return self.tm.unary(T_BNOT, x, w, sg);
            }
            return self.tm.var(w, sg);
        }
        if rv.kind == ir::RV_BINARY {
            let x = self.operand(cb, cm, state, rv.a, all);
            let y = self.operand(cb, cm, state, rv.b, all);
            let op = rv.c;
            let xty = cb.operands.at(rv.a as usize).ty;
            let fw = self.float_w(cm, xty);
            if fw != 0 {
                return self.float_binary(cb, op, x, y, fw, w, sg);
            }
            if (op == tt::TokenType::Plus as u8 || op == tt::TokenType::Minus as u8) && xty != TYPE_NONE && self.ast_of(
                cm,
            ).type_at(xty).kind == TypeKind::TYPE_POINTER && self.tm.is_int(y) {
                let es = self.size_term(cm, self.ast_of(cm).type_at(xty).as_data.elem);
                return self.ptr_offset(pick(op == tt::TokenType::Plus as u8, T_ADD, T_SUB), x, y, es);
            }
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
                    let z = self.tm.int(Num::<B>::zero(), self.tm.at(y).w, self.tm.at(y).sg);
                    let nz = self.tm.cmp(T_NE, y, z);
                    self.check_fact(pc, nz, key, sp);
                    return self.divided(pc, op == tt::TokenType::Slash as u8, x, y, w, sg);
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
                // An exact integer has no bits.
                if bo != 0 && exact_w(w) {
                    return self.tm.var(w, sg);
                }
                if bo == T_SHL || bo == T_SHR {
                    // A count below 0 or of the width or more traps in every profile.
                    let yx = self.tm.at(y);
                    let z = self.tm.int(Num::<B>::zero(), yx.w, yx.sg);
                    let wv = self.tm.int(wide::<B>(w), yx.w, yx.sg);
                    let c1 = self.tm.cmp(T_LE, z, y);
                    let c2 = self.tm.cmp(T_LT, y, wv);
                    self.check_fact(pc, c1, key, sp);
                    self.check_fact(pc, c2, key, sp);
                }
                if bo != 0 {
                    let r = self.tm.arith(bo, x, y, w, sg);
                    if bo == T_SHL || bo == T_SHR {
                        self.shifted(pc, r);
                    }
                    return r;
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
            // Equality of other values (ghost code's): a sequence's is extensional.
            if !ints && !bools && (op == tt::TokenType::EqualEqual as u8 || op == tt::TokenType::BangEqual as u8) && self.tm.at(
                x,
            ).w == W_OTHER && self.tm.at(y).w == W_OTHER {
                let e = self.tm.cmp(T_EQ, x, y);
                let et = self.seq_elem(cm, cb.operands.at(rv.a as usize).ty);
                if et != TYPE_NONE {
                    let (ew, esg) = self.ty_of(cm, et);
                    self.seq_ext(e, x, y, ew, esg);
                }
                return pick(op == tt::TokenType::EqualEqual as u8, e, self.tm.not(e));
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
        // The implicit `from` of a wide integer (`let x: u128 = 5`, `a < 1000`): the value it converts.
        if rv.kind == ir::RV_CAST && rv.b == ir::CAST_COERCE_FROM as u32 && self.wide_kind(rv.item) == WK_FROM {
            let x = self.operand(cb, cm, state, rv.a, all);
            if self.tm.is_int(x) {
                let v = self.widened(x, w, sg);
                if v != NONE {
                    return v;
                }
            }
        }
        // A cast from a pointer or a reference to a pointer keeps the address, which a reference's is not null.
        if rv.kind == ir::RV_CAST && rv.target != TYPE_NONE && cb.operands.at(rv.a as usize).ty != TYPE_NONE && self.ast_of(
            cm,
        ).type_at(rv.target).kind == TypeKind::TYPE_POINTER {
            let sk = self.ast_of(cm).type_at(cb.operands.at(rv.a as usize).ty).kind;
            if sk == TypeKind::TYPE_POINTER {
                return self.operand(cb, cm, state, rv.a, all);
            }
            if sk == TypeKind::TYPE_REFERENCE {
                let x = self.operand(cb, cm, state, rv.a, all);
                if !self.ptrd.contains_key(&x) {
                    self.ptrd.insert(x, true);
                    let nl = self.null_ptr();
                    let f = self.tm.cmp(T_NE, x, nl);
                    self.anchor(x, f);
                }
                return x;
            }
        }
        // A conversion into or out of a float.
        if rv.kind == ir::RV_CAST && (rv.b == ir::CAST_NUMERIC as u32 || rv.b == ir::CAST_UNCHECKED as u32) && (self.float_w(
            cm,
            rv.target,
        ) != 0 || self.float_w(cm, cb.operands.at(rv.a as usize).ty) != 0) {
            let x = self.operand(cb, cm, state, rv.a, all);
            return self.float_cast(cb, cm, pc, &rv, x, w, sg, ovf, key, sp);
        }
        // A pointer's address (`p as usize`).
        if rv.kind == ir::RV_CAST && rv.b == ir::CAST_NUMERIC as u32 && w == self.pw && !sg && cb.operands.at(
            rv.a as usize,
        ).ty != TYPE_NONE && self.ast_of(cm).type_at(cb.operands.at(rv.a as usize).ty).kind == TypeKind::TYPE_POINTER {
            let x = self.operand(cb, cm, state, rv.a, all);
            return self.ptr_addr(x);
        }
        if rv.kind == ir::RV_CAST && rv.b == ir::CAST_NUMERIC as u32 {
            let x = self.operand(cb, cm, state, rv.a, all);
            let xs = self.tm.at(x);
            if xs.w > W_BOOL && w > W_BOOL {
                // A cast that keeps every value of the source keeps the value: into `int` each one,
                // into `nat` one at least 0 (proved, as an overflow).
                let v = self.widened(x, w, sg);
                if v != NONE {
                    return v;
                }
                if w == W_NAT {
                    let z = self.tm.int(Num::<B>::zero(), xs.w, xs.sg);
                    let fits = self.tm.cmp(T_LE, z, x);
                    if ovf == OVF_PROVE {
                        self.oblige(
                            pc,
                            fits,
                            key,
                            sp,
                            format("cannot prove that this value is at least 0"),
                            String::new(),
                        );
                    }
                    pc.push(fits);
                    return x;
                }
                let (lo1, hi1) = Terms::<B>::range(w, sg);
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
        // A bounds check gives back the value it checks (the index, or a range's end), and the path goes
        // on only where the check holds (the panic edge leaves it).
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_SIZEOF {
            return self.size_term(cm, rv.b as TypeId);
        }
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_ALIGNOF {
            return self.align_term(cm, rv.b as TypeId);
        }
        // `dangling::<T>()`: the address `alignof(T)`, which is not null.
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_DANGLING {
            let r = self.tm.var(W_OTHER, false);
            let nl = self.null_ptr();
            pc.push(self.tm.cmp(T_NE, r, nl));
            let at = self.ptr_addr(r);
            let al = self.align_term(cm, rv.b as TypeId);
            pc.push(self.tm.cmp(T_EQ, at, al));
            return r;
        }
        // `likely(c)` and `unlikely(c)` are `c`.
        if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_LIKELY || rv.c == ir::IN_UNLIKELY) && rv.b == 1 {
            return self.operand(cb, cm, state, cb.oper_pool[rv.a as usize], all);
        }
        // A safepoint's report: 0, the path that goes on. Its cancellation, 1, unwinds as a panic does, which
        // the check at the safepoint covers (`statement`).
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_SAFEPOINT_C && w > W_BOOL {
            return self.tm.int(Num::<B>::zero(), w, sg);
        }
        // A strip-mined loop's chunk end (`IN_CHUNK(i, end)`): where `i < end`, a value above `i` and at most
        // `end`.
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_CHUNK && rv.b == 2 && w > W_BOOL {
            let x = self.operand(cb, cm, state, cb.oper_pool[rv.a as usize], all);
            let y = self.operand(cb, cm, state, cb.oper_pool[(rv.a + 1) as usize], all);
            let r = self.tm.var(w, sg);
            let lt = self.tm.cmp(T_LT, x, y);
            let a1 = self.tm.cmp(T_LT, x, r);
            let a2 = self.tm.cmp(T_LE, r, y);
            let inr = self.tm.and(a1, a2);
            pc.push(self.imp(lt, inr));
            return r;
        }
        if rv.kind == ir::RV_INTRINSIC && ir::is_check(rv.c) && rv.b >= 2 {
            let x = self.operand(cb, cm, state, cb.oper_pool[rv.a as usize], all);
            let y = self.operand(cb, cm, state, cb.oper_pool[(rv.a + 1) as usize], all);
            let z = if rv.b >= 3 {
                self.operand(cb, cm, state, cb.oper_pool[(rv.a + 2) as usize], all)
            } else {
                NONE
            };
            let ints = self.tm.is_int(x) && self.tm.is_int(y) && (z == NONE || self.tm.is_int(z));
            let own = !all && cb as *const ir::CoreBody == self.b;
            // The checks compare as `usize` (`__sc_bounds(size_t, size_t)`): a signed index below 0
            // fails.
            if ints && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN) {
                let lt = self.tm.cmp(T_LT, x, y);
                let nn = self.nonneg(x);
                let f = self.tm.and(nn, lt);
                self.note_check(own && rv.c == ir::IN_BOUNDS, rid, pc, f);
                self.check_fact(pc, f, key, sp);
                return x;
            }
            if ints && z != NONE && (rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS_PROVEN) {
                let c1 = self.tm.cmp(T_LE, x, y);
                let c2 = self.tm.cmp(T_LE, y, z);
                let nn = self.nonneg(x);
                let c12 = self.tm.and(c1, c2);
                let f = self.tm.and(nn, c12);
                self.note_check(own && rv.c == ir::IN_RANGE_BOUNDS, rid, pc, f);
                self.check_fact(pc, f, key, sp);
                return y;
            }
            if ints && z != NONE && (rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN) {
                // `index <= len && width <= len - index`, exact: `index + width <= len`.
                let (xw, xsg) = (self.tm.at(x).w, self.tm.at(x).sg);
                let c1 = self.tm.cmp(T_LE, x, y);
                let end = self.tm.arith(T_ADD, x, z, xw, xsg);
                let c2 = self.tm.cmp(T_LE, end, y);
                let nn = self.nonneg(x);
                let c12 = self.tm.and(c1, c2);
                let f = self.tm.and(nn, c12);
                self.note_check(own && rv.c == ir::IN_BOUNDS_GROUP, rid, pc, f);
                self.check_fact(pc, f, key, sp);
                return x;
            }
            // A check over values the walk does not model: no proof that it holds, and no fact.
            if !ints && (self.in_ghost || self.no_panic && self.chain_depth == 0) && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_BOUNDS_GROUP) {
                let no = self.tm.boolean(false);
                self.oblige(
                    pc,
                    no,
                    OB_PANIC << 56 | key & 0xFFFFFFFFFFFFFFu64,
                    sp,
                    format("cannot prove that this check holds"),
                    String::from_str(
                        pick(self.in_ghost, "ghost code never runs: each of its checks is an obligation", NO_PANIC_NOTE),
                    ),
                );
            }
        }
        return self.tm.var(w, sg);
    }

    // `0 <= x` for a signed integer `x`, `true` for an unsigned one.
    fn nonneg(self: &mut Self, x: u32) u32 {
        let t = self.tm.at(x);
        if !t.sg {
            return self.tm.boolean(true);
        }
        let z = self.tm.int(Num::<B>::zero(), t.w, t.sg);
        return self.tm.cmp(T_LE, z, x);
    }

    // The length and the view of container place `pl` of body `cb` (an array of a known length, a
    // view, a vector, a string); NONE both for another one.
    fn cont_view(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, pl: u32) (u32, u32) {
        let ty = cb.places.at(pl as usize).ty;
        let n = self.array_len(cm, ty);
        let v = self.read_place(cb, cm, state, pl, false);
        if n >= 0 {
            let mut xs = Vector::<u32>::new();
            xs.push(v);
            xs.push(self.tm.int(wide::<B>(n), W_NAT, false));
            return self.tm.int(wide::<B>(n), self.pw, false), self.seq_make(SQ_VIEWA, &xs);
        }
        let (dm, dd) = self.decl_of(cm, ty);
        if dd == NODE_NONE {
            return NONE, NONE;
        }
        if dm == self.slice.mid && dd == self.slice.node || dm == self.smut.mid && dd == self.smut.node {
            let l = self.sq1(SQ_SLEN, v, self.pw, false);
            let ep = self.slice_ep(cm, ty, state);
            return l, self.view_s(v, ep);
        }
        if dm == self.vecl.mid && dd == self.vecl.node {
            self.vec_fields(v);
        }
        if dm == self.vecl.mid && dd == self.vecl.node || dm == self.strl.mid && dd == self.strl.node {
            return self.vlen(v, self.pw, false), self.view_v(v);
        }
        return NONE, NONE;
    }

    // `base[lo..hi]` (RV_SLICE `rv`): a view whose length is `hi - lo` and whose elements, in this memory
    // epoch, are the container's from `lo`, when the container is one the walk models; a fresh view
    // otherwise.
    fn slice_of(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        rv: &ir::Rvalue,
    ) u32 {
        let s = self.fresh(cm, rv.target);
        let (n, cv) = self.cont_view(cb, cm, state, rv.a);
        if n == NONE {
            return s;
        }
        let lo = if rv.b != ir::IR_NONE {
            self.operand(cb, cm, state, rv.b, false)
        } else {
            self.tm.int(Num::<B>::zero(), self.pw, false)
        };
        let mut hi = if rv.item.node != ir::IR_NONE {
            self.operand(cb, cm, state, rv.item.node, false)
        } else {
            n
        };
        if !self.tm.is_int(lo) || !self.tm.is_int(hi) {
            return s;
        }
        if (rv.c & 1) != 0 && rv.item.node != ir::IR_NONE {
            let one = self.tm.int(Num::<B>::one(), W_INT, true);
            hi = self.tm.arith(T_ADD, hi, one, W_INT, true);
        }
        let l = self.sq1(SQ_SLEN, s, self.pw, false);
        let d = self.tm.arith(T_SUB, hi, lo, W_INT, true);
        pc.push(self.tm.cmp(T_EQ, l, d));
        let mut xs = Vector::<u32>::new();
        xs.push(cv);
        xs.push(self.sq_index(lo));
        xs.push(self.sq_index(hi));
        let sub = self.seq_make(SQ_SUB, &xs);
        let ep = self.slice_ep(cm, rv.target, state);
        self.sdef.insert(s as u64 << 32 | ep as u64, sub);
        return s;
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
        // An assignment's reads and writes through pointers may close the structs open at others.
        let w0 = self.wpc;
        let s0 = self.wsp;
        if !all {
            self.wpc = pc;
            self.wsp = cb.statements.at(sid as usize).span;
        }
        self.statement_in(cb, cm, state, pc, sid, all, ovf);
        self.wpc = w0;
        self.wsp = s0;
    }

    fn statement_in(
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
        // A local's storage starts again (a loop's local): no reference reaches it yet.
        if s.kind == ir::ST_STORAGE_LIVE && !all {
            self.unescape(s.a);
        }
        if s.kind != ir::ST_ASSIGN {
            return;
        }

        let rv = *cb.rvalues.at(s.rvalue as usize);
        if !all && rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_ASM || rv.c == ir::IN_VOLATILE_STORE) {
            self.mem_event(cb, cm, state);
        }
        // An operation that may panic (an overflow, a division by zero, a shift count, a conversion, a
        // check) unwinds past the body's values; in a body with contracts none does. Of a body without:
        // where the path decides its panic condition (`op_panics`), only where it holds.
        if !all && (!self.no_panic || self.pan_cond != NONE) && self.inv_locs.len() != 0 && Self::may_panic(&rv) {
            let pcond = if self.no_panic {
                NONE
            } else {
                self.op_panics(cb, cm, state, &rv)
            };
            if pcond == NONE {
                let fs = self.inv_unwind(
                    cb,
                    state,
                    pc,
                    7 << 52 | sid as u64,
                    s.span,
                    "where this operation may panic",
                    NONE,
                );
                Self::inv_proved(pc, &fs);
            } else if !self.tm.is_false(pcond) && !self.holds_within(pc, self.tm.not(pcond), PANIC_STEPS) {
                let mut pc2 = pc.clone();
                pc2.push(pcond);
                let _ = self.inv_unwind(
                    cb,
                    state,
                    &pc2,
                    7 << 52 | sid as u64,
                    s.span,
                    "where this operation may panic",
                    NONE,
                );
            }
        }
        // A safepoint that accepts a cancellation unwinds as a panic does, also in a body with contracts.
        if !all && self.inv_locs.len() != 0 && rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_SAFEPOINT_C {
            let fs = self.inv_unwind(
                cb,
                state,
                pc,
                7 << 52 | sid as u64,
                s.span,
                "where this loop may be cancelled",
                NONE,
            );
            Self::inv_proved(pc, &fs);
        }
        let dp = *cb.places.at(s.place as usize);
        self.dest_tmp = pick(dp.proj_len == 0, dp.base, NONE);
        self.in_vborrow = self.vborrow.contains_key(&sid);
        let v0 = self.rvalue(cb, cm, state, pc, s.rvalue, all, ovf, OB_OVERFLOW << 56 | sid as u64, s.span);
        self.dest_tmp = NONE;
        self.in_vborrow = false;
        let v = if !all && (rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST) && cb.operands.at(rv.a as usize).kind != ir::OP_CONST {
            let sp = *cb.places.at(cb.operands.at(rv.a as usize).data as usize);
            let sty = if sp.proj_len == 0 && sp.base as usize < cb.locals.len() {
                cb.locals.at(sp.base as usize).ty
            } else {
                sp.ty
            };
            self.share_arg(cm, sty, cm, dp.ty, v0, state, pc)
        } else {
            v0
        };
        // A pointer cast of an allocator's result is that result.
        if !all && rv.kind == ir::RV_CAST && v != NONE {
            let x = self.operand(cb, cm, state, rv.a, all);
            if let Some(ix) = self.alloc_of.get(&x) {
                let i = *ix;
                self.alloc_of.insert(v, i);
            }
        }
        // A write into foreign memory keeps the invariant of the value it changes there, which held before
        // (every value there left a body that proved it); a write past a raw pointer that value holds
        // changes memory, not the value (`mem_from`).
        let fk = if !all && !self.ghost_fn && cm == cb.module {
            self.foreign_deref(cb, state, &dp)
        } else {
            dp.proj_len
        };
        let fty = if fk < dp.proj_len && !self.has_deref(cb, &dp, fk + 1) && !self.mem_from(cb, &dp, fk + 1) {
            cb.projections.at((dp.proj_start + fk) as usize).ty
        } else {
            TYPE_NONE
        };
        // In the struct's own file the block may write several members first: its end proves the
        // invariant (`mi_close`).
        let finv = fty != TYPE_NONE && self.inv_here(cm, fty) && self.decl_of(cm, fty).0 != cb.module;
        // The value there after the write: the one before with the written member replaced.
        let mut fx0 = NONE;
        let mut fx1 = NONE;
        if finv {
            let x0 = self.read_prefix(cb, cm, state, &dp, fk + 1, false);
            fx0 = self.inv_of(cm, fty, x0, state);
            let y = if v == NONE {
                self.fresh(cm, dp.ty)
            } else {
                v
            };
            fx1 = self.update(cb, cm, state, &dp, fk + 1, x0, y, false);
        }
        // A counter field's step (`count_step`): its value before the write, and the block's pointer.
        let (cty, cfi) = if all || self.ghost_fn {
            (TYPE_NONE, NONE)
        } else {
            self.counter_place(cb, cm, &dp, false)
        };
        let (wty, _wfi) = if all || self.ghost_fn || cty != TYPE_NONE {
            (TYPE_NONE, NONE)
        } else {
            self.counter_place(cb, cm, &dp, true)
        };
        if cty == TYPE_NONE && wty == TYPE_NONE && !all && !self.ghost_fn && self.guard_place(cb, cm, &dp) {
            self.report(
                OB_COUNTER << 56 | 6 << 40 | sid as u64,
                dc::COUNTER_STEP,
                s.span,
                format("a member a counter's guard reads is written only where its struct starts"),
                String::from_str("write the whole struct (`*p = S { .. }`) where the body holds the guard"),
            );
        }
        let (cp, co) = if cty != TYPE_NONE {
            (
                self.read_prefix(cb, cm, state, &dp, dp.proj_len - 2, false),
                self.read_place(cb, cm, state, s.place, false)
            )
        } else if wty != TYPE_NONE {
            (self.read_prefix(cb, cm, state, &dp, dp.proj_len - 1, false), NONE)
        } else {
            (NONE, NONE)
        };
        self.write_place(cb, cm, state, s.place, v, all);
        if cty != TYPE_NONE {
            let t = self.tm.boolean(true);
            self.count_step(cb, cm, state, pc, cty, cfi, cp, co, v, NONE, t, CS_PLAIN, s.span, sid);
        } else if wty != TYPE_NONE && v != NONE {
            self.count_start(cb, cm, state, pc, wty, cp, v, s.span, sid);
        }
        if !all {
            self.st_report(pc, s.span);
        }
        // A whole local of a type that holds a block, assigned elsewhere: moved, it holds no value.
        if !all && s.kind == ir::ST_ASSIGN && self.inv_locs.len() != 0 {
            let rv = *cb.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_USE && rv.b == 0 {
                let op = *cb.operands.at(rv.a as usize);
                if op.kind != ir::OP_CONST && cb.places.at(op.data as usize).proj_len == 0 {
                    let l = cb.places.at(op.data as usize).base;
                    let lt = cb.locals.at(l as usize).ty;
                    if l != cb.places.at(s.place as usize).base && self.inv_locs.contains(&l) && self.ast_of(cm).type_at(
                        lt,
                    ).kind != TypeKind::TYPE_REFERENCE && self.inv_owns(cm, lt) {
                        state.set(l as usize, NONE);
                    }
                }
            }
        }
        if !all {
            self.own_check(pc, s.span);
            if finv {
                let x = if fx1 != NONE {
                    fx1
                } else {
                    self.read_prefix(cb, cm, state, &dp, fk + 1, false)
                };
                let mut pc1 = pc.clone();
                if fx0 != NONE {
                    pc1.push(fx0);
                }
                let _ = self.inv_need(cb, state, &pc1, fty, x, 8 << 52 | sid as u64, s.span, "after this write");
            }
        }
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
        // A float's patterns are not its encodings: its edges are unknown.
        let dx = if self.float_w(cm, cb.operands.at(t.a as usize).ty) != 0 {
            Term::<B> { k: Num::<B>::zero(), a: 0, b: 0, op: T_VAR, w: W_OTHER, sg: false }
        } else {
            self.tm.at(d)
        };
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
                    wide::<B>(val as i32)
                } else {
                    wide::<B>(val)
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
        // A clause's own checks are part of its condition, not obligations.
        let ig = replace(&mut self.in_ghost, false);
        let mut none = Vector::<u64>::new();
        self.chain_depth += 1;
        let r = self.chain_in(cb, cm, s, state, pc, all, wsp, &mut none);
        self.chain_depth -= 1;
        self.in_ghost = ig;
        return r;
    }

    // The definition of `r`, a call of spec function `d` over arguments `xs` in the caller's `state`:
    // its body walked with the arguments to each return, `!requires || (path && r == value) || ..`.
    // Where its `requires` holds, the body ends on one of the paths (its own proof: no panic, a
    // measure), so one path's disjunct is true. A fact of every obligation of the body under proof
    // (`holds`). The calls the walk makes stay opaque: one unfolding, as a lemma about the next call
    // (induction) gives the rest. A function without a body (`@trusted`) is defined by its `ensures`:
    // `!requires || ensures(r)`. With `by_ref`, the function returns a reference and `r` is the value
    // it refers to.
    fn define(self: &mut Self, r: u32, d: DefId, xs: &Vector<u32>, state: &Vector<u32>, by_ref: bool) {
        if self.defined.contains_key(&r) {
            return;
        }
        self.defined.insert(r, true);
        let mut cbp = self.kept(d);
        let axiom = cbp == null;
        if axiom && self.ast_of(d.module).ext(d.node).function.body == NODE_NONE {
            cbp = self.contract_body(d);
        }
        if cbp == null || unsafe (*cbp).returns != 1 || (unsafe (*cbp).args) as usize != xs.len() {
            return;
        }
        let cb = unsafe &*cbp;
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, cb.locals.len() + 1);
        frame.set(cb.locals.len(), state[state.len() - 1]);
        for j in 0..xs.len() {
            frame.set(cb.returns as usize + j, xs[j]);
        }
        let site = ir::ContractSite {
            pred: 0,
            chain: cb.entry,
            check: NONE,
            cont: 0,
            clause: 0,
            kind: CT_ENSURES,
            value: ir::IR_NONE,
        };
        let mut leaves = Vector::<u64>::new();
        let none = tok::Span { start: 0, end: 0 };
        let pc0 = Vector::<u32>::new();
        let om = replace(&mut self.mem, state);
        let ig = replace(&mut self.in_ghost, false);
        self.unfold += 1;
        self.chain_depth += 1;
        let co = replace(&mut self.chain_ovf, OVF_EXACT);
        let mut pre = self.tm.boolean(true);
        for j in 0..cb.contracts.len() {
            if cb.contracts[j].kind == CT_REQUIRES {
                let mut no = Vector::<u64>::new();
                let (fr, _v) = self.chain_in(cb, d.module, cb.contracts[j], &frame, &pc0, true, none, &mut no);
                pre = self.tm.and(pre, fr);
            }
        }
        let mut post = self.tm.boolean(true);
        if axiom {
            frame.set(0, pick(by_ref, self.tm.unary(T_REF, r, W_OTHER, false), r));
            for j in 0..cb.contracts.len() {
                if cb.contracts[j].kind == CT_ENSURES {
                    let mut no = Vector::<u64>::new();
                    let (fe, _v) = self.chain_in(cb, d.module, cb.contracts[j], &frame, &pc0, true, none, &mut no);
                    post = self.tm.and(post, fe);
                }
            }
        } else {
            let _ = self.chain_in(cb, d.module, site, &frame, &pc0, true, none, &mut leaves);
        }
        self.chain_ovf = co;
        self.chain_depth -= 1;
        self.unfold -= 1;
        self.in_ghost = ig;
        self.mem = om;
        let mut f = self.tm.not(pre);
        if axiom {
            f = self.tm.or(f, post);
        }
        // One path and no `requires`: the call is the value it returns. A recursive function's call stays a
        // term: its value would name every level below.
        if !axiom && !by_ref && leaves.len() == 1 && self.tm.is_true(pre) && !self.has_clause(d, CT_DECREASES) {
            let path = (leaves[0] >> 32) as u32;
            let v = (leaves[0] & 0xFFFFFFFFu64) as u32;
            if v != NONE && self.tm.is_true(path) && self.small(v) {
                self.exact.insert(r, v);
            } else if v != NONE && self.tm.is_true(path) && self.tm.is_bool(v) {
                self.qvalue.insert(r, v);
            }
        }
        if self.closed_def {
            return;
        }
        let st = self.alias_pool.len() as u64;
        for j in 0..leaves.len() {
            let v = (leaves[j] & 0xFFFFFFFFu64) as u32;
            if !by_ref && v != NONE && self.sq_of(v) != 0 {
                self.alias_pool.push(v);
            }
        }
        if self.alias_pool.len() as u64 != st {
            self.alias.insert(r, st << 32 | self.alias_pool.len() as u64 - st);
        }
        // A spec function's sequence or number: a goal whose facts decide the path names its value
        // (`decide`).
        if !axiom && !by_ref && leaves.len() != 0 && self.tm.is_true(pre) && self.is_ghost(d) && (self.seq_elem(
            d.module,
            cb.locals.at(0).ty,
        ) != TYPE_NONE || self.tm.is_int(r)) {
            let sp = self.spec_pool.len() as u64;
            for j in 0..leaves.len() {
                if (leaves[j] & 0xFFFFFFFFu64) as u32 != NONE {
                    self.spec_pool.push(leaves[j]);
                }
            }
            self.spec_leaves.insert(r, sp << 32 | self.spec_pool.len() as u64 - sp);
        }
        // A `bool` result every path knows: the call is the disjunction of its paths with the values they
        // return, one formula without a case per path (`a && b && c` is the conjunction). The paths are
        // disjoint, and they cover the body: it does not panic.
        let mut known = !by_ref && leaves.len() > 1 && self.tm.is_bool(r);
        for j in 0..leaves.len() {
            known = known && (leaves[j] & 0xFFFFFFFFu64) as u32 != NONE;
        }
        if known {
            let mut alts = Vector::<u32>::new();
            for j in 0..leaves.len() {
                let (path, v) = ((leaves[j] >> 32) as u32, (leaves[j] & 0xFFFFFFFFu64) as u32);
                // A path that tested the value it returns false (an early exit of `&&`) returns false.
                let nv = self.tm.not(v);
                if !self.conjunct(path, nv) {
                    alts.push(self.tm.and(path, v));
                }
            }
            let g = self.factor_or(&alts);
            let eq = self.tm.cmp(T_EQ, r, g);
            f = self.tm.or(f, eq);
            leaves.clear();
        }
        for j in 0..leaves.len() {
            let path = (leaves[j] >> 32) as u32;
            let v0 = (leaves[j] & 0xFFFFFFFFu64) as u32;
            // A reference result: the value it refers to; any value when the walk does not know it.
            let v = if !by_ref {
                v0
            } else if v0 != NONE && self.tm.at(v0).op == T_REF {
                self.tm.at(v0).a
            } else {
                NONE
            };
            let one = if v == NONE {
                path
            } else {
                // The result as its members, of the types the callee declares (`eta`), as each call
                // site spells it.
                let re = pick(by_ref, r, self.eta(d.module, cb.locals.at(0).ty, r, 0));
                let mut eq = self.tm.cmp(T_EQ, re, v);
                // A sequence's length as well: a length term of the value may be folded (`seq_len`), where
                // the equality gives none of the call's by congruence.
                if !by_ref && self.seq_elem(d.module, cb.locals.at(0).ty) != TYPE_NONE {
                    let nr = self.seq_len(re);
                    let nv = self.seq_len(v);
                    let le = self.tm.cmp(T_EQ, nr, nv);
                    eq = self.tm.and(eq, le);
                }
                self.tm.and(path, eq)
            };
            f = self.tm.or(f, one);
        }
        if !self.tm.is_true(f) && !self.tm.is_false(f) {
            self.anchor(r, f);
            self.specd.insert(r, true);
        }
        if self.has_clause(d, CT_DECREASES) {
            self.recd.insert(r, true);
        }
    }

    fn chain_in(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        s: ir::ContractSite,
        state: &Vector<u32>,
        pc: &Vector<u32>,
        all: bool,
        wsp: tok::Span,
        leaves_out: &mut Vector<u64>,
    ) (u32, u32) {
        // The paths that pass, one alternative each: `factor_or` takes out what they share.
        let mut alts = Vector::<u32>::new();
        let mut value = NONE;
        let mut subs = Vector::<Sub>::new();
        subs.push(Sub { state: state.clone(), conds: Vector::<u32>::new(), blk: s.chain });
        let mut leaves: u32 = 0;
        let mut edges = Vector::<u64>::new();
        // The path condition of the sub-path walked: `pc`, then its conditions (one buffer for the walk).
        let mut full = Vector::<u32>::with_capacity(pc.len() + 8);
        for _k in 0..STEP_BUDGET {
            if subs.len() == 0 {
                break;
            }
            if !self.spend() {
                self.budget_spent();
                return self.tm.boolean(false), NONE;
            }
            let mut sb = subs.pop().unwrap();
            full.clear();
            full.extend_copy(pc);
            full.extend_copy(&sb.conds);
            // A quantifier: its atom, past its loop.
            let qi = Prover::<B>::quant_at(cb, sb.blk);
            if qi != NONE {
                let qs = cb.quants[qi as usize];
                let q = self.quantifier(cb, cm, qi, &mut sb.state, &full, all);
                self.write_place(cb, cm, &mut sb.state, qs.result, q, all);
                sb.blk = qs.exit;
                subs.push(sb);
                continue;
            }
            let bb = *cb.blocks.at(sb.blk as usize);
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
                let v = self.rvalue(cb, cm, &mut sb.state, &mut full, st.rvalue, all, self.chain_ovf, key, sp);
                self.write_place(cb, cm, &mut sb.state, st.place, v, all);
            }
            for j in n0..full.len() {
                sb.conds.push(full[j]);
            }
            let t = bb.term;
            // A body walked to its returns (`define`): each return's path and result.
            if s.check == NONE && t.kind == ir::TM_RETURN {
                let v = self.local_val(cb, cm, &mut sb.state, 0);
                let mut path = self.tm.boolean(true);
                for j in 0..sb.conds.len() {
                    path = self.tm.and(path, sb.conds[j]);
                }
                leaves_out.push(path as u64 << 32 | v as u64);
                continue;
            }
            if sb.blk == s.check {
                let mut c = self.operand(cb, cm, &mut sb.state, t.a, all);

                // A value the path decides (a short-circuit's result): a refuted one adds no leaf.
                let nc = self.tm.not(c);
                if sb.conds.contains(&nc) || pc.contains(&nc) {
                    c = self.tm.boolean(false);
                } else if sb.conds.contains(&c) || pc.contains(&c) {
                    c = self.tm.boolean(true);
                }
                let mut path = self.tm.boolean(true);
                for j in 0..sb.conds.len() {
                    path = self.tm.and(path, sb.conds[j]);
                }
                let pc1 = self.tm.and(path, c);
                if !self.tm.is_false(pc1) {
                    alts.push(pc1);
                }
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
                // An edge whose condition the path refutes is never taken (a short-circuit's repeated
                // test of one value): no leaf. Each edge but the last takes a copy of the sub-path.
                let mut live: usize = 0;
                for j in 0..edges.len() {
                    let c = (edges[j] & 0xFFFFFFFFu64) as u32;
                    let nc = self.tm.not(c);
                    if !self.tm.is_false(c) && !sb.conds.contains(&nc) && !pc.contains(&nc) {
                        edges.set(live, edges[j]);
                        live += 1;
                    }
                }
                if live != 0 {
                    for j in 0..live - 1 {
                        let mut cs = sb.conds.clone();
                        cs.push((edges[j] & 0xFFFFFFFFu64) as u32);
                        subs.push(Sub { state: sb.state.clone(), conds: cs, blk: (edges[j] >> 32) as u32 });
                    }
                    sb.conds.push((edges[live - 1] & 0xFFFFFFFFu64) as u32);
                    sb.blk = (edges[live - 1] >> 32) as u32;
                    subs.push(sb);
                }
            } else if t.kind == ir::TM_CALL {
                let sp = if wsp.end > wsp.start {
                    wsp
                } else {
                    t.span
                };
                let key = OB_OVERFLOW << 56 | (cm as u64 & 0xFFFF) << 40 | 1 << 39 | t.span.start as u64;
                let n1 = full.len();
                self.chain_call(cb, cm, &mut sb.state, &mut full, &t, all, key, sp);
                for j in n1..full.len() {
                    sb.conds.push(full[j]);
                }
                sb.blk = t.t0;
                subs.push(sb);
            }
            // a return or an unreachable end: the chain panics on this path
        }
        return self.factor_or(&alts), value;
    }

    // A call of `trigger(x)`: `x`, a trigger of the quantifier whose body holds it (`utrig`); NONE for
    // another call.
    fn trigger_value(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let d = t.callee;
        if d.node == NODE_NONE || d.node != self.trigd || d.module as i32 != self.trigm || t.args_len != 1 || t.dests_len != 1 {
            return NONE;
        }
        let v = self.operand(cb, cm, state, cb.oper_pool[t.args_start as usize], all);
        if self.utrig_on && !self.utrig.contains(&v) {
            self.utrig.push(v);
        }
        return v;
    }

    // A call inside a contract chain: a wide integer's operation is its integer value (its overflow
    // proved under `pc`, obligation `key` at `sp`), a `const fn` call is a value of its arguments;
    // another call (an impure contract, reported apart) is a fresh unknown.
    fn chain_call(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
        key: u64,
        sp: tok::Span,
    ) {
        let mut r = self.trigger_value(cb, cm, state, t, all);
        if r == NONE {
            r = self.wide_op(cb, cm, state, pc, t, all, self.chain_ovf, key, sp);
        }
        if r == NONE && t.dests_len == 1 {
            r = self.secret_op(cb, cm, state, pc, t, all);
        }
        if r == NONE && t.dests_len == 1 {
            r = self.float_call(cb, cm, state, t, all);
        }
        if r == NONE && t.dests_len == 1 {
            r = self.soft_op(cb, cm, state, t, all);
        }
        if r == NONE {
            r = self.call_value(cb, cm, state, t, all);
            self.chain_ensures(cb, cm, state, t, r, all, sp);
        }
        if t.dests_len == 1 {
            self.write_place(cb, cm, state, cb.dest_pool[t.dests_start as usize], r, all);
        } else {
            for j in t.dests_start..t.dests_start + t.dests_len {
                self.write_place(cb, cm, state, cb.dest_pool[j as usize], NONE, all);
            }
        }
    }

    // The `ensures` of call `t` inside a contract chain, of result `r`: a callee that is no spec function
    // and ends (`ends`) has its results where they hold. They define `r` (`anchor`): a goal that names it
    // takes them as facts, as a spec function's definition.
    fn chain_ensures(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        r: u32,
        all: bool,
        sp: tok::Span,
    ) {
        let d = self.contract_of(t.callee);
        if r == NONE || d.node == NODE_NONE || self.is_ghost(t.callee) || !self.has_clause(d, CT_ENSURES) || self.chain_depth > 4 || !self.ends(
            t.callee,
            0,
        ) {
            return;
        }
        let cbp = self.contract_body(d);
        if cbp == null {
            return;
        }
        let ccb = unsafe &*cbp;
        let dm = d.module;
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, ccb.locals.len() + 1);
        frame.set(ccb.locals.len(), state[state.len() - 1]);
        for j in 0..t.args_len {
            if ccb.returns + j < ccb.locals.len() as u32 {
                let x = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + j) as usize], all);
                frame.set((ccb.returns + j) as usize, self.implicit_ref(cb, t, j, x));
            }
        }
        if ccb.returns == 1 {
            frame.set(0, r);
        }
        let mut binds = Vector::<u64>::new();
        self.contract_binds(cb, cm, t, d, &mut binds);
        let outer = replace(&mut self.subst, binds);
        // The references the arguments hold read the memory the chain reads: the caller's at a call's
        // clauses (`self.mem`), else the chain's own state.
        let om = self.mem;
        if om == null {
            self.mem = state;
        }
        let co = replace(&mut self.chain_ovf, OVF_EXACT);
        // The definition holds on every path: no fact of this one prunes a branch of the clauses.
        let mut none = Vector::<u32>::new();
        for j in 0..ccb.contracts.len() {
            let s = ccb.contracts[j];
            if (s.kind == CT_OLD || s.kind == CT_OLD_RUN) && s.value != ir::IR_NONE {
                let (_f, v) = self.chain(ccb, dm, s, &frame, &mut none, true, sp);
                let o = ccb.places.at(ccb.operands.at(s.value as usize).data as usize).base;
                if v != NONE {
                    frame.set(o as usize, v);
                }
            }
        }
        for j in 0..ccb.contracts.len() {
            let s = ccb.contracts[j];
            if s.kind == CT_ENSURES {
                let (f, _v) = self.chain(ccb, dm, s, &frame, &mut none, true, sp);
                self.view_defs(f, 0);
                self.anchor(r, f);
            }
        }
        self.chain_ovf = co;
        self.mem = om;
        self.subst = outer;
    }

    // Callee `d` as an operation of a wide integer (`UInt<N>`, `Int<N>`; std's conformances in its
    // `int` module, which keep these meanings): WK_FROM `from` (`u64` or `i64` to the type), WK_EQ `eq`,
    // WK_CMP `cmp` (-1, 0 or 1), WK_ADD, WK_SUB and WK_MUL `add`, `sub` and `mul` (trap or wrap on
    // overflow as the built-in integers do), WK_DIV and WK_REM `div` and `rem` (a zero divisor and
    // `MIN / -1` trap), WK_AND, WK_OR, WK_XOR and WK_NOT the bit operations, WK_SHL and WK_SHR `shl`
    // and `shr` (a count of at least the width gives 0, or -1 for a negative `Int` shifted right: no
    // trap); and of the built-in integers (std's `core` module): WK_WADD, WK_WSUB, WK_WMUL and WK_WNEG
    // `wrapping_add`, `wrapping_sub`, `wrapping_mul` and `wrapping_neg` (the result's low bits),
    // WK_ROTL and WK_ROTR `rotate_left` and `rotate_right`, WK_CLZ and WK_CTZ `leading_zeros` and
    // `trailing_zeros`; 0 for any other callee.
    fn wide_kind(self: &Self, d: DefId) u8 {
        let core = self.wcore.node != NODE_NONE && d.module == self.wcore.mid;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || self.wuint.node == NODE_NONE || d.module != self.wuint.mid && d.module != self.wint.mid && !core || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return 0;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return 0;
        }
        let c = a.container_of(d.node);
        if c == NODE_NONE || a.at_const(c).kind != NodeKind::NODE_EXTEND {
            return 0;
        }
        let name = self.text(d.module, a.at_const(a.ext_name(d.node)).span);
        if core {
            return if name == "wrapping_add" {
                WK_WADD
            } else if name == "wrapping_sub" {
                WK_WSUB
            } else if name == "wrapping_mul" {
                WK_WMUL
            } else if name == "wrapping_neg" {
                WK_WNEG
            } else if name == "rotate_left" {
                WK_ROTL
            } else if name == "rotate_right" {
                WK_ROTR
            } else if name == "leading_zeros" {
                WK_CLZ
            } else if name == "trailing_zeros" {
                WK_CTZ
            } else {
                0
            };
        }
        return if name == "from" {
            WK_FROM
        } else if name == "eq" {
            WK_EQ
        } else if name == "cmp" {
            WK_CMP
        } else if name == "add" {
            WK_ADD
        } else if name == "sub" {
            WK_SUB
        } else if name == "mul" {
            WK_MUL
        } else if name == "div" {
            WK_DIV
        } else if name == "rem" {
            WK_REM
        } else if name == "bit_and" {
            WK_AND
        } else if name == "bit_or" {
            WK_OR
        } else if name == "bit_xor" {
            WK_XOR
        } else if name == "bit_not" {
            WK_NOT
        } else if name == "shl" {
            WK_SHL
        } else if name == "shr" {
            WK_SHR
        } else {
            0
        };
    }

    // The value of call `t` when it is a wide integer's operation over integer values: `from` of a
    // value the type holds keeps it, `eq` compares, `cmp` is the order (`T_ORD`, which a comparison
    // with a constant turns into one of the operands), `add`, `sub` and `mul` are the exact result,
    // its overflow checked by `ovf` under `pc` (obligation `key` at `sp`). NONE otherwise: the caller
    // models the call as any other.
    fn wide_op(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
        ovf: u8,
        key: u64,
        sp: tok::Span,
    ) u32 {
        let k = self.wide_kind(t.callee);
        let n = pick(k == WK_FROM || k == WK_NOT || k == WK_WNEG || k == WK_CLZ || k == WK_CTZ, 1u32, 2);
        if k == 0 || t.args_len != n || t.dests_len != 1 {
            return NONE;
        }
        let rty = cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty;
        let (w, sg) = self.ty_of(cm, rty);
        let mut xs: [u32; 2] = [NONE, NONE];
        for j in 0..n {
            let oid = cb.oper_pool[(t.args_start + j) as usize];
            let mut x = self.operand(cb, cm, state, oid, all);
            // `self` and `other` are shared references: their values.
            let oy = *self.ast_of(cm).type_at(cb.operands.at(oid as usize).ty);
            if !self.autoref(cb, cm, t, j) && oy.kind == TypeKind::TYPE_REFERENCE {
                x = self.deref(state, x, cm, oy.as_data.elem);
            }
            if !self.tm.is_int(x) {
                return NONE;
            }
            xs[j as usize] = x;
        }
        let a = xs[0];
        let b = xs[1];
        if k == WK_FROM {
            return self.widened(a, w, sg);
        }
        if k == WK_EQ {
            return self.tm.cmp(T_EQ, a, b);
        }
        if k == WK_CMP {
            return pick(w > W_BOOL, self.tm.ord(a, b, w, sg), NONE);
        }
        if w <= W_BOOL || w > 64 && k >= WK_WADD {
            return NONE;
        }
        if k >= WK_WADD && k <= WK_WNEG {
            let e = if k == WK_WNEG {
                self.tm.neg(a, w, sg)
            } else {
                self.tm.arith(pick(k == WK_WADD, T_ADD, pick(k == WK_WSUB, T_SUB, T_MUL)), a, b, w, sg)
            };
            return self.tm.unary(T_CAST, e, w, sg);
        }
        if k == WK_ROTL || k == WK_ROTR {
            return self.rotated(k == WK_ROTL, a, b, w, sg);
        }
        if k == WK_CLZ || k == WK_CTZ {
            return self.zeros(pc, k == WK_CLZ, a, w, sg);
        }
        if k == WK_ADD || k == WK_SUB || k == WK_MUL {
            let op = if k == WK_ADD {
                T_ADD
            } else if k == WK_SUB {
                T_SUB
            } else {
                T_MUL
            };
            let e = self.tm.arith(op, a, b, w, sg);
            return self.checked(e, pc, ovf, key, sp);
        }
        if k == WK_DIV || k == WK_REM {
            // A zero divisor traps: past the operation it is not zero.
            let z = self.tm.int(Num::<B>::zero(), self.tm.at(b).w, self.tm.at(b).sg);
            let nz = self.tm.cmp(T_NE, b, z);
            self.check_fact(pc, nz, key, sp);
            return self.divided(pc, k == WK_DIV, a, b, w, sg);
        }
        if k == WK_NOT {
            return self.tm.unary(T_BNOT, a, w, sg);
        }
        if k == WK_SHL || k == WK_SHR {
            // `k` 1: the wide shift, which gives 0 (or -1) for a count past the width.
            let r = self.tm.make(
                Term::<B> { k: Num::<B>::one(), a: a, b: b, op: pick(k == WK_SHL, T_SHL, T_SHR), w: w, sg: sg },
            );
            self.shifted(pc, r);
            return r;
        }
        let op = if k == WK_AND {
            T_BAND
        } else if k == WK_OR {
            T_BOR
        } else {
            T_BXOR
        };
        return self.tm.arith(op, a, b, w, sg);
    }

    // The width of the integer a `Secret` of type `ty` (module `m`, through a reference) holds: (W_OTHER,
    // false) for another type.
    fn secret_elem(self: &Self, m: ModuleId, ty: TypeId) (u16, bool) {
        if self.secd == NODE_NONE || ty == TYPE_NONE {
            return W_OTHER, false;
        }
        let (m1, t1) = self.resolve(m, ty);
        let mut y = *self.ast_of(m1).type_at(t1);
        if y.kind == TypeKind::TYPE_REFERENCE {
            y = *self.ast_of(m1).type_at(y.as_data.elem);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return W_OTHER, false;
        }
        let inst = self.ast_of(m1).instance(y.as_data.inst);
        if inst.module != self.secm as ModuleId || inst.decl != self.secd || inst.n != 1 || self.float_w(
            m1,
            inst.args[0],
        ) != 0 {
            return W_OTHER, false;
        }
        return self.ty_of(m1, inst.args[0]);
    }

    // The value of call `t` of a C library function an IEEE 754 operation defines: `sqrt`, `fabs`,
    // `copysign`, `fma`, `round`, `floor`, `ceil` and `trunc`, of `f32` (an `f` suffix) or `f64`, or of the
    // `f32` and `f64` method that calls it (`abs` for `fabs`, `mul_add` for `fma`, the others by name);
    // and the methods `to_bits` and `from_bits`, which keep the encoding. NONE for another call, or in a
    // build that may rewrite float operations.
    fn float_call(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || t.args_len == 0 || t.args_len > 3 {
            return NONE;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return NONE;
        }
        // An extern function, or a method of `f32` or `f64` in std's core, which calls it.
        let ext = a.ext(d.node).function.is_extern();
        let c = a.container_of(d.node);
        let method = self.wcore.node != NODE_NONE && d.module == self.wcore.mid && c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND;
        if !ext && !method {
            return NONE;
        }
        let owned = String::from_str(self.text(d.module, a.at_const(a.ext_name(d.node)).span));
        let full = owned.as_str();
        // `to_bits` and `from_bits` keep the encoding, the value both sides hold.
        if method && t.args_len == 1 && (full == "to_bits" || full == "from_bits") {
            let oid = cb.oper_pool[t.args_start as usize];
            let rty = cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty;
            let (fty, ity) = pick(
                full == "to_bits",
                (cb.operands.at(oid as usize).ty, rty),
                (rty, cb.operands.at(oid as usize).ty),
            );
            let fw = self.float_w(cm, fty);
            let (iw, isg) = self.ty_of(cm, ity);
            if fw == 0 || iw != fw || isg {
                return NONE;
            }
            return self.operand(cb, cm, state, oid, all);
        }
        let fw = self.float_w(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty);
        if fw == 0 {
            return NONE;
        }
        // The `f32` name is the `f64` one with an `f`; a method's is the operation's.
        let name = if method {
            if full == "abs" {
                "fabs"
            } else if full == "mul_add" {
                "fma"
            } else {
                full
            }
        } else if fw == 32 && full.ends_with("f") {
            full.slice(0, full.len() - 1)
        } else if fw == 32 {
            return NONE;
        } else {
            full
        };
        let n = t.args_len;
        let one_arg = name == "sqrt" || name == "fabs" || name == "round" || name == "floor" || name == "ceil" || name == "trunc";
        let want: u32 = if one_arg || method && (name == "recip" || name == "fract" || class_of(name) != 0) {
            1
        } else if name == "copysign" {
            2
        } else if name == "fma" {
            3
        } else {
            0
        };
        if want == 0 || n != want {
            return NONE;
        }
        let mut xs = Vector::<u32>::with_capacity(3);
        for j in 0..n {
            let oid = cb.oper_pool[(t.args_start + j) as usize];
            if self.float_w(cm, cb.operands.at(oid as usize).ty) != fw {
                return NONE;
            }
            xs.push(self.operand(cb, cm, state, oid, all));
        }
        let fd = host_fd(fw);
        return if name == "sqrt" {
            self.tm.fconv(T_FSQRT, xs[0], fw, false, fd)
        } else if name == "round" || name == "floor" || name == "ceil" || name == "trunc" {
            let md = pick(
                name == "round",
                FR_ROUND,
                pick(name == "floor", FR_FLOOR, pick(name == "ceil", FR_CEIL, FR_TRUNC)),
            );
            self.tm.frint(xs[0], md, fw, fd)
        } else if name == "fabs" {
            self.tm.fabs(xs[0], fw)
        } else if name == "copysign" {
            self.tm.fcopysign(xs[0], xs[1], fw)
        } else if name == "recip" {
            let one = self.tm.int(u64_val::<B>(pick(fw == 32, 1.0f32.to_bits(), 1.0f64.to_bits())), fw, false);
            let r = self.fquot(one, xs[0], fw, fd);
            let e = self.tm.farith(T_FDIV, one, xs[0], fw, fd);
            self.tm.set_shape(r, e);
            r
        } else if name == "fract" {
            let tr = self.tm.frint(xs[0], FR_TRUNC, fw, fd);
            let nt = self.tm.fneg(tr, fw);
            let r0 = self.fsum(xs[0], nt, fw, fd);
            let r = self.reassoc(cb, T_FADD, r0, xs[0], nt, fw, fd);
            let e = self.tm.farith(T_FADD, xs[0], nt, fw, fd);
            self.tm.set_shape(r, e);
            r
        } else if name == "fma" {
            self.tm.ffma(&xs, fw, fd)
        } else {
            self.float_class(class_of(name), xs[0], fw, fd)
        };
    }

    // Callee `d` as an operation of `Float<E, F, FAMILY>` (std's `float` module, whose methods keep these
    // meanings: `soft_op`), SK_*; 0 for another callee.
    fn soft_kind(self: &Self, d: DefId) u8 {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || self.wflt.node == NODE_NONE || d.module != self.wflt.mid || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return 0;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return 0;
        }
        let c = a.container_of(d.node);
        if c == NODE_NONE || a.at_const(c).kind != NodeKind::NODE_EXTEND {
            return 0;
        }
        let ty = a.type_at(a.type_of(a.ext(c).extend_def.target_type));
        if ty.kind != TypeKind::TYPE_INSTANCE || a.instance(ty.as_data.inst).decl != self.wflt.node {
            return 0;
        }
        return soft_of(self.text(d.module, a.at_const(a.ext_name(d.node)).span));
    }

    // The value of call `t` when it is an operation of `Float<E, F, FAMILY>` (`soft_kind`), a float of its
    // encoding's width and format: the arithmetic, square root and fused multiply-add rounded as IEEE 754
    // rounds (the FINITE_ONLY family saturates); `rem` C's `fmod`; `eq` the encodings' equality and `cmp`
    // their total order (std's `Eq` and `Ord`); `ieee_eq`, `ieee_lt`, `ieee_le` the IEEE comparisons; the
    // classifications; the conversions; the constants. NONE otherwise, and for an operation that computes
    // in hardware floats where the build may rewrite them: the caller models the call as any other.
    fn soft_op(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, t: &ir::Terminator, all: bool) u32 {
        let k = self.soft_kind(t.callee);
        if k == 0 || t.dests_len != 1 || t.args_len > 3 {
            return NONE;
        }
        let rty = cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty;
        let (rw, rfd) = self.soft_fmt(cm, rty);
        let mut xs = Vector::<u32>::with_capacity(3);
        let mut fw: [u16; 3] = [0, 0, 0];
        let mut fds: [u64; 3] = [0, 0, 0];
        for j in 0..t.args_len {
            let oid = cb.oper_pool[(t.args_start + j) as usize];
            let mut x = self.operand(cb, cm, state, oid, all);
            let mut oty = cb.operands.at(oid as usize).ty;
            let oy = *self.ast_of(cm).type_at(oty);
            if !self.autoref(cb, cm, t, j) && oy.kind == TypeKind::TYPE_REFERENCE {
                x = self.deref(state, x, cm, oy.as_data.elem);
                oty = oy.as_data.elem;
            } else if oy.kind == TypeKind::TYPE_REFERENCE {
                oty = oy.as_data.elem;
            }
            let (w0, f0) = self.soft_fmt(cm, oty);
            fw[j as usize] = w0;
            fds[j as usize] = f0;
            if !self.tm.is_int(x) && !self.tm.is_bool(x) {
                return NONE;
            }
            xs.push(x);
        }
        let n = t.args_len as usize;
        // Bit operations on the encoding.
        if k >= SK_CLASS {
            return pick(n == 1 && fw[0] != 0, self.float_class(k - SK_CLASS, xs[0], fw[0], fds[0]), NONE);
        }
        if k == SK_NEG || k == SK_ABS || k == SK_COPYSIGN {
            if rw == 0 || fw[0] != rw || n != pick(k == SK_COPYSIGN, 2usize, 1) {
                return NONE;
            }
            return if k == SK_NEG {
                self.tm.fneg(xs[0], rw)
            } else if k == SK_ABS {
                self.tm.fabs(xs[0], rw)
            } else {
                self.tm.fcopysign(xs[0], xs[1], rw)
            };
        }
        if k == SK_EQ || k == SK_CMP {
            if n != 2 || fw[0] == 0 || fw[1] != fw[0] {
                return NONE;
            }
            if k == SK_EQ {
                return self.tm.cmp(T_EQ, xs[0], xs[1]);
            }
            let (w, sg) = self.ty_of(cm, rty);
            // std's `Float::total_key`.
            let ka = self.tm.fkey(xs[0], fw[0], fds[0]);
            let kb = self.tm.fkey(xs[1], fw[0], fds[0]);
            return pick(w > W_BOOL, self.tm.ord(ka, kb, w, sg), NONE);
        }
        if k == SK_TO_RAW || k == SK_FROM_RAW {
            let (w, sg) = self.ty_of(cm, rty);
            let xw = self.tm.at(xs[0]).w;
            return pick(n == 1 && w == xw && !sg && !self.tm.at(xs[0]).sg, xs[0], NONE);
        }
        if k >= SK_ZERO {
            return self.soft_const(k, &xs, rw, rfd);
        }
        // Operations that round: in software, but f16, the 8-bit formats and binary128 may compute in
        // hardware floats, which the build's float rewrites change.
        if self.fmath() != 0 {
            return NONE;
        }
        if k == SK_IEQ || k == SK_ILT || k == SK_ILE {
            if n != 2 || fw[0] == 0 || fw[1] != fw[0] {
                return NONE;
            }
            let op = pick(k == SK_IEQ, T_FEQ, pick(k == SK_ILT, T_FLT, T_FLE));
            return self.tm.fcmp(op, xs[0], xs[1], fds[0]);
        }
        if k == SK_TO_F32 || k == SK_TO_F64 {
            let hw = pick(k == SK_TO_F32, 32u16, 64u16);
            return pick(n == 1 && fw[0] != 0, self.tm.fconv(T_FCVT, xs[0], hw, false, host_fd(hw) | fds[0] << 32), NONE);
        }
        if rw == 0 {
            return NONE;
        }
        if k == SK_FROM_F32 || k == SK_FROM_F64 {
            let hw = pick(k == SK_FROM_F32, 32u16, 64u16);
            return pick(
                n == 1 && self.tm.at(xs[0]).w == hw,
                self.tm.fconv(T_FCVT, xs[0], rw, false, rfd | host_fd(hw) << 32),
                NONE,
            );
        }
        if k == SK_CONVERT {
            return pick(n == 1 && fw[0] != 0, self.tm.fconv(T_FCVT, xs[0], rw, false, rfd | fds[0] << 32), NONE);
        }
        if k == SK_FROM_UINT || k == SK_FROM_INT {
            let xw = self.tm.at(xs[0]).w;
            return pick(n == 1 && xw > W_BOOL && !exact_w(xw), self.tm.fconv(T_ITOF, xs[0], rw, false, rfd), NONE);
        }
        for j in 0..n {
            if fw[j] != rw || fds[j] != rfd {
                return NONE;
            }
        }
        return if k >= SK_ADD && k <= SK_REM && n == 2 {
            if k == SK_SUB {
                let nb = self.tm.fneg(xs[1], rw);
                self.tm.farith(T_FADD, xs[0], nb, rw, rfd)
            } else {
                let op = if k == SK_ADD {
                    T_FADD
                } else if k == SK_MUL {
                    T_FMUL
                } else if k == SK_DIV {
                    T_FDIV
                } else {
                    T_FREM
                };
                self.tm.farith(op, xs[0], xs[1], rw, rfd)
            }
        } else if k == SK_SQRT && n == 1 {
            self.tm.fconv(T_FSQRT, xs[0], rw, false, rfd)
        } else if k == SK_FMA && n == 3 {
            self.tm.ffma(&xs, rw, rfd)
        } else if k >= SK_TRUNC && k <= SK_EVEN && n == 1 {
            let md = if k == SK_TRUNC {
                FR_TRUNC
            } else if k == SK_FLOOR {
                FR_FLOOR
            } else if k == SK_CEIL {
                FR_CEIL
            } else if k == SK_ROUND {
                FR_ROUND
            } else {
                FR_EVEN
            };
            self.tm.frint(xs[0], md, rw, rfd)
        } else {
            NONE
        };
    }

    // The constant `k` (SK_ZERO ..) of format (`w`, `fd`), its argument `xs` (a sign); NONE where the
    // argument is not a constant, and for the infinity of a format without one (std panics).
    fn soft_const(self: &mut Self, k: u8, xs: &Vector<u32>, w: u16, fd: u64) u32 {
        if w == 0 {
            return NONE;
        }
        let m = (fd & 0xFFFF) as usize;
        let e = w as usize - 1 - m;
        let fo = (fd & FD_FINITE) != 0;
        let (sb, mg) = Terms::<B>::fsign_num(w);
        let one = Num::<B>::one();
        let ef = (one << e) - one << m;
        let mut neg = false;
        if k == SK_INF || k == SK_MAX {
            if xs.len() != 1 || self.tm.at(xs[0]).op != T_BOOL {
                return NONE;
            }
            neg = !self.tm.at(xs[0]).k.is_zero();
        } else if xs.len() != 0 {
            return NONE;
        }
        let v = if k == SK_ZERO {
            Num::<B>::zero()
        } else if k == SK_NEG_ZERO {
            sb
        } else if k == SK_ONE {
            (one << e - 1) - one << m
        } else if k == SK_INF {
            if fo {
                return NONE;
            }
            ef
        } else if k == SK_NAN {
            pick(fo, mg, ef | one << m - 1)
        } else if k == SK_MAX {
            pick(fo, mg - one, ef - one)
        } else {
            one
        };
        return self.tm.int(pick(neg, v | sb, v), w, false);
    }

    // Classification `c` (`class_of`) of float `x` of width `w` and format `fd`: the sign bit of the
    // encoding, or a float comparison of its magnitude (whose bits the operations' circuits read too).
    fn float_class(self: &mut Self, c: u8, x: u32, w: u16, fd: u64) u32 {
        let m = (fd & 0xFFFF) as usize;
        let e = w as usize - 1 - m;
        let fo = (fd & FD_FINITE) != 0;
        let (sb, _mg) = Terms::<B>::fsign_num(w);
        if c == FC_NEG || c == FC_POS {
            let s = self.tm.int(sb, w, false);
            return pick(c == FC_NEG, self.tm.cmp(T_LE, s, x), self.tm.cmp(T_LT, x, s));
        }
        let one = Num::<B>::one();
        let mag = self.tm.fabs(x, w);
        let zero = self.tm.int(Num::<B>::zero(), w, false);
        let inf = self.tm.int((one << e) - one << m, w, false);
        let norm = self.tm.int(one << m, w, false);
        let num = self.tm.fcmp(T_FEQ, x, x, fd);
        return if c == FC_NAN {
            self.tm.not(num)
        } else if c == FC_INF {
            pick(fo, self.tm.boolean(false), self.tm.fcmp(T_FEQ, mag, inf, fd))
        } else if c == FC_FINITE {
            pick(fo, num, self.tm.fcmp(T_FLT, mag, inf, fd))
        } else if c == FC_ZERO {
            self.tm.fcmp(T_FEQ, mag, zero, fd)
        } else if c == FC_NORMAL {
            let lo = self.tm.fcmp(T_FLE, norm, mag, fd);
            let hi = pick(fo, num, self.tm.fcmp(T_FLT, mag, inf, fd));
            self.tm.and(lo, hi)
        } else {
            let lo = self.tm.fcmp(T_FLT, zero, mag, fd);
            let hi = self.tm.fcmp(T_FLT, mag, norm, fd);
            self.tm.and(lo, hi)
        };
    }

    // The value of call `t` of a method of `std::crypto::secret`'s `Secret<T>`, as its body computes it
    // from the integer `v` each `Secret` holds (member 0), at `T`'s width: `new` and `declassify` move
    // it in and out; `eq`, `ne`, `lt`, `le`, `gt` and `ge` compare (a `Secret<bool>`); `pick(c, a, b)`
    // is `a` where `c`, else `b`; `rotate_left` and `rotate_right` rotate (`rotated`); `cast` zero-extends
    // or truncates; `add`, `sub`, `mul` and `neg` wrap; the bit operations, and `shl` and `shr` by a count
    // below the width (the body's assertion, a check as for `<<`). NONE for another call.
    fn secret_op(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let d = t.callee;
        if self.secm < 0 || d.module != self.secm as ModuleId || d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || t.args_len == 0 || t.args_len > 3 {
            return NONE;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return NONE;
        }
        let owned = String::from_str(self.text(d.module, a.at_const(a.ext_name(d.node)).span));
        let name = owned.as_str();
        let rty = cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty;
        let (rw, _rsg) = self.secret_elem(cm, rty);
        // The arguments: a `Secret`'s integer, or the value of another argument.
        let mut xs: [u32; 3] = [NONE, NONE, NONE];
        let mut ws: [u16; 3] = [W_OTHER, W_OTHER, W_OTHER];
        for j in 0..t.args_len {
            let oid = cb.oper_pool[(t.args_start + j) as usize];
            let mut x = self.operand(cb, cm, state, oid, all);
            let oty = cb.operands.at(oid as usize).ty;
            let oy = *self.ast_of(cm).type_at(oty);
            if !self.autoref(cb, cm, t, j) && oy.kind == TypeKind::TYPE_REFERENCE {
                x = self.deref(state, x, cm, oy.as_data.elem);
            }
            let (ew, _esg) = self.secret_elem(cm, oty);
            if ew != W_OTHER {
                let k0 = self.tm.int(Num::<B>::zero(), 64, false);
                x = self.sel(x, k0, ew, false);
            }
            xs[j as usize] = x;
            ws[j as usize] = ew;
        }
        let w = ws[0];
        let x = xs[0];
        let y = xs[1];
        let n = t.args_len;
        let v = if name == "new" && n == 1 && rw != W_OTHER {
            x
        } else if name == "declassify" && n == 1 && w != W_OTHER {
            return x;
        } else if n == 2 && w != W_OTHER && ws[1] == w && (name == "eq" || name == "ne" || name == "lt" || name == "le" || name == "gt" || name == "ge") {
            if name == "eq" {
                self.tm.cmp(T_EQ, x, y)
            } else if name == "ne" {
                self.tm.cmp(T_NE, x, y)
            } else if name == "lt" {
                self.tm.cmp(T_LT, x, y)
            } else if name == "le" {
                self.tm.cmp(T_LE, x, y)
            } else if name == "gt" {
                self.tm.cmp(T_LT, y, x)
            } else {
                self.tm.cmp(T_LE, y, x)
            }
        } else if name == "pick" && n == 3 && w == W_BOOL && ws[1] == rw && ws[2] == rw && rw != W_OTHER {
            let r = self.tm.var(rw, false);
            let e1 = self.tm.cmp(T_EQ, r, y);
            let e2 = self.tm.cmp(T_EQ, r, xs[2]);
            let nc = self.tm.not(x);
            let f1 = self.tm.or(nc, e1);
            let f2 = self.tm.or(x, e2);
            let f = self.tm.and(f1, f2);
            self.derive(pc, f, r);
            r
        } else if w == W_BOOL && rw == W_BOOL && (name == "bit_and" || name == "bit_or" || name == "bit_xor") && n == 2 {
            if name == "bit_and" {
                self.tm.and(x, y)
            } else if name == "bit_or" {
                self.tm.or(x, y)
            } else {
                self.tm.cmp(T_NE, x, y)
            }
        } else if w == W_BOOL && rw == W_BOOL && name == "bit_not" && n == 1 {
            self.tm.not(x)
        } else if w <= W_BOOL || w > 64 || rw == W_OTHER {
            return NONE;
        } else if (name == "rotate_left" || name == "rotate_right") && n == 2 && self.tm.is_int(y) {
            self.rotated(name == "rotate_left", x, y, w, false)
        } else if name == "cast" && n == 1 {
            if rw >= w {
                self.widened(x, rw, false)
            } else {
                self.tm.unary(T_CAST, x, rw, false)
            }
        } else if (name == "add" || name == "sub" || name == "mul") && n == 2 && ws[1] == w {
            let op = if name == "add" {
                T_ADD
            } else if name == "sub" {
                T_SUB
            } else {
                T_MUL
            };
            let e = self.tm.arith(op, x, y, w, false);
            self.tm.unary(T_CAST, e, w, false)
        } else if name == "neg" && n == 1 {
            let e = self.tm.neg(x, w, false);
            self.tm.unary(T_CAST, e, w, false)
        } else if (name == "bit_and" || name == "bit_or" || name == "bit_xor") && n == 2 && ws[1] == w {
            let op = if name == "bit_and" {
                T_BAND
            } else if name == "bit_or" {
                T_BOR
            } else {
                T_BXOR
            };
            self.tm.arith(op, x, y, w, false)
        } else if name == "bit_not" && n == 1 {
            self.tm.unary(T_BNOT, x, w, false)
        } else if (name == "shl" || name == "shr") && n == 2 && self.tm.is_int(y) {
            let yx = self.tm.at(y);
            let wv = self.tm.int(wide::<B>(w), yx.w, yx.sg);
            let c = self.tm.cmp(T_LT, y, wv);
            self.check_fact(pc, c, (cm as u64 & 0xFFFF) << 40 | 1 << 38 | t.span.start as u64, t.span);
            let r = self.tm.arith(pick(name == "shl", T_SHL, T_SHR), x, y, w, false);
            self.shifted(pc, r);
            r
        } else {
            return NONE;
        };
        let mut one = Vector::<u32>::with_capacity(1);
        one.push(v);
        return self.tm.pool(T_AGG, &one, Num::<B>::zero());
    }

    // The count of `x`'s leading (`lead`) or trailing zero bits, of type (`w`, `sg`): a function of `x`
    // (a key past every callee's, below the sequences' functions), defined by facts on `pc`: the width
    // for 0; else for `leading_zeros` the bit below them is set (`x >> (xw - 1 - r) == 1`), for
    // `trailing_zeros` the bit above them is set and the bits below it are clear.
    fn zeros(self: &mut Self, pc: &mut Vector<u32>, lead: bool, x: u32, w: u16, sg: bool) u32 {
        let xt = self.tm.at(x);
        let xw = xt.w;
        let u = if xt.sg {
            self.tm.unary(T_CAST, x, xw, false)
        } else {
            x
        };
        // A function of `u`: one term for each evaluation.
        let mut xs = Vector::<u32>::with_capacity(1);
        xs.push(u);
        let r = self.tm.call_k(Num::<B>::one().shl(71) + wide::<B>(pick(lead, 1i64, 2)), &xs, w, sg);
        let z = self.tm.int(Num::<B>::zero(), xw, false);
        let one = self.tm.int(Num::<B>::one(), xw, false);
        let wv = self.tm.int(wide::<B>(xw), w, sg);
        let is0 = self.tm.cmp(T_EQ, u, z);
        let rw = self.tm.cmp(T_EQ, r, wv);
        let at0 = self.tm.and(is0, rw);
        let n0 = self.tm.not(is0);
        let below = self.tm.cmp(T_LT, r, wv);
        let mut set = self.tm.and(n0, below);
        if lead {
            let top = self.tm.int(wide::<B>(xw as i64 - 1), w, sg);
            let cnt = self.tm.arith(T_SUB, top, r, w, sg);
            let sh = self.tm.arith(T_SHR, u, cnt, xw, false);
            let e = self.tm.cmp(T_EQ, sh, one);
            set = self.tm.and(set, e);
        } else {
            let sh = self.tm.arith(T_SHR, u, r, xw, false);
            let bit = self.tm.arith(T_BAND, sh, one, xw, false);
            let e = self.tm.cmp(T_EQ, bit, one);
            let p = self.tm.arith(T_SHL, one, r, xw, false);
            let mask = self.tm.arith(T_SUB, p, one, xw, false);
            let low = self.tm.arith(T_BAND, u, mask, xw, false);
            let e2 = self.tm.cmp(T_EQ, low, z);
            set = self.tm.and(set, e);
            set = self.tm.and(set, e2);
        }
        let f = self.tm.or(at0, set);
        self.derive(pc, f, r);
        return r;
    }

    // `x` rotated left (`left`) or right by `n % w` bits, as its body computes it: for unsigned `x`,
    // `x << k | x >> (w - k) % w` with `k = n % w`; a signed `x` rotates its bits as unsigned.
    fn rotated(self: &mut Self, left: bool, x: u32, n: u32, w: u16, sg: bool) u32 {
        let u = if sg {
            self.tm.unary(T_CAST, x, w, false)
        } else {
            x
        };
        let nt = self.tm.at(n);
        let mask = self.tm.int(wide::<B>(w as i64 - 1), nt.w, nt.sg);
        let wv = wide::<B>(w);
        let width = self.tm.int(wv, nt.w, nt.sg);
        let k = if nt.op == T_INT {
            self.tm.int(nt.k.rem_euclid(&wv), nt.w, nt.sg)
        } else {
            self.tm.arith(T_BAND, n, mask, nt.w, nt.sg)
        };
        let back = self.tm.arith(T_SUB, width, k, nt.w, nt.sg);
        let kt = self.tm.at(back);
        let j = if kt.op == T_INT {
            self.tm.int(kt.k.rem_euclid(&wv), nt.w, nt.sg)
        } else {
            self.tm.arith(T_BAND, back, mask, nt.w, nt.sg)
        };
        let p = self.tm.arith(pick(left, T_SHL, T_SHR), u, k, w, false);
        let q = self.tm.arith(pick(left, T_SHR, T_SHL), u, j, w, false);
        let r = self.tm.arith(T_BOR, p, q, w, false);
        return if sg {
            self.tm.unary(T_CAST, r, w, true)
        } else {
            r
        };
    }

    // `x / y` (`div`) or `x % y` of type (`w`, `sg`), truncated toward zero, `y` not zero on the path.
    // By a positive constant `c` the quotient `q` gets its definition as facts on `pc`: `x - c * q`
    // lies in [0, c - 1] when `x >= 0` and in [-(c - 1), 0] when `x < 0`, and the remainder is
    // `x - c * q`.
    fn divided(self: &mut Self, pc: &mut Vector<u32>, div: bool, x: u32, y: u32, w: u16, sg: bool) u32 {
        let r = self.tm.arith(pick(div, T_DIV, T_REM), x, y, w, sg);
        // Where it is defined (a divisor not 0, not `MIN / -1`), a fixed type's quotient or remainder is
        // `int`'s: a body that uses `int` compares the two.
        if self.exact_body && !exact_w(w) && self.tm.is_int(x) && self.tm.is_int(y) {
            let e = self.tm.arith(pick(div, T_DIV, T_REM), x, y, W_INT, true);
            let yx = self.tm.at(y);
            let z = self.tm.int(Num::<B>::zero(), yx.w, yx.sg);
            let mut undef = self.tm.cmp(T_EQ, y, z);
            if sg {
                let (lo, _hi) = Terms::<B>::range(w, sg);
                let xx = self.tm.at(x);
                let mn = self.tm.int(lo, xx.w, xx.sg);
                let m1 = self.tm.int(wide::<B>(-1), yx.w, yx.sg);
                let a = self.tm.cmp(T_EQ, x, mn);
                let b = self.tm.cmp(T_EQ, y, m1);
                let ov = self.tm.and(a, b);
                undef = self.tm.or(undef, ov);
            }
            let eq = self.tm.cmp(T_EQ, r, e);
            let f = self.tm.or(undef, eq);
            self.derive(pc, f, r);
        }
        let yt = self.tm.at(y);
        if !self.tm.is_int(x) || !self.tm.is_int(y) || yt.op == T_INT && !(Num::<B>::zero() < yt.k) {
            return r;
        }
        let q = if div {
            r
        } else {
            self.tm.arith(T_DIV, x, y, w, sg)
        };
        if yt.op == T_INT {
            self.quotient(pc, x, q, yt.k, w, sg, false);
        } else {
            self.quotient_by(pc, x, q, y, w, sg);
        }
        if !div {
            let cq = self.tm.arith(T_MUL, q, y, w, sg);
            let d = self.tm.arith(T_SUB, x, cq, w, sg);
            let f = self.tm.cmp(T_EQ, r, d);
            self.derive(pc, f, r);
        }
        return r;
    }

    // The facts of quotient `q` of `x` by the positive constant `c`: `x - c * q` in [0, c - 1] (`floor`,
    // or an `x` of an unsigned type), else in [0, c - 1] for `x >= 0` and [-(c - 1), 0] for `x < 0`
    // (truncation toward zero).
    fn quotient(self: &mut Self, pc: &mut Vector<u32>, x: u32, q: u32, c: Num<B>, w: u16, sg: bool, floor: bool) {
        let cv = self.tm.int(c, w, sg);
        let cq = self.tm.arith(T_MUL, q, cv, w, sg);
        let d = self.tm.arith(T_SUB, x, cq, w, sg);
        let zero = self.tm.int(Num::<B>::zero(), w, sg);
        let top = self.tm.int(c - Num::<B>::one(), w, sg);
        let bot = self.tm.int(Num::<B>::one() - c, w, sg);
        let d0 = self.tm.cmp(T_LE, zero, d);
        let dt = self.tm.cmp(T_LE, d, top);
        let pos = self.tm.and(d0, dt);
        if floor || !self.tm.at(x).sg {
            self.derive(pc, pos, q);
            return;
        }
        let db = self.tm.cmp(T_LE, bot, d);
        let d1 = self.tm.cmp(T_LE, d, zero);
        let neg = self.tm.and(db, d1);
        let xneg = self.tm.cmp(T_LT, x, zero);
        let xpos = self.tm.not(xneg);
        let f1 = self.tm.or(xneg, pos);
        let f2 = self.tm.or(xpos, neg);
        let f = self.tm.and(f1, f2);
        self.derive(pc, f, q);
    }

    // The facts of quotient `q` of `x` by an unknown `y`, where `y > 0`, as `quotient` gives them for a
    // constant: the product `q * y` an atom.
    fn quotient_by(self: &mut Self, pc: &mut Vector<u32>, x: u32, q: u32, y: u32, w: u16, sg: bool) {
        let yx = self.tm.at(y);
        let zero = self.tm.int(Num::<B>::zero(), w, sg);
        let one = self.tm.int(Num::<B>::one(), yx.w, yx.sg);
        let qy = self.tm.arith(T_MUL, q, y, w, sg);
        let d = self.tm.arith(T_SUB, x, qy, w, sg);
        let top = self.tm.arith(T_SUB, y, one, yx.w, yx.sg);
        let ny = self.tm.neg(y, yx.w, true);
        let bot = self.tm.arith(T_ADD, ny, one, yx.w, true);
        let d0 = self.tm.cmp(T_LE, zero, d);
        let dt = self.tm.cmp(T_LE, d, top);
        let pos = self.tm.and(d0, dt);
        let db = self.tm.cmp(T_LE, bot, d);
        let d1 = self.tm.cmp(T_LE, d, zero);
        let neg = self.tm.and(db, d1);
        let z = self.tm.int(Num::<B>::zero(), self.tm.at(x).w, self.tm.at(x).sg);
        let xneg = self.tm.cmp(T_LT, x, z);
        let xpos = self.tm.not(xneg);
        let f1 = self.tm.or(xneg, pos);
        let f2 = self.tm.or(xpos, neg);
        let f = self.tm.and(f1, f2);
        let yz = self.tm.int(Num::<B>::zero(), yx.w, yx.sg);
        let ypos = self.tm.cmp(T_LT, yz, y);
        let nyp = self.tm.not(ypos);
        let g = self.tm.or(nyp, f);
        self.derive(pc, g, q);
    }

    // Fact `f` about term `anchor` (its definition), marked as derived (`holds` tries a goal without
    // it first): on the path `pc`, or in a clause's or a definition's walk a fact of every obligation
    // that names `anchor` (`add_defs`): a clause's condition is no place for it.
    fn derive(self: &mut Self, pc: &mut Vector<u32>, f: u32, anchor: u32) {
        self.derived.insert(f, true);
        if self.chain_depth == 0 {
            // A path states a fact once: each copy of a disjunction would split the branches again.
            if !pc.contains(&f) {
                pc.push(f);
            }
            return;
        }
        self.anchor(anchor, f);
    }

    // Fact `f` of every obligation that names term `r` (`add_defs`). A definition made of derived facts alone
    // is derived too (`holds` tries a goal without it first).
    fn anchor(self: &mut Self, r: u32, f: u32) {
        if let Some(i) = self.def_of.get(&r) {
            let j = (*i) as usize;
            let g = self.tm.and(self.defs[j], f);
            if self.derived.contains_key(&self.defs[j]) && self.derived.contains_key(&f) {
                self.derived.insert(g, true);
            }
            self.defs.set(j, g);
            return;
        }
        self.def_of.insert(r, self.defs.len() as u32);
        self.defs.push(f);
    }

    // The facts of the shifts, quotients, remainders, bit operations, products and casts that `goal` and
    // `hyps` name, into `hyps` (`holds` adds them only to a goal that fails without them), each true by the
    // meaning of its operation (`terms.spc`):
    // - a bound by its operands: `a & b` at most each operand at least 0; `a | b` at least each and at most
    //   their sum, `a ^ b` from 0 to their sum, for operands at least 0; `a >> b`, and `a / b` and `a % b`
    //   with `b` at least 1, at most `a` at least 0, and `a >> b` below `a` at least 1 for `b` at least 1;
    //   `a * b` at least 0 for factors at least 0, and at least one factor where the other is at least 1;
    // - `a & c` is `a` for a constant low mask `c` (`2^j - 1`) and `a` from 0 to `c`; a cast is its operand
    //   where its type holds that value;
    // - an order between two terms of the same operation and type by the same second operand: a right shift
    //   and a quotient by at least 1 keep the order of their first operands, a left shift where no bit
    //   leaves the type (`a` at most `max >> b`); a product of factors at least 0 keeps the order of both.
    // `deep` adds a shift by an unknown count as a product or quotient by `1 << b`, the strict order of two
    // products, and the facts of an operand an equality makes a constant (`const_facts`). At most OP_TERMS terms, and PEERS_MAX others for each one's order; with `goal_only`, the terms
    // `goal` names alone (fewer facts: fewer cases to split).
    fn op_facts(self: &mut Self, goal: u32, hyps: &mut Vector<u32>, goal_only: bool, deep: bool) {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        let mut found = Vector::<u32>::new();
        stack.push(goal);
        for j in 0..pick(goal_only, 0, hyps.len()) {
            stack.push(hyps[j]);
        }
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 || found.len() >= OP_TERMS {
                break;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            let x = self.tm.at(t);
            // A product, quotient or remainder of exact integers (`int`, `nat`) too: their facts hold there.
            let exact_ok = x.op == T_MUL || x.op == T_DIV || x.op == T_REM || !exact_w(x.w) && x.w <= 64;
            if self.tm.is_int(t) && exact_ok && (x.op >= T_DIV && x.op <= T_SHR || x.op == T_CAST || x.op == T_MUL && self.tm.at(
                x.a,
            ).op != T_INT && self.tm.at(x.b).op != T_INT) {
                found.push(t);
            }
            self.tm.operands(t, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
        // The comparisons of a term with a constant (`x <= 7`, `3 < x`) anywhere in the facts: each bounds a
        // product the term is a factor of by a linear form, under that comparison as a condition.
        let mut cbound = Map::<u32, u32>::new();
        // The least constant each term is at most (`x < 13` gives 12): a left shift by the term is at most the
        // shift by it.
        let mut cupper = Map::<u32, Num<B>>::new();
        // The equalities of a term with a constant: an operation's operand that one makes a constant gets the
        // facts of that constant, under the equality.
        let mut ceq = Map::<u32, Vector<u32>>::new();
        let mut cstack = Vector::<u32>::new();
        for j in 0..hyps.len() {
            cstack.push(hyps[j]);
        }
        for _s in 0..LIN_MAX {
            if cstack.len() == 0 {
                break;
            }
            let h = cstack.pop().unwrap();
            let x = self.tm.at(h);
            if x.op == T_AND || x.op == T_OR {
                cstack.push(x.a);
                cstack.push(x.b);
            } else if x.op == T_NOT {
                cstack.push(x.a);
            } else if (x.op == T_LE || x.op == T_LT || x.op == T_EQ) && self.tm.is_int(x.a) && self.tm.is_int(x.b) && self.tm.at(
                x.a,
            ).op == T_INT != (self.tm.at(x.b).op == T_INT) {
                let v = pick(self.tm.at(x.a).op == T_INT, x.b, x.a);
                if x.op == T_EQ {
                    let mut l = switch ceq.get(&v) {
                        Some(e) => e.clone(),
                        None => Vector::<u32>::new(),
                    };
                    if l.len() < CONST_EQS && !l.contains(&h) {
                        l.push(h);
                        ceq.insert(v, l);
                    }
                } else {
                    if !cbound.contains_key(&v) {
                        cbound.insert(v, h);
                    }
                    if v == x.a {
                        let one = Num::<B>::one();
                        let kt = self.tm.at(x.b).k;
                        let k = pick(x.op == T_LT, ck(kt.checked_sub(&one)), Some(kt));
                        if let Some(k) = k {
                            let tighter = switch cupper.get(&v) {
                                Some(o) => k < *o,
                                None => true,
                            };
                            if tighter {
                                cupper.insert(v, k);
                            }
                        }
                    }
                }
            }
        }
        let mut peers = Map::<u64, Vector<u32>>::new();
        // A left shift adds its bound (`lim`) to `found`: the walk reads the new ends too.
        let mut f: usize = 0;
        while f < found.len() && f < 2 * OP_TERMS {
            let r = found[f];
            f += 1;
            self.op_bounds(r, hyps, &cbound, &cupper, &ceq, deep);
            let t = self.tm.at(r);
            if !(t.op == T_SHR || t.op == T_SHL || t.op == T_DIV || t.op == T_MUL) {
                continue;
            }
            let key = if t.op == T_MUL {
                hmix(T_MUL, 0)
            } else {
                hmix(hmix(t.op as u64 << 32 | t.w as u64 << 1 | t.sg as u64, t.k.limb(0)), t.b)
            };
            let mut list = switch peers.get(&key) {
                Some(v) => v.clone(),
                None => Vector::<u32>::new(),
            };
            // A left shift keeps no order past `max >> b`: that bound is a right shift by `b` too, ordered
            // against the right shifts by `b`.
            let lim = if t.op == T_SHL {
                let (_lo, hi) = Terms::<B>::range(t.w, t.sg);
                let mx = self.tm.int(hi, t.w, t.sg);
                let l = self.tm.arith(T_SHR, mx, t.b, t.w, t.sg);
                if !seen.contains_key(&l) {
                    seen.insert(l, true);
                    found.push(l);
                }
                l
            } else {
                NONE
            };
            let pb = self.at_least(t.b, 1);
            for j in 0..list.len().min(PEERS_MAX) {
                let q = list[j];
                for dir in 0..2u32 {
                    let (u, v) = pick(dir == 0, (r, q), (q, r));
                    let (ut, vt) = (self.tm.at(u), self.tm.at(v));
                    let mut cond = self.tm.cmp(T_LE, ut.a, vt.a);
                    if t.op == T_DIV {
                        cond = self.tm.and(cond, pb);
                    } else if t.op == T_SHL {
                        let n0 = self.at_least(ut.a, 0);
                        let fit = self.tm.cmp(T_LE, vt.a, lim);
                        let both = self.tm.and(n0, fit);
                        cond = self.tm.and(cond, both);
                    } else if t.op == T_MUL {
                        // Either pairing of the factors, each at least 0.
                        let n1 = self.at_least(ut.a, 0);
                        let n2 = self.at_least(ut.b, 0);
                        let n0 = self.tm.and(n1, n2);
                        let b1 = self.tm.cmp(T_LE, ut.b, vt.b);
                        let s1 = self.tm.and(cond, b1);
                        let c1 = self.tm.cmp(T_LE, ut.a, vt.b);
                        let c2 = self.tm.cmp(T_LE, ut.b, vt.a);
                        let s2 = self.tm.and(c1, c2);
                        let either = self.tm.or(s1, s2);
                        cond = self.tm.and(n0, either);
                    }
                    let le = self.tm.cmp(T_LE, u, v);
                    let g = self.imp(cond, le);
                    if !hyps.contains(&g) {
                        hyps.push(g);
                    }
                    // A product whose first factor is below the other's by at least 1 is below it by the second
                    // factor (`a < a'`, `0 <= b <= b'`: `a * b + b <= a' * b'`), in term order.
                    if deep && t.op == T_MUL {
                        let n1 = self.at_least(ut.a, 0);
                        let n2 = self.at_least(ut.b, 0);
                        let n0 = self.tm.and(n1, n2);
                        let lt = self.tm.cmp(T_LT, ut.a, vt.a);
                        let b1 = self.tm.cmp(T_LE, ut.b, vt.b);
                        let c3 = self.tm.and(n0, self.tm.and(lt, b1));
                        let ub = self.tm.arith(T_ADD, u, ut.b, W_INT, true);
                        let f3 = self.tm.cmp(T_LE, ub, v);
                        let g3 = self.imp(c3, f3);
                        if !hyps.contains(&g3) {
                            hyps.push(g3);
                        }
                    }
                }
            }
            list.push(r);
            peers.insert(key, list);
        }
    }

    // The bounds `op_facts` states of term `r` by its operands, into `hyps`; `cbound`: per term, a fact that
    // bounds it by a constant; `ceq`: one that makes it a constant.
    fn op_bounds(
        self: &mut Self,
        r: u32,
        hyps: &mut Vector<u32>,
        cbound: &Map<u32, u32>,
        cupper: &Map<u32, Num<B>>,
        ceq: &Map<u32, Vector<u32>>,
        deep: bool,
    ) {
        let t = self.tm.at(r);
        let mut fs = Vector::<u32>::new();
        if t.op == T_CAST {
            let e = t.a;
            let et = self.tm.at(e);
            if !self.tm.is_int(e) || et.op == T_INT {
                return;
            }
            let (lo, hi) = Terms::<B>::range(t.w, t.sg);
            let l = self.tm.int(lo, et.w, et.sg);
            let h = self.tm.int(hi, et.w, et.sg);
            let c1 = self.tm.cmp(T_LE, l, e);
            let c2 = self.tm.cmp(T_LE, e, h);
            let inr = self.tm.and(c1, c2);
            let eq = self.tm.cmp(T_EQ, r, e);
            fs.push(self.imp(inr, eq));
        } else if t.op == T_MUL {
            // A product of factors at least 0 is at least 0, and at least one factor where the other is at
            // least 1.
            let (a, b) = (t.a, t.b);
            let na = self.at_least(a, 0);
            let nb = self.at_least(b, 0);
            let both = self.tm.and(na, nb);
            let z = self.tm.int(Num::<B>::zero(), t.w, t.sg);
            let p0 = self.tm.cmp(T_LE, z, r);
            fs.push(self.imp(both, p0));
            // A factor at most 0 times one at least 0 is at most 0.
            for side in 0..2u32 {
                let (u, v) = pick(side == 0, (a, b), (b, a));
                let za = self.tm.int(Num::<B>::zero(), self.tm.at(u).w, self.tm.at(u).sg);
                let up = self.tm.cmp(T_LE, u, za);
                let nv = self.at_least(v, 0);
                let c = self.tm.and(up, nv);
                let le0 = self.tm.cmp(T_LE, r, z);
                fs.push(self.imp(c, le0));
            }
            for side in 0..2u32 {
                let (u, v) = pick(side == 0, (a, b), (b, a));
                let u1 = self.at_least(u, 1);
                let nv = self.at_least(v, 0);
                let c = self.tm.and(u1, nv);
                let ge = self.tm.cmp(T_LE, v, r);
                fs.push(self.imp(c, ge));
                // A factor `u` at most (at least) a constant `k`: the product is at most (at least) `k * v`.
                if let Some(h) = cbound.get(&u) {
                    let hx = self.tm.at(*h);
                    let upper = self.tm.at(hx.b).op == T_INT;
                    let kt = self.tm.at(pick(upper, hx.b, hx.a));
                    // A step past a constant at the end of the range leaves the bound out.
                    let one = Num::<B>::one();
                    let k = if hx.op != T_LT {
                        Some(kt.k)
                    } else if upper {
                        ck(kt.k.checked_sub(&one))
                    } else {
                        ck(kt.k.checked_add(&one))
                    }.unwrap_or(wide::<B>(-1));
                    if !k.is_negative() {
                        let kv = self.tm.int(k, t.w, t.sg);
                        let kp = self.tm.arith(T_MUL, kv, v, t.w, t.sg);
                        let ord = pick(upper, self.tm.cmp(T_LE, r, kp), self.tm.cmp(T_LE, kp, r));
                        let cond = self.tm.and(both, *h);
                        fs.push(self.imp(cond, ord));
                    }
                }
            }
        } else if t.op == T_SHL {
            // A constant `c` at least 0 shifted by a count at most a constant `k`, where `c << k` fits the
            // type: at most `c << k` (`1 << i` with `i < 13` is at most 4096).
            let at = self.tm.at(t.a);
            if let Some(k) = cupper.get(&t.b) {
                let (_lo, hi) = Terms::<B>::range(t.w, t.sg);
                if at.op == T_INT && !at.k.is_negative() && !k.is_negative() && *k < wide::<B>(t.w) && at.k <= hi.shr(
                    k.limb(0) as usize,
                ) {
                    let kv = self.tm.int(*k, self.tm.at(t.b).w, self.tm.at(t.b).sg);
                    let within = self.tm.cmp(T_LE, t.b, kv);
                    let lim = self.tm.int(at.k.shl(k.limb(0) as usize), t.w, t.sg);
                    let le = self.tm.cmp(T_LE, r, lim);
                    fs.push(self.imp(within, le));
                }
            }
        } else {
            let (a, b) = (t.a, t.b);
            let na = self.at_least(a, 0);
            let nb = self.at_least(b, 0);
            let pb = self.at_least(b, 1);
            let le_a = self.tm.cmp(T_LE, r, a);
            if t.op == T_BAND {
                fs.push(self.imp(na, le_a));
                let le_b = self.tm.cmp(T_LE, r, b);
                fs.push(self.imp(nb, le_b));
                for side in 0..2u32 {
                    let (m, v) = pick(side == 0, (b, a), (a, b));
                    let mt = self.tm.at(m);
                    if mt.op == T_INT && !mt.k.is_negative() && low_mask(mt.k) {
                        let nv = self.at_least(v, 0);
                        let within = self.tm.cmp(T_LE, v, m);
                        let cond = self.tm.and(nv, within);
                        let eq = self.tm.cmp(T_EQ, r, v);
                        fs.push(self.imp(cond, eq));
                    }
                }
            } else if t.op == T_BOR || t.op == T_BXOR {
                let both = self.tm.and(na, nb);
                let sum = self.tm.arith(T_ADD, a, b, W_INT, true);
                let mut f = self.tm.cmp(T_LE, r, sum);
                if t.op == T_BOR {
                    let ga = self.tm.cmp(T_LE, a, r);
                    let gb = self.tm.cmp(T_LE, b, r);
                    let g2 = self.tm.and(ga, gb);
                    f = self.tm.and(f, g2);
                } else {
                    let z = self.tm.int(Num::<B>::zero(), t.w, t.sg);
                    let g0 = self.tm.cmp(T_LE, z, r);
                    f = self.tm.and(f, g0);
                }
                fs.push(self.imp(both, f));
            } else {
                let cond = if t.op == T_SHR {
                    na
                } else {
                    self.tm.and(na, pb)
                };
                fs.push(self.imp(cond, le_a));
                // A quotient or remainder of a value at least 0 by one at least 1 is at least 0.
                if t.op != T_SHR {
                    let z = self.tm.int(Num::<B>::zero(), t.w, t.sg);
                    let ge0 = self.tm.cmp(T_LE, z, r);
                    fs.push(self.imp(cond, ge0));
                }
                if t.op == T_SHR {
                    let a1 = self.at_least(a, 1);
                    let lt = self.tm.cmp(T_LT, r, a);
                    let c = self.tm.and(a1, pb);
                    fs.push(self.imp(c, lt));
                }
            }
        }
        // A shift of an unsigned value by an unknown count `b` is a product or quotient by `p = 1 << b` (at least
        // 1, the count below the width on the path): `a >> b` is `t` with `t * p <= a <= t * p + p - 1`; `a << b`
        // is `a * p` where no bit leaves the type (`a` at most `max >> b`).
        if deep && (t.op == T_SHR || t.op == T_SHL) && !t.sg && self.tm.at(t.b).op != T_INT && self.tm.is_int(t.b) {
            let one = self.tm.int(Num::<B>::one(), t.w, false);
            let p = self.tm.arith(T_SHL, one, t.b, t.w, false);
            let p1 = self.tm.cmp(T_LE, one, p);
            fs.push(p1);
            if t.op == T_SHR {
                let tp = self.tm.arith(T_MUL, r, p, W_INT, true);
                let lo = self.tm.cmp(T_LE, tp, t.a);
                let top = self.tm.arith(T_ADD, tp, p, W_INT, true);
                let hi = self.tm.cmp(T_LT, t.a, top);
                fs.push(self.tm.and(lo, hi));
            } else {
                let (_l, h) = Terms::<B>::range(t.w, false);
                let mx = self.tm.int(h, t.w, false);
                let lim = self.tm.arith(T_SHR, mx, t.b, t.w, false);
                let fit = self.tm.cmp(T_LE, t.a, lim);
                let ap = self.tm.arith(T_MUL, t.a, p, W_INT, true);
                let eq = self.tm.cmp(T_EQ, r, ap);
                fs.push(self.imp(fit, eq));
            }
        }
        if deep {
            self.const_facts(r, ceq, &mut fs);
        }
        for j in 0..fs.len() {
            if !self.tm.is_true(fs[j]) && !hyps.contains(&fs[j]) {
                hyps.push(fs[j]);
            }
        }
    }

    // The facts of term `r` whose second operand (an `and`'s either one) the equalities `ceq` make a constant
    // `c`, under them, into `fs`: an `and` with a low mask `c` over a value from 0 to `c` is that value; a
    // quotient and a remainder by `c` above 0 of a value at least 0, and a shift by `c` below the width, have
    // the facts of `c` itself (`quotient`, `shifted`).
    fn const_facts(self: &mut Self, r: u32, ceq: &Map<u32, Vector<u32>>, fs: &mut Vector<u32>) {
        let t = self.tm.at(r);
        if !(t.op == T_BAND || t.op == T_DIV || t.op == T_REM || t.op == T_SHR || t.op == T_SHL) || ceq.len() == 0 {
            return;
        }
        for side in 0..pick(t.op == T_BAND, 2u32, 1u32) {
            let (y, x) = pick(side == 0, (t.b, t.a), (t.a, t.b));
            if self.tm.at(y).op == T_INT {
                continue;
            }
            let mut cases = Vector::<(Num<B>, u32)>::new();
            self.const_of(y, ceq, 3, &mut cases);
            for ci in 0..cases.len() {
                let (c, cond0) = cases[ci];
                self.const_fact(r, t, x, y, c, cond0, fs);
            }
        }
    }

    // `const_facts` for one constant `c` of operand `y` (the other `x`) under formula `cond0`.
    fn const_fact(self: &mut Self, r: u32, t: Term<B>, x: u32, y: u32, c: Num<B>, cond0: u32, fs: &mut Vector<u32>) {
        let nx = self.at_least(x, 0);
        let cond = self.tm.and(cond0, nx);
        if t.op == T_BAND {
            if c.is_negative() || !low_mask(c) {
                return;
            }
            let within = self.tm.cmp(T_LE, x, y);
            let g = self.tm.and(cond, within);
            let eq = self.tm.cmp(T_EQ, r, x);
            fs.push(self.imp(g, eq));
            return;
        }
        let w = t.w;
        let shift = t.op == T_SHR || t.op == T_SHL;
        if shift && (exact_w(w) || c.is_negative() || !(c < wide::<B>(w))) || !shift && !(Num::<B>::zero() < c) {
            return;
        }
        let d = pick(shift, Num::<B>::one().shl(c.to_i64() as usize), c);
        let dv = self.tm.int(d, W_INT, true);
        if t.op == T_SHL {
            if t.sg {
                return;
            }
            let lim = self.tm.int(
                Num::<B>::one().shl(w as usize - c.to_i64() as usize),
                self.tm.at(x).w,
                self.tm.at(x).sg,
            );
            let fit = self.tm.cmp(T_LT, x, lim);
            let g = self.tm.and(cond0, fit);
            let m = self.tm.arith(T_MUL, x, dv, W_INT, true);
            let eq = self.tm.cmp(T_EQ, r, m);
            fs.push(self.imp(g, eq));
            return;
        }
        // `x - d * q` from 0 to `d - 1`: the floor of `x / d` (a right shift at either sign, a quotient of a
        // value at least 0).
        let q = if t.op == T_REM {
            self.tm.arith(T_DIV, t.a, t.b, w, t.sg)
        } else {
            r
        };
        let dq = self.tm.arith(T_MUL, dv, q, W_INT, true);
        let rest = self.tm.arith(T_SUB, x, dq, W_INT, true);
        let zero = self.tm.int(Num::<B>::zero(), W_INT, true);
        let top = self.tm.int(d - Num::<B>::one(), W_INT, true);
        let lo = self.tm.cmp(T_LE, zero, rest);
        let hi = self.tm.cmp(T_LE, rest, top);
        let mut f = self.tm.and(lo, hi);
        if t.op == T_REM {
            let eq = self.tm.cmp(T_EQ, r, rest);
            f = self.tm.and(f, eq);
        }
        fs.push(self.imp(pick(t.op == T_SHR, cond0, cond), f));
    }

    // The constants integer `t` is where equalities of `ceq` hold, each with the formula of those it needs, into
    // `out`: a constant's value; each of a term's equalities; a sum or difference of such (CONST_EQS at most);
    // `depth` levels deep.
    fn const_of(self: &mut Self, t: u32, ceq: &Map<u32, Vector<u32>>, depth: u32, out: &mut Vector<(Num<B>, u32)>) {
        let x = self.tm.at(t);
        if x.op == T_INT {
            out.push((x.k, self.tm.boolean(true)));
            return;
        }
        if let Some(hs) = ceq.get(&t) {
            for j in 0..hs.len() {
                let hx = self.tm.at(hs[j]);
                let k = pick(self.tm.at(hx.a).op == T_INT, self.tm.at(hx.a).k, self.tm.at(hx.b).k);
                out.push((k, hs[j]));
            }
            return;
        }
        if depth == 0 || x.op != T_ADD && x.op != T_SUB {
            return;
        }
        let mut av = Vector::<(Num<B>, u32)>::new();
        let mut bv = Vector::<(Num<B>, u32)>::new();
        self.const_of(x.a, ceq, depth - 1, &mut av);
        self.const_of(x.b, ceq, depth - 1, &mut bv);
        for i in 0..av.len() {
            for j in 0..bv.len() {
                if out.len() < CONST_EQS {
                    let v = if x.op == T_ADD {
                        ck(av[i].0.checked_add(&bv[j].0))
                    } else {
                        ck(av[i].0.checked_sub(&bv[j].0))
                    };
                    if let Some(v) = v {
                        out.push((v, self.tm.and(av[i].1, bv[j].1)));
                    }
                }
            }
        }
    }

    // `c ==> f`: `f` when `c` is true.
    fn imp(self: &mut Self, c: u32, f: u32) u32 {
        if self.tm.is_true(c) {
            return f;
        }
        let nc = self.tm.not(c);
        return self.tm.or(nc, f);
    }

    // `x >= k` as a formula: true where `x`'s type has no value below `k` (an unsigned type and `k` 0).
    fn at_least(self: &mut Self, x: u32, k: i64) u32 {
        let xt = self.tm.at(x);
        if k == 0 && (xt.w == W_NAT || !exact_w(xt.w) && !xt.sg) || xt.op == T_INT && !(xt.k < wide::<B>(k)) {
            return self.tm.boolean(true);
        }
        let c = self.tm.int(wide::<B>(k), xt.w, xt.sg);
        return self.tm.cmp(T_LE, c, x);
    }

    // The facts of shift `r` by a constant count `c` below its width: `x >> c` is `x` divided by `2^c`
    // rounded down (an arithmetic shift too); `x << c` of an unsigned `x` below `2^(w - c)` is
    // `x * 2^c`.
    fn shifted(self: &mut Self, pc: &mut Vector<u32>, r: u32) {
        let t = self.tm.at(r);
        let ct = self.tm.at(t.b);
        if ct.op != T_INT || ct.k.is_negative() || !(ct.k < wide::<B>(t.w)) || !self.tm.is_int(t.a) {
            return;
        }
        let c = ct.k.to_i64() as usize;
        let p = Num::<B>::one().shl(c);
        if t.op == T_SHR {
            self.quotient(pc, t.a, r, p, t.w, t.sg, true);
            return;
        }
        if t.op != T_SHL || self.tm.at(t.a).sg {
            return;
        }
        let lim = self.tm.int(Num::<B>::one().shl(t.w as usize - c), t.w, false);
        let big = self.tm.cmp(T_LE, lim, t.a);
        let pv = self.tm.int(p, t.w, false);
        let m = self.tm.arith(T_MUL, t.a, pv, t.w, false);
        let eq = self.tm.cmp(T_EQ, r, m);
        let f = self.tm.or(big, eq);
        self.derive(pc, f, r);
    }

    // Integer `x` as a value of type (`w`, `sg`) through `from`: itself when the type holds every value
    // of `x`'s, NONE otherwise.
    const fn widened(self: &mut Self, x: u32, w: u16, sg: bool) u32 {
        let xt = self.tm.at(x);
        if w <= W_BOOL || xt.w <= W_BOOL {
            return NONE;
        }
        // `int` holds every integer, `nat` every one at least 0; a fixed type no exact one. Into `int`, a
        // fixed type's sum with a constant is the base's value plus the constant (`(p + 1) as int` is
        // `p as int + 1`): one term for one value.
        if w == W_INT && !exact_w(xt.w) {
            let (base, c) = self.tm.off_split(x, xt.w, xt.sg);
            if base != x && base != NONE {
                let neg = c.is_negative();
                let k = self.tm.int(pick(neg, Num::<B>::zero() - c, c), W_INT, true);
                return self.tm.arith(pick(neg, T_SUB, T_ADD), base, k, W_INT, true);
            }
        }
        // A constant as the constant of the exact type: `2usize as nat` is the `nat` 2 a literal spells.
        if exact_w(w) && !exact_w(xt.w) && xt.op == T_INT && (w == W_INT || !xt.k.is_negative()) {
            return self.tm.int(xt.k, w, sg);
        }
        if exact_w(w) || exact_w(xt.w) {
            return pick(w == W_INT || w == W_NAT && (xt.w == W_NAT || !exact_w(xt.w) && !xt.sg), x, NONE);
        }
        let (lo0, hi0) = Terms::<B>::range(xt.w, xt.sg);
        let (lo1, hi1) = Terms::<B>::range(w, sg);
        return pick(lo1 <= lo0 && hi0 <= hi1, x, NONE);
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
        let sv = self.sq_value(cb, cm, state, t, all);
        if sv != NONE {
            return sv;
        }
        if t.callee.node == NODE_NONE || !self.is_const_fn(t.callee) {
            return self.tm.var(w, sg);
        }
        // A spec function reads its arguments at the call and changes none.
        let ghost = self.is_ghost(t.callee);
        let mut xs = Vector::<u32>::with_capacity(t.args_len as usize);
        for j in t.args_start..t.args_start + t.args_len {
            let oid = cb.oper_pool[j as usize];
            if !all && !ghost && self.autoref(cb, cm, t, j - t.args_start) && !self.shared_read(cb, t, j - t.args_start) {
                return self.tm.var(w, sg);
            }
            let x0 = self.operand(cb, cm, state, oid, all);
            let oty = cb.operands.at(oid as usize).ty;
            // A reference a spec function reads: the value it refers to in this state, so that two calls
            // in one state are one term and a call in a later state another.
            let ot = *self.ast_of(cm).type_at(oty);
            // So is a reference a shared parameter reads (a `&mut` lent as `&`): one value per state, as
            // a borrow of the place gives (`implicit_ref`).
            let xo = self.tm.at(x0).op;
            let lent_shared = (xo == T_MREF || xo == T_PREF) && self.shared_param(t, j - t.args_start);
            let x = if (ghost || lent_shared) && oty != TYPE_NONE && ot.kind == TypeKind::TYPE_REFERENCE && xo != T_REF {
                let v = self.deref(state, x0, cm, ot.as_data.elem);
                self.tm.unary(T_REF, v, W_OTHER, false)
            } else {
                x0
            };
            // `v.invariant()`: the invariant of the value, the term the walk assumes (`inv_of`).
            if ghost && t.args_len == 1 && oty != TYPE_NONE {
                let vty = pick(ot.kind == TypeKind::TYPE_REFERENCE, ot.as_data.elem, oty);
                let mut ib = Vector::<u64>::new();
                let id = self.inv_method(cm, vty, &mut ib);
                if id.node != NODE_NONE && id.node == t.callee.node && id.module == t.callee.module {
                    let xv = self.tm.at(x);
                    let v = pick(xv.op == T_REF, xv.a, x);
                    let f = self.inv_of(cm, vty, v, state);
                    if f != NONE {
                        return f;
                    }
                }
            }
            // An automatic reference reads the value as `&x` does.
            let xr = self.implicit_ref(cb, t, j - t.args_start, x);
            let xt = self.tm.at(xr);
            // A raw pointer a spec function reads is its address (`null` too, whose constant may have no
            // pointer type of its own).
            let raw = ot.kind == TypeKind::TYPE_POINTER || ot.kind == TypeKind::TYPE_FUNCTION || xr == self.null_ptr() || self.fn_items.contains_key(
                &xr,
            );
            if xt.w == W_OTHER && xt.op != T_REF && xt.op != T_VIEW && !self.frozen(cm, oty) && !(ghost && raw) {
                return self.tm.var(w, sg);
            }
            xs.push(xr);
        }
        if xs.len() == 1 && self.tm.is_int(xs[0]) && self.is_from_addr(t.callee) {
            return self.ptr_at(xs[0]);
        }
        // An entry's precondition of its argument (`pre_of`), or of any (`pre_any`: of an unknown one).
        if xs.len() == 2 && self.is_pre(t.callee, 0) {
            let r = self.pre_value(xs[0], xs[1], state);
            if r != NONE {
                return r;
            }
        }
        if xs.len() == 1 && self.is_pre(t.callee, 1) {
            let any = self.tm.var(W_OTHER, false);
            let r = self.pre_value(xs[0], any, state);
            if r != NONE {
                return r;
            }
        }
        // Counted shares: an atom of the units held, the count itself.
        if xs.len() == 3 && self.is_shares(t.callee, 0) {
            return self.share_atom(xs[0], xs[1], xs[2]);
        }
        if xs.len() == 2 && self.is_shares(t.callee, 1) {
            let kc = self.int_const(xs[1]);
            if kc != NONE {
                return self.nsh(xs[0], kc, self.ov);
            }
        }
        // An element of a view of an array is the array's member (a reference to it).
        if xs.len() == 2 && self.is_slice_elem(t.callee) && self.tm.is_int(xs[1]) {
            let x = self.tm.at(xs[0]);
            let v = if x.op == T_REF {
                self.tm.at(x.a)
            } else {
                x
            };
            let rt = *self.ast_of(cm).type_at(rty);
            if v.op == T_VIEW && rt.kind == TypeKind::TYPE_REFERENCE {
                let (ew, esg) = self.ty_of(cm, rt.as_data.elem);
                let e = self.sel(v.a, xs[1], ew, esg);
                return self.tm.unary(T_REF, e, W_OTHER, false);
            }
            // Another view's element is the element of its sequence in this memory epoch.
            if rt.kind == TypeKind::TYPE_REFERENCE {
                let (ew, esg) = self.ty_of(cm, rt.as_data.elem);
                let sx = if x.op == T_REF {
                    x.a
                } else {
                    xs[0]
                };
                let ep = self.slice_ep(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty, state);
                let view = self.view_s(sx, ep);
                let e = self.seq_at(view, xs[1], ew, esg);
                return self.tm.unary(T_REF, e, W_OTHER, false);
            }
        }
        // A view of an array has the array's length; another view's length is a function of the view.
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
            let sx = if x.op == T_REF {
                x.a
            } else {
                xs[0]
            };
            // A literal's length is its member (`slice_field`).
            let n = self.slice_field(sx, true);
            self.len_cap(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty, sx);
            return if w == self.pw && !sg {
                n
            } else {
                self.tm.unary(T_CAST, n, w, sg)
            };
        }
        // The type arguments are part of the callee; their ids are read in the body's module, which
        // the key names so that two modules' equal ids never meet.
        // Inside a generic spec function's unfolding a type argument is the caller's type (`subst`);
        // one that still names a type parameter has no meaning of its own: the call is unknown.
        let mut key = skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64);
        for j in 0..t.targs_len {
            let t0 = cb.targ_pool[(t.targs_start + j) as usize];
            let (m2, t2) = self.resolve(cm, t0);
            if self.subst.len() != 0 && !self.bound_generic(cm, t0) && self.mentions_generic(m2, t2, 0) {
                return self.tm.var(w, sg);
            }
            key = skey_mix(key, self.type_key(m2, t2, 0));
        }
        // An interface's associated function through a type (`A::owns(..)`): its implementor is part of
        // the callee; at a type that names no parameter, that type's conformance defines it.
        let mut callee = t.callee;
        let mut cbinds = Vector::<u64>::new();
        let mut via = false;
        let ca = self.ast_of(t.callee.module);
        let cc = ca.container_of(t.callee.node);
        let iface_member = cc != NODE_NONE && ca.at_const(cc).kind == NodeKind::NODE_INTERFACE;
        if t.recv != TYPE_NONE && iface_member {
            let (m2, t2) = self.resolve(cm, t.recv);
            if self.subst.len() != 0 && !self.bound_generic(cm, t.recv) && self.mentions_generic(m2, t2, 0) {
                return self.tm.var(w, sg);
            }
            key = skey_mix(key, self.type_key(m2, t2, 0));
            if ghost && !self.mentions_generic(m2, t2, 0) {
                let d2 = self.spec_conf(t.callee, m2, t2, &mut cbinds);
                if d2.node != NODE_NONE {
                    callee = d2;
                    via = true;
                }
            }
        }
        // A `const fn` that ends, over constants and types that name no parameter, is the value its body
        // computes, as a spec function's call over constants is (`S::<u32>::cap_max()`).
        let mut lit0 = true;
        for j in 0..xs.len() {
            let op = self.tm.at(xs[j]).op;
            lit0 = lit0 && (op == T_INT || op == T_BOOL);
        }
        let mut closed = lit0 && !ghost && self.is_const_fn(t.callee);
        for j in 0..t.targs_len {
            let (m2, t2) = self.resolve(cm, cb.targ_pool[(t.targs_start + j) as usize]);
            closed = closed && !self.mentions_generic(m2, t2, 0);
        }
        closed = closed && self.ends(t.callee, 0);
        let mut binds = Vector::<u64>::new();
        let bound = if via {
            binds = cbinds;
            true
        } else {
            (ghost || closed) && !(iface_member && t.recv != TYPE_NONE) && self.call_binds(cb, cm, t, &mut binds)
        };
        // A spec function's reference result refers to a value that is a function of the arguments.
        let rt = *self.ast_of(cm).type_at(rty);
        let by_ref = ghost && rty != TYPE_NONE && rt.kind == TypeKind::TYPE_REFERENCE;
        let (vw, vsg) = if by_ref {
            self.ty_of(cm, rt.as_data.elem)
        } else {
            (w, sg)
        };
        // `A::owns(p, n, a)`: its conformance's property and the block's `held` atom (`held_atom`), keyed
        // on the implementor's type; a spec function that reaches one is keyed on the ownership version.
        let owns_atom = !by_ref && xs.len() == 3 && (self.is_owns(t.callee) || via && self.is_owns(callee));

        let hk = if !owns_atom {
            0u64
        } else if t.recv != TYPE_NONE {
            let (m2, t2) = self.resolve(cm, t.recv);
            self.alloc_key(m2, t2)
        } else {
            let ca2 = self.ast_of(t.callee.module);
            let e = ca2.container_of(t.callee.node);
            self.alloc_key(t.callee.module, ca2.type_of(ca2.ext(e).extend_def.target_type))
        };
        let vkey = self.mentions_owns(callee);
        let key0 = key;
        if vkey {
            key = skey_mix(key, OV_KEY | self.ov as u64);
        }
        let r = self.tm.call(key, &xs, vw, vsg);

        // A call over constants unfolds again, to UNFOLD_MAX deep: `pow2(3) == 8` is computed.
        let mut lit = true;
        for j in 0..xs.len() {
            let op = self.tm.at(xs[j]).op;
            lit = lit && (op == T_INT || op == T_BOOL);
        }

        let ck = callee.module as u64 << 32 | callee.node as u64;
        let nested = self.unfold < NEST_MAX && !self.unfolding.contains(&ck);
        if (self.unfold == 0 || lit && self.unfold < UNFOLD_MAX || nested) && bound {
            let outer = replace(&mut self.subst, binds);
            self.unfolding.push(ck);
            let cd = replace(&mut self.closed_def, closed && !ghost);
            self.define(r, callee, &xs, state, by_ref);
            self.closed_def = cd;
            let _ = self.unfolding.pop();
            self.subst = outer;
        }
        // The same call in an earlier version implies it where no block it holds was taken (`ov_frame`).
        if vkey && vw == W_BOOL && !by_ref {
            let mut ak: u64 = 0;
            for j in 0..xs.len() {
                ak = skey_mix(ak, xs[j]);
            }
            self.ov_frame(key0, ak, r);
        }
        if !by_ref {
            let val = if let Some(v) = self.exact.get(&r) {
                *v
            } else {
                // A small aggregate result is the aggregate of its members (`eta`): two equal ones are one
                // term to the closure.
                self.eta(cm, rty, r, 0)
            };
            if owns_atom {
                let h = self.held_atom(hk, xs[0], xs[1], xs[2]);
                // A block the definition gives another allocator (a pool's pass-through `A::owns`) has that
                // one as its one holder: this allocator's atom where no atom the definition claims holds.
                let mut hc = h;
                let mut hg = Vector::<u64>::new();
                let d = self.def_body(r);
                if d != NONE {
                    self.held_g(d, self.ov, &mut hg);
                }
                if hg.len() != 0 && !self.held_alt.contains_key(&h) {
                    self.held_alt.insert(h, Vector::<u32>::new());
                }
                for j in 0..hg.len() {
                    let hi = (hg[j] >> 32) as u32;
                    hc = self.tm.or(hi, hc);
                    let alts = self.held_alt.get_mut(&h).unwrap();
                    if !alts.contains(&hi) {
                        alts.push(hi);
                    }
                }
                return self.tm.and(val, hc);
            }
            return val;
        }
        return self.tm.unary(T_REF, r, W_OTHER, false);
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
                // Ghost code writes its own locals and the ghost variables.
                let gv = ld.dkind == ir::LK_GHOST && ir::is_ghost_site(s.kind);
                let own = ld.storage == ir::LS_TEMP || ld.storage == ir::LS_USER && ld.span.start >= expr.start && ld.span.end <= expr.end;
                if p.proj_len != 0 && !gv || !own && !gv {
                    return false;
                }
            }
            if blk == s.check {
                continue;
            }
            let t = bb.term;
            // A drop of a temporary of the clause ends a value the clause made.
            if t.kind == ir::TM_DROP && !(cb.places.at(t.a as usize).proj_len == 0 && cb.locals.at(
                cb.places.at(t.a as usize).base as usize,
            ).storage == ir::LS_TEMP) {
                return false;
            }
            if t.kind == ir::TM_CALL && !self.is_const_fn(t.callee) && !self.panics(t.callee) && !self.is_ghost(
                t.callee,
            ) && self.wide_kind(t.callee) == 0 && self.soft_kind(t.callee) == 0 {
                return false;
            }
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP {
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

    // Whether `d` is an element read of the prelude's views (`index`, `get`, `at`, `get_unsafe`).
    fn is_slice_elem(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || d.module != self.slice.mid || (d.node & NODE_BODY) != 0 {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let nm = self.text(d.module, a.at_const(a.ext_name(d.node)).span);
        return nm == "index" || nm == "get" || nm == "at" || nm == "get_unsafe";
    }

    // Whether `d` is `std::mem::ptr::from_addr_mut`.
    fn is_from_addr(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || self.pkg().modules.at(d.module as usize).path.as_str() != "std::mem::ptr" {
            return false;
        }
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && self.text(
            d.module,
            a.at_const(a.ext_name(d.node)).span,
        ) == "from_addr_mut";
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

    // Whether `d` ends the process (an `extern` function that never returns: `abort`, `exit`): no panic
    // unwinds from it, and no contract is broken past it.
    fn exits(self: &Self, d: DefId) bool {
        if !self.panics(d) {
            return false;
        }
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && a.ext(d.node).function.is_extern();
    }

    // ---- sequences (`std::spec::seq`) ---------------------------------------------------------------

    // The key of the prover's own function `op` (SQ_*): past every callee's `u64` key.
    const fn sqk(op: u64) Num<B> {
        return Num::<B>::one().shl(72) + u64_val::<B>(op);
    }

    // The SQ_* function term `t` applies, 0 for another term.
    const fn sq_of(self: &Self, t: u32) u64 {
        let x = self.tm.at(t);
        if x.op != T_CALL || x.k < Num::<B>::one().shl(72) {
            return 0;
        }
        return (x.k - Num::<B>::one().shl(72)).to_i64() as u64;
    }

    fn sq(self: &mut Self, op: u64, xs: &Vector<u32>, w: u16, sg: bool) u32 {
        return self.tm.call_k(Prover::<B>::sqk(op), xs, w, sg);
    }

    fn sq1(self: &mut Self, op: u64, a: u32, w: u16, sg: bool) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(a);
        return self.sq(op, &xs, w, sg);
    }

    fn sq2(self: &mut Self, op: u64, a: u32, b: u32, w: u16, sg: bool) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(a);
        xs.push(b);
        return self.sq(op, &xs, w, sg);
    }

    // An index of a sequence: a constant as an `int`, another integer as it is (its value is the index).
    fn sq_index(self: &mut Self, i: u32) u32 {
        let t = self.tm.at(i);
        if t.op == T_INT {
            return self.tm.int(t.k, W_INT, true);
        }
        // `x as int` has `x`'s value: one index term for both.
        if t.op == T_CAST && exact_w(t.w) && self.tm.at(t.a).w > W_BOOL && self.tm.at(t.a).w != W_OTHER {
            return self.sq_index(t.a);
        }
        return i;
    }

    // Whether term `t` is at least 0 by its form: a constant at least 0, a `nat`, or a value of an unsigned
    // fixed-width type (also cast to `int`).
    fn not_negative(self: &Self, t: u32) bool {
        let x = self.tm.at(t);
        if x.op == T_INT {
            return !x.k.is_negative();
        }
        if x.w == W_NAT || x.w <= 64 && !x.sg && x.w != W_OTHER && x.w != W_BOOL {
            return true;
        }
        return x.op == T_CAST && self.not_negative(x.a);
    }

    // `len(s)`, a `nat`: of the sequence with no element 0, of a push one more, of a concatenation the sum
    // (their facts in `seq_make`), of an update its sequence's (an update outside the sequence, which
    // `update`'s `requires` leaves unspecified, is the sequence: one model of it), else its own term.
    fn seq_len(self: &mut Self, s: u32) u32 {
        let op = self.sq_of(s);
        if op == SQ_EMPTY {
            return self.tm.int(Num::<B>::zero(), W_NAT, false);
        }
        if op == SQ_UPD {
            return self.seq_len(self.tm.args[self.tm.at(s).a as usize]);
        }
        // An array's view: the array's length.
        if op == SQ_VIEWA {
            let n = self.tm.args[(self.tm.at(s).a + 1) as usize];
            if self.tm.at(n).op == T_INT {
                return n;
            }
        }
        // A prefix (`take`) of a length that is not negative: that length; a subrange between constant
        // bounds `0 <= lo <= hi`: `hi - lo` (a subrange past the sequence's end, which `subrange`'s
        // `requires` leaves unspecified, has it too: one model of it).
        if op == SQ_SUB {
            let x = self.tm.at(s);
            let lo = self.tm.args[(x.a + 1) as usize];
            let hi = self.tm.args[(x.a + 2) as usize];
            let ilo = self.tm.at(lo).op == T_INT;
            if ilo && self.tm.at(lo).k.is_zero() && self.not_negative(hi) {
                return hi;
            }
            if ilo && self.tm.at(hi).op == T_INT && !self.tm.at(lo).k.is_negative() {
                let d = self.tm.arith(T_SUB, hi, lo, W_INT, true);
                if self.tm.at(d).op == T_INT && !self.tm.at(d).k.is_negative() {
                    return self.tm.int(self.tm.at(d).k, W_NAT, false);
                }
            }
        }
        if op == SQ_PUSH || op == SQ_CAT {
            let x = self.tm.at(s);
            let n0 = self.seq_len(self.tm.args[x.a as usize]);
            let n1 = if op == SQ_PUSH {
                self.tm.int(Num::<B>::one(), W_NAT, false)
            } else {
                self.seq_len(self.tm.args[(x.a + 1) as usize])
            };
            return self.tm.arith(T_ADD, n0, n1, W_NAT, false);
        }
        return self.sq1(SQ_LEN, s, W_NAT, false);
    }

    // Element `i` of sequence `s`, of type (`w`, `sg`): its fact through the function that made `s`,
    // anchored on the read, for `i` in the range that function defines.
    fn seq_at(self: &mut Self, s: u32, i0: u32, w: u16, sg: bool) u32 {
        let i = self.sq_index(i0);
        let r = self.sq2(SQ_AT, s, i, w, sg);
        if self.seld.contains_key(&r) {
            return r;
        }
        self.seld.insert(r, true);
        let op = self.sq_of(s);
        let sx = self.tm.at(s);
        let z = self.tm.int(Num::<B>::zero(), W_INT, true);
        let c0 = self.tm.cmp(T_LE, z, i);
        let f = if op == SQ_PUSH {
            let s0 = self.tm.args[sx.a as usize];
            let x = self.tm.args[(sx.a + 1) as usize];
            let n0 = self.seq_len(s0);
            let c1 = self.tm.cmp(T_LE, i, n0);
            let g = self.tm.and(c0, c1);
            let last = self.tm.cmp(T_EQ, i, n0);
            let e1 = self.tm.cmp(T_EQ, r, x);
            let a1 = self.tm.and(last, e1);
            let inner = self.seq_at(s0, i, w, sg);
            let e2 = self.tm.cmp(T_EQ, r, inner);
            let nl = self.tm.not(last);
            let a2 = self.tm.and(nl, e2);
            let b = self.tm.or(a1, a2);
            self.implied(g, b)
        } else if op == SQ_UPD {
            let s0 = self.tm.args[sx.a as usize];
            let j = self.tm.args[(sx.a + 1) as usize];
            let x = self.tm.args[(sx.a + 2) as usize];
            let n0 = self.seq_len(s0);
            let cj0 = self.tm.cmp(T_LE, z, j);
            let cj1 = self.tm.cmp(T_LT, j, n0);
            let ci1 = self.tm.cmp(T_LT, i, n0);
            let g1 = self.tm.and(cj0, cj1);
            let g2 = self.tm.and(c0, ci1);
            let g = self.tm.and(g1, g2);
            let at = self.tm.cmp(T_EQ, i, j);
            let e1 = self.tm.cmp(T_EQ, r, x);
            let a1 = self.tm.and(at, e1);
            let inner = self.seq_at(s0, i, w, sg);
            let e2 = self.tm.cmp(T_EQ, r, inner);
            let na = self.tm.not(at);
            let a2 = self.tm.and(na, e2);
            let b = self.tm.or(a1, a2);
            self.implied(g, b)
        } else if op == SQ_SUB {
            let s0 = self.tm.args[sx.a as usize];
            let lo = self.tm.args[(sx.a + 1) as usize];
            let hi = self.tm.args[(sx.a + 2) as usize];
            let g0 = self.sub_ok(s0, lo, hi);
            let d = self.tm.arith(T_SUB, hi, lo, W_INT, true);
            let ci1 = self.tm.cmp(T_LT, i, d);
            let gi = self.tm.and(c0, ci1);
            let g = self.tm.and(g0, gi);
            let li = self.tm.arith(T_ADD, lo, i, W_INT, true);
            let inner = self.seq_at(s0, li, w, sg);
            let e = self.tm.cmp(T_EQ, r, inner);
            self.implied(g, e)
        } else if op == SQ_CAT {
            let s0 = self.tm.args[sx.a as usize];
            let s1 = self.tm.args[(sx.a + 1) as usize];
            let n0 = self.seq_len(s0);
            let n1 = self.seq_len(s1);
            let n = self.tm.arith(T_ADD, n0, n1, W_INT, true);
            let ci1 = self.tm.cmp(T_LT, i, n);
            let g = self.tm.and(c0, ci1);
            let left = self.tm.cmp(T_LT, i, n0);
            let in0 = self.seq_at(s0, i, w, sg);
            let e1 = self.tm.cmp(T_EQ, r, in0);
            let a1 = self.tm.and(left, e1);
            let k = self.tm.arith(T_SUB, i, n0, W_INT, true);
            let in1 = self.seq_at(s1, k, w, sg);
            let e2 = self.tm.cmp(T_EQ, r, in1);
            let nleft = self.tm.not(left);
            let a2 = self.tm.and(nleft, e2);
            let b = self.tm.or(a1, a2);
            self.implied(g, b)
        } else if op == SQ_VIEWA {
            // An element of an array read whole (`eta`): of the term it was read from, one read at the
            // index, not a case per member.
            let a0 = self.tm.args[sx.a as usize];
            let arr = if let Some(src) = self.eta_src.get(&a0) {
                *src
            } else {
                a0
            };
            let n = self.tm.args[(sx.a + 1) as usize];
            let ci1 = self.tm.cmp(T_LT, i, n);
            let g = self.tm.and(c0, ci1);
            let key = self.index_key(i);
            let m = self.sel(arr, key, w, sg);
            let e = self.tm.cmp(T_EQ, r, m);
            self.implied(g, e)
        } else {
            self.tm.boolean(true)
        };
        if !self.tm.is_true(f) {
            self.anchor(r, f);
        }
        // A spec function's result: where it equals a sequence its body returns, its elements are that one's.
        if let Some(al) = self.alias.get(&s) {
            let (st, n) = (*al >> 32, *al & 0xFFFFFFFFu64);
            for j in st..st + n {
                let v = self.alias_pool[j as usize];
                let rv = self.seq_at(v, i, w, sg);
                let ne = self.tm.cmp(T_NE, s, v);
                let e = self.tm.cmp(T_EQ, r, rv);
                let g = self.tm.or(ne, e);
                self.anchor(r, g);
            }
        }
        return r;
    }

    fn implied(self: &mut Self, g: u32, b: u32) u32 {
        let ng = self.tm.not(g);
        return self.tm.or(ng, b);
    }

    // `0 <= lo <= hi <= len(s)`.
    fn sub_ok(self: &mut Self, s: u32, lo: u32, hi: u32) u32 {
        let z = self.tm.int(Num::<B>::zero(), W_INT, true);
        let n = self.seq_len(s);
        let a = self.tm.cmp(T_LE, z, lo);
        let b = self.tm.cmp(T_LE, lo, hi);
        let c = self.tm.cmp(T_LE, hi, n);
        let ab = self.tm.and(a, b);
        return self.tm.and(ab, c);
    }

    // Whether integer term `n` is the length of sequence `s`: its length's term, or a slice view's slice length.
    fn len_is(self: &mut Self, s: u32, n: u32) bool {
        if self.same_int(n, self.seq_len(s)) {
            return true;
        }
        if self.sq_of(s) != SQ_VIEWS {
            return false;
        }
        let l = self.sq1(SQ_SLEN, self.tm.args[self.tm.at(s).a as usize], self.pw, false);
        return self.same_int(n, l);
    }

    // Whether integer terms `a` and `b` are one value: one term, equal constants, a cast of one to a
    // mathematical integer, or sums of such.
    fn same_int(self: &Self, a: u32, b: u32) bool {
        let mut x = a;
        let mut y = b;
        for _d in 0..8 {
            if x == y {
                return true;
            }
            let tx = self.tm.at(x);
            let ty = self.tm.at(y);
            if tx.op == T_INT && ty.op == T_INT {
                return tx.k == ty.k;
            }
            if tx.op == T_CAST && (tx.w == W_INT || tx.w == W_NAT) {
                x = tx.a;
            } else if ty.op == T_CAST && (ty.w == W_INT || ty.w == W_NAT) {
                y = ty.a;
            } else if tx.op == T_ADD && ty.op == T_ADD {
                return self.same_int(tx.a, ty.a) && self.same_int(tx.b, ty.b) || self.same_int(tx.a, ty.b) && self.same_int(
                    tx.b,
                    ty.a,
                );
            } else {
                return false;
            }
        }
        return false;
    }

    // Sequence `op` over `xs` (SQ_EMPTY, SQ_PUSH, SQ_UPD, SQ_SUB, SQ_CAT, the views), with the
    // fact of its length anchored on it.
    fn seq_make(self: &mut Self, op: u64, xs: &Vector<u32>) u32 {
        // A prefix as long as its sequence: the sequence; of a concatenation, as long as its first part:
        // that part.
        if op == SQ_SUB && self.tm.at(xs[1]).op == T_INT && self.tm.at(xs[1]).k.is_zero() {
            if self.len_is(xs[0], xs[2]) {
                // The prefix stays the sequence's equal: a prefix whose bound equals this one only as a
                // fact of the path reaches the sequence by congruence.
                let c = self.sq(op, xs, W_OTHER, false);
                if !self.seld.contains_key(&c) {
                    self.seld.insert(c, true);
                    let e = self.tm.cmp(T_EQ, c, xs[0]);
                    self.anchor(xs[0], e);
                }
                return xs[0];
            }
            if self.sq_of(xs[0]) == SQ_CAT {
                let a = self.tm.args[self.tm.at(xs[0]).a as usize];
                if self.len_is(a, xs[2]) {
                    return a;
                }
            }
        }
        let c = self.sq(op, xs, W_OTHER, false);
        if self.seld.contains_key(&c) {
            return c;
        }
        self.seld.insert(c, true);
        let n = self.seq_len(c);
        let f = if op == SQ_EMPTY {
            let z = self.tm.int(Num::<B>::zero(), W_NAT, false);
            self.tm.cmp(T_EQ, n, z)
        } else if op == SQ_PUSH {
            let n0 = self.seq_len(xs[0]);
            let one = self.tm.int(Num::<B>::one(), W_NAT, false);
            let m = self.tm.arith(T_ADD, n0, one, W_NAT, false);
            self.tm.cmp(T_EQ, n, m)
        } else if op == SQ_SUB {
            // `hi - lo` between bounds `0 <= lo <= hi`, also past the sequence's end (`seq_len`).
            let z = self.tm.int(Num::<B>::zero(), W_INT, true);
            let g0 = self.tm.cmp(T_LE, z, xs[1]);
            let g1 = self.tm.cmp(T_LE, xs[1], xs[2]);
            let g = self.tm.and(g0, g1);
            let d = self.tm.arith(T_SUB, xs[2], xs[1], W_INT, true);
            let e = self.tm.cmp(T_EQ, n, d);
            self.implied(g, e)
        } else if op == SQ_CAT {
            let n0 = self.seq_len(xs[0]);
            let n1 = self.seq_len(xs[1]);
            let m = self.tm.arith(T_ADD, n0, n1, W_NAT, false);
            self.tm.cmp(T_EQ, n, m)
        } else if op == SQ_VIEWA {
            self.tm.cmp(T_EQ, n, xs[1])
        } else if op == SQ_VIEWS {
            let l = self.sq1(SQ_SLEN, xs[0], self.pw, false);
            self.tm.cmp(T_EQ, n, l)
        } else {
            self.tm.boolean(true)
        };
        if !self.tm.is_true(f) {
            self.anchor(c, f);
        }
        return c;
    }

    // The index of variant `d` among its enum's variants, -1 for another declaration.
    fn variant_index(self: &Self, d: DefId) i64 {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return -1;
        }
        if self.ast_of(d.module).at_const(d.node).kind != NodeKind::NODE_VARIANT {
            return -1;
        }
        let mut ord: i64 = 0;
        return pick(self.pkg().variant_enum(d, &mut ord) != NODE_NONE, ord, -1);
    }

    // Whether term `t` names an equality of sequences (`seq_ext`) or an element of a sequence.
    fn names_seq(self: &Self, t: u32) bool {
        let mut eqs = Map::<u32, bool>::new();
        for q in 0..self.seqeqs.len() / 3 {
            eqs.insert(self.seqeqs[3 * q], true);
        }
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(t);
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return false;
            }
            let x = stack.pop().unwrap();
            if seen.contains_key(&x) {
                continue;
            }
            seen.insert(x, true);
            if eqs.contains_key(&x) || self.sq_of(x) == SQ_AT {
                return true;
            }
            self.tm.operands(x, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
        return false;
    }

    // Equality `e` of sequences `x` and `y` of elements (`w`, `sg`): extensional, by the fact of a
    // witness `k` of a difference: `e || len(x) != len(y) || (0 <= k < len(x) && x[k] != y[k])`, which a
    // goal that names `e` takes (`seqwit`).
    fn seq_ext(self: &mut Self, e: u32, x: u32, y: u32, w: u16, sg: bool) {
        if self.seld.contains_key(&e) || self.tm.is_true(e) || self.tm.is_false(e) {
            return;
        }
        self.seld.insert(e, true);
        let nx = self.seq_len(x);
        let ny = self.seq_len(y);
        let ne = self.tm.cmp(T_NE, nx, ny);
        let k = self.tm.var(W_INT, true);
        let z = self.tm.int(Num::<B>::zero(), W_INT, true);
        let a = self.tm.cmp(T_LE, z, k);
        let b = self.tm.cmp(T_LT, k, nx);
        let ax = self.seq_at(x, k, w, sg);
        let ay = self.seq_at(y, k, w, sg);
        let d = self.tm.cmp(T_NE, ax, ay);
        let ab = self.tm.and(a, b);
        let wit = self.tm.and(ab, d);
        let o = self.tm.or(ne, wit);
        let f0 = self.tm.or(e, o);
        // A goal that names the equality takes the witness (`goal_witnesses`): as a fact of every path it
        // only adds cases. Equal sequences have one length, and one element at each index (`instantiate`, where the
        // formulas read one).
        self.seqwit.insert(e, f0);
        self.seqw.insert(e, w as u32 << 1 | pick(sg, 1u32, 0u32));
        let ne0 = self.tm.not(e);
        let le = self.tm.cmp(T_EQ, nx, ny);
        let f1 = self.tm.or(ne0, le);
        self.anchor(e, f1);
        self.seqeqs.push(e);
        self.seqeqs.push(x);
        self.seqeqs.push(y);
    }

    // The element type of `Seq<T>` type `ty` (of module `m`), TYPE_NONE when `ty` is no sequence.
    fn seq_elem(self: &Self, m: ModuleId, ty: TypeId) TypeId {
        if ty == TYPE_NONE || self.seqd == NODE_NONE {
            return TYPE_NONE;
        }
        let mut t = ty;
        let a = self.ast_of(m);
        for _k in 0..4 {
            if a.type_at(t).kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            t = a.type_at(t).as_data.elem;
        }
        let y = a.type_at(t);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return TYPE_NONE;
        }
        let inst = a.instance(y.as_data.inst);
        if inst.module != self.seqm as ModuleId || inst.decl != self.seqd || inst.n == 0 {
            return TYPE_NONE;
        }
        return inst.args[0];
    }

    // The declaration `ty` (of module `m`) is an instance of, through references: (module, node).
    fn decl_of(self: &Self, m: ModuleId, ty: TypeId) (ModuleId, NodeId) {
        if ty == TYPE_NONE {
            return 0, NODE_NONE;
        }
        let a = self.ast_of(m);
        let mut t = ty;
        for _k in 0..4 {
            if a.type_at(t).kind != TypeKind::TYPE_REFERENCE && a.type_at(t).kind != TypeKind::TYPE_POINTER {
                break;
            }
            t = a.type_at(t).as_data.elem;
        }
        let y = a.type_at(t);
        if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = a.instance(y.as_data.inst);
            return inst.module, inst.decl;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.module, y.as_data.decl;
        }
        return 0, NODE_NONE;
    }

    // Whether type `ty` (module `m`) is a vector or a string: a shared borrow of one cannot change its
    // value, and the elements its view holds change only through a `&mut` of it.
    fn container(self: &Self, m: ModuleId, ty: TypeId) bool {
        let (dm, dd) = self.decl_of(m, ty);
        return dd != NODE_NONE && self.ast_of(m).type_at(ty).kind != TypeKind::TYPE_REFERENCE && (dm == self.vecl.mid && dd == self.vecl.node || dm == self.strl.mid && dd == self.strl.node);
    }

    // What call `t` of body `cb` (module `cm`) is to the sequences: an SQ_* operation of `Seq` or a
    // view (SQ_VIEW), or a modeled method of the containers (VK_*); 0 for any other call.
    fn sq_kind(self: &Self, cb: &ir::CoreBody, cm: ModuleId, t: &ir::Terminator) u64 {
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return 0;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return 0;
        }
        let nm = self.text(d.module, a.at_const(a.ext_name(d.node)).span);
        // The receiver's declaration (the first argument's type), or the result's for a constructor.
        let (rm, rd) = if t.args_len != 0 {
            self.decl_of(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty)
        } else {
            (0 as ModuleId, NODE_NONE)
        };
        let (om, od) = if t.dests_len == 1 {
            self.decl_of(cm, cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty)
        } else {
            (0 as ModuleId, NODE_NONE)
        };
        // Vector's view: its definition in a body of its own module (`block(ptr).take(len)`), a term of
        // its own in another body, also in a callee's clauses read there.
        if nm == "view" && d.module == self.vecl.mid && self.vecl.node != NODE_NONE {
            return pick(self.m == self.vecl.mid, 0u64, SQ_VIEW);
        }
        // String's view alike (`storage().take(length())` in its own module).
        if nm == "view" && d.module == self.strl.mid && self.strl.node != NODE_NONE {
            return pick(self.m == self.strl.mid, 0u64, SQ_VIEW);
        }
        if self.seqm >= 0 && d.module == self.seqm as ModuleId {
            if nm == "view" {
                return SQ_VIEW;
            }
            if nm == "block" {
                return SQ_BLOCK;
            }
            let on_seq = rm == self.seqm as ModuleId && rd == self.seqd;
            if nm == "empty" && om == self.seqm as ModuleId && od == self.seqd {
                return SQ_EMPTY;
            }
            if !on_seq {
                return 0;
            }
            return if nm == "len" {
                SQ_LEN
            } else if nm == "index" {
                SQ_AT
            } else if nm == "push" {
                SQ_PUSH
            } else if nm == "update" {
                SQ_UPD
            } else if nm == "subrange" {
                SQ_SUB
            } else if nm == "take" {
                SQ_TAKE
            } else if nm == "skip" {
                SQ_SKIP
            } else if nm == "concat" {
                SQ_CAT
            } else {
                0
            };
        }
        // The containers' own methods only: std's, which no program extends with a same-named one.
        let mp = self.pkg().modules.at(d.module as usize).path.as_str();
        if !mp.starts_with("std::") && !mp.starts_with("__std::") {
            return 0;
        }
        let vec = rm == self.vecl.mid && rd == self.vecl.node && rd != NODE_NONE;
        if rm == self.strv.mid && rd == self.strv.node && rd != NODE_NONE {
            return if nm == "len" {
                VK_LEN
            } else if nm == "index" {
                VK_INDEX
            } else if nm == "ptr" && t.args_len == 1 {
                VK_SPTR
            } else {
                0
            };
        }
        // A vector's and a string's other methods are calls as any other: their contracts give their
        // effects. A borrow of a vector's elements (`at`, `index`, a view) is modeled, in its own module
        // too, but in the body that defines it.
        if vec {
            if self.m == self.vecl.mid && self.owner.module == d.module && self.owner.node == d.node {
                return 0;
            }
            return if nm == "index" || nm == "at" {
                VK_INDEX
            } else if nm == "index_mut" {
                VK_INDEX_MUT
            } else if nm == "as_slice" || nm == "as_mut_slice" {
                VK_AS_SLICE
            } else if nm == "index_range" {
                VK_RANGE
            } else if nm == "index_range_mut" {
                VK_RANGE_MUT
            } else {
                0
            };
        }
        let view = rd != NODE_NONE && (rm == self.smut.mid && rd == self.smut.node || rm == self.slice.mid && rd == self.slice.node);
        if view && nm == "index_mut" && rm == self.smut.mid && rd == self.smut.node {
            return VK_SINDEX_MUT;
        }
        if view && nm == "len" {
            return VK_SLEN;
        }
        if view && nm == "as_slice" && rm == self.smut.mid && rd == self.smut.node {
            return VK_SHARE;
        }
        if view && (nm == "index" || nm == "get" || nm == "at") {
            return VK_SINDEX;
        }
        if view && nm == "index_range" {
            return VK_RANGE;
        }
        if view && nm == "index_range_mut" && rm == self.smut.mid && rd == self.smut.node {
            return VK_RANGE_MUT;
        }
        return 0;
    }

    // `holds` within `steps`.
    fn holds_within(self: &mut Self, pc: &Vector<u32>, goal: u32, steps: u32) bool {
        let limit = self.sv.limit;
        self.sv.limit = limit.min(self.sv.steps.saturating_add(steps));
        let ok = self.holds(pc, goal);
        self.sv.limit = limit;
        return ok;
    }

    // `s.subrange(lo, hi)`.
    fn sub_seq(self: &mut Self, s: u32, lo: u32, hi: u32) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(s);
        xs.push(lo);
        xs.push(hi);
        return self.seq_make(SQ_SUB, &xs);
    }

    // `a.concat(c)`.
    fn cat_seq(self: &mut Self, a: u32, c: u32) u32 {
        let mut xs = Vector::<u32>::new();
        xs.push(a);
        xs.push(c);
        return self.seq_make(SQ_CAT, &xs);
    }

    // The length and the view of the receiver of call `t` (a vector, a string, a view), NONE where it is
    // no modeled container.
    fn recv_cont(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) (u32, u32) {
        let v = self.recv_value(b, b.module, &mut path.state, t, false);
        if v == NONE {
            return NONE, NONE;
        }
        let mut ty = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
        let a = self.ast_of(b.module);
        if a.type_at(ty).kind == TypeKind::TYPE_REFERENCE || a.type_at(ty).kind == TypeKind::TYPE_POINTER {
            ty = a.type_at(ty).as_data.elem;
        }
        let (dm, dd) = self.decl_of(b.module, ty);
        if dd == NODE_NONE {
            return NONE, NONE;
        }
        if dm == self.slice.mid && dd == self.slice.node || dm == self.smut.mid && dd == self.smut.node {
            let ep = self.slice_ep(b.module, ty, &path.state);
            return self.sq1(SQ_SLEN, v, self.pw, false), self.view_s(v, ep);
        }
        if dm == self.vecl.mid && dd == self.vecl.node {
            self.vec_fields(v);
        }
        if dm == self.vecl.mid && dd == self.vecl.node || dm == self.strl.mid && dd == self.strl.node {
            return self.vlen(v, self.pw, false), self.view_v(v);
        }
        return NONE, NONE;
    }

    // Whether function `d` states a contract: a `requires`, an `ensures` or a `panics if`.
    fn contracted(self: &Self, d: DefId) bool {
        return self.has_clause(d, CT_REQUIRES) || self.has_clause(d, CT_ENSURES) || self.has_clause(d, CT_PANICS);
    }

    // The function whose clauses a call of `d` proves and assumes: `d`, or for a conformance's method that
    // states none, the interface's method it implements (the refinement walk proves the body keeps them).
    fn contract_of(self: &Self, d: DefId) DefId {
        if d.node == NODE_NONE || self.contracted(d) {
            return d;
        }
        let im = self.iface_member(d);
        if im.node != NODE_NONE && self.contracted(im) {
            return im;
        }
        return d;
    }

    // Whether the vector struct states an invariant: its methods are proved against its fields
    // (`vec_fields`, `relink`).
    fn vec_inv(self: &Self) bool {
        let a = self.ast_of(self.vecl.mid);
        let (cs, ce) = a.contracts_of(self.vecl.node);
        return ce > cs;
    }

    // In a body of the vector's own module, vector value `v`'s view is its fields' (`Vector::view`):
    // `block(ptr).take(len)`, the term the spec function unfolds to (`vdef`).
    fn vec_fields(self: &mut Self, v: u32) {
        if self.m != self.vecl.mid || v == NONE || self.vdef.contains_key(&v) || !self.vec_inv() {
            return;
        }
        let a = self.ast_of(self.vecl.mid);
        let ms = a.ext(self.vecl.node).aggregate.members;
        let (mut ip, mut il) = (-1i64, -1i64);
        for j in 0..ms.len {
            let mn = a.at_const(unsafe a.list(ms)[j as usize]);
            if mn.kind != NodeKind::NODE_FIELD {
                continue;
            }
            let nm = self.text(self.vecl.mid, a.at_const(mn.as_data.field.name).span);
            if nm == "ptr" {
                ip = j;
            } else if nm == "len" {
                il = j;
            }
        }
        if ip < 0 || il < 0 {
            return;
        }
        let ok = self.tm.int(wide::<B>(ip) + Num::<B>::one().shl(41), 64, false);
        let blk = self.tm.sel(v, ok, W_OTHER, false);
        let lk = self.tm.int(wide::<B>(il), 64, false);
        let n = self.tm.sel(v, lk, self.pw, false);
        let mut xs = Vector::<u32>::new();
        xs.push(blk);
        xs.push(self.tm.int(Num::<B>::zero(), W_INT, true));
        xs.push(n);
        let view = self.seq_make(SQ_SUB, &xs);
        self.vdef.insert(v, view);
    }

    // The bounds check of modeled element or range call `t` (`index`, `index_mut`, `index_range`): an
    // obligation, then a fact of the path. A range's bounds: `lo <= hi <= len`, its end inclusive with
    // `inclusive` (`hi < len`, the range one longer).
    fn bounds_check(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        let k = self.sq_kind(b, b.module, t);
        let elem = k == VK_INDEX || k == VK_SINDEX || k == VK_INDEX_MUT || k == VK_SINDEX_MUT;
        if !elem && k != VK_RANGE && k != VK_RANGE_MUT || t.args_len != 2 {
            return;
        }
        let (n, _view) = self.recv_cont(b, path, t);
        if n == NONE {
            return;
        }
        let x = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
        let c = if elem {
            if !self.tm.is_int(x) {
                return;
            }
            self.tm.cmp(T_LT, x, n)
        } else {
            let (lo, hi, inc) = self.range_parts(x);
            if lo == NONE {
                return;
            }
            let l1 = self.tm.cmp(T_LE, lo, hi);
            let h1 = self.tm.cmp(T_LE, hi, n);
            let ex = self.tm.and(l1, h1);
            let h2 = self.tm.cmp(T_LT, hi, n);
            let one = self.tm.int(Num::<B>::one(), W_INT, true);
            let hi1 = self.tm.arith(T_ADD, hi, one, W_INT, true);
            let l2 = self.tm.cmp(T_LE, lo, hi1);
            let incl = self.tm.and(h2, l2);
            let a = self.tm.and(self.tm.not(inc), ex);
            let bb = self.tm.and(inc, incl);
            self.tm.or(a, bb)
        };
        let key = pick(self.in_ghost, OB_GHOST, OB_PANIC) << 56 | 3 << 53 | t.span.start as u64;
        self.oblige(
            &path.pc,
            c,
            key,
            t.span,
            format("cannot prove that this index is in bounds"),
            String::from_str(
                pick(self.in_ghost, "ghost code never runs: each of its checks is an obligation", NO_PANIC_NOTE),
            ),
        );
        path.pc.push(c);
    }

    // The start, the end and the inclusive flag of range value `r` (`Range<usize>`), NONE where it is no
    // value of three members.
    fn range_parts(self: &mut Self, r: u32) (u32, u32, u32) {
        if r == NONE || self.tm.at(r).w != W_OTHER {
            return NONE, NONE, NONE;
        }
        let k0 = self.tm.int(Num::<B>::zero(), 64, false);
        let k1 = self.tm.int(Num::<B>::one(), 64, false);
        let k2 = self.tm.int(wide::<B>(2), 64, false);
        let lo = self.sel(r, k0, self.pw, false);
        let hi = self.sel(r, k1, self.pw, false);
        let inc = self.sel(r, k2, W_BOOL, false);
        return lo, hi, inc;
    }

    // The value of the receiver of call `t` (its first argument): the place an implicit borrow takes,
    // or what the reference passed refers to.
    fn recv_value(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let oid = cb.oper_pool[t.args_start as usize];
        let op = *cb.operands.at(oid as usize);
        if self.autoref(cb, cm, t, 0) {
            return self.read_place(cb, cm, state, op.data, all);
        }
        let x = self.operand(cb, cm, state, oid, all);
        let y = self.ast_of(cm).type_at(op.ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return self.deref(state, x, cm, y.as_data.elem);
        }
        return x;
    }

    // The (width, signed) of the element type of the reference type `ty` (module `m`) points to.
    fn pointee_w(self: &Self, m: ModuleId, ty: TypeId) (u16, bool) {
        let y = *self.ast_of(m).type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            return self.ty_of(m, y.as_data.elem);
        }
        return W_OTHER, false;
    }

    // The value of call `t` when it is a pure operation of the sequences or a modeled read of a
    // container (`sq_kind`), NONE otherwise.
    fn sq_value(
        self: &mut Self,
        cb: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        t: &ir::Terminator,
        all: bool,
    ) u32 {
        let k = self.sq_kind(cb, cm, t);
        if k == 0 {
            return NONE;
        }
        let rty = if t.dests_len == 1 {
            cb.places.at(cb.dest_pool[t.dests_start as usize] as usize).ty
        } else {
            TYPE_NONE
        };
        let mut xs = Vector::<u32>::new();
        if k == SQ_VIEW {
            let rt = cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty;
            let v = self.recv_value(cb, cm, state, t, all);
            let (vm, vd) = self.decl_of(cm, rt);
            let vx = self.tm.at(v);
            let slice = vm == self.slice.mid && vd == self.slice.node || vm == self.smut.mid && vd == self.smut.node;
            if vx.op == T_VIEW {
                // An array's view: its members.
                xs.push(vx.a);
                xs.push(self.tm.int(vx.k, W_NAT, false));
                return self.seq_make(SQ_VIEWA, &xs);
            }
            if slice {
                let ep = self.slice_ep(cm, rt, state);
                return self.view_s(v, ep);
            }
            return self.view_v(v);
        }
        if k == SQ_EMPTY {
            return self.seq_make(SQ_EMPTY, &xs);
        }
        if k == SQ_BLOCK {
            // The struct's block member, where the argument reads an `@owned` field; else unknown.
            let op = *cb.operands.at(cb.oper_pool[t.args_start as usize] as usize);
            if op.kind != ir::OP_CONST {
                let pl = *cb.places.at(op.data as usize);
                if pl.proj_len != 0 {
                    let fj = pl.proj_len - 1;
                    let pj = *cb.projections.at((pl.proj_start + fj) as usize);
                    let bty = self.proj_base_ty(cb, &pl, fj);
                    if self.owned_field(cm, bty, &pj) && (all || self.tracked[pl.base as usize]) {
                        let sv = self.read_prefix(cb, cm, state, &pl, fj, all);
                        let k2 = self.own_key(cm, bty, &pj);
                        return self.sel(sv, k2, W_OTHER, false);
                    }
                }
            }
            return self.tm.var(W_OTHER, false);
        }
        if k == SQ_LEN {
            let s = self.recv_value(cb, cm, state, t, all);
            return self.seq_len(s);
        }
        if k == SQ_AT {
            let s = self.recv_value(cb, cm, state, t, all);
            let i = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + 1) as usize], all);
            let (w, sg) = self.pointee_w(cm, rty);
            let e = self.seq_at(s, i, w, sg);
            return self.tm.unary(T_REF, e, W_OTHER, false);
        }
        if (k == SQ_TAKE || k == SQ_SKIP) && t.args_len == 2 {
            let sv = self.recv_value(cb, cm, state, t, all);
            let n = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + 1) as usize], all);
            let ni = self.sq_index(n);
            xs.push(sv);
            if k == SQ_TAKE {
                xs.push(self.tm.int(Num::<B>::zero(), W_INT, true));
                xs.push(ni);
            } else {
                xs.push(ni);
                xs.push(self.seq_len(sv));
            }
            return self.seq_make(SQ_SUB, &xs);
        }
        if k == SQ_PUSH || k == SQ_UPD || k == SQ_SUB || k == SQ_CAT {
            xs.push(self.recv_value(cb, cm, state, t, all));
            for j in 1..t.args_len {
                let x = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + j) as usize], all);
                xs.push(
                    if j == 1 && k != SQ_PUSH && k != SQ_CAT || j == 2 && k == SQ_SUB {
                        self.sq_index(x)
                    } else {
                        x
                    },
                );
            }
            return self.seq_make(k, &xs);
        }
        let v = self.recv_value(cb, cm, state, t, all);
        let (w, sg) = self.ty_of(cm, rty);
        if k == VK_LEN || k == VK_SLEN {
            self.len_cap(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty, v);
        }
        if k == VK_LEN {
            return self.vlen(v, w, sg);
        }
        if k == VK_SPTR {
            return self.sel(v, self.tm.int(Num::<B>::zero(), 64, false), W_OTHER, false);
        }
        if k == VK_SLEN || k == VK_SINDEX {
            let vx = self.tm.at(v);
            if k == VK_SLEN {
                if vx.op == T_VIEW {
                    return self.tm.int(vx.k, w, sg);
                }
                // A literal's length is its member (`slice_field`).
                let n = self.slice_field(v, true);
                return pick(w == self.pw && !sg, n, self.tm.unary(T_CAST, n, w, sg));
            }
            let i = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + 1) as usize], all);
            let (ew, esg) = self.pointee_w(cm, rty);
            let e = if vx.op == T_VIEW {
                let key = self.index_key(i);
                self.sel(vx.a, key, ew, esg)
            } else {
                let ep = self.slice_ep(cm, cb.operands.at(cb.oper_pool[t.args_start as usize] as usize).ty, state);
                let view = self.view_s(v, ep);
                self.seq_at(view, i, ew, esg)
            };
            return self.tm.unary(T_REF, e, W_OTHER, false);
        }
        if k == VK_INDEX {
            let i = self.operand(cb, cm, state, cb.oper_pool[(t.args_start + 1) as usize], all);
            let view = self.view_v(v);
            let (ew, esg) = self.pointee_w(cm, rty);
            let e = self.seq_at(view, i, ew, esg);
            return self.tm.unary(T_REF, e, W_OTHER, false);
        }
        return NONE;
    }

    // `seq_make` over one argument, none with NONE.
    fn seq_make1(self: &mut Self, op: u64, a: u32) u32 {
        let mut xs = Vector::<u32>::new();
        if a != NONE {
            xs.push(a);
        }
        return self.seq_make(op, &xs);
    }

    // The equalities `view(x) == E` fact `f` states (a part of a conjunction): `E` is the view of `x` from
    // here on (`vdef`), as a modeled method's is, one term for the equal ones. `depth` parts deep.
    fn view_defs(self: &mut Self, f: u32, depth: u32) {
        let x = self.tm.at(f);
        if x.op == T_AND && depth < 8 {
            self.view_defs(x.a, depth + 1);
            self.view_defs(x.b, depth + 1);
            return;
        }
        if x.op != T_EQ {
            return;
        }
        for side in 0..2 {
            let (v, e) = pick(side == 0, (x.a, x.b), (x.b, x.a));
            if self.sq_of(v) == SQ_VIEWV {
                let ov = self.tm.args[self.tm.at(v).a as usize];
                if !self.vdef.contains_key(&ov) && self.sq_of(e) != SQ_VIEWV {
                    self.vdef.insert(ov, e);
                }
                return;
            }
        }
    }

    // The view of container value `v` (a vector's, a string's, a `str`'s): the sequence a modeled
    // method made it (`vdef`), else its own term.
    fn view_v(self: &mut Self, v: u32) u32 {
        if let Some(d) = self.vdef.get(&v) {
            return *d;
        }
        return self.seq_make1(SQ_VIEWV, v);
    }

    // The memory epoch the view of a slice of type `ty` (module `m`) depends on in `state`: the
    // current one for a `[]mut T`; none for a `[]T`, whose elements no write reaches while it lives.
    fn slice_ep(self: &mut Self, m: ModuleId, ty: TypeId, state: &Vector<u32>) u32 {
        let (dm, dd) = self.decl_of(m, ty);
        if dd != NODE_NONE && dm == self.smut.mid && dd == self.smut.node {
            return state[state.len() - 1];
        }
        return self.tm.boolean(false);
    }

    // The view of slice value `xs` in memory epoch `ep`: the sequence a modeled call made it (`sdef`),
    // else its own term.
    fn view_s(self: &mut Self, xs: u32, ep: u32) u32 {
        if let Some(d) = self.sdef.get(&(xs as u64 << 32 | ep as u64)) {
            return *d;
        }
        let mut a = Vector::<u32>::new();
        a.push(xs);
        a.push(ep);
        return self.seq_make(SQ_VIEWS, &a);
    }

    // The length of container value `v` (a vector's, a string's) as (`w`, `sg`): the length of its view.
    fn vlen(self: &mut Self, v: u32, w: u16, sg: bool) u32 {
        let n = self.sq1(SQ_VLEN, v, self.pw, false);
        if !self.seld.contains_key(&n) {
            self.seld.insert(n, true);
            let view = self.view_v(v);
            let m = self.seq_len(view);
            let f = self.tm.cmp(T_EQ, n, m);
            self.anchor(n, f);
        }
        if w == self.pw && !sg {
            return n;
        }
        return self.tm.unary(T_CAST, n, w, sg);
    }

    // The local or slot the receiver of call `t` (a `&mut` of a container) names, NONE when the walk
    // does not know it.
    fn recv_target(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, t: &ir::Terminator) u32 {
        let r = self.recv_ref(cb, cm, state, t);
        if r == NONE {
            return NONE;
        }
        return self.ref_target(r);
    }

    // The reference call `t`'s receiver is (`T_MREF`, `T_PREF`): an implicit borrow of a place, or a
    // reference the receiver holds; NONE when it reaches memory otherwise.
    fn recv_ref(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &mut Vector<u32>, t: &ir::Terminator) u32 {
        let oid = cb.oper_pool[t.args_start as usize];
        let op = *cb.operands.at(oid as usize);
        if op.kind == ir::OP_CONST {
            return NONE;
        }
        let p = *cb.places.at(op.data as usize);
        if self.autoref(cb, cm, t, 0) {
            return self.place_ref(cb, cm, state, &p);
        }
        let x = self.operand(cb, cm, state, oid, false);
        if self.tm.at(x).op == T_MREF || self.tm.at(x).op == T_PREF {
            return x;
        }
        return NONE;
    }

    // Call `t` of the body when it changes a container the walk knows (`sq_kind`): the container's new
    // value with the fact of its new view, and the call's result. Whether it did.
    fn sq_effect(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) bool {
        let k = self.sq_kind(b, b.module, t);
        if k != VK_INDEX_MUT && k != VK_AS_SLICE && k != VK_SINDEX_MUT && k != VK_SHARE && k != VK_RANGE && k != VK_RANGE_MUT {
            return false;
        }
        let cm = b.module;
        let dest = if t.dests_len == 1 {
            b.dest_pool[t.dests_start as usize]
        } else {
            ir::IR_NONE
        };
        if k == VK_SINDEX_MUT {
            // A reference to element `i` of the view: a write through it changes the view (`write_place`).
            let s = self.recv_value(b, cm, &mut path.state, t, false);
            let i = self.operand(b, cm, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
            let i2 = self.sq_index(i);
            let r = self.sq2(SQ_SEREF, s, i2, W_OTHER, false);
            if dest != ir::IR_NONE {
                self.write_place(b, cm, &mut path.state, dest, r, false);
            }
            return true;
        }
        if k == VK_SHARE {
            if dest == ir::IR_NONE {
                return true;
            }
            // A shared view of a `[]mut`: its elements now, which no write changes while it lives.
            let sv = self.recv_value(b, cm, &mut path.state, t, false);
            let ov = self.view_s(sv, path.state[path.state.len() - 1]);
            let xs = self.fresh(cm, b.places.at(dest as usize).ty);
            self.sdef.insert(xs as u64 << 32 | self.tm.boolean(false) as u64, ov);
            let sl = self.sq1(SQ_SLEN, xs, self.pw, false);
            let ol = self.sq1(SQ_SLEN, sv, self.pw, false);
            path.pc.push(self.tm.cmp(T_EQ, sl, ol));
            self.write_place(b, cm, &mut path.state, dest, xs, false);
            return true;
        }
        if k == VK_RANGE || k == VK_RANGE_MUT {
            if dest == ir::IR_NONE {
                return true;
            }
            // A view of elements `lo` to `hi - 1` (`hi` included with `inclusive`), in this memory epoch.
            // A `[]mut` one may write them: the container is memory from here on, as for `as_mut_slice`.
            let dty = b.places.at(dest as usize).ty;
            let xs = self.fresh(cm, dty);
            let (n, view) = self.recv_cont(b, path, t);
            let r = self.operand(b, cm, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
            let (lo, hi0, inc) = self.range_parts(r);
            if n != NONE && lo != NONE && (self.tm.is_false(inc) || self.tm.is_true(inc)) {
                let hi = if self.tm.is_true(inc) {
                    let one = self.tm.int(Num::<B>::one(), W_INT, true);
                    self.tm.arith(T_ADD, hi0, one, W_INT, true)
                } else {
                    hi0
                };
                let sl = self.sq1(SQ_SLEN, xs, self.pw, false);
                let d = self.tm.arith(T_SUB, hi, lo, W_INT, true);
                path.pc.push(self.tm.cmp(T_EQ, sl, d));
                let mut ys = Vector::<u32>::new();
                ys.push(view);
                ys.push(self.sq_index(lo));
                ys.push(self.sq_index(hi));
                let sub = self.seq_make(SQ_SUB, &ys);
                let ep = self.slice_ep(cm, dty, &path.state);
                self.sdef.insert(xs as u64 << 32 | ep as u64, sub);
            }
            self.write_place(b, cm, &mut path.state, dest, xs, false);
            if k == VK_RANGE_MUT {
                let tg = self.recv_target(b, cm, &mut path.state, t);
                if tg != NONE {
                    self.escape(tg);
                }
            }
            return true;
        }
        if k == VK_AS_SLICE {
            if dest == ir::IR_NONE {
                return true;
            }
            // A view of the container's elements: its length and, in this memory epoch, its elements, the
            // receiver a place or a reference (`&v` converts to the view). A `[]mut` one may write them:
            // the container is memory from here on (`escape`).
            let tg = self.recv_target(b, cm, &mut path.state, t);
            let cv = self.recv_value(b, cm, &mut path.state, t, false);
            let mut rty = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
            if self.ast_of(cm).type_at(rty).kind == TypeKind::TYPE_REFERENCE {
                rty = self.ast_of(cm).type_at(rty).as_data.elem;
            }
            let (rdm, rdd) = self.decl_of(cm, rty);
            if rdd != NODE_NONE && rdm == self.vecl.mid && rdd == self.vecl.node {
                self.vec_fields(cv);
            }
            let ov = self.view_v(cv);
            let xs = self.fresh(cm, b.places.at(dest as usize).ty);
            let ep = self.slice_ep(cm, b.places.at(dest as usize).ty, &path.state);
            self.sdef.insert(xs as u64 << 32 | ep as u64, ov);
            let sl = self.sq1(SQ_SLEN, xs, self.pw, false);
            let ol = self.seq_len(ov);
            path.pc.push(self.tm.cmp(T_EQ, sl, ol));
            self.write_place(b, cm, &mut path.state, dest, xs, false);
            let (dm, dd) = self.decl_of(cm, b.places.at(dest as usize).ty);
            if tg != NONE && dd != NODE_NONE && dm == self.smut.mid && dd == self.smut.node {
                self.escape_as(tg, xs);
            }
            return true;
        }
        let rr = self.recv_ref(b, cm, &mut path.state, t);
        if rr == NONE {
            return false;
        }
        let old = self.ref_get(&path.state, rr);
        if old == NONE {
            return false;
        }
        if k == VK_INDEX_MUT {
            let i = self.operand(b, cm, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
            let i2 = self.sq_index(i);
            let r = self.sq2(SQ_EREF, rr, i2, W_OTHER, false);
            if dest != ir::IR_NONE {
                self.write_place(b, cm, &mut path.state, dest, r, false);
            }
            return true;
        }
        return false;
    }

    // ---- the body ---------------------------------------------------------------------------------

    // Whether body `b` has an obligation: a contract check of its own, a call of a function with a
    // `requires` clause, or such a function used as a value (reported here).
    // Whether operand `oi` of body `b` is an argument of a call whose callee's clauses state its
    // precondition (`pre_of` or `pre_any` of that parameter): the handoff proves it at the call.
    fn handoff_arg(self: &Self, b: &ir::CoreBody, oi: u32) bool {
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE {
                continue;
            }
            for j in 0..t.args_len {
                if b.oper_pool[(t.args_start + j) as usize] != oi {
                    continue;
                }
                let cbp = self.contract_body(self.contract_of(t.callee));
                if cbp == null {
                    return false;
                }
                let cb = unsafe &*cbp;
                for k in 0..cb.blocks.len() {
                    let u = cb.blocks.at(k).term;
                    if u.kind != ir::TM_CALL || u.args_len == 0 || !(self.is_pre(u.callee, 0) || self.is_pre(
                        u.callee,
                        1,
                    )) {
                        continue;
                    }
                    let a0 = *cb.operands.at(cb.oper_pool[u.args_start as usize] as usize);
                    if a0.kind != ir::OP_CONST && cb.places.at(a0.data as usize).base == cb.returns + j {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn needs_proof(self: &mut Self, b: &ir::CoreBody) bool {
        let mut need = b.contracts.len() != 0 || self.inv_body(b);
        // A body that reaches a counter field, or a member its guard reads (`count_step`).
        for pi in 0..b.places.len() {
            if need {
                break;
            }
            let pl = b.places.at(pi);
            let mut c = false;
            for d in 1..3u32 {
                if pl.proj_len >= d {
                    let pj = *b.projections.at((pl.proj_start + pl.proj_len - d) as usize);
                    c = c || pj.kind == ir::PJ_DEREF && self.counted(b.module, pj.ty);
                }
            }
            need = c && (self.counter_place(b, b.module, pl, false).0 != TYPE_NONE || self.counter_place(
                b,
                b.module,
                pl,
                true,
            ).0 != TYPE_NONE || self.guard_place(b, b.module, pl));
        }
        // A body that reads or writes a static with an invariant (its own or its type's).
        for l in 0..b.locals.len() {
            need = need || self.static_inv_fn(b, l as u32) != NODE_NONE || self.static_tinv(b, l as u32);
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && self.has_clause(self.contract_of(t.callee), CT_REQUIRES) {
                need = true;
            }
        }
        // A float's unchecked conversion: its precondition, as a call's `requires`.
        need = need || b.has_unchecked;
        for oi in 0..b.operands.len() {
            let op = *b.operands.at(oi);
            if op.kind == ir::OP_CONST {
                let c = *b.constants.at(op.data as usize);
                if c.kind == ir::CK_ITEM && self.has_clause(self.contract_of(c.item), CT_REQUIRES) && !self.handoff_arg(
                    b,
                    oi as u32,
                ) {
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

    // Whether the walk of body `b` may give facts for the build (step 6): it holds a bounds check, and a
    // fact the checks can use (a contract, a callee's contract, a value of a pattern type); its function
    // is called only from code the build proves (not `@export`: C passes any value).
    fn facts_wanted(self: &mut Self, b: &ir::CoreBody) bool {
        let mut any = false;
        for r in 0..b.rvalues.len() {
            let rv = b.rvalues.at(r);
            any = any || rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_BOUNDS_GROUP);
        }
        if !any || b.owner.node == NODE_NONE || (b.owner.node & NODE_BODY) != 0 {
            return false;
        }
        let a = self.ast_of(b.owner.module);
        if a.at_const(b.owner.node).kind == NodeKind::NODE_FUNCTION && a.attr_of(b.owner.node, AttrKind::ATTR_EXPORT) != null {
            return false;
        }
        if b.contracts.len() != 0 {
            return true;
        }
        for l in 0..b.locals.len() {
            let t = b.locals.at(l).ty;
            if t != TYPE_NONE && self.ast_of(b.module).type_at(t).has_pat() {
                return true;
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            let c = self.contract_of(t.callee);
            if t.kind == ir::TM_CALL && (self.has_clause(c, CT_ENSURES) || self.has_clause(c, CT_REQUIRES)) {
                return true;
            }
        }
        return false;
    }

    // Whether body `b` of module `m` casts a value that is no pointer to a pointer.
    // The locals that hold a reference to a member of a local or of a parameter's target, made once
    // outside every loop, and used only through it to read or write a member (`lazy`): the walk follows
    // each such write to the target, which escapes only where the reference is passed on, and no
    // iteration writes the target unseen.
    fn scan_lazy(self: &mut Self, b: &ir::CoreBody) {
        let nl = b.locals.len();
        let mut inloop = Vector::<bool>::new();
        inloop.resize_default(b.blocks.len());
        for h in 0..b.blocks.len() {
            if self.fx.is_header(h as u32) {
                self.fx.loop_scan(h as u32);
                for j in 0..self.fx.lblocks.len() {
                    inloop.set(self.fx.lblocks[j] as usize, true);
                }
            }
        }
        // Each local's definitions: 1 for a member reference outside every loop, 2 for another.
        let mut defs = Vector::<u32>::new();
        defs.resize_default(nl);
        for bi in 0..b.blocks.len() {
            let bb = *b.blocks.at(bi);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN || b.places.at(st.place as usize).proj_len != 0 {
                    continue;
                }
                let d = b.places.at(st.place as usize).base as usize;
                let rv = *b.rvalues.at(st.rvalue as usize);
                let one = rv.kind == ir::RV_REF && !inloop[bi] && b.places.at(rv.a as usize).proj_len != 0;
                defs.set(d, defs[d] + pick(one, 1u32, 2u32));
            }
            let t = bb.term;
            if t.kind == ir::TM_CALL {
                for j in t.dests_start..t.dests_start + t.dests_len {
                    let d = b.places.at(b.dest_pool[j as usize] as usize).base as usize;
                    defs.set(d, defs[d] + 2);
                }
                // A method call through the reference lends it on.
                for j in 0..t.args_len {
                    let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                    if op.kind != ir::OP_CONST && self.autoref(b, b.module, &t, j) {
                        let d = b.places.at(op.data as usize).base as usize;
                        defs.set(d, defs[d] + 2);
                    }
                }
            }
        }
        self.lazy.clear();
        for l in 0..nl {
            self.lazy.push(defs[l] == 1);
        }
        // A local read as a value (copied, moved, passed) or borrowed, itself or through it, is not.
        for j in 0..b.operands.len() {
            let o = *b.operands.at(j);
            if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                let p = *b.places.at(o.data as usize);
                if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
                    self.lazy.set(p.base as usize, false);
                }
            }
        }
        for r in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(r);
            if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE {
                let src = b.places.at(rv.a as usize).base as usize;
                self.lazy.set(src, false);
            }
        }
    }

    fn has_ptr_cast(self: &Self, m: ModuleId, b: &ir::CoreBody) bool {
        let a = self.ast_of(m);
        for r in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(r);
            if rv.kind == ir::RV_CAST && rv.target != TYPE_NONE && a.type_at(rv.target).kind == TypeKind::TYPE_POINTER {
                // A pointer made from another pointer reaches only what that one did.
                let st = b.operands.at(rv.a as usize).ty;
                if st == TYPE_NONE || a.type_at(st).kind != TypeKind::TYPE_POINTER {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether argument `j` of call `t` (in body `cb` of module `cm`) is a place the call borrows
    // implicitly and may change: a parameter of reference or pointer type takes a value of another
    // type, unless a shared reference takes a frozen value. A call whose callee the walk cannot see
    // borrows every argument that is not a reference or a pointer.
    // Argument `j` of call `t` of body `cb` with value `x`: a reference to `x` when the callee's parameter
    // is a reference and the argument is the place it borrows (an implicit borrow of a frozen value).
    fn implicit_ref(self: &mut Self, cb: &ir::CoreBody, t: &ir::Terminator, j: u32, x: u32) u32 {
        let op = *cb.operands.at(cb.oper_pool[(t.args_start + j) as usize] as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return x;
        }
        let ok = self.ast_of(cb.module).type_at(op.ty).kind;
        let xo = self.tm.at(x).op;
        if ok == TypeKind::TYPE_REFERENCE || ok == TypeKind::TYPE_POINTER || xo == T_REF || xo == T_MREF || xo == T_PREF {
            return x;
        }
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return x;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return x;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return x;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        if pt == TYPE_NONE || a.type_at(pt).kind != TypeKind::TYPE_REFERENCE {
            return x;
        }
        return self.tm.unary(T_REF, x, W_OTHER, false);
    }

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
        // A parameter of a type parameter takes the value (an argument of a reference type is one).
        return py.kind == TypeKind::TYPE_REFERENCE || py.kind == TypeKind::TYPE_POINTER;
    }

    // The locals the walk models: every one but a static's reference. A local a pointer, a mutable
    // reference, a slice or a closure may reach (`is_mem`; a shared reference too, unless the local's
    // value is frozen or a container and no reference becomes a pointer; not a `&mut` lent to one
    // call) also changes at each memory event.
    fn scan_tracked(self: &mut Self, b: &ir::CoreBody) {
        let nl = b.locals.len();
        self.pref_tg.clear();
        self.pref_tgty.clear();
        self.pref_m.clear();
        self.pref_at.clear();
        self.pref_n.clear();
        self.pref_key.clear();
        self.pref_ty.clear();
        self.pref_km.clear();
        self.pref_by.clear();
        self.tracked.clear();
        self.is_mem.clear();
        self.mem_list.clear();
        for l in 0..nl {
            self.tracked.push(b.locals.at(l).storage != ir::LS_STATIC_REF);
            self.is_mem.push(false);
        }
        self.ptr_cast = self.has_ptr_cast(b.module, b);
        self.scan_lazy(b);
        // The temporaries lent to one call (`scoped`): read once, by a call whose results and other
        // arguments are values that hold no reference.
        let mut uses = Vector::<u32>::with_capacity(nl);
        uses.resize_default(nl);
        for j in 0..b.operands.len() {
            let o = *b.operands.at(j);
            if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
                let l = b.places.at(o.data as usize).base as usize;
                uses.set(l, uses[l] + 1);
            }
        }
        self.scoped.clear();
        self.scoped.resize_default(nl);
        self.scoped_in.clear();
        // A temporary's struct literal, and a `&mut` temporary's whole local: a `&mut` a literal holds.
        let mut lit = Map::<u32, u32>::new();
        let mut whole = Map::<u32, u32>::new();
        for si in 0..b.statements.len() {
            let st = *b.statements.at(si);
            if st.kind != ir::ST_ASSIGN || b.places.at(st.place as usize).proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            let d = b.places.at(st.place as usize).base;
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_STRUCT {
                lit.insert(d, st.rvalue);
            } else if rv.kind == ir::RV_REF && rv.b != 0 && b.places.at(rv.a as usize).proj_len == 0 {
                whole.insert(d, b.places.at(rv.a as usize).base);
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || self.is_ghost(t.callee) {
                continue;
            }
            let mut ok = true;
            for j in t.dests_start..t.dests_start + t.dests_len {
                ok = ok && self.frozen(b.module, b.places.at(b.dest_pool[j as usize] as usize).ty);
            }
            for j in 0..t.args_len {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                let shared = self.ast_of(b.module).type_at(op.ty).kind == TypeKind::TYPE_REFERENCE && self.ast_of(
                    b.module,
                ).type_at(op.ty).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
                let tmp = op.kind != ir::OP_CONST && b.places.at(op.data as usize).proj_len == 0 && b.locals.at(
                    b.places.at(op.data as usize).base as usize,
                ).storage == ir::LS_TEMP;
                ok = ok && (op.kind == ir::OP_CONST || self.frozen(b.module, op.ty) || shared || tmp && !self.autoref(
                    b,
                    b.module,
                    &t,
                    j,
                ));
            }
            if !ok {
                continue;
            }
            // One `&mut` temporary per call: two could be the same local's. A struct literal's temporary
            // read once holds its `&mut` temporaries (`E { m: &mut m }`).
            let mut n: u32 = 0;
            let mut last = NONE;
            let mut holder = NONE;
            for j in 0..t.args_len {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                if op.kind == ir::OP_CONST || self.frozen(b.module, op.ty) {
                    continue;
                }
                let base = b.places.at(op.data as usize).base;
                let y = self.ast_of(b.module).type_at(op.ty);
                if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 && b.places.at(
                    op.data as usize,
                ).proj_len == 0 {
                    n += 1;
                    last = base;
                    holder = NONE;
                } else if b.places.at(op.data as usize).proj_len == 0 && uses[base as usize] == 1 && lit.contains_key(
                    &base,
                ) {
                    let rv = *b.rvalues.at((*lit.get(&base).unwrap()) as usize);
                    for q in rv.a..rv.a + rv.b {
                        let o = b.oper_pool[q as usize];
                        if o == ir::IR_NONE || b.operands.at(o as usize).kind == ir::OP_CONST || b.places.at(
                            b.operands.at(o as usize).data as usize,
                        ).proj_len != 0 {
                            continue;
                        }
                        let fy = self.ast_of(b.module).type_at(b.operands.at(o as usize).ty);
                        if fy.kind == TypeKind::TYPE_REFERENCE && fy.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                            n += 1;
                            last = b.places.at(b.operands.at(o as usize).data as usize).base;
                            holder = base;
                        }
                    }
                }
            }
            if n == 1 && uses[last as usize] == 1 && b.locals.at(last as usize).storage == ir::LS_TEMP && (holder == NONE || whole.contains_key(
                &last,
            )) {
                self.scoped.set(last as usize, true);
                if holder != NONE {
                    self.scoped_in.insert(holder, *whole.get(&last).unwrap());
                }
            }
        }
        // The temporaries that hold a shared borrow of a struct and are read once, by a call that takes a
        // shared reference there and whose results hold no reference (`cell_read`).
        self.cell_tmp.clear();
        self.cell_tmp.resize_default(nl);
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || self.is_ghost(t.callee) || !self.ref_free_results(b, &t) {
                continue;
            }
            for j in 0..t.args_len {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                if op.kind == ir::OP_CONST || b.places.at(op.data as usize).proj_len != 0 {
                    continue;
                }
                let l = b.places.at(op.data as usize).base as usize;
                if uses[l] == 1 && b.locals.at(l).storage == ir::LS_TEMP && self.shared_param(&t, j) && self.plain_struct_ref(
                    b.module,
                    op.ty,
                ) {
                    self.cell_tmp.set(l, true);
                }
            }
        }
        for sid in 0..b.statements.len() {
            let s = *b.statements.at(sid);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE {
                let p = *b.places.at(rv.a as usize);
                // A `&mut` of a whole local or of a member into a temporary lent to one call (`scoped`): the
                // call's effect on it is `lent`'s, and no other memory event reaches it.
                let dp = *b.places.at(s.place as usize);
                let lent = rv.kind == ir::RV_REF && (rv.b != 0 && member_place(b, &p) && dp.proj_len == 0 && self.scoped[dp.base as usize] || rv.b == 0 && dp.proj_len == 0 && self.cell_tmp[dp.base as usize]) && !self.ptr_cast;
                let lty = b.locals.at(p.base as usize).ty;
                if !lent && !self.owned_elem(b, &p) && (rv.kind != ir::RV_REF || rv.b != 0 || self.ptr_cast || !self.frozen(
                    b.module,
                    lty,
                ) && !self.container(b.module, lty)) {
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
        // A borrow that only a container's view call reads, its block's last statement: the call
        // escapes the container (`sq_effect`), so far as the view lets it change.
        self.vborrow.clear();
        for bi in 0..b.blocks.len() {
            let bk = *b.blocks.at(bi);
            if bk.term.kind != ir::TM_CALL || bk.term.args_len != 1 || bk.stmt_len == 0 || self.sq_kind(
                b,
                b.module,
                &bk.term,
            ) != VK_AS_SLICE {
                continue;
            }
            let sid = bk.stmt_start + bk.stmt_len - 1;
            let st = *b.statements.at(sid as usize);
            let op = *b.operands.at(b.oper_pool[bk.term.args_start as usize] as usize);
            if st.kind == ir::ST_ASSIGN && op.kind != ir::OP_CONST && b.places.at(op.data as usize).proj_len == 0 && st.place == op.data && b.rvalues.at(
                st.rvalue as usize,
            ).kind == ir::RV_REF {
                self.vborrow.insert(sid, true);
            }
        }
        // A call's implicit borrow of a place reaches its local, unless the borrow ends with the call
        // (`borrow_ends`) or only reads (`shared_read`); a modeled method of a container changes only
        // what it models (`sq_effect`).
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || self.sq_kind(b, b.module, &t) != 0 || self.borrow_ends(b, &t) {
                continue;
            }
            for j in 0..t.args_len {
                if self.autoref(b, b.module, &t, j) && !self.shared_read(b, &t, j) && !self.cell_read(b, &t, j) {
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
        if s.kind == CT_PATTERN {
            return unsafe (*self.b).blocks.at(s.check as usize).term.span;
        }
        let a = self.ast_of(cm);
        return a.at_const(a.contracts.at(s.clause as usize).expr).span;
    }

    // The source site `s` of body `b` covers, which its own locals lie in: the clause's condition; an
    // `assert .. by` from `assert` to its block's end; a lemma call statement.
    fn site_extent(self: &Self, b: &ir::CoreBody, s: ir::ContractSite) tok::Span {
        if s.kind == CT_GHOST {
            return b.blocks.at(s.check as usize).term.span;
        }
        let sp = self.site_span(b.module, s);
        if s.kind != CT_ASSERT {
            return sp;
        }
        let a = self.ast_of(b.module);
        let c = *a.contracts.at(s.clause as usize);
        return tok::Span { start: c.at, end: a.at_const(c.owner).span.end.max(sp.end) };
    }

    // A new term table, and no fact over the old one's terms.
    fn clear_terms(self: &mut Self) {
        self.tm.clear();
        self.sv.forget();
        self.proved.clear();
        self.held_alt.clear();
        self.derived.clear();
        self.defs.clear();
        self.def_of.clear();
        self.res_of.clear();
        self.defined.clear();
        self.qclo.clear();
        self.qof.clear();
        self.qinst.clear();
        self.qdef.clear();
        self.seld.clear();
        self.cohd.clear();
        self.ptrd.clear();
        self.seqeqs.clear();
        self.seqwit.clear();
        self.inv_terms.clear();
        self.vdef.clear();
        self.sdef.clear();
        self.alias.clear();
        self.alias_pool.clear();
        self.spec_leaves.clear();
        self.spec_pool.clear();
        self.seqw.clear();
        self.exact.clear();
        self.qvalue.clear();
        self.unfolding.clear();
        self.eta_src.clear();
        self.capd.clear();
        self.mi_seen.clear();
        self.mi_fwd.clear();
        self.st_inv.clear();
        self.st_decl.clear();
        self.st_err.clear();
        self.st_list.clear();
        self.held_p.clear();
        self.held_k.clear();
        self.sh_p.clear();
        self.sh_kn.clear();
        self.fn_items.clear();
        self.fn_defs.clear();
        self.fn_binds.clear();
        self.ov_take_sh.clear();
        self.sh_seen.clear();
        self.sh_tk.clear();
        self.ov_had.clear();
        self.sh_gv.clear();
        self.nsh_wait.clear();
        self.ov_defd.clear();
        self.ov_kind.clear();
        self.ov_prev.clear();
        self.ov_pst.clear();
        self.ov_psn.clear();
        self.ov_ps.clear();
        self.ov_seen.clear();
        self.ov_col = NONE;
        self.src_tab.clear();
        self.ov_terms.clear();
        self.ov_fr.clear();

        self.ptr_apart.clear();
        self.held_by_ptr.clear();
        self.claims_of.clear();
        self.ov_src = 0;
        // Version 0: the body's entry.
        self.ov = self.ov_new(OV_BASE, NONE);
        self.specd.clear();
        self.recd.clear();
        self.pvars.clear();
        self.alloc_of.clear();
        self.alloc_rec.clear();
        self.exact_body = false;
    }

    // Whether `d` is a spec function or a lemma.
    // Whether `d` is a lemma.
    fn is_lemma(self: &Self, d: DefId) bool {
        if !self.is_ghost(d) {
            return false;
        }
        return self.ast_of(d.module).ext(d.node).function.is_lemma();
    }

    fn is_ghost(self: &Self, d: DefId) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module as usize >= self.pkg().modules.len() || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        return a.at_const(d.node).kind == NodeKind::NODE_FUNCTION && a.ext(d.node).function.is_ghost();
    }

    // Whether every call of `d` that its `requires` admits ends: a spec function or a lemma (each ends,
    // `fn_dec`), a `@prove_exhaustive` function (each run ended). Ghost code assumes the `ensures` of
    // such a callee only: another one may never return, and ghost code never runs to see it.
    fn total(self: &Self, d: DefId) bool {
        return self.is_ghost(d) || self.exhaustive(d);
    }

    // Whether every call of function `d` ends: its kept body has no loop and calls no function that may
    // not end (itself included, `depth` calls deep); a call that panics ends, as does an integer or float
    // method the walk models (`wide_kind`, `soft_kind`). Ghost code assumes the `ensures` of such a callee
    // (`v.len()` in an `invariant`).
    fn ends(self: &mut Self, d: DefId, depth: u32) bool {
        let key = d.module as u64 << 32 | d.node as u64;
        let pre = self.ends_memo.contains_key(&key);
        let mk = self.rd.get_mut().len();
        let r = self.ends_run(d, depth);
        self.memo_reads(1u64 << 63 | key, mk, !pre && self.ends_memo.contains_key(&key));
        return r;
    }

    fn ends_run(self: &mut Self, d: DefId, depth: u32) bool {
        if self.total(d) || self.panics(d) || self.wide_kind(d) != 0 || self.soft_kind(d) != 0 {
            return true;
        }
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || depth > 8 {
            return false;
        }
        let key = d.module as u64 << 32 | d.node as u64;
        if let Some(v) = self.ends_memo.get(&key) {
            return *v;
        }
        // A call back to a function being asked is a recursion: it may not end.
        self.ends_memo.insert(key, false);
        let cbp = self.kept(d);
        if cbp == null {
            return false;
        }
        let cb = unsafe &*cbp;
        if has_cycle(cb) {
            return false;
        }
        for blk in 0..cb.blocks.len() {
            let t = cb.blocks.at(blk).term;
            if t.kind == ir::TM_CALL && !self.ends(t.callee, depth + 1) {
                return false;
            }
        }
        self.ends_memo.insert(key, true);
        return true;
    }

    // Fact `f` of a check on the path `pc`: in ghost code an obligation first (`key` at `sp`).
    // Bounds check `rid` of the body under proof (`own`), reached on a path with conditions `pc`: a fact
    // for the build while `f` (the check's condition) holds on every path that reaches it.
    fn note_check(self: &mut Self, own: bool, rid: u32, pc: &Vector<u32>, f: u32) {
        if !own || !self.facts_on || self.in_ghost || self.chain_depth != 0 || self.chk_dead.contains_key(&rid) {
            return;
        }
        if self.holds_within(pc, f, FACT_STEPS) {
            self.chk_ok.insert(rid, true);
            return;
        }
        let _ = self.chk_ok.remove(&rid);
        self.chk_dead.insert(rid, true);
    }

    fn check_fact(self: &mut Self, pc: &mut Vector<u32>, f: u32, key: u64, sp: tok::Span) {
        if self.in_ghost {
            self.oblige(
                pc,
                f,
                OB_GHOST << 56 | 1 << 55 | key & 0x7FFFFFFFFFFFFFu64,
                sp,
                format("cannot prove that this check of ghost code holds"),
                String::from_str("ghost code never runs: each of its checks is an obligation"),
            );
        } else if self.no_panic && self.chain_depth == 0 {
            self.oblige(
                pc,
                f,
                OB_PANIC << 56 | key & 0xFFFFFFFFFFFFFFu64,
                sp,
                format("cannot prove that this check holds"),
                String::from_str(NO_PANIC_NOTE),
            );
        }
        pc.push(f);
    }

    // The return a path from block `blk` reaches through jumps, for a report's note.
    const fn return_span(self: &Self, b: &ir::CoreBody, blk: u32) tok::Span {
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
        let spec = self.ghost_fn && self.ast_of(b.module).ext(b.owner.node).function.is_spec();
        for j in 0..self.fx.rpo.len() {
            let h = self.fx.rpo[j];
            if !self.fx.is_header(h) || !self.fn_dec && !self.gblk[h as usize] {
                continue;
            }
            // A quantifier's loop never runs in a proof (`quantifier`) and runs over a bounded range.
            let mut quant = false;
            for q in 0..b.quants.len() {
                quant = quant || b.blocks.at(b.quants[q].entry as usize).term.t0 == h;
            }
            if quant {
                continue;
            }
            // A spec function's value is its body's at its returns: it has no loop (`define`).
            if spec {
                self.report(
                    0xFD00000000000000u64 | h as u64,
                    dc::CANNOT_PROVE_CONTRACT,
                    b.blocks.at(h as usize).term.span,
                    format("a spec function cannot loop: state it by recursion"),
                    String::new(),
                );
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
                    format(
                        "this loop needs a 'decreases' measure: {}",
                        if self.ghost_fn || self.gblk[h as usize] {
                            "ghost code must end"
                        } else {
                            "its function has one"
                        },
                    ),
                    String::from_str("a loop over a range with an end or over a collection needs none"),
                );
            }
        }
    }

    // Lower the contracts of every interface method that has contracts and no body.
    fn lower_shells(self: &mut Self, sh: &mut Shared, mods: &Vector<bool>) {
        let p = unsafe &*self.p;
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast || !mods[m] {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            for j in 0..a.contracts.len() {
                // A loop's or a block's record (a body node, which a language server may have released).
                let o = a.contracts.at(j).owner;
                if (o & NODE_BODY) != 0 || a.at_const(o).kind != NodeKind::NODE_FUNCTION || a.ext(o).function.body != NODE_NONE {
                    continue;
                }
                let key = skey_mix(0, m as u64 << 32 | o as u64);
                if sh.shell_ix.contains_key(&key) {
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
                                "it calls a function that is not a 'const fn', a spec function or a lemma, drops a value or writes a variable",
                            ),
                        );
                    }
                }
                sh.shell_ix.insert(key, sh.shells.len() as u32);
                sh.shells.push(b);
            }
        }
        self.failed.clear();
    }

    const fn shared(self: &Self) &Shared {
        return unsafe &*self.sh;
    }

    // Both walks of kept body `k`: its own obligations, then for a conformance's method the
    // refinement of its interface's contracts.
    // Prove kept body `k`; false, its reports and facts dropped, when a proof failed where a simplex ran
    // out of the numbers' bits: the wide numbers then prove it.
    fn prove_fits(self: &mut Self, k: usize) bool {
        let m = (unsafe (&*self.keep).kept.at(k).body.module) as usize;
        let held = replace(self.errs.index_mut(m), diag::Errors::new());
        let nf = self.facts.len();
        self.sv.clear_overflow();
        self.tm.big_seen = false;
        self.prove_kept(k);
        let fits = self.errs.at(m).errors.len() == 0 || !self.sv.overflowed() && !self.tm.big_seen;
        let mut e = replace(self.errs.index_mut(m), held);
        if fits {
            self.errs.index_mut(m).append(&mut e);
        } else {
            self.facts.truncate(nf);
        }
        return fits;
    }

    fn prove_kept(self: &mut Self, k: usize) {
        let kb = unsafe (&*self.keep).kept.at(k);
        self.me = k as u32;
        // A conformance's method runs where a call through the interface proved only the
        // interface's contracts. One with no contract of its own has the interface's (a direct call
        // proves them too, `call`): its one walk starts from them and has every obligation.
        let im = self.iface_member(kb.body.owner);
        let inherits = im.node != NODE_NONE && !self.contracted(kb.body.owner) && self.contracted(im);
        // A `@prove_exhaustive` function's own obligations are its runs' (`exhaustive_job`).
        if !self.exhaustive(kb.body.owner) && !inherits {
            self.prove_body(&kb.body, false);
        }
        if im.node != NODE_NONE && (self.has_clause(im, CT_REQUIRES) || self.has_clause(im, CT_ENSURES) || self.has_clause(
            kb.body.owner,
            CT_REQUIRES,
        ) || self.has_clause(kb.body.owner, CT_PANICS)) {
            self.refine = self.contract_body(im);
            // The interface's clauses read `Self` as the conformance's type: the parameters bind it.
            self.refine_subst.clear();
            if self.refine != null {
                let ib = unsafe &*self.refine;
                for k in 0..ib.args {
                    if k < kb.body.args {
                        self.unify(
                            ib.module,
                            ib.locals.at((ib.returns + k) as usize).ty,
                            kb.body.module,
                            kb.body.locals.at((kb.body.returns + k) as usize).ty,
                            &mut self.refine_subst,
                            0,
                        );
                    }
                }
            }
            self.refine_all = inherits && !self.exhaustive(kb.body.owner);
            self.prove_body(&kb.body, true);
            self.refine_all = false;
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
    fn exhaustive_job(self: &mut Self, k: usize) Option<PJob<B>> {
        let bp = (&unsafe (&*self.keep).kept.at(k).body) as *const ir::CoreBody;
        let b = unsafe &*bp;
        self.m = b.module;
        self.b = bp;
        self.me = k as u32;
        self.refining = false;
        self.clear_terms();
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
        let mut dims = Vector::<PDim<B>>::with_capacity(b.args as usize);
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
        return Some(PJob::<B> { k: k, dims: dims, inputs: inputs, first: NO_INPUT });
    }

    // Parameter `l` of body `b` as an input dimension (`PDim`), None when it has no small set of
    // values; an integer's range is narrowed to the bounds the conditions `pc` imply of its unknown in
    // `st`.
    fn pdim(self: &mut Self, b: &ir::CoreBody, l: u32, st: &Vector<u32>, pc: &Vector<u32>) Option<PDim<B>> {
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
        let mut d = PDim::<B> {
            l: l,
            kind: PD_INT,
            by_ref: by_ref,
            lo: Num::<B>::zero(),
            n: 0,
            count: Num::<B>::zero(),
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
            d.count = u64_val::<B>(d.n);
            return Some(d);
        }
        let (w, sg) = self.ty_of(b.module, ty);
        if w == W_BOOL {
            d.kind = PD_BOOL;
            d.n = 2;
            d.count = u64_val::<B>(2);
            return Some(d);
        }
        // A wide integer (`UInt<N>`, `Int<N>`) is a struct to the evaluator: no domain.
        if y.kind != TypeKind::TYPE_BUILTIN {
            return None;
        }
        if w < 8 || exact_w(w) {
            return None;
        }
        d.w = w;
        d.sg = sg;
        let (lo0, hi0) = Terms::<B>::range(w, sg);
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
                if self.holds(pc, goal) {
                    hi = mid;
                } else {
                    a = mid + Num::<B>::one();
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
                if self.holds(pc, goal) {
                    lo = mid;
                } else {
                    z = mid - Num::<B>::one();
                }
            }
        }
        d.lo = lo;
        d.count = if hi < lo {
            Num::<B>::zero()
        } else {
            hi - lo + Num::<B>::one()
        };
        d.n = if wide::<B>(iri::I64_MAX) < d.count {
            NO_INPUT
        } else {
            d.count.to_i64() as u64
        };
        return Some(d);
    }

    // Report the first failed run of `job`, from part `r`, which holds the least failed input.
    fn report_part(self: &mut Self, job: &PJob<B>, r: &PRes) {
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
    // their results, then their parameters), its result `r`: parameter by parameter.
    fn shell_frame(self: &mut Self, cb: &ir::CoreBody, b: &ir::CoreBody, state: &Vector<u32>, r: u32) Vector<u32> {
        let mut frame = Vector::<u32>::new();
        fill(&mut frame, cb.locals.len() + 1);
        frame.set(cb.locals.len(), state[state.len() - 1]);
        // Parameter `k` of each: the result slots before them may differ (`void` stated or not).
        for k in 0..cb.args {
            if k < b.args {
                frame.set((cb.returns + k) as usize, state[(b.returns + k) as usize]);
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
            let outer = replace(&mut self.subst, self.refine_subst.clone());
            let (f, _v) = self.chain(ib, ib.module, s, &frame, &path.pc, true, none);
            self.subst = outer;
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

    // The exact walk is exponential in the branches in a row: past its first cap body `bp` is walked
    // once more with paths merged at joins, each block about once (`merge_paths`). A merge forgets: a
    // body with obligations the merged walk cannot prove is walked exactly with the whole budget, and a
    // walk for facts keeps none. Only the walk's own limits, its steps and its paths, start the merged
    // walk: a solver that spent the budget would spend it again. Each walk starts afresh: the facts a
    // walk makes once per term (`clear_terms`) are not in the next one's paths.
    fn prove_body(self: &mut Self, bp: *const ir::CoreBody, refining: bool) {
        let m = (unsafe (*bp).module) as usize;
        let held = replace(self.errs.index_mut(m), diag::Errors::new());
        let nf = self.facts.len();
        self.over = false;
        self.walk_body(bp, refining, 0);
        if self.over && (self.steps > self.walk_cap || self.work_n as usize >= PATHS_MAX) {
            self.errs.set(m, diag::Errors::new());
            self.merging = true;
            self.walk_body(bp, refining, MERGED_PER_BLOCK * (unsafe (*bp).blocks.len()) as u32);
            self.merging = false;
            if !self.facts_only && (self.over || self.errs.at(m).errors.len() != 0) {
                self.facts.truncate(nf);
                self.errs.set(m, diag::Errors::new());
                self.walk_body(bp, refining, u32::MAX);
            }
        }
        let mut e = replace(self.errs.index_mut(m), held);
        self.errs.index_mut(m).append(&mut e);
    }

    // One walk of body `bp` with a budget of `cap` walk steps (`spend`), or with 0 the exact walk's
    // first (FACTS_WALK or PROOF_WALK).
    fn walk_body(self: &mut Self, bp: *const ir::CoreBody, refining: bool, cap: u32) {
        let b = unsafe &*bp;
        self.m = b.module;
        self.owner = b.owner;
        self.refining = refining;
        // The obligations of the body itself: its own walk, or the one walk of a method that has the
        // interface's contracts (`refine_all`).
        let own = !refining || self.refine_all;
        self.ghost_fn = self.is_ghost(b.owner);
        let facts = own && !self.ghost_fn && self.facts_wanted(b);
        let needs = self.needs_proof(b) || refining || self.ghost_fn;
        if !needs && !facts {
            return;
        }
        self.facts_on = facts;
        self.facts_only = !needs;
        self.walk_cap = if cap != 0 {
            cap
        } else if needs {
            PROOF_WALK
        } else {
            FACTS_WALK
        };
        self.chk_ok.clear();
        self.chk_dead.clear();
        self.pan_cond = NONE;
        self.refine_pan = NONE;
        self.b = bp;
        self.clear_terms();
        self.own_alloc = self.alloc_conf_key(b.owner);
        for l in 0..b.locals.len() {
            let (w, _sg) = self.ty_of(b.module, b.locals.at(l).ty);
            self.exact_body = self.exact_body || exact_w(w);
        }
        self.sv.steps = 0;
        self.steps = 0;
        self.over = false;
        self.failed.clear();
        self.begin_sites(b, !own);
        // A conversion into a pattern type is no contract of the function: it proves no overflow. Nor is a
        // ghost statement (a lemma's call, a `ghost let`).
        let mut clauses = false;
        for j in 0..b.contracts.len() {
            clauses = clauses || b.contracts[j].kind != CT_PATTERN && b.contracts[j].kind != CT_GHOST;
        }
        self.ovf = if clauses || self.ghost_fn {
            OVF_PROVE
        } else {
            OVF_KEEP
        };
        self.no_panic = clauses && !self.ghost_fn;
        // Ghost code must end: a spec function or a lemma as a function with a measure does.
        self.fn_dec = self.has_fn_dec(b) || self.ghost_fn;
        if own {
            self.loops_end(b);
        }
        self.work_reset();
        // A slot per `&mut T` parameter (`slot_ty`), past the locals; the memory epoch last.
        self.slot_ty.clear();
        self.slot_of.clear();
        fill(&mut self.slot_of, b.locals.len());
        self.nlocals = b.locals.len() as u32;
        for l in b.returns..b.returns + b.args {
            let py = *self.ast_of(b.module).type_at(b.locals.at(l as usize).ty);
            // A pointer made from it reaches it as `leak` records (an escape, or an inline array alone).
            if py.kind == TypeKind::TYPE_REFERENCE && py.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                self.slot_of.set(l as usize, b.locals.len() as u32 + self.slot_ty.len() as u32);
                self.slot_ty.push(py.as_data.elem);
                self.tracked.push(true);
                self.is_mem.push(true);
                self.mem_list.push(self.slot_of[l as usize]);
            }
        }
        self.inv_scan(b);
        self.own_scan(b);
        self.ctr_scan(b);
        let mut st = Vector::<u32>::new();
        fill(&mut st, b.locals.len() + self.slot_ty.len() + 1);
        let ne = st.len() - 1;
        st.set(ne, self.tm.var(W_OTHER, false));
        self.vname.clear();
        self.sref.clear();
        for l in b.returns..b.returns + b.args {
            let sl = self.slot_of[l as usize];
            if sl != NONE {
                self.forget(b, b.module, &mut st, sl);
                st.set(
                    l as usize,
                    self.tm.make(Term::<B> { k: Num::<B>::zero(), a: sl, b: 0, op: T_MREF, w: W_OTHER, sg: false }),
                );
                continue;
            }
            self.forget(b, b.module, &mut st, l);
            self.vname.insert(st[l as usize], l);
            let py = *self.ast_of(b.module).type_at(b.locals.at(l as usize).ty);
            if py.kind == TypeKind::TYPE_REFERENCE && py.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                self.sref.push(st[l as usize]);
            }
        }
        // The refinement walk starts from the interface's `requires`.
        let mut pc0 = Vector::<u32>::new();
        self.inv_enter(b, &st, &mut pc0);
        if refining && self.refine != null {
            let ib = unsafe &*self.refine;
            let frame = self.shell_frame(ib, b, &st, NONE);
            let none = tok::Span { start: 0, end: 0 };
            self.mem = &st;
            let outer = replace(&mut self.subst, self.refine_subst.clone());
            for j in 0..ib.contracts.len() {
                if ib.contracts[j].kind == CT_REQUIRES {
                    let (f, _v) = self.chain(ib, ib.module, ib.contracts[j], &frame, &pc0, true, none);
                    pc0.push(f);
                } else if ib.contracts[j].kind == CT_PANICS {
                    let (f, _v) = self.chain(ib, ib.module, ib.contracts[j], &frame, &pc0, true, none);
                    self.refine_pan = if self.refine_pan == NONE {
                        f
                    } else {
                        self.tm.or(self.refine_pan, f)
                    };
                }
            }
            self.subst = outer;
            self.mem = null;
        }
        let first = Path {
            state: st,
            pc: pc0,
            esc: Vector::<u32>::new(),
            aesc: Vector::<u32>::new(),
            views: Vector::<u64>::new(),
            lm: Vector::<u64>::new(),
            pend: Vector::<u64>::new(),
            ov: 0,
            mi: Vector::<u32>::new(),
            fresh: Vector::<u32>::new(),
            wrote: Vector::<u32>::new(),
            ens: Vector::<u32>::new(),
            blk: b.entry,
            from: NONE,
            m0: NONE,
        };
        self.push_path(first);
        self.walk_paths(b, own);
    }

    // Walk the queued paths of body `b` (its own walk when `own`): at the end each check that held on
    // every path that reached it is a fact.
    fn walk_paths(self: &mut Self, b: &ir::CoreBody, own: bool) {
        for _k in 0..STEP_BUDGET {
            if self.over {
                return;
            }
            if self.work_n == 0 {
                // Every path ended: each check that held on every path that reached it is a fact.
                if self.facts_on && own {
                    let mut rs = Vector::<u32>::new();
                    for (r, _v) in self.chk_ok.iter() {
                        rs.push(*r);
                    }
                    rs.sort();
                    for j in 0..rs.len() {
                        self.facts.push(self.me as u64 << 32 | rs[j] as u64);
                    }
                }
                return;
            }
            if !self.spend() {
                self.budget_spent();
                return;
            }
            let path = self.pop_path();
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
        self.gblk.clear();
        self.gblk.resize_default(nb);
        let mut gbits = Vector::<u64>::new();
        gbits.resize_default((nb + 63) / 64);
        for j in 0..b.contracts.len() {
            let s = b.contracts[j];
            self.site_of_chain.set(s.chain as usize, j as u32);
            self.site_of_pred.set(s.pred as usize, j as u32);
            if ir::is_ghost_site(s.kind) {
                ir::site_mark(b, s, &mut gbits);
            }
            let sp = self.site_extent(b, s);
            if !refining && !self.pure_chain(b, s, sp) {
                self.report(
                    0xFE00000000000000u64 | j as u64,
                    dc::CONTRACT_NOT_PURE,
                    sp,
                    format(
                        "{} must only compute its condition",
                        pick(ir::is_ghost_site(s.kind), "ghost code", "a contract"),
                    ),
                    String::from_str(
                        "it calls a function that is not a 'const fn', a spec function or a lemma, drops a value or writes a variable",
                    ),
                );
            }
        }
        for x in 0..nb {
            self.gblk.set(x, ir::in_blocks(&gbits, x as u32));
        }
    }

    fn push_path(self: &mut Self, path: Path) {
        // The exact walk: a stack, depth first.
        if !self.merging {
            if self.work.len() >= PATHS_MAX {
                self.budget_spent();
                return;
            }
            self.work.push(path);
            self.work_n += 1;
            return;
        }
        let blk = path.blk;
        let mut at = NONE;
        if let Some(s) = self.work_at.get(&blk) {
            at = *s;
        }
        if at != NONE {
            let mut a = replace(self.work.index_mut(at as usize), Path::empty());
            let ok = self.merge_paths(&mut a, &path);
            self.work.set(at as usize, a);
            if ok {
                return;
            }
        }
        if self.work_n as usize >= PATHS_MAX {
            self.budget_spent();
            return;
        }
        let slot = switch self.work_free.pop() {
            Some(x) => x,
            None => {
                self.work.push(Path::empty());
                (self.work.len() - 1) as u32
            },
        };
        self.work.set(slot as usize, path);
        let rpo = if blk as usize < self.fx.rpo_of.len() {
            self.fx.rpo_of[blk as usize]
        } else {
            0
        };
        let key = (u32::MAX - rpo) as u64 << 32 | (self.work_seq & 0xFFFFF) as u64 << 12 | slot as u64;
        self.work_q.push(key);
        self.work_seq = self.work_seq.wrapping_add(1);
        self.work_n += 1;
        self.work_at.insert(blk, slot);
    }

    // An empty walk queue.
    fn work_reset(self: &mut Self) {
        self.work.clear();
        self.work_q.clear();
        self.work_free.clear();
        self.work_at.clear();
        self.work_n = 0;
        self.work_seq = 0;
    }

    // The next queued path (`work_q`); one is queued.
    fn pop_path(self: &mut Self) Path {
        if !self.merging {
            self.work_n -= 1;
            return self.work.pop().unwrap();
        }
        let key = self.work_q.pop().unwrap();
        let slot = (key & 0xFFFu64) as u32;
        let path = replace(self.work.index_mut(slot as usize), Path::empty());
        self.work_free.push(slot);
        self.work_n -= 1;
        if let Some(s) = self.work_at.get(&path.blk) {
            if *s == slot {
                let _ = self.work_at.remove(&path.blk);
            }
        }
        return path;
    }

    // Merge path `b` into path `a`, both at one block, for the walk that merges (`merging`): they must
    // agree on the loop measures, the function's measure and the ownership state (`ov`, `pend`, `mi`,
    // `fresh`, `ens`), and each local's two values must have one width. A local valued on one side only
    // gets none: the next read makes an unknown (`local_val`), which any value is. Each other local whose
    // values differ gets an unknown; the facts are the common prefix, the facts both rest lists hold, and
    // one disjunction, each side the rest of its facts with the unknowns equal to its values. The locals
    // and inline arrays references may reach and the views are the unions: a memory event forgets more.
    // False, `a` unchanged, where they do not agree.
    fn merge_paths(self: &mut Self, a: &mut Path, b: &Path) bool {
        if a.m0 != b.m0 || a.state.len() != b.state.len() || a.lm.as_slice() != b.lm.as_slice() || a.ov != b.ov || a.pend.as_slice() != b.pend.as_slice() || a.mi.as_slice() != b.mi.as_slice() || a.fresh.as_slice() != b.fresh.as_slice() || a.ens.as_slice() != b.ens.as_slice() {
            return false;
        }
        let mut diff = Vector::<u32>::new();
        for i in 0..a.state.len() {
            let (x, y) = (a.state[i], b.state[i]);
            if x == y || x == NONE || y == NONE {
                continue;
            }
            let (tx, ty) = (self.tm.at(x), self.tm.at(y));
            if ty.w != tx.w || ty.sg != tx.sg {
                return false;
            }
            diff.push(i as u32);
        }
        for i in 0..a.state.len() {
            if b.state[i] == NONE {
                a.state.set(i, NONE);
            }
        }
        for j in 0..b.esc.len() {
            if !a.esc.contains(&b.esc[j]) {
                a.esc.push(b.esc[j]);
            }
        }
        for j in 0..b.aesc.len() {
            if !a.aesc.contains(&b.aesc[j]) {
                a.aesc.push(b.aesc[j]);
            }
        }
        for j in 0..b.views.len() {
            if !a.views.contains(&b.views[j]) {
                a.views.push(b.views[j]);
            }
        }
        let mut k: usize = 0;
        while k < a.pc.len() && k < b.pc.len() && a.pc[k] == b.pc[k] {
            k += 1;
        }
        let mut in_b = Set::<u32>::new();
        for j in k..b.pc.len() {
            in_b.insert(b.pc[j]);
        }
        let mut both = Set::<u32>::new();
        let mut kept = Vector::<u32>::new();
        let mut ca = self.tm.boolean(true);
        for j in k..a.pc.len() {
            let f = a.pc[j];
            if !in_b.contains(&f) {
                ca = self.tm.and(ca, f);
            } else if !both.contains(&f) {
                both.insert(f);
                kept.push(f);
            }
        }
        let mut cb = self.tm.boolean(true);
        for j in k..b.pc.len() {
            if !both.contains(&b.pc[j]) {
                cb = self.tm.and(cb, b.pc[j]);
            }
        }
        for q in 0..diff.len() {
            let i = diff[q] as usize;
            let t = self.tm.at(a.state[i]);
            let x = self.tm.var(t.w, t.sg);
            let ea = self.tm.cmp(T_EQ, x, a.state[i]);
            let eb = self.tm.cmp(T_EQ, x, b.state[i]);
            ca = self.tm.and(ca, ea);
            cb = self.tm.and(cb, eb);
            a.state.set(i, x);
        }
        let f = self.tm.or(ca, cb);
        a.pc.truncate(k);
        a.pc.extend_copy(&kept);
        if !self.tm.is_true(f) {
            a.pc.push(f);
        }
        return true;
    }

    // Enter block `to` from block `from` on `path`: a contract chain is evaluated in place, a loop
    // header cuts the loop at its invariants.
    fn enter(self: &mut Self, b: &ir::CoreBody, mut path: Path, from: u32, to: u32) {
        let qi = Prover::<B>::quant_at(b, to);
        if qi != NONE {
            let qs = b.quants[qi as usize];
            let q = self.quantifier(b, b.module, qi, &mut path.state, &path.pc, false);
            self.write_place(b, b.module, &mut path.state, qs.result, q, false);
            self.enter(b, path, to, qs.exit);
            return;
        }
        let s = self.site_of_chain[to as usize];
        if s != NONE && b.contracts[s as usize].pred == from && !ir::is_ghost_site(b.contracts[s as usize].kind) && b.contracts[s as usize].kind != CT_OLD_RUN {
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
        self.ov = path.ov;
        let (f, v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
        // The blocks the clauses give the body are distinct (the caller proved it, `ov_apart`).
        if s.kind == CT_REQUIRES && !self.refining {
            self.src_mark(f, SRC_REQ | si);
        }
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
        } else if s.kind == CT_PANICS {
            // A call through the interface proved its `panics if` false: the method's must be false too.
            if self.refining {
                let nf = self.tm.not(f);
                let ip = pick(self.refine_pan == NONE, self.tm.boolean(false), self.refine_pan);
                let g = self.tm.or(nf, ip);
                self.oblige(
                    &path.pc,
                    g,
                    OB_REFINE << 56 | si as u64,
                    sp,
                    format("cannot prove this 'panics if' from the interface's 'panics if'"),
                    String::from_str(
                        "a call through the interface proves only that the interface's 'panics if' is false",
                    ),
                );
            }
            self.pan_cond = if self.pan_cond == NONE {
                f
            } else {
                self.tm.or(self.pan_cond, f)
            };
        } else if s.kind == CT_PATTERN {
            self.oblige(
                &path.pc,
                f,
                OB_PATTERN << 56 | si as u64,
                sp,
                format("cannot prove that this value matches its pattern type"),
                String::from_str(
                    "a value of a pattern type is a constant that matches, an 'as?' conversion, or a value the path shows matches",
                ),
            );
            path.pc.push(f);
        } else if s.kind == CT_ENSURES {
            path.ens.push(f);
            // A static's invariant of its first value: the lemma its clauses expand to.
            let first = sp.end >= sp.start + 9 && self.text(b.module, tok::Span::new(sp.start, sp.start + 9)) == "invariant";
            let rs = self.return_span(b, s.cont);
            let note = if first {
                String::from_str("a static's first value satisfies its invariant: each read assumes it")
            } else if rs.end > rs.start {
                format("on a path to the return at line {}", self.source_line(b.module, rs.start))
            } else {
                String::new()
            };
            self.oblige(
                &path.pc,
                f,
                OB_ENSURES << 56 | si as u64,
                sp,
                if first {
                    String::from_str("cannot prove the invariant of this static's first value")
                } else {
                    String::from_str("cannot prove this 'ensures' clause")
                },
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
        let z = self.tm.int(Num::<B>::zero(), vx.w, vx.sg);
        let c1 = self.tm.cmp(T_LE, z, v);
        let c2 = self.tm.cmp(T_LT, v, m);
        return self.tm.and(c1, c2);
    }

    // Loop header `h` entered from `from`: each invariant holds on the way in; past the first entry
    // the path ends (the invariants hold again, so every later iteration is the one the first entry
    // walks); on the first entry every local the loop writes is forgotten and the invariants assumed.
    fn header(self: &mut Self, b: &ir::CoreBody, mut path: Path, from: u32, h: u32) {
        self.ov = path.ov;
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
        let mut lfs = Vector::<u32>::new();
        for j in 0..invs.len() {
            let s = b.contracts[invs[j] as usize];
            let (f, _v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
            lfs.push(f);
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
        if invs.len() != 0 {
            let sp = self.site_span(b.module, b.contracts[invs[0] as usize]);
            self.loop_apart(&path.pc, &lfs, sp, OB_INV_STEP << 56 | 1 << 55 | invs[0] as u64);
        }
        // `free`'s receiver, which `inv_locs` leaves out: a call of the loop may need its invariant, so it
        // holds where the loop starts and at the end of each iteration, and the header assumes it.
        let rs = self.inv_end;
        if rs != NONE && path.state[rs as usize] != NONE {
            let (rk, rsp, what) = if back {
                (9u64 << 52, b.blocks.at(from as usize).term.span, "at the end of this iteration")
            } else {
                (14u64 << 52, b.blocks.at(h as usize).term.span, "where this loop starts")
            };
            let rty = self.loc_ty(b, rs as usize);
            let _ = self.inv_need(
                b,
                &path.state,
                &path.pc,
                rty,
                path.state[rs as usize],
                rk | rs as u64 << 32 | h as u64,
                rsp,
                what,
            );
        }
        // A value of a struct type whose invariant this file proves (`inv_locs`) holds it at the end of each
        // iteration, and the values hold distinct blocks, none a shared parameter lends: the header assumes
        // both.
        if back {
            // A local whose storage starts in the loop is dead at its back edge: it holds no value, and the
            // next iteration writes it before it reads it.
            self.fx.loop_scan(h);
            for j in 0..self.fx.lblocks.len() {
                let bb = b.blocks.at(self.fx.lblocks[j] as usize);
                for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                    let st = *b.statements.at(sid as usize);
                    if st.kind == ir::ST_STORAGE_LIVE && self.inv_locs.contains(&st.a) {
                        self.inv_dead.push(st.a);
                    }
                }
            }
            let sp = b.blocks.at(from as usize).term.span;
            let _ = self.inv_unwind(
                b,
                &path.state,
                &path.pc,
                9 << 52 | h as u64,
                sp,
                "at the end of this iteration",
                NONE,
            );
            self.inv_dead.clear();
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
        // The element references of `[]mut` parameters (`param_write` calls' results): a write through one
        // reaches only that parameter's memory, a new epoch with no local changed.
        let mut prefs = Vector::<u32>::new();
        let mut pskip: u64 = 0;
        let mut ldef = Map::<u32, u32>::new();
        for j in 0..self.fx.lblocks.len() {
            let bb = b.blocks.at(self.fx.lblocks[j] as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind == ir::ST_ASSIGN && b.places.at(st.place as usize).proj_len == 0 {
                    ldef.insert(b.places.at(st.place as usize).base, st.rvalue);
                }
            }
        }
        for j in 0..self.fx.lblocks.len() {
            let t = b.blocks.at(self.fx.lblocks[j] as usize).term;
            if t.kind != ir::TM_CALL || t.dests_len != 1 || t.args_len == 0 || self.sq_kind(b, b.module, &t) != VK_SINDEX_MUT {
                continue;
            }
            let op = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
            if op.kind == ir::OP_CONST || b.places.at(op.data as usize).proj_len != 0 {
                continue;
            }
            let pb = param_bit(b, ref_origin(b, &ldef, b.places.at(op.data as usize).base));
            if pb != 0 {
                pskip |= pb;
                prefs.push(b.places.at(b.dest_pool[t.dests_start as usize] as usize).base);
            }
        }
        // The locals the loop's statements and calls may make memory (`is_mem`): a memory event of an
        // iteration may reach them. A local made memory only outside the loop is not memory in it
        // until it escapes (`esc`). A borrow through a reference reaches the memory it refers to, not
        // the local that holds it.
        let mut lmem = Vector::<u32>::new();
        for j in 0..self.fx.lblocks.len() {
            let bb = *b.blocks.at(self.fx.lblocks[j] as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let rv = *b.rvalues.at(st.rvalue as usize);
                if (rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF || rv.kind == ir::RV_SLICE) && !self.owned_elem(
                    b,
                    b.places.at(rv.a as usize),
                ) && !self.has_deref(b, b.places.at(rv.a as usize), 0) && !self.mem_from(
                    b,
                    b.places.at(rv.a as usize),
                    0,
                ) {
                    lmem.push(b.places.at(rv.a as usize).base);
                } else if rv.kind == ir::RV_CLOSURE {
                    for q in rv.a..rv.a + rv.b {
                        let op = *b.operands.at(b.oper_pool[q as usize] as usize);
                        if op.kind != ir::OP_CONST {
                            lmem.push(b.places.at(op.data as usize).base);
                        }
                    }
                }
            }
            if bb.term.kind == ir::TM_CALL && self.sq_kind(b, b.module, &bb.term) == 0 && !self.borrow_ends(b, &bb.term) {
                for q in 0..bb.term.args_len {
                    let op = *b.operands.at(b.oper_pool[(bb.term.args_start + q) as usize] as usize);
                    if op.kind != ir::OP_CONST && self.autoref(b, b.module, &bb.term, q) && !self.shared_read(
                        b,
                        &bb.term,
                        q,
                    ) && !self.cell_read(b, &bb.term, q) && !self.has_deref(b, b.places.at(op.data as usize), 0) {
                        lmem.push(b.places.at(op.data as usize).base);
                    }
                }
            }
        }
        let mut event = false;
        // A destructor or call that reaches one owned element alone (`owned_elem`): it runs code, which
        // reaches none of the loop's locals.
        let mut eevent = false;
        let mut pevent = false;
        // The `[]mut` parameters the loop's memory events may reach (`reached_params`; all bits: unknown).
        let mut lreach: u64 = 0;
        // An iteration's writes change what the walk's writes do (`havoc_write`). They run twice: the
        // second time each reads as unknown the references and members the loop writes (a reference one
        // iteration changes is the place another writes through).
        for j in 0..self.fx.lblocks.len() {
            let bb = *b.blocks.at(self.fx.lblocks[j] as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind == ir::ST_ASSIGN {
                    let _ = self.havoc_write(b, &mut path.state, st.place);
                }
            }
            if bb.term.kind == ir::TM_CALL || bb.term.kind == ir::TM_DROP {
                for q in bb.term.dests_start..bb.term.dests_start + bb.term.dests_len {
                    let _ = self.havoc_write(b, &mut path.state, b.dest_pool[q as usize]);
                }
            }
        }
        for j in 0..self.fx.lblocks.len() {
            let bb = *b.blocks.at(self.fx.lblocks[j] as usize);
            for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let st = *b.statements.at(sid as usize);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                // A place the loop borrows mutably or takes the address of: whatever the borrow reaches may
                // write it in an iteration (a call it is lent to, a write through it, each an event of its own).
                let rv = *b.rvalues.at(st.rvalue as usize);
                if rv.kind == ir::RV_REF && rv.b != 0 || rv.kind == ir::RV_ADDR {
                    let _ = self.havoc_write(b, &mut path.state, rv.a);
                }
                let pl = *b.places.at(st.place as usize);
                let plain = !(rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_ASM || rv.c == ir::IN_VOLATILE_STORE));
                if pl.proj_len != 0 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF && prefs.contains(
                    &ref_origin(b, &ldef, pl.base),
                ) && !self.has_deref(b, &pl, 1) && plain {
                    pevent = true;
                    continue;
                }
                let mem = self.havoc_write(b, &mut path.state, st.place);
                event = event || mem || !plain || self.is_mem[pl.base as usize];
                if mem && plain && self.has_deref(b, &pl, 0) {
                    let o = ref_origin(b, &ldef, pl.base);
                    lreach |= pick(param_bit(b, o) != 0 && !self.has_deref(b, &pl, 1), param_bit(b, o), ~0u64);
                } else if mem || !plain {
                    lreach = ~0u64;
                }
            }
            if bb.term.kind == ir::TM_DROP && self.owned_elem(b, b.places.at(bb.term.a as usize)) {
                self.forget_elems(b, &mut path.state, bb.term.a);
            }
            if bb.term.kind == ir::TM_CALL || bb.term.kind == ir::TM_DROP {
                for q in bb.term.dests_start..bb.term.dests_start + bb.term.dests_len {
                    let _ = self.havoc_write(b, &mut path.state, b.dest_pool[q as usize]);
                }
                // A receiver an unmodeled call borrows implicitly (`v.sort()`), or a reference it is passed
                // that was made before the loop: the callee may write what they reach. A modeled method's
                // effect is its model's (below).
                if bb.term.kind == ir::TM_CALL && !self.is_ghost(bb.term.callee) && self.sq_kind(b, b.module, &bb.term) == 0 {
                    for q in 0..bb.term.args_len {
                        let op = *b.operands.at(b.oper_pool[(bb.term.args_start + q) as usize] as usize);
                        if op.kind == ir::OP_CONST {
                            continue;
                        }
                        if q == 0 && self.elem_call(b, &bb.term) {
                            self.forget_elems(b, &mut path.state, op.data);
                            continue;
                        }
                        if self.shared_read(b, &bb.term, q) {
                            continue;
                        }
                        if self.cell_read(b, &bb.term, q) {
                            self.cell_refresh_arg(b, &mut path.state, op.data);
                            continue;
                        }
                        if self.autoref(b, b.module, &bb.term, q) {
                            let _ = self.havoc_write(b, &mut path.state, op.data);
                            continue;
                        }
                        let pl = *b.places.at(op.data as usize);
                        let v = if pl.proj_len == 0 {
                            path.state[pl.base as usize]
                        } else {
                            NONE
                        };
                        if v != NONE && (self.tm.at(v).op == T_MREF || self.tm.at(v).op == T_PREF) {
                            self.forget(b, b.module, &mut path.state, self.ref_target(v));
                        }
                    }
                }
                // A modeled method that changes its container: the container. One that writes no other
                // memory (`push`, `pop`, `clear`, a length, a shared element read, a view) is no event,
                // nor is a ghost call.
                let k = pick(bb.term.kind == ir::TM_CALL, self.sq_kind(b, b.module, &bb.term), 0);
                // An element write through a `[]mut` parameter reaches only the parameter's memory, which
                // no local shares.
                let param_write = k == VK_SINDEX_MUT && bb.term.dests_len == 1 && prefs.contains(
                    &b.places.at(b.dest_pool[bb.term.dests_start as usize] as usize).base,
                );
                let quiet = k == VK_LEN || k == VK_SPTR || k == VK_SLEN || k == VK_INDEX || k == VK_SINDEX || k == VK_SHARE || k == VK_RANGE || k == SQ_VIEW;
                let ghost = bb.term.kind == ir::TM_CALL && self.is_ghost(bb.term.callee);
                let elem = bb.term.kind == ir::TM_DROP && self.owned_elem(b, b.places.at(bb.term.a as usize)) || self.elem_call(
                    b,
                    &bb.term,
                );
                eevent = eevent || elem;
                event = event || !(quiet || ghost || param_write || elem);
                if !(quiet || ghost || param_write || elem) {
                    lreach |= self.loop_reach(b, &ldef, &bb.term);
                }
                if k == VK_INDEX_MUT {
                    let tg = self.recv_target(b, b.module, &mut path.state, &bb.term);
                    if tg != NONE {
                        self.forget(b, b.module, &mut path.state, tg);
                    }
                }
            }
        }
        // An earlier iteration may have taken or given a block: the loop's invariants state them.
        if self.loop_owns(b) {
            path.ov = self.ov_new(OV_BASE, NONE);
            self.ov = path.ov;
        }
        if event {
            // An earlier iteration may have reached any such local, and the parameters it reaches.
            let ep0 = path.state[path.state.len() - 1];
            self.esc = replace(&mut path.esc, Vector::<u32>::new());
            self.aesc = replace(&mut path.aesc, Vector::<u32>::new());
            self.views = replace(&mut path.views, Vector::<u64>::new());
            for j in 0..self.mem_list.len() {
                let l = self.mem_list[j];
                if lmem.contains(&l) || l as usize >= b.locals.len() && self.slot_lent(b, l, &lmem) {
                    self.escape(l);
                }
            }
            self.mem_event(b, b.module, &mut path.state);
            path.esc = replace(&mut self.esc, Vector::<u32>::new());
            path.aesc = replace(&mut self.aesc, Vector::<u32>::new());
            path.views = replace(&mut self.views, Vector::<u64>::new());
            path.pend.clear();
            self.keep_param_views(b, b.module, &path.state, ep0, lreach | pskip);
        }
        if (pevent || eevent) && !event {
            let ep0 = path.state[path.state.len() - 1];
            self.keep_own = !pevent;
            self.mem_event_of(b, b.module, &mut path.state, false);
            self.keep_own = false;
            self.keep_param_views(b, b.module, &path.state, ep0, pskip);
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
        let mut ils = self.inv_locs.clone();
        if rs != NONE {
            ils.push(rs);
        }
        for j in 0..ils.len() {
            let l = ils[j];
            let v = path.state[l as usize];
            if v != NONE {
                let f = self.inv_of(b.module, self.loc_ty(b, l as usize), v, &path.state);
                self.src_mark(f, SRC_LOC | l);
                if f != NONE && !path.pc.contains(&f) {
                    path.pc.push(f);
                }
            }
        }
        let mut lc = Vector::<u32>::new();
        self.lent_claims(b, &path.state, &mut path.pc, &mut lc);
        let mut lall = self.tm.boolean(true);
        for j in 0..invs.len() {
            let s = b.contracts[invs[j] as usize];
            let (f, _v) = self.chain(b, b.module, s, &path.state, &path.pc, false, none);
            path.pc.push(f);
            lall = self.tm.and(lall, f);
        }
        self.src_mark(lall, SRC_LOOP);
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
        self.aesc = replace(&mut path.aesc, Vector::<u32>::new());
        self.pend = replace(&mut path.pend, Vector::<u64>::new());
        self.views = replace(&mut path.views, Vector::<u64>::new());
        self.ov = path.ov;
        self.in_ghost = self.ghost_fn || self.gblk[path.blk as usize];
        let bb = *b.blocks.at(path.blk as usize);
        let ovf = self.ovf;
        self.mi_dirty = replace(&mut path.mi, Vector::<u32>::new());
        self.mi_fresh = replace(&mut path.fresh, Vector::<u32>::new());
        self.mi_wrote = replace(&mut path.wrote, Vector::<u32>::new());
        self.mi_lds.clear();
        for sid in bb.stmt_start..bb.stmt_start + bb.stmt_len {
            self.statement(b, b.module, &mut path.state, &mut path.pc, sid, false, ovf);
        }
        let t = bb.term;
        let me = path.blk;
        // Before a call, a drop, a check that may panic, a return or a loop's header: the structs the path
        // wrote through a pointer (`mi_close`). An allocator's call reaches none, and a branch runs no code:
        // a later block closes them.
        let acall = t.kind == ir::TM_CALL && self.alloc_call(t.callee) != AK_NONE;
        if acall {
            self.mi_alloc_open(b, &mut path, &t);
        }
        let carry = acall || (t.kind == ir::TM_GOTO || t.kind == ir::TM_SWITCH) && !self.to_header(b, &t);
        if self.mi_dirty.len() != 0 && !carry {
            let sp = if t.span.end > t.span.start {
                t.span
            } else {
                self.ast_of(b.module).at_const(b.owner.node).span
            };
            self.mi_close(b, &path.state, &mut path.pc, sp);
        }
        if t.kind == ir::TM_CALL {
            self.call(b, &mut path, &t);
        } else if t.kind == ir::TM_DROP {
            // The destructor assumes the value's invariant, and may panic past the other values.
            self.ov_pre = self.ov;
            self.recv_pre = self.recv_val(&path.state);
            let dty = b.places.at(t.a as usize).ty;
            let pl = *b.places.at(t.a as usize);
            let dead = pick(pl.proj_len == 0, pl.base, NONE);
            if !self.ghost_fn && self.inv_here(b.module, dty) {
                let dv = self.read_place(b, b.module, &mut path.state, t.a, false);
                self.own_check(&mut path.pc, t.span);
                let f = self.inv_need(
                    b,
                    &path.state,
                    &path.pc,
                    dty,
                    dv,
                    5 << 52 | t.span.start as u64,
                    t.span,
                    "at this drop",
                );
                // The destructor takes the value's blocks.
                self.ov_take.clear();
                self.ov_take_sh.clear();
                self.ov_name(f, 0);
                let tk0 = self.ov_take.clone();
                self.lent_take(b, &path.state, &mut path.pc, &tk0, t.span);
                self.ov_remove();
            }
            if self.inv_locs.len() != 0 {
                let fs = self.inv_unwind(
                    b,
                    &path.state,
                    &path.pc,
                    8 << 52 | t.span.start as u64,
                    t.span,
                    "where this drop may panic",
                    dead,
                );
                Self::inv_proved(&mut path.pc, &fs);
            }
            // A destructor runs code: a memory event, which reaches no `[]mut` parameter where the value
            // owns its memory (`owns`).
            let ep0 = path.state[path.state.len() - 1];
            // An element of an `@owned` block: its destructor reaches it alone (the other elements and the
            // blocks stay), and it holds no value after.
            let elem = self.owned_elem(b, &pl);
            let skip = pick(
                pl.proj_len == 0 && self.owns(b.module, b.locals.at(pl.base as usize).ty) || elem,
                0u64,
                ~0u64,
            );
            self.keep_own = elem;
            self.mem_event(b, b.module, &mut path.state);
            self.keep_own = false;
            self.keep_param_views(b, b.module, &path.state, ep0, skip);
            if elem {
                let ev = self.fresh(b.module, pl.ty);
                self.write_place(b, b.module, &mut path.state, t.a, ev, false);
            }
            if !self.ghost_fn {
                self.inv_resume(b, &mut path, 8 << 52 | t.span.start as u64, dead);
            }
            // A dropped local holds no value: no later check reads it, and a write gives it a new one.
            if dead != NONE && self.inv_locs.contains(&dead) {
                path.state.set(dead as usize, NONE);
            }
        }
        path.views = replace(&mut self.views, Vector::<u64>::new());
        path.esc = replace(&mut self.esc, Vector::<u32>::new());
        path.aesc = replace(&mut self.aesc, Vector::<u32>::new());
        path.pend = replace(&mut self.pend, Vector::<u64>::new());
        path.ov = self.ov;
        path.mi = replace(&mut self.mi_dirty, Vector::<u32>::new());
        path.fresh = replace(&mut self.mi_fresh, Vector::<u32>::new());
        path.wrote = replace(&mut self.mi_wrote, Vector::<u32>::new());
        if t.kind == ir::TM_GOTO {
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_DROP {
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_ASSERT {
            let c = self.operand(b, b.module, &mut path.state, t.a, false);
            self.own_check(&mut path.pc, t.span);
            if !self.in_ghost && (!self.no_panic || self.pan_cond != NONE) {
                let fs = self.inv_unwind(
                    b,
                    &path.state,
                    &path.pc,
                    6 << 52 | t.span.start as u64,
                    t.span,
                    "where this check may panic",
                    NONE,
                );
                Self::inv_proved(&mut path.pc, &fs);
            }
            let mut assert_by = false;
            for j in 0..b.contracts.len() {
                assert_by = assert_by || b.contracts[j].check == me && b.contracts[j].kind == CT_ASSERT;
            }
            if self.in_ghost {
                let msg = if assert_by {
                    format("cannot prove this 'assert'")
                } else {
                    format("cannot prove that this check of ghost code holds")
                };
                self.oblige(
                    &path.pc,
                    c,
                    OB_GHOST << 56 | me as u64,
                    t.span,
                    msg,
                    String::from_str(pick(assert_by, "", "ghost code never runs: each of its checks is an obligation")),
                );
            } else if self.no_panic && !assert_by {
                self.oblige(
                    &path.pc,
                    c,
                    OB_PANIC << 56 | 1 << 55 | me as u64,
                    t.span,
                    format("cannot prove that this check holds"),
                    String::from_str(NO_PANIC_NOTE),
                );
            }
            // The path where the check fails ends: the obligation covers it (a short-circuit's false
            // branch of `assert a && b` states `!a`).
            let nc = self.tm.not(c);
            if self.tm.is_false(c) || path.pc.contains(&nc) {
                return;
            }
            path.pc.push(c);
            self.enter(b, path, me, t.t0);
        } else if t.kind == ir::TM_SWITCH {
            let mut edges = Vector::<u64>::new();
            self.switch_edges(b, b.module, &mut path.state, &t, false, &mut edges);
            self.own_check(&mut path.pc, t.span);
            // An edge whose condition the path refutes is never taken (`chain`).
            let mut live = Vector::<u64>::with_capacity(edges.len());
            for j in 0..edges.len() {
                let c = (edges[j] & 0xFFFFFFFFu64) as u32;
                let nc = self.tm.not(c);
                if !self.tm.is_false(c) && !path.pc.contains(&nc) {
                    live.push(edges[j]);
                }
            }
            if live.len() == 0 {
                return;
            }
            // Each edge but the last takes a copy of the path, the last the path itself.
            for j in 0..live.len() - 1 {
                let mut q = path.copy();
                q.pc.push((live[j] & 0xFFFFFFFFu64) as u32);
                self.enter(b, q, me, (live[j] >> 32) as u32);
            }
            let e = live[live.len() - 1];
            path.pc.push((e & 0xFFFFFFFFu64) as u32);
            self.enter(b, path, me, (e >> 32) as u32);
        } else if t.kind == ir::TM_CALL {
            if self.pdef.len() != 0 {
                self.ptr_split(b, path, me, &t);
            } else {
                self.enter(b, path, me, t.t0);
            }
        } else if t.kind == ir::TM_RETURN {
            let sp = if t.span.end > t.span.start {
                t.span
            } else {
                self.ast_of(b.module).at_const(b.owner.node).span
            };
            if self.refining {
                self.refine_return(b, &mut path, sp);
            }
            if !self.refining || self.refine_all {
                self.inv_return(b, &path, sp);
            }
        }
        // a return or an unreachable end: the path ends
    }

    // Call `t` of a function in the caller's component (kept body `ci`): the callee's measure, over
    // the arguments, is at least 0 and below the caller's at its start.
    fn mutual(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, ci: u32) {
        let cb = unsafe &(&*self.keep).kept.at(ci as usize).body;
        self.note_read(cb.owner);
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
                let x0 = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + j) as usize], false);
                let x = self.implicit_ref(b, t, j, x0);
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
        self.pdef.clear();
        // A byte copy into a block or an inline array: those bytes (`mem_copy`).
        if t.intr != ir::CI_NONE && self.mem_copy(b, path, t) {
            return;
        }
        // A wide integer's operation borrows its operands only to read them: no escape, no memory event.
        if self.wide_kind(t.callee) != 0 {
            let key = OB_OVERFLOW << 56 | 1 << 39 | t.span.start as u64;
            let ovf = self.ovf;
            let r = self.wide_op(b, b.module, &mut path.state, &mut path.pc, t, false, ovf, key, t.span);
            if r != NONE {
                self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], r, false);
                return;
            }
        }
        // So does an operation of `Float<E, F, FAMILY>`.
        if self.soft_kind(t.callee) != 0 {
            let r = self.soft_op(b, b.module, &mut path.state, t, false);
            if r != NONE {
                self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], r, false);
                return;
            }
        }
        self.ov_take.clear();
        self.ov_take_sh.clear();
        self.tk_atoms.clear();
        self.tk_src.clear();
        self.ov_pre = self.ov;
        self.recv_pre = self.recv_val(&path.state);
        // A lemma whose clauses name blocks or units takes and gives them as a call does; other ghost code
        // reads only.
        let ghost_callee = self.is_ghost(t.callee) && !(self.is_lemma(t.callee) && self.mentions_owns(t.callee));
        self.inv_call(b, path, t);
        // `forget` ends its value without its destructor: the value's blocks stay with the body.
        if self.is_forget(t.callee) {
            self.ov_take.clear();
            self.ov_take_sh.clear();
            self.tk_atoms.clear();
            self.tk_src.clear();
        }
        let esc0 = self.esc.len();
        let aesc0 = self.aesc.len();
        // The `&mut` parameters' targets the call borrows (`param_reborrow`).
        let mut prb = Vector::<u32>::new();
        // An allocator's call: its size, and the block it moves (`own_after`).
        let ak = self.alloc_call(t.callee);
        let mut asize = NONE;
        let mut aold = NONE;
        let mut adir: u32 = 0;
        let mut aprod = NONE;
        // A block freed while it holds a struct with an invariant (`*mut S` given to `dealloc`): the struct's
        // blocks are the caller's from there, as a write through the pointer opens it (`mi_open`).
        if ak == AK_DEALLOC && t.args_len >= 2 && !self.ghost_fn {
            let opid = b.oper_pool[(t.args_start + 1) as usize];
            let op = *b.operands.at(opid as usize);
            let y = *self.ast_of(b.module).type_at(op.ty);
            if op.ty != TYPE_NONE && y.kind == TypeKind::TYPE_POINTER && self.mi_type(b.module, y.as_data.elem) {
                let r = self.operand(b, b.module, &mut path.state, opid, false);
                self.mi_close_at(b, &path.state, r);
                if !self.mi_wrote.contains(&r) {
                    let old = self.deref(&path.state, r, b.module, y.as_data.elem);
                    self.mi_open(r, b.module, y.as_data.elem, old, &path.state);
                }
                // The freed struct has no invariant left to prove: the blocks its value names stay the
                // caller's.
                let mut kept = Vector::<u32>::new();
                for q in 0..self.mi_dirty.len() / 3 {
                    if self.mi_dirty[3 * q] != r {
                        kept.extend_from_slice(self.mi_dirty[3 * q..3 * q + 3]);
                    }
                }
                self.mi_dirty = kept;
            }
        }
        if ak == AK_ALLOC && t.args_len >= 2 {
            asize = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
            aprod = self.size_product(&path.pc, asize);
        } else if ak == AK_REALLOC && t.args_len >= 4 {
            asize = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 3) as usize], false);
            aprod = self.size_product(&path.pc, asize);
            let pv = self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false);
            let mut et = TYPE_NONE;
            aold = self.block_of_ptr(b, &path.state, pv, &mut et);

            // Whether the block grows or shrinks, where the path decides it (`own_after`).
            if aold != NONE && et != TYPE_NONE {
                let k = self.widened(self.size_term(b.module, et), W_INT, true);
                let lo = self.seq_len(aold);
                let ob = self.tm.arith(T_MUL, lo, k, W_INT, true);
                let sz = self.widened(asize, W_INT, true);
                // A new size `x * sizeof(T)` grows the block where `x` is at least its length.
                let st = self.tm.at(asize);
                let ek = self.size_term(b.module, et);
                let x = if st.op == T_MUL && (st.a == ek || st.b == ek) {
                    self.widened(pick(st.a == ek, st.b, st.a), W_INT, true)
                } else {
                    self.product_count(aprod, k)
                };
                if sz != NONE {
                    let up = if x != NONE {
                        self.tm.cmp(T_LE, lo, x)
                    } else {
                        self.tm.cmp(T_LE, ob, sz)
                    };
                    // A decision the path leaves open keeps the block unknown: each side within STAGE_STEPS.
                    adir = if self.holds_within(&path.pc, up, STAGE_STEPS) {
                        1
                    } else if self.holds_within(&path.pc, self.tm.not(up), STAGE_STEPS) {
                        2
                    } else {
                        0
                    };
                }
            }
        }
        // An element or a range of a modeled container panics outside its bounds: a check of a body with
        // contracts or of ghost code.
        if self.in_ghost || self.no_panic {
            self.bounds_check(b, path, t);
        }
        // A modeled method of a container: its new value and view (`sq_effect`).
        if self.sq_effect(b, path, t) {
            return;
        }
        // A method of `Secret`: its value (`secret_op`), as for an operation on its integer.
        if t.dests_len == 1 {
            let mut r = self.secret_op(b, b.module, &mut path.state, &mut path.pc, t, false);
            if r == NONE {
                r = self.float_call(b, b.module, &mut path.state, t, false);
            }
            if r != NONE {
                self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], r, false);
                return;
            }
        }
        let d = t.callee;
        let tv = self.trigger_value(b, b.module, &mut path.state, t, false);
        if tv != NONE {
            self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], tv, false);
            return;
        }
        // Ghost code never runs: a panic in it is a check that fails. A body with contracts reaches none.
        if self.in_ghost && self.panics(d) {
            let f = self.tm.boolean(false);
            self.oblige(
                &path.pc,
                f,
                OB_GHOST << 56 | 2 << 53 | t.span.start as u64,
                t.span,
                format("cannot prove that ghost code does not panic here"),
                String::from_str("ghost code never runs: each of its checks is an obligation"),
            );
        } else if self.no_panic && self.panics(d) && !self.exits(d) {
            let f = self.tm.boolean(false);
            self.oblige(
                &path.pc,
                f,
                OB_PANIC << 56 | 2 << 53 | t.span.start as u64,
                t.span,
                format("cannot prove that this panic is unreachable"),
                String::from_str(NO_PANIC_NOTE),
            );
        }
        // A spec function or a lemma only reads its arguments, and a container's length query only its
        // receiver, whose borrow ends with the call. A modeled method that changes its container
        // (`push`, `pop`, `clear`) returns no reference: its borrow ends with the call too, and the model
        // gives the container's new value. A mutable reference passed on may be written through.
        let sk = self.sq_kind(b, b.module, t);
        let ghost = self.is_ghost(d);
        let reads = ghost || sk == VK_LEN || sk == VK_SLEN || sk == VK_SPTR;
        // A receiver that only it changes (`alloc_event`): an allocator that is a field of a value
        // (`v.alloc.alloc(..)`), or a field another call borrows and keeps nothing of (`p.v.push(5)`,
        // `borrow_ends`), whose other fields keep theirs; an element of an `@owned` block that the call
        // borrows alone (`v.ptr[i].free()`), whose other elements keep theirs.
        let arecv = if t.args_len != 0 && self.autoref(b, b.module, t, 0) {
            let p0 = *b.places.at(b.operands.at(b.oper_pool[t.args_start as usize] as usize).data as usize);
            let rp = b.operands.at(b.oper_pool[t.args_start as usize] as usize).data;
            if (ak != AK_NONE || self.borrow_ends(b, t)) && self.field_path(b, &p0, p0.proj_len) {
                rp
            } else if self.elem_call(b, t) {
                rp
            } else {
                NONE
            }
        } else {
            NONE
        };
        for j in 0..t.args_len {
            let oid = b.oper_pool[(t.args_start + j) as usize];
            let op = *b.operands.at(oid as usize);
            if j == 0 && arecv != NONE {
                continue;
            }
            if self.cell_read(b, t, j) {
                // Its cells take new values after the call (`call_event`).
            } else if self.autoref(b, b.module, t, j) && !reads && !self.shared_read(b, t, j) {
                // Through a raw pointer it reaches memory, not the local that holds the pointer; a member
                // borrow reaches that member alone (`borrow_reach`).
                let pl = *b.places.at(op.data as usize);
                if !self.raw_reach(b, b.module, &mut path.state, &pl) {
                    let pr = self.place_ref(b, b.module, &mut path.state, &pl);
                    if pr != NONE && self.tm.at(pr).op == T_MREF && self.param_reborrow(b, t, pr) {
                        prb.push(self.ref_target(pr));
                    } else {
                        self.borrow_reach(b, b.module, &mut path.state, &pl);
                    }
                }
            } else if !reads && op.kind != ir::OP_CONST && !self.shared_read(b, t, j) && !(b.places.at(op.data as usize).proj_len == 0 && self.scoped[b.places.at(
                op.data as usize,
            ).base as usize]) {
                // A shared read (`shared_read`) lets the callee keep no way to write what it reads.
                let v = self.operand(b, b.module, &mut path.state, oid, false);
                // A `&mut` parameter's whole target the call reborrows: the call's event gives it a new
                // value, and no pointer reaches it after the call.
                if v != NONE && self.tm.at(v).op == T_MREF && self.param_reborrow(b, t, v) {
                    prb.push(self.ref_target(v));
                } else {
                    self.leak(v);
                }
            }
        }
        let r0 = self.call_value(b, b.module, &mut path.state, t, false);
        self.own_check(&mut path.pc, t.span);
        // An unknown result of a small frozen aggregate type is the aggregate of its members (`eta`).
        let r = if t.dests_len == 1 && self.tm.at(r0).op == T_VAR {
            self.eta(b.module, b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty, r0, 0)
        } else {
            r0
        };
        // A raw pointer result of a call that takes one mutable borrow: its `ensures` may say where it
        // points (`ptr_defs`).
        let borrow_one = t.dests_len == 1 && self.ast_of(b.module).type_at(
            b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty,
        ).kind == TypeKind::TYPE_POINTER && self.one_borrow(b, t);
        // A `const fn` whose value the walk computed (no fresh unknown) writes no memory.
        let pure = self.tm.at(r).op == T_CALL || self.is_const_fn(d) && self.tm.at(r).op != T_VAR;
        let own = d.module == b.owner.module && d.node == b.owner.node;
        // A conformance's method with no contract of its own has the interface's (`contract_of`).
        let c = if own {
            d
        } else {
            self.contract_of(d)
        };
        let cbp = if d.node == NODE_NONE {
            null
        } else if own {
            b as *const ir::CoreBody
        } else {
            self.contract_body(c)
        };
        let cdm = c.module;
        // A call back into the function's own component must decrease the measure too.
        let ci = self.kept_index(d);
        let scc = &self.shared().scc;
        // A `@prove_exhaustive` callee ends for each argument its `requires` admits: each run ended.
        let cycle = !own && ci != NONE && self.me != NONE && scc[ci as usize] != NONE && scc[ci as usize] == scc[self.me as usize] && !self.exhaustive(
            d,
        );
        if self.ghost_fn && (own || cycle) && !self.has_fn_dec(b) {
            self.report(
                OB_DECREASES << 56 | 4 << 40 | t.span.start as u64,
                dc::CANNOT_PROVE_CONTRACT,
                t.span,
                format("this call recurses: a spec function or a lemma that does needs a 'decreases' measure"),
                String::from_str("ghost code must end"),
            );
        } else if self.fn_dec && cycle {
            self.mutual(b, path, t, ci);
        }
        let has_req = self.has_clause(c, CT_REQUIRES) || (self.no_panic || self.in_ghost) && self.has_clause(
            c,
            CT_PANICS,
        );
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
            let cm = cdm;
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
                            self.tm.make(
                                Term::<B> { k: Num::<B>::zero(), a: pl.base, b: 0, op: T_MREF, w: W_OTHER, sg: false },
                            )
                        } else {
                            let pr = self.place_ref(b, b.module, &mut path.state, &pl);
                            if pr != NONE {
                                pr
                            } else {
                                self.tm.var(W_OTHER, false)
                            }
                        }
                    } else {
                        let x0 = self.operand(b, b.module, &mut path.state, oid, false);
                        let x1 = self.implicit_ref(b, t, j, x0);
                        let op = *b.operands.at(oid as usize);
                        // The value's own type: a place's local for a whole local (the coercion to the
                        // parameter's type gives the place that type).
                        let aty = if op.kind == ir::OP_CONST {
                            op.ty
                        } else if b.places.at(op.data as usize).proj_len == 0 {
                            b.locals.at(b.places.at(op.data as usize).base as usize).ty
                        } else {
                            b.places.at(op.data as usize).ty
                        };
                        self.share_arg(
                            b.module,
                            aty,
                            cm,
                            cb.locals.at((cb.returns + j) as usize).ty,
                            x1,
                            &mut path.state,
                            &mut path.pc,
                        )
                    };
                    frame.set((cb.returns + j) as usize, x);
                }
            }
            if cb.returns == 1 && t.dests_len == 1 {
                frame.set(0, r);
            }
            let name = String::from_str(
                self.text(d.module, self.ast_of(d.module).at_const(self.ast_of(d.module).ext_name(d.node)).span),
            );
            // A generic callee's clauses read its type parameters as the call's type arguments.
            let mut binds = Vector::<u64>::new();
            self.contract_binds(b, b.module, t, c, &mut binds);
            let outer = replace(&mut self.subst, binds);
            // The frame's references to the caller's locals read the caller's state.
            self.mem = &path.state;
            // The callee's `old(e)` values: `e` in the frame before the call.
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if (s.kind == CT_OLD || s.kind == CT_OLD_RUN) && s.value != ir::IR_NONE {
                    let (_f, v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    let o = cb.places.at(cb.operands.at(s.value as usize).data as usize).base;
                    if v != NONE {
                        frame.set(o as usize, v);
                    }
                }
            }
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if s.kind == CT_REQUIRES {
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    self.ov_name(f, SRC_REQ | j as u32);
                    let csp = self.site_span(cm, s);
                    self.oblige(
                        &path.pc,
                        f,
                        OB_REQUIRES << 56 | t.span.start as u64 << 16 | j as u64,
                        t.span,
                        format("cannot prove the 'requires' of '{}' at this call", name.as_str()),
                        format("the clause: {}", self.text(cm, csp)),
                    );
                } else if s.kind == CT_PANICS && (self.in_ghost || self.no_panic && self.chain_depth == 0) {
                    // A body with contracts, and ghost code, proves that the callee does not panic.
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    let nf = self.tm.not(f);
                    let csp = self.site_span(cm, s);
                    self.oblige(
                        &path.pc,
                        nf,
                        pick(self.in_ghost, OB_GHOST, OB_PANIC) << 56 | 3 << 53 | t.span.start as u64 << 16 | j as u64,
                        t.span,
                        format("cannot prove that '{}' does not panic at this call", name.as_str()),
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
            if !pure && !ghost {
                self.alloc_event(b, path, t, ak, arecv);
                self.forget_all(b, &mut path.state, &prb);
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
            if !ghost_callee {
                self.ov_apart(&path.pc, t.span);
                let tk = self.ov_take.clone();
                self.lent_take(b, &path.state, &mut path.pc, &tk, t.span);
                self.ov_switch();
            }
            // The callee proves that its `ensures` clauses do not overflow under its `requires`, which
            // the call proved: here their arithmetic is exact.
            let co = replace(&mut self.chain_ovf, OVF_EXACT);
            for j in 0..cb.contracts.len() {
                let s = cb.contracts[j];
                if s.kind == CT_ENSURES && (!self.in_ghost || self.total(d) || self.ends(d, 0)) {
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    // A view's equality becomes its definition as well (`view_defs`), as a modeled
                    // method's effect is; the fact stays for the terms made before it.
                    self.view_defs(f, 0);
                    path.pc.push(f);
                    // The blocks the clauses give are distinct (the callee proved it at its return).
                    if !ghost_callee {
                        self.src_mark(f, SRC_RES);
                        self.sh_give(f);
                    }
                    if borrow_one {
                        self.ptr_defs(b, &path.state, f, r, 0);
                    }
                }
            }
            if self.pdef.len() != 0 {
                self.pdef_esc = esc0 as u64 << 32 | aesc0 as u64;
            }
            self.chain_ovf = co;
            self.mem = null;
            self.subst = outer;
        } else if !pure && !ghost {
            // A call that may write memory: a const fn call of frozen values writes none.
            self.alloc_event(b, path, t, ak, arecv);
            self.forget_all(b, &mut path.state, &prb);
        }
        if self.ov_col == NONE && !ghost_callee {
            self.ov_apart(&path.pc, t.span);
            let tk = self.ov_take.clone();
            self.lent_take(b, &path.state, &mut path.pc, &tk, t.span);
            self.ov_switch();
        }
        if t.dests_len == 1 {
            self.write_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], r, false);
            if r != NONE && !ghost_callee {
                self.res_of.insert(r, true);
            }
        } else {
            for j in t.dests_start..t.dests_start + t.dests_len {
                self.write_place(b, b.module, &mut path.state, b.dest_pool[j as usize], NONE, false);
            }
        }
        self.st_report(&path.pc, t.span);
        if (ak == AK_ALLOC || ak == AK_REALLOC) && t.dests_len == 1 {
            let rv = self.read_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], false);
            if ak == AK_ALLOC && !self.mi_fresh.contains(&rv) {
                self.mi_fresh.push(rv);
            }
            self.fresh_apart(&mut path.pc, rv);
            self.alloc_of.insert(rv, self.alloc_rec.len() as u32);
            self.alloc_rec.push(ak);
            self.alloc_rec.push(asize);
            self.alloc_rec.push(aold);
            self.alloc_rec.push(adir);
            self.alloc_rec.push(aprod);
        }
        // A reference the callee returns refers to a value that left a body: it satisfies its invariant. Its
        // blocks are its holder's, which may be a value the call lent: none the body may take.
        if t.dests_len == 1 && !self.ghost_fn {
            let dty = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
            let y = *self.ast_of(b.module).type_at(dty);
            if y.kind == TypeKind::TYPE_REFERENCE && self.inv_here(b.module, y.as_data.elem) {
                let rv = self.read_place(b, b.module, &mut path.state, b.dest_pool[t.dests_start as usize], false);
                let v = self.deref(&path.state, rv, b.module, y.as_data.elem);
                let ov0 = replace(&mut self.ov, OV_VALUE);
                let f = self.inv_of(b.module, y.as_data.elem, v, &path.state);
                self.ov = ov0;
                if f != NONE {
                    path.pc.push(f);
                }
            }
        }
        self.inv_called(b, path, t);
        self.ov_end();
        // An atomic operation on a counter field (`ctr_tmp`): the counter's step.
        if !self.ghost_fn && t.args_len != 0 && self.ctr_tmp.len() != 0 {
            let aop = self.atomic_op(t.callee);
            let op0 = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
            if aop != 255 && aop != 9 && op0.kind != ir::OP_CONST && b.places.at(op0.data as usize).proj_len == 0 {
                if let Some(cpl) = self.ctr_tmp.get(&b.places.at(op0.data as usize).base) {
                    let cpi = *cpl;
                    let cplace = *b.places.at(cpi as usize);
                    let (cty, cfi) = self.counter_place(b, b.module, &cplace, false);
                    let cp = self.read_prefix(b, b.module, &mut path.state, &cplace, cplace.proj_len - 2, false);
                    let arg1 = if t.args_len > 1 {
                        self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false)
                    } else {
                        NONE
                    };
                    let arg2 = if t.args_len > 2 {
                        self.operand(b, b.module, &mut path.state, b.oper_pool[(t.args_start + 2) as usize], false)
                    } else {
                        NONE
                    };
                    let tr = self.tm.boolean(true);
                    let (o, n, d, g) = if aop == CS_ADD || aop == CS_SUB {
                        let (w, sg) = (self.tm.at(r).w, self.tm.at(r).sg);
                        (r, self.tm.arith(pick(aop == CS_ADD, T_ADD, T_SUB), r, arg1, w, sg), arg1, tr)
                    } else if aop == CS_CAS {
                        (arg1, arg2, NONE, r)
                    } else {
                        (NONE, arg1, NONE, tr)
                    };
                    self.count_step(
                        b,
                        b.module,
                        &mut path.state,
                        &mut path.pc,
                        cty,
                        cfi,
                        cp,
                        o,
                        n,
                        d,
                        g,
                        aop,
                        t.span,
                        1 << 38 | t.span.start as u64,
                    );
                }
            }
        }
        self.inv_lent(b, path, t);
        // A local the call took by value holds no value: its blocks are the callee's, and no later check
        // reads it. Its invariant names `owns`: a type that holds a block is no `Copy` type.
        if self.inv_locs.len() != 0 && !ghost_callee {
            for j in 0..t.args_len {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                if op.kind == ir::OP_CONST || b.places.at(op.data as usize).proj_len != 0 || self.autoref(
                    b,
                    b.module,
                    t,
                    j,
                ) {
                    continue;
                }
                let l = b.places.at(op.data as usize).base;
                let lt = b.locals.at(l as usize).ty;
                if self.inv_locs.contains(&l) && self.ast_of(b.module).type_at(lt).kind != TypeKind::TYPE_REFERENCE && self.inv_owns(
                    b.module,
                    lt,
                ) {
                    path.state.set(l as usize, NONE);
                }
            }
        }
        // A borrow nothing keeps past the call ends with it: its local is no longer reached.
        if self.borrow_ends(b, t) {
            self.esc.truncate(esc0);
            self.aesc.truncate(aesc0);
        }
    }

    // The cases of `ensures` fact `f` that define the call's pointer result `r` (`r == p`, `g ==> r == p`,
    // parts of a conjunction `depth` deep) where `p` points into a block or an inline array the walk knows
    // (`ptr_target`): `pdef`.
    fn ptr_defs(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, f: u32, r: u32, depth: u32) {
        let x = self.tm.at(f);
        if x.op == T_AND && depth < 4 {
            self.ptr_defs(b, state, x.a, r, depth + 1);
            self.ptr_defs(b, state, x.b, r, depth + 1);
            return;
        }
        // `g ==> r == p`: `!g || r == p`, or `!g || g && r == p` (a short-circuit's form).
        let (g, e) = if x.op == T_OR && self.eq_part(x.b) != NONE {
            (self.tm.not(x.a), self.eq_part(x.b))
        } else if x.op == T_OR && self.eq_part(x.a) != NONE {
            (self.tm.not(x.b), self.eq_part(x.a))
        } else {
            (self.tm.boolean(true), f)
        };
        let ex = self.tm.at(e);
        if ex.op != T_EQ || ex.a != r && ex.b != r {
            return;
        }
        let p = pick(ex.a == r, ex.b, ex.a);
        let (tg, _i, _blk, val) = self.ptr_target(b, state, p, NONE);
        if tg != NONE && val != NONE && self.pdef.len() < 4 {
            self.pdef.push(g as u64 << 32 | p as u64);
        }
    }

    // Equality `f`, or the equality part of conjunction `f`; NONE for another.
    const fn eq_part(self: &Self, f: u32) u32 {
        let x = self.tm.at(f);
        if x.op == T_EQ {
            return f;
        }
        if x.op == T_AND && self.tm.at(x.b).op == T_EQ {
            return x.b;
        }
        if x.op == T_AND && self.tm.at(x.a).op == T_EQ {
            return x.a;
        }
        return NONE;
    }

    // The path after call `t` that defines its pointer result (`pdef`), once per case of its first guard
    // (`g`, `!g`): the result is the case's pointer, and the call's borrow reaches only what it points
    // into (`ptr_target`: a block, `own_exp`; an inline array, `aesc`). A case no `ensures` defines keeps
    // the call's escapes.
    fn ptr_split(self: &mut Self, b: &ir::CoreBody, path: Path, me: u32, t: &ir::Terminator) {
        let defs = replace(&mut self.pdef, Vector::<u64>::new());
        let (e0, a0) = ((self.pdef_esc >> 32) as usize, (self.pdef_esc & 0xFFFFFFFFu64) as usize);
        let g = (defs[0] >> 32) as u32;
        let dest = b.dest_pool[t.dests_start as usize];
        for side in 0..2 {
            if side == 1 && self.tm.is_true(g) {
                break;
            }
            let c = pick(side == 0, g, self.tm.not(g));
            let nc = self.tm.not(c);
            if self.tm.is_false(c) || path.pc.contains(&nc) || !self.tm.is_true(g) && self.holds_within(
                &path.pc,
                nc,
                SPLIT_STEPS,
            ) {
                continue;
            }
            let mut q = path.copy();
            if !self.tm.is_true(c) && !q.pc.contains(&c) {
                q.pc.push(c);
            }
            let mut p = NONE;
            for d in defs.iter() {
                let dg = (*d >> 32) as u32;
                if dg == c || self.tm.is_true(dg) {
                    p = (*d & 0xFFFFFFFFu64) as u32;
                }
            }
            if p != NONE {
                let (tg, _i, blk, _val) = self.ptr_target(b, &q.state, p, NONE);
                if tg != NONE {
                    q.esc.truncate(e0);
                    q.aesc.truncate(a0);
                    if blk {
                        self.own_exp.set(self.ref_target(tg) as usize, true);
                    } else if !q.aesc.contains(&tg) {
                        q.aesc.push(tg);
                    }
                    self.write_place(b, b.module, &mut q.state, dest, p, false);
                }
            }
            self.enter(b, q, me, t.t0);
        }
    }

    // Whether the slot `sl` of a `&mut` parameter is lent in a loop (`lmem` holds its parameter) or was
    // reached before it (`esc`).
    const fn slot_lent(self: &Self, b: &ir::CoreBody, sl: u32, lmem: &Vector<u32>) bool {
        if self.esc.contains(&sl) {
            return true;
        }
        for l in b.returns..b.returns + b.args {
            if self.slot_of[l as usize] == sl && lmem.contains(&l) {
                return true;
            }
        }
        return false;
    }

    // Whether call `t` of body `b` ends every borrow it takes: its results are frozen values, and its
    // arguments but one mutable borrow (an automatic one of a place, or a `&mut`) are constants, frozen
    // values or shared references to them, none of which can hold a reference. The callee then keeps the
    // borrow nowhere: its effect on the borrowed local is the call's own (`call_event`, `param_writes`).
    fn borrow_ends(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        for j in t.dests_start..t.dests_start + t.dests_len {
            if !self.frozen(b.module, b.places.at(b.dest_pool[j as usize] as usize).ty) {
                return false;
            }
        }
        return self.one_borrow(b, t);
    }

    // Whether `v`, an argument of call `t`, refers to the referent of a `&mut` parameter of body `b` and
    // the call's results hold no reference. The parameter is live while the body runs, and no other path
    // may reach its referent while it is: no pointer the callee keeps reaches it after the call.
    fn param_reborrow(self: &Self, b: &ir::CoreBody, t: &ir::Terminator, v: u32) bool {
        if v == NONE || self.tm.at(v).op != T_MREF && self.tm.at(v).op != T_PREF || self.ref_target(v) as usize < b.locals.len() {
            return false;
        }
        for j in t.dests_start..t.dests_start + t.dests_len {
            if !self.holds_no_borrow(b.module, b.places.at(b.dest_pool[j as usize] as usize).ty) {
                return false;
            }
        }
        return true;
    }

    // Whether the arguments of call `t` but one mutable borrow are constants, frozen values or shared
    // references to them (`borrow_ends`).
    fn one_borrow(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let mut muts: u32 = 0;
        for j in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            if op.kind == ir::OP_CONST || op.ty == TYPE_NONE || self.frozen(b.module, op.ty) {
                continue;
            }
            let y = *self.ast_of(b.module).type_at(op.ty);
            if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && self.frozen(
                b.module,
                y.as_data.elem,
            ) {
                continue;
            }
            if self.autoref(b, b.module, t, j) || y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                muts += 1;
                continue;
            }
            // A value of a type parameter of a callee that names no lifetime: computed before the call,
            // it holds no borrow the call takes, and no signature lets the callee put one in it.
            if self.generic_value_param(t.callee, j) {
                continue;
            }
            return false;
        }
        return muts <= 1;
    }

    // Whether parameter `j` of function `d` is a value of a type parameter (`value: T`) and neither `d` nor
    // its extend declares a lifetime.
    fn generic_value_param(self: &Self, d: DefId, j: u32) bool {
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION || a.lifetimes_of(d.node).len != 0 {
            return false;
        }
        let c = a.container_of(d.node);
        if c != NODE_NONE && a.lifetimes_of(c).len != 0 {
            return false;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return false;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        return pt != TYPE_NONE && a.type_at(pt).kind == TypeKind::TYPE_GENERIC;
    }

    // Struct literal `rv` of body `cb` with members `xs` (value `agg`): the block of each `@owned` field is
    // the one its pointer holds (`own_after`).
    // Whether `ty` (module `m`) is a union.
    fn is_union_ty(self: &Self, m: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.ast_of(m).type_at(ty);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(m, ty);
        return dn != NODE_NONE && self.pkg().modules.at(dm as usize).has_ast && self.ast_of(dm).at_const(dn).kind == NodeKind::NODE_STRUCT && unsafe self.ast_of(
            dm,
        ).ext(dn).aggregate.is_union;
    }

    // The unsigned integer leaves of a value of type `ty` (module `m`) at byte `off` of a union, with the
    // member keys `keys` before them: a builtin unsigned integer, the elements of an array of them, the
    // members of a struct. A pointer, a signed integer or another type is no leaf: its bytes make no
    // fact. At most UNION_LEAVES leaves.
    fn union_leaves(
        self: &mut Self,
        m: ModuleId,
        ty: TypeId,
        off: i64,
        keys: &mut Vector<u32>,
        pool: &mut Vector<u32>,
        out: &mut Vector<UnionLeaf>,
        depth: u32,
    ) {
        if ty == TYPE_NONE || off < 0 || depth > 4 || out.len() >= UNION_LEAVES {
            return;
        }
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let (w, sg) = self.ty_of(rm, rt);
            let l = self.lsv.layout(rm, rt);
            if sg || w <= W_BOOL || exact_w(w) || !l.ok || l.size * 8 != w as u64 {
                return;
            }
            let k0 = pool.len() as u32;
            pool.extend_copy(keys);
            out.push(UnionLeaf { off: off, size: l.size as u32, w: w, k0: k0, kn: keys.len() as u32 });
            return;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let n = self.array_len(rm, rt);
            let el = self.lsv.layout(rm, y.as_data.arr.elem);
            if n < 0 || n > UNION_LEAVES as i64 || !el.ok {
                return;
            }
            for k in 0..n {
                keys.push(self.tm.int(wide::<B>(k), 64, false));
                self.union_leaves(rm, y.as_data.arr.elem, off + k * el.size as i64, keys, pool, out, depth + 1);
                let _ = keys.pop();
            }
            return;
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE || self.is_union_ty(rm, rt) {
            return;
        }
        let (dm, dn) = self.decl_of(rm, rt);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return;
        }
        let mut mtys = Vector::<u64>::new();
        self.member_types(rm, rt, &mut mtys);
        let ms = self.ast_of(dm).ext(dn).aggregate.members;
        for j in 0..ms.len.min(mtys.len() as u32) {
            let f = unsafe self.ast_of(dm).list(ms)[j as usize];
            let fo = self.lsv.field_offset(rm, rt, f);
            if fo < 0 {
                continue;
            }
            keys.push(self.tm.int(wide::<B>(j), 64, false));
            let mt = mtys[j as usize];
            self.union_leaves(
                (mt >> 32) as ModuleId,
                (mt & 0xFFFFFFFFu64) as TypeId,
                off + fo,
                keys,
                pool,
                out,
                depth + 1,
            );
            let _ = keys.pop();
        }
    }

    // The leaf `l` of union value `u`: its members' selections.
    fn leaf_term(self: &mut Self, u: u32, l: &UnionLeaf, pool: &Vector<u32>) u32 {
        let mut v = u;
        for q in 0..l.kn {
            let last = q + 1 == l.kn;
            v = self.sel(v, pool[(l.k0 + q) as usize], pick(last, l.w, W_OTHER), false);
        }
        return v;
    }

    // Union value `u` of type `ty` (module `m`) holds one set of bytes: an unsigned integer leaf of one
    // member whose bytes one integer leaf of another member holds is those bytes, little-endian (every
    // target's order). Facts anchored on the leaves, made once for `u` (`cohd`).
    fn union_coherence(self: &mut Self, m: ModuleId, ty: TypeId, u: u32) {
        if u == NONE || self.cohd.contains_key(&u) || !self.is_union_ty(m, ty) {
            return;
        }
        self.cohd.insert(u, true);
        let (dm, dn) = self.decl_of(m, ty);
        let mut mtys = Vector::<u64>::new();
        self.member_types(m, ty, &mut mtys);
        let nm = self.ast_of(dm).ext(dn).aggregate.members.len.min(mtys.len() as u32);
        let mut pool = Vector::<u32>::new();
        let mut keys = Vector::<u32>::new();
        // The leaves of each member, [starts[j], starts[j + 1]).
        let mut leaves = Vector::<UnionLeaf>::new();
        let mut starts = Vector::<u32>::new();
        for j in 0..nm {
            starts.push(leaves.len() as u32);
            keys.push(self.tm.int(wide::<B>(j), 64, false));
            let mt = mtys[j as usize];
            self.union_leaves(
                (mt >> 32) as ModuleId,
                (mt & 0xFFFFFFFFu64) as TypeId,
                0,
                &mut keys,
                &mut pool,
                &mut leaves,
                0,
            );
            let _ = keys.pop();
        }
        starts.push(leaves.len() as u32);
        for t in 0..nm {
            for s in 0..nm {
                if s == t {
                    continue;
                }
                for li in starts[t as usize]..starts[(t + 1) as usize] {
                    let l = leaves[li as usize];
                    let lt = self.leaf_term(u, &l, &pool);
                    let mut acc = NONE;
                    let mut covered = true;
                    // The bytes of one leaf of the other member: a leaf that several hold is fixed by
                    // their facts, each a part of it (one fact per narrower leaf, not one per pair).
                    let mut src0 = NONE;
                    for b in 0..l.size as i64 {
                        let at = l.off + b;
                        let mut src = NONE;
                        for si in starts[s as usize]..starts[(s + 1) as usize] {
                            let x = leaves[si as usize];
                            if x.off <= at && at < x.off + x.size as i64 {
                                src = si;
                                break;
                            }
                        }
                        if src == NONE || src0 != NONE && src != src0 {
                            covered = false;
                            break;
                        }
                        src0 = src;
                        let x = leaves[src as usize];
                        // The whole leaf at once where it is the source's.
                        if b == 0 && x.off == l.off && x.size == l.size {
                            acc = self.leaf_term(u, &x, &pool);
                            break;
                        }
                        let xt = self.leaf_term(u, &x, &pool);
                        let shifted = if at == x.off {
                            xt
                        } else {
                            let sh = self.tm.int(wide::<B>(8 * (at - x.off)), x.w, false);
                            self.tm.arith(T_SHR, xt, sh, x.w, false)
                        };
                        let byte = if x.w == 8 {
                            shifted
                        } else {
                            self.tm.unary(T_CAST, shifted, 8, false)
                        };
                        let wide_b = if l.w == 8 {
                            byte
                        } else {
                            self.tm.unary(T_CAST, byte, l.w, false)
                        };
                        let piece = if b == 0 {
                            wide_b
                        } else {
                            let k = self.tm.int(wide::<B>(8 * b), l.w, false);
                            self.tm.arith(T_SHL, wide_b, k, l.w, false)
                        };
                        acc = if acc == NONE {
                            piece
                        } else {
                            self.tm.arith(T_BOR, acc, piece, l.w, false)
                        };
                    }
                    // On the leaf: a read of it names that term, which may not name `u` (a member's write
                    // folds away the union value of a read of another).
                    if covered && acc != NONE {
                        let e = self.tm.cmp(T_EQ, lt, acc);
                        self.anchor(lt, e);
                    }
                }
            }
        }
    }

    fn literal_blocks(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, rv: &ir::Rvalue, xs: &Vector<u32>, agg: u32) u32 {
        let y = *self.ast_of(cm).type_at(rv.target);
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return agg;
        }
        let (dm, dn) = self.decl_of(cm, rv.target);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return agg;
        }
        let ms = self.ast_of(dm).ext(dn).aggregate.members;
        let mut out = agg;
        for j in 0..ms.len {
            let f = unsafe self.ast_of(dm).list(ms)[j as usize];
            if j as usize >= xs.len() || self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) == null {
                continue;
            }
            let o = cb.oper_pool[(rv.a + j) as usize];
            if o == ir::IR_NONE {
                continue;
            }
            let pt = *self.ast_of(cm).type_at(cb.operands.at(o as usize).ty);
            let et = pick(pt.kind == TypeKind::TYPE_POINTER, pt.as_data.elem, TYPE_NONE);
            let k = self.tm.int(wide::<B>(j) + Num::<B>::one().shl(41), 64, false);
            let no = self.own_after(cm, et, xs[j as usize]);
            out = self.tm.upd(out, k, no);
        }
        return out;
    }

    // The block of the `@owned` field whose pointer is `pv`, among the members of the locals and slots of
    // body `b` in `state` (also of their members, `owned_path`); NONE where none holds it.
    fn block_of_ptr(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pv: u32, et: &mut TypeId) u32 {
        for l in 0..state.len() - 1 {
            let v = state[l];
            if v == NONE {
                continue;
            }
            let ty = if l < b.locals.len() {
                b.locals.at(l).ty
            } else {
                self.slot_ty[l - b.locals.len()]
            };
            let y = *self.ast_of(b.module).type_at(ty);
            if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
                continue;
            }
            let (dm, dn) = self.decl_of(b.module, ty);
            if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
                continue;
            }
            let ms = self.ast_of(dm).ext(dn).aggregate.members;
            for j in 0..ms.len {
                let f = unsafe self.ast_of(dm).list(ms)[j as usize];
                if self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) == null {
                    continue;
                }
                let fk = self.tm.int(wide::<B>(j), 64, false);
                if self.tm.sel(v, fk, W_OTHER, false) == pv {
                    let ft = self.ast_of(dm).type_of(f);
                    let fy = *self.ast_of(dm).type_at(ft);
                    *et = TYPE_NONE;
                    if fy.kind == TypeKind::TYPE_POINTER {
                        // The element type in the body's terms: a type parameter of the struct is the value's
                        // type argument.
                        let e = fy.as_data.elem;
                        let ey = *self.ast_of(dm).type_at(e);
                        if ey.kind == TypeKind::TYPE_GENERIC && y.kind == TypeKind::TYPE_INSTANCE {
                            let it = *self.ast_of(b.module).instance(y.as_data.inst);
                            let gs = self.ast_of(dm).ext(dn).aggregate.generics;
                            for g in 0..gs.len {
                                if unsafe self.ast_of(dm).list(gs)[g as usize] == ey.as_data.decl && g < it.n as u32 {
                                    *et = it.args[g as usize];
                                }
                            }
                        } else if dm == b.module {
                            *et = e;
                        }
                    }
                    let ok = self.tm.int(wide::<B>(j) + Num::<B>::one().shl(41), 64, false);
                    return self.sel(v, ok, W_OTHER, false);
                }
            }
        }
        // A field of a member (a union's too: `owned_path`), of the body's own module.
        for l in 0..state.len() - 1 {
            let v = state[l];
            if v == NONE {
                continue;
            }
            let ty = if l < b.locals.len() {
                b.locals.at(l).ty
            } else {
                self.slot_ty[l - b.locals.len()]
            };
            let mut keys = Vector::<u32>::new();
            let mut tys = Vector::<TypeId>::new();
            let mut kms = Vector::<ModuleId>::new();
            if self.owned_path(b.module, ty, v, pv, NONE, 0, &mut keys, &mut tys, &mut kms) {
                let n = tys.len() - 1;
                let (rm, rt) = self.resolve(kms[n], tys[n]);
                *et = pick(rm == b.module, self.ast_of(rm).type_at(rt).as_data.elem, TYPE_NONE);
                return self.path_val(v, &keys, &tys, &kms);
            }
        }
        return NONE;
    }

    // A reference entry (`T_PREF`) to local or slot `tg` (type `tgty`, module `m`) through member keys
    // `keys` of types `tys` (modules `kms`).
    fn pref_make(
        self: &mut Self,
        m: ModuleId,
        tg: u32,
        tgty: TypeId,
        keys: &Vector<u32>,
        tys: &Vector<TypeId>,
        kms: &Vector<ModuleId>,
    ) u32 {
        let start = self.pref_key.len() as u32;
        for q in 0..keys.len() {
            self.pref_key.push(keys[q]);
            self.pref_ty.push(tys[q]);
            self.pref_km.push(kms[q]);
        }
        return self.pref_new(start, tg, tgty, m);
    }

    // The `@owned` field of value `v` (type `ty`, module `m`) whose value is pointer `pv` to elements of
    // `es` bytes (NONE: any), at most PTR_DEPTH aggregates down: the keys of its path, their types and the types'
    // modules pushed on `keys`, `tys` and `kms`, the block's key last. False where none is.
    fn owned_path(
        self: &mut Self,
        m: ModuleId,
        ty: TypeId,
        v: u32,
        pv: u32,
        es: u32,
        depth: u32,
        keys: &mut Vector<u32>,
        tys: &mut Vector<TypeId>,
        kms: &mut Vector<ModuleId>,
    ) bool {
        if depth >= PTR_DEPTH || !self.holds_owned(m, ty, 0) {
            return false;
        }
        let (dm, dn) = self.decl_of(m, ty);
        let ms = self.ast_of(dm).ext(dn).aggregate.members;
        let mut mts = Vector::<u64>::new();
        self.member_types(m, ty, &mut mts);
        for j in 0..ms.len {
            if j as usize >= mts.len() {
                break;
            }
            let f = unsafe self.ast_of(dm).list(ms)[j as usize];
            let (fm, ft) = ((mts[j as usize] >> 32) as ModuleId, (mts[j as usize] & 0xFFFFFFFFu64) as TypeId);
            let key = self.tm.int(wide::<B>(j), 64, false);
            let (w, sg) = self.ty_of(fm, ft);
            let mv = self.tm.sel(v, key, w, sg);
            if self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) != null {
                let (rm, rt) = self.resolve(fm, ft);
                let fy = *self.ast_of(rm).type_at(rt);
                if mv == pv && fy.kind == TypeKind::TYPE_POINTER && (es == NONE || self.size_term(rm, fy.as_data.elem) == es) {
                    keys.push(self.tm.int(wide::<B>(j) + Num::<B>::one().shl(41), 64, false));
                    tys.push(ft);
                    kms.push(fm);
                    return true;
                }
                continue;
            }
            keys.push(key);
            tys.push(ft);
            kms.push(fm);
            if self.owned_path(fm, ft, mv, pv, es, depth + 1, keys, tys, kms) {
                return true;
            }
            keys.pop();
            tys.pop();
            kms.pop();
        }
        return false;
    }

    // What raw pointer value `pv` points into on this path, for elements of `es` bytes: a reference to the
    // block of the `@owned` field whose value it is (`owned_path`), or to the inline array whose element's
    // address it is (the element's `T_PREF`, cast); the index there, a 64-bit key, after its offsets
    // (`ptr_offset`) in elements of `es` bytes; whether it is a block; and its value. The reference is
    // NONE for a block a shared reference reaches (no write goes through it); all are NONE for another
    // pointer.
    fn ptr_target(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pv: u32, es: u32) (u32, u32, bool, u32) {
        let mut offs = Vector::<u32>::new();
        let p = self.ptr_base(pv, es, &mut offs);
        let x = self.tm.at(p);
        let mut r = NONE;
        let mut val = NONE;
        let mut idx = self.tm.int(Num::<B>::zero(), 64, false);
        let mut blk = false;
        if x.op == T_PREF {
            let e = x.a as usize;
            let n = self.pref_n[e];
            if n >= 2 {
                let (am, aty) = self.pref_cty(e, n - 1);
                let (m1, t1) = self.resolve(am, aty);
                let ay = *self.ast_of(m1).type_at(t1);
                if ay.kind == TypeKind::TYPE_ARRAY && !ay.arr_sym() && (es == NONE || self.size_term(
                    m1,
                    ay.as_data.arr.elem,
                ) == es) {
                    idx = self.pref_key[(self.pref_at[e] + n - 1) as usize];
                    r = self.pref_array(p);
                }
            }
        } else if x.op != T_MREF && x.op != T_REF {
            for l in 0..state.len() - 1 {
                let v = state[l];
                if v == NONE {
                    continue;
                }
                let ty = if l < b.locals.len() {
                    b.locals.at(l).ty
                } else {
                    self.slot_ty[l - b.locals.len()]
                };
                let mut keys = Vector::<u32>::new();
                let mut tys = Vector::<TypeId>::new();
                let mut kms = Vector::<ModuleId>::new();
                // A shared reference's value: its block is read only.
                let vx = self.tm.at(v);
                let yt = *self.ast_of(b.module).type_at(ty);
                if yt.kind == TypeKind::TYPE_REFERENCE && yt.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 && vx.op != T_MREF && vx.op != T_PREF {
                    let rv = if vx.op == T_REF {
                        vx.a
                    } else {
                        self.deref(state, v, b.module, yt.as_data.elem)
                    };
                    if self.owned_path(b.module, yt.as_data.elem, rv, p, es, 0, &mut keys, &mut tys, &mut kms) {
                        val = self.path_val(rv, &keys, &tys, &kms);
                        blk = true;
                        break;
                    }
                    continue;
                }
                if self.owned_path(b.module, ty, v, p, es, 0, &mut keys, &mut tys, &mut kms) {
                    r = self.pref_make(b.module, l as u32, ty, &keys, &tys, &kms);
                    blk = true;
                    break;
                }
            }
        }
        if r != NONE {
            val = self.ref_get(state, r);
        }
        if val == NONE {
            return NONE, NONE, false, NONE;
        }
        // An array as the term it was read from, not the aggregate of its members (`eta`): a copy or a
        // write of a few of its elements names that one term.
        if let Some(src) = self.eta_src.get(&val) {
            val = *src;
        }
        return r, self.add_offs(idx, &offs), blk, val;
    }

    // Member path `keys` (types `tys` of modules `kms`) of value `v`.
    fn path_val(self: &mut Self, v: u32, keys: &Vector<u32>, tys: &Vector<TypeId>, kms: &Vector<ModuleId>) u32 {
        let mut x = v;
        for q in 0..keys.len() {
            let (w, sg) = self.ty_of(kms[q], tys[q]);
            x = self.sel(x, keys[q], w, sg);
        }
        return x;
    }

    // Pointer `pv` without its offsets (`ptr_offset`) in elements of `es` bytes (NONE: any), which go on
    // `offs`.
    fn ptr_base(self: &Self, pv: u32, es: u32, offs: &mut Vector<u32>) u32 {
        let add = u64_val::<B>(skey_mix(16, T_ADD));
        let mut p = pv;
        for _d in 0..PTR_DEPTH {
            let x = self.tm.at(p);
            if x.op != T_CALL || x.k != add || x.b != 3 || es != NONE && self.tm.args[(x.a + 2) as usize] != es {
                break;
            }
            offs.push(self.tm.args[(x.a + 1) as usize]);
            p = self.tm.args[x.a as usize];
        }
        return p;
    }

    // Index key `k` (a sum of keys, `add_offs`) as an `int`: the sum of its parts, which is its value where
    // it is below 2^64 (a fact anchored on `k`; the bounds checks of the index use the `int`).
    fn key_int(self: &mut Self, k: u32) u32 {
        let x = self.tm.at(k);
        // The key of a narrower unsigned index (`index_key`): the index's value.
        if x.op == T_CAST && x.w == 64 && !x.sg && !self.tm.at(x.a).sg && self.tm.at(x.a).w < 64 {
            return self.widened(x.a, W_INT, true);
        }
        // A difference of keys: its value where it does not wrap, a fact anchored on `k`.
        if x.op == T_SUB && x.w == 64 && !x.sg {
            let wk = self.widened(k, W_INT, true);
            let a = self.key_int(x.a);
            let b = self.key_int(x.b);
            if wk != NONE && a != NONE && b != NONE && !self.seld.contains_key(&k) {
                self.seld.insert(k, true);
                let d = self.tm.arith(T_SUB, a, b, W_INT, true);
                let wraps = self.tm.cmp(T_LT, a, b);
                let e = self.tm.cmp(T_EQ, wk, d);
                let f = self.tm.or(wraps, e);
                self.anchor(k, f);
            }
            return wk;
        }
        if x.op != T_ADD || x.w != 64 || x.sg {
            return self.widened(k, W_INT, true);
        }
        let a = self.key_int(x.a);
        let b = self.key_int(x.b);
        if a == NONE || b == NONE {
            return NONE;
        }
        let s = self.tm.arith(T_ADD, a, b, W_INT, true);
        if !self.seld.contains_key(&k) {
            self.seld.insert(k, true);
            let wk = self.widened(k, W_INT, true);
            if wk != NONE {
                let top = self.tm.int(Num::<B>::one().shl(64), W_INT, true);
                let big = self.tm.cmp(T_LE, top, s);
                let e = self.tm.cmp(T_EQ, wk, s);
                let f = self.tm.or(big, e);
                self.anchor(k, f);
            }
        }
        return s;
    }

    // Index key `idx` moved by offsets `offs`.
    fn add_offs(self: &mut Self, idx: u32, offs: &Vector<u32>) u32 {
        let mut k = idx;
        for j in 0..offs.len() {
            let o = self.index_key(offs[j]);
            k = self.tm.arith(T_ADD, k, o, 64, false);
        }
        return k;
    }

    // The bytes raw pointer `pv` points at, for elements of `es` bytes, as a sequence and the index of
    // the first: a block's or an inline array's (`ptr_target`), or the view of the slice or `str` whose
    // pointer member it is (after offsets); NONE, NONE for another pointer.
    fn src_bytes(self: &mut Self, b: &ir::CoreBody, state: &Vector<u32>, pv: u32, es: u32) (u32, u32) {
        let (r, idx, blk, old) = self.ptr_target(b, state, pv, es);
        if old != NONE {
            return self.target_seq(b, r, old, blk), idx;
        }
        let mut offs = Vector::<u32>::new();
        let p = self.ptr_base(pv, es, &mut offs);
        let x = self.tm.at(p);
        if x.op != T_SEL || !self.tm.is_int(x.b) || self.tm.at(x.b).op != T_INT || !self.tm.at(x.b).k.is_zero() {
            return NONE, NONE;
        }
        for l in 0..state.len() - 1 {
            if state[l] != x.a {
                continue;
            }
            let ty = if l < b.locals.len() {
                b.locals.at(l).ty
            } else {
                self.slot_ty[l - b.locals.len()]
            };
            let (dm, dd) = self.decl_of(b.module, ty);
            let z = self.tm.int(Num::<B>::zero(), 64, false);
            if self.is_slice_ty(b.module, ty) {
                let ep = self.slice_ep(b.module, ty, state);
                return self.view_s(x.a, ep), self.add_offs(z, &offs);
            }
            if dd != NODE_NONE && dm == self.strv.mid && dd == self.strv.node {
                return self.view_v(x.a), self.add_offs(z, &offs);
            }
        }
        return NONE, NONE;
    }

    // The block of allocator result `v` no field holds yet (`pend`), NONE for none.
    const fn pend_get(self: &Self, v: u32) u32 {
        for j in 0..self.pend.len() {
            if (self.pend[j] >> 32) as u32 == v {
                return (self.pend[j] & 0xFFFFFFFFu64) as u32;
            }
        }
        return NONE;
    }

    fn pend_set(self: &mut Self, v: u32, blk: u32) {
        for j in 0..self.pend.len() {
            if (self.pend[j] >> 32) as u32 == v {
                self.pend.set(j, v as u64 << 32 | blk as u64);
                return;
            }
        }
        self.pend.push(v as u64 << 32 | blk as u64);
    }

    // The block of allocator result `pv` (after offsets in bytes), which no field holds yet, of elements
    // of type `et` (module `m`, of one byte): its pointer and block (`own_after` the first time); NONE,
    // NONE for another pointer.
    fn pend_target(self: &mut Self, m: ModuleId, et: TypeId, pv: u32, offs: &mut Vector<u32>) (u32, u32) {
        let one = self.tm.int(Num::<B>::one(), self.pw, false);
        let p = self.ptr_base(pv, one, offs);
        if !self.alloc_of.contains_key(&p) || et == TYPE_NONE || self.size_term(m, et) != one {
            return NONE, NONE;
        }
        let pb = self.pend_get(p);
        if pb != NONE {
            return p, pb;
        }
        return p, self.own_after(m, et, p);
    }

    // Call `t` of `memcpy`, `memmove` or `memset` (`Terminator.intr`) whose destination points into a
    // block or an inline array (`ptr_target`): its `n` bytes there become the source's (`src_bytes`;
    // unknown ones for another source and for `memset`) and the others stay, with no memory event; the
    // ranges are checked inside their sequences. False for another destination.
    fn mem_copy(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) bool {
        if t.args_len != 3 || t.intr != ir::CI_MEMCPY && t.intr != ir::CI_MEMMOVE && t.intr != ir::CI_MEMSET {
            return false;
        }
        let cm = b.module;
        let one = self.tm.int(Num::<B>::one(), self.pw, false);
        let dst = self.operand(b, cm, &mut path.state, b.oper_pool[t.args_start as usize], false);
        let (r0, idx0, blk0, old0) = self.ptr_target(b, &path.state, dst, one);
        // Else the block of an allocator's result no field holds yet (`pend`).
        let mut pp = NONE;
        let (r, idx, blk, old) = if r0 != NONE {
            (r0, idx0, blk0, old0)
        } else {
            let dty = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
            let (rm, rt) = self.resolve(cm, dty);
            let dy = *self.ast_of(rm).type_at(rt);
            let et = pick(dy.kind == TypeKind::TYPE_POINTER, dy.as_data.elem, TYPE_NONE);
            let mut offs = Vector::<u32>::new();
            let (p, pb) = self.pend_target(rm, et, dst, &mut offs);
            if pb == NONE {
                return false;
            }
            pp = p;
            let z = self.tm.int(Num::<B>::zero(), 64, false);
            (NONE, self.add_offs(z, &offs), true, pb)
        };
        let src = if t.intr == ir::CI_MEMSET {
            NONE
        } else {
            self.operand(b, cm, &mut path.state, b.oper_pool[(t.args_start + 1) as usize], false)
        };
        let n0 = self.operand(b, cm, &mut path.state, b.oper_pool[(t.args_start + 2) as usize], false);
        let n = self.index_key(n0);
        let (ss, si) = if src == NONE {
            (NONE, NONE)
        } else {
            self.src_bytes(b, &path.state, src, one)
        };
        let ds = self.target_seq(b, r, old, blk);
        let dn = self.seq_len(ds);
        let wi = self.key_int(idx);
        let wn = self.key_int(n);
        if wi == NONE || wn == NONE {
            return false;
        }
        let hi = self.tm.arith(T_ADD, wi, wn, W_INT, true);
        let mut g = self.tm.cmp(T_LE, hi, dn);
        let mut part = NONE;
        if ss != NONE {
            let wsi = self.key_int(si);
            if wsi != NONE {
                let shi = self.tm.arith(T_ADD, wsi, wn, W_INT, true);
                let sn = self.seq_len(ss);
                let gs = self.tm.cmp(T_LE, shi, sn);
                g = self.tm.and(g, gs);
                part = self.sub_seq(ss, wsi, shi);
            }
        }
        self.oblige(
            &path.pc,
            g,
            OB_BLOCK << 56 | 1 << 40 | t.span.start as u64,
            t.span,
            format("cannot prove that the bytes of this copy are inside the block or the array they are in"),
            String::from_str("its destination and its source must hold the bytes it names"),
        );
        path.pc.push(g);
        if part == NONE {
            part = self.tm.var(W_OTHER, false);
            let pn = self.seq_len(part);
            let f = self.tm.cmp(T_EQ, pn, wn);
            self.anchor(part, f);
        }
        let nv = if blk {
            let z = self.tm.int(Num::<B>::zero(), W_INT, true);
            let head = self.sub_seq(ds, z, wi);
            let tail = self.sub_seq(ds, hi, dn);
            let hp = self.cat_seq(head, part);
            self.cat_seq(hp, tail)
        } else {
            let mut xs = Vector::<u32>::new();
            xs.push(old);
            xs.push(idx);
            xs.push(part);
            xs.push(n);
            self.tm.call(skey_mix(19, 0), &xs, W_OTHER, false)
        };
        if pp != NONE {
            self.pend_set(pp, nv);
        } else {
            self.ref_set(b, &mut path.state, r, nv);
        }
        if t.dests_len == 1 {
            self.write_place(b, cm, &mut path.state, b.dest_pool[t.dests_start as usize], dst, false);
        }
        return true;
    }

    // Target `r` of a pointer (`ptr_target`; `blk`: a block) holding `old`, as a sequence: the block, or
    // the array's view.
    fn target_seq(self: &mut Self, b: &ir::CoreBody, r: u32, old: u32, blk: bool) u32 {
        if blk {
            return old;
        }
        let (rm, rt) = self.ref_ty(b, r);
        let (m1, t1) = self.resolve(rm, rt);
        let mut xs = Vector::<u32>::new();
        xs.push(old);
        xs.push(self.tm.int(wide::<B>(self.array_len(m1, t1)), W_NAT, false));
        return self.seq_make(SQ_VIEWA, &xs);
    }

    // Element `i` (NONE: 0) of what raw pointer `pv` points into (`ptr_target`), of type `ty` (module
    // `m`): the reference to the block or the array, the element's key, whether a block, and the old
    // value; its bounds check queued (`own_chk`). NONE where `pv` has no target, or none a write
    // (`write`) changes.
    fn ptr_elem(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &Vector<u32>,
        pv: u32,
        i: u32,
        m: ModuleId,
        ty: TypeId,
        write: bool,
    ) (u32, u32, bool, u32) {
        let es = self.size_term(m, ty);
        let (r, idx, blk, old) = self.ptr_target(b, state, pv, es);
        if old == NONE || write && r == NONE {
            return NONE, NONE, false, NONE;
        }
        let k = if i == NONE {
            idx
        } else {
            let ki = self.index_key(i);
            self.tm.arith(T_ADD, idx, ki, 64, false)
        };
        let sq = self.target_seq(b, r, old, blk);
        let ki = self.key_int(k);
        self.own_chk.push(pick(ki != NONE, ki, k));
        self.own_chk.push(sq);
        self.own_chk.push(es);
        return r, k, blk, old;
    }

    // A write of `v` (NONE: unknown) of type `ty` to element `i` (NONE: 0) of what raw pointer `pv`
    // points into (`ptr_elem`): that element of the block or the array, no memory event. False where `pv`
    // has no target.
    fn ptr_write(
        self: &mut Self,
        b: &ir::CoreBody,
        cm: ModuleId,
        state: &mut Vector<u32>,
        pv: u32,
        i: u32,
        v: u32,
        ty: TypeId,
    ) bool {
        // An iteration of a loop (`havoc_write`): any element, its block's length kept.
        if self.havoc_idx {
            let es = self.size_term(cm, ty);
            let (r, _idx, blk, old) = self.ptr_target(b, state, pv, es);
            if r == NONE {
                return false;
            }
            let nv = if blk {
                self.same_len(old)
            } else {
                let (rm, rt) = self.ref_ty(b, r);
                self.fresh_in(rm, rt, self.pref_union(r))
            };
            self.ref_set(b, state, r, nv);
            return true;
        }
        let (r, k, blk, old) = self.ptr_elem(b, state, pv, i, cm, ty, true);
        if r == NONE {
            return false;
        }
        let x = if v == NONE {
            self.fresh(cm, ty)
        } else {
            v
        };
        let nv = if blk {
            let mut xs = Vector::<u32>::new();
            xs.push(old);
            xs.push(k);
            xs.push(x);
            self.seq_make(SQ_UPD, &xs)
        } else {
            self.tm.upd(old, k, x)
        };
        self.leak(x);
        self.ref_set(b, state, r, nv);
        return true;
    }

    // A load of element `i` (NONE: 0), of type `ty`, of what raw pointer `pv` points into (`ptr_elem`);
    // NONE where `pv` has no target.
    fn ptr_read(self: &mut Self, b: &ir::CoreBody, cm: ModuleId, state: &Vector<u32>, pv: u32, i: u32, ty: TypeId) u32 {
        let (_r, k, blk, old) = self.ptr_elem(b, state, pv, i, cm, ty, false);
        if old == NONE {
            return NONE;
        }
        let (w, sg) = self.ty_of(cm, ty);
        let v = if blk {
            self.seq_at(old, k, w, sg)
        } else {
            self.sel(old, k, w, sg)
        };
        return pick(w == W_OTHER, self.eta(cm, ty, v, 0), v);
    }

    // The memory event of call `t` (`call_event`). An allocator's (`ak`) keeps the blocks (the allocator
    // writes none another value holds), and so does a call that changes only its receiver place `recv`
    // (else NONE), which reaches no memory: it takes a new value.
    fn alloc_event(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator, ak: u32, recv: u32) {
        self.keep_own = ak != AK_NONE || recv != NONE;
        self.skip_recv = recv != NONE;
        // The statics of this file before the call: an allocator of another file writes none of them.
        let keep_st = self.keep_own && t.callee.node != NODE_NONE && t.callee.module != b.module;
        let sv = self.st_save(&path.state, !keep_st);
        // The structs the path wrote through a pointer, open past the call (`mi_alloc_open`): the C heap
        // writes no block but the ones it gives and takes back.
        let mut dv = Vector::<u32>::new();
        if ak != AK_NONE && self.global_alloc(b, t) {
            for q in 0..self.mi_dirty.len() / 3 {
                let (r, m, ty) = (self.mi_dirty[3 * q], self.mi_dirty[3 * q + 1] as ModuleId, self.mi_dirty[3 * q + 2]);
                dv.push(self.deref(&path.state, r, m, ty));
            }
        }
        self.call_event(b, path, t);
        if dv.len() != 0 {
            let ep = path.state[path.state.len() - 1];
            for q in 0..dv.len() {
                let (r, m, ty) = (self.mi_dirty[3 * q], self.mi_dirty[3 * q + 1] as ModuleId, self.mi_dirty[3 * q + 2]);
                let (w, sg) = self.ty_of(m, ty);
                let now = self.tm.make(Term::<B> { k: Num::<B>::zero(), a: r, b: ep, op: T_LOAD, w: w, sg: sg });
                if now != dv[q] {
                    self.mi_fwd.insert(now, dv[q]);
                }
            }
        }
        self.skip_recv = false;
        self.keep_own = false;
        if recv != NONE {
            let v = self.fresh(b.module, b.places.at(recv as usize).ty);
            self.write_place(b, b.module, &mut path.state, recv, v, false);
        }
        self.st_carry(b.module, &path.state, &sv);
    }

    // Whether the first `n` projections of place `pl` of body `b` are a path of fields of a local, or of the
    // target of a `&mut` parameter.
    fn field_path(self: &Self, b: &ir::CoreBody, pl: &ir::Place, n: u32) bool {
        if n == 0 {
            return false;
        }
        for k in 0..n {
            let pj = *b.projections.at((pl.proj_start + k) as usize);
            if pj.kind == ir::PJ_FIELD && pj.data != ir::PJ_UNION_FIELD {
                continue;
            }
            let y = *self.ast_of(b.module).type_at(b.locals.at(pl.base as usize).ty);
            if pj.kind == ir::PJ_DEREF && k == 0 && pl.base >= b.returns && pl.base < b.returns + b.args && y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                continue;
            }
            return false;
        }
        return true;
    }

    // Whether call `t` borrows one owned element as its receiver (`owned_elem`) and nothing it keeps
    // (`borrow_ends`): it changes that element alone.
    fn elem_call(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind != ir::TM_CALL || t.args_len == 0 || !self.autoref(b, b.module, t, 0) {
            return false;
        }
        let op0 = *b.operands.at(b.oper_pool[t.args_start as usize] as usize);
        return self.owned_elem(b, b.places.at(op0.data as usize)) && self.borrow_ends(b, t);
    }

    // Whether place `pl` of body `b` is an element of the block of an `@owned` field, through a path of
    // fields (`field_path`): a borrow of it reaches that element alone.
    fn owned_elem(self: &Self, b: &ir::CoreBody, pl: &ir::Place) bool {
        return pl.proj_len >= 2 && self.ptr_index(b, b.module, pl, pl.proj_len - 1) == PI_OWNED && self.field_path(
            b,
            pl,
            pl.proj_len - 1,
        );
    }

    // The elements of the block that owned element `pl` (`owned_elem`) is in, forgotten (its length kept,
    // `own_forget`): a loop's code may change any of them.
    fn forget_elems(self: &mut Self, b: &ir::CoreBody, state: &mut Vector<u32>, pid: u32) {
        let pl = b.places.at(pid as usize);
        // The struct that holds the field: the base local, or the target of the `&mut` parameter.
        let deref = b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF;
        let l = if deref {
            let r = state[pl.base as usize];
            if r == NONE || self.tm.at(r).op != T_MREF && self.tm.at(r).op != T_PREF {
                let _ = self.havoc_write(b, state, pid);
                return;
            }
            self.ref_target(r)
        } else {
            pl.base
        };
        let sty = self.proj_base_ty(b, pl, pick(deref, 1u32, 0u32));
        // Only a field of the struct itself (`self.ptr[i]`): a deeper path forgets the struct.
        if pl.proj_len != pick(deref, 3u32, 2u32) {
            self.forget(b, b.module, state, l);
            return;
        }
        let v = state[l as usize];
        let nv = self.own_forget(b.module, sty, v, 0);
        state.set(l as usize, nv);
    }

    // Call `t` may write memory: a new epoch, and the locals it was lent. It reaches no `[]mut` parameter
    // of the body that its arguments do not reach, which only the body may write while it holds it: their
    // views stay (`keep_param_views`).
    fn call_event(self: &mut Self, b: &ir::CoreBody, path: &mut Path, t: &ir::Terminator) {
        let ep0 = path.state[path.state.len() - 1];
        let mut passed: u64 = 0;
        let mut vx = Vector::<u32>::new();
        for j in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            if op.kind == ir::OP_CONST || j == 0 && self.skip_recv || self.shared_read(b, t, j) || self.cell_read(
                b,
                t,
                j,
            ) {
                continue;
            }
            // An automatic borrow of a local of an owning type reaches that local alone, as `&mut v` does.
            let pl = b.places.at(op.data as usize);
            if pl.proj_len == 0 && param_bit(b, pl.base) == 0 && self.autoref(b, b.module, t, j) && self.owns(
                b.module,
                b.locals.at(pl.base as usize).ty,
            ) {
                continue;
            }
            passed |= self.reached_params(b, &mut path.state, pl.base, op.ty, &mut vx);
        }
        // The vectors lent as views the call is not given keep their values (their views' borrows have
        // ended or are not the call's).
        let keep = passed != ~0u64;
        self.mem_event_keep(b, b.module, &mut path.state, keep, &vx);
        self.lent(b, &mut path.state, t);
        self.keep_param_views(b, b.module, &path.state, ep0, passed);
        for j in 0..t.args_len {
            if !(j == 0 && self.skip_recv) && self.cell_read(b, t, j) {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                self.cell_refresh_arg(b, &mut path.state, op.data);
            }
        }
    }

    // The `[]mut` parameters loop terminator `t` (a call or a drop) may reach, the arguments' origins
    // through `ldef` (`ref_origin`): a value's (`frozen`) or a local's of an owning type (`owns`) none, a
    // parameter's that one, another's all.
    fn loop_reach(self: &Self, b: &ir::CoreBody, ldef: &Map<u32, u32>, t: &ir::Terminator) u64 {
        if t.kind == ir::TM_DROP {
            let pl = *b.places.at(t.a as usize);
            return pick(
                pl.proj_len == 0 && self.owns(b.module, b.locals.at(pl.base as usize).ty) || self.owned_elem(b, &pl),
                0u64,
                ~0u64,
            );
        }
        if self.elem_call(b, t) {
            return 0;
        }
        let mut m: u64 = 0;
        for j in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            if op.kind == ir::OP_CONST || self.frozen(b.module, op.ty) {
                continue;
            }
            if b.places.at(op.data as usize).proj_len != 0 {
                return ~0u64;
            }
            let o = ref_origin(b, ldef, b.places.at(op.data as usize).base);
            if param_bit(b, o) != 0 {
                m |= param_bit(b, o);
            } else if o as usize >= b.locals.len() || !self.owns(b.module, b.locals.at(o as usize).ty) {
                return ~0u64;
            }
        }
        return m;
    }

    // Value `x` of type `aty` (module `am`) used as type `pty` (module `pm`): a `[]mut` used as a shared
    // `[]T` (an argument, a copy) is a new view of its elements now (as `[]mut`'s `as_slice`,
    // `sq_effect`), which no write changes while it lives.
    fn share_arg(
        self: &mut Self,
        am: ModuleId,
        aty: TypeId,
        pm: ModuleId,
        pty: TypeId,
        x: u32,
        state: &mut Vector<u32>,
        pc: &mut Vector<u32>,
    ) u32 {
        if x == NONE || self.slice.node == NODE_NONE || aty == TYPE_NONE || pty == TYPE_NONE {
            return x;
        }
        let (dam, dad) = self.decl_of(am, aty);
        let (dpm, dpd) = self.decl_of(pm, pty);
        if dad == NODE_NONE || dpd == NODE_NONE || dam != self.smut.mid || dad != self.smut.node || dpm != self.slice.mid || dpd != self.slice.node {
            return x;
        }
        let ov = self.view_s(x, state[state.len() - 1]);
        let xs = self.fresh(pm, pty);
        self.sdef.insert(xs as u64 << 32 | self.tm.boolean(false) as u64, ov);
        let sl = self.sq1(SQ_SLEN, xs, self.pw, false);
        let ol = self.sq1(SQ_SLEN, x, self.pw, false);
        pc.push(self.tm.cmp(T_EQ, sl, ol));
        return xs;
    }

    // The parameters (`param_bit`) a value of type `ty` in local `l` may reach: none for a value
    // (`frozen`) or a reference to a local of an owning type (`owns`), the parameter whose value or
    // reference it holds, none but the vector for a view a vector was lent (`views`, the view into `vx`),
    // and all of them for another.
    fn reached_params(
        self: &mut Self,
        b: &ir::CoreBody,
        state: &mut Vector<u32>,
        l: u32,
        ty: TypeId,
        vx: &mut Vector<u32>,
    ) u64 {
        if self.frozen(b.module, ty) {
            return 0;
        }
        let own = param_bit(b, l);
        if own != 0 {
            return own;
        }
        let v = state[l as usize];
        if v == NONE {
            return ~0u64;
        }
        if self.tm.at(v).op == T_MREF || self.tm.at(v).op == T_PREF {
            let x = self.ref_target(v);
            let xb = param_bit(b, x);
            if xb != 0 {
                return xb;
            }
            let xt = if x as usize >= b.locals.len() {
                self.slot_ty[x as usize - b.locals.len()]
            } else {
                b.locals.at(x as usize).ty
            };
            return pick(self.owns(b.module, xt), 0u64, ~0u64);
        }
        let mut m: u64 = 0;
        for p in b.returns..b.returns + b.args {
            if state[p as usize] == v {
                m |= param_bit(b, p);
            }
        }
        // A view a local vector of values lent (`escape_as`) reaches that vector only.
        for q in 0..self.views.len() {
            let x = (self.views[q] >> 32) as u32;
            if self.views[q] as u32 == v && x as usize < b.locals.len() && param_bit(b, x) == 0 && self.owns(
                b.module,
                b.locals.at(x as usize).ty,
            ) {
                vx.push(v);
                return m;
            }
        }
        return pick(m != 0, m, ~0u64);
    }

    // Whether argument `j` of call `t` of body `b` is a shared borrow (an automatic one, a `&`, or a `&mut`
    // the shared parameter takes as a `&`) of a place whose type holds no `UnsafeCell` (`no_cell`): the
    // callee changes neither its value nor the blocks of its `@owned` fields.
    fn shared_read(self: &Self, b: &ir::CoreBody, t: &ir::Terminator, j: u32) bool {
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        if op.kind == ir::OP_CONST || op.ty == TYPE_NONE {
            return false;
        }
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return false;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        if pt == TYPE_NONE {
            return false;
        }
        let py = *a.type_at(pt);
        if py.kind != TypeKind::TYPE_REFERENCE || py.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return false;
        }
        let oy = *self.ast_of(b.module).type_at(op.ty);
        let vty = pick(oy.kind == TypeKind::TYPE_REFERENCE, oy.as_data.elem, op.ty);
        return self.no_cell_in(b.module, vty, 0, 0, NODE_NONE, false);
    }

    // Argument `j` of call `t` is an automatic shared borrow of a local or of what a reference local refers
    // to, of a struct that is no union, that `shared_read` does not take (a member may hold a cell: a type
    // parameter's), and the call's results hold no reference or pointer: the callee writes only what a cell
    // inside the value holds, and keeps no way to write it later. The members that may hold a cell take new
    // values (`cell_refresh`); the others keep theirs.
    fn cell_read(self: &Self, b: &ir::CoreBody, t: &ir::Terminator, j: u32) bool {
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        if op.kind == ir::OP_CONST || self.shared_read(b, t, j) {
            return false;
        }
        let pl0 = *b.places.at(op.data as usize);
        if pl0.proj_len == 0 && pl0.base as usize < self.cell_tmp.len() && self.cell_tmp[pl0.base as usize] {
            return true;
        }
        // A reference local passed on as a shared reference (a `&mut` too).
        if pl0.proj_len == 0 && self.ast_of(b.module).type_at(b.locals.at(pl0.base as usize).ty).kind == TypeKind::TYPE_REFERENCE {
            let ry = *self.ast_of(b.module).type_at(b.locals.at(pl0.base as usize).ty);
            return self.shared_param(t, j) && self.ref_free_results(b, t) && self.plain_struct_ref(
                b.module,
                ry.as_data.elem,
            );
        }
        if !self.autoref(b, b.module, t, j) {
            return false;
        }
        let d = t.callee;
        if op.kind == ir::OP_CONST || d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(
            d.module as usize,
        ).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return false;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        if pt == TYPE_NONE || a.type_at(pt).kind != TypeKind::TYPE_REFERENCE || a.type_at(pt).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len > 1 || pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind != ir::PJ_DEREF {
            return false;
        }
        if !self.ref_free_results(b, t) {
            return false;
        }
        let oy = *self.ast_of(b.module).type_at(op.ty);
        let vty = pick(oy.kind == TypeKind::TYPE_REFERENCE, oy.as_data.elem, op.ty);
        let vy = *self.ast_of(b.module).type_at(vty);
        if vy.kind != TypeKind::TYPE_STRUCT && vy.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(b.module, vty);
        return dn != NODE_NONE && self.pkg().modules.at(dm as usize).has_ast && self.ast_of(dm).at_const(dn).kind == NodeKind::NODE_STRUCT && !unsafe self.ast_of(
            dm,
        ).ext(dn).aggregate.is_union;
    }

    // Whether the results of call `t` are builtin values (no reference, no pointer).
    fn ref_free_results(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        for q in t.dests_start..t.dests_start + t.dests_len {
            if !self.holds_no_ref(b.module, b.places.at(b.dest_pool[q as usize] as usize).ty, 0) {
                return false;
            }
        }
        return true;
    }

    // Whether a value of type `ty` (module `m`) holds no reference or pointer of its own: a builtin, a type
    // parameter (its argument is the caller's type, which no borrow of a call's argument reaches), an array
    // of such, or an instance of a struct whose fields are its parameters or builtins (a tuple), over such
    // arguments.
    fn holds_no_ref(self: &Self, m: ModuleId, ty: TypeId, depth: u32) bool {
        if ty == TYPE_NONE || depth > 4 {
            return false;
        }
        let y = *self.ast_of(m).type_at(ty);
        if y.kind == TypeKind::TYPE_BUILTIN || y.kind == TypeKind::TYPE_GENERIC {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.holds_no_ref(m, y.as_data.arr.elem, depth + 1);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(m, ty);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        let da = self.ast_of(dm);
        let ms = da.ext(dn).aggregate.members;
        for j in 0..ms.len {
            let ft = da.type_of(unsafe da.list(ms)[j as usize]);
            if ft == TYPE_NONE {
                return false;
            }
            let fk = da.type_at(ft).kind;
            if fk != TypeKind::TYPE_GENERIC && fk != TypeKind::TYPE_BUILTIN {
                return false;
            }
        }
        let it = *self.ast_of(m).instance(y.as_data.inst);
        for j in 0..it.n as usize {
            if !self.holds_no_ref(m, it.args[j], depth + 1) {
                return false;
            }
        }
        return true;
    }

    // Whether the callee of call `t` takes a shared reference as its parameter `j`.
    fn shared_param(self: &Self, t: &ir::Terminator, j: u32) bool {
        let d = t.callee;
        if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || !self.pkg().modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = self.ast_of(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        let ps = a.ext(d.node).function.params;
        if j >= ps.len {
            return false;
        }
        let pt = a.type_of(unsafe a.list(ps)[j as usize]);
        return pt != TYPE_NONE && a.type_at(pt).kind == TypeKind::TYPE_REFERENCE && a.type_at(pt).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
    }

    // Whether `ty` (module `m`) is a shared reference to a struct that is no union, or such a struct.
    fn plain_struct_ref(self: &Self, m: ModuleId, ty: TypeId) bool {
        let oy = *self.ast_of(m).type_at(ty);
        if oy.kind == TypeKind::TYPE_REFERENCE && oy.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return false;
        }
        let vty = pick(oy.kind == TypeKind::TYPE_REFERENCE, oy.as_data.elem, ty);
        let vy = *self.ast_of(m).type_at(vty);
        if vy.kind != TypeKind::TYPE_STRUCT && vy.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(m, vty);
        return dn != NODE_NONE && self.pkg().modules.at(dm as usize).has_ast && self.ast_of(dm).at_const(dn).kind == NodeKind::NODE_STRUCT && !unsafe self.ast_of(
            dm,
        ).ext(dn).aggregate.is_union;
    }

    // The value the place of `cell_read` argument `pl` names, with its cells' members new (`cell_refresh`).
    fn cell_refresh_arg(self: &mut Self, b: &ir::CoreBody, state: &mut Vector<u32>, pl: u32) {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 && self.ast_of(b.module).type_at(b.locals.at(p.base as usize).ty).kind == TypeKind::TYPE_REFERENCE {
            // A reference local (a borrow temporary): what it refers to.
            let r = state[p.base as usize];
            let ry = *self.ast_of(b.module).type_at(b.locals.at(p.base as usize).ty);
            if r == NONE || self.tm.at(r).op != T_MREF || ry.kind != TypeKind::TYPE_REFERENCE {
                return;
            }
            let at = self.ref_target(r) as usize;
            if at < state.len() && state[at] != NONE {
                state.set(at, self.cell_refresh(b.module, ry.as_data.elem, state[at]));
            }
            return;
        }
        let at = if p.proj_len == 0 {
            p.base as usize
        } else {
            let r = state[p.base as usize];
            if r == NONE || self.tm.at(r).op != T_MREF {
                return;
            }
            self.ref_target(r) as usize
        };
        let ty = if p.proj_len == 0 {
            b.locals.at(p.base as usize).ty
        } else {
            b.projections.at(p.proj_start as usize).ty
        };
        if at < state.len() && state[at] != NONE {
            state.set(at, self.cell_refresh(b.module, ty, state[at]));
        }
    }

    // Struct value `v` of type `ty` (module `m`) after a callee that holds a shared reference to it: the
    // elements of its `@owned` blocks and each member that may hold a cell (`no_cell`; a type parameter's
    // argument) are new, the blocks' lengths and the other members keep theirs. A pointer member keeps its
    // value: a cell it reaches is memory.
    fn cell_refresh(self: &mut Self, m: ModuleId, ty: TypeId, v: u32) u32 {
        let out0 = self.own_forget(m, ty, v, 0);
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        let (dm, dn) = self.decl_of(rm, rt);
        if dn == NODE_NONE || y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return out0;
        }
        let ag = unsafe self.ast_of(dm).ext(dn).aggregate;
        let mut out = out0;
        for j in 0..ag.members.len {
            let f = unsafe self.ast_of(dm).list(ag.members)[j as usize];
            let mt = self.ast_of(dm).member_ty(f);
            let my = *self.ast_of(dm).type_at(mt);
            if mt == TYPE_NONE || my.kind == TypeKind::TYPE_POINTER || self.ast_of(dm).attr_of(f, AttrKind::ATTR_OWNED) != null {
                continue;
            }
            // A member of a type parameter: the instance's argument.
            let (mut fm, mut ft) = (dm, mt);
            let mut free = false;
            if my.kind == TypeKind::TYPE_GENERIC {
                ft = TYPE_NONE;
                if y.kind == TypeKind::TYPE_INSTANCE {
                    let it = *self.ast_of(rm).instance(y.as_data.inst);
                    for i in 0..ag.generics.len {
                        if unsafe self.ast_of(dm).list(ag.generics)[i as usize] == my.as_data.decl && i as u8 < it.n {
                            fm = rm;
                            ft = it.args[i as usize];
                            free = self.cell_free_of(rm, ft, NODE_NONE);
                        }
                    }
                }
            } else {
                free = self.cell_free_of(dm, mt, NODE_NONE);
            }
            if !free {
                let k = self.tm.int(wide::<B>(j), 64, false);
                let nv = if ft == TYPE_NONE {
                    self.tm.var(W_OTHER, false)
                } else {
                    self.fresh(fm, ft)
                };
                out = self.tm.upd(out, k, nv);
            }
        }
        return out;
    }

    // Whether a value of type `ty` (module `m`) holds no `UnsafeCell`, in its members, the elements its
    // pointers reach and its type arguments; a type parameter of struct `gd` (module `gm`) is one whose
    // argument was checked. `depth` levels deep.
    // `no_cell` of type `ty` of module `m`, a member of struct `gd` of `m` (NODE_NONE outside one), once
    // per type and struct (`cell_free`).
    fn cell_free_of(self: &mut Self, m: ModuleId, ty: TypeId, gd: NodeId) bool {
        let k = m as u64 << 32 | ty as u64;
        if let Some(e) = self.cell_free.get(&k) {
            if *e >> 1 == gd as u64 {
                return (*e & 1) != 0;
            }
        }
        let r = self.no_cell(m, ty, 0, pick(gd == NODE_NONE, 0, m), gd);
        self.cell_free.insert(k, gd as u64 << 1 | r as u64);
        return r;
    }

    fn no_cell(self: &Self, m: ModuleId, ty: TypeId, depth: u32, gm: ModuleId, gd: NodeId) bool {
        return self.no_cell_in(m, ty, depth, gm, gd, true);
    }

    // `no_cell`; without `through`, a pointer's or a reference's target is not read: the value's own
    // storage alone (what a pointer reaches is memory, or a local made memory where its address was
    // taken).
    fn no_cell_in(self: &Self, m: ModuleId, ty: TypeId, depth: u32, gm: ModuleId, gd: NodeId, through: bool) bool {
        if ty == TYPE_NONE || depth > 6 {
            return false;
        }
        let (rm, rt) = self.resolve(m, ty);
        let y = *self.ast_of(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_BUILTIN {
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            return !through || self.no_cell_in(rm, y.as_data.elem, depth + 1, gm, gd, through);
        }
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            return self.no_cell_in(rm, y.as_data.arr.elem, depth + 1, gm, gd, through);
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            // A parameter of the struct whose arguments were checked.
            if gd == NODE_NONE || y.module != gm || !self.pkg().modules.at(gm as usize).has_ast {
                return false;
            }
            let gs = self.ast_of(gm).ext(gd).aggregate.generics;
            for i in 0..gs.len {
                if unsafe self.ast_of(gm).list(gs)[i as usize] == y.as_data.decl {
                    return true;
                }
            }
            return false;
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let (dm, dn) = self.decl_of(rm, rt);
        if dn == NODE_NONE || !self.pkg().modules.at(dm as usize).has_ast || self.ast_of(dm).at_const(dn).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        if dm == self.wcore.mid && dn == self.wcore.node {
            return false;
        }
        // The type arguments: all of them, or for the value's own storage those its members are.
        let it = if y.kind == TypeKind::TYPE_INSTANCE {
            *self.ast_of(rm).instance(y.as_data.inst)
        } else {
            TyInstance { module: 0, decl: NODE_NONE, n: 0, args: [TYPE_NONE; 8], lts: 0 }
        };
        if through {
            for i in 0..it.n {
                if !self.no_cell_in(rm, it.args[i as usize], depth + 1, gm, gd, through) {
                    return false;
                }
            }
        }
        // A struct's or a union's members: a union holds a cell where one of its members does.
        let ag = unsafe self.ast_of(dm).ext(dn).aggregate;
        for j in 0..ag.members.len {
            let mt = self.ast_of(dm).member_ty(unsafe self.ast_of(dm).list(ag.members)[j as usize]);
            let my = *self.ast_of(dm).type_at(mt);
            let ok = if through {
                self.no_cell_in(dm, mt, depth + 1, dm, dn, through)
            } else if my.kind == TypeKind::TYPE_GENERIC {
                // A member of a parameter's type: the argument's own storage.
                let gs = ag.generics;
                let mut a = TYPE_NONE;
                for i in 0..gs.len {
                    if my.module == dm && unsafe self.ast_of(dm).list(gs)[i as usize] == my.as_data.decl && i as u8 < it.n {
                        a = it.args[i as usize];
                    }
                }
                self.no_cell_in(rm, a, depth + 1, 0, NODE_NONE, false)
            } else {
                // Another type naming a parameter is not read: unknown.
                self.no_cell_in(dm, mt, depth + 1, 0, NODE_NONE, false)
            };
            if !ok {
                return false;
            }
        }
        return true;
    }

    // Whether a value of type `ty` (module `m`) holds memory of its own only: a value (`frozen`), or a
    // vector of values or a string, whose elements no other value shares.
    fn owns(self: &Self, m: ModuleId, ty: TypeId) bool {
        if self.frozen(m, ty) {
            return true;
        }
        let (dm, dd) = self.decl_of(m, ty);
        if dd == NODE_NONE {
            return false;
        }
        if dm == self.strl.mid && dd == self.strl.node {
            return true;
        }
        if dm != self.vecl.mid || dd != self.vecl.node {
            return false;
        }
        let (m1, t1) = self.resolve(m, ty);
        let y = self.ast_of(m1).type_at(t1);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let inst = self.ast_of(m1).instance(y.as_data.inst);
        return inst.n >= 1 && self.frozen(m1, inst.args[0]);
    }

    // The locals call `t` was lent (`scoped`): the callee may have changed them.
    fn lent(self: &mut Self, b: &ir::CoreBody, state: &mut Vector<u32>, t: &ir::Terminator) {
        for j in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            // A shared read (`shared_read`) changes nothing it was lent.
            if op.kind == ir::OP_CONST || self.shared_read(b, t, j) {
                continue;
            }
            let p = *b.places.at(op.data as usize);
            // An automatic borrow of a local or of its member that the callee may change, where the local
            // is no memory (the borrow ends with the call, `is_mem`): the local takes a new value.
            if self.autoref(b, b.module, t, j) && !(j == 0 && self.skip_recv) && !self.has_deref(b, &p, 0) && !self.is_mem[p.base as usize] {
                self.forget(b, b.module, state, p.base);
                continue;
            }
            // A struct temporary that held the call's `&mut` of a whole local: the local takes a new value.
            if p.proj_len == 0 && self.scoped_in.contains_key(&p.base) {
                let l = *self.scoped_in.get(&p.base).unwrap();
                self.forget(b, b.module, state, l);
                continue;
            }
            if p.proj_len != 0 || !self.scoped[p.base as usize] || state[p.base as usize] == NONE {
                continue;
            }
            let r = state[p.base as usize];
            let v = self.tm.at(r);
            if v.op == T_MREF && v.a as usize != p.base as usize {
                self.forget(b, b.module, state, v.a);
            } else if v.op == T_PREF {
                // The member the callee was lent: only it may hold another value.
                let (rm, rty) = self.ref_ty(b, r);
                let f = self.fresh(rm, rty);
                self.ref_set(b, state, r, f);
            }
        }
    }

    // A `[]mut` parameter the body never reassigns refers to the caller's memory, which no local of the
    // body is part of: a write to a local leaves its view in the new epoch as it was in epoch `ep0`.
    fn keep_param_views(self: &mut Self, cb: &ir::CoreBody, cm: ModuleId, state: &Vector<u32>, ep0: u32, skip: u64) {
        let wm = self.param_writes(cb.owner, cb) | skip;
        let ep1 = state[state.len() - 1];
        for l in cb.returns..cb.returns + cb.args {
            let k = l - cb.returns;
            if k >= 64 || (wm >> k as u64 & 1) != 0 || state[l as usize] == NONE {
                continue;
            }
            let (dm, dd) = self.decl_of(cm, cb.locals.at(l as usize).ty);
            if dd == NODE_NONE || dm != self.smut.mid || dd != self.smut.node {
                continue;
            }
            let xs = state[l as usize];
            let v = self.view_s(xs, ep0);
            self.sdef.insert(xs as u64 << 32 | ep1 as u64, v);
        }
    }

    // The parameters callee `d` (body `cb`) may change, one bit each (the first 64): a write, a call's
    // result, or a borrow or address of the parameter's storage. Scanned once per callee.
    fn param_writes(self: &mut Self, d: DefId, cb: &ir::CoreBody) u64 {
        self.note_read(d);
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
            // A write or a borrow through the parameter's reference leaves the parameter as it is.
            if !through_ref(cb, s.place) {
                m |= param_bit(cb, cb.places.at(s.place as usize).base);
            }
            let rv = *cb.rvalues.at(s.rvalue as usize);
            if (rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF && (rv.b != 0 || ptr_cast) || rv.kind == ir::RV_SLICE) && !through_ref(
                cb,
                rv.a,
            ) {
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

// Whether place `pl` of `cb` starts with a dereference of its local.
const fn through_ref(cb: &ir::CoreBody, pl: u32) bool {
    let p = cb.places.at(pl as usize);
    return p.proj_len != 0 && cb.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF;
}

// Whether place `p` of `cb` is a local or a member a `T_MREF` or `T_PREF` can name (`place_ref`): no
// dereference but a first one, no variant, no union member.
const fn member_place(cb: &ir::CoreBody, p: &ir::Place) bool {
    for j in 0..p.proj_len {
        let pj = cb.projections.at((p.proj_start + j) as usize);
        if pj.kind == ir::PJ_DEREF && j != 0 || pj.kind == ir::PJ_DOWNCAST || pj.kind == ir::PJ_FIELD && pj.data == ir::PJ_UNION_FIELD {
            return false;
        }
    }
    return true;
}

// The local whose reference local `l` holds, through the whole-local copies and reborrows (`&mut *x`)
// of `ldef` (a local's defining rvalue): `l` itself when it holds no such copy.
fn ref_origin(cb: &ir::CoreBody, ldef: &Map<u32, u32>, l: u32) u32 {
    let mut x = l;
    for _k in 0..8 {
        if !ldef.contains_key(&x) {
            return x;
        }
        let rid = *ldef.get(&x).unwrap();
        let rv = *cb.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE && rv.b == 0 {
            let op = *cb.operands.at(rv.a as usize);
            if op.kind == ir::OP_CONST || cb.places.at(op.data as usize).proj_len != 0 {
                return x;
            }
            x = cb.places.at(op.data as usize).base;
        } else if rv.kind == ir::RV_REF {
            let p = *cb.places.at(rv.a as usize);
            if p.proj_len == 0 {
                return p.base;
            }
            if p.proj_len != 1 || cb.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
                return x;
            }
            x = p.base;
        } else {
            return x;
        }
    }
    return x;
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
        ) || any_pattern_in(p, m)) {
            return true;
        }
    }
    return false;
}

// Whether module `m` of `p` converts a value into a pattern type that its checker could not decide:
// a `CT_PATTERN` site the prover proves.
// A module that uses a pattern type (its facts may remove bounds checks) counts too.
fn any_pattern_in(p: &loader::Package, m: usize) bool {
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    for j in 0..a.coerces.len() {
        let c = a.coerces.at(j);
        if c.method.node == NODE_NONE && a.type_at(c.target).has_pat() {
            return true;
        }
    }
    for j in 0..a.used.len() {
        if a.type_at(a.used[j]).has_pat() {
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
const fn input_index<const B: usize>(job: &PJob<B>, x: u64, j: usize) u64 {
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
fn input_args<const B: usize>(job: &PJob<B>, x: u64, out: &mut Vector<iri::IVal>) {
    out.clear();
    for j in 0..job.dims.len() {
        let d = &job.dims[j];
        let i = input_index(job, x, j);
        let v = if d.kind == PD_BOOL {
            iri::IVal { kind: iri::IV_BOOL, tm: d.tm, ty: d.ty, i: i as i64, f: 0.0 }
        } else if d.kind == PD_ENUM {
            iri::IVal { kind: iri::IV_INT, tm: d.tm, ty: d.ty, i: d.tags[i as usize], f: 0.0 }
        } else {
            let bits = bits_of(d.lo + u64_val::<B>(i), d.w);
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
fn describe_input<const B: usize>(p: &loader::Package, b: &ir::CoreBody, job: &PJob<B>, x: u64, out: &mut String) {
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
            out.push_str((d.lo + u64_val::<B>(i)).to_string().as_str());
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
fn run_inputs<const B: usize>(p: &loader::Package, keep: &irl::Keep, job: &PJob<B>, r: &mut PRes) {
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
        e.trap_frames(pick(tk == iri::IT_TRAP_PANIC, 1, 0), &mut calls);
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
// The exhaustive proofs take built-in integers only: narrow numbers.
fn prove_exhaustive(pv: &mut Prover<NUM_NARROW>, p: &loader::Package, keep: &irl::Keep, skip: &Vector<bool>) {
    let mut jobs = Vector::<PJob<NUM_NARROW>>::new();
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
                let job = unsafe &*(ptr::from_addr_mut::<PJob<NUM_NARROW>>(ja) + r.job as usize);
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

// Prove kept body `k` with the narrow numbers (`prove_fits`), else, or when `wide`, with the wide ones
// (`pw`): its reports go to `pv.errs`, its facts to `pv.facts`.
fn prove_one(pv: &mut Prover<NUM_NARROW>, pw: &mut Prover<NUM_WIDE>, k: usize, wide: bool) {
    if !wide && pv.prove_fits(k) {
        return;
    }
    pw.prove_kept(k);
    let m = (unsafe (&*pv.keep).kept.at(k).body.module) as usize;
    pv.errs.index_mut(m).append(pw.errs.index_mut(m));
    pv.facts.extend_copy(&pw.facts);
    pw.facts.clear();
}

/// The language server's proofs of the kept bodies of module `m` (`check_kept`, serial) from kept slot
/// `*next` on, their reports appended to `errs`: true when they ended, false when `stop(sctx, true)`,
/// polled before each body and inside it (`Solver::set_poll`), asked to stop (a request stops them too),
/// `*next` then the slot to resume at: a body that a stop cut gives no reports and runs again. `keep`
/// holds every body the proofs read, and `mods` marks the modules whose contracts of functions without a
/// body they read (the modules `m` can name); `comp` is as for `check_kept`. Each body's proof depends on no other's, so a resumed run reports what one run does.
pub(package) fn check_module(
    p: &loader::Package,
    keep: &irl::Keep,
    comp: &Vector<u32>,
    m: usize,
    mods: &Vector<bool>,
    next: &mut usize,
    errs: &mut diag::Errors,
    stop: fn(*mut void, bool) bool,
    sctx: *mut void,
) bool {
    let mut sh = Shared { shells: Vector::<ir::CoreBody>::new(), shell_ix: Map::<u64, u32>::new(), scc: comp.clone() };
    let mut pv = Prover::<NUM_NARROW>::new(p, keep, p.prelude_lookup("Slice", true));
    pv.lower_shells(&mut sh, mods);
    if *next != 0 {
        // The first run reported the shells.
        let _ = replace(pv.errs.index_mut(m), diag::Errors::new());
    }
    pv.sh = &sh;
    let mut pw = Prover::<NUM_WIDE>::new(p, keep, pv.slice);
    pw.sh = &sh;
    pv.sv.set_poll(stop, sctx);
    pw.sv.set_poll(stop, sctx);
    while *next < keep.kept.len() {
        let k = *next;
        let kb = keep.kept.at(k);
        if kb.body.blocks.len() != 0 && kb.body.module as usize == m {
            if stop(sctx, true) {
                errs.append(pv.errs.index_mut(m));
                return false;
            }
            let held = replace(pv.errs.index_mut(m), diag::Errors::new());
            let wide = pv.needs_wide(k);
            prove_one(&mut pv, &mut pw, k, wide);
            // A stop in the body: its answer is none, and it runs again when the proofs resume.
            let mut e = replace(pv.errs.index_mut(m), held);
            if pv.sv.halted || pw.sv.halted {
                errs.append(pv.errs.index_mut(m));
                return false;
            }
            pv.errs.index_mut(m).append(&mut e);
        }
        *next = k + 1;
    }
    let mut skip = Vector::<bool>::with_capacity(p.modules.len());
    for i in 0..p.modules.len() {
        skip.push(i != m);
    }
    prove_exhaustive(&mut pv, p, keep, &skip);
    errs.append(pv.errs.index_mut(m));
    return true;
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
    facts: &mut Vector<u64>,
    reads: &mut Vector<Vector<u64>>,
) bool {
    let mut sh = Shared { shells: Vector::<ir::CoreBody>::new(), shell_ix: Map::<u64, u32>::new(), scc: comp.clone() };
    let mut pv = Prover::<NUM_NARROW>::new(p, keep, p.prelude_lookup("Slice", true));
    pv.rd_on = true;
    let mut all = Vector::<bool>::with_capacity(p.modules.len());
    for _m in 0..p.modules.len() {
        all.push(true);
    }
    pv.lower_shells(&mut sh, &all);
    pv.sh = &sh;
    let _ = pv.take_reads();
    reads.clear();
    for _m in 0..p.modules.len() {
        reads.push(Vector::<u64>::new());
    }
    let n = keep.kept.len();
    // A body with an integer wider than the narrow numbers hold proves with the wide ones.
    let mut wide = Vector::<bool>::with_capacity(n);
    for k in 0..n {
        let kb = keep.kept.at(k);
        wide.push(kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] && pv.needs_wide(k));
    }
    if p.jobs == 1 || n < 2 {
        let mut pw = Prover::<NUM_WIDE>::new(p, keep, pv.slice);
        pw.rd_on = true;
        pw.sh = &sh;
        for k in 0..n {
            let kb = keep.kept.at(k);
            if kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] {
                prove_one(&mut pv, &mut pw, k, wide[k]);
                let m = kb.body.module as usize;
                let r1 = pv.take_reads();
                let r2 = pw.take_reads();
                reads.index_mut(m).extend_copy(&r1);
                reads.index_mut(m).extend_copy(&r2);
            }
        }
    } else {
        // One prover per chunk of bodies, each body's reports in a container of its own; a walk
        // reads only the package, the keep and the shared state. The reports merge in body order and
        // then by position, as one prover orders them (`Errors::emit_ordered`).
        let mut outs = Vector::<diag::Errors>::with_capacity(n);
        let mut fouts = Vector::<Vector<u64>>::with_capacity(n);
        let mut routs = Vector::<Vector<u64>>::with_capacity(n);
        for _k in 0..n {
            outs.push(diag::Errors::new());
            fouts.push(Vector::<u64>::new());
            routs.push(Vector::<u64>::new());
        }
        let chunks = if n < p.jobs as usize * 4 {
            n
        } else {
            p.jobs as usize * 4
        };
        // The bodies by size, largest first (ties by index): chunk `c` takes every `chunks`-th from the
        // `c`-th, so the large bodies spread over the chunks and start first.
        let mut order = Vector::<u64>::with_capacity(n);
        for k in 0..n {
            let nb = keep.kept.at(k).body.blocks.len() as u64;
            order.push(0xFFFFFFFFu64 - nb << 32 | k as u64);
        }
        order.sort();
        let da = ((&order) as *const Vector<u64>) as usize;
        let pa = (p as *const loader::Package) as usize;
        let ka = (keep as *const irl::Keep) as usize;
        let ha = ((&sh) as *const Shared) as usize;
        let sa = (skip as *const Vector<bool>) as usize;
        let wa = ((&wide) as *const Vector<bool>) as usize;
        let oa = outs.as_mut_ptr() as usize;
        let fa = fouts.as_mut_ptr() as usize;
        let ra = routs.as_mut_ptr() as usize;
        let slice = pv.slice;
        // Each worker claims one chunk at a time.
        dpar::range_with(
            0..chunks,
            dpar::Options { schedule: dpar::Schedule::Dynamic, grain_size: 1 },
            |c: usize| {
                let pk = unsafe &*ptr::from_addr_mut::<loader::Package>(pa);
                let kp = unsafe &*ptr::from_addr_mut::<irl::Keep>(ka);
                let sk = unsafe &*ptr::from_addr_mut::<Vector<bool>>(sa);
                let wd = unsafe &*ptr::from_addr_mut::<Vector<bool>>(wa);
                let mut w = Prover::<NUM_NARROW>::new(pk, kp, slice);
                w.rd_on = true;
                w.sh = ptr::from_addr_mut::<Shared>(ha);
                let mut w2 = Prover::<NUM_WIDE>::new(pk, kp, slice);
                w2.rd_on = true;
                w2.sh = ptr::from_addr_mut::<Shared>(ha);
                let _ = w.take_reads();
                let _ = w2.take_reads();
                let od = unsafe &*ptr::from_addr_mut::<Vector<u64>>(da);
                for i in 0..(n - c + chunks - 1) / chunks {
                    let k = (od[c + i * chunks] & 0xFFFFFFFFu64) as usize;
                    let kb = kp.kept.at(k);
                    if kb.body.blocks.len() == 0 || sk[kb.body.module as usize] {
                        continue;
                    }
                    let m = kb.body.module as usize;
                    let (e, f) = if !wd[k] && w.prove_fits(k) {
                        (replace(w.errs.index_mut(m), diag::Errors::new()), replace(&mut w.facts, Vector::<u64>::new()))
                    } else {
                        w2.prove_kept(k);
                        (
                            replace(w2.errs.index_mut(m), diag::Errors::new()),
                            replace(&mut w2.facts, Vector::<u64>::new())
                        )
                    };
                    unsafe *(ptr::from_addr_mut::<diag::Errors>(oa) + k) = e;
                    unsafe *(ptr::from_addr_mut::<Vector<u64>>(fa) + k) = f;
                    let mut rk = w.take_reads();
                    let r2 = w2.take_reads();
                    rk.extend_copy(&r2);
                    unsafe *(ptr::from_addr_mut::<Vector<u64>>(ra) + k) = rk;
                }
            },
        );
        for k in 0..n {
            let m = keep.kept.at(k).body.module as usize;
            if outs.at(k).errors.len() != 0 {
                pv.errs.index_mut(m).append(outs.index_mut(k));
            }
            pv.facts.extend_copy(fouts.at(k));
            reads.index_mut(m).extend_copy(routs.at(k));
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
    // A `@prove_exhaustive` function's runs go through the evaluator, which reads what it calls: its module
    // reads every module (NODE_NONE: a whole module).
    for k in 0..n {
        let kb = keep.kept.at(k);
        if kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] && pv.exhaustive(kb.body.owner) {
            for y in 0..p.modules.len() {
                reads.index_mut(kb.body.module as usize).push(y as u64 << 32 | NODE_NONE as u64);
            }
        }
    }
    for m in 0..p.modules.len() {
        reads.index_mut(m).sort();
        reads.index_mut(m).dedup();
    }
    // The facts of a module whose proofs failed are no facts: the build stops.
    *facts = replace(&mut pv.facts, Vector::<u64>::new());
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

// Whether `c` (at least 0) is `2^j - 1` for some `j`: `c + 1` a power of two.
const fn low_mask<const B: usize>(c: Num<B>) bool {
    let n = c + Num::<B>::one();
    let mut p = Num::<B>::one();
    for _j in 0..B {
        if p == n {
            return true;
        }
        if n < p {
            return false;
        }
        p = p.shl(1);
    }
    return false;
}
