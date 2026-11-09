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
