// Promotion of private memory to values (scalar replacement and mem2reg), run by `lir::opt` between
// two walks, once inlining has made an iterator's or an `Option`'s slot local and the first walk has
// forwarded the inlined entry's parameters: a slot whose address only feeds loads and stores at
// constant offsets, copies of constant size and fills becomes one value per field (an offset and a
// type no other access overlaps; accesses of one offset whose types convert, an integer and a pointer
// or a float of its size, share a field and convert). Each field's stores define it; a load reads the
// definition that reaches it, a block where definitions merge takes it as a new parameter, which each
// edge into the block passes. The parameters go at the iterated dominance frontier of the stores,
// where the field is live (Cytron et al.'s placement, pruned by liveness, then renaming in one walk of
// the dominator tree); a copy into the slot becomes loads of the source's fields, a copy out of it
// stores of its fields, a copy between two promoted slots nothing. A field read where no store reaches
// reads the zero of its type (the slot's bytes are unspecified there). A load or store of a vector field's
// lane (of its lane type, at a lane's offset) reads it as `vextract` or sets it as `vinsert`. An integer
// load that other accesses overlap spans their fields (LLVM SROA's rewrite of a wide access over several
// partitions): its fields' values combined in their little-endian places, a byte no field holds reading
// 0. An integer load inside a wider integer field reads its bits there (`part_at`). A store of an integer
// constant over narrower fields, each inside it, writes each its bits of the constant, when its bytes no
// field holds are 0 (a spanning load reads them as 0): an `Option`'s `None` as one word over its tag and
// payload. A store of another integer over narrower stores, each inside it, writes each field it holds
// its bits of the value, when no load reads its bytes no field holds: an `Option`'s `Some` written as its
// tag extended to a word, over the `None` tag's byte store. A field across its edge keeps the slot in memory. A wide store stays one: its fields would each take a
// store where a copy reads them, and the walk forwards its bytes to narrower loads.
//
// Before that, a copy between two slots of its size whose source no instruction reads after it and whose
// destination none uses before it (the copy in no cycle, the source's address passed nowhere it may stay
// and the destination's passed somewhere, else promotion takes it) merges the two slots: the
// destination's addresses name the source, and the copy goes (LLVM's memcpy optimization forwards
// copies the same way). A call writing its aggregate result into the source is a use, not an escape. A
// copy the inliner left between a callee's slot and its caller's is the common case.
//
// The body is rebuilt in the same block order with its instructions renumbered; the optimizer's walk
// then forwards the parameters and drops the address arithmetic nothing uses.
import lir::ir as *;
import lir::verify as lv;

// A slot with more fields than this, or a body whose fields times blocks pass PROMOTE_WORK_MAX, keeps
// its memory: the placement is linear in the blocks per field.
const FIELDS_MAX: u32 = 64;
// `bound_after` looks at most this many instructions past a copy.
const AFTER_MAX: u32 = 16;
// The copies a body tries to merge at most (`Promoter::merges`: one walk of its blocks each).
const MERGE_TRIES: u32 = 256;
const PROMOTE_WORK_MAX: u64 = 1 << 22;

// An access of a slot: bytes `off` to `off + size` as `ty` (T_NONE: a copied range of no type).
struct Acc {
    pub(package) slot: u32,
    pub(package) off: i64,
    pub(package) size: i64,
    pub(package) ty: u8,
    pub(package) kind: u8, // W_LOAD: an integer load that may span fields or read part of one (`wide_kind`);
    // W_CSTORE: a store of an integer constant, which may span fields; W_VSTORE: one of another integer,
    // which may span narrower stores
}

extend Acc as Copy {}

// A copy (`memcpy`) or a fill (`memset`, `src` NONE and `byte` its byte) of `size` bytes with a slot on
// one side at least: the destination's and the source's slot (NONE: none) and offsets.
struct Copy {
    pub(package) inst: u32,
    pub(package) dslot: u32,
    pub(package) doff: i64,
    pub(package) sslot: u32,
    pub(package) soff: i64,
    pub(package) size: i64,
    pub(package) byte: u64,
}

extend Copy as Copy {}

// A field: a slot's bytes `off` to `off + type_bytes(ty)`. In `build_fields`' scratch, an access, with its
// `Acc.kind` and W_SPANS when it overlaps another access it is not the same field as.
struct Fld {
    pub(package) off: i64,
    pub(package) ty: u8,
    pub(package) w: u8,
}

// `Acc.kind` and `Fld.w`: an integer load; one that spans other fields; a store of an integer constant;
// a store of another integer.
const W_LOAD: u8 = 1;
const W_SPANS: u8 = 2;
const W_CSTORE: u8 = 4;
const W_VSTORE: u8 = 8;

extend Fld as Copy {}

/// The promotion's scratch, reused from body to body.
pub(package) struct Promoter {
    ptr: u32, // the data model's pointer size
    dslot: Vector<u32>, // per instruction, the slot its address value points into (NONE: none)
    doff: Vector<i64>, // and the offset
    cand: Vector<bool>, // per slot, whether it promotes
    accs: Vector<Acc>,
    copies: Vector<Copy>,
    // The fields: slot `s` has `flds[fat[s] .. fat[s + 1]]`, by offset.
    flds: Vector<Fld>,
    fat: Vector<u32>,
    tmp: Vector<Fld>,
    gap: Vector<Fld>, // `fill_gaps`'s fields
    reached: Vector<bool>, // per block, whether the entry reaches it
    zeros: Vector<u32>, // per machine type, its zero (`zero`; NONE: none yet)
    // The merges of copies (`merges`): their own slot tables, `collect`'s kept.
    rslot: Vector<u32>,
    mdslot: Vector<u32>,
    mdoff: Vector<i64>,
    iblk: Vector<u32>,
    muse: Vector<u64>,
    mat: Vector<u32>,
    mesc: Vector<bool>,
    mslot: Vector<u32>,
    cdrop: Vector<bool>,
    busy: Vector<bool>,
    typed: Vector<bool>, // `fields`' scratch: per slot, whether an access gives it a type
    pcand: Vector<bool>, // per slot, whether it promotes as the body stands, before any merge
    reach: Vector<u32>,
    xwords: Vector<u64>, // the words of the zeros of wide types
    // Per instruction: the field a promoted load reads or a promoted store writes (NONE: none), the lane
    // of a vector field it accesses (NONE: the whole field), and what replaced a promoted load.
    fid: Vector<u32>,
    lane: Vector<u32>,
    spanned: Vector<bool>, // per instruction, whether it is a load that spans fields (`spans`)
    part: Vector<u32>, // per instruction, a load's byte offset in the wider field it reads part of (`part_at`)
    repl: Vector<u32>,
    drop: Vector<bool>,
    // The dominance frontiers: block `k`'s are `df[df_at[k] .. df_at[k + 1]]`.
    df_at: Vector<u32>,
    df: Vector<u32>,
    pairs: Vector<u64>,
    mark: Vector<u32>,
    // Per field: the blocks that define it and the blocks that read it before any definition.
    dblk: Vector<u64>, // field << 32 | block
    ublk: Vector<u64>,
    livein: Vector<u32>, // per block, the field it is live into (NONE: none)
    hasphi: Vector<u32>, // per block, the field it has a parameter of
    isdef: Vector<u32>,
    work: Vector<u32>,
    // The new parameters: block << 32 | field, in block order after the sort; per block the range.
    phis: Vector<u64>,
    phi_at: Vector<u32>,
    // The renaming: per field its current value, the log that restores it, the edge arguments.
    cur: Vector<u32>,
    log: Vector<u64>,
    stack: Vector<u64>,
    eargs: Map<u64, u32>, // block << 32 | an edge's pool index, to its first new argument in `evals`
    evals: Vector<u32>,
    // New instructions: each placed before instruction `at`.
    xins: Vector<(u32, Inst)>,
    xat: Vector<u32>, // per instruction, the range of `xins` before it (by `xorder`)
    xorder: Vector<u32>,
    // The emission.
    cmap: Vector<u32>,
    pmap: Vector<u32>,
    done: Vector<bool>,
    edges: Vector<u32>,
}

