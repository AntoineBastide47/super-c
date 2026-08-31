// The shared pattern compiler: one algorithm for usefulness, exhaustiveness,
// unreachable arms, and match lowering. Typed source patterns normalize into a flat constructor
// form (or-patterns expand into extra rows, cap-bounded); a classic specialization matrix answers
// usefulness queries; a decision tree drives Core IR match lowering so no place is retested after
// its constructor is known on a path.
//
// Reads go through the typed-facts boundary plus package/declaration structure only. Constructor
// completeness is decided from the constructors themselves: enum variants against their declared
// member count (bit sets), booleans as a pair, tuples and structs as single constructors; integers,
// ranges, strings, floats, and every other literal are treated as never-complete, matching the
// established diagnostics (an integer switch needs a catch-all even when its ranges cover the
// domain). A work budget bounds adversarial or-pattern expansion; on overflow every query answers
// conservatively (assume exhaustive, assume reachable) and callers keep their legacy path.
import lexer::token as tok;
import lexer::token_type as tt;
import ast::ast as *;
import ast::facts as facts;
import module::loader as loader;

/// Normalized constructor kinds.
pub const PC_WILD: u8 = 0; // wildcard or a pure binding
pub const PC_VARIANT: u8 = 1; // val = ordinal; decl = variant; subs = payload
pub const PC_BOOL: u8 = 2; // val = 0/1
pub const PC_INT: u8 = 3; // val = literal value (decimal fast path; opaque otherwise)
pub const PC_RANGE: u8 = 4; // val/hi = bounds when both are plain decimals, else opaque
pub const PC_TUPLE: u8 = 5; // subs = elements (single, always-complete constructor)
pub const PC_STRUCT: u8 = 6; // decl = struct; subs = every field in decl order (absent = wild)
pub const PC_OPAQUE: u8 = 7; // string/float/const-path literal: only a wildcard covers it

pub const P_NONE: u32 = 0xFFFFFFFF;

/// One normalized pattern node (flat pools; subs index `subs` which indexes `pats`).
pub struct NPat {
    pub kind: u8,
    pub val: i64,
    pub hi: i64, // PC_RANGE upper bound; 1 = inclusive is packed in `arity`
    pub decl: DefId, // variant/struct declaration
    pub node: NodeId, // originating pattern node (bindings + diagnostics)
    pub sub_start: u32,
    pub sub_len: u32,
    pub arity: u32, // constructor arity (payload/field/element count); PC_RANGE: 1 = inclusive
}

/// One matrix row: a pattern per column plus its arm.
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
    // usefulness arena: matrices live as (start, len) row descriptors over a flat cell pool;
    // every recursion level appends behind a watermark and truncates on return, so a whole
    // query allocates only on first-capacity growth (the plan's flat-row requirement).
    mcells: Vector<u32>,
    mrows: Vector<u64>, // start << 32 | len
    seen: Vector<u32>, // distinct-head scratch, watermark-disciplined like the arenas
    pub budget: u32, // remaining work units; 0 = overflow, answer conservatively
    pub overflow: bool,
}

/// Decision-tree node kinds.
pub const DT_LEAF: u8 = 0; // arm chosen
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

extend DecisionTree as Free {
    pub fn free(self: &mut Self) {
        self.nodes.free();
        self.edges.free();
        self.paths.free();
    }
}

extend PatCx as Free {
    pub fn free(self: &mut Self) {
        self.pats.free();
        self.subs.free();
        self.cols.free();
        self.rows.free();
        self.mcells.free();
        self.mrows.free();
        self.seen.free();
    }
}

