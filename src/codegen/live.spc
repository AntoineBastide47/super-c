// The analysis pass of the native backends (after TPDE, Schwarz, Kamm and Engelke 2025): one walk over a
// LIR body gives the block layout, the loop nesting and each value's live range and use count, which the
// code generation pass reads to allocate registers in one pass.
//
// Layout: reverse postorder, each loop contiguous (a block's key is the list of its loop headers'
// positions, then its own, compared in order), a loop's cold blocks after its warm ones, the other cold
// blocks last. A value's range is the layout positions from its definition's block to `end`: its last
// use, or the last block of the outermost loop that holds a use but not the definition (the value must
// survive the back edge). The CFG is reducible (the verifier checks it), so an edge to a block not later
// in reverse postorder is a back edge.
import lir::ir as *;
import lir::verify as lv;
import ir::core as core;

/// `Live::plan`'s homes per value: no register for the whole range, a callee-saved one, a caller-saved one.
pub const HOME_NONE: u8 = 0;
pub const HOME_CALLEE: u8 = 1;
pub const HOME_SCRATCH: u8 = 2;
/// `Live::plan`'s request per value: it may take a callee-saved register, a caller-saved one; it is of the
/// vector file (else the general one).
pub const WANT_CALLEE: u8 = 1;
pub const WANT_SCRATCH: u8 = 2;
pub const WANT_V: u8 = 4;

/// The registers `Live::plan` gives out at once per file (`x`: general, `v`: vector): callee-saved,
/// caller-saved, and both together.
pub struct Caps {
    pub xc: u32,
    pub xs: u32,
    pub xj: u32,
    pub vc: u32,
    pub vs: u32,
    pub vj: u32,
}

extend Caps as Copy {}

/// The analysis of one body. Values index `insts` first, then `params`, then the overflow flags that have
/// a use (`flag_of`).
pub struct Live {
    pub order: Vector<u32>, // the blocks in layout order
    pub pos: Vector<u32>, // per block, its layout position
    pub npred: Vector<u32>, // per block, its predecessor count (an edge each)
    pub inner: Vector<u32>, // per block, the header of its innermost loop, NONE outside loops
    pub lend: Vector<u32>, // per loop header, the layout position of the loop's last block
    pub parent: Vector<u32>, // per loop header, the header of the loop around it, NONE
    pub def_blk: Vector<u32>, // per value, its block
    pub end: Vector<u32>, // per value, the last layout position it is live in
    pub uses: Vector<u32>, // per value, its use count, one more when a loop keeps it past its last use
    pub last: Vector<u32>, // per value, the highest instruction index that uses it (0: none)
    pub flag_of: Map<u32, u32>, // an instruction with a used flag -> the flag's value index
    pub home: Vector<u8>, // per value, its HOME_* (`plan`)
    /// The largest access a scaled index addresses (the target's, 0: none); per instruction, whether the
    /// load or store takes its address `ptradd`'s operands (`fold`), and whether the `ptradd` emits nothing
    /// for that (`pfold`; `uses_at`).
    pub fold_max: u32,
    pub fold: Vector<bool>,
    pub pfold: Vector<bool>,
    // `plan`'s scratch: per layout position its first instruction's ordinal; per block its frequency; per
    // value its range's first and last ordinals, its weight and its uses by instructions and edges; the
    // candidates by start, the values holding a register, and the count per file and home.
    base: Vector<u32>,
    freq: Vector<u64>,
    start: Vector<u32>,
    stop: Vector<u32>,
    wt: Vector<u64>,
    au: Vector<u32>,
    cand: Vector<u64>,
    act: Vector<u32>,
    cnt: Vector<u32>,
    rpo: Vector<u32>, // per block, its reverse postorder number (NONE: unreachable)
    succ: Vector<u32>,
    stack: Vector<u32>,
    work: Vector<u32>,
    keys: Vector<u64>,
    rd: Vector<Value>, // `reads_after`'s scratch
}

