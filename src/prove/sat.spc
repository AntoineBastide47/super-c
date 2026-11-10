// The SAT solver of the contract prover: conflict-driven clause learning over a CNF (`blast::Cnf`),
// with two watched literals, first-UIP learning with minimization, activity-ordered decisions, saved
// phases and Luby restarts. It is not trusted: a refutation writes an LRAT proof (`proof`) that the
// kernel checks (`Lrat::check`). Each learned clause names its hints, the clauses that unit
// propagation over the negated clause uses, in order: the unit clauses of the level-0 literals it
// reads, the reasons of the resolved and dropped literals by trail position, then the conflict.
//
// A literal is `var << 1 | negated`. Clause ids: the CNF's clauses are 1 to m in order; each step of
// the proof adds the next one.
import prove::terms as *;
import prove::blast as *;

// The answers of `solve`.
pub(package) const SAT_MODEL: u8 = 0;
pub(package) const SAT_REFUTED: u8 = 1;
pub(package) const SAT_ABORT: u8 = 2;

// The conflicts between restarts, times the Luby sequence.
const RESTART_UNIT: u32 = 64;
// The proof's u32 words, and the activity or increment past which all are halved 30 times.
const PROOF_MAX: usize = 1 << 22;
const ACT_MAX: u64 = 1 << 60;

// A literal's value (`Sat.val`, by literal).
const V_UNSET: u8 = 0;
const V_TRUE: u8 = 1;
const V_FALSE: u8 = 2;

pub(package) struct Sat {
    // Clause `c`: its literals [cstart[c], cstart[c] + clen[c]) of `pool`, its proof id. The first two
    // literals are the watched ones.
    cstart: Vector<u32>,
    clen: Vector<u32>,
    cid: Vector<u32>,
    pool: Vector<u32>,
    // Watch lists: node `2c + k` watches literal `pool[cstart[c] + k]`; `whead` per literal, `wnext`
    // per node.
    whead: Vector<u32>,
    wnext: Vector<u32>,
    val: Vector<u8>,
    level: Vector<u32>,
    reason: Vector<u32>,
    tpos: Vector<u32>,
    unit: Vector<u32>, // the proof id of a level-0 variable's unit clause
    phase: Vector<bool>,
    act: Vector<u64>,
    inc: u64,
    heap: Vector<u32>,
    hpos: Vector<u32>,
    trail: Vector<u32>,
    lims: Vector<u32>,
    qhead: usize,
    seen: Vector<bool>,
    learnt: Vector<u32>,
    hints: Vector<u64>, // trail position << 32 | clause id
    units: Vector<u32>,
    touched: Vector<u32>,
    mstack: Vector<u32>,
    next_id: u32,
    pub(package) steps: u32,
    pub(package) proof: Vector<u32>,
}

