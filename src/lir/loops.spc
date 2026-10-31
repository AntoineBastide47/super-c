// The loop transforms of an optimizing build, on innermost loops, by copying a loop's blocks.
//
// Full unrolling: a loop whose trip count the body's constants fix is peeled that many times, when the
// copies' instructions that do not fold (`LoopOpt::residual`) fit the budget. Each copy of the loop's
// blocks runs one iteration and continues into the next copy, the last one into the loop itself: any peel
// count keeps the body's meaning, and the exact one leaves the loop unreachable. The optimizer's next walk
// forwards each copy's parameters, folds its exit test, and the rebuild drops the loop (GCC's complete
// peeling, LLVM's full unrolling).
//
// A loop qualifies when it holds no other loop, has a preheader and one back edge, no value it defines is
// used outside it (each one leaves through an edge's arguments), it holds no inline assembly (whose labels
// a copy would repeat), and its header or latch ends in a branch on an integer comparison of a constant
// with a header parameter, or that parameter plus or minus a constant, the parameter starting at a
// constant and stepping by that addition. Its iterations then follow by the evaluator's own arithmetic.
//
// Final values (LLVM's IndVarSimplify exit values over SCEV's chains of recurrences, GCC's final value
// replacement): a loop whose instructions have no effect and cannot trap, which leaves only by a branch on
// a comparison of a counter (a header parameter stepping by a constant) plus an invariant with a bound it
// does not define, goes when each value it leaves with is a polynomial of the iteration. The facts of
// each value (`Poly`) follow its operations: a constant or invariant is of degree 0; a header parameter
// that steps by itself plus a polynomial that does not read it (`lin`) is one degree above that polynomial,
// resolved in rounds, so a chain of accumulators of any order resolves; sums, differences and products add
// or take the larger degree; a conversion keeps the bits it keeps (an extension keeps the polynomial when
// the interval of its integer values fits); an exact right shift divides it; a select whose condition the
// intervals decide (the counter's run from its start to the bound) takes that side, one on an invariant
// condition either. A header parameter that steps by an `xor` with an invariant alternates between two
// values, and so does any value of such ones and invariants: it leaves with its value on the iteration
// the trip count's parity gives. A loop that runs while a value is not 0, the value losing its lowest set
// bit per iteration (`x &= x - 1`) or shifting right by 1, counts its iterations by `popcnt` or the bit
// length (`clz`): LLVM's loop idiom recognition of bit counts. A block that replaces the loop computes the values the loop's instructions take on
// iterations 0 to the degree (copies of them, so any combination of these operations works), takes their
// differences (the polynomial's coefficients in the binomial basis), and sums each coefficient times the
// binomial of the trip count, its factorial's twos shifted out (`lshr.exact`) in a type twice as wide and
// its odd part multiplied out by its inverse: exact modulo the value's bits. The trip count, from the
// start, the step and the bound, is 0 when the start is past the bound; a bound that would let the
// counter wrap past it takes a guard that runs the loop instead. A loop around one that went is innermost
// in the next round, and its own analysis reads the block's arithmetic: nested sums go too.
//
// Vectorization (LLVM's LoopVectorize, GCC's tree-vectorize, for the simplest of their loops): a loop of
// a header that tests `i <u n` (or `i <s n` from a constant of at least 0) and one block that steps `i`
// by 1, whose other values are loads and stores of `base[i]` (each `base` the loop does not define), loads
// of one place the loop's stores keep apart from (their alias classes; the copy loads it once before
// its iterations, which run only when the body would),
// lane-wise arithmetic of them and of values defined before the loop, and reductions (a header parameter
// the block only combines with one such value by an integer `add`, `and`, `or` or `xor`, or a float
// `fadd` when the build allows reassociation) gets a copy that runs 16 bytes of lanes at a time,
// `vector` copies of them interleaved, while at least that many iterations are left; the loop runs the
// rest. A guard before the copy checks the count and that each stored range overlaps no other range the
// loop reads or writes through another base (same base, same element: an update in place). A loop of up
// to ILV_SIZE instructions that does not vectorize (a 64-bit product, a lane of 8 bytes on a 16-byte
// vector's terms) runs `vector` scalar copies of its body the same way (LLVM's interleaving at a vector
// factor of 1): each instruction's copies together, so their loads and stores pair (`ldp`, `stp`). Its
// counter may be narrower than a pointer or count down to 0 (`r *= b` while `e != 0`), each copy reads its
// own counter value, and a reduction may combine a value from before the loop.
//
// Beyond that shape: a load through every 2nd or 4th element unzips its vectors (`vunzip`); a group of
// stores that writes every element of such a step zips its vectors and stores them whole (`vziplo`,
// `vziphi`: `store_groups`); a header parameter that a select of a lane value and itself on their
// comparison updates is a min or max reduction (`minmax`); the counter truncated is a lane value (a splat
// plus each lane's iteration); a body with one branch whose sides meet again runs both as selects
// (`linearize`). Where the target converts vectors and shifts their lanes in registers (`Package.vops`),
// a plan mixes lane widths up to a factor of two (narrower vectors fill half a register), converts and
// shifts. `SC_VEC_REPORT=1` prints why each loop that stays scalar does (a debugging aid).
//
// Rotation (LLVM's LoopRotate, GCC's loop header copying): a loop whose header only tests whether to run
// the body gets a copy of the header the latch enters instead, so each iteration ends in one conditional
// branch back into the body rather than a jump to the test. The header stays as the test before the
// first iteration. The values the header defines that the body uses enter the body as its parameters,
// from the header and from the copy.
import lir::ir as *;
import lir::eval as le;
import lir::verify as lv;
import ir::core as core;
import ast::ast as ast;
import stdlib;

/// A loop peels at most MAX_PEEL times.
pub(package) const MAX_PEEL: u32 = 32;
// `LoopOpt::residual` follows a chain of RESIDUAL_PASSES instructions of the counter.
const RESIDUAL_PASSES: u32 = 4;
// At most MAX_OUT of a loop's values are used outside it (`LoopOpt::close`).
const MAX_OUT: usize = 32;
// A loop versions on at most MAX_CHECKS bounds checks; a vectorized loop checks at most MAX_CHECKS pairs
// of ranges.
const MAX_CHECKS: usize = 8;
// The fewest bytes of a vector the vectorizer makes; it makes the target's widest (`LoopOpt.vbytes`).
const VBYTES: u32 = 16;
// The blocks of a chain unroll and jam takes before or after the inner loop (`jam_chain`).
const JAM_CHAIN: u32 = 4;
// The most instructions of a loop's body the vectorizer interleaves as scalars.
const ILV_SIZE: u32 = 12;
// Final values: loops of at most CF_SIZE instructions, values of degree at most CF_DEG.
const CF_SIZE: u32 = 256;
const CF_DEG: u32 = 8;

// No condition (`LoopOpt::minmax`).
const NONE16: u16 = 0xFFFF;

// What a vectorized loop's instruction is (`LoopOpt.vk`).
const VK_STEP: u8 = 1; // the counter's step
const VK_ADDR: u8 = 2; // `base + i * size + offset`
const VK_LANE: u8 = 3; // a lane value: a load or arithmetic
const VK_STORE: u8 = 4;
const VK_RED: u8 = 5; // a reduction's update
const VK_INV: u8 = 6; // a load of an address the loop does not define, which no store of it touches
const VK_MASK: u8 = 7; // a comparison of lane values, or `and`/`or` of two: a select's condition
const VK_GADDR: u8 = 8; // `base + lane value * size + offset`: a gathered load's or a scattered store's address
const VK_RCMP: u8 = 9; // the comparison of a min or max reduction's select (`minmax`)

/// The peeling's scratch, reused from body to body.
pub(package) struct LoopOpt {
    owner: Vector<u32>, // per instruction, its block
    powner: Vector<u32>, // per block parameter, its block
    inl: Vector<bool>, // per block, whether it is in the loop at hand
    lblocks: Vector<u32>, // the loop's blocks, in body order
    imap: Vector<u32>, // per instruction of the loop, its value in the copy at hand
    pmap: Vector<u32>, // per block parameter of the loop, the copy's
    bmap: Vector<u32>, // per block of the loop, the copy's
    uses: Vector<Value>,
    edges: Vector<u32>,
    args: Vector<Value>,
    lout: Vector<Value>, // the loop's values the blocks outside it use (`close`)
    tgts: Vector<u32>, // the loop's exit targets
    lbase: Vector<u32>, // per exit target, its landing block's first parameter for `lout` (NONE: none)
    tgt_of: Vector<u32>, // per block, the exit target that dominates its uses of `lout` (NONE: no use)
    tused: Vector<bool>, // per block, whether it is an exit target `tgt_of` names
    // Per block, the block of the body before the first transform whose dominators it has: itself, a
    // copy's original, a landing block's target, a guard block's preheader.
    proxy: Vector<u32>,
    latch: u32, // the loop's block whose edge goes back to its header (`shape`)
    ctr: Value, // the counted loop's counter, a header parameter (`trip`)
    fixed: Vector<bool>, // per instruction, whether a copy computes it from constants (`residual`)
    // Bounds-check versioning (`checks`): the blocks whose branches the fast copy drops, the side each one
    // keeps (0: its taken edge, 1: the other), and the guard's comparisons (`n <= len` each; for a check of
    // `q << gsh + goff`, `n <= bound(len)`: `checks`).
    fixes: Vector<u32>,
    fside: Vector<u8>,
    gx: Vector<Value>,
    gy: Vector<Value>,
    gsh: Vector<u8>,
    goff: Vector<u64>,
    gcond: u16,
    // Rotation: the header's values the body uses (`hvals`), and per header parameter, instruction and
    // flag its index there (NONE: not used); the body's parameters' first new number and old range; the
    // header copy's parameters and instructions.
    hvals: Vector<Value>,
    hp: Vector<u32>,
    hi: Vector<u32>,
    hf: Vector<u32>,
    bnew: u32,
    bold: u32,
    blen: u32,
    cps: u32,
    cis: u32,
    // Vectorization (`vplan`): per instruction of the loop's body its kind (VK_*, 0: none); the counter
    // parameter, the bound, whether the test is signed; the reductions' parameters, update
    // instructions and operations; the accesses (instructions); the range pairs to check; the lane
    // bytes and lanes. The copy's values (`vmap`, per interleaved copy and body instruction), the
    // splats of the values the lanes read from outside the loop (`vinv`, `vspl`).
    vk: Vector<u8>,
    viv: Value,
    vn: Value,
    vsigned: bool,
    vred: Vector<Value>,
    vrup: Vector<u32>,
    // Per reduction, 0 for an arithmetic one; for a min or max one the condition under which a lane value
    // `x` replaces the accumulator `m` (`x < m` for a min, `x > m` for a max: signed, unsigned or ordered).
    vrel: Vector<u16>,
    // Per reduction, whether it keeps its order (a float one the build does not reassociate): one scalar
    // accumulator that the update takes each lane of each copy into in turn (`vextract`).
    vord: Vector<bool>,
    // Per reduction, whether it is a float min or max with signed zeros: the lanes keep their own extreme,
    // and a result of zero (whose sign the order of equal values decides) runs the loop again from its
    // start, in order. Only for a loop that stores nothing.
    vzr: Vector<bool>,
    vnv: u32, // the vector copies a vector loop interleaves (`Budgets.vector`)
    vne: bool, // the counted test is `i != n` (`counted_by`)
    // The counter counts down by 1 while it is not 0 (`counted_by`): a vector iteration runs the counter's
    // next `k` values, its lanes in the order of their elements (the reverse of the iterations').
    vrev: bool,
    // The body leaves the loop early too (`counted_by`): its branch's back edge `vback`, which runs while
    // condition `vxc` is `vxs` (true or false). A vector iteration whose lanes would leave hands its
    // iterations to the loop, which leaves at the right one.
    vexit: bool,
    vqk: u32, // the counter's step (a power of 2): each access steps by its scale times it
    // The loop maps elements (no reduction, no early exit, no store through a base it loads through):
    // its last vector iteration runs at `n - k` (the tail block past the new preheader), over iterations
    // an earlier one ran too, and leaves the loop nothing.
    vtail: bool,
    vback: u32,
    vxc: Value,
    vxs: bool,
    gq: u32, // `checks` of a test `i != n`: the counter's index among the header's parameters, else NONE
    grev: bool, // `checks` of a counter down by 1 while not 0 (`gq` its index): each check of `i - 1` needs `i0 <= len`
    vacc: Vector<u32>,
    vca: Vector<u32>,
    vcb: Vector<u32>,
    vsz: u32,
    vlanes: u32,
    vone: bool, // the plan runs scalar copies (a lane per copy)
    // `SC_VEC_REPORT=1` (a debugging aid): why the last plan failed (`no`), and per loop `run` left
    // scalar, its header's location (later transforms renumber the instructions) and that reason.
    report: bool,
    why: str<'static>,
    why_op: u8,
    pub(package) rejected: Vector<(Loc, String)>,
    /// A plan made vectors wider than a register (`plan_lanes`): `lir::opt` splits them (`lir::wide`).
    pub(package) wide: bool,
    vbytes: u32, // the bytes of the vectors (`run`'s `vec`)
    vstrided: bool, // a vector load reads every 2nd or 4th element: the loop runs the last iteration
    vgroups: bool, // stores write every 2nd or 4th element, each group of them every element (`store_groups`)
    vind: Vector<u32>, // the truncations of the counter the plan reads as lanes (`vclass`)
    vqc: Vector<Value>, // scalar copies: each copy's counter value
    vmax: u32, // the bytes of the widest vector of the target (`run`); `vbytes` the plan's
    vmin: u32, // the narrowest lane's bytes; `vsz` the widest's (at most twice as wide: `lane_size`)
    /// How the target converts vectors and shifts their lanes (`Package.vops`): with VOPS_SOME or
    /// VOPS_ALL a plan may mix lane widths and shift.
    pub(package) vops: u8,
    vgat: Vector<u32>, // the gathered loads and scattered stores (`vgather`)
    vmap: Vector<Value>,
    vinv: Vector<Value>,
    vspl: Vector<Value>,
    // If-conversion (`linearize`): the body's sizes before it (instructions, parameters, pool, blocks), the
    // branch's block and the latch; the loop's blocks before, the header's edge into the branch's block,
    // and per new instruction its original (`lorig`, for the alias classes).
    lsave: [u32; 6],
    // `linearize_exit`: the instructions of the new block before the exit test's block ends (NONE: no
    // such block), and whether the rest does what the scalar loop may not do past the exit (a store, a
    // load of any element), so that the loop keeps its own body for the scalar iterations.
    lsplit: u32,
    lkeep: bool,
    lold: Vector<u32>,
    ledge: u32,
    // `linearize`'s stores of a side: each store, the branch's condition, and whether it stores when the
    // condition holds. The vector loop stores the lanes the condition picks alone (`store_masked_ptr`).
    lcs: Vector<u32>,
    lcc: Vector<Value>,
    lcw: Vector<bool>,
    lorig: Vector<u32>,
    // Final values (`final_values`): the header; its counted test (the tested value, the counter, the
    // bound, the step's size and direction, whether the test lets the bound through, tests inequality,
    // compares signed, the counter's bits, needs a guard that the bound is at most or at least `cf_limit`);
    // the instruction whose location the new ones take; per header parameter its start and back edge
    // values and facts (`cf_hp`); per instruction its facts (`cf_st`, `cf_fv`) and its linear form for the
    // parameter at hand (`cf_lst`, `cf_lco`, `cf_lre`); the instructions copied in order (`cf_order`, per
    // instruction its place `cf_idx`), the header parameters they read (`cf_need`), and per iteration the
    // copies' values (`cf_val`) and the parameters' (`cf_pv`); per value the loop leaves with, whether its
    // closed form replaces it (`cf_poly`). `cf_bits` is a bit count's exit (CB_*), CB_NONE for a counter.
    cf_h: u32,
    cf_bits: u8,
    cf_x: Value,
    cf_q: Value,
    cf_bound: Value,
    cf_c: u64,
    cf_up: bool,
    cf_ns: bool,
    cf_ne: bool,
    cf_signed: bool,
    cf_w: u32,
    cf_guard: bool,
    cf_limit: u64,
    cf_at: u32,
    cf_init: Vector<Value>,
    cf_next: Vector<Value>,
    cf_hp: Vector<Poly>,
    cf_st: Vector<u8>,
    cf_fv: Vector<Poly>,
    cf_lst: Vector<u8>,
    cf_lco: Vector<i64>,
    cf_lre: Vector<Poly>,
    cf_order: Vector<u32>,
    cf_idx: Vector<u32>,
    cf_need: Vector<bool>,
    cf_poly: Vector<bool>,
    cf_leave: Vector<Value>, // the values the loop leaves with: the exit edge's arguments, then `lout`
    cf_val: Vector<Value>,
    cf_pv: Vector<Value>,
    // Unroll and jam (`jam_factor`): the outer header, its preheader, the inner header and body; the inner
    // counter; the chains of blocks before and after the inner loop (`jblk`, the first `jna` before); per
    // copy the outer counter's value (`jq`) and the values of the chain before (`jcopy`); the inner
    // loop's back edge arguments (`jargs`).
    jb: [u32; 4],
    jiv: Value,
    jblk: Vector<u32>,
    jna: u32,
    jq: Vector<Value>,
    jcopy: Vector<Value>,
    jargs: Vector<Value>,
}

/// The optimizer's alias classes (`lir::opt::Opt::classes`) for the loop transforms: per instruction its
/// access's class (`acc`, CL_MANY for none) and object (`obj`, NONE for an unknown one), the scope classes
/// it belongs to (`member`, empty when the body has no scope), the scope classes (`scoped`, bits), and
/// per class its roots' block (`root`).
pub(package) struct Classes<'a> {
    pub(package) acc: Slice<'a, u8>,
    pub(package) obj: Slice<'a, u32>,
    pub(package) member: Slice<'a, u64>,
    pub(package) scoped: u64,
    pub(package) root: Slice<'a, u32>,
}

extend Classes as Copy {}

/// `Classes.obj`: a data symbol the package defines (its number), a slot (OBJ_SLOT | its number), a slot
/// no pointer but its accesses' addresses reaches (OBJ_PRIVATE | its number, `lir::opt`'s `privates`).
/// Two accesses of different objects touch different bytes when neither object is unknown, or one is a
/// private slot.
pub(package) const OBJ_SLOT: u32 = 0x40000000;
pub(package) const OBJ_PRIVATE: u32 = 0x80000000;

/// The instructions a loop transform's copies may take (0: none): full unrolling (all its copies),
/// partial unrolling (the unrolled loop's copies of the body), versioning on bounds checks and unswitching
/// (the loop itself), rotation (the header's copy), final values (the copies of the iterations they
/// take); the vectors a vectorized loop interleaves (0: no vectorization).
pub(package) struct Budgets {
    pub(package) peel: u32,
    pub(package) partial: u32,
    pub(package) version: u32,
    pub(package) unswitch: u32,
    pub(package) rotate: u32,
    pub(package) vector: u32,
    pub(package) fin: u32,
}

extend Budgets as Copy {}

