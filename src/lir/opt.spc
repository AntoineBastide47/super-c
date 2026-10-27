// The optimizer of an optimizing build: one walk of a LIR body's dominator tree, after Click's global
// value numbering and Cranelift's scoped elaboration (Fallin 2026: the hash-consed dominator walk carries
// most of the gain of its e-graph). Each instruction is rewritten in place as the walk reaches it:
//
// - its operands take the values that replaced theirs;
// - an operation of constants folds to a constant by the evaluator's own arithmetic (`le::int_fold`),
//   an identity (`x + 0`, `x * 1`, `x & x`, ...) to its operand, a branch on a constant to a jump;
// - a pure operation a dominating block already computed becomes that value;
// - a load of a place a dominating instruction read or stored in the same memory state becomes that
//   value (each write starts a memory state, and a block whose one predecessor is its dominator
//   continues that block's last);
// - a load of read-only data folds to the constant it reads;
// - a pure operation of loop-invariant operands that cannot trap moves to the loop's preheader, and so
//   does a load of a field of a slot, a data symbol, an aggregate parameter or a reference parameter's
//   referent in a loop that writes none of the memory it may read (`classes`: an exclusive reference
//   parameter's referent is reached through that parameter alone).
//
// A rebuild then drops what was replaced and places what moved, and the lowering's `tidy` removes what
// nothing uses. Every step is linear in the body, the loop membership tests in its nesting depth.
import lir::ir as *;
import ir::core as core;
import lir::eval as le;
import lir::verify as lv;
import std::parallel::data as parallel;
import lir::inline as il;
import lir::promote as pr;
import lir::loops as lu;
import stdlib;

// `Opt.repl` of an instruction without a value that the rebuild drops.
const DROPPED: u32 = 0xFFFFFFFE;

// The scoped tables (`Opt.log`).
const LOG_PURE: u8 = 0;
const LOG_MEM: u8 = 1;
const LOG_COND: u8 = 2;
// `Opt::private_load`'s answers besides a value, and the memory state of the loads it keeps.
const PRIV_NONE: Value = VNONE;
const PRIV_KEPT: Value = VNONE - 1;
const KEPT_STATE: u32 = NONE;
// Private memory with more writes than this has no load promoted or kept (`private_load` scans them).
const SLOT_WRITES_MAX: u32 = 64;
// The loop transforms run at most LOOP_ROUNDS times per body: each round may double a loop.
const LOOP_ROUNDS: u32 = 2;

/// The optimizer's scratch, reused from body to body.
pub struct Opt {
    // The control flow graph: per block, its successors and predecessors as ranges of one list each.
    succ_at: Vector<u32>,
    succs: Vector<u32>,
    pred_at: Vector<u32>,
    preds: Vector<u32>,
    edges: Vector<u32>,
    // Reverse postorder, immediate dominators and the dominator tree (children as ranges; preorder and
    // postorder numbers for the dominance test).
    rpo: Vector<u32>,
    order: Vector<u32>,
    idom: Vector<u32>,
    kid_at: Vector<u32>,
    kids: Vector<u32>,
    dpre: Vector<u32>,
    dpost: Vector<u32>,
    // Loops: per block, its innermost loop's header (NONE outside loops); per header, the header of the
    // loop around it, its preheader (NONE: none) and the alias classes its blocks write (`class_bit`).
    inner: Vector<u32>,
    lparent: Vector<u32>,
    preh: Vector<u32>,
    writes: Vector<u64>,
    // The alias class of each instruction's and each block parameter's value (`classes`).
    icls: Vector<u8>,
    pcls: Vector<u8>,
    mark: Vector<u32>,
    // Per block parameter its block; per instruction its block (a moved one's new block), what replaced
    // it (VNONE: nothing) and whether it moved.
    pblock: Vector<u32>,
    blk_of: Vector<u32>,
    repl: Vector<u32>,
    prepl: Vector<u32>, // per block parameter, the value that replaced it (VNONE: none)
    frepl: Vector<u32>, // per checked operation, the value that replaced its flag (VNONE: none)
    extra: Vector<u32>, // the constants the walk made, which the entry block starts with
    made: Map<u64, u32>, // a made constant's hash to the constant
    moved: Vector<bool>,
    hoisted: Vector<u64>, // block << 32 | instruction, in the order they moved
    // The scoped tables: a pure instruction's hash to the instruction, a memory place's hash to its
    // `places` entry, a branch condition the edge into the scope decides to 0 or 1. `log` holds each
    // insertion of the open scopes: its table, key and the entry it replaced (NONE: none).
    pure: Map<u64, u32>,
    mem: Map<u64, u32>,
    cond: Map<u64, u32>,
    log: Vector<(u8, u64, u32)>,
    places: Vector<Place>,
    state: u32, // the current memory state
    // Private memory (`slot_writes`): the slots, then the aggregate arguments (each a copy the callee
    // owns). Per instruction the one its address value points into (NONE: none) and the offset; per one
    // whether its address escapes; the writes, by place (`wat`).
    sbase: Vector<u32>,
    soff: Vector<i64>,
    sesc: Vector<bool>,
    wr: Vector<SlotWrite>,
    wat: Vector<u32>,
    wl: Vector<SlotWrite>,
    end_state: Vector<u32>, // per block, its state at its end
    stack: Vector<u64>,
    work: Vector<u32>,
    // The rebuild.
    bmap: Vector<u32>, // per block, its new number (NONE: unreached)
    in_at: Vector<u32>, // per block, the range of `ins` (and `insrc`) of the edges into it
    ins: Vector<u32>,
    insrc: Vector<u32>, // the block each of those edges leaves
    nxt: Vector<u32>, // per block, the block that continues it (NONE: none)
    sread: Vector<bool>, // per slot, whether it is read (`slot_reads`)
    done_pool: Vector<bool>, // per pool word, whether it is renumbered
    pmap: Vector<u32>, // per block parameter, its new number
    params: Vector<u8>,
    live: Vector<bool>,
    uses: Vector<Value>,
    newidx: Vector<u32>,
    into: Vector<u32>,
    done: Vector<bool>, // per block, whether another block's chain continues into it
    insts: Vector<Inst>,
    locs: Vector<u32>,
    inls: Vector<u32>,
    blocks: Vector<Block>,
    // Promotion of private slots (`lir::promote`) and the body it builds.
    prom: pr::Promoter,
    pbody: Body,
    unr: lu::LoopOpt,
}

/// What `optimize` does: the inline budget, and the loop transforms' budgets.
pub struct Config {
    pub inline: il::Budget,
    pub loops: lu::Budgets,
}

extend Config as Copy {}

// A write into private memory whose address does not escape: bytes `off` to `end` of `slot` (`Opt.sbase`),
// by store `inst` in block `blk` (NONE: a copy or a fill).
struct SlotWrite {
    pub slot: u32,
    pub off: i64,
    pub end: i64,
    pub inst: u32,
    pub blk: u32,
}

extend SlotWrite as Copy {}

// A memory place in a memory state, and the value it holds.
struct Place {
    pub addr: u32,
    pub off: u32,
    pub ty: u8,
    pub state: u32,
    pub val: u32,
}

extend Place as Copy {}

