// The analysis pass of the native backends (after TPDE, Schwarz, Kamm and Engelke 2025): one walk over a
// LIR body gives the block layout, the loop nesting and each value's live range and use count, which the
// code generation pass reads to allocate registers in one pass.
//
// Layout: reverse postorder, each loop contiguous (a block's key is the list of its loop headers'
// positions, then its own, compared in order), a loop's rare blocks after its warm ones, the other rare
// blocks last. A block is rare when the entry reaches it only through a block marked rare (`BLOCK_RARE`:
// cold or unlikely), so no warm block follows a rare one in dominance. A value's range is the layout
// positions from its definition's block to `end`: its last use, or the last block of the outermost loop
// that holds a use but not the definition (the value must survive the back edge). The CFG is reducible
// (the verifier checks it), so an edge to a block not later in reverse postorder is a back edge.
import lir::ir as *;
import lir::verify as lv;
import ir::core as core;

/// `Live::fold_ops`: an integer comparison whose every use is a `select`'s or a `br`'s condition (each
/// compares again instead of testing a boolean set from the flags); an `and` whose every use compares it
/// with 0 for equality (`tst`); a product one `add` or `sub` takes (`madd`, `msub`); a logical shift right
/// by a constant one `and` with a mask of low bits takes (`ubfx`); the two shifts of a rotation and the
/// arithmetic of its second amount (`rotate_of`), of 32 or 64 bits, with FOLD_ROT_NARROW of 8 and 16 too
/// (`rol`, `ror`); the shift left by 1 to 3 and the inner sum one sum takes as an address (`lea_of`).
pub(package) const FOLD_CMP: u32 = 1;
pub(package) const FOLD_TST: u32 = 2;
pub(package) const FOLD_MADD: u32 = 4;
pub(package) const FOLD_UBFX: u32 = 8;
pub(package) const FOLD_ROT: u32 = 16;
pub(package) const FOLD_ROT_NARROW: u32 = 32;
pub(package) const FOLD_LEA: u32 = 64;
// The most folded instructions `uses_at` expands for one use: a comparison of a test of a field, say.
const FOLD_DEPTH: u32 = 8;

/// `Live::plan`'s homes per value: no register for the whole range, a callee-saved one, a caller-saved one.
pub(package) const HOME_NONE: u8 = 0;
pub(package) const HOME_CALLEE: u8 = 1;
pub(package) const HOME_SCRATCH: u8 = 2;
/// `Live::plan`'s request per value: it may take a callee-saved register, a caller-saved one; it is of the
/// vector file (else the general one).
pub(package) const WANT_CALLEE: u8 = 1;
pub(package) const WANT_SCRATCH: u8 = 2;
pub(package) const WANT_V: u8 = 4;

/// The registers `Live::plan` gives out at once per file (`x`: general, `v`: vector): callee-saved,
/// caller-saved, and both together.
pub(package) struct Caps {
    pub(package) xc: u32,
    pub(package) xs: u32,
    pub(package) xj: u32,
    pub(package) vc: u32,
    pub(package) vs: u32,
    pub(package) vj: u32,
}

extend Caps as Copy {}