// Decimal literal fast path (sign included); ok=false for any other spelling.
/// The code point of a `'x'` / `b'x'` literal (escape rules mirror the checker's decode).
pub fn char_of(src: str, sp: tok::Span) Option<i64> {
    if sp.end <= sp.start + 2 {
        return Option::<i64>::None;
    }
    let mut i = sp.start + 1;
    if src[sp.start as usize] == b'b' {
        i = i + 1;
    }
    if i >= sp.end {
        return Option::<i64>::None;
    }
    if src[i as usize] != b'\\' {
        return Option::<i64>::Some(src[i as usize]);
    }
    if i + 1 >= sp.end {
        return Option::<i64>::None;
    }
    let e = src[(i + 1) as usize];
    if e == b'n' {
        return Option::<i64>::Some(10);
    }
    if e == b't' {
        return Option::<i64>::Some(9);
    }
    if e == b'r' {
        return Option::<i64>::Some(13);
    }
    if e == b'0' {
        return Option::<i64>::Some(0);
    }
    if e == b'\\' {
        return Option::<i64>::Some(92);
    }
    if e == 39 {
        return Option::<i64>::Some(39);
    }
    if e == 34 {
        return Option::<i64>::Some(34);
    }
    if e == b'x' {
        let mut v: i64 = 0;
        let mut k = i + 2;
        while k < sp.end - 1 {
            let c = src[k as usize];
            let d: i64 = if c >= b'0' && c <= b'9' {
                c - b'0';
            } else if c >= b'a' && c <= b'f' {
                c - b'a' + 10;
            } else if c >= b'A' && c <= b'F' {
                c - b'A' + 10;
            } else {
                -1;
            };
            if d < 0 {
                return Option::<i64>::None;
            }
            v = v * 16 + d;
            k = k + 1;
        }
        return Option::<i64>::Some(v);
    }
    return Option::<i64>::None;
}

fn dec_of(src: str, sp: tok::Span) Option<i64> {
    let mut i = sp.start as usize;
    let mut neg = false;
    if i < sp.end as usize && src[i] == b'-' {
        neg = true;
        i += 1;
    }
    if i >= sp.end as usize {
        return Option::<i64>::None;
    }
    let mut v: i64 = 0;
    while i < sp.end as usize {
        let b = src[i];
        if b < b'0' || b > b'9' {
            return Option::<i64>::None;
        }
        if v > 922337203685477580 {
            return Option::<i64>::None;
        }
        v = v * 10 + (b - b'0') as i64;
        i += 1;
    }
    if neg {
        v = 0 - v;
    }
    return Option::<i64>::Some(v);
}