extend Opt {
    pub fn new() Opt {
        return Opt {
            succ_at: Vector::<u32>::new(),
            succs: Vector::<u32>::new(),
            pred_at: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            edges: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            kid_at: Vector::<u32>::new(),
            kids: Vector::<u32>::new(),
            dpre: Vector::<u32>::new(),
            dpost: Vector::<u32>::new(),
            inner: Vector::<u32>::new(),
            lparent: Vector::<u32>::new(),
            preh: Vector::<u32>::new(),
            writes: Vector::<u64>::new(),
            icls: Vector::<u8>::new(),
            pcls: Vector::<u8>::new(),
            mark: Vector::<u32>::new(),
            pblock: Vector::<u32>::new(),
            blk_of: Vector::<u32>::new(),
            repl: Vector::<u32>::new(),
            moved: Vector::<bool>::new(),
            hoisted: Vector::<u64>::new(),
            pure: Map::<u64, u32>::new(),
            mem: Map::<u64, u32>::new(),
            cond: Map::<u64, u32>::new(),
            log: Vector::<(u8, u64, u32)>::new(),
            places: Vector::<Place>::new(),
            sbase: Vector::<u32>::new(),
            soff: Vector::<i64>::new(),
            sesc: Vector::<bool>::new(),
            wr: Vector::<SlotWrite>::new(),
            wat: Vector::<u32>::new(),
            wl: Vector::<SlotWrite>::new(),
            state: 0,
            end_state: Vector::<u32>::new(),
            stack: Vector::<u64>::new(),
            work: Vector::<u32>::new(),
            bmap: Vector::<u32>::new(),
            in_at: Vector::<u32>::new(),
            ins: Vector::<u32>::new(),
            insrc: Vector::<u32>::new(),
            nxt: Vector::<u32>::new(),
            sread: Vector::<bool>::new(),
            done_pool: Vector::<bool>::new(),
            prepl: Vector::<u32>::new(),
            frepl: Vector::<u32>::new(),
            extra: Vector::<u32>::new(),
            made: Map::<u64, u32>::new(),
            pmap: Vector::<u32>::new(),
            params: Vector::<u8>::new(),
            live: Vector::<bool>::new(),
            uses: Vector::<Value>::new(),
            newidx: Vector::<u32>::new(),
            into: Vector::<u32>::new(),
            done: Vector::<bool>::new(),
            insts: Vector::<Inst>::new(),
            locs: Vector::<u32>::new(),
            inls: Vector::<u32>::new(),
            blocks: Vector::<Block>::new(),
            prom: pr::Promoter::new(),
            pbody: Body::new(),
            unr: lu::LoopOpt::new(),
        };
    }

    /// Optimize body `b` of package `pk`; with `force` the rebuild runs though nothing changed (after the
    /// inliner, which leaves blocks the entry may not reach). Whether it changed.
    pub fn run(self: &mut Self, pk: &Package, b: &mut Body, force: bool) bool {
        if b.naked {
            return false;
        }
        self.graph(b);
        self.dominators(b);
        self.loops(b);
        self.slot_writes(pk, b);
        let changed = self.walk(pk, b) || force;
        if changed {
            self.rebuild(b);
        }
        // SC_LIR_PROMOTE=0 promotes nothing (a debugging aid).
        if b.slots.len() == 0 || stdlib::env_is("SC_LIR_PROMOTE", "0") {
            return changed;
        }
        // Promotion, once the walk forwarded the parameters an inlined body's entry takes (a slot's
        // address among them); it keeps the blocks and their edges' targets, so the graph and the
        // dominators stand for the walk that follows it.
        self.graph(b);
        self.dominators(b);
        let promoted = self.prom.run(
            b,
            self.succ_at.as_slice(),
            self.succs.as_slice(),
            self.pred_at.as_slice(),
            self.preds.as_slice(),
            self.idom.as_slice(),
            self.order.as_slice(),
            self.kid_at.as_slice(),
            self.kids.as_slice(),
            pk.ptr_bytes,
            &mut self.pbody,
        );
        if !promoted {
            return changed;
        }
        let nb = replace(&mut self.pbody, Body::new());
        self.pbody = replace(b, nb);
        self.loops(b);
        self.slot_writes(pk, b);
        let _ = self.walk(pk, b);
        self.rebuild(b);
        return true;
    }

    /// Transform the innermost loops of body `b` (`lir::loops`) within budgets `bu`, then optimize it
    /// again. Whether any changed.
    pub fn loop_opts(self: &mut Self, pk: &Package, b: &mut Body, bu: lu::Budgets) bool {
        if b.naked {
            return false;
        }
        self.graph(b);
        self.dominators(b);
        self.loops(b);
        let any = self.unr.run(
            b,
            pk.ptr_bytes,
            bu,
            self.inner.as_slice(),
            self.lparent.as_slice(),
            self.preh.as_slice(),
            self.dpre.as_slice(),
            self.dpost.as_slice(),
        );
        if !any {
            return false;
        }
        let _ = self.run(pk, b, true);
        return true;
    }

    // ---- Analysis --------------------------------------------------------------------------------------

    fn graph(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.succ_at.truncate(0);
        self.succs.truncate(0);
        fill(&mut self.pred_at, nb + 1, 0);
        for k in 0..nb {
            self.succ_at.push(self.succs.len() as u32);
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]);
                self.succs.push(s);
                self.pred_at[s as usize + 1] += 1;
            }
        }
        self.succ_at.push(self.succs.len() as u32);
        for k in 0..nb {
            self.pred_at[k + 1] += self.pred_at[k];
        }
        fill(&mut self.preds, self.succs.len(), 0);
        fill(&mut self.work, nb, 0);
        for k in 0..nb {
            for e in self.succ_at[k]..self.succ_at[k + 1] {
                let s = self.succs[e as usize] as usize;
                self.preds[(self.pred_at[s] + self.work[s]) as usize] = k as u32;
                self.work[s] += 1;
            }
        }
        // Postorder by an explicit-stack depth-first search (block << 1 | finished), then its reverse.
        fill(&mut self.rpo, nb, NONE);
        self.work.truncate(0);
        self.stack.truncate(0);
        self.stack.push(0);
        // Each pop finishes a block, visits one, or drops a repeat: at most 2 per block and 1 per edge.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = (x >> 1) as usize;
            if (x & 1) != 0 {
                self.work.push(k as u32);
                continue;
            }
            if self.rpo[k] != NONE {
                continue;
            }
            self.rpo[k] = 0;
            self.stack.push(k as u64 << 1 | 1);
            for e in self.succ_at[k]..self.succ_at[k + 1] {
                let s = self.succs[e as usize];
                if self.rpo[s as usize] == NONE {
                    self.stack.push(s as u64 << 1);
                }
            }
        }
        self.order.truncate(0);
        let n = self.work.len();
        for i in 0..n {
            let k = self.work[n - 1 - i];
            self.rpo[k as usize] = i as u32;
            self.order.push(k);
        }
    }

    // Immediate dominators by Cooper, Harvey and Kennedy's iteration in reverse postorder, then the
    // dominator tree's children and its preorder and postorder numbers.
    fn dominators(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.idom, nb, NONE);
        self.idom[0] = 0;
        let mut changed = true;
        // A reducible graph settles in two passes; any graph in at most its block count.
        let mut passes: usize = 0;
        while changed && passes <= nb {
            changed = false;
            passes += 1;
            for i in 1..self.order.len() {
                let k = self.order[i] as usize;
                let mut d = NONE;
                for p in self.pred_at[k]..self.pred_at[k + 1] {
                    let q = self.preds[p as usize];
                    if self.idom[q as usize] == NONE {
                        continue;
                    }
                    d = if d == NONE {
                        q;
                    } else {
                        self.intersect(d, q);
                    };
                }
                if d != self.idom[k] {
                    self.idom[k] = d;
                    changed = true;
                }
            }
        }
        fill(&mut self.kid_at, nb + 1, 0);
        for i in 1..self.order.len() {
            self.kid_at[self.idom[self.order[i] as usize] as usize + 1] += 1;
        }
        for k in 0..nb {
            self.kid_at[k + 1] += self.kid_at[k];
        }
        fill(&mut self.kids, self.order.len(), 0);
        fill(&mut self.work, nb, 0);
        for i in 1..self.order.len() {
            let k = self.order[i];
            let d = self.idom[k as usize] as usize;
            self.kids[(self.kid_at[d] + self.work[d]) as usize] = k;
            self.work[d] += 1;
        }
        fill(&mut self.dpre, nb, 0);
        fill(&mut self.dpost, nb, 0);
        let mut pre: u32 = 0;
        let mut post: u32 = 0;
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is pushed and finished once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = (x >> 1) as usize;
            if (x & 1) != 0 {
                self.dpost[k] = post;
                post += 1;
                continue;
            }
            self.dpre[k] = pre;
            pre += 1;
            self.stack.push(k as u64 << 1 | 1);
            for c in self.kid_at[k]..self.kid_at[k + 1] {
                self.stack.push(self.kids[c as usize] as u64 << 1);
            }
        }
    }

    const fn intersect(self: &Self, a0: u32, c0: u32) u32 {
        let mut a = a0;
        let mut c = c0;
        // Each step climbs one dominator: at most the block count in all.
        while a != c {
            while self.rpo[a as usize] > self.rpo[c as usize] {
                a = self.idom[a as usize];
            }
            while self.rpo[c as usize] > self.rpo[a as usize] {
                c = self.idom[c as usize];
            }
        }
        return a;
    }

    // The alias class of every address value: CL_NOALIAS + k for one that comes from exclusive reference
    // parameter k (`Body.refs`) through address arithmetic, selects and block parameters, CL_OTHER for one
    // that comes from none, CL_MANY for one that may come from several. Two accesses of different classes,
    // neither CL_MANY, touch different bytes: the language makes the parameter the only path to its
    // referent during the call. A parameter whose value escapes (any use but as an access's address,
    // address arithmetic, a select, a comparison or a block argument) is not exclusive here: another
    // pointer may hold it. Joins at block parameters iterate in reverse postorder up to CLASS_ROUNDS
    // times; a body they do not settle in that many has no exclusive parameter.
    fn classes(self: &mut Self, b: &Body) {
        fill(&mut self.icls, b.insts.len(), CL_OTHER);
        fill(&mut self.pcls, b.params.len(), CL_OTHER);
        let e = b.blocks[0];
        let mut seeds: u64 = 0;
        for k in 0..b.refs.len() {
            if (b.refs[k] & REF_NOALIAS) != 0 && k < (CL_MANY - CL_NOALIAS) as usize && k < e.param_len as usize {
                seeds |= 1u64 << k as u64;
            }
        }
        // The second pass runs without the parameters the first found escaping.
        for _ in 0..2 {
            if seeds == 0 || !self.class_flow(b, seeds) {
                fill(&mut self.icls, b.insts.len(), CL_OTHER);
                fill(&mut self.pcls, b.params.len(), CL_OTHER);
                return;
            }
            let kept = seeds & ~self.escaped(b);
            if kept == seeds {
                return;
            }
            seeds = kept;
        }
    }

    // The classes of `classes` from the parameters `seeds` marks: whether the joins settled.
    fn class_flow(self: &mut Self, b: &Body, seeds: u64) bool {
        let e = b.blocks[0];
        for i in 0..b.insts.len() {
            let op = b.insts[i].op;
            self.icls[i] = if op == O_PTRADD || op == O_SELECT {
                CL_UNSET;
            } else {
                CL_OTHER;
            };
        }
        fill(&mut self.pcls, b.params.len(), CL_UNSET);
        for q in e.param_start..e.param_start + e.param_len as u32 {
            let k = q - e.param_start;
            self.pcls[q as usize] = if k < 64 && (seeds >> k as u64 & 1) != 0 {
                CL_NOALIAS + k as u8;
            } else {
                CL_OTHER;
            };
        }
        // Each round joins every value once; a value's class rises at most twice.
        for _ in 0..CLASS_ROUNDS {
            let mut changed = false;
            for o in 0..self.order.len() {
                let k = self.order[o];
                let bk = b.blocks[k as usize];
                for i in bk.start..bk.start + bk.len {
                    let t = b.insts[i as usize];
                    let c = if t.op == O_PTRADD {
                        self.class(t.a);
                    } else if t.op == O_SELECT {
                        join(self.class(t.b), self.class(t.c));
                    } else {
                        CL_OTHER;
                    };
                    if (t.op == O_PTRADD || t.op == O_SELECT) && c != self.icls[i as usize] {
                        self.icls[i as usize] = c;
                        changed = true;
                    }
                }
                b.succ_edges(term(b, k), &mut self.edges);
                for x in 0..self.edges.len() {
                    let ed = self.edges[x];
                    let s = b.blocks[b.edge_target(ed) as usize];
                    for a in 0..b.edge_nargs(ed) {
                        let q = (s.param_start + a) as usize;
                        let c = join(self.pcls[q], self.class(b.edge_arg(ed, a)));
                        if c != self.pcls[q] {
                            self.pcls[q] = c;
                            changed = true;
                        }
                    }
                }
            }
            if !changed {
                // A value of no reachable definition is no parameter's.
                for i in 0..self.icls.len() {
                    if self.icls[i] == CL_UNSET {
                        self.icls[i] = CL_OTHER;
                    }
                }
                for q in 0..self.pcls.len() {
                    if self.pcls[q] == CL_UNSET {
                        self.pcls[q] = CL_OTHER;
                    }
                }
                return true;
            }
        }
        return false;
    }

    // The parameters (bits) whose value escapes: a use of a value of their class but as an access's
    // address, address arithmetic's base, a select's operand, a comparison's operand or a block argument.
    fn escaped(self: &mut Self, b: &Body) u64 {
        let mut out: u64 = 0;
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let op = t.op;
            if op == O_LOAD || op == O_MEMCPY || op == O_MEMSET || op == O_PTRADD || op == O_SELECT || op == O_ICMP || op == O_JMP || op == O_BR || op == O_SWITCH {
                continue;
            }
            if op == O_STORE {
                out |= class_bit(self.class(t.b));
                continue;
            }
            lv::uses(b, t, &mut self.uses);
            for u in 0..self.uses.len() {
                out |= class_bit(self.class(self.uses[u]));
            }
        }
        return out >> 1;
    }

    // The alias class of value `v` (`classes`); CL_MANY for an instruction made after them.
    const fn class(self: &Self, v: Value) u8 {
        if v == VNONE || (v & VFLAG) != 0 {
            return CL_OTHER;
        }
        if (v & VPARAM) != 0 {
            let q = (v & ~VPARAM) as usize;
            return if q < self.pcls.len() {
                self.pcls[q];
            } else {
                CL_MANY;
            };
        }
        return if v as usize < self.icls.len() {
            self.icls[v as usize];
        } else {
            CL_MANY;
        };
    }

    // The alias classes block `k` of `b` writes (`class_bit`): a store's, a copy's or a fill's address
    // class; CL_OTHER for any other write, which reaches no exclusive parameter's referent.
    fn writes_in(self: &Self, b: &Body, k: u32) u64 {
        let bk = b.blocks[k as usize];
        let mut out: u64 = 0;
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            if t.op == O_STORE || t.op == O_MEMCPY || t.op == O_MEMSET {
                out |= class_bit(self.class(t.a));
            } else if writes_memory(t) {
                out |= class_bit(CL_OTHER);
            }
        }
        return out;
    }

    // Whether block `a` dominates block `x`.
    const fn dominates(self: &Self, a: u32, x: u32) bool {
        return self.dpre[a as usize] <= self.dpre[x as usize] && self.dpost[x as usize] <= self.dpost[a as usize];
    }

    // The natural loops: a back edge `u -> h` (`h` dominates `u`) makes `h` a header, and the blocks that
    // reach `u` without passing `h` its body. A header dominates the headers of the loops inside its own,
    // so in reverse postorder an outer loop comes first: each block keeps the last loop that holds it, its
    // innermost, and a header's innermost loop before its own is its parent. A loop's preheader is its
    // one predecessor outside it, when that block only jumps to it.
    fn loops(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.inner, nb, NONE);
        fill(&mut self.lparent, nb, NONE);
        fill(&mut self.preh, nb, NONE);
        fill(&mut self.mark, nb, NONE);
        fill(&mut self.writes, nb, 0);
        self.classes(b);
        for hi in 0..self.order.len() {
            let h = self.order[hi];
            self.work.truncate(0);
            for p in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let u = self.preds[p as usize];
                if self.dominates(h, u) && self.mark[u as usize] != h && u != h {
                    self.mark[u as usize] = h;
                    self.work.push(u);
                }
            }
            if self.work.len() == 0 && !self.has_pred(h, h) {
                continue;
            }
            self.lparent[h as usize] = self.inner[h as usize];
            self.inner[h as usize] = h;
            self.mark[h as usize] = h;
            let mut wr = self.writes_in(b, h);
            // Each block enters the walk once.
            while self.work.len() != 0 {
                let x = self.work.pop().unwrap();
                self.inner[x as usize] = h;
                wr |= self.writes_in(b, x);
                for p in self.pred_at[x as usize]..self.pred_at[x as usize + 1] {
                    let q = self.preds[p as usize];
                    if self.mark[q as usize] != h {
                        self.mark[q as usize] = h;
                        self.work.push(q);
                    }
                }
            }
            self.writes[h as usize] = wr;
            let mut outside = NONE;
            let mut n: u32 = 0;
            for p in self.pred_at[h as usize]..self.pred_at[h as usize + 1] {
                let q = self.preds[p as usize];
                if self.mark[q as usize] != h {
                    outside = q;
                    n += 1;
                }
            }
            if n == 1 && term(b, outside).op == O_JMP {
                self.preh[h as usize] = outside;
            }
        }
    }

    const fn has_pred(self: &Self, k: u32, p: u32) bool {
        for q in self.pred_at[k as usize]..self.pred_at[k as usize + 1] {
            if self.preds[q as usize] == p {
                return true;
            }
        }
        return false;
    }

    // Whether loop `h` holds block `x`.
    const fn in_loop(self: &Self, h: u32, x: u32) bool {
        let mut l = self.inner[x as usize];
        // Each step leaves one loop.
        while l != NONE {
            if l == h {
                return true;
            }
            l = self.lparent[l as usize];
        }
        return false;
    }

    // ---- The walk --------------------------------------------------------------------------------------

    // Whether an instruction changed.
    fn walk(self: &mut Self, pk: &Package, b: &mut Body) bool {
        let ni = b.insts.len();
        let nb = b.blocks.len();
        fill(&mut self.pblock, b.params.len(), NONE);
        fill(&mut self.blk_of, ni, NONE);
        for k in 0..nb {
            let bk = b.blocks[k];
            for q in 0..bk.param_len as u32 {
                self.pblock[(bk.param_start + q) as usize] = k as u32;
            }
            for i in bk.start..bk.start + bk.len {
                self.blk_of[i as usize] = k as u32;
            }
        }
        fill(&mut self.repl, ni, VNONE);
        fill(&mut self.prepl, b.params.len(), VNONE);
        fill(&mut self.frepl, ni, VNONE);
        self.extra.truncate(0);
        self.made.clear();
        fill_bool(&mut self.moved, ni, false);
        self.hoisted.truncate(0);
        self.pure.clear();
        self.mem.clear();
        self.cond.clear();
        self.log.truncate(0);
        self.places.truncate(0);
        fill(&mut self.end_state, nb, 0);
        let mut states: u32 = 0;
        let mut changed = false;
        // Preorder over the dominator tree: block << 1 enters a block, n << 33 | 1 closes its scope at log
        // length n.
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is entered and left once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            if (x & 1) != 0 {
                self.unwind((x >> 33) as usize);
                continue;
            }
            let k = (x >> 1) as usize;
            self.stack.push(self.log.len() as u64 << 33 | 1);
            if k != 0 && self.pred_at[k + 1] - self.pred_at[k] == 1 && self.preds[self.pred_at[k] as usize] == self.idom[k] {
                self.state = self.end_state[self.idom[k] as usize];
                // Its parameters are its one edge's arguments.
                changed = self.forward_params(b, k as u32) || changed;
                // Its one edge decides its dominator's branch condition here and below.
                let t = term(b, self.idom[k]);
                if t.op == O_BR && b.edge_target(t.b) != b.edge_target(t.c) && const_of(b, t.a).is_none() {
                    let taken: u32 = if b.edge_target(t.b) == k as u32 {
                        1;
                    } else {
                        0;
                    };
                    self.enter(LOG_COND, t.a, taken);
                }
            } else {
                states += 1;
                self.state = states;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                if writes_memory(b.insts[i as usize]) {
                    states += 1;
                    self.state = states;
                }
                changed = self.visit(pk, b, k as u32, i) || changed;
            }
            self.end_state[k] = self.state;
            for c in self.kid_at[k]..self.kid_at[k + 1] {
                self.stack.push(self.kids[c as usize] as u64 << 1);
            }
        }
        return changed;
    }

    fn unwind(self: &mut Self, to: usize) {
        // Each entry undoes one insertion.
        while self.log.len() > to {
            let (table, key, prev) = self.log.pop().unwrap();
            let m = if table == LOG_PURE {
                &mut self.pure;
            } else if table == LOG_MEM {
                &mut self.mem;
            } else {
                &mut self.cond;
            };
            if prev == NONE {
                let _ = m.remove(&key);
            } else {
                m.insert(key, prev);
            }
        }
    }

    fn enter(self: &mut Self, table: u8, key: u64, v: u32) {
        let m = if table == LOG_PURE {
            &mut self.pure;
        } else if table == LOG_MEM {
            &mut self.mem;
        } else {
            &mut self.cond;
        };
        let prev = switch m.get(&key) {
            Some(p) => *p,
            None => NONE,
        };
        m.insert(key, v);
        self.log.push((table, key, prev));
    }

    // The parameters of block `k`, whose one predecessor (its dominator, which the walk visited) has
    // the one edge into it: replaced by that edge's arguments. Whether it has any that did.
    fn forward_params(self: &mut Self, b: &Body, k: u32) bool {
        let bk = b.blocks[k as usize];
        if bk.param_len == 0 {
            return false;
        }
        b.succ_edges(term(b, self.idom[k as usize]), &mut self.edges);
        for e in 0..self.edges.len() {
            if b.edge_target(self.edges[e]) == k {
                for q in 0..bk.param_len as u32 {
                    self.prepl[(bk.param_start + q) as usize] = b.edge_arg(self.edges[e], q);
                }
                return true;
            }
        }
        // The predecessor's branch folded to its other edge: the rebuild drops the block.
        return false;
    }

    // The value `v` stands for now.
    const fn val(self: &Self, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            let r = self.prepl[(v & ~VPARAM) as usize];
            return if r == VNONE {
                v;
            } else {
                r;
            };
        }
        if (v & VFLAG) != 0 && self.frepl[(v & ~VFLAG) as usize] != VNONE {
            return self.frepl[(v & ~VFLAG) as usize];
        }
        let r = self.repl[(v & ~VFLAG) as usize];
        if r == VNONE {
            return v;
        }
        return r | v & VFLAG;
    }

    // An integer constant of type `ty` and bits `v` (truncated to it): one the dominating blocks hold, else
    // a new one at the start of the entry block.
    fn constant(self: &mut Self, b: &mut Body, ty: u8, v: u64) Value {
        let t = iconst(ty, v);
        let h = hash(t);
        let mut found = switch self.pure.get(&h) {
            Some(x) => *x,
            None => NONE,
        };
        if found == NONE || !same(b.insts[found as usize], t) {
            found = (switch self.made.get(&h) {
                Some(x) => *x,
                None => NONE,
            });
        }
        if found != NONE && same(b.insts[found as usize], t) {
            return found;
        }
        let i = b.insts.len() as u32;
        b.insts.push(t);
        b.locs.push(0);
        if b.inl.len() != 0 {
            b.inl.push(0);
        }
        self.repl.push(VNONE);
        self.frepl.push(VNONE);
        self.moved.push(false);
        self.blk_of.push(0);
        self.extra.push(i);
        self.made.insert(h, i);
        return i;
    }

    // Checked operation `i` of constants, or of an identity (`x + 0`, `x - 0`, `x * 1`, `x * 0`): its value
    // and flag replaced by the result and a constant flag. Whether it folded.
    fn fold_checked(self: &mut Self, pk: &Package, b: &mut Body, i: u32) bool {
        let t = b.insts[i as usize];
        if is_vec(t.ty) || t.ty == T_I128 {
            return false;
        }
        let ca = const_of(b, t.a);
        let cb = const_of(b, t.b);
        let signed = (t.aux & OV_SIGNED) != 0;
        let base = if t.op == O_ADDO {
            O_ADD;
        } else if t.op == O_SUBO {
            O_SUB;
        } else {
            O_MUL;
        };
        let mut val = VNONE;
        let mut flag: u64 = 0;
        if ca.is_some() && cb.is_some() {
            let mut r: u64 = 0;
            let _ = le::int_fold(base, t.ty, pk.ptr_bytes, ca.unwrap(), cb.unwrap(), &mut r);
            val = self.constant(b, t.ty, r);
            flag = le::overflows(t.op, t.ty, pk.ptr_bytes, signed, ca.unwrap(), cb.unwrap()) as u64;
        } else if cb.is_some() && (cb.unwrap() == 0 && t.op != O_MULO || cb.unwrap() == 1 && t.op == O_MULO) {
            val = t.a;
        } else if cb.is_some() && cb.unwrap() == 0 && t.op == O_MULO || ca.is_some() && ca.unwrap() == 0 && t.op == O_MULO {
            val = self.constant(b, t.ty, 0);
        } else if ca.is_some() && t.op != O_SUBO && (ca.unwrap() == 0 && t.op == O_ADDO || ca.unwrap() == 1 && t.op == O_MULO) {
            val = t.b;
        } else {
            return false;
        }
        self.repl[i as usize] = val;
        self.frepl[i as usize] = self.constant(b, T_I8, flag);
        return true;
    }

    // Instruction `i` of block `k`: its operands, then folding, numbering, memory forwarding and
    // hoisting. Whether it changed.
    fn visit(self: &mut Self, pk: &Package, b: &mut Body, k: u32, i: u32) bool {
        let t0 = b.insts[i as usize];
        let mut t = t0;
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.val(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.val(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.val(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for q in 0..t.aux as u32 {
                let at = (t.c + q) as usize;
                b.pool[at] = self.val(b.pool[at]);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                let at = (t.a + q) as usize;
                b.pool[at] = self.val(b.pool[at]);
            }
        }
        if is_terminator(t.op) {
            b.succ_edges(t, &mut self.edges);
            for e in 0..self.edges.len() {
                let x = self.edges[e];
                for q in 0..b.edge_nargs(x) {
                    let at = (x + 2 + q) as usize;
                    b.pool[at] = self.val(b.pool[at]);
                }
            }
            // A branch or a switch on a constant jumps, and so does a branch on a condition the edge into a
            // dominating block decides.
            let mut c = if t.op == O_BR || t.op == O_SWITCH {
                const_of(b, t.a);
            } else {
                Option::<u64>::None;
            };
            if t.op == O_BR && c.is_none() {
                if let Some(x) = self.cond.get(&(t.a as u64)) {
                    c = Option::<u64>::Some(*x);
                }
            }
            if t.op == O_BR && c.is_some() {
                t = jump(
                    if c.unwrap() != 0 {
                        t.b;
                    } else {
                        t.c;
                    },
                );
            } else if t.op == O_SWITCH && c.is_some() {
                let mut e = b.switch_edge(t, t.aux);
                for q in 0..t.aux as u32 {
                    if b.words[(t.b + q) as usize] == c.unwrap() {
                        e = b.switch_edge(t, q);
                        break;
                    }
                }
                t = jump(e);
            }
            b.insts[i as usize] = t;
            return !same(t, t0);
        }
        b.insts[i as usize] = t;
        // A copy or a fill of no byte does nothing.
        let size = if t.op == O_MEMCPY || t.op == O_MEMSET {
            const_of(b, t.c);
        } else {
            Option::<u64>::None;
        };
        if size.is_some() && size.unwrap() == 0 {
            self.repl[i as usize] = DROPPED;
            return true;
        }
        if t.op == O_STORE && (t.aux & MEM_VOLATILE) == 0 {
            // A load of the place the store wrote, in the state the store starts, reads the stored value.
            self.remember(t.a, t.c, b.type_of(t.b), t.b, self.state);
        } else if t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 {
            let p = self.private_load(pk, b, k, i, t);
            if p != PRIV_NONE && p != PRIV_KEPT {
                self.repl[i as usize] = p;
                return true;
            }
            // A load of bytes no write touches reads one value in every memory state.
            let st = if p == PRIV_KEPT {
                KEPT_STATE;
            } else {
                self.state;
            };
            let seen = self.recall(t.a, t.c, t.ty, st);
            if seen != VNONE {
                self.repl[i as usize] = seen;
                return true;
            }
            if fold_data(pk, b, i) {
                let _ = self.number(pk, b, k, i);
                return true;
            }
            self.remember(t.a, t.c, t.ty, i, st);
            if self.safe_load(pk, b, t) && self.hoist(pk, b, k, i, true, p == PRIV_KEPT) {
                return true;
            }
        } else if (t.op == O_ADDO || t.op == O_SUBO || t.op == O_MULO) && self.fold_checked(pk, b, i) {
            return true;
        } else if pure_op(t.op) && !tls_addr(pk, b, t) {
            let r = simplify(pk, b, i);
            if r != VNONE {
                self.repl[i as usize] = r;
                return true;
            }
            return self.number(pk, b, k, i) || !same(b.insts[i as usize], t0);
        }
        return !same(t, t0);
    }

    // Value-number pure instruction `i` of block `k`: an equal one of a dominating block replaces it, else
    // it enters the scope and moves out of the loops it does not vary in. Whether it went or moved.
    fn number(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32) bool {
        let t = b.insts[i as usize];
        let h = hash(t);
        let found = switch self.pure.get(&h) {
            Some(v) => *v,
            None => NONE,
        };
        if found != NONE && same(b.insts[found as usize], t) {
            self.repl[i as usize] = found;
            return true;
        }
        // On a hash collision the newer entry shadows the older: either is correct.
        self.enter(LOG_PURE, h, i);
        return self.hoist(pk, b, k, i, false, false);
    }

    // ---- Memory ----

    // The writes into each slot or aggregate argument whose address does not escape (`sbase`, `soff`,
    // `sesc`, `wat`, `wl`): its address and the constant offsets from it are only a load's or a store's
    // address, a copy's source, a copy's or a fill's destination, or the slice a vector access reads
    // (`header_read`). Every other use lets unknown code write it. The reached blocks in reverse postorder:
    // a definition comes before its uses.
    fn slot_writes(self: &mut Self, pk: &Package, b: &Body) {
        let ns = b.slots.len() + b.blocks[0].param_len as usize;
        let ni = b.insts.len();
        fill(&mut self.sbase, ni, NONE);
        self.soff.truncate(0);
        self.soff.resize_default(ni);
        fill_bool(&mut self.sesc, ns, false);
        self.wr.truncate(0);
        for q in 0..self.order.len() {
            let k = self.order[q];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if t.op == O_SLOTADDR {
                    self.sbase[i as usize] = t.a;
                    continue;
                }
                if t.op == O_PTRADD && t.b == VNONE && self.base(b, t.a) != NONE {
                    self.sbase[i as usize] = self.base(b, t.a);
                    self.soff[i as usize] = self.base_off(t.a) + (t.c as i32) as i64;
                    continue;
                }
                lv::uses(b, t, &mut self.uses);
                if is_terminator(t.op) {
                    b.succ_edges(t, &mut self.edges);
                    for e in 0..self.edges.len() {
                        for a in 0..b.edge_nargs(self.edges[e]) {
                            self.uses.push(b.edge_arg(self.edges[e], a));
                        }
                    }
                }
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    let s = self.base(b, v);
                    if s == NONE {
                        continue;
                    }
                    let o = self.base_off(v);
                    let size = if t.op == O_MEMCPY || t.op == O_MEMSET {
                        const_of(b, t.c);
                    } else {
                        Option::<u64>::None;
                    };
                    let end = if size.is_some() && size.unwrap() < 1u64 << 40 {
                        o + size.unwrap() as i64;
                    } else {
                        0x7FFFFFFFFFFFFFFF;
                    };
                    if t.op == O_LOAD || t.op == O_MEMCPY && t.b == v && t.a != v || t.op == O_VOP && header_read(
                        b,
                        t,
                        v,
                    ) {
                        // A read.
                    } else if t.op == O_STORE && t.a == v && t.b != v && (t.aux & MEM_VOLATILE) == 0 {
                        let at = o + (t.c as i32) as i64;
                        self.wr.push(
                            SlotWrite {
                                slot: s,
                                off: at,
                                end: at + type_bytes(b.type_of(t.b), pk.ptr_bytes) as i64,
                                inst: i,
                                blk: k,
                            },
                        );
                    } else if t.op == O_MEMCPY && t.a == v && t.b != v || t.op == O_MEMSET && t.a == v {
                        self.wr.push(SlotWrite { slot: s, off: o, end: end, inst: NONE, blk: k });
                    } else {
                        self.sesc[s as usize] = true;
                    }
                }
            }
        }
        // The writes by slot: a counting sort.
        fill(&mut self.wat, ns + 1, 0);
        for w in 0..self.wr.len() {
            self.wat[self.wr[w].slot as usize + 1] += 1;
        }
        for s in 0..ns {
            self.wat[s + 1] += self.wat[s];
        }
        fill(&mut self.work, ns, 0);
        self.wl.truncate(0);
        for w in 0..self.wr.len() {
            self.wl.push(self.wr[w]);
        }
        for w in 0..self.wr.len() {
            let s = self.wr[w].slot as usize;
            self.wl[(self.wat[s] + self.work[s]) as usize] = self.wr[w];
            self.work[s] += 1;
        }
    }

    // The private memory address value `v` points into (`sbase`'s numbering), NONE for none.
    const fn base(self: &Self, b: &Body, v: Value) u32 {
        if (v & VFLAG) != 0 {
            return NONE;
        }
        if (v & VPARAM) == 0 {
            return self.sbase[v as usize];
        }
        let p = v & ~VPARAM;
        let e = b.blocks[0];
        // The parameters past the signature's: an aggregate result's pointer, the caller's memory.
        if b.sig == NONE || p < e.param_start || p >= e.param_start + b.pool[b.sig as usize] || (b.pool[(b.sig + 3 + p - e.param_start) as usize] & AGG) == 0 {
            return NONE;
        }
        return b.slots.len() as u32 + p - e.param_start;
    }

    // The offset of address value `v` into its private memory (`base`).
    const fn base_off(self: &Self, v: Value) i64 {
        if (v & (VPARAM | VFLAG)) != 0 {
            return 0;
        }
        return self.soff[v as usize];
    }

    // Load `t` (instruction `i` of block `k`) of private memory whose address does not escape: PRIV_NONE
    // when that does not hold or another write touches its bytes; PRIV_KEPT when no write touches them, so
    // it reads the same value wherever it runs; else the value of the one store that writes exactly its
    // bytes when that store dominates it (as LLVM's mem2reg promotes an alloca of one store: on any path
    // to the load the last write of those bytes is that store's).
    fn private_load(self: &Self, pk: &Package, b: &Body, k: u32, i: u32, t: Inst) Value {
        let s = self.base(b, t.a) as usize;
        if s == NONE as usize || self.sesc[s] || self.wat[s + 1] - self.wat[s] > SLOT_WRITES_MAX {
            return PRIV_NONE;
        }
        let off = self.base_off(t.a) + (t.c as i32) as i64;
        let end = off + type_bytes(t.ty, pk.ptr_bytes) as i64;
        let mut one = NONE;
        let mut blk = NONE;
        for q in self.wat[s]..self.wat[s + 1] {
            let w = self.wl[q as usize];
            if w.off < end && off < w.end {
                if one != NONE || w.inst == NONE || w.off != off || w.end != end {
                    return PRIV_NONE;
                }
                one = w.inst;
                blk = w.blk;
            }
        }
        if one == NONE {
            return PRIV_KEPT;
        }
        let st = b.insts[one as usize];
        if b.type_of(st.b) != t.ty || blk == k && one >= i || blk != k && !self.dominates(blk, k) {
            return PRIV_NONE;
        }
        return self.val(st.b);
    }

    // The value a load of `addr + off` of type `ty` reads in memory state `state`, VNONE when unknown.
    fn recall(self: &Self, addr: u32, off: u32, ty: u8, state: u32) Value {
        let found = switch self.mem.get(&place_hash(addr, off, ty, state)) {
            Some(v) => *v,
            None => NONE,
        };
        if found == NONE {
            return VNONE;
        }
        let p = self.places[found as usize];
        return if p.addr == addr && p.off == off && p.ty == ty && p.state == state {
            p.val;
        } else {
            VNONE;
        };
    }

    fn remember(self: &mut Self, addr: u32, off: u32, ty: u8, v: Value, state: u32) {
        self.enter(LOG_MEM, place_hash(addr, off, ty, state), self.places.len() as u32);
        self.places.push(Place { addr: addr, off: off, ty: ty, state: state, val: v });
    }

    // Whether load `t` cannot fault wherever its address is defined: it reads inside a slot, a data
    // symbol of the package, an aggregate the caller passes by reference or a reference parameter's
    // referent (an entry block parameter: valid for the whole call).
    fn safe_load(self: &Self, pk: &Package, b: &Body, t: Inst) bool {
        if (t.a & VFLAG) != 0 {
            return false;
        }
        let mut size: i64 = -1;
        let mut off = (t.c as i32) as i64;
        if (t.a & VPARAM) != 0 {
            let p = t.a & ~VPARAM;
            let e = b.blocks[0];
            if b.sig != NONE && p >= e.param_start && p < e.param_start + b.pool[b.sig as usize] {
                let k = p - e.param_start;
                let code = b.pool[(b.sig + 3 + k) as usize];
                if (code & AGG) != 0 {
                    size = b.pool[(code & ~AGG) as usize];
                } else if k as usize < b.refs.len() {
                    size = b.refs[k as usize] & REF_BYTES;
                }
            }
        } else {
            let a = b.insts[t.a as usize];
            if a.op == O_SLOTADDR {
                size = b.slots[a.a as usize].size;
            } else if a.op == O_SYMADDR {
                let s = pk.syms[b.syms[a.a as usize] as usize];
                if s.kind == SK_DATA && s.def != NONE {
                    size = pk.data[s.def as usize].size;
                    off += a.b as i32;
                }
            }
        }
        return off >= 0 && off + type_bytes(t.ty, pk.ptr_bytes) as i64 <= size;
    }

    // ---- Hoisting ----

    // Move instruction `i` of block `k`, pure or a load (`load`), to the preheader of each loop around it
    // whose blocks do not define its operands (and, for a load, write no memory). Whether it moved.
    fn hoist(self: &mut Self, pk: &Package, b: &Body, k: u32, i: u32, load: bool, kept: bool) bool {
        let t = b.insts[i as usize];
        if !load && !speculable(pk, b, t) {
            return false;
        }
        let mut target = k;
        // Each step leaves one loop.
        loop {
            let h = self.inner[target as usize];
            if h == NONE || self.preh[h as usize] == NONE || load && !kept && (self.writes[h as usize] & class_bit(
                self.class(t.a),
            )) != 0 || !self.invariant(t, h) {
                break;
            }
            target = self.preh[h as usize];
        }
        if target == k {
            return false;
        }
        self.moved[i as usize] = true;
        self.blk_of[i as usize] = target;
        self.hoisted.push(target as u64 << 32 | i as u64);
        return true;
    }

    // Whether every operand of `t` is defined outside loop `h`.
    const fn invariant(self: &Self, t: Inst, h: u32) bool {
        let f = op_info(t.op).form;
        return (!lv::operand_a(f) || self.outside(t.a, h)) && (!lv::operand_b(f) || self.outside(t.b, h)) && (!lv::operand_c(
            f,
        ) || self.outside(t.c, h));
    }

    const fn outside(self: &Self, v: Value, h: u32) bool {
        if v == VNONE {
            return true;
        }
        let d = if (v & VPARAM) != 0 {
            self.pblock[(v & ~VPARAM) as usize];
        } else {
            self.blk_of[(v & ~VFLAG) as usize];
        };
        return !self.in_loop(h, d);
    }

    // ---- The rebuild -----------------------------------------------------------------------------------

    // The body without what the entry no longer reaches, what was replaced, and the pure instructions and
    // block parameters nothing uses (an edge argument is a use only for a parameter that stays); a block
    // whose one predecessor jumps to it continues that block; each moved instruction at the end of its
    // new block before the terminator, in the order they moved; every block, parameter and value
    // renumbered. No operand names a replaced value: the walk visits a definition before its uses.
    fn rebuild(self: &mut Self, b: &mut Body) {
        let ni = b.insts.len();
        let nb = b.blocks.len();
        let npar = b.params.len();
        self.reach(b);
        // The edges into each reached block (`into_at` ranges of `ins`), and its predecessor count.
        fill(&mut self.in_at, nb + 1, 0);
        for k in 0..nb {
            if self.bmap[k] != NONE {
                b.succ_edges(term(b, k as u32), &mut self.edges);
                for e in 0..self.edges.len() {
                    self.in_at[b.edge_target(self.edges[e]) as usize + 1] += 1;
                }
            }
        }
        for k in 0..nb {
            self.in_at[k + 1] += self.in_at[k];
        }
        fill(&mut self.ins, self.in_at[nb] as usize, 0);
        fill(&mut self.insrc, self.in_at[nb] as usize, 0);
        fill(&mut self.work, nb, 0);
        for k in 0..nb {
            if self.bmap[k] != NONE {
                b.succ_edges(term(b, k as u32), &mut self.edges);
                for e in 0..self.edges.len() {
                    let s = b.edge_target(self.edges[e]) as usize;
                    self.ins[(self.in_at[s] + self.work[s]) as usize] = self.edges[e];
                    self.insrc[(self.in_at[s] + self.work[s]) as usize] = k as u32;
                    self.work[s] += 1;
                }
            }
        }
        // Liveness over instructions and parameters: what has an effect in a reached block (and the entry
        // block's parameters, the signature's), then what it uses; a parameter that stays keeps its
        // edges' arguments.
        fill_bool(&mut self.live, ni + npar, false);
        self.work.truncate(0);
        let e0 = b.blocks[0];
        for q in e0.param_start..e0.param_start + e0.param_len as u32 {
            self.mark(ni as u32 + q);
        }
        self.slot_reads(b);
        for k in 0..nb {
            if self.bmap[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if self.repl[i as usize] == VNONE && !droppable(t) && !self.dead_store(b, t) {
                    self.mark(i);
                }
            }
        }
        // Each instruction and parameter enters the walk once.
        while self.work.len() != 0 {
            let x = self.work.pop().unwrap();
            if x as usize < ni {
                lv::uses(b, b.insts[x as usize], &mut self.uses);
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    self.mark(
                        if (v & VPARAM) != 0 {
                            ni as u32 + (v & ~VPARAM);
                        } else {
                            v & ~VFLAG;
                        },
                    );
                }
                continue;
            }
            let p = x - ni as u32;
            let k = self.pblock[p as usize] as usize;
            let q = p - b.blocks[k].param_start;
            for j in self.in_at[k]..self.in_at[k + 1] {
                let v = b.edge_arg(self.ins[j as usize], q);
                self.mark(
                    if (v & VPARAM) != 0 {
                        ni as u32 + (v & ~VPARAM);
                    } else {
                        v & ~VFLAG;
                    },
                );
            }
        }
        // Merges: `nxt[p]` is the block that continues block `p` (NONE: none), a block it alone jumps to.
        fill(&mut self.nxt, nb, NONE);
        for k in 1..nb {
            if self.bmap[k] == NONE || self.in_at[k + 1] - self.in_at[k] != 1 {
                continue;
            }
            let bk = b.blocks[k];
            let mut kept = false;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                kept = kept || self.live[ni + q as usize];
            }
            let p = self.insrc[self.in_at[k] as usize];
            if !kept && p != k as u32 && term(b, p).op == O_JMP {
                self.nxt[p as usize] = k as u32;
            }
        }
        // The heads: the reached blocks no other continues, numbered in order; a merged block takes its
        // head's number.
        fill_bool(&mut self.done, nb, false);
        for k in 0..nb {
            if self.nxt[k] != NONE {
                self.done[self.nxt[k] as usize] = true;
            }
        }
        let mut nk: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] != NONE && !self.done[k] {
                self.bmap[k] = nk;
                let mut cur = self.nxt[k];
                // Each step takes one block of the chain.
                while cur != NONE {
                    self.bmap[cur as usize] = nk;
                    cur = self.nxt[cur as usize];
                }
                nk += 1;
            }
        }
        // The moved instructions left, grouped by block: `into[work[k] .. work[k + 1]]`.
        fill(&mut self.work, nb + 1, 0);
        for q in 0..self.hoisted.len() {
            if self.live[(self.hoisted[q] as u32) as usize] {
                self.work[(self.hoisted[q] >> 32) as usize + 1] += 1;
            }
        }
        for k in 0..nb {
            self.work[k + 1] += self.work[k];
        }
        fill(&mut self.into, self.work[nb] as usize, 0);
        fill(&mut self.newidx, nb, 0);
        for q in 0..self.hoisted.len() {
            let i = self.hoisted[q] as u32;
            if self.live[i as usize] {
                let k = (self.hoisted[q] >> 32) as usize;
                self.into[(self.work[k] + self.newidx[k]) as usize] = i;
                self.newidx[k] += 1;
            }
        }
        // New numbers in emission order: per head block its parameters that stay, then its chain's
        // instructions.
        fill(&mut self.newidx, ni, NONE);
        fill(&mut self.pmap, npar, NONE);
        self.params.truncate(0);
        let mut n: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] == NONE || self.done[k] {
                continue;
            }
            let bk = b.blocks[k];
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                if self.live[ni + q as usize] {
                    self.pmap[q as usize] = self.params.len() as u32;
                    self.params.push(b.params[q as usize]);
                }
            }
            if k == 0 {
                for q in 0..self.extra.len() {
                    if self.live[self.extra[q] as usize] {
                        self.newidx[self.extra[q] as usize] = n;
                        n += 1;
                    }
                }
            }
            let mut cur = k as u32;
            // Each step takes one block of the chain.
            while cur != NONE {
                let ck = b.blocks[cur as usize];
                for i in ck.start..ck.start + ck.len - 1 {
                    if self.live[i as usize] && !self.moved[i as usize] {
                        self.newidx[i as usize] = n;
                        n += 1;
                    }
                }
                for q in self.work[cur as usize]..self.work[cur as usize + 1] {
                    self.newidx[self.into[q as usize] as usize] = n;
                    n += 1;
                }
                if self.nxt[cur as usize] == NONE {
                    self.newidx[(ck.start + ck.len - 1) as usize] = n;
                    n += 1;
                }
                cur = self.nxt[cur as usize];
            }
        }
        self.insts.truncate(0);
        self.locs.truncate(0);
        self.inls.truncate(0);
        self.blocks.truncate(0);
        fill_bool(&mut self.done_pool, b.pool.len(), false);
        let mut np: u32 = 0;
        for k in 0..nb {
            if self.bmap[k] == NONE || self.done[k] {
                continue;
            }
            let bk = b.blocks[k];
            let start = self.insts.len() as u32;
            let ps = np;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                if self.live[ni + q as usize] {
                    np += 1;
                }
            }
            if k == 0 {
                for q in 0..self.extra.len() {
                    if self.live[self.extra[q] as usize] {
                        self.emit(b, self.extra[q]);
                    }
                }
            }
            let mut cur = k as u32;
            let mut flags = bk.flags;
            // Each step takes one block of the chain.
            while cur != NONE {
                let ck = b.blocks[cur as usize];
                flags &= ck.flags;
                for i in ck.start..ck.start + ck.len - 1 {
                    if self.live[i as usize] && !self.moved[i as usize] {
                        self.emit(b, i);
                    }
                }
                for q in self.work[cur as usize]..self.work[cur as usize + 1] {
                    self.emit(b, self.into[q as usize]);
                }
                if self.nxt[cur as usize] == NONE {
                    self.emit(b, ck.start + ck.len - 1);
                }
                cur = self.nxt[cur as usize];
            }
            self.blocks.push(
                Block {
                    start: start,
                    len: self.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: (np - ps) as u16,
                    flags: flags,
                },
            );
        }
        self.insts = replace(&mut b.insts, replace(&mut self.insts, Vector::<Inst>::new()));
        self.locs = replace(&mut b.locs, replace(&mut self.locs, Vector::<u32>::new()));
        if b.inl.len() != 0 {
            self.inls = replace(&mut b.inl, replace(&mut self.inls, Vector::<u32>::new()));
        }
        self.blocks = replace(&mut b.blocks, replace(&mut self.blocks, Vector::<Block>::new()));
        self.params = replace(&mut b.params, replace(&mut self.params, Vector::<u8>::new()));
        self.drop_slots(b);
    }

    // Drop the slots no instruction takes the address of (promoted, merged or dead ones), and renumber
    // the others in order.
    fn drop_slots(self: &mut Self, b: &mut Body) {
        fill(&mut self.work, b.slots.len(), NONE);
        for i in 0..b.insts.len() {
            if b.insts[i].op == O_SLOTADDR {
                self.work[b.insts[i].a as usize] = 0;
            }
        }
        let mut n: u32 = 0;
        for s in 0..b.slots.len() {
            if self.work[s] != NONE {
                self.work[s] = n;
                b.slots[n as usize] = b.slots[s];
                n += 1;
            }
        }
        if n as usize == b.slots.len() {
            return;
        }
        b.slots.truncate(n as usize);
        for i in 0..b.insts.len() {
            if b.insts[i].op == O_SLOTADDR {
                let t = b.insts[i].a;
                b.insts.index_mut(i).a = self.work[t as usize];
            }
        }
    }

    // `sread`: per slot, whether a reached instruction reads it or takes its address further than a store
    // or a fill into it.
    fn slot_reads(self: &mut Self, b: &Body) {
        fill_bool(&mut self.sread, b.slots.len(), false);
        for k in 0..b.blocks.len() {
            if self.bmap[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                if self.repl[i as usize] != VNONE {
                    continue;
                }
                lv::uses(b, t, &mut self.uses);
                b.succ_edges(t, &mut self.edges);
                for e in 0..self.edges.len() {
                    for q in 0..b.edge_nargs(self.edges[e]) {
                        self.uses.push(b.edge_arg(self.edges[e], q));
                    }
                }
                for u in 0..self.uses.len() {
                    let v = self.uses[u];
                    if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_SLOTADDR {
                        continue;
                    }
                    let into = (t.op == O_STORE || t.op == O_MEMSET) && t.a == v && t.b != v && (t.op == O_STORE || t.c != v);
                    if !into {
                        self.sread[b.insts[v as usize].a as usize] = true;
                    }
                }
            }
        }
    }

    // Whether `t` of `b` stores or fills into a slot nothing reads (`sread`), not volatile.
    const fn dead_store(self: &Self, b: &Body, t: Inst) bool {
        if t.op != O_STORE && t.op != O_MEMSET || t.op == O_STORE && (t.aux & MEM_VOLATILE) != 0 || (t.a & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let a = b.insts[t.a as usize];
        return a.op == O_SLOTADDR && !self.sread[a.a as usize];
    }

    // `bmap`: 0 for each block the entry reaches through the rewritten terminators, else NONE.
    fn reach(self: &mut Self, b: &Body) {
        fill(&mut self.bmap, b.blocks.len(), NONE);
        self.bmap[0] = 0;
        self.work.truncate(0);
        self.work.push(0);
        // Each block enters the walk once.
        while self.work.len() != 0 {
            let k = self.work.pop().unwrap();
            b.succ_edges(term(b, k), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]);
                if self.bmap[s as usize] == NONE {
                    self.bmap[s as usize] = 0;
                    self.work.push(s);
                }
            }
        }
    }

    // Instruction or parameter `x` (an instruction index, or the instruction count plus a parameter
    // index) is live.
    fn mark(self: &mut Self, x: u32) {
        if !self.live[x as usize] {
            self.live[x as usize] = true;
            self.work.push(x);
        }
    }

    const fn renum(self: &Self, v: Value) Value {
        if v == VNONE {
            return v;
        }
        if (v & VPARAM) != 0 {
            return VPARAM | self.pmap[(v & ~VPARAM) as usize];
        }
        return self.newidx[(v & ~VFLAG) as usize] | v & VFLAG;
    }

    fn emit(self: &mut Self, b: &mut Body, i: u32) {
        let mut t = b.insts[i as usize];
        let f = op_info(t.op).form;
        if lv::operand_a(f) {
            t.a = self.renum(t.a);
        }
        if lv::operand_b(f) {
            t.b = self.renum(t.b);
        }
        if lv::operand_c(f) {
            t.c = self.renum(t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            for q in 0..t.aux as u32 {
                self.renum_pool(b, t.c + q);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                self.renum_pool(b, t.a + q);
            }
        }
        // Each edge: its target's number, and the arguments of the parameters that stay.
        b.succ_edges(t, &mut self.edges);
        for e in 0..self.edges.len() {
            let x = self.edges[e];
            if self.done_pool[x as usize] {
                continue;
            }
            self.done_pool[x as usize] = true;
            let tk = b.pool[x as usize];
            let tb = b.blocks[tk as usize];
            let mut kept: u32 = 0;
            for q in 0..b.pool[x as usize + 1] {
                if self.live[b.insts.len() + (tb.param_start + q) as usize] {
                    b.pool[(x + 2 + kept) as usize] = self.renum(b.pool[(x + 2 + q) as usize]);
                    kept += 1;
                }
            }
            b.pool[x as usize] = self.bmap[tk as usize];
            b.pool[x as usize + 1] = kept;
        }
        self.insts.push(t);
        self.locs.push(b.locs[i as usize]);
        if b.inl.len() != 0 {
            self.inls.push(b.inl[i as usize]);
        }
    }

    const fn renum_pool(self: &mut Self, b: &mut Body, at: u32) {
        if !self.done_pool[at as usize] {
            self.done_pool[at as usize] = true;
            b.pool[at as usize] = self.renum(b.pool[at as usize]);
        }
    }
}