/// The analysis of one body. Values index `insts` first, then `params`, then the overflow flags that have
/// a use (`flag_of`).
pub(package) struct Live {
    pub(package) order: Vector<u32>, // the blocks in layout order
    pub(package) pos: Vector<u32>, // per block, its layout position
    pub(package) npred: Vector<u32>, // per block, its predecessor count (an edge each)
    pub(package) inner: Vector<u32>, // per block, the header of its innermost loop, NONE outside loops
    pub(package) lend: Vector<u32>, // per loop header, the layout position of the loop's last block
    pub(package) parent: Vector<u32>, // per loop header, the header of the loop around it, NONE
    pub(package) rare: Vector<bool>, // per block, whether the entry reaches it only through a block marked rare
    /// Per block (empty: none), whether the layout puts it after every other block, in layout order: a
    /// generator's rare blocks that alone set its frame up, after the code that has none.
    pub(package) after: Vector<bool>,
    pub(package) def_blk: Vector<u32>, // per value, its block
    pub(package) end: Vector<u32>, // per value, the last layout position it is live in
    pub(package) uses: Vector<u32>, // per value, its use count, one more when a loop keeps it past its last use
    pub(package) last: Vector<u32>, // per value, the highest instruction index that uses it (0: none)
    pub(package) flag_of: Map<u32, u32>, // an instruction with a used flag -> the flag's value index
    pub(package) home: Vector<u8>, // per value, its HOME_* (`plan`)
    /// The largest access a scaled index addresses (the target's, 0: none); per instruction, whether the
    /// load or store takes its address `ptradd`'s operands (`fold`), and whether the `ptradd` emits nothing
    /// for that (`pfold`; `uses_at`).
    pub(package) fold_max: u32,
    pub(package) fold: Vector<bool>,
    pub(package) pfold: Vector<bool>,
    /// Stores whose value a call takes in place of memory (the generator's, before `run`): per
    /// instruction, a relayed store's call, else NONE (empty: none); `relayed`, call << 32 | store for each
    /// store whose value the call reads. A relayed store reads nothing; its call reads those values
    /// (`uses_at`).
    pub(package) relay: Vector<u32>,
    pub(package) relayed: Vector<u64>,
    /// The instructions that fold into their uses (`FOLD_*`, the target's): each use computes the folded
    /// instruction from its operands, which live to it (`uses_at`), and the instruction emits nothing
    /// (`pfold`).
    pub(package) fold_ops: u32,
    cnd: Vector<u32>, // `folds`' scratch: per instruction, its uses as a condition
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
    pub(package) fn new() Live {
        return Live {
            order: Vector::<u32>::new(),
            pos: Vector::<u32>::new(),
            npred: Vector::<u32>::new(),
            inner: Vector::<u32>::new(),
            lend: Vector::<u32>::new(),
            parent: Vector::<u32>::new(),
            rare: Vector::<bool>::new(),
            after: Vector::<bool>::new(),
            def_blk: Vector::<u32>::new(),
            end: Vector::<u32>::new(),
            uses: Vector::<u32>::new(),
            last: Vector::<u32>::new(),
            flag_of: Map::<u32, u32>::new(),
            home: Vector::<u8>::new(),
            fold_max: 0,
            fold: Vector::<bool>::new(),
            pfold: Vector::<bool>::new(),
            relay: Vector::<u32>::new(),
            relayed: Vector::<u64>::new(),
            fold_ops: 0,
            cnd: Vector::<u32>::new(),
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
    pub(package) const fn vix(self: &Self, b: &Body, v: Value) u32 {
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
    pub(package) fn run(self: &mut Self, b: &Body) {
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
        self.rare_blocks(b);
        self.loops(b);
        self.layout(b);
        self.folds(b);
        self.ranges(b);
    }

    // `fold`: a load or store of no offset whose address is a `ptradd` with an index, no offset, a scale
    // of 1 or the access's size (up to `fold_max`) and this one use, takes the `ptradd`'s operands as its
    // address (`ldr x0, [x1, x2, lsl #3]`, `mov (%rax,%rcx,8), %rdx`): they live to the access.
    //
    // The other instructions fold as `fold_ops` lets them (`FOLD_*`).
    fn folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.fold.truncate(0);
        self.fold.resize_default(ni);
        self.pfold.truncate(0);
        self.pfold.resize_default(ni);
        if self.fold_max == 0 && self.fold_ops == 0 {
            return;
        }
        // The use count of each instruction, and its uses as a condition.
        fill(&mut self.work, ni, 0);
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == 0 {
                    self.work[v as usize] += 1;
                }
            }
            if (t.op == O_SELECT || t.op == O_BR) && (t.a & (VPARAM | VFLAG)) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            self.pfold[i] = (self.fold_ops & FOLD_CMP) != 0 && t.op == O_ICMP && b.type_of(t.a) != T_I128 && self.work[i] != 0 && self.cnd[i] == self.work[i];
        }
        // An `and`'s uses as an equality with 0.
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (t.a & (VPARAM | VFLAG)) == 0 && b.insts[t.a as usize].op == O_AND && int_const(
                b,
                t.b,
            ) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            if !is_int(t.ty) || t.ty == T_I128 {
                continue;
            }
            let bits = type_bits(t.ty, 8);
            if t.op == O_AND && (self.fold_ops & FOLD_TST) != 0 && self.work[i] != 0 && self.cnd[i] == self.work[i] {
                // A narrow type's register may hold any bits above it: only a mask within the type tests.
                let m = int_const(b, t.b);
                self.pfold[i] = bits >= 32 || m != u64::MAX && m >> bits as u64 == 0;
            }
            let p = if t.op == O_SUB || t.op == O_ADD && int_const(b, t.a) == u64::MAX && int_const(b, t.b) == u64::MAX {
                t.b;
            } else {
                VNONE;
            };
            if (self.fold_ops & FOLD_MADD) != 0 && p != VNONE && (p & (VPARAM | VFLAG)) == 0 && b.insts[p as usize].op == O_MUL && self.work[p as usize] == 1 && int_const(
                b,
                t.a,
            ) == u64::MAX {
                self.pfold[p as usize] = true;
            }
            if (self.fold_ops & FOLD_ROT) != 0 && (bits >= 32 || (self.fold_ops & FOLD_ROT_NARROW) != 0) {
                let amt = rotate_of(b, i as u32).amt;
                if rotate_of(b, i as u32).x != VNONE && self.work[t.a as usize] == 1 && self.work[t.b as usize] == 1 {
                    self.pfold[t.a as usize] = true;
                    self.pfold[t.b as usize] = true;
                    // Each amount's extension or truncation with this one use. `inside`: the uses of the
                    // amount the folded instructions make; `open`: the other amount's user folds.
                    let mut inside: u32 = 0;
                    let mut open = false;
                    // The amount operand of the shift that takes `amt` itself, maybe its extension.
                    let mut own = VNONE;
                    for q in 0..2u32 {
                        let sh = if q == 0 {
                            t.a;
                        } else {
                            t.b;
                        };
                        let s = b.insts[sh as usize].b;
                        let ext = amount_of(b, s) != s;
                        if ext && self.work[s as usize] == 1 {
                            self.pfold[s as usize] = true;
                        }
                        if amount_of(b, s) == amt {
                            own = s;
                        }
                        if amount_of(b, s) == amt && (!ext || self.pfold[s as usize]) {
                            inside += 1;
                        }
                        if amount_of(b, s) != amt && (!ext || self.pfold[s as usize]) {
                            open = true;
                        }
                    }
                    if amt != VNONE {
                        // The other amount's `and` and `sub` or `neg`, while each has this one use; then the
                        // amount's own mask to the width, when the rotation alone reads it (a rotation
                        // takes its amount modulo the width).
                        let sa = amount_of(b, b.insts[t.a as usize].b);
                        let mut v = if sa == amt {
                            amount_of(b, b.insts[t.b as usize].b);
                        } else {
                            sa;
                        };
                        for _ in 0..2 {
                            if !open || !is_inst(v) || self.work[v as usize] != 1 {
                                break;
                            }
                            let o = b.insts[v as usize].op;
                            if o != O_AND && o != O_SUB && o != O_NEG {
                                break;
                            }
                            self.pfold[v as usize] = true;
                            v = if o == O_SUB {
                                b.insts[v as usize].b;
                            } else {
                                b.insts[v as usize].a;
                            };
                        }
                        if v == amt {
                            inside += 1;
                        }
                        // The amount's extension, which the other amount's folded chain may read too: folded
                        // when the shift and that chain are its only users.
                        if own != amt && !self.pfold[own as usize] && self.work[own as usize] == 1 + (v == own) as u32 {
                            self.pfold[own as usize] = true;
                            inside += 1;
                        }
                        if is_inst(amt) && b.insts[amt as usize].op == O_AND && int_const(b, b.insts[amt as usize].b) == bits as u64 - 1 && self.work[amt as usize] == inside {
                            self.pfold[amt as usize] = true;
                        }
                    }
                    continue;
                }
            }
            if (self.fold_ops & FOLD_LEA) != 0 && (t.op == O_ADD || t.op == O_SUB) {
                // The shift an index takes, then the inner sum whose operands the address takes.
                let nq: u32 = if t.op == O_ADD {
                    2;
                } else {
                    0;
                };
                for q in 0..nq {
                    let v = if q == 0 {
                        t.b;
                    } else {
                        t.a;
                    };
                    if lea_shift(b, v) == 0 || self.pfold[v as usize] || self.work[v as usize] != 1 {
                        continue;
                    }
                    self.pfold[v as usize] = true;
                    if lea_of(b, &self.pfold, i as u32).ok {
                        break;
                    }
                    self.pfold[v as usize] = false;
                }
                for q in 0..2u32 {
                    let v = if q == 0 {
                        t.a;
                    } else {
                        t.b;
                    };
                    if q == 1 && t.op == O_SUB || !is_inst(v) || self.pfold[v as usize] || self.work[v as usize] != 1 || b.insts[v as usize].op != O_ADD || b.insts[v as usize].ty != t.ty {
                        continue;
                    }
                    self.pfold[v as usize] = true;
                    if lea_of(b, &self.pfold, i as u32).ok {
                        break;
                    }
                    self.pfold[v as usize] = false;
                }
            }
            if (self.fold_ops & FOLD_UBFX) != 0 && t.op == O_AND && !self.pfold[i] && (t.a & (VPARAM | VFLAG)) == 0 {
                let s = b.insts[t.a as usize];
                let m = int_const(b, t.b);
                let k = if s.op == O_LSHR {
                    int_const(b, s.b);
                } else {
                    u64::MAX;
                };
                // A mask of the low `w` bits under a shift by `k`, both within the width.
                if self.work[t.a as usize] == 1 && m != u64::MAX && m != 0 && (m & m + 1) == 0 && k < bits as u64 {
                    let w = (m + 1).trailing_zeros() as u64;
                    self.pfold[t.a as usize] = self.pfold[t.a as usize] || k + w <= bits as u64;
                }
            }
        }
        if self.fold_max == 0 {
            return;
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
    /// branch's other edge must leave the loop, and no path from it reads the parameter but through the
    /// header, which defines it again (`reads_before`).
    pub(package) fn back_param(self: &Self, b: &Body, t: Inst, v: Value, pos: u32) u32 {
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
                    if self.lend[tk as usize] == NONE || o >= self.pos[tk as usize] && o <= self.lend[tk as usize] || self.end[px as usize] > self.lend[tk as usize] && reads_before(
                        b,
                        b.edge_target(edge_of(b, t, 1 - e)),
                        tk,
                        VPARAM | px - b.insts.len() as u32,
                        &self.pos,
                        self.end[px as usize],
                    ) {
                        return NONE;
                    }
                }
                return px;
            }
        }
        return NONE;
    }

    /// The rare blocks of `b` (`rare`) that edges between rare blocks connect to one of `framed` (per block:
    /// it holds a call that needs the frame): `after`, which the next `run` lays out last.
    pub(package) fn set_after(self: &mut Self, b: &Body, framed: &Vector<bool>) {
        // Per block, its component's root (union by index, paths halved: each step shortens a path).
        let nb = b.blocks.len();
        let mut root = Vector::<u32>::with_capacity(nb);
        for k in 0..nb {
            root.push(k as u32);
        }
        let mut es = Vector::<u32>::new();
        for k in 0..nb {
            if !self.rare[k] {
                continue;
            }
            let bk = b.blocks[k];
            b.succ_edges(b.insts[(bk.start + bk.len - 1) as usize], &mut es);
            for e in 0..es.len() {
                let s = b.edge_target(es[e]);
                if self.rare[s as usize] {
                    let x = find_root(&mut root, k as u32);
                    let y = find_root(&mut root, s);
                    if x != y {
                        root[x.max(y) as usize] = x.min(y);
                    }
                }
            }
        }
        let mut fr = Vector::<bool>::new();
        fr.resize_default(nb);
        for k in 0..nb {
            if framed[k] {
                fr[find_root(&mut root, k as u32) as usize] = true;
            }
        }
        self.after.truncate(0);
        for k in 0..nb {
            self.after.push(self.rare[k] && fr[find_root(&mut root, k as u32) as usize]);
        }
    }

    /// Whether an instruction of block `k` of `b` after instruction `i`, its terminator's edges included,
    /// reads value `v`.
    pub(package) fn reads_after(self: &mut Self, b: &Body, k: u32, i: u32, v: Value) bool {
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

    /// Whether the stores into slot `s` of `b` relay (`relay`): every use of its addresses is such a store
    /// or a call's argument, so no instruction reads or writes its memory.
    pub(package) fn relays_slot(self: &Self, b: &Body, s: u32) bool {
        for q in 0..self.relayed.len() {
            if b.insts[b.insts[(self.relayed[q] & 0xFFFFFFFF) as usize].a as usize].a == s {
                return true;
            }
        }
        return false;
    }

    /// The values instruction `i` of `b` uses, as `each_use` gives them but for the folded instructions
    /// (`pfold`): a use of one is a use of its two operands, and one uses none.
    pub(package) fn uses_at(self: &Self, b: &Body, i: u32, out: &mut Vector<Value>) {
        if self.pfold[i as usize] || self.relay.len() != 0 && self.relay[i as usize] != NONE {
            out.truncate(0);
            return;
        }
        each_use(b, b.insts[i as usize], out);
        let mut u: usize = 0;
        let mut n: u32 = 0;
        while u < out.len() {
            let v = out[u];
            if (v & (VPARAM | VFLAG)) != 0 || !self.pfold[v as usize] {
                u += 1;
                continue;
            }
            n += 1;
            assert(n <= FOLD_DEPTH, "live: more folded instructions in one use than FOLD_DEPTH");
            let p = b.insts[v as usize];
            out.swap_remove(u);
            out.push(p.a);
            if p.b != VNONE {
                out.push(p.b);
            }
        }
        for q in 0..self.relayed.len() {
            if (self.relayed[q] >> 32) as u32 == i {
                out.push(b.insts[(self.relayed[q] & 0xFFFFFFFF) as usize].b);
            }
        }
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

    // `rare`: the reachable blocks the entry reaches only through a block marked rare, that block included;
    // none when the entry is marked.
    fn rare_blocks(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        self.rare.truncate(0);
        let marked = (b.blocks[0].flags & BLOCK_RARE) != 0;
        for k in 0..nb {
            self.rare.push(self.rpo[k] != NONE && !marked);
        }
        if marked {
            return;
        }
        self.rare[0] = false;
        self.stack.truncate(0);
        self.stack.push(0);
        // Each block enters the stack once.
        while self.stack.len() != 0 {
            let k = self.stack.pop().unwrap();
            let t = b.insts[(b.blocks[k as usize].start + b.blocks[k as usize].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                let s = b.edge_target(self.succ[e]);
                if self.rare[s as usize] && (b.blocks[s as usize].flags & BLOCK_RARE) == 0 {
                    self.rare[s as usize] = false;
                    self.stack.push(s);
                }
            }
        }
    }

    // `order` and `pos`: the reachable warm blocks in reverse postorder, where a loop header brings its
    // whole loop (its members in reverse postorder, nested loops likewise); then the rare blocks.
    fn layout(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        // The warm blocks in reverse postorder.
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rpo[k] != NONE && !self.rare[k] {
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
        // The rare blocks in reverse postorder: one inside a loop with a warm header right after the innermost
        // such loop's last warm block (the loop stays contiguous, and the values live at a block it enters
        // live no further), the others last.
        self.loop_ends();
        self.keys.truncate(0);
        for k in 0..nb {
            if self.rare[k] {
                self.keys.push(self.rpo[k] as u64 << 32 | k as u64);
            }
        }
        self.keys.sort();
        let mut tail = Vector::<u64>::new();
        for j in 0..self.keys.len() {
            let h = self.warm_loop(self.keys[j] as u32);
            if h != NONE {
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
            if self.warm_loop(self.keys[j] as u32) == NONE {
                out.push(self.keys[j] as u32);
            }
        }
        // The blocks the generator puts last (`after`), in order.
        if self.after.len() == nb {
            let mut tail = Vector::<u32>::new();
            let mut j: usize = 0;
            for i in 0..out.len() {
                if self.after[out[i] as usize] {
                    tail.push(out[i]);
                } else {
                    out[j] = out[i];
                    j += 1;
                }
            }
            out.truncate(j);
            out.extend_copy(&tail);
        }
        self.order = out;
        for i in 0..self.order.len() {
            self.pos[self.order[i] as usize] = i as u32;
        }
        fill(&mut self.lend, nb, 0);
        self.loop_ends();
    }

    // The header of the innermost loop with a warm header around block `k`, NONE when none.
    const fn warm_loop(self: &Self, k: u32) u32 {
        let mut h = self.inner[k as usize];
        // Each step leaves one loop.
        while h != NONE && self.rare[h as usize] {
            h = self.parent[h as usize];
        }
        return h;
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
        self.rare_entries(b, &mut kept);
        // One more use, which no instruction makes: a kept value lives to the end of its last block.
        for x in 0..n {
            if kept[x] {
                self.uses[x] += 1;
            }
        }
    }
}

extend Live {
    /// Per instruction of `b` into `out`: whether it is a float or integer constant a loop block uses that
    /// lives past its block. No instruction takes a float as an immediate, and a wide integer takes several
    /// to build, so recomputing one at each use costs instructions every iteration: a generator asks a
    /// register for its whole range instead (an integer one when building it takes more than one
    /// instruction). After `run`.
    pub(package) fn loop_consts(self: &mut Self, b: &Body, out: &mut Vector<bool>) {
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
                    if (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_FCONST || b.insts[v as usize].op == O_ICONST) {
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
    /// its definition and uses: 8 per loop level up to 5, an eighth of that in an unlikely block, 0 in a
    /// cold one) gives its register up to a heavier one. A range runs from its definition (a parameter's:
    /// the first edge into it) to its last use (a kept value's, a parameter's or a flag's: the end of its
    /// last block). After `run`, before the generator counts the uses down.
    pub(package) fn plan(self: &mut Self, b: &Body, want: &Vector<u8>, caps: Caps) {
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
            self.freq[k] = if self.rare[k] {
                f / 8;
            } else {
                f;
            };
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

    /// Whether `plan` gave no register to a used value that `want` asked one for, in a block the layout
    /// does not put last (`after`).
    pub(package) fn homeless(self: &Self, want: &Vector<u8>) bool {
        for x in 0..self.home.len() {
            let d = self.def_blk[x];
            if (want[x] & (WANT_CALLEE | WANT_SCRATCH)) != 0 && self.home[x] == HOME_NONE && self.au[x] != 0 && d != NONE && self.pos[d as usize] != NONE && !self.after[d as usize] {
                return true;
            }
        }
        return false;
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

    // A rare block that branches into the body runs inside the ranges of the values live at its target,
    // though the layout puts it last: each value whose range holds the position of such a target, past the
    // block it is defined in (an instruction is not live at its own block's entry, a parameter is), lives
    // to the rare block too, and is kept (its last use does not end it), also when its own use there
    // already ends its range at the rare block (a loop counter a rare call reads). A range max over the
    // targets' positions (a sparse table of `best`: per position, the last rare block with an edge into
    // it) finds the extension of each value.
    fn rare_entries(self: &mut Self, b: &Body, kept: &mut Vector<bool>) {
        let np = self.order.len();
        let mut best = Vector::<u32>::new();
        fill(&mut best, np, 0);
        let mut any = false;
        for p in 0..np {
            let bk = b.blocks[self.order[p] as usize];
            if !self.rare[self.order[p] as usize] {
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
        let ni = b.insts.len();
        for x in 0..self.end.len() {
            let d = self.def_blk[x];
            if d == NONE || self.pos[d as usize] == NONE {
                continue;
            }
            let lo = self.pos[d as usize] as usize + (x < ni) as usize;
            // Each step moves the end to a later rare block: at most one step per rare block.
            loop {
                let hi = self.end[x] as usize;
                if lo > hi {
                    break;
                }
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
                // 0: no rare block's edge (the entry, at 0, is not rare).
                if e < self.end[x] || e == 0 {
                    break;
                }
                kept[x] = true;
                if e == self.end[x] {
                    break;
                }
                self.end[x] = e;
            }
        }
    }
}

/// Whether vector operation `t` (`O_VOP`) is a reduction, which computes in place over temporaries
/// (no call).
pub(package) const fn reduces(t: Inst) bool {
    let code = (t.aux & VOP_CODE) as u32;
    return code >= core::OP_SIMD && code < core::OP_CMP_LANES && core::simd_op((code - core::OP_SIMD) as u8).rule == core::SR_REDUCE;
}
/// Whether instruction `t` of `b` uses an address of slot `s` (an operand, an argument or an edge's argument);
/// `us` and `es` are scratch.
pub(package) fn reads_slot(b: &Body, t: Inst, s: u32, us: &mut Vector<Value>, es: &mut Vector<u32>) bool {
    each_use(b, t, us);
    b.succ_edges(t, es);
    for e in 0..es.len() {
        for q in 0..b.edge_nargs(es[e]) {
            us.push(b.edge_arg(es[e], q));
        }
    }
    for q in 0..us.len() {
        let v = us[q];
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR && b.insts[v as usize].a == s {
            return true;
        }
    }
    return false;
}

/// The values instruction `t` of `b` uses into `out`, each use once: its operands, a call's arguments, a
/// vector operation's operands and each edge's arguments.
// `reads_before` follows at most BACK_SCAN blocks.
const BACK_SCAN: u32 = 32;

pub(package) fn each_use(b: &Body, t: Inst, out: &mut Vector<Value>) {
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
pub(package) fn each_edge_param(b: &Body, t: Inst, out: &mut Vector<u32>) {
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
// Whether a path from block `from` reads value `v` before it reaches block `stop`: an instruction or an
// edge argument of a block on it; true too past BACK_SCAN blocks. A block laid out past `last` (`pos`),
// the end of `v`'s range, has `v` dead: no such path passes it.
fn reads_before(b: &Body, from: u32, stop: u32, v: Value, pos: &Vector<u32>, last: u32) bool {
    let mut seen = Vector::<u32>::new();
    let mut work = Vector::<u32>::new();
    let mut us = Vector::<Value>::new();
    let mut es = Vector::<u32>::new();
    work.push(from);
    // Each step visits one block, at most BACK_SCAN.
    while let Some(k) = work.pop() {
        if k == stop || pos[k as usize] == NONE || pos[k as usize] > last || contains_u32(&seen, k) {
            continue;
        }
        if seen.len() as u32 >= BACK_SCAN {
            return true;
        }
        seen.push(k);
        let bk = b.blocks[k as usize];
        for i in bk.start..bk.start + bk.len {
            let t = b.insts[i as usize];
            each_use(b, t, &mut us);
            for u in 0..us.len() {
                if us[u] == v {
                    return true;
                }
            }
            if is_terminator(t.op) {
                b.succ_edges(t, &mut es);
                for x in 0..es.len() {
                    for q in 0..b.edge_nargs(es[x]) {
                        if b.edge_arg(es[x], q) == v {
                            return true;
                        }
                    }
                    work.push(b.edge_target(es[x]));
                }
            }
        }
    }
    return false;
}

// The root of `k0`'s set in union-find forest `root`, its path halved.
fn find_root(root: &mut Vector<u32>, k0: u32) u32 {
    let mut k = k0;
    // Each step moves `k` closer to the root: at most `root.len()` steps.
    while root[k as usize] != k {
        root[k as usize] = root[root[k as usize] as usize];
        k = root[k as usize];
    }
    return k;
}

const fn contains_u32(xs: &Vector<u32>, x: u32) bool {
    for k in 0..xs.len() {
        if xs[k] == x {
            return true;
        }
    }
    return false;
}

pub(package) const fn edge_of(b: &Body, t: Inst, k: u32) u32 {
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
pub(package) fn fill(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    v.resize_default(n);
    if x != 0 {
        v.as_mut_slice().fill(x);
    }
}

// The bits of integer constant `v`, u64::MAX for a value that is no constant (or that constant).
/// A rotation (`rotate_of`): value `x` by amount `amt` (VNONE for constant `k`, rotating left), to the
/// right when `right`; `x` VNONE for none. `src` is the shift's own amount operand, `amt` maybe past an
/// extension of it (`rot_amount`).
pub(package) struct Rotation {
    pub(package) x: Value,
    pub(package) amt: Value,
    pub(package) src: Value,
    pub(package) k: u32,
    pub(package) right: bool,
}

extend Rotation as Copy {}

/// The rotation `or`, `xor` or `add` `i` of `b` computes: of a shift left and a logical shift right of one
/// value, by constants `k` and `w - k` (0 < k < w, the width), or by `s` and `w - s`, or, for an `or`, by
/// `s` and `(c - s) & (w - 1)` (c a multiple of w) or `-s & (w - 1)`, `s` the amount or the value it masks
/// with `w - 1`, each amount maybe through a zero extension or a truncation (`amount_of`: an amount of
/// another type). A shift past the width is undefined, so `s` is below it: by `w - s`, `s` is not 0 and the
/// shifts' bits are disjoint, so their sum and their `xor` are their `or`; a masked `s` of 0 shifts both
/// by 0, which only the `or` of the value with itself rotates. The amount rotates right when it is the
/// shift right's.
pub(package) fn rotate_of(b: &Body, i: u32) Rotation {
    let none = Rotation { x: VNONE, amt: VNONE, src: VNONE, k: 0, right: false };
    let t = b.insts[i as usize];
    if t.op != O_OR && t.op != O_XOR && t.op != O_ADD || !is_int(t.ty) || t.ty == T_I128 || !is_inst(t.a) || !is_inst(
        t.b,
    ) {
        return none;
    }
    let bits = type_bits(t.ty, 8) as u64;
    let p = b.insts[t.a as usize];
    let q = b.insts[t.b as usize];
    let (l, r) = if p.op == O_SHL && q.op == O_LSHR {
        (p, q);
    } else if p.op == O_LSHR && q.op == O_SHL {
        (q, p);
    } else {
        return none;
    };
    if l.a != r.a || l.ty != t.ty || r.ty != t.ty {
        return none;
    }
    let kl = int_const(b, l.b);
    let kr = int_const(b, r.b);
    let al = amount_of(b, l.b);
    let ar = amount_of(b, r.b);
    if kl != u64::MAX && kr != u64::MAX {
        if kl > 0 && kl < bits && kl + kr == bits {
            return Rotation { x: l.a, amt: VNONE, src: VNONE, k: kl as u32, right: false };
        }
        return none;
    }
    let or = t.op == O_OR;
    if negated(b, ar, al, bits, or) {
        return Rotation { x: l.a, amt: al, src: l.b, k: 0, right: false };
    }
    if negated(b, al, ar, bits, or) {
        return Rotation { x: l.a, amt: ar, src: r.b, k: 0, right: true };
    }
    return none;
}

/// The value a generator reads rotation `r`'s amount from (`folded`, the folded instructions): the shift's
/// own amount operand, past a folded extension or truncation and a folded mask to the width (the
/// rotation takes the amount modulo the width), whose operands live to the rotation; an unfolded one
/// lives itself.
pub(package) fn rot_amount(b: &Body, folded: &Vector<bool>, r: Rotation) Value {
    let mut n = r.src;
    for _ in 0..2 {
        if !is_inst(n) || !folded[n as usize] {
            break;
        }
        n = b.insts[n as usize].a;
    }
    return n;
}

/// Shift amount `v` past one zero extension or truncation: the amount computed in another type, which
/// is below the width wherever the shift is defined.
pub(package) fn amount_of(b: &Body, v: Value) Value {
    if is_inst(v) && (b.insts[v as usize].op == O_ZEXT || b.insts[v as usize].op == O_TRUNC) {
        return b.insts[v as usize].a;
    }
    return v;
}

// Whether shift amount `v` is `w - s` or, when `masks`, `(c - s) & (w - 1)` (c a multiple of width `w`) or
// `-s & (w - 1)`, for the amount `s` (`rotate_of`).
fn negated(b: &Body, v: Value, s: Value, w: u64, masks: bool) bool {
    if !is_inst(v) {
        return false;
    }
    let mut u = v;
    let masked = masks && b.insts[u as usize].op == O_AND && int_const(b, b.insts[u as usize].b) == w - 1;
    if masked {
        u = b.insts[u as usize].a;
        if !is_inst(u) {
            return false;
        }
    }
    let p = b.insts[u as usize];
    let c = int_const(b, p.a);
    let n = if p.op == O_SUB && c != u64::MAX && (masked && c % w == 0 || c == w) {
        p.b;
    } else if p.op == O_NEG && masked {
        p.a;
    } else {
        VNONE;
    };
    if n == VNONE {
        return false;
    }
    // `s` itself, or the value it masks to the width, either past an extension or a truncation.
    let m = amount_of(b, n);
    return m == s || is_inst(s) && b.insts[s as usize].op == O_AND && int_const(b, b.insts[s as usize].b) == w - 1 && amount_of(
        b,
        b.insts[s as usize].a,
    ) == m;
}

/// The shift a scaled index of an address takes (`lea_of`): 1 to 3 for a shift left by that constant, else
/// 0.
pub(package) fn lea_shift(b: &Body, v: Value) u32 {
    if !is_inst(v) || b.insts[v as usize].op != O_SHL {
        return 0;
    }
    let k = int_const(b, b.insts[v as usize].b);
    return if k >= 1 && k <= 3 {
        k as u32;
    } else {
        0u32;
    };
}

/// An address `lea` computes (`lea_of`): `base` + `index` << `sh` + `disp`, either register VNONE; `ok`
/// false for none.
pub(package) struct Lea {
    pub(package) ok: bool,
    pub(package) base: Value,
    pub(package) index: Value,
    pub(package) sh: u32,
    pub(package) disp: i64,
}

extend Lea as Copy {}

/// The address form in which `lea` computes sum `i` of `b` (`FOLD_LEA`; `folded`, the folded
/// instructions): an `add`, or a `sub` of a constant, of up to two registers, one of them shifted left by
/// 1 to 3 when folded (`lea_shift`), and a displacement that 32 signed bits hold, a folded inner `add`'s
/// operands among its own. An index alone takes a shift of at most 1 (`index + index`): no form here
/// lacks a base.
pub(package) fn lea_of(b: &Body, folded: &Vector<bool>, i: u32) Lea {
    let mut f = Lea { ok: true, base: VNONE, index: VNONE, sh: 0, disp: 0 };
    let t = b.insts[i as usize];
    if t.op != O_ADD && t.op != O_SUB || !is_int(t.ty) || t.ty == T_I128 || t.op == O_SUB && int_const(b, t.b) == u64::MAX {
        f.ok = false;
        return f;
    }
    let bits = type_bits(t.ty, 8);
    for q in 0..2u32 {
        let v = if q == 0 {
            t.a;
        } else {
            t.b;
        };
        let neg = q == 1 && t.op == O_SUB;
        // A folded inner sum's operands in its place.
        if is_inst(v) && folded[v as usize] && b.insts[v as usize].op == O_ADD {
            lea_term(b, folded, b.insts[v as usize].a, false, bits, &mut f);
            lea_term(b, folded, b.insts[v as usize].b, false, bits, &mut f);
        } else {
            lea_term(b, folded, v, neg, bits, &mut f);
        }
    }
    if f.disp < -2147483648 || f.disp > 2147483647 || f.base == VNONE && (f.index == VNONE || f.sh > 1) {
        f.ok = false;
    }
    return f;
}

// Operand `v` (`bits` wide, negated when `neg`) into address `f` (`lea_of`): a constant into the
// displacement, a folded shift as the index, a register as the base, then as the index; `ok` false when
// it takes none (a folded operand has no register).
fn lea_term(b: &Body, folded: &Vector<bool>, v: Value, neg: bool, bits: u32, f: &mut Lea) {
    let k = int_const(b, v);
    if k != u64::MAX {
        let s = sext_bits(k, bits);
        f.disp = if neg {
            f.disp - s;
        } else {
            f.disp + s;
        };
        return;
    }
    let fold = is_inst(v) && folded[v as usize];
    if fold && lea_shift(b, v) != 0 && f.index == VNONE {
        f.index = b.insts[v as usize].a;
        f.sh = lea_shift(b, v);
    } else if fold {
        f.ok = false;
    } else if f.base == VNONE {
        f.base = v;
    } else if f.index == VNONE {
        f.index = v;
    } else {
        f.ok = false;
    }
}

// Value `v` is an instruction's (no parameter, no flag, not VNONE).
const fn is_inst(v: Value) bool {
    return v != VNONE && (v & (VPARAM | VFLAG)) == 0;
}

// The signed value of the low `bits` of `k`.
const fn sext_bits(k: u64, bits: u32) i64 {
    let s = 64 - bits as u64;
    return (k << s) as i64 >> s as i64;
}

fn int_const(b: &Body, v: Value) u64 {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST {
        return u64::MAX;
    }
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}
