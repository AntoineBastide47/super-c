// The loop transforms of an optimizing build, on innermost loops, by copying a loop's blocks.
//
// Full unrolling: a loop whose trip count the body's constants fix is peeled that many times. Each copy of the loop's blocks runs one iteration and continues into the
// next copy, the last one into the loop itself: any peel count keeps the body's meaning, and the exact one
// leaves the loop unreachable. The optimizer's next walk forwards each copy's parameters, folds its exit
// test, and the rebuild drops the loop (GCC's complete peeling, LLVM's full unrolling).
//
// A loop qualifies when it holds no other loop, has a preheader and one back edge, no value it defines is
// used outside it (each one leaves through an edge's arguments), it holds no inline assembly (whose labels
// a copy would repeat), and its header or latch ends in a branch on an integer comparison of a constant
// with a header parameter, or that parameter plus or minus a constant, the parameter starting at a
// constant and stepping by that addition. Its iterations then follow by the evaluator's own arithmetic.
//
// Vectorization (LLVM's LoopVectorize, GCC's tree-vectorize, for the simplest of their loops): a loop of
// a header that tests `i <u n` (or `i <s n` from a constant of at least 0) and one block that steps `i`
// by 1, whose other values are loads and stores of `base[i]` (each `base` the loop does not define),
// lane-wise arithmetic of them and of values defined before the loop, and reductions (a header parameter
// the block only combines with one such value by an integer `add`, `and`, `or` or `xor`, or a float
// `fadd` when the build allows reassociation) gets a copy that runs 16 bytes of lanes at a time,
// `vector` copies of them interleaved, while at least that many iterations are left; the loop runs the
// rest. A guard before the copy checks the count and that each stored range overlaps no other range the
// loop reads or writes through another base (same base, same element: an update in place).
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

/// A loop peels at most MAX_PEEL times.
pub const MAX_PEEL: u32 = 32;
// At most MAX_OUT of a loop's values are used outside it (`LoopOpt::close`).
const MAX_OUT: usize = 32;
// A loop versions on at most MAX_CHECKS bounds checks; a vectorized loop checks at most MAX_CHECKS pairs
// of ranges.
const MAX_CHECKS: usize = 8;
// The bytes of a vector the vectorizer makes.
const VBYTES: u32 = 16;

// What a vectorized loop's instruction is (`LoopOpt.vk`).
const VK_STEP: u8 = 1; // the counter's step
const VK_ADDR: u8 = 2; // `base + i * size + offset`
const VK_LANE: u8 = 3; // a lane value: a load or arithmetic
const VK_STORE: u8 = 4;
const VK_RED: u8 = 5; // a reduction's update

/// The peeling's scratch, reused from body to body.
pub struct LoopOpt {
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
    // Per block, the block of the body before the first transform whose dominators it has: itself, a
    // copy's original, a landing block's target, a guard block's preheader.
    proxy: Vector<u32>,
    latch: u32, // the loop's block whose edge goes back to its header (`shape`)
    // Bounds-check versioning (`checks`): the blocks whose branches the fast copy drops, the side each one
    // keeps (0: its taken edge, 1: the other), and the guard's comparisons (`n <= len` each).
    fixes: Vector<u32>,
    fside: Vector<u8>,
    gx: Vector<Value>,
    gy: Vector<Value>,
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
    vacc: Vector<u32>,
    vca: Vector<u32>,
    vcb: Vector<u32>,
    vsz: u32,
    vlanes: u32,
    vmap: Vector<Value>,
    vinv: Vector<Value>,
    vspl: Vector<Value>,
}

/// The instructions a loop transform's copies may take (0: none): full unrolling (all its copies),
/// versioning on bounds checks and unswitching (the loop itself), rotation (the header's copy); the
/// vectors a vectorized loop interleaves (0: no vectorization).
pub struct Budgets {
    pub peel: u32,
    pub version: u32,
    pub unswitch: u32,
    pub rotate: u32,
    pub vector: u32,
}

extend Budgets as Copy {}