/// Optimize every body of `pk` on up to `jobs` threads as `cf` sets: callees first, each body inlines the
/// ones that fit the inline budget (`lir::inline`), goes through `Opt::run`, then `Opt::loop_opts`. A body's level is one more than its callees' that
/// may inline (0 without any; a call back into a body the walk is inside does not count), and the
/// bodies of one level go in parallel, reading the lower levels'. A body of a unit `sealed` marks (by
/// unit) inlines into bodies of its unit only.
pub fn optimize(pk: &mut Package, jobs: u32, sealed: &Vector<bool>, cf: Config) {
    let mut bodies = replace(&mut pk.bodies, Vector::<Body>::new());
    {
        let p: &Package = pk;
        let n = bodies.len();
        let mut shape = Vector::<bool>::with_capacity(n);
        shape.resize_default(n);
        let mut unit = Vector::<u32>::with_capacity(n);
        for _ in 0..n {
            unit.push(NONE);
        }
        for s in 0..p.syms.len() {
            let sy = p.syms[s];
            if sy.kind == SK_FUNC && sy.def != NONE {
                shape[sy.def as usize] = il::shape_ok(p, s as u32, &bodies[sy.def as usize]);
                if sy.unit < sealed.len() as u32 && sealed[sy.unit as usize] {
                    unit[sy.def as usize] = sy.unit;
                }
            }
        }
        let mut level = Vector::<u32>::new();
        levels(p, &bodies, &shape, &mut level);
        let mut top: u32 = 0;
        for i in 0..n {
            if level[i] > top {
                top = level[i];
            }
        }
        // The bodies by level: `byl[at[l] .. at[l + 1]]`.
        let mut at = Vector::<u32>::new();
        at.resize_default(top as usize + 2);
        for i in 0..n {
            at[level[i] as usize + 1] += 1;
        }
        for l in 0..top as usize + 1 {
            at[l + 1] += at[l];
        }
        let mut byl = Vector::<u32>::new();
        byl.resize_default(n);
        let mut fillp = Vector::<u32>::new();
        fillp.extend_copy(&at);
        for i in 0..n {
            byl[fillp[level[i] as usize] as usize] = i as u32;
            fillp[level[i] as usize] += 1;
        }
        let mut ok = Vector::<bool>::with_capacity(n);
        ok.resize_default(n);
        // SC_LIR_INLINE=0 inlines nothing (a debugging aid).
        let inline = !stdlib::env_is("SC_LIR_INLINE", "0");
        let base = bodies.as_mut_slice().as_mut_ptr() as usize;
        let ur: &Vector<u32> = &unit;
        for l in 0..top as usize + 1 {
            let part = byl.index_range_mut(at[l] as usize..at[l + 1] as usize);
            let okr: &Vector<bool> = &ok;
            if jobs < 2 || part.len() < 64 {
                level_bodies(p, base, okr, ur, cf.loops, part);
            } else {
                // 16 bodies per task: the scratch grows once per task.
                parallel::chunks_mut(
                    part,
                    16,
                    |c: []mut u32| {
                        level_bodies(p, base, okr, ur, cf.loops, c);
                    },
                );
            }
            for j in at[l]..at[l + 1] {
                let i = byl[j as usize] as usize;
                ok[i] = inline && shape[i] && il::small(&bodies[i], cf.inline);
            }
        }
    }
    pk.bodies = bodies;
}

