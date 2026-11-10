// Superword-level parallelism (Larsen and Amarasinghe, PLDI 2000), bottom-up from seeds as LLVM's SLP
// vectorizer: a pack of N isomorphic scalar values, one per lane of a vector of the target's register
// width (`Package.vector`, at least 16 bytes; a seed short of that many lanes packs the widest power of
// two of 16 bytes or more it fills), becomes one vector value. The seeds: N stores to consecutive
// addresses, in any order within SPAN_MAX instructions, each apart from every access between it and the
// group's last (`apart`: one base at offsets apart, a read-only referent's load, or the optimizer's alias
// classes and objects), N parameters of a block whose arguments on one edge are loads from consecutive
// addresses (a loop's carried values: the vector stays in a register across the back edge), and the N
// terms of a sum (a tree of integer adds, or float adds the build reassociates, each but the root with one
// use: one vector reduction), or more (a pack of each N, their vectors added, then one reduction, which
// the terms past the last pack join). The lanes of a pack's operand form a pack in turn: N instructions of one operation in
// one block (an `add`, `or` or `xor`, also with other values among them, each the operation of itself and
// 0: LLVM's copyable elements), N loads from consecutive addresses each apart from the writes between the
// first and it (one vector load), N parameters of one block other than the entry (one vector parameter;
// each edge into the block passes the pack of its arguments), one value (a splat), a pack's lanes or
// consecutive loads reversed, their halves or their pairs swapped (a `swizzle` the backends do in
// registers), or any values (a gather through memory). Each seed's packs must save more than they add
// (`pays`): a lane a use outside the packs reads keeps its scalar instruction and its operands'. The
// scalar instructions stay for the uses outside the packs, and go where none is left; a vector
// parameter's lanes come out through memory at its block's start for the scalar uses. `lir::opt` keeps
// the result when it lowers the instruction count weighted by loop depth.
import lir::ir as *;
import lir::verify as lv;
import lir::loops as lu;
import ir::core as core;
import ast::ast as ast;

// The bytes of the narrowest pack.
const VBYTES: u32 = 16;
// A body makes at most PACKS_MAX packs; a pack's operands nest at most DEPTH_MAX deep.
const PACKS_MAX: usize = 1024;
const DEPTH_MAX: u32 = 32;
// A block with more parameters is no seed, nor a store more than SPAN_MAX instructions before its
// group's last; loads more than SPAN_MAX apart are no pack (each search is linear in them).
const ARGS_MAX: u32 = 64;
const SPAN_MAX: u32 = 64;
// A vector load of what scalar stores just wrote waits for them (no store forwarding): its cost in
// instructions.
const GATHER_COST: u64 = 8;

const PK_OP: u8 = 1; // instructions of one operation in one block
const PK_LOAD: u8 = 2; // loads from consecutive addresses
const PK_PARAM: u8 = 3; // parameters of one block
const PK_SPLAT: u8 = 4; // one value in every lane
const PK_GATHER: u8 = 5; // any values
const PK_PERM: u8 = 6; // another pack's lanes in another order: lane `perm_lane(n, s, k)` (`perm_ok`)

struct Pack {
    pub(package) kind: u8,
    pub(package) ty: u8, // the lanes' type
    pub(package) n: u32, // the lane count
    pub(package) lane: u32, // its lanes: `lv[lane .. lane + n]`
    pub(package) a: u32, // PK_OP: the operand packs (`b` NONE for a unary operation); PK_PERM: its source, `s`
    pub(package) b: u32,
    pub(package) blk: u32, // PK_GATHER, PK_PERM: the block it runs in, right before instruction `at` (NONE: at its end)
    pub(package) at: u32,
    pub(package) vec: Value, // its vector once made (VNONE: not yet)
    pub(package) tpl: Value, // PK_OP: its first lane of the operation (`identity`); else its first lane
    pub(package) real: u32, // PK_OP: its lanes of the operation; else `n`
}

extend Pack as Copy {}

/// The SLP's scratch, reused from body to body.
pub(package) struct Slp {
    ptr: u32,
    vb: u32, // the bytes of the widest pack
    /// A sum's term loads go right before their adds (`term`): a target without paired accesses
    /// (`Package.apairs`), whose few vector registers would otherwise hold every term at once.
    pub(package) late_terms: bool,
    /// The target joins two scalar accesses of adjacent bytes into one (`Package.apairs`): a seed's
    /// scalar stores take half as many instructions.
    pub(package) pairs: bool,
    /// The instructions a halving step of a sum's reduction adds (`Package.vec_reduce`).
    pub(package) red_step: u64,
    packs: Vector<Pack>,
    lv: Vector<Value>,
    // The lanes `build` takes, a stack: each call's from its `at` on.
    tmp: Vector<Value>,
    opened: Vector<bool>, // `red_seeds`: per instruction of the block, an add another add opens
    open: Vector<Value>, // `red_seeds`: the terms still to open
    iown: Vector<u32>, // per instruction, its PK_OP or PK_LOAD pack (NONE: none)
    pown: Vector<u32>, // per block parameter, its PK_PARAM pack (NONE: none)
    iblk: Vector<u32>, // per instruction, its block
    pblk: Vector<u32>, // per block parameter, its block
    acls: Vector<u8>, // per instruction, its access's alias class (`lir::opt`'s `acls`)
    aobj: Vector<u32>, // per instruction, the object it accesses (`lir::opt`'s `aobj`)
    scoped: u64, // the scope classes (`lir::opt`'s `sbits`)
    /// `plan` took no classes and an access through another base might have been apart with them.
    pub(package) wants: bool,
    /// What the seeds `pays` kept save, weighted: `lir::opt` packs a body only for 2 or more.
    pub(package) paid: i64,
    // The edges into block `k`: `ins[in_at[k] .. in_at[k + 1]]`, from blocks `insrc[..]`.
    in_at: Vector<u32>,
    ins: Vector<u32>,
    insrc: Vector<u32>,
    cur: Vector<u32>,
    eargs: Vector<(u32, u32, u32)>, // (PK_PARAM pack, an edge into its block, the pack of its arguments)
    stores: Vector<u32>, // the seeds' stores, by group
    groups: Vector<(u32, u32)>, // per store seed: its first `stores` index, the pack of its values
    reds: Vector<(u32, u32, u32)>, // per sum seed: its root add, its first pack in `rpk`, their count
    rpk: Vector<u32>, // the packs of the sum seeds' terms, `n` terms each
    rrest: Vector<(u32, u32)>, // per sum seed: its first term in `rterm` past its packs, their count
    rterm: Vector<Value>,
    uses: Vector<u32>, // per instruction, its uses, edge arguments too
    inuse: Vector<u32>, // per instruction, its uses by the packs' lanes, the seeds' stores and sums
    kept: Vector<bool>, // `pays`: per instruction, whether its scalar stays for a use outside the packs
    wgt: Vector<u64>, // per block, the weight of an instruction there
    assoc: bool, // float adds reassociate
    hfa: bool, // a homogeneous float aggregate parameter or result passes in registers (`Package.hfa_regs`)
    sclaim: Vector<bool>, // per instruction, whether a store seed holds it
    extr: Vector<Value>, // per block parameter of a PK_PARAM pack, its lane out of the vector
    edges: Vector<u32>,
    fixed: Vector<bool>, // per instruction made, whether it reads vectors (no lane's scalar)
    /// Instruction << 32 | an instruction made to run right before it, in order.
    pub(package) pre: Vector<u64>,
    /// Block << 32 | an instruction made to run at its end before its terminator, in order.
    pub(package) tail: Vector<u64>,
    /// Per instruction made, its block.
    pub(package) blk: Vector<u32>,
}