extend Sat {
    pub(package) fn new() Sat {
        return Sat {
            cstart: Vector::<u32>::new(),
            clen: Vector::<u32>::new(),
            cid: Vector::<u32>::new(),
            pool: Vector::<u32>::new(),
            whead: Vector::<u32>::new(),
            wnext: Vector::<u32>::new(),
            val: Vector::<u8>::new(),
            level: Vector::<u32>::new(),
            reason: Vector::<u32>::new(),
            tpos: Vector::<u32>::new(),
            unit: Vector::<u32>::new(),
            phase: Vector::<bool>::new(),
            act: Vector::<u64>::new(),
            inc: 1,
            heap: Vector::<u32>::new(),
            hpos: Vector::<u32>::new(),
            trail: Vector::<u32>::new(),
            lims: Vector::<u32>::new(),
            qhead: 0,
            seen: Vector::<bool>::new(),
            learnt: Vector::<u32>::new(),
            hints: Vector::<u64>::new(),
            units: Vector::<u32>::new(),
            touched: Vector::<u32>::new(),
            mstack: Vector::<u32>::new(),
            next_id: 1,
            steps: 0,
            proof: Vector::<u32>::new(),
        };
    }

    // Whether variable `v` is true in the model `solve` found.
    pub(package) const fn holds(self: &Self, v: u32) bool {
        return self.val[(v << 1) as usize] == V_TRUE;
    }

    // Decide `cnf` within `budget` steps: SAT_MODEL (a model, `holds`), SAT_REFUTED (`proof` derives the
    // empty clause) or SAT_ABORT.
    pub(package) fn solve(self: &mut Self, cnf: &Cnf, budget: u32) u8 {
        self.reset(cnf.nv);
        self.steps = 0;
        let mut s: u32 = 0;
        self.next_id = cnf.ends.len() as u32 + 1;
        for j in 0..cnf.ends.len() {
            let e = cnf.ends[j];
            if !self.load(cnf, s, e, j as u32 + 1) {
                return SAT_REFUTED;
            }
            s = e;
        }
        let mut luby_u: u32 = 1;
        let mut luby_v: u32 = 1;
        let mut left = RESTART_UNIT;
        for _k in 0..budget {
            let c = self.propagate();
            if self.steps > budget || self.proof.len() > PROOF_MAX {
                return SAT_ABORT;
            }
            if c != NONE {
                if self.lims.len() == 0 {
                    self.refute_at_root(c);
                    return SAT_REFUTED;
                }
                self.analyze(c);
                left = left.saturating_sub(1);
                continue;
            }
            if left == 0 {
                // Luby: (u, v) -> (u & -u == v) ? (u + 1, 1) : (u, 2v).
                if (luby_u & luby_u.wrapping_neg()) == luby_v {
                    luby_u += 1;
                    luby_v = 1;
                } else {
                    luby_v = luby_v.saturating_mul(2);
                }
                left = RESTART_UNIT.saturating_mul(luby_v);
                self.backtrack(0);
                continue;
            }
            let v = self.pick_var();
            if v == NONE {
                return SAT_MODEL;
            }
            self.lims.push(self.trail.len() as u32);
            self.assign(v << 1 | (!self.phase[v as usize]) as u32, NONE);
        }
        return SAT_ABORT;
    }

    fn reset(self: &mut Self, nv: u32) {
        self.cstart.clear();
        self.clen.clear();
        self.cid.clear();
        self.pool.clear();
        self.wnext.clear();
        self.whead.clear();
        self.val.clear();
        self.level.clear();
        self.reason.clear();
        self.tpos.clear();
        self.unit.clear();
        self.phase.clear();
        self.act.clear();
        self.seen.clear();
        self.heap.clear();
        self.hpos.clear();
        self.trail.clear();
        self.lims.clear();
        self.proof.clear();
        self.qhead = 0;
        self.inc = 1;
        self.next_id = 1;
        for v in 0..nv {
            self.whead.push(NONE);
            self.whead.push(NONE);
            self.val.push(V_UNSET);
            self.val.push(V_UNSET);
            self.level.push(0);
            self.reason.push(NONE);
            self.tpos.push(0);
            self.unit.push(NONE);
            self.phase.push(false);
            self.act.push(0);
            self.seen.push(false);
            self.hpos.push(v);
            self.heap.push(v);
        }
    }

    // Clause [s, e) of `cnf` with proof id `id`: dropped when it holds both a literal and its negation,
    // assigned at level 0 when it is a unit. False when it refutes the clauses loaded before (the
    // proof then ends with the empty clause).
    fn load(self: &mut Self, cnf: &Cnf, s: u32, e: u32, id: u32) bool {
        let start = self.pool.len() as u32;
        for j in s..e {
            let l = cnf.lits[j as usize];
            let mut dup = false;
            for q in start..self.pool.len() as u32 {
                let m = self.pool[q as usize];
                if m == (l ^ 1) {
                    self.pool.truncate(start as usize);
                    return true;
                }
                dup = dup || m == l;
            }
            if !dup {
                self.pool.push(l);
            }
        }
        let n = self.pool.len() as u32 - start;
        if n == 0 {
            self.step0(id);
            return false;
        }
        if n == 1 {
            let l = self.pool[start as usize];
            self.pool.truncate(start as usize);
            if self.val[l as usize] == V_TRUE {
                return true;
            }
            if self.val[l as usize] == V_FALSE {
                self.units.clear();
                self.units.push(self.unit[(l >> 1) as usize]);
                self.units.push(id);
                self.empty_step();
                return false;
            }
            self.assign(l, NONE);
            self.unit.set((l >> 1) as usize, id);
            return true;
        }
        self.add_clause(start, n, id);
        return true;
    }

    // The proof step that derives the empty clause from the hint `id`, itself empty.
    fn step0(self: &mut Self, id: u32) {
        self.units.clear();
        self.units.push(id);
        self.empty_step();
    }

    // The empty clause, from the hints in `units`.
    fn empty_step(self: &mut Self) {
        self.proof.push(self.next_id);
        self.next_id += 1;
        self.proof.push(0);
        self.proof.push(self.units.len() as u32);
        self.proof.extend_copy(&self.units);
    }

    fn add_clause(self: &mut Self, start: u32, n: u32, id: u32) u32 {
        let c = self.cstart.len() as u32;
        self.cstart.push(start);
        self.clen.push(n);
        self.cid.push(id);
        for k in 0..2u32 {
            let l = self.pool[(start + k) as usize];
            self.wnext.push(self.whead[l as usize]);
            self.whead.set(l as usize, 2 * c + k);
        }
        return c;
    }

    fn assign(self: &mut Self, l: u32, r: u32) {
        let v = (l >> 1) as usize;
        self.val.set(l as usize, V_TRUE);
        self.val.set((l ^ 1) as usize, V_FALSE);
        self.level.set(v, self.lims.len() as u32);
        self.reason.set(v, r);
        self.tpos.set(v, self.trail.len() as u32);
        self.trail.push(l);
        if self.lims.len() == 0 && r != NONE {
            self.unit_step(l, r);
        }
    }

    // The unit clause of `l`, propagated at level 0 by clause `r`: its hints are the units of `r`'s
    // other literals, then `r`.
    fn unit_step(self: &mut Self, l: u32, r: u32) {
        let id = self.next_id;
        self.next_id += 1;
        self.proof.push(id);
        self.proof.push(1);
        self.proof.push(l);
        let s = self.cstart[r as usize];
        let n = self.clen[r as usize];
        self.proof.push(n);
        for j in s..s + n {
            let m = self.pool[j as usize];
            if m != l {
                self.proof.push(self.unit[(m >> 1) as usize]);
            }
        }
        self.proof.push(self.cid[r as usize]);
        self.unit.set((l >> 1) as usize, id);
    }

    // Propagate the trail from `qhead`: the clause in conflict, or NONE.
    fn propagate(self: &mut Self) u32 {
        for _q in 0..self.trail.len() + self.val.len() {
            if self.qhead >= self.trail.len() {
                return NONE;
            }
            let f = self.trail[self.qhead] ^ 1;
            self.qhead += 1;
            let mut prev = NONE;
            let mut node = self.whead[f as usize];
            for _w in 0..self.wnext.len() + 1 {
                if node == NONE {
                    break;
                }
                self.steps += 1;
                let next = self.wnext[node as usize];
                let c = node >> 1;
                let k = node & 1;
                let s = self.cstart[c as usize];
                let n = self.clen[c as usize];
                let other = self.pool[(s + 1 - k) as usize];
                if self.val[other as usize] == V_TRUE {
                    prev = node;
                    node = next;
                    continue;
                }
                let mut moved = false;
                for j in s + 2..s + n {
                    let m = self.pool[j as usize];
                    if self.val[m as usize] != V_FALSE {
                        self.pool.set(j as usize, f);
                        self.pool.set((s + k) as usize, m);
                        if prev == NONE {
                            self.whead.set(f as usize, next);
                        } else {
                            self.wnext.set(prev as usize, next);
                        }
                        self.wnext.set(node as usize, self.whead[m as usize]);
                        self.whead.set(m as usize, node);
                        moved = true;
                        break;
                    }
                }
                if moved {
                    node = next;
                    continue;
                }
                if self.val[other as usize] == V_FALSE {
                    self.qhead = self.trail.len();
                    return c;
                }
                self.assign(other, c);
                prev = node;
                node = next;
            }
        }
        return NONE;
    }

    // The empty clause from conflict `c` at level 0: the units of its literals, then `c`.
    fn refute_at_root(self: &mut Self, c: u32) {
        self.units.clear();
        let s = self.cstart[c as usize];
        for j in s..s + self.clen[c as usize] {
            self.units.push(self.unit[(self.pool[j as usize] >> 1) as usize]);
        }
        self.units.push(self.cid[c as usize]);
        self.empty_step();
    }

    // First-UIP learning from conflict `c`: the learned clause, its proof step, the backjump and the
    // assignment it asserts.
    fn analyze(self: &mut Self, c0: u32) {
        self.learnt.clear();
        self.learnt.push(NONE);
        self.hints.clear();
        self.units.clear();
        self.touched.clear();
        let top = self.lims.len() as u32;
        let mut count: u32 = 0;
        let mut c = c0;
        let mut p = NONE;
        let mut idx = self.trail.len();
        for _r in 0..self.trail.len() + 1 {
            let s = self.cstart[c as usize];
            for j in s..s + self.clen[c as usize] {
                let q = self.pool[j as usize];
                let v = (q >> 1) as usize;
                if q == p || self.seen[v] {
                    continue;
                }
                self.seen.set(v, true);
                self.touched.push(v as u32);
                self.bump(v as u32);
                let lv = self.level[v];
                if lv == 0 {
                    self.units.push(self.unit[v]);
                } else if lv == top {
                    count += 1;
                } else {
                    self.learnt.push(q);
                }
            }
            for _t in 0..idx {
                idx -= 1;
                if self.seen[(self.trail[idx] >> 1) as usize] {
                    break;
                }
            }
            p = self.trail[idx];
            count -= 1;
            if count == 0 {
                break;
            }
            c = self.reason[(p >> 1) as usize];
            self.hints.push(self.tpos[(p >> 1) as usize] as u64 << 32 | self.cid[c as usize] as u64);
        }
        self.learnt.set(0, p ^ 1);
        // Drop each literal whose reason's other literals are in the clause, at level 0, or dropped the
        // same way: their reasons join the hints.
        let mut o: usize = 1;
        for j in 1..self.learnt.len() {
            let q = self.learnt[j];
            if self.reason[(q >> 1) as usize] == NONE || !self.redundant(q >> 1) {
                self.learnt.set(o, q);
                o += 1;
            }
        }
        self.learnt.truncate(o);
        self.hints.sort();
        for j in 0..self.touched.len() {
            self.seen.set(self.touched[j] as usize, false);
        }
        self.inc += self.inc / 19 + 1;
        if self.inc > ACT_MAX {
            self.rescale();
        }
        // The step: the units, the reasons by trail position, the conflict.
        let id = self.next_id;
        self.next_id += 1;
        self.proof.push(id);
        self.proof.push(self.learnt.len() as u32);
        self.proof.extend_copy(&self.learnt);
        self.proof.push((self.units.len() + self.hints.len() + 1) as u32);
        self.proof.extend_copy(&self.units);
        for j in 0..self.hints.len() {
            self.proof.push(self.hints[j] as u32);
        }
        self.proof.push(self.cid[c0 as usize]);
        // Backjump to the highest level among the other literals, which goes second (watched).
        let mut back: u32 = 0;
        for j in 1..self.learnt.len() {
            let lv = self.level[(self.learnt[j] >> 1) as usize];
            if lv > back {
                back = lv;
                let x = self.learnt[1];
                self.learnt.set(1, self.learnt[j]);
                self.learnt.set(j, x);
            }
        }
        self.backtrack(back);
        let l = self.learnt[0];
        if self.learnt.len() == 1 {
            self.assign(l, NONE);
            self.unit.set((l >> 1) as usize, id);
            return;
        }
        let start = self.pool.len() as u32;
        self.pool.extend_copy(&self.learnt);
        let r = self.add_clause(start, self.learnt.len() as u32, id);
        self.assign(l, r);
    }

    // Whether variable `v` of the learned clause follows from the others: every literal of its reason
    // is in the clause, at level 0, or follows the same way. The reasons and units it reads join the
    // hints; on failure they and the marks it set are undone.
    fn redundant(self: &mut Self, v0: u32) bool {
        let top = self.touched.len();
        let nh = self.hints.len();
        let nu = self.units.len();
        self.mstack.clear();
        self.mstack.push(v0);
        self.hints.push(self.tpos[v0 as usize] as u64 << 32 | self.cid[self.reason[v0 as usize] as usize] as u64);
        for _k in 0..self.trail.len() + 1 {
            if self.mstack.len() == 0 {
                return true;
            }
            let v = self.mstack.pop().unwrap();
            let r = self.reason[v as usize] as usize;
            let s = self.cstart[r];
            let mut ok = true;
            for j in s..s + self.clen[r] {
                let u = self.pool[j as usize] >> 1;
                if u == v || self.seen[u as usize] {
                    continue;
                }
                if self.level[u as usize] != 0 && self.reason[u as usize] == NONE {
                    ok = false;
                    break;
                }
                self.seen.set(u as usize, true);
                self.touched.push(u);
                if self.level[u as usize] == 0 {
                    self.units.push(self.unit[u as usize]);
                } else {
                    self.hints.push(
                        self.tpos[u as usize] as u64 << 32 | self.cid[self.reason[u as usize] as usize] as u64,
                    );
                    self.mstack.push(u);
                }
            }
            if !ok {
                break;
            }
        }
        for j in top..self.touched.len() {
            self.seen.set(self.touched[j] as usize, false);
        }
        self.touched.truncate(top);
        self.hints.truncate(nh);
        self.units.truncate(nu);
        return false;
    }

    fn backtrack(self: &mut Self, lv: u32) {
        if self.lims.len() as u32 <= lv {
            return;
        }
        let keep = self.lims[lv as usize] as usize;
        for _j in keep..self.trail.len() {
            let l = self.trail.pop().unwrap();
            let v = l >> 1;
            self.val.set(l as usize, V_UNSET);
            self.val.set((l ^ 1) as usize, V_UNSET);
            self.phase.set(v as usize, (l & 1) == 0);
            if self.hpos[v as usize] == NONE {
                self.heap_push(v);
            }
        }
        self.lims.truncate(lv as usize);
        self.qhead = keep;
    }

    // ---- decisions: a max-heap of the variables by activity ---------------------------------------

    // Every activity and the increment halved 30 times: each stays below 2 * ACT_MAX.
    fn rescale(self: &mut Self) {
        for v in 0..self.act.len() {
            self.act.set(v, self.act[v] >> 30);
        }
        self.inc = (self.inc >> 30) + 1;
    }

    fn bump(self: &mut Self, v: u32) {
        self.act.set(v as usize, self.act[v as usize] + self.inc);
        if self.act[v as usize] > ACT_MAX {
            self.rescale();
        }
        let p = self.hpos[v as usize];
        if p != NONE {
            self.heap_up(p);
        }
    }

    // The unassigned variable of highest activity, NONE when every variable has a value.
    fn pick_var(self: &mut Self) u32 {
        for _k in 0..self.act.len() + 1 {
            if self.heap.len() == 0 {
                return NONE;
            }
            let v = self.heap[0];
            let last = self.heap.pop().unwrap();
            self.hpos.set(v as usize, NONE);
            if self.heap.len() != 0 {
                self.heap.set(0, last);
                self.hpos.set(last as usize, 0);
                self.heap_down(0);
            }
            if self.val[(v << 1) as usize] == V_UNSET {
                return v;
            }
        }
        return NONE;
    }

    fn heap_push(self: &mut Self, v: u32) {
        let p = self.heap.len() as u32;
        self.heap.push(v);
        self.hpos.set(v as usize, p);
        self.heap_up(p);
    }

    // Whether variable `a` goes before `b`: higher activity, then lower index.
    const fn before(self: &Self, a: u32, b: u32) bool {
        let x = self.act[a as usize];
        let y = self.act[b as usize];
        return x > y || x == y && a < b;
    }

    fn heap_up(self: &mut Self, p0: u32) {
        let mut p = p0;
        let v = self.heap[p as usize];
        for _k in 0..32 {
            if p == 0 {
                break;
            }
            let up = (p - 1) / 2;
            let u = self.heap[up as usize];
            if !self.before(v, u) {
                break;
            }
            self.heap.set(p as usize, u);
            self.hpos.set(u as usize, p);
            p = up;
        }
        self.heap.set(p as usize, v);
        self.hpos.set(v as usize, p);
    }

    fn heap_down(self: &mut Self, p0: u32) {
        let mut p = p0;
        let n = self.heap.len() as u32;
        let v = self.heap[p as usize];
        for _k in 0..32 {
            let mut ch = 2 * p + 1;
            if ch >= n {
                break;
            }
            if ch + 1 < n && self.before(self.heap[(ch + 1) as usize], self.heap[ch as usize]) {
                ch += 1;
            }
            let u = self.heap[ch as usize];
            if !self.before(u, v) {
                break;
            }
            self.heap.set(p as usize, u);
            self.hpos.set(u as usize, p);
            p = ch;
        }
        self.heap.set(p as usize, v);
        self.hpos.set(v as usize, p);
    }
}
