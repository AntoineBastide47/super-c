// Core effect and range-fact service over one final elaborated CoreBody. Three layers, each usable
// alone:
//
// 1. Memory effects (`stmt_effect`, `term_effect`): what one statement or terminator can write, as
//    a pure function of the body. A verified intrinsic call (`Terminator.intr`) has its exact effect;
//    inline assembly is an unknown heap write plus its output places.
// 2. Version tracking for a forward walk in reverse postorder (`Facts`): a value fact is keyed by
//    (local, version), where the version bumps on every write of the local, and a collection
//    fact by (place, heap, base, path and buffer generations): a write into one field of a base
//    spares the others, a write into a view's element buffer spares every header out of heap
//    memory, and an unknown write cannot reach a local whose address never escaped. A block
//    entered from other paths than the one the walk came from bumps every local written since its
//    immediate dominator ended, and a loop header bumps every local, base and heap the loop can
//    write, so a version names one value on every path. Copy, affine and reference bindings, the
//    escape set (one scan of the body before the walk) and the call and drop transparency rules
//    live here.
// 3. Integer facts (`IFact`): per local, a wrapped interval, a stride and known bits, solved on
//    demand by one intraprocedural worklist in reverse postorder over block-entry states. Every
//    table has a fixed bound; an overflow makes the fact unknown and sets `ilimited`.
import ast::ast as *;
import lexer::token_type as tt;
import ir::core as ir;
import ir::layout as lay;
import module::loader as loader;

// ---- memory effects --------------------------------------------------------------------------------

pub const EF_NONE: u8 = 0; // reads at most
pub const EF_WRITE: u8 = 1; // writes place `a` (a whole local, an interior, or through a deref)
pub const EF_PTR: u8 = 2; // writes through pointer operand `a` (a memory or atomic intrinsic, a vector store)
pub const EF_SYNC: u8 = 3; // writes nothing, but an ordered atomic makes other threads' writes visible
pub const EF_CALL: u8 = 4; // an unknown call: the heap, statics, escaped storage and the `roots`
pub const EF_DROP: u8 = 5; // drops place `a`: its ownership tree, or what a call reaches
pub const EF_ASM: u8 = 6; // inline assembly: an unknown heap write plus the output places' `roots`

const ROOTS_MAX: u32 = 16;

/// One statement's or terminator's memory effect. `roots` are locals the operation can write as a
/// whole (passed by mutable reference, or an assembly output); `over` means more than fit.
pub struct Effect {
    pub roots: [u32; 16],
    pub a: u32,
    pub n: u32,
    pub kind: u8,
    pub over: bool,
}

const fn effect(kind: u8, a: u32) Effect {
    return Effect { roots: [[0] = 0u32], a: a, n: 0, kind: kind, over: false };
}

fn push_root(e: &mut Effect, l: u32) {
    for i in 0..e.n {
        if unsafe e.roots[i as usize] == l {
            return;
        }
    }
    if e.n >= ROOTS_MAX {
        e.over = true;
        return;
    }
    unsafe e.roots[e.n as usize] = l;
    e.n += 1;
}

/// The effect of statement `s`. A vector store (`SM_WRITE`: `SIMD_STORE`, `SIMD_STORE_RAW`; and
/// `SM_WRITE_LANES`: the masked, scatter and compressing stores, one element per active lane at a
/// lane-dependent address) writes through operand 0, a slice, a pointer or an array of pointers; a
/// vector load only reads through it.
pub fn stmt_effect(b: &ir::CoreBody, s: &ir::Statement) Effect {
    if s.kind != ir::ST_ASSIGN {
        return effect(EF_NONE, ir::IR_NONE);
    }
    let rv = b.rvalues.at(s.rvalue as usize);
    if rv.kind == ir::RV_SIMD {
        assert(rv.c as usize < ir::SIMD_CODES, "an RV_SIMD code without a table row");
        if ir::simd_writes(rv.c) {
            return effect(EF_PTR, b.oper_pool[rv.a as usize]);
        }
    }
    if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_ASM {
        let mut e = effect(EF_ASM, s.place);
        let nout = b.asms.at(rv.item.node as usize).nout;
        for i in 0..nout {
            let op = *b.operands.at(b.oper_pool[(rv.a + i) as usize] as usize);
            push_root(&mut e, b.places.at(op.data as usize).base);
        }
        return e;
    }
    return effect(EF_WRITE, s.place);
}

// A constant memory-order operand naming Relaxed (0): the atomic orders nothing.
const fn relaxed(b: &ir::CoreBody, opid: u32) bool {
    let op = *b.operands.at(opid as usize);
    if op.kind != ir::OP_CONST {
        return false;
    }
    let c = *b.constants.at(op.data as usize);
    return c.kind == ir::CK_INT && c.val == 0;
}

/// True when `t` calls the borrow-pure prelude length getter `fn len(&self)` on a place: its shared
/// receiver cannot mutate the collection.
pub fn is_prelude_len_call(pkg: *const loader::Package, b: &ir::CoreBody, t: &ir::Terminator) bool {
    if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE || t.args_len != 1 || t.dests_len != 1 {
        return false;
    }
    let pk = unsafe &*pkg;
    if !pk.modules.at(t.callee.module as usize).prelude {
        return false;
    }
    let da = unsafe &*pk.module_ast_const(t.callee.module);
    let nd = da.at_const(t.callee.node);
    if nd.kind != NodeKind::NODE_FUNCTION {
        return false;
    }
    if b.operands.at(b.oper_pool[t.args_start as usize] as usize).kind == ir::OP_CONST {
        return false;
    }
    let ns = da.at_const(nd.as_data.function.name).as_data.name.text;
    let src = pk.modules.at(t.callee.module as usize).source.as_str();
    return src.slice(ns.start as usize, ns.end as usize) == "len";
}

/// The effect of terminator `t`. A call's destinations are written after its effect.
pub fn term_effect(pkg: *const loader::Package, b: &ir::CoreBody, t: &ir::Terminator) Effect {
    if t.kind == ir::TM_DROP {
        let k = (unsafe &*(&*pkg).module_ast_const(b.module)).type_at(b.places.at(t.a as usize).ty).kind;
        if k == TypeKind::TYPE_BUILTIN || k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE {
            return effect(EF_NONE, ir::IR_NONE); // no drop glue runs
        }
        return effect(EF_DROP, t.a);
    }
    if t.kind != ir::TM_CALL {
        return effect(EF_NONE, ir::IR_NONE);
    }
    let k = t.intr;
    if k != ir::CI_NONE {
        let a0 = b.oper_pool[t.args_start as usize];
        if k == ir::CI_FENCE {
            if relaxed(b, a0) {
                return effect(EF_NONE, ir::IR_NONE);
            }
            return effect(EF_SYNC, ir::IR_NONE);
        }
        if k == ir::CI_ATOMIC_LOAD {
            if relaxed(b, b.oper_pool[(t.args_start + 1) as usize]) {
                return effect(EF_NONE, ir::IR_NONE);
            }
            return effect(EF_SYNC, ir::IR_NONE);
        }
        return effect(EF_PTR, a0);
    }
    if is_prelude_len_call(pkg, b, t) {
        return effect(EF_NONE, ir::IR_NONE);
    }
    let mut e = effect(EF_CALL, ir::IR_NONE);
    let da = unsafe &*(&*pkg).module_ast_const(b.module);
    for i in 0..t.args_len {
        let op = *b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize);
        if op.kind == ir::OP_CONST {
            continue;
        }
        let y = da.type_at(op.ty);
        if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 && !b.place_has_deref(
            op.data,
        ) {
            push_root(&mut e, b.places.at(op.data as usize).base);
        }
    }
    return e;
}

// ---- version tracking --------------------------------------------------------------------------------

/// A resolved operand key: a constant, or (local, version) plus an affine constant offset, or opaque.
/// Two local keys with equal (l, v, off) name the SAME run-time value (identical expressions over the
/// same definition), also when the addition wrapped. No order is derived from two different offsets.
pub struct VKey {
    pub c: i64,
    pub off: i64,
    pub l: u32,
    pub v: u32,
    pub is_const: bool,
    pub is_local: bool,
}

pub const fn vkey_none() VKey {
    return VKey { is_const: false, c: 0, is_local: false, l: 0, v: 0, off: 0 };
}

// Per-local bindings, each stamped with the version of its OWNER local at definition time so a
// redefinition invalidates it without a sweep.
pub struct CopyBind {
    pub src: u32,
    pub src_v: u32,
    pub my_v: u32,
    pub ok: bool,
}
// dest = src + c (usize only; c may be negative for a Minus form)
pub struct AffBind {
    pub src: u32,
    pub src_v: u32,
    pub c: i64,
    pub my_v: u32,
    pub ok: bool,
}
pub struct RefBind {
    pub pl: u32,
    pub my_v: u32,
    pub ok: bool,
}

/// Place identities with this bit set are SYNTHETIC: the low bits name the reference LOCAL a
/// `[r, deref, .len]` read routed through. Two synthetic identities match on equal ids only.
pub const SYNTH_PL: u32 = 0x80000000u32;

// Fixed bounds: the exposed scalars a heap write kills, the escaped roots, pending mutable borrows,
// the loop-header scan work, the integer facts a block-entry state keeps, the entry-state pool and
// the solver's block visits.
const EXPOSED_MAX: usize = 64;
const ESC_MAX: usize = 16;
const PEND_MAX: usize = 8;
const IWIDTH_MAX: usize = 64;
const IPOOL_MAX: usize = 65536;
const PKILL_MAX: usize = 256;

// One loop-scan write: k 0 rekeys local `a`, 1 also its base generation, 2 writes place `p` of base
// `a`.
struct LOp {
    pub a: u32,
    pub p: u32,
    pub k: u8,
}

// A write that reached only the subtree of place `pl` (base `base`), at path generation `pg`.
struct PKill {
    pub base: u32,
    pub pg: u32,
    pub pl: u32,
}

// ---- integer facts -----------------------------------------------------------------------------------

/// A wrapped integer fact of one local at its type's width: the value lies in [lo, hi] (sign and
/// magnitude: `ln`/`hn` mark a negative bound), is `ph + k * st` for some integer k (`st` 1 = no
/// stride; an exact fact has lo == hi), and has the bits of `kz` clear and the bits of `ko` set (two's
/// complement at the width). `wid` marks a fact a loop-header widening changed.
pub struct IFact {
    pub lo: u64,
    pub hi: u64,
    pub kz: u64,
    pub ko: u64,
    pub st: u64,
    pub ph: u64,
    pub ln: bool,
    pub hn: bool,
    pub wid: bool,
}

struct IEnt {
    pub f: IFact,
    pub l: u32,
}

// A mathematical integer in [-2^64 + 1, 2^64 - 1]: sign and magnitude. Every type range fits, so the
// transfer functions compute exactly and test the target range; a magnitude overflow is out of every
// range.
struct Z {
    pub m: u64,
    pub n: bool,
}

const fn zk(m: u64, n: bool) Z {
    return Z { m: m, n: n && m != 0 };
}

const fn zlt(a: Z, b: Z) bool {
    if a.n != b.n {
        return a.n;
    }
    if a.n {
        return a.m > b.m;
    }
    return a.m < b.m;
}

const fn zle(a: Z, b: Z) bool {
    return !zlt(b, a);
}

const fn zadd(a: Z, b: Z, ok: &mut bool) Z {
    if a.n == b.n {
        let (s, o) = a.m.overflowing_add(b.m);
        if o {
            *ok = false;
        }
        return zk(s, a.n);
    }
    if a.m >= b.m {
        return zk(a.m - b.m, a.n);
    }
    return zk(b.m - a.m, b.n);
}

const fn zneg(a: Z) Z {
    return zk(a.m, !a.n);
}

const fn zmul(a: Z, b: Z, ok: &mut bool) Z {
    let (p, o) = a.m.overflowing_mul(b.m);
    if o {
        *ok = false;
    }
    return zk(p, a.n != b.n);
}

// The residue of `a` modulo `m` (m >= 1), in [0, m).
const fn zres(a: Z, m: u64) u64 {
    let r = a.m % m;
    if a.n && r != 0 {
        return m - r;
    }
    return r;
}

pub const fn gcd(a0: u64, b0: u64) u64 {
    let mut a = a0;
    let mut b = b0;
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    return a;
}

const fn wmask(w: u32) u64 {
    if w >= 64 {
        return 0xFFFFFFFFFFFFFFFFu64;
    }
    return (1u64 << w as u64) - 1;
}

const fn tmin(w: u32, sg: bool) Z {
    if !sg {
        return zk(0, false);
    }
    return zk(1u64 << (w - 1) as u64, true);
}

const fn tmax(w: u32, sg: bool) Z {
    if !sg {
        return zk(wmask(w), false);
    }
    return zk((1u64 << (w - 1) as u64) - 1, false);
}

const fn flo(f: &IFact) Z {
    return zk(f.lo, f.ln);
}

const fn fhi(f: &IFact) Z {
    return zk(f.hi, f.hn);
}

/// The unknown fact at width `w`.
pub const fn itop(w: u32, sg: bool) IFact {
    let a = tmin(w, sg);
    let c = tmax(w, sg);
    return IFact { lo: a.m, ln: a.n, hi: c.m, hn: c.n, kz: 0, ko: 0, st: 1, ph: 0, wid: false };
}

// The bit pattern of value `v` at width `w`.
const fn zbits(v: Z, w: u32) u64 {
    if v.n {
        return v.m.wrapping_neg() & wmask(w);
    }
    return v.m & wmask(w);
}

/// The exact fact for value `v` at width `w`.
const fn iconst(v: Z, w: u32) IFact {
    let bits = zbits(v, w);
    return IFact { lo: v.m, ln: v.n, hi: v.m, hn: v.n, kz: ~bits & wmask(w), ko: bits, st: 1, ph: 0, wid: false };
}

/// Is the fact exact (one value)?
pub const fn iexact(f: &IFact) bool {
    return f.lo == f.hi && f.ln == f.hn;
}

/// Does `f` carry nothing at width `w`?
const fn iis_top(f: &IFact, w: u32, sg: bool) bool {
    let a = tmin(w, sg);
    let c = tmax(w, sg);
    return f.lo == a.m && f.ln == a.n && f.hi == c.m && f.hn == c.n && ((f.kz | f.ko) & wmask(w)) == 0 && f.st <= 1;
}

// Set `f`'s interval to [a, c]; false when a > c (an empty set: the path cannot run).
const fn iset(f: &mut IFact, a: Z, c: Z) bool {
    f.lo = a.m;
    f.ln = a.n;
    f.hi = c.m;
    f.hn = c.n;
    return zle(a, c);
}

// The count of low bits `f` knows.
const fn known_low(f: &IFact, w: u32) u32 {
    let k = ~(f.kz | f.ko);
    let t = k.trailing_zeros() as u32;
    if t > w {
        return w;
    }
    return t;
}

// The stride and phase of `f` (an exact fact has stride 0 and its value as phase, in Z).
const fn sres(f: &IFact, m: u64) u64 {
    if iexact(f) {
        return zres(flo(f), m);
    }
    return f.ph % m;
}

/// The stride `f` proves (0 = exact).
pub const fn istride(f: &IFact) u64 {
    if iexact(f) {
        return 0;
    }
    return f.st;
}

// The stride and phase after a possible wrap at width `w`: a stride survives only when it divides
// 2^w (a power of two no larger).
const fn wrap_stride(f: &mut IFact, w: u32) {
    if f.st <= 1 {
        return;
    }
    if !f.st.is_power_of_two() || w < 64 && f.st > 1u64 << w as u64 {
        f.st = 1;
        f.ph = 0;
    }
}

// The fact for the exact Z interval [a, c] computed with `ok` (no host overflow), clipped to the
// width: out of range means the operation can wrap, so the interval is the type's.
const fn ifit(f: &mut IFact, a: Z, c: Z, ok: bool, w: u32, sg: bool) {
    if ok && zle(tmin(w, sg), a) && zle(c, tmax(w, sg)) {
        let _ = iset(f, a, c);
        return;
    }
    let _ = iset(f, tmin(w, sg), tmax(w, sg));
    wrap_stride(f, w);
}

// Known bits of an exact interval.
const fn exact_bits(f: &mut IFact, w: u32) {
    if iexact(f) {
        let bits = zbits(flo(f), w);
        f.kz = ~bits & wmask(w);
        f.ko = bits;
    }
}

// The low bits of `a + b` (`neg`: `a - b`) both operands know.
const fn add_bits(a: &IFact, b: &IFact, neg: bool, w: u32) IFact {
    let mut r = itop(w, false);
    let t = known_low(a, w).min(known_low(b, w));
    if t == 0 {
        return r;
    }
    let m = wmask(t);
    let v = if neg {
        a.ko.wrapping_sub(b.ko);
    } else {
        a.ko.wrapping_add(b.ko);
    } & m;
    r.kz = ~v & m;
    r.ko = v;
    return r;
}