extend Slp {
    pub(package) fn new() Slp {
        return Slp {
            ptr: 8,
            vb: VBYTES,
            late_terms: false,
            pairs: false,
            red_step: 0,
            packs: Vector::<Pack>::new(),
            lv: Vector::<Value>::new(),
            tmp: Vector::<Value>::new(),
            opened: Vector::<bool>::new(),
            open: Vector::<Value>::new(),
            iown: Vector::<u32>::new(),
            pown: Vector::<u32>::new(),
            iblk: Vector::<u32>::new(),
            pblk: Vector::<u32>::new(),
            acls: Vector::<u8>::new(),
            aobj: Vector::<u32>::new(),
            scoped: 0,
            wants: false,
            paid: 0,
            in_at: Vector::<u32>::new(),
            ins: Vector::<u32>::new(),
            insrc: Vector::<u32>::new(),
            cur: Vector::<u32>::new(),
            eargs: Vector::<(u32, u32, u32)>::new(),
            stores: Vector::<u32>::new(),
            groups: Vector::<(u32, u32)>::new(),
            reds: Vector::<(u32, u32, u32)>::new(),
            rpk: Vector::<u32>::new(),
            rrest: Vector::<(u32, u32)>::new(),
            rterm: Vector::<Value>::new(),
            uses: Vector::<u32>::new(),
            inuse: Vector::<u32>::new(),
            kept: Vector::<bool>::new(),
            wgt: Vector::<u64>::new(),
            assoc: false,
            hfa: false,
            sclaim: Vector::<bool>::new(),
            extr: Vector::<Value>::new(),
            edges: Vector::<u32>::new(),
            fixed: Vector::<bool>::new(),
            pre: Vector::<u64>::new(),
            tail: Vector::<u64>::new(),
            blk: Vector::<u32>::new(),
        };
    }

    /// The packs of body `b` (`ptr` its pointer size, `vb` the bytes of the widest vector, `w` per block the
    /// weight of an instruction there; per instruction its block `iblk` and its operands and edges'
    /// arguments `ops[ops_at[i]..ops_at[i + 1]]`, per parameter its block `pblk`; per instruction its access's alias
    /// class `acls` and object `aobj`, and the scope classes `scoped`): whether the instructions they save
    /// outweigh the splats and gathers they add. `b` stays as it is.
    pub(package) fn plan(
        self: &mut Self,
        b: &Body,
        ptr: u32,
        vb: u32,
        assoc: bool,
        hfa: bool,
        w: []u64,
        iblk: []u32,
        pblk: []u32,
        ops_at: []u32,
        ops: []Value,
        acls: []u8,
        aobj: []u32,
        scoped: u64,
    ) bool {
        self.ptr = ptr;
        self.vb = vb;
        self.assoc = assoc;
        self.hfa = hfa;
        self.reds.truncate(0);
        self.rrest.truncate(0);
        self.rterm.truncate(0);
        self.rpk.truncate(0);
        let ni = b.insts.len();
        let np = b.params.len();
        let nb = b.blocks.len();
        self.packs.truncate(0);
        self.lv.truncate(0);
        self.tmp.truncate(0);
        self.eargs.truncate(0);
        self.stores.truncate(0);
        self.groups.truncate(0);
        fill(&mut self.iown, ni, NONE);
        fill(&mut self.pown, np, NONE);
        self.iblk.truncate(0);
        self.iblk.extend_from_slice(iblk);
        self.pblk.truncate(0);
        self.pblk.extend_from_slice(pblk);
        self.acls.truncate(0);
        self.acls.extend_from_slice(acls);
        self.aobj.truncate(0);
        self.aobj.extend_from_slice(aobj);
        self.scoped = scoped;
        self.wants = false;
        self.paid = 0;
        fill(&mut self.sclaim, ni, false);
        fill(&mut self.in_at, nb + 1, 0);
        for k in 0..nb {
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                self.in_at[b.edge_target(self.edges[e]) as usize + 1] += 1;
            }
        }
        for k in 0..nb {
            self.in_at[k + 1] += self.in_at[k];
        }
        fill(&mut self.ins, self.in_at[nb] as usize, 0);
        fill(&mut self.insrc, self.in_at[nb] as usize, 0);
        fill(&mut self.cur, nb, 0);
        for k in 0..nb {
            b.succ_edges(term(b, k as u32), &mut self.edges);
            for e in 0..self.edges.len() {
                let s = b.edge_target(self.edges[e]) as usize;
                let at = (self.in_at[s] + self.cur[s]) as usize;
                self.ins[at] = self.edges[e];
                self.insrc[at] = k as u32;
                self.cur[s] += 1;
            }
        }
        self.wgt.truncate(0);
        self.wgt.extend_from_slice(w);
        // Each instruction's uses: by operands and by edges' arguments.
        fill(&mut self.uses, ni, 0);
        fill(&mut self.inuse, ni, 0);
        fill(&mut self.kept, ni, false);
        for i in 0..ni {
            for q in ops_at[i]..ops_at[i + 1] {
                let v = ops[q as usize];
                if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
                    self.uses[v as usize] += 1;
                }
            }
        }
        for k in 1..nb {
            self.edge_seeds(b, k as u32);
        }
        let edge_packs = self.packs.len();
        for k in 0..nb {
            self.store_seeds(b, k as u32);
        }
        for k in 0..nb {
            self.red_seeds(b, k as u32);
        }
        // What the loops' carried vectors save counts too (`paid`), with every seed's reads known; they stay
        // whatever it is.
        let _ = self.pays_of(b, 0, edge_packs, 0);
        // The stores again: a group whose values a sum's packs now hold reads their vector, where before
        // the sum's reads of them kept their scalars (`pays`).
        for k in 0..nb * (self.reds.len() != 0) as usize {
            self.store_seeds(b, k as u32);
        }
        // The estimate: what the packs and the seeds' stores save, less what the splats and gathers add.
        let mut gain: u64 = 0;
        let mut cost: u64 = 0;
        for p in 0..self.packs.len() {
            let pk = self.packs[p];
            let l0 = self.lv[pk.lane as usize];
            if pk.kind == PK_OP || pk.kind == PK_LOAD {
                gain += (pk.real - 1) as u64 * w[self.iblk[pk.tpl as usize] as usize];
            } else if pk.kind == PK_SPLAT || pk.kind == PK_GATHER {
                // Splats of one value are one (the optimizer numbers them).
                let mut again = false;
                for x in 0..p * (pk.kind == PK_SPLAT) as usize {
                    let o = self.packs[x];
                    again = again || o.kind == PK_SPLAT && o.n == pk.n && o.ty == pk.ty && self.lv[o.lane as usize] == l0;
                }
                if again {
                    continue;
                }
                let k = if pk.kind == PK_GATHER {
                    pk.blk
                } else {
                    self.def_block(l0)
                };
                cost += if self.consts(b, pk) || pk.kind == PK_SPLAT {
                    1u64
                } else {
                    pk.n as u64 + 1 + GATHER_COST
                } * w[k as usize];
            } else if pk.kind == PK_PERM {
                cost += perm_cost(pk) * w[pk.blk as usize];
            }
        }
        for g in 0..self.groups.len() {
            let (s0, vp) = self.groups[g];
            gain += (self.packs[vp as usize].n - 1) as u64 * w[self.iblk[self.stores[s0 as usize] as usize] as usize] / if self.pairs {
                2u64
            } else {
                1u64
            };
        }
        // A sum's reduction: `red_step` per halving of its lanes.
        for x in 0..self.reds.len() {
            let (r, p0, _) = self.reds[x];
            let lanes = self.packs[self.rpk[p0 as usize] as usize].n;
            cost += self.red_step * lanes.trailing_zeros() as u64 * w[self.iblk[r as usize] as usize];
        }
        return gain > cost;
    }

    /// Make the planned packs' vectors in `b`: the instructions made follow `b`'s, placed by `pre`, `tail`
    /// and `blk`; a seed's stores become one, the vector parameters' scalar uses read their lanes.
    pub(package) fn emit(self: &mut Self, b: &mut Body) {
        let ni = b.insts.len();
        self.pre.truncate(0);
        self.tail.truncate(0);
        self.blk.truncate(0);
        self.fixed.truncate(0);
        fill(&mut self.extr, b.params.len(), VNONE);
        // The parameters first: their lanes come out at their blocks' start, before any other use.
        for p in 0..self.packs.len() {
            if self.packs[p].kind == PK_PARAM {
                self.param(b, p as u32);
            }
        }
        // A sum's terms are made with the sum (`term`), under `late_terms`.
        let mut term = Vector::<bool>::new();
        term.resize_default(self.packs.len());
        for x in 0..self.reds.len() * self.late_terms as usize {
            let (_, p0, np) = self.reds[x];
            for q in 0..np {
                term[self.rpk[(p0 + q) as usize] as usize] = true;
            }
        }
        for p in 0..self.packs.len() {
            if !term[p] {
                let _ = self.vector(b, p as u32);
            }
        }
        for x in 0..self.eargs.len() {
            let (pp, e, ap) = self.eargs[x];
            let v = self.vector(b, ap);
            let p0 = self.lv[self.packs[pp as usize].lane as usize] & ~VPARAM;
            let q0 = p0 - b.blocks[self.pblk[p0 as usize] as usize].param_start;
            b.pool[(e + 2 + q0) as usize] = v;
        }
        // A sum's root: the reduction of the sum of its terms' vectors.
        for x in 0..self.reds.len() {
            let (r, p0, np) = self.reds[x];
            let t = b.insts[r as usize];
            let k = self.iblk[r as usize];
            let mut v = self.term(b, self.rpk[p0 as usize], k, r);
            for q in 1..np {
                let w = self.term(b, self.rpk[(p0 + q) as usize], k, r);
                v = self.make(b, Inst { op: t.op, ty: b.type_of(v), aux: 0, a: v, b: w, c: VNONE }, k, r, true);
            }
            let one = [v];
            let at = b.pool_list(one[0..1]);
            let code = (core::OP_SIMD + core::SIMD_REDUCE_ADD as u32) as u16;
            let mut red = self.make(b, Inst { op: O_VOP, ty: t.ty, aux: code, a: at, b: 1, c: VNONE }, k, r, true);
            // The terms past the packs, added to the reduction in order.
            let (r0, nr) = self.rrest[x];
            for q in r0..r0 + nr {
                red = self.make(
                    b,
                    Inst { op: t.op, ty: t.ty, aux: 0, a: red, b: self.rterm[q as usize], c: VNONE },
                    k,
                    r,
                    true,
                );
            }
            let c = self.make(b, Inst { op: O_ICONST, ty: T_I8, aux: 0, a: 1, b: 0, c: VNONE }, k, r, false);
            b.insts[r as usize] = Inst { op: O_SELECT, ty: t.ty, aux: 0, a: c, b: red, c: red };
        }
        for g in 0..self.groups.len() {
            let (s0, vp) = self.groups[g];
            let n = self.packs[vp as usize].n;
            let first = self.stores[s0 as usize];
            let mut last: u32 = 0;
            for q in 0..n {
                last = last.max(self.stores[(s0 + q) as usize]);
            }
            let t = b.insts[first as usize];
            let (root, off) = address(b, t);
            let v = self.vector(b, vp);
            let _ = self.make(
                b,
                Inst { op: O_STORE, ty: T_NONE, aux: t.aux, a: root, b: v, c: off as u32 },
                self.iblk[last as usize],
                last,
                true,
            );
            for q in 0..n {
                let s = self.stores[(s0 + q) as usize];
                b.insts[s as usize] = Inst { op: O_ICONST, ty: T_I32, aux: 0, a: 0, b: 0, c: VNONE };
            }
        }
        self.remap(b, ni);
    }

    // The lanes of the widest pack of `ty` (32- and 64-bit lanes only), 0 for another type.
    const fn lane_count(self: &Self, ty: u8) u32 {
        return if ty == T_I32 || ty == T_F32 || ty == T_I64 || ty == T_F64 {
            self.vb / type_bytes(ty, 8)
        } else {
            0u32
        };
    }

    // ---- Seeds ----

    // The sums of block `k`: a root add whose terms (through inner adds of one use in the block, at most
    // the widest pack's lane count of them) pack.
    fn red_seeds(self: &mut Self, b: &Body, k: u32) {
        let bk = b.blocks[k as usize];
        // The adds another add of the block opens (`inner`): no root.
        fill(&mut self.opened, bk.len as usize, false);
        for i in bk.start..bk.start + bk.len - 1 {
            let t = b.insts[i as usize];
            if t.op == O_ADD || t.op == O_FADD {
                for o in [t.a, t.b] {
                    if self.inner(b, o, k, t) {
                        self.opened[(o - bk.start) as usize] = true;
                    }
                }
            }
        }
        for i in bk.start..bk.start + bk.len - 1 {
            let t = b.insts[i as usize];
            let fl = t.op == O_FADD && self.assoc;
            if t.op != O_ADD && !fl || self.iown[i as usize] != NONE || self.opened[(i - bk.start) as usize] {
                continue;
            }
            let n = self.lane_count(t.ty);
            if n == 0 {
                continue;
            }
            // The terms, left to right: a stack of the values still to open.
            let at = self.tmp.len();
            self.open.truncate(0);
            self.open.push(i);
            // Each step opens one add of the block or takes one term: at most 2 * len + 1 steps.
            let mut steps: u32 = 0;
            while self.open.len() != 0 && steps <= 2 * bk.len + 1 {
                steps += 1;
                let v = self.open.pop().unwrap();
                if v == i || self.inner(b, v, k, t) {
                    // Its right term after its left.
                    let x = b.insts[v as usize];
                    self.open.push(x.b);
                    self.open.push(x.a);
                } else {
                    self.tmp.push(v);
                }
            }
            let got = (self.tmp.len() - at) as u32;
            let size = type_bytes(t.ty, self.ptr);
            // One pack of the terms, or a pack of each `n` of them, the rest (`rest`) added to the reduction.
            let one = got <= n && fit(got, n, size) == got;
            let np = if one {
                1u32
            } else {
                got / n
            };
            let rest = if one {
                0u32
            } else {
                got % n
            };
            if self.open.len() == 0 && got >= 2 && np != 0 {
                // Kept when no pack it makes gathers; else its packs go.
                let np0 = self.packs.len();
                let nl0 = self.lv.len();
                let ne0 = self.eargs.len();
                let r0 = self.rpk.len() as u32;
                let mut keep = true;
                let per = (got - rest) / np;
                for q in 0..np {
                    let vp = self.build(b, at as u32 + q * per, per, t.ty, k, i, 0);
                    keep = keep && vp != NONE && self.packs[vp as usize].kind != PK_SPLAT && self.packs[vp as usize].kind != PK_GATHER;
                    if !keep {
                        break;
                    }
                    self.rpk.push(vp);
                }
                for p in np0..self.packs.len() {
                    keep = keep && (self.packs[p].kind != PK_GATHER || self.consts(b, self.packs[p]));
                }
                // The adds that the vector adds and the reduction replace.
                let w = self.wgt[k as usize] as i64;
                let saved = (got - np - rest) as i64 * w - self.red_step as i64 * per.trailing_zeros() as i64 * w;
                for x in at..at + (got - rest) as usize {
                    self.use_lane(self.tmp[x], 1);
                }
                keep = keep && self.pays(b, np0, saved);
                if keep {
                    self.reds.push((i, r0, np));
                    self.rrest.push((self.rterm.len() as u32, rest));
                    for x in at + (got - rest) as usize..at + got as usize {
                        self.rterm.push(self.tmp[x]);
                    }
                } else {
                    for x in at..at + (got - rest) as usize {
                        self.use_lane(self.tmp[x], -1);
                    }
                    self.rpk.truncate(r0 as usize);
                    self.drop_packs(b, np0, nl0, ne0);
                }
            }
            self.tmp.truncate(at);
        }
    }

    // Drop the packs from `np0` on (their lanes from `nl0`, the edge packs from `ne0`): their values belong
    // to no pack again.
    fn drop_packs(self: &mut Self, b: &Body, np0: usize, nl0: usize, ne0: usize) {
        for x in ne0..self.eargs.len() {
            self.use_edge(b, x, -1);
        }
        for p in np0..self.packs.len() {
            let pk = self.packs[p];
            if pk.kind == PK_OP {
                self.use_operands(b, p as u32, -1);
            }
            if pk.kind != PK_OP && pk.kind != PK_LOAD && pk.kind != PK_PARAM {
                continue;
            }
            for q in 0..pk.n {
                let v = self.lv[(pk.lane + q) as usize];
                if (v & VPARAM) != 0 {
                    if self.pown[(v & ~VPARAM) as usize] == p as u32 {
                        self.pown[(v & ~VPARAM) as usize] = NONE;
                    }
                } else if self.iown[v as usize] == p as u32 {
                    self.iown[v as usize] = NONE;
                }
            }
        }
        self.packs.truncate(np0);
        self.lv.truncate(nl0);
        self.eargs.truncate(ne0);
    }

    // Whether value `v` is an inner add of a sum like root `r` in block `k`: the same operation and type,
    // one use, no pack's.
    const fn inner(self: &Self, b: &Body, v: Value, k: u32, r: Inst) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.iblk[v as usize] != k || self.iown[v as usize] != NONE {
            return false;
        }
        let x = b.insts[v as usize];
        return x.op == r.op && x.ty == r.ty && self.uses[v as usize] == 1;
    }

    // The parameters of block `k` whose arguments on an edge into it are loads from consecutive
    // addresses, packed.
    fn edge_seeds(self: &mut Self, b: &Body, k: u32) {
        let bk = b.blocks[k as usize];
        let na = bk.param_len as u32;
        if na < 2 || na > ARGS_MAX {
            return;
        }
        for j in self.in_at[k as usize]..self.in_at[k as usize + 1] {
            let e = self.ins[j as usize];
            for q in 0..na {
                let p = bk.param_start + q;
                let ty = b.params[p as usize];
                let n = self.lane_count(ty);
                let x = b.edge_arg(e, q);
                if self.pown[p as usize] != NONE || n == 0 || !plain_load(b, x, ty) {
                    continue;
                }
                let (root, off) = address(b, b.insts[x as usize]);
                let size = type_bytes(ty, self.ptr) as i64;
                let at = self.tmp.len();
                self.tmp.push(VPARAM | p);
                let mut got: u32 = 1;
                while got < n {
                    let mut found = NONE;
                    for q2 in 0..na {
                        let p2 = bk.param_start + q2;
                        let y = b.edge_arg(e, q2);
                        if q2 == q || self.pown[p2 as usize] != NONE || b.params[p2 as usize] != ty || !plain_load(
                            b,
                            y,
                            ty,
                        ) {
                            continue;
                        }
                        let (r2, o2) = address(b, b.insts[y as usize]);
                        if r2 == root && o2 == off + got as i64 * size {
                            found = p2;
                            break;
                        }
                    }
                    if found == NONE {
                        break;
                    }
                    self.tmp.push(VPARAM | found);
                    got += 1;
                }
                let m = fit(got, n, size as u32);
                if m != 0 {
                    let _ = self.build(b, at as u32, m, ty, NONE, NONE, 0);
                }
                self.tmp.truncate(at);
            }
        }
    }

    // The stores of block `k` to consecutive addresses, each apart from every access between it and the
    // group's last (`apart`: the vector store goes there), whose values pack into instructions, loads or
    // parameters.
    fn store_seeds(self: &mut Self, b: &Body, k: u32) {
        let bk = b.blocks[k as usize];
        let end = bk.start + bk.len - 1;
        for i in bk.start..end {
            let t = b.insts[i as usize];
            if t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || self.sclaim[i as usize] {
                continue;
            }
            let ty = b.type_of(t.b);
            let n = self.lane_count(ty);
            if n == 0 {
                continue;
            }
            let (root, off) = address(b, t);
            if self.in_regs(b, root) {
                continue;
            }
            let size = type_bytes(ty, self.ptr) as i64;
            // The values on the lane stack, the stores past the seeds' (`stores`) until it is one: lane `q`
            // the store to `off + q * size` within SPAN_MAX instructions of `i`, before it or after it.
            let at = self.tmp.len();
            let sat = self.stores.len();
            self.tmp.push(t.b);
            self.stores.push(i);
            let lo = bk.start.max(i.max(SPAN_MAX) - SPAN_MAX);
            let hi = end.min(i + SPAN_MAX + 1);
            let mut got: u32 = 1;
            while got < n {
                let mut found = NONE;
                for j in lo..hi {
                    let u = b.insts[j as usize];
                    if j != i && u.op == O_STORE && (u.aux & MEM_VOLATILE) == 0 && !self.sclaim[j as usize] && b.type_of(
                        u.b,
                    ) == ty {
                        let (r2, o2) = address(b, u);
                        if r2 == root && o2 == off + got as i64 * size {
                            found = j;
                            break;
                        }
                    }
                }
                if found == NONE {
                    break;
                }
                self.tmp.push(b.insts[found as usize].b);
                self.stores.push(found);
                got += 1;
            }
            // The widest group whose stores move to its last one past the accesses between (`group_last`).
            let mut m = fit(got, n, size as u32);
            let mut last = NONE;
            while m != 0 {
                last = self.group_last(b, sat, m);
                if last != NONE {
                    break;
                }
                m = fit(m - 1, n, size as u32);
            }
            let np0 = self.packs.len();
            let nl0 = self.lv.len();
            let ne0 = self.eargs.len();
            let vp = if m != 0 {
                self.build(b, at as u32, m, ty, k, last, 0)
            } else {
                NONE
            };
            let mut keep = vp != NONE && self.packs[vp as usize].kind != PK_SPLAT && self.packs[vp as usize].kind != PK_GATHER;
            if keep {
                // The stores the vector store replaces.
                let saved = (m - 1) as i64 * self.wgt[k as usize] as i64 / ast::pick(self.pairs, 2i64, 1);
                for q in 0..m {
                    self.use_lane(self.tmp[at + q as usize], 1);
                }
                keep = self.pays(b, np0, saved);
                if !keep {
                    for q in 0..m {
                        self.use_lane(self.tmp[at + q as usize], -1);
                    }
                }
            }
            self.tmp.truncate(at);
            if !keep {
                self.drop_packs(b, np0, nl0, ne0);
                self.stores.truncate(sat);
                continue;
            }
            // The stores past the pack's are seeds again.
            self.stores.truncate(sat + m as usize);
            self.groups.push((sat as u32, vp));
            for q in sat..self.stores.len() {
                self.sclaim[self.stores[q] as usize] = true;
            }
        }
    }

    // The last of the stores `stores[sat .. sat + m]` of one block, when each is apart from every access
    // between it and that last one but the group's (`apart`): the vector store goes there. NONE when not.
    const fn group_last(self: &mut Self, b: &Body, sat: usize, m: u32) u32 {
        let mut last: u32 = 0;
        for q in 0..m {
            last = last.max(self.stores[sat + q as usize]);
        }
        for q in 0..m {
            let s = self.stores[sat + q as usize];
            for u in s + 1..last {
                if !touches(b.insts[u as usize]) || self.apart(b, s, u) {
                    continue;
                }
                let mut lane = false;
                for r in 0..m {
                    lane = lane || self.stores[sat + r as usize] == u;
                }
                if !lane {
                    return NONE;
                }
            }
        }
        return last;
    }

    // ---- Packs ----

    // The pack of lanes `tmp[at .. at + n]` of type `ty`, for a user in block `ublk` right before
    // instruction `uat` (NONE: at the block's end), `depth` packs deep.
    fn build(self: &mut Self, b: &Body, at: u32, n: u32, ty: u8, ublk: u32, uat: u32, depth: u32) u32 {
        let l0 = self.tmp[at as usize];
        let mut same = true;
        for q in 1..n {
            same = same && self.tmp[(at + q) as usize] == l0;
        }
        if same {
            return self.add(PK_SPLAT, ty, at, n, ublk, uat);
        }
        if depth >= DEPTH_MAX || self.packs.len() >= PACKS_MAX {
            return self.add(PK_GATHER, ty, at, n, ublk, uat);
        }
        let o = self.owner(l0);
        if o != NONE {
            if self.same_lanes(o, at, n) {
                return o;
            }
            let s = self.perm_of(o, at, n, ty);
            return if s != 0 {
                self.add_perm(o, s, ty, at, n, ublk, uat)
            } else {
                self.add(PK_GATHER, ty, at, n, ublk, uat)
            };
        }
        let top = self.tmp.len();
        if self.params_of_one_block(b, at, n, ty) {
            let p = self.add(PK_PARAM, ty, at, n, NONE, NONE);
            for q in 0..n {
                self.pown[(self.tmp[(at + q) as usize] & ~VPARAM) as usize] = p;
            }
            let k = self.pblk[(l0 & ~VPARAM) as usize];
            let ps = b.blocks[k as usize].param_start;
            for j in self.in_at[k as usize]..self.in_at[k as usize + 1] {
                let e = self.ins[j as usize];
                for q in 0..n {
                    self.tmp.push(b.edge_arg(e, (self.tmp[(at + q) as usize] & ~VPARAM) - ps));
                }
                let ap = self.build(b, top as u32, n, ty, self.insrc[j as usize], NONE, depth + 1);
                self.tmp.truncate(top);
                self.eargs.push((p, e, ap));
                self.use_edge(b, self.eargs.len() - 1, 1);
            }
            return p;
        }
        let mut kind = self.isomorphic(b, at, n, ty);
        // Loads from consecutive addresses in another order: their vector, its lanes moved.
        if kind == 0 && plain_load(b, l0, ty) {
            for s in 1..2 * n {
                if !perm_ok(n, type_bytes(ty, self.ptr), s) {
                    continue;
                }
                // Lane perm_lane(s, k) of the loads in address order is lane k: lane j of them is lane
                // perm_lane's inverse of j.
                for q in 0..n {
                    self.tmp.push(self.tmp[(at + perm_back(n, s, q)) as usize]);
                }
                let ok = self.isomorphic(b, top as u32, n, ty) == PK_LOAD;
                let lp = if ok {
                    self.build(b, top as u32, n, ty, ublk, uat, depth + 1)
                } else {
                    NONE
                };
                self.tmp.truncate(top);
                if lp != NONE {
                    return self.add_perm(lp, s, ty, at, n, ublk, uat);
                }
            }
        }
        // The lanes that are no instruction of the operation (`ids`, a bit each), when they are its identity.
        let mut ids: u64 = 0;
        if kind == 0 {
            ids = self.identity(b, at, n, ty);
            if ids == 0 {
                return self.add(PK_GATHER, ty, at, n, ublk, uat);
            }
            kind = PK_OP;
        }
        let p = self.add(kind, ty, at, n, NONE, NONE);
        let mut last: u32 = 0;
        let mut tpl = VNONE;
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            if (ids >> q as u64 & 1) == 0 {
                self.iown[v as usize] = p;
                last = last.max(v);
                tpl = tpl.min(v);
            }
        }
        self.packs.index_mut(p as usize).tpl = tpl;
        self.packs.index_mut(p as usize).real = n - ids.count_ones() as u32;
        if kind == PK_LOAD {
            return p;
        }
        self.use_operands(b, p, 1);
        // The operands' packs, for the vector instruction right before the last lane: an identity lane's
        // operands are its value and 0 (VNONE, `lane_bits`).
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            self.tmp.push(
                if (ids >> q as u64 & 1) != 0 {
                    v
                } else {
                    b.insts[v as usize].a
                },
            );
        }
        let pa = self.build(b, top as u32, n, ty, self.iblk[last as usize], last, depth + 1);
        self.tmp.truncate(top);
        self.packs.index_mut(p as usize).a = pa;
        if !unary(b.insts[tpl as usize].op) {
            for q in 0..n {
                let v = self.tmp[(at + q) as usize];
                self.tmp.push(
                    if (ids >> q as u64 & 1) != 0 {
                        VNONE
                    } else {
                        b.insts[v as usize].b
                    },
                );
            }
            let pb = self.build(b, top as u32, n, ty, self.iblk[last as usize], last, depth + 1);
            self.tmp.truncate(top);
            self.packs.index_mut(p as usize).b = pb;
        }
        return p;
    }

    fn add(self: &mut Self, kind: u8, ty: u8, at: u32, n: u32, blk: u32, uat: u32) u32 {
        let lane = self.lv.len() as u32;
        for q in 0..n {
            self.lv.push(self.tmp[(at + q) as usize]);
        }
        self.packs.push(
            Pack {
                kind: kind,
                ty: ty,
                n: n,
                lane: lane,
                a: NONE,
                b: NONE,
                blk: blk,
                at: uat,
                vec: VNONE,
                tpl: self.tmp[at as usize],
                real: n,
            },
        );
        return self.packs.len() as u32 - 1;
    }

    // The PK_OP, PK_LOAD or PK_PARAM pack holding value `v` (NONE: none).
    const fn owner(self: &Self, v: Value) u32 {
        if v == VNONE || (v & VFLAG) != 0 {
            return NONE;
        }
        if (v & VPARAM) != 0 {
            return self.pown[(v & ~VPARAM) as usize];
        }
        return self.iown[v as usize];
    }

    // Whether pack `p` holds lanes `tmp[at .. at + n]` in that order.
    const fn same_lanes(self: &Self, p: u32, at: u32, n: u32) bool {
        let pk = self.packs[p as usize];
        if pk.n != n {
            return false;
        }
        for q in 0..n {
            if self.lv[(pk.lane + q) as usize] != self.tmp[(at + q) as usize] {
                return false;
            }
        }
        return true;
    }

    // The `s` of a lane order `perm_ok` takes in which pack `p` holds lanes `tmp[at .. at + n]` of type `ty`
    // (lane k from lane `perm_lane(n, s, k)`), 0 for none.
    const fn perm_of(self: &Self, p: u32, at: u32, n: u32, ty: u8) u32 {
        let pk = self.packs[p as usize];
        if pk.n != n {
            return 0;
        }
        for s in 1..2 * n + 2 {
            let mut all = perm_ok(n, type_bytes(ty, self.ptr), s);
            for q in 0..n {
                all = all && self.lv[(pk.lane + perm_lane(n, s, q)) as usize] == self.tmp[(at + q) as usize];
            }
            if all {
                return s;
            }
        }
        return 0;
    }

    // PK_PERM pack of lanes `tmp[at .. at + n]` of type `ty`: pack `src`'s, lane k from lane
    // `perm_lane(n, s, k)`, for a user in block `ublk` right before instruction `uat`.
    fn add_perm(self: &mut Self, src: u32, s: u32, ty: u8, at: u32, n: u32, ublk: u32, uat: u32) u32 {
        let p = self.add(PK_PERM, ty, at, n, ublk, uat);
        self.packs.index_mut(p as usize).a = src;
        self.packs.index_mut(p as usize).b = s;
        return p;
    }

    // Whether lanes `tmp[at .. at + n]` are distinct parameters of type `ty` of one block other than the
    // entry, no pack holding any.
    const fn params_of_one_block(self: &Self, b: &Body, at: u32, n: u32, ty: u8) bool {
        let l0 = self.tmp[at as usize];
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            if v == VNONE || (v & VPARAM) == 0 || (v & VFLAG) != 0 {
                return false;
            }
            let p = v & ~VPARAM;
            if self.pown[p as usize] != NONE || b.params[p as usize] != ty || self.pblk[p as usize] == 0 || self.pblk[p as usize] != self.pblk[(l0 & ~VPARAM) as usize] {
                return false;
            }
            for r in 0..q {
                if self.tmp[(at + r) as usize] == v {
                    return false;
                }
            }
        }
        return true;
    }

    // PK_LOAD when lanes `tmp[at .. at + n]` are loads of type `ty` from consecutive addresses in one block,
    // each apart from every write between the first lane and it (the vector load goes at the first); PK_OP when they are distinct instructions of one operation a vector has,
    // flags and type in one block; else 0. No pack holds any.
    const fn isomorphic(self: &mut Self, b: &Body, at: u32, n: u32, ty: u8) u8 {
        let l0 = self.tmp[at as usize];
        let mut lo = NONE;
        let mut hi: u32 = 0;
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || self.iown[v as usize] != NONE {
                return 0;
            }
            for r in 0..q {
                if self.tmp[(at + r) as usize] == v {
                    return 0;
                }
            }
            lo = lo.min(v);
            hi = hi.max(v);
        }
        let t0 = b.insts[l0 as usize];
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            let t = b.insts[v as usize];
            // A load's alignment may differ: the vector takes the first lane's.
            let flags = ast::pick(t0.op == O_LOAD, 0xFFF0u16, 0xFFFFu16);
            if t.op != t0.op || t.ty != ty || (t.aux & flags) != (t0.aux & flags) || self.iblk[v as usize] != self.iblk[l0 as usize] {
                return 0;
            }
        }
        if t0.op == O_LOAD {
            if (t0.aux & MEM_VOLATILE) != 0 || hi - lo > SPAN_MAX {
                return 0;
            }
            let (root, off) = address(b, t0);
            if self.in_regs(b, root) {
                return 0;
            }
            let size = type_bytes(ty, self.ptr) as i64;
            for q in 1..n {
                let (r2, o2) = address(b, b.insts[self.tmp[(at + q) as usize] as usize]);
                if r2 != root || o2 != off + q as i64 * size {
                    return 0;
                }
            }
            for q in 0..n {
                let v = self.tmp[(at + q) as usize];
                for i in lo + 1..v {
                    if writes_memory(b.insts[i as usize]) && !self.apart(b, i, v) {
                        return 0;
                    }
                }
            }
            return PK_LOAD;
        }
        let op = t0.op;
        let int_op = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR || op == O_NEG || op == O_NOT || op == O_MUL && type_bytes(
            ty,
            self.ptr,
        ) < 8;
        let float_op = op >= O_FADD && op <= O_FNEG || op == O_FSQRT;
        return ast::pick(is_int(ty) && int_op || is_float(ty) && float_op, PK_OP, 0u8);
    }

    // The lanes of `tmp[at .. at + n]` of type `ty` that are each the operation of itself and 0 (a bit
    // each), when the others, at least half, are distinct instructions of one `add`, `or` or `xor` of one
    // block, its flags and type, no pack's: such a lane is an entry parameter or an instruction of that
    // block before the last of the others, and no other lane. 0 when not.
    const fn identity(self: &Self, b: &Body, at: u32, n: u32, ty: u8) u64 {
        if !is_int(ty) || n > 64 {
            return 0;
        }
        // The operation (0: none yet), its flags and block.
        let mut op0: u8 = 0;
        let mut aux0: u16 = 0;
        let mut k = NONE;
        let mut last: u32 = 0;
        let mut ids: u64 = 0;
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            let inst = v != VNONE && (v & (VPARAM | VFLAG)) == 0;
            let t = if inst {
                b.insts[v as usize]
            } else {
                Inst { op: O_ICONST, ty: T_NONE, aux: 0, a: 0, b: 0, c: VNONE }
            };
            let op = t.op == O_ADD || t.op == O_OR || t.op == O_XOR;
            if op && t.ty == ty && self.iown[v as usize] == NONE && (op0 == 0 || t.op == op0 && t.aux == aux0 && self.iblk[v as usize] == k) {
                for r in 0..q {
                    if self.tmp[(at + r) as usize] == v {
                        return 0;
                    }
                }
                op0 = t.op;
                aux0 = t.aux;
                k = self.iblk[v as usize];
                last = last.max(v);
            } else {
                ids |= 1u64 << q as u64;
            }
        }
        if op0 == 0 || ids.count_ones() as u32 > n / 2 {
            return 0;
        }
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            if (ids >> q as u64 & 1) == 0 {
                continue;
            }
            if v == VNONE || (v & VFLAG) != 0 || b.type_of(v) != ty {
                return 0;
            }
            let entry = (v & VPARAM) != 0 && self.pblk[(v & ~VPARAM) as usize] == 0;
            let before = (v & VPARAM) == 0 && self.iblk[v as usize] == k && v < last && self.iown[v as usize] == NONE;
            if !entry && !before {
                return 0;
            }
            for r in 0..n {
                if r != q && (ids >> r as u64 & 1) == 0 && self.tmp[(at + r) as usize] == v {
                    return 0;
                }
            }
        }
        return ids;
    }

    // Count `d` (1 or -1) more uses of value `v` by the packs (`inuse`): none for a parameter or a flag.
    const fn use_lane(self: &mut Self, v: Value, d: i32) {
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
            self.inuse[v as usize] = (self.inuse[v as usize] as i32 + d) as u32;
        }
    }

    // Count `d` more uses (`use_lane`) of the arguments edge pack `eargs[x]` passes to a vector parameter.
    const fn use_edge(self: &mut Self, b: &Body, x: usize, d: i32) {
        let (pp, e, _) = self.eargs[x];
        let pk = self.packs[pp as usize];
        for q in 0..pk.n {
            let p = self.lv[(pk.lane + q) as usize] & ~VPARAM;
            self.use_lane(b.edge_arg(e, p - b.blocks[self.pblk[p as usize] as usize].param_start), d);
        }
    }

    // Count `d` more uses (`use_lane`) of the operands of PK_OP pack `p`'s lanes: an operation's
    // operands, an identity lane's value.
    const fn use_operands(self: &mut Self, b: &Body, p: u32, d: i32) {
        let pk = self.packs[p as usize];
        for q in 0..pk.n {
            let v = self.lv[(pk.lane + q) as usize];
            if (v & VPARAM) != 0 || self.iown[v as usize] != p {
                self.use_lane(v, d);
            } else {
                let t = b.insts[v as usize];
                self.use_lane(t.a, d);
                if !unary(t.op) {
                    self.use_lane(t.b, d);
                }
            }
        }
    }

    // Whether the packs from `np0` on, one seed's, save more than they add, with `saved` more saved: a
    // lane whose value a use outside the packs reads keeps its scalar instruction, and so its operands',
    // and saves none; a gather of other values than constants adds its own. A splat or a constant, which
    // several seeds may share, counts in `plan`'s estimate of all seeds.
    const fn pays(self: &mut Self, b: &Body, np0: usize, saved: i64) bool {
        return self.pays_of(b, np0, self.packs.len(), saved);
    }

    // `pays` of the packs from `np0` to `np1`.
    const fn pays_of(self: &mut Self, b: &Body, np0: usize, np1: usize, saved: i64) bool {
        let mut gain = saved;
        for p in np0..np1 {
            let pk = self.packs[p];
            if pk.kind == PK_OP || pk.kind == PK_LOAD {
                let mut real: i64 = 0;
                for q in 0..pk.n {
                    let v = self.lv[(pk.lane + q) as usize];
                    if (v & VPARAM) != 0 || self.iown[v as usize] != p as u32 {
                        continue;
                    }
                    if self.uses[v as usize] > self.inuse[v as usize] {
                        self.kept[v as usize] = true;
                    }
                    if !self.kept[v as usize] {
                        real += 1;
                    } else if pk.kind == PK_OP {
                        let t = b.insts[v as usize];
                        self.keep(t.a);
                        self.keep(t.b);
                    }
                }
                gain += (real - 1) * self.wgt[self.iblk[pk.tpl as usize] as usize] as i64;
            } else if pk.kind == PK_GATHER && !self.consts(b, pk) {
                gain -= (pk.n as i64 + 1 + GATHER_COST as i64) * self.wgt[pk.blk as usize] as i64;
            } else if pk.kind == PK_PERM {
                gain -= perm_cost(pk) as i64 * self.wgt[pk.blk as usize] as i64;
            }
        }
        // `kept` back to false: the lanes and their operands.
        for p in np0..np1 {
            let pk = self.packs[p];
            if pk.kind != PK_OP && pk.kind != PK_LOAD {
                continue;
            }
            for q in 0..pk.n {
                let v = self.lv[(pk.lane + q) as usize];
                if (v & VPARAM) != 0 || self.iown[v as usize] != p as u32 {
                    continue;
                }
                self.kept[v as usize] = false;
                if pk.kind == PK_OP {
                    let t = b.insts[v as usize];
                    self.unkeep(t.a);
                    self.unkeep(t.b);
                }
            }
        }
        if gain > 0 {
            self.paid += gain;
        }
        return gain > 0;
    }

    // `pays`: instruction value `v`'s scalar stays (`kept`).
    const fn keep(self: &mut Self, v: Value) {
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
            self.kept[v as usize] = true;
        }
    }

    const fn unkeep(self: &mut Self, v: Value) {
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 {
            self.kept[v as usize] = false;
        }
    }

    // Whether loads or stores `x` and `y` touch different bytes, so they run in either order: through one base
    // at offsets apart, a load of a read-only referent (CL_FROZEN, which no write touches), or objects or
    // alias classes the optimizer keeps apart (`aobj`, `acls`; a scope's class holds only for the loops its
    // roots are outside of, so none here). A volatile access keeps its place. Without the classes (`plan`
    // takes none at first) two accesses through different bases are not apart, and `wants` says so.
    const fn apart(self: &mut Self, b: &Body, x: u32, y: u32) bool {
        let tx = b.insts[x as usize];
        let ty = b.insts[y as usize];
        if tx.op != O_LOAD && tx.op != O_STORE || ty.op != O_LOAD && ty.op != O_STORE || ((tx.aux | ty.aux) & MEM_VOLATILE) != 0 {
            return false;
        }
        let (rx, ox) = address(b, tx);
        let (ry, oy) = address(b, ty);
        if rx == ry && (ox + access_bytes(b, tx, self.ptr) <= oy || oy + access_bytes(b, ty, self.ptr) <= ox) {
            return true;
        }
        if self.acls.len() == 0 {
            self.wants = self.wants || rx != ry;
            return false;
        }
        let jx = self.aobj[x as usize];
        let jy = self.aobj[y as usize];
        if jx != jy && (jx != NONE && jy != NONE || jx != NONE && (jx & lu::OBJ_PRIVATE) != 0 || jy != NONE && (jy & lu::OBJ_PRIVATE) != 0) {
            return true;
        }
        let cx = self.acls[x as usize];
        let cy = self.acls[y as usize];
        return cx == CL_FROZEN || cy == CL_FROZEN || cx != cy && self.settled(cx) && self.settled(cy);
    }

    // Whether alias class `c` keeps its accesses apart from another class's: no CL_MANY, no scope's.
    const fn settled(self: &Self, c: u8) bool {
        return c < CL_MANY && (self.scoped >> c as u64 & 1) == 0;
    }

    // Whether `v` is the address of an aggregate parameter or result whose elements pass in registers, one
    // each (`hfa`): a vector of them is built lane by lane and taken apart again.
    const fn in_regs(self: &Self, b: &Body, v: Value) bool {
        if !self.hfa || (v & VPARAM) == 0 || v == VNONE {
            return false;
        }
        let e = b.blocks[0];
        if (v & ~VPARAM) < e.param_start {
            return false;
        }
        let k = (v & ~VPARAM) - e.param_start;
        let np = b.pool[b.sig as usize];
        if k > np {
            return false;
        }
        let pt = b.pool[(b.sig + if k == np {
            2
        } else {
            3 + k
        }) as usize];
        return (pt & AGG) != 0 && is_float(homogeneous(b, pt & ~AGG, self.ptr));
    }

    // Whether the lanes of splat or gather `pk` are constants.
    const fn consts(self: &Self, b: &Body, pk: Pack) bool {
        for q in 0..pk.n {
            if lane_bits(b, self.lv[(pk.lane + q) as usize]).is_none() {
                return false;
            }
        }
        return true;
    }

    // The block that defines value `v`.
    const fn def_block(self: &Self, v: Value) u32 {
        return if (v & VPARAM) != 0 {
            self.pblk[(v & ~VPARAM) as usize]
        } else {
            self.iblk[v as usize]
        };
    }

    // ---- Emission ----

    // Instruction `t` for block `k`, right before instruction `at` (NONE: at the block's end); `fixed`
    // when it reads vectors. Its value.
    fn make(self: &mut Self, b: &mut Body, t: Inst, k: u32, at: u32, fixed: bool) Value {
        let src = if at == NONE {
            b.blocks[k as usize].start + b.blocks[k as usize].len - 1
        } else {
            at
        };
        let v = b.push_at(t, src);
        if at == NONE {
            self.tail.push(k as u64 << 32 | v as u64);
        } else {
            self.pre.push(at as u64 << 32 | v as u64);
        }
        self.blk.push(k);
        self.fixed.push(fixed);
        return v;
    }

    // Where an instruction right after value `v`'s definition goes: its block, and the instruction it
    // runs before (NONE: the block's end).
    const fn after(self: &Self, b: &Body, v: Value) (u32, u32) {
        let k = self.def_block(v);
        let bk = b.blocks[k as usize];
        let next = if (v & VPARAM) != 0 {
            bk.start
        } else {
            v + 1
        };
        if next == bk.start + bk.len - 1 {
            return (k, NONE);
        }
        return (k, next);
    }

    // PK_PARAM pack `p`: its first lane's parameter becomes the vector, the lanes come out of it through
    // memory at the block's start.
    fn param(self: &mut Self, b: &mut Body, p: u32) {
        let pk = self.packs[p as usize];
        let v = self.lv[pk.lane as usize];
        b.params[(v & ~VPARAM) as usize] = vec_type(pk.ty, pk.n);
        self.packs.index_mut(p as usize).vec = v;
        let (k, at) = self.after(b, v);
        let size = type_bytes(pk.ty, self.ptr);
        let sa = self.slot(b, k, at, pk.n * size);
        let _ = self.make(b, Inst { op: O_STORE, ty: T_NONE, aux: 4, a: sa, b: v, c: 0 }, k, at, true);
        for q in 0..pk.n {
            let x = self.lv[(pk.lane + q) as usize];
            self.extr[(x & ~VPARAM) as usize] = self.make(
                b,
                Inst { op: O_LOAD, ty: pk.ty, aux: size.trailing_zeros() as u16, a: sa, b: VNONE, c: q * size },
                k,
                at,
                false,
            );
        }
    }

    // A new vector slot of `n` bytes' address, in block `k` right before `at`.
    fn slot(self: &mut Self, b: &mut Body, k: u32, at: u32, n: u32) Value {
        let s = b.slot(n, 4);
        return self.make(b, Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: 0, c: 0 }, k, at, false);
    }

    // The vector of term pack `p` of the sum whose root is `r`, of block `k` (`reds`): a load whose lanes the
    // sum alone reads is made right before the root, where its add reads it, when nothing from its first
    // lane to the root writes memory: one term's vector lives at a time, not every one. Else `vector`.
    fn term(self: &mut Self, b: &mut Body, p: u32, k: u32, r: u32) Value {
        let pk = self.packs[p as usize];
        if pk.vec != VNONE || pk.kind != PK_LOAD {
            return self.vector(b, p);
        }
        let l0 = self.lv[pk.lane as usize];
        let mut first = l0;
        let mut ok = true;
        for q in 0..pk.n {
            let l = self.lv[(pk.lane + q) as usize];
            first = first.min(l);
            ok = ok && self.iblk[l as usize] == k && self.uses[l as usize] == 1;
        }
        for i in first..r {
            ok = ok && !writes_memory(b.insts[i as usize]);
        }
        if !ok {
            return self.vector(b, p);
        }
        let mut t = b.insts[l0 as usize];
        let (root, off) = address(b, t);
        t.ty = vec_type(pk.ty, pk.n);
        t.a = root;
        t.c = off as u32;
        let v = self.make(b, t, k, r, false);
        self.packs.index_mut(p as usize).vec = v;
        return v;
    }

    // Pack `p`'s vector, made on first use.
    fn vector(self: &mut Self, b: &mut Body, p: u32) Value {
        let pk = self.packs[p as usize];
        if pk.vec != VNONE {
            return pk.vec;
        }
        let vt = vec_type(pk.ty, pk.n);
        let l0 = self.lv[pk.lane as usize];
        let mut v = VNONE;
        if pk.kind == PK_OP {
            let va = self.vector(b, pk.a);
            let vb = if pk.b == NONE {
                VNONE
            } else {
                self.vector(b, pk.b)
            };
            let mut last = pk.tpl;
            for q in 0..pk.n {
                let l = self.lv[(pk.lane + q) as usize];
                if (l & VPARAM) == 0 && self.iown[l as usize] == p {
                    last = last.max(l);
                }
            }
            let mut t = b.insts[pk.tpl as usize];
            t.ty = vt;
            t.a = va;
            if pk.b != NONE {
                t.b = vb;
            }
            v = self.make(b, t, self.iblk[last as usize], last, true);
        } else if pk.kind == PK_PERM {
            // At the user, of the source's vector: a `swizzle` of lane k from lane k ^ s; a rotation, a
            // `shuffle` of the vector with itself from lane r on (`lv::lane_slide`); its low or high half's
            // lanes twice each, the vector interleaved with itself.
            let va = self.vector(b, pk.a);
            if pk.b >= 2 * pk.n {
                let op = ast::pick(pk.b == 2 * pk.n, O_VZIPLO, O_VZIPHI);
                v = self.make(b, Inst { op: op, ty: vt, aux: 0, a: va, b: va, c: 0 }, pk.blk, pk.at, true);
                self.packs.index_mut(p as usize).vec = v;
                return v;
            }
            let ix = b.pool.len() as u32;
            b.pool.push(pk.n);
            let rot = pk.b >= pk.n;
            for q in 0..pk.n {
                b.pool.push(
                    if rot {
                        pk.b - pk.n + q
                    } else {
                        q ^ pk.b
                    },
                );
            }
            let two = [va, va];
            let ap = b.pool_list(two[0..1 + rot as usize]);
            let code = (core::OP_SIMD + ast::pick(rot, core::SIMD_SHUFFLE, core::SIMD_SWIZZLE) as u32) as u16;
            v = self.make(
                b,
                Inst { op: O_VOP, ty: vt, aux: code, a: ap, b: 1 + rot as u32, c: ix },
                pk.blk,
                pk.at,
                true,
            );
        } else if pk.kind == PK_LOAD {
            let mut first = l0;
            for q in 1..pk.n {
                first = first.min(self.lv[(pk.lane + q) as usize]);
            }
            let mut t = b.insts[l0 as usize];
            let (root, off) = address(b, t);
            t.ty = vt;
            t.a = root;
            t.c = off as u32;
            v = self.make(b, t, self.iblk[first as usize], first, false);
        } else {
            // A splat (`splat`) right after its value's definition (out of the loops that do not define
            // it); a gather through memory at its user.
            let mut k = pk.blk;
            let mut at = pk.at;
            if pk.kind == PK_SPLAT {
                let (sk, sat) = self.after(b, l0);
                k = sk;
                at = sat;
            }
            if self.consts(b, pk) {
                v = self.wide(b, pk, vt, k, at);
            } else if pk.kind == PK_SPLAT {
                v = self.make(b, Inst { op: O_SPLAT, ty: vt, aux: 0, a: l0, b: VNONE, c: VNONE }, k, at, false);
            } else {
                let size = type_bytes(pk.ty, self.ptr);
                let sa = self.slot(b, k, at, pk.n * size);
                for q in 0..pk.n {
                    let mut x = self.lv[(pk.lane + q) as usize];
                    if x == VNONE {
                        x = self.make(b, Inst { op: O_ICONST, ty: pk.ty, aux: 0, a: 0, b: 0, c: VNONE }, k, at, false);
                    }
                    let _ = self.make(
                        b,
                        Inst { op: O_STORE, ty: T_NONE, aux: size.trailing_zeros() as u16, a: sa, b: x, c: q * size },
                        k,
                        at,
                        false,
                    );
                }
                v = self.make(b, Inst { op: O_LOAD, ty: vt, aux: 4, a: sa, b: VNONE, c: 0 }, k, at, false);
            }
        }
        self.packs.index_mut(p as usize).vec = v;
        return v;
    }

    // The constant lanes of pack `pk` as a wide constant of vector type `vt`, in block `k` before `at`.
    fn wide(self: &mut Self, b: &mut Body, pk: Pack, vt: u8, k: u32, at: u32) Value {
        let lb = type_bits(pk.ty, self.ptr);
        let nw = (pk.n * lb + 63) / 64;
        let w = b.words.len() as u32;
        b.words.resize_default(b.words.len() + nw as usize);
        for q in 0..pk.n {
            let mut x = lane_bits(b, self.lv[(pk.lane + q) as usize]).unwrap();
            if lb < 64 {
                x &= (1u64 << lb as u64) - 1;
            }
            let bit = (q * lb) as u64;
            let i = (w as u64 + bit / 64) as usize;
            b.words[i] = b.words[i] | x << bit % 64;
        }
        return self.make(b, Inst { op: O_WCONST, ty: vt, aux: 0, a: w, b: nw, c: VNONE }, k, at, false);
    }

    // The scalar uses of the vector parameters' lanes, in the instructions before `ni` and those made
    // that read no vector, read the lanes out of the vectors; an edge's argument for a vector parameter
    // stays.
    fn remap(self: &mut Self, b: &mut Body, ni: usize) {
        let n = b.insts.len();
        for i in 0..n {
            if i >= ni && self.fixed[i - ni] {
                continue;
            }
            let mut t = b.insts[i];
            let f = op_info(t.op).form;
            if lv::operand_a(f) {
                t.a = self.lane_of(t.a);
            }
            if lv::operand_b(f) {
                t.b = self.lane_of(t.b);
            }
            if lv::operand_c(f) {
                t.c = self.lane_of(t.c);
            }
            b.insts[i] = t;
            if f == F_CALL || f == F_CALLIND {
                for q in 0..t.aux as u32 {
                    b.pool[(t.c + q) as usize] = self.lane_of(b.pool[(t.c + q) as usize]);
                }
            } else if f == F_VOP || f == F_ASM {
                for q in 0..t.b {
                    b.pool[(t.a + q) as usize] = self.lane_of(b.pool[(t.a + q) as usize]);
                }
            } else if f == F_JMP || f == F_BR || f == F_SWITCH {
                b.succ_edges(t, &mut self.edges);
                for x in 0..self.edges.len() {
                    let e = self.edges[x];
                    let tb = b.blocks[b.edge_target(e) as usize];
                    for q in 0..b.edge_nargs(e) {
                        let p = tb.param_start + q;
                        let o = self.pown[p as usize];
                        if o == NONE || self.lv[self.packs[o as usize].lane as usize] != (VPARAM | p) {
                            b.pool[(e + 2 + q) as usize] = self.lane_of(b.edge_arg(e, q));
                        }
                    }
                }
            }
        }
    }

    // Value `v`, or its lane out of a vector parameter.
    const fn lane_of(self: &Self, v: Value) Value {
        if v == VNONE || (v & VPARAM) == 0 || (v & VFLAG) != 0 || self.extr[(v & ~VPARAM) as usize] == VNONE {
            return v;
        }
        return self.extr[(v & ~VPARAM) as usize];
    }
}