extend LoopOpt {
    pub fn new() LoopOpt {
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
            proxy: Vector::<u32>::new(),
            latch: NONE,
            fixes: Vector::<u32>::new(),
            fside: Vector::<u8>::new(),
            gx: Vector::<Value>::new(),
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
            vacc: Vector::<u32>::new(),
            vca: Vector::<u32>::new(),
            vcb: Vector::<u32>::new(),
            vsz: 0,
            vlanes: 0,
            vmap: Vector::<Value>::new(),
            vinv: Vector::<Value>::new(),
            vspl: Vector::<Value>::new(),
        };
    }

    /// Transform the innermost loops of `b` within budgets `bu` (`inner`: per block its innermost loop's
    /// header, NONE outside loops; `lparent`: per header the header of the loop around it; `preh`: per
    /// header its preheader, NONE without one; `dpre` and `dpost`: per block its preorder and postorder
    /// numbers in the dominator tree); pointers are `ptr` bytes, the float rewrites `fmath` allows
    /// (`FM_*`), and `vec` the bytes of the widest vector the target holds in a register (0: none). A loop
    /// peels when its trip count is known, else vectorizes, else versions on its bounds checks, else
    /// unswitches. Whether any changed.
    pub fn run(
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
    ) bool {
        let cand = self.candidates(b, inner, lparent, preh);
        let mut any = false;
        for c in 0..cand.len() {
            let h = cand[c];
            let p = preh[h as usize];
            let size = self.shape(b, inner, h);
            if size == 0 {
                continue;
            }
            let u = self.latch;
            if size <= bu.peel {
                // The counted exit: a branch of the header or the latch.
                let mut n = self.trip(b, ptr, h, p, u, h);
                if n == 0 && u != h {
                    n = self.trip(b, ptr, h, p, u, u);
                }
                if n != 0 && n * size <= bu.peel {
                    if self.close(b, dpre, dpost) {
                        self.peel(b, h, p, n);
                        any = true;
                    }
                    continue;
                }
            }
            if bu.vector != 0 && vec >= VBYTES && self.vplan(b, ptr, fmath, h, p, u) {
                self.vectorize(b, ptr, h, p, u, bu.vector);
                any = true;
                continue;
            }
            if size <= bu.version && self.checks(b, ptr, h, p, u) {
                if self.close(b, dpre, dpost) {
                    self.version(b, h, p, VNONE);
                    any = true;
                }
                continue;
            }
            if size <= bu.unswitch {
                let g = self.invariant_branch(b);
                if g != VNONE && self.close(b, dpre, dpost) {
                    self.version(b, h, p, g);
                    any = true;
                }
            }
        }
        return any;
    }

    /// Rotate the innermost loops of `b` whose header holds at most `max` instructions before its branch
    /// (the tables as `run` takes them). Whether any changed.
    pub fn rotate(
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
            if body != NONE && self.close(b, dpre, dpost) {
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
        fill_bool(&mut self.inl, nb, false);
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

    // ---- Vectorization ----

    // Whether loop `h` (preheader `p`, latch `u`, its blocks `lblocks`) vectorizes (the module comment):
    // sets the plan (`vk` ..`vlanes`).
    fn vplan(self: &mut Self, b: &Body, ptr: u32, fmath: u8, h: u32, p: u32, u: u32) bool {
        if self.lblocks.len() != 2 || u == h {
            return false;
        }
        let hb = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let t = term(b, h);
        if (hb.flags & BLOCK_NOVEC) != 0 || hb.len != 2 || t.op != O_BR || (t.a & (VPARAM | VFLAG)) != 0 || t.a != hb.start || b.edge_target(
            t.b,
        ) != u && b.edge_target(t.c) != u {
            return false;
        }
        let ci = b.insts[t.a as usize];
        let in_taken = b.edge_target(t.b) == u;
        if ci.op != O_ICMP || b.edge_nargs(
            if in_taken {
                t.b;
            } else {
                t.c;
            },
        ) != 0 {
            return false;
        }
        // The test read as `q < n` on the in-loop side.
        let (q, n, cond) = if in_taken && (ci.aux == C_ULT || ci.aux == C_SLT) {
            (ci.a, ci.b, ci.aux);
        } else if in_taken && (ci.aux == C_UGT || ci.aux == C_SGT) {
            (ci.b, ci.a, ci.aux - C_SGT + C_SLT);
        } else if !in_taken && (ci.aux == C_UGE || ci.aux == C_SGE) {
            (ci.a, ci.b, ci.aux - C_SGE + C_SLT);
        } else if !in_taken && (ci.aux == C_ULE || ci.aux == C_SLE) {
            (ci.b, ci.a, ci.aux - C_SLE + C_SLT);
        } else {
            return false;
        };
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 || n == VNONE || self.defined_in(
            n,
        ) {
            return false;
        }
        let qt = b.params[(q & ~VPARAM) as usize];
        if !is_int(qt) || qt == T_I128 || type_bytes(qt, ptr) != ptr {
            return false;
        }
        if cond == C_SLT {
            let init = b.edge_arg(term(b, p).a, (q & ~VPARAM) - hb.param_start);
            if !is_const(b, init) || le::sign_ext(
                b.insts[init as usize].a as u64 | b.insts[init as usize].b as u64 << 32,
                type_bits(qt, ptr),
            ) < 0 {
                return false;
            }
        }
        self.viv = q;
        self.vn = n;
        self.vsigned = cond == C_SLT;
        let tu = term(b, u);
        if tu.op != O_JMP || b.edge_target(tu.a) != h {
            return false;
        }
        // The body's instructions: the step, the reductions, then the rest in order.
        fill_u8(&mut self.vk, ub.len as usize, 0);
        self.vred.truncate(0);
        self.vrup.truncate(0);
        self.vsz = 0;
        for k in 0..hb.param_len as u32 {
            let pv = VPARAM | hb.param_start + k;
            let a = b.edge_arg(tu.a, k);
            if !self.in_body(b, u, a) {
                return false;
            }
            let at = b.insts[a as usize];
            if pv == q {
                if at.op != O_ADD || !(at.a == q && is_one(b, at.b) || at.b == q && is_one(b, at.a)) {
                    return false;
                }
                self.vk[(a - ub.start) as usize] = VK_STEP;
                continue;
            }
            let ty = b.params[(hb.param_start + k) as usize];
            let int_op = at.op == O_ADD || at.op == O_AND || at.op == O_OR || at.op == O_XOR;
            let ok_op = is_int(ty) && ty != T_I128 && int_op || is_float(ty) && at.op == O_FADD && (fmath & FM_ASSOC) != 0;
            if !ok_op || at.ty != ty || !(at.a == pv) == !(at.b == pv) || self.reads(b, u, pv) != 1 || self.reads(
                b,
                u,
                a,
            ) != 1 || !self.lane_size(ty, ptr) {
                return false;
            }
            self.vk[(a - ub.start) as usize] = VK_RED;
            self.vred.push(pv);
            self.vrup.push(a);
        }
        // The rest: addresses, loads, arithmetic, stores.
        self.vacc.truncate(0);
        for i in ub.start..ub.start + ub.len - 1 {
            let x = (i - ub.start) as usize;
            let t = b.insts[i as usize];
            if self.vk[x] == VK_STEP {
                if self.reads(b, u, i) != 1 {
                    return false;
                }
                continue;
            }
            if self.vk[x] == VK_RED {
                let o = if contains(&self.vred, t.a) {
                    t.b;
                } else {
                    t.a;
                };
                if self.kind(b, u, o) != VK_LANE {
                    return false;
                }
                continue;
            }
            let k = self.vclass(b, ptr, u, t);
            if k == 0 {
                return false;
            }
            self.vk[x] = k;
            if t.op == O_LOAD || t.op == O_STORE {
                self.vacc.push(i);
            }
        }
        // The counter only steps and indexes.
        for i in ub.start..ub.start + ub.len {
            let x = (i - ub.start) as usize;
            if i < ub.start + ub.len - 1 && (self.vk[x] == VK_ADDR || self.vk[x] == VK_STEP) {
                continue;
            }
            self.outside_uses(b, b.insts[i as usize]);
            if contains(&self.uses, q) {
                return false;
            }
        }
        if self.vsz == 0 {
            return false;
        }
        self.vlanes = VBYTES / self.vsz;
        return self.vchecks(b);
    }

    // The kind (VK_*) instruction `t` of body `u` takes, 0 when it does not vectorize; sets the lane size
    // from a lane value's type.
    fn vclass(self: &mut Self, b: &Body, ptr: u32, u: u32, t: Inst) u8 {
        let op = t.op;
        if op == O_PTRADD {
            return if t.b == self.viv && t.a != VNONE && !self.defined_in(t.a) && t.aux != 0 {
                VK_ADDR;
            } else {
                0;
            };
        }
        if op == O_LOAD || op == O_STORE {
            let ty = if op == O_LOAD {
                t.ty;
            } else {
                value_type(b, t.b);
            };
            if (t.aux & MEM_VOLATILE) != 0 || is_vec(ty) || ty == T_PTR || !self.lane_size(ty, ptr) || self.kind(
                b,
                u,
                t.a,
            ) != VK_ADDR || b.insts[t.a as usize].aux as u32 != type_bytes(ty, ptr) {
                return 0;
            }
            if op == O_LOAD {
                return VK_LANE;
            }
            return if self.kind(b, u, t.b) == VK_LANE || !self.defined_in(t.b) {
                VK_STORE;
            } else {
                0;
            };
        }
        let int_op = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR || op == O_NEG || op == O_NOT || op == O_MUL;
        let float_op = op >= O_FADD && op <= O_FNEG;
        if !(is_int(t.ty) && t.ty != T_I128 && int_op || is_float(t.ty) && float_op) || !self.lane_size(t.ty, ptr) {
            return 0;
        }
        // No 64-bit lane multiply in the vector units of the targets.
        if op == O_MUL && type_bytes(t.ty, ptr) == 8 {
            return 0;
        }
        let unary = op == O_NEG || op == O_NOT || op == O_FNEG;
        let ka = self.kind(b, u, t.a);
        let kb = if unary {
            0u8;
        } else {
            self.kind(b, u, t.b);
        };
        let la = ka == VK_LANE;
        let lb = kb == VK_LANE;
        let oa = la || !self.defined_in(t.a);
        let ob = unary || lb || !self.defined_in(t.b);
        return if (la || lb) && oa && ob {
            VK_LANE;
        } else {
            0;
        };
    }

    // Whether scalar type `ty` has the plan's lane size, setting it when unset.
    fn lane_size(self: &mut Self, ty: u8, ptr: u32) bool {
        let n = type_bytes(ty, ptr);
        if n == 0 || n > 8 || VBYTES / n < 2 {
            return false;
        }
        if self.vsz == 0 {
            self.vsz = n;
        }
        return self.vsz == n;
    }

    // The plan's kind of value `v` defined in body `u` (0: none or outside it).
    fn kind(self: &Self, b: &Body, u: u32, v: Value) u8 {
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
    // access through another base; an access through the same base must be the same element. False when
    // that does not hold or the pairs are too many.
    fn vchecks(self: &mut Self, b: &Body) bool {
        self.vca.truncate(0);
        self.vcb.truncate(0);
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
                if oa.a == sa.a {
                    if (oa.c as i32) as i64 + (o.c as i32) as i64 != (sa.c as i32) as i64 + (s.c as i32) as i64 {
                        return false;
                    }
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
                    return false;
                }
                self.vca.push(self.vacc[x]);
                self.vcb.push(self.vacc[y]);
            }
        }
        return true;
    }

    // Vectorize loop `h` (preheader `p`, body `u`) as planned, `nv` vectors interleaved. The preheader
    // enters a guard that runs the vector loop or enters the loop through a new preheader; the vector
    // loop's exit reduces its accumulators and enters the loop with the iterations left.
    fn vectorize(self: &mut Self, b: &mut Body, ptr: u32, h: u32, p: u32, u: u32, nv: u32) {
        let hb = b.blocks[h as usize];
        let ub = b.blocks[u as usize];
        let l0 = b.locs[hb.start as usize];
        let qt = b.params[(self.viv & ~VPARAM) as usize];
        let step = self.vlanes * nv;
        let nred = self.vred.len() as u32;
        // The block numbers: guard, vector preheader, vector loop, vector exit, the loop's new preheader.
        let g = b.blocks.len() as u32;
        let vp = g + 1;
        let vl = g + 2;
        let vx = g + 3;
        let sp = g + 4;
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
                    C_SLT;
                } else {
                    C_ULT;
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
        let mk = self.vconst(b, qt, ~((step - 1) as u64), l0);
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
        let to_sp = b.edge(sp, self.args.as_slice());
        let none: []Value = [];
        let to_vp = b.edge(vp, none);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: ok, b: to_vp, c: to_sp }, l0);
        self.vblock(b, g, gstart, gps, hb.param_len, hb.flags, p);
        // The vector preheader: the end of the vector iterations, the splats, the accumulators' start.
        let pstart = b.insts.len() as u32;
        let iend = self.vi(b, Inst { op: O_ADD, ty: qt, aux: 0, a: i0, b: cnt, c: 0 }, l0);
        self.vinv.truncate(0);
        self.vspl.truncate(0);
        for i in ub.start..ub.start + ub.len - 1 {
            let x = (i - ub.start) as usize;
            let t = b.insts[i as usize];
            // A reduction's update reads its parameter and a lane value: no splat.
            if self.vk[x] == VK_LANE || self.vk[x] == VK_STORE {
                let f = op_info(t.op).form;
                if t.op == O_STORE {
                    self.vsplat(b, u, t.b, ptr, l0);
                } else if t.op != O_LOAD {
                    if lv::operand_a(f) {
                        self.vsplat(b, u, t.a, ptr, l0);
                    }
                    if lv::operand_b(f) {
                        self.vsplat(b, u, t.b, ptr, l0);
                    }
                }
            }
        }
        self.args.truncate(0);
        self.args.push(i0);
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            let vt = vec_type(rt, self.vlanes);
            let idv = self.identity(b, b.insts[self.vrup[r as usize] as usize].op, rt);
            let id = self.vsplat_const(b, vt, idv, l0);
            for _ in 0..nv {
                self.args.push(id);
            }
        }
        let to_vl = b.edge(vl, self.args.as_slice());
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_vl, b: 0, c: 0 }, l0);
        self.vblock(b, vp, pstart, b.params.len() as u32, 0, hb.flags, g);
        // The vector loop: the counter, the accumulators; `nv` copies of the body's lanes.
        let vps = b.params.len() as u32;
        b.params.push(qt);
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            for _ in 0..nv {
                b.params.push(vec_type(rt, self.vlanes));
            }
        }
        let lstart = b.insts.len() as u32;
        let vi = VPARAM | vps;
        fill(&mut self.vmap, (nv * ub.len) as usize, VNONE);
        for c in 0..nv {
            for i in ub.start..ub.start + ub.len - 1 {
                let x = i - ub.start;
                let t = b.insts[i as usize];
                let k = self.vk[x as usize];
                let at = (c * ub.len + x) as usize;
                if k == VK_ADDR {
                    // One address per iteration: the copies' accesses add their offsets to it.
                    self.vmap[at] = if c == 0 {
                        self.vi(
                            b,
                            Inst { op: O_PTRADD, ty: T_PTR, aux: t.aux, a: t.a, b: vi, c: t.c },
                            b.locs[i as usize],
                        );
                    } else {
                        self.vmap[x as usize];
                    };
                } else if k == VK_LANE || k == VK_STORE {
                    let mut nt = t;
                    let f = op_info(t.op).form;
                    if t.op != O_STORE {
                        nt.ty = vec_type(t.ty, self.vlanes);
                    }
                    if t.op == O_LOAD || t.op == O_STORE {
                        nt.c = (((t.c as i32) as i64 + (c * VBYTES) as i64) as i32) as u32;
                    }
                    if lv::operand_a(f) {
                        nt.a = self.vval(b, u, c, t.a);
                    }
                    if lv::operand_b(f) && t.b != VNONE {
                        nt.b = self.vval(b, u, c, t.b);
                    }
                    self.vmap[at] = self.vi(b, nt, b.locs[i as usize]);
                } else if k == VK_RED {
                    let r = self.red_of(i);
                    let acc = VPARAM | vps + 1 + r * nv + c;
                    let o = if t.a == self.vred[r as usize] {
                        t.b;
                    } else {
                        t.a;
                    };
                    let mut nt = t;
                    nt.ty = vec_type(t.ty, self.vlanes);
                    nt.a = acc;
                    nt.b = self.vval(b, u, c, o);
                    self.vmap[at] = self.vi(b, nt, b.locs[i as usize]);
                }
            }
        }
        let sk = self.vconst(b, qt, step, l0);
        let vnext = self.vi(b, Inst { op: O_ADD, ty: qt, aux: 0, a: vi, b: sk, c: 0 }, l0);
        let more = self.vi(b, Inst { op: O_ICMP, ty: T_I8, aux: C_ULT, a: vnext, b: iend, c: 0 }, l0);
        self.args.truncate(0);
        self.args.push(vnext);
        for r in 0..nred {
            for c in 0..nv {
                let x = self.vrup[r as usize] - ub.start;
                self.args.push(self.vmap[(c * ub.len + x) as usize]);
            }
        }
        let back = b.edge(vl, self.args.as_slice());
        let out = b.edge(vx, self.args.as_slice()[1..self.args.len()]);
        let _ = self.vi(b, Inst { op: O_BR, ty: T_NONE, aux: 0, a: more, b: back, c: out }, l0);
        self.vblock(b, vl, lstart, vps, (1 + nred * nv) as u16, hb.flags, vp);
        // The vector exit: each reduction's accumulators combined and reduced into its start value.
        let xps = b.params.len() as u32;
        for r in 0..nred {
            let rt = b.params[(self.vred[r as usize] & ~VPARAM) as usize];
            for _ in 0..nv {
                b.params.push(vec_type(rt, self.vlanes));
            }
        }
        let xstart = b.insts.len() as u32;
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            let pv = VPARAM | hb.param_start + q;
            if pv == self.viv {
                self.args.push(iend);
                continue;
            }
            let r = self.red_param(pv);
            let rt = b.params[(pv & ~VPARAM) as usize];
            let op = b.insts[self.vrup[r as usize] as usize].op;
            let vt = vec_type(rt, self.vlanes);
            let mut acc = VPARAM | xps + r * nv;
            for c in 1..nv {
                acc = self.vi(b, Inst { op: op, ty: vt, aux: 0, a: acc, b: VPARAM | xps + r * nv + c, c: 0 }, l0);
            }
            let code = (core::OP_SIMD + if op == O_AND {
                core::SIMD_REDUCE_AND;
            } else if op == O_OR {
                core::SIMD_REDUCE_OR;
            } else if op == O_XOR {
                core::SIMD_REDUCE_XOR;
            } else {
                core::SIMD_REDUCE_ADD;
            } as u32) as u16;
            let one = [acc];
            let at = b.pool_list(one[0..1]);
            let red = self.vi(b, Inst { op: O_VOP, ty: rt, aux: code, a: at, b: 1, c: VNONE }, l0);
            let r0 = VPARAM | gps + (pv & ~VPARAM) - hb.param_start;
            let sum = self.vi(b, Inst { op: op, ty: rt, aux: 0, a: r0, b: red, c: 0 }, l0);
            self.args.push(sum);
        }
        let to_sp2 = b.edge(sp, self.args.as_slice());
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_sp2, b: 0, c: 0 }, l0);
        self.vblock(b, vx, xstart, xps, (nred * nv) as u16, hb.flags, vl);
        // The loop's new preheader.
        let sps = self.vblock_params(b, h);
        let sstart = b.insts.len() as u32;
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.args.push(VPARAM | sps + q);
        }
        let to_h = b.edge(h, self.args.as_slice());
        let _ = self.vi(b, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: to_h, b: 0, c: 0 }, l0);
        self.vblock(b, sp, sstart, sps, hb.param_len, hb.flags, g);
        // The preheader enters the guard; the loop runs what the vectors leave and vectorizes no more.
        let pe = term(b, p).a;
        b.pool[pe as usize] = g;
        b.blocks.index_mut(h as usize).flags |= BLOCK_NOVEC;
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
        let lo = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: a.aux, a: a.a, b: i0, c: off }, l);
        let hi = self.vi(b, Inst { op: O_PTRADD, ty: T_PTR, aux: a.aux, a: a.a, b: self.vn, c: off }, l);
        return lo, hi;
    }

    // The splat of value `v` of body `u` when the loop does not define it (a constant as a wide constant,
    // else through a stack slot), recorded in `vinv`/`vspl` once.
    fn vsplat(self: &mut Self, b: &mut Body, u: u32, v: Value, ptr: u32, l: u32) {
        if v == VNONE || self.in_body(b, u, v) || contains(&self.vinv, v) {
            return;
        }
        let ty = value_type(b, v);
        let vt = vec_type(ty, self.vlanes);
        let mut sv = VNONE;
        if (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_ICONST || b.insts[v as usize].op == O_FCONST) {
            let t = b.insts[v as usize];
            sv = self.vsplat_const(b, vt, t.a as u64 | t.b as u64 << 32, l);
        } else {
            let s = b.slots.len() as u32;
            b.slots.push(Slot { size: VBYTES, align_log2: 4 });
            let at = self.vi(b, Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: 0, c: 0 }, l);
            let al = type_bytes(ty, ptr).trailing_zeros() as u16;
            for k in 0..self.vlanes {
                let _ = self.vi(b, Inst { op: O_STORE, ty: T_NONE, aux: al, a: at, b: v, c: k * self.vsz }, l);
            }
            sv = self.vi(b, Inst { op: O_LOAD, ty: vt, aux: 4, a: at, b: VNONE, c: 0 }, l);
        }
        self.vinv.push(v);
        self.vspl.push(sv);
    }

    // Vector type `vt` with every lane the low bits of `x`, as a wide constant.
    fn vsplat_const(self: &mut Self, b: &mut Body, vt: u8, x: u64, l: u32) Value {
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
                0x80000000u64;
            } else {
                0x8000000000000000u64;
            };
        }
        return 0;
    }

    // Value `v` of body `u` in interleaved copy `c` of the vector loop: a lane value's copy, else its
    // splat.
    fn vval(self: &Self, b: &Body, u: u32, c: u32, v: Value) Value {
        if self.in_body(b, u, v) {
            let ub = b.blocks[u as usize];
            return self.vmap[(c * ub.len + v - ub.start) as usize];
        }
        for k in 0..self.vinv.len() {
            if self.vinv[k] == v {
                return self.vspl[k];
            }
        }
        assert(false, "loops: a vector operand without a splat");
        return VNONE;
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
            x;
        } else {
            y;
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
            body;
        } else {
            NONE;
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
        return b.edge(b.edge_target(e), self.args.as_slice());
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
                    self.hc(b, h, v);
                } else {
                    v;
                },
            );
        }
        if tg == body {
            for j in 0..self.hvals.len() {
                let v = self.hvals[j];
                self.args.push(
                    if copy {
                        self.hc(b, h, v);
                    } else {
                        v;
                    },
                );
            }
        }
        return b.edge(tg, self.args.as_slice());
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
            size;
        } else {
            0;
        };
    }

    // Make the loop's values leave it through edges only: the values the blocks outside it use (`lout`)
    // become parameters of a landing block per exit target that dominates such a use (`dpre`, `dpost`:
    // the dominator tree's numbers, by `proxy`), which that target's edges from the loop enter instead
    // and which jumps on to it; the uses take the parameters of the landing block of the target that
    // dominates them. False when a use has no such target, or its target has an edge from outside the
    // loop.
    fn close(self: &mut Self, b: &mut Body, dpre: []u32, dpost: []u32) bool {
        let nb = b.blocks.len();
        self.lout.truncate(0);
        fill(&mut self.tgt_of, nb, NONE);
        for k in 0..nb {
            if self.inl[k] {
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
        }
        for k in 0..nb {
            if self.inl[k] {
                continue;
            }
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]);
                for q in 0..nb {
                    if self.tgt_of[q] == s {
                        return false;
                    }
                }
            }
        }
        // A landing block per target in use: the target's parameters, then the values that leave; it
        // jumps on. The loop's exits into the target enter it with the values that leave.
        self.lbase.truncate(0);
        for q in 0..self.tgts.len() {
            let tg = self.tgts[q];
            let mut used = false;
            for k in 0..nb {
                used = used || self.tgt_of[k] == tg;
            }
            if !used {
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
            let e = b.edge(tg, self.args.as_slice());
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
        return true;
    }

    // Whether loop `h` (preheader `p`, latch `u`) has bounds checks a guard before it proves: branches
    // into a cold block on `i <u len` (or `len >u i`) with `len` defined outside the loop and `i` the header
    // parameter that the header's exit test keeps below `n` (`i <u n`, or `i <s n` with `i` starting at a
    // constant of at least 0 and stepping by 1), `n` defined outside the loop. Each check holds wherever
    // `n <= len` does: sets `fixes`, `fside` and the guard's `gx` (the `n`s) and `gy` (the `len`s).
    fn checks(self: &mut Self, b: &Body, ptr: u32, h: u32, p: u32, u: u32) bool {
        self.fixes.truncate(0);
        self.fside.truncate(0);
        self.gx.truncate(0);
        self.gy.truncate(0);
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
        // The comparison read as `q < n` on the in-loop side.
        let (q, n, cond) = if in_taken && (ci.aux == C_ULT || ci.aux == C_SLT) {
            (ci.a, ci.b, ci.aux);
        } else if in_taken && (ci.aux == C_UGT || ci.aux == C_SGT) {
            (ci.b, ci.a, ci.aux - C_SGT + C_SLT);
        } else if !in_taken && (ci.aux == C_UGE || ci.aux == C_SGE) {
            (ci.a, ci.b, ci.aux - C_SGE + C_SLT);
        } else if !in_taken && (ci.aux == C_ULE || ci.aux == C_SLE) {
            (ci.b, ci.a, ci.aux - C_SLE + C_SLT);
        } else {
            return false;
        };
        let hb = b.blocks[h as usize];
        if (q & VPARAM) == 0 || (q & ~VPARAM) < hb.param_start || (q & ~VPARAM) >= hb.param_start + hb.param_len as u32 {
            return false;
        }
        if self.defined_in(n) || n == VNONE {
            return false;
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
            // `q <u len` holds on the edge that does not fail.
            let ok = bc.a == q && (bc.aux == C_ULT && cold_c || bc.aux == C_UGE && cold_b) || bc.b == q && (bc.aux == C_UGT && cold_c || bc.aux == C_ULE && cold_b);
            if !ok {
                continue;
            }
            let len = if bc.a == q {
                bc.b;
            } else {
                bc.a;
            };
            if len == VNONE || self.defined_in(len) || value_type(b, len) != value_type(b, n) {
                continue;
            }
            if self.fixes.len() == MAX_CHECKS {
                break;
            }
            self.fixes.push(k);
            self.fside.push(
                if cold_c {
                    0u8;
                } else {
                    1u8;
                },
            );
            if !contains(&self.gy, len) {
                self.gx.push(n);
                self.gy.push(len);
            }
        }
        self.gcond = C_ULE;
        return self.fixes.len() != 0 && !self.guarded(b, p);
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
                let c = b.insts.len() as u32;
                b.insts.push(Inst { op: O_ICMP, ty: T_I8, aux: self.gcond, a: self.gx[k], b: self.gy[k], c: 0 });
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
        }
        self.args.truncate(0);
        for q in 0..hb.param_len as u32 {
            self.args.push(VPARAM | ps + q);
        }
        // The two preheaders follow the guard block.
        let ein = b.edge(gb + 1, self.args.as_slice());
        let eout = b.edge(gb + 2, self.args.as_slice());
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
        let e = b.edge(to, self.args.as_slice());
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
        return b.edge(land, self.args.as_slice());
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
        return b.edge(b.edge_target(e), self.args.as_slice());
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
            (ci.a, ci.b, false);
        } else if is_const(b, ci.a) {
            (ci.b, ci.a, true);
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
                le::icmp(ci.aux, ty, ptr, k, xv);
            } else {
                le::icmp(ci.aux, ty, ptr, xv, k);
            };
            if holds == out_taken {
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
                h;
            } else {
                base + nl + self.lpos(h);
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
            next_h;
        } else if self.inl[tg as usize] {
            self.bmap[tg as usize];
        } else {
            tg;
        };
        self.args.truncate(0);
        for q in 0..b.edge_nargs(e) {
            self.args.push(self.cv(b.edge_arg(e, q)));
        }
        return b.edge(nt, self.args.as_slice());
    }
}

