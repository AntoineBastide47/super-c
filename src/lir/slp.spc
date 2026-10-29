// Superword-level parallelism (Larsen and Amarasinghe, PLDI 2000), bottom-up from seeds as LLVM's SLP
// vectorizer: a pack of N isomorphic scalar values, one per lane of a 16-byte vector, becomes one vector
// value. The seeds: N stores to consecutive addresses with nothing that touches memory between them,
// and N parameters of a block whose arguments on one edge are loads from consecutive addresses (a loop's
// carried values: the vector stays in a register across the back edge). The lanes of a pack's operand
// form a pack in turn: N instructions of one operation in one block, N loads from consecutive addresses
// with no write between them (one vector load), N parameters of one block other than the entry (one
// vector parameter; each edge into the block passes the pack of its arguments), one value (a splat) or
// any values (a gather through memory). A value a pack holds in another arrangement is gathered. The
// scalar instructions stay for the uses outside the packs, and go where none is left; a vector
// parameter's lanes come out through memory at its block's start for the scalar uses. `lir::opt` keeps
// the result when it lowers the instruction count weighted by loop depth.
import lir::ir as *;
import lir::verify as lv;

// The bytes of a vector.
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

struct Pack {
    pub kind: u8,
    pub ty: u8, // the lanes' type
    pub n: u32, // the lane count
    pub lane: u32, // its lanes: `lv[lane .. lane + n]`
    pub a: u32, // PK_OP: the operand packs (`b` NONE for a unary operation)
    pub b: u32,
    pub blk: u32, // PK_GATHER: the block it runs in, right before instruction `at` (NONE: at its end)
    pub at: u32,
    pub vec: Value, // its vector once made (VNONE: not yet)
}

extend Pack as Copy {}

/// The SLP's scratch, reused from body to body.
pub struct Slp {
    ptr: u32,
    packs: Vector<Pack>,
    lv: Vector<Value>,
    // The lanes `build` takes, a stack: each call's from its `at` on.
    tmp: Vector<Value>,
    iown: Vector<u32>, // per instruction, its PK_OP or PK_LOAD pack (NONE: none)
    pown: Vector<u32>, // per block parameter, its PK_PARAM pack (NONE: none)
    iblk: Vector<u32>, // per instruction, its block
    pblk: Vector<u32>, // per block parameter, its block
    // The edges into block `k`: `ins[in_at[k] .. in_at[k + 1]]`, from blocks `insrc[..]`.
    in_at: Vector<u32>,
    ins: Vector<u32>,
    insrc: Vector<u32>,
    cur: Vector<u32>,
    eargs: Vector<(u32, u32, u32)>, // (PK_PARAM pack, an edge into its block, the pack of its arguments)
    stores: Vector<u32>, // the seeds' stores, by group
    groups: Vector<(u32, u32)>, // per store seed: its first `stores` index, the pack of its values
    sclaim: Vector<bool>, // per instruction, whether a store seed holds it
    extr: Vector<Value>, // per block parameter of a PK_PARAM pack, its lane out of the vector
    edges: Vector<u32>,
    fixed: Vector<bool>, // per instruction made, whether it reads vectors (no lane's scalar)
    /// Instruction << 32 | an instruction made to run right before it, in order.
    pub pre: Vector<u64>,
    /// Block << 32 | an instruction made to run at its end before its terminator, in order.
    pub tail: Vector<u64>,
    /// Per instruction made, its block.
    pub blk: Vector<u32>,
}

