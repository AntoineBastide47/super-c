// Switch lowering for the native backends (LLVM's SwitchLowering, its jump tables aside). A switch whose
// edges all pass one block a constant each, the constants packed into 64 bits, is a table in a register
// (LLVM's bitmap lookup table): `x - lo <=u span` selects the constant shifted out of it, else the
// default's. Else the cases, sorted by value, form clusters of consecutive values that leave by one edge,
// each a range `x - lo <=u n`; a group of clusters within 64 values, of at most 3 edges that would take
// enough comparisons (`bit_testable`), is a bit test (`(mask >> (x - lo)) & 1` per edge, one block for one
// edge); more than LEAF clusters split by a comparison
// with the middle one's low value, a binary search. The tests are branches between new blocks. A switch of
// at most LEAF values that forms no range nor bit test stays: the backends' compare chain mispredicts less
// than a search on unpredictable values.
import lir::ir as *;

// A bit test spans fewer than BT_SPAN values.
const BT_SPAN: u64 = 64;
// At most LEAF clusters are tested one after another.
const LEAF: usize = 8;

// The values `lo` to `hi` (unsigned in the switched type) that leave by edge `e`.
struct Cl {
    lo: u64,
    hi: u64,
    e: u32,
}

/// Lower each `switch` of body `b` (pointers of `ptr` bytes) that has a range or more than LEAF values.
/// Whether any.
pub(package) fn lower(b: &mut Body, ptr: u32) bool {
    let nb = b.blocks.len();
    let mut any = false;
    for k in 0..nb {
        let bk = b.blocks[k];
        if bk.len != 0 && b.insts[(bk.start + bk.len - 1) as usize].op == O_SWITCH {
            any = lower_one(b, k as u32, ptr) || any;
        }
    }
    return any;
}

// The switch ending block `k` as a tree of tests (the module comment), when it has a range or more than
// LEAF values. Whether it did.
fn lower_one(b: &mut Body, k: u32, ptr: u32) bool {
    let bk = b.blocks[k as usize];
    let at = bk.start + bk.len - 1;
    let t = b.insts[at as usize];
    let ty = b.type_of(t.a);
    if !is_int(ty) || ty == T_I128 {
        return false;
    }
    let bits = type_bits(ty, ptr);
    let all = if bits >= 64 {
        u64::MAX
    } else {
        (1u64 << bits as u64) - 1
    };
    let n = t.aux as u32;
    let dflt = b.switch_edge(t, n);
    // Per value its first case's edge; a case that leaves as the default does needs no test.
    let mut first = Map::<u64, u32>::new();
    let mut vals = Vector::<u64>::new();
    for q in 0..n {
        let v = b.words[(t.b + q) as usize] & all;
        if first.get(&v).is_none() {
            first.insert(v, b.switch_edge(t, q));
            vals.push(v);
        }
    }
    vals.sort();
    let mut cls = Vector::<Cl>::new();
    let mut nv: usize = 0;
    for q in 0..vals.len() {
        let v = vals[q];
        let e = *first.get(&v).unwrap();
        if same_edge(b, e, dflt) {
            continue;
        }
        nv += 1;
        let m = cls.len();
        if m != 0 && cls[m - 1].hi + 1 == v && same_edge(b, cls[m - 1].e, e) {
            cls.index_mut(m - 1).hi = v;
        } else {
            cls.push(Cl { lo: v, hi: v, e: e });
        }
    }
    let sw = Sw {
        x: t.a,
        ty: ty,
        loc: b.locs[at as usize],
        inl: inl_of(b, at),
        flags: bk.flags & BLOCK_RARE,
        dflt: dflt,
    };
    let tab = table(b, &sw, &vals, &first, ptr);
    if tab != NONE {
        b.insts[at as usize] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: tab, b: 0, c: 0 };
        return true;
    }
    if cls.len() == nv && nv <= LEAF && nv != 0 && !bit_testable(b, &cls, 0, cls.len()) {
        return false;
    }
    let root = build(b, &sw, &cls, 0, cls.len(), 0, all);
    b.insts[at as usize] = Inst { op: O_JMP, ty: T_NONE, aux: 0, a: root, b: 0, c: 0 };
    return true;
}

