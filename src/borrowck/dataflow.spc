// Initialization, move, and storage dataflow over Core IR: dense bit sets at block
// boundaries only, a change-driven work queue, and per-block event replay for statement-exact error
// checks. Merge rules: maybe-init and maybe-moved join by union, definitely-init by intersection.
import lexer::token as tok;
import ir::core as ir;
import borrowck::move_paths as mp;
import borrowck::facts as bf;

/// Move/init error kinds.
pub const ME_UNINIT: u8 = 0; // read of a never-initialized-on-some-path place
/// Move error kinds (MoveErr.kind).
pub const ME_MOVED: u8 = 1; // read of a maybe-moved place
pub const ME_DOUBLE_MOVE: u8 = 2; // second move of a maybe-moved place
pub const ME_PARTIAL: u8 = 3; // whole-value read while a sub-place is moved out

/// One use-after-move style error: kind, move path, and the offending point and span.
pub struct MoveErr {
    pub kind: u8,
    pub path: u32,
    pub point: u32,
    pub span: tok::Span,
}

/// Block successor and predecessor lists of one body in CSR form, plus its RPO.
pub struct Cfg {
    pub nblocks: u32,
    pub succ: Vector<u32>, // flat successor pool
    pub succ_start: Vector<u32>, // per block (+ sentinel)
    pub pred: Vector<u32>,
    pub pred_start: Vector<u32>,
    pub rpo: Vector<u32>, // reachable blocks in reverse postorder from the entry
    pub rpo_pos: Vector<u32>, // per block: its index in `rpo` (unreachable: 0xFFFFFFFF)
    pub acyclic: bool, // no back edge: one forward pass over `rpo` reaches the dataflow fixpoint
    s_cnt: Vector<u32>, // reused per-block counting scratch for the predecessor inversion
    s_color: Vector<u8>, // reused DFS colors (0 white / 1 grey / 2 black)
    s_stack: Vector<u64>, // reused DFS frames: block << 32 | next successor index
}

extend Cfg {
    /// A graph with no blocks and no heap storage; `build_into` fills it.
    pub fn empty() Cfg {
        return Cfg {
            nblocks: 0,
            succ: Vector::<u32>::new(),
            succ_start: Vector::<u32>::new(),
            pred: Vector::<u32>::new(),
            pred_start: Vector::<u32>::new(),
            rpo: Vector::<u32>::new(),
            rpo_pos: Vector::<u32>::new(),
            acyclic: true,
            s_cnt: Vector::<u32>::new(),
            s_color: Vector::<u8>::new(),
            s_stack: Vector::<u64>::new(),
        };
    }
}

/// The control-flow graph of `b`, freshly allocated, with predecessors built.
pub fn build_cfg(b: &ir::CoreBody) Cfg {
    let mut c = Cfg::empty();
    c.build_into(b);
    c.build_preds();
    return c;
}