// Each body `is` lists of the bodies at `base`: the callees `ok` marks inlined (`unit`: as
// `Inliner::run` takes it), then optimized, with one scratch. Each task writes its own bodies and reads
// the lower levels', which no task writes.
fn level_bodies(p: &Package, base: usize, ok: &Vector<bool>, unit: &Vector<u32>, bu: lu::Budgets, is: []mut u32) {
    let mut il = il::Inliner::new();
    let mut o = Opt::new();
    for j in 0..is.len() {
        let b = unsafe &mut *(base as *mut Body + is[j] as usize);
        let inlined = il.run(p, base as *const Body, ok, unit, is[j], b);
        let _ = o.run(p, b, inlined);
        // A loop a round copied is innermost again for the next one.
        let mut round: u32 = 0;
        while round < LOOP_ROUNDS && (bu.peel != 0 || bu.version != 0 || bu.unswitch != 0) && o.loop_opts(p, b, bu) {
            round += 1;
        }
    }
}

// Per body of `bodies`, its level (`optimize`): an explicit-stack depth-first search over the direct calls
// of the bodies `shape` marks (body << 1 | finished).
fn levels(p: &Package, bodies: &Vector<Body>, shape: &Vector<bool>, level: &mut Vector<u32>) {
    let n = bodies.len();
    level.truncate(0);
    level.resize_default(n);
    // 0: not seen, 1: on the stack, 2: finished.
    let mut st = Vector::<u8>::new();
    st.resize_default(n);
    let mut stack = Vector::<u64>::new();
    for r in 0..n {
        if st[r] != 0 {
            continue;
        }
        stack.push(r as u64 << 1);
        // Each body is pushed once per call into it and finished once.
        while stack.len() != 0 {
            let x = stack.pop().unwrap();
            let k = (x >> 1) as usize;
            let b = &bodies[k];
            if (x & 1) != 0 {
                let mut lv: u32 = 0;
                for i in 0..b.insts.len() {
                    let c = call_target(p, b, b.insts[i]);
                    if c != NONE && shape[c as usize] && st[c as usize] == 2 && c as usize != k && level[c as usize] + 1 > lv {
                        lv = level[c as usize] + 1;
                    }
                }
                level[k] = lv;
                st[k] = 2;
                continue;
            }
            if st[k] != 0 {
                continue;
            }
            st[k] = 1;
            stack.push(k as u64 << 1 | 1);
            for i in 0..b.insts.len() {
                let c = call_target(p, b, b.insts[i]);
                if c != NONE && shape[c as usize] && st[c as usize] == 0 {
                    stack.push(c as u64 << 1);
                }
            }
        }
    }
}