// The lane count of a vector of scalar type `ty`: 0 when it packs none (lanes of 4 bytes and more).
// The lanes a pack of `got` values of `size` bytes takes, at most `n`: the widest power of two of 16 bytes
// or more it fills, 0 when none.
const fn fit(got: u32, n: u32, size: u32) u32 {
    let mut m = n;
    // Each step halves `m`: at most 3 steps from 64 bytes.
    while m > got && m * size > VBYTES {
        m = m / 2;
    }
    return ast::pick(m <= got && m * size >= VBYTES, m, 0u32);
}

// The lane of the source PK_PERM lane `k` of `n` takes: `k ^ s` for `s` below `n`; `k` rotated by `s - n`
// below `2 * n`; lane `k / 2` of the low half (`2 * n`) or of the high half (`2 * n + 1`).
const fn perm_lane(n: u32, s: u32, k: u32) u32 {
    return if s < n {
        k ^ s
    } else if s < 2 * n {
        (k + s - n) % n
    } else {
        (s - 2 * n) * n / 2 + k / 2
    };
}

// The lane `perm_lane(n, s, ..)` maps to `j`: the inverse.
const fn perm_back(n: u32, s: u32, j: u32) u32 {
    return if s < n {
        j ^ s
    } else {
        (j + 2 * n - s) % n
    };
}