extend LoopOpt {
    pub(package) fn new() LoopOpt {
        return LoopOpt {
            owner: Vector::<u32>::new(),
            powner: Vector::<u32>::new(),
            inl: Vector::<bool>::new(),
            lblocks: Vector::<u32>::new(),
            imap: Vector::<u32>::new(),
            pmap: Vector::<u32>::new(),
            bmap: Vector::<u32>::new(),
            uses: Vector::<Value>::new(),
            edges: Vector::<u32>::new(),
            args: Vector::<Value>::new(),
            lout: Vector::<Value>::new(),
            tgts: Vector::<u32>::new(),
            lbase: Vector::<u32>::new(),
            tgt_of: Vector::<u32>::new(),
            tused: Vector::<bool>::new(),
            proxy: Vector::<u32>::new(),
            latch: NONE,
            ctr: VNONE,
            fixed: Vector::<bool>::new(),
            fixes: Vector::<u32>::new(),
            fside: Vector::<u8>::new(),
            gx: Vector::<Value>::new(),
            gsh: Vector::<u8>::new(),
            goff: Vector::<u64>::new(),
            gy: Vector::<Value>::new(),
            gcond: 0,
            hvals: Vector::<Value>::new(),
            hp: Vector::<u32>::new(),
            hi: Vector::<u32>::new(),
            hf: Vector::<u32>::new(),
            bnew: 0,
            bold: 0,
            blen: 0,
            cps: 0,
            cis: 0,
            vk: Vector::<u8>::new(),
            viv: VNONE,
            vn: VNONE,
            vsigned: false,
            vred: Vector::<Value>::new(),
            vrup: Vector::<u32>::new(),
            vrel: Vector::<u16>::new(),
            vord: Vector::<bool>::new(),
            vzr: Vector::<bool>::new(),
            vnv: 1,
            vne: false,
            vrev: false,
            vexit: false,
            vqk: 1,
            vtail: false,
            vback: 0,
            vxc: VNONE,
            vxs: true,
            gq: NONE,
            grev: false,
            vacc: Vector::<u32>::new(),
            vca: Vector::<u32>::new(),
            vcb: Vector::<u32>::new(),
            vsz: 0,
            vlanes: 0,
            vone: false,
            report: stdlib::env_is("SC_VEC_REPORT", "1"),
            why: "",
            why_op: 0,
            rejected: Vector::<(Loc, String)>::new(),
            wide: false,
            vbytes: VBYTES,
            vstrided: false,
            vgroups: false,
            vind: Vector::<u32>::new(),
            vqc: Vector::<Value>::new(),
            vmax: 0,
            vmin: 0,
            vops: 0,
            vgat: Vector::<u32>::new(),
            vmap: Vector::<Value>::new(),
            vinv: Vector::<Value>::new(),
            vspl: Vector::<Value>::new(),
            lsave: [0, 0, 0, 0, 0, 0],
            lsplit: NONE,
            lkeep: false,
            lold: Vector::<u32>::new(),
            lcs: Vector::<u32>::new(),
            lcc: Vector::<Value>::new(),
            lcw: Vector::<bool>::new(),
            ledge: NONE,
            lorig: Vector::<u32>::new(),
            cf_h: NONE,
            cf_x: VNONE,
            cf_q: VNONE,
            cf_bound: VNONE,
            cf_c: 0,
            cf_up: false,
            cf_ns: false,
            cf_ne: false,
            cf_bits: CB_NONE,
            cf_signed: false,
            cf_w: 0,
            cf_guard: false,
            cf_limit: 0,
            cf_at: 0,
            cf_init: Vector::<Value>::new(),
            cf_next: Vector::<Value>::new(),
            cf_hp: Vector::<Poly>::new(),
            cf_st: Vector::<u8>::new(),
            cf_fv: Vector::<Poly>::new(),
            cf_lst: Vector::<u8>::new(),
            cf_lco: Vector::<i64>::new(),
            cf_lre: Vector::<Poly>::new(),
            cf_order: Vector::<u32>::new(),
            cf_idx: Vector::<u32>::new(),
            cf_need: Vector::<bool>::new(),
            cf_poly: Vector::<bool>::new(),
            cf_leave: Vector::<Value>::new(),
            cf_val: Vector::<Value>::new(),
            cf_pv: Vector::<Value>::new(),
            jb: [0, 0, 0, 0],
            jiv: VNONE,
            jblk: Vector::<u32>::new(),
            jna: 0,
            jq: Vector::<Value>::new(),
            jcopy: Vector::<Value>::new(),
            jargs: Vector::<Value>::new(),
        };
    }

    /// Transform the innermost loops of `b` within budgets `bu` (`inner`: per block its innermost loop's
    /// header, NONE outside loops; `lparent`: per header the header of the loop around it; `preh`: per
    /// header its preheader, NONE without one; `dpre` and `dpost`: per block its preorder and postorder
    /// numbers in the dominator tree); pointers are `ptr` bytes, the float rewrites `fmath` allows
    /// (`FM_*`), and `vec` the bytes of the widest vector the target holds in a register (0: none). A loop
    /// goes when its final values have a closed form, else peels when its trip count is known, else
    /// vectorizes, else unrolls and jams the loop around it, else unrolls partially, else versions on its
    /// bounds checks, else unswitches. Whether any changed.
    pub(package) fn run(
        self: &mut Self,
        b: &mut Body,
        ptr: u32,
        fmath: u8,
        vec: u32,
        bu: Budgets,
        inner: []u32,
        lparent: []u32,
        preh: []u32,
        dpre: []u32,
        dpost: []u32,
        cl: Classes,
    ) bool {
        let cand = self.candidates(b, inner, lparent, preh);
        let mut any = false;
        self.vbytes = vec;
        self.vmax = vec;
        self.vnv = bu.vector;
        if bu.vector != 0 {
            self.rejected.truncate(0);
        }
        for c in 0..cand.len() {
            let h = cand[c];
            let p = preh[h as usize];
            let size = self.shape(b, inner, h);
            if size == 0 {
                continue;
            }
            if bu.fin != 0 && self.final_values(b, ptr, h, p, size, bu.fin, dpre, dpost) {
                any = true;
                continue;
            }
            let u = self.latch;
            if size <= bu.peel {
                // The counted exit: a branch of the header or the latch. The last copy of a loop that
                // exits from its header runs the header's test alone, which folds.
                let mut n = self.trip(b, ptr, h, p, u, h);
                let mut last: u32 = 1;
                if n == 0 && u != h {
                    n = self.trip(b, ptr, h, p, u, u);
                    last = 0;
                }
                if n != 0 && (n - last) * self.residual(b) + last <= bu.peel {
                    if self.close(b, h, dpre, dpost) {
                        self.peel(b, h, p, n);
                        any = true;
                    }
                    continue;
                }
            }
            if bu.vector != 0 && vec >= VBYTES && self.vplan(b, ptr, fmath, h, p, u, cl, false) {
                self.vectorize(b, h, p, u, bu.vector);
                any = true;
                continue;
            }
            if bu.vector != 0 && vec >= VBYTES && self.lblocks.len() > 2 {
                // A body with a branch: vectorized as one block of selects, else as it was.
                let nb = self.linearize(b, h, u);
                if nb != NONE {
                    if self.vplan(b, ptr, fmath, h, p, nb, cl, false) {
                        if self.lcs.len() == 0 && !self.lkeep {
                            self.commit_linear(b, u);
                            self.vectorize(b, h, p, nb, bu.vector);
                            self.lsplit = NONE;
                        } else {
                            // The vectors store a side's lanes alone; the loop keeps its branch for the
                            // rest, the new block left unreached.
                            let e = self.lsave[4];
                            let ein = self.ledge;
                            self.lsave = [0, 0, 0, 0, 0, 0];
                            self.vectorize(b, h, p, nb, bu.vector);
                            self.lcs.truncate(0);
                            self.lkeep = false;
                            self.lsplit = NONE;
                            b.pool[ein as usize] = e;
                            let nbk = b.blocks[nb as usize];
                            b.insts[(nbk.start + nbk.len - 1) as usize] = Inst {
                                op: O_UNREACHABLE,
                                ty: T_NONE,
                                aux: 0,
                                a: VNONE,
                                b: VNONE,
                                c: VNONE,
                            };
                        }
                        any = true;
                        continue;
                    }
                    self.unlinearize(b);
                }
            }
            if self.report && bu.vector != 0 && vec >= VBYTES && (b.blocks[h as usize].flags & BLOCK_NOVEC) == 0 {
                let mut s = String::from_str(self.why);
                if self.why_op != 0 {
                    s.format_into(" (`{}`)", op_info(self.why_op).name);
                }
                self.rejected.push((b.lines[b.locs[b.blocks[h as usize].start as usize] as usize], s));
            }
            if bu.vector > 1 && u != h && b.blocks[u as usize].len <= ILV_SIZE && self.vplan(
                b,
                ptr,
                fmath,
                h,
                p,
                u,
                cl,
                true,
            ) {
                self.vectorize(b, h, p, u, bu.vector);
                any = true;
                continue;
            }
            if bu.vector != 0 && bu.partial != 0 && vec >= VBYTES {
                let k = self.jam_factor(b, inner, lparent, preh, h, u, cl, 2 * bu.partial);
                if k != 0 {
                    self.jam(b, k);
                    any = true;
                    continue;
                }
                // The inner loop's tables again.
                let _ = self.shape(b, inner, h);
            }
            if bu.partial != 0 && self.counted(b, h, u) {
                let k = self.unroll_factor(b, h, u, bu.partial);
                if k != 0 {
                    self.unroll(b, h, p, u, k);
                    any = true;
                    continue;
                }
            }
            if size <= bu.version && self.checks(b, ptr, h, p, u) {
                if self.close(b, h, dpre, dpost) {
                    self.version(b, h, p, VNONE);
                    any = true;
                }
                continue;
            }
            if size <= bu.unswitch {
                let g = self.invariant_branch(b);
                if g != VNONE && self.close(b, h, dpre, dpost) {
                    self.version(b, h, p, g);
                    any = true;
                }
            }
        }
        return any;
    }

    /// Rotate the innermost loops of `b` whose header holds at most `max` instructions before its branch
    /// (the tables as `run` takes them). Whether any changed.
    pub(package) fn rotate(
        self: &mut Self,
        b: &mut Body,
        max: u32,
        inner: []u32,
        lparent: []u32,
        preh: []u32,
        dpre: []u32,
        dpost: []u32,
    ) bool {
        let cand = self.candidates(b, inner, lparent, preh);
        let mut any = false;
        for c in 0..cand.len() {
            let h = cand[c];
            if self.shape(b, inner, h) == 0 || self.latch == h {
                continue;
            }
            let body = self.rotatable(b, h, max);
            if body != NONE && self.close(b, h, dpre, dpost) {
                self.rotate_loop(b, h, body);
                any = true;
            }
        }
        return any;
    }

    // The tables `run` and `rotate` share set for `b`; the headers of its innermost loops with a
    // preheader.
    fn candidates(self: &mut Self, b: &Body, inner: []u32, lparent: []u32, preh: []u32) Vector<u32> {
        let nb = b.blocks.len();
        self.proxy.truncate(0);
        for k in 0..nb {
            self.proxy.push(k as u32);
        }
        fill(&mut self.owner, b.insts.len(), 0);
        fill(&mut self.powner, b.params.len(), 0);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.owner[i as usize] = k as u32;
            }
            for q in 0..bk.param_len as u32 {
                self.powner[(bk.param_start + q) as usize] = k as u32;
            }
        }
        // A header with a loop inside it is not innermost.
        fill(&mut self.inl, nb, false);
        for k in 0..nb {
            if lparent[k] != NONE {
                self.inl[lparent[k] as usize] = true;
            }
        }
        let mut cand = Vector::<u32>::new();
        for h in 0..nb {
            if inner[h] == h as u32 && !self.inl[h] && preh[h] != NONE {
                cand.push(h as u32);
            }
        }
        return cand;
    }

    // ---- Final values ----

    // Replace loop `h` (preheader `p`, blocks `lblocks`, `size` instructions) by the values it leaves with
    // (the module comment), when no instruction of it has an effect or traps, it leaves only by a counted
    // exit, each value it leaves with is a polynomial of the iteration, and the copies of the iterations
    // take at most `budget` instructions. A loop with effects stays, its exit edge entering a block that
    // computes the polynomial values it leaves with (the others pass through), when it leaves only by the
    // counted exit (or never comes back: a return, a panic, a trap) and needs no guard. Whether it did.
    fn final_values(
        self: &mut Self,
        b: &mut Body,
        ptr: u32,
        h: u32,
        p: u32,
        size: u32,
        budget: u32,
        dpre: []u32,
        dpost: []u32,
    ) bool {
        if size > CF_SIZE || term(b, p).op != O_JMP || b.edge_target(term(b, p).a) != h {
            return false;
        }
        let mut eb = NONE;
        let mut pure = true;
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                pure = pure && cf_pure(b, b.insts[i as usize]);
            }
            let t = term(b, k);
            if t.op != O_JMP && t.op != O_BR && t.op != O_SWITCH {
                if t.op != O_PANIC && t.op != O_UNREACHABLE && t.op != O_RET {
                    return false;
                }
                pure = false;
            }
            b.succ_edges(t, &mut self.edges);
            for e in 0..self.edges.len() {
                let x = b.edge_target(self.edges[e]);
                if self.inl[x as usize] {
                    continue;
                }
                // A failure path (a bounds check's panic) never comes back.
                let op = term(b, x).op;
                if op == O_PANIC || op == O_UNREACHABLE {
                    pure = false;
                    continue;
                }
                if eb != NONE {
                    return false;
                }
                eb = k;
            }
        }
        // Every test before `close` changes the body: a failed one leaves it as it was.
        if eb != h && eb != self.latch || !self.cf_test(b, ptr, h, p, eb) || !pure && self.cf_guard || !self.close_plan(
            b,
            h,
            dpre,
            dpost,
        ) {
            return false;
        }
        let t0 = term(b, eb);
        let out0 = if self.inl[b.edge_target(t0.b) as usize] {
            t0.c
        } else {
            t0.b
        };
        // The exit edge's arguments once `close` lands it: its own, then `lout` when its target lands them.
        self.cf_leave.truncate(0);
        for q in 0..b.edge_nargs(out0) {
            self.cf_leave.push(b.edge_arg(out0, q));
        }
        if self.lout.len() != 0 && self.tused[b.edge_target(out0) as usize] {
            for q in 0..self.lout.len() {
                self.cf_leave.push(self.lout[q]);
            }
        }
        self.cf_resolve(b, ptr);
        // The values that leave as polynomials in their types' bits, of degrees up to CF_DEG (`cf_poly`):
        // all of them when the loop goes, at least one when it stays.
        let na = self.cf_leave.len() as u32;
        fill(&mut self.cf_poly, na as usize, false);
        let mut d: u32 = 0;
        let mut any = false;
        // A loop that stays computes its counter for its test: the counter's values leave as they are,
        // unless the start and the bound are constants (the values are).
        let qi = ((self.cf_q & ~VPARAM) - b.blocks[h as usize].param_start) as usize;
        let qn = self.cf_next[qi];
        let known = is_const(b, self.cf_init[qi]) && (self.cf_bound == VNONE || is_const(b, self.cf_bound));
        for q in 0..na {
            let v = self.cf_leave[q as usize];
            if !pure && !known && (v == self.cf_q || v == self.cf_x || v == qn) {
                continue;
            }
            if self.defined_in(v) {
                let f = self.fact(b, ptr, v);
                let w = type_bits(value_type(b, v), ptr);
                if f.st != PS_YES || !f.rng && f.m < w || f.deg >= 2 && w.max(self.cf_w) + factorial_twos(f.deg) > 128 {
                    if pure {
                        return false;
                    }
                    continue;
                }
                self.cf_poly[q as usize] = true;
                any = true;
                d = d.max(f.deg);
            }
        }
        if !pure && !any {
            return false;
        }
        // The instructions the values and the counter's test read, in an order each one's operands of
        // the same iteration come first; the header parameters they read, and those parameters' back
        // edge values.
        fill(&mut self.cf_idx, b.insts.len(), NONE);
        fill(&mut self.cf_need, self.cf_init.len(), false);
        self.cf_order.truncate(0);
        if !self.cf_visit(b, self.cf_x) {
            return false;
        }
        for q in 0..na {
            if self.cf_poly[q as usize] && !self.cf_visit(b, self.cf_leave[q as usize]) {
                return false;
            }
        }
        if self.cf_order.len() as u32 * (d + 1) > budget {
            return false;
        }
        self.close_apply(b);
        let t = term(b, eb);
        let out = if self.inl[b.edge_target(t.b) as usize] {
            t.c
        } else {
            t.b
        };
        // The block that computes the values (the iterations 0 to `d`, the trip count, the values), with a
        // parameter per value that passes through.
        let xb = b.blocks.len() as u32;
        let start = b.insts.len() as u32;
        let ps = b.params.len() as u32;
        let mut np2: u16 = 0;
        for q in 0..na {
            let v = b.edge_arg(out, q);
            if self.defined_in(v) && !self.cf_poly[q as usize] {
                b.params.push(value_type(b, v));
                np2 += 1;
            }
        }
        let at = b.blocks[eb as usize].start + b.blocks[eb as usize].len - 1;
        self.cf_at = at;
        let n = self.cf_order.len();
        let np = self.cf_init.len();
        fill(&mut self.cf_val, n * (d as usize + 1), VNONE);
        fill(&mut self.cf_pv, np * (d as usize + 1), VNONE);
        for k in 0..d + 1 {
            for j in 0..np {
                if self.cf_need[j] {
                    self.cf_pv[k as usize * np + j] = if k == 0 {
                        self.cf_init[j]
                    } else {
                        self.cf_of(b, self.cf_next[j], k - 1)
                    };
                }
            }
            for o in 0..n {
                let i = self.cf_order[o];
                let mut c = b.insts[i as usize];
                let f = op_info(c.op).form;
                if lv::operand_a(f) {
                    c.a = self.cf_of(b, c.a, k);
                }
                if lv::operand_b(f) && c.b != VNONE {
                    c.b = self.cf_of(b, c.b, k);
                }
                if lv::operand_c(f) {
                    c.c = self.cf_of(b, c.c, k);
                }
                self.cf_val[k as usize * n + o] = cf_put(b, c, i);
            }
        }
        let x0 = self.cf_of(b, self.cf_x, 0);
        let count = self.cf_count(b, x0);
        self.args.truncate(0);
        let mut kept: u32 = 0;
        for q in 0..na {
            let v = b.edge_arg(out, q);
            let r = if self.cf_poly[q as usize] {
                self.cf_value(b, ptr, v, count)
            } else if self.defined_in(v) {
                kept += 1;
                VPARAM | ps + kept - 1
            } else {
                v
            };
            self.args.push(r);
        }
        let target = b.edge_target(out);
        let e = b.edge(target, &self.args);
        let _ = cf_put(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 }, at);
        let pb = b.blocks[p as usize];
        b.blocks.push(
            Block { start: start, len: b.insts.len() as u32 - start, param_start: ps, param_len: np2, flags: pb.flags },
        );
        self.inl.push(false);
        while self.powner.len() < b.params.len() {
            self.powner.push(xb);
        }
        if !pure {
            // The exit edge enters the block with the values that pass through.
            self.proxy.push(target);
            self.args.truncate(0);
            for q in 0..na {
                let v = b.edge_arg(out, q);
                if self.defined_in(v) && !self.cf_poly[q as usize] {
                    self.args.push(v);
                }
            }
            let ex = b.edge(xb, &self.args);
            let ti = (b.blocks[eb as usize].start + b.blocks[eb as usize].len - 1) as usize;
            let mut tt = b.insts[ti];
            if tt.b == out {
                tt.b = ex;
            } else {
                tt.c = ex;
            }
            b.insts[ti] = tt;
            while self.owner.len() < b.insts.len() {
                self.owner.push(xb);
            }
            return true;
        }
        self.proxy.push(p);
        // The preheader enters the block, or a guard that enters it when the bound lets the counter step
        // without wrapping and the loop otherwise.
        let mut to = xb;
        if self.cf_guard {
            to = b.blocks.len() as u32;
            let gs = b.insts.len() as u32;
            let ty = value_type(b, self.cf_bound);
            let lim = cf_put(b, iconst_of(ty, self.cf_limit), at);
            let cond = if self.cf_up {
                pick_c(self.cf_signed, C_SLE, C_ULE)
            } else {
                pick_c(self.cf_signed, C_SGE, C_UGE)
            };
            let g = cf_put(b, Inst { op: O_ICMP, ty: T_I8, aux: cond, a: self.cf_bound, b: lim, c: VNONE }, at);
            let ex = b.edge(xb, []);
            let _ = cf_put(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: g, b: ex, c: term(b, p).a }, at);
            b.blocks.push(
                Block {
                    start: gs,
                    len: b.insts.len() as u32 - gs,
                    param_start: b.params.len() as u32,
                    param_len: 0,
                    flags: pb.flags,
                },
            );
            self.inl.push(false);
            self.proxy.push(p);
        }
        let pe = b.edge(to, []);
        b.insts[(pb.start + pb.len - 1) as usize] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: pe, b: 0, c: 0 };
        while self.owner.len() < b.insts.len() {
            self.owner.push(xb);
        }
        return true;
    }

    // Whether block `eb`'s branch leaves loop `h` (preheader `p`) by a counted test: a comparison of a
    // value the loop does not define (`cf_bound`) with header parameter `q` plus an invariant, `q` stepping
    // by a constant, the loop running while the counter moves towards the bound (or differs from it, by
    // steps of 1). Sets the `cf_*` fields of the test, `cf_init` and `cf_next`.
    fn cf_test(self: &mut Self, b: &Body, ptr: u32, h: u32, p: u32, eb: u32) bool {
        let hb = b.blocks[h as usize];
        let pe = term(b, p).a;
        b.succ_edges(term(b, self.latch), &mut self.edges);
        let mut be = NONE;
        for j in 0..self.edges.len() {
            if b.edge_target(self.edges[j]) == h {
                be = self.edges[j];
            }
        }
        self.cf_h = h;
        self.cf_init.truncate(0);
        self.cf_next.truncate(0);
        for j in 0..hb.param_len as u32 {
            self.cf_init.push(b.edge_arg(pe, j));
            self.cf_next.push(b.edge_arg(be, j));
        }
        let t = term(b, eb);
        if (t.a & (VPARAM | VFLAG)) != 0 || !self.defined_in(t.a) || b.insts[t.a as usize].op != O_ICMP {
            return false;
        }
        let ci = b.insts[t.a as usize];
        let (x, bound, pred) = if self.defined_in(ci.a) && !self.defined_in(ci.b) {
            (ci.a, ci.b, ci.aux)
        } else if self.defined_in(ci.b) && !self.defined_in(ci.a) {
            (ci.b, ci.a, mirror(ci.aux))
        } else {
            return false;
        };
        let stay = if self.inl[b.edge_target(t.b) as usize] {
            pred
        } else {
            opposite(pred)
        };
        self.cf_bits = CB_NONE;
        if stay == C_NE && is_const(b, bound) && raw_const(b, bound) == 0 && self.bit_count(b, ptr, x) {
            return true;
        }
        // The counter: `x` itself or `x` less an invariant.
        let mut q = x;
        if (x & VPARAM) == 0 {
            let xi = b.insts[x as usize];
            q = if xi.op == O_ADD && self.header_param(xi.a) && !self.defined_in(xi.b) || xi.op == O_SUB && self.header_param(
                xi.a,
            ) && !self.defined_in(xi.b) {
                xi.a
            } else if xi.op == O_ADD && self.header_param(xi.b) && !self.defined_in(xi.a) {
                xi.b
            } else {
                VNONE
            };
        }
        if !self.header_param(q) {
            return false;
        }
        let qi = (q & ~VPARAM) - hb.param_start;
        let ty = b.params[(q & ~VPARAM) as usize];
        if !is_int(ty) || ty == T_I128 {
            return false;
        }
        let nv = self.cf_next[qi as usize];
        if (nv & (VPARAM | VFLAG)) != 0 || nv == VNONE {
            return false;
        }
        let si = b.insts[nv as usize];
        let w = type_bits(ty, ptr);
        let mut step: u64 = 0;
        if si.op == O_ADD && si.a == q && is_const(b, si.b) {
            step = raw_const(b, si.b);
        } else if si.op == O_ADD && si.b == q && is_const(b, si.a) {
            step = raw_const(b, si.a);
        } else if si.op == O_SUB && si.a == q && is_const(b, si.b) {
            step = 0u64.wrapping_sub(raw_const(b, si.b));
        } else {
            return false;
        }
        let s = sext_of(step, w);
        if s == 0 || s == smin(w) {
            return false;
        }
        let up = s > 0;
        let c = if up {
            s
        } else {
            -s
        };
        let signed = stay == C_SLT || stay == C_SLE || stay == C_SGT || stay == C_SGE;
        let ns = stay == C_SLE || stay == C_ULE || stay == C_SGE || stay == C_UGE;
        let ne = stay == C_NE;
        if ne && c != 1 || !ne && up != (stay == C_SLT || stay == C_SLE || stay == C_ULT || stay == C_ULE) || stay == C_EQ {
            return false;
        }
        self.cf_x = x;
        self.cf_q = q;
        self.cf_bound = bound;
        self.cf_c = c as u64;
        self.cf_up = up;
        self.cf_ns = ns;
        self.cf_ne = ne;
        self.cf_signed = signed;
        self.cf_w = w;
        self.cf_guard = false;
        if ne {
            return true;
        }
        // The counter steps past the last value the test lets through without wrapping when the bound is at
        // most `limit` (counting up) or at least it (counting down).
        let ns1: u64 = if ns {
            1
        } else {
            0
        };
        let lim = if up {
            type_max(w, signed).wrapping_sub(c as u64).wrapping_add(1).wrapping_sub(ns1)
        } else {
            type_min(w, signed).wrapping_add(c as u64).wrapping_sub(1).wrapping_add(ns1)
        };
        self.cf_limit = lim & mask_of(w);
        let cond = if up {
            pick_c(signed, C_SLE, C_ULE)
        } else {
            pick_c(signed, C_SGE, C_UGE)
        };
        if is_const(b, bound) {
            return le::icmp(cond, ty, ptr, raw_const(b, bound), self.cf_limit);
        }
        // A bound whose bits keep it at most the limit (`n & -4` for a step of 4, say).
        if up && top_of(b, bound, w, 4) <= self.cf_limit && (!signed || self.cf_limit <= type_max(w, true)) {
            return true;
        }
        self.cf_guard = self.cf_limit != (if up {
            type_max(w, signed)
        } else {
            type_min(w, signed)
        } & mask_of(w));
        return true;
    }

    // Whether the loop runs while `x` is not 0, `x` a header parameter `q` (or its next value) that steps by
    // `q & (q - 1)` (it runs popcount(x) more times: CB_POP) or `q >> 1` (bit length: CB_LEN), LLVM's loop
    // idiom recognition of bit counts. Sets the test's `cf_*` fields.
    fn bit_count(self: &mut Self, b: &Body, ptr: u32, x: Value) bool {
        let hb = b.blocks[self.cf_h as usize];
        let mut q = VNONE;
        for j in 0..hb.param_len as u32 {
            let pj = VPARAM | hb.param_start + j;
            if pj == x || self.cf_next[j as usize] == x {
                q = pj;
            }
        }
        if q == VNONE {
            return false;
        }
        let ty = b.params[(q & ~VPARAM) as usize];
        let nv = self.cf_next[((q & ~VPARAM) - hb.param_start) as usize];
        if !is_int(ty) || ty == T_I128 || (nv & (VPARAM | VFLAG)) != 0 || nv == VNONE || !self.defined_in(nv) {
            return false;
        }
        let s = b.insts[nv as usize];
        let mut kind = CB_NONE;
        if s.op == O_LSHR && s.a == q && is_const(b, s.b) && raw_const(b, s.b) == 1 {
            kind = CB_LEN;
        } else if s.op == O_AND && (s.a == q || s.b == q) {
            let d = if s.a == q {
                s.b
            } else {
                s.a
            };
            if (d & (VPARAM | VFLAG)) == 0 && d != VNONE && self.defined_in(d) {
                let m = b.insts[d as usize];
                let one = m.op == O_SUB && m.a == q && is_const(b, m.b) && raw_const(b, m.b) == 1;
                let all = mask_of(type_bits(ty, ptr));
                let minus = m.op == O_ADD && (m.a == q && is_const(b, m.b) && (raw_const(b, m.b) & all) == all || m.b == q && is_const(
                    b,
                    m.a,
                ) && (raw_const(b, m.a) & all) == all);
                if one || minus {
                    kind = CB_POP;
                }
            }
        }
        if kind == CB_NONE {
            return false;
        }
        self.cf_bits = kind;
        self.cf_x = x;
        self.cf_q = q;
        self.cf_bound = VNONE;
        self.cf_c = 1;
        self.cf_up = false;
        self.cf_ns = false;
        self.cf_ne = true;
        self.cf_signed = false;
        self.cf_w = type_bits(ty, ptr);
        self.cf_guard = false;
        return true;
    }

    // Whether `v` is a parameter of the loop's header.
    fn header_param(self: &Self, v: Value) bool {
        return v != VNONE && (v & VPARAM) != 0 && self.powner[(v & ~VPARAM) as usize] == self.cf_h;
    }

    // The facts of the header parameters (`cf_hp`): each one that steps by itself plus a polynomial that
    // does not read it is one degree above that polynomial; rounds until none resolves. The counter's
    // values lie between its start and the bound.
    fn cf_resolve(self: &mut Self, b: &Body, ptr: u32) {
        let np = self.cf_init.len();
        self.cf_hp.truncate(0);
        for _ in 0..np {
            self.cf_hp.push(p_of(PS_UNKNOWN));
        }
        // The facts and linear forms are read only where `cf_st` and `cf_lst` are set: they only grow.
        fill(&mut self.cf_st, b.insts.len(), 0);
        grow_poly(&mut self.cf_fv, b.insts.len());
        fill(&mut self.cf_lst, b.insts.len(), 0);
        if self.cf_lco.len() < b.insts.len() {
            self.cf_lco.resize_default(b.insts.len());
        }
        grow_poly(&mut self.cf_lre, b.insts.len());
        let hs = b.blocks[self.cf_h as usize].param_start;
        // Each round resolves at least one parameter.
        for _ in 0..np + 1 {
            let mut any = false;
            for j in 0..np {
                if self.cf_hp[j].st != PS_UNKNOWN {
                    continue;
                }
                self.cf_clear(b, true);
                let q = VPARAM | hs + j as u32;
                let w = type_bits(b.params[(hs + j as u32) as usize], ptr);
                // `q ^ k`, `k` the same on every iteration: it alternates.
                let k = self.toggle_by(b, q, self.cf_next[j]);
                if k != VNONE {
                    let fk = self.fact(b, ptr, k);
                    if fk.st == PS_UNKNOWN {
                        continue;
                    }
                    any = true;
                    self.cf_hp[j] = if fk.st == PS_YES && fk.deg == 0 {
                        p_tog(w)
                    } else {
                        p_of(PS_NO)
                    };
                    self.cf_clear(b, false);
                    continue;
                }
                let l = self.lin(b, ptr, self.cf_next[j], q);
                if l.rest.st == PS_UNKNOWN {
                    continue;
                }
                any = true;
                let mut f = p_of(PS_NO);
                if l.rest.st == PS_YES && l.coef == 1 && !l.rest.tog {
                    let zero = l.rest.rng && l.rest.lo == 0 && l.rest.hi == 0;
                    let deg = if zero {
                        0
                    } else {
                        l.rest.deg as u32 + 1
                    };
                    if deg <= CF_DEG {
                        f = Poly {
                            st: PS_YES,
                            deg: deg as u8,
                            m: (l.rest.m as u32).min(w) as u8,
                            rng: false,
                            lo: 0,
                            hi: 0,
                        };
                        if deg == 0 {
                            f.m = w as u8;
                        }
                        if q == self.cf_q && q == self.cf_x {
                            self.counter_range(b, &mut f, w);
                        }
                    }
                }
                self.cf_hp[j] = f;
                self.cf_clear(b, false);
            }
            if !any {
                break;
            }
        }
        self.cf_clear(b, false);
    }

    // The other operand `k` when `v` is `q ^ k` (an instruction of the loop), else VNONE.
    fn toggle_by(self: &Self, b: &Body, q: Value, v: Value) Value {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || !self.defined_in(v) || b.insts[v as usize].op != O_XOR {
            return VNONE;
        }
        let t = b.insts[v as usize];
        return if t.a == q && t.b != q {
            t.b
        } else if t.b == q && t.a != q {
            t.a
        } else {
            VNONE
        };
    }

    // Forget the facts of the loop's instructions (`lin`'s too when `lin` holds).
    fn cf_clear(self: &mut Self, b: &Body, lin: bool) {
        for j in 0..self.lblocks.len() {
            let bk = b.blocks[self.lblocks[j] as usize];
            for i in bk.start..bk.start + bk.len {
                self.cf_st[i as usize] = 0;
                if lin {
                    self.cf_lst[i as usize] = 0;
                }
            }
        }
    }

    // The interval of the counter's values (`f`, `w` bits) while the loop runs: from its start to the
    // last value the test lets through plus a step, the bounds its type's where they are not constants.
    fn counter_range(self: &Self, b: &Body, f: &mut Poly, w: u32) {
        let x0 = self.cf_init[((self.cf_q & ~VPARAM) - b.blocks[self.cf_h as usize].param_start) as usize];
        if self.cf_ne || !self.cf_signed && w >= 64 {
            return;
        }
        let c = self.cf_c as i64;
        let ns: i64 = if self.cf_ns {
            1
        } else {
            0
        };
        let (tmin, tmax) = if self.cf_signed {
            (smin(w), smax(w))
        } else {
            (0i64, umax(w))
        };
        let start = if is_const(b, x0) {
            int_value(raw_const(b, x0), w, self.cf_signed)
        } else if self.cf_up {
            tmin
        } else {
            tmax
        };
        let mut far = if self.cf_up {
            tmax
        } else {
            tmin
        };
        if is_const(b, self.cf_bound) {
            let bv = int_value(raw_const(b, self.cf_bound), w, self.cf_signed);
            far = if self.cf_up {
                bv + ns + c - 1
            } else {
                bv - ns - c + 1
            };
        }
        f.rng = true;
        f.lo = if self.cf_up {
            start
        } else {
            far.min(start)
        };
        f.hi = if self.cf_up {
            far.max(start)
        } else {
            start
        };
        f.m = w as u8;
    }

    // What value `v` is as a function of the iteration (`Poly`), for the header parameters' facts at hand.
    fn fact(self: &mut Self, b: &Body, ptr: u32, v: Value) Poly {
        if v == VNONE || !self.defined_in(v) {
            return const_fact(b, ptr, v);
        }
        if (v & VPARAM) != 0 {
            if !self.header_param(v) {
                return p_of(PS_NO);
            }
            return self.cf_hp[((v & ~VPARAM) - b.blocks[self.cf_h as usize].param_start) as usize];
        }
        if (v & VFLAG) != 0 {
            return p_of(PS_NO);
        }
        if self.cf_st[v as usize] != 0 {
            return self.cf_fv[v as usize];
        }
        let t = b.insts[v as usize];
        if !cf_pure(b, t) {
            return p_of(PS_NO);
        }
        let w = type_bits(t.ty, ptr);
        let f = op_info(t.op).form;
        let fa = if lv::operand_a(f) {
            self.fact(b, ptr, t.a)
        } else {
            p_inv(w)
        };
        let fb = if lv::operand_b(f) && t.b != VNONE {
            self.fact(b, ptr, t.b)
        } else {
            p_inv(w)
        };
        let fc = if lv::operand_c(f) {
            self.fact(b, ptr, t.c)
        } else {
            p_inv(w)
        };
        let mut r = p_of(PS_NO);
        if fa.tog || fb.tog || fc.tog {
            let st = p_st(p_st(fa.st, fb.st), fc.st);
            r = if st != PS_YES {
                p_of(st)
            } else {
                tog_of(tog_of(fa, fb, w), fc, w)
            };
        } else if t.op == O_SELECT && (fa.st != PS_YES || fa.deg != 0) {
            // A condition the intervals decide picks its side.
            let d = self.decide(b, ptr, t.a);
            r = if d == 1 {
                fb
            } else if d == 0 {
                fc
            } else if fa.st == PS_UNKNOWN {
                p_of(PS_UNKNOWN)
            } else {
                p_of(PS_NO)
            };
        } else {
            let st = p_st(p_st(fa.st, fb.st), fc.st);
            if st != PS_YES {
                r = p_of(st);
            } else if fa.deg == 0 && fb.deg == 0 && fc.deg == 0 {
                r = p_inv(w);
            } else if t.op == O_SELECT {
                // A condition the same on every iteration picks one side for the whole loop.
                r = either(fb, fc, w);
            } else {
                r = op_fact(b, ptr, t, fa, fb, w);
            }
        }
        self.cf_st[v as usize] = 1;
        self.cf_fv[v as usize] = r;
        return r;
    }

    // Whether condition `v` (an integer comparison) holds on every iteration (1), on none (0), or neither
    // is known (2), by its operands' intervals.
    fn decide(self: &mut Self, b: &Body, ptr: u32, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICMP {
            return 2;
        }
        let t = b.insts[v as usize];
        let x = self.fact(b, ptr, t.a);
        let y = self.fact(b, ptr, t.b);
        if x.st != PS_YES || y.st != PS_YES || !x.rng || !y.rng {
            return 2;
        }
        let w = type_bits(value_type(b, t.a), ptr);
        let sg = t.aux == C_SLT || t.aux == C_SLE || t.aux == C_SGT || t.aux == C_SGE;
        let in_s = x.lo >= smin(w) && x.hi <= smax(w) && y.lo >= smin(w) && y.hi <= smax(w);
        let in_u = x.lo >= 0 && x.hi <= umax(w) && y.lo >= 0 && y.hi <= umax(w);
        if sg && !in_s || !sg && t.aux != C_EQ && t.aux != C_NE && !in_u || !in_s && !in_u {
            return 2;
        }
        let c = t.aux;
        let lt_all = x.hi < y.lo;
        let ge_all = x.lo >= y.hi;
        let le_all = x.hi <= y.lo;
        let gt_all = x.lo > y.hi;
        let yes = c == C_SLT && lt_all || c == C_ULT && lt_all || c == C_SLE && le_all || c == C_ULE && le_all || c == C_SGT && gt_all || c == C_UGT && gt_all || c == C_SGE && ge_all || c == C_UGE && ge_all || c == C_NE && (lt_all || gt_all) || c == C_EQ && x.lo == x.hi && y.lo == y.hi && x.lo == y.lo;
        let no = (c == C_SLT || c == C_ULT) && ge_all || (c == C_SLE || c == C_ULE) && gt_all || (c == C_SGT || c == C_UGT) && le_all || (c == C_SGE || c == C_UGE) && lt_all || c == C_EQ && (lt_all || gt_all) || c == C_NE && x.lo == x.hi && y.lo == y.hi && x.lo == y.lo;
        return if yes {
            1
        } else if no {
            0
        } else {
            2
        };
    }

    // Value `v` as `coef` times header parameter `q` plus a polynomial `rest` that does not read `q`
    // (`rest.st` PS_NO when it is not one, PS_UNKNOWN when it reads a parameter not resolved yet).
    fn lin(self: &mut Self, b: &Body, ptr: u32, v: Value, q: Value) Lin {
        if v == q {
            return Lin { coef: 1, rest: p_zero(type_bits(value_type(b, v), ptr)) };
        }
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || !self.defined_in(v) {
            return Lin { coef: 0, rest: self.fact(b, ptr, v) };
        }
        if self.cf_lst[v as usize] != 0 {
            return Lin { coef: self.cf_lco[v as usize], rest: self.cf_lre[v as usize] };
        }
        let t = b.insts[v as usize];
        let w = type_bits(t.ty, ptr);
        let mut r = Lin { coef: 0, rest: p_of(PS_NO) };
        if t.op == O_ADD || t.op == O_SUB || t.op == O_MUL {
            let x = self.lin(b, ptr, t.a, q);
            let y = self.lin(b, ptr, t.b, q);
            let mut ok = true;
            let coef = if t.op == O_ADD {
                ck(x.coef.checked_add(y.coef), &mut ok)
            } else if t.op == O_SUB {
                ck(x.coef.checked_sub(y.coef), &mut ok)
            } else if x.coef == 0 && y.coef == 0 {
                0i64
            } else if x.coef == 0 && is_const(b, t.a) {
                ck(sext_of(raw_const(b, t.a), w).checked_mul(y.coef), &mut ok)
            } else if y.coef == 0 && is_const(b, t.b) {
                ck(sext_of(raw_const(b, t.b), w).checked_mul(x.coef), &mut ok)
            } else {
                ck(Option::<i64>::None, &mut ok)
            };
            if ok {
                r = Lin { coef: coef, rest: arith_fact(t.op, x.rest, y.rest, w) };
            }
        } else if t.op == O_NEG {
            let x = self.lin(b, ptr, t.a, q);
            if let Some(c) = 0i64.checked_sub(x.coef) {
                r = Lin { coef: c, rest: arith_fact(O_SUB, p_zero(w), x.rest, w) };
            }
        } else if t.op == O_SHL && shift_amount(b, t.b) < 62 && shift_amount(b, t.b) < w as u64 {
            let x = self.lin(b, ptr, t.a, q);
            let m = 1i64 << shift_amount(b, t.b) as i64;
            if let Some(c) = x.coef.checked_mul(m) {
                r = Lin { coef: c, rest: arith_fact(O_MUL, x.rest, p_const(w, m), w) };
            }
        } else if t.op == O_SEXT || t.op == O_ZEXT || t.op == O_TRUNC {
            // An extension keeps the parameter's term modulo the bits it extends, a truncation modulo its
            // own: the rest's bits bound both.
            let x = self.lin(b, ptr, t.a, q);
            if x.coef == 0 {
                r = Lin { coef: 0, rest: self.fact(b, ptr, v) };
            } else if x.rest.st != PS_YES {
                r = x;
            } else {
                let fw = type_bits(value_type(b, t.a), ptr);
                r = Lin {
                    coef: x.coef,
                    rest: Poly {
                        st: PS_YES,
                        deg: x.rest.deg,
                        m: (x.rest.m as u32).min(fw).min(w) as u8,
                        rng: false,
                        lo: 0,
                        hi: 0,
                        tog: x.rest.tog,
                    },
                };
            }
        } else if t.op == O_SELECT && self.fact(b, ptr, t.a).st == PS_YES && self.fact(b, ptr, t.a).deg == 0 {
            // Sides of one term on a condition the same on every iteration.
            let x = self.lin(b, ptr, t.b, q);
            let y = self.lin(b, ptr, t.c, q);
            if x.coef == y.coef {
                r = Lin { coef: x.coef, rest: either(x.rest, y.rest, w) };
            }
        } else if t.op == O_PTRADD {
            let x = self.lin(b, ptr, t.a, q);
            let y = if t.b == VNONE {
                Lin { coef: 0, rest: p_zero(w) }
            } else {
                self.lin(b, ptr, t.b, q)
            };
            if y.coef == 0 {
                r = Lin { coef: x.coef, rest: arith_fact(O_ADD, x.rest, scaled(y.rest, w), w) };
            }
        } else {
            r = Lin { coef: 0, rest: self.fact(b, ptr, v) };
        }
        self.cf_lst[v as usize] = 1;
        self.cf_lco[v as usize] = r.coef;
        self.cf_lre[v as usize] = r.rest;
        return r;
    }

    // Add value `v`'s instructions to the order (`cf_order`, `cf_idx`) after those it reads, and the
    // header parameters it reads to `cf_need` with their back edge values; false when it reads another
    // block's parameter of the loop or an instruction with an effect.
    fn cf_visit(self: &mut Self, b: &Body, v: Value) bool {
        if v == VNONE || !self.defined_in(v) {
            return true;
        }
        if (v & VPARAM) != 0 {
            if !self.header_param(v) {
                return false;
            }
            let j = ((v & ~VPARAM) - b.blocks[self.cf_h as usize].param_start) as usize;
            if self.cf_need[j] {
                return true;
            }
            self.cf_need[j] = true;
            return self.cf_visit(b, self.cf_next[j]);
        }
        if self.cf_idx[v as usize] != NONE {
            return true;
        }
        self.cf_idx[v as usize] = NONE - 1;
        let t = b.insts[v as usize];
        if !cf_pure(b, t) {
            return false;
        }
        let f = op_info(t.op).form;
        if lv::operand_a(f) && !self.cf_visit(b, t.a) || lv::operand_b(f) && !self.cf_visit(b, t.b) || lv::operand_c(f) && !self.cf_visit(
            b,
            t.c,
        ) {
            return false;
        }
        self.cf_idx[v as usize] = self.cf_order.len() as u32;
        self.cf_order.push(v);
        return true;
    }

    // Value `v` at iteration `k` in the block that computes the values.
    fn cf_of(self: &Self, b: &Body, v: Value, k: u32) Value {
        if v == VNONE || !self.defined_in(v) {
            return v;
        }
        if (v & VPARAM) != 0 {
            let j = (v & ~VPARAM) - b.blocks[self.cf_h as usize].param_start;
            return self.cf_pv[(k * self.cf_init.len() as u32 + j) as usize];
        }
        return self.cf_val[(k * self.cf_order.len() as u32 + self.cf_idx[v as usize]) as usize];
    }

    // The trip count, in the counter's type: the iterations whose test keeps the loop running, the
    // tested value starting at `x0` and stepping by `cf_c` towards the bound.
    fn cf_count(self: &Self, b: &mut Body, x0: Value) Value {
        let at = self.cf_at;
        let ty = value_type(b, x0);
        if self.cf_bits == CB_POP {
            return cf_put(b, Inst { op: O_POPCNT, ty: ty, aux: 0, a: x0, b: VNONE, c: VNONE }, at);
        }
        if self.cf_bits == CB_LEN {
            let z = cf_put(b, Inst { op: O_CLZ, ty: ty, aux: 0, a: x0, b: VNONE, c: VNONE }, at);
            return cf_put(b, bin(O_SUB, ty, cf_put(b, iconst_of(ty, self.cf_w), at), z), at);
        }
        let bound = self.cf_bound;
        if self.cf_ne {
            return if self.cf_up {
                cf_put(b, bin(O_SUB, ty, bound, x0), at)
            } else {
                cf_put(b, bin(O_SUB, ty, x0, bound), at)
            };
        }
        let mut far = bound;
        if self.cf_ns {
            let one = cf_put(b, iconst_of(ty, 1), at);
            far = cf_put(b, bin(pick_op(self.cf_up, O_ADD, O_SUB), ty, bound, one), at);
        }
        // A start past the bound runs no iteration; at the bound the difference is 0.
        let past = if self.cf_up {
            pick_c(self.cf_signed, pick_c(self.cf_c == 1, C_SGT, C_SGE), pick_c(self.cf_c == 1, C_UGT, C_UGE))
        } else {
            pick_c(self.cf_signed, pick_c(self.cf_c == 1, C_SLT, C_SLE), pick_c(self.cf_c == 1, C_ULT, C_ULE))
        };
        let cond = cf_put(b, Inst { op: O_ICMP, ty: T_I8, aux: past, a: x0, b: far, c: VNONE }, at);
        let mut diff = if self.cf_up {
            cf_put(b, bin(O_SUB, ty, far, x0), at)
        } else {
            cf_put(b, bin(O_SUB, ty, x0, far), at)
        };
        if self.cf_c != 1 {
            let one = cf_put(b, iconst_of(ty, 1), at);
            let c = cf_put(b, iconst_of(ty, self.cf_c), at);
            let less = cf_put(b, bin(O_SUB, ty, diff, one), at);
            let q = cf_put(b, bin(O_UDIV, ty, less, c), at);
            diff = cf_put(b, bin(O_ADD, ty, q, one), at);
        }
        let zero = cf_put(b, iconst_of(ty, 0), at);
        return cf_put(b, Inst { op: O_SELECT, ty: ty, aux: 0, a: cond, b: zero, c: diff }, at);
    }

    // Value `v` after `count` iterations: its values at iterations 0 to its degree give the coefficients of
    // its polynomial in the binomial basis (their differences), and the value is the sum of each
    // coefficient times the binomial of `count` (a pointer: its first value plus that sum of byte
    // differences).
    fn cf_value(self: &mut Self, b: &mut Body, ptr: u32, v: Value, count: Value) Value {
        let at = self.cf_at;
        let f = self.fact(b, ptr, v);
        let d = f.deg as u32;
        let s0 = self.cf_of(b, v, 0);
        if d == 0 {
            return s0;
        }
        if f.tog {
            let s1 = self.cf_of(b, v, 1);
            let ct = value_type(b, count);
            let odd = cf_put(b, bin(O_AND, ct, count, cf_put(b, iconst_of(ct, 1), at)), at);
            let c = cf_put(
                b,
                Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: odd, b: cf_put(b, iconst_of(ct, 0), at), c: VNONE },
                at,
            );
            return cf_put(b, Inst { op: O_SELECT, ty: value_type(b, v), aux: 0, a: c, b: s1, c: s0 }, at);
        }
        let vt = value_type(b, v);
        let ty = if vt == T_PTR {
            pick_op(ptr == 8, T_I64, T_I32)
        } else {
            vt
        };
        let w = type_bits(ty, ptr);
        let mut s = Vector::<Value>::new();
        for k in 0..d + 1 {
            let x = self.cf_of(b, v, k);
            s.push(
                if vt == T_PTR {
                    cf_put(b, Inst { op: O_PTRTOINT, ty: ty, aux: 0, a: x, b: VNONE, c: VNONE }, at)
                } else {
                    x
                },
            );
        }
        // The differences: after round r, s[r] is the coefficient of binomial (count, r).
        for r in 1..d + 1 {
            let mut k = d;
            while k >= r {
                s[k as usize] = cf_put(b, bin(O_SUB, ty, s[k as usize], s[k as usize - 1]), at);
                k -= 1;
            }
        }
        let cw = type_bits(value_type(b, count), ptr);
        let mut total = if vt == T_PTR {
            cf_put(b, iconst_of(ty, 0), at)
        } else {
            s[0]
        };
        // The binomials in a type of the value's or the count's bits and the shifts their factorials
        // take out, at most 128.
        let shift = factorial_twos(d);
        let wide = if w.max(cw) + shift <= 64 {
            T_I64
        } else {
            T_I128
        };
        let kw = if d >= 2 {
            cf_conv(b, count, cw, wide, ptr, at)
        } else {
            VNONE
        };
        let mut prod = kw;
        for j in 1..d + 1 {
            let mut bj = cf_conv(b, count, cw, ty, ptr, at);
            if j >= 2 {
                let less = cf_put(b, bin(O_SUB, wide, kw, cf_wide_const(b, wide, j - 1, at)), at);
                prod = cf_put(b, bin(O_MUL, wide, prod, less), at);
                let sh = cf_put(
                    b,
                    Inst {
                        op: O_LSHR,
                        ty: wide,
                        aux: SH_EXACT,
                        a: prod,
                        b: cf_wide_const(b, wide, factorial_twos(j), at),
                        c: VNONE,
                    },
                    at,
                );
                bj = cf_conv(b, sh, type_bits(wide, ptr), ty, ptr, at);
                let odd = factorial_odd(j);
                if odd != 1 {
                    let inv = cf_put(b, iconst_of(ty, inverse_of(odd)), at);
                    bj = cf_put(b, bin(O_MUL, ty, bj, inv), at);
                }
            }
            let term = cf_put(b, bin(O_MUL, ty, s[j as usize], bj), at);
            total = cf_put(b, bin(O_ADD, ty, total, term), at);
        }
        if vt == T_PTR {
            return cf_put(b, Inst { op: O_PTRADD, ty: T_PTR, aux: 1, a: s0, b: total, c: 0 }, at);
        }
        return total;
    }

    // ---- Vectorization ----

    // The plan fails for reason `why` (`report`), about an instruction of opcode `op` (0: none).
    fn no(self: &mut Self, why: str<'static>, op: u8) bool {
        self.why = why;
        self.why_op = op;
        return false;
    }

    // Whether loop `h` (preheader `p`, latch `u`, its blocks `lblocks`) vectorizes (the module comment), with
    // `one` as scalar copies: sets the plan (`vk` ..`vone`).
    fn vplan(self: &mut Self, b: &Body, ptr: u32, fmath: u8, h: u32, p: u32, u: u32, cl: Classes, one: bool) bool {
        self.vone = one;
        self.vbytes = self.vmax;
        self.vgroups = false;
        self.vind.truncate(0);
        if !self.counted(b, h, u) {
            if self.lblocks.len() != 2 || u == h {
                return self.no("its body is not one block", 0);
            }
            return false;
        }
        let hb = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let q = self.viv;
        let qt = b.params[(q & ~VPARAM) as usize];
        if type_bytes(qt, ptr) != ptr && !one {
            return self.no("its counter is narrower than a pointer", 0);
        }
        if self.vsigned {
            let init = b.edge_arg(term(b, p).a, (q & ~VPARAM) - hb.param_start);
            if !is_const(b, init) || le::sign_ext(
                b.insts[init as usize].a as u64 | b.insts[init as usize].b as u64 << 32,
                type_bits(qt, ptr),
            ) < 0 {
                return self.no("its signed counter may start below 0", 0);
            }
        }
        let tu = term(b, u);
        // The body's instructions: the step, the reductions, then the rest in order.
        fill(&mut self.vk, ub.len as usize, 0);
        self.vred.truncate(0);
        self.vrup.truncate(0);
        self.vrel.truncate(0);
        self.vord.truncate(0);
        self.vzr.truncate(0);
        self.vqk = 1;
        self.vsz = 0;
        self.vmin = 0;
        for k in 0..hb.param_len as u32 {
            let pv = VPARAM | hb.param_start + k;
            let a = b.edge_arg(ast::pick(self.vexit, self.vback, tu.a), k);
            if !self.in_body(b, u, a) {
                return self.no("a value it carries does not come from its body", 0);
            }
            let at = b.insts[a as usize];
            if pv == q {
                // By 1, or forward by a power of 2 up to 16.
                let kq = if at.op == O_ADD && at.a == q && is_const(b, at.b) {
                    raw_const(b, at.b)
                } else if at.op == O_ADD && at.b == q && is_const(b, at.a) {
                    raw_const(b, at.a)
                } else {
                    0u64
                };
                if !self.vrev && (kq == 0 || kq > 16 || (kq & kq - 1) != 0 || kq > 1 && (one || self.vexit)) {
                    return self.no("its counter does not step by 1", at.op);
                }
                self.vqk = ast::pick(self.vrev, 1u32, kq as u32);
                self.vk[(a - ub.start) as usize] = VK_STEP;
                continue;
            }
            let ty = b.params[(hb.param_start + k) as usize];
            if at.op == O_SELECT && !one {
                let rel = self.minmax(b, ptr, fmath, u, pv, a);
                // A float one with signed zeros: its lanes' extremes, run again in order on a zero (`vzr`;
                // ordered when the loop stores).
                let rz = if rel == NONE16 && is_float(ty) {
                    self.minmax(b, ptr, fmath | FM_NSZ, u, pv, a)
                } else {
                    NONE16
                };
                if rel == NONE16 && rz == NONE16 {
                    return self.no("a value it carries is no reduction it widens", at.op);
                }
                self.vk[(a - ub.start) as usize] = VK_RED;
                self.vk[(at.a - ub.start) as usize] = VK_RCMP;
                self.vred.push(pv);
                self.vrup.push(a);
                self.vrel.push(ast::pick(rel == NONE16, rz, rel));
                self.vord.push(false);
                self.vzr.push(rel == NONE16);
                continue;
            }
            // An integer product of lanes below 8 bytes (a vector multiply), a float sum or product, an
            // ordered float difference from the accumulator.
            let int_op = at.op == O_ADD || at.op == O_AND || at.op == O_OR || at.op == O_XOR || at.op == O_MUL && (one || type_bytes(
                ty,
                ptr,
            ) < 8);
            let assoc = (fmath & FM_ASSOC) != 0;
            let f_op = at.op == O_FADD || at.op == O_FMUL || at.op == O_FSUB && at.a == pv && !assoc;
            let ok_op = is_int(ty) && ty != T_I128 && int_op || is_float(ty) && f_op;
            if !ok_op || at.ty != ty || !(at.a == pv) == !(at.b == pv) || self.reads(b, u, pv) != 1 || self.reads(
                b,
                u,
                a,
            ) != 1 || !self.lane_size(ty, ptr) {
                return self.no("a value it carries is no reduction it widens", at.op);
            }
            self.vk[(a - ub.start) as usize] = VK_RED;
            self.vred.push(pv);
            self.vrup.push(a);
            self.vrel.push(0);
            self.vord.push(is_float(ty) && !assoc);
            self.vzr.push(false);
        }
        // The rest: addresses, loads, arithmetic, stores.
        self.vacc.truncate(0);
        self.vgat.truncate(0);
        self.vstrided = false;
        for i in ub.start..ub.start + ub.len - 1 {
            let x = (i - ub.start) as usize;
            let t = b.insts[i as usize];
            if self.vk[x] == VK_STEP {
                if self.reads(b, u, i) != 1 {
                    return self.no("its counter's next value has another use", 0);
                }
                continue;
            }
            if self.vk[x] == VK_RCMP {
                continue;
            }
            if self.vk[x] == VK_RED {
                let o = if t.op == O_SELECT && contains(&self.vred, t.b) {
                    t.c
                } else if t.op == O_SELECT {
                    t.b
                } else if contains(&self.vred, t.a) {
                    t.b
                } else {
                    t.a
                };
                if self.kind(b, u, o) != VK_LANE && self.kind(b, u, o) != VK_INV && !(one && !self.defined_in(o)) {
                    return self.no("a reduction takes no lane value", t.op);
                }
                continue;
            }
            let k = if !one && self.vqk == 1 && t.op == O_TRUNC && t.a == q && is_int(t.ty) && self.lane_size(t.ty, ptr) {
                // The counter truncated: the lanes count on from it (`vector_ind`).
                self.vind.push(i);
                VK_LANE
            } else {
                self.vclass(b, ptr, u, t)
            };
            if k == 0 {
                return self.no("an instruction it does not widen", t.op);
            }
            self.vk[x] = k;
            if (t.op == O_LOAD || t.op == O_STORE) && k != VK_INV {
                if self.kind(b, u, t.a) == VK_GADDR {
                    self.vgat.push(i);
                } else {
                    self.vacc.push(i);
                }
            }
        }
        // The counter only steps and indexes, but in scalar copies.
        for i in ub.start..ub.start + ub.len {
            let x = (i - ub.start) as usize;
            if i < ub.start + ub.len - 1 && (self.vk[x] == VK_ADDR || self.vk[x] == VK_STEP || contains_u32(
                &self.vind,
                i,
            )) {
                continue;
            }
            if self.vexit && i == ub.start + ub.len - 1 {
                // The exit edge enters the code after the loop, which the loop runs.
                if tu.a == q {
                    return self.no("its counter is a value besides an index", O_BR);
                }
                continue;
            }
            self.outside_uses(b, b.insts[i as usize]);
            // Scalar copies read their own counter (`vqc`), but not in an address they gather through.
            if contains(&self.uses, q) && (!one || self.vgat.len() != 0) {
                return self.no("its counter is a value besides an index", b.insts[i as usize].op);
            }
        }
        if self.vsz == 0 {
            return self.no("it computes no lane value", 0);
        }
        // A store of a branch's side: its condition one comparison of lane values (`store_masked_ptr`).
        for x in 0..self.lcs.len() {
            let s = self.lcs[x];
            if s < ub.start || s >= ub.start + ub.len {
                continue;
            }
            let c = self.lcc[x];
            if one || !self.in_body(b, u, c) || cmp_code(b.insts[c as usize]) == NONE16 || self.kind(b, u, c) != VK_MASK {
                return self.no("a store of a branch's side has no lane condition", O_STORE);
            }
        }
        // An early exit: a lane condition; no store, as a vector iteration runs the lanes past the exit;
        // each load of the slice whose length the loop counts to, element by element, so every byte up
        // to it may be read.
        if self.vexit {
            let k = self.kind(b, u, self.vxc);
            if one || k != VK_LANE && k != VK_MASK || b.insts[self.vxc as usize].op != O_ICMP && b.insts[self.vxc as usize].op != O_FCMP && k != VK_MASK {
                return self.no("its early exit is no lane condition", 0);
            }
            // Before the test (`lsplit`): the lanes past the exit run it too. The rest runs when no lane
            // leaves.
            let at = ub.start + ast::pick(self.lsplit == NONE, ub.len - 1, self.lsplit);
            if self.vstrided || self.vgroups || self.vrev {
                return self.no("an early exit reads past its iteration", 0);
            }
            for x in 0..self.vgat.len() {
                if self.vgat[x] < at {
                    return self.no("an early exit reads past its iteration", O_LOAD);
                }
            }
            for x in 0..self.vacc.len() {
                let t = b.insts[self.vacc[x] as usize];
                if self.vacc[x] < at && (t.op == O_STORE || !self.counted_slice(b, t, ptr)) {
                    return self.no("an early exit reads past its iteration", t.op);
                }
            }
            if at <= self.vxc {
                return self.no("its early exit is no lane condition", 0);
            }
        }
        // A loop that stores keeps the order of a float min or max with signed zeros.
        let mut stores = false;
        for x in 0..self.vacc.len() {
            stores = stores || b.insts[self.vacc[x] as usize].op == O_STORE;
        }
        for r in 0..self.vzr.len() {
            if self.vzr[r] && stores {
                self.vzr[r] = false;
                self.vrel[r] = 0;
                self.vord[r] = true;
            }
        }
        // An ordered reduction runs its lanes one by one: worth it when the lanes compute more than a load.
        if !one && contains_bool(&self.vord, true) {
            let mut work = false;
            for x in 0..ub.len as usize - 1 {
                let o = b.insts[ub.start as usize + x].op;
                work = work || self.vk[x] == VK_LANE && o != O_LOAD && o != O_PTRADD;
            }
            if !work {
                return self.no("an ordered reduction of loads alone gains nothing", 0);
            }
        }
        if self.vgroups && !self.store_groups(b) {
            return self.no("a strided store's group does not write every element", 0);
        }
        // Counting down, each vector holds its elements in order: no lane may stand for its iteration.
        if self.vrev {
            if self.vind.len() != 0 || self.vgroups || self.vstrided || self.vgat.len() != 0 {
                return self.no("a loop counting down reads its counter or a stride per lane", 0);
            }
            for x in 0..self.vacc.len() {
                let t = b.insts[self.vacc[x] as usize];
                let ty = if t.op == O_STORE {
                    value_type(b, t.b)
                } else {
                    t.ty
                };
                if self.stride(b, t.a) != type_bytes(ty, ptr) {
                    return self.no("a loop counting down reads its counter or a stride per lane", 0);
                }
            }
        }
        // The interleaving of a group's vectors, past 32 bytes, would move each lane.
        if self.vgroups && self.vbytes > 32 {
            self.vbytes = 32;
        }
        // An overlapping last vector iteration runs each element's work again: a map's alone.
        self.vtail = !one && self.vred.len() == 0 && !self.vexit && !self.vrev && self.vqk == 1 && !self.vstrided && !self.vgroups && self.vgat.len() == 0;
        for x in 0..self.vacc.len() {
            let s = b.insts[self.vacc[x] as usize];
            if s.op != O_STORE {
                continue;
            }
            for y in 0..self.vacc.len() {
                let o = b.insts[self.vacc[y] as usize];
                if o.op == O_LOAD && b.insts[o.a as usize].a == b.insts[s.a as usize].a {
                    self.vtail = false;
                }
            }
        }
        if !one && !self.cheaper(b, ub, ptr) {
            return self.no("its vector iterations cost more than its scalar ones", 0);
        }
        self.vlanes = if one {
            1
        } else {
            self.plan_lanes()
        };
        return self.vchecks(b, cl);
    }

    // The lanes of the plan's vectors: a register of the widest lane, or past a width ratio of 2 those of
    // 8 bytes of the narrowest (the widest then two registers wide).
    const fn plan_lanes(self: &Self) u32 {
        return (self.vbytes / self.vsz).max(ast::pick(self.vsz > 2 * self.vmin, 8 / self.vmin, 1u32));
    }

    // The cost model: whether a vector iteration of body `ub` runs fewer instructions than its lanes'
    // scalar iterations. An address or a hoisted load costs neither; a vector operation 1; a gathered
    // load 2 per lane (a load and an insert); a load or store through every s-th element 2s - 1 (the
    // loads or stores and the zips); a masked store 1 + 1 per lane; a conversion or shift the target does
    // lane by lane (`Package.vops`) 3 per lane; an ordered reduction's update 2 per lane (an extract and
    // the operation); each loop 2 for its latch.
    fn cheaper(self: &Self, b: &Body, ub: Block, ptr: u32) bool {
        let lanes = self.plan_lanes();
        let mut s: u32 = 2;
        let mut v: u32 = 2;
        for x in 0..ub.len - 1 {
            let i = ub.start + x;
            let t = b.insts[i as usize];
            let k = self.vk[x as usize];
            if k == VK_ADDR || k == VK_GADDR || k == VK_INV || k == VK_STEP || k == 0 {
                continue;
            }
            s += 1;
            let ty = if t.op == O_STORE {
                value_type(b, t.b)
            } else {
                t.ty
            };
            if t.op == O_LOAD && contains_u32(&self.vgat, i) {
                v += 2 * lanes;
            } else if t.op == O_STORE && contains_u32(&self.vgat, i) {
                v += 3 * lanes;
            } else if (t.op == O_LOAD || t.op == O_STORE) && self.stride(b, t.a) != type_bytes(ty, ptr) {
                v += 2 * (self.stride(b, t.a) / type_bytes(ty, ptr)) - 1;
            } else if t.op == O_STORE && self.cond_store(i) != NONE {
                v += 1 + lanes;
            } else if self.by_lane(b, t, ptr) {
                v += 3 * lanes;
            } else {
                v += 1;
            }
        }
        for r in 0..self.vord.len() {
            if self.vord[r] {
                v += 2 * lanes;
            }
        }
        return v < s * lanes;
    }

    // Whether each store through `base + i * step` with `step` 2 or 4 times its element's size (a strided
    // store, `vgroups`) is one of a group: the stores through that address of its element's type, one at
    // each element of the step (offsets `c`, `c + size`, ...).
    fn store_groups(self: &Self, b: &Body) bool {
        for x in 0..self.vacc.len() {
            let s = b.insts[self.vacc[x] as usize];
            if !self.strided_store(b, s) {
                continue;
            }
            let ty = value_type(b, s.b);
            let eb = type_bytes(ty, 8);
            let n = self.stride(b, s.a) / eb;
            // The group's offsets from the lowest: each element once.
            let mut lo = (s.c as i32) as i64;
            for y in 0..self.vacc.len() {
                let o = b.insts[self.vacc[y] as usize];
                if o.op == O_STORE && o.a == s.a {
                    lo = lo.min(o.c as i32);
                }
            }
            let mut seen: u32 = 0;
            for y in 0..self.vacc.len() {
                let o = b.insts[self.vacc[y] as usize];
                if o.a != s.a {
                    continue;
                }
                let d = (o.c as i32) as i64 - lo;
                if o.op != O_STORE || value_type(b, o.b) != ty || d % eb as i64 != 0 || d / eb as i64 >= n as i64 || (seen >> (d / eb as i64) as u32 & 1) != 0 {
                    return false;
                }
                seen |= 1u32 << (d / eb as i64) as u32;
            }
            if seen != (1u32 << n) - 1 {
                return false;
            }
        }
        return true;
    }

    // Whether `s` is a store of the plan through `base + i * step` with `step` past its element's size.
    fn strided_store(self: &Self, b: &Body, s: Inst) bool {
        return s.op == O_STORE && !self.vone && b.insts[s.a as usize].op == O_PTRADD && self.stride(b, s.a) != type_bytes(
            value_type(b, s.b),
            8,
        );
    }

    // Whether loop `h` (latch `u`, its blocks `lblocks`) is counted: a header of a test
    // `q < n` alone (`q` its parameter, `n` defined outside the loop, the test's sides either way) that
    // enters body `u`, which jumps back to it; sets the counter, the bound and the test's signedness
    // (`viv`, `vn`, `vsigned`). The vectorizer and partial unrolling read this shape.
    fn counted(self: &mut Self, b: &Body, h: u32, u: u32) bool {
        return self.lblocks.len() == 2 && u != h && self.counted_by(b, h, u, u);
    }

    // The tests of `counted_by` that read header `h` alone: not `novec`, a comparison and a branch on it.
    fn header_counts(self: &mut Self, b: &Body, h: u32) bool {
        let hb = b.blocks[h as usize];
        let t = term(b, h);
        if (hb.flags & BLOCK_NOVEC) != 0 {
            return self.no("its header is marked `novec`", 0);
        }
        if hb.len != 2 || t.op != O_BR || (t.a & (VPARAM | VFLAG)) != 0 || t.a != hb.start {
            return self.no("its header does more than test the counter", 0);
        }
        return b.insts[t.a as usize].op == O_ICMP;
    }

    // `counted` for loop `h` (its blocks `lblocks`) whose header enters block `e`, and whose block `u`
    // jumps back.
    fn counted_by(self: &mut Self, b: &Body, h: u32, e: u32, u: u32) bool {
        let hb = b.blocks[h as usize];
        let t = term(b, h);
        if !self.header_counts(b, h) {
            return false;
        }
        if b.edge_target(t.b) != e && b.edge_target(t.c) != e {
            return self.no("its header does more than test the counter", 0);
        }
        let ci = b.insts[t.a as usize];
        let in_taken = b.edge_target(t.b) == e;
        if b.edge_nargs(
            if in_taken {
                t.b
            } else {
                t.c
            },
        ) != 0 {
            return false;
        }
        // A counter down by 1 while `q != 0` (or `q >u 0`).
        let pa = (ci.a & VPARAM) != 0 && (ci.a & ~VPARAM) >= hb.param_start && (ci.a & ~VPARAM) < hb.param_start + hb.param_len as u32;
        let pb = (ci.b & VPARAM) != 0 && (ci.b & ~VPARAM) >= hb.param_start && (ci.b & ~VPARAM) < hb.param_start + hb.param_len as u32;
        let za = is_const(b, ci.a) && raw_const(b, ci.a) == 0;
        let zb = is_const(b, ci.b) && raw_const(b, ci.b) == 0;
        let nz_a = pa && zb && (in_taken && (ci.aux == C_NE || ci.aux == C_UGT) || !in_taken && (ci.aux == C_EQ || ci.aux == C_ULE));
        let nz_b = pb && za && (in_taken && (ci.aux == C_NE || ci.aux == C_ULT) || !in_taken && (ci.aux == C_EQ || ci.aux == C_UGE));
        self.vrev = false;
        self.vne = false;
        self.vexit = false;
        if nz_a || nz_b {
            let q = ast::pick(nz_a, ci.a, ci.b);
            let qt = b.params[(q & ~VPARAM) as usize];
            let tu = term(b, u);
            if is_int(qt) && qt != T_I128 && tu.op == O_JMP && b.edge_target(tu.a) == h {
                let nx = b.edge_arg(tu.a, (q & ~VPARAM) - hb.param_start);
                if (nx & (VPARAM | VFLAG)) == 0 && down_by_one(b, b.insts[nx as usize], q) {
                    self.viv = q;
                    self.vn = ast::pick(nz_a, ci.b, ci.a);
                    self.vsigned = false;
                    self.vrev = true;
                    return true;
                }
            }
        }
        // The test read as `q < n` on the in-loop side. `q != n` stepping by 1 reads as `q <u n`: a copy that
        // runs while `q + k <= n` (unsigned) runs only iterations the loop runs, and leaves the rest to it.
        let ne = in_taken && ci.aux == C_NE || !in_taken && ci.aux == C_EQ;
        self.vne = ne;
        let (q, n, cond) = if ne && pa {
            (ci.a, ci.b, C_ULT)
        } else if ne {
            (ci.b, ci.a, C_ULT)
        } else if in_taken && (ci.aux == C_ULT || ci.aux == C_SLT) {
            (ci.a, ci.b, ci.aux)
        } else if in_taken && (ci.aux == C_UGT || ci.aux == C_SGT) {
            (ci.b, ci.a, ci.aux - C_SGT + C_SLT)
        } else if !in_taken && (ci.aux == C_UGE || ci.aux == C_SGE) {
            (ci.a, ci.b, ci.aux - C_SGE + C_SLT)
        } else if !in_taken && (ci.aux == C_ULE || ci.aux == C_SLE) {
            (ci.b, ci.a, ci.aux - C_SLE + C_SLT)
        } else {
            return self.no("its test is no `i < n`", ci.op);
        };
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 || n == VNONE || self.defined_in(
            n,
        ) {
            return self.no("its test is no `i < n` of a counter and a bound from outside it", 0);
        }
        let qt = b.params[(q & ~VPARAM) as usize];
        let tu = term(b, u);
        if !is_int(qt) || qt == T_I128 {
            return false;
        }
        // A body that ends in a branch back or out of the loop: an early exit.
        self.vexit = false;
        if tu.op == O_BR && (tu.a & (VPARAM | VFLAG)) == 0 && tu.a != VNONE && e == u {
            let tb = b.edge_target(tu.b);
            let tc = b.edge_target(tu.c);
            if tb == h && !self.inl[tc as usize] || tc == h && !self.inl[tb as usize] {
                self.vexit = true;
                self.vback = ast::pick(tb == h, tu.b, tu.c);
                self.vxc = tu.a;
                self.vxs = tb == h;
            }
        }
        if !self.vexit && (tu.op != O_JMP || b.edge_target(tu.a) != h) {
            return false;
        }
        self.viv = q;
        self.vn = n;
        self.vsigned = cond == C_SLT;
        return true;
    }

    // The kind (VK_*) instruction `t` of body `u` takes, 0 when it does not vectorize; sets the lane size
    // from a lane value's type.
    fn vclass(self: &mut Self, b: &Body, ptr: u32, u: u32, t: Inst) u8 {
        let op = t.op;
        if op == O_PTRADD {
            if t.a == VNONE || self.defined_in(t.a) {
                return 0;
            }
            return if t.b == self.viv && t.aux != 0 {
                VK_ADDR
            } else if self.kind(b, u, t.b) == VK_LANE && is_int(value_type(b, t.b)) {
                VK_GADDR
            } else {
                0
            };
        }
        if self.vone && (op == O_SEXT || op == O_ZEXT || op == O_TRUNC) && is_int(t.ty) && t.ty != T_I128 && self.lane_size(
            t.ty,
            ptr,
        ) {
            return self.lane_operands(b, u, t, true);
        }
        if !self.vone && self.vops != 0 && op >= O_SEXT && op <= O_UITOFP && t.ty != T_I128 && value_type(b, t.a) != T_I128 && vconv_ok(
            op,
            value_type(b, t.a),
            t.ty,
            ptr,
        ) && self.lane_size(value_type(b, t.a), ptr) && self.lane_size(t.ty, ptr) {
            return self.lane_operands(b, u, t, true);
        }
        if op == O_LOAD && !self.defined_in(t.a) && (t.aux & MEM_VOLATILE) == 0 && is_int(t.ty) && t.ty != T_I128 || op == O_LOAD && !self.defined_in(
            t.a,
        ) && (t.aux & MEM_VOLATILE) == 0 && is_float(t.ty) {
            return if self.lane_size(t.ty, ptr) {
                VK_INV
            } else {
                0
            };
        }
        if op == O_LOAD || op == O_STORE {
            let ty = if op == O_LOAD {
                t.ty
            } else {
                value_type(b, t.b)
            };
            // Through `base + i * size`, or scalar copies through any step and a gathered address; a vector
            // load through every 2nd or 4th element (`vunzip`).
            let ka = self.kind(b, u, t.a);
            let eb = type_bytes(ty, ptr);
            if (t.aux & MEM_VOLATILE) != 0 || is_vec(ty) || ty == T_PTR || !self.lane_size(ty, ptr) || ka != VK_ADDR && ka != VK_GADDR {
                return 0;
            }
            if ka == VK_ADDR {
                let step = self.stride(b, t.a);
                let s = step / eb;
                if step != eb && !self.vone && !(step % eb == 0 && (s == 2 || s == 4)) {
                    return 0;
                }
                if op == O_LOAD {
                    self.vstrided = self.vstrided || step != eb && !self.vone;
                } else {
                    self.vgroups = self.vgroups || step != eb && !self.vone;
                }
            }
            if op == O_LOAD {
                return VK_LANE;
            }
            return if self.kind(b, u, t.b) == VK_LANE || self.kind(b, u, t.b) == VK_INV || !self.defined_in(t.b) {
                VK_STORE
            } else {
                0
            };
        }
        if op == O_ICMP || op == O_FCMP {
            // A mask of the operands' lane width: a vector comparison, integers or floats of the plan's
            // lane size.
            let ot = value_type(b, t.a);
            if !(is_int(ot) && ot != T_I128 || is_float(ot)) || op == O_FCMP && !vcmp_ok(t.aux, ot) || !self.lane_size(
                ot,
                ptr,
            ) {
                return 0;
            }
            return self.lane_operands(b, u, t, false);
        }
        if (op == O_AND || op == O_OR) && self.kind(b, u, t.a) == VK_MASK && self.kind(b, u, t.b) == VK_MASK {
            return VK_MASK;
        }
        if op == O_SELECT {
            // The condition a mask, or a value from outside the loop (one side for every lane).
            let kc = self.kind(b, u, t.a);
            if kc != VK_MASK && self.defined_in(t.a) || !(is_int(t.ty) && t.ty != T_I128 || is_float(t.ty)) || !self.lane_size(
                t.ty,
                ptr,
            ) {
                return 0;
            }
            let ks = self.kind(b, u, t.b);
            let kt = self.kind(b, u, t.c);
            let os = ks == VK_LANE || ks == VK_INV || !self.defined_in(t.b);
            let ot = kt == VK_LANE || kt == VK_INV || !self.defined_in(t.c);
            return if (kc == VK_MASK || ks == VK_LANE || kt == VK_LANE) && os && ot {
                VK_LANE
            } else {
                0
            };
        }
        // A shift's amounts are lanes too (each below the width, as the scalar shift's).
        let shift = (op == O_SHL || op == O_LSHR || op == O_ASHR) && self.vops != 0 && !self.vone;
        let int_op = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR || op == O_NEG || op == O_NOT || op == O_MUL || shift;
        let float_op = op >= O_FADD && op <= O_FNEG || op == O_FSQRT;
        if !(is_int(t.ty) && t.ty != T_I128 && int_op || is_float(t.ty) && float_op) || !self.lane_size(t.ty, ptr) {
            return 0;
        }
        // No 64-bit lane multiply in the vector units of the targets.
        if op == O_MUL && type_bytes(t.ty, ptr) == 8 && !self.vone {
            return 0;
        }
        return self.lane_operands(b, u, t, op == O_NEG || op == O_NOT || op == O_FNEG || op == O_FSQRT);
    }

    // The kind of lane operation `t` of body `u` (`unary`: one operand): a mask for a comparison, else a lane
    // value, when an operand is a lane value and each is one, an invariant load or from outside the loop;
    // else 0.
    fn lane_operands(self: &Self, b: &Body, u: u32, t: Inst, unary: bool) u8 {
        let ka = self.kind(b, u, t.a);
        let kb = if unary {
            0u8
        } else {
            self.kind(b, u, t.b)
        };
        let la = ka == VK_LANE;
        let lb = kb == VK_LANE;
        let oa = la || ka == VK_INV || !self.defined_in(t.a);
        let ob = unary || lb || kb == VK_INV || !self.defined_in(t.b);
        return if !((la || lb) && oa && ob) {
            0
        } else if t.op == O_ICMP || t.op == O_FCMP {
            VK_MASK
        } else {
            VK_LANE
        };
    }

    // Whether scalar type `ty` has the plan's lane size, setting it when unset. Scalar copies mix lane
    // sizes; vectors do when the target converts them in registers (`vops`), the widest lane at most twice
    // the narrowest, or 4 times with registers of at most 32 bytes (`plan_lanes`).
    fn lane_size(self: &mut Self, ty: u8, ptr: u32) bool {
        let n = type_bytes(ty, ptr);
        if n == 0 || n > 8 {
            return false;
        }
        if self.vsz == 0 {
            self.vsz = n;
            self.vmin = n;
        }
        if self.vsz == n && self.vmin == n || self.vone {
            return true;
        }
        let lo = self.vmin.min(n);
        let hi = self.vsz.max(n);
        if self.vops == 0 || hi > 4 * lo || hi > 2 * lo && self.vmax > 32 {
            return false;
        }
        self.vmin = lo;
        self.vsz = hi;
        return true;
    }

    // The plan's kind of value `v` defined in body `u` (0: none or outside it).
    fn kind(self: &Self, b: &Body, u: u32, v: Value) u8 {
        if self.vone && v == self.viv {
            return VK_LANE;
        }
        if !self.in_body(b, u, v) {
            return 0;
        }
        return self.vk[(v - b.blocks[u as usize].start) as usize];
    }

    // Whether `v` is an instruction's value of block `u`.
    fn in_body(self: &Self, b: &Body, u: u32, v: Value) bool {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let ub = b.blocks[u as usize];
        return v >= ub.start && v < ub.start + ub.len;
    }

    // The reads of value `v` in block `u`, its edges' arguments included.
    fn reads(self: &mut Self, b: &Body, u: u32, v: Value) u32 {
        let ub = b.blocks[u as usize];
        let mut n: u32 = 0;
        for i in ub.start..ub.start + ub.len {
            self.outside_uses(b, b.insts[i as usize]);
            for q in 0..self.uses.len() {
                n += (self.uses[q] == v) as u32;
            }
        }
        return n;
    }

    // The pairs of accesses whose ranges the guard checks apart (`vca`, `vcb`): each store and each other
    // access through another base, but those of different alias classes (`cl`: an exclusive parameter's
    // referent and other memory); an access through the same base must be the same element. False when
    // that does not hold, the pairs are too many, or a store is not apart from a load of one place.
    fn vchecks(self: &mut Self, b: &Body, cl: Classes) bool {
        self.vca.truncate(0);
        self.vcb.truncate(0);
        let ub = b.blocks[self.latch as usize];
        for x in 0..ub.len {
            if self.vk[x as usize] != VK_INV {
                continue;
            }
            for y in 0..self.vacc.len() {
                if b.insts[self.vacc[y] as usize].op == O_STORE && !self.apart(cl, ub.start + x, self.vacc[y]) {
                    return self.no("a store may write the place an invariant load reads", 0);
                }
            }
        }
        // A gathered load may read any element: apart from every store. A scattered store may write any
        // element: apart from every other access.
        for x in 0..self.vgat.len() {
            let g = self.vgat[x];
            let sc = b.insts[g as usize].op == O_STORE;
            for y in 0..self.vacc.len() {
                if (sc || b.insts[self.vacc[y] as usize].op == O_STORE) && !self.apart(cl, g, self.vacc[y]) {
                    return self.no("a store may write what a gathered load reads", 0);
                }
            }
            for y in 0..self.vgat.len() {
                if sc && y != x && !self.apart(cl, g, self.vgat[y]) {
                    return self.no("a scattered store may write what another access touches", 0);
                }
            }
        }
        for x in 0..self.vacc.len() {
            let s = b.insts[self.vacc[x] as usize];
            if s.op != O_STORE {
                continue;
            }
            let sa = b.insts[s.a as usize];
            for y in 0..self.vacc.len() {
                if x == y {
                    continue;
                }
                let o = b.insts[self.vacc[y] as usize];
                let oa = b.insts[o.a as usize];
                // Stores of one group write different elements of each iteration's step.
                if o.a == s.a && self.strided_store(b, s) && self.strided_store(b, o) {
                    continue;
                }
                if oa.a == sa.a {
                    let d = (oa.c as i32) as i64 + (o.c as i32) as i64 - (sa.c as i32) as i64 - (s.c as i32) as i64;
                    if oa.aux != sa.aux || d != 0 && !self.distance_ok(b, self.vacc[x], self.vacc[y], d) {
                        return self.no("a store and another access through its base touch different elements", 0);
                    }
                    continue;
                }
                if self.apart(cl, self.vacc[x], self.vacc[y]) {
                    continue;
                }
                // Each pair once.
                let mut seen = false;
                for z in 0..self.vca.len() {
                    seen = seen || self.vca[z] == self.vacc[y] && self.vcb[z] == self.vacc[x] || self.vca[z] == self.vacc[x] && self.vcb[z] == self.vacc[y];
                }
                if seen {
                    continue;
                }
                if self.vca.len() == MAX_CHECKS {
                    return self.no("its accesses need too many overlap checks", 0);
                }
                self.vca.push(self.vacc[x]);
                self.vcb.push(self.vacc[y]);
            }
        }
        return true;
    }

    // The bytes access address `a` (`base + i * scale`) steps by per iteration: its scale times the counter's
    // step.
    fn stride(self: &Self, b: &Body, a: Value) u32 {
        return b.insts[a as usize].aux as u32 * self.vqk;
    }

    // Whether the target converts or shifts as instruction `t` does lane by lane (`Package.vops`
    // VOPS_SOME).
    fn by_lane(self: &Self, b: &Body, t: Inst, ptr: u32) bool {
        if self.vops != VOPS_SOME {
            return false;
        }
        let op = t.op;
        let eb = type_bytes(t.ty, ptr);
        if op == O_SHL || op == O_LSHR || op == O_ASHR {
            return self.vbytes < 32 || eb < 4 || op == O_ASHR && eb == 8;
        }
        // A narrower integer to a float extends, then converts as signed (`vconv`).
        let ft = value_type(b, t.a);
        let wider = is_int(ft) && type_bytes(ft, ptr) < eb;
        return (op == O_SITOFP || op == O_UITOFP) && t.ty == T_F64 || op == O_FPTOSI && t.ty == T_I64 || op == O_UITOFP && !wider || op == O_FPTOUI;
    }

    // Whether load `t` reads element `i` of a slice at least as long as the bound the loop counts to:
    // through `ptr + i * size` at offset 0, `ptr` and the bound `n` the loads of one slice's two words, or
    // `n` the least of the slice's length and another.
    fn counted_slice(self: &Self, b: &Body, t: Inst, ptr: u32) bool {
        let a = b.insts[t.a as usize];
        if a.op != O_PTRADD || a.c != 0 || t.c != 0 || a.aux as u32 != type_bytes(t.ty, ptr) || (a.a & (VPARAM | VFLAG)) != 0 || (self.vn & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let pl = b.insts[a.a as usize];
        if slice_len(b, pl, self.vn, ptr) {
            return true;
        }
        // The least of lengths (`select (x <u y), x, y`), the slice's one of them.
        let s = b.insts[self.vn as usize];
        if s.op != O_SELECT || (s.a & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let c = b.insts[s.a as usize];
        return c.op == O_ICMP && (c.aux == C_ULT && c.a == s.b && c.b == s.c || c.aux == C_UGT && c.a == s.c && c.b == s.b) && (slice_len(
            b,
            pl,
            s.b,
            ptr,
        ) || slice_len(b, pl, s.c, ptr));
    }

    // Whether store `s` and access `o` through one base `d` bytes apart (both `base + i * step`) keep their
    // order in the vector loop: `o` a load, its elements no wider than the step; ahead of the store (`d` > 0)
    // and before it in the body, it reads each element before any iteration writes it; behind it by at least
    // a vector loop's iterations, it reads what an earlier vector iteration wrote (the dependence distance).
    fn distance_ok(self: &Self, b: &Body, s: u32, o: u32, d: i64) bool {
        let st = b.insts[s as usize];
        let ot = b.insts[o as usize];
        let step = self.stride(b, st.a) as i64;
        if ot.op != O_LOAD || step < type_bytes(ot.ty, 8) as i64 || step < type_bytes(value_type(b, st.b), 8) as i64 {
            return false;
        }
        if self.vrev {
            return false;
        }
        if d > 0 {
            return o < s;
        }
        return -d >= (self.vlanes * self.vnv) as i64 * step;
    }

    // Whether accesses `x` and `y` touch different bytes in every iteration of the loop at hand
    // (`cl`): different classes, neither CL_MANY nor a scope's whose roots the loop holds, each in the
    // other's scope.
    fn apart(self: &Self, cl: Classes, x: u32, y: u32) bool {
        let ox = obj_at(cl, self.orig(x));
        let oy = obj_at(cl, self.orig(y));
        if ox != oy && (ox != NONE && oy != NONE || private_obj(ox) || private_obj(oy)) {
            return true;
        }
        let cx = class_at(cl, self.orig(x));
        let cy = class_at(cl, self.orig(y));
        return cx != cy && self.scope_ok(cl, cx, y) && self.scope_ok(cl, cy, x);
    }

    // Whether class `c` keeps apart, for the loop at hand, an access in it from instruction `i`'s: no
    // CL_MANY, and a scope's when its roots are outside the loop and `i` is in its copy.
    fn scope_ok(self: &Self, cl: Classes, c: u8, i: u32) bool {
        if c >= CL_MANY {
            return false;
        }
        if c < 64 && (cl.scoped >> c as u64 & 1) == 0 {
            return true;
        }
        let r = cl.root[c as usize];
        let o = self.orig(i);
        let m = if o as usize < cl.member.len() {
            cl.member[o as usize]
        } else {
            0u64
        };
        return r != NONE && !self.inl[r as usize] && (m >> c as u64 & 1) != 0;
    }

    // Vectorize loop `h` (preheader `p`, body `u`) as planned, `nv` vectors interleaved. The preheader
    // enters a guard that runs the vector loop or enters the loop through a new preheader; the vector
    // loop's exit reduces its accumulators and enters the loop with the iterations left.
    fn vectorize(self: &mut Self, b: &mut Body, h: u32, p: u32, u: u32, nv: u32) {
        self.wide = self.wide || !self.vone && self.vlanes * self.vsz > self.vmax;
        let hb = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let l0 = b.locs[hb.start as usize];
        let qt = b.params[(self.viv & ~VPARAM) as usize];
        let step = self.vlanes * nv;
        let nred = self.vred.len() as u32;
        // The block numbers: guard, vector preheader, vector loop, (with an early exit, the vector loop's
        // latch,) vector exit, the loop's new preheader.
        let g = b.blocks.len() as u32;
        let vp = g + 1;
        let vl = g + 2;
        let lb = g + 3;
        let vx = g + 3 + self.vexit as u32;
        let sp = vx + 1;
        // The guard: the header's parameters; the count of iterations the vectors run, and the checks.
        let gps = self.vblock_params(b, h);
        let gstart = b.insts.len() as u32;
        let i0 = VPARAM | gps + (self.viv & ~VPARAM) - hb.param_start;
        let lt = self.vi(
            b,
            Inst {
                op: O_ICMP,
                ty: T_I8,
                aux: if self.vsigned {
                    C_SLT
                } else {
                    C_ULT
                },
                a: i0,
                b: self.vn,
                c: 0,
            },
            l0,
        );
        let mut d = if self.vrev {
            i0
        } else {
            self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: self.vn, b: i0, c: 0 }, l0)
        };
        let ks = self.vqk.trailing_zeros();
        if self.vqk > 1 {
            // The iterations from `i0` by `k` below `n`: ((n - i0 - 1) >> log2 k) + 1 (`i0 < n`).
            let one = self.vconst(b, qt, 1, l0);
            let sh = self.vconst(b, qt, ks as u64, l0);
            let d1 = self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: d, b: one, c: 0 }, l0);
            let d2 = self.vi(b, Inst { op: O_LSHR, ty: qt, aux: 0, a: d1, b: sh, c: 0 }, l0);
            d = self.vi(b, Inst { op: O_ADD, ty: qt, aux: 0, a: d2, b: one, c: 0 }, l0);
        }
        if self.vstrided {
            // A strided load's last vector reads up to the next iteration's element: the loop runs the
            // last iteration, whose element is past every byte the vectors read.
            let one = self.vconst(b, qt, 1, l0);
            d = self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: d, b: one, c: 0 }, l0);
        }
        let z = self.vconst(b, qt, 0, l0);
        // Counting down from `i0`, the loop runs `i0` iterations.
        let trips = if self.vrev {
            d
        } else {
            self.vi(b, Inst { op: O_SELECT, ty: qt, aux: 0, a: lt, b: d, c: z }, l0)
        };
        let mk = self.vconst(b, qt, ~((step - 1) as u64) & mask_of(type_bits(qt, 8)), l0);
        let cnt = self.vi(b, Inst { op: O_AND, ty: qt, aux: 0, a: trips, b: mk, c: 0 }, l0);
        let mut ok = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: cnt, b: z, c: 0 }, l0);
        for k in 0..self.vca.len() {
            let (alo, ahi) = self.vrange(b, self.vca[k], i0, l0);
            let (blo, bhi) = self.vrange(b, self.vcb[k], i0, l0);
            let c1 = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: ahi, b: blo, c: 0 }, l0);
            let c2 = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: bhi, b: alo, c: 0 }, l0);
            let apart = self.vi(b, Inst { op: O_OR, ty: T_I8, aux: 0, a: c1, b: c2, c: 0 }, l0);
            ok = self.vi(b, Inst { op: O_AND, ty: T_I8, aux: 0, a: ok, b: apart, c: 0 }, l0);
        }
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.args.push(VPARAM | gps + q);
        }
        let to_sp = b.edge(sp, &self.args);
        let none: []Value = [];
        let to_vp = b.edge(vp, none);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: ok, b: to_vp, c: to_sp }, l0);
        self.vblock(b, g, gstart, gps, hb.param_len, hb.flags, p);
        // The vector preheader: the end of the vector iterations, the splats, the accumulators' start.
        let pstart = b.insts.len() as u32;
        // The counter's end: the iterations times its step.
        let cu = if self.vqk > 1 {
            let sh = self.vconst(b, qt, ks as u64, l0);
            self.vi(b, Inst { op: O_SHL, ty: qt, aux: 0, a: cnt, b: sh, c: 0 }, l0)
        } else {
            cnt
        };
        let iend = self.vi(b, Inst { op: ast::pick(self.vrev, O_SUB, O_ADD), ty: qt, aux: 0, a: i0, b: cu, c: 0 }, l0);
        self.vinv.truncate(0);
        self.vspl.truncate(0);
        fill(&mut self.vmap, (nv * ub.len) as usize, VNONE);
        for i in ub.start..ub.start + ub.len - 1 {
            let x = (i - ub.start) as usize;
            if self.vk[x] == VK_INV {
                let s = self.vi(b, b.insts[i as usize], b.locs[i as usize]);
                self.vsplat(b, u, s, l0);
                let sv = self.vval(b, u, 0, s);
                for c in 0..nv {
                    self.vmap[(c * ub.len) as usize + x] = sv;
                }
            }
        }
        for i in ub.start..ub.start + ub.len - 1 {
            let x = (i - ub.start) as usize;
            let t = b.insts[i as usize];
            // A reduction's update reads its parameter and a lane value: no splat; nor does a select's
            // condition from outside the loop, which picks a side for every lane.
            if self.vk[x] == VK_LANE || self.vk[x] == VK_STORE || self.vk[x] == VK_MASK || self.vk[x] == VK_GADDR {
                let f = op_info(t.op).form;
                if t.op == O_STORE {
                    self.vsplat(b, u, t.b, l0);
                } else if t.op == O_SELECT {
                    self.vsplat(b, u, t.b, l0);
                    self.vsplat(b, u, t.c, l0);
                } else if t.op != O_LOAD {
                    if lv::operand_a(f) {
                        self.vsplat(b, u, t.a, l0);
                    }
                    if lv::operand_b(f) {
                        self.vsplat(b, u, t.b, l0);
                    }
                }
            }
        }
        self.args.truncate(0);
        self.args.push(i0);
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            let vt = self.lane_ty(rt);
            // An ordered one starts from the start value; a min or max starts each lane at it, which it may
            // take again.
            let id = if self.vord[r as usize] {
                VPARAM | gps + (self.vred[r as usize] & ~VPARAM) - hb.param_start
            } else if self.vrel[r as usize] != 0 {
                let r0 = VPARAM | gps + (self.vred[r as usize] & ~VPARAM) - hb.param_start;
                self.vi(b, Inst { op: O_SPLAT, ty: vt, aux: 0, a: r0, b: VNONE, c: VNONE }, l0)
            } else {
                let idv = self.identity(b, b.insts[self.vrup[r as usize] as usize].op, rt);
                self.vsplat_const(b, vt, idv, l0)
            };
            for _ in 0..nv {
                self.args.push(id);
            }
        }
        let to_vl = b.edge(vl, &self.args);
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_vl, b: 0, c: 0 }, l0);
        self.vblock(b, vp, pstart, b.params.len() as u32, 0, hb.flags, g);
        // The vector loop: the counter, the accumulators; `nv` copies of the body's lanes, each instruction's
        // copies together (the copies' loads and stores next to each other pair).
        let vps = b.params.len() as u32;
        b.params.push(qt);
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            let pt = ast::pick(self.vord[r as usize], rt, self.lane_ty(rt));
            for _ in 0..nv {
                b.params.push(pt);
            }
        }
        let lstart = b.insts.len() as u32;
        let vi = VPARAM | vps;
        // Scalar copies: copy c's counter, `c` steps on from the loop's.
        self.vqc.truncate(0);
        for c in 0..ast::pick(self.vone, nv, 0u32) {
            self.vqc.push(
                if c == 0 {
                    vi
                } else {
                    let kc = self.vconst(b, qt, c * self.vqk, l0);
                    self.vi(b, Inst { op: ast::pick(self.vrev, O_SUB, O_ADD), ty: qt, aux: 0, a: vi, b: kc, c: 0 }, l0)
                },
            );
        }
        // With an early exit, the latch block's start: past the exit test.
        let mut ls: u32 = 0;
        for i in ub.start..ub.start + ub.len - 1 {
            if self.vexit && self.lsplit != NONE && i == ub.start + self.lsplit {
                ls = self.vexit_test(b, ub, nv, vps, vi, vx, lb, lstart, hb.flags, vp, l0);
            }
            for c in 0..nv {
                let x = i - ub.start;
                let t = b.insts[i as usize];
                let k = self.vk[x as usize];
                let at = (c * ub.len + x) as usize;
                if k == VK_ADDR {
                    // One address per iteration: the copies' accesses add their offsets to it. Counting
                    // down, the lowest element's: the counter's value `step - 1` on.
                    self.vmap[at] = if c == 0 {
                        let ix = if self.vrev {
                            let sk1 = self.vconst(b, qt, step - 1, l0);
                            self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: vi, b: sk1, c: 0 }, l0)
                        } else {
                            vi
                        };
                        self.vi(
                            b,
                            Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux, a: t.a, b: ix, c: t.c },
                            b.locs[i as usize],
                        )
                    } else {
                        self.vmap[x as usize]
                    };
                } else if !self.vone && k == VK_GADDR {
                    // A gathered address: each lane's at its access (`vgather`).
                    self.vmap[at] = VNONE;
                } else if !self.vone && (t.op == O_LOAD || t.op == O_STORE) && self.kind(b, u, t.a) == VK_GADDR {
                    self.vmap[at] = self.vgather(b, u, c, t, b.locs[i as usize]);
                } else if k == VK_LANE && contains_u32(&self.vind, i) {
                    self.vmap[at] = self.vector_ind(b, t, vi, c, b.locs[i as usize]);
                } else if k == VK_LANE || k == VK_STORE || k == VK_MASK || k == VK_GADDR {
                    let mut nt = t;
                    let f = op_info(t.op).form;
                    if t.op != O_STORE {
                        nt.ty = self.lane_ty(t.ty);
                    }
                    let strided = (t.op == O_LOAD || t.op == O_STORE) && self.kind(b, u, t.a) == VK_ADDR;
                    if strided && self.strided_store(b, t) {
                        // A group's vectors interleaved, stored after its last store (`store_group`).
                        self.store_group(b, u, c, i);
                        continue;
                    }
                    if strided {
                        // Copy c starts `c * lanes` iterations on; counting down, its elements are the
                        // `nv - 1 - c`th lanes' from the lowest.
                        let step = self.stride(b, t.a);
                        let cc = ast::pick(self.vrev, nv - 1 - c, c);
                        nt.c = (((t.c as i32) as i64 + (cc * self.vlanes * step) as i64) as i32) as u32;
                        let eb = type_bytes(t.ty, 8);
                        if t.op == O_LOAD && step != eb && !self.vone {
                            // The vectors from the element on, each lane its own element's, then the
                            // even lanes of each pair until one vector is left.
                            nt.a = self.vval(b, u, c, t.a);
                            let mut parts = Vector::<Value>::new();
                            for j in 0..step / eb {
                                let mut lt = nt;
                                lt.c = (((nt.c as i32) as i64 + (j * self.vlanes * eb) as i64) as i32) as u32;
                                parts.push(self.vi(b, lt, b.locs[i as usize]));
                            }
                            while parts.len() > 1 {
                                let mut next = Vector::<Value>::new();
                                for q in 0..parts.len() / 2 {
                                    next.push(
                                        self.vi(
                                            b,
                                            Inst {
                                                op: O_VUNZIP,
                                                ty: nt.ty,
                                                aux: 0,
                                                a: parts[2 * q],
                                                b: parts[2 * q + 1],
                                                c: VNONE,
                                            },
                                            b.locs[i as usize],
                                        ),
                                    );
                                }
                                parts = next;
                            }
                            self.vmap[at] = parts[0];
                            continue;
                        }
                    }
                    let cs = if t.op == O_STORE {
                        self.cond_store(i)
                    } else {
                        NONE
                    };
                    if cs != NONE {
                        // The lanes the condition picks: a lane mask of the comparison, its complement for
                        // the other side; the store's address at the copy's offset.
                        let l = b.locs[i as usize];
                        let ci = b.insts[self.lcc[cs as usize] as usize];
                        let mt = mask_int_of(self.vlanes);
                        let ops = [self.vval(b, u, c, ci.a), self.vval(b, u, c, ci.b)];
                        let at2 = b.pool_list(ops[0..2]);
                        let mut m = self.vi(b, Inst { op: O_VOP, ty: mt, aux: cmp_code(ci), a: at2, b: 2, c: VNONE }, l);
                        if !self.lcw[cs as usize] {
                            let full = self.vconst(b, mt, mask_of(self.vlanes), l);
                            m = self.vi(b, Inst { op: O_XOR, ty: mt, aux: 0, a: m, b: full, c: 0 }, l);
                        }
                        let pa = self.vi(
                            b,
                            Inst { op: O_PTRADD, ty: T_PTR, aux: 0, a: self.vval(b, u, c, t.a), b: VNONE, c: nt.c },
                            l,
                        );
                        let sv = [pa, m, self.vval(b, u, c, t.b)];
                        let at3 = b.pool_list(sv[0..3]);
                        let code = (core::OP_SIMD + core::SIMD_STORE_MASKED_PTR as u32) as u16;
                        self.vmap[at] = self.vi(b, Inst { op: O_VOP, ty: T_NONE, aux: code, a: at3, b: 3, c: VNONE }, l);
                        continue;
                    }
                    if lv::operand_a(f) && !(t.op == O_SELECT && !self.defined_in(t.a)) {
                        nt.a = self.vval(b, u, c, t.a);
                    }
                    if lv::operand_b(f) && t.b != VNONE {
                        nt.b = self.vval(b, u, c, t.b);
                    }
                    if lv::operand_c(f) {
                        nt.c = self.vval(b, u, c, t.c);
                    }
                    if !self.vone {
                        // A mask's lanes are integers of its comparison's operands' width: a vector
                        // comparison; `and` and `or` of masks, and a select on one, convert one of
                        // another width (`vmask`).
                        let l = b.locs[i as usize];
                        if t.op == O_ICMP || t.op == O_FCMP {
                            nt.op = O_VCMP;
                            nt.ty = mask_type(self.lane_ty(value_type(b, t.a)));
                        } else if k == VK_MASK {
                            nt.ty = value_type(b, nt.a);
                            nt.b = self.vmask(b, nt.b, nt.ty, l);
                        } else if t.op == O_SELECT && self.defined_in(t.a) {
                            nt.op = O_VSEL;
                            nt.a = self.vmask(b, nt.a, mask_type(nt.ty), l);
                        } else if t.op >= O_SEXT && t.op <= O_UITOFP {
                            self.vmap[at] = self.vconv(b, nt, l);
                            continue;
                        }
                    }
                    self.vmap[at] = self.vi(b, nt, b.locs[i as usize]);
                } else if k == VK_RED && self.vord[self.red_of(i) as usize] {
                    // In order: copy c's lanes after copy c - 1's, each through the update.
                    let r = self.red_of(i);
                    let mut acc = if c == 0 {
                        VPARAM | vps + 1 + r * nv
                    } else {
                        self.vmap[((c - 1) * ub.len + x) as usize]
                    };
                    let pv = self.vred[r as usize];
                    let lx = if t.op == O_SELECT {
                        ast::pick(t.b == pv, t.c, t.b)
                    } else {
                        ast::pick(t.a == pv, t.b, t.a)
                    };
                    let xv = self.vval(b, u, c, lx);
                    let l = b.locs[i as usize];
                    let nl = ast::pick(self.vone, 1u32, self.vlanes);
                    for j0 in 0..nl {
                        // Counting down, the highest lane is the first iteration.
                        let j = ast::pick(self.vrev, nl - 1 - j0, j0);
                        let e = if self.vone {
                            xv
                        } else {
                            self.vi(b, Inst { op: O_VEXTRACT, ty: t.ty, aux: j as u16, a: xv, b: VNONE, c: VNONE }, l)
                        };
                        let mut nt = t;
                        if t.op == O_SELECT {
                            let mut ct = b.insts[t.a as usize];
                            ct.a = ast::pick(ct.a == pv, acc, e);
                            ct.b = ast::pick(ct.b == pv, acc, e);
                            nt.a = self.vi(b, ct, l);
                            nt.b = ast::pick(t.b == pv, acc, e);
                            nt.c = ast::pick(t.c == pv, acc, e);
                        } else {
                            nt.a = ast::pick(t.a == pv, acc, e);
                            nt.b = ast::pick(t.b == pv, acc, e);
                        }
                        acc = self.vi(b, nt, l);
                    }
                    self.vmap[at] = acc;
                } else if k == VK_RED && self.vrel[self.red_of(i) as usize] != 0 {
                    let r = self.red_of(i);
                    let acc = VPARAM | vps + 1 + r * nv + c;
                    let x = if t.b == self.vred[r as usize] {
                        t.c
                    } else {
                        t.b
                    };
                    let xv = self.vval(b, u, c, x);
                    self.vmap[at] = self.vbeat(b, self.vrel[r as usize], xv, acc, b.locs[i as usize]);
                } else if k == VK_RED {
                    let r = self.red_of(i);
                    let acc = VPARAM | vps + 1 + r * nv + c;
                    let o = if t.a == self.vred[r as usize] {
                        t.b
                    } else {
                        t.a
                    };
                    let mut nt = t;
                    nt.ty = self.lane_ty(t.ty);
                    nt.a = acc;
                    nt.b = self.vval(b, u, c, o);
                    self.vmap[at] = self.vi(b, nt, b.locs[i as usize]);
                }
            }
        }
        if self.vexit && (self.lsplit == NONE || self.lsplit == ub.len - 1) {
            ls = self.vexit_test(b, ub, nv, vps, vi, vx, lb, lstart, hb.flags, vp, l0);
        }
        let sk = self.vconst(b, qt, step * self.vqk, l0);
        let vnext = self.vi(b, Inst { op: ast::pick(self.vrev, O_SUB, O_ADD), ty: qt, aux: 0, a: vi, b: sk, c: 0 }, l0);
        // An overlapping last iteration: on while below `n - k`, then the tail block (`sp + 1`) runs the
        // iteration at `n - k` once when elements are left; the counter's chain stays an add.
        let last = if self.vtail {
            self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: self.vn, b: sk, c: 0 }, l0)
        } else {
            VNONE
        };
        let more = if self.vtail {
            self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_ULT, a: vnext, b: last, c: 0 }, l0)
        } else {
            self.vi(
                b,
                Inst { op: O_ICMP, ty: T_I8, aux: ast::pick(self.vrev, C_UGT, C_ULT), a: vnext, b: iend, c: 0 },
                l0,
            )
        };
        self.args.truncate(0);
        self.args.push(vnext);
        for r in 0..nred {
            for c in 0..nv {
                let x = self.vrup[r as usize] - ub.start;
                // An ordered one's last copy holds its accumulator: in each parameter.
                let cc = ast::pick(self.vord[r as usize], nv - 1, c);
                self.args.push(self.vmap[(cc * ub.len + x) as usize]);
            }
        }
        let back = b.edge(vl, &self.args);
        // Out of the loop the counter is the vectors' end; past the overlapping iteration's tail block, `n`.
        self.args[0] = ast::pick(self.vtail, vnext, iend);
        let out = b.edge(ast::pick(self.vtail, sp + 1, vx), &self.args);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: more, b: back, c: out }, l0);
        if self.vexit {
            self.vblock(b, lb, ls, b.params.len() as u32, 0, hb.flags, vl);
        } else {
            self.vblock(b, vl, lstart, vps, (1 + nred * nv) as u16, hb.flags | BLOCK_NOVEC, vp);
        }
        // The vector exit: the counter where the vectors stop; each reduction's accumulators combined and
        // reduced into its start value.
        let xq = b.params.len() as u32;
        b.params.push(qt);
        let xps = b.params.len() as u32;
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            let pt = ast::pick(self.vord[r as usize], rt, self.lane_ty(rt));
            for _ in 0..nv {
                b.params.push(pt);
            }
        }
        let xstart = b.insts.len() as u32;
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            let pv = VPARAM | hb.param_start + q;
            if pv == self.viv {
                self.args.push(VPARAM | xq);
                continue;
            }
            let r = self.red_param(pv);
            if self.vord[r as usize] {
                self.args.push(VPARAM | xps + r * nv);
                continue;
            }
            let rt = b.params[(pv & ~VPARAM) as usize];
            let op = b.insts[self.vrup[r as usize] as usize].op;
            let vt = self.lane_ty(rt);
            let rel = self.vrel[r as usize];
            let mut acc = VPARAM | xps + r * nv;
            for c in 1..nv {
                acc = if rel != 0 {
                    self.vbeat(b, rel, VPARAM | xps + r * nv + c, acc, l0)
                } else {
                    self.vi(b, Inst { op: op, ty: vt, aux: 0, a: acc, b: VPARAM | xps + r * nv + c, c: 0 }, l0)
                };
            }
            if rel != 0 {
                // The extreme lane; the start value is in every lane already.
                let lo = rel == C_SLT || rel == C_ULT || rel == C_OLT;
                let code = (core::OP_SIMD + if is_float(rt) && lo {
                    core::SIMD_REDUCE_MIN_NUM
                } else if is_float(rt) {
                    core::SIMD_REDUCE_MAX_NUM
                } else if lo {
                    core::SIMD_REDUCE_MIN
                } else {
                    core::SIMD_REDUCE_MAX
                } as u32) as u16 | if rel == C_SLT || rel == C_SGT {
                    VOP_SIGNED
                } else {
                    0
                };
                let one = [acc];
                let at = b.pool_list(one[0..1]);
                self.args.push(self.vi(b, Inst { op: O_VOP, ty: rt, aux: code, a: at, b: 1, c: VNONE }, l0));
                continue;
            }
            let r0 = VPARAM | gps + (pv & ~VPARAM) - hb.param_start;
            if self.vone {
                self.args.push(self.vi(b, Inst { op: op, ty: rt, aux: 0, a: r0, b: acc, c: 0 }, l0));
                continue;
            }
            let code = (core::OP_SIMD + if op == O_AND {
                core::SIMD_REDUCE_AND
            } else if op == O_OR {
                core::SIMD_REDUCE_OR
            } else if op == O_XOR {
                core::SIMD_REDUCE_XOR
            } else if op == O_MUL || op == O_FMUL {
                core::SIMD_REDUCE_MUL
            } else {
                core::SIMD_REDUCE_ADD
            } as u32) as u16;
            let one = [acc];
            let at = b.pool_list(one[0..1]);
            let red = self.vi(b, Inst { op: O_VOP, ty: rt, aux: code, a: at, b: 1, c: VNONE }, l0);
            let sum = self.vi(b, Inst { op: op, ty: rt, aux: 0, a: r0, b: red, c: 0 }, l0);
            self.args.push(sum);
        }
        let to_sp2 = b.edge(sp, &self.args);
        // A float min or max of zero: the loop again from the start (`vzr`).
        let mut again = VNONE;
        for q in 0..hb.param_len as u32 {
            let pv = VPARAM | hb.param_start + q;
            if pv == self.viv || !self.vzr[self.red_param(pv) as usize] {
                continue;
            }
            let rt = b.params[(pv & ~VPARAM) as usize];
            let z = self.vi(b, Inst { op: O_FCONST, ty: rt, aux: 0, a: 0, b: 0, c: VNONE }, l0);
            let e = self.vi(b, Inst { op: O_FCMP, ty: T_I8, aux: C_OEQ, a: self.args[q as usize], b: z, c: 0 }, l0);
            again = if again == VNONE {
                e
            } else {
                self.vi(b, Inst { op: O_OR, ty: T_I8, aux: 0, a: again, b: e, c: 0 }, l0)
            };
        }
        if again == VNONE {
            let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_sp2, b: 0, c: 0 }, l0);
        } else {
            self.args.truncate(0);
            for q in 0..hb.param_len as u32 {
                self.args.push(VPARAM | gps + q);
            }
            let from0 = b.edge(sp, &self.args);
            let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: again, b: from0, c: to_sp2 }, l0);
        }
        self.vblock(b, vx, xstart, xq, (1 + nred * nv) as u16, hb.flags, vl);
        // The loop's new preheader.
        let sps = self.vblock_params(b, h);
        let sstart = b.insts.len() as u32;
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.args.push(VPARAM | sps + q);
        }
        let to_h = b.edge(h, &self.args);
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_h, b: 0, c: 0 }, l0);
        self.vblock(b, sp, sstart, sps, hb.param_len, hb.flags, g);
        if self.vtail {
            // The tail block: the vector loop once more at `n - k` while elements are left, else out.
            let tq = b.params.len() as u32;
            b.params.push(qt);
            let tstart = b.insts.len() as u32;
            let rem = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_ULT, a: VPARAM | tq, b: self.vn, c: 0 }, l0);
            let again = [last];
            let to_vl = b.edge(vl, again[0..1]);
            let done = [self.vn];
            let to_vx = b.edge(vx, done[0..1]);
            let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: rem, b: to_vl, c: to_vx }, l0);
            self.vblock(b, sp + 1, tstart, tq, 1, hb.flags, vl);
        }
        // The preheader enters the guard; the loop runs what the vectors leave and vectorizes no more.
        let pe = term(b, p).a;
        b.pool[pe as usize] = g;
        b.blocks.index_mut(h as usize).flags |= BLOCK_NOVEC;
    }

    // ---- Partial unrolling ----

    // The copies of counted loop `h`'s body `u` (`counted`) an unrolled loop runs within `budget`
    // instructions: 4 or 2, 0 when the body does not unroll (its counter steps by other than 1, it calls,
    // whose cost the saved tests do not change, holds inline assembly, or reads the header's test).
    fn unroll_factor(self: &mut Self, b: &Body, h: u32, u: u32, budget: u32) u32 {
        let ub = b.blocks[u as usize];
        let n = ub.len - 1;
        let mut k: u32 = 4;
        while k > 1 && k * n > budget {
            k /= 2;
        }
        let hb = b.blocks[h as usize];
        if k == 1 || !self.steps_by_one(b, h, u, self.viv, (self.viv & ~VPARAM) - hb.param_start) {
            return 0;
        }
        for i in ub.start..ub.start + n {
            let op = b.insts[i as usize].op;
            if op == O_CALL || op == O_CALLIND || op == O_ASM {
                return 0;
            }
        }
        return if self.reads(b, u, hb.start) == 0 {
            k
        } else {
            0
        };
    }

    // Unroll counted loop `h` (preheader `p`, body `u`) by `k`: the preheader enters a guard that runs the
    // iterations a multiple of `k` covers in a loop of `k` copies of the body, each copy's header values
    // the previous one's back edge arguments, then enters the loop with the rest (fewer than `k`), which
    // unrolls and vectorizes no more.
    fn unroll(self: &mut Self, b: &mut Body, h: u32, p: u32, u: u32, k: u32) {
        let hb = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let l0 = b.locs[hb.start as usize];
        let qx = (self.viv & ~VPARAM) - hb.param_start;
        let np = hb.param_len as u32;
        // The block numbers: guard, unrolled loop, the loop's new preheader.
        let g = b.blocks.len() as u32;
        let ul = g + 1;
        let sp = g + 2;
        let iend = self.unroll_guard(b, h, p, k, ul, sp);
        // The unrolled loop: `vmap` holds the header's values for the copy at hand, `imap` the body's.
        let lps = self.vblock_params(b, h);
        let lstart = b.insts.len() as u32;
        self.vmap.truncate(0);
        for q in 0..np {
            self.vmap.push(VPARAM | lps + q);
        }
        fill(&mut self.imap, b.insts.len(), NONE);
        self.pmap.truncate(0);
        let te = term(b, u).a;
        for _ in 0..k {
            for i in ub.start..ub.start + ub.len - 1 {
                self.imap[i as usize] = self.copy_unrolled(b, i, h);
            }
            self.args.truncate(0);
            for q in 0..np {
                self.args.push(self.um(b, h, b.edge_arg(te, q)));
            }
            for q in 0..np {
                self.vmap[q as usize] = self.args[q as usize];
            }
        }
        let more = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: self.vmap[qx as usize], b: iend, c: 0 }, l0);
        let back = b.edge(ul, &self.args);
        let out = b.edge(sp, &self.args);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: more, b: back, c: out }, l0);
        self.vblock(b, ul, lstart, lps, hb.param_len, hb.flags, g);
        self.unroll_exit(b, h, p, sp, g);
    }

    // The guard of a loop `h` (preheader `p`, counter `viv`, bound `vn`) that unrolls by `k`, block
    // `b.blocks.len()`, which `p` enters, of the header's parameters: it enters block `ul` with them when
    // the loop runs `k` iterations or more, else `sp`. The end of the iterations a multiple of `k` covers.
    fn unroll_guard(self: &mut Self, b: &mut Body, h: u32, p: u32, k: u32, ul: u32, sp: u32) Value {
        let hb = b.blocks[h as usize];
        let l0 = b.locs[hb.start as usize];
        let qx = (self.viv & ~VPARAM) - hb.param_start;
        let qt = b.params[(self.viv & ~VPARAM) as usize];
        let np = hb.param_len as u32;
        let g = b.blocks.len() as u32;
        // The iterations the unrolled loop runs, `(n - i0) & -k` when `i0 < n`, and their end.
        let gps = self.vblock_params(b, h);
        let gstart = b.insts.len() as u32;
        let i0 = VPARAM | gps + qx;
        let lt = self.vi(
            b,
            Inst {
                op: O_ICMP,
                ty: T_I8,
                aux: if self.vsigned {
                    C_SLT
                } else {
                    C_ULT
                },
                a: i0,
                b: self.vn,
                c: 0,
            },
            l0,
        );
        let d = self.vi(b, Inst { op: O_SUB, ty: qt, aux: 0, a: self.vn, b: i0, c: 0 }, l0);
        let z = self.vconst(b, qt, 0, l0);
        let trips = self.vi(b, Inst { op: O_SELECT, ty: qt, aux: 0, a: lt, b: d, c: z }, l0);
        let mk = self.vconst(b, qt, ~((k - 1) as u64) & ~0u64 >> (64 - type_bits(qt, 8)) as u64, l0);
        let cnt = self.vi(b, Inst { op: O_AND, ty: qt, aux: 0, a: trips, b: mk, c: 0 }, l0);
        let ok = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: cnt, b: z, c: 0 }, l0);
        let iend = self.vi(b, Inst { op: O_ADD, ty: qt, aux: 0, a: i0, b: cnt, c: 0 }, l0);
        self.args.truncate(0);
        for q in 0..np {
            self.args.push(VPARAM | gps + q);
        }
        let to_ul = b.edge(ul, &self.args);
        let to_sp = b.edge(sp, &self.args);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: ok, b: to_ul, c: to_sp }, l0);
        self.vblock(b, g, gstart, gps, hb.param_len, hb.flags, p);
        return iend;
    }

    // Block `sp` (dominated as guard `g` is), loop `h`'s new preheader, which jumps to it with its
    // parameters; preheader `p` enters the guard. The loop runs what the unrolled one leaves and
    // vectorizes or unrolls no more.
    fn unroll_exit(self: &mut Self, b: &mut Body, h: u32, p: u32, sp: u32, g: u32) {
        let hb = b.blocks[h as usize];
        let l0 = b.locs[hb.start as usize];
        let np = hb.param_len as u32;
        let sps = self.vblock_params(b, h);
        let sstart = b.insts.len() as u32;
        self.args.truncate(0);
        for q in 0..np {
            self.args.push(VPARAM | sps + q);
        }
        let to_h = b.edge(h, &self.args);
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_h, b: 0, c: 0 }, l0);
        self.vblock(b, sp, sstart, sps, hb.param_len, hb.flags, g);
        let pe = term(b, p).a;
        b.pool[pe as usize] = g;
        b.blocks.index_mut(h as usize).flags |= BLOCK_NOVEC;
    }

    // A copy of instruction `i` of loop `h` for the copy at hand (`unrolled`), at the end of the
    // instructions with `i`'s location: its value.
    fn copy_unrolled(self: &mut Self, b: &mut Body, i: u32, h: u32) Value {
        let t = self.unrolled(b, b.insts[i as usize], h);
        let v = b.insts.len() as u32;
        b.insts.push(t);
        let l = b.locs[i as usize];
        b.locs.push(l);
        if b.inl.len() != 0 {
            let s = b.inl[i as usize];
            b.inl.push(s);
        }
        return v;
    }

    // ---- Unroll and jam ----

    // The copies of the loop around innermost loop `h` (latch `u`) that `jam` runs at once, so that the
    // element each iteration stores (4 or 8 bytes, at the outer counter's index) and the values the inner
    // loop computes for it pack into one 16-byte vector per iteration of the jammed inner loop
    // (`lir::slp`); 0 when the loops are not of this shape: an outer header of a counted test that enters
    // a chain of blocks to the inner header, which leaves for a chain of blocks back to the outer header
    // (`jam_chain`); both loops counted and stepping by 1, the inner one's start and bound outside the
    // outer loop (every copy runs it as often); the first chain and the inner loop read the outer
    // header's counter alone of its parameters; the blocks compute without effects or traps but for
    // loads and the second chain's stores, which touch no byte a load of the first chain or of the inner
    // loop reads (`cl`); the copies take at most `budget` instructions. Sets `jb`, `jiv`, the chains
    // (`jblk`, the first `jna` blocks the first one) and the tables to the outer loop.
    fn jam_factor(
        self: &mut Self,
        b: &Body,
        inner: []u32,
        lparent: []u32,
        preh: []u32,
        h: u32,
        u: u32,
        cl: Classes,
        budget: u32,
    ) u32 {
        if !self.counted(b, h, u) || self.vne || self.vrev || self.vexit {
            return 0;
        }
        let iv = self.viv;
        let n2 = self.vn;
        let ib = b.blocks[h as usize];
        let ivx = (iv & ~VPARAM) - ib.param_start;
        if !self.steps_by_one(b, h, u, iv, ivx) {
            return 0;
        }
        let ho = lparent[h as usize];
        if ho == NONE || preh[ho as usize] == NONE || term(b, ho).op != O_BR {
            return 0;
        }
        let to = term(b, ho);
        let th = term(b, h);
        let ex = if b.edge_target(th.b) == u {
            th.c
        } else {
            th.b
        };
        let a = if b.edge_target(to.b) as usize < inner.len() && inner[b.edge_target(to.b) as usize] == ho {
            b.edge_target(to.b)
        } else {
            b.edge_target(to.c)
        };
        self.jblk.truncate(0);
        if !self.jam_chain(b, a, h) {
            return 0;
        }
        self.jna = self.jblk.len() as u32;
        if !self.jam_chain(b, b.edge_target(ex), ho) {
            return 0;
        }
        // The outer loop is its header, the chains and the inner loop.
        let nb = b.blocks.len();
        let mut others: u32 = 0;
        for k in 0..inner.len().min(nb) {
            others += (inner[k] == ho) as u32;
        }
        let mut listed: u32 = 1;
        for x in 0..self.jblk.len() {
            let k = self.jblk[x] as usize;
            if k < inner.len() {
                if inner[k] != ho {
                    return 0;
                }
                listed += 1;
            }
        }
        if others != listed || self.preds(b, h) != 2 {
            return 0;
        }
        for k in 0..nb {
            self.inl[k] = false;
        }
        self.lblocks.truncate(0);
        self.lblocks.push(ho);
        self.lblocks.push(h);
        self.lblocks.push(u);
        for x in 0..self.jblk.len() {
            self.lblocks.push(self.jblk[x]);
        }
        for x in 0..self.lblocks.len() {
            self.inl[self.lblocks[x] as usize] = true;
        }
        let hb = b.blocks[ho as usize];
        let nj = self.jblk.len();
        let na = self.jna as usize;
        let lc = self.jblk[nj - 1];
        if !self.counted_by(b, ho, a, lc) || self.vne || self.vrev || self.vexit || !self.steps_by_one(
            b,
            ho,
            lc,
            self.viv,
            (self.viv & ~VPARAM) - hb.param_start,
        ) || self.defined_in(n2) || self.defined_in(b.edge_arg(term(b, self.jblk[na - 1]).a, ivx)) {
            return 0;
        }
        // The effects, and the outer header's values the first chain and the inner loop read.
        let mut size: u32 = 0;
        for x in 0..nj + 1 {
            let k = if x == nj {
                u
            } else {
                self.jblk[x]
            };
            let late = x >= na && x < nj;
            let bk = b.blocks[k as usize];
            size += bk.len - 1;
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                let mem = (t.op == O_LOAD || t.op == O_STORE && late) && (t.aux & MEM_VOLATILE) == 0;
                if i + 1 < bk.start + bk.len && !mem && !cf_pure(b, t) {
                    return 0;
                }
                if late {
                    continue;
                }
                self.outside_uses(b, t);
                for q in 0..self.uses.len() {
                    let v = self.uses[q];
                    if v != VNONE && (v & VPARAM) != 0 && v != self.viv && self.powner[(v & ~VPARAM) as usize] == ho {
                        return 0;
                    }
                }
            }
        }
        // The second chain's stores, apart from the loads the copies run before them; the element stored at
        // the outer counter's index.
        let mut sz: u32 = 0;
        for x in na..nj {
            let cb = b.blocks[self.jblk[x] as usize];
            for i in cb.start..cb.start + cb.len - 1 {
                let s = b.insts[i as usize];
                if s.op != O_STORE {
                    continue;
                }
                for y in 0..na + 1 {
                    let k = if y == na {
                        u
                    } else {
                        self.jblk[y]
                    };
                    let bk = b.blocks[k as usize];
                    for j in bk.start..bk.start + bk.len - 1 {
                        if b.insts[j as usize].op == O_LOAD && !self.apart(cl, i, j) {
                            return 0;
                        }
                    }
                }
                if (s.a & (VPARAM | VFLAG)) != 0 || !self.defined_in(s.b) {
                    continue;
                }
                let st = b.type_of(s.b);
                let ad = b.insts[s.a as usize];
                let n = type_bytes(st, 8);
                if !is_vec(st) && st != T_I128 && (n == 4 || n == 8) && ad.op == O_PTRADD && ad.b == self.viv && ad.aux == n && !self.defined_in(
                    ad.a,
                ) {
                    sz = n;
                }
            }
        }
        if sz == 0 || VBYTES / sz * size > budget {
            return 0;
        }
        self.jb = [ho, preh[ho as usize], h, u];
        self.jiv = iv;
        return VBYTES / sz;
    }

    // Block `k0` and the blocks after it up to block `end` (not included), onto `jblk`: at most JAM_CHAIN,
    // each entered from the one before alone (`k0` from outside the chain) and ending in a jump to the
    // next. Whether they are such a chain.
    fn jam_chain(self: &mut Self, b: &Body, k0: u32, end: u32) bool {
        let mut k = k0;
        for _ in 0..JAM_CHAIN {
            let t = term(b, k);
            if k == end || t.op != O_JMP || self.preds(b, k) != 1 {
                return false;
            }
            self.jblk.push(k);
            if b.edge_target(t.a) == end {
                return true;
            }
            k = b.edge_target(t.a);
        }
        return false;
    }

    // The edges into block `k`.
    fn preds(self: &mut Self, b: &Body, k: u32) u32 {
        let mut n: u32 = 0;
        for j in 0..b.blocks.len() {
            b.succ_edges(term(b, j as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                n += (b.edge_target(self.edges[e]) == k) as u32;
            }
        }
        return n;
    }

    // Unroll the loop `jam_factor` took by `k` and jam the copies of its inner loop into one: a guard
    // (`unroll_guard`) enters a block of the copies of the first chain, each with its counter's value,
    // which enters one inner loop of the copies' parameters (the counter one, copy 0's) that tests copy
    // 0's counter and runs the copies of its body, then leaves for a block of the copies of the second
    // chain in order, each with the outer header's values the previous one passes back, which enters the
    // first block again or the outer loop's new preheader with the iterations left (`unroll_exit`).
    fn jam(self: &mut Self, b: &mut Body, k: u32) {
        let ho = self.jb[0];
        let p = self.jb[1];
        let h = self.jb[2];
        let u = self.jb[3];
        let na = self.jna as usize;
        let nj = self.jblk.len();
        let hb = b.blocks[ho as usize];
        let ib = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let l0 = b.locs[hb.start as usize];
        let qx = (self.viv & ~VPARAM) - hb.param_start;
        let qt = b.params[(self.viv & ~VPARAM) as usize];
        let np = hb.param_len as u32;
        let ni = ib.param_len as u32;
        let ivx = (self.jiv & ~VPARAM) - ib.param_start;
        let th = term(b, h);
        let ex = if b.edge_target(th.b) == u {
            th.c
        } else {
            th.b
        };
        // The block numbers: guard, first chain's copies, inner header, its body, second chain's copies,
        // the outer loop's new preheader.
        let g = b.blocks.len() as u32;
        let ua = g + 1;
        let fh = g + 2;
        let fb = g + 3;
        let fc = g + 4;
        let sp = g + 5;
        fill(&mut self.imap, b.insts.len(), NONE);
        fill(&mut self.pmap, b.params.len(), NONE);
        let iend = self.unroll_guard(b, ho, p, k, ua, sp);
        // The first chain's copies, and the inner loop's start values.
        let lps = self.vblock_params(b, ho);
        let ustart = b.insts.len() as u32;
        self.vmap.truncate(0);
        for q in 0..np {
            self.vmap.push(VPARAM | lps + q);
        }
        self.jq.truncate(0);
        self.jcopy.truncate(0);
        self.args.truncate(0);
        let q0 = VPARAM | lps + qx;
        for j in 0..k {
            let qj = if j == 0 {
                q0
            } else {
                let cj = self.vconst(b, qt, j, l0);
                self.vi(b, Inst { op: O_ADD, ty: qt, aux: 0, a: q0, b: cj, c: 0 }, l0)
            };
            self.jq.push(qj);
            self.vmap[qx as usize] = qj;
            self.jam_blocks(b, ho, 0, na, NONE, true);
            let te = term(b, self.jblk[na - 1]).a;
            for x in 0..ni {
                self.args.push(self.um(b, ho, b.edge_arg(te, x)));
            }
        }
        let to_fh = b.edge(fh, &self.args);
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_fh, b: 0, c: 0 }, l0);
        self.vblock(b, ua, ustart, lps, hb.param_len, hb.flags, g);
        // The inner header: copy `j`'s parameter `x` is `fps + j * ni + x`; its test copy 0's.
        let fps = b.params.len() as u32;
        for _ in 0..k {
            for x in 0..ni {
                let pt = b.params[(ib.param_start + x) as usize];
                b.params.push(pt);
            }
        }
        self.jam_params(b, h, fps, ni, ivx, 0);
        let fstart = b.insts.len() as u32;
        let cv = self.copy_unrolled(b, ib.start, ho);
        self.imap[ib.start as usize] = cv;
        self.args.truncate(0);
        let to_fb = b.edge(fb, &self.args);
        let to_fc = b.edge(fc, &self.args);
        let (eb, ec) = if b.edge_target(th.b) == u {
            (to_fb, to_fc)
        } else {
            (to_fc, to_fb)
        };
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: cv, b: eb, c: ec }, l0);
        self.vblock(b, fh, fstart, fps, (k * ni) as u16, ib.flags | BLOCK_NOVEC, g);
        // The inner body: each copy with its counter, its copy of the first chain and its parameters.
        let bstart = b.insts.len() as u32;
        self.jargs.truncate(0);
        for j in 0..k {
            self.jam_copy(b, j, k, h, fps, ni, ivx);
            self.vmap[qx as usize] = self.jq[j as usize];
            for i in ub.start..ub.start + ub.len - 1 {
                self.imap[i as usize] = self.copy_unrolled(b, i, ho);
            }
            let te = term(b, u).a;
            for x in 0..ni {
                self.jargs.push(self.um(b, ho, b.edge_arg(te, x)));
            }
        }
        for j in 1..k {
            self.jargs[(j * ni + ivx) as usize] = self.jargs[ivx as usize];
        }
        let back = b.edge(fh, &self.jargs);
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: back, b: 0, c: 0 }, l0);
        self.vblock(b, fb, bstart, b.params.len() as u32, 0, ub.flags, g);
        // The second chain's copies in order, the outer header's values passed from one to the next.
        let cstart = b.insts.len() as u32;
        for q in 0..np {
            self.vmap[q as usize] = VPARAM | lps + q;
        }
        for j in 0..k {
            self.jam_copy(b, j, k, h, fps, ni, ivx);
            self.jam_blocks(b, ho, na, nj, ex, false);
            let te = term(b, self.jblk[nj - 1]).a;
            self.args.truncate(0);
            for q in 0..np {
                self.args.push(self.um(b, ho, b.edge_arg(te, q)));
            }
            for q in 0..np {
                self.vmap[q as usize] = self.args[q as usize];
            }
        }
        let more = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: self.vmap[qx as usize], b: iend, c: 0 }, l0);
        let again = b.edge(ua, &self.args);
        let out = b.edge(sp, &self.args);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: more, b: again, c: out }, l0);
        self.vblock(b, fc, cstart, b.params.len() as u32, 0, b.blocks[self.jblk[nj - 1] as usize].flags, g);
        self.unroll_exit(b, ho, p, sp, g);
    }

    // Copies of chain blocks `jblk[from .. to]` of the loop of header `ho` for the copy at hand, in order:
    // each block's parameters the arguments of the edge into it (`e` for the first), its instructions
    // copied (`copy_unrolled`); with `keep`, each parameter's and instruction's value onto `jcopy`.
    fn jam_blocks(self: &mut Self, b: &mut Body, ho: u32, from: usize, to: usize, e: u32, keep: bool) {
        let mut pe = e;
        for x in from..to {
            let k = self.jblk[x];
            let bk = b.blocks[k as usize];
            for q in 0..bk.param_len as u32 {
                let v = self.um(b, ho, b.edge_arg(pe, q));
                self.pmap[(bk.param_start + q) as usize] = v;
                if keep {
                    self.jcopy.push(v);
                }
            }
            for i in bk.start..bk.start + bk.len - 1 {
                let v = self.copy_unrolled(b, i, ho);
                self.imap[i as usize] = v;
                if keep {
                    self.jcopy.push(v);
                }
            }
            pe = term(b, k).a;
        }
    }

    // The maps for copy `j` of the `k` of `jam`: the inner header's parameters (`fps`, `ni` per copy; the
    // counter `ivx` copy 0's) and the first chain's values (`jcopy`, as `jam_blocks` kept them).
    fn jam_copy(self: &mut Self, b: &Body, j: u32, k: u32, h: u32, fps: u32, ni: u32, ivx: u32) {
        self.jam_params(b, h, fps, ni, ivx, j);
        let mut s = j as usize * self.jcopy.len() / k as usize;
        for x in 0..self.jna as usize {
            let bk = b.blocks[self.jblk[x] as usize];
            for q in 0..bk.param_len as u32 {
                self.pmap[(bk.param_start + q) as usize] = self.jcopy[s];
                s += 1;
            }
            for i in bk.start..bk.start + bk.len - 1 {
                self.imap[i as usize] = self.jcopy[s];
                s += 1;
            }
        }
    }

    // `pmap` of inner header `h`'s parameters for copy `j` of `jam`.
    fn jam_params(self: &mut Self, b: &Body, h: u32, fps: u32, ni: u32, ivx: u32, j: u32) {
        let ps = b.blocks[h as usize].param_start;
        for x in 0..ni {
            self.pmap[(ps + x) as usize] = VPARAM | fps + if x == ivx {
                0u32
            } else {
                j * ni
            } + x;
        }
    }

    // Value `v` of loop `h` in the copy at hand (`unroll`, `linearize`): a header parameter's value
    // (`vmap`), another parameter's (`pmap`, NONE: itself), a body instruction's copy (`imap`), any other
    // as it is.
    fn um(self: &Self, b: &Body, h: u32, v: Value) Value {
        if v == VNONE {
            return v;
        }
        let hb = b.blocks[h as usize];
        if (v & VPARAM) != 0 {
            let x = v & ~VPARAM;
            return if x >= hb.param_start && x < hb.param_start + hb.param_len as u32 {
                self.vmap[(x - hb.param_start) as usize]
            } else if x as usize < self.pmap.len() && self.pmap[x as usize] != NONE {
                self.pmap[x as usize]
            } else {
                v
            };
        }
        let x = v & ~VFLAG;
        return if x as usize < self.imap.len() && self.imap[x as usize] != NONE {
            self.imap[x as usize] | v & VFLAG
        } else {
            v
        };
    }

    // Body instruction `t0` of loop `h` for the copy at hand (`um`): its values the copy's.
    fn unrolled(self: &Self, b: &mut Body, t0: Inst, h: u32) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.um(b, h, t.a);
        }
        if lv::operand_b(f) {
            t.b = self.um(b, h, t.b);
        }
        if lv::operand_c(f) {
            t.c = self.um(b, h, t.c);
        }
        if f == F_VOP {
            let at = b.pool.len() as u32;
            for q in 0..t.b {
                let v = self.um(b, h, b.pool[(t.a + q) as usize]);
                b.pool.push(v);
            }
            t.a = at;
        }
        return t;
    }

    // ---- If-conversion ----

    // Loop `h` (latch `u`, its blocks `lblocks`) whose body branches on `c` at the end of its first block,
    // the two sides joining at `u` (each through its edge, or a block without parameters that jumps there),
    // `u` jumping back: a new block of the body's instructions in order (the first block's, each side's,
    // a select on `c` for each parameter of `u` whose sides' values differ, then `u`'s) that jumps back to
    // `h`, which enters it; the loop's blocks `h` and it. A side runs only what may run in every iteration:
    // pure instructions that cannot trap, and loads of an element the loop reads or writes in every
    // iteration. The block, NONE when the loop is not of this shape; `unlinearize` takes it back,
    // `commit_linear` keeps it.
    fn linearize(self: &mut Self, b: &mut Body, h: u32, u: u32) u32 {
        self.lkeep = false;
        self.lsplit = NONE;
        let th = term(b, h);
        if th.op != O_BR || u == h || term(b, u).op != O_JMP || b.edge_target(term(b, u).a) != h {
            let _ = self.no("its branches are not one test in its body", 0);
            return NONE;
        }
        let ein = if self.inl[b.edge_target(th.b) as usize] {
            th.b
        } else {
            th.c
        };
        let e = b.edge_target(ein);
        let te = term(b, e);
        if e == u || e == h || b.edge_nargs(ein) != 0 || te.op != O_BR {
            let _ = self.no("its body has more than one branch, or exits early", 0);
            return NONE;
        }
        if !self.inl[b.edge_target(te.b) as usize] || !self.inl[b.edge_target(te.c) as usize] {
            return self.linearize_exit(b, h, u, ein, e, te);
        }
        // Each side: its edge into `u` and its block (NONE: none).
        let (ex, ax) = self.lin_side(b, te.b, e, u);
        let (ey, ay) = self.lin_side(b, te.c, e, u);
        if ex == NONE || ey == NONE || ax != NONE && ax == ay {
            let _ = self.no("its branch's sides do not meet again at once", 0);
            return NONE;
        }
        let nl = 3 + (ax != NONE) as usize + (ay != NONE) as usize;
        if self.lblocks.len() != nl {
            let _ = self.no("its body has more than one branch, or exits early", 0);
            return NONE;
        }
        // The instructions: forms the vectorizer reads; on a side, what may run in every iteration.
        let order: [u32; 4] = [e, ax, ay, u];
        for k in 0..4usize {
            let blk = unsafe order[k];
            if blk == NONE {
                continue;
            }
            let bk = b.blocks[blk as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let t = b.insts[i as usize];
                let f = op_info(t.op).form;
                if !(f == F_IMM || f == F_UN || f == F_BIN || f == F_CMP || f == F_TRI || f == F_PTRADD || f == F_LOAD || f == F_STORE) {
                    let _ = self.no("an instruction it does not widen", t.op);
                    return NONE;
                }
                let side = k == 1 || k == 2;
                let store = t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0;
                if side && !store && !(t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 && self.every_iteration(b, e, u, t) || t.op != O_LOAD && cf_pure(
                    b,
                    t,
                )) {
                    let _ = self.no("a conditional side does what it may not do in every iteration", t.op);
                    return NONE;
                }
            }
        }
        // The tests of the header alone that `vplan` makes on the copy (`counted_by`), before the copy.
        if !self.header_counts(b, h) {
            return NONE;
        }
        // Saved for `unlinearize`.
        self.lsave = [b.insts.len() as u32, b.params.len() as u32, b.pool.len() as u32, b.blocks.len() as u32, e, u];
        self.lcs.truncate(0);
        self.lcc.truncate(0);
        self.lcw.truncate(0);
        self.ledge = ein;
        self.lold.truncate(0);
        for k in 0..self.lblocks.len() {
            self.lold.push(self.lblocks[k]);
        }
        let ub = b.blocks[u as usize];
        let nb = b.blocks.len() as u32;
        let hb = b.blocks[h as usize];
        self.vmap.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.vmap.push(VPARAM | hb.param_start + q);
        }
        fill(&mut self.imap, b.insts.len(), NONE);
        fill(&mut self.pmap, b.params.len(), NONE);
        self.lorig.truncate(0);
        let start = b.insts.len() as u32;
        for k in 0..4usize {
            let blk = unsafe order[k];
            if blk == NONE {
                continue;
            }
            if k == 3 {
                // `u`'s parameters: the sides' values, a select where they differ.
                let c = self.um(b, h, te.a);
                for q in 0..ub.param_len as u32 {
                    let x = self.um(b, h, b.edge_arg(ex, q));
                    let y = self.um(b, h, b.edge_arg(ey, q));
                    let mut v = x;
                    if x != y {
                        let ty = b.params[(ub.param_start + q) as usize];
                        v = self.vi(
                            b,
                            Inst { op: O_SELECT, ty: ty, aux: 0, a: c, b: x, c: y },
                            b.locs[(ub.start + ub.len - 1) as usize],
                        );
                        self.lorig.push(NONE);
                    }
                    self.pmap[(ub.param_start + q) as usize] = v;
                }
            }
            let bk = b.blocks[blk as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let t = self.unrolled(b, b.insts[i as usize], h);
                let v = b.insts.len() as u32;
                b.insts.push(t);
                let l = b.locs[i as usize];
                b.locs.push(l);
                if b.inl.len() != 0 {
                    let s = b.inl[i as usize];
                    b.inl.push(s);
                }
                self.imap[i as usize] = v;
                self.lorig.push(i);
                if (k == 1 || k == 2) && t.op == O_STORE {
                    self.lcs.push(v);
                    self.lcc.push(self.um(b, h, te.a));
                    self.lcw.push(k == 1);
                }
            }
        }
        self.args.truncate(0);
        let tu = term(b, u).a;
        for q in 0..b.edge_nargs(tu) {
            self.args.push(self.um(b, h, b.edge_arg(tu, q)));
        }
        let back = b.edge(h, &self.args);
        let _ = self.vi(
            b,
            Inst { op: O_JMP, ty: T_NONE, aux: 0, a: back, b: 0, c: 0 },
            b.locs[(ub.start + ub.len - 1) as usize],
        );
        self.lorig.push(NONE);
        self.vblock(b, nb, start, b.params.len() as u32, 0, ub.flags, e);
        b.pool[ein as usize] = nb;
        for k in 0..self.lold.len() {
            self.inl[self.lold[k] as usize] = false;
        }
        self.inl[h as usize] = true;
        self.inl[nb as usize] = true;
        self.lblocks.truncate(0);
        self.lblocks.push(h);
        self.lblocks.push(nb);
        self.latch = nb;
        return nb;
    }

    // `linearize` of a body whose branch (`te`, ending block `e`, which the header enters by `ein`) leaves
    // the loop on one side and enters latch `u` on the other (through a block or not): one block of `e`'s
    // instructions, the other side's and `u`'s (each one that may run in every iteration), then the
    // branch, out as before or back to the header with `u`'s arguments.
    fn linearize_exit(self: &mut Self, b: &mut Body, h: u32, u: u32, ein: u32, e: u32, te: Inst) u32 {
        let out_b = !self.inl[b.edge_target(te.b) as usize];
        if out_b == !self.inl[b.edge_target(te.c) as usize] {
            let _ = self.no("its body has more than one branch, or exits early", 0);
            return NONE;
        }
        let (es, xs) = if out_b {
            (te.b, te.c)
        } else {
            (te.c, te.b)
        };
        let (ex, ax) = self.lin_side(b, xs, e, u);
        if ex == NONE || self.lblocks.len() != 3 + (ax != NONE) as usize {
            let _ = self.no("its body has more than one branch, or exits early", 0);
            return NONE;
        }
        let order: [u32; 3] = [e, ax, u];
        for k in 0..3usize {
            let blk = unsafe order[k];
            if blk == NONE {
                continue;
            }
            let bk = b.blocks[blk as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let t = b.insts[i as usize];
                let f = op_info(t.op).form;
                let st = k != 0 && f == F_STORE && (t.aux & MEM_VOLATILE) == 0;
                if !(f == F_IMM || f == F_UN || f == F_BIN || f == F_CMP || f == F_TRI || f == F_PTRADD || f == F_LOAD || st) {
                    let _ = self.no("an instruction it does not widen", t.op);
                    return NONE;
                }
                if t.op == O_LOAD && (t.aux & MEM_VOLATILE) != 0 {
                    let _ = self.no("a conditional side does what it may not do in every iteration", t.op);
                    return NONE;
                }
                // Past the exit test: what the scalar loop may do only in an iteration that stays.
                if k != 0 && !(t.op == O_LOAD && self.every_iteration(b, e, e, t) || t.op != O_LOAD && !st && cf_pure(
                    b,
                    t,
                )) {
                    self.lkeep = true;
                }
            }
        }
        if !self.header_counts(b, h) {
            return NONE;
        }
        self.lsave = [b.insts.len() as u32, b.params.len() as u32, b.pool.len() as u32, b.blocks.len() as u32, e, u];
        self.lcs.truncate(0);
        self.lsplit = b.blocks[e as usize].len - 1;
        self.ledge = ein;
        self.lold.truncate(0);
        for k in 0..self.lblocks.len() {
            self.lold.push(self.lblocks[k]);
        }
        let ub = b.blocks[u as usize];
        let nb = b.blocks.len() as u32;
        let hb = b.blocks[h as usize];
        self.vmap.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.vmap.push(VPARAM | hb.param_start + q);
        }
        fill(&mut self.imap, b.insts.len(), NONE);
        fill(&mut self.pmap, b.params.len(), NONE);
        self.lorig.truncate(0);
        let start = b.insts.len() as u32;
        for k in 0..3usize {
            let blk = unsafe order[k];
            if blk == NONE {
                continue;
            }
            if k == 2 {
                for q in 0..ub.param_len as u32 {
                    self.pmap[(ub.param_start + q) as usize] = self.um(b, h, b.edge_arg(ex, q));
                }
            }
            let bk = b.blocks[blk as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let t = self.unrolled(b, b.insts[i as usize], h);
                let v = b.insts.len() as u32;
                b.insts.push(t);
                let l = b.locs[i as usize];
                b.locs.push(l);
                if b.inl.len() != 0 {
                    let s = b.inl[i as usize];
                    b.inl.push(s);
                }
                self.imap[i as usize] = v;
                self.lorig.push(i);
            }
        }
        // The exit edge's arguments, then the back edge's.
        self.args.truncate(0);
        for q in 0..b.edge_nargs(es) {
            self.args.push(self.um(b, h, b.edge_arg(es, q)));
        }
        let leave = b.edge(b.edge_target(es), &self.args);
        self.args.truncate(0);
        let tu = term(b, u).a;
        for q in 0..b.edge_nargs(tu) {
            self.args.push(self.um(b, h, b.edge_arg(tu, q)));
        }
        let back = b.edge(h, &self.args);
        let c = self.um(b, h, te.a);
        let l = b.locs[(ub.start + ub.len - 1) as usize];
        let _ = if out_b {
            self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: c, b: leave, c: back }, l)
        } else {
            self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: c, b: back, c: leave }, l)
        };
        self.lorig.push(NONE);
        self.vblock(b, nb, start, b.params.len() as u32, 0, ub.flags, e);
        b.pool[ein as usize] = nb;
        for k in 0..self.lold.len() {
            self.inl[self.lold[k] as usize] = false;
        }
        self.inl[h as usize] = true;
        self.inl[nb as usize] = true;
        self.lblocks.truncate(0);
        self.lblocks.push(h);
        self.lblocks.push(nb);
        self.latch = nb;
        return nb;
    }

    // Branch edge `s` out of block `e` toward `u` (`linearize`): the edge into `u` and the block between
    // (NONE: none), or (NONE, NONE) when neither the edge enters `u` nor a block of the loop without
    // parameters that only jumps to `u`.
    fn lin_side(self: &Self, b: &Body, s: u32, e: u32, u: u32) (u32, u32) {
        let a = b.edge_target(s);
        if a == u {
            return (s, NONE);
        }
        let t = term(b, a);
        if a == e || !self.inl[a as usize] || b.blocks[a as usize].param_len != 0 || b.edge_nargs(s) != 0 || t.op != O_JMP || b.edge_target(
            t.a,
        ) != u {
            return (NONE, NONE);
        }
        return (t.a, a);
    }

    // Whether the loop (body blocks `e` then `u`) reads or writes in every iteration the element load `t`
    // reads: an access in `e` or `u` through the same address and offset, of the same size.
    fn every_iteration(self: &Self, b: &Body, e: u32, u: u32, t: Inst) bool {
        let n = type_bytes(t.ty, 8);
        let blks: [u32; 2] = [e, u];
        for blk in blks {
            let bk = b.blocks[blk as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                let s = b.insts[i as usize];
                let sz = if s.op == O_LOAD {
                    type_bytes(s.ty, 8)
                } else if s.op == O_STORE {
                    type_bytes(value_type(b, s.b), 8)
                } else {
                    0u32
                };
                if sz == n && s.c == t.c && same_address(b, s.a, t.a) {
                    return true;
                }
            }
        }
        return false;
    }

    // Keep `linearize`'s block: the old latch `u` traps, so it no longer enters the header.
    fn commit_linear(self: &mut Self, b: &mut Body, u: u32) {
        let ub = b.blocks[u as usize];
        b.insts[(ub.start + ub.len - 1) as usize] = Inst {
            op: O_UNREACHABLE,
            ty: T_NONE,
            aux: 0,
            a: VNONE,
            b: VNONE,
            c: VNONE,
        };
        // A block outside the loop that reads a value of the old body (an early exit's target, which the
        // exit's block dominated) reads its copy in the new block, which now dominates it.
        let nb = self.lsave[3];
        for k in 0..nb {
            if contains_u32(&self.lold, k) {
                continue;
            }
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let mut t = b.insts[i as usize];
                let f = op_info(t.op).form;
                if lv::operand_a(f) {
                    t.a = self.lin_map(t.a);
                }
                if lv::operand_b(f) {
                    t.b = self.lin_map(t.b);
                }
                if lv::operand_c(f) {
                    t.c = self.lin_map(t.c);
                }
                b.insts[i as usize] = t;
                if f == F_CALL || f == F_CALLIND {
                    for q in 0..t.aux as u32 {
                        b.pool[(t.c + q) as usize] = self.lin_map(b.pool[(t.c + q) as usize]);
                    }
                } else if f == F_VOP || f == F_ASM {
                    for q in 0..t.b {
                        b.pool[(t.a + q) as usize] = self.lin_map(b.pool[(t.a + q) as usize]);
                    }
                } else if f == F_JMP || f == F_BR || f == F_SWITCH {
                    b.succ_edges(t, &mut self.edges);
                    for x in 0..self.edges.len() {
                        let e = self.edges[x];
                        for q in 0..b.edge_nargs(e) {
                            b.pool[(e + 2 + q) as usize] = self.lin_map(b.edge_arg(e, q));
                        }
                    }
                }
            }
        }
        self.lsave = [0, 0, 0, 0, 0, 0];
    }

    // Value `v` of the old body as `linearize` copied it into the new block (`imap`, `pmap`); any other
    // value as it is.
    fn lin_map(self: &Self, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            let x = v & ~VPARAM;
            return if x as usize < self.pmap.len() && self.pmap[x as usize] != NONE {
                self.pmap[x as usize]
            } else {
                v
            };
        }
        let x = v & ~VFLAG;
        if x as usize >= self.imap.len() || self.imap[x as usize] == NONE {
            return v;
        }
        return self.imap[x as usize] | v & VFLAG;
    }

    // Take back `linearize`: the header enters the branch's body again, the new block and its values go.
    fn unlinearize(self: &mut Self, b: &mut Body) {
        let nb = self.lsave[3];
        b.pool[self.ledge as usize] = self.lsave[4];
        self.latch = self.lsave[5];
        b.insts.truncate(self.lsave[0] as usize);
        b.locs.truncate(self.lsave[0] as usize);
        if b.inl.len() != 0 {
            b.inl.truncate(self.lsave[0] as usize);
        }
        b.params.truncate(self.lsave[1] as usize);
        b.pool.truncate(self.lsave[2] as usize);
        b.blocks.truncate(nb as usize);
        self.owner.truncate(self.lsave[0] as usize);
        self.powner.truncate(self.lsave[1] as usize);
        self.inl.truncate(nb as usize);
        self.proxy.truncate(nb as usize);
        self.lblocks.truncate(0);
        for k in 0..self.lold.len() {
            self.inl[self.lold[k] as usize] = true;
            self.lblocks.push(self.lold[k]);
        }
        self.lorig.truncate(0);
        self.lcs.truncate(0);
        self.lkeep = false;
        self.lsplit = NONE;
        self.lsave = [0, 0, 0, 0, 0, 0];
    }

    // An instruction's original for the alias classes: itself, or for one `linearize` made its source.
    fn orig(self: &Self, i: u32) u32 {
        let base = self.lsave[0];
        return if base != 0 && i >= base && (i - base) as usize < self.lorig.len() && self.lorig[(i - base) as usize] != NONE {
            self.lorig[(i - base) as usize]
        } else {
            i
        };
    }

    // New parameters of header `h`'s types; the first one's number.
    fn vblock_params(self: &mut Self, b: &mut Body, h: u32) u32 {
        let hb = b.blocks[h as usize];
        let ps = b.params.len() as u32;
        for q in 0..hb.param_len as u32 {
            let pt = b.params[(hb.param_start + q) as usize];
            b.params.push(pt);
        }
        return ps;
    }

    // Instruction `t` at the end of the instructions, location `l`: its value.
    fn vi(self: &mut Self, b: &mut Body, t: Inst, l: u32) Value {
        let v = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(l);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        return v;
    }

    // The integer constant `v` of type `ty`.
    fn vconst(self: &mut Self, b: &mut Body, ty: u8, v: u64, l: u32) Value {
        return self.vi(b, Inst { op: O_ICONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE }, l);
    }

    // Block `k`: the instructions from `start` on, `np` parameters from `ps`, flags `fl`, dominated as
    // `dom` is; the tables follow it.
    fn vblock(self: &mut Self, b: &mut Body, k: u32, start: u32, ps: u32, np: u16, fl: u16, dom: u32) {
        assert(b.blocks.len() as u32 == k, "loops: a vector block out of order");
        let n = b.insts.len() as u32 - start;
        b.blocks.push(Block { start: start, len: n, param_start: ps, param_len: np, flags: fl });
        for _ in 0..n {
            self.owner.push(k);
        }
        for _ in 0..np {
            self.powner.push(k);
        }
        self.inl.push(false);
        self.proxy.push(self.proxy[dom as usize]);
    }

    // The range of access `i` over the loop's iterations from `i0`: its first byte and the byte past its
    // last, through the same base, index and offset as the access.
    fn vrange(self: &mut Self, b: &mut Body, i: u32, i0: Value, l: u32) (Value, Value) {
        let t = b.insts[i as usize];
        let a = b.insts[t.a as usize];
        let off = (((a.c as i32) as i64 + (t.c as i32) as i64) as i32) as u32;
        if self.vrev {
            // The counter's values `i0` down to 1.
            let o1 = (((off as i32) as i64 + a.aux as i64) as i32) as u32;
            let lo = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: 0, a: a.a, b: VNONE, c: o1 }, l);
            let hi = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: a.aux, a: a.a, b: i0, c: o1 }, l);
            return (lo, hi);
        }
        let lo = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: a.aux, a: a.a, b: i0, c: off }, l);
        let hi = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: a.aux, a: a.a, b: self.vn, c: off }, l);
        return (lo, hi);
    }

    // Copy `c` of strided store `i` of body `u` (`store_groups`): at the group's last store, its stores' lane
    // vectors (`n`, by offset) interleaved into `n` vectors (zips of zips: for 4, the pairs 0 and 2, 1 and 3,
    // then the pairs of those), stored one after the other from the group's lowest offset. The other stores
    // of the group store nothing: the plan keeps every access of their place apart from the loop's others.
    fn store_group(self: &mut Self, b: &mut Body, u: u32, c: u32, i: u32) {
        let t = b.insts[i as usize];
        let ty = value_type(b, t.b);
        let eb = type_bytes(ty, 8);
        let step = self.stride(b, t.a);
        let n = step / eb;
        let mut lo = (t.c as i32) as i64;
        let mut last = i;
        for y in 0..self.vacc.len() {
            let o = b.insts[self.vacc[y] as usize];
            if o.op == O_STORE && o.a == t.a {
                lo = lo.min(o.c as i32);
                last = last.max(self.vacc[y]);
            }
        }
        if last != i {
            return;
        }
        let mut parts = Vector::<Value>::with_capacity(n as usize);
        parts.resize_default(n as usize);
        for y in 0..self.vacc.len() {
            let o = b.insts[self.vacc[y] as usize];
            if o.op == O_STORE && o.a == t.a {
                parts[(((o.c as i32) as i64 - lo) / eb as i64) as usize] = self.vval(b, u, c, o.b);
            }
        }
        let vt = vec_type(ty, self.vlanes);
        let l = b.locs[i as usize];
        // Each round zips part k with part k + n/2 of the parts in order: twice for 4, once for 2.
        let mut r: u32 = n;
        while r > 1 {
            let mut next = Vector::<Value>::with_capacity(n as usize);
            next.resize_default(n as usize);
            let hf = n / 2;
            for k in 0..hf {
                next[(2 * k) as usize] = self.vi(
                    b,
                    Inst { op: O_VZIPLO, ty: vt, aux: 0, a: parts[k as usize], b: parts[(k + hf) as usize], c: VNONE },
                    l,
                );
                next[(2 * k + 1) as usize] = self.vi(
                    b,
                    Inst { op: O_VZIPHI, ty: vt, aux: 0, a: parts[k as usize], b: parts[(k + hf) as usize], c: VNONE },
                    l,
                );
            }
            parts = next;
            r /= 2;
        }
        let a = self.vval(b, u, c, t.a);
        let base = lo + (c * self.vlanes * step) as i64;
        for k in 0..n {
            let off = ((base + (k * self.vlanes * eb) as i64) as i32) as u32;
            let _ = self.vi(b, Inst { op: O_STORE, ty: T_NONE, aux: t.aux, a: a, b: parts[k as usize], c: off }, l);
        }
    }

    // The vector loop's early exit test, ending block `vl` (from `lstart`; its parameters from `vps`, the
    // counter `vi`): when a lane of any copy would leave, the exit block `vx` hands this iteration's lanes to
    // the loop (the counter and the accumulators as this iteration found them); else latch block `lb`,
    // which starts at the returned instruction. Before the instructions past the test (`lsplit`), which run
    // only when no lane leaves.
    fn vexit_test(
        self: &mut Self,
        b: &mut Body,
        ub: Block,
        nv: u32,
        vps: u32,
        vi: Value,
        vx: u32,
        lb: u32,
        lstart: u32,
        fl: u16,
        vp: u32,
        l0: u32,
    ) u32 {
        let nred = self.vred.len() as u32;
        let vl = lb - 1;
        let x = self.vxc - ub.start;
        let mut m = self.vmap[x as usize];
        let mt = value_type(b, m);
        for c in 1..nv {
            m = self.vi(
                b,
                Inst {
                    op: ast::pick(self.vxs, O_AND, O_OR),
                    ty: mt,
                    aux: 0,
                    a: m,
                    b: self.vmap[(c * ub.len + x) as usize],
                    c: 0,
                },
                l0,
            );
        }
        // While the condition holds in every lane (`vxs`), or in none.
        let lt2 = lane_type(mt);
        let rc = (core::OP_SIMD + ast::pick(self.vxs, core::SIMD_REDUCE_AND, core::SIMD_REDUCE_OR) as u32) as u16;
        let one = [m];
        let at = b.pool_list(one[0..1]);
        let r = self.vi(b, Inst { op: O_VOP, ty: lt2, aux: rc, a: at, b: 1, c: VNONE }, l0);
        let want = self.vconst(b, lt2, ast::pick(self.vxs, mask_of(type_bits(lt2, 8)), 0u64), l0);
        let stay = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_EQ, a: r, b: want, c: 0 }, l0);
        self.args.truncate(0);
        self.args.push(vi);
        for r2 in 0..nred {
            for c in 0..nv {
                self.args.push(VPARAM | vps + 1 + r2 * nv + c);
            }
        }
        let leave = b.edge(vx, &self.args);
        let none2: []Value = [];
        let on = b.edge(lb, none2);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: stay, b: on, c: leave }, l0);
        let ls = b.insts.len() as u32;
        self.vblock(b, vl, lstart, vps, (1 + nred * nv) as u16, fl | BLOCK_NOVEC, vp);
        return ls;
    }

    // Copy `c` of gathered load or scattered store `t` of body `u`, lane by lane in order: each lane's
    // index out of the index vector, its address, then a scalar load into its lane (the first a splat), or
    // the value's lane stored.
    fn vgather(self: &mut Self, b: &mut Body, u: u32, c: u32, t: Inst, l: u32) Value {
        let ga = b.insts[t.a as usize];
        let iv = self.vval(b, u, c, ga.b);
        let it = value_type(b, ga.b);
        let xv = if t.op == O_STORE {
            self.vval(b, u, c, t.b)
        } else {
            VNONE
        };
        let st = if t.op == O_STORE {
            value_type(b, t.b)
        } else {
            t.ty
        };
        let vt = vec_type(st, self.vlanes);
        let mut v = VNONE;
        for k in 0..self.vlanes {
            let ik = self.vi(b, Inst { op: O_VEXTRACT, ty: it, aux: k as u16, a: iv, b: VNONE, c: VNONE }, l);
            let ak = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: ga.aux, a: ga.a, b: ik, c: ga.c }, l);
            if t.op == O_STORE {
                let xk = self.vi(b, Inst { op: O_VEXTRACT, ty: st, aux: k as u16, a: xv, b: VNONE, c: VNONE }, l);
                let _ = self.vi(b, Inst { op: O_STORE, ty: T_NONE, aux: t.aux, a: ak, b: xk, c: t.c }, l);
                continue;
            }
            let xk = self.vi(b, Inst { op: O_LOAD, ty: t.ty, aux: t.aux, a: ak, b: VNONE, c: t.c }, l);
            v = if k == 0 {
                self.vi(b, Inst { op: O_SPLAT, ty: vt, aux: 0, a: xk, b: VNONE, c: VNONE }, l)
            } else {
                self.vi(b, Inst { op: O_VINSERT, ty: vt, aux: k as u16, a: v, b: xk, c: VNONE }, l)
            };
        }
        return v;
    }

    // Copy `c` of truncation `t` of the counter, in the vector loop whose counter is `vi`: the truncated
    // counter in every lane plus the lane's iteration, `c * vlanes` up.
    fn vector_ind(self: &mut Self, b: &mut Body, t: Inst, vi: Value, c: u32, l: u32) Value {
        let vt = vec_type(t.ty, self.vlanes);
        let s = self.vi(b, Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: vi, b: VNONE, c: VNONE }, l);
        let sv = self.vi(b, Inst { op: O_SPLAT, ty: vt, aux: 0, a: s, b: VNONE, c: VNONE }, l);
        let lb = type_bits(t.ty, 8);
        let nw = (self.vlanes * lb + 63) / 64;
        let w = b.words.len() as u32;
        for _ in 0..nw {
            b.words.push(0);
        }
        for k in 0..self.vlanes {
            let mut v = (c * self.vlanes + k) as u64;
            if lb < 64 {
                v &= (1u64 << lb as u64) - 1;
            }
            let bit = (k * lb) as u64;
            let at = (w as u64 + bit / 64) as usize;
            b.words[at] = b.words[at] | v << bit % 64;
        }
        let ks = self.vi(b, Inst { op: O_WCONST, ty: vt, aux: 0, a: w, b: nw, c: VNONE }, l);
        return self.vi(b, Inst { op: O_ADD, ty: vt, aux: 0, a: sv, b: ks, c: VNONE }, l);
    }

    // Vector conversion `t` as steps the targets have (`vconv_ok`): an integer to 4 times its width or a
    // quarter through twice or half; a narrower integer to a float extended to the float's width (by its
    // sign, or zeros for `uitofp`), then converted as signed, which the extended value fits.
    fn vconv(self: &mut Self, b: &mut Body, t: Inst, l: u32) Value {
        let ft = value_type(b, t.a);
        let fl = lane_type(ft);
        let tl = lane_type(t.ty);
        let fb = type_bytes(fl, 8);
        let tb = type_bytes(tl, 8);
        let n = lanes(t.ty);
        let mut v = t.a;
        if (t.op == O_SITOFP || t.op == O_UITOFP) && fb < tb {
            let it = int_of_bytes(tb);
            let e = Inst {
                op: ast::pick(t.op == O_SITOFP, O_SEXT, O_ZEXT),
                ty: vec_type(it, n),
                aux: 0,
                a: v,
                b: VNONE,
                c: VNONE,
            };
            v = self.vconv(b, e, l);
            return self.vi(b, Inst { op: O_SITOFP, ty: t.ty, aux: t.aux, a: v, b: VNONE, c: VNONE }, l);
        }
        if (t.op == O_SEXT || t.op == O_ZEXT) && tb == 4 * fb || t.op == O_TRUNC && fb == 4 * tb {
            let mt = vec_type(int_of_bytes(ast::pick(t.op == O_TRUNC, tb, fb) * 2), n);
            v = self.vi(b, Inst { op: t.op, ty: mt, aux: 0, a: v, b: VNONE, c: VNONE }, l);
        }
        return self.vi(b, Inst { op: t.op, ty: t.ty, aux: t.aux, a: v, b: VNONE, c: VNONE }, l);
    }

    // Mask `m` as one of type `want`: itself, or its lanes extended or truncated to the other width (every
    // lane all ones or 0 either way).
    fn vmask(self: &mut Self, b: &mut Body, m: Value, want: u8, l: u32) Value {
        let mt = value_type(b, m);
        if mt == want {
            return m;
        }
        let op = if type_bytes(lane_type(want), 8) > type_bytes(lane_type(mt), 8) {
            O_SEXT
        } else {
            O_TRUNC
        };
        return self.vi(b, Inst { op: op, ty: want, aux: 0, a: m, b: VNONE, c: VNONE }, l);
    }

    // The lanes of vector `x` where `x REL m` holds (`vrel`), else those of `m`: a min or max step.
    fn vbeat(self: &mut Self, b: &mut Body, rel: u16, x: Value, m: Value, l: u32) Value {
        let vt = value_type(b, x);
        let mk = self.vi(b, Inst { op: O_VCMP, ty: mask_type(vt), aux: rel, a: x, b: m, c: 0 }, l);
        return self.vi(b, Inst { op: O_VSEL, ty: vt, aux: 0, a: mk, b: x, c: m }, l);
    }

    // The splat of value `v` of body `u` when the loop does not define it (a constant as a wide constant,
    // else `splat`), recorded in `vinv`/`vspl` once.
    fn vsplat(self: &mut Self, b: &mut Body, u: u32, v: Value, l: u32) {
        if v == VNONE || self.in_body(b, u, v) || contains(&self.vinv, v) || self.vone && v == self.viv {
            return;
        }
        if self.vone {
            self.vinv.push(v);
            self.vspl.push(v);
            return;
        }
        let ty = value_type(b, v);
        let vt = vec_type(ty, self.vlanes);
        let mut sv = VNONE;
        if (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_ICONST || b.insts[v as usize].op == O_FCONST) {
            let t = b.insts[v as usize];
            sv = self.vsplat_const(b, vt, t.a as u64 | t.b as u64 << 32, l);
        } else {
            sv = self.vi(b, Inst { op: O_SPLAT, ty: vt, aux: 0, a: v, b: VNONE, c: VNONE }, l);
        }
        self.vinv.push(v);
        self.vspl.push(sv);
    }

    // The type of a copy of a value of scalar type `t`: its vector, or itself for scalar copies.
    const fn lane_ty(self: &Self, t: u8) u8 {
        return if self.vone {
            t
        } else {
            vec_type(t, self.vlanes)
        };
    }

    // Vector type `vt` with every lane the low bits of `x`, as a wide constant (scalar copies: `x` as a
    // constant of the scalar type `vt`).
    fn vsplat_const(self: &mut Self, b: &mut Body, vt: u8, x: u64, l: u32) Value {
        if !is_vec(vt) {
            let op = if is_float(vt) {
                O_FCONST
            } else {
                O_ICONST
            };
            let v = x & if type_bits(vt, 8) >= 64 {
                ~0u64
            } else {
                (1u64 << type_bits(vt, 8) as u64) - 1
            };
            return self.vi(b, Inst { op: op, ty: vt, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE }, l);
        }
        let lb = type_bits(lane_type(vt), 8);
        let n = lanes(vt);
        let nw = (n * lb + 63) / 64;
        let w = b.words.len() as u32;
        for _ in 0..nw {
            b.words.push(0);
        }
        let mut lv = x;
        if lb < 64 {
            lv &= (1u64 << lb as u64) - 1;
        }
        for k in 0..n {
            let bit = (k * lb) as u64;
            let at = (w as u64 + bit / 64) as usize;
            b.words[at] = b.words[at] | lv << bit % 64;
        }
        return self.vi(b, Inst { op: O_WCONST, ty: vt, aux: 0, a: w, b: nw, c: VNONE }, l);
    }

    // The identity of reduction operation `op` on lanes of type `ty`: its bits.
    fn identity(self: &Self, b: &Body, op: u8, ty: u8) u64 {
        let _ = b;
        if op == O_AND {
            return 0xFFFFFFFFFFFFFFFF;
        }
        if op == O_FADD {
            // -0.0: x + -0.0 is x for every x, -0.0 included.
            return if ty == T_F32 {
                0x80000000u64
            } else {
                0x8000000000000000u64
            };
        }
        if op == O_MUL {
            return 1;
        }
        if op == O_FMUL {
            return if ty == T_F32 {
                0x3F800000u64
            } else {
                0x3FF0000000000000u64
            };
        }
        return 0;
    }

    // Value `v` of body `u` in interleaved copy `c` of the vector loop: a lane value's copy, else its
    // splat.
    fn vval(self: &Self, b: &Body, u: u32, c: u32, v: Value) Value {
        if self.vone && v == self.viv {
            return self.vqc[c as usize];
        }
        if self.in_body(b, u, v) {
            let ub = b.blocks[u as usize];
            return self.vmap[(c * ub.len + v - ub.start) as usize];
        }
        for k in 0..self.vinv.len() {
            if self.vinv[k] == v {
                return self.vspl[k];
            }
        }
        // Scalar copies read a value from before the loop as it is.
        if self.vone && !self.defined_in(v) {
            return v;
        }
        assert(false, "loops: a vector operand without a splat");
        return VNONE;
    }

    // The index in `lcs` of store `i`, NONE when it stores in every iteration.
    fn cond_store(self: &Self, i: u32) u32 {
        for x in 0..self.lcs.len() {
            if self.lcs[x] == i {
                return x as u32;
            }
        }
        return NONE;
    }

    // The reduction whose update is instruction `i`.
    fn red_of(self: &Self, i: u32) u32 {
        for r in 0..self.vrup.len() {
            if self.vrup[r] == i {
                return r as u32;
            }
        }
        assert(false, "loops: no reduction for the update");
        return 0;
    }

    // For header parameter `pv` of body `u` whose back edge passes select `a`: a min or max reduction when the
    // select takes a lane value `x` or `pv` on a comparison of the two that only it reads (an integer one,
    // or an ordered float one that takes `x` when it holds, with no signed zeros in `fmath`: the lanes keep
    // their own extreme, which reorders the comparisons of equal values). The condition under which `x`
    // replaces `pv` (`vrel`), NONE16 when it is not one.
    fn minmax(self: &mut Self, b: &Body, ptr: u32, fmath: u8, u: u32, pv: Value, a: u32) u16 {
        let s = b.insts[a as usize];
        let ty = s.ty;
        if !(is_int(ty) && ty != T_I128 || is_float(ty) && (fmath & FM_NSZ) != 0) || !self.lane_size(ty, ptr) || !self.in_body(
            b,
            u,
            s.a,
        ) {
            return NONE16;
        }
        let c = b.insts[s.a as usize];
        let x = if s.b == pv {
            s.c
        } else {
            s.b
        };
        if s.b != pv && s.c != pv || x == pv || c.op != O_ICMP && c.op != O_FCMP || !(c.a == x && c.b == pv || c.a == pv && c.b == x) {
            return NONE16;
        }
        if self.reads(b, u, pv) != 2 || self.reads(b, u, a) != 1 || self.reads(b, u, s.a) != 1 {
            return NONE16;
        }
        // The condition as `x REL pv` when the select takes `x`.
        let mut rel = c.aux;
        if c.a == pv && c.op == O_FCMP && rel >= C_OLT && rel <= C_OGE {
            // `<` and `>`, `<=` and `>=`.
            rel ^= 2;
        } else if c.a == pv {
            rel = mirror(rel);
        }
        if s.b == pv {
            if c.op == O_FCMP {
                return NONE16;
            }
            rel = opposite(rel);
        }
        let less = rel == C_SLT || rel == C_SLE || rel == C_ULT || rel == C_ULE || rel == C_OLT || rel == C_OLE;
        let more = rel == C_SGT || rel == C_SGE || rel == C_UGT || rel == C_UGE || rel == C_OGT || rel == C_OGE;
        if !less && !more {
            return NONE16;
        }
        // Strict: an equal value replaces nothing.
        return if rel == C_SLE {
            C_SLT
        } else if rel == C_ULE {
            C_ULT
        } else if rel == C_OLE {
            C_OLT
        } else if rel == C_SGE {
            C_SGT
        } else if rel == C_UGE {
            C_UGT
        } else if rel == C_OGE {
            C_OGT
        } else {
            rel
        };
    }

    // The reduction of header parameter `pv`.
    fn red_param(self: &Self, pv: Value) u32 {
        for r in 0..self.vred.len() {
            if self.vred[r] == pv {
                return r as u32;
            }
        }
        assert(false, "loops: a header parameter that is no reduction");
        return 0;
    }

    // ---- Rotation ----

    // The block loop `h` (its blocks in `lblocks`, latch `latch`) runs its body from, when the loop
    // rotates: the header holds at most `max` instructions and ends in a branch whose one side enters
    // that block, which the header alone enters, and whose other side leaves the loop. NONE when not.
    fn rotatable(self: &mut Self, b: &Body, h: u32, max: u32) u32 {
        let hb = b.blocks[h as usize];
        let t = term(b, h);
        if t.op != O_BR || hb.len - 1 > max {
            return NONE;
        }
        let x = b.edge_target(t.b);
        let y = b.edge_target(t.c);
        if self.inl[x as usize] == self.inl[y as usize] {
            return NONE;
        }
        let body = if self.inl[x as usize] {
            x
        } else {
            y
        };
        if body == h {
            return NONE;
        }
        // The header's edge is the only one into the body.
        let mut n: u32 = 0;
        for k in 0..b.blocks.len() {
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                n += (b.edge_target(self.edges[e]) == body) as u32;
            }
        }
        return if n == 1 {
            body
        } else {
            NONE
        };
    }

    // Rotate loop `h` (closed: its values leave through edges) whose body starts at block `body`: the
    // body takes the header's values it uses as new parameters, the header passes them, and a copy of the
    // header that passes its own copies of them takes the latch's back edge.
    fn rotate_loop(self: &mut Self, b: &mut Body, h: u32, body: u32) {
        let hb = b.blocks[h as usize];
        // The header's values the other loop blocks use, in first-use order.
        self.hvals.truncate(0);
        fill(&mut self.hp, hb.param_len as usize, NONE);
        fill(&mut self.hi, hb.len as usize, NONE);
        fill(&mut self.hf, hb.len as usize, NONE);
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            if k == h {
                continue;
            }
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                self.outside_uses(b, b.insts[i as usize]);
                for q in 0..self.uses.len() {
                    let v = self.uses[q];
                    if self.of_header(b, h, v) && self.hix(b, h, v) == NONE {
                        self.set_hix(b, h, v, self.hvals.len() as u32);
                        self.hvals.push(v);
                    }
                }
            }
        }
        // The body's parameters: its own, then the header's values.
        let bb = b.blocks[body as usize];
        self.bold = bb.param_start;
        self.blen = bb.param_len;
        self.bnew = b.params.len() as u32;
        for q in 0..bb.param_len as u32 {
            let pt = b.params[(bb.param_start + q) as usize];
            b.params.push(pt);
        }
        for j in 0..self.hvals.len() {
            let ty = value_type(b, self.hvals[j]);
            b.params.push(ty);
        }
        let nbp = self.blen + self.hvals.len() as u32;
        b.blocks.index_mut(body as usize).param_start = self.bnew;
        b.blocks.index_mut(body as usize).param_len = nbp as u16;
        for _ in 0..nbp {
            self.powner.push(body);
        }
        // The other loop blocks read them.
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            if k == h {
                continue;
            }
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let t = self.renamed(b, b.insts[i as usize], h);
                b.insts[i as usize] = t;
            }
        }
        // The header's copy: its parameters, instructions and branch, the copy's values.
        let copy = b.blocks.len() as u32;
        self.cps = b.params.len() as u32;
        self.cis = b.insts.len() as u32;
        for q in 0..hb.param_len as u32 {
            let pt = b.params[(hb.param_start + q) as usize];
            b.params.push(pt);
        }
        for i in hb.start..hb.start + hb.len {
            let t0 = b.insts[i as usize];
            let t = self.header_copy(b, t0, h, body, true);
            b.insts.push(t);
            let l = b.locs[i as usize];
            b.locs.push(l);
            if b.inl.len() != 0 {
                let s = b.inl[i as usize];
                b.inl.push(s);
            }
        }
        b.blocks.push(
            Block { start: self.cis, len: hb.len, param_start: self.cps, param_len: hb.param_len, flags: hb.flags },
        );
        for _ in 0..hb.len {
            self.owner.push(copy);
        }
        for _ in 0..hb.param_len {
            self.powner.push(copy);
        }
        self.inl.push(false);
        self.proxy.push(self.proxy[self.latch as usize]);
        // The header passes its own values into the body.
        let ht = b.insts[(hb.start + hb.len - 1) as usize];
        let nt = self.header_copy(b, ht, h, body, false);
        b.insts[(hb.start + hb.len - 1) as usize] = nt;
        // The latch's back edge enters the copy.
        b.succ_edges(term(b, self.latch), &mut self.edges);
        for e in 0..self.edges.len() {
            if b.edge_target(self.edges[e]) == h {
                b.pool[self.edges[e] as usize] = copy;
            }
        }
    }

    // Whether `v` is a parameter, instruction or flag of header `h`.
    fn of_header(self: &Self, b: &Body, h: u32, v: Value) bool {
        let hb = b.blocks[h as usize];
        if v == VNONE {
            return false;
        }
        if (v & VPARAM) != 0 {
            let q = v & ~VPARAM;
            return q >= hb.param_start && q < hb.param_start + hb.param_len as u32;
        }
        let i = v & ~VFLAG;
        return i >= hb.start && i < hb.start + hb.len;
    }

    // The index of header `h`'s value `v` in `hvals` (NONE: none).
    fn hix(self: &Self, b: &Body, h: u32, v: Value) u32 {
        let hb = b.blocks[h as usize];
        if (v & VPARAM) != 0 {
            return self.hp[((v & ~VPARAM) - hb.param_start) as usize];
        }
        if (v & VFLAG) != 0 {
            return self.hf[((v & ~VFLAG) - hb.start) as usize];
        }
        return self.hi[(v - hb.start) as usize];
    }

    fn set_hix(self: &mut Self, b: &Body, h: u32, v: Value, x: u32) {
        let hb = b.blocks[h as usize];
        if (v & VPARAM) != 0 {
            self.hp[((v & ~VPARAM) - hb.param_start) as usize] = x;
        } else if (v & VFLAG) != 0 {
            self.hf[((v & ~VFLAG) - hb.start) as usize] = x;
        } else {
            self.hi[(v - hb.start) as usize] = x;
        }
    }

    // `v` as the loop's blocks past header `h` read it after rotation: a body parameter's new number, a
    // header value's body parameter.
    fn rn(self: &Self, b: &Body, h: u32, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            let q = v & ~VPARAM;
            if q >= self.bold && q < self.bold + self.blen {
                return VPARAM | self.bnew + q - self.bold;
            }
        }
        if self.of_header(b, h, v) {
            return VPARAM | self.bnew + self.blen + self.hix(b, h, v);
        }
        return v;
    }

    // `v` of header `h` in the header's copy (`cps`, `cis`); any other as it is.
    fn hc(self: &Self, b: &Body, h: u32, v: Value) Value {
        if !self.of_header(b, h, v) {
            return v;
        }
        let hb = b.blocks[h as usize];
        if (v & VPARAM) != 0 {
            return VPARAM | self.cps + (v & ~VPARAM) - hb.param_start;
        }
        return self.cis + (v & ~VFLAG) - hb.start | v & VFLAG;
    }

    // Instruction `t0` of a loop block past header `h`, its values `rn`'s: operands, value lists and
    // edges' arguments, the lists and edges new when one changes.
    fn renamed(self: &mut Self, b: &mut Body, t0: Inst, h: u32) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.rn(b, h, t.a);
        }
        if lv::operand_b(f) {
            t.b = self.rn(b, h, t.b);
        }
        if lv::operand_c(f) {
            t.c = self.rn(b, h, t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            t.c = self.renamed_list(b, t.c, t.aux, h);
        } else if f == F_VOP || f == F_ASM {
            t.a = self.renamed_list(b, t.a, t.b, h);
        } else if f == F_JMP {
            t.a = self.renamed_edge(b, t.a, h);
        } else if f == F_BR {
            t.b = self.renamed_edge(b, t.b, h);
            t.c = self.renamed_edge(b, t.c, h);
        } else if f == F_SWITCH {
            let at = b.pool.len() as u32;
            for _ in 0..t.aux as u32 + 1 {
                b.pool.push(0);
            }
            for k in 0..t.aux as u32 + 1 {
                let e0 = b.pool[(t.c + k) as usize];
                let e = self.renamed_edge(b, e0, h);
                b.pool[(at + k) as usize] = e;
            }
            t.c = at;
        }
        return t;
    }

    fn renamed_list(self: &Self, b: &mut Body, at: u32, n: u32, h: u32) u32 {
        let mut any = false;
        for q in 0..n {
            let v = b.pool[(at + q) as usize];
            any = any || self.rn(b, h, v) != v;
        }
        if !any {
            return at;
        }
        let out = b.pool.len() as u32;
        for q in 0..n {
            let v = self.rn(b, h, b.pool[(at + q) as usize]);
            b.pool.push(v);
        }
        return out;
    }

    fn renamed_edge(self: &mut Self, b: &mut Body, e: u32, h: u32) u32 {
        let mut any = false;
        for q in 0..b.edge_nargs(e) {
            let v = b.edge_arg(e, q);
            any = any || self.rn(b, h, v) != v;
        }
        if !any {
            return e;
        }
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            let v = self.rn(b, h, b.edge_arg(e, q));
            self.args.push(v);
        }
        return b.edge(b.edge_target(e), &self.args);
    }

    // Instruction `t0` of header `h` for its copy (`copy`: its values the copy's) or for the header itself;
    // a branch's edge into `body` adds the header values the body takes (`hvals`), in the copy the copy's.
    fn header_copy(self: &mut Self, b: &mut Body, t0: Inst, h: u32, body: u32, copy: bool) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if copy {
            if lv::operand_a(f) {
                t.a = self.hc(b, h, t.a);
            }
            if lv::operand_b(f) {
                t.b = self.hc(b, h, t.b);
            }
            if lv::operand_c(f) {
                t.c = self.hc(b, h, t.c);
            }
            if f == F_CALL || f == F_CALLIND {
                t.c = self.header_list(b, t.c, t.aux, h);
            } else if f == F_VOP || f == F_ASM {
                t.a = self.header_list(b, t.a, t.b, h);
            }
        }
        if f == F_BR {
            t.b = self.header_edge(b, t.b, h, body, copy);
            t.c = self.header_edge(b, t.c, h, body, copy);
        }
        return t;
    }

    fn header_list(self: &Self, b: &mut Body, at: u32, n: u32, h: u32) u32 {
        let out = b.pool.len() as u32;
        for q in 0..n {
            let v = self.hc(b, h, b.pool[(at + q) as usize]);
            b.pool.push(v);
        }
        return out;
    }

    fn header_edge(self: &mut Self, b: &mut Body, e: u32, h: u32, body: u32, copy: bool) u32 {
        let tg = b.edge_target(e);
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            let v = b.edge_arg(e, q);
            self.args.push(
                if copy {
                    self.hc(b, h, v)
                } else {
                    v
                },
            );
        }
        if tg == body {
            for j in 0..self.hvals.len() {
                let v = self.hvals[j];
                self.args.push(
                    if copy {
                        self.hc(b, h, v)
                    } else {
                        v
                    },
                );
            }
        }
        return b.edge(tg, &self.args);
    }

    // The instruction count of loop `h` when it qualifies, else 0; sets `inl` and `lblocks` to its blocks
    // and `latch` to the block of its one back edge. `inner` covers the blocks before the first transform;
    // the blocks after them are in no loop.
    fn shape(self: &mut Self, b: &Body, inner: []u32, h: u32) u32 {
        let nb = b.blocks.len();
        self.lblocks.truncate(0);
        let mut size: u32 = 0;
        for k in 0..nb {
            self.inl[k] = k < inner.len() && inner[k] == h;
            if self.inl[k] {
                self.lblocks.push(k as u32);
                size += b.blocks[k].len;
            }
        }
        let mut backs: u32 = 0;
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            b.succ_edges(term(b, k), &mut self.edges);
            for e in 0..self.edges.len() {
                if b.edge_target(self.edges[e]) == h {
                    self.latch = k;
                    backs += 1;
                }
            }
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                if b.insts[i as usize].op == O_ASM {
                    return 0;
                }
            }
        }
        return if backs == 1 {
            size
        } else {
            0
        };
    }

    // Make the loop's values leave it through edges only: the values the blocks outside it use (`lout`)
    // become parameters of a landing block per exit target that dominates such a use (`dpre`, `dpost`:
    // the dominator tree's numbers, by `proxy`), which that target's edges from the loop enter instead
    // and which jumps on to it; the uses take the parameters of the landing block of the target that
    // dominates them. False, the body unchanged, when a use has no such target, or its target has an edge
    // from outside the loop. `h`: the loop's header.
    fn close(self: &mut Self, b: &mut Body, h: u32, dpre: []u32, dpost: []u32) bool {
        if !self.close_plan(b, h, dpre, dpost) {
            return false;
        }
        self.close_apply(b);
        return true;
    }

    // `close`'s tests, the body unchanged: `lout`, `tgts`, `tgt_of` and `tused` for `close_apply`.
    fn close_plan(self: &mut Self, b: &Body, h: u32, dpre: []u32, dpost: []u32) bool {
        let nb = b.blocks.len();
        self.lout.truncate(0);
        fill(&mut self.tgt_of, nb, NONE);
        fill(&mut self.tused, nb, false);
        let (hpre, hpost) = (dpre[h as usize], dpost[h as usize]);
        for k in 0..nb {
            // A value of the loop has its uses where its definition dominates them: in the blocks the
            // header dominates, or in one the entry does not reach (no dominator numbers, by `proxy`); a
            // block of a transform's with no numbers is read too.
            let x = self.proxy[k] as usize;
            if self.inl[k] || x < dpre.len() && !(hpre <= dpre[x] && dpost[x] <= hpost) && (x == 0 || dpre[x] != 0 || dpost[x] != 0) {
                continue;
            }
            let bk = b.blocks[k];
            let mut uses_out = false;
            for i in bk.start..bk.start + bk.len {
                self.outside_uses(b, b.insts[i as usize]);
                for q in 0..self.uses.len() {
                    let v = self.uses[q];
                    if self.defined_in(v) {
                        uses_out = true;
                        if !contains(&self.lout, v) {
                            if self.lout.len() == MAX_OUT {
                                return false;
                            }
                            self.lout.push(v);
                        }
                    }
                }
            }
            if uses_out {
                self.tgt_of[k] = 0;
            }
        }
        if self.lout.len() == 0 {
            return true;
        }
        // The exit targets.
        self.tgts.truncate(0);
        for j in 0..self.lblocks.len() {
            b.succ_edges(term(b, self.lblocks[j]), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]);
                if !self.inl[s as usize] && !contains(&self.tgts, s) {
                    self.tgts.push(s);
                }
            }
        }
        // Each using block's target: the exit target that dominates it, which only the loop enters.
        for k in 0..nb {
            if self.tgt_of[k] == NONE {
                continue;
            }
            let x = self.proxy[k];
            let mut t = NONE;
            for q in 0..self.tgts.len() {
                let g = self.tgts[q];
                if dpre[g as usize] <= dpre[x as usize] && dpost[x as usize] <= dpost[g as usize] {
                    t = g;
                }
            }
            if t == NONE {
                return false;
            }
            self.tgt_of[k] = t;
            self.tused[t as usize] = true;
        }
        for k in 0..nb {
            if self.inl[k] {
                continue;
            }
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                if self.tused[b.edge_target(self.edges[e]) as usize] {
                    return false;
                }
            }
        }
        return true;
    }

    // `close`'s changes, after `close_plan` held.
    fn close_apply(self: &mut Self, b: &mut Body) {
        if self.lout.len() == 0 {
            return;
        }
        let nb = self.tgt_of.len();
        // A landing block per target in use: the target's parameters, then the values that leave; it
        // jumps on. The loop's exits into the target enter it with the values that leave.
        self.lbase.truncate(0);
        for q in 0..self.tgts.len() {
            let tg = self.tgts[q];
            if !self.tused[tg as usize] {
                self.lbase.push(NONE);
                continue;
            }
            let tb = b.blocks[tg as usize];
            let land = b.blocks.len() as u32;
            let ps = b.params.len() as u32;
            for j in 0..tb.param_len as u32 {
                let pt = b.params[(tb.param_start + j) as usize];
                b.params.push(pt);
            }
            for j in 0..self.lout.len() {
                let ty = value_type(b, self.lout[j]);
                b.params.push(ty);
            }
            self.args.truncate(0);
            for j in 0..tb.param_len as u32 {
                self.args.push(VPARAM | ps + j);
            }
            let e = b.edge(tg, &self.args);
            let start = b.insts.len() as u32;
            b.insts.push(Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 });
            let l0 = b.locs[tb.start as usize];
            b.locs.push(l0);
            if b.inl.len() != 0 {
                b.inl.push(0);
            }
            let npar = tb.param_len + self.lout.len() as u16;
            b.blocks.push(Block { start: start, len: 1, param_start: ps, param_len: npar, flags: tb.flags });
            self.owner.push(land);
            for _ in 0..npar {
                self.powner.push(land);
            }
            self.inl.push(false);
            self.proxy.push(tg);
            self.lbase.push(ps + tb.param_len as u32);
            for j in 0..self.lblocks.len() {
                let bk = b.blocks[self.lblocks[j] as usize];
                let i = bk.start + bk.len - 1;
                let t = self.land_edges(b, b.insts[i as usize], tg, land);
                b.insts[i as usize] = t;
            }
        }
        // The uses outside the loop take their landing block's parameters.
        for k in 0..nb {
            if self.tgt_of[k] == NONE {
                continue;
            }
            let mut base = NONE;
            for q in 0..self.tgts.len() {
                if self.tgts[q] == self.tgt_of[k] {
                    base = self.lbase[q];
                }
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = self.relanded(b, b.insts[i as usize], base);
                b.insts[i as usize] = t;
            }
        }
    }

    // Whether loop `h` (preheader `p`, latch `u`) has bounds checks a guard before it proves: branches
    // into a cold block on `x <u len` (or `len >u x`) with `len` defined outside the loop, `x` the header
    // parameter `i` that the header's exit test keeps below `n` (`i <u n`, or `i <s n` with `i` starting at
    // a constant of at least 0 and stepping by 1), or `i << s + c` (a shift or a product by `2^s`, plus or
    // or-ed with a constant `c`, below `2^s` for an `or`), `n` defined outside the loop. A check of `i`
    // holds wherever `n <= len` does; one of `i << s + c` wherever `n <= bound(len)`, with `bound(len)`
    // `((len - c - 1) >> s) + 1` when `len > c`, else 0: then `(n - 1) << s + c` stays below `len` and wraps
    // nowhere. Sets `fixes`, `fside` and the guard's `gx` (the `n`s), `gy` (the `len`s), `gsh` and `goff`.
    // The loop with the checks a guard keeps (`BLOCK_NOVEC`) has none.
    fn checks(self: &mut Self, b: &Body, ptr: u32, h: u32, p: u32, u: u32) bool {
        self.fixes.truncate(0);
        self.fside.truncate(0);
        self.gx.truncate(0);
        self.gy.truncate(0);
        self.gsh.truncate(0);
        self.goff.truncate(0);
        if (b.blocks[h as usize].flags & BLOCK_NOVEC) != 0 {
            return false;
        }
        // The header's exit test: in-loop when `q < n`.
        let t = term(b, h);
        if t.op != O_BR || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return false;
        }
        let ci = b.insts[t.a as usize];
        let in_taken = self.inl[b.edge_target(t.b) as usize];
        if ci.op != O_ICMP || in_taken == self.inl[b.edge_target(t.c) as usize] {
            return false;
        }
        // The comparison read as `q < n` on the in-loop side; `q != n` too, by steps of 1 from at most `n`
        // (`gq`: the guard checks the start).
        let ne = in_taken && ci.aux == C_NE || !in_taken && ci.aux == C_EQ;
        let hb0 = b.blocks[h as usize];
        let pa = (ci.a & VPARAM) != 0 && (ci.a & ~VPARAM) >= hb0.param_start && (ci.a & ~VPARAM) < hb0.param_start + hb0.param_len as u32;
        let pb = (ci.b & VPARAM) != 0 && (ci.b & ~VPARAM) >= hb0.param_start && (ci.b & ~VPARAM) < hb0.param_start + hb0.param_len as u32;
        self.gq = NONE;
        // A counter down by 1 while not 0 (`grev`).
        let za = is_const(b, ci.a) && raw_const(b, ci.a) == 0;
        let zb = is_const(b, ci.b) && raw_const(b, ci.b) == 0;
        let qd = if pa && zb && (in_taken && (ci.aux == C_NE || ci.aux == C_UGT) || !in_taken && (ci.aux == C_EQ || ci.aux == C_ULE)) {
            ci.a
        } else if pb && za && (in_taken && (ci.aux == C_NE || ci.aux == C_ULT) || !in_taken && (ci.aux == C_EQ || ci.aux == C_UGE)) {
            ci.b
        } else {
            VNONE
        };
        self.grev = qd != VNONE && self.steps_down(b, h, u, qd, (qd & ~VPARAM) - hb0.param_start);
        if self.grev {
            self.gq = (qd & ~VPARAM) - hb0.param_start;
        }
        let (q, n, cond) = if self.grev {
            (qd, VNONE, C_ULT)
        } else if ne && pa {
            (ci.a, ci.b, C_ULT)
        } else if ne {
            (ci.b, ci.a, C_ULT)
        } else if in_taken && (ci.aux == C_ULT || ci.aux == C_SLT) {
            (ci.a, ci.b, ci.aux)
        } else if in_taken && (ci.aux == C_UGT || ci.aux == C_SGT) {
            (ci.b, ci.a, ci.aux - C_SGT + C_SLT)
        } else if !in_taken && (ci.aux == C_UGE || ci.aux == C_SGE) {
            (ci.a, ci.b, ci.aux - C_SGE + C_SLT)
        } else if !in_taken && (ci.aux == C_ULE || ci.aux == C_SLE) {
            (ci.b, ci.a, ci.aux - C_SLE + C_SLT)
        } else {
            return false;
        };
        let hb = b.blocks[h as usize];
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return false;
        }
        if !self.grev && (self.defined_in(n) || n == VNONE) {
            return false;
        }
        if ne && !self.grev {
            let qi = (q & ~VPARAM) - hb.param_start;
            if !self.steps_by_one(b, h, u, q, qi) {
                return false;
            }
            self.gq = qi;
        }
        if cond == C_SLT {
            // From a constant of at least 0, by 1: no value below 0, none past `n` wraps.
            let qi = (q & ~VPARAM) - hb.param_start;
            let ty = b.params[(q & ~VPARAM) as usize];
            let init = b.edge_arg(term(b, p).a, qi);
            if !is_const(b, init) {
                return false;
            }
            let iv = b.insts[init as usize].a as u64 | b.insts[init as usize].b as u64 << 32;
            if le::sign_ext(iv, type_bits(ty, ptr)) < 0 || !self.steps_by_one(b, h, u, q, qi) {
                return false;
            }
        }
        // The checks: a branch whose one edge enters a cold block, on `q <u len`.
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            if k == h {
                continue;
            }
            let bt = term(b, k);
            if bt.op != O_BR || (bt.a & (VPARAM | VFLAG)) != 0 || bt.a == VNONE {
                continue;
            }
            let bc = b.insts[bt.a as usize];
            let cold_b = cold(b, b.edge_target(bt.b));
            let cold_c = cold(b, b.edge_target(bt.c));
            if bc.op != O_ICMP || cold_b == cold_c {
                continue;
            }
            // `x <u len` holds on the edge that does not fail, `x` of `q` (counting down, `x` is `q - 1`).
            let (mut sa, oa) = self.affine(b, ptr, bc.a, q);
            let (mut sb, ob) = self.affine(b, ptr, bc.b, q);
            if self.grev {
                sa = ast::pick(self.down_of(b, bc.a, q), 0u8, 0xFFu8);
                sb = ast::pick(self.down_of(b, bc.b, q), 0u8, 0xFFu8);
            }
            let ok = sa != 0xFF && (bc.aux == C_ULT && cold_c || bc.aux == C_UGE && cold_b) || sb != 0xFF && (bc.aux == C_UGT && cold_c || bc.aux == C_ULE && cold_b);
            if !ok {
                continue;
            }
            let on_a = sa != 0xFF && (bc.aux == C_ULT || bc.aux == C_UGE);
            let len = if on_a {
                bc.b
            } else {
                bc.a
            };
            let (sh, off) = if on_a {
                (sa, oa)
            } else {
                (sb, ob)
            };
            if len == VNONE || self.defined_in(len) || value_type(b, len) != value_type(b, ast::pick(self.grev, q, n)) {
                continue;
            }
            if self.fixes.len() == MAX_CHECKS {
                break;
            }
            self.fixes.push(k);
            self.fside.push(
                if cold_c {
                    0u8
                } else {
                    1u8
                },
            );
            let mut seen = false;
            for g in 0..self.gy.len() {
                seen = seen || self.gy[g] == len && self.gsh[g] == sh && self.goff[g] == off;
            }
            if !seen {
                self.gx.push(n);
                self.gy.push(len);
                self.gsh.push(sh);
                self.goff.push(off);
            }
        }
        self.gcond = C_ULE;
        return self.fixes.len() != 0 && !self.guarded(b, p);
    }

    // `x` as `q << s + c` (`checks`): (s, c), (0xFF, 0) when it is not of that form.
    fn affine(self: &Self, b: &Body, ptr: u32, x: Value, q: Value) (u8, u64) {
        if x == q {
            return (0u8, 0u64);
        }
        if x == VNONE || (x & (VPARAM | VFLAG)) != 0 || !self.defined_in(x) {
            return (0xFFu8, 0u64);
        }
        let t = b.insts[x as usize];
        let bits = type_bits(t.ty, ptr);
        let k = if (t.b & (VPARAM | VFLAG)) == 0 && t.b != VNONE && t.b < b.insts.len() as u32 && b.insts[t.b as usize].op == O_ICONST {
            b.insts[t.b as usize].a as u64 | b.insts[t.b as usize].b as u64 << 32
        } else {
            u64::MAX
        };
        if k == u64::MAX {
            return (0xFFu8, 0u64);
        }
        if t.a == q && t.op == O_SHL && k >= 1 && k < 16 {
            return (k as u8, 0u64);
        }
        if t.a == q && t.op == O_MUL && k >= 2 && k <= 0x8000 && (k & k - 1) == 0 {
            return (k.trailing_zeros() as u8, 0u64);
        }
        if (t.op == O_ADD || t.op == O_OR) && k < 0x80000000 && bits == type_bits(value_type(b, q), ptr) {
            let (s, c) = self.affine(b, ptr, t.a, q);
            if s != 0xFF && c == 0 && (t.op == O_ADD || k < 1u64 << s as u64) {
                return (s, k);
            }
        }
        return (0xFFu8, 0u64);
    }

    // Whether a branch on the guard `version` would make (`gx`, `gy`, `gcond`) already enters preheader
    // `p`: the loop is the copy that keeps its checks.
    fn guarded(self: &Self, b: &Body, p: u32) bool {
        for k in 0..b.blocks.len() {
            let t = term(b, k as u32);
            if t.op == O_BR && (b.edge_target(t.b) == p || b.edge_target(t.c) == p) && self.is_guard(b, t.a) {
                return true;
            }
        }
        return false;
    }

    // Whether `v` is the guard `version` makes: the comparisons in order, joined by `and`.
    fn is_guard(self: &Self, b: &Body, v: Value) bool {
        let mut c = v;
        let mut k = self.gx.len();
        // Each step reads one comparison.
        while k > 0 {
            k -= 1;
            if (c & (VPARAM | VFLAG)) != 0 || c == VNONE {
                return false;
            }
            let mut t = b.insts[c as usize];
            if k != 0 {
                if t.op != O_AND || (t.b & (VPARAM | VFLAG)) != 0 || t.b == VNONE {
                    return false;
                }
                c = t.a;
                t = b.insts[t.b as usize];
            }
            if t.op != O_ICMP || t.aux != self.gcond || t.a != self.gx[k] || t.b != self.gy[k] {
                return false;
            }
        }
        return true;
    }

    // Whether the back edge from latch `u` to `h` passes header parameter `q` (its `qi`-th) plus 1.
    fn steps_by_one(self: &mut Self, b: &Body, h: u32, u: u32, q: Value, qi: u32) bool {
        b.succ_edges(term(b, u), &mut self.edges);
        for j in 0..self.edges.len() {
            let e = self.edges[j];
            if b.edge_target(e) != h {
                continue;
            }
            let nv = b.edge_arg(e, qi);
            if (nv & (VPARAM | VFLAG)) != 0 || nv == VNONE {
                return false;
            }
            let si = b.insts[nv as usize];
            return (si.op == O_ADD || si.op == O_ADDO) && si.a == q && is_const(b, si.b) && b.insts[si.b as usize].a == 1 && b.insts[si.b as usize].b == 0;
        }
        return false;
    }

    // Whether the back edge of loop `h` from `u` passes `q - 1` (`down_by_one`) as `q` (header parameter `qi`).
    fn steps_down(self: &mut Self, b: &Body, h: u32, u: u32, q: Value, qi: u32) bool {
        b.succ_edges(term(b, u), &mut self.edges);
        for j in 0..self.edges.len() {
            let e = self.edges[j];
            if b.edge_target(e) != h {
                continue;
            }
            let nv = b.edge_arg(e, qi);
            return (nv & (VPARAM | VFLAG)) == 0 && nv != VNONE && down_by_one(b, b.insts[nv as usize], q);
        }
        return false;
    }

    // Whether `x` is `q - 1` (`down_by_one`), defined in the loop.
    fn down_of(self: &Self, b: &Body, x: Value, q: Value) bool {
        return x != VNONE && (x & (VPARAM | VFLAG)) == 0 && self.defined_in(x) && down_by_one(b, b.insts[x as usize], q);
    }

    // A branch of loop `h` on a value defined outside it, not a constant (VNONE: none): unswitching
    // copies the loop for each side. Sets `fixes` and `fside` to that branch.
    fn invariant_branch(self: &mut Self, b: &Body) Value {
        self.fixes.truncate(0);
        self.fside.truncate(0);
        self.gx.truncate(0);
        self.gy.truncate(0);
        for j in 0..self.lblocks.len() {
            let k = self.lblocks[j];
            let t = term(b, k);
            if t.op != O_BR || t.a == VNONE || self.defined_in(t.a) || is_const(b, t.a) {
                continue;
            }
            // Each side's copy jumps to that side.
            self.fixes.push(k);
            self.fside.push(0);
            return t.a;
        }
        return VNONE;
    }

    // Version loop `h` (preheader `p`): a copy of it whose back edge enters its own header, and a guard
    // block the preheader enters instead, which enters the copy when the guard holds and the loop
    // otherwise, each through a block that only jumps (its preheader). The guard is `g`, or with VNONE the
    // conjunction of `gx[k] <=u gy[k]`. In the copy each branch of `fixes` jumps to its `fside` side; with
    // `g` the loop's jumps to the other side.
    fn version(self: &mut Self, b: &mut Body, h: u32, p: u32, g: Value) {
        let first = b.blocks.len() as u32;
        let nl = self.lblocks.len() as u32;
        fill(&mut self.bmap, b.blocks.len(), NONE);
        for x in 0..nl {
            self.bmap[self.lblocks[x as usize] as usize] = first + x;
        }
        let hc = first + self.lpos(h);
        self.copy(b, h, hc);
        for j in 0..self.fixes.len() {
            let k = self.fixes[j];
            let side = self.fside[j];
            fix_branch(b, self.bmap[k as usize], side);
            if g != VNONE {
                fix_branch(b, k, 1 - side);
            }
        }
        // The guard block: the header's parameters, the guard, the branch.
        let hb = b.blocks[h as usize];
        let gb = b.blocks.len() as u32;
        let ps = b.params.len() as u32;
        for q in 0..hb.param_len as u32 {
            let pt = b.params[(hb.param_start + q) as usize];
            b.params.push(pt);
        }
        let start = b.insts.len() as u32;
        let l0 = b.locs[hb.start as usize];
        let mut gv = g;
        if g == VNONE {
            for k in 0..self.gx.len() {
                let mut y = self.gy[k];
                if self.gsh[k] != 0 || self.goff[k] != 0 {
                    // bound(len) = len > c ? ((len - c - 1) >> s) + 1 : 0 (`checks`).
                    let ty = value_type(b, y);
                    let c0 = vpush(b, iconst_of(ty, self.goff[k]), l0);
                    let c1 = vpush(b, iconst_of(ty, self.goff[k] + 1), l0);
                    let cs = vpush(b, iconst_of(ty, self.gsh[k]), l0);
                    let one = vpush(b, iconst_of(ty, 1), l0);
                    let zero = vpush(b, iconst_of(ty, 0), l0);
                    let gt = vpush(b, Inst { op: O_ICMP, ty: T_I8, aux: C_UGT, a: y, b: c0, c: 0 }, l0);
                    let d = vpush(b, bin(O_SUB, ty, y, c1), l0);
                    let s = vpush(b, bin(O_LSHR, ty, d, cs), l0);
                    let s1 = vpush(b, bin(O_ADD, ty, s, one), l0);
                    y = vpush(b, Inst { op: O_SELECT, ty: ty, aux: 0, a: gt, b: s1, c: zero }, l0);
                }
                let c = b.insts.len() as u32;
                // Counting down from `i0`, the checks read `i0 - 1` at most: `i0 <= len`.
                let x = if self.grev {
                    VPARAM | ps + self.gq
                } else {
                    self.gx[k]
                };
                b.insts.push(Inst { op: O_ICMP, ty: T_I8, aux: self.gcond, a: x, b: y, c: 0 });
                b.locs.push(l0);
                if gv != VNONE {
                    let a2 = b.insts.len() as u32;
                    b.insts.push(Inst { op: O_AND, ty: T_I8, aux: 0, a: gv, b: c, c: 0 });
                    b.locs.push(l0);
                    gv = a2;
                } else {
                    gv = c;
                }
            }
            if self.gq != NONE && !self.grev && gv != VNONE {
                // `i != n` from at most `n`: every value below `n`.
                let c = vpush(
                    b,
                    Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: VPARAM | ps + self.gq, b: self.gx[0], c: 0 },
                    l0,
                );
                gv = vpush(b, Inst { op: O_AND, ty: T_I8, aux: 0, a: gv, b: c, c: 0 }, l0);
            }
        }
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.args.push(VPARAM | ps + q);
        }
        // The two preheaders follow the guard block.
        let ein = b.edge(gb + 1, &self.args);
        let eout = b.edge(gb + 2, &self.args);
        b.insts.push(Inst { op: O_BR, ty: T_NONE, aux: 0, a: gv, b: ein, c: eout });
        b.locs.push(l0);
        let n = b.insts.len() as u32 - start;
        if b.inl.len() != 0 {
            for _ in 0..n {
                b.inl.push(0);
            }
        }
        b.blocks.push(Block { start: start, len: n, param_start: ps, param_len: hb.param_len, flags: hb.flags });
        for _ in 0..n {
            self.owner.push(gb);
        }
        for _ in 0..hb.param_len {
            self.powner.push(gb);
        }
        self.inl.push(false);
        self.proxy.push(self.proxy[p as usize]);
        self.jump_block(b, hc, h, p);
        self.jump_block(b, h, h, p);
        // The preheader enters the guard.
        let pe = term(b, p).a;
        b.pool[pe as usize] = gb;
        if g == VNONE {
            // The loop with the checks runs only when one of them may fail: rarely, and as it is.
            b.blocks.index_mut(gb as usize + 2).flags |= BLOCK_UNLIKELY;
            b.blocks.index_mut(h as usize).flags |= BLOCK_NOVEC;
        }
    }

    // A block with header `h`'s parameters that jumps to `to` with them, dominated as `p` is.
    fn jump_block(self: &mut Self, b: &mut Body, to: u32, h: u32, p: u32) {
        let hb = b.blocks[h as usize];
        let k = b.blocks.len() as u32;
        let ps = b.params.len() as u32;
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            let pt = b.params[(hb.param_start + q) as usize];
            b.params.push(pt);
            self.args.push(VPARAM | ps + q);
        }
        let e = b.edge(to, &self.args);
        let start = b.insts.len() as u32;
        b.insts.push(Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 });
        let l0 = b.locs[hb.start as usize];
        b.locs.push(l0);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        b.blocks.push(Block { start: start, len: 1, param_start: ps, param_len: hb.param_len, flags: hb.flags });
        self.owner.push(k);
        for _ in 0..hb.param_len {
            self.powner.push(k);
        }
        self.inl.push(false);
        self.proxy.push(self.proxy[p as usize]);
    }

    // The values instruction `t` uses, its edges' arguments too, into `uses`.
    fn outside_uses(self: &mut Self, b: &Body, t: Inst) {
        lv::uses(b, t, &mut self.uses);
        b.succ_edges(t, &mut self.edges);
        for e in 0..self.edges.len() {
            for q in 0..b.edge_nargs(self.edges[e]) {
                self.uses.push(b.edge_arg(self.edges[e], q));
            }
        }
    }

    // Terminator `t` with each edge into `tg` a new one into `land` that adds the values that leave
    // (`lout`, as the loop has them) after its arguments.
    fn land_edges(self: &mut Self, b: &mut Body, t0: Inst, tg: u32, land: u32) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if f == F_JMP {
            t.a = self.land_edge(b, t.a, tg, land);
        } else if f == F_BR {
            t.b = self.land_edge(b, t.b, tg, land);
            t.c = self.land_edge(b, t.c, tg, land);
        } else if f == F_SWITCH {
            let at = b.pool.len() as u32;
            for _ in 0..t.aux as u32 + 1 {
                b.pool.push(0);
            }
            for k in 0..t.aux as u32 + 1 {
                let e0 = b.pool[(t.c + k) as usize];
                let e = self.land_edge(b, e0, tg, land);
                b.pool[(at + k) as usize] = e;
            }
            t.c = at;
        }
        return t;
    }

    fn land_edge(self: &mut Self, b: &mut Body, e: u32, tg: u32, land: u32) u32 {
        if b.edge_target(e) != tg {
            return e;
        }
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            self.args.push(b.edge_arg(e, q));
        }
        for q in 0..self.lout.len() {
            self.args.push(self.lout[q]);
        }
        return b.edge(land, &self.args);
    }

    // Instruction `t` outside the loop with each value that leaves the loop the landing block's parameter
    // for it (at `base` on): its operands, value lists and edges' arguments, the lists and edges new.
    fn relanded(self: &mut Self, b: &mut Body, t0: Inst, base: u32) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.landed(t.a, base);
        }
        if lv::operand_b(f) {
            t.b = self.landed(t.b, base);
        }
        if lv::operand_c(f) {
            t.c = self.landed(t.c, base);
        }
        if f == F_CALL || f == F_CALLIND {
            t.c = self.landed_list(b, t.c, t.aux, base);
        } else if f == F_VOP || f == F_ASM {
            t.a = self.landed_list(b, t.a, t.b, base);
        } else if f == F_JMP {
            t.a = self.landed_edge(b, t.a, base);
        } else if f == F_BR {
            t.b = self.landed_edge(b, t.b, base);
            t.c = self.landed_edge(b, t.c, base);
        } else if f == F_SWITCH {
            let at = b.pool.len() as u32;
            for _ in 0..t.aux as u32 + 1 {
                b.pool.push(0);
            }
            for k in 0..t.aux as u32 + 1 {
                let e0 = b.pool[(t.c + k) as usize];
                let e = self.landed_edge(b, e0, base);
                b.pool[(at + k) as usize] = e;
            }
            t.c = at;
        }
        return t;
    }

    // `v`, or the landing block's parameter for it (from `base`) when it leaves the loop.
    fn landed(self: &Self, v: Value, base: u32) Value {
        for q in 0..self.lout.len() {
            if self.lout[q] == v {
                return VPARAM | base + q as u32;
            }
        }
        return v;
    }

    // The `n` values at pool `at`, or a new list with the landing block's parameters when one leaves.
    fn landed_list(self: &Self, b: &mut Body, at: u32, n: u32, base: u32) u32 {
        let mut any = false;
        for q in 0..n {
            any = any || contains(&self.lout, b.pool[(at + q) as usize]);
        }
        if !any {
            return at;
        }
        let out = b.pool.len() as u32;
        for q in 0..n {
            let v = self.landed(b.pool[(at + q) as usize], base);
            b.pool.push(v);
        }
        return out;
    }

    // Edge `e`, or a new one with the landing block's parameters when an argument leaves the loop.
    fn landed_edge(self: &mut Self, b: &mut Body, e: u32, base: u32) u32 {
        let mut any = false;
        for q in 0..b.edge_nargs(e) {
            any = any || contains(&self.lout, b.edge_arg(e, q));
        }
        if !any {
            return e;
        }
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            self.args.push(self.landed(b.edge_arg(e, q), base));
        }
        return b.edge(b.edge_target(e), &self.args);
    }

    // Whether value `v` is defined in the loop at hand.
    fn defined_in(self: &Self, v: Value) bool {
        if v == VNONE {
            return false;
        }
        if (v & VPARAM) != 0 {
            return self.inl[self.powner[(v & ~VPARAM) as usize] as usize];
        }
        return self.inl[self.owner[(v & ~VFLAG) as usize] as usize];
    }

    // The iteration (1-based, at most MAX_PEEL) at which block `e` of loop `h` (preheader `p`, latch `u`)
    // leaves the loop by its branch on a counted comparison; 0 when the branch is not one or it does not
    // leave within that.
    fn trip(self: &mut Self, b: &Body, ptr: u32, h: u32, p: u32, u: u32, e: u32) u32 {
        let t = term(b, e);
        if t.op != O_BR || (t.a & (VPARAM | VFLAG)) != 0 || t.a == VNONE {
            return 0;
        }
        let ci = b.insts[t.a as usize];
        if ci.op != O_ICMP {
            return 0;
        }
        // Which edge leaves: the one whose target is outside the loop (the latch's other edge goes back).
        let out_taken = !self.inl[b.edge_target(t.b) as usize];
        let out_other = !self.inl[b.edge_target(t.c) as usize];
        if out_taken == out_other {
            return 0;
        }
        // The comparison's counted side `x` and constant side; `swap` when the constant comes first.
        let (x, kv, swap) = if is_const(b, ci.b) {
            (ci.a, ci.b, false)
        } else if is_const(b, ci.a) {
            (ci.b, ci.a, true)
        } else {
            return 0;
        };
        let k = b.insts[kv as usize].a as u64 | b.insts[kv as usize].b as u64 << 32;
        // `x` is header parameter `q`, or `q` plus or minus constant `xs` (op `xop`).
        let mut q = x;
        let mut xop: u8 = 0;
        let mut xs: u64 = 0;
        if (x & VPARAM) == 0 {
            if (x & VFLAG) != 0 || x == VNONE {
                return 0;
            }
            let xi = b.insts[x as usize];
            if !step_op(xi.op) || !is_const(b, xi.b) {
                return 0;
            }
            q = xi.a;
            xop = xi.op;
            xs = b.insts[xi.b as usize].a as u64 | b.insts[xi.b as usize].b as u64 << 32;
        }
        let hb = b.blocks[h as usize];
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return 0;
        }
        let qi = (q & ~VPARAM) - hb.param_start;
        let ty = b.params[(q & ~VPARAM) as usize];
        if !is_int(ty) || ty == T_I128 {
            return 0;
        }
        // Its start: the preheader's argument.
        let pe = term(b, p).a;
        let init = b.edge_arg(pe, qi);
        if !is_const(b, init) {
            return 0;
        }
        // Its step: the back edge's argument, the parameter plus or minus a constant.
        b.succ_edges(term(b, u), &mut self.edges);
        let mut be = NONE;
        for j in 0..self.edges.len() {
            if b.edge_target(self.edges[j]) == h {
                be = self.edges[j];
            }
        }
        let nv = b.edge_arg(be, qi);
        if (nv & (VPARAM | VFLAG)) != 0 || nv == VNONE {
            return 0;
        }
        let si = b.insts[nv as usize];
        if !step_op(si.op) || si.a != q || !is_const(b, si.b) {
            return 0;
        }
        let step = b.insts[si.b as usize].a as u64 | b.insts[si.b as usize].b as u64 << 32;
        let mut v = b.insts[init as usize].a as u64 | b.insts[init as usize].b as u64 << 32;
        // Each iteration evaluates the comparison once.
        for n in 1..MAX_PEEL + 1 {
            let mut xv = v;
            if xop != 0 && le::int_fold(base_op(xop), ty, ptr, v, xs, &mut xv) != le::FOLD_OK {
                return 0;
            }
            let holds = if swap {
                le::icmp(ci.aux, ty, ptr, k, xv)
            } else {
                le::icmp(ci.aux, ty, ptr, xv, k)
            };
            if holds == out_taken {
                self.ctr = q;
                return n;
            }
            let mut nx: u64 = 0;
            if le::int_fold(base_op(si.op), ty, ptr, v, step, &mut nx) != le::FOLD_OK {
                return 0;
            }
            v = nx;
        }
        return 0;
    }

    // The instructions a copy of the counted loop (`lblocks`, counter `ctr`) keeps once its counter is a
    // constant: all but those computed from constants and the counter alone, the addresses they decide
    // past a base from outside the loop, the branches on them, which the walk folds, and the jumps, which
    // merge the blocks; at least 1.
    fn residual(self: &mut Self, b: &Body) u32 {
        fill(&mut self.fixed, b.insts.len(), false);
        // Each pass marks what the last pass's marks decide; a chain longer than RESIDUAL_PASSES counts.
        for _ in 0..RESIDUAL_PASSES {
            for j in 0..self.lblocks.len() {
                let bk = b.blocks[self.lblocks[j] as usize];
                for i in bk.start..bk.start + bk.len - 1 {
                    let t = b.insts[i as usize];
                    let f = op_info(t.op).form;
                    if t.op >= O_ICONST && t.op <= O_INTTOPTR && !is_vec(t.ty) && (!lv::operand_a(f) || self.decided(
                        b,
                        t.a,
                    )) && (!lv::operand_b(f) || self.decided(b, t.b)) && (!lv::operand_c(f) || self.decided(b, t.c)) {
                        self.fixed[i as usize] = true;
                    }
                    // An address the counter decides past a base the loop does not define: a constant
                    // offset, which the accesses take.
                    if t.op == O_PTRADD && (self.decided(b, t.a) || !self.defined_in(t.a)) && (t.b == VNONE || self.decided(
                        b,
                        t.b,
                    )) {
                        self.fixed[i as usize] = true;
                    }
                }
            }
        }
        let mut n: u32 = 0;
        for j in 0..self.lblocks.len() {
            let bk = b.blocks[self.lblocks[j] as usize];
            for i in bk.start..bk.start + bk.len - 1 {
                if !self.fixed[i as usize] {
                    n += 1;
                }
            }
            let t = b.insts[(bk.start + bk.len - 1) as usize];
            if t.op != O_JMP && (t.op != O_BR || !self.decided(b, t.a)) {
                n += 1;
            }
        }
        return n.max(1);
    }

    // Whether a copy of the counted loop knows value `v` (`residual`): the counter, a constant, or what
    // they compute.
    const fn decided(self: &Self, b: &Body, v: Value) bool {
        if v == self.ctr {
            return true;
        }
        if (v & VPARAM) != 0 || v == VNONE {
            return false;
        }
        let x = v & ~VFLAG;
        return self.fixed[x as usize] || b.insts[x as usize].op == O_ICONST;
    }

    // Peel loop `h` (preheader `p`, blocks `lblocks`) `n` times: copy 1 takes the preheader's edge, copy j's
    // back edge enters copy j + 1, copy n's the loop.
    fn peel(self: &mut Self, b: &mut Body, h: u32, p: u32, n: u32) {
        let first = b.blocks.len() as u32;
        let nl = self.lblocks.len() as u32;
        // Copy j's blocks are `first + (j - 1) nl + x` for the loop's `x`-th block.
        fill(&mut self.bmap, b.blocks.len(), NONE);
        for j in 1..n + 1 {
            let base = first + (j - 1) * nl;
            for x in 0..nl {
                self.bmap[self.lblocks[x as usize] as usize] = base + x;
            }
            let next_h = if j == n {
                h
            } else {
                base + nl + self.lpos(h)
            };
            self.copy(b, h, next_h);
        }
        // The preheader enters copy 1.
        let pe = term(b, p).a;
        b.pool[pe as usize] = first + self.lpos(h);
    }

    // The position of loop block `k` in `lblocks`.
    fn lpos(self: &Self, k: u32) u32 {
        for x in 0..self.lblocks.len() {
            if self.lblocks[x] == k {
                return x as u32;
            }
        }
        assert(false, "loops: a block outside the loop");
        return 0;
    }

    // One copy of the loop's blocks at `bmap`, its back edge into block `next_h`.
    fn copy(self: &mut Self, b: &mut Body, h: u32, next_h: u32) {
        // The copy's numbering: instructions and parameters in order after the body's.
        fill(&mut self.imap, b.insts.len(), NONE);
        fill(&mut self.pmap, b.params.len(), NONE);
        let mut ni = b.insts.len() as u32;
        let mut np = b.params.len() as u32;
        for x in 0..self.lblocks.len() {
            let bk = b.blocks[self.lblocks[x] as usize];
            for i in bk.start..bk.start + bk.len {
                self.imap[i as usize] = ni;
                ni += 1;
            }
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                self.pmap[q as usize] = np;
                np += 1;
            }
        }
        for x in 0..self.lblocks.len() {
            let bk = b.blocks[self.lblocks[x] as usize];
            let start = b.insts.len() as u32;
            let ps = b.params.len() as u32;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                let pt = b.params[q as usize];
                b.params.push(pt);
            }
            for i in bk.start..bk.start + bk.len {
                let t0 = b.insts[i as usize];
                let t = self.copy_inst(b, t0, h, next_h);
                b.insts.push(t);
                let l = b.locs[i as usize];
                b.locs.push(l);
                if b.inl.len() != 0 {
                    let s = b.inl[i as usize];
                    b.inl.push(s);
                }
            }
            b.blocks.push(
                Block {
                    start: start,
                    len: b.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: bk.param_len,
                    flags: bk.flags,
                },
            );
            // The tables of the blocks follow the copies: no loop holds them.
            let k = b.blocks.len() as u32 - 1;
            self.proxy.push(self.proxy[self.lblocks[x] as usize]);
            for _ in 0..bk.len {
                self.owner.push(k);
            }
            for _ in 0..bk.param_len {
                self.powner.push(k);
            }
            self.inl.push(false);
        }
    }

    // The copy's value for `v`: a loop value's copy, any other as it is.
    fn cv(self: &Self, v: Value) Value {
        if !self.defined_in(v) {
            return v;
        }
        if (v & VPARAM) != 0 {
            return VPARAM | self.pmap[(v & ~VPARAM) as usize];
        }
        return self.imap[(v & ~VFLAG) as usize] | v & VFLAG;
    }

    // Instruction `t0` of the loop for the copy: its values the copy's, its value lists and edges new.
    fn copy_inst(self: &mut Self, b: &mut Body, t0: Inst, h: u32, next_h: u32) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.cv(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.cv(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.cv(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            t.c = self.copy_list(b, t.c, t.aux);
        } else if f == F_VOP || f == F_ASM {
            t.a = self.copy_list(b, t.a, t.b);
        } else if f == F_JMP {
            t.a = self.copy_edge(b, t.a, h, next_h);
        } else if f == F_BR {
            t.b = self.copy_edge(b, t.b, h, next_h);
            t.c = self.copy_edge(b, t.c, h, next_h);
        } else if f == F_SWITCH {
            let at = b.pool.len() as u32;
            for k in 0..t.aux as u32 + 1 {
                b.pool.push(0);
            }
            for k in 0..t.aux as u32 + 1 {
                let e0 = b.pool[(t.c + k) as usize];
                let e = self.copy_edge(b, e0, h, next_h);
                b.pool[(at + k) as usize] = e;
            }
            t.c = at;
        }
        return t;
    }

    // A copy of the `n` values at pool `at`, in the copy's numbering.
    fn copy_list(self: &Self, b: &mut Body, at: u32, n: u32) u32 {
        let out = b.pool.len() as u32;
        for q in 0..n {
            let v = self.cv(b.pool[(at + q) as usize]);
            b.pool.push(v);
        }
        return out;
    }

    // A copy of edge `e`: into the copy's block for a loop block, `next_h` for the header, else the same
    // block; its arguments the copy's.
    fn copy_edge(self: &mut Self, b: &mut Body, e: u32, h: u32, next_h: u32) u32 {
        let tg = b.edge_target(e);
        let nt = if tg == h {
            next_h
        } else if self.inl[tg as usize] {
            self.bmap[tg as usize]
        } else {
            tg
        };
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            self.args.push(self.cv(b.edge_arg(e, q)));
        }
        return b.edge(nt, &self.args);
    }
}

