// The loan-scope solver: a unified origin-and-CFG graph queried lazily per candidate.
// Subset edges exist at their Core IR points (location-sensitive); liveness edges follow CFG point
// order for origins live at the target. A cheap point-stripped prepass filters candidates first:
// it may produce false candidates but can never hide one, because every edge it drops exists at
// SOME point. The reference solver at the bottom materializes the full product graph and must agree
// with the optimized path on small bodies; only tests run it.
// Rows over points come in two representations. Dense rows are bitsets spanning the whole body, so
// one body costs origins x points bits. Sparse rows are sorted point intervals per local and sorted
// point lists per loan, the flood's visited set is a hash set, and the prepass keeps only the
// columns anything asks about (placeholders and return slots), so every row costs its own size.
// Bodies above SPARSE_MIN_CELLS origin-point cells take the sparse rows; both give the same results,
// and SC_BC_VALIDATE solves every body both ways and compares them (`assert_agrees`).
import lexer::token as tok;
import ir::core as ir;
import borrowck::facts as bf;
import borrowck::dataflow as df;
import borrowck::loan_set as ls;
import utils::bits as bits;

/// Borrow error kinds.
pub const BE_CONFLICT: u8 = 0; // access invalidates a loan that is still required
pub const BE_ESCAPE: u8 = 1; // borrow of body-local storage escapes through a placeholder

/// BorrowErr.acc for a conflict caused by storage death (the borrowed local leaves scope).
pub const ACC_DEAD: u8 = 5;

/// One borrow error the solver found: its kind, the offending loan, and the point and span of the
/// invalidating access.
pub struct BorrowErr {
    pub kind: u8,
    pub acc: u8, // BE_CONFLICT: the invalidating access kind (bf::ACC_* or ACC_DEAD)
    pub loan: u32,
    pub point: u32,
    pub span: tok::Span, // the invalidating access (or escape site)
}

/// The loan solver's state for one body: the in-scope loan matrix, per-point liveness, and the
/// errors found. Pointers borrow the caller's facts for the solve's duration.
pub struct Solver {
    pub b: *const ir::CoreBody,
    pub f: *const bf::BodyFacts,
    pub c: *const df::Cfg,
    pub lv: *const df::Liveness,
    pub errs: Vector<BorrowErr>,
    pub flow_pushes: u32, // scope_flow queue pushes, seeds included (asserted within the monotone bound)
    pub point_block: Vector<u32>, // per point: its block
    pub sub_by_point: Vector<u32>, // subset indexes sorted by point
    pub sub_pt_start: Vector<u32>, // per point (+1): range into sub_by_point (entry seeds at 0)
    pub live_pts: Vector<u64>, // per inference origin: point bitset (word-major, pwords per origin)
    pub pwords: u32,
    pub oreach: Vector<u64>, // prepass: per origin, origins reachable over point-stripped subsets
    pub owords: u32,
    pub cuts: Vector<u64>, // the facts' rebind cuts (origin << 32 | point), sorted for cut_at
    pub req_cache: Vector<u64>, // per queried loan: required-point bitset (pwords), or empty
    pub req_have: Vector<bool>,
    pub scope: ls::LoanMat, // block-entry loans-in-scope
    pub kill_keys: Vector<u64>, // sparse: every kill as loan << 32 | point, sorted
    pub ret_pts: Vector<u32>, // return terminators' entry points, ascending block order
    pub sparse: bool, // interval and point-list rows instead of dense point bitsets
    pub lv_start: Vector<u32>, // sparse: per local (+1), CSR into lv_iv
    pub lv_iv: Vector<u64>, // sparse: live intervals start << 32 | end (inclusive), ascending per local
    pub rq_range: Vector<u64>, // sparse: per queried loan, range start << 32 | end into rq_pts
    pub rq_pts: Vector<u32>, // sparse: required points, ascending per loan
    pub tgt_col: Vector<u32>, // sparse prepass: per origin, its oreach column or BF_NONE
    vt: Vector<u64>, // sparse flood visited set: open addressing, (origin << 32 | point) << 2 | levels
    vt_used: Vector<u32>, // slots set this query, so clearing is O(touched)
    vt_shift: u32, // 64 - log2(vt.len())
    pub issues_blk: Vector<u32>, // per block: loan issues, generation (= point) order
    pub issue_start: Vector<u32>,
    pub kills_blk: Vector<u64>, // per block: kill records (point << 32 | loan), sorted
    pub kill_start: Vector<u32>,
    pub visit: Vector<u64>, // flood scratch: (origin, point) visited bits
    pub visit_dirty: Vector<u32>, // words set in `visit` this query, so clearing is O(touched) not O(vwords)
    pub work: Vector<u64>, // flood worklist: origin << 32 | point
    pub succs: Vector<u32>, // reused point-successor scratch for the flood
    // Reused per-stage scratch (truncated at each use), so a body allocates none of it after warmup.
    s_cur32: Vector<u32>, // index_points: counting-sort cursors
    s_ic: Vector<u32>, // index_points: per-block issue counts; prepass and conflicts: CSR cursors
    s_kc: Vector<u32>, // index_points: per-block kill counts
    s_uses: Vector<u64>, // origin_live_points: point<<32|local records
    s_cur64: Vector<u64>, // origin_live_points block state / conflicts replay row
    s_dset: Vector<u64>, // origin_live_points: per-pair defs
    s_uset: Vector<u64>, // origin_live_points: per-pair uses
    s_flow: Vector<u64>, // scope_flow: transfer scratch row
    s_flow_queued: Vector<bool>, // scope_flow, and the prepass worklist
    s_flow_queue: Vector<u32>,
    s_lo_start: Vector<u32>, // origin_live_points: per-local CSR into s_lo_flat of inference origins
    s_lo_flat: Vector<u32>,
    s_lb_start: Vector<u32>, // conflicts: per-local CSR into s_lb_flat of loans by place base;
    // the prepass: per origin, CSR of the subset sources flowing into it
    s_lb_flat: Vector<u32>,
    s_omask: Vector<u64>, // origin_live_points: per local word, the locals owning an inference origin
    s_open: Vector<u32>, // live_intervals: per local, top point + 1 of its open interval (0 = closed)
    s_opos: Vector<u32>, // live_intervals: per open local, its index in s_members
    s_members: Vector<u32>, // live_intervals: the open locals
    s_flags: Vector<u8>, // live_intervals: per local, this pair's def (1), use (2), copy-out (4) records
    s_touched: Vector<u32>, // live_intervals: the locals with records in this pair
    s_ivloc: Vector<u32>, // live_intervals: per closed interval (s_ivrec), its local
    s_ivrec: Vector<u64>, // live_intervals: closed intervals in block order, start << 32 | end
    s_rq: Vector<u32>, // required (sparse): the flood's required points before sorting
}

/// Origin x point cells above which a body takes the sparse rows.
pub const SPARSE_MIN_CELLS: u64 = 1u64 << 20;

// The reference level (0 or 1) a loan at level `d` reaches over a subset edge of kind `delta`,
// or 2 when the edge drops it (see bf::SD_KEEP).
const fn edge_level(delta: u8, d: u32) u32 {
    if delta == bf::SD_REF {
        return 1;
    }
    if delta == bf::SD_DEREF && d == 0 {
        return 2;
    }
    return d;
}

/// Solve body `b` from scratch: the returned solver's `errs` holds every borrow error.
pub fn solve(b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) Solver {
    let mut s = Solver::empty();
    s.build_into(b, f, c, lv);
    return s;
}