extend Live {
    pub fn new() Live {
        return Live {
            order: Vector::<u32>::new(),
            pos: Vector::<u32>::new(),
            npred: Vector::<u32>::new(),
            inner: Vector::<u32>::new(),
            lend: Vector::<u32>::new(),
            parent: Vector::<u32>::new(),
            def_blk: Vector::<u32>::new(),
            end: Vector::<u32>::new(),
            uses: Vector::<u32>::new(),
            last: Vector::<u32>::new(),
            flag_of: Map::<u32, u32>::new(),
            home: Vector::<u8>::new(),
            fold_max: 0,
            fold: Vector::<bool>::new(),
            pfold: Vector::<bool>::new(),
            base: Vector::<u32>::new(),
            freq: Vector::<u64>::new(),
            start: Vector::<u32>::new(),
            stop: Vector::<u32>::new(),
            wt: Vector::<u64>::new(),
            au: Vector::<u32>::new(),
            cand: Vector::<u64>::new(),
            act: Vector::<u32>::new(),
            cnt: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            stack: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            keys: Vector::<u64>::new(),
            rd: Vector::<Value>::new(),
        };
    }

    /// The value index of `v`.
    pub const fn vix(self: &Self, b: &Body, v: Value) u32 {
        if (v & VPARAM) != 0 {
            return b.insts.len() as u32 + (v & ~VPARAM);
        }
        if (v & VFLAG) != 0 {
            return switch self.flag_of.get(&(v & ~VFLAG)) {
                Some(k) => *k,
                None => NONE,
            };
        }
        return v;
    }

    /// Analyze `b`.
    pub fn run(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.npred, nb, 0);
        fill(&mut self.rpo, nb, NONE);
        fill(&mut self.inner, nb, NONE);
        fill(&mut self.lend, nb, 0);
        fill(&mut self.parent, nb, NONE);
        fill(&mut self.pos, nb, NONE);
        for k in 0..nb {
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                self.npred[b.edge_target(self.succ[e]) as usize] += 1;
            }
        }
        self.reverse_postorder(b);
        self.loops(b);
        self.layout(b);
        self.folds(b);
        self.ranges(b);
    }

    // `fold`: a load or store of no offset whose address is a `ptradd` with an index, no offset, a scale
    // of 1 or the access's size (up to `fold_max`) and this one use, takes the `ptradd`'s operands as its
    // address (`ldr x0, [x1, x2, lsl #3]`, `mov (%rax,%rcx,8), %rdx`): they live to the access.
    fn folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.fold.truncate(0);
        self.fold.resize_default(ni);
        self.pfold.truncate(0);
        self.pfold.resize_default(ni);
        if self.fold_max == 0 {
            return;
        }
        // The use count of each `ptradd` with an index.
        fill(&mut self.work, ni, 0);
        for i in 0..ni {
            each_use(b, b.insts[i], &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_PTRADD {
                    self.work[v as usize] += 1;
                }
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            if t.op != O_LOAD && t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || t.c != 0 || (t.a & (VPARAM | VFLAG)) != 0 {
                continue;
            }
            let p = b.insts[t.a as usize];
            let ty = if t.op == O_LOAD {
                t.ty;
            } else {
                b.type_of(t.b);
            };
            let n = type_bytes(ty, 8); // the targets that fold have 8-byte pointers
            let sc = p.aux as u32;
            // A vector of 8 or 16 bytes lives in a register; another is memory.
            let reg = !is_vec(ty) && ty != T_I128 || n == 8 || n == 16;
            self.fold[i] = p.op == O_PTRADD && p.b != VNONE && p.c == 0 && self.work[t.a as usize] == 1 && reg && (sc == 1 || sc == n && n <= self.fold_max);
            if self.fold[i] {
                self.pfold[t.a as usize] = true;
            }
        }
    }

    // `uses_at` into `succ`.
    fn uses_into(self: &mut Self, b: &Body, i: u32) {
        let mut out = replace(&mut self.succ, Vector::<u32>::new());
        self.uses_at(b, i, &mut out);
        self.succ = out;
    }

    /// The value index of a parameter that a back edge of terminator `t` (of the block at layout position
    /// `pos`) passes value `v` to (an edge into a loop header not later in the layout); NONE for none. A
    /// branch's other edge must leave the loop, and the parameter must not live past the loop: no path
    /// from `t` reads the parameter but through its block, which defines it again.
    pub fn back_param(self: &Self, b: &Body, t: Inst, v: Value, pos: u32) u32 {
        let ne: u32 = if t.op == O_JMP {
            1;
        } else if t.op == O_BR {
            2;
        } else {
            0;
        };
        for e in 0..ne {
            let x = edge_of(b, t, e);
            let tk = b.edge_target(x);
            if self.pos[tk as usize] > pos {
                continue;
            }
            let tb = b.blocks[tk as usize];
            for q in 0..b.edge_nargs(x) {
                if b.edge_arg(x, q) != v {
                    continue;
                }
                let px = b.insts.len() as u32 + tb.param_start + q;
                if ne == 2 {
                    let o = self.pos[b.edge_target(edge_of(b, t, 1 - e)) as usize];
                    if self.lend[tk as usize] == NONE || o >= self.pos[tk as usize] && o <= self.lend[tk as usize] || self.end[px as usize] > self.lend[tk as usize] {
                        return NONE;
                    }
                }
                return px;
            }
        }
        return NONE;
    }

    /// Whether an instruction of block `k` of `b` after instruction `i`, its terminator's edges included,
    /// reads value `v`.
    pub fn reads_after(self: &mut Self, b: &Body, k: u32, i: u32, v: Value) bool {
        let bk = b.blocks[k as usize];
        let mut out = replace(&mut self.rd, Vector::<Value>::new());
        let mut found = false;
        for j in i + 1..bk.start + bk.len {
            self.uses_at(b, j, &mut out);
            for u in 0..out.len() {
                found = found || out[u] == v;
            }
            if found {
                break;
            }
        }
        self.rd = out;
        return found;
    }

    /// The values instruction `i` of `b` uses, as `each_use` gives them but for the folded addresses
    /// (`fold`): a load or store that folds one uses its `ptradd`'s operands, which uses none.
    pub fn uses_at(self: &Self, b: &Body, i: u32, out: &mut Vector<Value>) {
        if self.pfold[i as usize] {
            out.truncate(0);
            return;
        }
        let t = b.insts[i as usize];
        each_use(b, t, out);
        if !self.fold[i as usize] {
            return;
        }
        for u in 0..out.len() {
            if out[u] == t.a {
                out.swap_remove(u);
                break;
            }
        }
        let p = b.insts[t.a as usize];
        out.push(p.a);
        out.push(p.b);
    }

    // `rpo`: the reverse postorder number of each block the entry reaches, by an explicit-stack DFS
    // (`stack` holds block << 1 | finished). A block is visited when popped, so it may be pushed once
    // per edge into it.
    fn reverse_postorder(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        self.work.truncate(0); // postorder
        self.stack.truncate(0);
        self.stack.push(0);
        // Each pop finishes a block, visits one, or drops an edge's repeat: at most 2 per block and 1 per edge.
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = x >> 1;
            if (x & 1) != 0 {
                self.work.push(k);
                continue;
            }
            if seen[k as usize] {
                continue;
            }
            seen[k as usize] = true;
            self.stack.push(k << 1 | 1);
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            // Pushed in reverse, so the first successor is visited first.
            let mut e = self.succ.len();
            while e > 0 {
                e -= 1;
                let s = b.edge_target(self.succ[e]);
                if !seen[s as usize] {
                    self.stack.push(s << 1);
                }
            }
        }
        let n = self.work.len() as u32;
        for i in 0..self.work.len() {
            self.rpo[self.work[i] as usize] = n - 1 - i as u32;
        }
    }

    // Natural loops: an edge to a block whose number is not above its source's is a back edge to a loop
    // header; the loop is what reaches a back edge's source without passing the header. Headers are
    // taken innermost first (highest number first), so a block's first loop is its innermost and a
    // header's first enclosing loop its parent.
    fn loops(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // Predecessor lists (CSR): `keys` holds the starts, `work` the sources.
        let mut start = Vector::<u32>::with_capacity(nb + 1);
        let mut acc: u32 = 0;
        for k in 0..nb {
            start.push(acc);
            acc += self.npred[k];
        }
        start.push(acc);
        let mut fillp = Vector::<u32>::with_capacity(nb);
        fillp.extend_copy(&start);
        let mut preds = Vector::<u32>::new();
        preds.resize_default(acc as usize);
        let mut hdrs = Vector::<u64>::new();
        for k in 0..nb {
            if self.rpo[k] == NONE {
                continue;
            }
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                preds[fillp[s as usize] as usize] = k as u32;
                fillp[s as usize] += 1;
                if self.rpo[s as usize] <= self.rpo[k] {
                    hdrs.push(self.rpo[s as usize] as u64 << 32 | s as u64);
                }
            }
        }
        hdrs.sort();
        hdrs.dedup();
        let mut mark = Vector::<u32>::new();
        fill(&mut mark, nb, NONE);
        let mut i = hdrs.len();
        while i > 0 {
            i -= 1;
            let h = hdrs[i] as u32;
            // The loop of `h`: from the back edges' sources backward to `h`.
            self.stack.truncate(0);
            mark[h as usize] = h;
            for q in start[h as usize]..start[h as usize + 1] {
                let p = preds[q as usize];
                if self.rpo[p as usize] >= self.rpo[h as usize] && mark[p as usize] != h {
                    mark[p as usize] = h;
                    self.stack.push(p);
                }
            }
            if self.inner[h as usize] == NONE {
                self.inner[h as usize] = h;
            }
            // Each block enters the stack once per loop.
            while self.stack.len() != 0 {
                let x = self.stack.pop().unwrap();
                if self.inner[x as usize] == NONE {
                    self.inner[x as usize] = h;
                } else if self.inner[x as usize] == x && self.parent[x as usize] == NONE && x != h {
                    self.parent[x as usize] = h;
                }
                for q in start[x as usize]..start[x as usize + 1] {
                    let p = preds[q as usize];
                    if self.rpo[p as usize] != NONE && mark[p as usize] != h {
                        mark[p as usize] = h;
                        self.stack.push(p);
                    }
                }
            }
        }
    }

    // `order` and `pos`: the reachable warm blocks in reverse postorder, where a loop header brings its
    // whole loop (its members in reverse postorder, nested loops likewise); then the cold blocks.
    fn layout(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // The warm blocks in reverse postorder.
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rpo[k] != NONE && (b.blocks[k].flags & BLOCK_COLD) == 0 {
                self.keys.push(self.rpo[k] as u64 << 32 | k as u64);
            }
        }
        self.keys.sort();
        // Each loop's members in reverse postorder (CSR by header): `mstart[h]..mstart[h] + mlen[h]`.
        let mut mlen = Vector::<u32>::new();
        fill(&mut mlen, nb, 0);
        for i in 0..self.keys.len() {
            let mut h = self.inner[(self.keys[i] as u32) as usize];
            while h != NONE {
                mlen[h as usize] += 1;
                h = self.parent[h as usize];
            }
        }
        let mut mstart = Vector::<u32>::with_capacity(nb);
        let mut acc: u32 = 0;
        for k in 0..nb {
            mstart.push(acc);
            acc += mlen[k];
            mlen[k] = 0;
        }
        let mut mlist = Vector::<u32>::new();
        mlist.resize_default(acc as usize);
        for i in 0..self.keys.len() {
            let k = self.keys[i] as u32;
            let mut h = self.inner[k as usize];
            while h != NONE {
                mlist[(mstart[h as usize] + mlen[h as usize]) as usize] = k;
                mlen[h as usize] += 1;
                h = self.parent[h as usize];
            }
        }
        // A stack of lists being walked: list (NONE the whole body, else a header) << 32 | next index.
        self.order.truncate(0);
        let mut placed = Vector::<bool>::new();
        placed.resize_default(nb);
        self.stack.truncate(0);
        let mut lists = Vector::<u64>::new();
        lists.push(NONE as u64 << 32);
        // Each step places a block, opens a loop once, or closes a list: at most 3 per block.
        while lists.len() != 0 {
            let top = lists.len() - 1;
            let l = (lists[top] >> 32) as u32;
            let i = lists[top] as u32;
            let n = if l == NONE {
                self.keys.len() as u32;
            } else {
                mlen[l as usize];
            };
            if i == n {
                let _ = lists.pop();
                continue;
            }
            lists[top] = lists[top] + 1;
            let k = if l == NONE {
                self.keys[i as usize] as u32;
            } else {
                mlist[(mstart[l as usize] + i) as usize];
            };
            if placed[k as usize] {
                continue;
            }
            if self.inner[k as usize] == k && l != k {
                lists.push(k as u64 << 32);
                continue;
            }
            placed[k as usize] = true;
            self.order.push(k);
        }
        // The cold blocks in reverse postorder: one of a loop with a warm header right after the loop's last
        // warm block (the loop stays contiguous, and the values live at a block it enters live no
        // further), the others last.
        self.loop_ends();
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rpo[k] != NONE && (b.blocks[k].flags & BLOCK_COLD) != 0 {
                self.keys.push(self.rpo[k] as u64 << 32 | k as u64);
            }
        }
        self.keys.sort();
        let mut tail = Vector::<u64>::new();
        for j in 0..self.keys.len() {
            let h = self.inner[(self.keys[j] as u32) as usize];
            if h != NONE && (b.blocks[h as usize].flags & BLOCK_COLD) == 0 {
                tail.push(self.lend[h as usize] as u64 << 32 | j as u64);
            }
        }
        tail.sort();
        let warm = self.order.len();
        let mut out = Vector::<u32>::with_capacity(warm + self.keys.len());
        let mut t: usize = 0;
        for i in 0..warm {
            out.push(self.order[i]);
            while t < tail.len() && (tail[t] >> 32) as usize == i {
                out.push(self.keys[(tail[t] as u32) as usize] as u32);
                t += 1;
            }
        }
        for j in 0..self.keys.len() {
            let h = self.inner[(self.keys[j] as u32) as usize];
            if h == NONE || (b.blocks[h as usize].flags & BLOCK_COLD) != 0 {
                out.push(self.keys[j] as u32);
            }
        }
        self.order = out;
        for i in 0..self.order.len() {
            self.pos[self.order[i] as usize] = i as u32;
        }
        fill(&mut self.lend, nb, 0);
        self.loop_ends();
    }

    // `lend`: each loop's last block in `order`.
    const fn loop_ends(self: &mut Self) {
        for i in 0..self.order.len() {
            let k = self.order[i];
            let mut h = self.inner[k as usize];
            // At most one step per enclosing loop.
            while h != NONE {
                if self.lend[h as usize] < i as u32 {
                    self.lend[h as usize] = i as u32;
                }
                h = self.parent[h as usize];
            }
        }
    }

    // Per value: its block, live range end and use count.
    fn ranges(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        self.flag_of.clear();
        // The flags with a use get indexes after the parameters; `work` lists their instructions.
        let mut nf: u32 = 0;
        self.work.truncate(0);
        for k in 0..ni {
            let t = b.insts[k];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == VFLAG && !self.flag_of.contains_key(&(v & ~VFLAG)) {
                    self.flag_of.insert(v & ~VFLAG, nv as u32 + nf);
                    self.work.push(v & ~VFLAG);
                    nf += 1;
                }
            }
        }
        let n = nv + nf as usize;
        fill(&mut self.def_blk, n, NONE);
        fill(&mut self.end, n, 0);
        fill(&mut self.uses, n, 0);
        fill(&mut self.last, n, 0);
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.def_blk[i as usize] = k as u32;
            }
            for q in 0..bk.param_len as u32 {
                self.def_blk[ni + (bk.param_start + q) as usize] = k as u32;
            }
        }
        for f in 0..nf as usize {
            self.def_blk[nv + f] = self.def_blk[self.work[f] as usize];
        }
        for v in 0..n {
            if self.def_blk[v] != NONE && self.pos[self.def_blk[v] as usize] != NONE {
                self.end[v] = self.pos[self.def_blk[v] as usize];
            }
        }
        // The values a loop keeps (`kept`): the back edge, past their last use, reads them again.
        let mut kept = Vector::<bool>::new();
        kept.resize_default(n);
        for p in 0..self.order.len() {
            let k = self.order[p];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                self.uses_into(b, i);
                for u in 0..self.succ.len() {
                    let x = self.vix(b, self.succ[u]);
                    self.uses[x as usize] += 1;
                    if i > self.last[x as usize] {
                        self.last[x as usize] = i;
                    }
                    let mut e = p as u32;
                    // A use in a loop the definition is outside of keeps the value to the loop's end.
                    let dp = self.pos[self.def_blk[x as usize] as usize];
                    let mut h = self.inner[k as usize];
                    while h != NONE && !(self.pos[h as usize] <= dp && dp <= self.lend[h as usize]) {
                        e = self.lend[h as usize];
                        h = self.parent[h as usize];
                        kept[x as usize] = true;
                    }
                    if e > self.end[x as usize] {
                        self.end[x as usize] = e;
                    }
                }
            }
            // An edge writes its target's parameters: one use of each (`each_edge_param`), and they keep
            // their homes to the last edge into them, which a back edge's source writes after the layout
            // passed their block.
            let t = b.insts[(bk.start + bk.len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let sb = b.blocks[b.edge_target(self.succ[e]) as usize];
                for q in 0..sb.param_len as u32 {
                    let x = ni + (sb.param_start + q) as usize;
                    self.uses[x] += 1;
                    if p as u32 > self.end[x] {
                        self.end[x] = p as u32;
                    }
                }
            }
        }
        self.cold_entries(b, &mut kept);
        // One more use, which no instruction makes: a kept value lives to the end of its last block.
        for x in 0..n {
            if kept[x] {
                self.uses[x] += 1;
            }
        }
    }
}