// The terminator of block `k`.
// Whether `t` is `q - 1` (or `q + -1`).
fn down_by_one(b: &Body, t: Inst, q: Value) bool {
    if t.op == O_SUB {
        return t.a == q && is_const(b, t.b) && raw_const(b, t.b) == 1;
    }
    if t.op != O_ADD {
        return false;
    }
    let m = mask_of(type_bits(t.ty, 8));
    return t.a == q && is_const(b, t.b) && (raw_const(b, t.b) & m) == m || t.b == q && is_const(b, t.a) && (raw_const(
        b,
        t.a,
    ) & m) == m;
}

// The `vop` lane comparison (a `SIMD_CMP_*` code and VOP_SIGNED) of comparison `t` (`icmp`, `fcmp`),
// NONE16 when none matches it: an equality, an order of integers, an ordered order of floats, `une`.
fn cmp_code(t: Inst) u16 {
    if t.op != O_ICMP && t.op != O_FCMP {
        return NONE16;
    }
    let c = t.aux;
    let (k, sg) = if c == C_EQ || c == C_OEQ && t.op == O_FCMP {
        (core::SIMD_CMP_EQ, false)
    } else if c == C_NE && t.op == O_ICMP || c == C_UNE && t.op == O_FCMP {
        (core::SIMD_CMP_NE, false)
    } else if c == C_SLT || c == C_ULT || c == C_OLT && t.op == O_FCMP {
        (core::SIMD_CMP_LT, c == C_SLT)
    } else if c == C_SLE || c == C_ULE || c == C_OLE && t.op == O_FCMP {
        (core::SIMD_CMP_LE, c == C_SLE)
    } else if c == C_SGT || c == C_UGT || c == C_OGT && t.op == O_FCMP {
        (core::SIMD_CMP_GT, c == C_SGT)
    } else if c == C_SGE || c == C_UGE || c == C_OGE && t.op == O_FCMP {
        (core::SIMD_CMP_GE, c == C_SGE)
    } else {
        return NONE16;
    };
    return (core::OP_SIMD + k as u32) as u16 | ast::pick(sg, VOP_SIGNED, 0);
}