// The terminator of block `k`.
const fn term(b: &Body, k: u32) Inst {
    let bk = b.blocks[k as usize];
    return b.insts[(bk.start + bk.len - 1) as usize];
}

// Branch terminator of block `k` as a jump to its taken edge (`side` 0) or its other one.
fn fix_branch(b: &mut Body, k: u32, side: u8) {
    let bk = b.blocks[k as usize];
    let i = (bk.start + bk.len - 1) as usize;
    let t = b.insts[i];
    let e = if side == 0 {
        t.b;
    } else {
        t.c;
    };
    b.insts[i] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 };
}

// Whether block `k` is a failure path: cold, or ending in a panic or a trap.
fn cold(b: &Body, k: u32) bool {
    let op = term(b, k).op;
    return (b.blocks[k as usize].flags & BLOCK_COLD) != 0 || op == O_PANIC || op == O_UNREACHABLE;
}

// Whether `vs` holds `v`.
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

// Whether `v` is the integer constant 1.
fn is_one(b: &Body, v: Value) bool {
    return is_const(b, v) && b.insts[v as usize].a == 1 && b.insts[v as usize].b == 0;
}

fn fill_u8(v: &mut Vector<u8>, n: usize, x: u8) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

// Whether `v` is an instruction's value that is an integer constant.
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
        O_ADD;
    } else {
        O_SUB;
    };
}

fn fill(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

fn fill_bool(v: &mut Vector<bool>, n: usize, x: bool) {
    v.truncate(0);
    v.resize_default(n);
    if x {
        v.as_mut_slice().fill(x);
    }
}