extend Solver {
    /// A solver with no body attached and no heap storage; `build_into` fills it.
    pub fn empty() Solver {
        return Solver {
            b: null,
            f: null,
            c: null,
            lv: null,
            errs: Vector::<BorrowErr>::new(),
            flow_pushes: 0,
            point_block: Vector::<u32>::new(),
            sub_by_point: Vector::<u32>::new(),
            sub_pt_start: Vector::<u32>::new(),
            live_pts: Vector::<u64>::new(),
            pwords: 0,
            oreach: Vector::<u64>::new(),
            owords: 0,
            cuts: Vector::<u64>::new(),
            req_cache: Vector::<u64>::new(),
            req_have: Vector::<bool>::new(),
            scope: ls::LoanMat::new(0, 0),
            kill_keys: Vector::<u64>::new(),
            ret_pts: Vector::<u32>::new(),
            sparse: false,
            lv_start: Vector::<u32>::new(),
            lv_iv: Vector::<u64>::new(),
            rq_range: Vector::<u64>::new(),
            rq_pts: Vector::<u32>::new(),
            tgt_col: Vector::<u32>::new(),
            vt: Vector::<u64>::new(),
            vt_used: Vector::<u32>::new(),
            vt_shift: 64,
            issues_blk: Vector::<u32>::new(),
            issue_start: Vector::<u32>::new(),
            kills_blk: Vector::<u64>::new(),
            kill_start: Vector::<u32>::new(),
            visit: Vector::<u64>::new(),
            visit_dirty: Vector::<u32>::new(),
            work: Vector::<u64>::new(),
            succs: Vector::<u32>::new(),
            s_cur32: Vector::<u32>::new(),
            s_ic: Vector::<u32>::new(),
            s_kc: Vector::<u32>::new(),
            s_uses: Vector::<u64>::new(),
            s_cur64: Vector::<u64>::new(),
            s_dset: Vector::<u64>::new(),
            s_uset: Vector::<u64>::new(),
            s_flow: Vector::<u64>::new(),
            s_flow_queued: Vector::<bool>::new(),
            s_flow_queue: Vector::<u32>::new(),
            s_lo_start: Vector::<u32>::new(),
            s_lo_flat: Vector::<u32>::new(),
            s_lb_start: Vector::<u32>::new(),
            s_lb_flat: Vector::<u32>::new(),
            s_omask: Vector::<u64>::new(),
            s_open: Vector::<u32>::new(),
            s_opos: Vector::<u32>::new(),
            s_members: Vector::<u32>::new(),
            s_flags: Vector::<u8>::new(),
            s_touched: Vector::<u32>::new(),
            s_ivloc: Vector::<u32>::new(),
            s_ivrec: Vector::<u64>::new(),
            s_rq: Vector::<u32>::new(),
        };
    }

    /// Heap bytes kept across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        return (self.errs.capacity() * sizeof(BorrowErr) + self.point_block.capacity() * sizeof(u32) + self.sub_by_point.capacity() * sizeof(u32) + self.sub_pt_start.capacity() * sizeof(u32) + self.live_pts.capacity() * sizeof(u64) + self.oreach.capacity() * sizeof(u64) + self.cuts.capacity() * sizeof(u64) + self.req_cache.capacity() * sizeof(u64) + self.req_have.capacity() * sizeof(bool) + self.issues_blk.capacity() * sizeof(u32) + self.issue_start.capacity() * sizeof(u32) + self.kills_blk.capacity() * sizeof(u64) + self.kill_start.capacity() * sizeof(u32) + self.visit.capacity() * sizeof(u64) + self.visit_dirty.capacity() * sizeof(u32) + self.work.capacity() * sizeof(u64) + self.succs.capacity() * sizeof(u32) + self.s_cur32.capacity() * sizeof(u32) + self.s_ic.capacity() * sizeof(u32) + self.s_kc.capacity() * sizeof(u32) + self.s_uses.capacity() * sizeof(u64) + self.s_cur64.capacity() * sizeof(u64) + self.s_dset.capacity() * sizeof(u64) + self.s_uset.capacity() * sizeof(u64) + self.s_flow.capacity() * sizeof(u64) + self.s_flow_queued.capacity() * sizeof(bool) + self.s_flow_queue.capacity() * sizeof(u32) + self.s_lo_start.capacity() * sizeof(u32) + self.s_lo_flat.capacity() * sizeof(u32) + self.s_lb_start.capacity() * sizeof(u32) + self.s_lb_flat.capacity() * sizeof(u32) + self.s_omask.capacity() * sizeof(u64) + self.scope.pool.capacity() * 8 + self.kill_keys.capacity() * sizeof(u64) + self.ret_pts.capacity() * sizeof(u32) + self.lv_start.capacity() * sizeof(u32) + self.lv_iv.capacity() * sizeof(u64) + self.rq_range.capacity() * sizeof(u64) + self.rq_pts.capacity() * sizeof(u32) + self.tgt_col.capacity() * sizeof(u32) + self.vt.capacity() * sizeof(u64) + self.vt_used.capacity() * sizeof(u32) + self.s_open.capacity() * sizeof(u32) + self.s_opos.capacity() * sizeof(u32) + self.s_members.capacity() * sizeof(u32) + self.s_flags.capacity() * sizeof(u8) + self.s_touched.capacity() * sizeof(u32) + self.s_ivloc.capacity() * sizeof(u32) + self.s_ivrec.capacity() * sizeof(u64) + self.s_rq.capacity() * sizeof(u32)) as u64;
    }

    /// Truncate every vector (keeping heap capacity) and clear scalars and scope, for reuse.
    pub fn reset(self: &mut Self) {
        self.pwords = 0;
        self.owords = 0;
        self.errs.truncate(0);
        self.flow_pushes = 0;
        self.point_block.truncate(0);
        self.sub_by_point.truncate(0);
        self.oreach.truncate(0);
        self.cuts.truncate(0);
        self.req_cache.truncate(0);
        self.req_have.truncate(0);
        self.issues_blk.truncate(0);
        self.issue_start.truncate(0);
        self.kills_blk.truncate(0);
        self.kill_start.truncate(0);
        self.visit.truncate(0);
        self.visit_dirty.truncate(0);
        self.work.truncate(0);
        self.succs.truncate(0);
        self.scope.reset_to(0, 0);
        self.kill_keys.truncate(0);
        self.ret_pts.truncate(0);
        self.lv_iv.truncate(0);
        self.rq_range.truncate(0);
        self.rq_pts.truncate(0);
        self.tgt_col.truncate(0);
        self.vt_clear();
    }

    /// Solve body `b` in place, keeping this solver's heap capacity from earlier bodies. Bodies above
    /// SPARSE_MIN_CELLS origin-point cells take the sparse rows.
    pub fn build_into(self: &mut Self, b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) {
        self.build_rows(b, f, c, lv, f.norigins as u64 * f.npoints as u64 > SPARSE_MIN_CELLS);
    }

    /// Solve body `b` in place with sparse (`sparse`) or dense rows.
    pub fn build_rows(
        self: &mut Self,
        b: &ir::CoreBody,
        f: &bf::BodyFacts,
        c: &df::Cfg,
        lv: &df::Liveness,
        sparse: bool,
    ) {
        let s = self;
        s.reset();
        s.sparse = sparse;
        s.b = b;
        s.f = f;
        s.c = c;
        s.lv = lv;
        // Zero loans: conflict, scope, and escape analysis have nothing to feed (each of their
        // errors names a loan).
        if f.loans.len() == 0 {
            return;
        }
        s.index_points();
        s.origin_live_points();
        s.prepass();
        s.scope_flow();
        s.conflicts();
        s.escapes();
    }

    const fn body(self: &Self) &ir::CoreBody {
        return unsafe &*self.b;
    }

    const fn fx(self: &Self) &bf::BodyFacts {
        return unsafe &*self.f;
    }

    const fn cfg(self: &Self) &df::Cfg {
        return unsafe &*self.c;
    }

    fn index_points(self: &mut Self) {
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        for bi in 0..c.nblocks {
            let base = f.block_base[bi as usize];
            let mut end = f.npoints;
            if (bi + 1) as usize < f.block_base.len() {
                end = f.block_base[bi as usize + 1];
            }
            for _p in base..end {
                self.point_block.push(bi);
            }
        }
        // Subsets sorted by point (counting sort: two passes over the fact vector).
        let n = f.subsets.len();
        self.sub_pt_start.truncate(0);
        self.sub_pt_start.resize_default((f.npoints + 1) as usize);
        for i in 0..n {
            let p = f.subsets.at(i).point;
            self.sub_pt_start.set(p as usize + 1, self.sub_pt_start[p as usize + 1] + 1);
        }
        for p in 0..f.npoints {
            self.sub_pt_start.set(p as usize + 1, self.sub_pt_start[p as usize + 1] + self.sub_pt_start[p as usize]);
        }
        self.s_cur32.truncate(0);
        for p in 0..f.npoints {
            self.s_cur32.push(self.sub_pt_start[p as usize]);
        }
        self.sub_by_point.resize_default(n);
        for i in 0..n {
            let p = f.subsets.at(i).point as usize;
            self.sub_by_point.set(self.s_cur32[p] as usize, i as u32);
            self.s_cur32.set(p, self.s_cur32[p] + 1);
        }
        // Rebind cuts sorted once: the flood asks cut_at for every node it visits.
        for i in 0..f.cuts.len() {
            self.cuts.push(f.cuts[i]);
        }
        self.cuts.sort();

        // Loan issues and kills bucketed per block.
        let nb = c.nblocks;
        self.s_ic.truncate(0);
        self.s_kc.truncate(0);
        self.s_ic.resize_default(nb as usize);
        self.s_kc.resize_default(nb as usize);
        for l in 0..f.loans.len() {
            let blk = self.point_block[f.loans.at(l).issued_at as usize] as usize;
            self.s_ic.set(blk, self.s_ic[blk] + 1);
        }
        for k in 0..f.kills.len() {
            let blk = self.point_block[f.kills.at(k).point as usize] as usize;
            self.s_kc.set(blk, self.s_kc[blk] + 1);
        }
        let mut ia: u32 = 0;
        let mut ka: u32 = 0;
        for bi in 0..nb {
            self.issue_start.push(ia);
            self.kill_start.push(ka);
            ia += self.s_ic[bi as usize];
            ka += self.s_kc[bi as usize];
            self.s_ic.set(bi as usize, 0);
            self.s_kc.set(bi as usize, 0);
        }
        self.issue_start.push(ia);
        self.kill_start.push(ka);
        self.issues_blk.resize_default(ia as usize);
        self.kills_blk.resize_default(ka as usize);
        for l in 0..f.loans.len() {
            let blk = self.point_block[f.loans.at(l).issued_at as usize] as usize;
            self.issues_blk.set((self.issue_start[blk] + self.s_ic[blk]) as usize, l as u32);
            self.s_ic.set(blk, self.s_ic[blk] + 1);
        }
        // The facts list call-argument kills during the walk and assignment kills after it, so
        // it is not point-ordered. Blocks number their points in block order: sorting the records
        // by point keeps each block's range where `kill_start` puts it and orders it for the
        // replay (`transfer_block` stops at the first kill past its point).
        for k in 0..f.kills.len() {
            self.kills_blk.set(k, f.kills.at(k).point as u64 << 32 | f.kills.at(k).loan as u64);
        }
        self.kills_blk.sort();
        // Sparse rows: kills by loan, sorted once, for the overwrite test and the in-scope query.
        if self.sparse {
            for k in 0..f.kills.len() {
                self.kill_keys.push(f.kills.at(k).loan as u64 << 32 | f.kills.at(k).point as u64);
            }
            self.kill_keys.sort();
        }
        // Return points, found once for every escape candidate.
        let bd = unsafe &*self.b;
        for bi in 0..nb {
            let blk = bd.blocks.at(bi as usize);
            if blk.term.kind == ir::TM_RETURN {
                self.ret_pts.push(f.block_base[bi as usize] + blk.stmt_len * 2);
            }
        }
    }

    // Statement-exact liveness points for every inference origin, from one backward replay of each
    // block against the boundary liveness solution.
    fn origin_live_points(self: &mut Self) {
        let bd = unsafe &*self.b;
        let f = unsafe &*self.f;
        let lw = f.lwords as usize;
        // Invert origin_local into a per-local CSR: each statement pair then touches only the
        // origins whose local is live there (found by scanning the live-word bits), instead of
        // testing every inference origin per pair: the old O(pairs * norigins) hot spot.
        let nl = bd.locals.len();
        self.s_lo_start.truncate(0);
        self.s_lo_start.resize_default(nl + 1);
        for o in f.nuniversal..f.norigins {
            let l = f.origin_local[o as usize];
            if l != bf::BF_NONE {
                self.s_lo_start.set(l as usize + 1, self.s_lo_start[l as usize + 1] + 1);
            }
        }
        for i in 0..nl {
            self.s_lo_start.set(i + 1, self.s_lo_start[i + 1] + self.s_lo_start[i]);
        }
        self.s_cur32.truncate(0);
        for i in 0..nl {
            self.s_cur32.push(self.s_lo_start[i]);
        }
        self.s_lo_flat.truncate(0);
        self.s_lo_flat.resize_default(self.s_lo_start[nl] as usize);
        for o in f.nuniversal..f.norigins {
            let l = f.origin_local[o as usize] as usize;
            if l as u32 != bf::BF_NONE {
                self.s_lo_flat.set(self.s_cur32[l] as usize, o);
                self.s_cur32.set(l, self.s_cur32[l] + 1);
            }
        }
        self.s_omask.truncate(0);
        self.s_omask.resize_default(lw);
        for l in 0..nl {
            if self.s_lo_start[l] != self.s_lo_start[l + 1] {
                self.s_omask.set(l / 64, self.s_omask[l / 64] | 1u64 << (l & 63) as u64);
            }
        }
        // Per-point use/def of locals, derived from accesses (a whole-local store defines, all else uses).
        // The four scratch vectors swap out of their reused Solver slots and back at the end.
        // Only locals that own an inference origin matter here (the fill below reads their CSR
        // range), so the record list and the live rows are cut to those locals up front. A record
        // is point << 32 | local, bit 63 marking a def and bit 62 a copy-out use.
        let mut uses = replace(&mut self.s_uses, Vector::<u64>::new()); // sorted by point
        uses.truncate(0);
        for a in 0..f.accesses.len() {
            let ac = *f.accesses.at(a);
            if ac.place == bf::BF_NONE {
                // Destruction of an owned carrier OBSERVES its stored borrows: a point-level use.
                if ac.local != bf::BF_NONE && f.observed[ac.local as usize] && (self.s_omask[(ac.local / 64) as usize] >> (ac.local & 63) as u64 & 1u64) != 0 {
                    uses.push(ac.point as u64 << 32 | ac.local as u64);
                }
                continue;
            }
            let pl = *self.body().places.at(ac.place as usize);
            if (self.s_omask[(pl.base / 64) as usize] >> (pl.base & 63) as u64 & 1u64) == 0 {
                continue;
            }
            let is_def = ac.def;
            let mut enc = ac.point as u64 << 32 | pl.base as u64;
            if is_def {
                enc = enc | 1u64 << 63;
            } else if ac.copy_out {
                enc = enc | 1u64 << 62;
            }
            uses.push(enc);
        }
        // Insertion sort by point (accesses are nearly point-ordered already).
        for i in 1..uses.len() {
            let v = uses[i];
            let mut j = i;
            while j > 0 && (uses[j - 1] & 0x3FFFFFFF00000000u64) > (v & 0x3FFFFFFF00000000u64) {
                uses.set(j, uses[j - 1]);
                j -= 1;
            }
            uses.set(j, v);
        }
        self.s_uses = uses;
        if self.sparse {
            self.live_intervals();
        } else {
            self.live_dense();
        }
    }

    // Dense rows: one bit per (inference origin, point).
    fn live_dense(self: &mut Self) {
        let bd = unsafe &*self.b;
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let lvr = unsafe &*self.lv;
        self.pwords = (f.npoints + 63) / 64;
        if self.pwords == 0 {
            self.pwords = 1;
        }
        let ninf = f.norigins - f.nuniversal;
        self.live_pts.truncate(0);
        self.live_pts.resize_default((ninf * self.pwords) as usize);
        let lw = f.lwords as usize;
        let nl = bd.locals.len();
        let uses = replace(&mut self.s_uses, Vector::<u64>::new());
        // Statement pairs backward (entry, exit). A definition is LIVE at both points of its own
        // statement (loans and subsets injected there must flow onward) and dead before it.
        // dset/uset live outside the block loop (the pair loop re-zeroes them) so a body allocates
        // them once, not per block.
        let mut cur = replace(&mut self.s_cur64, Vector::<u64>::new());
        let mut dset = replace(&mut self.s_dset, Vector::<u64>::new());
        let mut uset = replace(&mut self.s_uset, Vector::<u64>::new());
        // S_cur32 is free again after the CSR fill above; reuse it as the pair's dirty-word list.
        let mut dirty = replace(&mut self.s_cur32, Vector::<u32>::new());
        cur.truncate(0);
        dset.truncate(0);
        uset.truncate(0);
        cur.resize_default(lw);
        dset.resize_default(lw);
        uset.resize_default(lw);
        let mut ub: usize = 0; // running cursor into `uses` (blocks ascend, so it only moves forward)
        for bi in 0..c.nblocks {
            let base = f.block_base[bi as usize];
            let mut end = f.npoints;
            if (bi + 1) as usize < f.block_base.len() {
                end = f.block_base[bi as usize + 1];
            }
            for k in 0..lw {
                cur.set(k, lvr.live_out[bi as usize * lw + k]);
            }
            // Return slots are consumed by the return terminator itself.
            if bd.blocks.at(bi as usize).term.kind == ir::TM_RETURN {
                for r in 0..bd.returns {
                    cur.set((r / 64) as usize, cur[(r / 64) as usize] | 1u64 << (r & 63));
                }
            }
            // Blocks ascend and pairs descend while `uses` is point-sorted, so two monotone cursors
            // replace the per-block and per-pair binary searches: each use record is visited once.
            while ub < uses.len() && (uses[ub] >> 32 & 0x3FFFFFFFu64) < base as u64 {
                ub += 1;
            }
            let first = ub;
            while ub < uses.len() && (uses[ub] >> 32 & 0x3FFFFFFFu64) < end as u64 {
                ub += 1;
            }
            let mut wpos = ub;
            let mut p = end;
            // Dset/uset are all-zero at every pair entry: the fill below records the words it
            // touches and the pair's tail re-zeroes exactly those, so the per-pair cost follows
            // the pair's accesses instead of the full row width.
            while p > base + 1 {
                let hi2 = p - 1;
                let lo2 = p - 2;
                p -= 2;
                // Every use's point falls in exactly one pair; the window walks left as pairs descend.
                let mut wlo = wpos;
                while wlo > first && (uses[wlo - 1] >> 32 & 0x3FFFFFFFu64) >= lo2 as u64 {
                    wlo -= 1;
                }
                dirty.truncate(0);
                let hi_w = wpos;
                let mut i = wlo;
                while i < wpos {
                    let l = (uses[i] & 0xFFFFFFFFu64) as usize;
                    if (uses[i] >> 62 & 1u64) != 0 {
                        i += 1;
                        continue;
                    }
                    if (dset[l / 64] | uset[l / 64]) == 0 {
                        dirty.push((l / 64) as u32);
                    }
                    if uses[i] >> 63 != 0 {
                        dset.set(l / 64, dset[l / 64] | 1u64 << (l & 63) as u64);
                    } else {
                        uset.set(l / 64, uset[l / 64] | 1u64 << (l & 63) as u64);
                    }
                    i += 1;
                }
                wpos = wlo;
                // Record at both points: live-after plus this statement's uses and definitions.
                for k in 0..lw {
                    let mut m = (cur[k] | uset[k] | dset[k]) & self.s_omask[k];
                    while m != 0 {
                        let l = k * 64 + m.trailing_zeros();
                        m = m & m - 1u64;
                        if l >= nl {
                            continue;
                        }
                        for oi in self.s_lo_start[l]..self.s_lo_start[l + 1] {
                            let o = self.s_lo_flat[oi as usize];
                            let row = ((o - f.nuniversal) * self.pwords) as usize;
                            self.live_pts.set(
                                row + (lo2 / 64) as usize,
                                self.live_pts[row + (lo2 / 64) as usize] | 1u64 << (lo2 & 63) as u64,
                            );
                            self.live_pts.set(
                                row + (hi2 / 64) as usize,
                                self.live_pts[row + (hi2 / 64) as usize] | 1u64 << (hi2 & 63) as u64,
                            );
                        }
                    }
                }
                // live-before = (live-after - defs) | uses; untouched words have empty defs/uses,
                // so only the dirty words can change: fold their re-zeroing into the same pass.
                for di in 0..dirty.len() {
                    let k = dirty[di] as usize;
                    cur.set(k, cur[k] & ~dset[k] | uset[k]);
                    dset.set(k, 0u64);
                    uset.set(k, 0u64);
                }
                // A copy-out use is live at the entry point and before it, not at the exit.
                for j in wlo..hi_w {
                    if (uses[j] >> 62 & 1u64) == 0 {
                        continue;
                    }
                    let l = (uses[j] & 0xFFFFFFFFu64) as usize;
                    cur.set(l / 64, cur[l / 64] | 1u64 << (l & 63) as u64);
                    for oi in self.s_lo_start[l]..self.s_lo_start[l + 1] {
                        let o = self.s_lo_flat[oi as usize];
                        let row = ((o - f.nuniversal) * self.pwords) as usize;
                        self.live_pts.set(
                            row + (lo2 / 64) as usize,
                            self.live_pts[row + (lo2 / 64) as usize] | 1u64 << (lo2 & 63) as u64,
                        );
                    }
                }
            }
        }
        self.s_uses = uses;
        self.s_cur64 = cur;
        self.s_dset = dset;
        self.s_uset = uset;
        self.s_cur32 = dirty;
    }

    // Sparse rows: per local owning an inference origin, its live points as intervals. The same
    // backward pair replay as live_dense, driven by the records: a pair touches only the locals it
    // records, an interval opens where its local turns live and closes where it dies or at the
    // block's base, so the work follows the records and the intervals instead of the local count.
    fn live_intervals(self: &mut Self) {
        let bd = unsafe &*self.b;
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let lvr = unsafe &*self.lv;
        let lw = f.lwords as usize;
        let nl = bd.locals.len();
        let uses = replace(&mut self.s_uses, Vector::<u64>::new());
        let mut open = replace(&mut self.s_open, Vector::<u32>::new());
        let mut opos = replace(&mut self.s_opos, Vector::<u32>::new());
        let mut members = replace(&mut self.s_members, Vector::<u32>::new());
        let mut flags = replace(&mut self.s_flags, Vector::<u8>::new());
        let mut touched = replace(&mut self.s_touched, Vector::<u32>::new());
        let mut ivloc = replace(&mut self.s_ivloc, Vector::<u32>::new());
        let mut ivrec = replace(&mut self.s_ivrec, Vector::<u64>::new());
        open.truncate(0);
        opos.truncate(0);
        flags.truncate(0);
        open.resize_default(nl);
        opos.resize_default(nl);
        flags.resize_default(nl);
        members.truncate(0);
        ivloc.truncate(0);
        ivrec.truncate(0);
        let mut ub: usize = 0;
        for bi in 0..c.nblocks {
            let base = f.block_base[bi as usize];
            let mut end = f.npoints;
            if (bi + 1) as usize < f.block_base.len() {
                end = f.block_base[bi as usize + 1];
            }
            let first_iv = ivrec.len();
            // Live after the block: the live-out locals, plus the return slots a return consumes.
            for k in 0..lw {
                let mut m = lvr.live_out[bi as usize * lw + k] & self.s_omask[k];
                while m != 0 {
                    let l = k * 64 + m.trailing_zeros();
                    m = m & m - 1u64;
                    open.set(l, end);
                    opos.set(l, members.len() as u32);
                    members.push(l as u32);
                }
            }
            if bd.blocks.at(bi as usize).term.kind == ir::TM_RETURN {
                for r in 0..bd.returns {
                    let owns = (self.s_omask[(r / 64) as usize] >> (r & 63) as u64 & 1u64) != 0;
                    if owns && open[r as usize] == 0 {
                        open.set(r as usize, end);
                        opos.set(r as usize, members.len() as u32);
                        members.push(r);
                    }
                }
            }
            while ub < uses.len() && (uses[ub] >> 32 & 0x3FFFFFFFu64) < base as u64 {
                ub += 1;
            }
            let first = ub;
            while ub < uses.len() && (uses[ub] >> 32 & 0x3FFFFFFFu64) < end as u64 {
                ub += 1;
            }
            let mut wpos = ub;
            let mut p = end;
            while p > base + 1 {
                let hi2 = p - 1;
                let lo2 = p - 2;
                p -= 2;
                let mut wlo = wpos;
                while wlo > first && (uses[wlo - 1] >> 32 & 0x3FFFFFFFu64) >= lo2 as u64 {
                    wlo -= 1;
                }
                touched.truncate(0);
                for i in wlo..wpos {
                    let l = (uses[i] & 0xFFFFFFFFu64) as usize;
                    let bit: u8 = if uses[i] >> 63 != 0 {
                        1;
                    } else if (uses[i] >> 62 & 1u64) != 0 {
                        4;
                    } else {
                        2;
                    };
                    if flags[l] == 0 {
                        touched.push(l as u32);
                    }
                    flags.set(l, flags[l] | bit);
                }
                wpos = wlo;
                for ti in 0..touched.len() {
                    let l = touched[ti] as usize;
                    let fl = flags[l];
                    flags.set(l, 0);
                    // A use or definition is live at both points of its pair, a copy-out alone at
                    // the entry point only.
                    if open[l] == 0 {
                        let top = if (fl & 3) != 0 {
                            hi2;
                        } else {
                            lo2;
                        };
                        open.set(l, top + 1);
                        opos.set(l, members.len() as u32);
                        members.push(l as u32);
                    }
                    // Live before the pair unless only defined here.
                    if fl == 1 {
                        ivloc.push(l as u32);
                        ivrec.push(lo2 as u64 << 32 | (open[l] - 1) as u64);
                        let last = members[members.len() - 1];
                        members.set(opos[l] as usize, last);
                        opos.set(last as usize, opos[l]);
                        let _ = members.pop();
                        open.set(l, 0);
                    }
                }
            }
            // The block's base closes every interval still open.
            for mi in 0..members.len() {
                let l = members[mi] as usize;
                ivloc.push(l as u32);
                ivrec.push(base as u64 << 32 | (open[l] - 1) as u64);
                open.set(l, 0);
            }
            members.truncate(0);
            // A block closes intervals in descending order: reverse them so each local's ascend.
            let mut i = first_iv;
            let mut j = ivrec.len();
            while i + 1 < j {
                j -= 1;
                ivrec.swap(i, j);
                ivloc.swap(i, j);
                i += 1;
            }
        }
        // Rows by local (a stable counting sort keeps each row ascending).
        self.lv_start.truncate(0);
        self.lv_start.resize_default(nl + 1);
        for i in 0..ivloc.len() {
            let l = ivloc[i] as usize;
            self.lv_start.set(l + 1, self.lv_start[l + 1] + 1);
        }
        self.s_cur32.truncate(0);
        for l in 0..nl {
            self.lv_start.set(l + 1, self.lv_start[l + 1] + self.lv_start[l]);
            self.s_cur32.push(self.lv_start[l]);
        }
        self.lv_iv.truncate(0);
        self.lv_iv.resize_default(ivrec.len());
        for i in 0..ivloc.len() {
            let l = ivloc[i] as usize;
            self.lv_iv.set(self.s_cur32[l] as usize, ivrec[i]);
            self.s_cur32.set(l, self.s_cur32[l] + 1);
        }
        self.s_uses = uses;
        self.s_open = open;
        self.s_opos = opos;
        self.s_members = members;
        self.s_flags = flags;
        self.s_touched = touched;
        self.s_ivloc = ivloc;
        self.s_ivrec = ivrec;
    }

    // Is point `p` inside one of local `l`'s live intervals (sparse rows)?
    const fn local_live_at(self: &Self, l: u32, p: u32) bool {
        let i0 = self.lv_start[l as usize] as usize;
        let mut lo = i0;
        let mut hi = self.lv_start[l as usize + 1] as usize;
        // Past the last interval starting at or before `p`.
        let key = p as u64 << 32 | 0xFFFFFFFFu64;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.lv_iv[mid] <= key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo > i0 && (self.lv_iv[lo - 1] & 0xFFFFFFFFu64) >= p as u64;
    }

    const fn origin_live_at(self: &Self, o: u32, p: u32) bool {
        let f = self.fx();
        if o < f.nuniversal {
            return true;
        }
        if self.sparse {
            let l = f.origin_local[o as usize];
            return l != bf::BF_NONE && self.local_live_at(l, p);
        }
        let row = ((o - f.nuniversal) * self.pwords) as usize;
        return (*self.live_pts.at(row + (p / 64) as usize) >> (p & 63) as u64 & 1u64) != 0;
    }

    // Point-stripped origin reachability: the conservative candidate filter. A subset edge makes
    // `from` reach everything `to` reaches, so a worklist re-joins only the sources of an origin
    // whose row grew. Rows only gain bits, so an origin is queued at most norigins + 1 times.
    fn prepass(self: &mut Self) {
        let f = unsafe &*self.f;
        self.subset_sources();
        if self.sparse {
            self.reach_targets();
            return;
        }
        self.owords = (f.norigins + 63) / 64;
        if self.owords == 0 {
            self.owords = 1;
        }
        for o in 0..f.norigins {
            for w in 0..self.owords {
                let mut v: u64 = 0;
                if w == o / 64 {
                    v = 1u64 << (o & 63) as u64;
                }
                self.oreach.push(v);
            }
        }
        let no = f.norigins as usize;
        let ow = self.owords as usize;
        self.s_flow_queue.truncate(0);
        self.s_flow_queued.truncate(0);
        for o in 0..no {
            self.s_flow_queue.push((no - 1 - o) as u32);
            self.s_flow_queued.push(true);
        }
        while self.s_flow_queue.len() != 0 {
            let to = self.s_flow_queue[self.s_flow_queue.len() - 1] as usize;
            let _ = self.s_flow_queue.pop();
            self.s_flow_queued.set(to, false);
            for k in self.s_lb_start[to]..self.s_lb_start[to + 1] {
                let from = self.s_lb_flat[k as usize] as usize;
                let mut grew = false;
                for w in 0..ow {
                    let d = from * ow + w;
                    let v = self.oreach[d] | self.oreach[to * ow + w];
                    if v != self.oreach[d] {
                        self.oreach.set(d, v);
                        grew = true;
                    }
                }
                if grew && !self.s_flow_queued[from] {
                    self.s_flow_queued.set(from, true);
                    self.s_flow_queue.push(from as u32);
                }
            }
        }
    }

    // Subset sources grouped by target origin (counting sort) into s_lb_start / s_lb_flat.
    fn subset_sources(self: &mut Self) {
        let f = unsafe &*self.f;
        let no = f.norigins as usize;
        self.s_lb_start.truncate(0);
        self.s_lb_start.resize_default(no + 1);
        for i in 0..f.subsets.len() {
            let t = f.subsets.at(i).to as usize;
            self.s_lb_start.set(t + 1, self.s_lb_start[t + 1] + 1);
        }
        self.s_ic.truncate(0);
        for o in 0..no {
            self.s_lb_start.set(o + 1, self.s_lb_start[o + 1] + self.s_lb_start[o]);
            self.s_ic.push(self.s_lb_start[o]);
        }
        self.s_lb_flat.truncate(0);
        self.s_lb_flat.resize_default(f.subsets.len());
        for i in 0..f.subsets.len() {
            let e = *f.subsets.at(i);
            self.s_lb_flat.set(self.s_ic[e.to as usize] as usize, e.from);
            self.s_ic.set(e.to as usize, self.s_ic[e.to as usize] + 1);
        }
    }

    // The sparse prepass: reachability only toward the origins anything asks about, the
    // placeholders (escapes) and the return slots' origins (escape wording), one column each. Each
    // column is a backward search from its target over the subset sources, so an origin enters a
    // column's queue at most once.
    fn reach_targets(self: &mut Self) {
        let f = unsafe &*self.f;
        let bd = unsafe &*self.b;
        let no = f.norigins as usize;
        self.tgt_col.truncate(0);
        self.tgt_col.resize_default(no);
        for o in 0..no {
            self.tgt_col.set(o, bf::BF_NONE);
        }
        let mut ncol: u32 = 0;
        for u in 0..f.nuniversal {
            self.tgt_col.set(u as usize, ncol);
            ncol += 1;
        }
        for r in 0..bd.returns {
            if r as usize < f.local_origin.len() {
                let o = f.local_origin[r as usize];
                if o != bf::BF_NONE && self.tgt_col[o as usize] == bf::BF_NONE {
                    self.tgt_col.set(o as usize, ncol);
                    ncol += 1;
                }
            }
        }
        self.owords = (ncol + 63) / 64;
        if self.owords == 0 {
            self.owords = 1;
        }
        let ow = self.owords as usize;
        self.oreach.resize_default(no * ow);
        let mut queue = replace(&mut self.s_flow_queue, Vector::<u32>::new());
        for t in 0..no {
            let col = self.tgt_col[t];
            if col == bf::BF_NONE {
                continue;
            }
            let w = (col / 64) as usize;
            let bit = 1u64 << (col & 63) as u64;
            self.oreach.set(t * ow + w, self.oreach[t * ow + w] | bit);
            queue.truncate(0);
            queue.push(t as u32);
            while queue.len() != 0 {
                let to = queue[queue.len() - 1] as usize;
                let _ = queue.pop();
                for k in self.s_lb_start[to]..self.s_lb_start[to + 1] {
                    let from = self.s_lb_flat[k as usize] as usize;
                    if (self.oreach[from * ow + w] & bit) == 0 {
                        self.oreach.set(from * ow + w, self.oreach[from * ow + w] | bit);
                        queue.push(from as u32);
                    }
                }
            }
        }
        self.s_flow_queue = queue;
    }

    const fn prereach(self: &Self, from: u32, to: u32) bool {
        if self.sparse {
            let col = self.tgt_col[to as usize];
            assert(col != bf::BF_NONE, "the sparse prepass has a column for every asked target");
            return (*self.oreach.at(from as usize * self.owords as usize + (col / 64) as usize) >> (col & 63) as u64 & 1u64) != 0;
        }
        return (*self.oreach.at(from as usize * self.owords as usize + (to / 64) as usize) >> (to & 63) as u64 & 1u64) != 0;
    }

    /// Conservative origin reachability over subsets (the prepass relation).
    /// Production wording uses it to tell a returned borrow from a store-through-out-param escape.
    pub const fn origin_reaches(self: &Self, from: u32, to: u32) bool {
        return from == to || self.prereach(from, to);
    }

    /// A whole-local rebind at (origin `o`, stmt entry `p`): flows already in `o` end before the
    /// write; a subset ENTERING `o` at `p` lands past it (the incoming value survives its own store).
    pub const fn cut_at(self: &Self, o: u32, p: u32) bool {
        return switch self.cuts.binary_search(&(o as u64 << 32 | p as u64)) {
            Ok(_) => true,
            Err(_) => false,
        };
    }

    fn scope_flow(self: &mut Self) {
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let nb = c.nblocks;
        self.scope.reset_to(f.loans.len() as u32, nb);
        // Reused scratch, swapped out of the Solver slots and back at the end.
        let mut scratch = replace(&mut self.s_flow, Vector::<u64>::new());
        let mut queued = replace(&mut self.s_flow_queued, Vector::<bool>::new());
        let mut queue = replace(&mut self.s_flow_queue, Vector::<u32>::new());
        scratch.truncate(0);
        queued.truncate(0);
        queue.truncate(0);
        // Every block runs at least once: a block's own issues must reach its successors even when
        // its entry row never changes. Seed so the LIFO pops visit reachable blocks in exact RPO:
        // loans flow forward, so each sees converged predecessors on its first visit (the liveness
        // seed's mirror), with unreachable blocks after them (same converged state as before).
        queued.resize_default(nb as usize);
        for i in 0..c.rpo.len() {
            queued.set(c.rpo[i] as usize, true);
        }
        for bi in 0..nb {
            if !queued[bi as usize] {
                // Popped after the RPO run.
                queue.push(bi);
            }
        }
        for i in 0..c.rpo.len() {
            queue.push(c.rpo[c.rpo.len() - 1 - i]);
        }
        for bi in 0..nb {
            queued.set(bi as usize, true);
        }
        self.flow_pushes = nb;
        // Monotone bound: a block's entry row only gains loan bits, and each gain queues it once.
        let bound = nb as u64 + c.succ.len() as u64 * f.loans.len() as u64;
        while queue.len() != 0 {
            let bi = queue[queue.len() - 1];
            let _ = queue.pop();
            queued.set(bi as usize, false);
            self.transfer_block(bi, bf::BF_NONE, &mut scratch);
            for s in c.succ_start[bi as usize]..c.succ_start[bi as usize + 1] {
                let t = c.succ[s as usize];
                if self.scope.or_scratch(t, &scratch) && !queued[t as usize] {
                    queued.set(t as usize, true);
                    queue.push(t);
                    self.flow_pushes += 1;
                    assert(self.flow_pushes as u64 <= bound, "the loan scope fixpoint stays within its bound");
                }
            }
        }
        self.s_flow = scratch;
        self.s_flow_queued = queued;
        self.s_flow_queue = queue;
    }

    // Replay block `bi` from its entry row through the facts at points below `before` (BF_NONE:
    // the whole block). Leaves the state in `scratch`.
    fn transfer_block(self: &mut Self, bi: u32, before: u32, scratch: &mut Vector<u64>) {
        let f = self.fx();
        self.scope.read_row(bi, scratch);
        // Issues and kills interleave in point order (both lists are already point-sorted); a kill
        // recorded before a loan's issue must not clear that later issue.
        let mut i = self.issue_start[bi as usize];
        let ie = self.issue_start[bi as usize + 1];
        let mut k = self.kill_start[bi as usize];
        let ke = self.kill_start[bi as usize + 1];
        while i < ie || k < ke {
            let ip: u32 = if i < ie {
                f.loans.at(self.issues_blk[i as usize] as usize).issued_at;
            } else {
                bf::BF_NONE;
            };
            let kp: u32 = if k < ke {
                (self.kills_blk[k as usize] >> 32) as u32;
            } else {
                bf::BF_NONE;
            };
            if kp != bf::BF_NONE && (ip == bf::BF_NONE || kp <= ip) {
                if kp >= before {
                    break;
                }
                bits::bit_clear(scratch, (self.kills_blk[k as usize] & 0xFFFFFFFFu64) as u32);
                k += 1;
            } else if ip != bf::BF_NONE {
                if ip >= before {
                    break;
                }
                bits::bit_set(scratch, self.issues_blk[i as usize]);
                i += 1;
            }
        }
    }

    // Point successors: entry -> exit within a statement, exit -> next entry, terminator exit -> the
    // base point of every CFG successor.
    fn point_succs(self: &Self, p: u32, out: &mut Vector<u32>) {
        out.clear();
        let f = self.fx();
        let bi = self.point_block[p as usize];
        let mut end = f.npoints;
        if (bi + 1) as usize < f.block_base.len() {
            end = f.block_base[bi as usize + 1];
        }
        if p + 1 < end {
            out.push(p + 1);
            return;
        }
        for s in self.cfg().succ_start[bi as usize]..self.cfg().succ_start[bi as usize + 1] {
            out.push(f.block_base[self.cfg().succ[s as usize] as usize]);
        }
    }

    // Empty the sparse visited set, keeping its table.
    fn vt_clear(self: &mut Self) {
        for i in 0..self.vt_used.len() {
            self.vt.set(self.vt_used[i] as usize, 0u64);
        }
        self.vt_used.truncate(0);
    }

    // The visited set's slot for node key `k` (origin << 32 | point): its entry, or the empty slot it
    // takes. The table stays at most half full.
    const fn vt_find(self: &Self, k: u64) usize {
        let mask = self.vt.len() - 1;
        let mut i = (k.wrapping_mul(0x9E3779B97F4A7C15u64) >> self.vt_shift as u64) as usize;
        for _ in 0..self.vt.len() {
            let e = self.vt[i];
            if e == 0 || e >> 2 == k {
                return i;
            }
            i = i + 1 & mask;
        }
        assert(false, "the visited set is never full");
        return 0;
    }

    // Double the visited set's table (64 slots first) and re-place its entries.
    fn vt_grow(self: &mut Self) {
        let mut n = self.vt.len() * 2;
        if n < 64 {
            n = 64;
        }
        let old = replace(&mut self.vt, Vector::<u64>::new());
        self.vt.resize_default(n);
        self.vt_shift = 64 - n.trailing_zeros() as u32;
        for i in 0..self.vt_used.len() {
            let e = old[self.vt_used[i] as usize];
            let slot = self.vt_find(e >> 2);
            self.vt.set(slot, e);
            self.vt_used.set(i, slot as u32);
        }
    }

    // Mark flood node (o, p) visited at level `d` (level 1 covers level 0, as in the dense bits);
    // false when it already was.
    fn vt_mark(self: &mut Self, o: u32, p: u32, d: u32) bool {
        let k = o as u64 << 32 | p as u64;
        let slot = self.vt_find(k);
        let e = self.vt[slot];
        if (e >> d as u64 & 1u64) != 0 {
            return false;
        }
        if e == 0 {
            self.vt_used.push(slot as u32);
        }
        self.vt.set(slot, k << 2 | e & 3u64 | 1u64 + 2u64 * d as u64);
        if self.vt_used.len() * 2 > self.vt.len() {
            self.vt_grow();
        }
        return true;
    }

    /// The row where loan `li` is required: some origin that can hold it is live there. Dense rows
    /// are point bitsets (`req_word`), sparse rows sorted point lists; `req_at` reads either.
    pub fn required(self: &mut Self, li: u32) usize {
        let f = unsafe &*self.f;
        if self.req_have.len() == 0 {
            self.req_have.resize_default(f.loans.len());
            if self.sparse {
                self.rq_range.resize_default(f.loans.len());
            } else {
                self.req_cache.resize_default(f.loans.len() * self.pwords as usize);
            }
        }
        let row = if self.sparse {
            li as usize;
        } else {
            (li * self.pwords) as usize;
        };
        if self.req_have[li as usize] {
            return row;
        }
        self.req_have.set(li as usize, true);
        if self.sparse {
            assert(f.norigins < 1u32 << 30, "a visited-set key leaves room for its level bits");
            self.vt_clear();
            if self.vt.len() == 0 {
                self.vt_grow();
            }
            self.s_rq.truncate(0);
        } else {
            // Two visit bits per (origin, point): the loan's reference level there (bf::SD_KEEP).
            let vwords = ((f.norigins as u64 * f.npoints as u64 * 2 + 63) / 64) as usize;
            // Keep `visit` sized once per body and clear only the words the previous query set: the
            // flood touches at most `steps` words, so this is O(touched) instead of
            // O(norigins*npoints/64).
            self.visit.resize_default(vwords);
            for d in 0..self.visit_dirty.len() {
                self.visit.set(self.visit_dirty[d] as usize, 0u64);
            }
            self.visit_dirty.truncate(0);
        }
        self.work.clear();
        let lo = *f.loans.at(li as usize);
        // A loan never flows into the origin of the local it borrows: `&mut p` handed onward must
        // not pin `p` through p's OWN origin (the invariance backlink would self-contain it).
        let self_org = f.local_origin[self.body().places.at(lo.place as usize).base as usize];
        self.work.push(lo.origin as u64 << 32 | lo.issued_at as u64 | lo.deep as u64 << 31);
        let mut succs = replace(&mut self.succs, Vector::<u32>::new());
        while self.work.len() != 0 {
            let node = self.work[self.work.len() - 1];
            let _ = self.work.pop();
            let o = (node >> 32) as u32;
            let p = (node & 0x7FFFFFFFu64) as u32;
            let d = (node >> 31 & 1u64) as u32;
            // Level 1 reaches everything level 0 reaches (no edge drops it), so it marks both.
            if self.sparse {
                if !self.vt_mark(o, p, d) {
                    continue;
                }
            } else {
                let bit = (o as u64 * f.npoints as u64 + p as u64) * 2;
                let w = (bit / 64) as usize;
                let msk = 1u64 + 2u64 * d as u64 << (bit & 63);
                if (self.visit[w] & 1u64 << (bit & 63) + d as u64) != 0 {
                    continue;
                }
                if self.visit[w] == 0 {
                    self.visit_dirty.push(w as u32);
                }
                self.visit.set(w, self.visit[w] | msk);
            }
            if self.origin_live_at(o, p) {
                if self.sparse {
                    self.s_rq.push(p);
                } else {
                    self.req_cache.set(
                        row + (p / 64) as usize,
                        self.req_cache[row + (p / 64) as usize] | 1u64 << (p & 63) as u64,
                    );
                }
            }
            // Subset edges at this point.
            for i in self.sub_pt_start[p as usize]..self.sub_pt_start[p as usize + 1] {
                let e = *f.subsets.at(self.sub_by_point[i as usize] as usize);
                let nd = edge_level(e.delta, d);
                if e.from == o && nd <= 1 && (self_org == bf::BF_NONE || e.to != self_org) {
                    let mut tp = p;
                    if self.cut_at(e.to, p) {
                        tp = p + 1;
                    }
                    self.work.push(e.to as u64 << 32 | tp as u64 | nd as u64 << 31);
                }
            }
            // Liveness edges along the CFG (universal origins always flow, rebind cuts sever).
            self.point_succs(p, &mut succs);
            for s in 0..succs.len() {
                let q = succs[s];
                if q == p + 1 && self.cut_at(o, p) {
                    continue;
                }
                if o < f.nuniversal || self.origin_live_at(o, q) {
                    self.work.push(o as u64 << 32 | q as u64 | d as u64 << 31);
                }
            }
        }
        // Return the reused scratch to the solver, keeping its capacity.
        self.succs = succs;
        if self.sparse {
            self.s_rq.sort();
            let start = self.rq_pts.len();
            for i in 0..self.s_rq.len() {
                if i == 0 || self.s_rq[i] != self.s_rq[i - 1] {
                    self.rq_pts.push(self.s_rq[i]);
                }
            }
            self.rq_range.set(li as usize, start as u64 << 32 | self.rq_pts.len() as u64);
        }
        return row;
    }

    // Is `p` the entry point of a call terminator?
    const fn call_entry(self: &Self, p: u32) bool {
        let bi = self.point_block[p as usize] as usize;
        let blk = self.body().blocks.at(bi);
        return blk.term.kind == ir::TM_CALL && self.fx().block_base[bi] + blk.stmt_len * 2 == p;
    }

    const fn req_at(self: &Self, row: usize, p: u32) bool {
        if self.sparse {
            let r = self.rq_range[row];
            let mut lo = (r >> 32) as usize;
            let mut hi = (r & 0xFFFFFFFFu64) as usize;
            while lo < hi {
                let mid = lo + (hi - lo) / 2;
                if self.rq_pts[mid] < p {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo < (r & 0xFFFFFFFFu64) as usize && self.rq_pts[lo] == p;
        }
        return (*self.req_cache.at(row + (p / 64) as usize) >> (p & 63) as u64 & 1u64) != 0;
    }

    /// Word `w` of the cached dense required-loan row starting at `row`.
    pub const fn req_word(self: &Self, row: usize, w: u32) u64 {
        return *self.req_cache.at(row + w as usize);
    }

    // Does access `ac` invalidate loan `li` by kind (two-phase aware)?
    const fn kind_conflicts(self: &Self, lo: &bf::Loan, ac: &bf::Access) bool {
        if ac.kind == bf::ACC_READ {
            if lo.kind == bf::LK_SHARED {
                return false;
            }
            if lo.kind == bf::LK_RESERVED {
                // Reads stay legal through the activating call itself (its own argument reads
                // share the activation point); the claim is exclusive only past it.
                return lo.activated_at != bf::BF_NONE && ac.point > lo.activated_at;
            }
            return true;
        }
        return true;
    }

    // Sparse rows: does loan `li` have a kill at a point in [lo, hi)?
    const fn killed_in(self: &Self, li: u32, lo: u32, hi: u32) bool {
        if lo >= hi {
            return false;
        }
        let first = li as u64 << 32 | lo as u64;
        let mut a: usize = 0;
        let mut z = self.kill_keys.len();
        while a < z {
            let mid = a + (z - a) / 2;
            if self.kill_keys[mid] < first {
                a = mid + 1;
            } else {
                z = mid;
            }
        }
        return a < self.kill_keys.len() && self.kill_keys[a] < (li as u64 << 32 | hi as u64);
    }

    /// Sparse rows: is loan `li` in scope just before access point `p`? The block replay
    /// (transfer_block before p) for one loan: its single issue and its kills in the block before
    /// `p` decide, a kill at the issue's own point applying first. At a block's first point the
    /// entry row alone decides.
    pub const fn in_scope(self: &Self, li: u32, p: u32) bool {
        let f = self.fx();
        let bi = self.point_block[p as usize];
        let base = f.block_base[bi as usize];
        let ip = f.loans.at(li as usize).issued_at;
        if ip >= base && ip < p {
            return !self.killed_in(li, ip + 1, p);
        }
        return self.scope.get(bi, li) && !self.killed_in(li, base, p);
    }

    fn conflicts(self: &mut Self) {
        let f = unsafe &*self.f;
        let mut scratch = replace(&mut self.s_flow, Vector::<u64>::new());
        let na = f.accesses.len();
        let nl = f.loans.len();
        // Every conflict needs the loan and the access to share a base local (the whole-local
        // branch tests it, places_conflict demands it), so bucket loans by base and sweep only
        // the access's own bucket: O(accesses + same-base pairs) instead of accesses * loans.
        // Bucket order is ascending loan id: the exact subsequence the full sweep visited.
        let bucketed = na * nl >= 1024;
        if bucketed {
            bf::bucket_loans_by_base(
                unsafe &*self.b,
                &f.loans,
                &mut self.s_lb_start,
                &mut self.s_lb_flat,
                &mut self.s_ic,
            );
        }
        for a in 0..na {
            let ac = *f.accesses.at(a);
            let mut it0: usize = 0;
            let mut it1 = nl;
            let mut scoped = false;
            if bucketed {
                let base = if ac.place == bf::BF_NONE {
                    ac.local as usize;
                } else {
                    self.body().places.at(ac.place as usize).base as usize;
                };
                it0 = self.s_lb_start[base] as usize;
                it1 = self.s_lb_start[base + 1] as usize;
            }
            for it in it0..it1 {
                let li = if bucketed {
                    self.s_lb_flat[it] as usize;
                } else {
                    it;
                };
                let lo = *f.loans.at(li);
                if ac.place == bf::BF_NONE {
                    // Whole-local access: the borrowed storage dies. A loan THROUGH a dereference
                    // borrows foreign storage and merely becomes unreachable (its kill handles it),
                    // and a loan on a VIEW value aliases what the view points at, not this storage.
                    if lo.view {
                        continue;
                    }
                    if lo.pin && f.moved_whole[self.body().places.at(lo.place as usize).base as usize] {
                        // The pinned container's ownership travelled with a move.
                        continue;
                    }
                    if self.body().places.at(lo.place as usize).base != ac.local || self.body().place_has_deref(
                        lo.place,
                    ) {
                        continue;
                    }
                } else {
                    if ac.point == lo.issued_at || ac.point == lo.activated_at && ac.place == lo.place {
                        // A loan's own issue/activation is not an invalidation of itself.
                        continue;
                    }
                    if !self.kind_conflicts(&lo, &ac) {
                        continue;
                    }
                    if lo.pin && (ac.kind == bf::ACC_MOVE || ac.kind == bf::ACC_FREE) && self.body().places.at(
                        ac.place as usize,
                    ).proj_len == 0 {
                        // Element views ride a whole-container move (heap storage is stable):
                        // the walk accepts this, so the pin must too.
                        continue;
                    }

                    if !bf::places_conflict(self.body(), lo.place, ac.place) {
                        continue;
                    }
                }
                // In scope at the access? Dense rows replay the access's block row once; sparse rows
                // ask per loan, as a row costs a word per 64 loans at every access.
                if !self.sparse {
                    if !scoped {
                        self.transfer_block(self.point_block[ac.point as usize], ac.point, &mut scratch);
                        scoped = true;
                    }
                    if !bits::bit_get(&scratch, li as u32) {
                        continue;
                    }
                } else if !self.in_scope(li as u32, ac.point) {
                    continue;
                }
                // Still required (some live origin can hold it)?
                let row = self.required(li as u32);
                if !self.req_at(row, ac.point) {
                    continue;
                }
                // Does this write KILL the loan (it overwrites the borrowed storage)? Then the
                // conflict exists only if the loan is still wanted past this statement
                // (`rel = rel.slice(..)` re-owns; `x = 2; *r` still dangles).
                let mut overwrite = false;
                if ac.kind == bf::ACC_WRITE {
                    if self.sparse {
                        overwrite = self.killed_in(li as u32, ac.point, ac.point + 1);
                    } else {
                        // A dense body is small: scan every kill.
                        for kk in 0..f.kills.len() {
                            let kl = *f.kills.at(kk);
                            if kl.loan == li as u32 && kl.point == ac.point {
                                overwrite = true;
                            }
                        }
                    }
                }
                if overwrite && lo.deref {
                    // Overwriting the reference a reborrow went through replaces the reference, not
                    // the borrowed pointee: the write only ends the loan.
                    continue;
                }
                // A write at a call's entry is an argument autoref claiming `&mut`, and an activation
                // there is a two-phase `&mut` argument claiming it: the claim takes effect after the
                // argument reads, so a loan only those reads required (copy-out uses stop at the
                // entry) is over by then, and a loan an argument hands to the callee is not.
                let claim = (ac.kind == bf::ACC_WRITE || ac.kind == bf::ACC_ACT) && self.call_entry(ac.point);
                if ac.kind == bf::ACC_ACT || overwrite || claim {
                    // Two-phase activation (and an overwriting kill) tolerates loans whose LAST
                    // requirement is this statement itself. Same-pair liveness injection reaches
                    // point + 1, so "later" starts past the pair, except for a call claim: every
                    // argument but a copy-out stays live at the call's exit. A loan wanted at any
                    // later point on a path through this access is wanted there: its holder must
                    // stay live across it, and the flood only advances through live points.
                    let mut later = false;
                    if claim && !overwrite {
                        later = self.req_at(row, ac.point + 1);
                    } else {
                        let mut succs = replace(&mut self.succs, Vector::<u32>::new());
                        self.point_succs(ac.point + 1, &mut succs);
                        for k in 0..succs.len() {
                            if self.req_at(row, succs[k]) {
                                later = true;
                            }
                        }
                        self.succs = succs;
                    }
                    if !later {
                        continue;
                    }
                }
                let mut sp = ac.span;
                let mut ak = ac.kind;
                if ac.place == bf::BF_NONE {
                    // Point at the borrow that outlives its storage.
                    sp = lo.span;
                    ak = ACC_DEAD;
                }
                self.errs.push(BorrowErr { kind: BE_CONFLICT, acc: ak, loan: li as u32, point: ac.point, span: sp });
            }
        }
        self.s_flow = scratch;
    }

    // A loan of storage this body owns must never reach a placeholder that is live at a return.
    fn escapes(self: &mut Self) {
        let f = unsafe &*self.f;
        let bd = unsafe &*self.b;
        for li in 0..f.loans.len() {
            let lo = *f.loans.at(li);
            if lo.view {
                // A borrow OF a view chains to the view's own origin, not local storage.
                continue;
            }
            if lo.pin && f.moved_whole[self.body().places.at(lo.place as usize).base as usize] {
                // A moved container carries its pinned views with it.
                continue;
            }
            let pl = *bd.places.at(lo.place as usize);
            let st = bd.locals.at(pl.base as usize).storage;
            if st == ir::LS_STATIC_REF {
                continue;
            }
            if bd.place_has_deref(lo.place) {
                // A reborrow's storage belongs to the reference it went through.
                continue;
            }
            // Prepass filter, then precise flood: does the loan reach any placeholder?
            let mut cand = false;
            for u in 0..f.nuniversal {
                if self.prereach(lo.origin, u) && lo.origin != u {
                    cand = true;
                }
            }
            if !cand {
                continue;
            }
            let row = self.required(li as u32);
            // The flood marked universal-held points; find one at a return terminator. Rebind cuts
            // already stop flows a reassignment ended (`r = &x; r = p; return r` escapes p, not x).
            for ri in 0..self.ret_pts.len() {
                let p = self.ret_pts[ri];
                if self.req_at(row, p) || self.req_at(row, p + 1) {
                    self.errs.push(BorrowErr { kind: BE_ESCAPE, acc: 0, loan: li as u32, point: p, span: lo.span });
                    break;
                }
            }
        }
    }

    /// Validation: `self` (sparse rows) and `d` (dense rows), solved over the same body, agree on
    /// the errors in order, every loan's required points, every inference origin's live points, the
    /// prepass columns the sparse rows keep, and the in-scope bit against the block replay at every
    /// access for every loan on its base (the conflicts' candidates).
    pub fn assert_agrees(self: &mut Self, d: &mut Solver) {
        assert(self.sparse && !d.sparse, "one sparse and one dense solve");
        assert(self.errs.len() == d.errs.len(), "sparse and dense rows find as many borrow errors");
        for i in 0..self.errs.len() {
            let a = *self.errs.at(i);
            let b = *d.errs.at(i);
            assert(
                a.kind == b.kind && a.acc == b.acc && a.loan == b.loan && a.point == b.point && a.span.start == b.span.start && a.span.end == b.span.end,
                "sparse and dense rows find the same borrow errors in the same order",
            );
        }
        let f = unsafe &*self.f;
        let bd = unsafe &*self.b;
        if f.loans.len() == 0 {
            return;
        }
        for li in 0..f.loans.len() {
            let rs = self.required(li as u32);
            let rd = d.required(li as u32);
            let r = self.rq_range[rs];
            let mut k = (r >> 32) as usize;
            for w in 0..d.pwords {
                let mut m = d.req_word(rd, w);
                while m != 0 {
                    let p = w as usize * 64 + m.trailing_zeros();
                    m = m & m - 1u64;
                    assert(
                        k < (r & 0xFFFFFFFFu64) as usize && self.rq_pts[k] as usize == p,
                        "a required point in both rows",
                    );
                    k += 1;
                }
            }
            assert(k == (r & 0xFFFFFFFFu64) as usize, "no required point only in the sparse row");
        }
        for o in f.nuniversal..f.norigins {
            let l = f.origin_local[o as usize];
            let mut n: u64 = 0;
            for w in 0..d.pwords {
                let mut m = d.live_pts[((o - f.nuniversal) * d.pwords + w) as usize];
                while m != 0 {
                    let p = w * 64 + m.trailing_zeros() as u32;
                    m = m & m - 1u64;
                    assert(l != bf::BF_NONE && self.local_live_at(l, p), "a live point in both rows");
                    n += 1;
                }
            }
            if l != bf::BF_NONE {
                for i in self.lv_start[l as usize]..self.lv_start[l as usize + 1] {
                    let iv = self.lv_iv[i as usize];
                    n -= (iv & 0xFFFFFFFFu64) - (iv >> 32) + 1;
                }
            }
            assert(n == 0, "no live point only in the sparse row");
        }
        for t in 0..f.norigins {
            if self.tgt_col[t as usize] == bf::BF_NONE {
                continue;
            }
            for o in 0..f.norigins {
                assert(self.prereach(o, t) == d.prereach(o, t), "the prepass columns agree");
            }
        }
        let mut start = Vector::<u32>::new();
        let mut flat = Vector::<u32>::new();
        let mut cur = Vector::<u32>::new();
        let mut row = Vector::<u64>::new();
        bf::bucket_loans_by_base(bd, &f.loans, &mut start, &mut flat, &mut cur);
        for a in 0..f.accesses.len() {
            let ac = *f.accesses.at(a);
            let base = if ac.place == bf::BF_NONE {
                ac.local as usize;
            } else {
                bd.places.at(ac.place as usize).base as usize;
            };
            d.transfer_block(d.point_block[ac.point as usize], ac.point, &mut row);
            for it in start[base]..start[base + 1] {
                let li = flat[it as usize];
                assert(
                    self.in_scope(li, ac.point) == bits::bit_get(&row, li),
                    "the in-scope query matches the block replay",
                );
            }
        }
    }
}

/// Small, slow, and independent: materializes every (origin, point) node and edge, then answers each
/// loan query by direct search. Development comparisons only: never part of compilation.
pub struct RefResult {
    pub required: Vector<u64>, // per loan: point bitset rows (pwords each)
    pub pwords: u32,
}

pub fn solve_reference(b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) RefResult {
    // Rebuild statement-exact origin liveness with the optimized path's own helper, then do the
    // dumbest possible thing: per loan, breadth-first over an explicit edge list.
    let sv = solve(b, f, c, lv);
    let mut pwords = (f.npoints + 63) / 64;
    if pwords == 0 {
        pwords = 1;
    }
    let mut r = RefResult { required: Vector::<u64>::new(), pwords: pwords };
    // Explicit edges: (o, p) -> (o2, p) for subsets at p; (o, p) -> (o, q) for point succ q.
    for li in 0..f.loans.len() {
        let lo = *f.loans.at(li);
        let mut seen = Vector::<u64>::new();
        let vwords = ((f.norigins as u64 * f.npoints as u64 * 2 + 63) / 64) as usize;
        seen.resize_default(vwords);
        let mut req = Vector::<u64>::new();
        req.resize_default(pwords as usize);
        let mut work = Vector::<u64>::new();
        let self_org = f.local_origin[b.places.at(lo.place as usize).base as usize];
        work.push(lo.origin as u64 << 32 | lo.issued_at as u64 | lo.deep as u64 << 31);
        let mut succs = Vector::<u32>::new();
        while work.len() != 0 {
            let node = work[work.len() - 1];
            let _ = work.pop();
            let o = (node >> 32) as u32;
            let p = (node & 0x7FFFFFFFu64) as u32;
            let d = (node >> 31 & 1u64) as u32;
            let bit = (o as u64 * f.npoints as u64 + p as u64) * 2 + d as u64;
            if (seen[(bit / 64) as usize] & 1u64 << (bit & 63)) != 0 {
                continue;
            }
            seen.set((bit / 64) as usize, seen[(bit / 64) as usize] | 1u64 << (bit & 63));
            if sv.origin_live_at(o, p) {
                req.set((p / 64) as usize, req[(p / 64) as usize] | 1u64 << (p & 63) as u64);
            }
            for i in 0..f.subsets.len() {
                let e = *f.subsets.at(i);
                let nd = edge_level(e.delta, d);
                if e.point == p && e.from == o && nd <= 1 && (self_org == bf::BF_NONE || e.to != self_org) {
                    let mut tp = p;
                    if sv.cut_at(e.to, p) {
                        tp = p + 1;
                    }
                    work.push(e.to as u64 << 32 | tp as u64 | nd as u64 << 31);
                }
            }
            sv.point_succs(p, &mut succs);
            for s in 0..succs.len() {
                let q = succs[s];
                if q == p + 1 && sv.cut_at(o, p) {
                    continue;
                }
                if o < f.nuniversal || sv.origin_live_at(o, q) {
                    work.push(o as u64 << 32 | q as u64 | d as u64 << 31);
                }
            }
        }
        for w in 0..pwords {
            r.required.push(req[w as usize]);
        }
    }
    return r;
}
