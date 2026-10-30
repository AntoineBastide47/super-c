// Splitting of vectors wider than a register into register-wide parts, for the native backends
// (`Package.vector`: the bytes of a register), which hold such a vector in memory and compute it chunk by
// chunk through it (LLVM's type legalization of vectors by splitting). A lane-wise operation of a wide
// vector (arithmetic, a square root, a fused multiply-add, a comparison, a select, a splat, a constant, a
// lane's insert or extraction, which touch one part, a `vop` that traps in no lane: lane rules, a shift by
// a scalar, a bitcast, an absolute difference, a lane mask's comparison and choice, an unchecked gather, a
// masked load or store through a pointer), its load and its store become one per part, each part
// `Package.vector` bytes of consecutive lanes, which the register allocator keeps in registers; a block
// parameter becomes one per part. A conversion of one width converts by parts, and an integer of a
// register widens to two parts or narrows from two (`conv_parts`). A lane mask of a `vop` comparison (an
// integer, bit i for lane i) splits as the parts' masks, its `and`, `or` and `xor` by parts; a use of the
// whole mask joins them by shifts.
//
// An entry parameter, a call's or a vector operation's result and every operation without a part form keep
// the vector whole: a use that needs parts stores the whole vector to a slot of its own and loads the parts
// back, and a use that needs the whole stores the parts there and loads it, each at the use (its block
// need not be dominated by another use's). The body is rebuilt in reverse postorder, so each value is
// split before its uses; an unreached block becomes `unreachable`.
import lir::ir as *;
import lir::verify as lv;
import ir::core as core;
import ast::ast as ast;

pub(package) struct Wide {
    ni: usize, // the old body's instruction count: value `ni + p` is parameter p
    rb: u32, // the bytes of a part
    val: Vector<Value>, // per old value (instructions, then parameters): its new value, NONE when split
    at: Vector<u32>, // per split old value: its first part in `parts`, NONE when whole
    parts: Vector<Value>,
    slot: Vector<u32>, // per wide old value, its slot for joins and splits, NONE until made
    mask: Vector<u32>, // per split old lane mask: its part count << 16 | the lanes of a part; else 0
    tmp: Vector<Value>, // one operand's parts (`parts_of`)
    types: Vector<u8>, // a block's new parameter types
}