extend Promoter {
    pub(package) fn new() Promoter {
        return Promoter {
            dslot: Vector::<u32>::new(),
            doff: Vector::<i64>::new(),
            cand: Vector::<bool>::new(),
            accs: Vector::<Acc>::new(),
            copies: Vector::<Copy>::new(),
            flds: Vector::<Fld>::new(),
            fat: Vector::<u32>::new(),
            tmp: Vector::<Fld>::new(),
            gap: Vector::<Fld>::new(),
            reached: Vector::<bool>::new(),
            zeros: Vector::<u32>::new(),
            ptr: 8,
            rslot: Vector::<u32>::new(),
            mdslot: Vector::<u32>::new(),
            mdoff: Vector::<i64>::new(),
            iblk: Vector::<u32>::new(),
            muse: Vector::<u64>::new(),
            mat: Vector::<u32>::new(),
            mesc: Vector::<bool>::new(),
            mslot: Vector::<u32>::new(),
            cdrop: Vector::<bool>::new(),
            busy: Vector::<bool>::new(),
            typed: Vector::<bool>::new(),
            pcand: Vector::<bool>::new(),
            reach: Vector::<u32>::new(),
            xwords: Vector::<u64>::new(),
            fid: Vector::<u32>::new(),
            lane: Vector::<u32>::new(),
            spanned: Vector::<bool>::new(),
            part: Vector::<u32>::new(),
            repl: Vector::<u32>::new(),
            drop: Vector::<bool>::new(),
            df_at: Vector::<u32>::new(),
            df: Vector::<u32>::new(),
            pairs: Vector::<u64>::new(),
            mark: Vector::<u32>::new(),
            dblk: Vector::<u64>::new(),
            ublk: Vector::<u64>::new(),
            livein: Vector::<u32>::new(),
            hasphi: Vector::<u32>::new(),
            isdef: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            phis: Vector::<u64>::new(),
            phi_at: Vector::<u32>::new(),
            cur: Vector::<u32>::new(),
            log: Vector::<u64>::new(),
            stack: Vector::<u64>::new(),
            eargs: Map::<u64, u32>::new(),
            evals: Vector::<u32>::new(),
            xins: Vector::<(u32, Inst)>::new(),
            xat: Vector::<u32>::new(),
            xorder: Vector::<u32>::new(),
            cmap: Vector::<u32>::new(),
            pmap: Vector::<u32>::new(),
            done: Vector::<bool>::new(),
            edges: Vector::<u32>::new(),
        };
    }

    /// Promote the private slots of `b`, whose graph is given: successors and predecessors as ranges,
    /// immediate dominators (NONE: unreached), the reverse postorder, the dominator tree's children as
    /// ranges, each instruction's block (NONE: none), each instruction's operands then its edges'
    /// arguments (`ops[ops_at[i]..ops_at[i + 1]]`, the arguments from `ops_arg[i]`). The new body goes to
    /// `out`; false when no slot promotes (`out` untouched).
    pub(package) fn run(
        self: &mut Self,
        b: &Body,
        succ_at: []u32,
        succs: []u32,
        pred_at: []u32,
        preds: []u32,
        idom: []u32,
        order: []u32,
        kid_at: []u32,
        kids: []u32,
        blk: []u32,
        ops_at: []u32,
        ops_arg: []u32,
        ops: []Value,
        ptr: u32,
        out: &mut Body,
    ) bool {
        self.ptr = ptr;
        let ns = b.slots.len();
        if ns == 0 || b.naked {
            return false;
        }
        self.reached.truncate(0);
        for k in 0..b.blocks.len() {
            self.reached.push(idom[k] != NONE);
        }
        fill(&mut self.busy, ns, false);
        let any = self.collect(b, idom, ops_at, ops);
        self.pcand.truncate(0);
        for s in 0..ns {
            self.pcand.push(self.cand[s]);
        }
        // A merge makes its two slots `busy`: they leave the candidates `collect` found, its accesses and
        // copies stay.
        let merged = self.merges(b, succ_at, succs, blk, ops_at, ops_arg, ops);
        let mut left = any && !merged;
        if merged {
            for s in 0..ns {
                self.cand[s] = self.pcand[s] && !self.busy[s];
                left = left || self.cand[s];
            }
        }
        if !left {
            if !merged {
                return false;
            }
            self.plain(b);
            self.emit(b, out);
            return true;
        }
        self.frontiers(b, pred_at, preds, idom, order);
        // Each round drops at least one slot, or ends.
        for _ in 0..ns + 1 {
            if !self.fields(b) {
                return false;
            }
            let nf = self.flds.len() as u64;
            if nf * b.blocks.len() as u64 > PROMOTE_WORK_MAX {
                return false;
            }
            self.place(b, pred_at, preds, idom);
            let bad = self.rename(b, kid_at, kids);
            if bad != NONE {
                self.cand[bad as usize] = false;
                continue;
            }
            self.emit(b, out);
            return true;
        }
        if merged {
            self.plain(b);
            self.emit(b, out);
            return true;
        }
        return false;
    }

    // The emission's state for the copies merged alone: no field, no new parameter or instruction.
    fn plain(self: &mut Self, b: &Body) {
        self.flds.truncate(0);
        self.phis.truncate(0);
        fill(&mut self.phi_at, b.blocks.len() + 1, 0);
        fill(&mut self.repl, b.insts.len(), NONE);
        fill(&mut self.drop, b.insts.len(), false);
        self.xins.truncate(0);
        self.xwords.truncate(0);
        self.eargs.clear();
        self.evals.truncate(0);
        for i in 0..b.insts.len() {
            self.drop[i] = self.cdrop[i];
        }
    }

    // ---- Copies between slots ------------------------------------------------------------------------

    // Merge the slots of each copy between two slots of its size whose source no instruction reads after
    // it and whose destination none uses before it (`mslot`: per slot, the slot it merges into; `cdrop`:
    // the copies that go). A slot takes part in one merge at most. Whether any merged.
    fn merges(
        self: &mut Self,
        b: &Body,
        succ_at: []u32,
        succs: []u32,
        blk: []u32,
        ops_at: []u32,
        ops_arg: []u32,
        ops: []Value,
    ) bool {
        let ni = b.insts.len();
        let ns = b.slots.len();
        let nb = b.blocks.len();
        fill(&mut self.mslot, ns, NONE);
        fill(&mut self.cdrop, ni, false);
        fill(&mut self.busy, ns, false);
        // Per instruction its block (`blk`'s); its slots `collect` derived (`rslot`, `mdslot`, `mdoff`).
        self.iblk.truncate(0);
        self.iblk.extend_from_slice(blk);
        let mut copies: u32 = 0;
        for i in 0..ni {
            copies += (b.insts[i].op == O_MEMCPY && self.iblk[i] != NONE) as u32;
        }
        if copies == 0 {
            return false;
        }
        // Each slot's uses (slot << 32 | instruction), and whether its address may stay somewhere.
        self.muse.truncate(0);
        fill(&mut self.mesc, ns, false);
        for i in 0..ni {
            let t = b.insts[i];
            if self.iblk[i] == NONE || !self.reached[self.iblk[i] as usize] {
                for u in ops_at[i]..ops_arg[i] {
                    self.escape(ops[u as usize], i as u32);
                }
                continue;
            }
            self.note_uses(b, i as u32, t, ops_at, ops_arg, ops);
        }
        self.muse.sort();
        fill(&mut self.mat, ns + 1, 0);
        for q in 0..self.muse.len() {
            self.mat[(self.muse[q] >> 32) as usize + 1] += 1;
        }
        for s in 0..ns {
            self.mat[s + 1] += self.mat[s];
        }
        fill(&mut self.reach, nb, NONE);
        let mut any = false;
        let mut tries: u32 = 0;
        for i in 0..ni as u32 {
            let t = b.insts[i as usize];
            if t.op != O_MEMCPY || self.iblk[i as usize] == NONE || !self.reached[self.iblk[i as usize] as usize] {
                continue;
            }
            let n = const_int(b, t.c);
            let d = self.slot_at0(t.a);
            let sr = self.slot_at0(t.b);
            // A destination that promotes takes the source's fields without the merge.
            if n <= 0 || d == NONE || sr == NONE || d == sr || self.busy[d as usize] || self.busy[sr as usize] || self.mesc[sr as usize] || self.pcand[d as usize] {
                continue;
            }
            if b.slots[d as usize].size as i64 != n || b.slots[sr as usize].size as i64 != n {
                continue;
            }
            // At most MERGE_TRIES reachability walks per body: each is linear in the blocks.
            tries += 1;
            if tries > MERGE_TRIES {
                break;
            }
            let k = self.iblk[i as usize];
            if !self.walk_from(b, k, i, succ_at, succs) {
                continue;
            }
            // The source: no use after the copy; the destination: no use before it.
            let mut ok = true;
            for q in self.mat[sr as usize]..self.mat[sr as usize + 1] {
                let u = self.muse[q as usize] as u32;
                ok = ok && (u == i || !self.after(k, i, u));
            }
            for q in self.mat[d as usize]..self.mat[d as usize + 1] {
                let u = self.muse[q as usize] as u32;
                ok = ok && (u == i || self.after(k, i, u));
            }
            if ok {
                self.mslot[d as usize] = sr;
                self.busy[d as usize] = true;
                self.busy[sr as usize] = true;
                self.cdrop[i as usize] = true;
                any = true;
            }
        }
        return any;
    }

    // The slot address value `v` is with offset 0 (NONE: none).
    const fn slot_at0(self: &Self, v: Value) u32 {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || self.mdslot[v as usize] == NONE || self.mdoff[v as usize] != 0 {
            return NONE;
        }
        return self.mdslot[v as usize];
    }

    // Mark the blocks the copy at instruction `i` of block `k` reaches past it (`reach` = `i`); false when
    // it reaches itself (a cycle runs it again).
    fn walk_from(self: &mut Self, b: &Body, k: u32, i: u32, succ_at: []u32, succs: []u32) bool {
        self.work.truncate(0);
        for e in succ_at[k as usize]..succ_at[k as usize + 1] {
            let s = succs[e as usize];
            if self.reach[s as usize] != i {
                self.reach[s as usize] = i;
                self.work.push(s);
            }
        }
        // Each block enters the list once.
        while self.work.len() != 0 {
            let x = self.work.pop().unwrap();
            for e in succ_at[x as usize]..succ_at[x as usize + 1] {
                let s = succs[e as usize];
                if self.reach[s as usize] != i {
                    self.reach[s as usize] = i;
                    self.work.push(s);
                }
            }
        }
        let _ = b;
        return self.reach[k as usize] != i;
    }

    // Whether instruction `u` runs after the copy at instruction `i` of block `k` (`walk_from`'s marks).
    const fn after(self: &Self, k: u32, i: u32, u: u32) bool {
        let ub = self.iblk[u as usize];
        return self.reach[ub as usize] == i || ub == k && u > i;
    }

    // An escape of slot address `v` at instruction `i`: a use too, where the address goes.
    fn escape(self: &mut Self, v: Value, i: u32) {
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.rslot[v as usize] != NONE {
            self.mesc[self.rslot[v as usize] as usize] = true;
            self.use_of(v, i);
        }
    }

    // A use of slot address `v` by instruction `i` (NONE: `v` is none).
    fn use_of(self: &mut Self, v: Value, i: u32) {
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && self.rslot[v as usize] != NONE {
            self.muse.push(self.rslot[v as usize] as u64 << 32 | i as u64);
        }
    }

    // Note instruction `i`'s uses of slot addresses: an access through one (a load's or store's address, a copy's or
    // fill's side, an address computation, a vector operation's operand, an aggregate argument the callee owns, an
    // aggregate result's memory) is a use; any other (a stored value, an edge's argument, another argument) lets the
    // address stay where the slot's merges cannot see it.
    fn note_uses(self: &mut Self, b: &Body, i: u32, t: Inst, ops_at: []u32, ops_arg: []u32, ops: []Value) {
        let f = op_info(t.op).form;
        if f == F_LOAD {
            self.use_of(t.a, i);
        } else if f == F_STORE {
            self.use_of(t.a, i);
            self.escape(t.b, i);
        } else if f == F_PTRADD {
            self.use_of(t.a, i);
            self.escape(t.b, i);
        } else if t.op == O_MEMCPY || t.op == O_MEMSET {
            self.use_of(t.a, i);
            if t.op == O_MEMCPY {
                self.use_of(t.b, i);
            } else {
                self.escape(t.b, i);
            }
            self.escape(t.c, i);
        } else if f == F_VOP {
            for q in 0..t.b {
                self.use_of(b.pool[(t.a + q) as usize], i);
            }
        } else if f == F_CALL || f == F_CALLIND {
            if f == F_CALLIND {
                self.escape(t.a, i);
            }
            let np = b.pool[t.b as usize];
            let sret = (b.pool[t.b as usize + 2] & AGG) != 0;
            for q in 0..t.aux as u32 {
                let v = b.pool[(t.c + q) as usize];
                // An aggregate argument the callee owns, or the memory its aggregate result goes to.
                if q < np && (b.pool[(t.b + 3 + q) as usize] & AGG) != 0 || q == np && sret {
                    self.use_of(v, i);
                } else {
                    self.escape(v, i);
                }
            }
        } else {
            for u in ops_at[i as usize]..ops_arg[i as usize] {
                self.escape(ops[u as usize], i);
            }
        }
        for u in ops_arg[i as usize]..ops_at[i as usize + 1] {
            self.escape(ops[u as usize], i);
        }
    }

    // ---- Candidates ----------------------------------------------------------------------------------

    // The derived addresses, the accesses and copies of each slot, and which slots stay candidates:
    // every use of a derived address is a load's or a store's address, a constant `ptradd`'s base, or a
    // side of a copy or a fill of constant size. False when none is. Per instruction also the slot for
    // `merges`: through any address arithmetic (`rslot`), through constant offsets alone with the offset
    // (`mdslot`, `mdoff`).
    fn collect(self: &mut Self, b: &Body, idom: []u32, ops_at: []u32, ops: []Value) bool {
        let ni = b.insts.len();
        let ns = b.slots.len();
        fill(&mut self.dslot, ni, NONE);
        self.doff.truncate(0);
        self.doff.resize_default(ni);
        fill(&mut self.rslot, ni, NONE);
        fill(&mut self.mdslot, ni, NONE);
        self.mdoff.truncate(0);
        self.mdoff.resize_default(ni);
        fill(&mut self.cand, ns, true);
        for s in 0..ns {
            if self.busy[s] {
                self.cand[s] = false;
            }
        }
        self.accs.truncate(0);
        self.copies.truncate(0);
        // The derived addresses: a base dominates its uses, so the blocks in array order may see a use
        // first; two passes settle a chain whose links come in that order, which the second checks.
        for _pass in 0..2 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op == O_SLOTADDR {
                    self.dslot[i] = t.a;
                    self.rslot[i] = t.a;
                    self.mdslot[i] = t.a;
                } else if t.op == O_PTRADD && (t.a & (VPARAM | VFLAG)) == 0 && t.a != VNONE && self.rslot[t.a as usize] != NONE {
                    // A `dslot` base is an `rslot` one: both chains start at a slot address.
                    let a = t.a as usize;
                    self.rslot[i] = self.rslot[a];
                    if t.b == VNONE && self.mdslot[a] != NONE {
                        self.mdslot[i] = self.mdslot[a];
                        self.mdoff[i] = self.mdoff[a] + (t.c as i32) as i64;
                    }
                    // A constant index is a constant offset (the optimizer keeps a slot address's index).
                    let ix = if t.b == VNONE || self.dslot[a] == NONE {
                        0i64
                    } else {
                        const_int(b, t.b)
                    };
                    if self.dslot[a] != NONE && ix >= 0 {
                        self.dslot[i] = self.dslot[a];
                        self.doff[i] = self.doff[a] + (t.c as i32) as i64 + ix * scale_of(t) as i64;
                    }
                }
            }
        }
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            let reached = idom[k] != NONE;
            for i in bk.start..bk.start + bk.len {
                let t = b.insts[i as usize];
                self.check_uses(b, i, t, reached, ops_at, ops);
            }
        }
        for s in 0..ns {
            if self.cand[s] {
                return true;
            }
        }
        return false;
    }

    // The slot address value `v` points into (NONE: none).
    const fn slot_of(self: &Self, v: Value) u32 {
        if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
            return NONE;
        }
        return self.dslot[v as usize];
    }

    const fn reject(self: &mut Self, v: Value) {
        let s = self.slot_of(v);
        if s != NONE {
            self.cand[s as usize] = false;
        }
    }

    // Record instruction `i`'s accesses, and reject the slots it lets escape (an unreached block's
    // access too).
    fn check_uses(self: &mut Self, b: &Body, i: u32, t: Inst, reached: bool, ops_at: []u32, ops: []Value) {
        let op = t.op;
        if op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 && self.slot_of(t.a) != NONE {
            let s = self.slot_of(t.a);
            self.cand[s as usize] = self.cand[s as usize] && reached;
            self.accs.push(
                Acc {
                    slot: s,
                    off: self.doff[t.a as usize] + (t.c as i32) as i64,
                    size: 0,
                    ty: t.ty,
                    kind: wide_kind(t.ty),
                },
            );
            return;
        }
        if op == O_STORE && (t.aux & MEM_VOLATILE) == 0 && self.slot_of(t.a) != NONE {
            let s = self.slot_of(t.a);
            self.cand[s as usize] = self.cand[s as usize] && reached;
            self.reject(t.b);
            let ty = b.type_of(t.b);
            self.accs.push(
                Acc {
                    slot: s,
                    off: self.doff[t.a as usize] + (t.c as i32) as i64,
                    size: 0,
                    ty: ty,
                    kind: if wide_kind(ty) == 0 {
                        0
                    } else if int_bits(b, t.b).is_some() {
                        W_CSTORE
                    } else {
                        W_VSTORE
                    },
                },
            );
            return;
        }
        if op == O_PTRADD && (t.b == VNONE || self.dslot[i as usize] != NONE) {
            return; // a derived address, or none
        }
        if (op == O_MEMCPY || op == O_MEMSET) && (self.slot_of(t.a) != NONE || op == O_MEMCPY && self.slot_of(t.b) != NONE) {
            let n = const_int(b, t.c);
            let d = self.slot_of(t.a);
            let sv = if op == O_MEMCPY {
                self.slot_of(t.b)
            } else {
                NONE
            };
            let byte = if op == O_MEMSET {
                const_int(b, t.b)
            } else {
                0i64
            };
            if n <= 0 || n > 4096 || !reached || d != NONE && d == sv || op == O_MEMSET && byte < 0 {
                self.reject(t.a);
                self.reject(t.b);
                return;
            }
            self.copies.push(
                Copy {
                    inst: i,
                    dslot: d,
                    doff: if d != NONE {
                        self.doff[t.a as usize]
                    } else {
                        0i64
                    },
                    sslot: sv,
                    soff: if sv != NONE {
                        self.doff[t.b as usize]
                    } else {
                        0i64
                    },
                    size: n,
                    byte: byte as u64,
                },
            );
            return;
        }
        // Any other use of a derived address lets it escape: an operand or an edge's argument (`ops`).
        for u in ops_at[i as usize]..ops_at[i as usize + 1] {
            self.reject(ops[u as usize]);
        }
    }

    // ---- Fields --------------------------------------------------------------------------------------

    // The fields of every candidate slot, and per instruction the field it reads or writes; a slot whose
    // accesses overlap with another type, or have too many fields, stops being a candidate. Copies between
    // two candidates share their fields first (two rounds), then the bytes a copy covers but no access
    // names become integer fields. False when no candidate is left.
    fn fields(self: &mut Self, b: &Body) bool {
        let ns = b.slots.len();
        // Two rounds of sharing, on the accesses alone; then the gaps.
        for _round in 0..2 {
            self.build_fields(b, false);
            // A copy between two candidates gives each side the other's fields.
            let n0 = self.accs.len();
            for c in 0..self.copies.len() {
                let cp = self.copies[c];
                if cp.dslot == NONE || cp.sslot == NONE || !self.cand[cp.dslot as usize] || !self.cand[cp.sslot as usize] {
                    continue;
                }
                self.share(cp.sslot, cp.soff, cp.dslot, cp.doff, cp.size);
                self.share(cp.dslot, cp.doff, cp.sslot, cp.soff, cp.size);
            }
            if self.accs.len() == n0 {
                break;
            }
        }
        // A slot only copies touch, copied to or from a slot that stays in memory, stays too: its fields
        // would be integer words, whose stores into the other slot keep that one in memory for good,
        // where a later promotion (once unrolling gives its accesses constant offsets) takes both with
        // the other's types.
        fill(&mut self.typed, ns, false);
        for a in 0..self.accs.len() {
            self.typed[self.accs[a].slot as usize] = true;
        }
        for c in 0..self.copies.len() {
            let cp = self.copies[c];
            if cp.dslot != NONE && cp.sslot != NONE {
                if !self.typed[cp.dslot as usize] && !self.cand[cp.sslot as usize] {
                    self.cand[cp.dslot as usize] = false;
                }
                if !self.typed[cp.sslot as usize] && !self.cand[cp.dslot as usize] {
                    self.cand[cp.sslot as usize] = false;
                }
            }
        }
        self.build_fields(b, true);
        // A field a copy or a fill covers in part keeps its slot in memory: the copy writes or reads some
        // of its bytes only. Each round drops a slot or ends.
        for _ in 0..ns + 1 {
            let mut dropped = false;
            for c in 0..self.copies.len() {
                let cp = self.copies[c];
                for side in 0..2 {
                    let (cs, co) = if side == 0 {
                        (cp.dslot, cp.doff)
                    } else {
                        (cp.sslot, cp.soff)
                    };
                    if cs == NONE || !self.cand[cs as usize] {
                        continue;
                    }
                    for f in self.fat[cs as usize]..self.fat[cs as usize + 1] {
                        let fl = self.flds[f as usize];
                        let overlaps = fl.off < co + cp.size && co < fl.off + size_of(fl.ty, self.ptr);
                        if overlaps && !in_range(fl, co, cp.size, self.ptr) {
                            self.cand[cs as usize] = false;
                            dropped = true;
                        }
                    }
                }
            }
            if !dropped {
                break;
            }
            self.build_fields(b, true);
        }
        // The two sides of a copy between candidates must have the same fields.
        for c in 0..self.copies.len() {
            let cp = self.copies[c];
            if cp.dslot == NONE || cp.sslot == NONE || !self.cand[cp.dslot as usize] || !self.cand[cp.sslot as usize] {
                continue;
            }
            if !self.same_fields(cp.dslot, cp.doff, cp.sslot, cp.soff, cp.size) {
                self.cand[cp.dslot as usize] = false;
                self.cand[cp.sslot as usize] = false;
                self.build_fields(b, true);
            }
        }
        // The field of each load and store, or whether it spans fields (`spanned`); a slot with a spanning
        // access `spannable` refuses stays in memory, and the fields are built again. Each round drops a
        // slot or ends.
        for _ in 0..ns + 1 {
            fill(&mut self.fid, b.insts.len(), NONE);
            fill(&mut self.lane, b.insts.len(), NONE);
            fill(&mut self.spanned, b.insts.len(), false);
            fill(&mut self.part, b.insts.len(), NONE);
            let mut any = false;
            for s in 0..ns {
                any = any || self.cand[s];
            }
            if !any {
                return false;
            }
            let mut dropped = false;
            for i in 0..b.insts.len() {
                let t = b.insts[i];
                if (t.op == O_LOAD || t.op == O_STORE) && (t.aux & MEM_VOLATILE) == 0 && self.slot_of(t.a) != NONE {
                    let s = self.slot_of(t.a);
                    if self.cand[s as usize] {
                        let ty = if t.op == O_LOAD {
                            t.ty
                        } else {
                            b.type_of(t.b)
                        };
                        let off = self.doff[t.a as usize] + (t.c as i32) as i64;
                        self.fid[i] = self.field_at(s, off, ty);
                        if self.fid[i] == NONE {
                            let (f, k) = self.lane_at(s, off, ty);
                            self.fid[i] = f;
                            self.lane[i] = k;
                        }
                        if self.fid[i] == NONE {
                            let pf = if t.op == O_LOAD && wide_kind(ty) != 0 {
                                self.part_at(s, off, size_of(ty, self.ptr))
                            } else {
                                NONE
                            };
                            if t.op == O_LOAD && wide_kind(ty) != 0 && self.spannable(s, off, size_of(ty, self.ptr)) {
                                self.spanned[i] = true;
                            } else if pf != NONE {
                                self.fid[i] = pf;
                                self.part[i] = (off - self.flds[pf as usize].off) as u32;
                            } else if t.op == O_STORE && wide_kind(ty) != 0 && int_bits(b, t.b).is_some() && self.spannable(
                                s,
                                off,
                                size_of(ty, self.ptr),
                            ) && self.gaps_zero(s, off, size_of(ty, self.ptr), int_bits(b, t.b).unwrap()) {
                                self.spanned[i] = true;
                            } else if t.op == O_STORE && wide_kind(ty) != 0 && self.spannable(
                                s,
                                off,
                                size_of(ty, self.ptr),
                            ) && !self.gaps_read(s, off, size_of(ty, self.ptr)) {
                                self.spanned[i] = true;
                            } else {
                                self.cand[s as usize] = false;
                                dropped = true;
                            }
                        }
                    }
                }
            }
            if !dropped {
                return true;
            }
            self.build_fields(b, true);
        }
        return false;
    }

    // Add to slot `d`'s accesses the fields of slot `s` in bytes `so` to `so + n`, at `do`.
    fn share(self: &mut Self, s: u32, so: i64, d: u32, dof: i64, n: i64) {
        for f in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f as usize];
            if fl.off >= so && fl.off + size_of(fl.ty, self.ptr) <= so + n {
                self.accs.push(Acc { slot: d, off: fl.off - so + dof, size: 0, ty: fl.ty, kind: 0 });
            }
        }
    }

    // Whether slot `a`'s fields in bytes `ao` to `ao + n` are slot `c`'s in `co` to `co + n`.
    const fn same_fields(self: &Self, a: u32, ao: i64, c: u32, co: i64, n: i64) bool {
        let mut fa = self.fat[a as usize];
        let mut fc = self.fat[c as usize];
        // Each step passes one field of each: at most FIELDS_MAX + 1 steps.
        for _ in 0..FIELDS_MAX + 1 {
            while fa < self.fat[a as usize + 1] && !(self.flds[fa as usize].off >= ao && self.flds[fa as usize].off < ao + n) {
                fa += 1;
            }
            while fc < self.fat[c as usize + 1] && !(self.flds[fc as usize].off >= co && self.flds[fc as usize].off < co + n) {
                fc += 1;
            }
            let ea = fa >= self.fat[a as usize + 1];
            let ec = fc >= self.fat[c as usize + 1];
            if ea || ec {
                return ea && ec;
            }
            let x = self.flds[fa as usize];
            let y = self.flds[fc as usize];
            if x.off - ao != y.off - co || x.ty != y.ty {
                return false;
            }
            fa += 1;
            fc += 1;
        }
        return false;
    }

    // The fields of every candidate from its accesses (and the gaps of its copies when `gaps`).
    fn build_fields(self: &mut Self, b: &Body, gaps: bool) {
        let ns = b.slots.len();
        // The accesses by slot: a counting sort.
        fill(&mut self.fat, ns + 1, 0);
        for a in 0..self.accs.len() {
            self.fat[self.accs[a].slot as usize + 1] += 1;
        }
        for s in 0..ns {
            self.fat[s + 1] += self.fat[s];
        }
        self.mark.truncate(0);
        self.mark.extend_copy(&self.fat);
        self.tmp.truncate(0);
        for _ in 0..self.accs.len() {
            self.tmp.push(Fld { off: 0, ty: T_NONE, w: 0 });
        }
        for a in 0..self.accs.len() {
            let ac = self.accs[a];
            self.tmp[self.mark[ac.slot as usize] as usize] = Fld { off: ac.off, ty: ac.ty, w: ac.kind };
            self.mark[ac.slot as usize] += 1;
        }
        self.flds.truncate(0);
        let mut at = Vector::<u32>::with_capacity(ns + 1);
        at.push(0);
        for s in 0..ns {
            let lo = self.fat[s] as usize;
            let hi = self.fat[s + 1] as usize;
            let start = self.flds.len();
            if self.cand[s] {
                if hi - lo > FIELDS_MAX as usize * 4 {
                    self.cand[s] = false;
                } else {
                    sort_fields(&mut self.tmp, lo, hi);
                    // Accesses that overlap otherwise span fields when they may (`spans`), else reject
                    // the slot.
                    if !self.merge(lo, hi, start) {
                        self.flds.truncate(start);
                        self.cand[s] = self.spans(lo, hi) && self.merge(lo, hi, start);
                    }
                }
                if self.cand[s] && gaps {
                    self.fill_gaps(s as u32, start);
                }
                if !self.cand[s] || self.flds.len() - start > FIELDS_MAX as usize {
                    self.cand[s] = false;
                    self.flds.truncate(start);
                }
            }
            at.push(self.flds.len() as u32);
        }
        self.fat = at;
    }

    // The fields of the accesses `tmp[lo .. hi]` (one slot's, sorted) but those marked W_SPANS, pushed from
    // `flds[start]`: equal accesses merge. False at two that overlap otherwise.
    fn merge(self: &mut Self, lo: usize, hi: usize, start: usize) bool {
        for j in lo..hi {
            let mut f = self.tmp[j];
            if (f.w & W_SPANS) != 0 {
                continue;
            }
            f.w = 0;
            let n = self.flds.len();
            // The same bytes as another type that converts to the field's: one field.
            if n > start && self.flds[n - 1].off == f.off && conv_op(f.ty, self.flds[n - 1].ty, self.ptr) != NO_CONV {
                continue;
            }
            // A lane of a vector field is part of it; a vector over lane 0 takes its place.
            if n > start && is_lane(self.flds[n - 1], f) {
                continue;
            }
            if n > start && self.flds[n - 1].off == f.off && is_lane(f, self.flds[n - 1]) {
                self.flds[n - 1] = f;
                continue;
            }
            if n > start && self.flds[n - 1].off + size_of(self.flds[n - 1].ty, self.ptr) > f.off {
                return false;
            }
            self.flds.push(f);
        }
        return true;
    }

    // Mark W_SPANS each load of `tmp[lo .. hi]` (one slot's, sorted) that may span fields (`Acc.kind`)
    // and overlaps another access that is not the same field (the same offset in a type that converts, or a
    // lane of it), and each constant store that holds such an access whole. Whether any.
    fn spans(self: &mut Self, lo: usize, hi: usize) bool {
        let mut any = false;
        for j in lo..hi {
            let a = self.tmp[j];
            if a.w == 0 {
                continue;
            }
            let ae = a.off + size_of(a.ty, self.ptr);
            // The accesses are by offset: those from `ae` on overlap none of its bytes.
            for q in lo..hi {
                let c = self.tmp[q];
                if c.off >= ae {
                    break;
                }
                let same = c.off == a.off && conv_op(c.ty, a.ty, self.ptr) != NO_CONV || is_lane(a, c) || is_lane(c, a);
                // A store spans only accesses it holds whole, a narrower one keeping its field; another
                // integer's, only integer stores (a load inside it reads part of its field instead).
                let held = (a.w & (W_CSTORE | W_VSTORE)) == 0 || a.off <= c.off && c.off + size_of(c.ty, self.ptr) <= ae;
                let kind_ok = (a.w & W_VSTORE) == 0 || (c.w & (W_CSTORE | W_VSTORE)) != 0;
                if q != j && !same && held && kind_ok && a.off < c.off + size_of(c.ty, self.ptr) {
                    self.tmp[j].w = a.w | W_SPANS;
                    any = true;
                    break;
                }
            }
        }
        return any;
    }

    // The bytes of slot `s`'s copies that no field (from `flds[start ..]`) covers: integer fields, each
    // the widest of 8, 4, 2 or 1 bytes its offset is aligned to that fits.
    fn fill_gaps(self: &mut Self, s: u32, start: usize) {
        let end = self.flds.len();
        self.gap.truncate(0);
        for f in start..end {
            self.gap.push(self.flds[f]);
        }
        for c in 0..self.copies.len() {
            let cp = self.copies[c];
            for side in 0..2 {
                let (cs, co) = if side == 0 {
                    (cp.dslot, cp.doff)
                } else {
                    (cp.sslot, cp.soff)
                };
                if cs != s {
                    continue;
                }
                let mut p = co;
                // Each step passes a field or adds one: at most the copy's bytes.
                while p < co + cp.size {
                    let mut covered: i64 = -1;
                    for f in 0..self.gap.len() {
                        let fl = self.gap[f];
                        if fl.off <= p && p < fl.off + size_of(fl.ty, self.ptr) {
                            covered = fl.off + size_of(fl.ty, self.ptr);
                        }
                    }
                    if covered > p {
                        p = covered;
                        continue;
                    }
                    // The gap's end: the next field's start or the copy's end.
                    let mut ge = co + cp.size;
                    for f in 0..self.gap.len() {
                        let fl = self.gap[f];
                        if fl.off > p && fl.off < ge {
                            ge = fl.off;
                        }
                    }
                    let mut w: i64 = 8;
                    while w > 1 && (p % w != 0 || p + w > ge) {
                        w /= 2;
                    }
                    let ty = if w == 8 {
                        T_I64
                    } else if w == 4 {
                        T_I32
                    } else if w == 2 {
                        T_I16
                    } else {
                        T_I8
                    };
                    self.gap.push(Fld { off: p, ty: ty, w: 0 });
                    p += w;
                    if self.gap.len() > FIELDS_MAX as usize {
                        self.cand[s as usize] = false;
                        return;
                    }
                }
            }
        }
        let n = self.gap.len();
        sort_fields(&mut self.gap, 0, n);
        self.flds.truncate(start);
        for f in 0..n {
            self.flds.push(self.gap[f]);
        }
    }

    // Whether the fields of slot `s` that bytes `off` to `off + n` overlap all lie in them, each a scalar
    // whose bits an integer of its size holds (`spanned`).
    const fn spannable(self: &Self, s: u32, off: i64, n: i64) bool {
        for f in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f as usize];
            let fe = fl.off + size_of(fl.ty, self.ptr);
            if fl.off < off + n && off < fe && (fl.off < off || fe > off + n || is_vec(fl.ty) || fl.ty == T_I128 || conv_op(
                fl.ty,
                int_of(size_of(fl.ty, self.ptr)),
                self.ptr,
            ) == NO_CONV) {
                return false;
            }
        }
        return true;
    }

    // Whether an integer load of slot `s` (which may span fields, reading 0 where none is) covers one of
    // bytes `off` to `off + n` that no field holds.
    fn gaps_read(self: &Self, s: u32, off: i64, n: i64) bool {
        for a in 0..self.accs.len() {
            let ac = self.accs[a];
            if ac.slot != s || (ac.kind & W_LOAD) == 0 {
                continue;
            }
            let lo = if ac.off > off {
                ac.off
            } else {
                off
            };
            let ae = ac.off + size_of(ac.ty, self.ptr);
            let hi = if ae < off + n {
                ae
            } else {
                off + n
            };
            for p in lo..hi {
                let mut held = false;
                for f in self.fat[s as usize]..self.fat[s as usize + 1] {
                    let fl = self.flds[f as usize];
                    held = held || fl.off <= p && p < fl.off + size_of(fl.ty, self.ptr);
                }
                if !held {
                    return true;
                }
            }
        }
        return false;
    }

    // Whether the bytes of constant `c` (`n` bytes at `off` of slot `s`) that no field holds are 0.
    const fn gaps_zero(self: &Self, s: u32, off: i64, n: i64, c: u64) bool {
        for p in 0..n {
            let mut held = false;
            for f in self.fat[s as usize]..self.fat[s as usize + 1] {
                let fl = self.flds[f as usize];
                held = held || fl.off <= off + p && off + p < fl.off + size_of(fl.ty, self.ptr);
            }
            if !held && (c >> (8 * p) as u64 & 0xFF) != 0 {
                return false;
            }
        }
        return true;
    }

    // The global index of slot `s`'s field wider than `n` bytes that holds bytes `off` to `off + n`, a
    // scalar whose bits an integer of its size holds (a load of them reads part of it); NONE when none.
    const fn part_at(self: &Self, s: u32, off: i64, n: i64) u32 {
        for f in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f as usize];
            let fw = size_of(fl.ty, self.ptr);
            if fl.off <= off && off + n <= fl.off + fw && fw > n && !is_vec(fl.ty) && fl.ty != T_I128 && conv_op(
                fl.ty,
                int_of(fw),
                self.ptr,
            ) != NO_CONV {
                return f;
            }
        }
        return NONE;
    }

    // The global index of slot `s`'s field at `off` whose type `ty` converts to (NONE: none).
    // The vector field of slot `s` that bytes `off` as `ty` are a lane of, and the lane; NONE twice when
    // none.
    const fn lane_at(self: &Self, s: u32, off: i64, ty: u8) (u32, u32) {
        for f in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f as usize];
            if is_lane(fl, Fld { off: off, ty: ty, w: 0 }) {
                return (f, ((off - fl.off) / size_of(ty, self.ptr)) as u32);
            }
        }
        return (NONE, NONE);
    }

    const fn field_at(self: &Self, s: u32, off: i64, ty: u8) u32 {
        for f in self.fat[s as usize]..self.fat[s as usize + 1] {
            if self.flds[f as usize].off == off && conv_op(ty, self.flds[f as usize].ty, self.ptr) != NO_CONV {
                return f;
            }
        }
        return NONE;
    }

    // ---- Placement -----------------------------------------------------------------------------------

    // The dominance frontier of every reached block (Cooper, Harvey and Kennedy).
    fn frontiers(self: &mut Self, b: &Body, pred_at: []u32, preds: []u32, idom: []u32, order: []u32) {
        let nb = b.blocks.len();
        self.pairs.truncate(0);
        fill(&mut self.mark, nb, NONE);
        for o in 0..order.len() {
            let k = order[o];
            let mut np: u32 = 0;
            for p in pred_at[k as usize]..pred_at[k as usize + 1] {
                np += (idom[preds[p as usize] as usize] != NONE) as u32;
            }
            if np < 2 {
                continue;
            }
            for p in pred_at[k as usize]..pred_at[k as usize + 1] {
                let mut r = preds[p as usize];
                if idom[r as usize] == NONE {
                    continue;
                }
                // Each step climbs one dominator.
                while r != idom[k as usize] {
                    if self.mark[r as usize] != k {
                        self.mark[r as usize] = k;
                        self.pairs.push(r as u64 << 32 | k as u64);
                    }
                    if r == 0 {
                        break;
                    }
                    r = idom[r as usize];
                }
            }
        }
        fill(&mut self.df_at, nb + 1, 0);
        for q in 0..self.pairs.len() {
            self.df_at[(self.pairs[q] >> 32) as usize + 1] += 1;
        }
        for k in 0..nb {
            self.df_at[k + 1] += self.df_at[k];
        }
        fill(&mut self.df, self.pairs.len(), 0);
        fill(&mut self.work, nb, 0);
        for q in 0..self.pairs.len() {
            let r = (self.pairs[q] >> 32) as usize;
            self.df[(self.df_at[r] + self.work[r]) as usize] = self.pairs[q] as u32;
            self.work[r] += 1;
        }
    }

    // Per field the blocks that define it and that read it first, then its parameters: the iterated
    // frontier of its definitions where it is live.
    fn place(self: &mut Self, b: &Body, pred_at: []u32, preds: []u32, idom: []u32) {
        let nb = b.blocks.len();
        let nf = self.flds.len();
        self.dblk.truncate(0);
        self.ublk.truncate(0);
        // Per field, the last block that defined it in the scan (the first read before it is exposed).
        fill(&mut self.isdef, nf, NONE);
        for k in 0..nb {
            if idom[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.reads_writes(b, i, k as u32);
            }
        }
        // The definitions and first reads by field: sort the packed lists.
        self.dblk.sort();
        self.ublk.sort();
        fill(&mut self.livein, nb, NONE);
        fill(&mut self.hasphi, nb, NONE);
        fill(&mut self.mark, nb, NONE); // per block, the field it defines
        self.phis.truncate(0);
        let mut di: usize = 0;
        let mut ui: usize = 0;
        for f in 0..nf as u32 {
            let d0 = di;
            while di < self.dblk.len() && (self.dblk[di] >> 32) as u32 == f {
                self.mark[(self.dblk[di] as u32) as usize] = f;
                di += 1;
            }
            // Live-in: from each first read up the predecessors, through the blocks that do not define it.
            self.work.truncate(0);
            while ui < self.ublk.len() && (self.ublk[ui] >> 32) as u32 == f {
                let k = self.ublk[ui] as u32;
                if self.livein[k as usize] != f {
                    self.livein[k as usize] = f;
                    self.work.push(k);
                }
                ui += 1;
            }
            // Each block enters the list once per field.
            while self.work.len() != 0 {
                let k = self.work.pop().unwrap();
                for p in pred_at[k as usize]..pred_at[k as usize + 1] {
                    let q = preds[p as usize];
                    if idom[q as usize] != NONE && self.mark[q as usize] != f && self.livein[q as usize] != f {
                        self.livein[q as usize] = f;
                        self.work.push(q);
                    }
                }
            }
            // The iterated frontier of the definitions, where the field is live; a field live into the
            // entry block is defined there (by the zero of its type, `zero`).
            for d in d0..di {
                self.work.push(self.dblk[d] as u32);
            }
            if self.livein[0] == f && self.mark[0] != f {
                self.work.push(0);
            }
            // Each block takes one parameter per field and enters the list once more for it.
            while self.work.len() != 0 {
                let x = self.work.pop().unwrap();
                for j in self.df_at[x as usize]..self.df_at[x as usize + 1] {
                    let y = self.df[j as usize];
                    if self.hasphi[y as usize] != f && self.livein[y as usize] == f {
                        self.hasphi[y as usize] = f;
                        self.phis.push(y as u64 << 32 | f as u64);
                        if self.mark[y as usize] != f {
                            self.work.push(y);
                        }
                    }
                }
            }
        }
        self.phis.sort();
        fill(&mut self.phi_at, nb + 1, 0);
        for q in 0..self.phis.len() {
            self.phi_at[(self.phis[q] >> 32) as usize + 1] += 1;
        }
        for k in 0..nb {
            self.phi_at[k + 1] += self.phi_at[k];
        }
    }

    // Note instruction `i` of block `k`: the fields it defines (`dblk`) and reads before a definition in
    // the block (`ublk`, by `isdef` per field: the last block that defined it in this scan).
    fn reads_writes(self: &mut Self, b: &Body, i: u32, k: u32) {
        let t = b.insts[i as usize];
        if self.spanned[i as usize] {
            let s = self.slot_of(t.a);
            let off = self.doff[t.a as usize] + (t.c as i32) as i64;
            let n = if t.op == O_STORE {
                size_of(b.type_of(t.b), self.ptr)
            } else {
                size_of(t.ty, self.ptr)
            };
            for f2 in self.fat[s as usize]..self.fat[s as usize + 1] {
                if in_range(self.flds[f2 as usize], off, n, self.ptr) {
                    if t.op == O_STORE {
                        self.write(f2, k);
                    } else {
                        self.read(f2, k);
                    }
                }
            }
            return;
        }
        let f = self.fid[i as usize];
        if f != NONE {
            // A lane's store keeps the other lanes: it reads the field too.
            if t.op == O_LOAD || self.lane[i as usize] != NONE {
                self.read(f, k);
            }
            if t.op == O_STORE {
                self.write(f, k);
            }
            return;
        }
        if t.op != O_MEMCPY && t.op != O_MEMSET {
            return;
        }
        let c = self.copy_of(i);
        if c == NONE {
            return;
        }
        let cp = self.copies[c as usize];
        if cp.sslot != NONE && self.cand[cp.sslot as usize] {
            for f2 in self.fat[cp.sslot as usize]..self.fat[cp.sslot as usize + 1] {
                if in_range(self.flds[f2 as usize], cp.soff, cp.size, self.ptr) {
                    self.read(f2, k);
                }
            }
        }
        if cp.dslot != NONE && self.cand[cp.dslot as usize] {
            for f2 in self.fat[cp.dslot as usize]..self.fat[cp.dslot as usize + 1] {
                if in_range(self.flds[f2 as usize], cp.doff, cp.size, self.ptr) {
                    self.write(f2, k);
                }
            }
        }
    }

    fn read(self: &mut Self, f: u32, k: u32) {
        if self.isdef[f as usize] != k && self.isdef[f as usize] != (k | 0x80000000) {
            self.ublk.push(f as u64 << 32 | k as u64);
            // One first read per block suffices.
            self.isdef[f as usize] = k | 0x80000000;
        }
    }

    fn write(self: &mut Self, f: u32, k: u32) {
        if self.isdef[f as usize] != k {
            self.dblk.push(f as u64 << 32 | k as u64);
        }
        self.isdef[f as usize] = k;
    }

    // The copy record of instruction `i` (NONE: none): `copies` is in instruction order.
    const fn copy_of(self: &Self, i: u32) u32 {
        let mut lo: usize = 0;
        let mut hi = self.copies.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.copies[mid].inst < i {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return if lo < self.copies.len() && self.copies[lo].inst == i {
            lo as u32
        } else {
            NONE
        };
    }

    // ---- Renaming ------------------------------------------------------------------------------------

    // One preorder walk of the dominator tree: each field's current value, set by its parameters and
    // definitions, read by its loads and by the edges into blocks with its parameters. A fill no
    // constant can stand for returns its slot (NONE: all renamed).
    fn rename(self: &mut Self, b: &Body, kid_at: []u32, kids: []u32) u32 {
        let ni = b.insts.len();
        let np0 = b.params.len() as u32;
        fill(&mut self.cur, self.flds.len(), NONE);
        fill(&mut self.zeros, 256, NONE);
        self.xwords.truncate(0);
        fill(&mut self.repl, ni, NONE);
        fill(&mut self.drop, ni, false);
        for i in 0..ni {
            self.drop[i] = self.cdrop[i];
        }
        self.xins.truncate(0);
        self.eargs.clear();
        self.evals.truncate(0);
        self.log.truncate(0);
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block is entered and left once.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            if (x & 1) != 0 {
                let to = (x >> 1) as usize;
                // Each step restores one definition.
                while self.log.len() > to {
                    let e = self.log.pop().unwrap();
                    self.cur[(e >> 32) as usize] = e as u32;
                }
                continue;
            }
            let k = (x >> 1) as u32;
            self.stack.push(self.log.len() as u64 << 1 | 1);
            for q in self.phi_at[k as usize]..self.phi_at[k as usize + 1] {
                self.set(self.phis[q as usize] as u32, VPARAM | np0 + q);
            }
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let bad = self.rename_inst(b, i);
                if bad != NONE {
                    return bad;
                }
            }
            // The edges into blocks with parameters pass the current values.
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.edges);
            for e in 0..self.edges.len() {
                let ed = self.edges[e];
                let tk = b.edge_target(ed);
                let key = k as u64 << 32 | ed as u64;
                if self.phi_at[tk as usize] == self.phi_at[tk as usize + 1] || self.eargs.contains_key(&key) {
                    continue;
                }
                self.eargs.insert(key, self.evals.len() as u32);
                for q in self.phi_at[tk as usize]..self.phi_at[tk as usize + 1] {
                    let v = self.value(b, self.phis[q as usize] as u32);
                    self.evals.push(v);
                }
            }
            for c in kid_at[k as usize]..kid_at[k as usize + 1] {
                self.stack.push(kids[c as usize] as u64 << 1);
            }
        }
        return NONE;
    }

    // Value `v` of type `from` as type `to`: itself, or a conversion placed before instruction `i`.
    fn convert(self: &mut Self, b: &Body, i: u32, v: u32, from: u8, to: u8) u32 {
        if from == to {
            return v;
        }
        let x = (b.insts.len() + self.xins.len()) as u32;
        self.xins.push((i, Inst { op: conv_op(from, to, self.ptr), ty: to, aux: 0, a: v, b: VNONE, c: VNONE }));
        return x;
    }

    // Field `f`'s current value; where no store reaches, the zero of its type (the slot's bytes are
    // undefined there: any value is one).
    fn value(self: &mut Self, b: &Body, f: u32) u32 {
        let v = self.cur[f as usize];
        if v != NONE {
            return v;
        }
        return self.zero(b, self.flds[f as usize].ty);
    }

    // The zero of type `ty`, made once per type before the entry block's first instruction.
    fn zero(self: &mut Self, b: &Body, ty: u8) u32 {
        if self.zeros[ty as usize] != NONE {
            return self.zeros[ty as usize];
        }
        let k = if is_vec(ty) || ty == T_I128 {
            let at = b.words.len() + self.xwords.len();
            let nw = (type_bytes(ty, self.ptr) + 7) / 8;
            for _ in 0..nw {
                self.xwords.push(0);
            }
            Inst { op: O_WCONST, ty: ty, aux: 0, a: at as u32, b: nw, c: VNONE }
        } else {
            fill_const(ty, 0, self.ptr)
        };
        let v = (b.insts.len() + self.xins.len()) as u32;
        self.xins.push((b.blocks[0].start, k));
        self.zeros[ty as usize] = v;
        return v;
    }

    fn set(self: &mut Self, f: u32, v: u32) {
        self.log.push(f as u64 << 32 | self.cur[f as usize] as u64);
        self.cur[f as usize] = v;
    }

    // Rename instruction `i`: a promoted load takes its field's value, a promoted store sets it, a copy
    // or a fill with a candidate side becomes new instructions or definitions. A fill no constant can
    // stand for returns its slot (NONE: none).
    fn rename_inst(self: &mut Self, b: &Body, i: u32) u32 {
        let t = b.insts[i as usize];
        if self.spanned[i as usize] && t.op == O_STORE {
            self.drop[i as usize] = true;
            if int_bits(b, t.b).is_some() {
                self.rename_cstore(b, i, t);
            } else {
                self.rename_vstore(b, i, t);
            }
            return NONE;
        }
        if self.spanned[i as usize] {
            self.drop[i as usize] = true;
            self.rename_span(b, i, t);
            return NONE;
        }
        let f = self.fid[i as usize];
        if f != NONE {
            self.drop[i as usize] = true;
            let fty = self.flds[f as usize].ty;
            let k = self.lane[i as usize];
            if self.part[i as usize] != NONE {
                // Part of a wider field: its integer bits shifted down and truncated (little-endian).
                let it = int_of(size_of(fty, self.ptr));
                let fv = self.value(b, f);
                let mut v = self.convert(b, i, fv, fty, it);
                let sh = 8 * self.part[i as usize] as u64;
                if sh != 0 {
                    let c = self.push(b, i, fill_int(it, sh));
                    v = self.push(b, i, Inst { op: O_LSHR, ty: it, aux: 0, a: v, b: c, c: VNONE });
                }
                self.repl[i as usize] = self.push(
                    b,
                    i,
                    Inst { op: O_TRUNC, ty: t.ty, aux: 0, a: v, b: VNONE, c: VNONE },
                );
            } else if k != NONE {
                let v = self.value(b, f);
                let x = (b.insts.len() + self.xins.len()) as u32;
                if t.op == O_LOAD {
                    self.xins.push((i, Inst { op: O_VEXTRACT, ty: t.ty, aux: k as u16, a: v, b: VNONE, c: VNONE }));
                    self.repl[i as usize] = x;
                } else {
                    self.xins.push((i, Inst { op: O_VINSERT, ty: fty, aux: k as u16, a: v, b: t.b, c: VNONE }));
                    self.set(f, x);
                }
            } else if t.op == O_LOAD {
                let v = self.value(b, f);
                self.repl[i as usize] = self.convert(b, i, v, fty, t.ty);
            } else {
                let v = self.convert(b, i, t.b, b.type_of(t.b), fty);
                self.set(f, v);
            }
            return NONE;
        }
        if t.op != O_MEMCPY && t.op != O_MEMSET {
            return NONE;
        }
        let c = self.copy_of(i);
        if c == NONE {
            return NONE;
        }
        let cp = self.copies[c as usize];
        let dc = cp.dslot != NONE && self.cand[cp.dslot as usize];
        let sc = cp.sslot != NONE && self.cand[cp.sslot as usize];
        if !dc && !sc {
            return NONE;
        }
        self.drop[i as usize] = true;
        if sc && !dc {
            // Out of the promoted source: one store per field into the destination.
            for f2 in self.fat[cp.sslot as usize]..self.fat[cp.sslot as usize + 1] {
                let fl = self.flds[f2 as usize];
                if !in_range(fl, cp.soff, cp.size, self.ptr) {
                    continue;
                }
                let off = (fl.off - cp.soff) as i32;
                let v = self.value(b, f2);
                self.xins.push((i, Inst { op: O_STORE, ty: T_NONE, aux: 0, a: t.a, b: v, c: off as u32 }));
            }
            return NONE;
        }
        // Into the promoted destination: from the promoted source's fields, plain memory's loads, or
        // the fill's constants.
        let base = self.fat[cp.dslot as usize];
        for f2 in base..self.fat[cp.dslot as usize + 1] {
            let fl = self.flds[f2 as usize];
            if !in_range(fl, cp.doff, cp.size, self.ptr) {
                continue;
            }
            let rel = fl.off - cp.doff;
            let mut v = NONE;
            if sc {
                let sf = self.field_at(cp.sslot, cp.soff + rel, fl.ty);
                v = self.value(b, sf);
            } else if t.op == O_MEMCPY {
                v = (b.insts.len() + self.xins.len()) as u32;
                let (fx, bd) = self.bound_after(b, i, cp.dslot, fl);
                self.xins.push((i, Inst { op: O_LOAD, ty: fl.ty, aux: fx, a: t.b, b: bd, c: rel as u32 }));
            } else {
                let k = fill_const(fl.ty, cp.byte, self.ptr);
                if k.op != NO_CONST {
                    v = (b.insts.len() + self.xins.len()) as u32;
                    self.xins.push((i, k));
                } else if (cp.byte & 0xFF) == 0 {
                    v = self.zero(b, fl.ty);
                } else {
                    return cp.dslot;
                }
            }
            self.set(f2, v);
        }
        return NONE;
    }

    // The bound (`MEM_BOOL`, `MEM_RANGE`: flags and bound) of the load of slot `s`'s field `fl` right after
    // copy `i`, past constants, addresses and other loads only (at most AFTER_MAX): a read each run of the
    // copy reaches holds its type's values in the source's bytes too, which a read under a test of another
    // field does not (an `Ok` payload's, where the bytes may be an `Err`'s). (0, 0): none.
    fn bound_after(self: &Self, b: &Body, i: u32, s: u32, fl: Fld) (u16, u32) {
        let mut end = i + 1 + AFTER_MAX;
        if end > b.insts.len() as u32 {
            end = b.insts.len() as u32;
        }
        for x in i + 1..end {
            let t = b.insts[x as usize];
            if t.op == O_LOAD && t.ty == fl.ty && self.slot_of(t.a) == s && self.doff[t.a as usize] + (t.c as i32) as i64 == fl.off {
                let fx = t.aux & (MEM_BOOL | MEM_RANGE);
                return (
                    fx,
                    if (fx & MEM_RANGE) != 0 {
                        t.b
                    } else {
                        0
                    }
                );
            }
            if t.op != O_LOAD && t.op != O_ICONST && t.op != O_FCONST && t.op != O_SLOTADDR && t.op != O_PTRADD {
                break;
            }
        }
        return (0, 0);
    }

    // Spanning store `t` (instruction `i`) of an integer constant: each field it holds takes its bits.
    fn rename_cstore(self: &mut Self, b: &Body, i: u32, t: Inst) {
        let s = self.slot_of(t.a);
        let off = self.doff[t.a as usize] + (t.c as i32) as i64;
        let c = int_bits(b, t.b).unwrap();
        let n = size_of(b.type_of(t.b), self.ptr);
        for f2 in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f2 as usize];
            if !in_range(fl, off, n, self.ptr) {
                continue;
            }
            let fb = size_of(fl.ty, self.ptr);
            let mut x = c >> (8 * (fl.off - off)) as u64;
            if fb < 8 {
                x &= (1u64 << (8 * fb) as u64) - 1;
            }
            let k = bits_const(fl.ty, x);
            let v = self.push(b, i, k);
            self.set(f2, v);
        }
    }

    // Spanning store `t` (instruction `i`) of an integer value: each field it holds takes its bits, shifted
    // down and truncated (little-endian).
    fn rename_vstore(self: &mut Self, b: &Body, i: u32, t: Inst) {
        let s = self.slot_of(t.a);
        let off = self.doff[t.a as usize] + (t.c as i32) as i64;
        let ty = b.type_of(t.b);
        let n = size_of(ty, self.ptr);
        for f2 in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f2 as usize];
            if !in_range(fl, off, n, self.ptr) {
                continue;
            }
            let it = int_of(size_of(fl.ty, self.ptr));
            let sh = 8 * (fl.off - off) as u64;
            let mut v = t.b;
            if sh != 0 {
                let c = self.push(b, i, fill_int(ty, sh));
                v = self.push(b, i, Inst { op: O_LSHR, ty: ty, aux: 0, a: v, b: c, c: VNONE });
            }
            if it != ty {
                v = self.push(b, i, Inst { op: O_TRUNC, ty: it, aux: 0, a: v, b: VNONE, c: VNONE });
            }
            let fv = self.convert(b, i, v, it, fl.ty);
            self.set(f2, fv);
        }
    }

    // Spanning load `t` (instruction `i`): its fields' bits, each zero-extended and shifted to its place,
    // combined.
    fn rename_span(self: &mut Self, b: &Body, i: u32, t: Inst) {
        let s = self.slot_of(t.a);
        let off = self.doff[t.a as usize] + (t.c as i32) as i64;
        let n = size_of(t.ty, self.ptr);
        let mut acc = NONE;
        for f2 in self.fat[s as usize]..self.fat[s as usize + 1] {
            let fl = self.flds[f2 as usize];
            if !in_range(fl, off, n, self.ptr) {
                continue;
            }
            let it = int_of(size_of(fl.ty, self.ptr));
            let sh = 8 * (fl.off - off) as u64;
            let fv = self.value(b, f2);
            let mut v = self.convert(b, i, fv, fl.ty, it);
            if it != t.ty {
                v = self.push(b, i, Inst { op: O_ZEXT, ty: t.ty, aux: 0, a: v, b: VNONE, c: VNONE });
            }
            if sh != 0 {
                let c = self.push(b, i, fill_int(t.ty, sh));
                v = self.push(b, i, Inst { op: O_SHL, ty: t.ty, aux: 0, a: v, b: c, c: VNONE });
            }
            acc = if acc == NONE {
                v
            } else {
                self.push(b, i, Inst { op: O_OR, ty: t.ty, aux: 0, a: acc, b: v, c: VNONE })
            };
        }
        self.repl[i as usize] = if acc == NONE {
            self.zero(b, t.ty)
        } else {
            acc
        };
    }

    // New instruction `x` before instruction `i`: its value.
    fn push(self: &mut Self, b: &Body, i: u32, x: Inst) u32 {
        let v = (b.insts.len() + self.xins.len()) as u32;
        self.xins.push((i, x));
        return v;
    }

    // ---- Emission ------------------------------------------------------------------------------------

    // The new body: per block its parameters then its new ones, its instructions with the new ones before
    // the instruction they precede, the dropped ones left out; values, pool lists and edges renumbered;
    // the edges into blocks with new parameters rewritten with their arguments.
    fn emit(self: &mut Self, b: &Body, o: &mut Body) {
        let ni = b.insts.len();
        let nx = self.xins.len();
        let np0 = b.params.len();
        // The new instructions grouped by the instruction they precede, in their order.
        fill(&mut self.xat, ni + 1, 0);
        for q in 0..nx {
            self.xat[self.xins[q].0 as usize + 1] += 1;
        }
        for i in 0..ni {
            self.xat[i + 1] += self.xat[i];
        }
        fill(&mut self.xorder, nx, 0);
        fill(&mut self.work, ni, 0);
        for q in 0..nx {
            let at = self.xins[q].0 as usize;
            self.xorder[(self.xat[at] + self.work[at]) as usize] = q as u32;
            self.work[at] += 1;
        }
        // The numbering.
        fill(&mut self.cmap, ni + nx, NONE);
        fill(&mut self.pmap, np0 + self.phis.len(), NONE);
        let mut n: u32 = 0;
        let mut np: u32 = 0;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                self.pmap[q as usize] = np;
                np += 1;
            }
            for q in self.phi_at[k]..self.phi_at[k + 1] {
                self.pmap[np0 + q as usize] = np;
                np += 1;
            }
            if !self.reached[k] {
                n += 1; // its `unreachable`
                continue;
            }
            for i in bk.start..bk.start + bk.len {
                for x in self.xat[i as usize]..self.xat[i as usize + 1] {
                    self.cmap[ni + self.xorder[x as usize] as usize] = n;
                    n += 1;
                }
                if !self.drop[i as usize] {
                    self.cmap[i as usize] = n;
                    n += 1;
                }
            }
        }
        o.clear();
        o.pool.extend_copy(&b.pool);
        o.words.extend_copy(&b.words);
        o.words.extend_copy(&self.xwords);
        o.slots.extend_copy(&b.slots);
        // A merged slot's alignment: the larger of the two.
        for s in 0..b.slots.len() {
            let m = self.mslot[s];
            if m != NONE && b.slots[s].align_log2 > o.slots[m as usize].align_log2 {
                o.slots.index_mut(m as usize).align_log2 = b.slots[s].align_log2;
            }
        }
        o.syms.extend_copy(&b.syms);
        o.msgs.extend_copy(&b.msgs);
        o.lines.truncate(0);
        o.lines.extend_copy(&b.lines);
        o.sig = b.sig;
        o.refs.truncate(0);
        o.refs.extend_copy(&b.refs);
        o.owned.truncate(0);
        o.owned.extend_copy(&b.owned);
        o.bools = b.bools;
        o.fmath = b.fmath;
        // A scope's root: its replacement, renumbered; one in no reached block goes.
        o.scopes.truncate(0);
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            let v = self.val(sc.root);
            if v != VNONE {
                o.scopes.push(Scope { site: sc.site, group: sc.group, root: v });
            }
        }
        o.naked = b.naked;
        fill(&mut self.done, b.pool.len(), false);
        let inl = b.inl.len() != 0;
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            let start = o.insts.len() as u32;
            let ps = o.params.len() as u32;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                o.params.push(b.params[q as usize]);
            }
            for q in self.phi_at[k]..self.phi_at[k + 1] {
                o.params.push(self.flds[(self.phis[q as usize] as u32) as usize].ty);
            }
            if !self.reached[k] {
                // No edge of a reached block enters it; its own edges would lack the new arguments.
                o.insts.push(Inst { op: O_UNREACHABLE, ty: T_NONE, aux: 0, a: VNONE, b: VNONE, c: VNONE });
                o.locs.push(0);
                if inl {
                    o.inl.push(0);
                }
            }
            for i in bk.start..bk.start + bk.len {
                if !self.reached[k] {
                    break;
                }
                for x in self.xat[i as usize]..self.xat[i as usize + 1] {
                    let mut t = self.xins[self.xorder[x as usize] as usize].1;
                    let f = op_info(t.op).form;
                    if lv::operand_a(f) {
                        t.a = self.val(t.a);
                    }
                    if lv::operand_b(f) {
                        t.b = self.val(t.b);
                    }
                    o.insts.push(t);
                    o.locs.push(b.locs[i as usize]);
                    if inl {
                        o.inl.push(b.inl[i as usize]);
                    }
                }
                if self.drop[i as usize] {
                    continue;
                }
                let t = self.inst(b, k as u32, b.insts[i as usize], o);
                o.insts.push(t);
                o.locs.push(b.locs[i as usize]);
                if inl {
                    o.inl.push(b.inl[i as usize]);
                }
            }
            o.blocks.push(
                Block {
                    start: start,
                    len: o.insts.len() as u32 - start,
                    param_start: ps,
                    param_len: (o.params.len() as u32 - ps) as u16,
                    flags: bk.flags,
                },
            );
        }
    }

    // The new number of value `v` (a promoted load's: its replacement's, followed to the end).
    fn val(self: &mut Self, v0: Value) Value {
        let mut v = v0;
        // Each step follows one promoted load: at most every instruction.
        for _ in 0..self.repl.len() + 1 {
            if v == VNONE {
                return v;
            }
            if (v & VPARAM) != 0 {
                return VPARAM | self.pmap[(v & ~VPARAM) as usize];
            }
            let x = (v & ~VFLAG) as usize;
            if x < self.repl.len() && self.repl[x] != NONE {
                v = self.repl[x];
                continue;
            }
            return self.cmap[x] | v & VFLAG;
        }
        assert(false, "promote: a cycle of replaced loads");
        return VNONE;
    }

    // Instruction `t0` of `b` with its values, pool lists and edges renumbered.
    fn inst(self: &mut Self, b: &Body, k: u32, t0: Inst, o: &mut Body) Inst {
        let mut t = t0;
        let f = op_info(t.op).form;
        if t.op == O_SLOTADDR && self.mslot[t.a as usize] != NONE {
            t.a = self.mslot[t.a as usize];
        }
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
                self.pval(o, t.c + q);
            }
        } else if f == F_VOP || f == F_ASM {
            for q in 0..t.b {
                self.pval(o, t.a + q);
            }
        }
        if f == F_JMP {
            t.a = self.edge(b, k, o, t.a);
        } else if f == F_BR {
            t.b = self.edge(b, k, o, t.b);
            t.c = self.edge(b, k, o, t.c);
        } else if f == F_SWITCH {
            for q in 0..t.aux as u32 + 1 {
                let at = (t.c + q) as usize;
                if !self.done[at] {
                    self.done[at] = true;
                    o.pool[at] = self.edge(b, k, o, b.pool[at]);
                }
            }
        }
        return t;
    }

    fn pval(self: &mut Self, o: &mut Body, at: u32) {
        if !self.done[at as usize] {
            self.done[at as usize] = true;
            o.pool[at as usize] = self.val(o.pool[at as usize]);
        }
    }

    // Edge `e` of block `k` of `b` in `o`: its arguments renumbered, and when its target takes new
    // parameters a new record with their arguments too.
    fn edge(self: &mut Self, b: &Body, k: u32, o: &mut Body, e: u32) u32 {
        let tk = b.edge_target(e);
        let na = b.edge_nargs(e);
        let extra = switch self.eargs.get(&(k as u64 << 32 | e as u64)) {
            Some(x) => *x,
            None => NONE,
        };
        if extra == NONE {
            if !self.done[e as usize] {
                self.done[e as usize] = true;
                for q in 0..na {
                    self.pval(o, e + 2 + q);
                }
            }
            return e;
        }
        let nphi = self.phi_at[tk as usize + 1] - self.phi_at[tk as usize];
        let at = o.pool.len() as u32;
        o.pool.push(tk);
        o.pool.push(na + nphi);
        for q in 0..na {
            o.pool.push(self.val(b.edge_arg(e, q)));
        }
        for q in 0..nphi {
            o.pool.push(self.val(self.evals[(extra + q) as usize]));
        }
        return at;
    }
}

