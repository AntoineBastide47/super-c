// Per-function control-flow analysis for the streaming C backend. Given a verified Core body it
// derives, in near-linear time over blocks and edges, the facts the emitter needs to reconstruct
// structured C: reachability from entry, trivial-forward jump threading, reverse-postorder layout,
// predecessor lists, immediate dominators, loop headers with their break targets, and each branch's
// join. It reads Core IR only; it never mutates the body, spells C, or does semantic work. All
// storage is per-function and freed with the value.
import ir::core as ir;

/// The absent block, position, or dominator.
pub const NONE: u32 = 0xFFFFFFFF;

/// The derived control-flow facts of one body; every vector is indexed by block id (`[n]`).
pub struct CFlow {
    pub n: u32,
    pub entry: u32, // threaded entry block
    pub thread: Vector<u32>, // [n] final target of a trivial-forward (empty goto) chain from b
    pub reach: Vector<bool>, // [n] reachable from entry over threaded edges
    pub rpo: Vector<u32>, // [n] reverse-postorder position, NONE if unreachable
    pub order: Vector<u32>, // reachable blocks in reverse-postorder (emission order)
    pub preds: Vector<u32>, // [n] reachable in-edge count
    pub pred_start: Vector<u32>, // [n+1] CSR offsets into pred_list
    pub pred_list: Vector<u32>, // reachable predecessors, grouped by target
    pub idom: Vector<u32>, // [n] immediate dominator, NONE for entry/unreachable
    pub tin: Vector<u32>, // [n] dominator-tree DFS entry stamp (Euler tour) -> O(1) dominance
    pub tout: Vector<u32>, // [n] dominator-tree DFS exit stamp
    pub ipdom: Vector<u32>, // [n+1] immediate post-dominator over the reverse graph (index n = exit)
    pub is_header: Vector<bool>, // [n] loop header (target of a back edge)
    pub loop_follow: Vector<u32>, // [n] header -> break target block, NONE if none/infinite
    pub loop_of: Vector<u32>, // [n] innermost enclosing loop header, NONE if outside all loops
    pub loop_parent: Vector<u32>, // [n] loop header -> immediately enclosing loop header
    pub follow: Vector<u32>, // [n] branch block -> its join block, NONE if arms do not rejoin
    pub reducible: bool, // every retreating edge is a back edge
    // Scratch storage for build_into and its passes, kept across functions so a pooled CFlow
    // rebuilds without allocating (every vector clears and refills in place).
    s_tdone: Vector<bool>,
    s_onpath: Vector<bool>,
    s_tpath: Vector<u32>,
    s_state: Vector<u8>,
    s_stack: Vector<u32>,
    s_kidx: Vector<u32>,
    s_post: Vector<u32>,
    s_fill: Vector<u32>,
    s_cnt: Vector<u32>,
    s_cstart: Vector<u32>,
    s_clist: Vector<u32>,
    s_rrpo: Vector<u32>,
    s_sinks: Vector<u32>,
    s_inloop: Vector<bool>,
    s_members: Vector<u32>,
    s_work: Vector<u32>,
}

// A block that only forwards: no statements, an unconditional goto. Predecessors thread through it.
fn trivial(b: &ir::CoreBody, x: u32) bool {
    let blk = b.blocks.at(x as usize);
    if blk.term.kind != ir::TM_GOTO {
        return false;
    }
    for i in 0..blk.stmt_len {
        let k = b.statements.at((blk.stmt_start + i) as usize).kind;
        if k != ir::ST_STORAGE_LIVE && k != ir::ST_STORAGE_DEAD {
            return false;
        }
    }
    return true;
}

// Raw successor edge count (switch: one per arm plus the otherwise edge).
fn n_succ(b: &ir::CoreBody, x: u32) u32 {
    let t = b.blocks.at(x as usize).term;
    if t.kind == ir::TM_RETURN || t.kind == ir::TM_UNREACHABLE {
        return 0;
    }
    if t.kind == ir::TM_SWITCH {
        if const_switch_edge(b, x) != NONE {
            return 1;
        }
        return t.sw_len + 1;
    }
    return 1;
}