extend Wide {
    pub(package) fn new() Wide {
        return Wide {
            ni: 0,
            rb: 0,
            val: Vector::<Value>::new(),
            at: Vector::<u32>::new(),
            parts: Vector::<Value>::new(),
            slot: Vector::<u32>::new(),
            mask: Vector::<u32>::new(),
            tmp: Vector::<Value>::new(),
            types: Vector::<u8>::new(),
        };
    }

    /// Split the vectors of `b` wider than `rb` bytes, whose reached blocks are `order` in reverse
    /// postorder (`rpo`: per block, its position there, NONE when unreached), into `out`; false when `b`
    /// has none (`out` untouched).
    pub(package) fn run(self: &mut Self, b: &Body, rb: u32, order: []u32, rpo: []u32, out: &mut Body) bool {
        if b.naked || !has_wide(b, rb) {
            return false;
        }
        let ni = b.insts.len();
        let np = b.params.len();
        self.ni = ni;
        self.rb = rb;
        fill(&mut self.val, ni + np, VNONE);
        fill(&mut self.at, ni + np, NONE);
        fill(&mut self.slot, ni + np, NONE);
        fill(&mut self.mask, ni + np, 0);
        self.parts.truncate(0);
        out.clear();
        out.pool.extend_copy(&b.pool);
        out.words.extend_copy(&b.words);
        out.slots.extend_copy(&b.slots);
        out.syms.extend_copy(&b.syms);
        out.msgs.extend_copy(&b.msgs);
        out.lines.truncate(0);
        out.lines.extend_copy(&b.lines);
        out.sig = b.sig;
        out.refs.extend_copy(&b.refs);
        out.owned.extend_copy(&b.owned);
        out.bools = b.bools;
        out.naked = b.naked;
        // The blocks, a wide parameter of a block but the entry as its parts.
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            self.types.truncate(0);
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                let t = b.params[q as usize];
                if k != 0 && self.splits(t) {
                    for _ in 0..self.count(t) {
                        self.types.push(self.part_type(t));
                    }
                } else {
                    self.types.push(t);
                }
            }
            let nk = out.add_block(&self.types) as usize;
            out.blocks.index_mut(nk).flags = bk.flags;
            let mut p = out.blocks[nk].param_start;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                let x = ni + q as usize;
                let t = b.params[q as usize];
                if k != 0 && self.splits(t) {
                    self.at[x] = self.parts.len() as u32;
                    for j in 0..self.count(t) {
                        self.parts.push(VPARAM | p + j);
                    }
                    p += self.count(t);
                } else {
                    self.val[x] = VPARAM | p;
                    p += 1;
                }
            }
        }
        for k in 0..b.blocks.len() {
            if rpo[k] == NONE {
                out.begin(k as u32);
                let _ = self.put(
                    b,
                    out,
                    b.blocks[k].start,
                    Inst { op: O_UNREACHABLE, ty: T_NONE, aux: 0, a: VNONE, b: VNONE, c: VNONE },
                );
            }
        }
        for n in 0..order.len() {
            let k = order[n];
            let bk = b.blocks[k as usize];
            out.begin(k);
            for i in bk.start..bk.start + bk.len {
                self.inst(b, out, i);
            }
        }
        // A scope's root, renumbered; one in no reached block goes.
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            let v = self.val[self.ix(sc.root)];
            if v != VNONE {
                out.scopes.push(Scope { site: sc.site, group: sc.group, root: v });
            }
        }
        return true;
    }

    // Whether a value of type `t` splits: a vector of a multiple of `rb` bytes past `rb`, with a lane count
    // its part count divides.
    const fn splits(self: &Self, t: u8) bool {
        return wide_type(t, self.rb);
    }

    // The parts of a vector of type `t` (`splits`).
    const fn count(self: &Self, t: u8) u32 {
        return type_bytes(t, 8) / self.rb;
    }

    // The type of a part of a vector of type `t` (`splits`).
    const fn part_type(self: &Self, t: u8) u8 {
        return vec_type(lane_type(t), lanes(t) / self.count(t));
    }

    // The value index of `v` in `val` and `at`.
    const fn ix(self: &Self, v: Value) usize {
        if (v & VPARAM) != 0 {
            return self.ni + (v & ~VPARAM) as usize;
        }
        return (v & ~VFLAG) as usize;
    }

    // Append `t` at old instruction `i`'s location; its value.
    fn put(self: &Self, b: &Body, out: &mut Body, i: u32, t: Inst) Value {
        let v = out.emit(t, b.locs[i as usize]);
        if b.inl.len() != 0 {
            out.inl.push(b.inl[i as usize]);
        }
        return v;
    }

    // The slot through which wide value `v` (of type `t`) joins or splits: aligned to a part, made once.
    fn slot_of(self: &mut Self, out: &mut Body, v: Value, t: u8) u32 {
        let x = self.ix(v);
        if self.slot[x] == NONE {
            self.slot[x] = out.slot(type_bytes(t, 8), self.rb.trailing_zeros() as u8);
        }
        return self.slot[x];
    }

    // The new value of `v` whole: a split one's parts stored to its slot, loaded as one.
    fn whole(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value) Value {
        if v == VNONE {
            return v;
        }
        // An operation's flag: the flag of its new instruction.
        if (v & VFLAG) != 0 {
            return VFLAG | self.val[self.ix(v)];
        }
        let x = self.ix(v);
        if self.at[x] == NONE {
            return self.val[x];
        }
        let t = b.type_of(v);
        if !is_vec(t) {
            // A lane mask: part j's bits from bit j * lanes on.
            let n = self.mask[x] >> 16;
            let l = self.mask[x] & 0xFFFF;
            let mut acc = VNONE;
            for j in 0..n {
                let mut pv = self.parts[(self.at[x] + j) as usize];
                if out.type_of(pv) != t {
                    pv = self.put(b, out, i, Inst { op: O_ZEXT, ty: t, aux: 0, a: pv, b: VNONE, c: VNONE });
                }
                if j != 0 {
                    let k = self.put(b, out, i, Inst { op: O_ICONST, ty: t, aux: 0, a: j * l, b: 0, c: VNONE });
                    pv = self.put(b, out, i, Inst { op: O_SHL, ty: t, aux: 0, a: pv, b: k, c: VNONE });
                    pv = self.put(b, out, i, Inst { op: O_OR, ty: t, aux: 0, a: acc, b: pv, c: VNONE });
                }
                acc = pv;
            }
            return acc;
        }
        let s = self.slot_of(out, v, t);
        let a = self.put(b, out, i, Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: VNONE, c: VNONE });
        let al = self.rb.trailing_zeros() as u16;
        for j in 0..self.count(t) {
            let pv = self.parts[(self.at[x] + j) as usize];
            let _ = self.put(b, out, i, Inst { op: O_STORE, ty: T_NONE, aux: al, a: a, b: pv, c: j * self.rb });
        }
        return self.put(b, out, i, Inst { op: O_LOAD, ty: t, aux: al, a: a, b: VNONE, c: 0 });
    }

    // The new parts of wide `v` into `tmp`: its own, or its whole value stored to its slot and loaded back
    // by parts; a splat's scalar in each part.
    fn parts_of(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value) {
        self.tmp.truncate(0);
        let x = self.ix(v);
        let t = b.type_of(v);
        if self.at[x] != NONE {
            for j in 0..self.count(t) {
                self.tmp.push(self.parts[(self.at[x] + j) as usize]);
            }
            return;
        }
        let s = self.slot_of(out, v, t);
        let a = self.put(b, out, i, Inst { op: O_SLOTADDR, ty: T_PTR, aux: 0, a: s, b: VNONE, c: VNONE });
        let al = self.rb.trailing_zeros() as u16;
        let _ = self.put(b, out, i, Inst { op: O_STORE, ty: T_NONE, aux: al, a: a, b: self.val[x], c: 0 });
        let pt = self.part_type(t);
        for j in 0..self.count(t) {
            let p = self.put(b, out, i, Inst { op: O_LOAD, ty: pt, aux: al, a: a, b: VNONE, c: j * self.rb });
            self.tmp.push(p);
        }
    }

    // The new edge of edge `e` of instruction `i`: a wide argument as its parts, but into the entry.
    fn edge(self: &mut Self, b: &Body, out: &mut Body, i: u32, e: u32) u32 {
        let tk = b.edge_target(e);
        let na = b.edge_nargs(e);
        let mut vs = Vector::<Value>::with_capacity(na as usize + 4);
        for q in 0..na {
            let a = b.edge_arg(e, q);
            if tk != 0 && (a & VFLAG) == 0 && self.splits(b.type_of(a)) {
                self.parts_of(b, out, i, a);
                vs.extend_copy(&self.tmp);
            } else {
                vs.push(self.whole(b, out, i, a));
            }
        }
        return out.edge(tk, &vs);
    }

    // The new pool list of the `n` values at `at` of `b`, each whole.
    fn list(self: &mut Self, b: &Body, out: &mut Body, i: u32, at: u32, n: u32) u32 {
        let mut vs = Vector::<Value>::with_capacity(n as usize);
        for q in 0..n {
            vs.push(self.whole(b, out, i, b.pool[(at + q) as usize]));
        }
        return out.pool_list(&vs);
    }

    // Conversion `t` by parts: of a vector and a result of one width part by part; an integer of a
    // register to twice its width as two parts, each the source's low or high lanes interleaved
    // (`vziplo`, `vziphi`) with zeros or with their signs (a lane comparison with 0), which as the wider
    // lanes are the extended values; an integer of two parts to half its width in a register, the even
    // narrower lanes of the parts (`vunzip`), which are the wider lanes' low halves. Whether it applied.
    fn conv_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let op = t.op;
        let ft = b.type_of(t.a);
        let ws = self.splits(ft);
        let wd = self.splits(t.ty);
        let fb = type_bytes(ft, 8);
        let tb = type_bytes(t.ty, 8);
        let first = self.parts.len() as u32;
        if ws && wd && fb == tb {
            let n = self.count(t.ty);
            let pt = self.part_type(t.ty);
            self.parts_of(b, out, i, t.a);
            for j in 0..n {
                let pv = self.tmp[j as usize];
                let p = self.put(b, out, i, Inst { op: op, ty: pt, aux: t.aux, a: pv, b: VNONE, c: VNONE });
                self.parts.push(p);
            }
            self.at[i as usize] = first;
            return true;
        }
        if (op == O_SEXT || op == O_ZEXT) && !ws && wd && fb == self.rb && tb == 2 * fb {
            let s = self.whole(b, out, i, t.a);
            let fl = lane_type(ft);
            let z = self.put(b, out, i, Inst { op: O_ICONST, ty: fl, aux: 0, a: 0, b: 0, c: VNONE });
            let mut hi = self.put(b, out, i, Inst { op: O_SPLAT, ty: ft, aux: 0, a: z, b: VNONE, c: VNONE });
            if op == O_SEXT {
                hi = self.put(b, out, i, Inst { op: O_VCMP, ty: mask_type(ft), aux: C_SLT, a: s, b: hi, c: 0 });
            }
            let pt = self.part_type(t.ty);
            for zop in [O_VZIPLO, O_VZIPHI] {
                let zv = self.put(b, out, i, Inst { op: zop, ty: ft, aux: 0, a: s, b: hi, c: VNONE });
                let p = self.put(b, out, i, Inst { op: O_BITCAST, ty: pt, aux: 0, a: zv, b: VNONE, c: VNONE });
                self.parts.push(p);
            }
            self.at[i as usize] = first;
            return true;
        }
        if op == O_TRUNC && ws && !wd && tb == self.rb && fb == 2 * tb {
            self.parts_of(b, out, i, t.a);
            let p0 = self.put(b, out, i, Inst { op: O_BITCAST, ty: t.ty, aux: 0, a: self.tmp[0], b: VNONE, c: VNONE });
            let p1 = self.put(b, out, i, Inst { op: O_BITCAST, ty: t.ty, aux: 0, a: self.tmp[1], b: VNONE, c: VNONE });
            self.val[i as usize] = self.put(b, out, i, Inst { op: O_VUNZIP, ty: t.ty, aux: 0, a: p0, b: p1, c: VNONE });
            return true;
        }
        return false;
    }

    // Instruction `i` of `b` into `out`.
    fn inst(self: &mut Self, b: &Body, out: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        if self.by_parts(b, out, i, t) {
            return;
        }
        let f = op_info(t.op).form;
        let mut u = t;
        if lv::operand_a(f) {
            u.a = self.whole(b, out, i, t.a);
        }
        if lv::operand_b(f) {
            u.b = self.whole(b, out, i, t.b);
        }
        if lv::operand_c(f) {
            u.c = self.whole(b, out, i, t.c);
        }
        if f == F_CALL || f == F_CALLIND {
            u.c = self.list(b, out, i, t.c, t.aux);
        } else if f == F_VOP || f == F_ASM {
            u.a = self.list(b, out, i, t.a, t.b);
        } else if f == F_JMP {
            u.a = self.edge(b, out, i, t.a);
        } else if f == F_BR {
            u.b = self.edge(b, out, i, t.b);
            u.c = self.edge(b, out, i, t.c);
        } else if f == F_SWITCH {
            let mut es = Vector::<u32>::with_capacity(t.aux as usize + 1);
            for q in 0..t.aux as u32 + 1 {
                es.push(self.edge(b, out, i, b.switch_edge(t, q)));
            }
            u.c = out.pool_list(&es);
        }
        self.val[i as usize] = self.put(b, out, i, u);
    }

    // Operand `v` of an operation by `n` parts into `ops`: its parts when wide, else itself `n` times.
    fn operand_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value, n: u32, ops: &mut Vector<Value>) {
        if (v & VFLAG) == 0 && self.splits(b.type_of(v)) {
            self.parts_of(b, out, i, v);
            ops.extend_copy(&self.tmp);
            return;
        }
        let w = self.whole(b, out, i, v);
        for _ in 0..n {
            ops.push(w);
        }
    }

    // Lane mask `v` as `n` parts of `l` lanes each into `ops`: its own when split so, else its whole value's
    // bits shifted down and kept to `l`.
    fn mask_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value, n: u32, l: u32, ops: &mut Vector<Value>) {
        let x = self.ix(v);
        if self.at[x] != NONE && self.mask[x] == (n << 16 | l) {
            for j in 0..n {
                ops.push(self.parts[(self.at[x] + j) as usize]);
            }
            return;
        }
        let w = self.whole(b, out, i, v);
        let t = b.type_of(v);
        let pt = mask_int(l);
        let low = self.put(
            b,
            out,
            i,
            Inst { op: O_ICONST, ty: pt, aux: 0, a: ((1u64 << l as u64) - 1) as u32, b: 0, c: VNONE },
        );
        for j in 0..n {
            let mut pv = w;
            if j != 0 {
                let k = self.put(b, out, i, Inst { op: O_ICONST, ty: t, aux: 0, a: j * l, b: 0, c: VNONE });
                pv = self.put(b, out, i, Inst { op: O_LSHR, ty: t, aux: 0, a: pv, b: k, c: VNONE });
            }
            if pt != t {
                pv = self.put(b, out, i, Inst { op: O_TRUNC, ty: pt, aux: 0, a: pv, b: VNONE, c: VNONE });
            }
            if l < type_bits(pt, 8) {
                pv = self.put(b, out, i, Inst { op: O_AND, ty: pt, aux: 0, a: pv, b: low, c: VNONE });
            }
            ops.push(pv);
        }
    }

    // `vop` `t` (instruction `i`) by parts, when its lanes split and no lane traps: a lane rule, a shift by
    // a scalar, a bitcast, a comparison (into a lane mask's parts), a choice by a lane mask. Whether it did.
    fn vop_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        let k = t.b;
        if t.c != VNONE || k == 0 || k > 4 {
            return false;
        }
        for q in 0..k {
            if (b.pool[(t.a + q) as usize] & VFLAG) != 0 {
                return false;
            }
        }
        let t0 = b.type_of(b.pool[t.a as usize]);
        let rule = if code >= core::OP_SIMD && code < core::OP_CMP_LANES {
            core::simd_op((code - core::OP_SIMD) as u8).rule
        } else {
            NONE as u8
        };
        let shift = (code == core::OP_SHL_SCALAR || code == core::OP_SHR_SCALAR) && k == 2 && t0 == t.ty && !is_vec(
            b.type_of(b.pool[(t.a + 1) as usize]),
        );
        let signed_abs = code == core::OP_SIMD + core::SIMD_ABS as u32 && !is_float(lane_type(t.ty)) && (t.aux & VOP_SIGNED) != 0;
        let mut same = true;
        for q in 0..k {
            same = same && b.type_of(b.pool[(t.a + q) as usize]) == t0;
        }
        // `abs_diff` gives lanes of its operands' width (unsigned).
        let ad = code == core::OP_SIMD + core::SIMD_ABS_DIFF as u32 && same && lanes(t0) == lanes(t.ty) && type_bytes(
            t0,
            8,
        ) == type_bytes(t.ty, 8);
        let vec = rule == core::SR_VEC && !signed_abs && same && t0 == t.ty || ad;
        let cmp = rule == core::SR_MASK && same && is_int(t.ty);
        let choose = rule == core::SR_CHOOSE && k == 3 && is_int(t0) && b.type_of(b.pool[(t.a + 1) as usize]) == t.ty && b.type_of(
            b.pool[(t.a + 2) as usize],
        ) == t.ty;
        let cast = rule == core::SR_BITCAST && k == 1 && self.splits(t0) && type_bytes(t0, 8) == type_bytes(t.ty, 8);
        // An unchecked gather (place, indexes, mask, fallback) reads each lane alone.
        let gather = code == core::OP_SIMD + core::SIMD_GATHER_UNCHECKED as u32 && k == 4 && !is_vec(t0) && lanes(
            b.type_of(b.pool[(t.a + 1) as usize]),
        ) == lanes(t.ty) && self.splits(b.type_of(b.pool[(t.a + 1) as usize])) && is_int(
            b.type_of(b.pool[(t.a + 2) as usize]),
        ) && b.type_of(b.pool[(t.a + 3) as usize]) == t.ty;
        let wt = if cmp {
            t0
        } else {
            t.ty
        };
        if !(shift || vec || cmp || choose || cast || gather) || !self.splits(wt) {
            return false;
        }
        let n = self.count(wt);
        let l = lanes(wt) / n;
        let pt = if cmp {
            mask_int(l)
        } else {
            self.part_type(t.ty)
        };
        // Operand q's part j at q * n + j.
        let mut ops = Vector::<Value>::with_capacity((k * n) as usize);
        for q in 0..k {
            let v = b.pool[(t.a + q) as usize];
            if choose && q == 0 || gather && q == 2 {
                self.mask_parts(b, out, i, v, n, l, &mut ops);
            } else {
                self.operand_parts(b, out, i, v, n, &mut ops);
            }
        }
        let first = self.parts.len() as u32;
        let mut vs = Vector::<Value>::with_capacity(k as usize);
        for j in 0..n as usize {
            vs.truncate(0);
            for q in 0..k as usize {
                vs.push(ops[q * n as usize + j]);
            }
            let list = out.pool_list(&vs);
            let p = self.put(b, out, i, Inst { op: O_VOP, ty: pt, aux: t.aux, a: list, b: k, c: VNONE });
            self.parts.push(p);
        }
        self.at[i as usize] = first;
        if cmp {
            self.mask[i as usize] = n << 16 | l;
        }
        return true;
    }

    // Masked load or store through a pointer `t` (instruction `i`: `load_masked_ptr`, `store_masked_ptr`;
    // pointer, mask, vector) by parts, each at its bytes: a part a constant mask sets whole is a plain
    // load or store, one it leaves out the fallback or nothing. Whether it did.
    fn masked_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let code = (t.aux & VOP_CODE) as u32;
        let ld = code == core::OP_SIMD + core::SIMD_LOAD_MASKED_PTR as u32;
        let st = code == core::OP_SIMD + core::SIMD_STORE_MASKED_PTR as u32;
        if !(ld || st) || t.b != 3 || t.c != VNONE {
            return false;
        }
        let pv = b.pool[t.a as usize];
        let m = b.pool[(t.a + 1) as usize];
        let v = b.pool[(t.a + 2) as usize];
        if ((pv | m | v) & VFLAG) != 0 || !self.splits(b.type_of(v)) {
            return false;
        }
        let vt = b.type_of(v);
        let n = self.count(vt);
        let l = lanes(vt) / n;
        let pt = self.part_type(vt);
        let full = (1u64 << l as u64) - 1;
        let km = if (m & VPARAM) == 0 && b.insts[m as usize].op == O_ICONST {
            Option::<u64>::Some(b.insts[m as usize].b as u64 << 32 | b.insts[m as usize].a as u64)
        } else {
            Option::<u64>::None
        };
        let base = self.whole(b, out, i, pv);
        let mut mp = Vector::<Value>::with_capacity(n as usize);
        if km.is_none() {
            self.mask_parts(b, out, i, m, n, l, &mut mp);
        }
        let mut vp = Vector::<Value>::with_capacity(n as usize);
        self.operand_parts(b, out, i, v, n, &mut vp);
        let first = self.parts.len() as u32;
        for j in 0..n {
            let bits = if km.is_some() {
                km.unwrap() >> (j * l) as u64 & full
            } else {
                1u64
            };
            let a = if j == 0 {
                base
            } else {
                self.put(b, out, i, Inst { op: O_PTRADD, ty: T_PTR, aux: 0, a: base, b: VNONE, c: j * self.rb })
            };
            let mut part = vp[j as usize];
            if km.is_some() && bits == full {
                if ld {
                    part = self.put(b, out, i, Inst { op: O_LOAD, ty: pt, aux: 0, a: a, b: VNONE, c: 0 });
                } else {
                    let _ = self.put(b, out, i, Inst { op: O_STORE, ty: T_NONE, aux: 0, a: a, b: part, c: 0 });
                }
            } else if km.is_none() || bits != 0 {
                let mk = if km.is_some() {
                    self.put(b, out, i, Inst { op: O_ICONST, ty: mask_int(l), aux: 0, a: bits as u32, b: 0, c: VNONE })
                } else {
                    mp[j as usize]
                };
                let list = out.pool_list([a, mk, part]);
                let r = self.put(
                    b,
                    out,
                    i,
                    Inst { op: O_VOP, ty: ast::pick(ld, pt, T_NONE), aux: t.aux, a: list, b: 3, c: VNONE },
                );
                if ld {
                    part = r;
                }
            }
            if ld {
                self.parts.push(part);
            }
        }
        if ld {
            self.at[i as usize] = first;
        }
        return true;
    }

    // `and`, `or` or `xor` `t` (instruction `i`) of a split lane mask by its parts. Whether it did.
    fn mask_op(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let mut m: u32 = 0;
        for v in [t.a, t.b] {
            if (v & VFLAG) == 0 && self.at[self.ix(v)] != NONE && self.mask[self.ix(v)] != 0 {
                m = self.mask[self.ix(v)];
            }
        }
        if m == 0 {
            return false;
        }
        let n = m >> 16;
        let l = m & 0xFFFF;
        let mut oa = Vector::<Value>::new();
        let mut ob = Vector::<Value>::new();
        self.mask_parts(b, out, i, t.a, n, l, &mut oa);
        self.mask_parts(b, out, i, t.b, n, l, &mut ob);
        let first = self.parts.len() as u32;
        for j in 0..n as usize {
            let p = self.put(b, out, i, Inst { op: t.op, ty: mask_int(l), aux: t.aux, a: oa[j], b: ob[j], c: VNONE });
            self.parts.push(p);
        }
        self.at[i as usize] = first;
        self.mask[i as usize] = m;
        return true;
    }

    // Instruction `i` (`t`) of `b` by parts, when it has a part form: whether it did.
    fn by_parts(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let op = t.op;
        if op == O_VOP {
            return self.masked_parts(b, out, i, t) || self.vop_parts(b, out, i, t);
        }
        if (op == O_AND || op == O_OR || op == O_XOR) && is_int(t.ty) {
            return self.mask_op(b, out, i, t);
        }
        // A lane of a split vector: the lane of its part; an insert replaces the lane in its part alone.
        if op == O_VEXTRACT && self.at[self.ix(t.a)] != NONE {
            let vt = b.type_of(t.a);
            let l = lanes(vt) / self.count(vt);
            let p = self.parts[(self.at[self.ix(t.a)] + t.aux as u32 / l) as usize];
            self.val[i as usize] = self.put(
                b,
                out,
                i,
                Inst { op: O_VEXTRACT, ty: t.ty, aux: (t.aux as u32 % l) as u16, a: p, b: VNONE, c: VNONE },
            );
            return true;
        }
        if op == O_VINSERT && self.splits(t.ty) {
            let n = self.count(t.ty);
            let l = lanes(t.ty) / n;
            let s = self.whole(b, out, i, t.b);
            let mut ops = Vector::<Value>::with_capacity(n as usize);
            self.operand_parts(b, out, i, t.a, n, &mut ops);
            let j = t.aux as u32 / l;
            ops[j as usize] = self.put(
                b,
                out,
                i,
                Inst {
                    op: O_VINSERT,
                    ty: self.part_type(t.ty),
                    aux: (t.aux as u32 % l) as u16,
                    a: ops[j as usize],
                    b: s,
                    c: VNONE,
                },
            );
            self.at[i as usize] = self.parts.len() as u32;
            self.parts.extend_copy(&ops);
            return true;
        }
        // A store of a split vector by parts; of a whole one whole.
        if op == O_STORE && (t.b & VFLAG) == 0 && self.splits(b.type_of(t.b)) && self.at[self.ix(t.b)] != NONE && (t.aux & MEM_VOLATILE) == 0 {
            let n = self.count(b.type_of(t.b));
            if (t.c as i32) as i64 + (n * self.rb) as i64 > 0x7FFFFFFF {
                return false;
            }
            let a = self.whole(b, out, i, t.a);
            self.parts_of(b, out, i, t.b);
            for j in 0..n {
                let pv = self.tmp[j as usize];
                let _ = self.put(
                    b,
                    out,
                    i,
                    Inst {
                        op: O_STORE,
                        ty: T_NONE,
                        aux: t.aux,
                        a: a,
                        b: pv,
                        c: (t.c as i32 + (j * self.rb) as i32) as u32,
                    },
                );
            }
            return true;
        }
        if op >= O_SEXT && op <= O_UITOFP && is_vec(t.ty) && (t.a & VFLAG) == 0 {
            return self.conv_parts(b, out, i, t);
        }
        if !self.splits(t.ty) {
            return false;
        }
        let n = self.count(t.ty);
        let pt = self.part_type(t.ty);
        let lane_op = op >= O_ADD && op <= O_NOT || op >= O_FADD && op <= O_FNEG || op == O_FSQRT || op == O_FMA || op == O_VCMP || op == O_VSEL || op == O_SELECT;
        let load = op == O_LOAD && (t.aux & MEM_VOLATILE) == 0 && (t.c as i32) as i64 + (n * self.rb) as i64 <= 0x7FFFFFFF;
        if !lane_op && !load && op != O_SPLAT && op != O_WCONST {
            return false;
        }
        let x = i as usize;
        let first = self.parts.len() as u32;
        if load {
            let a = self.whole(b, out, i, t.a);
            for j in 0..n {
                let p = self.put(
                    b,
                    out,
                    i,
                    Inst {
                        op: O_LOAD,
                        ty: pt,
                        aux: t.aux,
                        a: a,
                        b: VNONE,
                        c: (t.c as i32 + (j * self.rb) as i32) as u32,
                    },
                );
                self.parts.push(p);
            }
        } else if op == O_SPLAT {
            // One splat for every part.
            let s = self.whole(b, out, i, t.a);
            let p = self.put(b, out, i, Inst { op: O_SPLAT, ty: pt, aux: 0, a: s, b: VNONE, c: VNONE });
            for _ in 0..n {
                self.parts.push(p);
            }
        } else if op == O_WCONST {
            // Each part's lanes are consecutive words.
            let w = self.rb / 8;
            for j in 0..n {
                let p = self.put(b, out, i, Inst { op: O_WCONST, ty: pt, aux: 0, a: t.a + j * w, b: w, c: VNONE });
                self.parts.push(p);
            }
        } else {
            // A lane-wise operation: per part, of the operands' parts (a select's scalar condition whole).
            let f = op_info(op).form;
            let mut oa = Vector::<Value>::new();
            let mut ob = Vector::<Value>::new();
            let mut oc = Vector::<Value>::new();
            if lv::operand_a(f) && t.a != VNONE {
                self.operand_parts(b, out, i, t.a, n, &mut oa);
            }
            if lv::operand_b(f) && t.b != VNONE {
                self.operand_parts(b, out, i, t.b, n, &mut ob);
            }
            if lv::operand_c(f) && t.c != VNONE {
                self.operand_parts(b, out, i, t.c, n, &mut oc);
            }
            for j in 0..n as usize {
                let mut u = t;
                u.ty = if op == O_VCMP {
                    mask_type(self.part_type(b.type_of(t.a)))
                } else {
                    pt
                };
                if oa.len() != 0 {
                    u.a = oa[j];
                }
                if ob.len() != 0 {
                    u.b = ob[j];
                }
                if oc.len() != 0 {
                    u.c = oc[j];
                }
                let p = self.put(b, out, i, u);
                self.parts.push(p);
            }
        }
        self.at[x] = first;
        return true;
    }
}

// Whether type `t` is a vector of a multiple of `rb` bytes past `rb`, with a lane count its part count
// divides.
const fn wide_type(t: u8, rb: u32) bool {
    if !is_vec(t) {
        return false;
    }
    let n = type_bytes(t, 8);
    return n > rb && n % rb == 0 && lanes(t) % (n / rb) == 0;
}

// Whether `b` holds a vector wider than `rb` bytes that splits (`wide_type`).
fn has_wide(b: &Body, rb: u32) bool {
    for q in 0..b.params.len() {
        if wide_type(b.params[q], rb) {
            return true;
        }
    }
    for i in 0..b.insts.len() {
        if wide_type(b.insts[i].ty, rb) {
            return true;
        }
    }
    return false;
}

// The integer of a lane mask of `l` lanes (as the lowering's).
const fn mask_int(l: u32) u8 {
    if l <= 8 {
        return T_I8;
    }
    if l <= 16 {
        return T_I16;
    }
    if l <= 32 {
        return T_I32;
    }
    return T_I64;
}

fn fill(v: &mut Vector<u32>, n: usize, x: u32) {
    v.truncate(0);
    for _ in 0..n {
        v.push(x);
    }
}