// The integer of a lane mask of `l` lanes (bit k for lane k), as the lowering's.
const fn mask_int_of(l: u32) u8 {
    if l <= 8 {
        return T_I8;
    }
    if l <= 16 {
        return T_I16;
    }
    if l <= 32 {
        return T_I32;
    }
    return T_I64;
}

// Branch terminator of block `k` as a jump to its taken edge (`side` 0) or its other one.
fn fix_branch(b: &mut Body, k: u32, side: u8) {
    let bk = b.blocks[k as usize];
    let i = (bk.start + bk.len - 1) as usize;
    let t = b.insts[i];
    let e = if side == 0 {
        t.b
    } else {
        t.c
    };
    b.insts[i] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 };
}

// Whether block `k` is a failure path: cold, or ending in a panic or a trap.
fn cold(b: &Body, k: u32) bool {
    let op = term(b, k).op;
    return (b.blocks[k as usize].flags & BLOCK_COLD) != 0 || op == O_PANIC || op == O_UNREACHABLE;
}

// Whether `vs` holds `v`.
// Whether vector conversion `op` of lanes of `from` into lanes of `to` is one the targets that convert
// vectors in registers do (`Package.vops`), in at most two steps (`vconv`): an integer to a float of its
// width and back, an integer to twice or 4 times its width and back, a narrower integer to a float, f32
// to f64 and back.
const fn vconv_ok(op: u8, from: u8, to: u8, ptr: u32) bool {
    let fb = type_bytes(from, ptr);
    let tb = type_bytes(to, ptr);
    let fi = is_int(from);
    let ti = is_int(to);
    return (op == O_SEXT || op == O_ZEXT) && fi && ti && (tb == 2 * fb || tb == 4 * fb) || op == O_TRUNC && fi && ti && (fb == 2 * tb || fb == 4 * tb) || (op == O_SITOFP || op == O_UITOFP) && fi && is_float(
        to,
    ) && (fb == tb || tb == 2 * fb || tb == 4 * fb) || (op == O_FPTOSI || op == O_FPTOUI) && is_float(from) && ti && fb == tb || op == O_FPEXT && from == T_F32 && to == T_F64 || op == O_FPTRUNC && from == T_F64 && to == T_F32;
}