// The edge into a register table for the switch `sw` of values `vals` (sorted), each leaving by edge
// `first[v]` (the module comment): every edge goes to one block of one integer parameter (directly, or
// through a block that only jumps there) and passes a constant, each case's in `w` bits (8, 16, 32), the
// cases from `base` (0 when it fits, else the least) packed into 64 bits. NONE when not.
fn table(b: &mut Body, sw: &Sw, vals: &Vector<u64>, first: &Map<u64, u32>, ptr: u32) u32 {
    let de = forward(b, sw.dflt);
    let j = b.edge_target(de);
    let n = vals.len();
    if n < 2 || b.blocks[j as usize].param_len != 1 || b.edge_nargs(de) != 1 {
        return NONE;
    }
    let rt = b.params[b.blocks[j as usize].param_start as usize];
    let dv = konst_of(b, b.edge_arg(de, 0));
    if !is_int(rt) || rt == T_I128 || dv.is_none() {
        return NONE;
    }
    let rbits = type_bits(rt, ptr);
    let rmask = if rbits >= 64 {
        u64::MAX
    } else {
        (1u64 << rbits as u64) - 1
    };
    let d = dv.unwrap() & rmask;
    let mut top = d;
    for q in 0..n {
        let e = forward(b, *first.get(&vals[q]).unwrap());
        if b.edge_target(e) != j {
            return NONE;
        }
        let c = konst_of(b, b.edge_arg(e, 0));
        if c.is_none() {
            return NONE;
        }
        top |= c.unwrap() & rmask;
    }
    let w: u64 = if top < 256 {
        8
    } else if top < 65536 {
        16
    } else if top >> 32 == 0 {
        32
    } else {
        64
    };
    let hi = vals[n - 1];
    let base = if (hi + 1) * w <= 64 {
        0u64
    } else {
        vals[0]
    };
    if (hi - base + 1) * w > 64 {
        return NONE;
    }
    // Each value of the span holds its case's constant, a hole the default's.
    let mut tab: u64 = 0;
    let mut q: usize = 0;
    for v in base..hi + 1 {
        let mut c = d;
        if q < n && vals[q] == v {
            c = konst_of(b, b.edge_arg(forward(b, *first.get(&v).unwrap()), 0)).unwrap() & rmask;
            q += 1;
        }
        tab |= c << (v - base) * w;
    }
    let k = open(b, sw);
    let mut x = sw.x;
    if base != 0 {
        let kb = konst(b, sw, sw.ty, base);
        x = emit(b, sw, Inst { op: O_SUB, ty: sw.ty, aux: 0, a: x, b: kb, c: 0 });
    }
    let ks = konst(b, sw, sw.ty, hi - base);
    let inr = emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: x, b: ks, c: 0 });
    let mut x64 = x;
    if sw.ty != T_I64 {
        x64 = emit(b, sw, Inst { op: O_ZEXT, ty: T_I64, aux: 0, a: x, b: VNONE, c: VNONE });
    }
    let lw = konst(b, sw, T_I64, w.trailing_zeros() as u64);
    let amt = emit(b, sw, Inst { op: O_SHL, ty: T_I64, aux: 0, a: x64, b: lw, c: 0 });
    // The amount within the width: the range test discards the constant past the table.
    let k63 = konst(b, sw, T_I64, 63);
    let am = emit(b, sw, Inst { op: O_AND, ty: T_I64, aux: 0, a: amt, b: k63, c: 0 });
    let kt = konst(b, sw, T_I64, tab);
    let mut r = emit(b, sw, Inst { op: O_LSHR, ty: T_I64, aux: 0, a: kt, b: am, c: 0 });
    if w < 64 && w < rbits as u64 {
        let km = konst(b, sw, T_I64, (1u64 << w) - 1);
        r = emit(b, sw, Inst { op: O_AND, ty: T_I64, aux: 0, a: r, b: km, c: 0 });
    }
    if rt != T_I64 {
        r = emit(b, sw, Inst { op: O_TRUNC, ty: rt, aux: 0, a: r, b: VNONE, c: VNONE });
    }
    let kd = b.edge_arg(de, 0);
    let s = emit(b, sw, Inst { op: O_SELECT, ty: rt, aux: 0, a: inr, b: r, c: kd });
    let out = b.edge(j, [s]);
    let _ = emit(b, sw, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: out, b: 0, c: 0 });
    return b.edge(k, []);
}

