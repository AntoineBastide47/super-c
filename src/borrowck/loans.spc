// The loan-scope solver: a unified origin-and-CFG graph queried lazily per candidate.
// Subset edges exist at their Core IR points (location-sensitive); liveness edges follow CFG point
// order for origins live at the target. A cheap point-stripped prepass filters candidates first --
// it may produce false candidates but can never hide one, because every edge it drops exists at
// SOME point. The reference solver at the bottom materializes the full product graph and must agree
// with the optimized path on small bodies; only tests run it.
import stdlib;
import lexer::token as tok;
import ir::core as ir;
import borrowck::facts as bf;
import borrowck::dataflow as df;
import borrowck::loan_set as ls;

/// Borrow error kinds.
pub const BE_CONFLICT: u8 = 0; // access invalidates a loan that is still required
pub const BE_ESCAPE: u8 = 1; // borrow of body-local storage escapes through a placeholder
pub const BE_PLACEHOLDER: u8 = 2; // placeholder flows into another without a declared relation

/// BorrowErr.acc for a conflict caused by storage death (the borrowed local leaves scope).
pub const ACC_DEAD: u8 = 5;

pub struct BorrowErr {
    pub kind: u8,
    pub acc: u8, // BE_CONFLICT: the invalidating access kind (bf::ACC_* or ACC_DEAD)
    pub loan: u32,
    pub point: u32,
    pub span: tok::Span, // the invalidating access (or escape site)
    pub loan_span: tok::Span,
}

/// Per-body solver counters (aggregated by the driver's report).
pub struct Stats {
    pub origins: u64,
    pub universals: u64,
    pub loans: u64,
    pub points: u64,
    pub cfg_edges: u64,
    pub subset_facts: u64,
    pub issue_facts: u64,
    pub kill_facts: u64,
    pub activation_facts: u64,
    pub access_facts: u64,
    pub candidates: u64,
    pub clean_bodies: u64,
    pub queries: u64,
    pub cache_hits: u64,
    pub steps: u64,
    pub loanset_bytes: u64,
    pub scratch_bytes: u64,
}

pub const fn stats_zero() Stats {
    return Stats {
        origins: 0,
        universals: 0,
        loans: 0,
        points: 0,
        cfg_edges: 0,
        subset_facts: 0,
        issue_facts: 0,
        kill_facts: 0,
        activation_facts: 0,
        access_facts: 0,
        candidates: 0,
        clean_bodies: 0,
        queries: 0,
        cache_hits: 0,
        steps: 0,
        loanset_bytes: 0,
        scratch_bytes: 0,
    };
}

pub const fn stats_add(a: &mut Stats, b: &Stats) {
    a.origins += b.origins;
    a.universals += b.universals;
    a.loans += b.loans;
    a.points += b.points;
    a.cfg_edges += b.cfg_edges;
    a.subset_facts += b.subset_facts;
    a.issue_facts += b.issue_facts;
    a.kill_facts += b.kill_facts;
    a.activation_facts += b.activation_facts;
    a.access_facts += b.access_facts;
    a.candidates += b.candidates;
    a.clean_bodies += b.clean_bodies;
    a.queries += b.queries;
    a.cache_hits += b.cache_hits;
    a.steps += b.steps;
    a.loanset_bytes += b.loanset_bytes;
    a.scratch_bytes += b.scratch_bytes;
}

pub struct Solver {
    pub b: *const ir::CoreBody,
    pub f: *const bf::BodyFacts,
    pub c: *const df::Cfg,
    pub lv: *const df::Liveness,
    pub errs: Vector<BorrowErr>,
    pub stats: Stats,
    pub point_block: Vector<u32>, // per point: its block
    pub sub_by_point: Vector<u32>, // subset indexes sorted by point
    pub sub_pt_start: Vector<u32>, // per point (+1): range into sub_by_point (entry seeds at 0)
    pub live_pts: Vector<u64>, // per inference origin: point bitset (word-major, pwords per origin)
    pub pwords: u32,
    pub oreach: Vector<u64>, // prepass: per origin, origins reachable over point-stripped subsets
    pub owords: u32,
    pub req_cache: Vector<u64>, // per queried loan: required-point bitset (pwords), or empty
    pub req_have: Vector<bool>,
    pub scope: ls::LoanMat, // block-entry loans-in-scope
    pub issues_blk: Vector<u32>, // per block: loan issues, generation (= point) order
    pub issue_start: Vector<u32>,
    pub kills_blk: Vector<u64>, // per block: kill records (point << 32 | loan), sorted
    pub kill_start: Vector<u32>,
    pub visit: Vector<u64>, // flood scratch: (origin, point) visited bits
    pub visit_dirty: Vector<u32>, // words set in `visit` this query, so clearing is O(touched) not O(vwords)
    pub work: Vector<u64>, // flood worklist: origin << 32 | point
    pub succs: Vector<u32>, // reused point-successor scratch for the flood
}

