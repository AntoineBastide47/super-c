// Per-function control-flow analysis for the streaming C backend. Given a verified Core body it
// derives, in near-linear time over blocks and edges, the facts the emitter needs to reconstruct
// structured C: reachability from entry, trivial-forward jump threading, reverse-postorder layout,
// predecessor lists, immediate dominators, loop headers with their break targets, and each branch's
// join. It reads Core IR only -- it never mutates the body, spells C, or does semantic work. All
// storage is per-function and freed with the value.
import ir::core as ir;

pub const NONE: u32 = 0xFFFFFFFF;

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
    pub follow: Vector<u32>, // [n] branch block -> its join block, NONE if arms do not rejoin
    pub reducible: bool, // every retreating edge is a back edge
    pub simple: bool, // reducible AND every loop-exit edge targets the loop header or its follow;
    // structured emission applies only when simple, else the goto layout is used
}

extend CFlow as Free {
    pub fn free(self: &mut Self) {
        self.thread.free();
        self.reach.free();
        self.rpo.free();
        self.order.free();
        self.preds.free();
        self.pred_start.free();
        self.pred_list.free();
        self.idom.free();
        self.tin.free();
        self.tout.free();
        self.ipdom.free();
        self.is_header.free();
        self.loop_follow.free();
        self.loop_of.free();
        self.follow.free();
    }
}