// Edge `e` of `b`, or the jump of the block it enters when that block holds the jump alone and has no
// parameters.
fn forward(b: &Body, e: u32) u32 {
    let bk = b.blocks[b.edge_target(e) as usize];
    let t = b.insts[(bk.start + bk.len - 1) as usize];
    return if bk.len == 1 && bk.param_len == 0 && b.edge_nargs(e) == 0 && t.op == O_JMP {
        t.a
    } else {
        e
    };
}

// The bits of integer constant `v` of `b`, if it is one.
fn konst_of(b: &Body, v: Value) Option<u64> {
    if (v & (VPARAM | VFLAG)) != 0 || b.insts[v as usize].op != O_ICONST || b.insts[v as usize].ty == T_I128 {
        return None;
    }
    let t = b.insts[v as usize];
    return Some(t.b as u64 << 32 | t.a as u64);
}

// What every test of one switch reads: the switched value and its type, the switch's location and inline
// mark, the flags its blocks take, its default edge.
struct Sw {
    x: Value,
    ty: u8,
    loc: u32,
    inl: u32,
    flags: u16,
    dflt: u32,
}

// The inline mark of instruction `i` of `b`, 0 when the body has none.
fn inl_of(b: &Body, i: u32) u32 {
    return if b.inl.len() != 0 {
        b.inl[i as usize]
    } else {
        0
    };
}

// The edge into the tests of clusters `l` to `r` of `cls`, the switched value known to lie in `lo` to `hi`:
// the default's when there is none, a cluster's own when it covers that range, else a new block's.
fn build(b: &mut Body, sw: &Sw, cls: &Vector<Cl>, l: usize, r: usize, lo: u64, hi: u64) u32 {
    if l == r {
        return sw.dflt;
    }
    if r - l == 1 && cls[l].lo == lo && cls[l].hi == hi {
        return cls[l].e;
    }
    if bit_testable(b, cls, l, r) {
        return bit_test(b, sw, cls, l, r, lo, hi);
    }
    if r - l > LEAF {
        // Each step halves the clusters: at most 64 levels.
        let mid = l + (r - l) / 2;
        let pivot = cls[mid].lo;
        let left = build(b, sw, cls, l, mid, lo, pivot - 1);
        let right = build(b, sw, cls, mid, r, pivot, hi);
        let k = open(b, sw);
        let c = konst(b, sw, sw.ty, pivot);
        let lt = emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULT, a: sw.x, b: c, c: 0 });
        let _ = emit(b, sw, Inst { op: O_BR, ty: T_NONE, aux: 0, a: lt, b: left, c: right });
        return b.edge(k, []);
    }
    // One test per cluster, the widest first (the likeliest on spread values), the last falling to the
    // default.
    let mut order = StaticVector::<usize, LEAF>::new();
    for j in l..r {
        order.push(j);
    }
    order.as_mut_slice().sort_stable_by(
        |x: &usize, y: &usize| {
            let wx = cls[*x].hi - cls[*x].lo;
            let wy = cls[*y].hi - cls[*y].lo;
            return if wx > wy {
                -1
            } else if wx < wy {
                1
            } else {
                0
            };
        },
    );
    let mut next = sw.dflt;
    let mut j = r - l;
    while j > 0 {
        j -= 1;
        let c = cls[order[j]];
        let k = open(b, sw);
        let ok = if c.lo == c.hi {
            let kv = konst(b, sw, sw.ty, c.lo);
            emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_EQ, a: sw.x, b: kv, c: 0 })
        } else if c.lo == lo {
            let kv = konst(b, sw, sw.ty, c.hi);
            emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: sw.x, b: kv, c: 0 })
        } else if c.hi == hi {
            let kv = konst(b, sw, sw.ty, c.lo);
            emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_UGE, a: sw.x, b: kv, c: 0 })
        } else {
            let kl = konst(b, sw, sw.ty, c.lo);
            let d = emit(b, sw, Inst { op: O_SUB, ty: sw.ty, aux: 0, a: sw.x, b: kl, c: 0 });
            let kn = konst(b, sw, sw.ty, c.hi - c.lo);
            emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: d, b: kn, c: 0 })
        };
        let _ = emit(b, sw, Inst { op: O_BR, ty: T_NONE, aux: 0, a: ok, b: c.e, c: next });
        next = b.edge(k, []);
    }
    return next;
}