// The body index a direct call `t` of `b` reaches (NONE: not a call, or no body).
const fn call_target(p: &Package, b: &Body, t: Inst) u32 {
    if t.op != O_CALL {
        return NONE;
    }
    let sy = p.syms[b.syms[t.a as usize] as usize];
    return if sy.kind == SK_FUNC && sy.def != NONE {
        sy.def;
    } else {
        NONE;
    };
}

// Whether `t` has no effect but its value: dropped when nothing uses it.
const fn droppable(t: Inst) bool {
    return pure_op(t.op) || t.op == O_LOAD && (t.aux & MEM_VOLATILE) == 0;
}

// ---- Folding ------------------------------------------------------------------------------------------

// The integer constant value `v` is (up to 64 bits, truncated to its type), if it is one.
const fn const_of(b: &Body, v: Value) Option<u64> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST || b.insts[v as usize].ty == T_I128 {
        return Option::<u64>::None;
    }
    let t = b.insts[v as usize];
    return Option::<u64>::Some(t.b as u64 << 32 | t.a as u64);
}

const fn float_const(b: &Body, v: Value) Option<u64> {
    if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_FCONST {
        return Option::<u64>::None;
    }
    let t = b.insts[v as usize];
    return Option::<u64>::Some(t.b as u64 << 32 | t.a as u64);
}