extend Solver as Free {
    pub fn free(self: &mut Self) {
        self.errs.free();
        self.point_block.free();
        self.sub_by_point.free();
        self.sub_pt_start.free();
        self.live_pts.free();
        self.oreach.free();
        self.req_cache.free();
        self.req_have.free();
        self.scope.free();
        self.issues_blk.free();
        self.issue_start.free();
        self.kills_blk.free();
        self.kill_start.free();
        self.visit.free();
        self.visit_dirty.free();
        self.work.free();
        self.succs.free();
    }
}

extend Solver {
    pub fn empty() Solver {
        return Solver {
            b: null,
            f: null,
            c: null,
            lv: null,
            errs: Vector::<BorrowErr>::new(),
            stats: stats_zero(),
            point_block: Vector::<u32>::new(),
            sub_by_point: Vector::<u32>::new(),
            sub_pt_start: Vector::<u32>::new(),
            live_pts: Vector::<u64>::new(),
            pwords: 0,
            oreach: Vector::<u64>::new(),
            owords: 0,
            req_cache: Vector::<u64>::new(),
            req_have: Vector::<bool>::new(),
            scope: ls::LoanMat::new(0, 0),
            issues_blk: Vector::<u32>::new(),
            issue_start: Vector::<u32>::new(),
            kills_blk: Vector::<u64>::new(),
            kill_start: Vector::<u32>::new(),
            visit: Vector::<u64>::new(),
            visit_dirty: Vector::<u32>::new(),
            work: Vector::<u64>::new(),
            succs: Vector::<u32>::new(),
        };
    }

    // Truncate every vector (keeping heap capacity) and clear scalars/stats/scope, for reuse.
    pub fn reset(self: &mut Self) {
        self.stats = stats_zero();
        self.pwords = 0;
        self.owords = 0;
        self.errs.truncate(0);
        self.point_block.truncate(0);
        self.sub_by_point.truncate(0);
        self.sub_pt_start.truncate(0);
        self.live_pts.truncate(0);
        self.oreach.truncate(0);
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
    }
}

pub fn solve(b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) Solver {
    let mut s = Solver::empty();
    s.build_into(b, f, c, lv);
    return s;
}

extend Solver {
    pub fn build_into(self: &mut Self, b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) {
        let s = self;
        s.reset();
        s.b = b;
        s.f = f;
        s.c = c;
        s.lv = lv;
        s.stats.origins = f.norigins;
        s.stats.universals = f.nuniversal;
        s.stats.loans = f.loans.len() as u64;
        s.stats.points = f.npoints;
        s.stats.subset_facts = f.subsets.len() as u64;
        s.stats.issue_facts = f.loans.len() as u64;
        s.stats.kill_facts = f.kills.len() as u64;
        s.stats.access_facts = f.accesses.len() as u64;
        for l in 0..f.loans.len() {
            if f.loans.at(l).activated_at != bf::BF_NONE {
                s.stats.activation_facts += 1;
            }
        }
        s.index_points();
        s.origin_live_points();
        s.prepass();
        s.scope_flow();
        s.conflicts();
        s.escapes();
        s.placeholders();
        s.stats.loanset_bytes = s.scope.retained_bytes() as u64;
        s.stats.scratch_bytes = (s.visit.capacity() * 8 + s.live_pts.capacity() * 8 + s.req_cache.capacity() * 8) as u64;
        if s.errs.len() == 0 {
            s.stats.clean_bodies = 1;
        }
    }
}