// Whether `v` is the length of the slice whose pointer load `pl` reads: a load of the word after it.
fn slice_len(b: &Body, pl: Inst, v: Value, ptr: u32) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let nl = b.insts[v as usize];
    return pl.op == O_LOAD && nl.op == O_LOAD && pl.a == nl.a && (pl.aux & MEM_VOLATILE) == 0 && (nl.c as i32) as i64 == (pl.c as i32) as i64 + ptr as i64 && is_int(
        nl.ty,
    ) && type_bytes(nl.ty, ptr) == ptr;
}

// The integer type of `n` bytes (1, 2, 4 or 8).
const fn int_of_bytes(n: u32) u8 {
    return if n == 1 {
        T_I8
    } else if n == 2 {
        T_I16
    } else if n == 4 {
        T_I32
    } else {
        T_I64
    };
}

// Append `t` at location `l` to `b` (in the block being built at its end); its value.
fn vpush(b: &mut Body, t: Inst, l: u32) Value {
    let v = b.insts.len() as u32;
    b.insts.push(t);
    b.locs.push(l);
    return v;
}

fn contains_bool(vs: &Vector<bool>, v: bool) bool {
    for k in 0..vs.len() {
        if vs[k] == v {
            return true;
        }
    }
    return false;
}

fn contains_u32(vs: &Vector<u32>, v: u32) bool {
    for k in 0..vs.len() {
        if vs[k] == v {
            return true;
        }
    }
    return false;
}

