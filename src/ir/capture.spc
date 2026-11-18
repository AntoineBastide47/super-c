// Which reference and pointer parameters a call may let outlive it: per kept function body (the borrow
// checker's lowerings, `irl::Keep`), the parameters whose pointer, or a pointer into whose referent, the
// body stores outside its locals and its result, turns into an integer, captures in a closure, or hands
// to a call that may let it escape. A reference erased to a raw pointer ends its borrow at once and the
// pointer stays valid, so after the call anyone may write such a parameter's target; the Core facts
// (`ir::facts`) take a `&mut` argument of any other call to stay in the call. A pointer the body loads
// from the referent is not followed: it points at storage the referent owns, or at storage whose
// address the caller stored into it, which the caller's own escape scan marks.
//
// One scan per body, flow-insensitive over the values each local may hold (a fixed number of rounds,
// else every parameter escapes), then one worklist over the call edges: a parameter escapes when an
// argument it reaches does, or reaches a call of no kept body (a function value, an extern function).
// A call of an interface member reaches every kept body of its name that a conformance or the
// interface declares (the borrow pass keeps each conformance method of a member a kept body calls).
// Linear in the bodies' statements and call edges.
import ast::ast as *;
import ir::core as ir;
import ir::lower as irl;
import module::loader as loader;

// The rounds a body's scan runs before it gives up (every parameter escapes).
const SCAN_ROUNDS: u32 = 8;

// The scans per entry the results' summaries (`CaptureStore.ret`) may take before every result points
// into every parameter.
const RET_SCANS: usize = 8;

// An edge target that is the group of an interface member's name (`CaptureStore.gix`), not a body.
const GROUP: u64 = 1u64 << 63;

const fn key_of(d: DefId) u64 {
    return d.module as u64 << 32 | d.node as u64;
}

// A call edge: argument `arg` of a call in body `from` (index into `CaptureStore.esc`) points into
// what parameter `bit` of that body points into; the call runs entry `to`.
@derive(Copy)
struct Edge {
    to: u32,
    from: u32,
    bit: u32,
    arg: u32,
}

pub(package) struct CaptureStore {
    ix: Map<u64, u64>, // body key -> index into `esc`
    gix: Map<u64, u64>, // interface member name -> index into `esc` of its group
    esc: Vector<u64>, // per kept function body and per group, the parameters (bits, the first 64) that may escape
    ret: Vector<u64>, // per entry of `esc`, the parameters the result may point into
    rlen: Vector<u32>, // per entry of `esc`, the parameter every result's view length equals, or IR_NONE
    grp: Vector<u32>, // per entry of `esc`, the group a body belongs to, or IR_NONE
    src: Vector<u32>, // per entry of `esc`, the index of its body in the keep, or IR_NONE for a group
    blk: Vector<u32>, // per entry of `esc`, the start of its body's blocks in `tgt`
    tgt: Vector<u32>, // per block of each body, the entry its call runs, or IR_NONE (no call, none known)
}

// What one scan of a body found: the parameters that escape, and those the result may point into.
struct Scan {
    esc: u64,
    ret: u64,
}