// The stride of `a + b` (`neg`: `a - b`), before the wrap rule.
const fn add_stride(r: &mut IFact, a: &IFact, b: &IFact, neg: bool) {
    let sa = istride(a);
    let sb = istride(b);
    let g = gcd(sa, sb);
    if g <= 1 || g > 0x4000000000000000u64 {
        r.st = 1;
        r.ph = 0;
        return;
    }
    let pa = sres(a, g);
    let pb = sres(b, g);
    r.st = g;
    r.ph = if neg {
        (pa + g - pb) % g;
    } else {
        (pa + pb) % g;
    };
}

// The join (hull) of `a` and `b`.
const fn ijoin(a: &IFact, b: &IFact) IFact {
    let mut r = *a;
    let lo = if zlt(flo(b), flo(a)) {
        flo(b);
    } else {
        flo(a);
    };
    let hi = if zlt(fhi(a), fhi(b)) {
        fhi(b);
    } else {
        fhi(a);
    };
    let _ = iset(&mut r, lo, hi);
    r.kz = a.kz & b.kz;
    r.ko = a.ko & b.ko;
    r.wid = a.wid || b.wid;
    if iexact(&r) {
        return r;
    }
    // strides: the gcd of both strides and the phase difference
    let mut m: u64 = 0;
    if iexact(a) && iexact(b) {
        let mut ok = true;
        let d = zadd(flo(a), zneg(flo(b)), &mut ok);
        m = if ok {
            d.m;
        } else {
            1;
        };
    } else {
        let g = gcd(istride(a), istride(b));
        if g == 0 {
            m = 1;
        } else {
            let pa = sres(a, g);
            let pb = sres(b, g);
            let d = if pa > pb {
                pa - pb;
            } else {
                pb - pa;
            };
            m = gcd(g, d);
        }
    }
    if m <= 1 {
        r.st = 1;
        r.ph = 0;
    } else {
        r.st = m;
        r.ph = sres(a, m);
    }
    return r;
}

const fn ieq(a: &IFact, b: &IFact) bool {
    return a.lo == b.lo && a.ln == b.ln && a.hi == b.hi && a.hn == b.hn && a.kz == b.kz && a.ko == b.ko && a.st == b.st && a.ph == b.ph && a.wid == b.wid;
}

// The cmp binding of an in-block comparison `t = a OP b`, valid until t, a or b is written.
struct CmpRec {
    pub t: u32,
    pub a: u32, // operand ids
    pub b: u32,
    pub la: u32, // their whole locals, or IR_NONE
    pub lb: u32,
    pub op: u8,
}

pub struct Facts {
    pub pkg: *const loader::Package,
    pub pw: u32, // the target's pointer width in bits
    // CFG: reverse postorder over the reachable blocks, the RPO index of each block (IR_NONE when
    // unreachable), the predecessor lists, the forward predecessor counts and immediate dominators.
    pub rpo: Vector<u32>,
    pub rpo_of: Vector<u32>,
    pub npred: Vector<u32>,
    pub fwd: Vector<u32>,
    pub pstart: Vector<u32>,
    pub plist: Vector<u32>,
    pub idom: Vector<u32>,
    pub seen: Vector<u8>,
    pub succs: Vector<u32>,
    pub backs: Vector<u64>, // back edges: source << 32 | target
    pub sstart: Vector<u32>,
    pub stack: Vector<u64>,
    // versions and generations
    pub lver: Vector<u32>,
    pub vclock: u32,
    pub vfloor: u32,
    pub basegen: Vector<u32>,
    pub heapgen: u32,
    // writes into the element buffer of a prelude view (bumped by every heap write too): only a place
    // heap memory may hold (`resident`) can change by one
    pub bufgen: u32,
    // path generations: a write into one subtree of a base bumps `pgen[base]` and logs the subtree;
    // a place identity captured at path generation g survives the logged kills after g that do
    // not overlap it
    pub pgen: Vector<u32>,
    pub pkills: Vector<PKill>,
    pub copyof: Vector<CopyBind>,
    // a prelude view built by a struct literal: its `len` field holds `src`; a `len` read of such a
    // view: its value is `src` (`view_len`)
    pub lenval: Vector<CopyBind>,
    pub views: bool, // some view of this body was built by a struct literal: `view_len` can answer
    pub affof: Vector<AffBind>,
    pub refof: Vector<RefBind>,
    // the written locals in walk order (a log), and each block's log length when the walk left it
    pub wlog: Vector<u32>,
    pub wold: Vector<u32>, // per `wlog` entry: the local's version before the write
    pub clk_end: Vector<u32>,
    pub bst: Vector<u32>, // dedupe stamps of one bump batch
    pub bstamp: u32,
    // loop-header scan: block marks, the loop's blocks, the remaining scan work
    pub lmark: Vector<u32>,
    pub lstamp: u32,
    pub lblocks: Vector<u32>,
    // per-block loop-scan summaries (lsummarize): op ranges into `lops` (start IR_NONE = not yet),
    // flags, and the flags of the block being summarized
    pub lops: Vector<LOp>,
    pub lsum_s: Vector<u32>,
    pub lsum_n: Vector<u32>,
    pub lsum_f: Vector<u8>,
    pub lfl: u8,
    pub scan_left: i64,
    // the single definition of a local (statement id) or IR_NONE
    pub def1: Vector<u32>,
    pub ndef: Vector<u8>,
    // exposure: scalar locals whose storage a pointer or a call can write (address taken mutably, or
    // a static); `expover` when more than EXPOSED_MAX, which makes all of them opaque
    pub exposed: Vector<bool>,
    pub explist: Vector<u32>,
    pub expover: bool,
    pub esc_use: Vector<bool>,
    // statements an escape or an interval proof may start from, found by the definition scan
    pub ecand: Vector<u32>,
    pub gcand: Vector<u32>,
    pub grem: bool,
    // locals that may hold a borrow of a deref-free place (a local's own storage)
    pub holds: Vector<bool>,
    // locals a slice views: their storage is a view's element buffer
    pub bufexp: Vector<bool>,
    // signature transparency (see call_transparent)
    pub off_sig: bool, // SC_BCE_DISABLE=sig
    pub escall: bool,
    pub escroot: Vector<bool>,
    pub esclist: Vector<u32>,
    pub statics: Vector<u32>,
    // integer facts: per-local width (0 = untracked) and signedness, cross-block locals, the dense
    // scratch of the block being evaluated (valid where cst == stamp), the block-entry states, the
    // narrowing accumulators, the worklist state
    pub iw: Vector<u8>,
    pub isg: Vector<bool>,

    pub cur: Vector<IFact>,
    pub cst: Vector<u32>,
    pub stamp: u32,
    pub live: Vector<u32>,
    pub cmps: Vector<CmpRec>,
    pub ent: Vector<IEnt>,
    pub ent_start: Vector<u32>,
    pub ent_len: Vector<u32>,
    pub ent_set: Vector<bool>,
    pub nar: Vector<IEnt>,
    pub nar_start: Vector<u32>,
    pub nar_len: Vector<u32>,
    pub nar_set: Vector<bool>,
    pub dirty: Vector<bool>,
    pub nwide: Vector<u8>,
    pub ebuf: Vector<IEnt>,
    pub jbuf: Vector<IEnt>,
    // the solver's slice: per statement, whether its transfer can change a tracked fact; per block,
    // the tracked locals its terminator makes unknown (CSR over `tkill`)
    pub srel: Vector<bool>,
    pub tk_start: Vector<u32>,
    pub tkill: Vector<u32>,
    pub cmpt: Vector<bool>, // comparison results: a rewrite ends their binding
    pub irel: Vector<bool>, // tracked locals
    pub ion: bool, // the solver ran for this body
    pub ilimited: bool,
}