extend Cfg {
    /// Reset-and-fill in place, keeping vector capacity across bodies (the reusable-context path).
    pub fn build_into(self: &mut Self, b: &ir::CoreBody) {
        let c = self; // keep the body below identical to the by-value builder
        let n = b.blocks.len() as u32;
        c.nblocks = n;
        c.succ.truncate(0);
        c.succ_start.truncate(0);
        c.pred.truncate(0);
        c.pred_start.truncate(0);
        for bi in 0..n {
            c.succ_start.push(c.succ.len() as u32);
            let t = b.blocks.at(bi as usize).term;
            if t.kind == ir::TM_GOTO || t.kind == ir::TM_CALL || t.kind == ir::TM_ASSERT || t.kind == ir::TM_DROP {
                if t.t0 != ir::IR_NONE {
                    c.succ.push(t.t0);
                }
            } else if t.kind == ir::TM_SWITCH {
                for i in 0..t.sw_len {
                    let tgt = (b.switch_pool[(t.sw_start + i) as usize] & 0xFFFFFFFFu64) as u32;
                    c.succ.push(tgt);
                }
                if t.t0 != ir::IR_NONE {
                    c.succ.push(t.t0);
                }
            }
        }
        c.succ_start.push(c.succ.len() as u32);
        // Reverse postorder + back-edge detection from the entry (iterative three-color DFS).
        // On a DAG, RPO is a topological order, so one forward dataflow pass is the fixpoint.
        c.rpo.truncate(0);
        c.rpo_pos.truncate(0);
        c.acyclic = true;
        for _i in 0..n {
            c.rpo_pos.push(0xFFFFFFFFu32);
        }
        if n == 0 {
            return;
        }
        c.s_color.truncate(0);
        for _i in 0..n {
            c.s_color.push(0);
        }
        c.s_stack.truncate(0);
        c.s_stack.push(b.entry as u64 << 32);
        c.s_color.set(b.entry as usize, 1);
        while c.s_stack.len() != 0 {
            let fr = c.s_stack[c.s_stack.len() - 1];
            let node = (fr >> 32) as u32;
            let ei = (fr & 0xFFFFFFFFu64) as u32;
            if c.succ_start[node as usize] + ei < c.succ_start[node as usize + 1] {
                c.s_stack.set(c.s_stack.len() - 1, fr + 1);
                let t = c.succ[(c.succ_start[node as usize] + ei) as usize];
                let col = c.s_color[t as usize];
                if col == 1 {
                    c.acyclic = false;
                } else if col == 0 {
                    c.s_color.set(t as usize, 1);
                    c.s_stack.push(t as u64 << 32);
                }
            } else {
                let _ = c.s_stack.pop();
                c.s_color.set(node as usize, 2);
                c.rpo.push(node);
            }
        }
        c.rpo.reverse();
        for i in 0..c.rpo.len() {
            c.rpo_pos.set(c.rpo[i] as usize, i as u32);
        }
    }

    /// Invert successors into predecessor lists (two passes: counts, then fill). Liveness is the
    /// only consumer, so this runs lazily: zero-loan bodies never pay for it. Idempotent per body:
    /// build_into truncates pred_start, and a filled list is left alone.
    pub fn build_preds(self: &mut Self) {
        let c = self;
        if c.pred_start.len() != 0 {
            return;
        }
        let n = c.nblocks;
        c.s_cnt.truncate(0);
        for _i in 0..n {
            c.s_cnt.push(0);
        }
        for bi in 0..n {
            for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                let t = c.succ[s as usize];
                c.s_cnt.set(t as usize, c.s_cnt[t as usize] + 1);
            }
        }
        let mut acc: u32 = 0;
        for bi in 0..n {
            c.pred_start.push(acc);
            acc += c.s_cnt[bi as usize];
            c.s_cnt.set(bi as usize, 0);
        }
        c.pred_start.push(acc);
        for _i in 0..acc {
            c.pred.push(0);
        }
        for bi in 0..n {
            for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                let t = c.succ[s as usize] as usize;
                c.pred.set((c.pred_start[t] + c.s_cnt[t]) as usize, bi);
                c.s_cnt.set(t, c.s_cnt[t] + 1);
            }
        }
    }
}

/// Backward local liveness at block boundaries from the generator's use/def summaries.
pub struct Liveness {
    pub words: u32,
    pub live_in: Vector<u64>, // per block * words
    pub live_out: Vector<u64>,
    s_queue: Vector<u32>, // reused work queue / queued-flags for the fixpoint
    s_queued: Vector<bool>,
}

extend Liveness {
    /// A solution with no rows; `build_into` fills it.
    pub fn empty() Liveness {
        return Liveness {
            words: 0,
            live_in: Vector::<u64>::new(),
            live_out: Vector::<u64>::new(),
            s_queue: Vector::<u32>::new(),
            s_queued: Vector::<bool>::new(),
        };
    }
}

/// Per-block origin liveness of `f` over `c`, freshly allocated.
pub fn solve_liveness(f: &bf::BodyFacts, c: &Cfg) Liveness {
    let mut lv = Liveness::empty();
    lv.build_into(f, c);
    return lv;
}