// Whether clusters `l` to `r` of `cls` are one bit test: more than one, spanning fewer than BT_SPAN values,
// whose tests one after another would take at least 3 comparisons for one edge, 5 for two, 6 for three
// (a range 2; LLVM's `isSuitableForBitTests`).
fn bit_testable(b: &Body, cls: &Vector<Cl>, l: usize, r: usize) bool {
    if r - l < 2 || cls[r - 1].hi - cls[l].lo >= BT_SPAN {
        return false;
    }
    let mut es = StaticVector::<u32, 4>::new();
    let mut ncmp: u32 = 0;
    for j in l..r {
        ncmp += if cls[j].lo == cls[j].hi {
            1u32
        } else {
            2u32
        };
        let mut seen = false;
        for q in 0..es.len() {
            seen = seen || same_edge(b, es[q], cls[j].e);
        }
        if !seen {
            if es.len() == 3 {
                return false;
            }
            es.push(cls[j].e);
        }
    }
    let n = es.len();
    return n == 1 && ncmp >= 3 || n == 2 && ncmp >= 5 || n == 3 && ncmp >= 6;
}

// The index in `es` of an edge the same as `e`, `es.len()` when none.
fn edge_index(b: &Body, es: &Vector<u32>, e: u32) usize {
    for q in 0..es.len() {
        if same_edge(b, es[q], e) {
            return q;
        }
    }
    return es.len();
}