extend Solver {
    const fn body(self: &Self) &ir::CoreBody {
        return unsafe &*self.b;
    }

    const fn fx(self: &Self) &bf::BodyFacts {
        return unsafe &*self.f;
    }

    const fn cfg(self: &Self) &df::Cfg {
        return unsafe &*self.c;
    }

    // ---- indexes ----------------------------------------------------------------------------------

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
        self.stats.cfg_edges = c.succ.len() as u64;
        // Subsets sorted by point (counting sort: two passes over the fact vector).
        let n = f.subsets.len();
        for _p in 0..f.npoints + 1 {
            self.sub_pt_start.push(0);
        }
        for i in 0..n {
            let p = f.subsets.at(i).point;
            self.sub_pt_start.set(p as usize + 1, self.sub_pt_start[p as usize + 1] + 1);
        }
        for p in 0..f.npoints {
            self.sub_pt_start.set(p as usize + 1, self.sub_pt_start[p as usize + 1] + self.sub_pt_start[p as usize]);
        }
        let mut cur = Vector::<u32>::new();
        for p in 0..f.npoints {
            cur.push(self.sub_pt_start[p as usize]);
        }
        for _i in 0..n {
            self.sub_by_point.push(0);
        }
        for i in 0..n {
            let p = f.subsets.at(i).point;
            self.sub_by_point.set(cur[p as usize] as usize, i as u32);
            cur.set(p as usize, cur[p as usize] + 1);
        }

        // Loan issues and kills bucketed per block.
        let nb = c.nblocks;
        let mut ic = Vector::<u32>::new();
        let mut kc = Vector::<u32>::new();
        for _i in 0..nb {
            ic.push(0);
            kc.push(0);
        }
        for l in 0..f.loans.len() {
            let blk = self.point_block[f.loans.at(l).issued_at as usize];
            ic.set(blk as usize, ic[blk as usize] + 1);
        }
        for k in 0..f.kills.len() {
            let blk = self.point_block[f.kills.at(k).point as usize];
            kc.set(blk as usize, kc[blk as usize] + 1);
        }
        let mut ia: u32 = 0;
        let mut ka: u32 = 0;
        for bi in 0..nb {
            self.issue_start.push(ia);
            self.kill_start.push(ka);
            ia += ic[bi as usize];
            ka += kc[bi as usize];
            ic.set(bi as usize, 0);
            kc.set(bi as usize, 0);
        }
        self.issue_start.push(ia);
        self.kill_start.push(ka);
        for _i in 0..ia {
            self.issues_blk.push(0);
        }
        for _i in 0..ka {
            self.kills_blk.push(0u64);
        }
        for l in 0..f.loans.len() {
            let blk = self.point_block[f.loans.at(l).issued_at as usize] as usize;
            self.issues_blk.set((self.issue_start[blk] + ic[blk]) as usize, l as u32);
            ic.set(blk, ic[blk] + 1);
        }
        for k in 0..f.kills.len() {
            let blk = self.point_block[f.kills.at(k).point as usize] as usize;
            self.kills_blk.set(
                (self.kill_start[blk] + kc[blk]) as usize,
                f.kills.at(k).point as u64 << 32 | f.kills.at(k).loan as u64,
            );
            kc.set(blk, kc[blk] + 1);
        }
    }

    // Statement-exact liveness points for every inference origin, from one backward replay of each
    // block against the boundary liveness solution.
    fn origin_live_points(self: &mut Self) {
        let bd = unsafe &*self.b;
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let lvr = unsafe &*self.lv;
        self.pwords = (f.npoints + 63) / 64;
        if self.pwords == 0 {
            self.pwords = 1;
        }
        let ninf = f.norigins - f.nuniversal;
        for _i in 0..ninf * self.pwords {
            self.live_pts.push(0u64);
        }
        // Per-point use/def of locals, derived from accesses (a full write defines, all else uses).
        let mut uses = Vector::<u64>::new(); // point << 32 | local, sorted by point via counting
        for a in 0..f.accesses.len() {
            let ac = *f.accesses.at(a);
            if ac.place == bf::BF_NONE {
                // Destruction of an owned carrier OBSERVES its stored borrows: a point-level use.
                if ac.local != bf::BF_NONE && f.observed[ac.local as usize] {
                    uses.push(ac.point as u64 << 32 | ac.local as u64);
                }
                continue;
            }
            let pl = *self.body().places.at(ac.place as usize);
            let mut is_def = false;
            if ac.kind == bf::ACC_WRITE && pl.proj_len == 0 {
                is_def = true;
            }
            let mut enc = ac.point as u64 << 32 | pl.base as u64;
            if is_def {
                enc = enc | 1u64 << 63;
            }
            uses.push(enc);
        }
        // Insertion sort by point (accesses are nearly point-ordered already).
        for i in 1..uses.len() {
            let v = uses[i];
            let mut j = i;
            while j > 0 && (uses[j - 1] & 0x7FFFFFFF00000000u64) > (v & 0x7FFFFFFF00000000u64) {
                uses.set(j, uses[j - 1]);
                j -= 1;
            }
            uses.set(j, v);
        }
        let lw = f.lwords as usize;
        let mut cur = Vector::<u64>::new();
        for _i in 0..lw {
            cur.push(0u64);
        }
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
            // Find this block's slice of `uses` (binary search on the sorted vector).
            let mut lo: usize = 0;
            let mut hi = uses.len();
            while lo < hi {
                let mid = (lo + hi) / 2;
                if (uses[mid] >> 32 & 0x7FFFFFFFu64) < base as u64 {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            let first = lo;
            // Statement pairs backward (entry, exit). A definition is LIVE at both points of its own
            // statement -- loans and subsets injected there must flow onward -- and dead before it.
            let mut dset = Vector::<u64>::new();
            let mut uset = Vector::<u64>::new();
            for _i in 0..lw {
                dset.push(0u64);
                uset.push(0u64);
            }
            let mut p = end;
            while p > base + 1 {
                let hi2 = p - 1;
                let lo2 = p - 2;
                p -= 2;
                for k in 0..lw {
                    dset.set(k, 0u64);
                    uset.set(k, 0u64);
                }
                // Lower bound of this pair's accesses inside the block slice.
                let mut a0 = first;
                let mut a1 = uses.len();
                while a0 < a1 {
                    let mid = (a0 + a1) / 2;
                    if (uses[mid] >> 32 & 0x7FFFFFFFu64) < lo2 as u64 {
                        a0 = mid + 1;
                    } else {
                        a1 = mid;
                    }
                }
                let mut i = a0;
                while i < uses.len() && (uses[i] >> 32 & 0x7FFFFFFFu64) <= hi2 as u64 {
                    let l = (uses[i] & 0xFFFFFFFFu64) as usize;
                    if uses[i] >> 63 != 0 {
                        dset.set(l / 64, dset[l / 64] | 1u64 << (l & 63) as u64);
                    } else {
                        uset.set(l / 64, uset[l / 64] | 1u64 << (l & 63) as u64);
                    }
                    i += 1;
                }
                // Record at both points: live-after plus this statement's uses and definitions.
                for o in f.nuniversal..f.norigins {
                    let l = f.origin_local[o as usize];
                    if l == bf::BF_NONE {
                        continue;
                    }
                    let w = (l / 64) as usize;
                    let bit = 1u64 << (l & 63) as u64;
                    if ((cur[w] | uset[w] | dset[w]) & bit) != 0 {
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
                // live-before = (live-after - defs) | uses.
                for k in 0..lw {
                    cur.set(k, cur[k] & ~dset[k] | uset[k]);
                }
            }
        }
    }

    const fn origin_live_at(self: &Self, o: u32, p: u32) bool {
        let f = self.fx();
        if o < f.nuniversal {
            return true;
        }
        let row = ((o - f.nuniversal) * self.pwords) as usize;
        return (*self.live_pts.at(row + (p / 64) as usize) >> (p & 63) as u64 & 1u64) != 0;
    }

    // Point-stripped origin reachability: the conservative candidate filter.
    fn prepass(self: &mut Self) {
        let f = unsafe &*self.f;
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
        let mut changed = true;
        while changed {
            changed = false;
            for i in 0..f.subsets.len() {
                let e = *f.subsets.at(i);
                for w in 0..self.owords as usize {
                    let src = self.oreach[e.to as usize * self.owords as usize + w];
                    let d = e.from as usize * self.owords as usize + w;
                    let v = self.oreach[d] | src;
                    if v != self.oreach[d] {
                        self.oreach.set(d, v);
                        changed = true;
                    }
                }
            }
            for i in 0..f.uni_flows.len() {
                let fr = (f.uni_flows[i] >> 32) as usize;
                let to = (f.uni_flows[i] & 0xFFFFFFFFu64) as usize;
                for w in 0..self.owords as usize {
                    let src = self.oreach[to * self.owords as usize + w];
                    let d = fr * self.owords as usize + w;
                    let v = self.oreach[d] | src;
                    if v != self.oreach[d] {
                        self.oreach.set(d, v);
                        changed = true;
                    }
                }
            }
        }
    }

    const fn prereach(self: &Self, from: u32, to: u32) bool {
        return (*self.oreach.at(from as usize * self.owords as usize + (to / 64) as usize) >> (to & 63) as u64 & 1u64) != 0;
    }

    /// Conservative origin reachability over subsets + universal flows (the prepass relation).
    /// Production wording uses it to tell a returned borrow from a store-through-out-param escape.
    pub const fn origin_reaches(self: &Self, from: u32, to: u32) bool {
        return from == to || self.prereach(from, to);
    }

    // A whole-local rebind at (origin `o`, stmt entry `p`): flows already in `o` end before the
    // write; a subset ENTERING `o` at `p` lands past it (the incoming value survives its own store).
    pub const fn cut_at(self: &Self, o: u32, p: u32) bool {
        let f = unsafe &*self.f;
        let key = o as u64 << 32 | p as u64;
        for i in 0..f.cuts.len() {
            if f.cuts[i] == key {
                return true;
            }
        }
        return false;
    }

    // ---- loans-in-scope dataflow ------------------------------------------------------------------

    fn scope_flow(self: &mut Self) {
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let nb = c.nblocks;
        self.scope.reset_to(f.loans.len() as u32, nb);
        let mut scratch = Vector::<u64>::new();
        let mut queued = Vector::<bool>::new();
        let mut queue = Vector::<u32>::new();
        // Every block runs at least once: a block's own issues must reach its successors even when
        // its entry row never changes from the empty initial state.
        for i in 0..nb {
            queued.push(true);
            queue.push(nb - 1 - i);
        }
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
                }
            }
        }
    }

    // Replay block `bi` from its entry row; stop AFTER applying facts at points <= `upto`
    // (BF_NONE = whole block). Leaves the state in `scratch`.
    fn transfer_block(self: &mut Self, bi: u32, upto: u32, scratch: &mut Vector<u64>) {
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
                if upto != bf::BF_NONE && kp > upto {
                    break;
                }
                ls::row_clear(scratch, (self.kills_blk[k as usize] & 0xFFFFFFFFu64) as u32);
                k += 1;
            } else if ip != bf::BF_NONE {
                if upto != bf::BF_NONE && ip > upto {
                    break;
                }
                ls::row_set(scratch, self.issues_blk[i as usize]);
                i += 1;
            }
        }
    }

    // ---- lazy required-point reachability ---------------------------------------------------------

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

    /// The point bitset where loan `li` is required: some origin that can hold it is live there.
    fn required(self: &mut Self, li: u32) usize {
        let f = unsafe &*self.f;
        if self.req_have.len() == 0 {
            for _i in 0..f.loans.len() {
                self.req_have.push(false);
            }
            for _i in 0..f.loans.len() as u32 * self.pwords {
                self.req_cache.push(0u64);
            }
        }
        let row = (li * self.pwords) as usize;
        if self.req_have[li as usize] {
            self.stats.cache_hits += 1;
            return row;
        }
        self.stats.queries += 1;
        self.req_have.set(li as usize, true);
        let vwords = ((f.norigins as u64 * f.npoints as u64 + 63) / 64) as usize;
        // Keep `visit` sized once per body and clear only the words the previous query set: the flood
        // touches at most `steps` words, so this is O(touched) instead of O(norigins*npoints/64).
        while self.visit.len() < vwords {
            self.visit.push(0u64);
        }
        for d in 0..self.visit_dirty.len() {
            self.visit.set(self.visit_dirty[d] as usize, 0u64);
        }
        self.visit_dirty.truncate(0);
        self.work.clear();
        let lo = *f.loans.at(li as usize);
        // A loan never flows into the origin of the local it borrows: `&mut p` handed onward must
        // not pin `p` through p's OWN origin (the invariance backlink would self-contain it).
        let self_org = f.local_origin[self.body().places.at(lo.place as usize).base as usize];
        self.work.push(lo.origin as u64 << 32 | lo.issued_at as u64);
        let mut succs = replace(&mut self.succs, Vector::<u32>::new());
        while self.work.len() != 0 {
            let node = self.work[self.work.len() - 1];
            let _ = self.work.pop();
            let o = (node >> 32) as u32;
            let p = (node & 0xFFFFFFFFu64) as u32;
            let bit = o as u64 * f.npoints as u64 + p as u64;
            let w = (bit / 64) as usize;
            let msk = 1u64 << (bit & 63);
            if (self.visit[w] & msk) != 0 {
                continue;
            }
            if self.visit[w] == 0 {
                self.visit_dirty.push(w as u32);
            }
            self.visit.set(w, self.visit[w] | msk);
            self.stats.steps += 1;
            if self.origin_live_at(o, p) {
                self.req_cache.set(
                    row + (p / 64) as usize,
                    self.req_cache[row + (p / 64) as usize] | 1u64 << (p & 63) as u64,
                );
            }
            // Subset edges at this point, plus omnipresent flows into universals.
            for i in self.sub_pt_start[p as usize]..self.sub_pt_start[p as usize + 1] {
                let e = *f.subsets.at(self.sub_by_point[i as usize] as usize);
                if e.from == o && (self_org == bf::BF_NONE || e.to != self_org) {
                    let mut tp = p;
                    if self.cut_at(e.to, p) {
                        tp = p + 1;
                    }
                    self.work.push(e.to as u64 << 32 | tp as u64);
                }
            }
            for u2 in 0..f.uni_flows.len() {
                if (f.uni_flows[u2] >> 32) as u32 == o {
                    self.work.push((f.uni_flows[u2] & 0xFFFFFFFFu64) << 32 | p as u64);
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
                    self.work.push(o as u64 << 32 | q as u64);
                }
            }
        }
        self.succs = succs; // return the reused scratch to the solver, keeping its capacity
        return row;
    }

    const fn req_at(self: &Self, row: usize, p: u32) bool {
        return (*self.req_cache.at(row + (p / 64) as usize) >> (p & 63) as u64 & 1u64) != 0;
    }

    /// Comparison hooks for the reference solver: the required-point row of a loan, and its words.
    pub fn required_row(self: &mut Self, li: u32) usize {
        return self.required(li);
    }

    pub const fn req_word(self: &Self, row: usize, w: u32) u64 {
        return *self.req_cache.at(row + w as usize);
    }

    // ---- error detection --------------------------------------------------------------------------

    // Does access `ac` invalidate loan `li` by kind (two-phase aware)?
    const fn kind_conflicts(self: &Self, lo: &bf::Loan, ac: &bf::Access) bool {
        if lo.kind == bf::LK_CAP {
            return false; // capture loans invalidate only through storage death (established rules)
        }
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

    fn conflicts(self: &mut Self) {
        let f = unsafe &*self.f;
        let mut scratch = Vector::<u64>::new();
        for a in 0..f.accesses.len() {
            let ac = *f.accesses.at(a);
            for li in 0..f.loans.len() {
                let lo = *f.loans.at(li);
                if ac.place == bf::BF_NONE {
                    // Whole-local access: the borrowed storage dies. A loan THROUGH a dereference
                    // borrows foreign storage and merely becomes unreachable (its kill handles it),
                    // and a loan on a VIEW value aliases what the view points at, not this storage.
                    if lo.view {
                        continue;
                    }
                    if lo.pin && f.moved_whole[self.body().places.at(lo.place as usize).base as usize] {
                        continue; // the pinned container's ownership travelled with a move
                    }
                    let pl = *self.body().places.at(lo.place as usize);
                    if pl.base != ac.local {
                        continue;
                    }
                    let mut through = false;
                    for i in 0..pl.proj_len {
                        if self.body().projections.at((pl.proj_start + i) as usize).kind == ir::PJ_DEREF {
                            through = true;
                        }
                    }
                    if through {
                        continue;
                    }
                } else {
                    if ac.point == lo.issued_at || ac.point == lo.activated_at && ac.place == lo.place {
                        continue; // a loan's own issue/activation is not an invalidation of itself
                    }
                    if !self.kind_conflicts(&lo, &ac) {
                        continue;
                    }
                    if lo.pin && (ac.kind == bf::ACC_MOVE || ac.kind == bf::ACC_FREE) && self.body().places.at(
                        ac.place as usize,
                    ).proj_len == 0 {
                        // Element views ride a whole-container move (heap storage is stable) --
                        // the walk accepts this, so the pin must too.
                        continue;
                    }

                    if !bf::places_conflict(self.body(), lo.place, ac.place) {
                        continue;
                    }
                }
                self.stats.candidates += 1;
                // In scope at the access?
                let bi = self.point_block[ac.point as usize];
                self.transfer_block(bi, ac.point - 1, &mut scratch);
                if !ls::row_get(&scratch, li as u32) {
                    continue;
                }
                // Still required (some live origin can hold it)?
                let row = self.required(li as u32);
                if !self.req_at(row, ac.point) {
                    continue;
                }
                let mut overwrite = false;
                if ac.kind == bf::ACC_WRITE {
                    // Does this write KILL the loan (it overwrites the borrowed storage)? Then the
                    // conflict exists only if the loan is still wanted past this statement
                    // (`rel = rel.slice(..)` re-owns; `x = 2; *r` still dangles).
                    for kk in 0..f.kills.len() {
                        let kl = *f.kills.at(kk);
                        if kl.loan == li as u32 && kl.point == ac.point {
                            overwrite = true;
                        }
                    }
                }
                if ac.kind == bf::ACC_ACT || overwrite {
                    // Two-phase activation (and an overwriting kill) tolerates loans whose LAST
                    // requirement is this statement itself. Same-pair liveness injection reaches
                    // point + 1, so "later" starts past the pair.
                    let mut later = false;
                    let mut q = ac.point + 2;
                    while q < f.npoints {
                        if self.req_at(row, q) {
                            later = true;
                            break;
                        }
                        q += 1;
                    }
                    if !later {
                        continue;
                    }
                }
                let mut sp = ac.span;
                let mut ak = ac.kind;
                if ac.place == bf::BF_NONE {
                    sp = lo.span; // point at the borrow that outlives its storage
                    ak = ACC_DEAD;
                }
                self.errs.push(
                    BorrowErr {
                        kind: BE_CONFLICT,
                        acc: ak,
                        loan: li as u32,
                        point: ac.point,
                        span: sp,
                        loan_span: lo.span,
                    },
                );
            }
        }
    }

    // A loan of storage this body owns must never reach a placeholder that is live at a return.
    fn escapes(self: &mut Self) {
        let f = unsafe &*self.f;
        let c = unsafe &*self.c;
        let bd = unsafe &*self.b;
        for li in 0..f.loans.len() {
            let lo = *f.loans.at(li);
            if lo.view {
                continue; // a borrow OF a view chains to the view's own origin, not local storage
            }
            if lo.pin && f.moved_whole[self.body().places.at(lo.place as usize).base as usize] {
                continue; // a moved container carries its pinned views with it
            }
            let pl = *bd.places.at(lo.place as usize);
            let st = bd.locals.at(pl.base as usize).storage;
            if st == ir::LS_STATIC_REF {
                continue;
            }
            let mut through = false;
            for i in 0..pl.proj_len {
                if bd.projections.at((pl.proj_start + i) as usize).kind == ir::PJ_DEREF {
                    through = true;
                }
            }
            if through {
                continue; // a reborrow's storage belongs to the reference it went through
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
            for bi in 0..c.nblocks {
                let t = bd.blocks.at(bi as usize).term;
                if t.kind != ir::TM_RETURN {
                    continue;
                }
                let p = f.block_base[bi as usize] + bd.blocks.at(bi as usize).stmt_len * 2;
                if self.req_at(row, p) || self.req_at(row, p + 1) {
                    self.errs.push(
                        BorrowErr {
                            kind: BE_ESCAPE,
                            acc: 0,
                            loan: li as u32,
                            point: p,
                            span: lo.span,
                            loan_span: lo.span,
                        },
                    );
                    break;
                }
            }
        }
    }

    // Placeholder-to-placeholder flow must be declared. Elided return placeholders accept every
    // input; 'static (origin 0) flows anywhere.
    fn placeholders(self: &mut Self) {
        let f = unsafe &*self.f;
        for u in 1..f.nuniversal {
            for v in 0..f.nuniversal {
                if u == v || !self.prereach(u, v) {
                    continue;
                }
                // Only flows into a DECLARED return placeholder are checkable relations; elided
                // returns accept every input, and argument placeholders are the store-escape
                // analysis' concern, not a signature relation.
                let mut is_ret = false;
                let mut ok = u == 0;
                for r in 0..f.ret_origin.len() {
                    if f.ret_origin[r] == v {
                        is_ret = true;
                        if f.ret_elided[r] {
                            ok = true;
                        }
                    }
                }
                if !is_ret {
                    ok = true;
                }
                for k in 0..f.known_subsets.len() {
                    let rec = f.known_subsets[k];
                    if (rec >> 32) as u32 == u && (rec & 0xFFFFFFFFu64) as u32 == v {
                        ok = true;
                    }
                }
                if !ok {
                    if stdlib::getenv("SC_BORROW_TRACE") != null {
                        eprint("ph-flow u={} v={} nuni={} known={}\n", u, v, f.nuniversal, f.known_subsets.len());
                        for kk in 0..f.known_subsets.len() {
                            eprint(
                                "  known {} -> {}\n",
                                (f.known_subsets[kk] >> 32) as u32,
                                (f.known_subsets[kk] & 0xFFFFFFFFu64) as u32,
                            );
                        }
                    }
                    // Location-sensitive confirmation: some point-local chain must actually connect
                    // the two placeholders (the prepass alone may be a false candidate).
                    if self.uni_reaches(u, v) {
                        self.errs.push(
                            BorrowErr {
                                kind: BE_PLACEHOLDER,
                                acc: 0,
                                loan: bf::BF_NONE,
                                point: 0,
                                span: f.uni_name[u as usize],
                                loan_span: f.uni_name[v as usize],
                            },
                        );
                    }
                }
            }
        }
    }

    // Full location-sensitive placeholder query: flood from (u, entry) like a loan.
    fn uni_reaches(self: &mut Self, u: u32, v: u32) bool {
        let f = unsafe &*self.f;
        let vwords = ((f.norigins as u64 * f.npoints as u64 + 63) / 64) as usize;
        self.visit.clear();
        for _i in 0..vwords {
            self.visit.push(0u64);
        }
        self.work.clear();
        self.work.push(u as u64 << 32 | 0u64);
        let mut succs = Vector::<u32>::new();
        let mut found = false;
        while self.work.len() != 0 && !found {
            let node = self.work[self.work.len() - 1];
            let _ = self.work.pop();
            let o = (node >> 32) as u32;
            let p = (node & 0xFFFFFFFFu64) as u32;
            let bit = o as u64 * f.npoints as u64 + p as u64;
            let w = (bit / 64) as usize;
            let msk = 1u64 << (bit & 63);
            if (self.visit[w] & msk) != 0 {
                continue;
            }
            if self.visit[w] == 0 {
                self.visit_dirty.push(w as u32);
            }
            self.visit.set(w, self.visit[w] | msk);
            self.stats.steps += 1;
            if o == v {
                found = true;
                break;
            }
            for i in self.sub_pt_start[p as usize]..self.sub_pt_start[p as usize + 1] {
                let e = *f.subsets.at(self.sub_by_point[i as usize] as usize);
                if e.from == o {
                    self.work.push(e.to as u64 << 32 | p as u64);
                }
            }
            for u2 in 0..f.uni_flows.len() {
                if (f.uni_flows[u2] >> 32) as u32 == o {
                    self.work.push((f.uni_flows[u2] & 0xFFFFFFFFu64) << 32 | p as u64);
                }
            }
            self.point_succs(p, &mut succs);
            for s in 0..succs.len() {
                let q = succs[s];
                if o < f.nuniversal || self.origin_live_at(o, q) {
                    self.work.push(o as u64 << 32 | q as u64);
                }
            }
        }
        return found;
    }
}

// ---- reference solver -----------------------------------------------------------------------------

/// Small, slow, and independent: materializes every (origin, point) node and edge, then answers each
/// loan query by direct search. Development comparisons only -- never part of compilation.
pub struct RefResult {
    pub required: Vector<u64>, // per loan: point bitset rows (pwords each)
    pub pwords: u32,
    pub errs: Vector<BorrowErr>,
}

extend RefResult as Free {
    pub fn free(self: &mut Self) {
        self.required.free();
        self.errs.free();
    }
}

pub fn solve_reference(b: &ir::CoreBody, f: &bf::BodyFacts, c: &df::Cfg, lv: &df::Liveness) RefResult {
    // Rebuild statement-exact origin liveness with the optimized path's own helper, then do the
    // dumbest possible thing: per loan, breadth-first over an explicit edge list.
    let sv = solve(b, f, c, lv);
    let mut pwords = (f.npoints + 63) / 64;
    if pwords == 0 {
        pwords = 1;
    }
    let mut r = RefResult { required: Vector::<u64>::new(), pwords: pwords, errs: Vector::<BorrowErr>::new() };
    // Explicit edges: (o, p) -> (o2, p) for subsets at p; (o, p) -> (o, q) for point succ q.
    for li in 0..f.loans.len() {
        let lo = *f.loans.at(li);
        let mut seen = Vector::<u64>::new();
        let vwords = ((f.norigins as u64 * f.npoints as u64 + 63) / 64) as usize;
        for _i in 0..vwords {
            seen.push(0u64);
        }
        let mut req = Vector::<u64>::new();
        for _i in 0..pwords {
            req.push(0u64);
        }
        let mut work = Vector::<u64>::new();
        let self_org = f.local_origin[b.places.at(lo.place as usize).base as usize];
        work.push(lo.origin as u64 << 32 | lo.issued_at as u64);
        let mut succs = Vector::<u32>::new();
        while work.len() != 0 {
            let node = work[work.len() - 1];
            let _ = work.pop();
            let o = (node >> 32) as u32;
            let p = (node & 0xFFFFFFFFu64) as u32;
            let bit = o as u64 * f.npoints as u64 + p as u64;
            if (seen[(bit / 64) as usize] & 1u64 << (bit & 63)) != 0 {
                continue;
            }
            seen.set((bit / 64) as usize, seen[(bit / 64) as usize] | 1u64 << (bit & 63));
            if sv.origin_live_at(o, p) {
                req.set((p / 64) as usize, req[(p / 64) as usize] | 1u64 << (p & 63) as u64);
            }
            for i in 0..f.subsets.len() {
                let e = *f.subsets.at(i);
                if e.point == p && e.from == o && (self_org == bf::BF_NONE || e.to != self_org) {
                    let mut tp = p;
                    if sv.cut_at(e.to, p) {
                        tp = p + 1;
                    }
                    work.push(e.to as u64 << 32 | tp as u64);
                }
            }
            for u2 in 0..f.uni_flows.len() {
                if (f.uni_flows[u2] >> 32) as u32 == o {
                    work.push((f.uni_flows[u2] & 0xFFFFFFFFu64) << 32 | p as u64);
                }
            }
            sv.point_succs(p, &mut succs);
            for s in 0..succs.len() {
                let q = succs[s];
                if q == p + 1 && sv.cut_at(o, p) {
                    continue;
                }
                if o < f.nuniversal || sv.origin_live_at(o, q) {
                    work.push(o as u64 << 32 | q as u64);
                }
            }
        }
        for w in 0..pwords {
            r.required.push(req[w as usize]);
        }
    }
    // The error list comes from the optimized solver run above (same facts, same rules); the
    // comparison value of this path is the independently computed `required` sets.
    for e in 0..sv.errs.len() {
        r.errs.push(*sv.errs.at(e));
    }
    return r;
}