extend Liveness {
    /// Solve in place, keeping row capacity from earlier bodies.
    pub fn build_into(self: &mut Self, f: &bf::BodyFacts, c: &Cfg) {
        let lv = self;
        let w = f.lwords;
        lv.words = w;
        // Rows grow only past the high-water mark, then re-zero through raw stores (see MoveFlow).
        let need = (c.nblocks * w) as usize;
        while lv.live_in.len() < need {
            lv.live_in.push(0u64);
            lv.live_out.push(0u64);
        }
        lv.live_in.truncate(need);
        lv.live_out.truncate(need);
        unsafe {
            let zi = lv.live_in.as_ptr() as *mut u64;
            let zo = lv.live_out.as_ptr() as *mut u64;
            for i in 0..need {
                *(zi + i) = 0u64;
                *(zo + i) = 0u64;
            }
        }
        // Seed so the LIFO pops visit reachable blocks in POSTORDER (successors before
        // predecessors): liveness flows backward, so each block then sees converged successors on
        // its first visit instead of zeros. Unreachable blocks still run once, after them, so the
        // converged state matches the old every-block seed exactly.
        lv.s_queued.truncate(0);
        lv.s_queue.truncate(0);
        for _i in 0..c.nblocks {
            lv.s_queued.push(false);
        }
        for i in 0..c.rpo.len() {
            lv.s_queued.set(c.rpo[i] as usize, true);
        }
        for bi in 0..c.nblocks {
            if !lv.s_queued[bi as usize] {
                // Popped after the postorder run.
                lv.s_queue.push(bi);
            }
        }
        for i in 0..c.rpo.len() {
            lv.s_queue.push(c.rpo[i]);
        }
        for bi in 0..c.nblocks {
            lv.s_queued.set(bi as usize, true);
        }
        // Rows are sized once above; every `base/succ*w + k` is `< nblocks*w = row.len()`, so the
        // per-word inner loop indexes unchecked (super-c has no BCE pass, so this drops it by hand).
        let pin = lv.live_in.as_ptr() as *mut u64;
        let pout = lv.live_out.as_ptr() as *mut u64;
        let puse = f.luse.as_ptr();
        let pdef = f.ldef.as_ptr();
        while lv.s_queue.len() != 0 {
            let bi = lv.s_queue[lv.s_queue.len() - 1];
            let _ = lv.s_queue.pop();
            lv.s_queued.set(bi as usize, false);
            let base = (bi * w) as usize;
            let mut changed = false;
            for k in 0..w {
                let mut o: u64 = 0;
                for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                    o = o | unsafe *(pin + (c.succ[s as usize] * w + k) as usize);
                }
                unsafe {
                    let bk = base + k as usize;
                    if o != *(pout + bk) {
                        *(pout + bk) = o;
                        changed = true;
                    }
                    let inw = *(puse + bk) | o & ~*(pdef + bk);
                    if inw != *(pin + bk) {
                        *(pin + bk) = inw;
                        changed = true;
                    }
                }
            }
            if changed {
                for p in c.pred_start[bi as usize]..c.pred_start[bi as usize + 1] {
                    let pb = c.pred[p as usize];
                    if !lv.s_queued[pb as usize] {
                        lv.s_queued.set(pb as usize, true);
                        lv.s_queue.push(pb);
                    }
                }
            }
        }
    }
}

/// The move/init dataflow solution of one body: per-block entry states and the errors found.
pub struct MoveFlow {
    pub npaths: u32,
    pub words: u32,
    pub mi: Vector<u64>, // block-entry maybe-init
    pub di: Vector<u64>, // block-entry definitely-init
    pub mm: Vector<u64>, // block-entry maybe-moved
    pub errs: Vector<MoveErr>,
    s_reached: Vector<bool>, // reused per-block reached markers + work queue for the fixpoint
    s_queue: Vector<u32>,
    s_queued: Vector<bool>,
    s_ctx: FlowCtx, // reused per-block scratch state (mi/di/mm) applied during event replay
    s_scratch: Vector<u32>, // reused move-forest DFS stack + subtree buffer
    s_sub: Vector<u32>,
}

struct FlowCtx {
    pub mi: Vector<u64>,
    pub di: Vector<u64>,
    pub mm: Vector<u64>,
}

