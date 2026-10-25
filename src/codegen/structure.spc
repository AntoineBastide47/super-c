// What structured control flow needs from a LIR body's control-flow graph (Ramsey, "Beyond Relooper",
// ICFP 2022): reverse postorder, immediate dominators (Cooper, Harvey and Kennedy's iteration), the
// forward in-edges of each block, the loop headers, and each block's dominator-tree children in reverse
// postorder. The graph is reducible (the verifier checks it), so an edge to a block whose number is not
// above its source's is a back edge, and its target dominates its source.
import lir::ir as *;
import codegen::live as lv;

/// The structure of one body.
pub struct Shape {
    pub rpo: Vector<u32>, // per block, its reverse postorder number (NONE: unreachable)
    pub order: Vector<u32>, // the reachable blocks in reverse postorder
    pub idom: Vector<u32>, // per block, its immediate dominator (the entry's is itself)
    pub fwd: Vector<u32>, // per block, its forward in-edges, one per edge
    pub header: Vector<bool>, // per block, the target of a back edge
    pub kids_at: Vector<u32>, // per block, the start of its children in `kids`; one more entry at the end
    pub kids: Vector<u32>, // the dominator-tree children, each block's in reverse postorder
    succ: Vector<u32>,
    stack: Vector<u32>,
}

extend Shape {
    pub fn new() Shape {
        return Shape {
            rpo: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            idom: Vector::<u32>::new(),
            fwd: Vector::<u32>::new(),
            header: Vector::<bool>::new(),
            kids_at: Vector::<u32>::new(),
            kids: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            stack: Vector::<u32>::new(),
        };
    }

    /// Whether block `k` is a merge node: two or more forward in-edges.
    pub const fn merge(self: &Self, k: u32) bool {
        return self.fwd[k as usize] >= 2;
    }

    /// Whether the edge from block `s` to block `t` is a back edge.
    pub const fn back(self: &Self, s: u32, t: u32) bool {
        return self.rpo[t as usize] <= self.rpo[s as usize];
    }

    /// Analyze `b`.
    pub fn run(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        lv::fill(&mut self.rpo, nb, NONE);
        lv::fill(&mut self.idom, nb, NONE);
        lv::fill(&mut self.fwd, nb, 0);
        self.header.truncate(0);
        self.header.resize_default(nb);
        self.postorder(b);
        // Forward edges and loop headers.
        for q in 0..self.order.len() {
            let k = self.order[q];
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                if self.back(k, s) {
                    self.header[s as usize] = true;
                } else {
                    self.fwd[s as usize] += 1;
                }
            }
        }
        self.dominators(b);
        // The children of each block, in reverse postorder (CSR over `order`).
        lv::fill(&mut self.kids_at, nb + 1, 0);
        for q in 1..self.order.len() {
            let k = self.order[q];
            self.kids_at[self.idom[k as usize] as usize + 1] += 1;
        }
        for k in 0..nb {
            self.kids_at[k + 1] += self.kids_at[k];
        }
        lv::fill(&mut self.kids, self.kids_at[nb] as usize, 0);
        let mut fillp = Vector::<u32>::with_capacity(nb + 1);
        fillp.extend_copy(&self.kids_at);
        for q in 1..self.order.len() {
            let k = self.order[q];
            let d = self.idom[k as usize] as usize;
            self.kids[fillp[d] as usize] = k;
            fillp[d] += 1;
        }
    }

    // `order` and `rpo` by an explicit-stack DFS from the entry (`stack` holds block << 1 | finished): at
    // most two pops per block and one per edge.
    fn postorder(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        let mut seen = Vector::<bool>::new();
        seen.resize_default(nb);
        self.order.truncate(0);
        self.stack.truncate(0);
        self.stack.push(0);
        while self.stack.len() != 0 {
            let x = self.stack.pop().unwrap();
            let k = x >> 1;
            if (x & 1) != 0 {
                self.order.push(k);
                continue;
            }
            if seen[k as usize] {
                continue;
            }
            seen[k as usize] = true;
            self.stack.push(k << 1 | 1);
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            let mut e = self.succ.len();
            while e > 0 {
                e -= 1;
                let s = b.edge_target(self.succ[e]);
                if !seen[s as usize] {
                    self.stack.push(s << 1);
                }
            }
        }
        self.order.reverse();
        for q in 0..self.order.len() {
            self.rpo[self.order[q] as usize] = q as u32;
        }
    }

    // Immediate dominators by Cooper, Harvey and Kennedy's iteration over reverse postorder. A reducible
    // graph settles in two passes; each pass is bounded by the edges.
    fn dominators(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // Predecessor lists of the reachable blocks (CSR).
        let mut start = Vector::<u32>::new();
        lv::fill(&mut start, nb + 1, 0);
        for q in 0..self.order.len() {
            let k = self.order[q];
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                start[b.edge_target(self.succ[e]) as usize + 1] += 1;
            }
        }
        for k in 0..nb {
            start[k + 1] += start[k];
        }
        let mut preds = Vector::<u32>::new();
        lv::fill(&mut preds, start[nb] as usize, 0);
        let mut fillp = Vector::<u32>::with_capacity(nb + 1);
        fillp.extend_copy(&start);
        for q in 0..self.order.len() {
            let k = self.order[q];
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]) as usize;
                preds[fillp[s] as usize] = k;
                fillp[s] += 1;
            }
        }
        if self.order.len() == 0 {
            return;
        }
        self.idom[self.order[0] as usize] = self.order[0];
        // Each pass that changes nothing ends the iteration; a pass changes at most every block.
        for _ in 0..nb + 1 {
            let mut changed = false;
            for q in 1..self.order.len() {
                let k = self.order[q] as usize;
                let mut d = NONE;
                for j in start[k]..start[k + 1] {
                    let p = preds[j as usize];
                    if self.idom[p as usize] == NONE {
                        continue;
                    }
                    d = if d == NONE {
                        p;
                    } else {
                        self.common(d, p);
                    };
                }
                if d != self.idom[k] {
                    self.idom[k] = d;
                    changed = true;
                }
            }
            if !changed {
                return;
            }
        }
    }

    // The nearest common dominator of `x` and `y`, both with dominators set: each step moves the deeper
    // one up the tree.
    fn common(self: &Self, x0: u32, y0: u32) u32 {
        let mut x = x0;
        let mut y = y0;
        while x != y {
            while self.rpo[x as usize] > self.rpo[y as usize] {
                x = self.idom[x as usize];
            }
            while self.rpo[y as usize] > self.rpo[x as usize] {
                y = self.idom[y as usize];
            }
        }
        return x;
    }
}