// A literal switch has one live edge. Removing its dead edges here keeps them out of reachability,
// dominance, loop discovery, and the final C layout.
fn const_switch_edge(b: &ir::CoreBody, x: u32) u32 {
    let t = b.blocks.at(x as usize).term;
    if t.kind != ir::TM_SWITCH {
        return NONE;
    }
    let op = *b.operands.at(t.a as usize);
    if op.kind != ir::OP_CONST {
        return NONE;
    }
    let c = *b.constants.at(op.data as usize);
    if c.kind != ir::CK_INT && c.kind != ir::CK_BOOL {
        return NONE;
    }
    for k in 0..t.sw_len {
        if (b.switch_pool[(t.sw_start + k) as usize] >> 32) as u32 == c.val as u32 {
            return k;
        }
    }
    return t.sw_len;
}

// Raw k-th successor block (pre-threading).
fn raw_succ(b: &ir::CoreBody, x: u32, k: u32) u32 {
    let t = b.blocks.at(x as usize).term;
    if t.kind == ir::TM_SWITCH {
        let ce = const_switch_edge(b, x);
        let sk = if ce == NONE {
            k;
        } else {
            ce;
        };
        if sk < t.sw_len {
            return (b.switch_pool[(t.sw_start + sk) as usize] & 0xFFFFFFFFu64) as u32;
        }
        return t.t0;
    }
    return t.t0;
}