// Whether a vector of `n` lanes of `eb` bytes moves its lanes in registers as lane k from lane
// `perm_lane(n, s, k)` does: of 16 bytes, the lanes reversed within each 8 bytes, the 8-byte halves
// swapped, or both (`lv::lane_perm`), or a half's lanes twice each (`O_VZIPLO`, `O_VZIPHI`); of 8, 16 or
// 32 bytes, rotated (`lv::lane_slide`).
const fn perm_ok(n: u32, eb: u32, s: u32) bool {
    if s >= n && s < 2 * n {
        return s != n && (n * eb == 8 || n * eb == 16 || n * eb == 32);
    }
    if s == 2 * n || s == 2 * n + 1 {
        return n * eb == 16;
    }
    if n * eb != 16 || s == 0 || s >= n {
        return false;
    }
    let m = 8 / eb;
    let rev = m > 1 && (s & m - 1) == m - 1;
    let swap = (s & ~(m - 1)) == n - m;
    return (rev || swap) && s == (rev as u32 * (m - 1) | swap as u32 * (n - m));
}

// The instructions PK_PERM pack `pk` moves its lanes with: one per step (`perm_ok`).
const fn perm_cost(pk: Pack) u64 {
    if pk.b >= pk.n {
        return 1;
    }
    let m = 8 / (16 / pk.n);
    return ((pk.b & m - 1) != 0) as u64 + ((pk.b & ~(m - 1)) != 0) as u64;
}

const fn unary(op: u8) bool {
    return op == O_NEG || op == O_NOT || op == O_FNEG || op == O_FSQRT;
}

// Whether `v` is a load of type `ty` that is not volatile.
const fn plain_load(b: &Body, v: Value, ty: u8) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    return t.op == O_LOAD && t.ty == ty && (t.aux & MEM_VOLATILE) == 0;
}

// The bits of a lane `v` of a splat or gather: 0 for VNONE (an identity lane's second operand), else a
// constant's (`const_bits`).
const fn lane_bits(b: &Body, v: Value) Option<u64> {
    return if v == VNONE {
        Some(0u64)
    } else {
        const_bits(b, v)
    };
}

// The bytes load or store `t` accesses.
const fn access_bytes(b: &Body, t: Inst, ptr: u32) i64 {
    return type_bytes(
        if t.op == O_LOAD {
            t.ty
        } else {
            b.type_of(t.b)
        },
        ptr,
    );
}

// Whether `t` may read or write memory.
const fn touches(t: Inst) bool {
    return t.op == O_LOAD || writes_memory(t);
}