extend Facts {
    pub fn new(off_sig: bool) Facts {
        return Facts {
            pkg: null,
            pw: 64,
            rpo: Vector::<u32>::new(),
            rpo_of: Vector::<u32>::new(),
            npred: Vector::<u32>::new(),
            fwd: Vector::<u32>::new(),
            pstart: Vector::<u32>::new(),
            plist: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            seen: Vector::<u8>::new(),
            succs: Vector::<u32>::new(),
            backs: Vector::<u64>::new(),
            sstart: Vector::<u32>::new(),
            stack: Vector::<u64>::new(),
            lver: Vector::<u32>::new(),
            vclock: 0,
            vfloor: 0,
            basegen: Vector::<u32>::new(),
            heapgen: 0,
            bufgen: 0,
            pgen: Vector::<u32>::new(),
            pkills: Vector::<PKill>::new(),
            copyof: Vector::<CopyBind>::new(),
            lenval: Vector::<CopyBind>::new(),
            views: false,
            affof: Vector::<AffBind>::new(),
            refof: Vector::<RefBind>::new(),
            wlog: Vector::<u32>::new(),
            wold: Vector::<u32>::new(),
            clk_end: Vector::<u32>::new(),
            bst: Vector::<u32>::new(),
            bstamp: 0,
            lmark: Vector::<u32>::new(),
            lstamp: 0,
            lblocks: Vector::<u32>::new(),
            lops: Vector::<LOp>::new(),
            lsum_s: Vector::<u32>::new(),
            lsum_n: Vector::<u32>::new(),
            lsum_f: Vector::<u8>::new(),
            lfl: 0,
            scan_left: 0,
            def1: Vector::<u32>::new(),
            ndef: Vector::<u8>::new(),
            exposed: Vector::<bool>::new(),
            explist: Vector::<u32>::new(),
            expover: false,
            esc_use: Vector::<bool>::new(),
            ecand: Vector::<u32>::new(),
            gcand: Vector::<u32>::new(),
            grem: false,
            holds: Vector::<bool>::new(),
            bufexp: Vector::<bool>::new(),
            off_sig: off_sig,
            escall: false,
            escroot: Vector::<bool>::new(),
            esclist: Vector::<u32>::new(),
            statics: Vector::<u32>::new(),
            iw: Vector::<u8>::new(),
            isg: Vector::<bool>::new(),
            cur: Vector::<IFact>::new(),
            cst: Vector::<u32>::new(),
            stamp: 0,
            live: Vector::<u32>::new(),
            cmps: Vector::<CmpRec>::new(),
            ent: Vector::<IEnt>::new(),
            ent_start: Vector::<u32>::new(),
            ent_len: Vector::<u32>::new(),
            ent_set: Vector::<bool>::new(),
            nar: Vector::<IEnt>::new(),
            nar_start: Vector::<u32>::new(),
            nar_len: Vector::<u32>::new(),
            nar_set: Vector::<bool>::new(),
            dirty: Vector::<bool>::new(),
            nwide: Vector::<u8>::new(),
            ebuf: Vector::<IEnt>::new(),
            jbuf: Vector::<IEnt>::new(),
            srel: Vector::<bool>::new(),
            tk_start: Vector::<u32>::new(),
            tkill: Vector::<u32>::new(),
            cmpt: Vector::<bool>::new(),
            irel: Vector::<bool>::new(),
            ion: false,
            ilimited: false,
        };
    }

    // ---- CFG -----------------------------------------------------------------------------------------

    // The successors of block `blk`'s terminator: switch targets first, then the shared t0 edge.
    const fn succ_count(self: &Self, b: &ir::CoreBody, blk: usize) u32 {
        let t = &b.blocks.at(blk).term;
        let mut n: u32 = 0;
        if t.kind == ir::TM_SWITCH {
            n = t.sw_len;
        }
        if t.kind == ir::TM_GOTO || t.kind == ir::TM_CALL || t.kind == ir::TM_DROP || t.kind == ir::TM_ASSERT || t.kind == ir::TM_SWITCH {
            n += 1;
        }
        return n;
    }

    const fn succ_at(self: &Self, b: &ir::CoreBody, blk: usize, i: u32) u32 {
        let t = &b.blocks.at(blk).term;
        if t.kind == ir::TM_SWITCH && i < t.sw_len {
            return (b.switch_pool[(t.sw_start + i) as usize] & 0xFFFFFFFFu64) as u32;
        }
        return t.t0;
    }

    /// Reset every per-body table for body `b`; capacity persists across bodies.
    pub fn begin(self: &mut Self, b: &ir::CoreBody, pkg: *const loader::Package) {
        self.pkg = pkg;
        self.pw = lay::target_for(unsafe (&*pkg).arch).ptr as u32 * 8;
        let nl = b.locals.len();
        let nb = b.blocks.len();
        self.build_cfg(b);
        // Versions, generations, write sequence numbers and bindings carry over from the previous
        // body: the clock continues and the floor rises past every earlier value, so nothing stale
        // matches and no per-local table is cleared.
        if self.vclock > 0xC0000000u32 {
            self.lver.clear();
            self.basegen.clear();
            self.copyof.clear();
            self.lenval.clear();
            self.affof.clear();
            self.refof.clear();
            self.vclock = 0;
        }
        if self.lver.len() < nl {
            self.lver.resize_default(nl);
            self.basegen.resize_default(nl);
            self.pgen.resize_default(nl);
        }
        while self.copyof.len() < nl {
            self.copyof.push(CopyBind { src: 0, src_v: 0, my_v: 0, ok: false });
            self.lenval.push(CopyBind { src: 0, src_v: 0, my_v: 0, ok: false });
            self.affof.push(AffBind { src: 0, src_v: 0, c: 0, my_v: 0, ok: false });
            self.refof.push(RefBind { pl: 0, my_v: 0, ok: false });
        }
        self.vclock += 1;
        self.vfloor = self.vclock;
        self.heapgen = 0;
        self.bufgen = 0;
        self.pkills.clear();
        self.wlog.clear();
        self.wold.clear();
        self.views = false;
        if self.clk_end.len() < nb {
            self.clk_end.resize_default(nb);
        }
        while self.bst.len() < nl {
            self.bst.push(0);
        }
        while self.lmark.len() < nb {
            self.lmark.push(0);
        }
        self.lops.clear();
        self.lsum_s.clear();
        self.lsum_s.resize_default(nb);
        self.lsum_n.clear();
        self.lsum_n.resize_default(nb);
        self.lsum_f.clear();
        self.lsum_f.resize_default(nb);
        self.scan_left = 8 * b.statements.len() as i64 + 4096;
        self.escall = false;
        self.escroot.clear();
        self.escroot.resize_default(nl);
        self.esclist.clear();
        self.statics.clear();
        self.scan_defs(b);
        self.ion = false;
        self.ilimited = false;
    }

    // Reverse postorder, predecessor lists, forward predecessor counts, immediate dominators.
    fn build_cfg(self: &mut Self, b: &ir::CoreBody) {
        let nb = b.blocks.len();
        self.rpo.clear();
        self.seen.clear();
        self.seen.resize_default(nb);
        self.npred.clear();
        self.npred.resize_default(nb);
        // each reachable block's successors once, in expansion order (`sstart` per block)
        self.succs.clear();
        self.sstart.clear();
        self.sstart.resize_default(nb);
        self.stack.clear();
        self.stack.push(b.entry as u64 << 1);
        self.seen.set(b.entry as usize, 1);
        while self.stack.len() != 0 {
            let top = self.stack[self.stack.len() - 1];
            let _ = self.stack.pop();
            let blk = (top >> 1) as usize;
            if (top & 1) != 0 {
                self.rpo.push(blk as u32);
                continue;
            }
            self.stack.push(top | 1);
            self.sstart.set(blk, self.succs.len() as u32);
            for i in 0..self.succ_count(b, blk) {
                let s = self.succ_at(b, blk, i);
                self.succs.push(s);
                self.npred.set(s as usize, self.npred[s as usize] + 1);
                if self.seen[s as usize] == 0 {
                    self.seen.set(s as usize, 1);
                    self.stack.push(s as u64 << 1);
                }
            }
        }
        self.rpo.reverse();
        if self.rpo_of.len() < nb {
            self.rpo_of.resize_default(nb); // read only for reachable blocks (`seen`)
        }
        for i in 0..self.rpo.len() {
            self.rpo_of.set(self.rpo[i] as usize, i as u32);
        }
        // predecessor lists over the reachable blocks (CSR), counted per edge
        self.fwd.clear();
        self.fwd.resize_default(nb);
        // pstart first holds each block's end offset; filling backwards leaves its start
        self.pstart.clear();
        let mut acc: u32 = 0;
        for i in 0..nb {
            acc += self.npred[i];
            self.pstart.push(acc);
        }
        self.pstart.push(acc);
        self.plist.clear();
        self.plist.resize_default(acc as usize);
        self.backs.clear();
        if self.rpo.len() == 0 {
            return;
        }
        // Immediate dominators (Cooper, Harvey, Kennedy) over RPO indices, in the same pass: the
        // forward predecessors give the dominators of a reducible graph; a back edge whose target
        // does not dominate its source marks an irreducible one, solved by the general iteration
        // below.
        if self.idom.len() < nb {
            self.idom.resize_default(nb); // every reachable block's entry is set below
        }
        let e = self.rpo[0];
        self.idom.set(e as usize, e);
        for bi in 0..self.rpo.len() {
            let p = self.rpo[bi];
            let s0 = self.sstart[p as usize] as usize;
            for k in s0..s0 + self.succ_count(b, p as usize) as usize {
                let s = self.succs[k] as usize;
                let c = self.pstart[s] - 1;
                self.plist.set(c as usize, p);
                self.pstart.set(s, c);
                if self.rpo_of[s] > bi as u32 {
                    if self.fwd[s] == 0 {
                        self.idom.set(s, p);
                    } else {
                        self.idom.set(s, self.intersect(p, self.idom[s]));
                    }
                    self.fwd.set(s, self.fwd[s] + 1);
                } else {
                    self.backs.push(p as u64 << 32 | s as u64); // a back edge
                }
            }
        }
        let mut reducible = true;
        for k in 0..self.backs.len() {
            let e9 = self.backs[k];
            let h = (e9 & 0xFFFFFFFFu64) as u32;
            let hr = self.rpo_of[h as usize];
            let mut p = (e9 >> 32) as u32;
            while self.rpo_of[p as usize] > hr {
                p = self.idom[p as usize];
            }
            if p != h {
                reducible = false;
            }
        }
        let mut changed = !reducible;
        let mut rounds = 0;
        while changed && rounds < 64 {
            changed = false;
            rounds += 1;
            for bi in 1..self.rpo.len() {
                let blk = self.rpo[bi] as usize;
                let mut nd = ir::IR_NONE;
                for k in self.pstart[blk]..self.pstart[blk + 1] {
                    let p = self.plist[k as usize];
                    if self.idom[p as usize] == ir::IR_NONE {
                        continue;
                    }
                    nd = if nd == ir::IR_NONE {
                        p;
                    } else {
                        self.intersect(p, nd);
                    };
                }
                if nd != self.idom[blk] {
                    self.idom.set(blk, nd);
                    changed = true;
                }
            }
        }
        if changed {
            // no fixed point within the bound: no dominator is trusted, every join bumps all
            for i in 0..nb {
                if i != e as usize {
                    self.idom.set(i, ir::IR_NONE);
                }
            }
        }
    }

    const fn intersect(self: &Self, a0: u32, b0: u32) u32 {
        let mut a = a0;
        let mut c = b0;
        while a != c {
            while self.rpo_of[a as usize] > self.rpo_of[c as usize] {
                a = self.idom[a as usize];
            }
            while self.rpo_of[c as usize] > self.rpo_of[a as usize] {
                c = self.idom[c as usize];
            }
        }
        return a;
    }

    /// Does block `blk` have a back-edge predecessor (a loop header)?
    pub const fn is_header(self: &Self, blk: u32) bool {
        return self.npred[blk as usize] != self.fwd[blk as usize];
    }

    // One pass over the body: single definitions, exposed scalars, statics, and the escape facts
    // (`esc_use`: locals whose value leaves the body's derefs, copies into locals and calls that
    // return no reference; `holds`: locals that may hold a borrow of a local's storage; `bufexp`:
    // locals a slice views).
    fn scan_defs(self: &mut Self, b: &ir::CoreBody) {
        let nl = b.locals.len();
        self.def1.clear();
        self.def1.resize_default(nl);
        self.ndef.clear();
        self.ndef.resize_default(nl);
        self.exposed.clear();
        self.exposed.resize_default(nl);
        self.esc_use.clear();
        self.esc_use.resize_default(nl);
        self.holds.clear();
        self.holds.resize_default(nl);
        self.bufexp.clear();
        self.bufexp.resize_default(nl);
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        self.explist.clear();
        self.expover = false;
        for i in 0..nl {
            let ld = b.locals.at(i);
            if ld.storage == ir::LS_STATIC_REF && self.item_mutable(ld.item) {
                self.statics.push(i as u32);
                self.expose(da, b, i as u32);
            }
        }
        self.stack.clear(); // copy edges: dest << 32 | src
        self.ecand.clear();
        self.gcand.clear();
        self.grem = false;
        for bi in 0..self.rpo.len() {
            let bb = *b.blocks.at(self.rpo[bi] as usize);
            for si in 0..bb.stmt_len {
                let sid = bb.stmt_start + si;
                let s = *b.statements.at(sid as usize);
                if s.kind != ir::ST_ASSIGN {
                    continue;
                }
                let p = *b.places.at(s.place as usize);
                let d = if p.proj_len == 0 {
                    p.base;
                } else {
                    ir::IR_NONE;
                };
                if d != ir::IR_NONE {
                    let n = self.ndef[d as usize];
                    if n < 2 {
                        self.ndef.set(d as usize, n + 1);
                    }
                    self.def1.set(d as usize, sid);
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF && rv.b == 1 || rv.kind == ir::RV_CAST && da.type_at(
                    rv.target,
                ).kind == TypeKind::TYPE_POINTER {
                    self.ecand.push(sid);
                } else if rv.kind == ir::RV_INTRINSIC && ir::is_check(rv.c) {
                    self.gcand.push(sid);
                } else if rv.kind == ir::RV_BINARY {
                    let op = norm_op(rv.c);
                    if op >= tt::TokenType::EqualEqual as u8 && op <= tt::TokenType::GreaterThanEqual as u8 && (self.const_ge2(
                        b,
                        rv.a,
                    ) || self.const_ge2(b, rv.b)) {
                        self.gcand.push(sid);
                    } else if op == tt::TokenType::Percent as u8 && self.const_ge2(b, rv.b) {
                        self.grem = true;
                    }
                }
                if rv.kind == ir::RV_USE {
                    let op = *b.operands.at(rv.a as usize);
                    if op.kind != ir::OP_CONST && rv.b != 0 && !b.place_has_deref(op.data) {
                        self.bufexp.set(b.places.at(op.data as usize).base as usize, true); // an array's view
                    }
                    let src = if op.kind == ir::OP_CONST {
                        ir::IR_NONE;
                    } else {
                        self.whole_local(b, op.data);
                    };
                    if src != ir::IR_NONE && d != ir::IR_NONE && b.locals.at(d as usize).storage != ir::LS_RET {
                        self.stack.push(d as u64 << 32 | src as u64);
                    } else {
                        self.esc_op(b, rv.a);
                    }
                } else if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
                    let rp = *b.places.at(rv.a as usize);
                    let deref = b.place_has_deref(rv.a);
                    if (rv.kind == ir::RV_ADDR || rv.b == 1) && !deref {
                        self.expose(da, b, rp.base);
                    }
                    if rp.proj_len == 0 {
                        self.esc_use.set(rp.base as usize, true); // the borrow's own storage
                    }
                    if !deref && d != ir::IR_NONE {
                        self.holds.set(d as usize, true);
                    }
                } else if rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_DYN {
                    self.esc_op(b, rv.a);
                } else if rv.kind == ir::RV_BINARY || rv.kind == ir::RV_REPEAT {
                    self.esc_op(b, rv.a);
                    self.esc_op(b, rv.b);
                } else if ir::has_op_range(&rv) {
                    for i in 0..rv.b {
                        self.esc_op(b, b.oper_pool[(rv.a + i) as usize]);
                    }
                } else if rv.kind == ir::RV_SLICE {
                    self.esc_use.set(rp_base(b, rv.a) as usize, true);
                    if !b.place_has_deref(rv.a) {
                        self.bufexp.set(rp_base(b, rv.a) as usize, true);
                    }
                }
            }
            let t = bb.term;
            if t.kind == ir::TM_CALL {
                if !self.scalar_dests(b, &t) {
                    for i in 0..t.args_len {
                        self.esc_op(b, b.oper_pool[(t.args_start + i) as usize]);
                    }
                }
                for i in 0..t.dests_len {
                    let p = *b.places.at(b.dest_pool[(t.dests_start + i) as usize] as usize);
                    if p.proj_len == 0 {
                        self.ndef.set(p.base as usize, 2);
                    }
                }
            }
        }
        for i in 0..nl {
            if self.ndef[i] != 1 {
                self.def1.set(i, ir::IR_NONE);
            }
        }
        // a copy that escapes carries its source along; a copy of a borrow holds it
        let mut changed = true;
        let mut rounds = 0;
        while changed && rounds < 8 {
            changed = false;
            rounds += 1;
            for i in 0..self.stack.len() {
                let e = self.stack[i];
                let d = (e >> 32) as usize;
                let src = (e & 0xFFFFFFFFu64) as usize;
                if self.esc_use[d] && !self.esc_use[src] {
                    self.esc_use.set(src, true);
                    changed = true;
                }
                if self.holds[src] && !self.holds[d] {
                    self.holds.set(d, true);
                    changed = true;
                }
            }
        }
        if changed {
            for i in 0..nl {
                self.esc_use.set(i, true);
                self.holds.set(i, true);
            }
        }
        // escapes: a raw address, a mutable borrow stored or used past derefs, copies and calls, a
        // reference cast to a raw pointer. Resolved by single definitions, so the set holds on
        // every path; an unresolved one disables transparency.
        for ci in 0..self.ecand.len() {
            {
                let s = *b.statements.at(self.ecand[ci] as usize);
                let rv = *b.rvalues.at(s.rvalue as usize);
                let d = self.whole_local(b, s.place);
                if rv.kind == ir::RV_ADDR || rv.kind == ir::RV_REF && rv.b == 1 && (d == ir::IR_NONE || self.esc_use[d as usize]) {
                    self.escape_place(b, rv.a);
                } else if rv.kind == ir::RV_CAST && self.is_ref_to_ptr_cast(b, &rv) {
                    // the BORROWED storage escapes, not the reference
                    let cl = self.whole_local(b, b.operands.at(rv.a as usize).data);
                    let r = if cl == ir::IR_NONE {
                        ir::IR_NONE;
                    } else {
                        self.def_src(b, cl);
                    };
                    if r == ir::IR_NONE {
                        self.escall = true;
                    } else if self.def1[r as usize] != ir::IR_NONE && b.rvalues.at(
                        b.statements.at(self.def1[r as usize] as usize).rvalue as usize,
                    ).kind == ir::RV_REF {
                        self.escape_place(
                            b,
                            b.rvalues.at(b.statements.at(self.def1[r as usize] as usize).rvalue as usize).a,
                        );
                    } else if self.holds[r as usize] {
                        self.escall = true;
                    } else {
                        self.mark_escaped(r);
                    }
                }
            }
        }
    }

    // The storage of place `pl` escapes: its root, by single definitions (buffer memory is
    // covered by the buffer and resident rules).
    fn escape_place(self: &mut Self, b: &ir::CoreBody, pl0: u32) {
        if self.sbuf(b, pl0) {
            return;
        }
        let mut pl = pl0;
        for _g in 0..3 {
            let p = *b.places.at(pl as usize);
            let mut deref = false;
            for i in 0..p.proj_len {
                if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                    if i != 0 {
                        self.escall = true;
                        return;
                    }
                    deref = true;
                }
            }
            if !deref {
                self.mark_escaped(p.base);
                return;
            }
            let r = self.def_src(b, p.base);
            if r == ir::IR_NONE {
                self.escall = true;
                return;
            }
            let d = self.def1[r as usize];
            if d != ir::IR_NONE && b.rvalues.at(b.statements.at(d as usize).rvalue as usize).kind == ir::RV_REF {
                pl = b.rvalues.at(b.statements.at(d as usize).rvalue as usize).a;
                continue;
            }
            if self.holds[r as usize] {
                self.escall = true; // it may point at a local's storage
                return;
            }
            self.mark_escaped(r);
            return;
        }
        self.escall = true;
    }

    // Can item `d` change: anything but a constant or a non-extern immutable static?
    fn item_mutable(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.pkg;
        if d.node == NODE_NONE || Ast::in_body(d.node) || d.module as usize >= pk.modules.len() || !pk.modules.at(
            d.module as usize,
        ).has_ast {
            return true; // a body's syntax may be released by now
        }
        let n = (unsafe &*pk.module_ast_const(d.module)).at_const(d.node);
        if n.kind == NodeKind::NODE_FUNCTION {
            return false;
        }
        return n.kind != NodeKind::NODE_CONST || n.as_data.const_def.is_static_mut || n.as_data.const_def.is_extern;
    }

    fn expose(self: &mut Self, da: &Ast, b: &ir::CoreBody, l: u32) {
        if self.exposed[l as usize] {
            return;
        }
        let k = da.type_at(b.locals.at(l as usize).ty).kind;
        if k != TypeKind::TYPE_BUILTIN && k != TypeKind::TYPE_POINTER && k != TypeKind::TYPE_REFERENCE {
            return; // an aggregate's facts are keyed by generations, which a heap write bumps
        }
        self.exposed.set(l as usize, true);
        if self.explist.len() >= EXPOSED_MAX {
            self.expover = true;
            return;
        }
        self.explist.push(l);
    }

    // The width and signedness of integer type `ty` of `da`; false for every other type.
    const fn int_kind(self: &Self, da: &Ast, ty: TypeId, w: &mut u32, sg: &mut bool) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = da.type_at(ty);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = y.as_data.builtin;
        *sg = bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE;
        *w = (switch bt {
            BT_I8 | BT_U8 => 8,
            BT_I16 | BT_U16 => 16,
            BT_I32 | BT_U32 => 32,
            BT_I64 | BT_U64 => 64,
            BT_ISIZE | BT_USIZE => self.pw,
            _ => 0,
        });
        return *w != 0;
    }

    // ---- versions --------------------------------------------------------------------------------------

    /// Exact structural place equality (base + full projection content). PJ_INDEX_OP compares its
    /// OperandId, so distinct dynamic indexes never merge.
    pub fn places_eq(self: &Self, b: &ir::CoreBody, p1: u32, p2: u32) bool {
        if p1 == p2 {
            return true;
        }
        if (p1 & SYNTH_PL) != 0 || (p2 & SYNTH_PL) != 0 {
            return false;
        }
        let a = *b.places.at(p1 as usize);
        let c = *b.places.at(p2 as usize);
        if a.base != c.base || a.proj_len != c.proj_len {
            return false;
        }
        for i in 0..a.proj_len {
            let x = *b.projections.at((a.proj_start + i) as usize);
            let y = *b.projections.at((c.proj_start + i) as usize);
            if x.kind != y.kind || x.data != y.data || x.sub != y.sub {
                return false;
            }
        }
        return true;
    }

    /// A whole-local place (no projections), or IR_NONE.
    pub const fn whole_local(self: &Self, b: &ir::CoreBody, pl: u32) u32 {
        let p = *b.places.at(pl as usize);
        if p.proj_len != 0 {
            return ir::IR_NONE;
        }
        return p.base;
    }

    /// Is local `l` opaque (an exposed scalar past the exposure bound)?
    pub const fn opaque(self: &Self, l: u32) bool {
        return self.expover && self.exposed[l as usize];
    }

    /// Resolve an operand to a value key, following at most six whole-local copy or affine steps.
    /// With `clean`, a step through a local marked in `cw` at `cstamp` (its binds describe an old value)
    /// is refused.
    pub fn vkey_w(self: &Self, b: &ir::CoreBody, opid: u32, cw: &Vector<u32>, cstamp: u32, clean: bool) VKey {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let cn = *b.constants.at(op.data as usize);
            if cn.kind == ir::CK_INT {
                return VKey { is_const: true, c: cn.val, is_local: false, l: 0, v: 0, off: 0 };
            }
            return vkey_none();
        }
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return vkey_none();
        }
        let mut l = self.whole_local(b, op.data);
        if l == ir::IR_NONE || clean && cw[l as usize] == cstamp || self.opaque(l) {
            return vkey_none();
        }
        let mut off: i64 = 0;
        let mut guard = 0;
        while guard < 6 {
            let cb = *self.copyof.at(l as usize);
            if cb.ok && cb.my_v == self.ver(l) && self.ver(cb.src) == cb.src_v && (!clean || cw[cb.src as usize] != cstamp) {
                l = cb.src;
                guard += 1;
                continue;
            }
            let ab = *self.affof.at(l as usize);
            if ab.ok && ab.my_v == self.ver(l) && self.ver(ab.src) == ab.src_v && (!clean || cw[ab.src as usize] != cstamp) {
                off = off + ab.c;
                l = ab.src;
                guard += 1;
                continue;
            }
            break;
        }
        return VKey { is_const: false, c: 0, is_local: true, l: l, v: self.ver(l), off: off };
    }

    /// The base local behind up to four still-current whole-local copies.
    pub fn copy_root(self: &Self, l0: u32) u32 {
        let mut l = l0;
        let mut guard = 0;
        while guard < 4 {
            let cb = *self.copyof.at(l as usize);
            if cb.ok && cb.my_v == self.ver(l) && self.ver(cb.src) == cb.src_v {
                l = cb.src;
                guard += 1;
                continue;
            }
            break;
        }
        return l;
    }

    /// A new version of local `l` (a write, or a value no earlier binding describes).
    pub fn bump_local(self: &mut Self, l: u32) {
        self.wold.push(self.lver[l as usize]);
        self.vclock += 1;
        self.lver.set(l as usize, self.vclock);
        self.wlog.push(l);
    }

    /// The current version of local `l`. Versions come from one clock, so a version names one write
    /// or one block entry; every version below the floor (raised when every local dies at once)
    /// reads as the floor.
    pub const fn ver(self: &Self, l: u32) u32 {
        let v = self.lver[l as usize];
        if v < self.vfloor {
            return self.vfloor;
        }
        return v;
    }

    /// The current base generation of local `l` (one clock, one floor).
    pub const fn bgen(self: &Self, l: u32) u32 {
        let g = self.basegen[l as usize];
        if g < self.vfloor {
            return self.vfloor;
        }
        return g;
    }

    fn bump_base(self: &mut Self, l: u32) {
        self.vclock += 1;
        self.basegen.set(l as usize, self.vclock);
    }

    // A fresh version of local `l` at a block entry: the value is no other path's, and no binding
    // names the new version. Not a write: a later join finds the writes that caused it in the log.
    fn rekey(self: &mut Self, l: u32) {
        self.vclock += 1;
        self.lver.set(l as usize, self.vclock);
    }

    /// An unknown heap write: every collection identity keyed by the heap generation dies, and so
    /// does every value of an exposed scalar.
    pub fn heap(self: &mut Self) {
        self.heapgen += 1;
        self.buf();
    }

    /// A write into a prelude view's element buffer: only places heap memory may hold change, and
    /// exposed scalars (a view can be built over any storage).
    pub fn buf(self: &mut Self) {
        self.bufgen += 1;
        for i in 0..self.explist.len() {
            self.bump_local(self.explist[i]);
        }
    }

    /// Is `sub` the field named `name` of the prelude view `view_ty` (a type of `b`'s module)?
    pub fn is_prelude_field(self: &Self, b: &ir::CoreBody, view_ty: TypeId, sub: NodeId, name: str) bool {
        if view_ty == TYPE_NONE || sub == NODE_NONE {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        let y = *da.type_at(view_ty);
        let mut m9: ModuleId = 0;
        if y.kind == TypeKind::TYPE_STRUCT {
            m9 = y.module;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            m9 = da.instance(y.as_data.inst).module;
        } else {
            return false;
        }
        if m9 as usize >= pk.modules.len() || !pk.modules.at(m9 as usize).prelude {
            return false;
        }
        let fa = unsafe &*pk.module_ast_const(m9);
        let fnode = fa.at_const(sub);
        if fnode.kind != NodeKind::NODE_FIELD {
            return false;
        }
        let ns = fa.at_const(fnode.as_data.field.name).as_data.name.text;
        let src = pk.modules.at(m9 as usize).source.as_str();
        return src.slice(ns.start as usize, ns.end as usize) == name;
    }

    /// Does place `pl` reach into a prelude view's element buffer (its `ptr` field, then an index or
    /// a deref)?
    pub fn buf_place(self: &Self, b: &ir::CoreBody, pl: u32) bool {
        let p = *b.places.at(pl as usize);
        if p.proj_len < 2 {
            return false;
        }
        for i in 0..p.proj_len - 1 {
            let x = *b.projections.at((p.proj_start + i) as usize);
            if x.kind != ir::PJ_FIELD || x.data == ir::PJ_UNION_FIELD {
                continue;
            }
            let nk = b.projections.at((p.proj_start + i + 1) as usize).kind;
            if nk != ir::PJ_INDEX_OP && nk != ir::PJ_INDEX_CONST && nk != ir::PJ_DEREF {
                continue;
            }
            let parent = if i == 0 {
                b.locals.at(p.base as usize).ty;
            } else {
                b.projections.at((p.proj_start + i - 1) as usize).ty;
            };
            if self.is_prelude_field(b, parent, x.sub, "ptr") {
                return true;
            }
        }
        return false;
    }

    /// May heap memory hold place `pl`: a deref past its first projection, or a view's buffer?
    pub fn resident(self: &Self, b: &ir::CoreBody, pl: u32) bool {
        if (pl & SYNTH_PL) != 0 {
            return false;
        }
        let p = *b.places.at(pl as usize);
        if self.bufexp[p.base as usize] {
            return true;
        }
        for i in 1..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return true;
            }
        }
        return self.buf_place(b, pl);
    }

    /// Apply the write of place `pl`.
    pub fn write_place(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 {
            self.bump_local(p.base);
            return;
        }
        if b.place_has_deref(pl) {
            self.deref_write(b, pl);
            return;
        }
        self.kill_path(b, p.base, pl);
    }

    // A write through a deref. A leading deref of a reference whose target is known (a current
    // borrow of a deref-free place, or a reference parameter, whose target no local of this body
    // is) writes only that subtree: the borrow rules keep every other path to it unusable. Every
    // other deref can alias any storage.
    fn deref_write(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let mut base: u32 = 0;
        let mut path: u32 = 0;
        if self.in_buffer(b, pl) {
            self.buf();
            return;
        }
        if self.ref_path(b, pl, &mut base, &mut path) {
            self.kill_path(b, base, path);
            return;
        }
        let p = *b.places.at(pl as usize);
        if b.projections.at(p.proj_start as usize).kind == ir::PJ_DEREF {
            // through a current borrow of a buffer element
            if self.holds[p.base as usize] {
                self.kill_all(); // it may point at any local's storage
                return;
            }
        }
        self.heap();
    }

    // The subtree a place through a leading reference deref reaches: (base, place).
    fn ref_path(self: &Self, b: &ir::CoreBody, pl: u32, base: &mut u32, path: &mut u32) bool {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
            return false;
        }
        for i in 1..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return false;
            }
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        let bk = da.type_at(b.locals.at(p.base as usize).ty).kind;
        if bk != TypeKind::TYPE_REFERENCE && bk != TypeKind::TYPE_POINTER {
            return false;
        }
        let r = self.copy_root(p.base);
        let rb = *self.refof.at(r as usize);
        if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 {
            if b.place_has_deref(rb.pl) && !self.arg_deref(b, rb.pl, self.copy_root(b.places.at(rb.pl as usize).base)) {
                return false;
            }
            *base = b.places.at(rb.pl as usize).base;
            *path = rb.pl;
            return true;
        }
        if self.arg_deref(b, pl, r) {
            *base = r; // a copy of a parameter reaches the parameter's target
            *path = pl;
            return true;
        }
        return false;
    }

    // Place `pl` reaches through one leading deref of a reference parameter `root` (its base or a copy
    // of it) that no write or binding redirects.
    fn arg_deref(self: &Self, b: &ir::CoreBody, pl: u32, root: u32) bool {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
            return false;
        }
        for i in 1..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return false;
            }
        }
        let ld = b.locals.at(root as usize);
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        if ld.storage != ir::LS_ARG || da.type_at(ld.ty).kind != TypeKind::TYPE_REFERENCE || self.ndef[root as usize] != 0 {
            return false;
        }
        let rb = *self.refof.at(root as usize);
        return !(rb.ok && rb.my_v == self.ver(root));
    }

    /// A write into the subtree of place `pl` of base local `base`.
    pub fn kill_path(self: &mut Self, b: &ir::CoreBody, base: u32, pl: u32) {
        if b.places.at(pl as usize).proj_len == 0 || self.pkills.len() >= PKILL_MAX {
            self.kill_root(base);
            return;
        }
        self.pgen.set(base as usize, self.pgen[base as usize] + 1);
        self.pkills.push(PKill { base: base, pg: self.pgen[base as usize], pl: pl });
        self.bump_local(base);
    }

    /// Does place `pl`, captured at path generation `from`, survive every subtree write of its base
    /// up to path generation `to`?
    pub fn path_alive(self: &Self, b: &ir::CoreBody, pl: u32, from: u32, to: u32) bool {
        if from == to || (pl & SYNTH_PL) != 0 {
            return true;
        }
        let lo = from.min(to);
        let hi = from.max(to);
        let base = b.places.at(pl as usize).base;
        for i in 0..self.pkills.len() {
            let k = self.pkills[i];
            if k.base == base && k.pg > lo && k.pg <= hi && places_overlap(b, k.pl, pl) {
                return false;
            }
        }
        return true;
    }
    /// Kill every fact identity rooted at `l`: the version covers value binds and synthetic length
    /// identities, the base generation covers real length places.
    pub fn kill_root(self: &mut Self, l: u32) {
        self.bump_local(l);
        self.bump_base(l);
    }

    pub fn kill_roots(self: &mut Self, e: &Effect) {
        if e.over {
            self.kill_all();
            return;
        }
        for i in 0..e.n {
            self.kill_root(unsafe e.roots[i as usize]);
        }
    }

    // Every local, base and the heap: the bound of a scan or an effect was exceeded.
    fn kill_all(self: &mut Self) {
        self.vclock += 1;
        self.vfloor = self.vclock; // every version and base generation so far is dead
        self.heapgen += 1;
    }

    pub fn kill_ambient(self: &mut Self) {
        for i in 0..self.statics.len() {
            self.kill_root(self.statics[i]);
        }
        for i in 0..self.esclist.len() {
            self.kill_root(self.esclist[i]);
        }
    }

    /// Enter block `blk` in the walk: bump every local written since its immediate dominator was
    /// left (another path's writes reach the walk's tables first), and at a loop header every
    /// local, base and the heap the loop can write. A block with one predecessor restores those
    /// locals' versions instead: every write since its predecessor was left is another path's.
    pub fn enter_block(self: &mut Self, b: &ir::CoreBody, blk: u32) {
        if self.rpo.len() != 0 && blk != self.rpo[0] {
            let d = self.idom[blk as usize];
            let from = if d == ir::IR_NONE {
                0;
            } else {
                self.clk_end[d as usize];
            };
            if d != ir::IR_NONE && self.npred[blk as usize] == 1 {
                let mut k = self.wlog.len();
                while k > from as usize {
                    k -= 1;
                    self.lver.set(self.wlog[k] as usize, self.wold[k]);
                }
                return;
            }
            self.bstamp += 1;
            for k in from as usize..self.wlog.len() {
                let l = self.wlog[k];
                if self.bst[l as usize] != self.bstamp {
                    self.bst.set(l as usize, self.bstamp);
                    self.rekey(l);
                }
            }
        }
        if self.is_header(blk) {
            self.loop_bump(b, blk);
        }
    }

    /// Leave block `blk` in the walk.
    pub fn leave_block(self: &mut Self, blk: u32) {
        self.clk_end.set(blk as usize, self.wlog.len() as u32);
    }

    // The root local a whole local `l0` designates for a call or a drop, through its single
    // definitions: a copy continues, a borrow of a deref-free place names the place's base, a
    // borrow through a leading deref continues with the reference. A local with no single definition
    // is its own root. IR_NONE when a deref sits behind other projections.
    fn def_root(self: &Self, b: &ir::CoreBody, l0: u32) u32 {
        let mut l = l0;
        let mut guard = 0;
        while guard < 8 {
            guard += 1;
            let d = self.def1[l as usize];
            if d == ir::IR_NONE {
                if self.holds[l as usize] {
                    return ir::IR_NONE; // several definitions, one of them a local's borrow
                }
                return l;
            }
            let s = *b.statements.at(d as usize);
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.kind == ir::OP_CONST {
                    return l;
                }
                let w = self.whole_local(b, op.data);
                if w == ir::IR_NONE {
                    return l;
                }
                l = w;
                continue;
            }
            if rv.kind != ir::RV_REF && rv.kind != ir::RV_ADDR {
                return l;
            }
            let p = *b.places.at(rv.a as usize);
            let mut deref = false;
            for i in 0..p.proj_len {
                if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                    if i != 0 {
                        return ir::IR_NONE;
                    }
                    deref = true;
                }
            }
            if !deref {
                return p.base;
            }
            l = p.base;
        }
        return ir::IR_NONE;
    }

    // Collect what one loop can write (the natural loops of header `h`) and bump it.
    fn loop_bump(self: &mut Self, b: &ir::CoreBody, h: u32) {
        self.lstamp += 1;
        self.lblocks.clear();
        self.lmark.set(h as usize, self.lstamp);
        self.lblocks.push(h);
        let r = self.rpo_of[h as usize];
        for k in self.pstart[h as usize]..self.pstart[h as usize + 1] {
            let p = self.plist[k as usize];
            if self.rpo_of[p as usize] >= r && self.lmark[p as usize] != self.lstamp {
                self.lmark.set(p as usize, self.lstamp);
                self.lblocks.push(p);
            }
        }
        let mut sp: usize = 1; // the DFS stack is lblocks' unscanned tail
        while sp < self.lblocks.len() {
            let x = self.lblocks[sp];
            sp += 1;
            for k in self.pstart[x as usize]..self.pstart[x as usize + 1] {
                let q = self.plist[k as usize];
                if self.lmark[q as usize] != self.lstamp {
                    self.lmark.set(q as usize, self.lstamp);
                    self.lblocks.push(q);
                }
            }
        }
        self.bstamp += 1;
        let mut fl: u8 = 0;
        for i in 0..self.lblocks.len() {
            let blk = self.lblocks[i] as usize;
            if self.lsum_s[blk] == 0 {
                self.lsummarize(b, blk);
            }
            let s0 = self.lsum_s[blk] as usize - 1;
            let n = self.lsum_n[blk] as usize;
            self.scan_left -= n as i64 + 1;
            fl |= self.lsum_f[blk];
            if self.scan_left < 0 || (fl & 4) != 0 {
                self.kill_all();
                return;
            }
            for k in s0..s0 + n {
                let o = self.lops[k];
                if o.k == 2 {
                    self.lpath(b, o.a, o.p);
                } else {
                    self.lbump(o.a, o.k == 1);
                }
            }
        }
        if (fl & 1) != 0 {
            self.heap();
        } else if (fl & 2) != 0 {
            self.buf();
        }
        if (fl & 8) != 0 {
            self.kill_ambient();
        }
    }

    // The writes of block `blk` a loop scan applies, once per body: the locals and places it can
    // write, and flags (1 heap, 2 view buffer, 4 every local, 8 statics and escaped roots).
    fn lsummarize(self: &mut Self, b: &ir::CoreBody, blk: usize) {
        let s0 = self.lops.len() as u32;
        self.lfl = 0;
        self.lsum_one(b, blk);
        self.lsum_s.set(blk, s0 + 1); // 0 marks a block not summarized
        self.lsum_n.set(blk, self.lops.len() as u32 - s0);
        self.lsum_f.set(blk, self.lfl);
    }

    fn lsum_one(self: &mut Self, b: &ir::CoreBody, blk: usize) {
        let bb = *b.blocks.at(blk);
        let pkg = self.pkg;
        let da = unsafe &*(&*pkg).module_ast_const(b.module);
        for si in 0..bb.stmt_len {
            let s = *b.statements.at((bb.stmt_start + si) as usize);
            if s.kind == ir::ST_STORAGE_DEAD {
                self.lop(0, s.a, 0);
                continue;
            }
            let e = stmt_effect(b, &s);
            if e.kind == EF_ASM {
                self.lfl |= 1;
                if e.over {
                    self.lfl |= 4;
                    return;
                }
                for k in 0..e.n {
                    self.lop(1, unsafe e.roots[k as usize], 0);
                }
                self.lwrite(b, s.place);
            } else if e.kind == EF_PTR {
                self.lfl |= 1;
                self.lwrite(b, s.place);
            } else if e.kind == EF_WRITE {
                self.lwrite(b, s.place);
            }
        }
        let t = bb.term;
        let e = term_effect(pkg, b, &t);
        if e.kind == EF_CALL {
            let mut ok = !self.off_sig && !self.escall && !t.is_variadic && self.callee_defined(t.callee);
            for k in 0..t.args_len {
                if !ok {
                    break;
                }
                let op = *b.operands.at(b.oper_pool[(t.args_start + k) as usize] as usize);
                if op.kind == ir::OP_CONST {
                    continue;
                }
                let y = *da.type_at(op.ty);
                if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_OPAQUE {
                    ok = false;
                } else if y.kind == TypeKind::TYPE_REFERENCE {
                    if y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                        continue;
                    }
                    let l = self.whole_local(b, op.data);
                    if l == ir::IR_NONE {
                        if self.sbuf(b, op.data) {
                            self.lfl |= 2;
                        } else if !b.place_has_deref(op.data) {
                            self.lop(2, b.places.at(op.data as usize).base, op.data);
                        }
                        continue;
                    }
                    let mut pb: u32 = 0;
                    let mut pp: u32 = 0;
                    if self.sbuf_ref(b, l) {
                        self.lfl |= 2;
                        self.lop(0, l, 0);
                        continue;
                    }
                    if self.def_path(b, l, &mut pb, &mut pp) {
                        self.lop(2, pb, pp);
                        self.lop(0, l, 0);
                        continue;
                    }
                    let rt = self.def_root(b, l);
                    if rt == ir::IR_NONE {
                        ok = false;
                    } else {
                        self.lop(1, rt, 0);
                        self.lop(1, l, 0);
                    }
                } else if op.kind == ir::OP_MOVE {
                    if b.place_has_deref(op.data) {
                        ok = false;
                    } else {
                        self.lop(2, b.places.at(op.data as usize).base, op.data);
                    }
                }
            }
            if ok {
                self.lfl |= 8;
            } else {
                self.lfl |= 1;
                if e.over {
                    self.lfl |= 4;
                    return;
                }
                for k in 0..e.n {
                    let l = unsafe e.roots[k as usize];
                    self.lop(1, l, 0);
                    let rt = self.def_root(b, l);
                    if rt == ir::IR_NONE {
                        self.lfl |= 4;
                        return;
                    }
                    self.lop(1, rt, 0);
                }
            }
        } else if e.kind == EF_DROP {
            let p = *b.places.at(t.a as usize);
            let mut pb: u32 = 0;
            let mut pp: u32 = 0;
            let ok = !self.off_sig && !self.escall;
            if ok && self.sbuf(b, t.a) {
                self.lfl |= 2;
                self.lfl |= 8;
            } else if ok && !b.place_has_deref(t.a) {
                self.lop(2, p.base, t.a);
                self.lfl |= 8;
            } else if ok && self.sref_path(b, t.a, &mut pb, &mut pp) {
                self.lop(2, pb, pp);
                self.lfl |= 8;
            } else {
                let rt = self.def_root(b, p.base);
                if ok && rt != ir::IR_NONE {
                    self.lop(1, rt, 0);
                    self.lfl |= 8;
                } else {
                    self.lfl |= 1;
                    if !b.place_has_deref(t.a) {
                        self.lop(1, p.base, 0);
                    }
                }
            }
        } else if e.kind != EF_NONE {
            self.lfl |= 1;
        }
        if t.kind == ir::TM_CALL {
            for k in 0..t.dests_len {
                self.lwrite(b, b.dest_pool[(t.dests_start + k) as usize]);
            }
        }
    }

    fn lop(self: &mut Self, k: u8, a: u32, p: u32) {
        self.lops.push(LOp { a: a, p: p, k: k });
    }

    // One loop-scan bump of local `l` (`root`: its base generation too), once per scan.
    fn lbump(self: &mut Self, l: u32, root: bool) {
        if root {
            self.bump_base(l);
        }
        if self.bst[l as usize] != self.bstamp {
            self.bst.set(l as usize, self.bstamp);
            self.rekey(l);
        }
    }

    fn lwrite(self: &mut Self, b: &ir::CoreBody, pl: u32) {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 {
            self.lop(0, p.base, 0);
        } else if b.place_has_deref(pl) {
            let mut pb: u32 = 0;
            let mut pp: u32 = 0;
            if self.sbuf(b, pl) {
                self.lfl |= 2;
            } else if self.sref_path(b, pl, &mut pb, &mut pp) {
                self.lop(2, pb, pp);
            } else if self.holds[p.base as usize] {
                self.lfl |= 4;
            } else {
                self.lfl |= 1;
            }
        } else {
            self.lop(2, p.base, pl);
        }
    }

    // Does reference local `l0` borrow a view buffer's element, by its single definitions?
    fn sbuf_ref(self: &Self, b: &ir::CoreBody, l0: u32) bool {
        let l = self.def_src(b, l0);
        if l == ir::IR_NONE || self.def1[l as usize] == ir::IR_NONE {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(self.def1[l as usize] as usize).rvalue as usize);
        return (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR) && self.sbuf(b, rv.a);
    }

    // in_buffer from single definitions.
    fn sbuf(self: &Self, b: &ir::CoreBody, pl0: u32) bool {
        let mut pl = pl0;
        let mut guard = 0;
        while guard < 4 {
            guard += 1;
            if self.buf_place(b, pl) {
                return true;
            }
            let p = *b.places.at(pl as usize);
            if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
                return false;
            }
            let l = self.def_src(b, p.base);
            if l == ir::IR_NONE || self.def1[l as usize] == ir::IR_NONE {
                return false;
            }
            let rv = *b.rvalues.at(b.statements.at(self.def1[l as usize] as usize).rvalue as usize);
            if rv.kind != ir::RV_REF && rv.kind != ir::RV_ADDR {
                return false;
            }
            pl = rv.a;
        }
        return false;
    }

    // One loop-scan write into the subtree `pl` of base `base`.
    fn lpath(self: &mut Self, b: &ir::CoreBody, base: u32, pl: u32) {
        if b.places.at(pl as usize).proj_len == 0 {
            self.lbump(base, true);
            return;
        }
        self.kill_path(b, base, pl);
    }

    // The local a whole local's single definitions copy, or IR_NONE past the bound.
    fn def_src(self: &Self, b: &ir::CoreBody, l0: u32) u32 {
        let mut l = l0;
        let mut guard = 0;
        while guard < 8 {
            guard += 1;
            let d = self.def1[l as usize];
            if d == ir::IR_NONE {
                return l;
            }
            let rv = *b.rvalues.at(b.statements.at(d as usize).rvalue as usize);
            if rv.kind != ir::RV_USE && !self.addr_cast(b, &rv) {
                return l;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind == ir::OP_CONST || self.whole_local(b, op.data) == ir::IR_NONE {
                return l;
            }
            l = self.whole_local(b, op.data);
        }
        return ir::IR_NONE;
    }

    // ref_path from single definitions: the subtree a reference local's borrow reaches.
    fn def_path(self: &Self, b: &ir::CoreBody, l0: u32, base: &mut u32, path: &mut u32) bool {
        let l = self.def_src(b, l0);
        if l == ir::IR_NONE || self.def1[l as usize] == ir::IR_NONE {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(self.def1[l as usize] as usize).rvalue as usize);
        if rv.kind != ir::RV_REF {
            return false;
        }
        if !b.place_has_deref(rv.a) {
            *base = b.places.at(rv.a as usize).base;
            *path = rv.a;
            return true;
        }
        return self.sref_path(b, rv.a, base, path);
    }

    // ref_path from single definitions for place `pl` with a leading reference deref.
    fn sref_path(self: &Self, b: &ir::CoreBody, pl: u32, base: &mut u32, path: &mut u32) bool {
        let p = *b.places.at(pl as usize);
        if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
            return false;
        }
        for i in 1..p.proj_len {
            if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return false;
            }
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        if da.type_at(b.locals.at(p.base as usize).ty).kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        let l = self.def_src(b, p.base);
        if l == ir::IR_NONE {
            return false;
        }
        let d = self.def1[l as usize];
        if d == ir::IR_NONE {
            if self.arg_deref(b, pl, l) {
                *base = l;
                *path = pl;
                return true;
            }
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(d as usize).rvalue as usize);
        if rv.kind != ir::RV_REF || b.place_has_deref(rv.a) && !self.arg_deref(
            b,
            rv.a,
            self.def_src(b, b.places.at(rv.a as usize).base),
        ) {
            return false;
        }
        *base = b.places.at(rv.a as usize).base;
        *path = rv.a;
        return true;
    }

    // ---- signature transparency ------------------------------------------------------------------------

    /// The root local behind a place, through at most two current reference bindings: no deref
    /// resolves to the base local; a leading deref resolves through `refof`, and a reference with no
    /// binding (a parameter) is itself the root. False when a deref sits behind other projections.
    pub fn root_of_place(self: &Self, b: &ir::CoreBody, pl0: u32, out: &mut u32) bool {
        let mut pl = pl0;
        let mut guard = 0;
        while guard < 3 {
            guard += 1;
            let p = *b.places.at(pl as usize);
            let mut deref = false;
            for i in 0..p.proj_len {
                if b.projections.at((p.proj_start + i) as usize).kind == ir::PJ_DEREF {
                    if i != 0 {
                        return false;
                    }
                    deref = true;
                }
            }
            if !deref {
                *out = p.base;
                return true;
            }
            let r = self.copy_root(p.base);
            let rb = *self.refof.at(r as usize);
            if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 {
                pl = rb.pl;
                continue;
            }
            *out = r;
            return true;
        }
        return false;
    }

    pub fn mark_escaped(self: &mut Self, r: u32) {
        if self.escroot[r as usize] {
            return;
        }
        if self.esclist.len() >= ESC_MAX {
            self.escall = true;
            return;
        }
        self.escroot.set(r as usize, true);
        self.esclist.push(r);
    }

    /// Does place `pl` lie in a view's element buffer, directly or through current reference
    /// bindings?
    pub fn in_buffer(self: &Self, b: &ir::CoreBody, pl0: u32) bool {
        let mut pl = pl0;
        let mut guard = 0;
        while guard < 4 {
            guard += 1;
            if self.buf_place(b, pl) {
                return true;
            }
            let p = *b.places.at(pl as usize);
            if p.proj_len == 0 || b.projections.at(p.proj_start as usize).kind != ir::PJ_DEREF {
                return false;
            }
            let r = self.copy_root(p.base);
            let rb = *self.refof.at(r as usize);
            if !(rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0) {
                return false;
            }
            pl = rb.pl;
        }
        return false;
    }

    // Does call `t` return nothing a reference could hide in (no destination, or scalar ones)?
    const fn scalar_dests(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        for i in 0..t.dests_len {
            let ty = b.places.at(b.dest_pool[(t.dests_start + i) as usize] as usize).ty;
            if ty != TYPE_NONE && da.type_at(ty).kind != TypeKind::TYPE_BUILTIN {
                return false;
            }
        }
        return true;
    }

    // Mark a whole-local operand's local as used past derefs, copies and calls.
    fn esc_op(self: &mut Self, b: &ir::CoreBody, opid: u32) {
        if opid == ir::IR_NONE {
            return;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            return;
        }
        let l = self.whole_local(b, op.data);
        if l != ir::IR_NONE {
            self.esc_use.set(l as usize, true);
        }
    }

    /// True when the callee is a local Super-C function body (not extern, not a fn value).
    pub const fn callee_defined(self: &Self, d: DefId) bool {
        let pk = unsafe &*self.pkg;
        if d.node == NODE_NONE || d.module as usize >= pk.modules.len() || !pk.modules.at(d.module as usize).has_ast {
            return false;
        }
        let a = unsafe &*pk.module_ast_const(d.module);
        let n = a.at_const(d.node);
        if n.kind != NodeKind::NODE_FUNCTION {
            return false;
        }
        return !n.as_data.function.is_extern();
    }

    /// `rv` casts a reference to a raw pointer: its target leaves the borrow discipline.
    pub const fn is_ref_to_ptr_cast(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let op = *b.operands.at(rv.a as usize);
        if op.kind == ir::OP_CONST {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        if da.type_at(op.ty).kind != TypeKind::TYPE_REFERENCE {
            return false;
        }
        return da.type_at(rv.target).kind == TypeKind::TYPE_POINTER;
    }

    /// Signature transparency for one call: keep collection facts when every argument is a
    /// constant, a shared reference, or a by-value datum. Kills exactly the roots handed out mutably
    /// or by move, plus statics and escaped roots. A raw pointer, fn value, dyn value, variadic
    /// tail, fn-value callee, or extern callee is not transparent. A &mut loaded from memory kills
    /// nothing extra: it can alias only an escaped root or state no tracked fact roots.
    pub fn call_transparent(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if self.off_sig || self.escall || t.is_variadic || !self.callee_defined(t.callee) {
            return false;
        }
        let pk = unsafe &*self.pkg;
        let da = unsafe &*pk.module_ast_const(b.module);
        let mut kills: [u32; 16] = [[0] = 0u32];
        let mut kpl: [u32; 16] = [[0] = ir::IR_NONE]; // the subtree a kill reaches, IR_NONE: the root
        let mut nk: usize = 0;
        let mut bufk = false; // an argument borrows a view buffer's element
        for i in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize);
            if op.kind == ir::OP_CONST {
                continue;
            }
            let y = *da.type_at(op.ty);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION || y.kind == TypeKind::TYPE_DYN || y.kind == TypeKind::TYPE_OPAQUE {
                return false;
            }
            let mut victim = ir::IR_NONE;
            let mut victim2 = ir::IR_NONE;
            let mut vpl = ir::IR_NONE;
            if y.kind == TypeKind::TYPE_REFERENCE {
                if y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    continue; // a shared reference cannot mutate the header it points at
                }
                let l = self.whole_local(b, op.data);
                if l == ir::IR_NONE {
                    // a projected operand place is an elided autoref of a projected collection
                    // (s.field): kill its base. A deref inside is a loaded &mut.
                    if self.in_buffer(b, op.data) {
                        bufk = true;
                    } else if !b.place_has_deref(op.data) {
                        victim = b.places.at(op.data as usize).base;
                        vpl = op.data;
                    }
                } else {
                    let r = self.copy_root(l);
                    let rb = *self.refof.at(r as usize);
                    let mut rt: u32 = 0;
                    if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 && self.in_buffer(b, rb.pl) {
                        bufk = true;
                    } else if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 && self.borrow_path(
                        b,
                        rb.pl,
                        &mut rt,
                        &mut vpl,
                    ) {
                        victim = rt;
                    } else if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 && self.root_of_place(
                        b,
                        rb.pl,
                        &mut rt,
                    ) {
                        victim = rt;
                    } else {
                        // an elided autoref (the local IS the collection), a &mut parameter, or an
                        // expired binding: kill both ends of the value chain
                        if self.holds[l as usize] && y.kind == TypeKind::TYPE_REFERENCE && da.type_at(
                            b.places.at(op.data as usize).ty,
                        ).kind == TypeKind::TYPE_REFERENCE {
                            return false; // an unresolved borrow of some local's storage
                        }
                        victim = l;
                        victim2 = r;
                    }
                }
            } else if op.kind == ir::OP_MOVE {
                // ownership leaves the caller: kill the moved-from base
                if b.place_has_deref(op.data) {
                    return false;
                }
                victim = b.places.at(op.data as usize).base;
                vpl = op.data;
            }
            if victim != ir::IR_NONE {
                if nk >= 15 {
                    return false;
                }
                unsafe kills[nk] = victim;
                unsafe kpl[nk] = vpl;
                nk += 1;
                if victim2 != ir::IR_NONE && victim2 != victim {
                    unsafe kills[nk] = victim2;
                    nk += 1;
                }
            }
        }
        for i in 0..nk {
            if unsafe kpl[i] == ir::IR_NONE {
                self.kill_root(unsafe kills[i]);
            } else {
                self.kill_path(b, unsafe kills[i], unsafe kpl[i]);
            }
        }
        if bufk {
            self.buf();
        }
        self.kill_ambient();
        return true;
    }

    // The subtree a borrow of place `pl` reaches: a deref-free place, or a leading reference deref
    // with a known target (see deref_write).
    fn borrow_path(self: &Self, b: &ir::CoreBody, pl: u32, base: &mut u32, path: &mut u32) bool {
        if !b.place_has_deref(pl) {
            *base = b.places.at(pl as usize).base;
            *path = pl;
            return true;
        }
        return self.ref_path(b, pl, base, path);
    }

    /// A drop reaches only the dropped value's ownership tree, plus statics and escaped roots.
    pub fn drop_transparent(self: &mut Self, b: &ir::CoreBody, pl: u32) bool {
        if self.off_sig || self.escall {
            return false;
        }
        let mut r: u32 = 0;
        let mut path: u32 = 0;
        if self.in_buffer(b, pl) {
            self.buf();
        } else if self.borrow_path(b, pl, &mut r, &mut path) {
            self.kill_path(b, r, path);
        } else if self.root_of_place(b, pl, &mut r) {
            self.kill_root(r);
        } else {
            return false;
        }
        self.kill_ambient();
        return true;
    }

    /// Apply terminator `t`'s effect and its destination writes to the versions. Returns true when a
    /// call kept collection facts through signature transparency.
    pub fn apply_term(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator, pure: bool) bool {
        if t.kind == ir::TM_CALL && t.intr == ir::CI_NONE && (pure || self.call_transparent(b, t)) {
            // the prelude length getter writes nothing; a transparent call killed its roots
            for i in 0..t.dests_len {
                self.write_place(b, b.dest_pool[(t.dests_start + i) as usize]);
            }
            return !pure;
        }
        let e = term_effect(self.pkg, b, t);
        if e.kind == EF_CALL {
            self.heap();
            self.kill_call_roots(b, &e);
        } else if e.kind == EF_DROP {
            if !self.drop_transparent(b, t.a) {
                self.heap();
                let mut r: u32 = 0;
                if self.root_of_place(b, t.a, &mut r) {
                    self.kill_root(r);
                }
            }
        } else if e.kind == EF_PTR || e.kind == EF_SYNC {
            self.heap();
        }
        if t.kind == ir::TM_CALL {
            for i in 0..t.dests_len {
                self.write_place(b, b.dest_pool[(t.dests_start + i) as usize]);
            }
        }
        return false;
    }

    // The storage an unknown call writes through its mutable reference arguments: each argument
    // root, and the place a current borrow names.
    fn kill_call_roots(self: &mut Self, b: &ir::CoreBody, e: &Effect) {
        self.kill_roots(e);
        for i in 0..e.n {
            let l = unsafe e.roots[i as usize];
            let r = self.copy_root(l);
            let rb = *self.refof.at(r as usize);
            let mut rt: u32 = 0;
            if rb.ok && rb.my_v == self.ver(r) && (rb.pl & SYNTH_PL) == 0 && self.root_of_place(b, rb.pl, &mut rt) {
                self.kill_root(rt);
            } else if self.holds[l as usize] {
                self.kill_all(); // an unresolved borrow of some local's storage
                return;
            }
            if r != l {
                self.kill_root(r);
            }
        }
    }

    /// Can an unknown write reach place `pl`: a deref, a static, or an escaped local? The storage
    /// of a local whose address never left the tracked borrows is out of an unknown callee's
    /// reach.
    pub fn reachable(self: &Self, b: &ir::CoreBody, pl: u32) bool {
        if self.escall || (pl & SYNTH_PL) != 0 || b.place_has_deref(pl) {
            return true;
        }
        let base = b.places.at(pl as usize).base;
        return self.escroot[base as usize] || self.bufexp[base as usize] || b.locals.at(base as usize).storage == ir::LS_STATIC_REF;
    }

    /// Apply statement `s`'s generic effect: escape notes, the write, and copy, affine and reference
    /// bindings. The caller reads what it needs of the operands first.
    pub fn apply_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) {
        if s.kind == ir::ST_STORAGE_DEAD {
            self.bump_local(s.a);
            return;
        }
        if s.kind != ir::ST_ASSIGN {
            return;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        let dest = self.whole_local(b, s.place);
        let e = stmt_effect(b, s);
        if e.kind == EF_ASM || e.kind == EF_PTR {
            self.heap();
            self.kill_roots(&e);
            self.write_place(b, s.place);
            return;
        }
        if dest != ir::IR_NONE {
            if rv.kind == ir::RV_BINARY && (rv.c == tt::TokenType::Plus as u8 || rv.c == tt::TokenType::Minus as u8) && rv.target == Ast::builtin(
                BuiltinType::BT_USIZE,
            ) {
                // dest = src +- c: an affine alias of src, matched by exact offset only
                let ka = self.vkey(b, rv.a);
                let kb = self.vkey(b, rv.b);
                let mut srcl = ir::IR_NONE;
                let mut c0: i64 = 0;
                if ka.is_local && kb.is_const {
                    srcl = ka.l;
                    c0 = ka.off + if rv.c == tt::TokenType::Plus as u8 {
                        kb.c;
                    } else {
                        0 - kb.c;
                    };
                } else if kb.is_local && ka.is_const && rv.c == tt::TokenType::Plus as u8 {
                    srcl = kb.l;
                    c0 = kb.off + ka.c;
                }
                self.write_place(b, s.place);
                if srcl != ir::IR_NONE && srcl != dest && c0 > 0 - 1048576 && c0 < 1048576 {
                    self.affof.set(
                        dest as usize,
                        AffBind { src: srcl, src_v: self.ver(srcl), c: c0, my_v: self.ver(dest), ok: true },
                    );
                }
                return;
            }
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    let srcl = self.whole_local(b, op.data);
                    if srcl != ir::IR_NONE {
                        self.write_place(b, s.place);
                        self.copyof.set(
                            dest as usize,
                            CopyBind { src: srcl, src_v: self.ver(srcl), my_v: self.ver(dest), ok: true },
                        );
                        return;
                    }
                }
            }
            if rv.kind == ir::RV_REF {
                self.write_place(b, s.place);
                self.refof.set(dest as usize, RefBind { pl: rv.a, my_v: self.ver(dest), ok: true });
                return;
            }
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_STRUCT {
                let k = self.view_len_key(b, &rv);
                self.write_place(b, s.place);
                if k.is_local && k.off == 0 {
                    self.lenval.set(dest as usize, CopyBind { src: k.l, src_v: k.v, my_v: self.ver(dest), ok: true });
                    self.views = true;
                }
                return;
            }
            if rv.kind == ir::RV_LEN {
                let mut x = self.whole_local(b, rv.a);
                self.write_place(b, s.place);
                if x != ir::IR_NONE {
                    x = self.copy_root(x);
                    let lb = *self.lenval.at(x as usize);
                    if lb.ok && lb.my_v == self.ver(x) && self.ver(lb.src) == lb.src_v {
                        self.lenval.set(
                            dest as usize,
                            CopyBind { src: lb.src, src_v: lb.src_v, my_v: self.ver(dest), ok: true },
                        );
                    }
                }
                return;
            }
        }
        self.write_place(b, s.place);
        if dest != ir::IR_NONE && self.addr_cast(b, &rv) {
            // the cast keeps the address: a deref through the pointer reaches the same place
            let src = self.whole_local(b, b.operands.at(rv.a as usize).data);
            self.copyof.set(dest as usize, CopyBind { src: src, src_v: self.ver(src), my_v: self.ver(dest), ok: true });
        }
    }

    /// The value a length operand reads when it is the `len` of a view built by a struct literal,
    /// else none.
    pub fn view_len(self: &Self, b: &ir::CoreBody, opid: u32) VKey {
        let k = self.vkey(b, opid);
        if !k.is_local || k.off != 0 {
            return vkey_none();
        }
        let lb = *self.lenval.at(k.l as usize);
        if !lb.ok || lb.my_v != self.ver(k.l) || self.ver(lb.src) != lb.src_v {
            return vkey_none();
        }
        return VKey { is_const: false, c: 0, is_local: true, l: lb.src, v: lb.src_v, off: 0 };
    }

    // The value key of the `len` operand of a struct literal of a prelude view, else none.
    fn view_len_key(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) VKey {
        let pk = unsafe &*self.pkg;
        if rv.item.node == NODE_NONE || !pk.modules.at(rv.item.module as usize).prelude {
            return vkey_none();
        }
        let da = unsafe &*pk.module_ast_const(rv.item.module);
        let members = da.at_const(rv.item.node).as_data.aggregate.members;
        for j in 0..members.len {
            let opid = b.oper_pool[(rv.a + j) as usize];
            if opid != ir::IR_NONE && self.is_prelude_field(b, rv.target, unsafe da.list(members)[j as usize], "len") {
                return self.vkey(b, opid);
            }
        }
        return vkey_none();
    }

    // A numeric cast of a whole-local reference or pointer to a reference or pointer type.
    const fn addr_cast(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        if rv.kind != ir::RV_CAST || rv.b != ir::CAST_NUMERIC as u32 {
            return false;
        }
        let op = *b.operands.at(rv.a as usize);
        if op.kind == ir::OP_CONST || self.whole_local(b, op.data) == ir::IR_NONE {
            return false;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        let k1 = da.type_at(op.ty).kind;
        let k2 = da.type_at(rv.target).kind;
        return (k1 == TypeKind::TYPE_POINTER || k1 == TypeKind::TYPE_REFERENCE) && (k2 == TypeKind::TYPE_POINTER || k2 == TypeKind::TYPE_REFERENCE);
    }

    pub fn vkey(self: &Self, b: &ir::CoreBody, opid: u32) VKey {
        return self.vkey_w(b, opid, &self.bst, 0, false);
    }

    // ---- integer facts -----------------------------------------------------------------------------

    /// The fact of operand `opid` at the evaluation point (unknown at the operand's width, or a
    /// zero-width unknown for a non-integer operand). `w`/`sg` receive the operand's kind.
    pub fn ival(self: &Self, b: &ir::CoreBody, opid: u32, w: &mut u32, sg: &mut bool) IFact {
        let op = *b.operands.at(opid as usize);
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        if !self.int_kind(da, op.ty, w, sg) {
            *w = 0;
            return itop(64, false);
        }
        if !self.ion {
            return itop(*w, *sg);
        }
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            if c.kind != ir::CK_INT {
                return itop(*w, *sg);
            }
            let m = if c.item.node != NODE_NONE {
                c.item.module;
            } else {
                b.module;
            };
            let mut v: i64 = 0;
            if !c.int_value(unsafe (&*self.pkg).modules.at(m as usize).source.as_str(), &mut v) {
                return itop(*w, *sg);
            }
            let z = if *sg && v < 0 {
                zk((v as u64).wrapping_neg(), true);
            } else {
                zk(v as u64 & wmask(*w), false);
            };
            if !zle(tmin(*w, *sg), z) || !zle(z, tmax(*w, *sg)) {
                return itop(*w, *sg);
            }
            return iconst(z, *w);
        }
        let l = self.whole_local(b, op.data);
        if l == ir::IR_NONE || self.iw[l as usize] as u32 != *w || self.isg[l as usize] != *sg || self.cst[l as usize] != self.stamp {
            return itop(*w, *sg);
        }
        return self.cur[l as usize];
    }

    /// The fact of local `l` at the evaluation point.
    pub fn ilocal(self: &Self, l: u32) IFact {
        if !self.ion || self.iw[l as usize] == 0 || self.cst[l as usize] != self.stamp {
            return itop(64, false); // unknown at any width: no bound, no stride, no known bits
        }
        return self.cur[l as usize];
    }

    fn iput(self: &mut Self, l: u32, f: IFact) {
        if self.iw[l as usize] == 0 {
            return;
        }
        if self.cst[l as usize] != self.stamp {
            self.cst.set(l as usize, self.stamp);
            self.live.push(l);
        }
        self.cur.set(l as usize, f);
    }

    fn itop_local(self: &mut Self, l: u32) {
        let w = self.iw[l as usize] as u32;
        if w != 0 {
            self.iput(l, itop(w, self.isg[l as usize]));
        }
    }

    // A write of local `l`: its comparison bindings die.
    fn iwrote(self: &mut Self, l: u32) {
        let mut i: usize = 0;
        while i < self.cmps.len() {
            let c = self.cmps[i];
            if c.t == l || c.la == l || c.lb == l {
                let _ = self.cmps.swap_remove(i);
                continue;
            }
            i += 1;
        }
    }

    const fn op_local(self: &Self, b: &ir::CoreBody, opid: u32) u32 {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            return ir::IR_NONE;
        }
        return self.whole_local(b, op.data);
    }

    fn itop_exposed(self: &mut Self) {
        for i in 0..self.explist.len() {
            let l = self.explist[i];
            self.itop_local(l);
            self.iwrote(l);
        }
    }

    fn ikill_roots(self: &mut Self, e: &Effect) {
        if e.over {
            // more roots than fit: nothing in the block survives
            for i in 0..self.live.len() {
                let l = self.live[i];
                self.itop_local(l);
            }
            self.cmps.clear();
            return;
        }
        for i in 0..e.n {
            let l = unsafe e.roots[i as usize];
            self.itop_local(l);
            self.iwrote(l);
        }
    }

    // Load block `blk`'s entry state into the scratch.
    fn iload(self: &mut Self, nl: usize, blk: u32) {
        self.stamp += 1;
        while self.cur.len() < nl {
            self.cur.push(itop(64, false));
            self.cst.push(0);
        }
        self.live.clear();
        self.cmps.clear();
        if !self.ent_set[blk as usize] {
            return;
        }
        let s0 = self.ent_start[blk as usize] as usize;
        for i in s0..s0 + self.ent_len[blk as usize] as usize {
            let e = self.ent[i];
            self.iput(e.l, e.f);
        }
    }

    /// Could an interval proof help body `b`: a fixed array checked, a length compared with a
    /// constant of 2 or more, or a remainder by a constant (the definition scan's candidates)?
    pub fn want_ints(self: &Self, b: &ir::CoreBody) bool {
        if self.grem {
            return true;
        }
        for ci in 0..self.gcand.len() {
            let rv = *b.rvalues.at(b.statements.at(self.gcand[ci] as usize).rvalue as usize);
            if rv.kind == ir::RV_INTRINSIC {
                // A fixed array's length, or a constant one (a vector's lane count).
                let lop = b.oper_pool[(rv.a + if rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN {
                    1;
                } else {
                    rv.b - 1;
                }) as usize];
                if self.fixed_len(b, lop) || self.const_ge2(b, lop) {
                    return true;
                }
            } else if self.len_read(b, rv.a) && self.const_ge2(b, rv.b) || self.len_read(b, rv.b) && self.const_ge2(
                b,
                rv.a,
            ) {
                return true;
            }
        }
        return false;
    }

    /// The scratch at statement `sid` of block `blk` (just solved mid-walk): the block's entry
    /// state, then the transfers of the statements before `sid`.
    pub fn ireplay(self: &mut Self, b: &ir::CoreBody, blk: u32, sid: u32) {
        self.iload(b.locals.len(), blk);
        for k in b.blocks.at(blk as usize).stmt_start..sid {
            self.istep(b, k as usize);
        }
    }

    /// Enter block `blk` in the walk: its solved entry state, or nothing when unsolved.
    pub fn ienter(self: &mut Self, b: &ir::CoreBody, blk: u32) {
        if self.ion {
            self.iload(b.locals.len(), blk);
        }
    }

    /// The transfer of statement `s`: the scratch afterwards holds the facts after it.
    pub fn istep(self: &mut Self, b: &ir::CoreBody, sid: usize) {
        if !self.ion || !self.srel[sid] {
            return;
        }
        let s = b.statements.at(sid);
        if s.kind == ir::ST_STORAGE_DEAD {
            self.itop_local(s.a);
            self.iwrote(s.a);
            return;
        }
        if s.kind != ir::ST_ASSIGN {
            return;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        let e = stmt_effect(b, s);
        if e.kind == EF_ASM || e.kind == EF_PTR {
            self.itop_exposed();
            self.ikill_roots(&e);
            return;
        }
        let p = *b.places.at(s.place as usize);
        if p.proj_len != 0 {
            if b.place_has_deref(s.place) {
                self.itop_exposed();
            }
            return;
        }
        let l = p.base;
        if rv.kind == ir::RV_BINARY && self.iw[l as usize] == 0 {
            let op = norm_op(rv.c);
            if op == tt::TokenType::LessThan as u8 || op == tt::TokenType::LessThanEqual as u8 || op == tt::TokenType::GreaterThan as u8 || op == tt::TokenType::GreaterThanEqual as u8 || op == tt::TokenType::EqualEqual as u8 || op == tt::TokenType::BangEqual as u8 {
                self.iwrote(l);
                if self.cmps.len() >= 4 {
                    let _ = self.cmps.swap_remove(0);
                }
                let la = self.op_local(b, rv.a);
                let lb = self.op_local(b, rv.b);
                self.cmps.push(CmpRec { t: l, a: rv.a, b: rv.b, la: la, lb: lb, op: op });
                return;
            }
        }
        if self.iw[l as usize] == 0 {
            self.iwrote(l);
            return;
        }
        let f = self.irvalue(b, &rv, l);
        self.iwrote(l);
        self.iput(l, f);
    }

    /// The transfer of block `blk`'s terminator before its edges: the tracked locals it can write.
    fn iterm(self: &mut Self, blk: u32) {
        for k in self.tk_start[blk as usize]..self.tk_start[blk as usize + 1] {
            let l = self.tkill[k as usize];
            self.itop_local(l);
        }
    }

    // The solver's slice. Tracked: the integer locals a check reads, what their definitions read,
    // the other side of a comparison with a tracked side, and both sides of a comparison with a
    // length read, closed in a bounded number of passes (a smaller set is sound: an untracked local
    // is unknown). Relevant statements: writes of tracked locals and comparison
    // results, comparisons, assembly, and deref writes when an exposed local is tracked. False when
    // nothing is tracked.
    fn islice(self: &mut Self, b: &ir::CoreBody) bool {
        let nl = b.locals.len();
        let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
        self.cmpt.clear();
        self.cmpt.resize_default(nl);
        self.irel.clear();
        self.irel.resize_default(nl);
        for i in 0..b.statements.len() {
            let st = *b.statements.at(i);
            if st.kind == ir::ST_ASSIGN && b.rvalues.at(st.rvalue as usize).kind == ir::RV_BINARY {
                let op = norm_op(b.rvalues.at(st.rvalue as usize).c);
                let d = self.whole_local(b, st.place);
                if op >= tt::TokenType::EqualEqual as u8 && op <= tt::TokenType::GreaterThanEqual as u8 && d != ir::IR_NONE {
                    self.cmpt.set(d as usize, true);
                }
            }
        }
        self.iw.clear();
        self.isg.clear();
        for i in 0..nl {
            let mut w: u32 = 0;
            let mut sg = false;
            let ld = b.locals.at(i);
            if ld.storage != ir::LS_STATIC_REF {
                let _ = self.int_kind(da, ld.ty, &mut w, &mut sg);
            }
            self.iw.push(w as u8);
            self.isg.push(sg);
        }
        // seeds: the checks' operands and results
        for i in 0..b.statements.len() {
            let st = *b.statements.at(i);
            if st.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            if rv.kind == ir::RV_INTRINSIC && ir::is_check(rv.c) {
                for k in 0..rv.b {
                    let _ = self.irel_op(b, b.oper_pool[(rv.a + k) as usize]);
                }
                let d = self.whole_local(b, st.place);
                if d != ir::IR_NONE && self.iw[d as usize] != 0 {
                    self.irel.set(d as usize, true); // the checked index, refined by the check
                }
            } else if rv.kind == ir::RV_BINARY && (self.len_read(b, rv.a) && self.const_ge2(b, rv.b) || self.len_read(
                b,
                rv.b,
            ) && self.const_ge2(b, rv.a)) {
                let _ = self.irel_op(b, rv.a);
                let _ = self.irel_op(b, rv.b);
            }
        }
        // closure over definitions, bounded
        let mut changed = true;
        let mut rounds = 0;
        while changed && rounds < 4 {
            changed = false;
            rounds += 1;
            let mut i = b.statements.len();
            while i > 0 {
                i -= 1;
                let st = *b.statements.at(i);
                if st.kind != ir::ST_ASSIGN {
                    continue;
                }
                let d = self.whole_local(b, st.place);
                if d == ir::IR_NONE {
                    continue;
                }
                let rv = *b.rvalues.at(st.rvalue as usize);
                if self.cmpt[d as usize] && rv.kind == ir::RV_BINARY {
                    // a comparison bounds a tracked side by the other
                    let la = self.op_local(b, rv.a);
                    let lb = self.op_local(b, rv.b);
                    if la != ir::IR_NONE && self.irel[la as usize] || lb != ir::IR_NONE && self.irel[lb as usize] {
                        changed = self.irel_op(b, rv.a) || changed;
                        changed = self.irel_op(b, rv.b) || changed;
                    }
                    continue;
                }
                if !self.irel[d as usize] {
                    continue;
                }
                if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST {
                    changed = self.irel_op(b, rv.a) || changed;
                } else if rv.kind == ir::RV_BINARY {
                    changed = self.irel_op(b, rv.a) || changed;
                    changed = self.irel_op(b, rv.b) || changed;
                } else if rv.kind == ir::RV_INTRINSIC && (ir::is_check(rv.c) || rv.c == ir::IN_CHUNK) {
                    for k in 0..rv.b {
                        changed = self.irel_op(b, b.oper_pool[(rv.a + k) as usize]) || changed;
                    }
                }
            }
        }
        let mut any = false;
        let mut exp = false;
        for l in 0..nl {
            if !self.irel[l] {
                self.iw.set(l, 0);
            } else if self.iw[l] != 0 {
                any = true;
                exp = exp || self.exposed[l];
            }
        }
        if !any {
            return false;
        }
        // relevant statements
        self.srel.clear();
        self.srel.resize_default(b.statements.len());
        for i in 0..b.statements.len() {
            let st = *b.statements.at(i);
            let mut r = false;
            if st.kind == ir::ST_STORAGE_DEAD {
                r = self.iw[st.a as usize] != 0 || self.cmpt[st.a as usize];
            } else if st.kind == ir::ST_ASSIGN {
                let rv = *b.rvalues.at(st.rvalue as usize);
                let p = *b.places.at(st.place as usize);
                if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_ASM {
                    r = true;
                } else if p.proj_len == 0 {
                    r = self.iw[p.base as usize] != 0 || self.cmpt[p.base as usize];
                } else {
                    r = exp && b.place_has_deref(st.place);
                }
            }
            self.srel.set(i, r);
        }
        // terminator kills
        self.tk_start.clear();
        self.tkill.clear();
        for blk in 0..b.blocks.len() {
            self.tk_start.push(self.tkill.len() as u32);
            if self.seen[blk] == 0 {
                continue;
            }
            let t = b.blocks.at(blk).term;
            if t.kind != ir::TM_CALL && t.kind != ir::TM_DROP {
                continue;
            }
            if exp && term_effect(self.pkg, b, &t).kind != EF_NONE {
                for k in 0..self.explist.len() {
                    if self.iw[self.explist[k] as usize] != 0 {
                        self.tkill.push(self.explist[k]);
                    }
                }
            }
            if t.kind == ir::TM_CALL && t.intr == ir::CI_NONE {
                // a tracked local handed by mutable reference
                for k in 0..t.args_len {
                    let opid = b.oper_pool[(t.args_start + k) as usize];
                    let l = self.op_local(b, opid);
                    if l != ir::IR_NONE && self.iw[l as usize] != 0 {
                        let y = da.type_at(b.operands.at(opid as usize).ty);
                        if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                            self.tkill.push(l);
                        }
                    }
                }
            }
            if t.kind == ir::TM_CALL {
                for k in 0..t.dests_len {
                    let p = *b.places.at(b.dest_pool[(t.dests_start + k) as usize] as usize);
                    if p.proj_len == 0 && self.iw[p.base as usize] != 0 {
                        self.tkill.push(p.base);
                    }
                }
            }
        }
        self.tk_start.push(self.tkill.len() as u32);
        return true;
    }

    // Is operand `opid` an integer constant of 2 or more?
    pub fn const_ge2(self: &Self, b: &ir::CoreBody, opid: u32) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_CONST {
            return false;
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind != ir::CK_INT {
            return false;
        }
        let m = if c.item.node != NODE_NONE {
            c.item.module;
        } else {
            b.module;
        };
        let mut v: i64 = 0;
        return c.int_value(unsafe (&*self.pkg).modules.at(m as usize).source.as_str(), &mut v) && v >= 2;
    }

    // Is operand `opid` a whole local whose single definition is the length of a fixed array?
    pub fn fixed_len(self: &Self, b: &ir::CoreBody, opid: u32) bool {
        let l0 = self.op_local(b, opid);
        if l0 == ir::IR_NONE {
            return false;
        }
        let l = self.def_src(b, l0);
        if l == ir::IR_NONE || self.def1[l as usize] == ir::IR_NONE {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(self.def1[l as usize] as usize).rvalue as usize);
        if rv.kind != ir::RV_LEN {
            return false;
        }
        let ty = b.places.at(rv.a as usize).ty;
        if ty == TYPE_NONE {
            return false;
        }
        let y = (unsafe &*(&*self.pkg).module_ast_const(b.module)).type_at(ty);
        return y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym();
    }

    // Does operand `opid` read a length: a whole local whose single definition is a length or a field
    // read?
    pub fn len_read(self: &Self, b: &ir::CoreBody, opid: u32) bool {
        let l0 = self.op_local(b, opid);
        if l0 == ir::IR_NONE {
            return false;
        }
        let l = self.def_src(b, l0);
        if l == ir::IR_NONE || self.def1[l as usize] == ir::IR_NONE {
            return false;
        }
        let rv = *b.rvalues.at(b.statements.at(self.def1[l as usize] as usize).rvalue as usize);
        if rv.kind == ir::RV_LEN {
            return true;
        }
        if rv.kind != ir::RV_USE {
            return false;
        }
        let op = *b.operands.at(rv.a as usize);
        if op.kind == ir::OP_CONST {
            return false;
        }
        let p = *b.places.at(op.data as usize);
        return p.proj_len != 0 && b.projections.at((p.proj_start + p.proj_len - 1) as usize).kind == ir::PJ_FIELD;
    }

    // Mark the whole-local integer operand `opid` tracked; true when newly marked.
    fn irel_op(self: &mut Self, b: &ir::CoreBody, opid: u32) bool {
        if opid == ir::IR_NONE {
            return false;
        }
        let l = self.op_local(b, opid);
        if l == ir::IR_NONE || self.irel[l as usize] || self.iw[l as usize] == 0 {
            return false;
        }
        self.irel.set(l as usize, true);
        return true;
    }

    // The fact of rvalue `rv` assigned to tracked local `l`.
    fn irvalue(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, l: u32) IFact {
        let w = self.iw[l as usize] as u32;
        let sg = self.isg[l as usize];
        let top = itop(w, sg);
        let mut aw: u32 = 0;
        let mut asg = false;
        if rv.kind == ir::RV_USE {
            let f = self.ival(b, rv.a, &mut aw, &mut asg);
            if aw == w && asg == sg {
                return f;
            }
            return top;
        }
        if rv.kind == ir::RV_CAST {
            if rv.b != ir::CAST_NUMERIC as u32 {
                return top;
            }
            let f = self.ival(b, rv.a, &mut aw, &mut asg);
            if aw == 0 {
                return top;
            }
            return icast(&f, aw, w, sg);
        }
        if rv.kind == ir::RV_LEN {
            // a raw array's fixed extent
            let da = unsafe &*(&*self.pkg).module_ast_const(b.module);
            let ty = b.places.at(rv.a as usize).ty;
            if ty != TYPE_NONE {
                let y = *da.type_at(ty);
                if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() && y.as_data.arr.len >= 0 {
                    return iconst(zk(y.as_data.arr.len, false), w);
                }
            }
            return top;
        }
        if rv.kind == ir::RV_BINARY {
            let a = self.ival(b, rv.a, &mut aw, &mut asg);
            let mut bw: u32 = 0;
            let mut bsg = false;
            let c = self.ival(b, rv.b, &mut bw, &mut bsg);
            if aw == 0 || bw == 0 {
                return top;
            }
            return ibinary(norm_op(rv.c), &a, &c, aw, w, sg);
        }
        if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_BOUNDS || rv.c == ir::IN_BOUNDS_PROVEN || rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN) {
            // the checked index: below the length (minus the group's width) once the check passed
            let iop = b.oper_pool[rv.a as usize];
            let mut f = self.ival(b, iop, &mut aw, &mut asg);
            let mut lw: u32 = 0;
            let mut lsg = false;
            let lf = self.ival(b, b.oper_pool[(rv.a + 1) as usize], &mut lw, &mut lsg);
            if aw != w || asg || lw == 0 {
                return top;
            }
            let mut cap = fhi(&lf);
            let mut ok = true;
            if rv.c == ir::IN_BOUNDS_GROUP || rv.c == ir::IN_BOUNDS_GROUP_PROVEN {
                let mut gw: u32 = 0;
                let mut gsg = false;
                let gf = self.ival(b, b.oper_pool[(rv.a + 2) as usize], &mut gw, &mut gsg);
                cap = zadd(cap, zneg(flo(&gf)), &mut ok);
            }
            cap = zadd(cap, zk(1, true), &mut ok);
            if ok && zlt(cap, fhi(&f)) {
                let lo = flo(&f);
                if !iset(&mut f, lo, cap) {
                    return f; // the check always fails here: the value is never used
                }
            }
            let il = self.op_local(b, iop);
            if il != ir::IR_NONE && self.iw[il as usize] as u32 == w {
                self.iput(il, f);
            }
            return f;
        }
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_CHUNK {
            // i < lim <= end
            let f = self.ival(b, b.oper_pool[rv.a as usize], &mut aw, &mut asg);
            let mut ew: u32 = 0;
            let mut esg = false;
            let ef = self.ival(b, b.oper_pool[(rv.a + 1) as usize], &mut ew, &mut esg);
            if aw != w || ew != w {
                return top;
            }
            let mut ok = true;
            let lo = zadd(flo(&f), zk(1, false), &mut ok);
            let mut r = top;
            if ok && iset(&mut r, lo, fhi(&ef)) {
                return r;
            }
            return top;
        }
        return top;
    }

    // ---- solver ------------------------------------------------------------------------------------

    /// Solve the integer facts of body `b` (after `begin`): block-entry states to a fixed point with
    /// widening at loop headers, then one narrowing pass.
    pub fn solve(self: &mut Self, b: &ir::CoreBody) {
        let nb = b.blocks.len();
        let sl = self.rpo.len() != 0 && self.islice(b);
        if !sl {
            return; // nothing tracked: every fact is unknown, no solver state
        }
        self.ent.clear();
        self.ent_start.clear();
        self.ent_start.resize_default(nb);
        self.ent_len.clear();
        self.ent_len.resize_default(nb);
        self.ent_set.clear();
        self.ent_set.resize_default(nb);
        self.dirty.clear();
        self.dirty.resize_default(nb);
        self.nwide.clear();
        self.nwide.resize_default(nb);
        self.ion = true;
        let e0 = self.rpo[0] as usize;
        self.ent_set.set(e0, true);
        self.dirty.set(e0, true);
        let mut visits: usize = 0;
        let cap = 8 * self.rpo.len() + 64;
        let mut changed = true;
        while changed {
            changed = false;
            for bi in 0..self.rpo.len() {
                let blk = self.rpo[bi];
                if !self.dirty[blk as usize] {
                    continue;
                }
                self.dirty.set(blk as usize, false);
                changed = true;
                visits += 1;
                if visits > cap || self.ent.len() > IPOOL_MAX {
                    self.ilimited = true;
                    self.ent_set.clear();
                    self.ent_set.resize_default(nb);
                    return;
                }
                self.visit(b, blk, false);
            }
        }

        // narrowing: every block once from the fixed point, into fresh accumulators
        self.nar.clear();
        self.nar_start.clear();
        self.nar_start.resize_default(nb);
        self.nar_len.clear();
        self.nar_len.resize_default(nb);
        self.nar_set.clear();
        self.nar_set.resize_default(nb);
        self.nar_set.set(e0, true);
        for bi in 0..self.rpo.len() {
            let blk = self.rpo[bi];
            if self.ent_set[blk as usize] {
                self.visit(b, blk, true);
            }
        }
        if self.nar.len() <= IPOOL_MAX {
            for bi in 0..self.rpo.len() {
                let blk = self.rpo[bi] as usize;
                if self.nar_set[blk] && self.ent_set[blk] {
                    self.ent_start.set(blk, self.ent.len() as u32);
                    let s0 = self.nar_start[blk] as usize;
                    for i in s0..s0 + self.nar_len[blk] as usize {
                        let x = self.nar[i];
                        self.ent.push(x);
                    }
                    self.ent_len.set(blk, self.nar_len[blk]);
                }
            }
        }
    }

    // Evaluate block `blk` from its entry state and join its exits into its successors (`narrow`:
    // into the narrowing accumulators, without widening).
    fn visit(self: &mut Self, b: &ir::CoreBody, blk: u32, narrow: bool) {
        self.iload(b.locals.len(), blk);
        let bb = *b.blocks.at(blk as usize);
        for si in 0..bb.stmt_len {
            self.istep(b, (bb.stmt_start + si) as usize);
        }
        let t = bb.term;
        self.iterm(blk);
        // the exit state (sorted by local, cross-block locals only, bounded)
        self.jbuf.clear();
        self.live.sort();
        for i in 0..self.live.len() {
            let l = self.live[i];
            if i > 0 && self.live[i - 1] == l {
                continue;
            }
            let f = self.cur[l as usize];
            if iis_top(&f, self.iw[l as usize], self.isg[l as usize]) {
                continue;
            }
            if self.jbuf.len() >= IWIDTH_MAX {
                self.ilimited = true;
                break;
            }
            self.jbuf.push(IEnt { f: f, l: l });
        }
        // the branch condition of a two-way switch on a comparison of this block
        let mut cmp = ir::IR_NONE;
        let mut tval: u64 = 0;
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 || t.kind == ir::TM_ASSERT {
            let cl = self.op_local(b, t.a);
            for i in 0..self.cmps.len() {
                if self.cmps[i].t == cl && cl != ir::IR_NONE {
                    cmp = i as u32;
                }
            }
            if t.kind == ir::TM_SWITCH {
                tval = b.switch_pool[t.sw_start as usize] >> 32;
            }
        }
        for i in 0..self.succ_count(b, blk as usize) {
            let s = self.succ_at(b, blk as usize, i);
            self.ebuf.clear();
            for k in 0..self.jbuf.len() {
                let x = self.jbuf[k];
                self.ebuf.push(x);
            }
            if cmp != ir::IR_NONE && (tval == 0 || tval == 1) {
                // switch: target i == 0 is the edge where the condition equals tval; t0 the other.
                // assert: t0 is the edge where the condition holds.
                let holds = if t.kind == ir::TM_ASSERT {
                    true;
                } else {
                    i == 0 == (tval == 1);
                };
                if !self.refine(b, self.cmps[cmp as usize], holds) {
                    continue; // the edge cannot run
                }
            }
            self.join_into(s, blk, narrow);
        }
    }

    // Refine `ebuf` by comparison `c` holding (`holds`) or not; false when the edge cannot run.
    fn refine(self: &mut Self, b: &ir::CoreBody, c: CmpRec, holds: bool) bool {
        let mut aw: u32 = 0;
        let mut asg = false;
        let mut bw: u32 = 0;
        let mut bsg = false;
        let mut fa = self.ival(b, c.a, &mut aw, &mut asg);
        let mut fb = self.ival(b, c.b, &mut bw, &mut bsg);
        if aw == 0 || bw == 0 {
            return true;
        }
        // canonical a < b or a <= b, by swapping and negating
        let mut op = c.op;
        let mut swap = false;
        if op == tt::TokenType::GreaterThan as u8 {
            op = tt::TokenType::LessThan as u8;
            swap = true;
        } else if op == tt::TokenType::GreaterThanEqual as u8 {
            op = tt::TokenType::LessThanEqual as u8;
            swap = true;
        }
        if op == tt::TokenType::EqualEqual as u8 || op == tt::TokenType::BangEqual as u8 {
            if op == tt::TokenType::EqualEqual as u8 != holds {
                return true; // a != b refines nothing
            }
            let lo = if zlt(flo(&fa), flo(&fb)) {
                flo(&fb);
            } else {
                flo(&fa);
            };
            let hi = if zlt(fhi(&fa), fhi(&fb)) {
                fhi(&fa);
            } else {
                fhi(&fb);
            };
            if !iset(&mut fa, lo, hi) || !iset(&mut fb, lo, hi) {
                return false;
            }
        } else {
            let mut x = fa;
            let mut y = fb;
            if swap {
                x = fb;
                y = fa;
            }
            let mut strict = op == tt::TokenType::LessThan as u8;
            if !holds {
                // !(x < y) is y <= x; !(x <= y) is y < x
                let t = x;
                x = y;
                y = t;
                strict = !strict;
            }
            let mut ok = true;
            let d = if strict {
                zk(1, false);
            } else {
                zk(0, false);
            };
            let xhi = zadd(fhi(&y), zneg(d), &mut ok);
            let ylo = zadd(flo(&x), d, &mut ok);
            if !ok {
                return true;
            }
            if zlt(xhi, fhi(&x)) {
                let lo = flo(&x);
                if !iset(&mut x, lo, xhi) {
                    return false;
                }
            }
            if zlt(flo(&y), ylo) {
                let hi = fhi(&y);
                if !iset(&mut y, ylo, hi) {
                    return false;
                }
            }
            if !holds {
                let t = x;
                x = y;
                y = t;
            }
            if swap {
                fa = y;
                fb = x;
            } else {
                fa = x;
                fb = y;
            }
        }
        self.ebuf_put(b, c.a, fa);
        self.ebuf_put(b, c.b, fb);
        return true;
    }

    // Replace or insert the fact of operand `opid`'s local in `ebuf` (kept sorted).
    fn ebuf_put(self: &mut Self, b: &ir::CoreBody, opid: u32, f: IFact) {
        let l = self.op_local(b, opid);
        if l == ir::IR_NONE || self.iw[l as usize] == 0 {
            return;
        }
        let mut i: usize = 0;
        while i < self.ebuf.len() && self.ebuf[i].l < l {
            i += 1;
        }
        if i < self.ebuf.len() && self.ebuf[i].l == l {
            self.ebuf[i].f = f;
            return;
        }
        if self.ebuf.len() >= IWIDTH_MAX {
            self.ilimited = true;
            return;
        }
        self.ebuf.insert(i, IEnt { f: f, l: l });
    }

    // Join `ebuf` (the edge from `from`) into block `s`'s entry state.
    fn join_into(self: &mut Self, s: u32, from: u32, narrow: bool) {
        let su = s as usize;
        if narrow {
            if !self.nar_set[su] {
                self.nar_set.set(su, true);
                self.nar_start.set(su, self.nar.len() as u32);
                for k in 0..self.ebuf.len() {
                    let x = self.ebuf[k];
                    self.nar.push(x);
                }
                self.nar_len.set(su, self.ebuf.len() as u32);
                return;
            }
            let s0 = self.nar_start[su] as usize;
            let n0 = self.nar_len[su] as usize;
            let st = self.nar.len();
            self.merge(true, s0, n0, false);
            self.nar_start.set(su, st as u32);
            self.nar_len.set(su, (self.nar.len() - st) as u32);
            return;
        }
        if !self.ent_set[su] {
            self.ent_set.set(su, true);
            self.ent_start.set(su, self.ent.len() as u32);
            for k in 0..self.ebuf.len() {
                let x = self.ebuf[k];
                self.ent.push(x);
            }
            self.ent_len.set(su, self.ebuf.len() as u32);
            self.dirty.set(su, true);
            return;
        }
        let s0 = self.ent_start[su] as usize;
        let n0 = self.ent_len[su] as usize;
        let back = self.rpo_of[from as usize] >= self.rpo_of[su];
        let mut widen = false;
        if back && self.nwide[su] >= 2 {
            widen = true;
        }
        let st = self.ent.len();
        self.merge(false, s0, n0, widen);
        let n1 = self.ent.len() - st;
        // unchanged: drop the copy
        let mut same = n1 == n0;
        if same {
            for k in 0..n0 {
                let x = self.ent[s0 + k];
                let y = self.ent[st + k];
                if x.l != y.l || !ieq(&x.f, &y.f) {
                    same = false;
                    break;
                }
            }
        }
        if same {
            self.ent.truncate(st);
            return;
        }
        if back && self.nwide[su] < 2 {
            self.nwide.set(su, self.nwide[su] + 1);
        }
        self.ent_start.set(su, st as u32);
        self.ent_len.set(su, n1 as u32);
        self.dirty.set(su, true);
    }

    // Append join(pool[s0 .. s0 + n0], ebuf) to the pool (`nar` or `ent`), widening a bound that grew.
    fn merge(self: &mut Self, nar: bool, s0: usize, n0: usize, widen: bool) {
        let mut i: usize = 0;
        let mut j: usize = 0;
        while i < n0 && j < self.ebuf.len() {
            let x = if nar {
                self.nar[s0 + i];
            } else {
                self.ent[s0 + i];
            };
            let y = self.ebuf[j];
            if x.l < y.l {
                i += 1;
                continue;
            }
            if y.l < x.l {
                j += 1;
                continue;
            }
            let w = self.iw[x.l as usize] as u32;
            let sg = self.isg[x.l as usize];
            let mut f = ijoin(&x.f, &y.f);
            if widen {
                if zlt(flo(&f), flo(&x.f)) {
                    let hi = fhi(&f);
                    let _ = iset(&mut f, tmin(w, sg), hi);
                    f.wid = true;
                }
                if zlt(fhi(&x.f), fhi(&f)) {
                    let lo = flo(&f);
                    let _ = iset(&mut f, lo, tmax(w, sg));
                    f.wid = true;
                }
            }
            if !iis_top(&f, w, sg) {
                if nar {
                    self.nar.push(IEnt { f: f, l: x.l });
                } else {
                    self.ent.push(IEnt { f: f, l: x.l });
                }
            }
            i += 1;
            j += 1;
        }
    }
}