extend Live {
    /// Per instruction of `b` into `out`: whether it is a float constant a loop block uses that lives past
    /// its block. No instruction takes a float as an immediate, so recomputing one at each use costs one to
    /// five instructions per iteration: a generator asks a register for its whole range instead. After
    /// `run`.
    pub fn loop_fconsts(self: &mut Self, b: &Body, out: &mut Vector<bool>) {
        out.truncate(0);
        out.resize_default(b.insts.len());
        let mut us = replace(&mut self.succ, Vector::<u32>::new());
        for k in 0..b.blocks.len() {
            if self.inner[k] == NONE || self.pos[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                self.uses_at(b, i, &mut us);
                for u in 0..us.len() {
                    let v = us[u];
                    if (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_FCONST {
                        let d = self.def_blk[v as usize];
                        out[v as usize] = out[v as usize] || self.end[v as usize] > self.pos[d as usize];
                    }
                }
            }
        }
        self.succ = us;
    }

    /// Plan which values hold one register for their whole range (`home`): the ones `want` (WANT_* per
    /// value) asks one for, by a linear scan over the layout in the order the ranges start (Poletto and
    /// Sarkar's); when a file's registers are taken, the active value of least weight (the frequency of
    /// its definition and uses: 8 per loop level up to 5, 0 in a cold block) gives its register up to a
    /// heavier one. A range runs from its definition (a parameter's: the first edge into it) to its last
    /// use (a kept value's, a parameter's or a flag's: the end of its last block). After `run`, before the
    /// generator counts the uses down.
    pub fn plan(self: &mut Self, b: &Body, want: &Vector<u8>, caps: Caps) {
        let n = self.end.len();
        let ni = b.insts.len();
        let nv = ni + b.params.len();
        let np = self.order.len();
        self.home.truncate(0);
        self.home.resize_default(n);
        fill(&mut self.base, np + 1, 0);
        for p in 0..np {
            self.base[p + 1] = self.base[p] + b.blocks[self.order[p] as usize].len;
        }
        self.freq.truncate(0);
        self.freq.resize_default(b.blocks.len());
        for p in 0..np {
            let k = self.order[p] as usize;
            if (b.blocks[k].flags & BLOCK_COLD) != 0 {
                continue;
            }
            let mut f: u64 = 1;
            let mut h = self.inner[k];
            // Each step leaves one loop, at most 5.
            for _ in 0..5 {
                if h == NONE {
                    break;
                }
                f *= 8;
                h = self.parent[h as usize];
            }
            self.freq[k] = f;
        }
        fill(&mut self.start, n, NONE);
        fill(&mut self.stop, n, 0);
        fill(&mut self.au, n, 0);
        self.wt.truncate(0);
        self.wt.resize_default(n);
        for p in 0..np {
            let k = self.order[p];
            let bk = b.blocks[k as usize];
            let f = self.freq[k as usize];
            for q in 0..bk.param_len as u32 {
                let x = ni + (bk.param_start + q) as usize;
                if self.base[p] < self.start[x] {
                    self.start[x] = self.base[p];
                }
            }
            for i in bk.start..bk.start + bk.len {
                self.start[i as usize] = self.base[p] + i - bk.start;
                self.wt[i as usize] += f;
                self.uses_into(b, i);
                for u in 0..self.succ.len() {
                    let x = self.vix(b, self.succ[u]) as usize;
                    self.wt[x] += f;
                    self.au[x] += 1;
                }
            }
            // The terminator's edges write their targets' parameters.
            let o = self.base[p + 1] - 1;
            each_edge_param(b, b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
            for q in 0..self.succ.len() {
                let x = self.succ[q] as usize;
                self.wt[x] += f;
                self.au[x] += 1;
                if o < self.start[x] {
                    self.start[x] = o;
                }
            }
        }
        for x in 0..n {
            let d = self.def_blk[x];
            if d == NONE || self.pos[d as usize] == NONE {
                self.start[x] = NONE;
                continue;
            }
            if x >= nv {
                self.start[x] = self.base[self.pos[d as usize] as usize];
            }
            let e = self.end[x] as usize;
            let l = self.last[x];
            self.stop[x] = if x < ni && self.au[x] != 0 && self.uses[x] == self.au[x] && self.pos[self.def_blk[l as usize] as usize] == e as u32 {
                self.base[e] + l - b.blocks[self.def_blk[l as usize] as usize].start;
            } else {
                self.base[e + 1] - 1;
            };
        }
        self.cand.truncate(0);
        for x in 0..n {
            if (want[x] & (WANT_CALLEE | WANT_SCRATCH)) != 0 && self.start[x] != NONE && self.au[x] != 0 {
                self.cand.push(self.start[x] as u64 << 32 | x as u64);
            }
        }
        self.cand.sort();
        self.act.truncate(0);
        fill(&mut self.cnt, 4, 0);
        for c in 0..self.cand.len() {
            let x = (self.cand[c] & 0xFFFFFFFF) as u32;
            let s = (self.cand[c] >> 32) as u32;
            // The ranges that ended before this one starts give their registers back.
            let mut j: usize = 0;
            while j < self.act.len() {
                let a = self.act[j];
                if self.stop[a as usize] < s {
                    self.leave(j, want);
                } else {
                    j += 1;
                }
            }
            let mut h = self.fits(x, want, caps, NONE);
            if h == HOME_NONE {
                // The lightest value of the file that holds a register this one could take.
                let mut v: usize = NONE as usize;
                for j in 0..self.act.len() {
                    let a = self.act[j];
                    if (want[a as usize] & WANT_V) != (want[x as usize] & WANT_V) || self.wt[a as usize] >= self.wt[x as usize] {
                        continue;
                    }
                    if v != NONE as usize && self.wt[a as usize] >= self.wt[self.act[v] as usize] {
                        continue;
                    }
                    if self.fits(x, want, caps, a) != HOME_NONE {
                        v = j;
                    }
                }
                if v != NONE as usize {
                    let a = self.act[v];
                    self.leave(v, want);
                    self.home[a as usize] = HOME_NONE;
                    h = self.fits(x, want, caps, NONE);
                }
            }
            if h != HOME_NONE {
                self.home[x as usize] = h;
                self.cnt[Live::slot(want[x as usize], h)] += 1;
                self.act.push(x);
            }
        }
    }

    // The home value `x` takes with `want`'s request among the registers taken (`cnt`), those of value
    // `without` given back: a caller-saved one first; HOME_NONE when its file has none to give.
    const fn fits(self: &Self, x: u32, want: &Vector<u8>, caps: Caps, without: u32) u8 {
        let w = want[x as usize];
        let vf = (w & WANT_V) != 0;
        let mut c = self.cnt[Live::slot(w, HOME_CALLEE)];
        let mut s = self.cnt[Live::slot(w, HOME_SCRATCH)];
        if without != NONE {
            if self.home[without as usize] == HOME_CALLEE {
                c -= 1;
            } else {
                s -= 1;
            }
        }
        let (cc, sc, jc) = if vf {
            (caps.vc, caps.vs, caps.vj);
        } else {
            (caps.xc, caps.xs, caps.xj);
        };
        if c + s >= jc {
            return HOME_NONE;
        }
        if (w & WANT_SCRATCH) != 0 && s < sc {
            return HOME_SCRATCH;
        }
        if (w & WANT_CALLEE) != 0 && c < cc {
            return HOME_CALLEE;
        }
        return HOME_NONE;
    }

    // `cnt`'s entry of the file of request `w` and home `h`.
    const fn slot(w: u8, h: u8) usize {
        return ((w & WANT_V) != 0) as usize * 2 + (h - 1) as usize;
    }

    // Value `act[j]` leaves the registers: its home's count goes down.
    fn leave(self: &mut Self, j: usize, want: &Vector<u8>) {
        let a = self.act[j];
        let h = self.home[a as usize];
        if h != HOME_NONE {
            self.cnt[Live::slot(want[a as usize], h)] -= 1;
        }
        let last = self.act.len() - 1;
        self.act[j] = self.act[last];
        self.act.truncate(last);
    }

    // A cold block that branches into the body runs inside the ranges of the values live at its target,
    // though the layout puts it last: each value whose range holds the position of such a target lives to
    // the cold block too, and is kept (its last use does not end it). A range max over the targets'
    // positions (a sparse table of `best`: per position, the last cold block with an edge into it) finds
    // the extension of each value.
    fn cold_entries(self: &mut Self, b: &Body, kept: &mut Vector<bool>) {
        let np = self.order.len();
        let mut best = Vector::<u32>::new();
        fill(&mut best, np, 0);
        let mut any = false;
        for p in 0..np {
            let bk = b.blocks[self.order[p] as usize];
            if (bk.flags & BLOCK_COLD) == 0 {
                continue;
            }
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
            for e in 0..self.succ.len() {
                let q = self.pos[b.edge_target(self.succ[e]) as usize] as usize;
                if best[q] < p as u32 {
                    best[q] = p as u32;
                    any = true;
                }
            }
        }
        if !any {
            return;
        }
        // Level j holds the maxima of the 2^j positions from each position.
        let mut levels: usize = 1;
        while 1usize << levels <= np {
            levels += 1;
        }
        let mut sp = Vector::<u32>::with_capacity(levels * np);
        sp.extend_copy(&best);
        for j in 1..levels {
            let h = 1usize << j - 1;
            for i in 0..np {
                let a = sp[(j - 1) * np + i];
                let c = if i + h < np {
                    sp[(j - 1) * np + i + h];
                } else {
                    0u32;
                };
                sp.push(
                    if a > c {
                        a;
                    } else {
                        c;
                    },
                );
            }
        }
        for x in 0..self.end.len() {
            let d = self.def_blk[x];
            if d == NONE || self.pos[d as usize] == NONE {
                continue;
            }
            let lo = self.pos[d as usize] as usize;
            // Each step moves the end to a later cold block: at most one step per cold block.
            loop {
                let hi = self.end[x] as usize;
                let mut j: usize = 0;
                while 2usize << j <= hi - lo + 1 {
                    j += 1;
                }
                let a = sp[j * np + lo];
                let c = sp[j * np + hi + 1 - (1usize << j)];
                let e = if a > c {
                    a;
                } else {
                    c;
                };
                if e <= self.end[x] {
                    break;
                }
                self.end[x] = e;
                kept[x] = true;
            }
        }
    }
}

/// Whether vector operation `t` (`O_VOP`) is a reduction, which computes in place over temporaries
/// (no call).
pub const fn reduces(t: Inst) bool {
    let code = (t.aux & VOP_CODE) as u32;
    return code >= core::OP_SIMD && code < core::OP_CMP_LANES && core::simd_op((code - core::OP_SIMD) as u8).rule == core::SR_REDUCE;
}

/// The values instruction `t` of `b` uses into `out`, each use once: its operands, a call's arguments, a
/// vector operation's operands and each edge's arguments.
pub fn each_use(b: &Body, t: Inst, out: &mut Vector<Value>) {
    out.truncate(0);
    let f = op_info(t.op).form;
    if lv::operand_a(f) && t.a != VNONE {
        out.push(t.a);
    }
    if lv::operand_b(f) && t.b != VNONE {
        out.push(t.b);
    }
    if lv::operand_c(f) && t.c != VNONE {
        out.push(t.c);
    }
    if f == F_CALL || f == F_CALLIND {
        for k in 0..t.aux as u32 {
            out.push(b.pool[(t.c + k) as usize]);
        }
    } else if f == F_VOP || f == F_ASM {
        for k in 0..t.b {
            out.push(b.pool[(t.a + k) as usize]);
        }
    } else if t.op == O_RET && (b.pool[b.sig as usize + 2] & AGG) != 0 {
        // The return reads the aggregate result's memory, the parameter after the declared ones.
        out.push(VPARAM | b.blocks[0].param_start + b.pool[b.sig as usize]);
    }
    let ne: u32 = if t.op == O_JMP {
        1;
    } else if t.op == O_BR {
        2;
    } else if t.op == O_SWITCH {
        t.aux as u32 + 1;
    } else {
        0;
    };
    for k in 0..ne {
        let e = edge_of(b, t, k);
        for x in 0..b.edge_nargs(e) {
            out.push(b.edge_arg(e, x));
        }
    }
}

/// The value indexes of the parameters terminator `t` of `b` writes, one per edge into them, into `out`.
pub fn each_edge_param(b: &Body, t: Inst, out: &mut Vector<u32>) {
    out.truncate(0);
    let ni = b.insts.len() as u32;
    b.succ_edges(t, out);
    let ne = out.len();
    for e in 0..ne {
        let sb = b.blocks[b.edge_target(out[e]) as usize];
        for q in 0..sb.param_len as u32 {
            out.push(ni + sb.param_start + q);
        }
    }
    // The parameters move to the front over the edges.
    let np = out.len() - ne;
    for i in 0..np {
        out[i] = out[ne + i];
    }
    out.truncate(np);
}

/// Edge `k` of terminator `t` (`jmp`: 0; `br`: 0 taken, 1 not; `switch`: its cases, then the default).
pub const fn edge_of(b: &Body, t: Inst, k: u32) u32 {
    if t.op == O_JMP {
        return t.a;
    }
    if t.op == O_BR {
        return if k == 0 {
            t.b;
        } else {
            t.c;
        };
    }
    return b.switch_edge(t, k);
}

/// `v` as `n` copies of `x`, its buffer reused.
pub fn fill(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}