// Clusters `l` to `r` of `cls` as a bit test: the offset from the first cluster's low value (from 0 when
// every value is below BT_SPAN), checked within the span (unless `lo` to `hi` is the span), then per edge a
// test of its bit in the edge's mask, the last edge none when the clusters cover the span.
fn bit_test(b: &mut Body, sw: &Sw, cls: &Vector<Cl>, l: usize, r: usize, lo: u64, hi: u64) u32 {
    let base = if cls[r - 1].hi < BT_SPAN {
        0u64
    } else {
        cls[l].lo
    };
    let span = cls[r - 1].hi - base;
    let mut es = Vector::<u32>::new();
    let mut masks = Vector::<u64>::new();
    let mut full = base == cls[l].lo;
    for j in l..r {
        let q = edge_index(b, &es, cls[j].e);
        if q == es.len() {
            es.push(cls[j].e);
            masks.push(0);
        }
        for v in cls[j].lo..cls[j].hi + 1 {
            masks[q] = masks[q] | 1u64 << v - base;
        }
        full = full && (j == l || cls[j - 1].hi + 1 == cls[j].lo);
    }
    let ranged = !(base == lo && base + span == hi);
    // One edge, not every value of the span: one block, `x - base <=u span` and its bit (the amount within
    // the width: the range test discards the bit past it).
    if es.len() == 1 && !full && ranged {
        let k = open(b, sw);
        let d = if base == 0 {
            sw.x
        } else {
            let kb = konst(b, sw, sw.ty, base);
            emit(b, sw, Inst { op: O_SUB, ty: sw.ty, aux: 0, a: sw.x, b: kb, c: 0 })
        };
        let ks = konst(b, sw, sw.ty, span);
        let inr = emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: d, b: ks, c: 0 });
        let mut d64 = d;
        if sw.ty != T_I64 {
            d64 = emit(b, sw, Inst { op: O_ZEXT, ty: T_I64, aux: 0, a: d, b: VNONE, c: VNONE });
        }
        let k63 = konst(b, sw, T_I64, 63);
        let am = emit(b, sw, Inst { op: O_AND, ty: T_I64, aux: 0, a: d64, b: k63, c: 0 });
        let km = konst(b, sw, T_I64, masks[0]);
        let sh = emit(b, sw, Inst { op: O_LSHR, ty: T_I64, aux: 0, a: km, b: am, c: 0 });
        let tr = emit(b, sw, Inst { op: O_TRUNC, ty: T_I8, aux: 0, a: sh, b: VNONE, c: VNONE });
        let one = konst(b, sw, T_I8, 1);
        let bit = emit(b, sw, Inst { op: O_AND, ty: T_I8, aux: 0, a: tr, b: one, c: 0 });
        let ok = emit(b, sw, Inst { op: O_AND, ty: T_I8, aux: 0, a: inr, b: bit, c: 0 });
        let _ = emit(b, sw, Inst { op: O_BR, ty: T_NONE, aux: 0, a: ok, b: es[0], c: sw.dflt });
        return b.edge(k, []);
    }
    // The tests' blocks, the last first; each reads the offset the entry block computes.
    let entry = b.add_block([]);
    let mut next = sw.dflt;
    let mut ne = es.len();
    if full {
        ne -= 1;
        next = es[ne];
    }
    let mut tests = Vector::<u32>::new();
    for _ in 0..ne {
        tests.push(b.add_block([]));
    }
    b.blocks.index_mut(entry as usize).flags = sw.flags;
    b.begin(entry);
    let d = if base == 0 {
        sw.x
    } else {
        let kb = konst(b, sw, sw.ty, base);
        emit(b, sw, Inst { op: O_SUB, ty: sw.ty, aux: 0, a: sw.x, b: kb, c: 0 })
    };
    let d64 = if sw.ty == T_I64 {
        d
    } else {
        emit(b, sw, Inst { op: O_ZEXT, ty: T_I64, aux: 0, a: d, b: VNONE, c: VNONE })
    };
    let first = if ne == 0 {
        next
    } else {
        b.edge(tests[0], [])
    };
    if !ranged {
        let _ = emit(b, sw, Inst { op: O_JMP, ty: T_NONE, aux: 0, a: first, b: 0, c: 0 });
    } else {
        let ks = konst(b, sw, sw.ty, span);
        let inr = emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_ULE, a: d, b: ks, c: 0 });
        let _ = emit(b, sw, Inst { op: O_BR, ty: T_NONE, aux: 0, a: inr, b: first, c: sw.dflt });
    }
    for q in 0..ne {
        b.blocks.index_mut(tests[q] as usize).flags = sw.flags;
        b.begin(tests[q]);
        let km = konst(b, sw, T_I64, masks[q]);
        let sh = emit(b, sw, Inst { op: O_LSHR, ty: T_I64, aux: 0, a: km, b: d64, c: 0 });
        let one = konst(b, sw, T_I64, 1);
        let bit = emit(b, sw, Inst { op: O_AND, ty: T_I64, aux: 0, a: sh, b: one, c: 0 });
        let zero = konst(b, sw, T_I64, 0);
        let c = emit(b, sw, Inst { op: O_ICMP, ty: T_I8, aux: C_NE, a: bit, b: zero, c: 0 });
        let after = if q + 1 < ne {
            b.edge(tests[q + 1], [])
        } else {
            next
        };
        let _ = emit(b, sw, Inst { op: O_BR, ty: T_NONE, aux: 0, a: c, b: es[q], c: after });
    }
    return b.edge(entry, []);
}

// A new block without parameters, begun, of the switch's flags.
fn open(b: &mut Body, sw: &Sw) u32 {
    let k = b.add_block([]);
    b.blocks.index_mut(k as usize).flags = sw.flags;
    b.begin(k);
    return k;
}

// Instruction `i` appended to the block begun last, at the switch's location and inline mark.
fn emit(b: &mut Body, sw: &Sw, i: Inst) Value {
    let v = b.emit(i, sw.loc);
    if b.inl.len() != 0 {
        b.inl.push(sw.inl);
    }
    return v;
}

// The integer constant `v` of type `ty`.
fn konst(b: &mut Body, sw: &Sw, ty: u8, v: u64) Value {
    return emit(b, sw, Inst { op: O_ICONST, ty: ty, aux: 0, a: v as u32, b: (v >> 32) as u32, c: VNONE });
}

// Whether edges `e` and `f` of `b` go to one block with the same arguments.
fn same_edge(b: &Body, e: u32, f: u32) bool {
    if b.edge_target(e) != b.edge_target(f) || b.edge_nargs(e) != b.edge_nargs(f) {
        return false;
    }
    for q in 0..b.edge_nargs(e) {
        if b.edge_arg(e, q) != b.edge_arg(f, q) {
            return false;
        }
    }
    return true;
}