/// May writes to the subtree of place `p1` change place `p2`? The caller knows both reach the same
/// root (the bases are that root, or copies of a reference parameter). Two field paths that
/// diverge at different fields of a struct, or two different constant indexes, are disjoint.
pub fn places_overlap(b: &ir::CoreBody, p1: u32, p2: u32) bool {
    let a = *b.places.at(p1 as usize);
    let c = *b.places.at(p2 as usize);
    let n = a.proj_len.min(c.proj_len);
    for i in 0..n {
        let x = *b.projections.at((a.proj_start + i) as usize);
        let y = *b.projections.at((c.proj_start + i) as usize);
        if x.kind != y.kind {
            return true;
        }
        if x.kind == ir::PJ_FIELD && x.data != ir::PJ_UNION_FIELD && y.data != ir::PJ_UNION_FIELD && (x.sub != NODE_NONE && y.sub != NODE_NONE && x.sub != y.sub || x.data != ir::IR_NONE && y.data != ir::IR_NONE && x.data != y.data) {
            return false; // two fields of one struct (by declaration, or by index when both carry one)
        }
        if x.kind == ir::PJ_INDEX_CONST && x.data != y.data {
            return false;
        }
    }
    return true;
}

// The base local of place `pl`.
const fn rp_base(b: &ir::CoreBody, pl: u32) u32 {
    return b.places.at(pl as usize).base;
}