extend CFlow {
    /// Threaded k-th successor of x.
    pub fn succ(self: &Self, b: &ir::CoreBody, x: u32, k: u32) u32 {
        return *self.thread.at(raw_succ(b, x, k) as usize);
    }

    /// A value with no blocks and no heap storage; `analyze` fills it.
    pub fn new_empty() CFlow {
        return CFlow {
            n: 0,
            entry: 0,
            thread: Vector::<u32>::new(),
            reach: Vector::<bool>::new(),
            rpo: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            pred_start: Vector::<u32>::new(),
            pred_list: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            tin: Vector::<u32>::new(),
            tout: Vector::<u32>::new(),
            ipdom: Vector::<u32>::new(),
            is_header: Vector::<bool>::new(),
            loop_follow: Vector::<u32>::new(),
            loop_of: Vector::<u32>::new(),
            loop_parent: Vector::<u32>::new(),
            follow: Vector::<u32>::new(),
            reducible: true,
            s_tdone: Vector::<bool>::new(),
            s_onpath: Vector::<bool>::new(),
            s_tpath: Vector::<u32>::new(),
            s_state: Vector::<u8>::new(),
            s_stack: Vector::<u32>::new(),
            s_kidx: Vector::<u32>::new(),
            s_post: Vector::<u32>::new(),
            s_fill: Vector::<u32>::new(),
            s_cnt: Vector::<u32>::new(),
            s_cstart: Vector::<u32>::new(),
            s_clist: Vector::<u32>::new(),
            s_rrpo: Vector::<u32>::new(),
            s_sinks: Vector::<u32>::new(),
            s_inloop: Vector::<bool>::new(),
            s_members: Vector::<u32>::new(),
            s_work: Vector::<u32>::new(),
        };
    }

    /// Rebuild in place: every vector clears and refills, so a pooled CFlow analyzes function
    /// after function without allocating once its high-water capacity is reached.
    pub fn build_into(self: &mut Self, b: &ir::CoreBody) {
        let n = b.blocks.len() as u32;
        self.n = n;
        self.entry = 0;
        self.reducible = true;
        self.thread.clear();
        self.reach.clear();
        self.rpo.clear();
        self.order.clear();
        self.preds.clear();
        self.pred_start.clear();
        self.pred_list.clear();
        self.idom.clear();
        self.tin.clear();
        self.tout.clear();
        self.ipdom.clear();
        self.is_header.clear();
        self.loop_follow.clear();
        self.loop_of.clear();
        self.loop_parent.clear();
        self.follow.clear();
        for _i in 0..n {
            self.thread.push(0);
            self.reach.push(false);
            self.rpo.push(NONE);
            self.preds.push(0);
            self.idom.push(NONE);

            self.tin.push(NONE);

            self.tout.push(NONE);
            self.is_header.push(false);
            self.loop_follow.push(NONE);
            self.loop_of.push(NONE);
            self.loop_parent.push(NONE);
            self.follow.push(NONE);
        }
        if n == 0 {
            return;
        }
        // Thread trivial-forward (empty goto) chains, with path compression so each block is
        // resolved once: a whole chain collapses to its end in O(chain), amortized O(1) per block.
        self.s_tdone.clear();
        self.s_onpath.clear();
        for _i in 0..n {
            self.s_tdone.push(false);
            self.s_onpath.push(false);
        }
        self.s_tpath.clear();
        for x in 0..n {
            if *self.s_tdone.at(x as usize) {
                continue;
            }
            self.s_tpath.truncate(0);
            let mut c = x;
            while trivial(b, c) && !*self.s_tdone.at(c as usize) && !*self.s_onpath.at(c as usize) {
                self.s_onpath.set(c as usize, true);
                self.s_tpath.push(c);
                c = b.blocks.at(c as usize).term.t0;
            }
            let target = if *self.s_tdone.at(c as usize) {
                *self.thread.at(c as usize);
            } else {
                c;
            };
            for i in 0..self.s_tpath.len() {
                let p = *self.s_tpath.at(i);
                self.thread.set(p as usize, target);
                self.s_tdone.set(p as usize, true);
                self.s_onpath.set(p as usize, false);
            }
            // A non-trivial start is its own target and is not on the path.
            self.thread.set(x as usize, target);
            self.s_tdone.set(x as usize, true);
        }
        self.entry = *self.thread.at(b.entry as usize);

        // Chain fast path: without a TM_SWITCH no block branches, so the reachable CFG is a single
        // forward chain (a repeated block would be a switchless loop: bail to the general path).
        // Every derived fact (rpo, preds, dominators, post-dominators, loops, follows) has the
        // closed form the general passes would compute, at O(chain) instead of many passes.
        {
            let mut has_switch = false;
            for x in 0..n {
                if b.blocks.at(x as usize).term.kind == ir::TM_SWITCH {
                    has_switch = true;
                    break;
                }
            }
            if !has_switch {
                let mut c = self.entry;
                let mut ok = true;
                loop {
                    if *self.reach.at(c as usize) {
                        // A cycle: fall back to the general passes.
                        ok = false;
                        break;
                    }
                    self.reach.set(c as usize, true);
                    self.rpo.set(c as usize, self.order.len() as u32);
                    self.order.push(c);
                    if n_succ(b, c) == 0 {
                        break;
                    }
                    c = self.succ(b, c, 0);
                }
                if ok {
                    let m = self.order.len();
                    for i in 0..m {
                        let x = *self.order.at(i);
                        if i != 0 {
                            self.preds.set(x as usize, 1);
                            self.idom.set(x as usize, *self.order.at(i - 1));
                        } else {
                            self.idom.set(x as usize, x);
                        }
                        // Dominator tree is the chain itself: nested Euler intervals.
                        self.tin.set(x as usize, i as u32);
                        self.tout.set(x as usize, (2 * m - i) as u32);
                    }
                    let mut acc = 0u32;
                    for x in 0..n {
                        self.pred_start.push(acc);
                        acc += *self.preds.at(x as usize);
                    }
                    self.pred_start.push(acc);
                    for _i in 0..acc {
                        self.pred_list.push(NONE);
                    }
                    for i in 1..m {
                        let x = *self.order.at(i);
                        self.pred_list.set((*self.pred_start.at(x as usize)) as usize, *self.order.at(i - 1));
                    }
                    for _i in 0..n + 1 {
                        self.ipdom.push(NONE);
                    }
                    for i in 0..m {
                        let x = *self.order.at(i);
                        let nx = if i + 1 < m {
                            *self.order.at(i + 1);
                        } else {
                            n;
                        };
                        self.ipdom.set(x as usize, nx);
                    }
                    self.ipdom.set(n as usize, n);
                    return;
                }
                // Undo the partial chain walk.
                for i in 0..self.order.len() {
                    let x = *self.order.at(i);
                    self.reach.set(x as usize, false);
                    self.rpo.set(x as usize, NONE);
                }
                self.order.truncate(0);
            }
        }

        // Reverse-postorder DFS from entry over threaded edges (iterative; children in edge order).
        // 0 unseen, 1 on-stack, 2 done.
        self.s_state.clear();
        for _i in 0..n {
            self.s_state.push(0);
        }
        self.s_stack.clear();
        // Next child index per stack frame.
        self.s_kidx.clear();
        self.s_post.clear();
        self.s_stack.push(self.entry);
        self.s_kidx.push(0);
        self.s_state.set(self.entry as usize, 1);
        self.reach.set(self.entry as usize, true);
        while self.s_stack.len() != 0 {
            let top = *self.s_stack.at(self.s_stack.len() - 1);
            let ki = *self.s_kidx.at(self.s_kidx.len() - 1);
            if ki < n_succ(b, top) {
                self.s_kidx.set(self.s_kidx.len() - 1, ki + 1);
                let s = self.succ(b, top, ki);
                if *self.s_state.at(s as usize) == 0 {
                    self.s_state.set(s as usize, 1);
                    self.reach.set(s as usize, true);
                    self.s_stack.push(s);
                    self.s_kidx.push(0);
                }
            } else {
                self.s_state.set(top as usize, 2);
                self.s_post.push(top);
                let _ = self.s_stack.pop();
                let _ = self.s_kidx.pop();
            }
        }
        // order = reverse of postorder; rpo = position in order.
        let m = self.s_post.len();
        for i in 0..m {
            let blk = *self.s_post.at(m - 1 - i);
            self.order.push(blk);
            self.rpo.set(blk as usize, i as u32);
        }

        // Predecessor lists (CSR) over reachable threaded edges.
        for x in 0..n {
            if !*self.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = self.succ(b, x, k);
                self.preds.set(s as usize, *self.preds.at(s as usize) + 1);
            }
        }
        let mut acc = 0u32;
        for x in 0..n {
            self.pred_start.push(acc);
            acc += *self.preds.at(x as usize);
        }
        self.pred_start.push(acc);
        for _i in 0..acc {
            self.pred_list.push(NONE);
        }
        self.s_fill.clear();
        for x in 0..n {
            self.s_fill.push(*self.pred_start.at(x as usize));
        }
        for x in 0..n {
            if !*self.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = self.succ(b, x, k);
                let at = *self.s_fill.at(s as usize);
                self.pred_list.set(at as usize, x);
                self.s_fill.set(s as usize, at + 1);
            }
        }

        self.compute_idom();
        self.compute_domtree();
        self.compute_pdom(b);
        // Reducibility: a retreating edge (target not later in RPO) that its target does not
        // dominate makes the CFG irreducible; structured emission then defers to the goto layout.
        for x in 0..n {
            if !*self.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = self.succ(b, x, k);
                if *self.rpo.at(s as usize) <= *self.rpo.at(x as usize) && !self.dominates(s, x) {
                    self.reducible = false;
                }
            }
        }
        self.compute_loops(b);
        self.compute_follows(b);
    }

    // Cooper-Harvey-Kennedy immediate dominators over the reachable RPO.
    fn compute_idom(self: &mut Self) {
        self.idom.set(self.entry as usize, self.entry);
        let mut changed = true;
        while changed {
            changed = false;
            for i in 1..self.order.len() {
                let x = *self.order.at(i);
                let ps = *self.pred_start.at(x as usize);
                let pe = *self.pred_start.at((x + 1) as usize);
                let mut nd = NONE;
                for pi in ps..pe {
                    let p = *self.pred_list.at(pi as usize);
                    if *self.idom.at(p as usize) == NONE {
                        continue;
                    }
                    if nd == NONE {
                        nd = p;
                    } else {
                        nd = self.intersect(p, nd);
                    }
                }
                if nd != NONE && *self.idom.at(x as usize) != nd {
                    self.idom.set(x as usize, nd);
                    changed = true;
                }
            }
        }
    }

    // Immediate post-dominators: dominators of the reverse graph (edges reversed, a virtual exit
    // block `n` linking every sink). ipdom[x] is where all forward paths out of x reconverge; the
    // structured emitter uses it as the exact branch follow.
    fn compute_pdom(self: &mut Self, b: &ir::CoreBody) {
        let e = self.n; // virtual exit
        self.s_rrpo.clear();
        for _i in 0..self.n + 1 {
            self.ipdom.push(NONE);
            self.s_rrpo.push(NONE);
        }
        if self.n == 0 {
            return;
        }
        // Sinks (reachable blocks with no forward successor) are the exit's reverse-graph successors,
        // built once so the DFS indexes rather than rescanning all blocks per sink.
        self.s_sinks.clear();
        for v in 0..self.n {
            if *self.reach.at(v as usize) && n_succ(b, v) == 0 {
                self.s_sinks.push(v);
            }
        }
        // reverse-graph DFS from the exit: exit -> sinks, then block -> its forward predecessors
        self.s_state.clear();
        for _i in 0..self.n + 1 {
            self.s_state.push(0);
        }
        self.s_stack.clear();
        self.s_kidx.clear();
        self.s_post.clear();
        self.s_stack.push(e);
        self.s_kidx.push(0);
        self.s_state.set(e as usize, 1);
        while self.s_stack.len() != 0 {
            let top = *self.s_stack.at(self.s_stack.len() - 1);
            let ki = *self.s_kidx.at(self.s_kidx.len() - 1);
            let mut nx = NONE;
            if top == e {
                if ki as usize < self.s_sinks.len() {
                    nx = *self.s_sinks.at(ki as usize);
                }
            } else {
                let ps = *self.pred_start.at(top as usize);
                let pe = *self.pred_start.at((top + 1) as usize);
                if ps + ki < pe {
                    nx = *self.pred_list.at((ps + ki) as usize);
                }
            }
            if nx != NONE {
                self.s_kidx.set(self.s_kidx.len() - 1, ki + 1);
                if *self.s_state.at(nx as usize) == 0 {
                    self.s_state.set(nx as usize, 1);
                    self.s_stack.push(nx);
                    self.s_kidx.push(0);
                }
            } else {
                self.s_state.set(top as usize, 2);
                self.s_post.push(top);
                let _ = self.s_stack.pop();
                let _ = self.s_kidx.pop();
            }
        }
        let m = self.s_post.len();
        for i in 0..m {
            self.s_rrpo.set((*self.s_post.at(m - 1 - i)) as usize, i as u32);
        }
        // Cooper-Harvey-Kennedy on the reverse graph; reverse-preds of x = its forward successors,
        // plus the exit when x is a sink.
        self.ipdom.set(e as usize, e);
        let mut changed = true;
        while changed {
            changed = false;
            for i in 0..m {
                let x = *self.s_post.at(m - 1 - i);
                if x == e {
                    continue;
                }
                let mut nd = NONE;
                let ns = n_succ(b, x);
                if ns == 0 {
                    // Sink: its only reverse-pred is the exit.
                    nd = e;
                }
                for k in 0..ns {
                    let s = self.succ(b, x, k);
                    if *self.s_rrpo.at(s as usize) == NONE || *self.ipdom.at(s as usize) == NONE {
                        continue;
                    }
                    if nd == NONE {
                        nd = s;
                    } else {
                        nd = self.pintersect(s, nd);
                    }
                }
                if nd != NONE && *self.ipdom.at(x as usize) != nd {
                    self.ipdom.set(x as usize, nd);
                    changed = true;
                }
            }
        }
    }

    fn pintersect(self: &Self, a0: u32, b0: u32) u32 {
        let mut a = a0;
        let mut bb = b0;
        while a != bb {
            while *self.s_rrpo.at(a as usize) > *self.s_rrpo.at(bb as usize) {
                a = *self.ipdom.at(a as usize);
            }
            while *self.s_rrpo.at(bb as usize) > *self.s_rrpo.at(a as usize) {
                bb = *self.ipdom.at(bb as usize);
            }
        }
        return a;
    }

    fn intersect(self: &Self, a0: u32, b0: u32) u32 {
        let mut a = a0;
        let mut bb = b0;
        while a != bb {
            while *self.rpo.at(a as usize) > *self.rpo.at(bb as usize) {
                a = *self.idom.at(a as usize);
            }
            while *self.rpo.at(bb as usize) > *self.rpo.at(a as usize) {
                bb = *self.idom.at(bb as usize);
            }
        }
        return a;
    }

    // Dominator-tree Euler tour: an iterative DFS over the dominator tree (children are the blocks
    // whose immediate dominator is this one), stamping entry/exit times so dominance is an O(1)
    // interval test instead of an idom-chain walk per query.
    fn compute_domtree(self: &mut Self) {
        // Children CSR from idom.
        self.s_cnt.clear();
        for _i in 0..self.n {
            self.s_cnt.push(0);
        }
        for i in 1..self.order.len() {
            let x = *self.order.at(i);
            self.s_cnt.set(
                (*self.idom.at(x as usize)) as usize,
                *self.s_cnt.at((*self.idom.at(x as usize)) as usize) + 1,
            );
        }
        self.s_cstart.clear();
        let mut acc = 0u32;
        for x in 0..self.n {
            self.s_cstart.push(acc);
            acc += *self.s_cnt.at(x as usize);
        }
        self.s_cstart.push(acc);
        self.s_clist.clear();
        for _i in 0..acc {
            self.s_clist.push(NONE);
        }
        self.s_fill.clear();
        for x in 0..self.n {
            self.s_fill.push(*self.s_cstart.at(x as usize));
        }
        for i in 1..self.order.len() {
            let x = *self.order.at(i);
            let p = (*self.idom.at(x as usize)) as usize;
            self.s_clist.set((*self.s_fill.at(p)) as usize, x);
            self.s_fill.set(p, *self.s_fill.at(p) + 1);
        }
        self.s_stack.clear();
        self.s_kidx.clear();
        let mut timer = 0u32;
        self.s_stack.push(self.entry);
        self.s_kidx.push(*self.s_cstart.at(self.entry as usize));
        self.tin.set(self.entry as usize, timer);
        timer += 1;
        while self.s_stack.len() != 0 {
            let top = *self.s_stack.at(self.s_stack.len() - 1);
            let ki = *self.s_kidx.at(self.s_kidx.len() - 1);
            if ki < *self.s_cstart.at((top + 1) as usize) {
                self.s_kidx.set(self.s_kidx.len() - 1, ki + 1);
                let ch = *self.s_clist.at(ki as usize);
                self.tin.set(ch as usize, timer);
                timer += 1;
                self.s_stack.push(ch);
                self.s_kidx.push(*self.s_cstart.at(ch as usize));
            } else {
                self.tout.set(top as usize, timer);
                timer += 1;
                let _ = self.s_stack.pop();
                let _ = self.s_kidx.pop();
            }
        }
    }

    /// True when x dominates y: an O(1) interval test over the dominator-tree Euler tour.
    pub const fn dominates(self: &Self, x: u32, y: u32) bool {
        if *self.tin.at(y as usize) == NONE || *self.tin.at(x as usize) == NONE {
            return false;
        }
        return *self.tin.at(x as usize) <= *self.tin.at(y as usize) && *self.tout.at(y as usize) <= *self.tout.at(
            x as usize,
        );
    }

    // Loop headers (back-edge targets) and, per header, the break target: an edge leaving the
    // natural loop. All per-header work touches only the loop's own nodes (collected in `members`),
    // so the total cost is the sum of loop sizes, not headers x blocks.
    fn compute_loops(self: &mut Self, b: &ir::CoreBody) {
        self.s_inloop.clear();
        for _i in 0..self.n {
            self.s_inloop.push(false);
        }
        self.s_members.clear();
        self.s_work.clear();
        for i in 0..self.order.len() {
            let h = *self.order.at(i);
            // latches: reachable preds p with h dominating p (back edge p -> h)
            let ps = *self.pred_start.at(h as usize);
            let pe = *self.pred_start.at((h + 1) as usize);
            let mut is_hdr = false;
            for pi in ps..pe {
                let p = *self.pred_list.at(pi as usize);
                if self.dominates(h, p) {
                    is_hdr = true;
                }
            }
            if !is_hdr {
                continue;
            }
            self.loop_parent.set(h as usize, *self.loop_of.at(h as usize));
            self.is_header.set(h as usize, true);
            // natural loop = h plus every node that reaches a latch without passing through h
            self.s_inloop.set(h as usize, true);
            self.s_members.push(h);
            for pi in ps..pe {
                let p = *self.pred_list.at(pi as usize);
                if self.dominates(h, p) && !*self.s_inloop.at(p as usize) {
                    self.s_inloop.set(p as usize, true);
                    self.s_members.push(p);
                    self.s_work.push(p);
                }
            }
            while self.s_work.len() != 0 {
                let x = *self.s_work.at(self.s_work.len() - 1);
                let _ = self.s_work.pop();
                let xs = *self.pred_start.at(x as usize);
                let xe = *self.pred_start.at((x + 1) as usize);
                for pi in xs..xe {
                    let p = *self.pred_list.at(pi as usize);
                    if !*self.s_inloop.at(p as usize) {
                        self.s_inloop.set(p as usize, true);
                        self.s_members.push(p);
                        self.s_work.push(p);
                    }
                }
            }
            // Innermost enclosing header per node: the deepest (largest RPO) header wins.
            for mi in 0..self.s_members.len() {
                let k = *self.s_members.at(mi);
                let cur = *self.loop_of.at(k as usize);
                if cur == NONE || *self.rpo.at(h as usize) > *self.rpo.at(cur as usize) {
                    self.loop_of.set(k as usize, h);
                }
            }
            // break target = a loop-exit edge's destination, earliest in RPO
            let mut brk = NONE;
            for mi in 0..self.s_members.len() {
                let x = *self.s_members.at(mi);
                if !*self.reach.at(x as usize) {
                    continue;
                }
                for e in 0..n_succ(b, x) {
                    let s = self.succ(b, x, e);
                    if !*self.s_inloop.at(s as usize) {
                        if brk == NONE || *self.rpo.at(s as usize) < *self.rpo.at(brk as usize) {
                            brk = s;
                        }
                    }
                }
            }
            self.loop_follow.set(h as usize, brk);
            // Clear only this loop's membership for the next header.
            for mi in 0..self.s_members.len() {
                self.s_inloop.set((*self.s_members.at(mi)) as usize, false);
            }
            self.s_members.clear();
        }
    }

    // Branch join: where a branch's arms reconverge, its immediate post-dominator, but only when
    // the branch dominates it (so it is genuinely inside the branch and emitted once, after the
    // arms). NONE when the arms do not rejoin (each terminates, or the continuation is absorbed into
    // an arm because it post-dominates through a path that leaves the branch).
    fn compute_follows(self: &mut Self, b: &ir::CoreBody) {
        for x in 0..self.n {
            if !*self.reach.at(x as usize) {
                continue;
            }
            if b.blocks.at(x as usize).term.kind != ir::TM_SWITCH {
                continue;
            }
            let m = *self.ipdom.at(x as usize);
            if m != NONE && m != self.n && m != x && self.dominates(x, m) && *self.loop_of.at(x as usize) == *self.loop_of.at(
                m as usize,
            ) {
                self.follow.set(x as usize, m);
            }
        }
    }
}
