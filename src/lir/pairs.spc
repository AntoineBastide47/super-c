// Splitting of 128-bit integers into pairs of 64-bit words, for the native backends of arm64 and x86-64
// (`Package.pairs`), which hold an i128 in memory: each i128 value becomes its low and high words, two
// i64 values the register allocator keeps in registers, and each operation on it the operations on the
// words (LLVM's expansion of integer types wider than the registers). A sum carries through an unsigned
// comparison of the low words; a product takes the high half of the low words' product (`O_MULHU`) and
// the two cross products; a shift by an amount below 128 selects between the shifts within the words and
// the ones across them; an order compares the high words and, where they are equal, the low ones
// unsigned. A load and a store access the two words little-endian, as both targets are.
//
// The entry's parameters and a call's result stay i128 (a calling convention passes an i128 in two
// registers, which the backend reads from memory) and truncations split them; a call's argument, a
// return, a division and every other operation without a word form take the value joined again. The body
// is rebuilt in reverse postorder, so each value is split before its uses; an unreached block becomes
// `unreachable`.
import lir::ir as *;
import lir::verify as lv;

pub(package) struct Pairs {
    ni: usize, // the old body's instruction count: value `ni + p` is parameter p
    lo: Vector<Value>, // per old value (instructions, then parameters): its new value, an i128's low word
    hi: Vector<Value>, // an i128's high word; VNONE for any other value
    whole: Vector<Value>, // an i128 the new body holds whole (an entry parameter, a call's result), else VNONE
    args: Vector<Value>, // an edge's or a list's new values
    edges: Vector<u32>, // a switch's new edges
    types: Vector<u8>, // a block's new parameter types
    w64: u32, // the `words` index of the 128-bit constant 64 in the new body, NONE until made
}

