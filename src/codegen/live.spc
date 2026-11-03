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
/// (`rol`, `ror`); the shift left by 1 to 3 and the inner sum one sum takes as an address (`lea_of`); an
/// `and` or `or` of flags that are comparisons each with this one use, or such `and`s and `or`s, compared
/// one after the other (`conj`: arm64's `ccmp`); a mask of a 32- or 64-bit shift's amount to the low bits
/// of the width, which the shift takes modulo its width anyway (`shift_amount`); a `select`'s side that is
/// the other side plus 1, negated or inverted (`cs_kind`: arm64's `csinc`, `csneg`, `csinv`); two
/// extensions of the same kind from 32 bits, or one and a constant within the extension's range, that a
/// 64-bit product alone reads (`mull_ext`: arm64's `umull`, `smull`); a shift by a constant that a 32- or 64-bit sum, difference or bitwise operation
/// alone reads as an operand it may take shifted (`shop_side`: arm64's shifted register operand); a
/// scalar float comparison only selects and branches read, of one condition (`FOLD_FCMP`; not `one`,
/// `ueq`).
pub(package) const FOLD_CMP: u64 = 1;
pub(package) const FOLD_TST: u64 = 2;
pub(package) const FOLD_MADD: u64 = 4;
pub(package) const FOLD_UBFX: u64 = 8;
pub(package) const FOLD_ROT: u64 = 16;
pub(package) const FOLD_ROT_NARROW: u64 = 32;
pub(package) const FOLD_LEA: u64 = 64;
pub(package) const FOLD_CCMP: u64 = 128;
pub(package) const FOLD_SHAMT: u64 = 256;
pub(package) const FOLD_CSEL: u64 = 512;
pub(package) const FOLD_MULL: u64 = 1024;
pub(package) const FOLD_SHOP: u64 = 2048;
pub(package) const FOLD_FCMP: u64 = 4096;
pub(package) const FOLD_BLEN: u64 = 8192;
pub(package) const FOLD_CARRY: u64 = 16384;
pub(package) const FOLD_FSEL: u64 = 32768;
pub(package) const FOLD_NOT: u64 = 65536;
pub(package) const FOLD_XBFX: u64 = 131072;
pub(package) const FOLD_BFI: u64 = 262144;
/// A load's or store's folded index that is the 64-bit zero or sign extension of a 32-bit value (or of an
/// unsigned 8- or 16-bit entry parameter, under `ext_args`), which only that access reads: the access
/// extends it (arm64 `[xn, wm, uxtw]`).
pub(package) const FOLD_XIDX: u64 = 524288;
/// `FOLD_LDOP`: a single-use scalar float load as the right operand of arithmetic, or an integer load
/// that one comparison or `add`, `sub`, `and`, `or`, `xor` or `mul` reads
/// folds into it, which reads the memory (x86-64's `cmp [m], k`, `add r, [m]`, `imul r, [m]`;
/// `Live::ldop_user`).
pub(package) const FOLD_LDOP: u64 = 1048576;
/// `FOLD_ANY`: an `or` of the lanes of a 16-byte lane mask (`lane_mask`) that equalities with 0 alone
/// read folds into each: they test the lanes' sign bits (x86-64's `pmovmskb` and `test`). `FOLD_ANY_WIDE`:
/// of a 32-byte one too (AVX2's `vpmovmskb`).
pub(package) const FOLD_ANY: u64 = 2097152;
pub(package) const FOLD_ANY_WIDE: u64 = 4194304;
/// `FOLD_VMLA`: a product of integer vectors of 8 or 16 bytes, lanes below 8 bytes, with one use, the second
/// operand of a sum or a difference or the first of a sum, folds into it (arm64's MLA and MLS); else a right
/// shift by an immediate (`vshimm`) with one use, an operand of a sum, folds into it (USRA and SSRA).
pub(package) const FOLD_VMLA: u64 = 8388608;
/// `FOLD_VSHIMM`: a vector shift by one constant below its integer lanes' width (`vec_shift_amount`) shifts
/// by an immediate, and a splat or wide constant such shifts alone read as their amount folds into them:
/// 16-byte vectors of 2- to 8-byte lanes, the arithmetic shifts below 8 (SSE2). `FOLD_VSHIMM_WIDE`: 32-byte
/// ones too (AVX2). `FOLD_VSHIMM_ALL`: 8- and 16-byte vectors of any lanes but a lone 8-byte one (Neon).
pub(package) const FOLD_VSHIMM: u64 = 16777216;
pub(package) const FOLD_VSHIMM_WIDE: u64 = 33554432;
pub(package) const FOLD_VSHIMM_ALL: u64 = 67108864;
/// `FOLD_XADDR`: an address `ptradd` of a base and an index scaled by 1, 2, 4 or 8 that only the loads
/// and stores of its block read as their address folds into each, at any offset (x86-64's
/// `[base + index * scale + disp]`).
pub(package) const FOLD_XADDR: u64 = 134217728;
/// `FOLD_BRCONJ`: an `and` or `or` of two integer comparisons of up to 64 bits, each with that one use,
/// whose one use is a `br`: both fold into the branch, which tests the first and jumps, then the second
/// (x86-64's `cmp; jcc; cmp; jcc`).
pub(package) const FOLD_BRCONJ: u64 = 268435456;
/// `FOLD_VWADD`: a 16-byte integer vector `bitcast` of a `vziplo` or `vziphi` of a vector with zeros (its
/// low or high half zero-extended to lanes twice as wide), each with one use, that a vector sum of the
/// wide lanes adds: the sum widens and adds (arm64 `uaddw`, `uaddw2`).
pub(package) const FOLD_VWADD: u64 = 536870912;
/// `FOLD_TRUNC`: a truncation of an integer to 8 or 16 bits that only integer comparisons read folds into
/// each: they extend or test its low bits in the source's register (arm64 `tst`, `uxtb`, `sxth`).
pub(package) const FOLD_TRUNC: u64 = 1073741824;
/// `FOLD_ADC`: the sum `h + zext(c)` (or difference `h - zext(c)`) of a sum (difference) `h` of two values
/// and the carry (borrow) `c` of an unsigned `addo` (`subo`) of the same width, 32 or 64 bits, with only
/// `h` and the extension between them, each of one use and no flag read: `h` and the extension fold into
/// it, the `addo` keeps its carry in the flags, and it adds with it (`adc`, arm64 `sbc` / x86-64 `sbb`).
/// `Live::carry` marks the three parts.
pub(package) const FOLD_ADC: u64 = 2147483648;
/// `FOLD_LANE`: a lane read (`vextract`) of a vector of 8 or 16 bytes, lanes of 4 or 8 bytes, whose one use is
/// a `splat`: the splat broadcasts the lane from the vector's register (arm64 `dup v, v[k]`, x86-64 `pshufd`).
pub(package) const FOLD_LANE: u64 = 4294967296;
/// `FOLD_LANE_MUL`: such a splat of a lane with one use, the second operand of a product of float vectors of 8
/// or 16 bytes, folds into it too: the product multiplies by the lane (arm64 `fmul v, v, v[k]`).
pub(package) const FOLD_LANE_MUL: u64 = 8589934592;
/// `FOLD_ZSHL`: a zero extension of an integer of `k` bits with one use, a left shift by a constant `s`
/// with `k + s` at least the width, folds into it: every bit the extension clears leaves the result, so
/// the shift reads the narrow value's register (`shl_source`). Neither may fold into anything else.
pub(package) const FOLD_ZSHL: u64 = 17179869184;
/// `FOLD_FREE_ZEXT`: a zero extension of an 8- or 16-bit integer to 16 or 32 bits, for a target that keeps
/// every narrow integer zero-extended in a 32-bit location (wasm): each use reads its operand. So does a
/// truncation of such a location to 8 or 16 bits whose operand fits (`fits_low`), or that only select
/// sides read where the condition bounds the operand (`bounded_side`).
pub(package) const FOLD_FREE_ZEXT: u64 = 68719476736;
/// `FOLD_VSAD`: an unsigned absolute difference of byte vectors (`vop` `SIMD_ABS_DIFF`) that one widening
/// sum into 8-byte lanes (`O_VSUMW`) alone reads folds into it: the sum takes the two vectors (x86-64
/// `psadbw`).
pub(package) const FOLD_VSAD: u64 = 34359738368;
/// `FOLD_LANE_PAIR`: lanes 0 and 1 of one float vector of two lanes (8 or 16 bytes), each read with one use,
/// that a scalar `fadd` adds, fold into it: the sum adds the vector's lanes pairwise (arm64 `faddp`).
pub(package) const FOLD_LANE_PAIR: u64 = 137438953472;
/// `Live::carry`: per instruction, its part of a `FOLD_ADC` sum: none, the `addo` or `subo` whose carry the
/// flags keep, a folded sum or extension, the sum with the carry.
pub(package) const CARRY_NONE: u8 = 0;
pub(package) const CARRY_LO: u8 = 1;
pub(package) const CARRY_PART: u8 = 2;
pub(package) const CARRY_ADC: u8 = 3;
// `lane_mask` follows this many `and`, `or` and `xor` operations.
pub(package) const MASK_DEPTH: u32 = 8;
// `Live::ldop_user` looks this many instructions past a load for its use.
const LDOP_REACH: u32 = 16;
// The terminator of block `k` of `b`.
const fn term_of(b: &Body, k: u32) Inst {
    let bk = b.blocks[k as usize];
    return b.insts[(bk.start + bk.len - 1) as usize];
}