// W_LOAD for a load of type `ty` that may span fields or read part of a wider one, an integer of 1 to 8
// bytes; else 0.
const fn wide_kind(ty: u8) u8 {
    return if is_int(ty) && ty != T_PTR && ty != T_I128 {
        W_LOAD
    } else {
        0
    };
}

// The integer type of `n` bytes (1, 2, 4 or 8).
const fn int_of(n: i64) u8 {
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

// The integer constant `v` of type `ty`.
const fn fill_int(ty: u8, v: u64) Inst {
    return Inst { op: O_ICONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE };
}

// `conv_op`'s answer when no conversion exists.
const NO_CONV: u8 = 0xFF;

// The conversion of a value of type `from` to type `to` of its size, pointers of `ptr` bytes: none (0),
// a bitcast, or a pointer conversion; NO_CONV when none is.
const fn conv_op(from: u8, to: u8, ptr: u32) u8 {
    if from == to {
        return 0;
    }
    if type_bytes(from, ptr) != type_bytes(to, ptr) {
        return NO_CONV;
    }
    if from == T_PTR && is_int(to) {
        return O_PTRTOINT;
    }
    if is_int(from) && to == T_PTR {
        return O_INTTOPTR;
    }
    if from == T_PTR || to == T_PTR {
        return NO_CONV;
    }
    return O_BITCAST;
}

// Whether field `f` lies in bytes `off` to `off + n`, pointers of `ptr` bytes.
const fn in_range(f: Fld, off: i64, n: i64, ptr: u32) bool {
    return f.off >= off && f.off + size_of(f.ty, ptr) <= off + n;
}

const fn size_of(ty: u8, ptr: u32) i64 {
    return type_bytes(ty, ptr);
}

// The integer constant `v` is (sign-extended from its type), or -1 when it is none or negative.
const fn const_int(b: &Body, v: Value) i64 {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST {
        return -1;
    }
    let t = b.insts[v as usize];
    let x = t.b as u64 << 32 | t.a as u64;
    return if x > 0x7FFFFFFFFFFFFFFF {
        -1i64
    } else {
        x as i64
    };
}

// `fill_const`'s answer when no constant has the type.
const NO_CONST: u8 = 0;

// The constant of type `ty` whose every byte is `byte` (a fill's), pointers of `ptr` bytes; NO_CONST when
// no constant has the type.
const fn fill_const(ty: u8, byte: u64, ptr: u32) Inst {
    let n = type_bytes(ty, ptr);
    let mut x: u64 = 0;
    for _ in 0..n {
        x = x << 8 | byte & 0xFF;
    }
    if is_int(ty) && ty != T_I128 || ty == T_PTR {
        return Inst { op: O_ICONST, ty: ty, aux: 0, a: x as u32, b: (x >> 32) as u32, c: VNONE };
    }
    if ty == T_F64 || ty == T_F32 {
        return Inst { op: O_FCONST, ty: ty, aux: 0, a: x as u32, b: (x >> 32) as u32, c: VNONE };
    }
    return Inst { op: NO_CONST, ty: T_NONE, aux: 0, a: 0, b: 0, c: 0 };
}

// The bits of integer constant `v` of `b`, None when it is no constant.
const fn int_bits(b: &Body, v: Value) Option<u64> {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST {
        return None;
    }
    let t = b.insts[v as usize];
    return Some(t.b as u64 << 32 | t.a as u64);
}

// A constant of scalar type `ty` (an integer, a pointer or a float) of bits `x`.
const fn bits_const(ty: u8, x: u64) Inst {
    return Inst {
        op: if is_float(ty) {
            O_FCONST
        } else {
            O_ICONST
        },
        ty: ty,
        aux: 0,
        a: x as u32,
        b: (x >> 32) as u32,
        c: VNONE,
    };
}

// `v[lo .. hi]` by offset (insertion sort: a slot has few accesses).
// Whether access `x` is a lane of vector field `v`: of its lane type, at a lane's offset within it.
const fn is_lane(v: Fld, x: Fld) bool {
    if !is_vec(v.ty) || is_vec(x.ty) || x.ty != lane_type(v.ty) {
        return false;
    }
    let eb = type_bytes(x.ty, 8) as i64;
    return x.off >= v.off && x.off < v.off + type_bytes(v.ty, 8) as i64 && (x.off - v.off) % eb == 0;
}

const fn sort_fields(v: &mut Vector<Fld>, lo: usize, hi: usize) {
    for i in lo + 1..hi {
        let x = v[i];
        let mut j = i;
        while j > lo && (v[j - 1].off > x.off || v[j - 1].off == x.off && v[j - 1].ty > x.ty) {
            v[j] = v[j - 1];
            j -= 1;
        }
        v[j] = x;
    }
}