extend Pairs {
    pub(package) fn new() Pairs {
        return Pairs {
            ni: 0,
            lo: Vector::<Value>::new(),
            hi: Vector::<Value>::new(),
            whole: Vector::<Value>::new(),
            args: Vector::<Value>::new(),
            edges: Vector::<u32>::new(),
            types: Vector::<u8>::new(),
            w64: NONE,
        };
    }

    /// Split the i128 values of `b`, which holds one (`has_i128`) and is not naked, whose reached blocks
    /// are `order` in reverse postorder (`rpo`: per block, its position there, NONE when unreached), into
    /// `out`.
    pub(package) fn run(self: &mut Self, b: &Body, order: []u32, rpo: []u32, out: &mut Body) {
        let ni = b.insts.len();
        let np = b.params.len();
        self.ni = ni;
        fill(&mut self.lo, ni + np, VNONE);
        fill(&mut self.hi, ni + np, VNONE);
        fill(&mut self.whole, ni + np, VNONE);
        self.w64 = NONE;
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
        // The blocks, an i128 parameter of a block but the entry as its two words.
        for k in 0..b.blocks.len() {
            let bk = b.blocks[k];
            self.types.truncate(0);
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                let t = b.params[q as usize];
                if t == T_I128 && k != 0 {
                    self.types.push(T_I64);
                    self.types.push(T_I64);
                } else {
                    self.types.push(t);
                }
            }
            let nk = out.add_block(&self.types) as usize;
            out.blocks.index_mut(nk).flags = bk.flags;
            let mut p = out.blocks[nk].param_start;
            for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                let x = ni + q as usize;
                self.lo[x] = VPARAM | p;
                if b.params[q as usize] == T_I128 && k != 0 {
                    self.hi[x] = VPARAM | p + 1;
                    p += 2;
                } else {
                    if b.params[q as usize] == T_I128 {
                        self.whole[x] = VPARAM | p;
                    }
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
            if k == 0 {
                // The entry's i128 parameters split.
                for q in bk.param_start..bk.param_start + bk.param_len as u32 {
                    let x = ni + q as usize;
                    if b.params[q as usize] == T_I128 {
                        let v = self.whole[x];
                        self.lo[x] = self.un(b, out, bk.start, O_TRUNC, T_I64, v);
                        self.hi[x] = self.high(b, out, bk.start, v);
                    }
                }
            }
            for i in bk.start..bk.start + bk.len {
                self.inst(b, out, i);
            }
        }
        // A scope's root, renumbered; one in no reached block goes.
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            let v = self.val(sc.root);
            if v != VNONE {
                out.scopes.push(Scope { site: sc.site, group: sc.group, root: v });
            }
        }
    }

    // The value index of `v` in `lo`, `hi` and `whole`.
    const fn ix(self: &Self, v: Value) usize {
        if (v & VPARAM) != 0 {
            return self.ni + (v & ~VPARAM) as usize;
        }
        return (v & ~VFLAG) as usize;
    }

    // The new value of `v` (an i128's low word).
    const fn val(self: &Self, v: Value) Value {
        if v == VNONE {
            return VNONE;
        }
        if (v & VFLAG) != 0 {
            return VFLAG | self.lo[self.ix(v)];
        }
        return self.lo[self.ix(v)];
    }

    // The new value of `v` as an operation without a word form reads it: an i128 whole.
    fn arg(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value) Value {
        if v == VNONE || (v & VFLAG) != 0 || b.type_of(v) != T_I128 {
            return self.val(v);
        }
        let x = self.ix(v);
        if self.whole[x] != VNONE {
            return self.whole[x];
        }
        // `hi << 64 | lo`, made at each use: the use's block need not be dominated by another use's.
        let zl = self.un(b, out, i, O_ZEXT, T_I128, self.lo[x]);
        let zh = self.un(b, out, i, O_ZEXT, T_I128, self.hi[x]);
        let sh = self.bin(b, out, i, O_SHL, T_I128, zh, self.c64(b, out, i));
        return self.bin(b, out, i, O_OR, T_I128, sh, zl);
    }

    // Append `t` at old instruction `i`'s location; its value.
    fn put(self: &Self, b: &Body, out: &mut Body, i: u32, t: Inst) Value {
        let v = out.emit(t, b.locs[i as usize]);
        if b.inl.len() != 0 {
            out.inl.push(b.inl[i as usize]);
        }
        return v;
    }

    fn un(self: &Self, b: &Body, out: &mut Body, i: u32, op: u8, ty: u8, a: Value) Value {
        return self.put(b, out, i, Inst { op: op, ty: ty, aux: 0, a: a, b: VNONE, c: VNONE });
    }

    fn bin(self: &Self, b: &Body, out: &mut Body, i: u32, op: u8, ty: u8, x: Value, y: Value) Value {
        return self.put(b, out, i, Inst { op: op, ty: ty, aux: 0, a: x, b: y, c: VNONE });
    }

    fn cmp(self: &Self, b: &Body, out: &mut Body, i: u32, c: u16, x: Value, y: Value) Value {
        return self.put(b, out, i, Inst { op: O_ICMP, ty: T_I8, aux: c, a: x, b: y, c: VNONE });
    }

    fn sel(self: &Self, b: &Body, out: &mut Body, i: u32, ty: u8, c: Value, x: Value, y: Value) Value {
        return self.put(b, out, i, Inst { op: O_SELECT, ty: ty, aux: 0, a: c, b: x, c: y });
    }

    // The i64 constant `k`.
    fn k64(self: &Self, b: &Body, out: &mut Body, i: u32, k: u64) Value {
        return self.put(b, out, i, Inst { op: O_ICONST, ty: T_I64, aux: 0, a: k as u32, b: (k >> 32) as u32, c: VNONE });
    }

    // The i128 constant 64.
    fn c64(self: &mut Self, b: &Body, out: &mut Body, i: u32) Value {
        if self.w64 == NONE {
            self.w64 = out.words.len() as u32;
            out.words.push(64);
            out.words.push(0);
        }
        return self.put(b, out, i, Inst { op: O_WCONST, ty: T_I128, aux: 0, a: self.w64, b: 2, c: VNONE });
    }

    // The high word of i128 `v` (a value of the new body).
    fn high(self: &mut Self, b: &Body, out: &mut Body, i: u32, v: Value) Value {
        let sh = self.bin(b, out, i, O_LSHR, T_I128, v, self.c64(b, out, i));
        return self.un(b, out, i, O_TRUNC, T_I64, sh);
    }

    // The new edge of edge `e` of instruction `i`: an i128 argument as its two words, but into the entry.
    fn edge(self: &mut Self, b: &Body, out: &mut Body, i: u32, e: u32) u32 {
        let tk = b.edge_target(e);
        let na = b.edge_nargs(e);
        let mut vs = Vector::<Value>::with_capacity(na as usize + 2);
        for q in 0..na {
            let a = b.edge_arg(e, q);
            if tk != 0 && (a & VFLAG) == 0 && b.type_of(a) == T_I128 {
                let x = self.ix(a);
                vs.push(self.lo[x]);
                vs.push(self.hi[x]);
            } else {
                vs.push(self.arg(b, out, i, a));
            }
        }
        return out.edge(tk, &vs);
    }

    // The new pool list of the `n` values at `at` of `b` (a call's arguments, a vector operation's or an
    // assembly statement's operands), each whole.
    fn list(self: &mut Self, b: &Body, out: &mut Body, i: u32, at: u32, n: u32) u32 {
        let mut vs = Vector::<Value>::with_capacity(n as usize);
        for q in 0..n {
            vs.push(self.arg(b, out, i, b.pool[(at + q) as usize]));
        }
        return out.pool_list(&vs);
    }

    // Instruction `i` of `b` into `out`.
    fn inst(self: &mut Self, b: &Body, out: &mut Body, i: u32) {
        let t = b.insts[i as usize];
        let x = i as usize;
        if self.words(b, out, i, t) {
            return;
        }
        let f = op_info(t.op).form;
        let mut u = t;
        if lv::operand_a(f) {
            u.a = self.arg(b, out, i, t.a);
        }
        if lv::operand_b(f) {
            u.b = self.arg(b, out, i, t.b);
        }
        if lv::operand_c(f) {
            u.c = self.arg(b, out, i, t.c);
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
        let v = self.put(b, out, i, u);
        self.lo[x] = v;
        if t.ty == T_I128 {
            // Kept whole (a call's result, a division): split for its uses.
            self.whole[x] = v;
            self.lo[x] = self.un(b, out, i, O_TRUNC, T_I64, v);
            self.hi[x] = self.high(b, out, i, v);
        }
    }

    // Instruction `i` (`t`) of `b` in words, when it has a word form: whether it did.
    fn words(self: &mut Self, b: &Body, out: &mut Body, i: u32, t: Inst) bool {
        let x = i as usize;
        let op = t.op;
        let wide = t.ty == T_I128;
        if op == O_TRUNC && b.type_of(t.a) == T_I128 {
            let l = self.lo[self.ix(t.a)];
            self.lo[x] = if t.ty == T_I64 {
                l
            } else {
                self.un(b, out, i, O_TRUNC, t.ty, l)
            };
            return true;
        }
        if op == O_ICMP && b.type_of(t.a) == T_I128 {
            let (al, ah) = (self.lo[self.ix(t.a)], self.hi[self.ix(t.a)]);
            let (bl, bh) = (self.lo[self.ix(t.b)], self.hi[self.ix(t.b)]);
            if t.aux == C_EQ || t.aux == C_NE {
                let d = self.bin(
                    b,
                    out,
                    i,
                    O_OR,
                    T_I64,
                    self.bin(b, out, i, O_XOR, T_I64, al, bl),
                    self.bin(b, out, i, O_XOR, T_I64, ah, bh),
                );
                self.lo[x] = self.cmp(b, out, i, t.aux, d, self.k64(b, out, i, 0));
                return true;
            }
            // The low words compare unsigned whatever the order's sign.
            let uc = if t.aux >= C_SLT && t.aux <= C_SGE {
                t.aux + 4
            } else {
                t.aux
            };
            let he = self.cmp(b, out, i, C_EQ, ah, bh);
            let lc = self.cmp(b, out, i, uc, al, bl);
            let hc = self.cmp(b, out, i, t.aux, ah, bh);
            self.lo[x] = self.sel(b, out, i, T_I8, he, lc, hc);
            return true;
        }
        if op == O_STORE && (t.b & VFLAG) == 0 && b.type_of(t.b) == T_I128 {
            if !word_access(t) {
                return false;
            }
            let a = self.val(t.a);
            let v = self.ix(t.b);
            let al = t.aux & ~15u16 | (t.aux & 15).min(3);
            let _ = self.put(b, out, i, Inst { op: O_STORE, ty: T_NONE, aux: al, a: a, b: self.lo[v], c: t.c });
            let _ = self.put(
                b,
                out,
                i,
                Inst { op: O_STORE, ty: T_NONE, aux: al, a: a, b: self.hi[v], c: (t.c as i32 + 8) as u32 },
            );
            return true;
        }
        if !wide {
            return false;
        }
        let mut l = VNONE;
        let mut h = VNONE;
        if op == O_WCONST {
            l = self.k64(b, out, i, b.words[t.a as usize]);
            h = self.k64(b, out, i, b.words[t.a as usize + 1]);
        } else if op == O_LOAD {
            if !word_access(t) {
                return false;
            }
            let a = self.val(t.a);
            let al = t.aux & ~15u16 | (t.aux & 15).min(3);
            l = self.put(b, out, i, Inst { op: O_LOAD, ty: T_I64, aux: al, a: a, b: VNONE, c: t.c });
            h = self.put(b, out, i, Inst { op: O_LOAD, ty: T_I64, aux: al, a: a, b: VNONE, c: (t.c as i32 + 8) as u32 });
        } else if op == O_ZEXT || op == O_SEXT {
            let a = self.val(t.a);
            l = if b.type_of(t.a) == T_I64 {
                a
            } else {
                self.un(b, out, i, op, T_I64, a)
            };
            h = if op == O_ZEXT {
                self.k64(b, out, i, 0)
            } else {
                self.bin(b, out, i, O_ASHR, T_I64, l, self.k64(b, out, i, 63))
            };
        } else if op == O_SELECT {
            let c = self.val(t.a);
            let (yl, yh) = (self.lo[self.ix(t.b)], self.hi[self.ix(t.b)]);
            let (zl, zh) = (self.lo[self.ix(t.c)], self.hi[self.ix(t.c)]);
            l = self.sel(b, out, i, T_I64, c, yl, zl);
            h = self.sel(b, out, i, T_I64, c, yh, zh);
        } else if op >= O_ADD && op <= O_NOT && op != O_SDIV && op != O_UDIV && op != O_SREM && op != O_UREM {
            let (al, ah) = (self.lo[self.ix(t.a)], self.hi[self.ix(t.a)]);
            if op == O_NOT {
                l = self.un(b, out, i, O_NOT, T_I64, al);
                h = self.un(b, out, i, O_NOT, T_I64, ah);
            } else if op == O_NEG {
                // -x: the low word negated; the high one negated, less 1 when the low word is not 0.
                l = self.un(b, out, i, O_NEG, T_I64, al);
                let nz = self.cmp(b, out, i, C_NE, al, self.k64(b, out, i, 0));
                let nw = self.un(b, out, i, O_ZEXT, T_I64, nz);
                h = self.bin(b, out, i, O_SUB, T_I64, self.un(b, out, i, O_NEG, T_I64, ah), nw);
            } else if op == O_SHL || op == O_LSHR || op == O_ASHR {
                let (l2, h2) = self.shift(b, out, i, op, al, ah, self.lo[self.ix(t.b)]);
                l = l2;
                h = h2;
            } else {
                let (bl, bh) = (self.lo[self.ix(t.b)], self.hi[self.ix(t.b)]);
                if op == O_ADD {
                    l = self.bin(b, out, i, O_ADD, T_I64, al, bl);
                    let c = self.un(b, out, i, O_ZEXT, T_I64, self.cmp(b, out, i, C_ULT, l, al));
                    h = self.bin(b, out, i, O_ADD, T_I64, self.bin(b, out, i, O_ADD, T_I64, ah, bh), c);
                } else if op == O_SUB {
                    l = self.bin(b, out, i, O_SUB, T_I64, al, bl);
                    let c = self.un(b, out, i, O_ZEXT, T_I64, self.cmp(b, out, i, C_ULT, al, bl));
                    h = self.bin(b, out, i, O_SUB, T_I64, self.bin(b, out, i, O_SUB, T_I64, ah, bh), c);
                } else if op == O_MUL {
                    // The low words' full product, plus the cross products shifted up by 64.
                    l = self.bin(b, out, i, O_MUL, T_I64, al, bl);
                    let p = self.bin(b, out, i, O_MULHU, T_I64, al, bl);
                    let q = self.bin(b, out, i, O_ADD, T_I64, p, self.bin(b, out, i, O_MUL, T_I64, al, bh));
                    h = self.bin(b, out, i, O_ADD, T_I64, q, self.bin(b, out, i, O_MUL, T_I64, ah, bl));
                } else {
                    l = self.bin(b, out, i, op, T_I64, al, bl);
                    h = self.bin(b, out, i, op, T_I64, ah, bh);
                }
            }
        } else {
            return false;
        }
        self.lo[x] = l;
        self.hi[x] = h;
        return true;
    }

    // `(l, h)` shifted by `n` (an i64 below 128) by shift operation `op`: within the words by `n & 63`,
    // the bits that cross between them through a shift by 1 and one by `63 - (n & 63)` (so 0 crosses
    // nothing), then, when `n` is 64 or more, the words moved over.
    fn shift(self: &mut Self, b: &Body, out: &mut Body, i: u32, op: u8, l: Value, h: Value, n: Value) (Value, Value) {
        let s = self.bin(b, out, i, O_AND, T_I64, n, self.k64(b, out, i, 63));
        let r = self.bin(b, out, i, O_XOR, T_I64, s, self.k64(b, out, i, 63));
        let big = self.cmp(
            b,
            out,
            i,
            C_NE,
            self.bin(b, out, i, O_AND, T_I64, n, self.k64(b, out, i, 64)),
            self.k64(b, out, i, 0),
        );
        let one = self.k64(b, out, i, 1);
        if op == O_SHL {
            let lw = self.bin(b, out, i, O_SHL, T_I64, l, s);
            let cross = self.bin(b, out, i, O_LSHR, T_I64, self.bin(b, out, i, O_LSHR, T_I64, l, one), r);
            let hw = self.bin(b, out, i, O_OR, T_I64, self.bin(b, out, i, O_SHL, T_I64, h, s), cross);
            let z = self.k64(b, out, i, 0);
            return (self.sel(b, out, i, T_I64, big, z, lw), self.sel(b, out, i, T_I64, big, lw, hw));
        }
        let hw = self.bin(b, out, i, op, T_I64, h, s);
        let cross = self.bin(b, out, i, O_SHL, T_I64, self.bin(b, out, i, O_SHL, T_I64, h, one), r);
        let lw = self.bin(b, out, i, O_OR, T_I64, self.bin(b, out, i, O_LSHR, T_I64, l, s), cross);
        let fill = if op == O_ASHR {
            self.bin(b, out, i, O_ASHR, T_I64, h, self.k64(b, out, i, 63))
        } else {
            self.k64(b, out, i, 0)
        };
        return (self.sel(b, out, i, T_I64, big, hw, lw), self.sel(b, out, i, T_I64, big, fill, hw));
    }
}

// Whether `b` has an i128 value.
pub(package) const fn has_i128(b: &Body) bool {
    for q in 0..b.params.len() {
        if b.params[q] == T_I128 {
            return true;
        }
    }
    for i in 0..b.insts.len() {
        if b.insts[i].ty == T_I128 {
            return true;
        }
    }
    return false;
}

// Whether i128 load or store `t` splits into two word accesses: not volatile, its second word's offset
// an i32.
const fn word_access(t: Inst) bool {
    return (t.aux & MEM_VOLATILE) == 0 && (t.c as i32) as i64 + 8 <= 0x7FFFFFFF;
}