// Unchecked bit ops on a dataflow row. Precondition (held everywhere they are called): `i` is a
// move-path id < npaths and `v` holds ceil(npaths/64) words, so `w = i/64 < v.len()`. The
// id<npaths<->word-count invariant is not one bounds-check elimination proves, so this hot inner
// loop drops the guard by hand.
const fn bit_get(v: &Vector<u64>, i: u32) bool {
    let w = (i / 64) as usize;
    return (unsafe *(v.as_ptr() + w) >> (i & 63) as u64 & 1u64) != 0;
}

const fn bit_set(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    unsafe {
        let p = v.as_ptr() as *mut u64 + w;
        *p = *p | 1u64 << (i & 63) as u64;
    }
}

const fn bit_clear(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    unsafe {
        let p = v.as_ptr() as *mut u64 + w;
        *p = *p & ~(1u64 << (i & 63) as u64);
    }
}

/// Apply one init/move event to caller-held state rows (the transfer function, reporting-free).
pub fn apply_event(
    forest: &mp::MoveForest,
    ev: &bf::Event,
    scratch: &mut Vector<u32>,
    sub: &mut Vector<u32>,
    mi: &mut Vector<u64>,
    di: &mut Vector<u64>,
    mm: &mut Vector<u64>,
) {
    forest.subtree(ev.path(), scratch, sub);
    if ev.kind() == bf::EV_ASSIGN {
        for i in 0..sub.len() {
            bit_set(mi, sub[i]);
            bit_set(di, sub[i]);
            bit_clear(mm, sub[i]);
        }
        let mut p = forest.parent[ev.path() as usize];
        while p != mp::MP_NONE {
            bit_set(mi, p);
            p = forest.parent[p as usize];
        }
        return;
    }
    if ev.kind() == bf::EV_DEAD {
        for i in 0..sub.len() {
            bit_clear(mi, sub[i]);
            bit_clear(di, sub[i]);
            bit_clear(mm, sub[i]);
        }
        return;
    }
    if ev.kind() == bf::EV_MOVE || ev.kind() == bf::EV_MOVE_CUT {
        for i in 0..sub.len() {
            bit_clear(mi, sub[i]);
            bit_clear(di, sub[i]);
            bit_set(mm, sub[i]);
        }
    }
}

extend FlowCtx {
    // Apply one event to the scratch state; when `report` is set, emit errors against it.
    fn step(
        self: &mut Self,
        forest: &mp::MoveForest,
        ev: &bf::Event,
        scratch: &mut Vector<u32>,
        sub: &mut Vector<u32>,
        report: bool,
        errs: &mut Vector<MoveErr>,
    ) {
        // Reads (EV_USE, and EV_MOVE_CUT which never mutates here) only matter when reporting;
        // in the fixpoint's silent replays (the majority of all event work) they are no-ops,
        // so skip the subtree materialization entirely.
        if !report && ev.kind() != bf::EV_ASSIGN && ev.kind() != bf::EV_DEAD && ev.kind() != bf::EV_MOVE {
            return;
        }
        // Leaf paths (no tracked sub-places) are the overwhelming majority; inline their one-element
        // subtree here so the hot replay skips the out-of-line, cross-TU `subtree` call.
        if forest.is_leaf(ev.path()) {
            sub.clear();
            sub.push(ev.path());
        } else {
            forest.subtree(ev.path(), scratch, sub);
        }
        if ev.kind() == bf::EV_ASSIGN {
            for i in 0..sub.len() {
                bit_set(&mut self.mi, sub[i]);
                bit_set(&mut self.di, sub[i]);
                bit_clear(&mut self.mm, sub[i]);
            }
            // A partial write leaves ancestors only maybe-initialized.
            let mut p = forest.parent[ev.path() as usize];
            while p != mp::MP_NONE {
                bit_set(&mut self.mi, p);
                p = forest.parent[p as usize];
            }
            return;
        }
        if ev.kind() == bf::EV_DEAD {
            for i in 0..sub.len() {
                bit_clear(&mut self.mi, sub[i]);
                bit_clear(&mut self.di, sub[i]);
                bit_clear(&mut self.mm, sub[i]);
            }
            return;
        }
        // EV_MOVE / EV_USE: the read must see an initialized, unmoved place.
        if report {
            let mut di_any = bit_get(&self.di, ev.path());
            let mut mi_any = bit_get(&self.mi, ev.path());
            let mut mm_here = bit_get(&self.mm, ev.path());
            let mut p = forest.parent[ev.path() as usize];
            while p != mp::MP_NONE {
                if bit_get(&self.di, p) {
                    di_any = true;
                }
                if bit_get(&self.mi, p) {
                    mi_any = true;
                }
                if bit_get(&self.mm, p) {
                    mm_here = true;
                }
                p = forest.parent[p as usize];
            }
            if mm_here && !di_any {
                let mut k = ME_MOVED;
                if ev.kind() == bf::EV_MOVE {
                    k = ME_DOUBLE_MOVE;
                }
                errs.push(MoveErr { kind: k, path: ev.path(), point: ev.point, span: ev.span });
            } else if !di_any {
                // Not definitely initialized: uninitialized on at least one path.
                errs.push(MoveErr { kind: ME_UNINIT, path: ev.path(), point: ev.point, span: ev.span });
            } else if !mm_here {
                // Whole-value read while a sub-place is moved out and not reinitialized.
                for i in 0..sub.len() {
                    if bit_get(&self.mm, sub[i]) && !bit_get(&self.di, sub[i]) {
                        errs.push(MoveErr { kind: ME_PARTIAL, path: sub[i], point: ev.point, span: ev.span });
                        break;
                    }
                }
            }
        }
        if ev.kind() == bf::EV_MOVE {
            for i in 0..sub.len() {
                bit_clear(&mut self.mi, sub[i]);
                bit_clear(&mut self.di, sub[i]);
                bit_set(&mut self.mm, sub[i]);
            }
        }
    }
}

