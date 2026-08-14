// Initialization, move, and storage dataflow over Core IR: dense bit sets at block
// boundaries only, a change-driven work queue, and per-block event replay for statement-exact error
// checks. Merge rules: maybe-init and maybe-moved join by union, definitely-init by intersection.
import lexer::token as tok;
import ir::core as ir;
import borrowck::move_paths as mp;
import borrowck::facts as bf;

/// Move/init error kinds.
pub const ME_UNINIT: u8 = 0; // read of a never-initialized-on-some-path place
pub const ME_MOVED: u8 = 1; // read of a maybe-moved place
pub const ME_DOUBLE_MOVE: u8 = 2; // second move of a maybe-moved place
pub const ME_PARTIAL: u8 = 3; // whole-value read while a sub-place is moved out

pub struct MoveErr {
    pub kind: u8,
    pub path: u32,
    pub point: u32,
    pub span: tok::Span,
}

pub struct Cfg {
    pub nblocks: u32,
    pub succ: Vector<u32>, // flat successor pool
    pub succ_start: Vector<u32>, // per block (+ sentinel)
    pub pred: Vector<u32>,
    pub pred_start: Vector<u32>,
}

extend Cfg as Free {
    pub fn free(self: &mut Self) {
        self.succ.free();
        self.succ_start.free();
        self.pred.free();
        self.pred_start.free();
    }
}

pub fn build_cfg(b: &ir::CoreBody) Cfg {
    let n = b.blocks.len() as u32;
    let mut c = Cfg {
        nblocks: n,
        succ: Vector::<u32>::new(),
        succ_start: Vector::<u32>::new(),
        pred: Vector::<u32>::new(),
        pred_start: Vector::<u32>::new(),
    };
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
    // Invert for predecessors (two passes: counts, then fill).
    let mut cnt = Vector::<u32>::new();
    for _i in 0..n {
        cnt.push(0);
    }
    for bi in 0..n {
        for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
            let t = c.succ[s as usize];
            cnt.set(t as usize, cnt[t as usize] + 1);
        }
    }
    let mut acc: u32 = 0;
    for bi in 0..n {
        c.pred_start.push(acc);
        acc += cnt[bi as usize];
        cnt.set(bi as usize, 0);
    }
    c.pred_start.push(acc);
    for _i in 0..acc {
        c.pred.push(0);
    }
    for bi in 0..n {
        for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
            let t = c.succ[s as usize] as usize;
            c.pred.set((c.pred_start[t] + cnt[t]) as usize, bi);
            cnt.set(t, cnt[t] + 1);
        }
    }
    return c;
}

/// Backward local liveness at block boundaries from the generator's use/def summaries.
pub struct Liveness {
    pub words: u32,
    pub live_in: Vector<u64>, // per block * words
    pub live_out: Vector<u64>,
}

extend Liveness as Free {
    pub fn free(self: &mut Self) {
        self.live_in.free();
        self.live_out.free();
    }
}

pub fn solve_liveness(f: &bf::BodyFacts, c: &Cfg) Liveness {
    let w = f.lwords;
    let mut lv = Liveness { words: w, live_in: Vector::<u64>::new(), live_out: Vector::<u64>::new() };
    for _i in 0..c.nblocks * w {
        lv.live_in.push(0u64);
        lv.live_out.push(0u64);
    }
    let mut queued = Vector::<bool>::new();
    let mut queue = Vector::<u32>::new();
    for bi in 0..c.nblocks {
        queued.push(true);
        queue.push(c.nblocks - 1 - bi);
    }
    while queue.len() != 0 {
        let bi = queue[queue.len() - 1];
        let _ = queue.pop();
        queued.set(bi as usize, false);
        let base = (bi * w) as usize;
        let mut changed = false;
        for k in 0..w {
            let mut o: u64 = 0;
            for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                o = o | lv.live_in[(c.succ[s as usize] * w + k) as usize];
            }
            if o != lv.live_out[base + k as usize] {
                lv.live_out.set(base + k as usize, o);
                changed = true;
            }
            let inw = f.luse[base + k as usize] | o & ~f.ldef[base + k as usize];
            if inw != lv.live_in[base + k as usize] {
                lv.live_in.set(base + k as usize, inw);
                changed = true;
            }
        }
        if changed {
            for p in c.pred_start[bi as usize]..c.pred_start[bi as usize + 1] {
                let pb = c.pred[p as usize];
                if !queued[pb as usize] {
                    queued.set(pb as usize, true);
                    queue.push(pb);
                }
            }
        }
    }
    return lv;
}