/// `cs_kind`: a `select`'s side as the other side plus 1, negated, inverted; none of these.
pub(package) const CS_NONE: u8 = 0;
pub(package) const CS_INC: u8 = 1;
pub(package) const CS_NEG: u8 = 2;
pub(package) const CS_NOT: u8 = 3;
// A chain of conditional comparisons (`FOLD_CCMP`) holds at most this many comparisons.
const CCMP_MAX: u8 = 3;
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
    pub(package) npred: Vector<u32>, // per block, its predecessor count (an edge each from a block the entry reaches)
    pub(package) inner: Vector<u32>, // per block, the header of its innermost loop, NONE outside loops
    pub(package) lend: Vector<u32>, // per loop header, the layout position of the loop's last block
    pub(package) parent: Vector<u32>, // per loop header, the header of the loop around it, NONE
    pub(package) rare: Vector<bool>, // per block, whether the entry reaches it only through a block marked rare
    /// Per block (empty: none), whether the layout puts it after every other block, in layout order: a
    /// generator's rare blocks that alone set its frame up, after the code that has none.
    pub(package) after: Vector<bool>,
    pub(package) def_blk: Vector<u32>, // per value, its block
    // Per block, its predecessors that the entry reaches: `preds[pat[k]..pat[k + 1]]` (`loops`).
    pub(package) pat: Vector<u32>,
    pub(package) preds: Vector<u32>,
    // Per instruction of a laid-out block, its uses as `uses_at` gives them: `uv[ua[i]..ua[i] + un[i]]`
    // (`ranges`; `uses_of`).
    ua: Vector<u32>,
    un: Vector<u32>,
    uv: Vector<Value>,
    pub(package) next: Vector<u32>, // per value, its next use's layout ordinal, NONE after the last use
    use_next: Vector<u32>, // per folded operand, the next use of that value
    pub(package) end: Vector<u32>, // per value, the last layout position it is live in
    pub(package) uses: Vector<u32>, // per value, its use count, one more when a loop keeps it past its last use
    pub(package) last: Vector<u32>, // per value, the highest instruction index that uses it (0: none)
    wpos: Vector<u32>, // per block parameter, the last layout position of a block whose edge writes it, NONE: none
    wn: Vector<u32>, // per block parameter, how many edges write it
    pub(package) flag_of: Map<u32, u32>, // an instruction with a used flag -> the flag's value index
    pub(package) home: Vector<u8>, // per value, its HOME_* (`plan`)
    pub(package) split: bool, // permit a register prefix followed by a stack home
    pub(package) cut: Vector<u32>, // per value, the first layout block outside its register prefix, NONE otherwise
    pub(package) splits: Vector<u64>, // cut << 32 | value, in cut order
    /// Per value, the loop header parameter whose register a parameter of a block after the loop takes
    /// (`exit_partner`), else NONE (`plan`).
    pub(package) share: Vector<u32>,
    shared_by: Vector<u32>, // per loop header parameter, the one parameter that shares its register (`share`)
    /// The edges whose moves the generator places in a stub past the last block (`late_edges`): source
    /// block << 32 | edge.
    pub(package) late: Vector<u64>,
    /// The largest access a scaled index addresses (the target's, 0: none); per instruction, whether the
    /// load or store takes its address `ptradd`'s operands (`fold`), and whether the `ptradd` emits nothing
    /// for that (`pfold`; `uses_at`).
    pub(package) fold_max: u32,
    pub(package) fold: Vector<bool>,
    pub(package) pfold: Vector<bool>,
    pub(package) carry: Vector<u8>, // per instruction, its CARRY_* part of a `FOLD_ADC` sum
    /// Per instruction, the comparisons of the `and` or `or` of flags it is when `FOLD_CCMP` folds them into
    /// conditional comparisons (`folds`), else 0.
    pub(package) conj: Vector<u8>,
    /// Stores whose value a call takes in place of memory (the generator's, before `run`): per
    /// instruction, a relayed store's call, else NONE (empty: none); `relayed`, call << 32 | store for each
    /// store whose value the call reads. A relayed store reads nothing; its call reads those values
    /// (`uses_at`).
    pub(package) relay: Vector<u32>,
    pub(package) relayed: Vector<u64>,
    /// The instructions that fold into their uses (`FOLD_*`, the target's): each use computes the folded
    /// instruction from its operands, which live to it (`uses_at`), and the instruction emits nothing
    /// (`pfold`).
    pub(package) fold_ops: u64,
    /// Whether the calling convention has the caller extend 8- and 16-bit arguments to 32 bits by their
    /// signedness (Apple arm64), so their registers' low 32 bits are their values extended.
    pub(package) ext_args: bool,
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
    stepped: Vector<u64>, // `plan`: header parameter << 32 | the step that shares its register (`step_partner`)
    pub(package) rpo: Vector<u32>, // per block, its reverse postorder number (NONE: unreachable)
    succ: Vector<u32>,
    stack: Vector<u32>,
    work: Vector<u32>,
    breaks: Vector<u32>, // `plan`: per layout position `q`, the blocks at 1 to `q` that do not keep the register state (`continues`)
    /// Per instruction of the body, its use count: operands, call and vector arguments, edge arguments (`folds`).
    pub(package) count: Vector<u32>,
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
            wpos: Vector::<u32>::new(),
            wn: Vector::<u32>::new(),
            flag_of: Map::<u32, u32>::new(),
            home: Vector::<u8>::new(),
            split: false,
            cut: Vector::<u32>::new(),
            splits: Vector::<u64>::new(),
            share: Vector::<u32>::new(),
            shared_by: Vector::<u32>::new(),
            late: Vector::<u64>::new(),
            fold_max: 0,
            fold: Vector::<bool>::new(),
            pfold: Vector::<bool>::new(),
            carry: Vector::<u8>::new(),
            conj: Vector::<u8>::new(),
            relay: Vector::<u32>::new(),
            relayed: Vector::<u64>::new(),
            fold_ops: 0,
            ext_args: false,
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
            stepped: Vector::<u64>::new(),
            rpo: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            stack: Vector::<u32>::new(),
            work: Vector::<u32>::new(),
            breaks: Vector::<u32>::new(),
            count: Vector::<u32>::new(),
            keys: Vector::<u64>::new(),
            rd: Vector::<Value>::new(),
            ua: Vector::<u32>::new(),
            pat: Vector::<u32>::new(),
            preds: Vector::<u32>::new(),
            un: Vector::<u32>::new(),
            uv: Vector::<Value>::new(),
            next: Vector::<u32>::new(),
            use_next: Vector::<u32>::new(),
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

    /// Whether the block at layout position `q` of `b` keeps the register state: its only predecessor is
    /// the block before it in the layout.
    pub(package) const fn continues(self: &Self, b: &Body, q: u32) bool {
        if q == 0 {
            return true;
        }
        let k = self.order[q as usize];
        if self.npred[k as usize] != 1 {
            return false;
        }
        let pb = b.blocks[self.order[q as usize - 1] as usize];
        let t = b.insts[(pb.start + pb.len - 1) as usize];
        let ne: u32 = if t.op == O_JMP {
            1
        } else if t.op == O_BR {
            2
        } else if t.op == O_SWITCH {
            t.aux as u32 + 1
        } else {
            0
        };
        for e in 0..ne {
            if b.edge_target(edge_of(b, t, e)) == k {
                return true;
            }
        }
        return false;
    }

    /// Value index `x`'s uses less the edges that write it (a block parameter's).
    pub(package) const fn reads(self: &Self, x: u32) u32 {
        return self.uses[x as usize] - self.wn[x as usize];
    }

    /// Analyze `b`.
    pub(package) fn run(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.npred, nb, 0);
        fill(&mut self.rpo, nb, NONE);
        fill(&mut self.inner, nb, NONE);
        fill(&mut self.parent, nb, NONE);
        self.reverse_postorder(b);
        for k in 0..nb {
            if self.rpo[k] == NONE {
                continue;
            }
            let t = b.insts[(b.blocks[k].start + b.blocks[k].len - 1) as usize];
            b.succ_edges(t, &mut self.succ);
            for e in 0..self.succ.len() {
                self.npred[b.edge_target(self.succ[e]) as usize] += 1;
            }
        }
        self.rare_blocks(b);
        self.loops(b);
        self.folds(b);
        self.relayout(b);
    }

    /// The layout of `b` and the live ranges again, for another `after`: the rest of `run`'s analysis stands.
    pub(package) fn relayout(self: &mut Self, b: &Body) {
        let nb = b.blocks.len();
        fill(&mut self.lend, nb, 0);
        fill(&mut self.pos, nb, NONE);
        self.layout(b);
        self.late_edges(b);
        self.ranges(b);
    }

    // The edges whose moves wait in a stub past the last block, which then jumps to the target (`late`):
    // each passes only integer and float constants, from a warm block laid out before a loop to a warm block
    // laid out after it that an edge from a block laid out between them, with no loop after that block,
    // reaches too (its parameters take their homes there). The target's parameters then start their ranges
    // after the loop (`plan`) in place of holding registers across it.
    fn late_edges(self: &mut Self, b: &Body) {
        self.late.truncate(0);
        let np = self.order.len();
        // Per layout position, the least last position of a loop whose header is there or later.
        let mut close = Vector::<u32>::with_capacity(np + 1);
        fill(&mut close, np + 1, NONE);
        for q0 in 0..np {
            let q = np - 1 - q0;
            let h = self.order[q];
            close[q] = close[q + 1];
            if self.inner[h as usize] == h {
                close[q] = close[q].min(self.lend[h as usize]);
            }
        }
        for q in 0..np {
            let p = self.order[q];
            if self.rare[p as usize] || close[q + 1] == NONE {
                continue;
            }
            let t = term_of(b, p);
            let ne: u32 = if t.op == O_JMP {
                1
            } else if t.op == O_BR {
                2
            } else {
                0
            };
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                let j = b.edge_target(ed);
                let pj = self.pos[j as usize];
                if b.edge_nargs(ed) == 0 || pj == NONE || pj <= q as u32 || self.rare[j as usize] || close[q + 1] >= pj || ne == 2 && b.edge_target(
                    edge_of(b, t, 1 - e),
                ) == j {
                    continue;
                }
                let mut ok = true;
                for a in 0..b.edge_nargs(ed) {
                    let v = b.edge_arg(ed, a);
                    ok = ok && (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_ICONST || b.insts[v as usize].op == O_FCONST);
                }
                let mut other = false;
                for x in self.pat[j as usize]..self.pat[j as usize + 1] {
                    let pq = self.pos[self.preds[x as usize] as usize];
                    other = other || pq != NONE && pq > q as u32 && pq < pj && close[pq as usize + 1] >= pj;
                }
                if ok && other {
                    self.late.push(p as u64 << 32 | ed as u64);
                }
            }
        }
    }

    /// The target of block `k`'s late edge (`late`), NONE when it has none.
    pub(package) fn late_target(self: &Self, b: &Body, k: u32) u32 {
        for q in 0..self.late.len() {
            if (self.late[q] >> 32) as u32 == k {
                return b.edge_target(self.late[q] as u32);
            }
        }
        return NONE;
    }

    /// The index in `late` of edge `e` of block `k`'s terminator (blocks may share an edge's record), NONE
    /// when it is not late.
    pub(package) fn late_index(self: &Self, k: u32, e: u32) u32 {
        let key = k as u64 << 32 | e as u64;
        for q in 0..self.late.len() {
            if self.late[q] == key {
                return q as u32;
            }
        }
        return NONE;
    }

    // `fold`: a load or store of no offset whose address is a `ptradd` with an index, no offset, a scale
    // of 1 or the access's size (up to `fold_max`) and this one use, takes the `ptradd`'s operands as its
    // address (`ldr x0, [x1, x2, lsl #3]`, `mov (%rax,%rcx,8), %rdx`): they live to the access.
    //
    // The other instructions fold as `fold_ops` lets them (`FOLD_*`).
    // Whether index `v` of `b` is the 64-bit extension `FOLD_XIDX` folds into its one access.
    fn ext_index(self: &Self, b: &Body, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let t = b.insts[v as usize];
        if t.op != O_ZEXT && t.op != O_SEXT || t.ty != T_I64 {
            return false;
        }
        let ft = b.type_of(t.a);
        if ft == T_I32 {
            return true;
        }
        // An unsigned entry parameter of 8 or 16 bits the caller zero-extended.
        if !self.ext_args || t.op != O_ZEXT || ft != T_I8 && ft != T_I16 || (t.a & VPARAM) == 0 {
            return false;
        }
        let k = (t.a & ~VPARAM) as usize;
        let np = b.pool[b.sig as usize] as usize;
        return k < np && b.blocks[0].param_start == 0 && (b.pool[b.sig as usize + 3 + k] & (SIG_SEXT | AGG)) == 0;
    }

    // `FOLD_SHAMT`: a 32- or 64-bit shift's count that an `and` with the width's mask (`& 31`, `& 63`) makes,
    // read only there, folds into the shift, which takes the count modulo the width.
    fn shift_counts(self: &mut Self, b: &Body) {
        if (self.fold_ops & FOLD_SHAMT) == 0 {
            return;
        }
        for i in 0..b.insts.len() {
            let t = b.insts[i];
            let bits = type_bits(t.ty, 8);
            if t.op < O_SHL || t.op > O_ASHR || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] {
                continue;
            }
            let m = t.b;
            if (m & (VPARAM | VFLAG)) != 0 || m == VNONE || b.insts[m as usize].op != O_AND || self.count[m as usize] != 1 || self.pfold[m as usize] {
                continue;
            }
            let k = int_const(b, b.insts[m as usize].b);
            if k != u64::MAX && (k & (bits - 1) as u64) == (bits - 1) as u64 {
                self.pfold[m as usize] = true;
            }
        }
    }

    fn folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        self.fold.truncate(0);
        self.fold.resize_default(ni);
        self.pfold.truncate(0);
        self.pfold.resize_default(ni);
        fill(&mut self.conj, ni, 0);
        fill(&mut self.carry, ni, CARRY_NONE);
        if self.fold_max == 0 && self.fold_ops == 0 {
            return;
        }
        // The use count of each instruction, and its uses as a condition.
        fill(&mut self.count, ni, 0);
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            each_use(b, t, &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == 0 {
                    self.count[v as usize] += 1;
                }
            }
            if (t.op == O_SELECT || t.op == O_BR) && (t.a & (VPARAM | VFLAG)) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            let fc = (self.fold_ops & FOLD_FCMP) != 0 && t.op == O_FCMP && !is_vec(b.type_of(t.a)) && t.aux != C_ONE && t.aux != C_UEQ;
            self.pfold[i] = (self.fold_ops & FOLD_CMP) != 0 && (t.op == O_ICMP && b.type_of(t.a) != T_I128 || fc) && self.count[i] != 0 && self.cnd[i] == self.count[i];
        }
        // An `and`'s uses as an equality with 0.
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            if t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (t.a & (VPARAM | VFLAG)) == 0 && (b.insts[t.a as usize].op == O_AND || b.insts[t.a as usize].op == O_VOP) && int_const(
                b,
                t.b,
            ) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            if (self.fold_ops & FOLD_VMLA) != 0 && (t.op == O_ADD || t.op == O_SUB) && is_vec(t.ty) {
                let mut p = self.vmla_mul(b, t);
                if p == VNONE && t.op == O_ADD {
                    p = self.vsra_shift(b, t);
                }
                if p != VNONE {
                    self.pfold[p as usize] = true;
                }
            }
            if (self.fold_ops & FOLD_LANE) != 0 && t.op == O_SPLAT && is_inst(t.a) && b.insts[t.a as usize].op == O_VEXTRACT && self.count[t.a as usize] == 1 {
                let vt = b.type_of(b.insts[t.a as usize].a);
                let eb = type_bytes(lane_type(vt), 8);
                if (type_bytes(t.ty, 8) == 8 || type_bytes(t.ty, 8) == 16) && (type_bytes(vt, 8) == 8 || type_bytes(
                    vt,
                    8,
                ) == 16) && (eb == 4 || eb == 8) {
                    self.pfold[t.a as usize] = true;
                }
            }
            if (self.fold_ops & FOLD_LANE_MUL) != 0 && t.op == O_FMUL && is_vec(t.ty) && (type_bytes(t.ty, 8) == 8 || type_bytes(
                t.ty,
                8,
            ) == 16) && is_inst(t.b) && b.insts[t.b as usize].op == O_SPLAT && self.count[t.b as usize] == 1 && is_inst(
                b.insts[t.b as usize].a,
            ) && self.pfold[b.insts[t.b as usize].a as usize] {
                self.pfold[t.b as usize] = true;
            }
            if (self.fold_ops & FOLD_LANE_PAIR) != 0 && lane_pair(b, t) && self.count[t.a as usize] == 1 && self.count[t.b as usize] == 1 {
                self.pfold[t.a as usize] = true;
                self.pfold[t.b as usize] = true;
            }
            if (self.fold_ops & FOLD_VSAD) != 0 && t.op == O_VSUMW {
                let p = self.vsad_diff(b, t);
                if p != VNONE {
                    self.pfold[p as usize] = true;
                }
            }
            if (self.fold_ops & FOLD_VWADD) != 0 && t.op == O_ADD && is_vec(t.ty) {
                let p = self.vwadd_ext(b, t);
                if p != VNONE {
                    self.pfold[p as usize] = true;
                    self.pfold[b.insts[p as usize].a as usize] = true;
                }
            }
            if !is_int(t.ty) || t.ty == T_I128 {
                continue;
            }
            let bits = type_bits(t.ty, 8);
            if t.op == O_VOP && self.count[i] != 0 && self.cnd[i] == self.count[i] && self.any_fold(b, t) {
                self.pfold[i] = true;
            }
            if t.op == O_AND && (self.fold_ops & FOLD_TST) != 0 && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                // A narrow type's register may hold any bits above it: only a mask within the type tests.
                let m = int_const(b, t.b);
                self.pfold[i] = bits >= 32 || m != u64::MAX && m >> bits as u64 == 0;
            }
            let p = if t.op == O_SUB || t.op == O_ADD && int_const(b, t.a) == u64::MAX && int_const(b, t.b) == u64::MAX {
                t.b
            } else {
                VNONE
            };
            if (self.fold_ops & FOLD_MADD) != 0 && p != VNONE && (p & (VPARAM | VFLAG)) == 0 && b.insts[p as usize].op == O_MUL && self.count[p as usize] == 1 && int_const(
                b,
                t.a,
            ) == u64::MAX {
                self.pfold[p as usize] = true;
            } else if (self.fold_ops & FOLD_MADD) != 0 && p != VNONE && t.op == O_ADD && is_inst(t.a) && b.insts[t.a as usize].op == O_MUL && self.count[t.a as usize] == 1 {
                // The product as the first addend.
                self.pfold[t.a as usize] = true;
            }
            if (self.fold_ops & FOLD_ROT) != 0 && (bits >= 32 || (self.fold_ops & FOLD_ROT_NARROW) != 0) {
                let rot = rotate_of(b, i as u32);
                let amt = rot.amt;
                if rot.x != VNONE && self.count[t.a as usize] == 1 && self.count[t.b as usize] == 1 {
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
                            t.a
                        } else {
                            t.b
                        };
                        let s = b.insts[sh as usize].b;
                        let ext = amount_of(b, s) != s;
                        if ext && self.count[s as usize] == 1 {
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
                            amount_of(b, b.insts[t.b as usize].b)
                        } else {
                            sa
                        };
                        for _ in 0..2 {
                            if !open || !is_inst(v) || self.count[v as usize] != 1 {
                                break;
                            }
                            let o = b.insts[v as usize].op;
                            if o != O_AND && o != O_SUB && o != O_NEG {
                                break;
                            }
                            self.pfold[v as usize] = true;
                            v = if o == O_SUB {
                                b.insts[v as usize].b
                            } else {
                                b.insts[v as usize].a
                            };
                        }
                        if v == amt {
                            inside += 1;
                        }
                        // The amount's extension, which the other amount's folded chain may read too: folded
                        // when the shift and that chain are its only users.
                        if own != amt && !self.pfold[own as usize] && self.count[own as usize] == 1 + (v == own) as u32 {
                            self.pfold[own as usize] = true;
                            inside += 1;
                        }
                        if is_inst(amt) && b.insts[amt as usize].op == O_AND && int_const(b, b.insts[amt as usize].b) == bits as u64 - 1 && self.count[amt as usize] == inside {
                            self.pfold[amt as usize] = true;
                        }
                    }
                    continue;
                }
            }
            if (self.fold_ops & FOLD_LEA) != 0 && (t.op == O_ADD || t.op == O_SUB || is_sum_or(b, t)) {
                // The shift an index takes, then the inner sum whose operands the address takes.
                let nq: u32 = if t.op != O_SUB {
                    2
                } else {
                    0
                };
                for q in 0..nq {
                    let v = if q == 0 {
                        t.b
                    } else {
                        t.a
                    };
                    if lea_shift(b, v) == 0 || self.pfold[v as usize] || self.count[v as usize] != 1 {
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
                        t.a
                    } else {
                        t.b
                    };
                    if q == 1 && t.op == O_SUB || !is_inst(v) || self.pfold[v as usize] || self.count[v as usize] != 1 || b.insts[v as usize].op != O_ADD || b.insts[v as usize].ty != t.ty {
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
                    int_const(b, s.b)
                } else {
                    u64::MAX
                };
                // A mask of the low `w` bits under a shift by `k`, both within the width.
                if self.count[t.a as usize] == 1 && m != u64::MAX && m != 0 && (m & m + 1) == 0 && k < bits as u64 {
                    let w = (m + 1).trailing_zeros() as u64;
                    self.pfold[t.a as usize] = self.pfold[t.a as usize] || k + w <= bits as u64;
                }
            }
        }
        if (self.fold_ops & FOLD_FREE_ZEXT) != 0 {
            // A truncation's uses as a select's side its condition bounds (`bounded_side`).
            fill(&mut self.cnd, ni, 0);
            for i in 0..ni {
                let t = b.insts[i];
                if t.op == O_SELECT && !is_vec(t.ty) {
                    if bounded_side(b, t.a, t.b, true) {
                        self.cnd[t.b as usize] += 1;
                    }
                    if bounded_side(b, t.a, t.c, false) {
                        self.cnd[t.c as usize] += 1;
                    }
                }
            }
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_ZEXT && t.op != O_TRUNC {
                    continue;
                }
                let ft = b.type_of(t.a);
                if t.op == O_ZEXT && (t.ty == T_I16 || t.ty == T_I32) && (ft == T_I8 || ft == T_I16) && ft != t.ty {
                    self.pfold[i] = true;
                }
                if t.op == O_TRUNC && (t.ty == T_I8 || t.ty == T_I16) && (ft == T_I16 || ft == T_I32) && ft != t.ty {
                    self.pfold[i] = self.count[i] != 0 && (self.cnd[i] == self.count[i] || fits_low(
                        b,
                        t.a,
                        type_mask(t.ty),
                        FITS_DEPTH,
                    ));
                }
            }
        }
        if self.fold_max == 0 {
            self.shift_counts(b);
            return;
        }
        for i in 0..ni {
            let t = b.insts[i];
            if t.op != O_LOAD && t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || t.c != 0 || (t.a & (VPARAM | VFLAG)) != 0 {
                continue;
            }
            let p = b.insts[t.a as usize];
            let ty = if t.op == O_LOAD {
                t.ty
            } else {
                b.type_of(t.b)
            };
            let n = type_bytes(ty, 8); // the targets that fold have 8-byte pointers
            let sc = scale_of(p);
            // A vector of 8 or 16 bytes lives in a register; another is memory.
            let reg = !is_vec(ty) && ty != T_I128 || n == 8 || n == 16;
            self.fold[i] = p.op == O_PTRADD && p.b != VNONE && p.c == 0 && self.count[t.a as usize] == 1 && reg && (sc == 1 || sc == n && n <= self.fold_max);
            if self.fold[i] {
                self.pfold[t.a as usize] = true;
                if (self.fold_ops & FOLD_XIDX) != 0 && self.ext_index(b, p.b) {
                    self.pfold[p.b as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_XADDR) != 0 {
            self.fold_addrs(b);
        }
        // `FOLD_BLEN`: a count of leading zeros of 32 or 64 bits that only `width - clz` reads, the bit
        // length, or `clz ^ (width - 1)`, the top bit's index, folds into it.
        if (self.fold_ops & FOLD_BLEN) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                let w = type_bits(t.ty, 8) as u64;
                let sub = t.op == O_SUB;
                let c = if sub {
                    t.b
                } else {
                    t.a
                };
                if !sub && t.op != O_XOR || !is_int(t.ty) || w != 32 && w != 64 || (c & (VPARAM | VFLAG)) != 0 || c == VNONE {
                    continue;
                }
                let ci = b.insts[c as usize];
                let k = int_const(
                    b,
                    if sub {
                        t.a
                    } else {
                        t.b
                    },
                );
                if ci.op == O_CLZ && ci.ty == t.ty && self.count[c as usize] == 1 && !self.pfold[c as usize] && k == if sub {
                    w
                } else {
                    w - 1
                } {
                    self.pfold[c as usize] = true;
                }
            }
        }
        self.shift_counts(b);
        if (self.fold_ops & FOLD_SHOP) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
                if !ops || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] || int_const(b, t.a) != u64::MAX || int_const(
                    b,
                    t.b,
                ) != u64::MAX {
                    continue;
                }
                // The other operand in a register: not one another fold computes in this instruction.
                let s = if self.shop_ok(b, t.b, bits) && !(is_inst(t.a) && self.pfold[t.a as usize]) {
                    t.b
                } else if t.op != O_SUB && self.shop_ok(b, t.a, bits) && !(is_inst(t.b) && self.pfold[t.b as usize]) {
                    t.a
                } else {
                    VNONE
                };
                if s != VNONE {
                    self.pfold[s as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_MULL) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_MUL || t.ty != T_I64 || self.pfold[i] || mull_ext(b, t) == 0 {
                    continue;
                }
                let k = is_const_val(b, t.b);
                if self.count[t.a as usize] == 1 && (k || self.count[t.b as usize] == 1) && !self.pfold[t.a as usize] && !self.pfold[t.b as usize] {
                    self.pfold[t.a as usize] = true;
                    self.pfold[t.b as usize] = !k;
                }
            }
        }
        if (self.fold_ops & FOLD_CSEL) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_SELECT || !is_int(t.ty) || t.ty == T_I128 || is_vec(t.ty) {
                    continue;
                }
                // A side the other plus 1, negated or inverted, or such a value of anything when the other is 0
                // (the zero register).
                let zb = is_const_val(b, t.b) && const_val(b, t.b) == 0;
                let zc = is_const_val(b, t.c) && const_val(b, t.c) == 0;
                if is_inst(t.b) && self.count[t.b as usize] == 1 && !self.pfold[t.b as usize] && (cs_kind(b, t.b, t.c) != CS_NONE || zc && cs_base(
                    b,
                    t.b,
                ).0 != CS_NONE) {
                    self.pfold[t.b as usize] = true;
                } else if is_inst(t.c) && self.count[t.c as usize] == 1 && !self.pfold[t.c as usize] && (cs_kind(
                    b,
                    t.c,
                    t.b,
                ) != CS_NONE || zb && cs_base(b, t.c).0 != CS_NONE) {
                    self.pfold[t.c as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_BRCONJ) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_BR || !is_inst(t.a) {
                    continue;
                }
                let c = b.insts[t.a as usize];
                if (c.op == O_AND || c.op == O_OR) && c.ty == T_I8 && self.count[t.a as usize] == 1 && !self.pfold[t.a as usize] && c.a != c.b && self.cmp_leaf(
                    b,
                    c.a,
                ) && self.cmp_leaf(b, c.b) {
                    self.pfold[t.a as usize] = true;
                    self.pfold[c.a as usize] = true;
                    self.pfold[c.b as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_CCMP) != 0 {
            self.conj_folds(b);
        }
        // `FOLD_FSEL`: a comparison of scalar floats but `one` and `ueq` (no SSE comparison gives their mask)
        // whose every use is the condition of a select of floats of its type folds into the selects.
        if (self.fold_ops & FOLD_FSEL) != 0 {
            fill(&mut self.cnd, ni, 0);
            for i in 0..ni {
                let t = b.insts[i];
                if t.op == O_SELECT && (t.ty == T_F32 || t.ty == T_F64) && is_inst(t.a) && b.insts[t.a as usize].op == O_FCMP && b.type_of(
                    b.insts[t.a as usize].a,
                ) == t.ty {
                    self.cnd[t.a as usize] += 1;
                }
            }
            for i in 0..ni {
                let t = b.insts[i];
                if t.op == O_FCMP && !is_vec(b.type_of(t.a)) && t.aux != C_ONE && t.aux != C_UEQ && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                    self.pfold[i] = true;
                }
            }
        }
        // `FOLD_NOT`: an inversion (`not`, or `xor` with all ones) whose one use is an `and`, `or` or `xor` of
        // at most 64 bits, whose other operand and the inverted value fold nothing, folds into it (arm64
        // `bic`, `orn`, `eon`: `not_side`).
        if (self.fold_ops & FOLD_NOT) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_AND && t.op != O_OR && t.op != O_XOR || !is_int(t.ty) || t.ty == T_I128 || self.pfold[i] {
                    continue;
                }
                for side in 0..2 {
                    let (s, o) = if side == 0 {
                        (t.b, t.a)
                    } else {
                        (t.a, t.b)
                    };
                    let x = inversion(b, s);
                    if x != VNONE && self.count[s as usize] == 1 && !self.pfold[s as usize] && !(is_inst(o) && self.pfold[o as usize]) && !(is_inst(
                        x,
                    ) && self.pfold[x as usize]) {
                        self.pfold[s as usize] = true;
                        break;
                    }
                }
            }
        }
        // `FOLD_TRUNC`: a narrow truncation of a value that folds nothing, read by comparisons alone.
        if (self.fold_ops & FOLD_TRUNC) != 0 {
            fill(&mut self.cnd, ni, 0);
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_ICMP {
                    continue;
                }
                for s in [t.a, t.b] {
                    if is_inst(s) && b.insts[s as usize].op == O_TRUNC {
                        self.cnd[s as usize] += 1;
                    }
                }
            }
            for i in 0..ni {
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                if t.op == O_TRUNC && (bits == 8 || bits == 16) && (t.a & VFLAG) == 0 && is_int(b.type_of(t.a)) && b.type_of(
                    t.a,
                ) != T_I128 && self.count[i] != 0 && self.cnd[i] == self.count[i] && !self.pfold[i] && !(is_inst(t.a) && self.pfold[t.a as usize]) {
                    self.pfold[i] = true;
                }
            }
        }
        // `FOLD_XBFX`: a left shift by a constant whose one use is a right shift of 32 or 64 bits by at least
        // as much folds into it: a field extracted, sign- or zero-extended (arm64 `sbfx`, `ubfx`).
        if (self.fold_ops & FOLD_XBFX) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                let bits = type_bits(t.ty, 8);
                if t.op != O_LSHR && t.op != O_ASHR || !is_int(t.ty) || bits != 32 && bits != 64 || self.pfold[i] || !is_inst(
                    t.a,
                ) {
                    continue;
                }
                let s = b.insts[t.a as usize];
                let k = int_const(b, t.b);
                let l = if s.op == O_SHL {
                    int_const(b, s.b)
                } else {
                    u64::MAX
                };
                if l != u64::MAX && k != u64::MAX && l <= k && k < bits as u64 && self.count[t.a as usize] == 1 && !self.pfold[t.a as usize] && !(is_inst(
                    s.a,
                ) && self.pfold[s.a as usize]) {
                    self.pfold[t.a as usize] = true;
                }
            }
        }
        // `FOLD_BFI`: an insertion of a field (`bfi_of`) whose three inner instructions each have this one use
        // folds them (arm64 `bfi`); the shift may be a shifted operand already (`FOLD_SHOP`).
        if (self.fold_ops & FOLD_BFI) != 0 {
            for i in 0..ni {
                let f = bfi_of(b, b.insts[i]);
                if f.x == VNONE || self.pfold[i] {
                    continue;
                }
                let (ka, kb) = (f.keep, f.field);
                let kc = b.insts[kb as usize].a;
                let tr = f.trunc == VNONE || self.count[f.trunc as usize] == 1 && !self.pfold[f.trunc as usize];
                if tr && self.count[ka as usize] == 1 && self.count[kb as usize] == 1 && self.count[kc as usize] == 1 && !self.pfold[ka as usize] && !self.pfold[kc as usize] && !(is_inst(
                    f.x,
                ) && self.pfold[f.x as usize]) && !(is_inst(f.v) && self.pfold[f.v as usize]) {
                    self.pfold[ka as usize] = true;
                    self.pfold[kb as usize] = true;
                    self.pfold[kc as usize] = true;
                    if f.trunc != VNONE {
                        self.pfold[f.trunc as usize] = true;
                    }
                }
            }
        }
        // `FOLD_CARRY`: a select of 32 or 64 bits between a value and that value plus 1 (`CS_INC`, its one
        // use) on a folded integer comparison: the side folds into the select, an add of the condition
        // (`carry_inc`).
        if (self.fold_ops & FOLD_CARRY) != 0 {
            for i in 0..ni {
                let s = carry_inc(b, &self.pfold, i as u32);
                if s != VNONE && self.count[s as usize] == 1 {
                    self.pfold[s as usize] = true;
                }
            }
        }
        if (self.fold_ops & FOLD_LDOP) != 0 {
            for k in 0..b.blocks.len() {
                let bk = b.blocks[k];
                for i in bk.start..bk.start + bk.len {
                    if self.ldop_user(b, i, bk.start + bk.len) {
                        self.pfold[i as usize] = true;
                    }
                }
            }
        }
        if (self.fold_ops & (FOLD_VSHIMM | FOLD_VSHIMM_ALL)) != 0 {
            fill(&mut self.cnd, ni, 0);
            for i in 0..ni {
                let t = b.insts[i];
                if self.vshimm(b, t) != NONE && t.a != t.b {
                    self.cnd[t.b as usize] += 1;
                }
            }
            for i in 0..ni {
                let op = b.insts[i].op;
                if (op == O_SPLAT || op == O_WCONST) && self.count[i] != 0 && self.cnd[i] == self.count[i] {
                    self.pfold[i] = true;
                }
            }
        }
        // Last: its parts fold no other operand.
        if (self.fold_ops & FOLD_ADC) != 0 {
            self.carries(b);
        }
        if (self.fold_ops & FOLD_ZSHL) != 0 {
            for i in 0..ni {
                let t = b.insts[i];
                if t.op != O_SHL || !is_int(t.ty) || t.ty == T_I128 || self.pfold[i] || !is_inst(t.a) {
                    continue;
                }
                let s = int_const(b, t.b);
                let z = b.insts[t.a as usize];
                if z.op != O_ZEXT || self.count[t.a as usize] != 1 || self.pfold[t.a as usize] || is_inst(z.a) && self.pfold[z.a as usize] {
                    continue;
                }
                if s != u64::MAX && type_bits(b.type_of(z.a), 8) as u64 + s >= type_bits(t.ty, 8) as u64 && s < type_bits(
                    t.ty,
                    8,
                ) as u64 {
                    self.pfold[t.a as usize] = true;
                }
            }
        }
    }

    /// The immediate amount vector shift `t` of `b` takes (`FOLD_VSHIMM`), else NONE.
    pub(package) fn vshimm(self: &Self, b: &Body, t: Inst) u32 {
        if t.op != O_SHL && t.op != O_LSHR && t.op != O_ASHR || !is_vec(t.ty) {
            return NONE;
        }
        let eb = type_bytes(lane_type(t.ty), 8);
        let nb = type_bytes(t.ty, 8);
        let ok = if (self.fold_ops & FOLD_VSHIMM_ALL) != 0 {
            (nb == 8 || nb == 16) && !(nb == 8 && eb == 8)
        } else {
            (self.fold_ops & FOLD_VSHIMM) != 0 && eb >= 2 && !(t.op == O_ASHR && eb == 8) && (nb == 16 || nb == 32 && (self.fold_ops & FOLD_VSHIMM_WIDE) != 0)
        };
        return if ok {
            vec_shift_amount(b, t)
        } else {
            NONE
        };
    }

    /// `FOLD_LDOP`: whether load `i` of `b` (its block ending before `end`) folds into its one use, a
    /// comparison of its type or an `add`, `sub` (the load second), `and`, `or`, `xor` or `mul` (by no
    /// constant, which `imul`'s immediate form takes) of 32 or 64 bits that folds into nothing, within LDOP_REACH instructions, whose other operand is no folded
    /// instruction, with no write of memory up to where the use is computed (a folded comparison: its
    /// select's or branch's place; not a `FOLD_CARRY` select's unsigned order comparison of 32 or 64 bits,
    /// whose `adc` the generator computes from the operands' registers).
    /// Not a load of an entry parameter's aggregate (the generator takes its registers,
    /// `place::parts_taken`) or of the aggregate result (which registers may hold), nor one
    /// whose operation's result is stored back in place (the generator's read-modify-write).
    fn ldop_user(self: &Self, b: &Body, i: u32, end: u32) bool {
        let t = b.insts[i as usize];
        if t.op != O_LOAD || (t.aux & MEM_VOLATILE) != 0 || !(is_int(t.ty) || is_float(t.ty)) || t.ty == T_I128 || self.count[i as usize] != 1 || self.pfold[i as usize] || agg_param(
            b,
            t.a,
        ) {
            return false;
        }
        let mut u = i + 1;
        while u < end && u <= i + LDOP_REACH {
            let x = b.insts[u as usize];
            let alu = x.op == O_ADD || x.op == O_SUB || x.op == O_AND || x.op == O_OR || x.op == O_XOR || x.op == O_MUL;
            let fp = is_float(t.ty) && x.op >= O_FADD && x.op <= O_FDIV && x.b == i;
            if fp || !is_float(t.ty) && (x.op == O_ICMP || alu) && (x.a == i || x.b == i) {
                break;
            }
            if writes_mem(x) {
                return false;
            }
            u += 1;
        }
        if u == end || u > i + LDOP_REACH {
            return false;
        }
        let x = b.insts[u as usize];
        let o = if x.a == i {
            x.b
        } else {
            x.a
        };
        if is_inst(o) && self.pfold[o as usize] || x.op == O_MUL && (is_const_val(b, o) || o == i) {
            return false;
        }
        if is_float(t.ty) {
            return !self.pfold[u as usize];
        }
        if x.op != O_ICMP {
            let st = b.insts[u as usize + 1];
            let back = u == i + 1 && st.op == O_STORE && st.b == u && st.a == t.a && st.c == t.c;
            return !self.pfold[u as usize] && type_bits(t.ty, 8) >= 32 && (x.op != O_SUB || x.b == i) && !back;
        }
        if !self.pfold[u as usize] {
            return true;
        }
        // A folded comparison: its one select or branch, with no write of memory before.
        if self.count[u as usize] != 1 {
            return false;
        }
        for w in u + 1..end {
            let y = b.insts[w as usize];
            if y.op == O_SELECT && y.a == u {
                let side = is_inst(y.b) && self.pfold[y.b as usize] || is_inst(y.c) && self.pfold[y.c as usize];
                let order = x.aux == C_ULT || x.aux == C_UGT || x.aux == C_ULE || x.aux == C_UGE;
                let wide = type_bits(t.ty, 8) >= 32;
                return !(side && order && wide);
            }
            if y.op == O_BR && y.a == u {
                return true;
            }
            if writes_mem(y) {
                return false;
            }
        }
        return false;
    }

    /// The uses of instruction `i` of a laid-out block, as `uses_at` gives them (`ranges` found them).
    pub(package) fn uses_of(self: &Self, i: u32) Slice<Value> {
        let a = self.ua[i as usize] as usize;
        return self.uv[a..a + self.un[i as usize] as usize];
    }

    /// Advance the next-use cursors past instruction `i`, once in layout order.
    pub(package) fn advance(self: &mut Self, b: &Body, i: u32) {
        let a = self.ua[i as usize];
        for u in a..a + self.un[i as usize] {
            let x = self.vix(b, self.uv[u as usize]);
            self.next[x as usize] = self.use_next[u as usize];
        }
    }

    /// The value index of a parameter that a back edge of terminator `t` (of the block at layout position
    /// `pos`) passes value `v` to (an edge into a loop header not later in the layout); NONE for none. A
    /// branch's other edge must leave the loop, and no path from it reads the parameter but through the
    /// header, which defines it again (`reads_before`).
    pub(package) fn back_param(self: &Self, b: &Body, t: Inst, v: Value, pos: u32) u32 {
        let ne: u32 = if t.op == O_JMP {
            1
        } else if t.op == O_BR {
            2
        } else {
            0
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

    // `FOLD_XADDR` over `b`: each address `ptradd` that the loads and stores of its block alone read, as
    // their address, folds into them all.
    fn fold_addrs(self: &mut Self, b: &Body) {
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let p = b.insts[i as usize];
                if p.op != O_PTRADD || p.b == VNONE || p.c != 0 || scale_of(p) != 1 && scale_of(p) != 2 && scale_of(p) != 4 && scale_of(
                    p,
                ) != 8 || self.pfold[i as usize] || self.count[i as usize] == 0 {
                    continue;
                }
                let mut n: u32 = 0;
                for j in i + 1..bk.start + bk.len {
                    if self.addr_of(b, j) == i {
                        n += 1;
                    }
                }
                if n != self.count[i as usize] {
                    continue;
                }
                self.pfold[i as usize] = true;
                for j in i + 1..bk.start + bk.len {
                    if self.addr_of(b, j) == i {
                        self.fold[j as usize] = true;
                    }
                }
            }
        }
    }

    // The address instruction `j` of `b` accesses through when it is a load or store a folded address may
    // serve (`fold`'s rule: not volatile, a value a register holds, the stored value not the address);
    // NONE else.
    const fn addr_of(self: &Self, b: &Body, j: u32) u32 {
        let t = b.insts[j as usize];
        if t.op != O_LOAD && t.op != O_STORE || (t.aux & MEM_VOLATILE) != 0 || (t.a & (VPARAM | VFLAG)) != 0 || t.op == O_STORE && t.b == t.a {
            return NONE;
        }
        let ty = if t.op == O_LOAD {
            t.ty
        } else {
            b.type_of(t.b)
        };
        let n = type_bytes(ty, 8);
        if is_vec(ty) && n != 8 && n != 16 || ty == T_I128 {
            return NONE;
        }
        return t.a;
    }

    /// Whether `v` of `b` is a parameter of a block other than the entry that every edge into it passes a
    /// constant: verified LIR holds a narrow constant zero-extended (`verify::fits`), which the backends
    /// write as it is, by an edge's move or from a switch's table (a narrow load), so the parameter's
    /// register holds it so.
    pub(package) fn zero_param(self: &Self, b: &Body, v: Value) bool {
        if (v & VPARAM) == 0 {
            return false;
        }
        let k = self.def_blk[self.vix(b, v) as usize];
        if k == 0 {
            return false;
        }
        let q = (v & ~VPARAM) - b.blocks[k as usize].param_start;
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = b.blocks[self.preds[j as usize] as usize];
            let t = b.insts[(pb.start + pb.len - 1) as usize];
            let ne: u32 = if t.op == O_JMP {
                1
            } else if t.op == O_BR {
                2
            } else if t.op == O_SWITCH {
                t.aux as u32 + 1
            } else {
                0
            };
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                let mut c: u64 = 0;
                if b.edge_target(ed) == k && !const_of(b, b.edge_arg(ed, q), &mut c) {
                    return false;
                }
            }
        }
        return true;
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
    /// (`pfold`): a use of one is a use of its operands, and one uses none.
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
            if p.op == O_SPLAT && is_inst(p.a) && self.pfold[p.a as usize] {
                // A lane a product multiplies by (`FOLD_LANE_MUL`): its lane read.
                out.push(p.a);
            } else if p.op == O_SPLAT || p.op == O_WCONST {
                // An immediate shift amount (`FOLD_VSHIMM`): nothing.
            } else if p.op == O_VOP {
                // Its operands in the pool (`FOLD_ANY`'s one).
                for q in 0..p.b {
                    out.push(b.pool[(p.a + q) as usize]);
                }
            } else {
                out.push(p.a);
                // A load's `b` is its bound (`MEM_RANGE`), no operand.
                if p.b != VNONE && p.op != O_LOAD {
                    out.push(p.b);
                }
            }
        }
        for q in 0..self.relayed.len() {
            if (self.relayed[q] >> 32) as u32 == i {
                out.push(b.insts[(self.relayed[q] & 0xFFFFFFFF) as usize].b);
            }
        }
    }

    // `FOLD_CCMP`: each `and` or `or` of flags whose operands are comparisons of integers of up to 64 bits
    // with this one use and no folded operand, or such folded `and`s and `or`s, one of the two a
    // comparison, at most CCMP_MAX comparisons in all: its comparisons fold into it (`conj`), and it folds
    // into its users when each is a `select`'s or a `br`'s condition. Instructions come after their
    // operands, so an inner `and` is known before the one that takes it.
    fn conj_folds(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            let t = b.insts[i];
            if (t.op == O_SELECT || t.op == O_BR) && (t.a & (VPARAM | VFLAG)) == 0 {
                self.cnd[t.a as usize] += 1;
            }
        }
        for i in 0..ni {
            let t = b.insts[i];
            if t.op != O_AND && t.op != O_OR || t.ty != T_I8 || self.pfold[i] || self.count[i] == 0 {
                continue;
            }
            let mut na = self.conj_part(b, t.a);
            let mut nb = self.conj_part(b, t.b);
            let leaf_a = na == 1 && b.insts[t.a as usize].op == O_ICMP;
            let leaf_b = nb == 1 && b.insts[t.b as usize].op == O_ICMP;
            // A comparison of a folded operand (a `tst`) starts the chain, before a comparison the other
            // side is: the generator compares it first (`conj_flags`).
            if na == 0 && leaf_b && self.tst_leaf(b, t.a) {
                na = 1;
            } else if nb == 0 && leaf_a && self.tst_leaf(b, t.b) {
                nb = 1;
            }
            if na == 0 || nb == 0 || !leaf_a && !leaf_b || na + nb > CCMP_MAX {
                continue;
            }
            self.conj[i] = na + nb;
            self.pfold[t.a as usize] = true;
            self.pfold[t.b as usize] = true;
            self.pfold[i] = self.cnd[i] == self.count[i];
        }
    }

    // Whether `v` is an integer comparison of up to 64 bits with one use that folds into nothing
    // (`FOLD_BRCONJ`).
    fn cmp_leaf(self: &Self, b: &Body, v: Value) bool {
        if !is_inst(v) || b.insts[v as usize].op != O_ICMP || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let ty = b.type_of(b.insts[v as usize].a);
        return is_int(ty) && ty != T_I128 || ty == T_PTR;
    }

    // The product `FOLD_VMLA` folds into vector sum or difference `t`: its second operand, else (a sum) its
    // first. VNONE when none.
    pub(package) fn vmla_mul(self: &Self, b: &Body, t: Inst) Value {
        let lt = lane_type(t.ty);
        let nb = type_bytes(t.ty, 8);
        if !is_int(lt) || type_bytes(lt, 8) >= 8 || nb != 8 && nb != 16 {
            return VNONE;
        }
        let ok = |v: Value| (v & (VPARAM | VFLAG)) == 0 && v != VNONE && b.insts[v as usize].op == O_MUL && b.insts[v as usize].ty == t.ty && self.count[v as usize] == 1;
        if ok(t.b) && t.b != t.a {
            return t.b;
        }
        if t.op == O_ADD && ok(t.a) && t.a != t.b {
            return t.a;
        }
        return VNONE;
    }

    // The right shift by an immediate `FOLD_VMLA` folds into vector sum `t` when no product does: its second
    // operand, else its first. VNONE when none.
    pub(package) fn vsra_shift(self: &Self, b: &Body, t: Inst) Value {
        let ok = |v: Value| is_inst(v) && (b.insts[v as usize].op == O_LSHR || b.insts[v as usize].op == O_ASHR) && b.insts[v as usize].ty == t.ty && self.count[v as usize] == 1 && self.vshimm(
            b,
            b.insts[v as usize],
        ) != NONE && self.vshimm(b, b.insts[v as usize]) != 0;
        if ok(t.b) && t.b != t.a {
            return t.b;
        }
        if ok(t.a) && t.a != t.b {
            return t.a;
        }
        return VNONE;
    }

    // The absolute difference `FOLD_VSAD` folds into widening sum `t`: its second operand, an unsigned
    // `SIMD_ABS_DIFF` of two byte vectors of one use, when `t` sums into 8-byte lanes. VNONE when none.
    pub(package) fn vsad_diff(self: &Self, b: &Body, t: Inst) Value {
        let v = t.b;
        if type_bytes(lane_type(t.ty), 8) != 8 || (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 {
            return VNONE;
        }
        let d = b.insts[v as usize];
        let code = (core::OP_SIMD + core::SIMD_ABS_DIFF as u32) as u16;
        return if d.op == O_VOP && d.aux == code && d.b == 2 && type_bytes(lane_type(d.ty), 8) == 1 {
            v
        } else {
            VNONE
        };
    }

    // The extension `FOLD_VWADD` folds into vector sum `t`: its second operand, else its first. VNONE when
    // none.
    pub(package) fn vwadd_ext(self: &Self, b: &Body, t: Inst) Value {
        let lt = lane_type(t.ty);
        if !is_int(lt) || type_bytes(lt, 8) < 2 || type_bytes(t.ty, 8) != 16 {
            return VNONE;
        }
        if self.zero_zip(b, lt, t.b) && t.b != t.a {
            return t.b;
        }
        if self.zero_zip(b, lt, t.a) && t.a != t.b {
            return t.a;
        }
        return VNONE;
    }

    // Whether `v`, with one use, is a `bitcast` to lanes of type `lt` of a 16-byte `vziplo` or `vziphi`,
    // with one use, of a vector of half-width lanes with zeros (`FOLD_VWADD`).
    fn zero_zip(self: &Self, b: &Body, lt: u8, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || b.insts[v as usize].op != O_BITCAST {
            return false;
        }
        let z = b.insts[v as usize].a;
        if (z & (VPARAM | VFLAG)) != 0 || z == VNONE || self.count[z as usize] != 1 {
            return false;
        }
        let zt = b.insts[z as usize];
        return (zt.op == O_VZIPLO || zt.op == O_VZIPHI) && type_bytes(zt.ty, 8) == 16 && 2 * type_bytes(
            lane_type(zt.ty),
            8,
        ) == type_bytes(lt, 8) && zero_vec(b, zt.b) && zt.a != zt.b;
    }

    // Whether `O_VOP` `t` is an `or` of the lanes of an integer lane mask that `FOLD_ANY` (16 bytes) or
    // `FOLD_ANY_WIDE` (32) folds.
    fn any_fold(self: &Self, b: &Body, t: Inst) bool {
        if (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_REDUCE_OR as u32 || t.b != 1 {
            return false;
        }
        let v = b.pool[t.a as usize];
        let nb = type_bytes(b.type_of(v), 8);
        let f = if nb == 16 {
            FOLD_ANY
        } else if nb == 32 {
            FOLD_ANY_WIDE
        } else {
            0
        };
        return (self.fold_ops & f) != 0 && lane_mask(b, v, MASK_DEPTH);
    }

    // Whether `v` is an equality with 0 of an `and` `FOLD_TST` folds, which this use alone reads: a chain's
    // first comparison (`conj_folds`).
    fn tst_leaf(self: &Self, b: &Body, v: Value) bool {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return false;
        }
        let t = b.insts[v as usize];
        return t.op == O_ICMP && (t.aux == C_EQ || t.aux == C_NE) && (t.a & (VPARAM | VFLAG)) == 0 && self.pfold[t.a as usize] && b.insts[t.a as usize].op == O_AND;
    }

    // Whether `s` is a shift of `bits` bits by a constant below them, read once and not folded yet: an
    // operand `FOLD_SHOP` folds.
    fn shop_ok(self: &Self, b: &Body, s: Value, bits: u32) bool {
        if !is_inst(s) || self.pfold[s as usize] || self.count[s as usize] != 1 {
            return false;
        }
        let t = b.insts[s as usize];
        return t.op >= O_SHL && t.op <= O_ASHR && type_bits(t.ty, 8) == bits && int_const(b, t.b) < bits as u64;
    }

    // The comparisons operand `v` of an `and` or `or` brings to a `FOLD_CCMP` chain: 1 for a comparison it
    // alone uses, the chain's count for a chain it alone uses, else 0.
    fn conj_part(self: &Self, b: &Body, v: Value) u8 {
        if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || self.count[v as usize] != 1 || self.pfold[v as usize] {
            return 0;
        }
        let t = b.insts[v as usize];
        if self.conj[v as usize] != 0 {
            return self.conj[v as usize];
        }
        if t.op != O_ICMP || !is_int(b.type_of(t.a)) || b.type_of(t.a) == T_I128 {
            return 0;
        }
        let folded = (t.a & (VPARAM | VFLAG)) == 0 && self.pfold[t.a as usize] || t.b != VNONE && (t.b & (VPARAM | VFLAG)) == 0 && self.pfold[t.b as usize];
        return if folded {
            0
        } else {
            1
        };
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
        // Predecessor lists (CSR): `pat` holds the starts, `preds` the sources.
        let mut start = replace(&mut self.pat, Vector::<u32>::new());
        start.truncate(0);
        let mut acc: u32 = 0;
        for k in 0..nb {
            start.push(acc);
            acc += self.npred[k];
        }
        start.push(acc);
        let mut fillp = Vector::<u32>::with_capacity(nb);
        fillp.extend_copy(&start);
        let mut preds = replace(&mut self.preds, Vector::<u32>::new());
        fill(&mut preds, acc as usize, 0);
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
        self.pat = start;
        self.preds = preds;
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
                self.keys.len() as u32
            } else {
                mlen[l as usize]
            };
            if i == n {
                let _ = lists.pop();
                continue;
            }
            lists[top] = lists[top] + 1;
            let k = if l == NONE {
                self.keys[i as usize] as u32
            } else {
                mlist[(mstart[l as usize] + i) as usize]
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
        fill(&mut self.wpos, n, NONE);
        fill(&mut self.wn, n, 0);
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
        fill(&mut self.ua, ni, 0);
        fill(&mut self.un, ni, 0);
        self.uv.truncate(0);
        for p in 0..self.order.len() {
            let k = self.order[p];
            let bk = b.blocks[k as usize];
            for i in bk.start..bk.start + bk.len {
                let mut us = replace(&mut self.succ, Vector::<u32>::new());
                self.uses_at(b, i, &mut us);
                self.ua[i as usize] = self.uv.len() as u32;
                self.un[i as usize] = us.len() as u32;
                self.uv.extend_copy(&us);
                self.succ = us;
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
                    self.wn[x] += 1;
                    if self.wpos[x] == NONE || p as u32 > self.wpos[x] {
                        self.wpos[x] = p as u32;
                    }
                    if p as u32 > self.end[x] {
                        self.end[x] = p as u32;
                    }
                }
            }
        }
        self.rare_entries(b, &mut kept);
        fill(&mut self.next, n, NONE);
        fill(&mut self.use_next, self.uv.len(), NONE);
        let mut ordinal = ni as u32;
        for q in 0..self.order.len() {
            let bk = b.blocks[self.order[self.order.len() - 1 - q] as usize];
            for j in 0..bk.len {
                let i = bk.start + bk.len - 1 - j;
                ordinal -= 1;
                let a = self.ua[i as usize];
                let nu = self.un[i as usize];
                for r in 0..nu {
                    let u = (a + nu - 1 - r) as usize;
                    let x = self.vix(b, self.uv[u]) as usize;
                    self.use_next[u] = self.next[x];
                    self.next[x] = ordinal;
                }
            }
        }
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
        for k in 0..b.blocks.len() {
            if self.inner[k] == NONE || self.pos[k] == NONE {
                continue;
            }
            let bk = b.blocks[k];
            for i in bk.start..bk.start + bk.len {
                let a = self.ua[i as usize];
                for u in a..a + self.un[i as usize] {
                    let v = self.uv[u as usize];
                    if (v & (VPARAM | VFLAG)) == 0 && (b.insts[v as usize].op == O_FCONST || b.insts[v as usize].op == O_ICONST) {
                        let d = self.def_blk[v as usize];
                        out[v as usize] = out[v as usize] || self.end[v as usize] > self.pos[d as usize];
                    }
                }
            }
        }
    }

    /// Plan which values hold one register for their whole range or a block prefix (`home`, `cut`): the ones `want` (WANT_* per
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
        fill(&mut self.cut, n, NONE);
        self.splits.truncate(0);
        // A cut cannot cross a backward edge: code after it never re-enters the register prefix.
        fill(&mut self.work, np + 1, 0);
        if self.split {
            for q in 0..np {
                let k = self.order[q] as usize;
                for j in self.pat[k]..self.pat[k + 1] {
                    let p = self.pos[self.preds[j as usize] as usize];
                    if p != NONE && p > q as u32 {
                        self.work[q + 1] = self.work[q + 1].max(p + 1);
                    }
                }
            }
            for q in 1..np {
                self.work[q] = self.work[q].max(self.work[q - 1]);
            }
            // A value whose register prefix enters only blocks that keep the register state gains nothing
            // from a cut: the generator keeps it in its register without a home, and stores it only when it
            // must.
            fill(&mut self.breaks, np, 0);
            for q in 1..np {
                self.breaks[q] = self.breaks[q - 1] + (!self.continues(b, q as u32)) as u32;
            }
        }
        fill(&mut self.share, n, NONE);
        fill(&mut self.shared_by, n, NONE);
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
                f / 8
            } else {
                f
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
                let a = self.ua[i as usize];
                for u in a..a + self.un[i as usize] {
                    let x = self.vix(b, self.uv[u as usize]) as usize;
                    self.wt[x] += f;
                    self.au[x] += 1;
                }
            }
            // The terminator's edges write their targets' parameters; a late edge's moves wait past the last
            // block (`late`).
            let o = self.base[p + 1] - 1;
            each_edge_param(b, b.insts[(bk.start + bk.len - 1) as usize], &mut self.succ);
            let lt = self.late_target(b, k);
            for q in 0..self.succ.len() {
                let x = self.succ[q] as usize;
                self.wt[x] += f;
                self.au[x] += 1;
                if o < self.start[x] && (lt == NONE || self.def_blk[x] != lt) {
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
            // A block parameter ends at its last read too when no edge from its last block writes it
            // (edges write at the block's end).
            let read = if x < ni {
                self.au[x] != 0
            } else {
                x < nv && self.uses[x] > self.wn[x] && (self.wpos[x] == NONE || self.wpos[x] < e as u32)
            };
            self.stop[x] = if read && self.uses[x] == self.au[x] && self.pos[self.def_blk[l as usize] as usize] == e as u32 {
                self.base[e] + l - b.blocks[self.def_blk[l as usize] as usize].start
            } else {
                self.base[e + 1] - 1
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
        self.stepped.truncate(0);
        fill(&mut self.cnt, 4, 0);
        for c in 0..self.cand.len() {
            let x = (self.cand[c] & 0xFFFFFFFF) as u32;
            let s = (self.cand[c] >> 32) as u32;
            // The ranges that ended before this one starts give their registers back, but to a step that
            // shares one and lives on (`step_partner`), which holds it from there.
            let mut j: usize = 0;
            while j < self.act.len() {
                let a = self.act[j];
                if self.stop[a as usize] >= s {
                    j += 1;
                    continue;
                }
                let mut h = NONE;
                for q in 0..self.stepped.len() {
                    if (self.stepped[q] >> 32) as u32 == a {
                        h = (self.stepped[q] & 0xFFFFFFFF) as u32;
                    }
                }
                if h != NONE && self.home[h as usize] != HOME_NONE && self.stop[h as usize] >= s {
                    self.act[j] = h;
                    j += 1;
                } else {
                    self.leave(j, want);
                }
            }
            // A parameter of a block after a loop shares the register of the loop's parameter it continues
            // (`exit_partner`): that parameter's range covers it.
            let ep = self.exit_partner(b, x);
            if ep != NONE && self.shared_by[ep as usize] == NONE && self.home[ep as usize] != HOME_NONE && (want[x as usize] & WANT_V) == (want[ep as usize] & WANT_V) && (want[x as usize] & Live::want_of(
                self.home[ep as usize],
            )) != 0 {
                let mut j: usize = 0;
                while j < self.act.len() && self.act[j] != ep {
                    j += 1;
                }
                if j < self.act.len() {
                    self.home[x as usize] = self.home[ep as usize];
                    self.stop[ep as usize] = self.stop[ep as usize].max(self.stop[x as usize]);
                    self.share[x as usize] = ep;
                    self.shared_by[ep as usize] = x;
                    continue;
                }
            }
            // A loop's step or accumulator takes the register of the header parameter it replaces
            // (`step_partner`): that parameter's range ends where it starts.
            let sp = self.step_partner(b, x);
            if sp != NONE && self.home[sp as usize] != HOME_NONE && (want[x as usize] & WANT_V) == (want[sp as usize] & WANT_V) && (want[x as usize] & Live::want_of(
                self.home[sp as usize],
            )) != 0 && (want[x as usize] & WANT_SCRATCH) != 0 {
                let mut j: usize = 0;
                while j < self.act.len() && self.act[j] != sp {
                    j += 1;
                }
                if j < self.act.len() {
                    self.home[x as usize] = self.home[sp as usize];
                    self.stepped.push(sp as u64 << 32 | x as u64);
                    continue;
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
                    let mut lo: usize = 0;
                    let mut hi = np;
                    while lo + 1 < hi {
                        let mid = lo + (hi - lo) / 2;
                        if self.base[mid] <= s {
                            lo = mid;
                        } else {
                            hi = mid;
                        }
                    }
                    let block = lo;
                    let d = self.pos[self.def_blk[a as usize] as usize] as usize;
                    if self.split && self.work[block] <= block as u32 && d < block && self.breaks[block] > self.breaks[d] && self.start[a as usize] < self.base[block] && self.share[a as usize] == NONE && self.shared_by[a as usize] == NONE && a < nv as u32 && !(a >= ni as u32 && agg_param(
                        b,
                        VPARAM | a - ni as u32,
                    )) {
                        self.cut[a as usize] = block as u32;
                    } else {
                        self.home[a as usize] = HOME_NONE;
                        // The parameter that shares its register (`exit_partner`) loses it too: no count holds it.
                        let sx = self.shared_by[a as usize];
                        if sx != NONE {
                            self.home[sx as usize] = HOME_NONE;
                            self.share[sx as usize] = NONE;
                            self.shared_by[a as usize] = NONE;
                        }
                    }
                    // So do the steps that share it.
                    for q in 0..self.stepped.len() {
                        if (self.stepped[q] >> 32) as u32 == a {
                            self.home[(self.stepped[q] & 0xFFFFFFFF) as usize] = HOME_NONE;
                        }
                    }
                    h = self.fits(x, want, caps, NONE);
                }
            }
            if h != HOME_NONE {
                self.home[x as usize] = h;
                self.cnt[Live::slot(want[x as usize], h)] += 1;
                self.act.push(x);
            }
        }
        for x in 0..n {
            if self.cut[x] != NONE {
                self.splits.push(self.cut[x] as u64 << 32 | x as u64);
            }
        }
        self.splits.sort();
    }

    /// The register home of value `x` in layout block `pos`.
    pub(package) const fn home_at(self: &Self, x: u32, pos: u32) u8 {
        return if pos < self.cut[x as usize] {
            self.home[x as usize]
        } else {
            HOME_NONE
        };
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
            (caps.vc, caps.vs, caps.vj)
        } else {
            (caps.xc, caps.xs, caps.xj)
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

    // `FOLD_ADC`: each sum or difference with a carry or borrow (`carry_of`), its parts marked (`carry`).
    fn carries(self: &mut Self, b: &Body) {
        let ni = b.insts.len();
        // The uses of each instruction's flag.
        fill(&mut self.cnd, ni, 0);
        for i in 0..ni {
            each_use(b, b.insts[i], &mut self.succ);
            for u in 0..self.succ.len() {
                let v = self.succ[u];
                if (v & (VPARAM | VFLAG)) == VFLAG {
                    self.cnd[(v & ~VFLAG) as usize] += 1;
                }
            }
        }
        for i in 0..ni as u32 {
            let t = b.insts[i as usize];
            let sub = t.op == O_SUB || t.op == O_SUBO;
            if !self.wrapping(b, i, sub) {
                continue;
            }
            for side in 0..2u32 {
                // A difference's borrow is its second operand.
                if sub && side == 0 {
                    continue;
                }
                let (z, h) = if side == 0 {
                    (t.a, t.b)
                } else {
                    (t.b, t.a)
                };
                if !is_inst(z) || !is_inst(h) || self.count[z as usize] != 1 || self.count[h as usize] != 1 || self.pfold[z as usize] || self.pfold[h as usize] || !self.wrapping(
                    b,
                    h,
                    sub,
                ) {
                    continue;
                }
                let zt = b.insts[z as usize];
                if zt.op != O_ZEXT || zt.ty != t.ty || (zt.a & (VPARAM | VFLAG)) != VFLAG {
                    continue;
                }
                let lo = zt.a & ~VFLAG;
                let lt = b.insts[lo as usize];
                let ht = b.insts[h as usize];
                if lt.op != if sub {
                    O_SUBO
                } else {
                    O_ADDO
                } || lt.aux == OV_SIGNED || lt.ty != t.ty || self.cnd[lo as usize] != 1 || self.pfold[lo as usize] || is_inst(
                    ht.a,
                ) && self.pfold[ht.a as usize] || is_inst(ht.b) && self.pfold[ht.b as usize] {
                    continue;
                }
                // Only `h` and the extension between the `addo` and the sum: no code between sets the flags.
                let mut ok = lo < z && lo < h && z < i && h < i;
                for j in lo + 1..i {
                    ok = ok && (j == z || j == h);
                }
                if ok {
                    self.pfold[z as usize] = true;
                    self.pfold[h as usize] = true;
                    self.carry[lo as usize] = CARRY_LO;
                    self.carry[z as usize] = CARRY_PART;
                    self.carry[h as usize] = CARRY_PART;
                    self.carry[i as usize] = CARRY_ADC;
                    break;
                }
            }
        }
    }

    // Whether instruction `i` of `b` is a sum (`sub`: difference) of two integers of 32 or 64 bits that
    // wraps: `add`, or `addo` whose flag nothing reads (`cnd`).
    fn wrapping(self: &Self, b: &Body, i: u32, sub: bool) bool {
        let t = b.insts[i as usize];
        let bits = type_bits(t.ty, 8);
        let (plain, ovf) = if sub {
            (O_SUB, O_SUBO)
        } else {
            (O_ADD, O_ADDO)
        };
        return (t.op == plain || t.op == ovf && self.cnd[i as usize] == 0) && is_int(t.ty) && (bits == 32 || bits == 64);
    }

    // The loop header parameter instruction `x` replaces, when it may take that parameter's register as
    // the generators' `def_step` and `step_reg` do: the back edge that ends `x`'s block passes `x` to it
    // (`back_param`), its range ends in that block, nothing after `x` there reads it, and `x` reads it as
    // its first operand alone if at all. NONE when not.
    fn step_partner(self: &mut Self, b: &Body, x: u32) u32 {
        if x as usize >= b.insts.len() {
            return NONE;
        }
        let k = self.def_blk[x as usize];
        if k == NONE || self.pos[k as usize] == NONE {
            return NONE;
        }
        let bk = b.blocks[k as usize];
        let px = self.back_param(b, b.insts[(bk.start + bk.len - 1) as usize], x, self.pos[k as usize]);
        if px == NONE || self.end[px as usize] != self.pos[k as usize] {
            return NONE;
        }
        let pv = VPARAM | px - b.insts.len() as u32;
        let a = self.ua[x as usize];
        let mut n: u32 = 0;
        for u in a..a + self.un[x as usize] {
            n += (self.uv[u as usize] == pv) as u32;
        }
        if n > 1 || n == 1 && b.insts[x as usize].a != pv || self.reads_after(b, k, x, pv) {
            return NONE;
        }
        return px;
    }

    // The header parameter of a loop that parameter value `x` of `b`, of a block laid out after the loop,
    // continues: every edge into `x`'s block comes from a block laid out before it, and leaves the loop
    // passing that parameter or the value its back edge passes it, or comes from a block laid out before
    // the loop; the parameter is dead past the loop and of `x`'s type. Its register may then hold `x` too:
    // on the loop's exits it holds the value already, and an edge that skips the loop finds it unused.
    // NONE else.
    fn exit_partner(self: &Self, b: &Body, x: u32) u32 {
        let ni = b.insts.len() as u32;
        if x < ni || x >= ni + b.params.len() as u32 {
            return NONE;
        }
        let k = self.def_blk[x as usize];
        if k == 0 || k == NONE || self.pos[k as usize] == NONE {
            return NONE;
        }
        let q = x - ni - b.blocks[k as usize].param_start;
        let mut px = NONE;
        let mut h = NONE;
        // Each predecessor's terminator and its edges into the block: a bounded walk of the edge lists.
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = self.preds[j as usize];
            // An edge from a later block would write the register after the range ends.
            if self.pos[pb as usize] != NONE && self.pos[pb as usize] >= self.pos[k as usize] {
                return NONE;
            }
            let hh = self.left(b, pb);
            if self.pos[pb as usize] == NONE || hh == NONE || self.pos[k as usize] <= self.lend[hh as usize] {
                continue;
            }
            let t = term_of(b, pb);
            let ne: u32 = if t.op == O_JMP {
                1
            } else if t.op == O_BR {
                2
            } else {
                0
            };
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                if b.edge_target(ed) != k {
                    continue;
                }
                let p = self.exit_value(b, hh, t, ed, q);
                if p == NONE || px != NONE && p != px {
                    return NONE;
                }
                px = p;
                h = hh;
            }
        }
        if px == NONE || b.params[(px - ni) as usize] != b.params[(x - ni) as usize] || self.end[px as usize] > self.lend[h as usize] {
            return NONE;
        }
        // The other edges come from before the loop, or from inside it with the same value.
        for j in self.pat[k as usize]..self.pat[k as usize + 1] {
            let pb = self.preds[j as usize];
            let pp = self.pos[pb as usize];
            if pp == NONE {
                continue;
            }
            let inside = pp >= self.pos[h as usize] && pp <= self.lend[h as usize] || self.left(b, pb) == h;
            if !inside && pp >= self.pos[h as usize] {
                return NONE;
            }
            if inside {
                let t = term_of(b, pb);
                if t.op != O_JMP && t.op != O_BR {
                    return NONE;
                }
                let ne: u32 = if t.op == O_JMP {
                    1
                } else {
                    2
                };
                for e in 0..ne {
                    let ed = edge_of(b, t, e);
                    if b.edge_target(ed) == k && self.exit_value(b, h, t, ed, q) != px {
                        return NONE;
                    }
                }
            }
        }
        return px;
    }

    // The loop block `k` of `b` leaves: its innermost one, or for a lone jump whose one predecessor is in a
    // loop the block is outside of (a split exit edge), that loop. NONE else.
    fn left(self: &Self, b: &Body, k: u32) u32 {
        let h = self.inner[k as usize];
        if h != NONE {
            return h;
        }
        if b.blocks[k as usize].len != 1 || term_of(b, k).op != O_JMP || self.pat[k as usize + 1] - self.pat[k as usize] != 1 {
            return NONE;
        }
        let p = self.preds[self.pat[k as usize] as usize];
        let hp = self.inner[p as usize];
        if hp == NONE || self.pos[k as usize] == NONE || self.pos[k as usize] >= self.pos[hp as usize] && self.pos[k as usize] <= self.lend[hp as usize] {
            return NONE;
        }
        return hp;
    }

    // The parameter value of loop header `h` that argument `q` of edge `ed` of terminator `t` continues: the
    // one the other edge of `t`, a back edge to `h`, passes it to (that edge's moves before the branch then
    // serve `ed` too), else `header_of_value`.
    fn exit_value(self: &Self, b: &Body, h: u32, t: Inst, ed: u32, q: u32) u32 {
        let v = b.edge_arg(ed, q);
        if t.op == O_BR {
            let o = if ed == t.b {
                t.c
            } else {
                t.b
            };
            if b.edge_target(o) == h {
                let hb = b.blocks[h as usize];
                for j in 0..hb.param_len as u32 {
                    if b.edge_arg(o, j) == v {
                        return b.insts.len() as u32 + hb.param_start + j;
                    }
                }
            }
        }
        return self.header_of_value(b, h, v);
    }

    // The parameter value of loop header `h` that `v` of `b` is: the parameter itself, or the value a back
    // edge of the loop passes it. NONE else.
    fn header_of_value(self: &Self, b: &Body, h: u32, v: Value) u32 {
        let ni = b.insts.len() as u32;
        let hb = b.blocks[h as usize];
        if v != VNONE && (v & VFLAG) == 0 && (v & VPARAM) != 0 {
            let p = v & ~VPARAM;
            return if p >= hb.param_start && p < hb.param_start + hb.param_len as u32 {
                ni + p
            } else {
                NONE
            };
        }
        for j in self.pat[h as usize]..self.pat[h as usize + 1] {
            let pb = self.preds[j as usize];
            let pp = self.pos[pb as usize];
            if pp == NONE || pp < self.pos[h as usize] || pp > self.lend[h as usize] {
                continue;
            }
            let t = term_of(b, pb);
            let ne: u32 = if t.op == O_JMP {
                1
            } else if t.op == O_BR {
                2
            } else {
                0
            };
            for e in 0..ne {
                let ed = edge_of(b, t, e);
                if b.edge_target(ed) != h {
                    continue;
                }
                for q in 0..hb.param_len as u32 {
                    if b.edge_arg(ed, q) == v {
                        return ni + hb.param_start + q;
                    }
                }
            }
        }
        return NONE;
    }

    // The request that home `h` answers.
    const fn want_of(h: u8) u8 {
        return if h == HOME_CALLEE {
            WANT_CALLEE
        } else {
            WANT_SCRATCH
        };
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
                    sp[(j - 1) * np + i + h]
                } else {
                    0u32
                };
                sp.push(
                    if a > c {
                        a
                    } else {
                        c
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
                    a
                } else {
                    c
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
/// `us` is scratch.
pub(package) fn reads_slot(b: &Body, t: Inst, s: u32, us: &mut Vector<Value>) bool {
    each_use(b, t, us);
    for q in 0..us.len() {
        let v = us[q];
        if v != VNONE && (v & (VPARAM | VFLAG)) == 0 && b.insts[v as usize].op == O_SLOTADDR && b.insts[v as usize].a == s {
            return true;
        }
    }
    return false;
}

// `reads_before` follows at most BACK_SCAN blocks.
const BACK_SCAN: u32 = 32;

/// `op_flags` bits: the body holds an `O_RETADDR`, an `O_VASTART`, an `O_ASM`, an `O_SYS`.
pub(package) const OP_RETADDR: u8 = 1;
pub(package) const OP_VASTART: u8 = 2;
pub(package) const OP_ASM: u8 = 4;
pub(package) const OP_SYS: u8 = 8;

/// Which of the operations `OP_*` names body `b` holds.
pub(package) const fn op_flags(b: &Body) u8 {
    let mut f: u8 = 0;
    for i in 0..b.insts.len() {
        let op = b.insts[i].op;
        if op == O_RETADDR {
            f |= OP_RETADDR;
        } else if op == O_VASTART {
            f |= OP_VASTART;
        } else if op == O_ASM {
            f |= OP_ASM;
        } else if op == O_SYS {
            f |= OP_SYS;
        }
    }
    return f;
}

/// The values instruction `t` of `b` uses into `out`, each use once: its operands, a call's arguments, a
/// vector operation's operands and each edge's arguments.
pub(package) fn each_use(b: &Body, t: Inst, out: &mut Vector<Value>) {
    lv::uses(b, t, out);
    if t.op == O_RET && (b.pool[b.sig as usize + 2] & AGG) != 0 {
        // The return reads the aggregate result's memory, the parameter after the declared ones.
        out.push(VPARAM | b.blocks[0].param_start + b.pool[b.sig as usize]);
    }
    let ne: u32 = if t.op == O_JMP {
        1
    } else if t.op == O_BR {
        2
    } else if t.op == O_SWITCH {
        t.aux as u32 + 1
    } else {
        0
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

/// Edge `k` of terminator `t` (`jmp`: 0; `br`: 0 taken, 1 not; `switch`: its cases, then the default).
pub(package) const fn edge_of(b: &Body, t: Inst, k: u32) u32 {
    if t.op == O_JMP {
        return t.a;
    }
    if t.op == O_BR {
        return if k == 0 {
            t.b
        } else {
            t.c
        };
    }
    return b.switch_edge(t, k);
}

/// A rotation (`rotate_of`): value `x` by amount `amt` (VNONE for constant `k`, rotating left), to the
/// right when `right`; `x` VNONE for none. `src` is the shift's own amount operand, `amt` maybe past an
/// extension of it (`rot_amount`). A funnel shift when `y`, the value shifted right, is not `x`: `x << k |
/// y >> (w - k)`, by a constant.
pub(package) struct Rotation {
    pub(package) x: Value,
    pub(package) y: Value,
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
/// shift right's. Of two values of 32 or 64 bits by constants, a funnel shift.
pub(package) fn rotate_of(b: &Body, i: u32) Rotation {
    let none = Rotation { x: VNONE, y: VNONE, amt: VNONE, src: VNONE, k: 0, right: false };
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
        (p, q)
    } else if p.op == O_LSHR && q.op == O_SHL {
        (q, p)
    } else {
        return none;
    };
    if l.ty != t.ty || r.ty != t.ty || l.a != r.a && bits < 32 {
        return none;
    }
    let kl = int_const(b, l.b);
    let kr = int_const(b, r.b);
    let al = amount_of(b, l.b);
    let ar = amount_of(b, r.b);
    if kl != u64::MAX && kr != u64::MAX {
        if kl > 0 && kl < bits && kl + kr == bits {
            return Rotation { x: l.a, y: r.a, amt: VNONE, src: VNONE, k: kl as u32, right: false };
        }
        return none;
    }
    if l.a != r.a {
        return none;
    }
    let or = t.op == O_OR;
    if negated(b, ar, al, bits, or) {
        return Rotation { x: l.a, y: l.a, amt: al, src: l.b, k: 0, right: false };
    }
    if negated(b, al, ar, bits, or) {
        return Rotation { x: l.a, y: l.a, amt: ar, src: r.b, k: 0, right: true };
    }
    return none;
}

/// What `v` is as a `select`'s side next to side `other` (CS_*): `other + 1`, `-other`, `~other` (an
/// integer of up to 64 bits), which a conditional instruction computes from `other`; else CS_NONE.
/// A field insertion `bfi_of` reads: `keep` (`x & ~(m << s)`), `field` (`(v & m) << s`), `m` the `w` low
/// bits.
pub(package) struct Bfi {
    pub(package) x: Value,
    pub(package) v: Value,
    pub(package) keep: Value,
    pub(package) field: Value,
    pub(package) trunc: Value, // the truncation the kept side extends, else VNONE
    pub(package) s: u32,
    pub(package) w: u32,
}

/// Instruction `t` of `b` as an insertion of `v`'s low `w` bits into `x` at bit `s`: an `or` of 32 or 64
/// bits of `x & ~(m << s)` (or the extension of `x` truncated to the bits below the field when it reaches
/// the top) and `(v & m) << s` (or `v` extended from `w` bits, shifted), `m` the `w` low bits, the field
/// within the width; `x` VNONE when it is not one.
pub(package) fn bfi_of(b: &Body, t: Inst) Bfi {
    let none = Bfi { x: VNONE, v: VNONE, keep: VNONE, field: VNONE, trunc: VNONE, s: 0, w: 0 };
    let bits = type_bits(t.ty, 8);
    if t.op != O_OR || !is_int(t.ty) || bits != 32 && bits != 64 || !is_inst(t.a) || !is_inst(t.b) {
        return none;
    }
    let all = if bits == 64 {
        u64::MAX
    } else {
        0xFFFFFFFFu64
    };
    for side in 0..2 {
        let (ka, kb) = if side == 0 {
            (t.a, t.b)
        } else {
            (t.b, t.a)
        };
        let a = b.insts[ka as usize];
        let sh = b.insts[kb as usize];
        if a.op != O_AND && a.op != O_ZEXT || sh.op != O_SHL || !is_inst(sh.a) {
            continue;
        }
        let f = b.insts[sh.a as usize];
        let s = int_const(b, sh.b);
        let m = if f.op == O_AND {
            int_const(b, f.b)
        } else if f.op == O_ZEXT && type_bits(b.type_of(f.a), 8) < 64 {
            (1u64 << type_bits(b.type_of(f.a), 8) as u64) - 1
        } else {
            u64::MAX
        };
        // The kept bits: an `and`'s mask, or those below a truncation's width.
        let (x, k, tr) = if a.op == O_AND {
            (a.a, int_const(b, a.b), VNONE)
        } else if is_inst(a.a) && b.insts[a.a as usize].op == O_TRUNC && type_bits(b.type_of(a.a), 8) < 64 {
            let n = b.insts[a.a as usize];
            (n.a, (1u64 << type_bits(n.ty, 8) as u64) - 1, a.a)
        } else {
            (VNONE, u64::MAX, VNONE)
        };
        if s == u64::MAX || m == u64::MAX || k == u64::MAX || m == 0 || (m & m + 1) != 0 || s >= bits as u64 || type_bits(
            b.type_of(x),
            8,
        ) != bits {
            continue;
        }
        let w = (m + 1).trailing_zeros() as u64;
        if s + w <= bits as u64 && (k & all) == (~(m << s) & all) {
            return Bfi { x: x, v: f.a, keep: ka, field: kb, trunc: tr, s: s as u32, w: w as u32 };
        }
    }
    return none;
}

/// The value instruction `v` of `b` inverts (`not v`, or `xor v` with all ones of its width); VNONE when it
/// is no inversion.
pub(package) fn inversion(b: &Body, v: Value) Value {
    if !is_inst(v) {
        return VNONE;
    }
    let t = b.insts[v as usize];
    if t.op == O_NOT {
        return t.a;
    }
    let m = if type_bits(t.ty, 8) >= 64 {
        u64::MAX
    } else {
        (1u64 << type_bits(t.ty, 8) as u64) - 1
    };
    if t.op == O_XOR && is_int(t.ty) && t.ty != T_I128 && is_const_val(b, t.b) && (const_val(b, t.b) & m) == m {
        return t.a;
    }
    return VNONE;
}

/// The operand of `and`, `or` or `xor` `t` of `b` that is a folded inversion (`FOLD_NOT`, `folded`); VNONE
/// when none.
pub(package) fn not_side(b: &Body, folded: &Vector<bool>, t: Inst) Value {
    if t.op != O_AND && t.op != O_OR && t.op != O_XOR {
        return VNONE;
    }
    if is_inst(t.b) && folded[t.b as usize] && inversion(b, t.b) != VNONE {
        return t.b;
    }
    if is_inst(t.a) && folded[t.a as usize] && inversion(b, t.a) != VNONE {
        return t.a;
    }
    return VNONE;
}

// Whether instruction `t` may write memory: a store, a call, a block copy or fill, an atomic operation,
// inline assembly, a system call or a variadic access.
const fn writes_mem(t: Inst) bool {
    let op = t.op;
    return op == O_STORE || op == O_CALL || op == O_CALLIND || op == O_MEMCPY || op == O_MEMSET || op >= O_ALOAD && op <= O_FENCE || op == O_ASM || op == O_SYS || op == O_VASTART || op == O_VAARG;
}

// Whether value `v` of `b` is an entry parameter of aggregate type (a pointer to its bytes), or the
// pointer to an aggregate result (the parameter after the signature's).
fn agg_param(b: &Body, v: Value) bool {
    if (v & VPARAM) == 0 || v == VNONE || b.sig == NONE {
        return false;
    }
    let e = b.blocks[0];
    let q = (v & ~VPARAM) - e.param_start;
    let np = b.pool[b.sig as usize];
    if (v & ~VPARAM) < e.param_start || q >= e.param_len as u32 {
        return false;
    }
    return q < np && (b.pool[(b.sig + 3 + q) as usize] & AGG) != 0 || q == np && (b.pool[b.sig as usize + 2] & AGG) != 0;
}

/// The side of select `i` of `b` that `FOLD_CARRY` folds (the other side plus 1), when `i` is of 32 or 64
/// bits on a folded (`folded`) integer comparison of at most 64 bits; VNONE else.
pub(package) fn carry_inc(b: &Body, folded: &Vector<bool>, i: u32) Value {
    let t = b.insts[i as usize];
    if t.op != O_SELECT || !is_int(t.ty) || type_bits(t.ty, 8) < 32 || t.ty == T_I128 || !is_inst(t.a) || !folded[t.a as usize] {
        return VNONE;
    }
    let c = b.insts[t.a as usize];
    if c.op != O_ICMP || type_bits(b.type_of(c.a), 8) > 64 {
        return VNONE;
    }
    if is_inst(t.b) && !folded[t.b as usize] && cs_kind(b, t.b, t.c) == CS_INC {
        return t.b;
    }
    if is_inst(t.c) && !folded[t.c as usize] && cs_kind(b, t.c, t.b) == CS_INC {
        return t.c;
    }
    return VNONE;
}

pub(package) fn cs_kind(b: &Body, v: Value, other: Value) u8 {
    if other == VNONE {
        return CS_NONE;
    }
    let (k, x) = cs_base(b, v);
    return if x == other {
        k
    } else {
        CS_NONE
    };
}

/// `cs_kind` of `v` with the value it adds 1 to, negates or inverts: that kind and value, else
/// (CS_NONE, VNONE).
pub(package) fn cs_base(b: &Body, v: Value) (u8, Value) {
    if !is_inst(v) {
        return (CS_NONE, VNONE);
    }
    let t = b.insts[v as usize];
    let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_NEG || t.op == O_NOT || t.op == O_XOR;
    if !ops || !is_int(t.ty) || t.ty == T_I128 {
        return (CS_NONE, VNONE);
    }
    let m = if type_bits(t.ty, 8) >= 64 {
        u64::MAX
    } else {
        (1u64 << type_bits(t.ty, 8) as u64) - 1
    };
    let un = t.op == O_NEG || t.op == O_NOT;
    let ka = const_val(b, t.a) & m;
    let kb = if un {
        0
    } else {
        const_val(b, t.b) & m
    };
    let ca = is_const_val(b, t.a);
    let cb = !un && is_const_val(b, t.b);
    if t.op == O_ADD && cb && kb == 1 || t.op == O_SUB && cb && kb == m {
        return (CS_INC, t.a);
    }
    if t.op == O_ADD && ca && ka == 1 {
        return (CS_INC, t.b);
    }
    if t.op == O_NEG {
        return (CS_NEG, t.a);
    }
    if t.op == O_SUB && ca && ka == 0 && !cb {
        return (CS_NEG, t.b);
    }
    if t.op == O_NOT || t.op == O_XOR && cb && kb == m {
        return (CS_NOT, t.a);
    }
    if t.op == O_XOR && ca && ka == m {
        return (CS_NOT, t.b);
    }
    return (CS_NONE, VNONE);
}

// Whether `v` is an integer constant, and its bits.
fn is_const_val(b: &Body, v: Value) bool {
    return is_inst(v) && b.insts[v as usize].op == O_ICONST;
}

fn const_val(b: &Body, v: Value) u64 {
    if !is_const_val(b, v) {
        return 0;
    }
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}

/// The operand of 32- or 64-bit sum, difference or bitwise operation `t` that is a folded shift by a
/// constant (`FOLD_SHOP`): `t.b`, else `t.a`; VNONE when neither is.
pub(package) fn shop_side(b: &Body, pfold: &Vector<bool>, t: Inst) Value {
    let ops = t.op == O_ADD || t.op == O_SUB || t.op == O_AND || t.op == O_OR || t.op == O_XOR;
    if !ops || !is_int(t.ty) || t.ty == T_I128 {
        return VNONE;
    }
    if is_inst(t.b) && pfold[t.b as usize] && b.insts[t.b as usize].op >= O_SHL && b.insts[t.b as usize].op <= O_ASHR {
        return t.b;
    }
    if is_inst(t.a) && pfold[t.a as usize] && b.insts[t.a as usize].op >= O_SHL && b.insts[t.a as usize].op <= O_ASHR {
        return t.a;
    }
    return VNONE;
}

/// The extension (`O_ZEXT`, `O_SEXT`) both operands of 64-bit product `t` are, from 32 bits, two
/// instructions, or its first operand is with the second a constant the extension of its low 32 bits; 0
/// when not.
pub(package) fn mull_ext(b: &Body, t: Inst) u8 {
    if !is_inst(t.a) || !is_inst(t.b) || t.a == t.b {
        return 0;
    }
    let x = b.insts[t.a as usize];
    let y = b.insts[t.b as usize];
    if is_const_val(b, t.b) && (x.op == O_ZEXT || x.op == O_SEXT) && b.type_of(x.a) == T_I32 {
        let c = const_val(b, t.b);
        let fits = if x.op == O_ZEXT {
            c >> 32 == 0
        } else {
            c as i64 >= -2147483648 && c as i64 < 2147483648
        };
        return if fits {
            x.op
        } else {
            0u8
        };
    }
    if x.op != y.op || x.op != O_ZEXT && x.op != O_SEXT || b.type_of(x.a) != T_I32 || b.type_of(y.a) != T_I32 {
        return 0;
    }
    return x.op;
}

/// The value a left shift with operand `v` shifts: the narrow value when `v` is a zero extension folded
/// into it (`FOLD_ZSHL`), else `v`.
pub(package) fn shl_source(b: &Body, pfold: &Vector<bool>, v: Value) Value {
    if !is_inst(v) || !pfold[v as usize] || b.insts[v as usize].op != O_ZEXT {
        return v;
    }
    return b.insts[v as usize].a;
}

/// The amount a shift with amount operand `v` takes: the operand of `v` when `v` is a mask folded into the
/// shift (`FOLD_SHAMT`), else `v`.
pub(package) fn shift_amount(b: &Body, pfold: &Vector<bool>, v: Value) Value {
    if (v & (VPARAM | VFLAG)) != 0 || v == VNONE || !pfold[v as usize] || b.insts[v as usize].op != O_AND {
        return v;
    }
    return b.insts[v as usize].a;
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
        p.b
    } else if p.op == O_NEG && masked {
        p.a
    } else {
        VNONE
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
        k as u32
    } else {
        0u32
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
/// instructions): an `add`, an `or` of disjoint bits (`is_sum_or`), or a `sub` of a constant, of up to
/// two registers, one of them shifted left by
/// 1 to 3 when folded (`lea_shift`), and a displacement that 32 signed bits hold, a folded inner `add`'s
/// operands among its own. An index alone takes a shift of at most 1 (`index + index`): no form here
/// lacks a base.
pub(package) fn lea_of(b: &Body, folded: &Vector<bool>, i: u32) Lea {
    let mut f = Lea { ok: true, base: VNONE, index: VNONE, sh: 0, disp: 0 };
    let t = b.insts[i as usize];
    if t.op != O_ADD && t.op != O_SUB && !is_sum_or(b, t) || !is_int(t.ty) || t.ty == T_I128 || t.op == O_SUB && int_const(
        b,
        t.b,
    ) == u64::MAX {
        f.ok = false;
        return f;
    }
    let bits = type_bits(t.ty, 8);
    for q in 0..2u32 {
        let v = if q == 0 {
            t.a
        } else {
            t.b
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
            f.disp - s
        } else {
            f.disp + s
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

/// Whether `t` of `b` is an `or` of two integers no bit of which both may have (`ones_of`): a sum.
pub(package) fn is_sum_or(b: &Body, t: Inst) bool {
    if t.op != O_OR || !is_int(t.ty) || t.ty == T_I128 || t.ty == T_PTR {
        return false;
    }
    let bits = type_bits(t.ty, 8);
    return (ones_of(b, t.a, bits, ONES_DEPTH) & ones_of(b, t.b, bits, ONES_DEPTH)) == 0;
}

// The bits value `v` of `b` (`bits` wide) may have set, through at most `depth` instructions: a
// constant's, an `and`'s with a constant, a shift's by a constant, a zero extension's; else all.
fn ones_of(b: &Body, v: Value, bits: u32, depth: u32) u64 {
    let all = if bits >= 64 {
        u64::MAX
    } else {
        (1u64 << bits as u64) - 1
    };
    let k = int_const(b, v);
    if k != u64::MAX {
        return k & all;
    }
    if !is_inst(v) || depth == 0 {
        return all;
    }
    let t = b.insts[v as usize];
    if t.op != O_AND && t.op != O_SHL && t.op != O_LSHR && t.op != O_ZEXT {
        return all;
    }
    // `b` is a value of these (a call's is a pool index).
    let c = if t.op == O_ZEXT {
        u64::MAX
    } else {
        int_const(b, t.b)
    };
    if t.op == O_AND {
        let m = if c != u64::MAX {
            c
        } else {
            ones_of(b, t.b, bits, depth - 1)
        };
        return ones_of(b, t.a, bits, depth - 1) & m & all;
    }
    if (t.op == O_SHL || t.op == O_LSHR) && c != u64::MAX && c < bits as u64 {
        let x = ones_of(b, t.a, bits, depth - 1);
        return if t.op == O_SHL {
            x << c & all
        } else {
            x >> c
        };
    }
    if t.op == O_ZEXT && is_int(b.type_of(t.a)) && b.type_of(t.a) != T_I128 {
        return ones_of(b, t.a, type_bits(b.type_of(t.a), 8), depth - 1);
    }
    return all;
}

// `ones_of` looks through at most ONES_DEPTH instructions.
const ONES_DEPTH: u32 = 4;

/// How `t` of `b` moves the lanes of a 16-byte vector or a vector of 8 bytes, a `swizzle` of constant
/// indexes of one operand of its type: PERM_REV8 reverses the lanes within each 8 bytes, PERM_SWAP8 swaps
/// the two 8-byte halves, both reverse them all; 0 for another swizzle or another
/// instruction.
pub(package) fn lane_perm(b: &Body, t: Inst) u8 {
    if t.op != O_VOP || (t.aux & VOP_CODE) as u32 != core::OP_SIMD + core::SIMD_SWIZZLE as u32 || t.b != 1 || t.c == VNONE {
        return 0;
    }
    let n = lanes(t.ty);
    let nb = type_bytes(t.ty, 8);
    let eb = type_bytes(lane_type(t.ty), 8);
    if n < 2 || nb != 8 && nb != 16 || b.type_of(b.pool[t.a as usize]) != t.ty || b.pool[t.c as usize] != n {
        return 0;
    }
    // Lane `k` from `k ^ s`: `s` the lanes of 8 bytes less one within them, of 8 bytes across them.
    let m = 8 / eb;
    let s = b.pool[(t.c + 1) as usize];
    let rev = m > 1 && (s & m - 1) == m - 1;
    let swap = n > m && (s & ~(m - 1)) == n - m;
    let want = rev as u32 * (m - 1) | swap as u32 * (n - m);
    if !rev && !swap || s != want {
        return 0;
    }
    for k in 0..n {
        if b.pool[(t.c + 1 + k) as usize] != (k ^ s) {
            return 0;
        }
    }
    return rev as u8 * PERM_REV8 | swap as u8 * PERM_SWAP8;
}

/// `lane_perm`: the lanes reversed within each 8 bytes.
pub(package) const PERM_REV8: u8 = 1;
/// `lane_perm`: the two 8-byte halves swapped.
pub(package) const PERM_SWAP8: u8 = 2;

/// Whether `t` of `b` is a scalar float `fadd` of lanes 0 and 1 (in either order) of one float vector of two
/// lanes (`FOLD_LANE_PAIR`).
pub(package) const fn lane_pair(b: &Body, t: Inst) bool {
    if t.op != O_FADD || is_vec(t.ty) || !is_inst(t.a) || !is_inst(t.b) {
        return false;
    }
    let x = b.insts[t.a as usize];
    let y = b.insts[t.b as usize];
    return x.op == O_VEXTRACT && y.op == O_VEXTRACT && x.a == y.a && x.aux + y.aux == 1 && lanes(b.type_of(x.a)) == 2 && type_bytes(
        t.ty,
        8,
    ) >= 4;
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

// The bits of integer constant `v`, u64::MAX for a value that is no constant (or that constant).
/// The type of value index `x` of `b`: an instruction's, a block parameter's, else i8.
pub(package) const fn xty(b: &Body, x: u32) u8 {
    let ni = b.insts.len() as u32;
    if x < ni {
        return b.insts[x as usize].ty;
    }
    if x < ni + b.params.len() as u32 {
        return b.params[(x - ni) as usize];
    }
    return T_I8;
}

/// Whether symbol `s` of `b` (of package `p`) is a thread-local variable.
pub(package) const fn tls_sym(p: &Package, b: &Body, s: u32) bool {
    return p.syms[b.syms[s as usize] as usize].kind == SK_TLS;
}

/// Whether `v` of `b` (of package `p`) is an instruction value a generator recomputes at each use.
pub(package) const fn remat_inst(p: &Package, b: &Body, v: Value) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    return t.op == O_ICONST || t.op == O_FCONST || t.op == O_SLOTADDR || t.op == O_SYMADDR && !tls_sym(p, b, t.a);
}

// How deep `fits_low` looks through operations.
const FITS_DEPTH: u32 = 4;

// The mask of integer type `t`'s bits: all of a 64-bit one's.
const fn type_mask(t: u8) u64 {
    let n = type_bits(t, 4);
    return if n >= 64 {
        u64::MAX
    } else {
        (1u64 << n as u64) - 1
    };
}

// Whether every value integer `v` of `b` (of up to 32 bits) takes is at most low-bit mask `m`, as a
// constant, a zero extension, an `and`, a right shift, a remainder or quotient by a constant, or a select
// shows it, `depth` instructions deep.
fn fits_low(b: &Body, v: Value, m: u64, depth: u32) bool {
    let ty = b.type_of(v);
    if type_bits(ty, 4) > 32 {
        return false;
    }
    let tm = type_mask(ty);
    if tm <= m {
        return true;
    }
    if (v & (VPARAM | VFLAG)) != 0 || depth == 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op == O_ICONST {
        return (int_const(b, v) & tm) <= m;
    }
    if t.op == O_ZEXT || t.op == O_UDIV && int_const(b, t.b) != u64::MAX {
        return fits_low(b, t.a, m, depth - 1);
    }
    if t.op == O_AND {
        return fits_low(b, t.a, m, depth - 1) || fits_low(b, t.b, m, depth - 1);
    }
    if t.op == O_SELECT {
        return fits_low(b, t.b, m, depth - 1) && fits_low(b, t.c, m, depth - 1);
    }
    if t.op != O_LSHR && t.op != O_UREM {
        return false;
    }
    let k = int_const(b, t.b);
    if t.op == O_LSHR && k < type_bits(ty, 4) as u64 {
        return tm >> k <= m || fits_low(b, t.a, m, depth - 1);
    }
    return t.op == O_UREM && (k & tm) != 0 && ((k & tm) - 1 <= m || fits_low(b, t.a, m, depth - 1));
}

// Whether `side`, a truncation of a 16- or 32-bit integer to 8 or 16 bits, is the side of a select on
// condition `c` that the select takes only where `c` bounds the truncated value within the narrow type
// (true side `on_true`): the side is that value, whatever the truncation clears.
fn bounded_side(b: &Body, c: Value, side: Value, on_true: bool) bool {
    if ((c | side) & (VPARAM | VFLAG)) != 0 || b.insts[side as usize].op != O_TRUNC || b.insts[c as usize].op != O_ICMP {
        return false;
    }
    let s = b.insts[side as usize];
    let q = b.insts[c as usize];
    let k = int_const(b, q.b);
    let ft = b.type_of(q.a);
    if q.a != s.a || k == u64::MAX || ft != T_I16 && ft != T_I32 {
        return false;
    }
    let m = type_mask(s.ty);
    let kk = k & type_mask(ft);
    // Taken when the value is at most `m`: true below or at, false above.
    if on_true {
        return q.aux == C_ULT && kk <= m + 1 || q.aux == C_ULE && kk <= m;
    }
    return q.aux == C_UGT && kk <= m || q.aux == C_UGE && kk <= m + 1;
}

/// Whether `v` of `b` is an integer constant; its bits in `out`.
pub(package) const fn const_of(b: &Body, v: Value, out: &mut u64) bool {
    if (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op != O_ICONST {
        return false;
    }
    *out = t.b as u64 << 32 | t.a as u64;
    return true;
}

/// The amount every lane of vector shift `t` of `b` (integer lanes) shifts by, when one constant below the
/// lanes' width: a splat of an integer constant, or a wide constant of equal lanes. NONE when not.
pub(package) fn vec_shift_amount(b: &Body, t: Inst) u32 {
    let lt = lane_type(t.ty);
    if !is_vec(t.ty) || !is_int(lt) || (t.b & (VPARAM | VFLAG)) != 0 || t.b == VNONE {
        return NONE;
    }
    let a = b.insts[t.b as usize];
    let bits = 8 * type_bytes(lt, 8) as u64;
    let m = if bits == 64 {
        ~0u64
    } else {
        (1u64 << bits) - 1
    };
    let mut k: u64 = 0;
    if a.op == O_SPLAT && const_of(b, a.a, &mut k) {
        k &= m;
    } else if a.op == O_WCONST {
        k = b.words[a.a as usize] & m;
        for q in 0..a.b {
            let x = b.words[(a.a + q) as usize];
            for l in 0..64 / bits {
                if (x >> l * bits & m) != k {
                    return NONE;
                }
            }
        }
    } else {
        return NONE;
    }
    return if k < bits {
        k as u32
    } else {
        NONE
    };
}

/// Whether instruction `i` of `b` (of package `p`, liveness `lv`) leads only to its block's `unreachable`:
/// every instruction after it reads values a generator recomputes. `uses` is scratch.
pub(package) fn dead_end(p: &Package, b: &Body, lv: &Live, i: usize, uses: &mut Vector<Value>) bool {
    let bk = b.blocks[lv.def_blk[i] as usize];
    let end = (bk.start + bk.len - 1) as usize;
    if b.insts[end].op != O_UNREACHABLE {
        return false;
    }
    for j in i + 1..end {
        each_use(b, b.insts[j], uses);
        for u in 0..uses.len() {
            if !remat_inst(p, b, uses[u]) {
                return false;
            }
        }
    }
    return true;
}

// Whether `v` is a vector of zeros: a splat of 0 or a wide constant of zero words.
fn zero_vec(b: &Body, v: Value) bool {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 {
        return false;
    }
    let t = b.insts[v as usize];
    if t.op == O_SPLAT {
        return int_const(b, t.a) == 0;
    }
    if t.op != O_WCONST {
        return false;
    }
    for k in t.a..t.a + t.b {
        if b.words[k as usize] != 0 {
            return false;
        }
    }
    return true;
}

fn int_const(b: &Body, v: Value) u64 {
    if v == VNONE || (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST {
        return u64::MAX;
    }
    let t = b.insts[v as usize];
    return t.a as u64 | t.b as u64 << 32;
}