extend MoveFlow {
    /// A solution with no paths; `build_into` fills it.
    pub fn empty() MoveFlow {
        return MoveFlow {
            npaths: 0,
            words: 0,
            mi: Vector::<u64>::new(),
            di: Vector::<u64>::new(),
            mm: Vector::<u64>::new(),
            errs: Vector::<MoveErr>::new(),
            s_reached: Vector::<bool>::new(),
            s_queue: Vector::<u32>::new(),
            s_queued: Vector::<bool>::new(),
            s_ctx: FlowCtx { mi: Vector::<u64>::new(), di: Vector::<u64>::new(), mm: Vector::<u64>::new() },
            s_scratch: Vector::<u32>::new(),
            s_sub: Vector::<u32>::new(),
        };
    }
}

/// The move/init solution of `b`, freshly allocated; `errs` holds every move error.
pub fn solve_moves(b: &ir::CoreBody, forest: &mp::MoveForest, f: &bf::BodyFacts, c: &Cfg) MoveFlow {
    let mut mf = MoveFlow::empty();
    mf.build_into(b, forest, f, c);
    return mf;
}

extend MoveFlow {
    /// Solve in place, keeping capacity from earlier bodies.
    pub fn build_into(self: &mut Self, b: &ir::CoreBody, forest: &mp::MoveForest, f: &bf::BodyFacts, c: &Cfg) {
        let mf = self;
        let npaths = forest.paths.len() as u32;
        let mut w = (npaths + 63) / 64;
        if w == 0 {
            w = 1;
        }
        mf.npaths = npaths;
        mf.words = w;
        mf.errs.truncate(0);
        // Entry states: nothing reachable yet except the entry block, whose arguments and item-storage
        // roots are fully initialized. Unreached blocks start all-empty and fill by union/intersection
        // as predecessors reach them, so the DI intersection needs a reached marker to avoid treating
        // untouched blocks as "everything definite".
        // Rows grow only past the high-water mark, then re-zero through raw stores: a bulk word
        // write per element beats a push (with its length/capacity check) for every body after
        // the largest one seen.
        let need = (c.nblocks * w) as usize;
        while mf.mi.len() < need {
            mf.mi.push(0u64);
            mf.di.push(0u64);
            mf.mm.push(0u64);
        }
        mf.mi.truncate(need);
        mf.di.truncate(need);
        mf.mm.truncate(need);
        unsafe {
            let zmi = mf.mi.as_ptr() as *mut u64;
            let zdi = mf.di.as_ptr() as *mut u64;
            let zmm = mf.mm.as_ptr() as *mut u64;
            for i in 0..need {
                *(zmi + i) = 0u64;
                *(zdi + i) = 0u64;
                *(zmm + i) = 0u64;
            }
        }
        while mf.s_reached.len() < c.nblocks as usize {
            mf.s_reached.push(false);
        }
        mf.s_reached.truncate(c.nblocks as usize);
        unsafe {
            let zr = mf.s_reached.as_ptr() as *mut bool;
            for i in 0..c.nblocks as usize {
                *(zr + i) = false;
            }
        }
        mf.s_ctx.mi.truncate(0);
        mf.s_ctx.di.truncate(0);
        mf.s_ctx.mm.truncate(0);
        for _i in 0..w {
            mf.s_ctx.mi.push(0u64);
            mf.s_ctx.di.push(0u64);
            mf.s_ctx.mm.push(0u64);
        }
        // Seed the entry block.
        mf.s_scratch.truncate(0);
        mf.s_sub.truncate(0);
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            let is_ret = l as u32 < b.returns;
            if (st == ir::LS_ARG || st == ir::LS_STATIC_REF) && !is_ret {
                let root = forest.local_root[l];
                forest.subtree(root, &mut mf.s_scratch, &mut mf.s_sub);
                for i in 0..mf.s_sub.len() {
                    let base = (b.entry * w) as usize;
                    let word = (mf.s_sub[i] / 64) as usize;
                    mf.mi.set(base + word, mf.mi[base + word] | 1u64 << (mf.s_sub[i] & 63) as u64);
                    mf.di.set(base + word, mf.di[base + word] | 1u64 << (mf.s_sub[i] & 63) as u64);
                }
            }
        }
        mf.s_reached.set(b.entry as usize, true);
        // Acyclic bodies (the common case): RPO is a topological order, so every block's entry
        // state is final on first touch: one fused pass replays events WITH reporting and
        // propagates, and both the change-driven queue and the separate reporting pass vanish.
        // Cyclic bodies keep the queue and report after convergence.
        let fused = c.acyclic;
        mf.s_queued.truncate(0);
        mf.s_queue.truncate(0);
        if !fused {
            for _i in 0..c.nblocks {
                mf.s_queued.push(false);
            }
        }
        let mut ri: usize = 0;
        // Raw row pointers: mf.mi/di/mm and ctx.mi/di/mm are sized once above and never grow inside
        // the fixpoint (errors only accumulate under `fused`/reporting replays), so these stay
        // valid. Every `base/tb + k` is `< nblocks*w = row.len()`, so the per-word loops index unchecked.
        let pmi = mf.mi.as_ptr() as *mut u64;
        let pdi = mf.di.as_ptr() as *mut u64;
        let pmm = mf.mm.as_ptr() as *mut u64;
        let qmi = mf.s_ctx.mi.as_ptr() as *mut u64;
        let qdi = mf.s_ctx.di.as_ptr() as *mut u64;
        let qmm = mf.s_ctx.mm.as_ptr() as *mut u64;
        loop {
            let mut bi: u32 = 0;
            let mut sweep = false;
            if ri < c.rpo.len() {
                // First (both modes): one exact-RPO sweep, so every block's first visit sees all
                // its already-swept predecessors converged; only back edges re-enter via the queue.
                bi = c.rpo[ri];
                ri += 1;
                sweep = true;
            } else if fused || mf.s_queue.len() == 0 {
                break;
            } else {
                bi = mf.s_queue[0];
                // Pop from the front to keep propagation roughly topological; swap-with-last keeps it O(1).
                mf.s_queue.set(0, mf.s_queue[mf.s_queue.len() - 1]);
                let _ = mf.s_queue.pop();
                mf.s_queued.set(bi as usize, false);
            }
            let base = (bi * w) as usize;
            // A block with no move events has an identity transfer, so its exit state IS its entry
            // row: skip the copy-to-ctx and the event pass, and propagate straight from mf's row.
            let mut smi = pmi;
            let mut sdi = pdi;
            let mut smm = pmm;
            let mut soff = base;
            // The fused single pass replays the full stream (reads feed its reporting); the silent
            // queue replays stream only the state-changing events, so read-only blocks keep the
            // identity fast path.
            let mut es = f.ev_start[bi as usize];
            let mut ee = f.ev_start[bi as usize + 1];
            if !fused {
                es = f.mev_start[bi as usize];
                ee = f.mev_start[bi as usize + 1];
            }
            if es != ee {
                for k in 0..w as usize {
                    unsafe {
                        *(qmi + k) = *(pmi + base + k);
                        *(qdi + k) = *(pdi + base + k);
                        *(qmm + k) = *(pmm + base + k);
                    }
                }
                for e in es..ee {
                    let ev = if fused {
                        *f.events.at(e as usize);
                    } else {
                        *f.mev.at(e as usize);
                    };
                    mf.s_ctx.step(forest, &ev, &mut mf.s_scratch, &mut mf.s_sub, fused, &mut mf.errs);
                }
                smi = qmi;
                sdi = qdi;
                smm = qmm;
                soff = 0;
            }
            for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                let t = c.succ[s as usize];
                let tb = (t * w) as usize;
                let mut changed = false;
                if !mf.s_reached[t as usize] {
                    mf.s_reached.set(t as usize, true);
                    for k in 0..w as usize {
                        unsafe {
                            *(pmi + tb + k) = *(smi + soff + k);
                            *(pdi + tb + k) = *(sdi + soff + k);
                            *(pmm + tb + k) = *(smm + soff + k);
                        }
                    }
                    changed = true;
                } else {
                    for k in 0..w as usize {
                        unsafe {
                            let mi2 = *(pmi + tb + k) | *(smi + soff + k);
                            let di2 = *(pdi + tb + k) & *(sdi + soff + k);
                            let mm2 = *(pmm + tb + k) | *(smm + soff + k);
                            if mi2 != *(pmi + tb + k) || mm2 != *(pmm + tb + k) || di2 != *(pdi + tb + k) {
                                *(pmi + tb + k) = mi2;
                                *(pdi + tb + k) = di2;
                                *(pmm + tb + k) = mm2;
                                changed = true;
                            }
                        }
                    }
                }
                if !fused && changed && !mf.s_queued[t as usize] {
                    // During the sweep, forward targets get their visit later in RPO anyway; only a
                    // back (or self) edge needs the queue.
                    if !sweep || c.rpo_pos[t as usize] < ri as u32 {
                        mf.s_queued.set(t as usize, true);
                        mf.s_queue.push(t);
                    }
                }
            }
        }
        if fused {
            // The single pass already reported.
            return;
        }
        // Reporting pass: replay every reached block once against its fixpoint entry state. A block
        // with no events (or none the replay could report on) skips entirely.
        for bi in 0..c.nblocks {
            if !mf.s_reached[bi as usize] || !f.rep_blk[bi as usize] {
                continue;
            }
            let base = (bi * w) as usize;
            if f.easy_blk[bi as usize] {
                // Easy block (assigns + root-leaf uses only): a use can only error if its path's
                // entry maybe-moved bit is set or its entry definitely-init bit is clear: the
                // block's own assigns strictly improve both. Clean entry bits are proof; a dirty
                // word falls through to the exact replay.
                let lb = (bi * f.lwords) as usize;
                let mut bad: u64 = 0;
                for k in 0..f.lwords as usize {
                    let um = f.easy_use[lb + k];
                    bad = bad | mf.mm[base + k] & um | um & ~mf.di[base + k];
                }
                if bad == 0 {
                    continue;
                }
            }
            for k in 0..w as usize {
                unsafe {
                    *(qmi + k) = *(pmi + base + k);
                    *(qdi + k) = *(pdi + base + k);
                    *(qmm + k) = *(pmm + base + k);
                }
            }
            for e in f.ev_start[bi as usize]..f.ev_start[bi as usize + 1] {
                let ev = *f.events.at(e as usize);
                mf.s_ctx.step(forest, &ev, &mut mf.s_scratch, &mut mf.s_sub, true, &mut mf.errs);
            }
        }
    }
}