// Pure instruction `i` of `b`, its operands final: the value it equals (VNONE: none). Else it may be
// rewritten in place: to a constant, to a canonical form (a commutative operation's constant second), or
// an address with its constant index and its base address's offset in its own.
fn simplify(pk: &Package, b: &mut Body, i: u32) Value {
    let mut t = b.insts[i as usize];
    if is_vec(t.ty) || t.ty == T_I128 {
        return VNONE;
    }
    let ptr = pk.ptr_bytes;
    if t.op == O_SELECT {
        let c = const_of(b, t.a);
        if c.is_some() {
            return if c.unwrap() != 0 {
                t.b;
            } else {
                t.c;
            };
        }
        return if t.b == t.c {
            t.b;
        } else {
            VNONE;
        };
    }
    if t.op == O_PTRADD {
        // A slot's address keeps its index: a constant offset past the slot in a path that never runs
        // would fail the verifier's check of slot accesses.
        let ix = const_of(b, t.b);
        if ix.is_some() && !slot_based(b, t.a) {
            let off = (t.c as i32) as i64 + le::sign_ext(ix.unwrap(), type_bits(b.type_of(t.b), ptr)) * t.aux as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                t.b = VNONE;
                t.c = off as u32;
            }
        }
        if t.b == VNONE && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_PTRADD && b.insts[t.a as usize].b == VNONE {
            let off = (t.c as i32) as i64 + (b.insts[t.a as usize].c as i32) as i64;
            if off >= -0x80000000 && off <= 0x7FFFFFFF {
                t.a = b.insts[t.a as usize].a;
                t.c = off as u32;
            }
        }
        b.insts[i as usize] = t;
        return if t.b == VNONE && t.c == 0 {
            t.a;
        } else {
            VNONE;
        };
    }
    if t.op == O_ICMP {
        let ca = const_of(b, t.a);
        let cb = const_of(b, t.b);
        if ca.is_some() && cb.is_some() {
            b.insts[i as usize] = iconst(t.ty, le::icmp(t.aux, b.type_of(t.a), ptr, ca.unwrap(), cb.unwrap()) as u64);
        } else if t.a == t.b {
            let c = t.aux;
            b.insts[i as usize] = iconst(
                t.ty,
                (c == C_EQ || c == C_SLE || c == C_SGE || c == C_ULE || c == C_UGE) as u64,
            );
        }
        return VNONE;
    }
    if t.op >= O_FADD && t.op <= O_FDIV {
        let x = float_const(b, t.a);
        let y = float_const(b, t.b);
        if x.is_some() && y.is_some() {
            let r = le::float_op(t.op, t.ty, x.unwrap(), y.unwrap());
            // A NaN result keeps its operation: the machine chooses its payload.
            if !is_nan(t.ty, r) {
                b.insts[i as usize] = Inst {
                    op: O_FCONST,
                    ty: t.ty,
                    aux: 0,
                    a: r as u32,
                    b: (r >> 32) as u32,
                    c: VNONE,
                };
            }
        }
        return VNONE;
    }
    if t.op == O_SEXT || t.op == O_ZEXT || t.op == O_TRUNC || t.op == O_INTTOPTR || t.op == O_PTRTOINT {
        let x = const_of(b, t.a);
        let mut r: u64 = 0;
        if x.is_some() && le::scalar_convert(t.op, t.aux, b.type_of(t.a), t.ty, ptr, x.unwrap(), &mut r) {
            b.insts[i as usize] = iconst(t.ty, r);
        }
        return VNONE;
    }
    if !is_int(t.ty) || t.op < O_ADD || t.op > O_NOT {
        return VNONE;
    }
    // A commutative operation takes a constant second.
    let op = t.op;
    if (op == O_ADD || op == O_MUL || op == O_AND || op == O_OR || op == O_XOR) && const_of(b, t.a).is_some() && const_of(
        b,
        t.b,
    ).is_none() {
        let x = t.a;
        t.a = t.b;
        t.b = x;
        b.insts[i as usize] = t;
    }
    let ca = const_of(b, t.a);
    let cb = if op == O_NEG || op == O_NOT {
        Option::<u64>::Some(0);
    } else {
        const_of(b, t.b);
    };
    let mut r: u64 = 0;
    if ca.is_some() && cb.is_some() {
        if le::int_fold(op, t.ty, ptr, ca.unwrap(), cb.unwrap(), &mut r) == le::FOLD_OK {
            b.insts[i as usize] = iconst(t.ty, r);
        }
        return VNONE;
    }
    if op == O_NEG || op == O_NOT {
        return VNONE;
    }
    let ones = le::trunc_bits(0xFFFFFFFFFFFFFFFF, type_bits(t.ty, ptr));
    if cb.is_some() {
        let y = cb.unwrap();
        if y == 0 && (op == O_ADD || op == O_SUB || op == O_OR || op == O_XOR || op == O_SHL || op == O_LSHR || op == O_ASHR) || y == 1 && (op == O_MUL || op == O_SDIV || op == O_UDIV) || y == ones && op == O_AND {
            return t.a;
        }
        if y == 0 && (op == O_MUL || op == O_AND) || y == ones && op == O_OR {
            b.insts[i as usize] = iconst(t.ty, y);
        }
        return VNONE;
    }
    if t.a == t.b {
        if op == O_AND || op == O_OR {
            return t.a;
        }
        if op == O_SUB || op == O_XOR {
            b.insts[i as usize] = iconst(t.ty, 0);
        }
    }
    return VNONE;
}