extend CaptureStore {
    pub(package) fn new() CaptureStore {
        return CaptureStore {
            ix: Map::<u64, u64>::new(),
            gix: Map::<u64, u64>::new(),
            esc: Vector::<u64>::new(),
            ret: Vector::<u64>::new(),
            rlen: Vector::<u32>::new(),
            grp: Vector::<u32>::new(),
            src: Vector::<u32>::new(),
            blk: Vector::<u32>::new(),
            tgt: Vector::<u32>::new(),
        };
    }

    // The entry call target `to` (`target`) runs, or IR_NONE: no kept body, or none known.
    fn entry(self: &Self, to: u64) u32 {
        if to == 0 {
            return ir::IR_NONE;
        }
        let m = if (to & GROUP) != 0 {
            self.gix.get(&(to & ~GROUP))
        } else {
            self.ix.get(&to)
        };
        return switch m {
            Some(x) => (*x) as u32,
            None => ir::IR_NONE,
        };
    }

    /// Whether call `t` keeps no pointer it reaches from its argument `i` past the call: each kept body
    /// it may run lets parameter `i` escape nowhere.
    pub(package) fn keeps_none(self: &Self, pkg: *const loader::Package, t: &ir::Terminator, i: u32) bool {
        let x = self.entry(target(pkg, t));
        return x != ir::IR_NONE && i < 64 && (self.esc[x as usize] >> i as u64 & 1) == 0;
    }

    /// Whether no result of call `t` may point into what its argument `i` points into (each kept body it
    /// may run returns no pointer from parameter `i`).
    pub(package) fn returns_none(self: &Self, pkg: *const loader::Package, t: &ir::Terminator, i: u32) bool {
        let x = self.entry(target(pkg, t));
        return x != ir::IR_NONE && i < 64 && (self.ret[x as usize] >> i as u64 & 1) == 0;
    }

    /// The argument of call `t` that the length of the view it returns equals (each kept body it may run
    /// builds its result from that parameter, `view_len_param`), or IR_NONE.
    pub(package) fn returns_len(self: &Self, pkg: *const loader::Package, t: &ir::Terminator) u32 {
        let x = self.entry(target(pkg, t));
        return if x == ir::IR_NONE {
            ir::IR_NONE
        } else {
            self.rlen[x as usize]
        };
    }

    /// The facts a direct call of function `d` reads (`keeps_none`, `returns_none`, `returns_len`) as one
    /// hash; 0 when no kept body answers for it.
    pub(package) fn summary(self: &Self, p: &loader::Package, d: DefId) u64 {
        let a = unsafe &*p.module_ast_const(d.module);
        let c = a.container_of(d.node);
        let x = self.entry(
            if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_INTERFACE {
                GROUP | name_key(p, d)
            } else {
                key_of(d)
            },
        );
        if x == ir::IR_NONE {
            return 0;
        }
        let h = (self.esc[x as usize] ^ 0x9E3779B97F4A7C15u64).wrapping_mul(0x100000001B3u64) ^ self.ret[x as usize];
        return h.wrapping_mul(0x100000001B3u64) ^ self.rlen[x as usize] as u64 | 1;
    }

    /// The parameters of every kept function body of `keep` that may escape.
    pub(package) fn build(self: &mut Self, pkg: *const loader::Package, keep: &irl::Keep) {
        for i in 0..keep.kept.len() {
            let b = &keep.kept.at(i).body;
            if b.owner.node == NODE_NONE || Ast::in_body(b.owner.node) {
                continue;
            }
            let k = key_of(b.owner);
            if self.ix.contains_key(&k) {
                continue;
            }
            let at = self.esc.len() as u32;
            self.ix.insert(k, at);
            self.push_entry(i as u32);
            let g = group_of(pkg, b.owner);
            if g != 0 {
                if !self.gix.contains_key(&g) {
                    self.gix.insert(g, self.esc.len() as u64);
                    self.push_entry(ir::IR_NONE);
                }
                self.grp.set(at as usize, (*self.gix.get(&g).unwrap()) as u32);
            }
        }
        // The parameters each result may point into, from none up to the least fixed point: a body scans
        // again when the result of an entry one of its calls with destinations runs grows (`pairs`, from
        // `first`). Past the bound on rescans, every result may point into every parameter. Then one scan
        // per body finds its escapes and call edges under the final results.
        let n = self.esc.len();
        let mut pairs = Vector::<u64>::new(); // entry << 32 | calling body
        let mut queued = Vector::<bool>::new();
        queued.resize_default(n);
        let mut rescan = Vector::<u32>::new();
        let mut views = Vector::<u32>::new(); // the entries whose body returns a prelude view
        for x in 0..n {
            self.blk.push(self.tgt.len() as u32);
            if self.src[x] == ir::IR_NONE {
                continue;
            }
            let b = &keep.kept.at(self.src[x] as usize).body;
            // A scalar result returns no pointer: its body needs no scan for it, and no rescan.
            let scalar = scalar_result(pkg, b);
            if !scalar {
                rescan.push(x as u32);
                queued.set(x, true);
                if view_result(pkg, b) {
                    views.push(x as u32);
                }
            }
            for k in 0..b.blocks.len() {
                let t = b.blocks.at(k).term;
                let e = if t.kind == ir::TM_CALL {
                    self.entry(target(pkg, &t))
                } else {
                    ir::IR_NONE
                };
                self.tgt.push(e);
                if e != ir::IR_NONE && t.dests_len != 0 && t.args_len != 0 && !scalar {
                    pairs.push(e as u64 << 32 | x as u64);
                }
            }
        }
        pairs.sort();
        let mut first = Vector::<u32>::new(); // per entry, the start of its callers in `pairs`
        first.resize_default(n + 1);
        for q in 0..pairs.len() {
            let e = (pairs[q] >> 32) as usize;
            first.set(e + 1, first[e + 1] + 1);
        }
        for e in 0..n {
            first.set(e + 1, first[e + 1] + first[e]);
        }
        let mut edges = Vector::<Edge>::new();
        let mut held = Vector::<u64>::new();
        let mut budget = RET_SCANS * n;
        while rescan.len() != 0 {
            if budget == 0 {
                for x in 0..n {
                    self.ret.set(x, ~0u64);
                }
                break;
            }
            budget -= 1;
            let x = rescan.pop().unwrap() as usize;
            queued.set(x, false);
            let r = scan(pkg, self, &keep.kept.at(self.src[x] as usize).body, x as u32, &mut edges, &mut held, false).ret;
            if r == self.ret[x] {
                continue;
            }
            self.ret.set(x, r);
            let g = self.grp[x];
            let mut grew = x as u32;
            if g != ir::IR_NONE && (self.ret[g as usize] | r) != self.ret[g as usize] {
                self.ret.set(g as usize, self.ret[g as usize] | r);
                grew = g;
            }
            // The callers of the body, and of its group when the group's result grew.
            let mut e = x as u32;
            for _ in 0..2 {
                for q in first[e as usize]..first[e as usize + 1] {
                    let c = (pairs[q as usize] & 0xFFFFFFFFu64) as usize;
                    if !queued[c] {
                        queued.set(c, true);
                        rescan.push(c as u32);
                    }
                }
                if grew == e {
                    break;
                }
                e = grew;
            }
        }
        // The parameter each view result's length equals, from none: a summary is set only from those
        // already set, so every round's summaries hold; rounds stop when none changes, at most RET_SCANS.
        let mut lv = Vector::<u32>::new();
        for _ in 0..RET_SCANS {
            let mut changed = false;
            for v in 0..views.len() {
                let x = views[v] as usize;
                let r = view_len_param(pkg, self, &keep.kept.at(self.src[x] as usize).body, &mut lv);
                if r != self.rlen[x] {
                    self.rlen.set(x, r);
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        for x in 0..self.esc.len() {
            if self.src[x] != ir::IR_NONE {
                let e = scan(pkg, self, &keep.kept.at(self.src[x] as usize).body, x as u32, &mut edges, &mut held, true).esc;
                self.esc.set(x, e);
            }
        }
        // A group lets a parameter escape when one of its bodies does.
        for x in 0..self.esc.len() {
            let g = self.grp[x];
            if g != ir::IR_NONE {
                let m = self.esc[g as usize] | self.esc[x];
                self.esc.set(g as usize, m);
            }
        }
        // The edges by the entry they run (`into`, from `efirst`), for the worklist.
        let mut into = Vector::<u64>::new(); // entry << 32 | edge
        for e in 0..edges.len() {
            into.push(edges[e].to as u64 << 32 | e as u64);
        }
        into.sort();
        let mut efirst = Vector::<u32>::new();
        efirst.resize_default(n + 1);
        for q in 0..into.len() {
            let e = (into[q] >> 32) as usize;
            efirst.set(e + 1, efirst[e + 1] + 1);
        }
        for e in 0..n {
            efirst.set(e + 1, efirst[e + 1] + efirst[e]);
        }
        let mut work = Vector::<u64>::new();
        for x in 0..n {
            let m = self.esc[x];
            for bit in 0..64u64 {
                if (m >> bit & 1) != 0 {
                    work.push(x as u64 << 6 | bit);
                }
            }
        }
        // Each (entry, parameter) enters the worklist once: when its bit is set.
        while work.len() != 0 {
            let w = work.pop().unwrap();
            let x = (w >> 6) as usize;
            let bit = (w & 63) as u32;
            let g = self.grp[x];
            if g != ir::IR_NONE {
                self.set(g, bit, &mut work);
            }
            for q in efirst[x]..efirst[x + 1] {
                let ed = edges[(into[q as usize] & 0xFFFFFFFFu64) as usize];
                if ed.arg == bit {
                    self.set(ed.from, ed.bit, &mut work);
                }
            }
        }
    }

    // A new entry for kept body `src` (IR_NONE: a group): nothing escapes or returns yet.
    fn push_entry(self: &mut Self, src: u32) {
        self.esc.push(0);
        self.ret.push(0);
        self.rlen.push(ir::IR_NONE);
        self.grp.push(ir::IR_NONE);
        self.src.push(src);
    }

    // Parameter `bit` of entry `x` escapes; newly, it joins the worklist.
    fn set(self: &mut Self, x: u32, bit: u32, work: &mut Vector<u64>) {
        let m = 1u64 << bit as u64;
        let old = self.esc[x as usize];
        if (old & m) == 0 {
            self.esc.set(x as usize, old | m);
            work.push(x as u64 << 6 | bit as u64);
        }
    }
}

// The name of function `d` as a hash, when a call of an interface member may run its body: a member
// of an interface (a default) or of a conformance; else 0.
fn group_of(pkg: *const loader::Package, d: DefId) u64 {
    let p = unsafe &*pkg;
    let a = unsafe &*p.module_ast_const(d.module);
    let c = a.container_of(d.node);
    if c == NODE_NONE {
        return 0;
    }
    let k = a.at_const(c).kind;
    if k != NodeKind::NODE_INTERFACE && (k != NodeKind::NODE_EXTEND || a.ext(c).extend_def.interface_type == NODE_NONE) {
        return 0;
    }
    return name_key(p, d);
}

// Whether every result of body `b` is a scalar: it returns no pointer into a parameter.
fn scalar_result(pkg: *const loader::Package, b: &ir::CoreBody) bool {
    let da = unsafe &*(&*pkg).module_ast_const(b.module);
    for i in 0..b.returns {
        if i as usize < b.locals.len() && da.type_at(b.locals.at(i as usize).ty).kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
    }
    return true;
}

// Whether body `b` returns one value of a prelude struct (a view: a slice, a string).
fn view_result(pkg: *const loader::Package, b: &ir::CoreBody) bool {
    if b.returns != 1 || b.locals.len() == 0 {
        return false;
    }
    let p = unsafe &*pkg;
    let da = unsafe &*p.module_ast_const(b.module);
    let y = *da.type_at(b.locals.at(0).ty);
    let m = if y.kind == TypeKind::TYPE_STRUCT {
        y.module
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        da.instance(y.as_data.inst).module
    } else {
        return false;
    };
    return m as usize < p.modules.len() && p.modules.at(m as usize).prelude;
}

/// Whether member `sub` of a value of type `view_ty` (in `b`'s module) is the prelude struct field `name`.
pub(package) const fn prelude_field(
    pkg: *const loader::Package,
    b: &ir::CoreBody,
    view_ty: TypeId,
    sub: NodeId,
    name: str,
) bool {
    if view_ty == TYPE_NONE || sub == NODE_NONE {
        return false;
    }
    let pk = unsafe &*pkg;
    let da = unsafe &*pk.module_ast_const(b.module);
    let y = *da.type_at(view_ty);
    let mut m: ModuleId = 0;
    if y.kind == TypeKind::TYPE_STRUCT {
        m = y.module;
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        m = da.instance(y.as_data.inst).module;
    } else {
        return false;
    }
    if m as usize >= pk.modules.len() || !pk.modules.at(m as usize).prelude {
        return false;
    }
    let fa = unsafe &*pk.module_ast_const(m);
    let fnode = fa.at_const(sub);
    if fnode.kind != NodeKind::NODE_FIELD {
        return false;
    }
    let ns = fa.at_const(fnode.as_data.field.name).as_data.name.text;
    let src = pk.modules.at(m as usize).source.as_str();
    return src.slice(ns.start as usize, ns.end as usize) == name;
}

/// The operand of the `len` member of struct literal `rv` of a prelude view, or IR_NONE.
pub(package) fn view_len_operand(pkg: *const loader::Package, b: &ir::CoreBody, rv: &ir::Rvalue) u32 {
    let pk = unsafe &*pkg;
    if rv.kind != ir::RV_AGGREGATE || rv.c != ir::AGG_STRUCT || rv.item.node == NODE_NONE || !pk.modules.at(
        rv.item.module as usize,
    ).prelude {
        return ir::IR_NONE;
    }
    let da = unsafe &*pk.module_ast_const(rv.item.module);
    let members = da.ext(rv.item.node).aggregate.members;
    for j in 0..members.len {
        let opid = b.oper_pool[(rv.a + j) as usize];
        if opid != ir::IR_NONE && prelude_field(pkg, b, rv.target, unsafe da.list(members)[j as usize], "len") {
            return opid;
        }
    }
    return ir::IR_NONE;
}

// A local's state in `view_len_param`: no definition seen yet, or definitions that disagree or are not
// tracked; a tracked value is a parameter index plus LV_PARAM.
const LV_UNSET: u32 = 0;
const LV_NONE: u32 = 1;
const LV_PARAM: u32 = 2;

// `s` after one more definition of value `v` (LV_UNSET: not known yet, skipped).
const fn lv_merge(s: u32, v: u32) u32 {
    return if v == LV_UNSET || s == v {
        s
    } else if s == LV_UNSET {
        v
    } else {
        LV_NONE
    };
}

// The whole local operand `opid` copies or moves, or IR_NONE.
const fn whole_op_local(b: &ir::CoreBody, opid: u32) u32 {
    if opid == ir::IR_NONE {
        return ir::IR_NONE;
    }
    let op = *b.operands.at(opid as usize);
    if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE || b.places.at(op.data as usize).proj_len != 0 {
        return ir::IR_NONE;
    }
    return b.places.at(op.data as usize).base;
}

// The parameter whose value the length of every view body `b` returns equals, or IR_NONE: the result
// is a prelude view literal whose `len` is that parameter, a copy of such a value, or the result of a
// call that returns a view of that parameter (`CaptureStore::returns_len`), and no statement writes or
// borrows the parameter. Flow-insensitive over the definitions of whole locals (statements and call
// destinations write locals; a source not defined yet counts at its definition); a local written in
// part, borrowed or addressed is not tracked. `lv` is scratch: per local the value it holds (`n`), then the view length
// it holds (`n + l`).
fn view_len_param(pkg: *const loader::Package, st: &CaptureStore, b: &ir::CoreBody, lv: &mut Vector<u32>) u32 {
    let n = b.locals.len();
    if b.has_reflect || b.has_lists {
        return ir::IR_NONE;
    }
    lv.truncate(0);
    lv.resize_default(2 * n);
    for i in 0..b.args {
        let l = (b.returns + i) as usize;
        if l < n {
            lv.set(l, LV_PARAM + i);
            lv.set(n + l, LV_NONE);
        }
    }
    let mut settled = false;
    for _ in 0..SCAN_ROUNDS {
        let mut changed = false;
        for k in 0..b.blocks.len() {
            let bb = b.blocks.at(k);
            for si in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let s = *b.statements.at(si as usize);
                if s.kind != ir::ST_ASSIGN {
                    continue;
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
                    changed = lv_kill(lv, n, b.places.at(rv.a as usize).base as usize) || changed;
                }
                let pl = b.places.at(s.place as usize);
                let l = pl.base as usize;
                let mut val = LV_NONE;
                let mut vl = LV_NONE;
                if pl.proj_len == 0 {
                    if rv.kind == ir::RV_USE {
                        let q = whole_op_local(b, rv.a);
                        if q != ir::IR_NONE {
                            val = lv[q as usize];
                            vl = lv[n + q as usize];
                        }
                    } else if rv.kind == ir::RV_AGGREGATE {
                        let q = whole_op_local(b, view_len_operand(pkg, b, &rv));
                        if q != ir::IR_NONE {
                            vl = lv[q as usize];
                        }
                    }
                }
                changed = lv_def(lv, n, l, val, vl) || changed;
            }
            let t = b.blocks.at(k).term;
            if t.kind != ir::TM_CALL {
                continue;
            }
            let j = if t.dests_len == 1 {
                st.returns_len(pkg, &t)
            } else {
                ir::IR_NONE
            };
            for i in 0..t.dests_len {
                let pl = b.places.at(b.dest_pool[(t.dests_start + i) as usize] as usize);
                let mut vl = LV_NONE;
                if j < t.args_len && pl.proj_len == 0 {
                    let q = whole_op_local(b, b.oper_pool[(t.args_start + j) as usize]);
                    if q != ir::IR_NONE {
                        vl = lv[q as usize];
                    }
                }
                changed = lv_def(lv, n, pl.base as usize, LV_NONE, vl) || changed;
            }
        }
        if !changed {
            settled = true;
            break;
        }
    }
    let r = if n == 0 {
        LV_NONE
    } else {
        lv[n]
    };
    return if settled && r >= LV_PARAM {
        r - LV_PARAM
    } else {
        ir::IR_NONE
    };
}

// One definition of local `l`: value `val` and view length `vl`. True when either state changed.
const fn lv_def(lv: &mut Vector<u32>, n: usize, l: usize, val: u32, vl: u32) bool {
    let a = lv_merge(lv[l], val);
    let c = lv_merge(lv[n + l], vl);
    let changed = a != lv[l] || c != lv[n + l];
    lv.set(l, a);
    lv.set(n + l, c);
    return changed;
}

// Local `l` is borrowed: neither its value nor its view length is tracked. True when either changed.
const fn lv_kill(lv: &mut Vector<u32>, n: usize, l: usize) bool {
    let changed = lv[l] != LV_NONE || lv[n + l] != LV_NONE;
    lv.set(l, LV_NONE);
    lv.set(n + l, LV_NONE);
    return changed;
}

// The FNV-1a hash of function `d`'s name, never 0.
fn name_key(p: &loader::Package, d: DefId) u64 {
    let a = unsafe &*p.module_ast_const(d.module);
    let s = a.at_const(a.ext_name(d.node)).as_data.name.text;
    let src = p.modules.at(d.module as usize).source.as_str();
    let mut h: u64 = 0xcbf29ce484222325u64;
    for i in s.start as usize..s.end as usize {
        h = (h ^ src.byte_at(i) as u64).wrapping_mul(0x100000001b3u64);
    }
    return h & ~GROUP | 1;
}

// What call `t` runs: the key of its callee's body; GROUP | the callee's name for an interface member
// (any conformance's method of that name, or the default); 0 when unknown (a function value, a
// variadic or verified intrinsic call, an inherited default dispatched by `iface` on no member).
fn target(pkg: *const loader::Package, t: &ir::Terminator) u64 {
    if t.callee.node == NODE_NONE || t.is_variadic || t.intr != ir::CI_NONE {
        return 0;
    }
    let p = unsafe &*pkg;
    if t.callee.module as usize >= p.modules.len() || !p.modules.at(t.callee.module as usize).has_ast {
        return 0;
    }
    let a = unsafe &*p.module_ast_const(t.callee.module);
    let c = a.container_of(t.callee.node);
    if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_INTERFACE {
        return GROUP | name_key(p, t.callee);
    }
    if t.iface != TYPE_NONE {
        return 0;
    }
    return key_of(t.callee);
}

// The parameters (bits) operand `opid` may point into, by the values `src` gives each local: a whole
// local or a field of one. A value read through a pointer is not followed (see the top). None for a
// constant.
fn op_bits(b: &ir::CoreBody, da: &Ast, src: &Vector<u64>, opid: u32) u64 {
    if opid == ir::IR_NONE {
        return 0;
    }
    let op = *b.operands.at(opid as usize);
    if op.kind == ir::OP_CONST || derefs(b, da, op.data) != 0 {
        return 0;
    }
    return src[b.places.at(op.data as usize).base as usize];
}

// The number of derefs among place `pl`'s projections: an index of anything but an array or a vector
// value (a pointer, a view) reads the storage it points at, as a deref does.
fn derefs(b: &ir::CoreBody, da: &Ast, pl: u32) u32 {
    let p = b.places.at(pl as usize);
    let mut n: u32 = 0;
    let mut ty = b.locals.at(p.base as usize).ty;
    for i in 0..p.proj_len {
        let pj = b.projections.at((p.proj_start + i) as usize);
        if pj.kind == ir::PJ_DEREF {
            n += 1;
        } else if pj.kind == ir::PJ_INDEX_OP || pj.kind == ir::PJ_INDEX_CONST {
            let k = da.type_at(ty).kind;
            if k != TypeKind::TYPE_ARRAY && k != TypeKind::TYPE_SIMD {
                n += 1;
            }
        }
        ty = pj.ty;
    }
    return n;
}

// The parameters (bits) the address of place `pl` may point into: a place through one deref of what
// its local holds (a reborrow of a referent, a field or element of it). Through two derefs, the storage
// a loaded pointer names.
fn place_bits(b: &ir::CoreBody, da: &Ast, src: &Vector<u64>, pl: u32) u64 {
    if derefs(b, da, pl) != 1 {
        return 0;
    }
    return src[b.places.at(pl as usize).base as usize];
}

// Value `v` (bits) is written to place `pl`: a local, or a field of one, holds it (true when its bits
// grew); the result, or a field of it, returns it (`ret`: a caller's call destinations take the bits
// of those arguments); any other place keeps it out of sight (`esc`).
fn flow(b: &ir::CoreBody, da: &Ast, held: &mut Vector<u64>, o: &mut Scan, pl: u32, v: u64) bool {
    if v == 0 {
        return false;
    }
    let l = b.places.at(pl as usize).base as usize;
    let ds = b.locals.at(l).storage;
    if derefs(b, da, pl) != 0 || ds == ir::LS_STATIC_REF {
        o.esc |= v;
        return false;
    }
    if ds == ir::LS_RET {
        o.ret |= v;
        return false;
    }
    if (held[l] | v) == held[l] {
        return false;
    }
    held.set(l, held[l] | v);
    return true;
}

// Body `b` (entry `at` of `st`): the parameters that escape in it and those its result may point into,
// by the results' summaries so far (`st.ret`); with `collect`, its call edges (`edges`). `held` is
// scratch. A parameter of no reference or pointer type (a generic one may bind either) escapes and
// returns.
fn scan(
    pkg: *const loader::Package,
    st: &CaptureStore,
    b: &ir::CoreBody,
    at: u32,
    edges: &mut Vector<Edge>,
    held: &mut Vector<u64>,
    collect: bool,
) Scan {
    let da = unsafe &*(&*pkg).module_ast_const(b.module);
    let nl = b.locals.len();
    held.truncate(0);
    held.resize_default(nl);
    let np = b.args.min(64);
    let mut all: u64 = 0;
    for i in 0..np {
        let l = (b.returns + i) as usize;
        if l >= nl {
            break;
        }
        let y = da.type_at(b.locals.at(l).ty);
        if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
            held[l] = 1u64 << i as u64;
            all |= held[l];
        }
    }
    if all == 0 || b.has_reflect || b.has_lists {
        return Scan { esc: ~0u64, ret: ~0u64 };
    }
    let mut o = Scan { esc: 0, ret: 0 };
    let mut settled = false;
    // Each round adds bits to locals; a body the rounds do not settle lets every parameter escape.
    for _ in 0..SCAN_ROUNDS {
        let mut changed = false;
        for k in 0..b.blocks.len() {
            let bb = b.blocks.at(k);
            for si in bb.stmt_start..bb.stmt_start + bb.stmt_len {
                let s = *b.statements.at(si as usize);
                if s.kind != ir::ST_ASSIGN {
                    continue;
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                let mut v: u64 = 0;
                if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY {
                    v = op_bits(b, da, held, rv.a);
                } else if rv.kind == ir::RV_BINARY {
                    v = op_bits(b, da, held, rv.a) | op_bits(b, da, held, rv.b);
                } else if rv.kind == ir::RV_CAST {
                    v = op_bits(b, da, held, rv.a);
                    let ty = da.type_at(rv.target);
                    if ty.kind != TypeKind::TYPE_POINTER && ty.kind != TypeKind::TYPE_REFERENCE {
                        // An address as an integer may be kept anywhere.
                        o.esc |= v;
                    }
                } else if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE {
                    v = place_bits(b, da, held, rv.a);
                    if derefs(b, da, rv.a) == 0 {
                        // The address of a local: a read through it is out of this scan's sight.
                        o.esc |= held[b.places.at(rv.a as usize).base as usize];
                    }
                } else if rv.kind == ir::RV_AGGREGATE {
                    // An aggregate holds what its operands hold: a field read of its local reads them.
                    for q in 0..rv.b {
                        v |= op_bits(b, da, held, b.oper_pool[(rv.a + q) as usize]);
                    }
                } else if rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
                    o.esc |= op_bits(b, da, held, rv.a);
                } else if ir::has_op_range(&rv) {
                    // Captured by a closure, or an operand of a vector operation or an intrinsic.
                    for q in 0..rv.b {
                        o.esc |= op_bits(b, da, held, b.oper_pool[(rv.a + q) as usize]);
                    }
                }
                changed = flow(b, da, held, &mut o, s.place, v) || changed;
            }
            // A call's destinations may point into what the arguments its callee may return do.
            let t = bb.term;
            if t.kind == ir::TM_CALL && t.dests_len != 0 {
                let te = st.tgt[(st.blk[at as usize] + k as u32) as usize];
                let rm = if te == ir::IR_NONE {
                    ~0u64
                } else {
                    st.ret[te as usize]
                };
                let mut v: u64 = 0;
                for i in 0..t.args_len {
                    if i >= 64 || (rm >> i as u64 & 1) != 0 {
                        v |= op_bits(b, da, held, b.oper_pool[(t.args_start + i) as usize]);
                    }
                }
                for i in 0..t.dests_len {
                    changed = flow(b, da, held, &mut o, b.dest_pool[(t.dests_start + i) as usize], v) || changed;
                }
            }
        }
        if !changed {
            settled = true;
            break;
        }
    }
    if !settled {
        return Scan { esc: ~0u64, ret: ~0u64 };
    }
    if !collect {
        return Scan { esc: o.esc | ~all, ret: o.ret | ~all };
    }
    for k in 0..b.blocks.len() {
        let t = b.blocks.at(k).term;
        if t.kind == ir::TM_DROP {
            // The drop glue of a value behind a parameter, or of a local holding a pointer into one, gets
            // a pointer to it. A scalar, a pointer or a reference has none.
            let dk = da.type_at(b.places.at(t.a as usize).ty).kind;
            if dk != TypeKind::TYPE_BUILTIN && dk != TypeKind::TYPE_POINTER && dk != TypeKind::TYPE_REFERENCE {
                o.esc |= place_bits(b, da, held, t.a);
                if derefs(b, da, t.a) == 0 {
                    o.esc |= held[b.places.at(t.a as usize).base as usize];
                }
            }
            continue;
        }
        if t.kind != ir::TM_CALL {
            continue;
        }
        let to = st.tgt[(st.blk[at as usize] + k as u32) as usize];
        for i in 0..t.args_len {
            let v = op_bits(b, da, held, b.oper_pool[(t.args_start + i) as usize]) & ~o.esc;
            if v == 0 {
                continue;
            }
            if t.intr != ir::CI_NONE && (i == 0 || t.intr <= ir::CI_ATOMIC_LOAD) {
                // A verified memory or atomic routine reads and writes through its pointers and keeps
                // none; an atomic store, exchange or compare stores its later arguments.
                continue;
            }
            if to == ir::IR_NONE || i >= 64 {
                o.esc |= v;
                continue;
            }
            for bit in 0..64u32 {
                if (v >> bit as u64 & 1) != 0 {
                    edges.push(Edge { to: to, from: at, bit: bit, arg: i });
                }
            }
        }
    }
    return Scan { esc: o.esc | ~all, ret: o.ret | ~all };
}