// A compound-assignment operator as its plain operator.
const fn norm_op(c: u8) u8 {
    let t = c as tt::TokenType;
    let r = switch t {
        PlusEqual => tt::TokenType::Plus,
        MinusEqual => tt::TokenType::Minus,
        StarEqual => tt::TokenType::Star,
        SlashEqual => tt::TokenType::Slash,
        PercentEqual => tt::TokenType::Percent,
        AmpersandEqual => tt::TokenType::Ampersand,
        PipeEqual => tt::TokenType::Pipe,
        CaretEqual => tt::TokenType::Caret,
        LeftShiftEqual => tt::TokenType::LeftShift,
        RightShiftEqual => tt::TokenType::RightShift,
        _ => t,
    };
    return r as u8;
}

// The fact of `f` (width `fw`) converted to width `w` (signed `sg`): the interval stays when it
// fits, the low bits and a power-of-two stride stay through a wrap.
const fn icast(f: &IFact, fw: u32, w: u32, sg: bool) IFact {
    let mut r = itop(w, sg);
    let a = flo(f);
    let c = fhi(f);
    if zle(tmin(w, sg), a) && zle(c, tmax(w, sg)) {
        let _ = iset(&mut r, a, c);
        r.st = f.st;
        r.ph = f.ph;
        r.wid = f.wid;
    } else {
        r.st = f.st;
        r.ph = f.ph;
        wrap_stride(&mut r, w);
    }
    let keep = wmask(fw.min(w));
    r.kz = f.kz & keep;
    r.ko = f.ko & keep;
    if w > fw && !f.ln {
        // a non-negative source: the new high bits are zero
        r.kz |= wmask(w) & ~wmask(fw);
    }
    exact_bits(&mut r, w);
    return r;
}