// Whether address `v` of `b` is a slot's address plus constant offsets.
const fn slot_based(b: &Body, v: Value) bool {
    let mut x = v;
    // Each step goes to an earlier address of the chain: at most the instruction count.
    for _ in 0..b.insts.len() {
        if (x & (VPARAM | VFLAG)) != 0 {
            return false;
        }
        let t = b.insts[x as usize];
        if t.op == O_SLOTADDR {
            return true;
        }
        if t.op != O_PTRADD || t.b != VNONE {
            return false;
        }
        x = t.a;
    }
    return false;
}

// A load of read-only data of the package at a constant place clear of its relocations: rewritten to the
// constant it reads. Whether instruction `i` folded.
fn fold_data(pk: &Package, b: &mut Body, i: u32) bool {
    let t = b.insts[i as usize];
    if (t.a & (VPARAM | VFLAG)) != 0 || is_vec(t.ty) || t.ty == T_PTR || t.ty == T_I128 || b.insts[t.a as usize].op != O_SYMADDR {
        return false;
    }
    let at = b.insts[t.a as usize];
    let s = pk.syms[b.syms[at.a as usize] as usize];
    if s.kind != SK_DATA || s.def == NONE {
        return false;
    }
    let d = pk.data[s.def as usize];
    let off = (at.b as i32) as i64 + (t.c as i32) as i64;
    let n = type_bytes(t.ty, pk.ptr_bytes) as i64;
    if !d.readonly || off < 0 || off + n > d.size as i64 {
        return false;
    }
    for r in d.relocs..d.relocs + d.nrelocs {
        let ro = pk.relocs[r as usize].offset as i64;
        if ro < off + n && ro + pk.ptr_bytes as i64 > off {
            return false;
        }
    }
    // Little-endian, as every native target.
    let mut v: u64 = 0;
    for q in 0..n {
        if off + q < d.nbytes as i64 {
            v |= pk.bytes[(d.bytes as i64 + off + q) as usize] as u64 << (8 * q) as u64;
        }
    }
    b.insts[i as usize] = if is_float(t.ty) {
        Inst { op: O_FCONST, ty: t.ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE };
    } else {
        iconst(t.ty, v);
    };
    return true;
}