fn contains(vs: &Vector<Value>, v: Value) bool {
    for q in 0..vs.len() {
        if vs[q] == v {
            return true;
        }
    }
    return false;
}

// The type of value `v`: an instruction's, a block parameter's, or a checked operation's flag (`i8`).
fn value_type(b: &Body, v: Value) u8 {
    if (v & VPARAM) != 0 {
        return b.params[(v & ~VPARAM) as usize];
    }
    if (v & VFLAG) != 0 {
        return T_I8;
    }
    return b.insts[v as usize].ty;
}

// Whether `v` is an instruction's value that is an integer constant.
// The access class of instruction `i` (`Classes.acc`); CL_MANY for one made since.
const fn class_at(cl: Classes, i: u32) u8 {
    return if i as usize < cl.acc.len() {
        cl.acc[i as usize]
    } else {
        CL_MANY
    };
}

const fn obj_at(cl: Classes, i: u32) u32 {
    return if i as usize < cl.obj.len() {
        cl.obj[i as usize]
    } else {
        NONE
    };
}

const fn private_obj(o: u32) bool {
    return o != NONE && (o & OBJ_PRIVATE) != 0;
}

fn is_const(b: &Body, v: Value) bool {
    return v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_ICONST;
}

// Whether `op` steps a counter: an addition or a subtraction, checked or not (the value result).
const fn step_op(op: u8) bool {
    return op == O_ADD || op == O_SUB || op == O_ADDO || op == O_SUBO;
}