// The fact of `a op b` at the result's width `w` (operands of width `aw`).
const fn ibinary(op: u8, a: &IFact, b: &IFact, aw: u32, w: u32, sg: bool) IFact {
    let t = op as tt::TokenType;
    let mut r = itop(w, sg);
    let mut ok = true;
    if t == tt::TokenType::Plus || t == tt::TokenType::Minus {
        let neg = t == tt::TokenType::Minus;
        let lo = if neg {
            zadd(flo(a), zneg(fhi(b)), &mut ok);
        } else {
            zadd(flo(a), flo(b), &mut ok);
        };
        let hi = if neg {
            zadd(fhi(a), zneg(flo(b)), &mut ok);
        } else {
            zadd(fhi(a), fhi(b), &mut ok);
        };
        let kb = add_bits(a, b, neg, w);
        r.kz = kb.kz;
        r.ko = kb.ko;
        add_stride(&mut r, a, b, neg);
        ifit(&mut r, lo, hi, ok, w, sg);
    } else if t == tt::TokenType::Star {
        let p1 = zmul(flo(a), flo(b), &mut ok);
        let p2 = zmul(flo(a), fhi(b), &mut ok);
        let p3 = zmul(fhi(a), flo(b), &mut ok);
        let p4 = zmul(fhi(a), fhi(b), &mut ok);
        let mut lo = p1;
        let mut hi = p1;
        if zlt(p2, lo) {
            lo = p2;
        }
        if zlt(hi, p2) {
            hi = p2;
        }
        if zlt(p3, lo) {
            lo = p3;
        }
        if zlt(hi, p3) {
            hi = p3;
        }
        if zlt(p4, lo) {
            lo = p4;
        }
        if zlt(hi, p4) {
            hi = p4;
        }
        // low bits: the product of the known low bits
        let kt = known_low(a, w).min(known_low(b, w));
        if kt > 0 {
            let v = a.ko.wrapping_mul(b.ko) & wmask(kt);
            r.kz = ~v & wmask(kt);
            r.ko = v;
        }
        // stride: a multiple of a constant
        let mut ce = a;
        let mut sv = b;
        if iexact(b) {
            ce = b;
            sv = a;
        }
        if iexact(ce) && !iexact(sv) && sv.st > 1 {
            let (m, o1) = sv.st.overflowing_mul(ce.lo);
            if !o1 && m > 1 && m <= 0x4000000000000000u64 {
                let mut ok2 = true;
                let ph = zmul(zk(sv.ph, false), flo(ce), &mut ok2);
                if ok2 {
                    r.st = m;
                    r.ph = zres(ph, m);
                }
            }
        }
        ifit(&mut r, lo, hi, ok, w, sg);
    } else if t == tt::TokenType::Slash {
        if !a.ln && !b.ln && !(b.lo == 0) {
            let _ = iset(&mut r, zk(a.lo / b.hi, false), zk(a.hi / b.lo, false));
        }
    } else if t == tt::TokenType::Percent {
        if !a.ln && !b.ln && b.lo > 0 {
            let mut hi = b.hi - 1;
            if a.hi < hi {
                hi = a.hi;
            }
            let mut lo: u64 = 0;
            if a.hi < b.lo {
                lo = a.lo;
            }
            let _ = iset(&mut r, zk(lo, false), zk(hi, false));
            if iexact(b) && b.lo.is_power_of_two() {
                let m = b.lo - 1;
                r.kz = a.kz & m | wmask(w) & ~m;
                r.ko = a.ko & m;
            }
        }
    } else if t == tt::TokenType::Ampersand || t == tt::TokenType::Pipe || t == tt::TokenType::Caret {
        if t == tt::TokenType::Ampersand {
            r.kz = (a.kz | b.kz) & wmask(w);
            r.ko = a.ko & b.ko;
            // a non-negative operand bounds the result
            if !a.ln && !b.ln {
                let _ = iset(&mut r, zk(0, false), zk(a.hi.min(b.hi), false));
            } else if !a.ln {
                let _ = iset(&mut r, zk(0, false), zk(a.hi, false));
            } else if !b.ln {
                let _ = iset(&mut r, zk(0, false), zk(b.hi, false));
            }
        } else {
            if t == tt::TokenType::Pipe {
                r.ko = a.ko | b.ko;
                r.kz = a.kz & b.kz;
            } else {
                r.ko = a.ko & b.kz | a.kz & b.ko;
                r.kz = a.kz & b.kz | a.ko & b.ko;
            }
            if !a.ln && !b.ln {
                let top = a.hi.max(b.hi);
                let bits = 64 - top.leading_zeros() as u32;
                let _ = iset(&mut r, zk(0, false), zk(wmask(bits), false));
            }
        }
    } else if t == tt::TokenType::LeftShift || t == tt::TokenType::RightShift {
        if !iexact(b) || b.ln || b.lo >= aw as u64 {
            return r;
        }
        let k = b.lo as u32;
        if t == tt::TokenType::LeftShift {
            let p = zk(1u64 << k as u64, false);
            let lo = zmul(flo(a), p, &mut ok);
            let hi = zmul(fhi(a), p, &mut ok);
            r.kz = (a.kz << k as u64 | wmask(k)) & wmask(w);
            r.ko = a.ko << k as u64 & wmask(w);
            if !iexact(a) && a.st > 1 {
                let (m, o1) = a.st.overflowing_mul(1u64 << k as u64);
                if !o1 && m <= 0x4000000000000000u64 {
                    r.st = m;
                    r.ph = (a.ph << k as u64) % m;
                }
            }
            ifit(&mut r, lo, hi, ok, w, sg);
        } else if !a.ln {
            let _ = iset(&mut r, zk(a.lo >> k as u64, false), zk(a.hi >> k as u64, false));
            r.kz = (a.kz & wmask(aw)) >> k as u64 | wmask(w) & ~wmask(aw - k);
            r.ko = (a.ko & wmask(aw)) >> k as u64;
        }
    } else {
        return r;
    }
    exact_bits(&mut r, w);
    return r;
}
