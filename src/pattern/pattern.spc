// The shared pattern compiler: one algorithm for usefulness, exhaustiveness,
// unreachable arms, and match lowering. Typed source patterns normalize into a flat constructor
// form (or-patterns expand into extra rows, cap-bounded); a classic specialization matrix answers
// usefulness queries; a decision tree drives Core IR match lowering so no place is retested after
// its constructor is known on a path.
//
// Reads go through the typed-facts boundary plus package/declaration structure only. Constructor
// completeness is decided from the constructors themselves: the distinct enum variants seen against
// the declared member count, booleans as a pair, tuples and structs as single constructors, and
// integer values and ranges (every spelling, limit and named constant, valued by the type checker in
// `Ast.pat_vals`) as intervals of the matched type: a column of them splits the type's domain at every
// bound, so each head covers a piece whole or not at all, and the pieces decide completeness,
// usefulness and the decision tree's edges. Strings, floats and every other literal are never
// complete; two of them are one constructor when they are spelled alike. A work budget bounds
// adversarial or-pattern expansion; on overflow every query answers conservatively (assume
// exhaustive, assume reachable).
import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::facts as facts;
import module::loader as loader;
import ir::layout as lay;

/// Normalized constructor kinds.
pub const PC_WILD: u8 = 0; // wildcard or a pure binding
/// Pattern constructor kinds (Pat.kind); PC_WILD is 0.
pub const PC_VARIANT: u8 = 1; // val = ordinal; decl = variant; subs = payload
pub const PC_BOOL: u8 = 2; // val = 0/1
pub const PC_INT: u8 = 3; // val = the value's bits
pub const PC_RANGE: u8 = 4; // valued (arity 0 or 1): val..=hi, bits; opaque (arity 2): keyed by node
pub const PC_TUPLE: u8 = 5; // subs = elements (single, always-complete constructor)
pub const PC_STRUCT: u8 = 6; // decl = struct; subs = every field in decl order (absent = wild)
pub const PC_OPAQUE: u8 = 7; // string/float literal: only a wildcard or the same spelling covers it

/// The absent pattern, path, or node index.
pub const P_NONE: u32 = 0xFFFFFFFF;

/// One normalized pattern node (flat pools; subs index `subs` which indexes `pats`).
pub struct NPat {
    pub kind: u8,
    pub uns: bool, // PC_INT/PC_RANGE: the values compare unsigned
    pub bits: u8, // PC_INT/PC_RANGE: the matched type's width
    pub val: i64,
    pub hi: i64, // PC_RANGE: the inclusive upper bound
    pub decl: DefId, // variant/struct declaration
    pub node: NodeId, // originating pattern node (bindings + diagnostics); NODE_NONE for a split piece
    pub sub_start: u32,
    pub sub_len: u32,
    pub arity: u32, // constructor arity (payload/field/element count); PC_RANGE: 0 = empty, 1 = valued, 2 = opaque
}

// One matrix row: a pattern per column plus its arm.
struct Row {
    pub start: u32, // into ctx.cols (NPat ids)
    pub len: u32,
    pub arm: u32,
}

/// The pattern-compiler context for one match: pools + budget.
pub struct PatCx {
    pub pkg: *const loader::Package,
    pub f: facts::TypedFacts,
    pub src: str<'static>,
    pub pats: Vector<NPat>,
    pub subs: Vector<u32>, // flat sub-pattern id pool
    cols: Vector<u32>, // flat row storage (NPat ids)
    rows: Vector<Row>,
    // Usefulness arena: matrices live as (start, len) row descriptors over a flat cell pool;
    // every recursion level appends behind a watermark and truncates on return, so a whole
    // query allocates only on first-capacity growth (the plan's flat-row requirement).
    mcells: Vector<u32>,
    mrows: Vector<u64>, // start << 32 | len
    seen: Vector<u32>, // distinct-head scratch, watermark-disciplined like the arenas
    cuts: Vector<i64>, // integer-column piece starts, watermark-disciplined like the arenas
    ptr32: bool, // usize and isize are 32-bit on the target
    // Decision-tree arena: rows over parallel pattern/occurrence cell pools, watermarked like the
    // usefulness arena.
    trows: Vector<Row>,
    tpats: Vector<u32>,
    toccs: Vector<u32>, // DtPath ids, parallel to tpats
    pub budget: u32, // remaining work units; 0 = overflow, answer conservatively
    pub overflow: bool,
    // A column holds constructors the tree cannot tell apart (literals whose spellings may name one
    // value, an unvalued integer): the match keeps sequential lowering.
    tree_refused: bool,
}

/// Decision-tree node kinds.
pub const DT_LEAF: u8 = 0; // arm chosen
/// Decision-tree node kinds (DtNode.kind); DT_LEAF is 0.
pub const DT_TEST: u8 = 1; // test `place` against edge constructors; default child otherwise
pub const DT_FAIL: u8 = 2; // no row matches (unreachable for exhaustive matches)

/// A scrutinee sub-place: the projection path a test or binding reads.
pub struct DtPath {
    pub parent: u32, // DtPath id; P_NONE = the scrutinee itself
    pub downcast: i64, // variant ordinal applied before the field, -1 = none
    pub vdecl: DefId, // the variant declaration for the downcast
    pub field: u32, // field/element ordinal after the (optional) downcast
    pub fdecl: NodeId, // resolved field decl for named fields; NODE_NONE for tuple elements
    pub pat: NodeId, // a pattern node whose checked type describes this sub-place
}

/// One outgoing edge of a DT_TEST: constructor -> child node.
pub struct DtEdge {
    pub pat: u32, // representative NPat id (its constructor identifies the edge)
    pub child: u32,
}

/// One decision-tree node: a leaf naming its arm, a test over a place with an edge range, or a
/// failure.
pub struct DtNode {
    pub kind: u8,
    pub arm: u32, // DT_LEAF
    pub place: u32, // DT_TEST: DtPath id
    pub edge_start: u32,
    pub edge_len: u32,
    pub default_child: u32, // DT_TEST: fallthrough child (P_NONE when the edge set is complete)
}

/// The lowering-facing result: nodes/edges/paths/bindings in flat pools; `root` enters the tree.
pub struct DecisionTree {
    pub nodes: Vector<DtNode>,
    pub edges: Vector<DtEdge>,
    pub paths: Vector<DtPath>,
    pub root: u32,
    pub ok: bool, // false: budget exceeded; the caller keeps sequential lowering
}

/// The smallest value of the integer type of width `bits`, as bits.
pub const fn dom_min(uns: bool, bits: u8) i64 {
    if uns {
        return 0;
    }
    return (1u64 << (bits - 1) as u64).wrapping_neg() as i64;
}

/// The largest value of the integer type of width `bits`, as bits.
pub const fn dom_max(uns: bool, bits: u8) i64 {
    if uns && bits == 64 {
        return 0xFFFFFFFFFFFFFFFFu64 as i64;
    }
    if uns {
        return ((1u64 << bits as u64) - 1) as i64;
    }
    return ((1u64 << (bits - 1) as u64) - 1) as i64;
}