// The unchecked operation of step `op`.
const fn base_op(op: u8) u8 {
    return if op == O_ADD || op == O_ADDO {
        O_ADD
    } else {
        O_SUB
    };
}

// A loop's counted exit (`LoopOpt::cf_bits`): a counter, or a value that loses its lowest set bit
// (popcount iterations) or shifts right by 1 (bit length) per iteration.
const CB_NONE: u8 = 0;
const CB_POP: u8 = 1;
const CB_LEN: u8 = 2;

// ---- Final values: facts ----

// What a loop value is as a function of the iteration (`LoopOpt::fact`): `st` PS_YES when it equals a
// polynomial of degree `deg` with integer values modulo 2^`m`; with `rng`, that polynomial's values lie
// in [`lo`, `hi`] and the value equals it modulo 2^(its bits). With `tog` (degree 1, all its bits), it is
// no polynomial but takes one value on even iterations and another on odd ones: a header parameter that
// steps by an `xor` with an invariant, and the values of such ones and invariants (`p_tog`).
struct Poly {
    pub(package) st: u8,
    pub(package) deg: u8,
    pub(package) m: u8,
    pub(package) rng: bool,
    pub(package) lo: i64,
    pub(package) hi: i64,
    pub(package) tog: bool,
}

extend Poly as Copy {}