// A block that only forwards: no statements, an unconditional goto. Predecessors thread through it.
fn trivial(b: &ir::CoreBody, x: u32) bool {
    let blk = b.blocks.at(x as usize);
    if blk.term.kind != ir::TM_GOTO {
        return false;
    }
    for i in 0..blk.stmt_len {
        let k = b.statements.at((blk.stmt_start + i) as usize).kind;
        if k != ir::ST_STORAGE_LIVE && k != ir::ST_STORAGE_DEAD && k != ir::ST_NOP {
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
    // Threaded k-th successor of x.
    pub fn succ(self: &Self, b: &ir::CoreBody, x: u32, k: u32) u32 {
        return *self.thread.at(raw_succ(b, x, k) as usize);
    }

    pub fn build(b: &ir::CoreBody) CFlow {
        let n = b.blocks.len() as u32;
        let mut cf = CFlow {
            n: n,
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
            follow: Vector::<u32>::new(),
            reducible: true,
            simple: true,
        };
        for _i in 0..n {
            cf.thread.push(0);
            cf.reach.push(false);
            cf.rpo.push(NONE);
            cf.preds.push(0);
            cf.idom.push(NONE);

            cf.tin.push(NONE);

            cf.tout.push(NONE);
            cf.is_header.push(false);
            cf.loop_follow.push(NONE);
            cf.loop_of.push(NONE);
            cf.follow.push(NONE);
        }
        if n == 0 {
            return cf;
        }
        // Thread trivial-forward (empty goto) chains, with path compression so each block is
        // resolved once: a whole chain collapses to its end in O(chain), amortized O(1) per block.
        let mut tdone = Vector::<bool>::new();
        let mut onpath = Vector::<bool>::new();
        for _i in 0..n {
            tdone.push(false);
            onpath.push(false);
        }
        let mut tpath = Vector::<u32>::new();
        for x in 0..n {
            if *tdone.at(x as usize) {
                continue;
            }
            tpath.truncate(0);
            let mut c = x;
            while trivial(b, c) && !*tdone.at(c as usize) && !*onpath.at(c as usize) {
                onpath.set(c as usize, true);
                tpath.push(c);
                c = b.blocks.at(c as usize).term.t0;
            }
            let target = if *tdone.at(c as usize) {
                *cf.thread.at(c as usize);
            } else {
                c;
            };
            for i in 0..tpath.len() {
                let p = *tpath.at(i);
                cf.thread.set(p as usize, target);
                tdone.set(p as usize, true);
                onpath.set(p as usize, false);
            }
            // a non-trivial start is its own target and is not on the path
            cf.thread.set(x as usize, target);
            tdone.set(x as usize, true);
        }
        tdone.free();
        onpath.free();
        tpath.free();
        cf.entry = *cf.thread.at(b.entry as usize);

        // Reverse-postorder DFS from entry over threaded edges (iterative; children in edge order).
        let mut state = Vector::<u8>::new(); // 0 unseen, 1 on-stack, 2 done
        for _i in 0..n {
            state.push(0);
        }
        let mut stack = Vector::<u32>::new();
        let mut kidx = Vector::<u32>::new(); // next child index per stack frame
        let mut post = Vector::<u32>::new();
        stack.push(cf.entry);
        kidx.push(0);
        state.set(cf.entry as usize, 1);
        cf.reach.set(cf.entry as usize, true);
        while stack.len() != 0 {
            let top = *stack.at(stack.len() - 1);
            let ki = *kidx.at(kidx.len() - 1);
            if ki < n_succ(b, top) {
                kidx.set(kidx.len() - 1, ki + 1);
                let s = cf.succ(b, top, ki);
                if *state.at(s as usize) == 0 {
                    state.set(s as usize, 1);
                    cf.reach.set(s as usize, true);
                    stack.push(s);
                    kidx.push(0);
                }
            } else {
                state.set(top as usize, 2);
                post.push(top);
                let _ = stack.pop();
                let _ = kidx.pop();
            }
        }
        // order = reverse of postorder; rpo = position in order.
        let m = post.len();
        for i in 0..m {
            let blk = *post.at(m - 1 - i);
            cf.order.push(blk);
            cf.rpo.set(blk as usize, i as u32);
        }

        // Predecessor lists (CSR) over reachable threaded edges.
        for x in 0..n {
            if !*cf.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = cf.succ(b, x, k);
                cf.preds.set(s as usize, *cf.preds.at(s as usize) + 1);
            }
        }
        let mut acc = 0u32;
        for x in 0..n {
            cf.pred_start.push(acc);
            acc += *cf.preds.at(x as usize);
        }
        cf.pred_start.push(acc);
        for _i in 0..acc {
            cf.pred_list.push(NONE);
        }
        let mut fill = Vector::<u32>::new();
        for x in 0..n {
            fill.push(*cf.pred_start.at(x as usize));
        }
        for x in 0..n {
            if !*cf.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = cf.succ(b, x, k);
                let at = *fill.at(s as usize);
                cf.pred_list.set(at as usize, x);
                fill.set(s as usize, at + 1);
            }
        }

        cf.compute_idom();
        cf.compute_domtree();
        cf.compute_pdom(b);
        // Reducibility: a retreating edge (target not later in RPO) that its target does not
        // dominate makes the CFG irreducible; structured emission then defers to the goto layout.
        for x in 0..n {
            if !*cf.reach.at(x as usize) {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = cf.succ(b, x, k);
                if *cf.rpo.at(s as usize) <= *cf.rpo.at(x as usize) && !cf.dominates(s, x) {
                    cf.reducible = false;
                }
            }
        }
        cf.compute_loops(b);
        cf.compute_follows(b);
        // simple loops: every edge leaving a node's innermost loop targets that loop's header
        // (continue) or its follow (break). A multi-level break/continue or irreducibility forces
        // the goto layout instead.
        cf.simple = cf.reducible;
        for x in 0..n {
            if !*cf.reach.at(x as usize) {
                continue;
            }
            let lx = *cf.loop_of.at(x as usize);
            if lx == NONE {
                continue;
            }
            for k in 0..n_succ(b, x) {
                let s = cf.succ(b, x, k);
                if s == lx || s == *cf.loop_follow.at(lx as usize) || cf.dominates(lx, s) {
                    continue;
                }
                cf.simple = false;
            }
        }

        state.free();
        stack.free();
        kidx.free();
        post.free();
        fill.free();
        return cf;
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
        let mut rrpo = Vector::<u32>::new();
        for _i in 0..self.n + 1 {
            self.ipdom.push(NONE);
            rrpo.push(NONE);
        }
        if self.n == 0 {
            rrpo.free();
            return;
        }
        // sinks (reachable blocks with no forward successor) -- the exit's reverse-graph successors,
        // built once so the DFS indexes rather than rescanning all blocks per sink
        let mut sinks = Vector::<u32>::new();
        for v in 0..self.n {
            if *self.reach.at(v as usize) && n_succ(b, v) == 0 {
                sinks.push(v);
            }
        }
        // reverse-graph DFS from the exit: exit -> sinks, then block -> its forward predecessors
        let mut state = Vector::<u8>::new();
        for _i in 0..self.n + 1 {
            state.push(0);
        }
        let mut stack = Vector::<u32>::new();
        let mut kidx = Vector::<u32>::new();
        let mut post = Vector::<u32>::new();
        stack.push(e);
        kidx.push(0);
        state.set(e as usize, 1);
        while stack.len() != 0 {
            let top = *stack.at(stack.len() - 1);
            let ki = *kidx.at(kidx.len() - 1);
            let mut nx = NONE;
            if top == e {
                if ki as usize < sinks.len() {
                    nx = *sinks.at(ki as usize);
                }
            } else {
                let ps = *self.pred_start.at(top as usize);
                let pe = *self.pred_start.at((top + 1) as usize);
                if ps + ki < pe {
                    nx = *self.pred_list.at((ps + ki) as usize);
                }
            }
            if nx != NONE {
                kidx.set(kidx.len() - 1, ki + 1);
                if *state.at(nx as usize) == 0 {
                    state.set(nx as usize, 1);
                    stack.push(nx);
                    kidx.push(0);
                }
            } else {
                state.set(top as usize, 2);
                post.push(top);
                let _ = stack.pop();
                let _ = kidx.pop();
            }
        }
        let m = post.len();
        for i in 0..m {
            rrpo.set((*post.at(m - 1 - i)) as usize, i as u32);
        }
        // Cooper-Harvey-Kennedy on the reverse graph; reverse-preds of x = its forward successors,
        // plus the exit when x is a sink.
        self.ipdom.set(e as usize, e);
        let mut changed = true;
        while changed {
            changed = false;
            for i in 0..m {
                let x = *post.at(m - 1 - i);
                if x == e {
                    continue;
                }
                let mut nd = NONE;
                let ns = n_succ(b, x);
                if ns == 0 {
                    nd = e; // sink: its only reverse-pred is the exit
                }
                for k in 0..ns {
                    let s = self.succ(b, x, k);
                    if *rrpo.at(s as usize) == NONE || *self.ipdom.at(s as usize) == NONE {
                        continue;
                    }
                    if nd == NONE {
                        nd = s;
                    } else {
                        nd = self.pintersect(&rrpo, s, nd);
                    }
                }
                if nd != NONE && *self.ipdom.at(x as usize) != nd {
                    self.ipdom.set(x as usize, nd);
                    changed = true;
                }
            }
        }
        state.free();
        stack.free();
        kidx.free();
        post.free();
        rrpo.free();
        sinks.free();
    }

    fn pintersect(self: &Self, rrpo: &Vector<u32>, a0: u32, b0: u32) u32 {
        let mut a = a0;
        let mut bb = b0;
        while a != bb {
            while *rrpo.at(a as usize) > *rrpo.at(bb as usize) {
                a = *self.ipdom.at(a as usize);
            }
            while *rrpo.at(bb as usize) > *rrpo.at(a as usize) {
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
        // children CSR from idom
        let mut cnt = Vector::<u32>::new();
        for _i in 0..self.n {
            cnt.push(0);
        }
        for i in 1..self.order.len() {
            let x = *self.order.at(i);
            cnt.set((*self.idom.at(x as usize)) as usize, *cnt.at((*self.idom.at(x as usize)) as usize) + 1);
        }
        let mut cstart = Vector::<u32>::new();
        let mut acc = 0u32;
        for x in 0..self.n {
            cstart.push(acc);
            acc += *cnt.at(x as usize);
        }
        cstart.push(acc);
        let mut clist = Vector::<u32>::new();
        for _i in 0..acc {
            clist.push(NONE);
        }
        let mut fill = Vector::<u32>::new();
        for x in 0..self.n {
            fill.push(*cstart.at(x as usize));
        }
        for i in 1..self.order.len() {
            let x = *self.order.at(i);
            let p = (*self.idom.at(x as usize)) as usize;
            clist.set((*fill.at(p)) as usize, x);
            fill.set(p, *fill.at(p) + 1);
        }
        let mut stack = Vector::<u32>::new();
        let mut kidx = Vector::<u32>::new();
        let mut timer = 0u32;
        stack.push(self.entry);
        kidx.push(*cstart.at(self.entry as usize));
        self.tin.set(self.entry as usize, timer);
        timer += 1;
        while stack.len() != 0 {
            let top = *stack.at(stack.len() - 1);
            let ki = *kidx.at(kidx.len() - 1);
            if ki < *cstart.at((top + 1) as usize) {
                kidx.set(kidx.len() - 1, ki + 1);
                let ch = *clist.at(ki as usize);
                self.tin.set(ch as usize, timer);
                timer += 1;
                stack.push(ch);
                kidx.push(*cstart.at(ch as usize));
            } else {
                self.tout.set(top as usize, timer);
                timer += 1;
                let _ = stack.pop();
                let _ = kidx.pop();
            }
        }
        cnt.free();
        cstart.free();
        clist.free();
        fill.free();
        stack.free();
        kidx.free();
    }

    // x dominates y: an O(1) interval test over the dominator-tree Euler tour.
    pub fn dominates(self: &Self, x: u32, y: u32) bool {
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
        let mut inloop = Vector::<bool>::new();
        for _i in 0..self.n {
            inloop.push(false);
        }
        let mut members = Vector::<u32>::new();
        let mut work = Vector::<u32>::new();
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
            self.is_header.set(h as usize, true);
            // natural loop = h plus every node that reaches a latch without passing through h
            inloop.set(h as usize, true);
            members.push(h);
            for pi in ps..pe {
                let p = *self.pred_list.at(pi as usize);
                if self.dominates(h, p) && !*inloop.at(p as usize) {
                    inloop.set(p as usize, true);
                    members.push(p);
                    work.push(p);
                }
            }
            while work.len() != 0 {
                let x = *work.at(work.len() - 1);
                let _ = work.pop();
                let xs = *self.pred_start.at(x as usize);
                let xe = *self.pred_start.at((x + 1) as usize);
                for pi in xs..xe {
                    let p = *self.pred_list.at(pi as usize);
                    if !*inloop.at(p as usize) {
                        inloop.set(p as usize, true);
                        members.push(p);
                        work.push(p);
                    }
                }
            }
            // innermost enclosing header per node: the deepest (largest RPO) header wins
            for mi in 0..members.len() {
                let k = *members.at(mi);
                let cur = *self.loop_of.at(k as usize);
                if cur == NONE || *self.rpo.at(h as usize) > *self.rpo.at(cur as usize) {
                    self.loop_of.set(k as usize, h);
                }
            }
            // break target = a loop-exit edge's destination, earliest in RPO
            let mut brk = NONE;
            for mi in 0..members.len() {
                let x = *members.at(mi);
                if !*self.reach.at(x as usize) {
                    continue;
                }
                for e in 0..n_succ(b, x) {
                    let s = self.succ(b, x, e);
                    if !*inloop.at(s as usize) {
                        if brk == NONE || *self.rpo.at(s as usize) < *self.rpo.at(brk as usize) {
                            brk = s;
                        }
                    }
                }
            }
            self.loop_follow.set(h as usize, brk);
            // clear only this loop's membership for the next header
            for mi in 0..members.len() {
                inloop.set((*members.at(mi)) as usize, false);
            }
            members.clear();
        }
        work.free();
        members.free();
        inloop.free();
    }

    // Branch join: where a branch's arms reconverge -- its immediate post-dominator, but only when
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