// `a <= b` for values of one integer type.
const fn ile(uns: bool, a: i64, b: i64) bool {
    if uns {
        return a as u64 <= b as u64;
    }
    return a <= b;
}

// `a < b` for values of one integer type.
const fn ilt(uns: bool, a: i64, b: i64) bool {
    return !ile(uns, b, a);
}

// The value after `a`, which is below its type's largest (the bits wrap for a signed -1).
const fn inext(a: i64) i64 {
    return (a as u64).wrapping_add(1) as i64;
}

// The value before `a`, which is above its type's smallest.
const fn iprev(a: i64) i64 {
    return (a as u64).wrapping_sub(1) as i64;
}

// Sort `v[from..]` ascending in the integer order (heapsort: no allocation, O(n log n)).
fn sort_vals(v: &mut Vector<i64>, from: usize, uns: bool) {
    let n = v.len() - from;
    let mut k = n / 2;
    while k > 0 {
        k -= 1;
        sift_down(v, from, k, n, uns);
    }
    let mut end = n;
    while end > 1 {
        end -= 1;
        v.swap(from, from + end);
        sift_down(v, from, 0, end, uns);
    }
}

// Restore the max-heap `v[from..from + n]` below position `k`.
fn sift_down(v: &mut Vector<i64>, from: usize, k: usize, n: usize, uns: bool) {
    let mut r = k;
    while 2 * r + 1 < n {
        let mut c = 2 * r + 1;
        if c + 1 < n && ilt(uns, v[from + c], v[from + c + 1]) {
            c += 1;
        }
        if !ilt(uns, v[from + r], v[from + c]) {
            return;
        }
        v.swap(from + r, from + c);
        r = c;
    }
}

// Whether `p` is a valued integer constructor: a value, or a valued range (maybe empty).
const fn is_ival(p: &NPat) bool {
    return p.kind == PC_INT || p.kind == PC_RANGE && p.arity <= 1;
}

// The inclusive interval `lo..=hi` of valued integer constructor `p`; false when it is empty.
const fn ival_of(p: &NPat, lo: &mut i64, hi: &mut i64) bool {
    *lo = p.val;
    *hi = pick(p.kind == PC_INT, p.val, p.hi);
    return p.kind == PC_INT || p.arity == 1;
}

// One child's normalized alternatives during norm_children: its sub-slot, its run in the
// alternative list, and the cartesian cursor over that run.
struct ChildAlts {
    pub slot: i64,
    pub start: u32,
    pub len: u32,
    pub cursor: u32,
}

