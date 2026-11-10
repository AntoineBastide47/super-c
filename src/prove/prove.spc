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

    fn set(self: &mut Self, t: u32, v: Num<B>) {
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
        return x.op == T_VAR || x.op == T_CALL || x.op >= T_AGG && x.op != T_ORD || x.op == T_REF;
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
            if x.op != T_NEG && x.op != T_NOT && x.op != T_BNOT && x.op != T_CAST {
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
        let one = Num::<B>::one();
        let z = Num::<B>::zero();
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
            if !exact_w(x.w) {
                let (lo, hi) = Terms::<B>::range(x.w, x.sg);
                if q < lo || hi < q {
                    return None;
                }
            }
            return if x.op == T_DIV {
                Some(q)
            } else {
                switch b.checked_mul(&q) {
                    Some(bq) => a.checked_sub(&bq),
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
    fn assign(self: &mut Self, k0: u64, cands: &Vector<Num<B>>, cstart: &Vector<u32>) bool {
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
    line_mod: u32, // the module whose line starts `line_starts` holds (`source_line`), NONE before one
    line_starts: Vector<u32>,
    tm: Terms<B>,
    sv: Solver<B>,
    // The facts the walk derives for a division or a shift by a constant (`quotient`, `shifted`),
    // which `holds` adds to a goal's facts only when it fails without them.
    derived: Map<u32, bool>,
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
    me: u32, // the kept index of the body under proof
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
    // The definitions of the spec function calls the body's walk made (`define`), facts of every
    // obligation; the calls defined; the depth of definition walks, whose calls stay opaque.
    defs: Vector<u32>,
    def_of: Map<u32, u32>, // a defined call -> its index in `defs`
    defined: Map<u32, bool>,
    unfold: u32,
    chain_ovf: u8, // the overflow model of a chain walk: OVF_PROVE, or OVF_EXACT in a definition
    chain_depth: u32, // the depth of chain walks (a clause, a definition): `derive` anchors their facts
    exact_body: bool, // the body under proof has a local of type `int` or `nat`
    ovf: u8,
    steps: u32,
    over: bool, // the body spent its budget
    work: Vector<Path>,
    ev: Eval<B>,
    vname: Map<u32, u32>, // a parameter's unknown -> the parameter's local, for counterexamples
    // The refinement walk of a conformance's method: only its `OB_REFINE` obligations count, and
    // `refine` holds the interface's contracts (null: the interface's method has none).
    refining: bool,
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
// The depth of definitions of spec function calls over constants (`call_value`).
const UNFOLD_MAX: u32 = 64;

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
            line_mod: NONE,
            line_starts: Vector::<u32>::new(),
            tm: Terms::<B>::new(),
            sv: Solver::<B>::new(),
            derived: Map::<u32, bool>::new(),
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
            me: NONE,
            fn_dec: false,
            ptr_cast: false,
            mem: null,
            site_of_chain: Vector::<u32>::new(),
            site_of_pred: Vector::<u32>::new(),
            ghost_fn: false,
            gblk: Vector::<bool>::new(),
            in_ghost: false,
            defs: Vector::<u32>::new(),
            def_of: Map::<u32, u32>::new(),
            defined: Map::<u32, bool>::new(),
            unfold: 0,
            chain_ovf: OVF_PROVE,
            chain_depth: 0,
            exact_body: false,
            ovf: OVF_KEEP,
            steps: 0,
            over: false,
            work: Vector::<Path>::new(),
            ev: Eval::<B>::new(),
            vname: Map::<u32, u32>::new(),
            refining: false,
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

    fn ty_of(self: &Self, m: ModuleId, ty: TypeId) (u16, bool) {
        if ty == TYPE_NONE {
            return W_OTHER, false;
        }
        let a = self.ast_of(m);
        let y = a.type_at(ty);
        if y.kind == TypeKind::TYPE_INSTANCE {
            // `UInt<N>` and `Int<N>` up to `int_limit` bits (`u128`, `i128`, `UInt<256>`) are integers of
            // N bits.
            let (n, sg) = self.wide_bits(m, ty);
            if n > 0 && n <= int_limit(B) {
                return n as u16, sg;
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
            _ => 0,
        };
        return w as u16, sg;
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
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        // A wide integer is a value of limbs, as a built-in integer is.
        let (w, _sg) = self.ty_of(m, ty);
        if w > W_BOOL {
            return true;
        }
        if self.slice.node == NODE_NONE {
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

    const fn spend(self: &mut Self) bool {
        self.steps += 1;
        return self.steps + self.sv.steps <= STEP_BUDGET;
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

    // Whether the facts `pc` imply `goal`: first without the facts derived for a division or a shift
    // by a constant, which most goals do not need and which make each simplex larger (on code with
    // many divisions, about 40% more instructions to prove all goals with them), then with them, then
    // without them again but refuting a branch by its bits (a SAT refutation), which costs more again
    // and needs no derived fact: the bits define a division and a shift.
    fn holds(self: &mut Self, pc0: &Vector<u32>, goal: u32) bool {
        // The definitions of the spec function calls the formulas name hold on every path.
        let mut withdefs = Vector::<u32>::new();
        if self.defs.len() != 0 {
            withdefs.extend_copy(pc0);
            self.add_defs(goal, &mut withdefs);
        }
        let pc = if withdefs.len() > pc0.len() {
            &withdefs
        } else {
            pc0
        };
        let mut n: usize = 0;
        for j in 0..pc.len() {
            n += self.derived.contains_key(&pc[j]) as usize;
        }
        if n == 0 {
            return self.sv.implies(&self.tm, pc, goal, true);
        }
        let mut base = Vector::<u32>::with_capacity(pc.len() - n);
        for j in 0..pc.len() {
            if !self.derived.contains_key(&pc[j]) {
                base.push(pc[j]);
            }
        }
        return self.sv.implies(&self.tm, &base, goal, false) || self.sv.implies(&self.tm, pc, goal, false) || self.sv.implies(
            &self.tm,
            &base,
            goal,
            true,
        );
    }

    // Append to `hyps` (the path) the definitions of the spec function calls under `goal` and `hyps`,
    // and of the calls under those definitions.
    fn add_defs(self: &mut Self, goal: u32, hyps: &mut Vector<u32>) {
        let mut seen = Map::<u32, bool>::new();
        let mut stack = Vector::<u32>::new();
        let mut ops = Vector::<u32>::new();
        stack.push(goal);
        for j in 0..hyps.len() {
            stack.push(hyps[j]);
        }
        for _s in 0..LIN_MAX * 16 {
            if stack.len() == 0 {
                return;
            }
            let t = stack.pop().unwrap();
            if seen.contains_key(&t) {
                continue;
            }
            seen.insert(t, true);
            if let Some(d) = self.def_of.get(&t) {
                let f = self.defs[(*d) as usize];
                if !hyps.contains(&f) {
                    hyps.push(f);
                }
                stack.push(f);
            }
            self.tm.operands(t, &mut ops);
            for j in 0..ops.len() {
                stack.push(ops[j]);
            }
        }
    }

    // Prove that the conditions `pc` imply `goal`; report obligation `key` when they do not.
    fn oblige(self: &mut Self, pc: &Vector<u32>, goal: u32, key: u64, sp: tok::Span, msg: String, note: String) {
        if self.over || self.failed.contains_key(&key) || self.refining && key >> 56 != OB_REFINE {
            return;
        }
        if self.holds(pc, goal) {
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
                v = self.tm.make(Term::<B> { k: wide::<B>(pj.data), a: v, b: 0, op: T_DOWN, w: W_OTHER, sg: false });
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
                return self.tm.int(wide::<B>(ix), 64, false);
            }
            return self.tm.int(wide::<B>(pj.sub) + Num::<B>::one().shl(40), 64, false);
        }
        return self.tm.int(wide::<B>(pj.data), 64, false);
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
        return self.tm.make(Term::<B> { k: Num::<B>::zero(), a: r, b: ep, op: T_LOAD, w: w, sg: sg });
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
                    u64_val::<B>(v as u64)
                } else {
                    wide::<B>(v)
                };
                return self.tm.int(k, w, sg);
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
        let rv = *cb.rvalues.at(rid as usize);
        let (w, sg) = self.ty_of(cm, rv.target);
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
                    return self.tm.make(
                        Term::<B> { k: Num::<B>::zero(), a: p.base, b: 0, op: T_MREF, w: W_OTHER, sg: false },
                    );
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
            return self.tm.pool(T_AGG, &xs, Num::<B>::zero());
        }
        if rv.kind == ir::RV_LEN {
            let n = self.array_len(cm, cb.places.at(rv.a as usize).ty);
            if n >= 0 && w > W_BOOL {
                return self.tm.int(wide::<B>(n), w, sg);
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
            if op == tt::TokenType::Tilde as u8 && self.tm.is_int(x) && w > W_BOOL && !exact_w(w) {
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
        if rv.kind == ir::RV_INTRINSIC && ir::is_check(rv.c) && rv.b >= 2 {
            let x = self.operand(cb, cm, state, cb.oper_pool[rv.a as usize], all);
            let y = self.operand(cb, cm, state, cb.oper_pool[(rv.a + 1) as usize], all);
            let z = if rv.b >= 3 {
                self.operand(cb, cm, state, cb.oper_pool[(rv.a + 2) as usize], all)
            } else {
                NONE
            };
            let ints = self.tm.is_int(x) && self.tm.is_int(y) && (z == NONE || self.tm.is_int(z));
            if ints && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN) {
                let f = self.tm.cmp(T_LT, x, y);
                self.check_fact(pc, f, key, sp);
                return x;
            }
            if ints && z != NONE && (rv.c == ir::IN_RANGE_BOUNDS || rv.c == ir::IN_RANGE_BOUNDS_PROVEN) {
                let c1 = self.tm.cmp(T_LE, x, y);
                let c2 = self.tm.cmp(T_LE, y, z);
                let f = self.tm.and(c1, c2);
                self.check_fact(pc, f, key, sp);
                return y;
            }
            if ints && z != NONE && (rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN) {
                // `index <= len && width <= len - index`, exact: `index + width <= len`.
                let (xw, xsg) = (self.tm.at(x).w, self.tm.at(x).sg);
                let c1 = self.tm.cmp(T_LE, x, y);
                let end = self.tm.arith(T_ADD, x, z, xw, xsg);
                let c2 = self.tm.cmp(T_LE, end, y);
                let f = self.tm.and(c1, c2);
                self.check_fact(pc, f, key, sp);
                return x;
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
    // (induction) gives the rest.
    fn define(self: &mut Self, r: u32, d: DefId, xs: &Vector<u32>, state: &Vector<u32>) {
        if self.defined.contains_key(&r) {
            return;
        }
        self.defined.insert(r, true);
        let cbp = self.kept(d);
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
        let _ = self.chain_in(cb, d.module, site, &frame, &pc0, true, none, &mut leaves);
        self.chain_ovf = co;
        self.chain_depth -= 1;
        self.unfold -= 1;
        self.in_ghost = ig;
        self.mem = om;
        let mut f = self.tm.not(pre);
        for j in 0..leaves.len() {
            let path = (leaves[j] >> 32) as u32;
            let v = (leaves[j] & 0xFFFFFFFFu64) as u32;
            let eq = self.tm.cmp(T_EQ, r, v);
            let one = self.tm.and(path, eq);
            f = self.tm.or(f, one);
        }
        if !self.tm.is_true(f) && !self.tm.is_false(f) {
            self.anchor(r, f);
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
        return f, value;
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
        let mut r = self.wide_op(cb, cm, state, pc, t, all, self.chain_ovf, key, sp);
        if r == NONE {
            r = self.call_value(cb, cm, state, t, all);
        }
        if t.dests_len == 1 {
            self.write_place(cb, cm, state, cb.dest_pool[t.dests_start as usize], r, all);
        } else {
            for j in t.dests_start..t.dests_start + t.dests_len {
                self.write_place(cb, cm, state, cb.dest_pool[j as usize], NONE, all);
            }
        }
    }

    // Callee `d` as an operation of a wide integer (`UInt<N>`, `Int<N>`; std's conformances in its
    // `int` module, which keep these meanings): WK_FROM `from` (`u64` or `i64` to the type), WK_EQ `eq`,
    // WK_CMP `cmp` (-1, 0 or 1), WK_ADD, WK_SUB and WK_MUL `add`, `sub` and `mul` (trap or wrap on
    // overflow as the built-in integers do), WK_DIV and WK_REM `div` and `rem` (a zero divisor and
    // `MIN / -1` trap), WK_AND, WK_OR, WK_XOR and WK_NOT the bit operations, WK_SHL and WK_SHR `shl`
    // and `shr` (a count of at least the width gives 0, or -1 for a negative `Int` shifted right: no
    // trap); and of the built-in integers (std's `core` module): WK_WADD, WK_WSUB, WK_WMUL and WK_WNEG
    // `wrapping_add`, `wrapping_sub`, `wrapping_mul` and `wrapping_neg` (the result's low bits),
    // WK_ROTL and WK_ROTR `rotate_left` and `rotate_right`; 0 for any other callee.
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
        let n = pick(k == WK_FROM || k == WK_NOT || k == WK_WNEG, 1u32, 2);
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
            pc.push(self.tm.cmp(T_NE, b, z));
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

    // Fact `f` of every obligation that names term `r` (`add_defs`).
    fn anchor(self: &mut Self, r: u32, f: u32) {
        if let Some(i) = self.def_of.get(&r) {
            let j = (*i) as usize;
            let g = self.tm.and(self.defs[j], f);
            self.defs.set(j, g);
            return;
        }
        self.def_of.insert(r, self.defs.len() as u32);
        self.defs.push(f);
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
        // `int` holds every integer, `nat` every one at least 0; a fixed type no exact one.
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
        let r = self.tm.call(key, &xs, w, sg);
        // A call over constants unfolds again, to UNFOLD_MAX deep: `pow2(3) == 8` is computed.
        let mut lit = true;
        for j in 0..xs.len() {
            let op = self.tm.at(xs[j]).op;
            lit = lit && (op == T_INT || op == T_BOOL);
        }
        if (self.unfold == 0 || lit && self.unfold < UNFOLD_MAX) && t.targs_len == 0 && self.is_ghost(t.callee) {
            self.define(r, t.callee, &xs, state);
        }
        return r;
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
            if t.kind == ir::TM_DROP || t.kind == ir::TM_CALL && !self.is_const_fn(t.callee) && !self.panics(t.callee) && !self.is_ghost(
                t.callee,
            ) && self.wide_kind(t.callee) == 0 {
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
        self.derived.clear();
        self.defs.clear();
        self.def_of.clear();
        self.defined.clear();
        self.exact_body = false;
    }

    // Whether `d` is a spec function or a lemma.
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

    // Fact `f` of a check on the path `pc`: in ghost code an obligation first (`key` at `sp`).
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
    fn lower_shells(self: &mut Self, sh: &mut Shared) {
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
        self.ghost_fn = self.is_ghost(b.owner);
        if !self.needs_proof(b) && !refining && !self.ghost_fn {
            return;
        }
        self.b = bp;
        self.clear_terms();
        for l in 0..b.locals.len() {
            let (w, _sg) = self.ty_of(b.module, b.locals.at(l).ty);
            self.exact_body = self.exact_body || exact_w(w);
        }
        self.sv.steps = 0;
        self.steps = 0;
        self.over = false;
        self.failed.clear();
        self.begin_sites(b, refining);
        self.ovf = if b.contracts.len() != 0 || self.ghost_fn {
            OVF_PROVE
        } else {
            OVF_KEEP
        };
        // Ghost code must end: a spec function or a lemma as a function with a measure does.
        self.fn_dec = self.has_fn_dec(b) || self.ghost_fn;
        if !refining {
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
        self.gblk.clear();
        self.gblk.resize_default(nb);
        for j in 0..b.contracts.len() {
            let s = b.contracts[j];
            self.site_of_chain.set(s.chain as usize, j as u32);
            self.site_of_pred.set(s.pred as usize, j as u32);
            if ir::is_ghost_site(s.kind) {
                for x in s.chain..s.cont {
                    self.gblk.set(x as usize, true);
                }
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
        if s != NONE && b.contracts[s as usize].pred == from && !ir::is_ghost_site(b.contracts[s as usize].kind) {
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
        let z = self.tm.int(Num::<B>::zero(), vx.w, vx.sg);
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
        self.in_ghost = self.ghost_fn || self.gblk[path.blk as usize];
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
            }
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
        let d = t.callee;
        // Ghost code never runs: a panic in it is a check that fails.
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
        }
        // A spec function or a lemma only reads its arguments.
        let ghost = self.is_ghost(d);
        for j in 0..t.args_len {
            if self.autoref(b, b.module, t, j) && !ghost {
                let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
                self.escape(b.places.at(op.data as usize).base);
            }
        }
        let r = self.call_value(b, b.module, &mut path.state, t, false);
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
                            self.tm.make(
                                Term::<B> { k: Num::<B>::zero(), a: pl.base, b: 0, op: T_MREF, w: W_OTHER, sg: false },
                            )
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
            if self.tm.at(r).op != T_CALL && !ghost {
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
                if s.kind == CT_ENSURES && (!self.in_ghost || self.total(d)) {
                    let (f, _v) = self.chain(cb, cm, s, &frame, &path.pc, true, t.span);
                    path.pc.push(f);
                }
            }
            self.mem = null;
        } else if self.tm.at(r).op != T_CALL && !ghost {
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
    let mut sh = Shared { shells: Vector::<ir::CoreBody>::new(), shell_ix: Map::<u64, u32>::new(), scc: comp.clone() };
    let mut pv = Prover::<NUM_NARROW>::new(p, keep, p.prelude_lookup("Slice", true));
    pv.lower_shells(&mut sh);
    pv.sh = &sh;
    let n = keep.kept.len();
    // A body with an integer wider than the narrow numbers hold proves with the wide ones.
    let mut wide = Vector::<bool>::with_capacity(n);
    for k in 0..n {
        let kb = keep.kept.at(k);
        wide.push(kb.body.blocks.len() != 0 && !skip[kb.body.module as usize] && pv.needs_wide(k));
    }
    if p.jobs == 1 || n < 2 {
        let mut pw = Prover::<NUM_WIDE>::new(p, keep, pv.slice);
        pw.sh = &sh;
        for k in 0..n {
            let kb = keep.kept.at(k);
            if kb.body.blocks.len() == 0 || skip[kb.body.module as usize] {
                continue;
            }
            if !wide[k] {
                pv.prove_kept(k);
                continue;
            }
            pw.prove_kept(k);
            let m = kb.body.module as usize;
            pv.errs.index_mut(m).append(pw.errs.index_mut(m));
        }
    } else {
        // One prover per chunk of bodies, each body's reports in a container of its own; a walk
        // reads only the package, the keep and the shared state. The reports merge in body order and
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
        let ha = ((&sh) as *const Shared) as usize;
        let sa = (skip as *const Vector<bool>) as usize;
        let wa = ((&wide) as *const Vector<bool>) as usize;
        let oa = outs.as_mut_ptr() as usize;
        let slice = pv.slice;
        // A chunk's cost is its bodies': each worker claims one chunk at a time.
        dpar::range_with(
            0..chunks,
            dpar::Options { schedule: dpar::Schedule::Dynamic, grain_size: 1 },
            |c: usize| {
                let pk = unsafe &*ptr::from_addr_mut::<loader::Package>(pa);
                let kp = unsafe &*ptr::from_addr_mut::<irl::Keep>(ka);
                let sk = unsafe &*ptr::from_addr_mut::<Vector<bool>>(sa);
                let wd = unsafe &*ptr::from_addr_mut::<Vector<bool>>(wa);
                let mut w = Prover::<NUM_NARROW>::new(pk, kp, slice);
                w.sh = ptr::from_addr_mut::<Shared>(ha);
                let mut w2 = Prover::<NUM_WIDE>::new(pk, kp, slice);
                w2.sh = ptr::from_addr_mut::<Shared>(ha);
                for k in c * n / chunks..(c + 1) * n / chunks {
                    let kb = kp.kept.at(k);
                    if kb.body.blocks.len() == 0 || sk[kb.body.module as usize] {
                        continue;
                    }
                    let m = kb.body.module as usize;
                    let e = if wd[k] {
                        w2.prove_kept(k);
                        replace(w2.errs.index_mut(m), diag::Errors::new())
                    } else {
                        w.prove_kept(k);
                        replace(w.errs.index_mut(m), diag::Errors::new())
                    };
                    unsafe *(ptr::from_addr_mut::<diag::Errors>(oa) + k) = e;
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