// A value as `coef` times a header parameter plus `rest` (`LoopOpt::lin`).
struct Lin {
    pub(package) coef: i64,
    pub(package) rest: Poly,
}

extend Lin as Copy {}

const PS_UNKNOWN: u8 = 0; // it reads a header parameter not resolved yet
const PS_NO: u8 = 1; // no polynomial
const PS_YES: u8 = 2;

// The status of a value of two operands of statuses `a` and `b`.
const fn p_st(a: u8, b: u8) u8 {
    return if a == PS_NO || b == PS_NO {
        PS_NO
    } else if a == PS_UNKNOWN || b == PS_UNKNOWN {
        PS_UNKNOWN
    } else {
        PS_YES
    };
}

const fn p_of(st: u8) Poly {
    return Poly { st: st, deg: 0, m: 0, rng: false, lo: 0, hi: 0, tog: false };
}

// A value of `w` bits the same on every iteration.
const fn p_inv(w: u32) Poly {
    return Poly { st: PS_YES, deg: 0, m: w as u8, rng: false, lo: 0, hi: 0, tog: false };
}

const fn p_const(w: u32, c: i64) Poly {
    return Poly { st: PS_YES, deg: 0, m: w as u8, rng: true, lo: c, hi: c, tog: false };
}

// A value of `w` bits that alternates between two values (`Poly.tog`).
const fn p_tog(w: u32) Poly {
    return Poly { st: PS_YES, deg: 1, m: w as u8, rng: false, lo: 0, hi: 0, tog: true };
}

// The facts of a value of operands `x` and `y` (`w` bits, each PS_YES), one of them alternating: an
// alternating value when the other is too or the same on every iteration.
const fn tog_of(x: Poly, y: Poly, w: u32) Poly {
    return if (x.tog || x.deg == 0) && (y.tog || y.deg == 0) {
        p_tog(w)
    } else {
        p_of(PS_NO)
    };
}

const fn p_zero(w: u32) Poly {
    return p_const(w, 0);
}

// The facts of value `v` the loop does not define.
fn const_fact(b: &Body, ptr: u32, v: Value) Poly {
    let w = type_bits(value_type(b, v), ptr);
    if is_const(b, v) {
        return p_const(w, sext_of(raw_const(b, v), w));
    }
    return p_inv(w);
}

// The facts of a value that is `x` on some runs of the loop and `y` on the others (`w` bits).
const fn either(x: Poly, y: Poly, w: u32) Poly {
    let st = p_st(x.st, y.st);
    if st != PS_YES {
        return p_of(st);
    }
    if x.tog || y.tog {
        return tog_of(x, y, w);
    }
    let rng = x.rng && y.rng;
    return Poly {
        st: PS_YES,
        deg: x.deg.max(y.deg),
        m: if rng {
            w as u8
        } else {
            (x.m as u32).min(y.m).min(w) as u8
        },
        rng: rng,
        lo: x.lo.min(y.lo),
        hi: x.hi.max(y.hi),
    };
}

// `f` (`w` bits) times a constant: its degree and bits, no interval.
const fn scaled(f: Poly, w: u32) Poly {
    return if f.st != PS_YES || f.tog {
        f
    } else {
        Poly { st: PS_YES, deg: f.deg, m: (f.m as u32).min(w) as u8, rng: false, lo: 0, hi: 0, tog: false }
    };
}

// The facts of `x op y` in `w` bits, `op` an addition, a subtraction or a multiplication.
fn arith_fact(op: u8, x: Poly, y: Poly, w: u32) Poly {
    let st = p_st(x.st, y.st);
    if st != PS_YES {
        return p_of(st);
    }
    if x.tog || y.tog {
        return tog_of(x, y, w);
    }
    let deg = if op == O_MUL {
        x.deg as u32 + y.deg as u32
    } else {
        (x.deg as u32).max(y.deg)
    };
    if deg > CF_DEG {
        return p_of(PS_NO);
    }
    let mut r = Poly {
        st: PS_YES,
        deg: deg as u8,
        m: (x.m as u32).min(y.m).min(w) as u8,
        rng: false,
        lo: 0,
        hi: 0,
        tog: false,
    };
    if deg == 0 {
        r.m = w as u8;
    }
    if x.rng && y.rng {
        let mut ok = true;
        let mut lo: i64 = 0;
        let mut hi: i64 = 0;
        if op == O_ADD {
            lo = ck(x.lo.checked_add(y.lo), &mut ok);
            hi = ck(x.hi.checked_add(y.hi), &mut ok);
        } else if op == O_SUB {
            lo = ck(x.lo.checked_sub(y.hi), &mut ok);
            hi = ck(x.hi.checked_sub(y.lo), &mut ok);
        } else {
            let (l, h) = products(x, y, &mut ok);
            lo = l;
            hi = h;
        }
        if ok {
            r.rng = true;
            r.lo = lo;
            r.hi = hi;
            r.m = w as u8;
        }
    }
    return r;
}

// The value of `x`; clears `ok` when there is none.
fn ck(x: Option<i64>, ok: &mut bool) i64 {
    if let Some(v) = x {
        return v;
    }
    *ok = false;
    return 0;
}

// The interval of the products of intervals `x` and `y`; clears `ok` when one overflows.
fn products(x: Poly, y: Poly, ok: &mut bool) (i64, i64) {
    let a = ck(x.lo.checked_mul(y.lo), ok);
    let b = ck(x.lo.checked_mul(y.hi), ok);
    let c = ck(x.hi.checked_mul(y.lo), ok);
    let d = ck(x.hi.checked_mul(y.hi), ok);
    return (a.min(b).min(c).min(d), a.max(b).max(c).max(d));
}

// The facts of instruction `t` (`w` bits) from its operands' (`fa`, `fb`, each PS_YES, not all of
// degree 0): ring operations keep a polynomial, a conversion keeps it in the bits it keeps, an exact right
// shift by a constant divides it.
fn op_fact(b: &Body, ptr: u32, t: Inst, fa: Poly, fb: Poly, w: u32) Poly {
    let op = t.op;
    if op == O_ADD || op == O_SUB || op == O_MUL {
        return arith_fact(op, fa, fb, w);
    }
    if op == O_NEG {
        return arith_fact(O_SUB, p_zero(w), fa, w);
    }
    let amount = shift_amount(b, t.b);
    if op == O_SHL && amount < 62 && amount < w as u64 {
        return arith_fact(O_MUL, fa, p_const(w, 1i64 << amount as i64), w);
    }
    if op == O_LSHR && t.aux == SH_EXACT && amount < w as u64 {
        let s = amount as u32;
        if fa.rng && fa.lo >= 0 && fa.hi <= umax(w) {
            return Poly { st: PS_YES, deg: fa.deg, m: w as u8, rng: true, lo: fa.lo >> s, hi: fa.hi >> s, tog: false };
        }
        let m = (fa.m as u32).min(w);
        return if m <= s {
            p_of(PS_NO)
        } else {
            Poly { st: PS_YES, deg: fa.deg, m: (m - s) as u8, rng: false, lo: 0, hi: 0, tog: false }
        };
    }
    let fw = type_bits(value_type(b, t.a), ptr);
    if op == O_ZEXT || op == O_SEXT {
        let exact = if op == O_ZEXT {
            fa.rng && fa.lo >= 0 && fa.hi <= umax(fw)
        } else {
            fa.rng && fa.lo >= smin(fw) && fa.hi <= smax(fw)
        };
        if exact {
            return Poly { st: PS_YES, deg: fa.deg, m: w as u8, rng: true, lo: fa.lo, hi: fa.hi, tog: false };
        }
        return Poly { st: PS_YES, deg: fa.deg, m: (fa.m as u32).min(fw) as u8, rng: false, lo: 0, hi: 0, tog: false };
    }
    if op == O_TRUNC {
        return Poly {
            st: PS_YES,
            deg: fa.deg,
            m: (fa.m as u32).min(w) as u8,
            rng: fa.rng,
            lo: fa.lo,
            hi: fa.hi,
            tog: false,
        };
    }
    if op == O_PTRADD {
        return arith_fact(O_ADD, scaled(fa, w), scaled(fb, w), w);
    }
    if (op == O_PTRTOINT || op == O_INTTOPTR || op == O_BITCAST && is_int(t.ty) && is_int(value_type(b, t.a))) && fw == w {
        return scaled(fa, w);
    }
    return p_of(PS_NO);
}

// Whether instruction `t` of a loop computes its value without an effect and without a trap, so the loop
// may not run: the arithmetic, comparisons, conversions and selects of scalars, a division by a constant
// it may take (not 0, a signed one not -1).
fn cf_pure(b: &Body, t: Inst) bool {
    let op = t.op;
    if is_vec(t.ty) || op == O_ADDO || op == O_SUBO || op == O_MULO {
        return false;
    }
    if op >= O_SDIV && op <= O_UREM {
        if !is_const(b, t.b) || t.ty == T_I128 {
            return false;
        }
        let d = raw_const(b, t.b) & mask_of(type_bits(t.ty, 8));
        return d != 0 && (op == O_UDIV || op == O_UREM || d != mask_of(type_bits(t.ty, 8)));
    }
    return op >= O_ICONST && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT || op == O_CLZ || op == O_CTZ || op == O_POPCNT || op == O_FMA || op == O_MULHU || op == O_MULHS || op == O_BSWAP || op == O_SPLAT;
}

// Whether addresses `x` and `y` are one: the same value, or the same `ptradd` of the same operands.
fn same_address(b: &Body, x: Value, y: Value) bool {
    if x == y {
        return true;
    }
    if ((x | y) & (VPARAM | VFLAG)) != 0 || x == VNONE || y == VNONE {
        return false;
    }
    let s = b.insts[x as usize];
    let t = b.insts[y as usize];
    return s.op == O_PTRADD && t.op == O_PTRADD && s.a == t.a && s.b == t.b && s.aux == t.aux && s.c == t.c;
}

// Push instruction `t` with the location of instruction `from`.
fn cf_put(b: &mut Body, t: Inst, from: u32) Value {
    let v = b.insts.len() as u32;
    b.insts.push(t);
    let l = b.locs[from as usize];
    b.locs.push(l);
    if b.inl.len() != 0 {
        let x = b.inl[from as usize];
        b.inl.push(x);
    }
    return v;
}

// Value `v` of `from` bits as type `ty`: zero-extended or truncated.
fn cf_conv(b: &mut Body, v: Value, from: u32, ty: u8, ptr: u32, at: u32) Value {
    let to = type_bits(ty, ptr);
    if to == from {
        return v;
    }
    return cf_put(
        b,
        Inst {
            op: if to > from {
                O_ZEXT
            } else {
                O_TRUNC
            },
            ty: ty,
            aux: 0,
            a: v,
            b: VNONE,
            c: VNONE,
        },
        at,
    );
}

// The constant `v` of type `ty`, a 128-bit one as a wide constant.
fn cf_wide_const(b: &mut Body, ty: u8, v: u64, at: u32) Value {
    if ty != T_I128 {
        return cf_put(b, iconst_of(ty, v), at);
    }
    let w = b.words.len() as u32;
    b.words.push(v);
    b.words.push(0);
    return cf_put(b, Inst { op: O_WCONST, ty: T_I128, aux: 0, a: w, b: 2, c: VNONE }, at);
}

const fn bin(op: u8, ty: u8, a: Value, b: Value) Inst {
    return Inst { op: op, ty: ty, aux: 0, a: a, b: b, c: VNONE };
}

// The integer constant `v` of type `ty` (up to 64 bits), truncated to it.
const fn iconst_of(ty: u8, v: u64) Inst {
    let x = v & mask_of(type_bits(ty, 8));
    return Inst { op: O_ICONST, ty: ty, aux: 0, a: x as u32, b: (x >> 32) as u32, c: VNONE };
}

// The amount constant `v` shifts by (a wide constant's when its high word is 0); ~0 when it is none.
fn shift_amount(b: &Body, v: Value) u64 {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return ~0u64;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICONST {
        return raw_const(b, v);
    }
    if t.op == O_WCONST && t.ty == T_I128 && b.words[t.a as usize + 1] == 0 {
        return b.words[t.a as usize];
    }
    return ~0u64;
}

// The 64 bits of integer constant `v`, as stored.
fn raw_const(b: &Body, v: Value) u64 {
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}

// The low `w` bits.
const fn mask_of(w: u32) u64 {
    return if w >= 64 {
        ~0u64
    } else {
        (1u64 << w) - 1
    };
}

// An unsigned bound on `v`'s `w` bits from the instructions that make it, `depth` deep: a constant, an
// `and` with a constant, a right shift by one, a zero extension; else all ones.
const fn top_of(b: &Body, v: Value, w: u32, depth: u32) u64 {
    let all = mask_of(w);
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || depth == 0 {
        return all;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICONST {
        return raw_const(b, v) & all;
    }
    if t.op == O_ZEXT {
        let fw = type_bits(value_type(b, t.a), 8);
        return top_of(b, t.a, fw, depth - 1);
    }
    if t.op == O_AND && is_const(b, t.b) {
        return top_of(b, t.a, w, depth - 1).min(raw_const(b, t.b) & all);
    }
    if t.op == O_AND && is_const(b, t.a) {
        return top_of(b, t.b, w, depth - 1).min(raw_const(b, t.a) & all);
    }
    if t.op == O_LSHR && is_const(b, t.b) && (raw_const(b, t.b) & all) < w as u64 {
        return top_of(b, t.a, w, depth - 1) >> (raw_const(b, t.b) & all);
    }
    return all;
}

// `x`'s low `w` bits sign-extended.
const fn sext_of(x: u64, w: u32) i64 {
    return if w >= 64 {
        x as i64
    } else {
        (x << 64 - w) as i64 >> 64 - w
    };
}

// `x`'s low `w` bits as a signed or an unsigned integer (`w` below 64 when unsigned).
const fn int_value(x: u64, w: u32, signed: bool) i64 {
    return if signed {
        sext_of(x, w)
    } else {
        (x & mask_of(w)) as i64
    };
}

// The least and greatest signed values of `w` bits, and the greatest unsigned one, within i64.
const fn smin(w: u32) i64 {
    return if w >= 64 {
        i64::MIN
    } else {
        -(1i64 << w - 1)
    };
}

const fn smax(w: u32) i64 {
    return if w >= 64 {
        i64::MAX
    } else {
        (1i64 << w - 1) - 1
    };
}

const fn umax(w: u32) i64 {
    return if w >= 63 {
        i64::MAX
    } else {
        (1i64 << w) - 1
    };
}

// The greatest and least values of `w` bits, signed or not, as stored.
const fn type_max(w: u32, signed: bool) u64 {
    return if signed {
        mask_of(w) >> 1
    } else {
        mask_of(w)
    };
}

const fn type_min(w: u32, signed: bool) u64 {
    return if signed {
        (mask_of(w) >> 1) + 1
    } else {
        0
    };
}

// The twos in `j!`, and its odd part.
const fn factorial_twos(j: u32) u32 {
    let mut n: u32 = 0;
    for i in 2..j + 1 {
        n += (i as u64).trailing_zeros() as u32;
    }
    return n;
}

const fn factorial_odd(j: u32) u64 {
    let mut p: u64 = 1;
    for i in 2..j + 1 {
        let x = i as u64;
        p *= x >> x.trailing_zeros() as u64;
    }
    return p;
}

// The inverse of odd `x` modulo 2^64 (Newton's iteration: each step doubles the bits that hold).
const fn inverse_of(x: u64) u64 {
    let mut y = x;
    for _ in 0..5 {
        y = y.wrapping_mul(2u64.wrapping_sub(x.wrapping_mul(y)));
    }
    return y;
}

const fn pick_c(c: bool, a: u16, b: u16) u16 {
    return if c {
        a
    } else {
        b
    };
}

const fn pick_op(c: bool, a: u8, b: u8) u8 {
    return if c {
        a
    } else {
        b
    };
}

// `v` grown to `n` facts, when shorter.
fn grow_poly(v: &mut Vector<Poly>, n: usize) {
    if v.len() >= n {
        return;
    }
    v.reserve(n - v.len());
    while v.len() < n {
        v.push(p_of(PS_UNKNOWN));
    }
}