extend PatCx {
    /// A pattern context over module `ast` of `pkg` (both must outlive it) with empty pools.
    pub fn new(pkg: *const loader::Package, ast: *const Ast, src: str) PatCx {
        return PatCx {
            pkg: pkg,
            f: facts::TypedFacts::of(ast),
            src: str::from_raw(src.ptr(), src.len()),
            pats: Vector::<NPat>::new(),
            subs: Vector::<u32>::new(),
            cols: Vector::<u32>::new(),
            rows: Vector::<Row>::new(),
            mcells: Vector::<u32>::new(),
            mrows: Vector::<u64>::new(),
            seen: Vector::<u32>::new(),
            cuts: Vector::<i64>::new(),
            ptr32: lay::target_for(unsafe (&*pkg).arch).ptr == 4,
            trows: Vector::<Row>::new(),
            tpats: Vector::<u32>::new(),
            toccs: Vector::<u32>::new(),
            budget: 65536,
            overflow: false,
            tree_refused: false,
        };
    }

    const fn spend(self: &mut Self, n: u32) bool {
        if self.budget < n {
            self.budget = 0;
            self.overflow = true;
            return false;
        }
        self.budget -= n;
        return true;
    }

    fn wild(self: &mut Self, node: NodeId) u32 {
        return self.leaf(PC_WILD, 0, node);
    }

    // Append a pattern of `kind` with value `val` and no declaration or sub-patterns; its index.
    fn leaf(self: &mut Self, kind: u8, val: i64, node: NodeId) u32 {
        self.pats.push(
            NPat {
                kind: kind,
                uns: false,
                bits: 0,
                val: val,
                hi: 0,
                decl: DefId { module: 0, node: NODE_NONE },
                node: node,
                sub_start: 0,
                sub_len: 0,
                arity: 0,
            },
        );
        return self.pats.len() as u32 - 1;
    }

    /// The enum decl containing variant `vd`, its ordinal, and the member count; ord -1 = unknown.
    pub fn variant_ordinal(self: &Self, vd: DefId, count: &mut u32) i64 {
        let mut ord: i64 = 0;
        let en = unsafe (&*self.pkg).variant_enum(vd, &mut ord);
        *count = 0;
        if en != NODE_NONE {
            let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
            *count = a.at_const(en).as_data.aggregate.members.len;
        }
        return ord;
    }

    // The payload arity of variant `vd`.
    const fn variant_arity(self: &Self, vd: DefId) u32 {
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        return a.at_const(vd.node).as_data.variant.payload.len;
    }

    // The declared field ordinal of `fdecl` inside variant payload / struct member list `ms` of
    // module `m`; -1 when absent.
    fn field_ordinal(self: &Self, m: ModuleId, ms: NodeList, fdecl: NodeId) i64 {
        let a = unsafe &*(&*self.pkg).module_ast_const(m);
        for j in 0..ms.len {
            if unsafe a.list(ms)[j as usize] == fdecl {
                return j;
            }
        }
        return -1;
    }

    /// Normalize pattern `pid` into one or more alternatives appended to `out` (or-patterns fan
    /// out; every other shape contributes exactly one id).
    pub fn normalize(self: &mut Self, pid: NodeId, out: &mut Vector<u32>) {
        if !self.spend(1) {
            return;
        }
        if pid == NODE_NONE {
            out.push(self.wild(pid));
            return;
        }
        let k = self.f.node(pid).kind;
        if k == NodeKind::NODE_PATTERN_OR {
            let ch = self.f.node(pid).as_data.pattern.children;
            for i in 0..ch.len {
                self.normalize(unsafe self.f.list(ch)[i as usize], out);
            }
            return;
        }
        if k == NodeKind::NODE_PATTERN_WILDCARD || k == NodeKind::NODE_IDENTIFIER {
            out.push(self.wild(pid));
            return;
        }
        if k == NodeKind::NODE_PATTERN_NAME {
            let pd = self.f.node(pid).as_data.pattern;
            let vd = self.f.res(pd.name);
            let isv = vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT;
            if isv {
                self.norm_variant(pid, vd, NodeList { start: 0, len: 0 }, false, out);
                return;
            }
            if pd.children.len != 0 {
                // `name @ sub`: the name binds; the subpattern decides matching.
                self.normalize(unsafe self.f.list(pd.children)[0], out);
                return;
            }
            out.push(self.wild(pid));
            return;
        }
        if k == NodeKind::NODE_PATTERN_LITERAL {
            self.norm_literal(pid, out);
            return;
        }
        if k == NodeKind::NODE_PATTERN_RANGE {
            out.push(self.norm_range(pid));
            return;
        }
        if k == NodeKind::NODE_PATTERN_TUPLE {
            let pd = self.f.node(pid).as_data.pattern;
            let vd = if pd.name != NODE_NONE {
                self.f.res(pd.name);
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                self.norm_variant(pid, vd, pd.children, false, out);
                return;
            }
            if pd.children.len == 1 {
                // Parenthesized pattern.
                self.normalize(unsafe self.f.list(pd.children)[0], out);
                return;
            }
            self.norm_children(
                pid,
                DefId { module: 0, node: NODE_NONE },
                pd.children,
                false,
                NodeList { start: 0, len: 0 },
                pd.children.len,
                PC_TUPLE,
                0,
                out,
            );
            return;
        }
        if k == NodeKind::NODE_PATTERN_STRUCT {
            let pd = self.f.node(pid).as_data.pattern;
            let vd = if pd.name != NODE_NONE {
                self.f.res(pd.name);
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            if vd.node != NODE_NONE && self.decl_kind(vd) == NodeKind::NODE_VARIANT {
                self.norm_variant(pid, vd, pd.children, true, out);
                return;
            }
            self.norm_struct(pid, vd, out);
            return;
        }
        // Unknown pattern shape: cover nothing beyond itself.
        out.push(self.leaf(PC_OPAQUE, pid, pid));
    }

    const fn decl_kind(self: &Self, d: DefId) NodeKind {
        if d.node == NODE_NONE {
            return NodeKind::NODE_NONE_KIND;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(d.module);
        return a.at_const(d.node).kind;
    }

    // The value of integer constant pattern `b` (a PATTERN_LITERAL or a bare bound) as bits, with the
    // matched type's order and width, from the type checker's record; false when it has none.
    fn int_val(self: &Self, b: NodeId, v: &mut i64, uns: &mut bool, bits: &mut u8) bool {
        let e = if self.f.node(b).kind == NodeKind::NODE_PATTERN_LITERAL {
            self.f.node(b).as_data.single.value;
        } else {
            b;
        };
        let t = self.f.node_type(b);
        if t == TYPE_NONE || self.f.ty(t).kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = self.f.ty(t).as_data.builtin;
        if bt == BuiltinType::BT_CHAR {
            *uns = true;
            *bits = 8;
        } else if bt_int_width(bt, self.ptr32) != 0 {
            *uns = bt_is_unsigned(bt);
            *bits = bt_int_width(bt, self.ptr32) as u8;
        } else {
            return false;
        }
        return switch self.f.pat_value(e) {
            Some(x) => {
                *v = x as i64;
                true;
            },
            None => false,
        };
    }

    // A range pattern: valued as the inclusive interval of its bounds (an open end at its type's
    // extreme; an exclusive one below its end, empty below the type's smallest), else opaque.
    fn norm_range(self: &mut Self, pid: NodeId) u32 {
        let rd = self.f.node(pid).as_data.pattern_range;
        let mut uns = false;
        let mut bits: u8 = 0;
        let mut lo: i64 = 0;
        let mut hi: i64 = 0;
        let lo_ok = rd.start == NODE_NONE || self.int_val(rd.start, &mut lo, &mut uns, &mut bits);
        let hi_ok = rd.end == NODE_NONE || self.int_val(rd.end, &mut hi, &mut uns, &mut bits);
        let valued = lo_ok && hi_ok && bits != 0;
        let mut arity: u32 = 2;
        if valued {
            arity = 1;
            if rd.start == NODE_NONE {
                lo = dom_min(uns, bits);
            }
            if rd.end == NODE_NONE {
                hi = dom_max(uns, bits);
            } else if !rd.inclusive && hi == dom_min(uns, bits) {
                arity = 0;
            } else if !rd.inclusive {
                hi = iprev(hi);
            }
            if ilt(uns, hi, lo) {
                arity = 0;
            }
        }
        self.pats.push(
            NPat {
                kind: PC_RANGE,
                uns: uns,
                bits: bits,
                // An opaque range is keyed by its node: it covers nothing and equals only itself.
                val: pick(valued, lo, pid),
                hi: pick(valued, hi, pid),
                decl: DefId { module: 0, node: NODE_NONE },
                node: pid,
                sub_start: 0,
                sub_len: 0,
                arity: arity,
            },
        );
        return self.pats.len() as u32 - 1;
    }

    fn norm_literal(self: &mut Self, pid: NodeId, out: &mut Vector<u32>) {
        let v = self.f.node(pid).as_data.single.value;
        if self.f.node(v).kind == NodeKind::NODE_LITERAL {
            let ld = self.f.node(v).as_data.literal;
            if ld.token_type == tt::TokenType::True || ld.token_type == tt::TokenType::False {
                let bv: i64 = if ld.token_type == tt::TokenType::True {
                    1;
                } else {
                    0;
                };
                out.push(self.leaf(PC_BOOL, bv, pid));
                return;
            }
        }
        let mut iv: i64 = 0;
        let mut uns = false;
        let mut bits: u8 = 0;
        if self.int_val(pid, &mut iv, &mut uns, &mut bits) {
            out.push(self.int_pat(iv, iv, uns, bits, pid));
            return;
        }
        // Strings, floats, library-integer literals: opaque, keyed by node.
        out.push(self.leaf(PC_OPAQUE, pid, pid));
    }

    // A variant pattern: subs = the full payload in declaration order (`by_name` aligns struct-
    // payload fields through their resolved field decls; positional payloads align by index).
    fn norm_variant(self: &mut Self, pid: NodeId, vd: DefId, ch: NodeList, by_name: bool, out: &mut Vector<u32>) {
        let mut count: u32 = 0;
        let ord = self.variant_ordinal(vd, &mut count);
        let arity = self.variant_arity(vd);
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        let payload = a.at_const(vd.node).as_data.variant.payload;
        self.norm_children(pid, vd, ch, by_name, payload, arity, PC_VARIANT, ord, out);
    }

    fn norm_struct(self: &mut Self, pid: NodeId, sd: DefId, out: &mut Vector<u32>) {
        if sd.node == NODE_NONE || self.decl_kind(sd) != NodeKind::NODE_STRUCT {
            // An unresolved struct pattern covers nothing beyond itself.
            out.push(self.leaf(PC_OPAQUE, pid, pid));
            return;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(sd.module);
        let ms = a.at_const(sd.node).as_data.aggregate.members;
        let ch = self.f.node(pid).as_data.pattern.children;
        self.norm_children(pid, sd, ch, true, ms, ms.len, PC_STRUCT, 0, out);
    }

    // Shared child alignment: build `arity` sub-slots (wild by default), place each listed child
    // pattern at its slot, expanding or-children into alternative parents (bounded).
    fn norm_children(
        self: &mut Self,
        pid: NodeId,
        decl: DefId,
        ch: NodeList,
        by_name: bool,
        dlist: NodeList,
        arity: u32,
        kind: u8,
        ord: i64,
        out: &mut Vector<u32>,
    ) {
        if !self.spend(arity + 1) {
            out.push(self.wild(pid));
            return;
        }
        // Normalize each child into its alternatives first: kids[i] names child i's slot and its run
        // in `alts`.
        let mut alts = Vector::<u32>::new();
        let mut kids = Vector::<ChildAlts>::new();
        for i in 0..ch.len {
            let cid = unsafe self.f.list(ch)[i as usize];
            let mut slot: i64 = i;
            let mut sub = cid;
            if by_name {
                // PATTERN_FIELD-shaped child: name resolves to the field decl; children[0] is the
                // sub-pattern (missing = a pure binding of the field name).
                let fpd = self.f.node(cid).as_data.pattern;
                let fd = self.f.res(fpd.name);
                slot = self.field_ordinal(decl.module, dlist, fd.node);
                if fpd.children.len != 0 {
                    sub = unsafe self.f.list(fpd.children)[0];
                } else {
                    sub = NODE_NONE;
                }
            }
            let start = alts.len();
            if sub == NODE_NONE {
                alts.push(self.wild(cid));
            } else {
                self.normalize(sub, &mut alts);
            }
            if alts.len() == start {
                alts.push(self.wild(cid));
            }
            kids.push(ChildAlts { slot: slot, start: start as u32, len: (alts.len() - start) as u32, cursor: 0 });
        }
        // Cartesian expansion over children with several alternatives (nested or-patterns), bounded
        // by the budget; the common case is one alternative each = one parent.
        loop {
            if !self.spend(arity + 1) {
                out.push(self.wild(pid));
                return;
            }
            let sub_start = self.subs.len() as u32;
            // Default every slot to wild, then place the children.
            for s in 0..arity {
                self.subs.push(P_NONE);
            }
            for i in 0..kids.len() {
                let k = kids[i];
                if k.slot >= 0 && k.slot as u32 < arity {
                    self.subs.set((sub_start + k.slot as u32) as usize, alts[(k.start + k.cursor) as usize]);
                }
            }
            for s in 0..arity {
                if self.subs[(sub_start + s) as usize] == P_NONE {
                    let w = self.wild(pid);
                    self.subs.set((sub_start + s) as usize, w);
                }
            }
            self.pats.push(
                NPat {
                    kind: kind,
                    uns: false,
                    bits: 0,
                    val: ord,
                    hi: 0,
                    decl: decl,
                    node: pid,
                    sub_start: sub_start,
                    sub_len: arity,
                    arity: arity,
                },
            );
            out.push(self.pats.len() as u32 - 1);
            // Advance the cartesian cursor.
            let mut carried = true;
            let mut i2: usize = 0;
            while carried && i2 < kids.len() {
                let c = kids[i2].cursor + 1;
                if c < kids[i2].len {
                    kids[i2].cursor = c;
                    carried = false;
                } else {
                    kids[i2].cursor = 0;
                    i2 += 1;
                }
            }
            if carried {
                break;
            }
        }
    }

    /// Append arm pattern `pid` (all alternatives) as single-column rows for arm `arm`.
    pub fn add_arm(self: &mut Self, pid: NodeId, arm: u32) {
        let mut alts = Vector::<u32>::new();
        self.normalize(pid, &mut alts);
        for i in 0..alts.len() {
            let start = self.cols.len() as u32;
            self.cols.push(alts[i]);
            self.rows.push(Row { start: start, len: 1, arm: arm });
        }
    }

    // Does constructor pattern `q` fall inside row-head `r` (r covers q)?
    const fn head_covers(self: &Self, r: u32, q: u32) bool {
        let rp = self.pats.at(r as usize);
        let qp = self.pats.at(q as usize);
        if rp.kind == PC_WILD {
            return true;
        }
        if is_ival(rp) && is_ival(qp) {
            // An interval covers every interval inside it; an empty one covers and is covered by none.
            let mut rl: i64 = 0;
            let mut rh: i64 = 0;
            let mut ql: i64 = 0;
            let mut qh: i64 = 0;
            return ival_of(rp, &mut rl, &mut rh) && ival_of(qp, &mut ql, &mut qh) && ile(rp.uns, rl, ql) && ile(
                rp.uns,
                qh,
                rh,
            );
        }
        if rp.kind != qp.kind {
            return false;
        }
        if rp.kind == PC_VARIANT {
            return rp.val == qp.val && rp.decl.node == qp.decl.node;
        }
        if rp.kind == PC_BOOL {
            return rp.val == qp.val;
        }
        if rp.kind == PC_RANGE {
            return rp.val == qp.val && rp.hi == qp.hi && rp.arity == qp.arity;
        }
        if rp.kind == PC_OPAQUE {
            return rp.val == qp.val || self.same_spelling(rp.node, qp.node);
        }
        // Tuple/struct: single constructor.
        return true;
    }

    // The raw spelling of literal pattern `pid` (a PATTERN_LITERAL over a literal); empty otherwise.
    const fn lit_raw(self: &Self, pid: NodeId) tok::Span {
        let none = tok::Span { start: 0, end: 0 };
        if pid == NODE_NONE || self.f.node(pid).kind != NodeKind::NODE_PATTERN_LITERAL {
            return none;
        }
        let v = self.f.node(pid).as_data.single.value;
        if self.f.node(v).kind != NodeKind::NODE_LITERAL {
            return none;
        }
        return self.f.node(v).as_data.literal.raw;
    }

    // Whether literal patterns `a` and `b` are spelled alike, so they match one value.
    const fn same_spelling(self: &Self, a: NodeId, b: NodeId) bool {
        let x = self.lit_raw(a);
        let y = self.lit_raw(b);
        return x.end > x.start && self.src.slice(x.start as usize, x.end as usize) == self.src.slice(
            y.start as usize,
            y.end as usize,
        );
    }

    // Whether literal pattern `pid` is a string literal spelled without escapes: two of them spelled
    // differently match different values.
    const fn plain_string(self: &Self, pid: NodeId) bool {
        let r = self.lit_raw(pid);
        if r.end <= r.start {
            return false;
        }
        let tk = self.f.node(self.f.node(pid).as_data.single.value).as_data.literal.token_type;
        let text = self.src.slice(r.start as usize, r.end as usize);
        return tk == tt::TokenType::StringLiteral && text.byte_at(0) == b'"' && text.find_byte(b'\\') < 0;
    }

    // Push onto `cuts` the start of every piece that the bounds of the integer heads `seen[from..]`
    // cut `lo..=hi` into, ascending and distinct: each head then covers a piece whole or not at all.
    fn split(self: &mut Self, from: usize, lo: i64, hi: i64, uns: bool) {
        let wm = self.cuts.len();
        self.cuts.push(lo);
        for s2 in from..self.seen.len() {
            let p = *self.pats.at(self.seen[s2] as usize);
            let mut a: i64 = 0;
            let mut b: i64 = 0;
            if !is_ival(&p) || !ival_of(&p, &mut a, &mut b) {
                continue;
            }
            if ilt(uns, lo, a) && ile(uns, a, hi) {
                self.cuts.push(a);
            }
            if ile(uns, lo, b) && ilt(uns, b, hi) {
                self.cuts.push(inext(b));
            }
        }
        sort_vals(&mut self.cuts, wm, uns);
        let mut w = wm + 1;
        for r in wm + 1..self.cuts.len() {
            if self.cuts[r] != self.cuts[w - 1] {
                self.cuts.set(w, self.cuts[r]);
                w += 1;
            }
        }
        self.cuts.truncate(w);
    }

    // The last value of piece `i` of the `n` pieces at `cuts[wm..]` that end at `hi`.
    const fn piece_end(self: &Self, wm: usize, i: usize, n: usize, hi: i64) i64 {
        if i + 1 < n {
            return iprev(self.cuts[wm + i + 1]);
        }
        return hi;
    }

    // Whether an integer head among `seen[from..to]` holds value `a`, and in `rep` the head whose
    // interval is exactly `a..=b` (P_NONE when none is).
    fn piece_heads(self: &Self, from: usize, to: usize, a: i64, b: i64, uns: bool, rep: &mut u32) bool {
        *rep = P_NONE;
        let mut covered = false;
        for s2 in from..to {
            let p = self.pats.at(self.seen[s2] as usize);
            let mut l: i64 = 0;
            let mut h: i64 = 0;
            if ival_of(p, &mut l, &mut h) && ile(uns, l, a) && ile(uns, a, h) {
                covered = true;
                if l == a && h == b {
                    *rep = self.seen[s2];
                }
            }
        }
        return covered;
    }

    // The integer constructor `a..=b` (a value when it holds one) of pattern `node` (NODE_NONE for a
    // split piece); its index.
    fn int_pat(self: &mut Self, a: i64, b: i64, uns: bool, bits: u8, node: NodeId) u32 {
        self.pats.push(
            NPat {
                kind: pick(a == b, PC_INT, PC_RANGE),
                uns: uns,
                bits: bits,
                val: a,
                hi: b,
                decl: DefId { module: 0, node: NODE_NONE },
                node: node,
                sub_start: 0,
                sub_len: 0,
                arity: pick(a == b, 0u32, 1u32),
            },
        );
        return self.pats.len() as u32 - 1;
    }

    // Whether the non-wild heads `seen[from..]` are all integer constructors (at least one).
    fn int_column(self: &Self, from: usize) bool {
        for s2 in from..self.seen.len() {
            if !is_ival(self.pats.at(self.seen[s2] as usize)) {
                return false;
            }
        }
        return self.seen.len() > from;
    }

    // Usefulness of query row `qrow`, whose first column takes a value in `lo..=hi`, against rows
    // `rs..rs+rn` whose integer heads are `seen[from..]`: useful on some piece of the split. The pieces
    // no head holds all answer alike (only the wildcard rows reach them), so one of them is asked; a
    // piece a head holds is not asked in a one-column query, whose row then matches it whole.
    fn useful_split(self: &mut Self, rs: usize, rn: usize, qrow: usize, from: usize, lo: i64, hi: i64, h0: NPat) bool {
        let one_col = (self.mrows[qrow] & 0xFFFFFFFFu64) == 1;
        let wm_k = self.cuts.len();
        self.split(from, lo, hi, h0.uns);
        let n = self.cuts.len() - wm_k;
        let to = self.seen.len();
        let mut found = false;
        let mut open_asked = false;
        if self.spend(n as u32) {
            for i in 0..n {
                let a = self.cuts[wm_k + i];
                let b = self.piece_end(wm_k, i, n, hi);
                let mut rep = P_NONE;
                if self.piece_heads(from, to, a, b, h0.uns, &mut rep) {
                    if one_col {
                        continue;
                    }
                } else if open_asked {
                    continue;
                } else {
                    open_asked = true;
                }
                let wm_c = self.mcells.len();
                let wm_r = self.mrows.len();
                let wm_p = self.pats.len();
                let pc = self.int_pat(a, b, h0.uns, h0.bits, NODE_NONE);
                found = self.useful_by(rs, rn, qrow, pc, true);
                self.cut(wm_c, wm_r, wm_p);
                if found {
                    break;
                }
            }
        }
        self.cuts.truncate(wm_k);
        return found;
    }

    // Usefulness of the query row at mrows[qrow] against the matrix rows mrows[rs..rs+rn]
    // (classic specialization; or-patterns were expanded at normalization). All storage is the
    // watermarked arena: each level appends its specialized matrix + query and truncates on return.
    fn useful_rec(self: &mut Self, rs: usize, rn: usize, qrow: usize) bool {
        if !self.spend(rn as u32 + 1) {
            // Conservative: not useful => assume covered / unreachable never fires.
            return false;
        }
        let q = self.mrows[qrow];
        let qs = (q >> 32) as usize;
        let ql = (q & 0xFFFFFFFFu64) as usize;
        if ql == 0 {
            return rn == 0;
        }
        let q0 = self.mcells[qs];
        let q0k = self.pats.at(q0 as usize).kind;
        let wm_c = self.mcells.len();
        let wm_r = self.mrows.len();
        let wm_p = self.pats.len();
        let q0p = *self.pats.at(q0 as usize);
        if q0k != PC_WILD && !is_ival(&q0p) {
            let r = self.useful_by(rs, rn, qrow, q0, true);
            self.cut(wm_c, wm_r, wm_p);
            return r;
        }
        // Distinct head constructors.
        let wm_s = self.seen.len();
        for r in 0..rn {
            let row = self.mrows[rs + r];
            let h = self.mcells[(row >> 32) as usize];
            if self.pats.at(h as usize).kind == PC_WILD {
                continue;
            }
            self.note_head(wm_s, h);
        }
        if q0k != PC_WILD || self.int_column(wm_s) {
            // An integer query, or a wildcard over integer heads: the interval it takes (the whole
            // domain for a wildcard; none for an empty range) splits at the heads' bounds.
            let h0 = if q0k != PC_WILD {
                q0p;
            } else {
                *self.pats.at(self.seen[wm_s] as usize);
            };
            let mut lo = dom_min(h0.uns, h0.bits);
            let mut hi = dom_max(h0.uns, h0.bits);
            let empty = q0k != PC_WILD && !ival_of(&q0p, &mut lo, &mut hi);
            let r = !empty && self.useful_split(rs, rn, qrow, wm_s, lo, hi, h0);
            self.seen.truncate(wm_s);
            self.cut(wm_c, wm_r, wm_p);
            return r;
        }
        // Wildcard q0: completeness.
        let complete = self.ctors_complete(&self.seen, wm_s);
        if !complete {
            // Default matrix: wild-headed rows, minus the column.
            let drs = self.mrows.len();
            let mut drn: usize = 0;
            for r in 0..rn {
                let row = self.mrows[rs + r];
                let rstart = (row >> 32) as usize;
                let rlen = (row & 0xFFFFFFFFu64) as usize;
                if self.pats.at(self.mcells[rstart] as usize).kind != PC_WILD {
                    continue;
                }
                let ns = self.mcells.len();
                for c in 1..rlen {
                    self.mcells.push(self.mcells[rstart + c]);
                }
                self.mrows.push(ns as u64 << 32 | (rlen - 1) as u64);
                drn += 1;
            }
            let nqs = self.mcells.len();
            for c in 1..ql {
                self.mcells.push(self.mcells[qs + c]);
            }
            let nq = self.mrows.len();
            self.mrows.push(nqs as u64 << 32 | (ql - 1) as u64);
            let r = self.useful_rec(drs, drn, nq);
            self.cut(wm_c, wm_r, wm_p);
            self.seen.truncate(wm_s);
            return r;
        }
        // Complete head set: useful iff useful under some constructor.
        let mut found = false;
        for s2 in wm_s..self.seen.len() {
            found = self.useful_by(rs, rn, qrow, self.seen[s2], false);
            self.cut(wm_c, wm_r, wm_p);
            if found {
                break;
            }
        }
        self.seen.truncate(wm_s);
        return found;
    }

    // Drop the arena cells, rows and patterns appended past watermarks `wc`, `wr`, `wp`.
    fn cut(self: &mut Self, wc: usize, wr: usize, wp: usize) {
        self.mcells.truncate(wc);
        self.mrows.truncate(wr);
        self.pats.truncate(wp);
    }

    // Append head constructor `h` to `seen` unless `seen[from..]` already holds the same one.
    fn note_head(self: &mut Self, from: usize, h: u32) {
        for s2 in from..self.seen.len() {
            if self.same_ctor(self.seen[s2], h) {
                return;
            }
        }
        self.seen.push(h);
    }

    // Whether head constructors `a` and `b` cover each other.
    const fn same_ctor(self: &Self, a: u32, b: u32) bool {
        return self.head_covers(a, b) && self.head_covers(b, a);
    }

    // Specialize on constructor `c` and recurse. With `from_query`, `c` is the query's own head:
    // rows whose head covers it stay, and the query contributes c's sub-patterns. Otherwise `c` is a
    // head constructor of the rows: wild rows and rows with the same constructor stay, and the query
    // (wild-headed) contributes wildcards.
    fn useful_by(self: &mut Self, rs: usize, rn: usize, qrow: usize, c: u32, from_query: bool) bool {
        let q = self.mrows[qrow];
        let qs = (q >> 32) as usize;
        let ql = (q & 0xFFFFFFFFu64) as usize;
        let cp = *self.pats.at(c as usize);
        let arity = cp.sub_len as usize;
        let nrs = self.mrows.len();
        let mut nrn: usize = 0;
        for r in 0..rn {
            let row = self.mrows[rs + r];
            let rstart = (row >> 32) as usize;
            let rlen = (row & 0xFFFFFFFFu64) as usize;
            let h = self.mcells[rstart];
            let hp = *self.pats.at(h as usize);
            let cov = if from_query {
                self.head_covers(h, c);
            } else {
                hp.kind == PC_WILD || self.same_ctor(h, c);
            };
            if !cov {
                continue;
            }
            let ns = self.mcells.len();
            if hp.kind == PC_WILD {
                for k in 0..arity {
                    let w = self.wild(hp.node);
                    self.mcells.push(w);
                }
            } else {
                for k in 0..hp.sub_len {
                    self.mcells.push(self.subs[(hp.sub_start + k) as usize]);
                }
            }
            for c2 in 1..rlen {
                self.mcells.push(self.mcells[rstart + c2]);
            }
            self.mrows.push(ns as u64 << 32 | (arity + rlen - 1) as u64);
            nrn += 1;
        }
        let qn = self.pats.at(self.mcells[qs] as usize).node;
        let nqs = self.mcells.len();
        for k in 0..arity {
            let cell = if from_query {
                self.subs[(cp.sub_start + k as u32) as usize];
            } else {
                self.wild(qn);
            };
            self.mcells.push(cell);
        }
        for c2 in 1..ql {
            self.mcells.push(self.mcells[qs + c2]);
        }
        let nq = self.mrows.len();
        self.mrows.push(nqs as u64 << 32 | (arity + ql - 1) as u64);
        return self.useful_rec(nrs, nrn, nq);
    }

    // Copy the recorded arm rows (those before `limit_arm`) into the arena as the root matrix.
    fn snapshot_arena(self: &mut Self, limit_arm: u32) usize {
        let mut n: usize = 0;
        for r in 0..self.rows.len() {
            let row = *self.rows.at(r);
            if row.arm >= limit_arm {
                continue;
            }
            let ns = self.mcells.len();
            for c in 0..row.len {
                self.mcells.push(self.cols[(row.start + c) as usize]);
            }
            self.mrows.push(ns as u64 << 32 | row.len as u64);
            n += 1;
        }
        return n;
    }

    // Run one usefulness query for probe pattern `probe` against rows before `limit_arm`.
    fn query(self: &mut Self, probe: u32, limit_arm: u32) bool {
        let wm_c = self.mcells.len();
        let wm_r = self.mrows.len();
        let rs = self.mrows.len();
        let rn = self.snapshot_arena(limit_arm);
        let nqs = self.mcells.len();
        self.mcells.push(probe);
        let nq = self.mrows.len();
        self.mrows.push(nqs as u64 << 32 | 1);
        let r = self.useful_rec(rs, rn, nq);
        self.mcells.truncate(wm_c);
        self.mrows.truncate(wm_r);
        return r;
    }

    /// Is a wildcard still useful after every recorded row? (true = the match is NOT exhaustive.)
    pub fn wildcard_useful(self: &mut Self) bool {
        if self.overflow {
            return false;
        }
        let w = self.wild(NODE_NONE);
        return self.query(w, 0xFFFFFFFF) && !self.overflow;
    }

    /// Is enum variant `vd` (ordinal `ord`) still reachable after every recorded row?
    pub fn variant_missing(self: &mut Self, vd: DefId, ord: i64) bool {
        if self.overflow {
            return false;
        }
        let arity = self.variant_arity(vd);
        let sub_start = self.subs.len() as u32;
        for s in 0..arity {
            let w = self.wild(NODE_NONE);
            self.subs.push(w);
        }
        self.pats.push(
            NPat {
                kind: PC_VARIANT,
                uns: false,
                bits: 0,
                val: ord,
                hi: 0,
                decl: vd,
                node: NODE_NONE,
                sub_start: sub_start,
                sub_len: arity,
                arity: arity,
            },
        );
        let probe = self.pats.len() as u32 - 1;
        return self.query(probe, 0xFFFFFFFF) && !self.overflow;
    }

    /// Is arm `arm`'s pattern `pid` reachable given every earlier recorded row? (Earlier guarded
    /// arms must NOT be recorded: a failed guard falls through, so they cover nothing here.)
    pub fn arm_reachable(self: &mut Self, pid: NodeId, arm: u32) bool {
        if self.overflow {
            return true;
        }
        let mut alts = Vector::<u32>::new();
        self.normalize(pid, &mut alts);
        for i in 0..alts.len() {
            if self.query(alts[i], arm) {
                return true;
            }
        }
        return self.overflow;
    }

    /// Build the decision tree for the recorded rows (call add_arm for EVERY arm first; matches
    /// with guards must keep sequential lowering and never reach this). `ok=false` on overflow.
    pub fn build_tree(self: &mut Self) DecisionTree {
        let mut t = DecisionTree {
            nodes: Vector::<DtNode>::new(),
            edges: Vector::<DtEdge>::new(),
            paths: Vector::<DtPath>::new(),
            root: 0,
            ok: true,
        };
        // Path 0 is the scrutinee itself.
        t.paths.push(
            DtPath {
                parent: P_NONE,
                downcast: -1,
                vdecl: DefId { module: 0, node: NODE_NONE },
                field: 0,
                fdecl: NODE_NONE,
                pat: NODE_NONE,
            },
        );
        for r in 0..self.rows.len() {
            let row = *self.rows.at(r);
            let start = self.tpats.len() as u32;
            for c in 0..row.len {
                self.tpats.push(self.cols[(row.start + c) as usize]);
                self.toccs.push(0);
            }
            self.trows.push(Row { start: start, len: row.len, arm: row.arm });
        }
        t.root = self.tree_rec(&mut t, 0, self.trows.len());
        self.trows.clear();
        self.tpats.clear();
        self.toccs.clear();
        if self.overflow || self.tree_refused {
            t.ok = false;
        }
        return t;
    }

    fn tree_leaf(self: &Self, t: &mut DecisionTree, kind: u8, arm: u32) u32 {
        t.nodes.push(DtNode { kind: kind, arm: arm, place: P_NONE, edge_start: 0, edge_len: 0, default_child: P_NONE });
        return t.nodes.len() as u32 - 1;
    }

    // The subtree for arena rows trows[rs..rs+rn].
    fn tree_rec(self: &mut Self, t: &mut DecisionTree, rs: usize, rn: usize) u32 {
        if !self.spend(rn as u32 + 1) || rn == 0 {
            return self.tree_leaf(t, DT_FAIL, 0);
        }
        // First row all-wild: it matches; later rows are this path's dead tail.
        let r0 = *self.trows.at(rs);
        let mut col: i64 = -1;
        for c in 0..r0.len {
            if self.pats.at(self.tpats[(r0.start + c) as usize] as usize).kind != PC_WILD {
                col = c;
                break;
            }
        }
        if col < 0 {
            return self.tree_leaf(t, DT_LEAF, r0.arm);
        }
        let c = col as u32;
        let occ = self.toccs[(r0.start + c) as usize];
        // Distinct head constructors in the column go to `seen` behind its watermark, then the child
        // built for each: constructors at [wm_s, wm_s + n), children at [wm_s + n, wm_s + 2n).
        let wm_s = self.seen.len();
        for r in 0..rn {
            let row = *self.trows.at(rs + r);
            let h = self.tpats[(row.start + c) as usize];
            if self.pats.at(h as usize).kind == PC_WILD {
                continue;
            }
            self.note_head(wm_s, h);
        }
        let n = self.seen.len() - wm_s;
        if self.int_column(wm_s) {
            return self.tree_ints(t, rs, rn, c, occ, wm_s);
        }
        if n >= 2 && !self.tree_distinct(wm_s) {
            self.tree_refused = true;
            self.seen.truncate(wm_s);
            return self.tree_leaf(t, DT_FAIL, 0);
        }
        let complete = self.ctors_complete(&self.seen, wm_s);
        let wm_r = self.trows.len();
        let wm_c = self.tpats.len();
        // Build one child per constructor.
        for s2 in 0..n {
            let rep = self.seen[wm_s + s2];
            let repp = *self.pats.at(rep as usize);
            let arity = repp.sub_len;
            // Sub-occurrence paths for this constructor: t.paths[sp0 .. sp0 + arity).
            let sp0 = t.paths.len() as u32;
            for f in 0..arity {
                let dc: i64 = if repp.kind == PC_VARIANT {
                    repp.val;
                } else {
                    -1;
                };
                t.paths.push(
                    DtPath {
                        parent: occ,
                        downcast: dc,
                        vdecl: repp.decl,
                        field: f,
                        fdecl: self.slot_field_decl(&repp, f),
                        pat: self.slot_pat_node(&repp, f),
                    },
                );
            }
            for r in 0..rn {
                let row = *self.trows.at(rs + r);
                let h = self.tpats[(row.start + c) as usize];
                let hp = *self.pats.at(h as usize);
                if hp.kind != PC_WILD && !self.same_ctor(h, rep) {
                    continue;
                }
                let ns = self.tpats.len();
                if hp.kind == PC_WILD {
                    for f in 0..arity {
                        let w = self.wild(hp.node);
                        self.tpats.push(w);
                        self.toccs.push(sp0 + f);
                    }
                } else {
                    for f in 0..hp.sub_len {
                        self.tpats.push(self.subs[(hp.sub_start + f) as usize]);
                        self.toccs.push(sp0 + f);
                    }
                }
                self.push_other_columns(row, c);
                self.trows.push(Row { start: ns as u32, len: (self.tpats.len() - ns) as u32, arm: row.arm });
            }
            let child = self.tree_rec(t, wm_r, self.trows.len() - wm_r);
            self.trows.truncate(wm_r);
            self.tpats.truncate(wm_c);
            self.toccs.truncate(wm_c);
            self.seen.push(child);
        }
        // Default child for an incomplete constructor set.
        let mut dchild = P_NONE;
        if !complete {
            for r in 0..rn {
                let row = *self.trows.at(rs + r);
                if self.pats.at(self.tpats[(row.start + c) as usize] as usize).kind != PC_WILD {
                    continue;
                }
                let ns = self.tpats.len();
                self.push_other_columns(row, c);
                self.trows.push(Row { start: ns as u32, len: (self.tpats.len() - ns) as u32, arm: row.arm });
            }
            dchild = self.tree_rec(t, wm_r, self.trows.len() - wm_r);
            self.trows.truncate(wm_r);
            self.tpats.truncate(wm_c);
            self.toccs.truncate(wm_c);
        }
        let estart = t.edges.len() as u32;
        for s2 in 0..n {
            t.edges.push(DtEdge { pat: self.seen[wm_s + s2], child: self.seen[wm_s + n + s2] });
        }
        self.seen.truncate(wm_s);
        t.nodes.push(
            DtNode { kind: DT_TEST, arm: 0, place: occ, edge_start: estart, edge_len: n as u32, default_child: dchild },
        );
        return t.nodes.len() as u32 - 1;
    }

    // Whether the tree tells the distinct heads `seen[from..]` of a column apart by testing them in
    // turn: no integer head among other kinds, no opaque range, and no two literals whose different
    // spellings may name one value (only escape-free strings are known apart).
    fn tree_distinct(self: &Self, from: usize) bool {
        for s2 in from..self.seen.len() {
            let p = self.pats.at(self.seen[s2] as usize);
            if is_ival(p) || p.kind == PC_RANGE || p.kind == PC_OPAQUE && !self.plain_string(p.node) {
                return false;
            }
        }
        return true;
    }

    // The subtree for rows trows[rs..rs+rn] tested on integer column `c` (place `occ`) whose heads are
    // seen[wm_s..]: one edge per piece of the type's domain that a head holds (the head itself when its
    // interval is the piece, so the test keeps its spelling), whose child keeps the rows holding the
    // piece, and a default child for the values no head holds.
    fn tree_ints(self: &mut Self, t: &mut DecisionTree, rs: usize, rn: usize, c: u32, occ: u32, wm_s: usize) u32 {
        let h0 = *self.pats.at(self.seen[wm_s] as usize);
        let lo = dom_min(h0.uns, h0.bits);
        let hi = dom_max(h0.uns, h0.bits);
        let nh = self.seen.len();
        let wm_k = self.cuts.len();
        self.split(wm_s, lo, hi, h0.uns);
        let np = self.cuts.len() - wm_k;
        let wm_r = self.trows.len();
        let wm_c = self.tpats.len();
        let mut open = false;
        if self.spend(np as u32) {
            for i in 0..np {
                let a = self.cuts[wm_k + i];
                let b = self.piece_end(wm_k, i, np, hi);
                let mut rep = P_NONE;
                if !self.piece_heads(wm_s, nh, a, b, h0.uns, &mut rep) {
                    open = true;
                    continue;
                }
                if rep == P_NONE {
                    rep = self.int_pat(a, b, h0.uns, h0.bits, NODE_NONE);
                }
                for r in 0..rn {
                    let row = *self.trows.at(rs + r);
                    let hp = *self.pats.at(self.tpats[(row.start + c) as usize] as usize);
                    let mut l: i64 = 0;
                    let mut u: i64 = 0;
                    if hp.kind != PC_WILD && !(ival_of(&hp, &mut l, &mut u) && ile(h0.uns, l, a) && ile(h0.uns, a, u)) {
                        continue;
                    }
                    let ns = self.tpats.len();
                    self.push_other_columns(row, c);
                    self.trows.push(Row { start: ns as u32, len: (self.tpats.len() - ns) as u32, arm: row.arm });
                }
                let child = self.tree_rec(t, wm_r, self.trows.len() - wm_r);
                self.trows.truncate(wm_r);
                self.tpats.truncate(wm_c);
                self.toccs.truncate(wm_c);
                self.seen.push(rep);
                self.seen.push(child);
            }
        }
        let mut dchild = P_NONE;
        if open {
            for r in 0..rn {
                let row = *self.trows.at(rs + r);
                if self.pats.at(self.tpats[(row.start + c) as usize] as usize).kind != PC_WILD {
                    continue;
                }
                let ns = self.tpats.len();
                self.push_other_columns(row, c);
                self.trows.push(Row { start: ns as u32, len: (self.tpats.len() - ns) as u32, arm: row.arm });
            }
            dchild = self.tree_rec(t, wm_r, self.trows.len() - wm_r);
            self.trows.truncate(wm_r);
            self.tpats.truncate(wm_c);
            self.toccs.truncate(wm_c);
        }
        let estart = t.edges.len() as u32;
        let ne = (self.seen.len() - nh) / 2;
        for e in 0..ne {
            t.edges.push(DtEdge { pat: self.seen[nh + 2 * e], child: self.seen[nh + 2 * e + 1] });
        }
        self.seen.truncate(wm_s);
        self.cuts.truncate(wm_k);
        t.nodes.push(
            DtNode { kind: DT_TEST, arm: 0, place: occ, edge_start: estart, edge_len: ne as u32, default_child: dchild },
        );
        return t.nodes.len() as u32 - 1;
    }

    // Append every cell of arena row `row` except column `c` (patterns and occurrences).
    fn push_other_columns(self: &mut Self, row: Row, c: u32) {
        for c2 in 0..row.len {
            if c2 != c {
                self.tpats.push(self.tpats[(row.start + c2) as usize]);
                self.toccs.push(self.toccs[(row.start + c2) as usize]);
            }
        }
    }

    // Is the head-constructor set seen[from..] complete for its column type?
    fn ctors_complete(self: &Self, seen: &Vector<u32>, from: usize) bool {
        let mut tcov = false;
        let mut fcov = false;
        let mut variant_count: u32 = 0;
        let mut nvar: u32 = 0;
        for s2 in from..seen.len() {
            let hp = self.pats.at(seen[s2] as usize);
            if hp.kind == PC_TUPLE || hp.kind == PC_STRUCT {
                return true;
            }
            if hp.kind == PC_BOOL {
                if hp.val != 0 {
                    tcov = true;
                } else {
                    fcov = true;
                }
            }
            if hp.kind == PC_VARIANT {
                if variant_count == 0 {
                    let mut c2: u32 = 0;
                    let _ = self.variant_ordinal(hp.decl, &mut c2);
                    variant_count = c2;
                }
                nvar += 1;
            }
        }
        if tcov && fcov {
            return true;
        }
        return variant_count != 0 && nvar >= variant_count;
    }

    // The declared field node a constructor's slot `f` reads (named payloads/structs), or NONE.
    const fn slot_field_decl(self: &Self, p: &NPat, f: u32) NodeId {
        if p.kind == PC_STRUCT && p.decl.node != NODE_NONE {
            let a = unsafe &*(&*self.pkg).module_ast_const(p.decl.module);
            let ms = a.at_const(p.decl.node).as_data.aggregate.members;
            if f < ms.len {
                return unsafe a.list(ms)[f as usize];
            }
        }
        if p.kind == PC_VARIANT && p.decl.node != NODE_NONE {
            let a = unsafe &*(&*self.pkg).module_ast_const(p.decl.module);
            let ps = a.at_const(p.decl.node).as_data.variant.payload;
            if f < ps.len {
                return unsafe a.list(ps)[f as usize];
            }
        }
        return NODE_NONE;
    }

    // A pattern node whose checked type describes slot `f` (for the lowerer's place types).
    const fn slot_pat_node(self: &Self, p: &NPat, f: u32) NodeId {
        if f < p.sub_len {
            let sub = self.subs[(p.sub_start + f) as usize];
            return self.pats.at(sub as usize).node;
        }
        return NODE_NONE;
    }
}