// ---- init/move solver -----------------------------------------------------------------------------

pub struct MoveFlow {
    pub npaths: u32,
    pub words: u32,
    pub mi: Vector<u64>, // block-entry maybe-init
    pub di: Vector<u64>, // block-entry definitely-init
    pub mm: Vector<u64>, // block-entry maybe-moved
    pub errs: Vector<MoveErr>,
}

extend MoveFlow as Free {
    pub fn free(self: &mut Self) {
        self.mi.free();
        self.di.free();
        self.mm.free();
        self.errs.free();
    }
}

struct FlowCtx {
    pub mi: Vector<u64>,
    pub di: Vector<u64>,
    pub mm: Vector<u64>,
}

const fn bit_get(v: &Vector<u64>, i: u32) bool {
    return (*v.at((i / 64) as usize) >> (i & 63) as u64 & 1u64) != 0;
}

fn bit_set(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    v.set(w, v[w] | 1u64 << (i & 63) as u64);
}

fn bit_clear(v: &mut Vector<u64>, i: u32) {
    let w = (i / 64) as usize;
    v.set(w, v[w] & ~(1u64 << (i & 63) as u64));
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
    forest.subtree(ev.path, scratch, sub);
    if ev.kind == bf::EV_ASSIGN {
        for i in 0..sub.len() {
            bit_set(mi, sub[i]);
            bit_set(di, sub[i]);
            bit_clear(mm, sub[i]);
        }
        let mut p = forest.paths.at(ev.path as usize).parent;
        while p != mp::MP_NONE {
            bit_set(mi, p);
            p = forest.paths.at(p as usize).parent;
        }
        return;
    }
    if ev.kind == bf::EV_DEAD {
        for i in 0..sub.len() {
            bit_clear(mi, sub[i]);
            bit_clear(di, sub[i]);
            bit_clear(mm, sub[i]);
        }
        return;
    }
    if ev.kind == bf::EV_MOVE || ev.kind == bf::EV_MOVE_CUT {
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
        forest.subtree(ev.path, scratch, sub);
        if ev.kind == bf::EV_ASSIGN {
            for i in 0..sub.len() {
                bit_set(&mut self.mi, sub[i]);
                bit_set(&mut self.di, sub[i]);
                bit_clear(&mut self.mm, sub[i]);
            }
            // A partial write leaves ancestors only maybe-initialized.
            let mut p = forest.paths.at(ev.path as usize).parent;
            while p != mp::MP_NONE {
                bit_set(&mut self.mi, p);
                p = forest.paths.at(p as usize).parent;
            }
            return;
        }
        if ev.kind == bf::EV_DEAD {
            for i in 0..sub.len() {
                bit_clear(&mut self.mi, sub[i]);
                bit_clear(&mut self.di, sub[i]);
                bit_clear(&mut self.mm, sub[i]);
            }
            return;
        }
        // EV_MOVE / EV_USE: the read must see an initialized, unmoved place.
        if report {
            let mut di_any = bit_get(&self.di, ev.path);
            let mut mi_any = bit_get(&self.mi, ev.path);
            let mut mm_here = bit_get(&self.mm, ev.path);
            let mut p = forest.paths.at(ev.path as usize).parent;
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
                p = forest.paths.at(p as usize).parent;
            }
            if mm_here && !di_any {
                let mut k = ME_MOVED;
                if ev.kind == bf::EV_MOVE {
                    k = ME_DOUBLE_MOVE;
                }
                errs.push(MoveErr { kind: k, path: ev.path, point: ev.point, span: ev.span });
            } else if !di_any {
                // Not definitely initialized: uninitialized on at least one path.
                errs.push(MoveErr { kind: ME_UNINIT, path: ev.path, point: ev.point, span: ev.span });
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
        if ev.kind == bf::EV_MOVE {
            for i in 0..sub.len() {
                bit_clear(&mut self.mi, sub[i]);
                bit_clear(&mut self.di, sub[i]);
                bit_set(&mut self.mm, sub[i]);
            }
        }
    }
}

pub fn solve_moves(b: &ir::CoreBody, forest: &mp::MoveForest, f: &bf::BodyFacts, c: &Cfg) MoveFlow {
    let npaths = forest.paths.len() as u32;
    let mut w = (npaths + 63) / 64;
    if w == 0 {
        w = 1;
    }
    let mut mf = MoveFlow {
        npaths: npaths,
        words: w,
        mi: Vector::<u64>::new(),
        di: Vector::<u64>::new(),
        mm: Vector::<u64>::new(),
        errs: Vector::<MoveErr>::new(),
    };
    // Entry states: nothing reachable yet except the entry block, whose arguments and item-storage
    // roots are fully initialized. Unreached blocks start all-empty and fill by union/intersection
    // as predecessors reach them, so the DI intersection needs a reached marker to avoid treating
    // untouched blocks as "everything definite".
    for _i in 0..c.nblocks * w {
        mf.mi.push(0u64);
        mf.di.push(0u64);
        mf.mm.push(0u64);
    }
    let mut reached = Vector::<bool>::new();
    for _i in 0..c.nblocks {
        reached.push(false);
    }
    let mut ctx = FlowCtx { mi: Vector::<u64>::new(), di: Vector::<u64>::new(), mm: Vector::<u64>::new() };
    for _i in 0..w {
        ctx.mi.push(0u64);
        ctx.di.push(0u64);
        ctx.mm.push(0u64);
    }
    // Seed the entry block.
    let mut scratch = Vector::<u32>::new();
    let mut sub = Vector::<u32>::new();
    for l in 0..b.locals.len() {
        let st = b.locals.at(l).storage;
        let is_ret = l as u32 < b.returns;
        if (st == ir::LS_ARG || st == ir::LS_STATIC_REF) && !is_ret {
            let root = forest.local_root[l];
            forest.subtree(root, &mut scratch, &mut sub);
            for i in 0..sub.len() {
                let base = (b.entry * w) as usize;
                let word = (sub[i] / 64) as usize;
                mf.mi.set(base + word, mf.mi[base + word] | 1u64 << (sub[i] & 63) as u64);
                mf.di.set(base + word, mf.di[base + word] | 1u64 << (sub[i] & 63) as u64);
            }
        }
    }
    reached.set(b.entry as usize, true);
    let mut queued = Vector::<bool>::new();
    let mut queue = Vector::<u32>::new();
    for _i in 0..c.nblocks {
        queued.push(false);
    }
    queue.push(b.entry);
    queued.set(b.entry as usize, true);
    while queue.len() != 0 {
        let bi = queue[0];
        // Pop from the front to keep propagation roughly topological; swap-with-last keeps it O(1).
        queue.set(0, queue[queue.len() - 1]);
        let _ = queue.pop();
        queued.set(bi as usize, false);
        let base = (bi * w) as usize;
        for k in 0..w as usize {
            ctx.mi.set(k, mf.mi[base + k]);
            ctx.di.set(k, mf.di[base + k]);
            ctx.mm.set(k, mf.mm[base + k]);
        }
        for e in f.ev_start[bi as usize]..f.ev_start[bi as usize + 1] {
            let ev = *f.events.at(e as usize);
            ctx.step(forest, &ev, &mut scratch, &mut sub, false, &mut mf.errs);
        }
        for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
            let t = c.succ[s as usize];
            let tb = (t * w) as usize;
            let mut changed = false;
            if !reached[t as usize] {
                reached.set(t as usize, true);
                for k in 0..w as usize {
                    mf.mi.set(tb + k, ctx.mi[k]);
                    mf.di.set(tb + k, ctx.di[k]);
                    mf.mm.set(tb + k, ctx.mm[k]);
                }
                changed = true;
            } else {
                for k in 0..w as usize {
                    let mi2 = mf.mi[tb + k] | ctx.mi[k];
                    let di2 = mf.di[tb + k] & ctx.di[k];
                    let mm2 = mf.mm[tb + k] | ctx.mm[k];
                    if mi2 != mf.mi[tb + k] || di2 != mf.di[tb + k] || mm2 != mf.mm[tb + k] {
                        mf.mi.set(tb + k, mi2);
                        mf.di.set(tb + k, di2);
                        mf.mm.set(tb + k, mm2);
                        changed = true;
                    }
                }
            }
            if changed && !queued[t as usize] {
                queued.set(t as usize, true);
                queue.push(t);
            }
        }
    }
    // Reporting pass: replay every reached block once against its fixpoint entry state.
    for bi in 0..c.nblocks {
        if !reached[bi as usize] {
            continue;
        }
        let base = (bi * w) as usize;
        for k in 0..w as usize {
            ctx.mi.set(k, mf.mi[base + k]);
            ctx.di.set(k, mf.di[base + k]);
            ctx.mm.set(k, mf.mm[base + k]);
        }
        for e in f.ev_start[bi as usize]..f.ev_start[bi as usize + 1] {
            let ev = *f.events.at(e as usize);
            ctx.step(forest, &ev, &mut scratch, &mut sub, true, &mut mf.errs);
        }
    }
    return mf;
}