extend PatCx {
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
            budget: 65536,
            overflow: false,
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
        self.pats.push(
            NPat {
                kind: PC_WILD,
                val: 0,
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

    // The enum decl containing variant `vd`, its ordinal, and the member count; ord -1 = unknown.
    pub fn variant_ordinal(self: &Self, vd: DefId, count: &mut u32) i64 {
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_ENUM {
                continue;
            }
            let ms = a.at_const(nid).as_data.aggregate.members;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == vd.node {
                    *count = ms.len;
                    return j;
                }
            }
        }
        *count = 0;
        return -1;
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

    // Normalize pattern `pid` into one or more alternatives appended to `out` (or-patterns fan
    // out; every other shape contributes exactly one id).
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
            let rd = self.f.node(pid).as_data.pattern_range;
            let lov = if rd.start != NODE_NONE {
                self.bound_dec(rd.start);
            } else {
                Option::<i64>::None;
            };
            let hiv = if rd.end != NODE_NONE {
                self.bound_dec(rd.end);
            } else {
                Option::<i64>::None;
            };
            let lo_ok = lov.is_some();
            let hi_ok = hiv.is_some();
            let lo = lov.unwrap_or(0);
            let hi = hiv.unwrap_or(0);
            // bounds the matrix cannot value (const paths, hex, open ends) key the range by its
            // NODE with the arity-2 sentinel: it covers nothing and equals only itself -- garbage
            // (0,0) bounds once merged every char range into one edge
            let opaque = !(lo_ok && hi_ok);
            self.pats.push(
                NPat {
                    kind: PC_RANGE,
                    val: if opaque {
                        pid;
                    } else {
                        lo;
                    },
                    hi: if opaque {
                        pid;
                    } else {
                        hi;
                    },
                    decl: DefId { module: 0, node: NODE_NONE },
                    node: pid,
                    sub_start: 0,
                    sub_len: 0,
                    arity: if opaque {
                        2;
                    } else if rd.inclusive {
                        1;
                    } else {
                        0;
                    },
                },
            );
            out.push(self.pats.len() as u32 - 1);
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
                // parenthesized pattern
                self.normalize(unsafe self.f.list(pd.children)[0], out);
                return;
            }
            self.norm_children(
                pid,
                DefId { module: 0, node: NODE_NONE },
                pd.children,
                false,
                0,
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
        self.pats.push(
            NPat {
                kind: PC_OPAQUE,
                val: pid,
                hi: 0,
                decl: DefId { module: 0, node: NODE_NONE },
                node: pid,
                sub_start: 0,
                sub_len: 0,
                arity: 0,
            },
        );
        out.push(self.pats.len() as u32 - 1);
    }

    const fn decl_kind(self: &Self, d: DefId) NodeKind {
        if d.node == NODE_NONE {
            return NodeKind::NODE_NONE_KIND;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(d.module);
        return a.at_const(d.node).kind;
    }

    fn bound_dec(self: &Self, b: NodeId) Option<i64> {
        let mut v = b;
        if self.f.node(v).kind == NodeKind::NODE_PATTERN_LITERAL {
            v = self.f.node(v).as_data.single.value;
        }
        if self.f.node(v).kind != NodeKind::NODE_LITERAL {
            return Option::<i64>::None;
        }
        let ld = self.f.node(v).as_data.literal;
        if ld.token_type == tt::TokenType::CharacterLiteral || ld.token_type == tt::TokenType::ByteCharacterLiteral {
            return char_of(self.src, ld.raw);
        }
        return dec_of(self.src, ld.raw);
    }

    fn norm_literal(self: &mut Self, pid: NodeId, out: &mut Vector<u32>) {
        let v = self.f.node(pid).as_data.single.value;
        let no = DefId { module: 0, node: NODE_NONE };
        let vk = self.f.node(v).kind;
        if vk == NodeKind::NODE_LITERAL {
            let ld = self.f.node(v).as_data.literal;
            if ld.token_type == tt::TokenType::True || ld.token_type == tt::TokenType::False {
                let bv: i64 = if ld.token_type == tt::TokenType::True {
                    1;
                } else {
                    0;
                };
                self.pats.push(
                    NPat { kind: PC_BOOL, val: bv, hi: 0, decl: no, node: pid, sub_start: 0, sub_len: 0, arity: 0 },
                );
                out.push(self.pats.len() as u32 - 1);
                return;
            }
            let ivo = dec_of(self.src, ld.raw);
            if ivo.is_some() {
                self.pats.push(
                    NPat {
                        kind: PC_INT,
                        val: ivo.unwrap(),
                        hi: 0,
                        decl: no,
                        node: pid,
                        sub_start: 0,
                        sub_len: 0,
                        arity: 0,
                    },
                );
                out.push(self.pats.len() as u32 - 1);
                return;
            }
        }
        // Chars, strings, floats, negated/hex spellings, const paths: opaque, keyed by node.
        self.pats.push(
            NPat { kind: PC_OPAQUE, val: pid, hi: 0, decl: no, node: pid, sub_start: 0, sub_len: 0, arity: 0 },
        );
        out.push(self.pats.len() as u32 - 1);
    }

    // A variant pattern: subs = the full payload in declaration order (`by_name` aligns struct-
    // payload fields through their resolved field decls; positional payloads align by index).
    fn norm_variant(self: &mut Self, pid: NodeId, vd: DefId, ch: NodeList, by_name: bool, out: &mut Vector<u32>) {
        let mut count: u32 = 0;
        let ord = self.variant_ordinal(vd, &mut count);
        let arity = self.variant_arity(vd);
        let a = unsafe &*(&*self.pkg).module_ast_const(vd.module);
        let payload = a.at_const(vd.node).as_data.variant.payload;
        self.norm_children(pid, vd, ch, by_name, vd.module, payload, arity, PC_VARIANT, ord, out);
    }

    fn norm_struct(self: &mut Self, pid: NodeId, sd: DefId, out: &mut Vector<u32>) {
        if sd.node == NODE_NONE || self.decl_kind(sd) != NodeKind::NODE_STRUCT {
            // an unresolved struct pattern covers nothing beyond itself
            self.pats.push(
                NPat {
                    kind: PC_OPAQUE,
                    val: pid,
                    hi: 0,
                    decl: DefId { module: 0, node: NODE_NONE },
                    node: pid,
                    sub_start: 0,
                    sub_len: 0,
                    arity: 0,
                },
            );
            out.push(self.pats.len() as u32 - 1);
            return;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(sd.module);
        let ms = a.at_const(sd.node).as_data.aggregate.members;
        let ch = self.f.node(pid).as_data.pattern.children;
        self.norm_children(pid, sd, ch, true, sd.module, ms, ms.len, PC_STRUCT, 0, out);
    }

    // Shared child alignment: build `arity` sub-slots (wild by default), place each listed child
    // pattern at its slot, expanding or-children into alternative parents (bounded).
    fn norm_children(
        self: &mut Self,
        pid: NodeId,
        decl: DefId,
        ch: NodeList,
        by_name: bool,
        dmod: ModuleId,
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
        // Normalize each child into its own alternative list first.
        let mut slot_alts = Vector::<Vector<u32>>::new();
        let mut slot_of = Vector::<i64>::new(); // child index -> slot ordinal
        for i in 0..ch.len {
            let cid = unsafe self.f.list(ch)[i as usize];
            let mut slot: i64 = i;
            let mut sub = cid;
            if by_name {
                // PATTERN_FIELD-shaped child: name resolves to the field decl; children[0] is the
                // sub-pattern (missing = a pure binding of the field name).
                let fpd = self.f.node(cid).as_data.pattern;
                let fd = self.f.res(fpd.name);
                slot = self.field_ordinal(dmod, dlist, fd.node);
                if fpd.children.len != 0 {
                    sub = unsafe self.f.list(fpd.children)[0];
                } else {
                    sub = NODE_NONE;
                }
            }
            let mut alts = Vector::<u32>::new();
            if sub == NODE_NONE {
                alts.push(self.wild(cid));
            } else {
                self.normalize(sub, &mut alts);
            }
            if alts.len() == 0 {
                alts.push(self.wild(cid));
            }
            slot_alts.push(alts);
            slot_of.push(slot);
        }
        // Cartesian expansion over children with several alternatives (nested or-patterns), bounded
        // by the budget; the common case is one alternative each = one parent.
        let mut cursors = Vector::<u32>::new();
        for i in 0..slot_alts.len() {
            cursors.push(0);
        }
        loop {
            if !self.spend(arity + 1) {
                out.push(self.wild(pid));
                return;
            }
            let sub_start = self.subs.len() as u32;
            // default every slot to wild, then place the children
            let mut slot_pat = Vector::<u32>::new();
            for s in 0..arity {
                slot_pat.push(P_NONE);
            }
            for i in 0..slot_alts.len() {
                let s = slot_of[i];
                if s >= 0 && s as u32 < arity {
                    slot_pat.set(s as usize, slot_alts.at(i)[cursors[i] as usize]);
                }
            }
            for s in 0..arity {
                let mut v = slot_pat[s as usize];
                if v == P_NONE {
                    v = self.wild(pid);
                }
                self.subs.push(v);
            }
            self.pats.push(
                NPat {
                    kind: kind,
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
            // advance the cartesian cursor
            let mut carried = true;
            let mut i2: usize = 0;
            while carried && i2 < cursors.len() {
                let c = cursors[i2] + 1;
                if c as usize < slot_alts.at(i2).len() {
                    cursors.set(i2, c);
                    carried = false;
                } else {
                    cursors.set(i2, 0);
                    i2 += 1;
                }
            }
            if carried {
                break;
            }
        }
    }

    // ---- matrix rows ------------------------------------------------------------------------------

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
        if rp.kind != qp.kind {
            // a range head covers an integer constructor inside its bounds
            if rp.kind == PC_RANGE && qp.kind == PC_INT && rp.arity <= 1 {
                let hi_in = if rp.arity == 1 {
                    qp.val <= rp.hi;
                } else {
                    qp.val < rp.hi;
                };
                return qp.val >= rp.val && hi_in;
            }
            return false;
        }
        if rp.kind == PC_VARIANT {
            return rp.val == qp.val && rp.decl.node == qp.decl.node;
        }
        if rp.kind == PC_BOOL || rp.kind == PC_INT {
            return rp.val == qp.val;
        }
        if rp.kind == PC_RANGE {
            return rp.val == qp.val && rp.hi == qp.hi && rp.arity == qp.arity;
        }
        if rp.kind == PC_OPAQUE {
            return rp.val == qp.val;
        }
        return true; // tuple/struct: single constructor
    }

    // Usefulness of the query row at mrows[qrow] against the matrix rows mrows[rs..rs+rn]
    // (classic specialization; or-patterns were expanded at normalization). All storage is the
    // watermarked arena: each level appends its specialized matrix + query and truncates on return.
    fn useful_rec(self: &mut Self, rs: usize, rn: usize, qrow: usize) bool {
        if !self.spend(rn as u32 + 1) {
            return false; // conservative: not useful => assume covered / unreachable never fires
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
        if q0k != PC_WILD {
            let r = self.useful_spec(rs, rn, qrow, q0);
            self.mcells.truncate(wm_c);
            self.mrows.truncate(wm_r);
            self.pats.truncate(wm_p);
            return r;
        }
        // q0 wild: distinct head constructors + completeness
        let wm_s = self.seen.len();
        let mut complete = false;
        let mut variant_count: u32 = 0;
        let mut vmask = Cover4x {};
        let mut tcov = false;
        let mut fcov = false;
        let mut single = P_NONE;
        for r in 0..rn {
            let row = self.mrows[rs + r];
            let h = self.mcells[(row >> 32) as usize];
            let hp = self.pats.at(h as usize);
            if hp.kind == PC_WILD {
                continue;
            }
            if hp.kind == PC_VARIANT {
                if variant_count == 0 {
                    let mut c2: u32 = 0;
                    let _ = self.variant_ordinal(hp.decl, &mut c2);
                    variant_count = c2;
                }
                if hp.val >= 0 && hp.val < 256 {
                    let ix = (hp.val >> 6) as usize;
                    unsafe {
                        vmask.b[ix] = vmask.b[ix] | 1u64 << (hp.val & 63) as u64;
                    }
                }
            } else if hp.kind == PC_BOOL {
                if hp.val != 0 {
                    tcov = true;
                } else {
                    fcov = true;
                }
            } else if hp.kind == PC_TUPLE || hp.kind == PC_STRUCT {
                single = h;
            }
            let mut dup = false;
            for s2 in wm_s..self.seen.len() {
                let sv = self.seen[s2];
                if self.head_covers(sv, h) && self.head_covers(h, sv) {
                    dup = true;
                }
            }
            if !dup {
                self.seen.push(h);
            }
        }
        if single != P_NONE {
            complete = true;
        } else if tcov && fcov {
            complete = true;
        } else if variant_count != 0 && variant_count <= 256 {
            let mut n: u32 = 0;
            for w in 0..4 {
                let mut bits = unsafe vmask.b[w as usize];
                while bits != 0 {
                    bits = bits & bits - 1;
                    n += 1;
                }
            }
            complete = n >= variant_count;
        }
        if !complete {
            // default matrix: wild-headed rows, minus the column
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
            self.mcells.truncate(wm_c);
            self.mrows.truncate(wm_r);
            self.pats.truncate(wm_p);
            self.seen.truncate(wm_s);
            return r;
        }
        // complete head set: useful iff useful under some constructor
        let seen_end = self.seen.len();
        let mut s2 = wm_s;
        while s2 < seen_end {
            let rep = self.seen[s2];
            let r = self.useful_ctor(rs, rn, qrow, rep);
            if r {
                self.mcells.truncate(wm_c);
                self.mrows.truncate(wm_r);
                self.pats.truncate(wm_p);
                self.seen.truncate(wm_s);
                return true;
            }
            self.mcells.truncate(wm_c);
            self.mrows.truncate(wm_r);
            self.pats.truncate(wm_p);
            s2 += 1;
        }
        self.seen.truncate(wm_s);
        return false;
    }

    // Specialize on the QUERY's own constructor q0 and recurse.
    fn useful_spec(self: &mut Self, rs: usize, rn: usize, qrow: usize, q0: u32) bool {
        let q = self.mrows[qrow];
        let qs = (q >> 32) as usize;
        let ql = (q & 0xFFFFFFFFu64) as usize;
        let arity = self.pats.at(q0 as usize).sub_len as usize;
        let nrs = self.mrows.len();
        let mut nrn: usize = 0;
        for r in 0..rn {
            let row = self.mrows[rs + r];
            let rstart = (row >> 32) as usize;
            let rlen = (row & 0xFFFFFFFFu64) as usize;
            let h = self.mcells[rstart];
            if !self.head_covers(h, q0) {
                continue;
            }
            let hp = *self.pats.at(h as usize);
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
            for c in 1..rlen {
                self.mcells.push(self.mcells[rstart + c]);
            }
            self.mrows.push(ns as u64 << 32 | (arity + rlen - 1) as u64);
            nrn += 1;
        }
        let qp = *self.pats.at(q0 as usize);
        let nqs = self.mcells.len();
        for k in 0..qp.sub_len {
            self.mcells.push(self.subs[(qp.sub_start + k) as usize]);
        }
        for c in 1..ql {
            self.mcells.push(self.mcells[qs + c]);
        }
        let nq = self.mrows.len();
        self.mrows.push(nqs as u64 << 32 | (arity + ql - 1) as u64);
        return self.useful_rec(nrs, nrn, nq);
    }

    // Specialize on head constructor `rep` with a wild-expanded query and recurse.
    fn useful_ctor(self: &mut Self, rs: usize, rn: usize, qrow: usize, rep: u32) bool {
        let q = self.mrows[qrow];
        let qs = (q >> 32) as usize;
        let ql = (q & 0xFFFFFFFFu64) as usize;
        let arity = self.pats.at(rep as usize).sub_len as usize;
        let nrs = self.mrows.len();
        let mut nrn: usize = 0;
        for r in 0..rn {
            let row = self.mrows[rs + r];
            let rstart = (row >> 32) as usize;
            let rlen = (row & 0xFFFFFFFFu64) as usize;
            let h = self.mcells[rstart];
            let hp = *self.pats.at(h as usize);
            let cov = if hp.kind == PC_WILD {
                true;
            } else {
                self.head_covers(h, rep) && self.head_covers(rep, h);
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
            for c in 1..rlen {
                self.mcells.push(self.mcells[rstart + c]);
            }
            self.mrows.push(ns as u64 << 32 | (arity + rlen - 1) as u64);
            nrn += 1;
        }
        let qn = self.pats.at(self.mcells[qs] as usize).node;
        let nqs = self.mcells.len();
        for k in 0..arity {
            let w = self.wild(qn);
            self.mcells.push(w);
        }
        for c in 1..ql {
            self.mcells.push(self.mcells[qs + c]);
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
}

// 256-variant coverage scratch (mirrors the typechecker's cap).
struct Cover4x {
    pub b: [u64; 4],
}

// One in-flight decision-tree row: patterns with their occurrence paths, plus the arm it selects.
struct RowB {
    pub pats: Vector<u32>,
    pub occs: Vector<u32>, // DtPath ids, parallel to pats
    pub arm: u32,
}

extend PatCx {
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
        // path 0 = the scrutinee itself
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
        let mut rows = Vector::<RowB>::new();
        for r in 0..self.rows.len() {
            let row = *self.rows.at(r);
            let mut pv = Vector::<u32>::new();
            let mut ov = Vector::<u32>::new();
            for c in 0..row.len {
                pv.push(self.cols[(row.start + c) as usize]);
                ov.push(0);
            }
            rows.push(RowB { pats: pv, occs: ov, arm: row.arm });
        }
        t.root = self.tree_rec(&mut t, &rows);
        if self.overflow {
            t.ok = false;
        }
        return t;
    }

    fn tree_leaf(self: &Self, t: &mut DecisionTree, kind: u8, arm: u32) u32 {
        t.nodes.push(DtNode { kind: kind, arm: arm, place: P_NONE, edge_start: 0, edge_len: 0, default_child: P_NONE });
        return t.nodes.len() as u32 - 1;
    }

    fn tree_rec(self: &mut Self, t: &mut DecisionTree, rows: &Vector<RowB>) u32 {
        if !self.spend(rows.len() as u32 + 1) {
            return self.tree_leaf(t, DT_FAIL, 0);
        }
        if rows.len() == 0 {
            return self.tree_leaf(t, DT_FAIL, 0);
        }
        // first row all-wild: it matches; later rows are this path's dead tail
        let r0 = rows.at(0);
        let mut col: i64 = -1;
        for c in 0..r0.pats.len() {
            if self.pats.at(r0.pats[c] as usize).kind != PC_WILD {
                col = c as i64;
                break;
            }
        }
        if col < 0 {
            // pick the leftmost column any row tests, else the first row wins outright
            for c in 0..r0.pats.len() {
                let mut any = false;
                for r in 1..rows.len() {
                    if self.pats.at(rows.at(r).pats[c] as usize).kind != PC_WILD {
                        any = true;
                    }
                }
                if any {
                    col = c as i64;
                    break;
                }
            }
            if col < 0 {
                return self.tree_leaf(t, DT_LEAF, r0.arm);
            }
            // the first row is wild in the test column too, so it still wins: emitting the test
            // first would only grow the tree; take the leaf directly (bindings re-walk the arm).
            return self.tree_leaf(t, DT_LEAF, r0.arm);
        }
        let c = col as usize;
        // distinct head constructors in the column
        let mut seen = Vector::<u32>::new();
        for r in 0..rows.len() {
            let h = rows.at(r).pats[c];
            if self.pats.at(h as usize).kind == PC_WILD {
                continue;
            }
            let mut dup = false;
            for s2 in 0..seen.len() {
                if self.head_covers(seen[s2], h) && self.head_covers(h, seen[s2]) {
                    dup = true;
                }
            }
            if !dup {
                seen.push(h);
            }
        }
        let complete = self.ctors_complete(&seen);
        // build one child per constructor
        let mut children = Vector::<u32>::new();
        for s2 in 0..seen.len() {
            let rep = seen[s2];
            let arity = self.pats.at(rep as usize).sub_len;
            let repp = *self.pats.at(rep as usize);
            // sub-occurrence paths for this constructor
            let occ = rows.at(0).occs[c];
            let mut sub_paths = Vector::<u32>::new();
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
                sub_paths.push(t.paths.len() as u32 - 1);
            }
            let mut nrs = Vector::<RowB>::new();
            for r in 0..rows.len() {
                let row = rows.at(r);
                let h = row.pats[c];
                let hp = *self.pats.at(h as usize);
                let cov = if hp.kind == PC_WILD {
                    true;
                } else {
                    self.head_covers(h, rep) && self.head_covers(rep, h);
                };
                if !cov {
                    continue;
                }
                let mut pv = Vector::<u32>::new();
                let mut ov = Vector::<u32>::new();
                if hp.kind == PC_WILD {
                    for f in 0..arity {
                        let w = self.wild(hp.node);
                        pv.push(w);
                        ov.push(sub_paths[f as usize]);
                    }
                } else {
                    for f in 0..hp.sub_len {
                        pv.push(self.subs[(hp.sub_start + f) as usize]);
                        ov.push(sub_paths[f as usize]);
                    }
                }
                for c2 in 0..row.pats.len() {
                    if c2 != c {
                        pv.push(row.pats[c2]);
                        ov.push(row.occs[c2]);
                    }
                }
                nrs.push(RowB { pats: pv, occs: ov, arm: row.arm });
            }
            let child = self.tree_rec(t, &nrs);
            children.push(child);
        }
        // default child for an incomplete constructor set
        let mut dchild = P_NONE;
        if !complete {
            let mut nrs = Vector::<RowB>::new();
            for r in 0..rows.len() {
                let row = rows.at(r);
                if self.pats.at(row.pats[c] as usize).kind != PC_WILD {
                    continue;
                }
                let mut pv = Vector::<u32>::new();
                let mut ov = Vector::<u32>::new();
                for c2 in 0..row.pats.len() {
                    if c2 != c {
                        pv.push(row.pats[c2]);
                        ov.push(row.occs[c2]);
                    }
                }
                nrs.push(RowB { pats: pv, occs: ov, arm: row.arm });
            }
            dchild = self.tree_rec(t, &nrs);
        }
        let estart = t.edges.len() as u32;
        for s2 in 0..seen.len() {
            t.edges.push(DtEdge { pat: seen[s2], child: children[s2] });
        }
        t.nodes.push(
            DtNode {
                kind: DT_TEST,
                arm: 0,
                place: rows.at(0).occs[c],
                edge_start: estart,
                edge_len: seen.len() as u32,
                default_child: dchild,
            },
        );
        return t.nodes.len() as u32 - 1;
    }

    // Is the collected head-constructor set complete for its column type?
    fn ctors_complete(self: &Self, seen: &Vector<u32>) bool {
        let mut tcov = false;
        let mut fcov = false;
        let mut variant_count: u32 = 0;
        let mut nvar: u32 = 0;
        for s2 in 0..seen.len() {
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