extend Slp {
    pub fn new() Slp {
        return Slp {
            ptr: 8,
            packs: Vector::<Pack>::new(),
            lv: Vector::<Value>::new(),
            tmp: Vector::<Value>::new(),
            iown: Vector::<u32>::new(),
            pown: Vector::<u32>::new(),
            iblk: Vector::<u32>::new(),
            pblk: Vector::<u32>::new(),
            in_at: Vector::<u32>::new(),
            ins: Vector::<u32>::new(),
            insrc: Vector::<u32>::new(),
            cur: Vector::<u32>::new(),
            eargs: Vector::<(u32, u32, u32)>::new(),
            stores: Vector::<u32>::new(),
            groups: Vector::<(u32, u32)>::new(),
            sclaim: Vector::<bool>::new(),
            extr: Vector::<Value>::new(),
            edges: Vector::<u32>::new(),
            fixed: Vector::<bool>::new(),
            pre: Vector::<u64>::new(),
            tail: Vector::<u64>::new(),
            blk: Vector::<u32>::new(),
        };
    }

    /// The packs of body `b` (`ptr` its pointer size, `w` per block the weight of an instruction there):
    /// whether the instructions they save outweigh the splats and gathers they add. `b` stays as it is.
    pub fn plan(self: &mut Self, b: &Body, ptr: u32, w: []u64) bool {
        self.ptr = ptr;
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
        fill(&mut self.iblk, ni, NONE);
        fill(&mut self.pblk, np, NONE);
        fill_bool(&mut self.sclaim, ni, false);
        for k in 0..nb {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.iblk[i as usize] = k as u32;
            }
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                self.pblk[q as usize] = k as u32;
            }
        }
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
        for k in 1..nb {
            self.edge_seeds(b, k as u32);
        }
        for k in 0..nb {
            self.store_seeds(b, k as u32);
        }
        // The estimate: what the packs and the seeds' stores save, less what the splats and gathers add.
        let mut gain: u64 = 0;
        let mut cost: u64 = 0;
        for p in 0..self.packs.len() {
            let pk = self.packs[p];
            let l0 = self.lv[pk.lane as usize];
            if pk.kind == PK_OP || pk.kind == PK_LOAD {
                gain += (pk.n - 1) as u64 * w[self.iblk[l0 as usize] as usize];
            } else if pk.kind == PK_SPLAT || pk.kind == PK_GATHER {
                let k = if pk.kind == PK_GATHER {
                    pk.blk;
                } else {
                    self.def_block(l0);
                };
                cost += if self.consts(b, pk) || pk.kind == PK_SPLAT {
                    1u64;
                } else {
                    pk.n as u64 + 1 + GATHER_COST;
                } * w[k as usize];
            }
        }
        for g in 0..self.groups.len() {
            let (s0, vp) = self.groups[g];
            gain += (self.packs[vp as usize].n - 1) as u64 * w[self.iblk[self.stores[s0 as usize] as usize] as usize];
        }
        return gain > cost;
    }

    /// Make the planned packs' vectors in `b`: the instructions made follow `b`'s, placed by `pre`, `tail`
    /// and `blk`; a seed's stores become one, the vector parameters' scalar uses read their lanes.
    pub fn emit(self: &mut Self, b: &mut Body) {
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
        for p in 0..self.packs.len() {
            let _ = self.vector(b, p as u32);
        }
        for x in 0..self.eargs.len() {
            let (pp, e, ap) = self.eargs[x];
            let v = self.vector(b, ap);
            let p0 = self.lv[self.packs[pp as usize].lane as usize] & ~VPARAM;
            let q0 = p0 - b.blocks[self.pblk[p0 as usize] as usize].param_start;
            b.pool[(e + 2 + q0) as usize] = v;
        }
        for g in 0..self.groups.len() {
            let (s0, vp) = self.groups[g];
            let n = self.packs[vp as usize].n;
            let first = self.stores[s0 as usize];
            let last = self.stores[(s0 + n - 1) as usize];
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

    // ---- Seeds ----

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
                let n = lane_count(ty);
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
                if got == n {
                    let _ = self.build(b, at as u32, n, ty, NONE, NONE, 0);
                }
                self.tmp.truncate(at);
            }
        }
    }

    // The stores of block `k` to consecutive addresses, nothing between them touching memory, whose
    // values pack into instructions, loads or parameters.
    fn store_seeds(self: &mut Self, b: &Body, k: u32) {
        let bk = b.blocks[k as usize];
        let end = bk.start + bk.len - 1;
        for i in bk.start..end {
            let t = b.insts[i as usize];
            if t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || self.sclaim[i as usize] {
                continue;
            }
            let ty = b.type_of(t.b);
            let n = lane_count(ty);
            if n == 0 {
                continue;
            }
            let (root, off) = address(b, t);
            let size = type_bytes(ty, self.ptr) as i64;
            // The values on the lane stack, the stores past the seeds' (`stores`) until it is one.
            let at = self.tmp.len();
            let sat = self.stores.len();
            self.tmp.push(t.b);
            self.stores.push(i);
            let mut got: u32 = 1;
            let mut j = i + 1;
            while j < end && j - i <= SPAN_MAX && got < n {
                let u = b.insts[j as usize];
                let mut lane = false;
                if u.op == O_STORE && (u.aux & MEM_VOLATILE) == 0 && !self.sclaim[j as usize] && b.type_of(u.b) == ty {
                    let (r2, o2) = address(b, u);
                    lane = r2 == root && o2 == off + got as i64 * size;
                }
                if lane {
                    self.tmp.push(u.b);
                    self.stores.push(j);
                    got += 1;
                } else if touches(u) {
                    break;
                }
                j += 1;
            }
            let vp = if got == n {
                self.build(b, at as u32, n, ty, k, self.stores[sat + n as usize - 1], 0);
            } else {
                NONE;
            };
            self.tmp.truncate(at);
            if vp == NONE || self.packs[vp as usize].kind == PK_SPLAT || self.packs[vp as usize].kind == PK_GATHER {
                self.stores.truncate(sat);
                continue;
            }
            self.groups.push((sat as u32, vp));
            for q in sat..self.stores.len() {
                self.sclaim[self.stores[q] as usize] = true;
            }
        }
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
            return if self.same_lanes(o, at, n) {
                o;
            } else {
                self.add(PK_GATHER, ty, at, n, ublk, uat);
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
            }
            return p;
        }
        let kind = self.isomorphic(b, at, n, ty);
        if kind == 0 {
            return self.add(PK_GATHER, ty, at, n, ublk, uat);
        }
        let p = self.add(kind, ty, at, n, NONE, NONE);
        let mut last = l0;
        for q in 0..n {
            let v = self.tmp[(at + q) as usize];
            self.iown[v as usize] = p;
            last = last.max(v);
        }
        if kind == PK_LOAD {
            return p;
        }
        // The operands' packs, for the vector instruction right before the last lane.
        for q in 0..n {
            self.tmp.push(b.insts[self.tmp[(at + q) as usize] as usize].a);
        }
        let pa = self.build(b, top as u32, n, ty, self.iblk[last as usize], last, depth + 1);
        self.tmp.truncate(top);
        self.packs.index_mut(p as usize).a = pa;
        if !unary(b.insts[l0 as usize].op) {
            for q in 0..n {
                self.tmp.push(b.insts[self.tmp[(at + q) as usize] as usize].b);
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
        self.packs.push(Pack { kind: kind, ty: ty, n: n, lane: lane, a: NONE, b: NONE, blk: blk, at: uat, vec: VNONE });
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

    // PK_LOAD when lanes `tmp[at .. at + n]` are loads of type `ty` from consecutive addresses in one block with
    // no write between them; PK_OP when they are distinct instructions of one operation a vector has,
    // flags and type in one block; else 0. No pack holds any.
    fn isomorphic(self: &Self, b: &Body, at: u32, n: u32, ty: u8) u8 {
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
            let flags = if t0.op == O_LOAD {
                0xFFF0u16;
            } else {
                0xFFFFu16;
            };
            if t.op != t0.op || t.ty != ty || (t.aux & flags) != (t0.aux & flags) || self.iblk[v as usize] != self.iblk[l0 as usize] {
                return 0;
            }
        }
        if t0.op == O_LOAD {
            if (t0.aux & MEM_VOLATILE) != 0 || hi - lo > SPAN_MAX {
                return 0;
            }
            let (root, off) = address(b, t0);
            let size = type_bytes(ty, self.ptr) as i64;
            for q in 1..n {
                let (r2, o2) = address(b, b.insts[self.tmp[(at + q) as usize] as usize]);
                if r2 != root || o2 != off + q as i64 * size {
                    return 0;
                }
            }
            for i in lo + 1..hi {
                if writes(b.insts[i as usize]) {
                    return 0;
                }
            }
            return PK_LOAD;
        }
        let op = t0.op;
        let int_op = op == O_ADD || op == O_SUB || op == O_AND || op == O_OR || op == O_XOR || op == O_NEG || op == O_NOT || op == O_MUL && type_bytes(
            ty,
            self.ptr,
        ) < 8;
        let float_op = op >= O_FADD && op <= O_FNEG;
        return if is_int(ty) && int_op || is_float(ty) && float_op {
            PK_OP;
        } else {
            0u8;
        };
    }

    // Whether the lanes of splat or gather `pk` are constants.
    const fn consts(self: &Self, b: &Body, pk: Pack) bool {
        for q in 0..pk.n {
            if const_bits(b, self.lv[(pk.lane + q) as usize]).is_none() {
                return false;
            }
        }
        return true;
    }

    // The block that defines value `v`.
    const fn def_block(self: &Self, v: Value) u32 {
        return if (v & VPARAM) != 0 {
            self.pblk[(v & ~VPARAM) as usize];
        } else {
            self.iblk[v as usize];
        };
    }

    // ---- Emission ----

    // Instruction `t` for block `k`, right before instruction `at` (NONE: at the block's end); `fixed`
    // when it reads vectors. Its value.
    fn make(self: &mut Self, b: &mut Body, t: Inst, k: u32, at: u32, fixed: bool) Value {
        let v = b.insts.len() as u32;
        let src = if at == NONE {
            b.blocks[k as usize].start + b.blocks[k as usize].len - 1;
        } else {
            at;
        };
        b.insts.push(t);
        b.locs.push(b.locs[src as usize]);
        if b.inl.len() != 0 {
            b.inl.push(b.inl[src as usize]);
        }
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
            bk.start;
        } else {
            v + 1;
        };
        if next == bk.start + bk.len - 1 {
            return k, NONE;
        }
        return k, next;
    }

    // PK_PARAM pack `p`: its first lane's parameter becomes the vector, the lanes come out of it through
    // memory at the block's start.
    fn param(self: &mut Self, b: &mut Body, p: u32) {
        let pk = self.packs[p as usize];
        let v = self.lv[pk.lane as usize];
        b.params[(v & ~VPARAM) as usize] = vec_type(pk.ty, pk.n);
        self.packs.index_mut(p as usize).vec = v;
        let (k, at) = self.after(b, v);
        let sa = self.slot(b, k, at);
        let _ = self.make(b, Inst { op: O_STORE, ty: T_NONE, aux: 4, a: sa, b: v, c: 0 }, k, at, true);
        let size = type_bytes(pk.ty, self.ptr);
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

    // A new vector slot's address, in block `k` right before `at`.
    fn slot(self: &mut Self, b: &mut Body, k: u32, at: u32) Value {
        let s = b.slot(VBYTES, 4);
        return self.make(b, Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: 0, c: 0 }, k, at, false);
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
                VNONE;
            } else {
                self.vector(b, pk.b);
            };
            let mut last = l0;
            for q in 1..pk.n {
                last = last.max(self.lv[(pk.lane + q) as usize]);
            }
            let mut t = b.insts[l0 as usize];
            t.ty = vt;
            t.a = va;
            if pk.b != NONE {
                t.b = vb;
            }
            v = self.make(b, t, self.iblk[last as usize], last, true);
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
                let sa = self.slot(b, k, at);
                let size = type_bytes(pk.ty, self.ptr);
                for q in 0..pk.n {
                    let x = self.lv[(pk.lane + q) as usize];
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
        for _ in 0..nw {
            b.words.push(0);
        }
        for q in 0..pk.n {
            let mut x = const_bits(b, self.lv[(pk.lane + q) as usize]).unwrap();
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
const fn lane_count(ty: u8) u32 {
    return if ty == T_I32 || ty == T_F32 {
        4u32;
    } else if ty == T_I64 || ty == T_F64 {
        2u32;
    } else {
        0u32;
    };
}

const fn unary(op: u8) bool {
    return op == O_NEG || op == O_NOT || op == O_FNEG;
}

// Whether `v` is a load of type `ty` that is not volatile.
const fn plain_load(b: &Body, v: Value, ty: u8) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    return t.op == O_LOAD && t.ty == ty && (t.aux & MEM_VOLATILE) == 0;
}

// The address of load or store `t`: a base no constant offset derives from, and the bytes past it.
const fn address(b: &Body, t: Inst) (Value, i64) {
    let mut base = t.a;
    let mut off = (t.c as i32) as i64;
    // Each step leaves one constant offset.
    for _ in 0..8 {
        if base == VNONE || (base & (VPARAM | VFLAG)) != 0 {
            break;
        }
        let x = b.insts[base as usize];
        if x.op != O_PTRADD || x.b != VNONE {
            break;
        }
        off += x.c as i32;
        base = x.a;
    }
    return base, off;
}

// The bits of constant `v` (an integer's or a float's), if it is one.
fn const_bits(b: &Body, v: Value) Option<u64> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST && b.insts[v as usize].op != O_FCONST {
        return Option::<u64>::None;
    }
    let t = b.insts[v as usize];
    return Option::<u64>::Some(t.b as u64 << 32 | t.a as u64);
}

// Whether `t` may read or write memory.
const fn touches(t: Inst) bool {
    return t.op == O_LOAD || writes(t);
}

// Whether `t` may write memory or order memory accesses.
const fn writes(t: Inst) bool {
    let op = t.op;
    return op == O_STORE || op == O_MEMCPY || op == O_MEMSET || op >= O_ALOAD && op <= O_FENCE || op == O_CALL || op == O_CALLIND || op == O_ASM || op == O_SYS || op >= O_VOP && op <= O_VAEND;
}

// The terminator of block `k`.
const fn term(b: &Body, k: u32) Inst {
    let bk = b.blocks[k as usize];
    return b.insts[(bk.start + bk.len - 1) as usize];
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