// ---- Helpers ------------------------------------------------------------------------------------------

// Block `k`'s terminator.
const fn term(b: &Body, k: u32) Inst {
    let bk = b.blocks[k as usize];
    return b.insts[(bk.start + bk.len - 1) as usize];
}

// Whether vector operation `t` reads the slice at `v`, its first operand and no other, and writes no byte
// of it: a checked load or store, or a masked, partial or gather access of a slice.
const fn header_read(b: &Body, t: Inst, v: Value) bool {
    let code = (t.aux & VOP_CODE) as u32;
    if code < core::OP_SIMD || code >= core::OP_CMP_LANES || t.b == 0 || b.pool[t.a as usize] != v {
        return false;
    }
    for q in 1..t.b {
        if b.pool[(t.a + q) as usize] == v {
            return false;
        }
    }
    let c = (code - core::OP_SIMD) as u8;
    let rule = core::simd_op(c).rule;
    return rule == core::SR_LOAD && c != core::SIMD_LOAD_RAW || rule == core::SR_STORE && c != core::SIMD_STORE_RAW || (rule == core::SR_MLOAD || rule == core::SR_MSTORE) && c < core::SIMD_GATHER_PTR;
}

// Whether `t` may write memory or order memory accesses: a store, a copy, a fill, an atomic or a fence,
// a call, inline assembly, a vector operation or a variadic access.
const fn writes_memory(t: Inst) bool {
    let op = t.op;
    return op == O_STORE || op == O_MEMCPY || op == O_MEMSET || op >= O_ALOAD && op <= O_FENCE || op == O_CALL || op == O_CALLIND || op == O_ASM || op >= O_VOP && op <= O_VAEND;
}

// Alias classes (`Opt::classes`): no parameter's referent, exclusive parameter k's (CL_NOALIAS + k), any.
const CL_OTHER: u8 = 0;
const CL_NOALIAS: u8 = 1;
const CL_MANY: u8 = 64;
const CL_UNSET: u8 = 65;
// The rounds of joins `Opt::classes` runs before it gives up.
const CLASS_ROUNDS: u32 = 8;

// The bits of the classes an access of class `c` may touch.
const fn class_bit(c: u8) u64 {
    return if c >= CL_MANY {
        ~0u64;
    } else {
        1u64 << c as u64;
    };
}

// The class of a value that may be either `a`'s or `b`'s.
const fn join(a: u8, b: u8) u8 {
    return if a == CL_UNSET || a == b {
        b;
    } else if b == CL_UNSET {
        a;
    } else {
        CL_MANY;
    };
}

// Whether opcode `op` computes a value from its operands alone, the same each time it does not trap.
const fn pure_op(op: u8) bool {
    return op >= O_ICONST && op <= O_INTTOPTR || op == O_PTRADD || op == O_SELECT;
}

// Whether pure `t` of `b` may run where the program would not run it: it has operands (a constant is
// `tidy`'s to place), cannot trap and gives a defined value (a shift amount below the width; no checked
// arithmetic, division or float to integer conversion).
fn speculable(pk: &Package, b: &Body, t: Inst) bool {
    let op = t.op;
    if op <= O_SLOTADDR || op >= O_SDIV && op <= O_UREM || op >= O_ADDO && op <= O_MULO || op == O_FPTOSI || op == O_FPTOUI {
        return false;
    }
    if op == O_SHL || op == O_LSHR || op == O_ASHR {
        let c = const_of(b, t.b);
        return c.is_some() && c.unwrap() < type_bits(t.ty, pk.ptr_bytes) as u64;
    }
    return true;
}

// Whether `t` of `b` is the address of a thread-local variable: the running thread's copy, which a call
// may change (a task resumes on another thread), so no two of them are one value.
const fn tls_addr(pk: &Package, b: &Body, t: Inst) bool {
    return t.op == O_SYMADDR && pk.syms[b.syms[t.a as usize] as usize].kind == SK_TLS;
}

// Whether `t` and `u` are the same instruction.
const fn same(t: Inst, u: Inst) bool {
    return t.op == u.op && t.ty == u.ty && t.aux == u.aux && t.a == u.a && t.b == u.b && t.c == u.c;
}

const fn jump(e: u32) Inst {
    return Inst { op: O_JMP, ty: T_NONE, aux: 0, a: e, b: 0, c: 0 };
}

// An integer constant of type `ty` (`v` truncated to it), as the lowering writes one.
const fn iconst(ty: u8, v: u64) Inst {
    return Inst { op: O_ICONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE };
}

const fn is_nan(ty: u8, r: u64) bool {
    if ty == T_F32 {
        return (r & 0x7F800000) == 0x7F800000 && (r & 0x7FFFFF) != 0;
    }
    return (r & 0x7FF0000000000000) == 0x7FF0000000000000 && (r & 0xFFFFFFFFFFFFF) != 0;
}

const fn mix(h: u64, x: u64) u64 {
    let m = (h ^ x).wrapping_mul(0x9E3779B97F4A7C15);
    return m ^ m >> 31;
}

const fn hash(t: Inst) u64 {
    return mix(mix(mix(t.op as u64 | t.ty as u64 << 8 | t.aux as u64 << 16, t.a), t.b), t.c);
}

const fn place_hash(addr: u32, off: u32, ty: u8, state: u32) u64 {
    return mix(mix(addr as u64 | ty as u64 << 32, off), state);
}

fn fill<T: Clone + Default + Eq>(v: &mut Vector<T>, n: usize, x: T) {
    v.truncate(0);
    v.resize_default(n);
    if x != T::default() {
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
