// The instance and reachability graph: discovers every concrete generic instantiation by walking
// lowered Core IR bodies from concrete roots, expanding generic bodies under substitution frames.
// Keys are package-stable: a declaration DefId plus the skey of every concrete argument, so records
// from different module pools compare equal without touching any pool.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import ir::lower as irl;

/// Record kinds.
pub const IG_AGG: u8 = 0; // generic struct/enum instantiation
/// Instance record kinds (InstRec.kind).
pub const IG_FN: u8 = 1; // generic function instantiation
pub const IG_METHOD: u8 = 2; // method demanded on a generic-aggregate instance

/// The absent record index.
pub const IG_NONE: u32 = 0xFFFFFFFF;

/// One instance argument: its package-stable skey plus, for const-generic values, the folded
/// integer (what lets compound const-exprs like `{BITS*2}` evaluate under a frame).
pub struct ArgKey {
    pub skey: u64,
    pub val: i64,
    pub has_val: bool,
}

/// One discovered instance: the declaration plus its argument keys (flat pool range). Packed to
/// 32 bytes (two records per cache line): expansion and pairing iterate `recs` by value.
pub struct InstRec {
    pub hash: u64,
    pub def: DefId,
    pub args_start: u32,
    pub args_len: u32,
    /// Pool anchor: the module + TypeId where this instance was first seen as a real pool type
    /// (TYPE_NONE = derived through substitution/cross product only).
    pub aty: TypeId,
    pub amod: ModuleId,
    pub kind: u8,
    pub expanded: bool,
}

// One extend targeting a declaration (built once; aggregate expansion walks its methods).
struct ExtRow {
    pub dmod: ModuleId,
    pub ddecl: NodeId,
    pub emod: ModuleId,
    pub enode: NodeId,
}

// One substitution frame entry: generic-param decl -> the argument's key (value included for
// const params, so dependent const-exprs can fold).
struct Subst {
    pub pmod: ModuleId,
    pub pdecl: NodeId,
    pub key: ArgKey,
}

// Per kept body: the walk-relevant items, extracted once. A body's locals and rvalues repeat the
// same interned TypeIds heavily, and generic bodies re-walk once per instantiation frame: the
// framed walks iterate this ~10x smaller list instead of the whole body.
struct WalkCache {
    pub built: bool,
    pub tys: Vector<TypeId>, // unique local/rvalue types, first-occurrence order
    pub consts: Vector<u32>, // CK_ITEM constant ids carrying bound targs
    pub calls: Vector<u32>, // block ids whose terminator is a resolved TM_CALL
}

/// The package's closed set of generic instantiations, reached by walking every live body's
/// demands to a fixpoint; records are deduplicated by (kind, def, argument keys).
pub struct InstGraph {
    pub pkg: *const loader::Package,
    pub recs: Vector<InstRec>,
    pub keys: Vector<ArgKey>, // flat argument-key pool
    index: Vector<u32>, // open addressing over recs (hash lookup, exact compare)
    ix_used: u32,
    cursor: usize, // worklist: recs[cursor..] await expansion
    exts: Vector<ExtRow>, // every extend in the package, keyed by its target declaration
    // Membership indexes over `exts` and the package's interfaces: expansion asks per call site,
    // so owner lookups must not rescan the extend/item lists.
    ext_of: Map<u64, u64>, // (module << 32 | fnode) -> owning extend node (rows of `exts` only)
    iface_of: Map<u64, u64>, // (module << 32 | fnode) -> owning interface node
    // Per-module TypeIds already fully walked by note_type under an EMPTY frame: bodies name the
    // same interned types over and over, and a completed depth-0 walk covers every revisit.
    noted: Vector<Vector<bool>>,
    /// One lowering per declaration, shared by every frame that walks it (lowering ignores the
    /// frame; only walking applies it). The emitter takes these bodies instead of re-lowering.
    /// `kept_ix` maps (module << 32 | node) to a `kept` index; 0xFFFFFFFFFFFFFFFF = lowering failed.
    pub kept: Vector<irl::Lowerer>,
    pub kept_ix: Map<u64, u64>,
    // The argument keys of the record being interned: every add() reads this buffer, so the hot
    // walk never allocates a per-record key vector.
    argbuf: Vector<ArgKey>,
    /// The shared scratch Lowerer: every body lowers through its (capacity-retaining) pools, and
    /// only an exact-size compact copy lands in `kept`: no growth chains, no retained slack.
    low: irl::Lowerer,
    wcache: Vector<WalkCache>, // parallel to `kept`
    wt_seen: Map<u64, u64>, // scratch: TypeIds already in the cache being built
    /// Borrowck's finished lowerings (null = none): `body_idx` moves an entry into `kept` on first
    /// demand instead of lowering the body a second time.
    keep: *mut irl::Keep,
    /// Per-module emission liveness (null = every module emits). A prelude module marked dead emits no
    /// TU, so nothing seeds from its bodies: the instances they alone reach would land in the shared
    /// type header with no code naming them.
    live: *const bool,
    pub bodies: u64, // walked body count (roots + expansions)
    pub overflow: bool, // budget exhausted; the report marks itself partial
    budget: u32,
}

extend InstGraph as Free {
    pub fn free(self: &mut Self) {
        self.recs.free();
        self.keys.free();
        self.index.free();
        self.exts.free();
        self.ext_of.free();
        self.iface_of.free();
        self.noted.free();
        self.kept.free();
        self.kept_ix.free();
        self.argbuf.free();
        self.low.free();
        self.wcache.free();
        self.wt_seen.free();
    }
}

const fn mix(h: u64, v: u64) u64 {
    return skey_mix(h, v);
}

/// type_skey with shared-reference spellings unified: a REFERENCE's CONST qualifier (written
/// `&'a T`) keys as NONE (the checker-inserted form), so the two spellings of one shared borrow
/// cannot split a record. Both sides of every instance comparison key through this.
pub fn skey_norm(a: &Ast, t: TypeId, depth: i32) u64 {
    if t == TYPE_NONE || depth > 8 {
        return 0;
    }
    let y = *a.type_at(t);
    let mut q = y.qualifier;
    if y.kind == TypeKind::TYPE_REFERENCE && q == TypeQualifier::TYPE_QUAL_CONST as u8 {
        q = TypeQualifier::TYPE_QUAL_NONE as u8;
    }
    let h = skey_mix(skey_mix(14695981039346656037u64, y.kind as u64), q);
    return switch y.kind {
        TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => skey_mix(h, skey_norm(a, y.as_data.elem, depth + 1)),
        TYPE_ARRAY => skey_mix(skey_mix(h, skey_norm(a, y.as_data.arr.elem, depth + 1)), y.as_data.arr.len),
        TYPE_INSTANCE | TYPE_DYN => {
            let it = a.instance(y.as_data.inst);
            let mut k = skey_mix(skey_mix(h, it.module), it.decl);
            for i in 0..it.n {
                k = skey_mix(k, skey_norm(a, unsafe it.args[i], depth + 1));
            }
            k;
        },
        _ => a.type_skey(t, depth),
    };
}

extend InstGraph {
    /// An empty graph over `pkg`; `keep` (null = lower on demand) supplies kept lowerings and `live`
    /// (per module) selects the roots. Both must outlive the graph.
    pub fn new(pkg: *const loader::Package, keep: *mut irl::Keep, live: *const bool) InstGraph {
        return InstGraph {
            keep: keep,
            live: live,
            pkg: pkg,
            recs: Vector::<InstRec>::new(),
            keys: Vector::<ArgKey>::new(),
            index: Vector::<u32>::new(),
            ix_used: 0,
            cursor: 0,
            exts: Vector::<ExtRow>::new(),
            ext_of: Map::<u64, u64>::new(),
            iface_of: Map::<u64, u64>::new(),
            noted: Vector::<Vector<bool>>::new(),
            kept: Vector::<irl::Lowerer>::new(),
            kept_ix: Map::<u64, u64>::new(),
            argbuf: Vector::<ArgKey>::new(),
            low: irl::Lowerer::new(pkg, 0, NODE_NONE),
            wcache: Vector::<WalkCache>::new(),
            wt_seen: Map::<u64, u64>::new(),
            bodies: 0,
            overflow: false,
            budget: 64000000,
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

    /// Intern the record whose argument keys sit in `argbuf`; returns its id and whether it was
    /// new. Hash + equality use skeys only (the value is derived data riding along for frame
    /// evaluation).
    pub fn add(self: &mut Self, kind: u8, def: DefId, fresh: &mut bool) u32 {
        let mut h = mix(mix(1469598103934665603u64, kind), def.module);
        h = mix(h, def.node);
        for i in 0..self.argbuf.len() {
            h = mix(h, self.argbuf.at(i).skey);
        }
        if self.index.len() == 0 || (self.ix_used as usize + 1) * 4 >= self.index.len() * 3 {
            let mut cap: usize = 64;
            while cap < (self.recs.len() + 1) * 4 {
                cap = cap * 2;
            }
            let mut nix = Vector::<u32>::new();
            for i in 0..cap {
                nix.push(IG_NONE);
            }
            for r in 0..self.recs.len() {
                let rh = self.recs.at(r).hash;
                let mut i2 = rh as usize & cap - 1;
                let step2 = (rh >> 32) as usize | 1;
                while nix[i2] != IG_NONE {
                    i2 = i2 + step2 & cap - 1;
                }
                nix.set(i2, r as u32);
            }
            self.index = nix;
            self.ix_used = self.recs.len() as u32;
        }
        let mask = self.index.len() - 1;
        let mut i = h as usize & mask;
        let step = (h >> 32) as usize | 1;
        loop {
            let cur = self.index[i];
            if cur == IG_NONE {
                let start = self.keys.len() as u32;
                for k in 0..self.argbuf.len() {
                    self.keys.push(*self.argbuf.at(k));
                }
                self.recs.push(
                    InstRec {
                        hash: h,
                        def: def,
                        args_start: start,
                        args_len: self.argbuf.len() as u32,
                        aty: TYPE_NONE,
                        amod: 0,
                        kind: kind,
                        expanded: false,
                    },
                );
                let id = self.recs.len() as u32 - 1;
                self.index.set(i, id);
                self.ix_used += 1;
                *fresh = true;
                return id;
            }
            let r = self.recs.at(cur as usize);
            if r.hash == h && r.kind == kind && r.def.module == def.module && r.def.node == def.node && r.args_len as usize == self.argbuf.len() {
                let mut eq = true;
                for k in 0..r.args_len {
                    if self.keys.at((r.args_start + k) as usize).skey != self.argbuf.at(k as usize).skey {
                        eq = false;
                        break;
                    }
                }
                if eq {
                    *fresh = false;
                    return cur;
                }
            }
            i = i + step & mask;
        }
    }

    // type_skey with a substitution frame: a generic parameter keys as its bound argument, so the
    // key of `Vector<T>` under {T -> i32} equals the key of `Vector<i32>` in any pool.
    fn skey_subst(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) u64 {
        if t == TYPE_NONE || depth > 8 {
            return 0;
        }
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl {
                    return frame.at(i).key.skey;
                }
            }
            return skey_norm(a, t, depth);
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let bound = self.const_expr_bound(a, &y, frame);
            if bound.skey != 0 {
                return bound.skey;
            }
        }
        let h = mix(mix(14695981039346656037u64, y.kind as u64), y.qualifier);
        return switch y.kind {
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => mix(h, self.skey_subst(a, y.as_data.elem, frame, depth + 1)),
            TYPE_ARRAY => mix(mix(h, self.skey_subst(a, y.as_data.arr.elem, frame, depth + 1)), y.as_data.arr.len),
            TYPE_BUILTIN => mix(h, y.as_data.builtin as u64),
            TYPE_CONST => mix(h, y.as_data.value as u64),
            TYPE_INSTANCE | TYPE_DYN => {
                let it = a.instance(y.as_data.inst);
                let mut k = mix(mix(h, it.module), it.decl);
                for i in 0..it.n {
                    k = mix(k, self.skey_subst(a, unsafe it.args[i], frame, depth + 1));
                }
                k;
            },
            _ => a.type_skey(t, depth),
        };
    }

    // The key a const-expr resolves to under `frame`: identity forms (`{N}`) inherit the bound
    // key verbatim; compound forms (`{BITS*2}`, `{(BITS+7)/8}`) EVALUATE when every param has a
    // bound value, keying exactly as the emitter's folded TYPE_CONST does. skey 0 = unbound.
    fn const_expr_bound(self: &Self, a: &Ast, y: &Ty, frame: &Vector<Subst>) ArgKey {
        let none = ArgKey { skey: 0, val: 0, has_val: false };
        let l = a.const_lin_at(y.as_data.inst);
        // Identity: one coefficient-1 param, no constant, no divisor.
        let mut nact: u32 = 0;
        let mut hit: i64 = -1;
        for i in 0..l.n {
            if unsafe l.c[i as usize] != 0 {
                nact += 1;
                hit = i;
            }
        }
        if l.k == 0 && l.div_of() <= 1 && nact == 1 && unsafe l.c[hit as usize] == 1 {
            let pd = unsafe l.p[hit as usize];
            for i in 0..frame.len() {
                if frame.at(i).pmod == pd.module && frame.at(i).pdecl == pd.node {
                    return frame.at(i).key;
                }
            }
            return none;
        }
        // Compound: fold value = (k + sum(c_i * v_i)) / div from bound VALUES.
        let mut v = l.k;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c == 0 {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            let mut bound = false;
            for f in 0..frame.len() {
                if frame.at(f).pmod == pd.module && frame.at(f).pdecl == pd.node && frame.at(f).key.has_val {
                    let fv = frame.at(f).key.val;
                    // Widths are small; a huge operand means a non-width const rode in: bail.
                    if fv < 0 || fv > 0xFFFFFFFF || c > 0xFFFF || c < -65536 {
                        return none;
                    }
                    v += c * fv;
                    bound = true;
                }
            }
            if !bound {
                return none;
            }
        }
        let d = l.div_of();
        if d > 1 {
            v = v / d;
        }
        // Key exactly as type_skey keys the folded TYPE_CONST (qualifier 0).
        let h = mix(mix(14695981039346656037u64, TypeKind::TYPE_CONST as u64), 0);
        return ArgKey { skey: mix(h, v as u64), val: v, has_val: true };
    }

    // The full ArgKey of `t` under `frame`: the substituted skey plus the folded value when the
    // argument is a const (TYPE_CONST directly, or a const-expr the frame can evaluate).
    fn argkey_subst(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>) ArgKey {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_CONST {
            return ArgKey { skey: self.skey_subst(a, t, frame, 0), val: y.as_data.value, has_val: true };
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let b = self.const_expr_bound(a, &y, frame);
            if b.skey != 0 {
                return b;
            }
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl {
                    return frame.at(i).key;
                }
            }
        }
        return ArgKey { skey: self.skey_subst(a, t, frame, 0), val: 0, has_val: false };
    }

    // Is `t` concrete once the frame applies? (Every symbolic leaf must be bound.)
    fn concrete_subst(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) bool {
        if t == TYPE_NONE || depth > 8 {
            return false;
        }
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl {
                    return true;
                }
            }
            return false;
        }
        return switch y.kind {
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => self.concrete_subst(a, y.as_data.elem, frame, depth + 1),
            TYPE_ARRAY => self.concrete_subst(a, y.as_data.arr.elem, frame, depth + 1),
            TYPE_CONST_EXPR => self.const_expr_bound(a, &y, frame).skey != 0,
            TYPE_FIELD_PROJECTION => false,
            TYPE_INSTANCE | TYPE_DYN => {
                let it = a.instance(y.as_data.inst);
                let mut ok = true;
                for i in 0..it.n {
                    if !self.concrete_subst(a, unsafe it.args[i], frame, depth + 1) {
                        ok = false;
                    }
                }
                ok;
            },
            _ => true,
        };
    }

    // Register every concrete aggregate instantiation inside `t` (nested arguments included).
    // A completed empty-frame depth-0 walk of `t` covers every later occurrence (a nested revisit
    // truncates no deeper than the depth-0 walk did), so revisits skip in O(1).
    fn note_type(self: &mut Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) {
        if t == TYPE_NONE || depth > 8 {
            return;
        }
        let memo = frame.len() == 0;
        if memo {
            if self.noted.len() == 0 {
                for _i in 0..(unsafe &*self.pkg).modules.len() {
                    self.noted.push(Vector::<bool>::new());
                }
            }
            let seen = self.noted.at(a.module as usize);
            if t as usize < seen.len() && *seen.at(t as usize) {
                return;
            }
        }
        self.note_type_walk(a, t, frame, depth);
        if memo && depth == 0 {
            while self.noted[a.module as usize].len() <= t as usize {
                self.noted[a.module as usize].push(false);
            }
            self.noted[a.module as usize].set(t as usize, true);
        }
    }

    fn note_type_walk(self: &mut Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) {
        if !self.spend(1) {
            return;
        }
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_SLICE {
            self.note_type(a, y.as_data.elem, frame, depth + 1);
            // `[]T` is the surface spelling of prelude Slice<T> (SliceMut for `[]mut T`); the old
            // propagation records that instance, so the graph must too.
            let p2 = unsafe &*self.pkg;
            let hit = if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                p2.prelude_lookup("SliceMut", true);
            } else {
                p2.prelude_lookup("Slice", true);
            };
            if hit.node != NODE_NONE && self.concrete_subst(a, y.as_data.elem, frame, depth + 1) {
                let k0 = self.argkey_subst(a, y.as_data.elem, frame);
                self.argbuf.truncate(0);
                self.argbuf.push(k0);
                let mut fresh = false;
                let _ = self.add(IG_AGG, DefId { module: hit.mid, node: hit.node }, &mut fresh);
            }
            return;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            self.note_type(a, y.as_data.elem, frame, depth + 1);
            return;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            self.note_type(a, y.as_data.arr.elem, frame, depth + 1);
            return;
        }
        if y.kind != TypeKind::TYPE_INSTANCE && y.kind != TypeKind::TYPE_DYN {
            return;
        }
        let it = *a.instance(y.as_data.inst);
        // The declaration must be a real aggregate (dyn fn carriers ride FUNCTION_TYPE decls).
        let da = unsafe &*(&*self.pkg).module_ast_const(it.module);
        let dk = da.at_const(it.decl).kind;
        for i in 0..it.n {
            self.note_type(a, unsafe it.args[i], frame, depth + 1);
        }
        if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM {
            return;
        }
        self.argbuf.truncate(0);
        for i in 0..it.n {
            if !self.concrete_subst(a, unsafe it.args[i], frame, depth + 1) {
                return;
            }
            let k0 = self.argkey_subst(a, unsafe it.args[i], frame);
            self.argbuf.push(k0);
        }
        let mut fresh = false;
        let id = self.add(IG_AGG, DefId { module: it.module, node: it.decl }, &mut fresh);
        if self.recs.at(id as usize).aty == TYPE_NONE && a.type_concrete(t) {
            // A pool-concrete spelling anchors the record (frames leave symbolic types unanchored).
            self.recs[id as usize].amod = a.module;
            self.recs[id as usize].aty = t;
        }
    }

    // Walk one lowered body under `frame`: every type it stores, every resolved call, every item
    // constant. Fresh generic-fn instances queue their own expansion.
    fn walk_body(self: &mut Self, b: &ir::CoreBody, a: &Ast, frame: &Vector<Subst>) {
        self.bodies += 1;
        for i in 0..b.locals.len() {
            self.note_type(a, b.locals.at(i).ty, frame, 0);
        }
        for i in 0..b.rvalues.len() {
            self.note_type(a, b.rvalues.at(i).target, frame, 0);
        }
        for i in 0..b.constants.len() {
            let c = b.constants.at(i);
            if c.kind == ir::CK_ITEM && c.targ_len != 0 {
                self.note_call(a, c.item, b, c.targ_start, c.targ_len, frame);
            }
        }
        for i in 0..b.blocks.len() {
            let t = b.blocks.at(i).term;
            if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE {
                continue;
            }
            if t.targs_len != 0 {
                self.note_call(a, t.callee, b, t.targs_start, t.targs_len, frame);
            }
            self.note_method(a, &t, b, frame);
        }
    }

    // Demand a generic-extend method from an explicit call site: the receiver operand's (peeled)
    // instance binds the extend's params; the method body walks under that frame. No extend search:
    // the checker already selected the method.
    fn note_method(self: &mut Self, a: &Ast, t: &ir::Terminator, b: &ir::CoreBody, frame: &Vector<Subst>) {
        // The method's enclosing extend, if it is generic.
        let ma = unsafe &*(&*self.pkg).module_ast_const(t.callee.module);
        let ext = switch self.ext_of.get(&skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64)) {
            Some(v) => (*v) as NodeId,
            None => NODE_NONE,
        };
        if ext == NODE_NONE {
            return;
        }
        let ed = ma.at_const(ext).as_data.extend_def;
        if ed.generics.len == 0 {
            return;
        }
        if t.args_len == 0 {
            return;
        }
        // Peel the receiver to its instance.
        let recv_op = b.oper_pool[t.args_start as usize];
        let mut rt = b.operands.at(recv_op as usize).ty;
        let mut guard = 0;
        while guard < 4 {
            let y = *a.type_at(rt);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                rt = y.as_data.elem;
            } else {
                break;
            }
            guard += 1;
        }
        if a.type_at(rt).kind != TypeKind::TYPE_INSTANCE {
            return;
        }
        let it = *a.instance(a.type_at(rt).as_data.inst);
        // Method key: receiver-instance args, then the method's own bound args (bail on symbolic).
        self.argbuf.truncate(0);
        for i in 0..it.n {
            if !self.concrete_subst(a, unsafe it.args[i], frame, 0) {
                return;
            }
            let k0 = self.argkey_subst(a, unsafe it.args[i], frame);
            self.argbuf.push(k0);
        }
        for i in 0..t.targs_len {
            let ty2 = b.targ_pool[(t.targs_start + i) as usize];
            if !self.concrete_subst(a, ty2, frame, 0) {
                return;
            }
            let k1 = self.argkey_subst(a, ty2, frame);
            self.argbuf.push(k1);
        }
        let mut fresh = false;
        let _ = self.add(IG_METHOD, t.callee, &mut fresh);
    }

    // A resolved call/value use of a generic function with bound arguments.
    fn note_call(self: &mut Self, a: &Ast, callee: DefId, b: &ir::CoreBody, ts: u32, tn: u32, frame: &Vector<Subst>) {
        self.argbuf.truncate(0);
        for i in 0..tn {
            let t = b.targ_pool[(ts + i) as usize];
            if !self.concrete_subst(a, t, frame, 0) {
                // Still symbolic here; the enclosing instantiation walks it bound.
                return;
            }
            let k0 = self.argkey_subst(a, t, frame);
            self.argbuf.push(k0);
        }
        let mut fresh = false;
        let _ = self.add(IG_FN, callee, &mut fresh);
    }

    /// Expand queued records to a fixed point, alternating the worklist with the demand cross
    /// product: method demand is PER DECLARATION (one call to `.at` on any Vector<X> emits `at` for
    /// every reachable Vector instance: the established method_used semantics), so each demanded
    /// non-generic method pairs with every instance of its extend's target.
    pub fn run(self: &mut Self) {
        loop {
            self.drain();
            let before = self.recs.len();
            self.cross_demand();
            if self.recs.len() == before && self.cursor >= self.recs.len() {
                break;
            }
        }
    }

    // Pair every demanded method DECL with every instance of its extend's target (bounds filtering
    // stays with the emitter: the graph is a superset, which is the diff direction that matters).
    // Three demand sources need no call site: `free` (RAII inserts the calls after lowering),
    // interface DEFAULT bodies (one copy per conforming instance, unconditionally), and dyn-vtable
    // methods (every interface method of a dyn-erased source type).
    fn cross_demand(self: &mut Self) {
        // Demanded method decls, deduped.
        let mut dm = Vector::<DefId>::new();
        let mut dseen = Set::<u64>::new();
        for r in 0..self.recs.len() {
            let rec = self.recs.at(r);
            if rec.kind != IG_METHOD {
                continue;
            }
            let dk = skey_mix(0, rec.def.module as u64 << 32 | rec.def.node as u64);
            if !dseen.contains(&dk) {
                dseen.insert(dk);
                dm.push(rec.def);
            }
        }
        // The checker's own demand record is the authority: method_used marks every method a body
        // referenced (the typed fact the emitter gates on), and every extend method named `free` is
        // glue demand (RAII inserts those calls after lowering; drop elaboration later refines this
        // with move analysis). Both fold into the demanded-decl set.
        let p = unsafe &*self.pkg;
        for m in 0..p.method_used.len() {
            let row = p.method_used.at(m);
            for n in 0..row.len() {
                if row[n] {
                    let dk = skey_mix(0, m as u64 << 32 | n as u64);
                    if !dseen.contains(&dk) {
                        dseen.insert(dk);
                        dm.push(DefId { module: m as ModuleId, node: n as NodeId });
                    }
                }
            }
        }
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let src = unsafe (&*self.pkg).modules.at(row.emod as usize).source.as_str();
            let ed = a.at_const(row.enode).as_data.extend_def;
            // An interface-conforming extend emits EVERY bodied method per instance: the
            // The method_used gate applies only to plain extends.
            let conforming = ed.interface_type != NODE_NONE;
            for j in 0..ed.items.len {
                let iid = unsafe a.list(ed.items)[j as usize];
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_FUNCTION || it.as_data.function.body == NODE_NONE {
                    continue;
                }
                let nsp = a.at_const(it.as_data.function.name).as_data.name.text;
                if conforming || src.slice(nsp.start as usize, nsp.end as usize) == "free" {
                    let dk = skey_mix(0, row.emod as u64 << 32 | iid as u64);
                    if !dseen.contains(&dk) {
                        dseen.insert(dk);
                        dm.push(DefId { module: row.emod, node: iid });
                    }
                }
            }
        }
        // A demanded INTERFACE method maps to each conforming extend's override of the same name:
        // dispatch through a bound selects the impl per receiver, so the emitter emits the impl
        // decl: the demand must follow it there.
        let ndm = dm.len();
        for d in 0..ndm {
            let md = *dm.at(d);
            let ia = unsafe &*(&*self.pkg).module_ast_const(md.module);
            let iface = self.enclosing_interface(md);
            if iface == NODE_NONE {
                continue;
            }
            let isrc = unsafe (&*self.pkg).modules.at(md.module as usize).source.as_str();
            let msp = ia.at_const(ia.at_const(md.node).as_data.function.name).as_data.name.text;
            let mname = isrc.slice(msp.start as usize, msp.end as usize);
            for x in 0..self.exts.len() {
                let row = *self.exts.at(x);
                let a2 = unsafe &*(&*self.pkg).module_ast_const(row.emod);
                let ed = a2.at_const(row.enode).as_data.extend_def;
                if ed.interface_type == NODE_NONE {
                    continue;
                }
                let ir2 = self.ext_interface(a2, row.enode);
                if ir2.module != md.module || ir2.node != iface {
                    continue;
                }
                let src2 = unsafe (&*self.pkg).modules.at(row.emod as usize).source.as_str();
                for j in 0..ed.items.len {
                    let iid = unsafe a2.list(ed.items)[j as usize];
                    let it = a2.at_const(iid);
                    if it.kind != NodeKind::NODE_FUNCTION || it.as_data.function.body == NODE_NONE {
                        continue;
                    }
                    let osp = a2.at_const(it.as_data.function.name).as_data.name.text;
                    if src2.slice(osp.start as usize, osp.end as usize) == mname {
                        dm.push(DefId { module: row.emod, node: iid });
                    }
                }
            }
        }
        // AGG rec ids grouped per declaration (ascending), so each pairing walks only its
        // target's group; METHOD adds below never change AGG membership.
        let mut gk = Map::<u64, u64>::new();
        let mut groups = Vector::<Vector<u32>>::new();
        for r in 0..self.recs.len() {
            let rec = self.recs.at(r);
            if rec.kind != IG_AGG {
                continue;
            }
            let key = skey_mix(0, rec.def.module as u64 << 32 | rec.def.node as u64);
            let gi = switch gk.get(&key) {
                Some(v) => *v,
                None => {
                    gk.insert(key, groups.len() as u64);
                    groups.push(Vector::<u32>::new());
                    groups.len() as u64 - 1;
                },
            };
            groups[gi as usize].push(r as u32);
        }
        self.cross_defaults(&gk, &groups);
        for d in 0..dm.len() {
            let md = *dm.at(d);
            let ext = self.enclosing_extend(md);
            if ext == NODE_NONE {
                continue;
            }
            let a = unsafe &*(&*self.pkg).module_ast_const(md.module);
            // A demanded method with own generics pairs only through explicit (instance, targs).
            if a.at_const(md.node).as_data.function.generics.len != 0 {
                continue;
            }
            let target = self.ext_target(a, ext);
            if target.node == NODE_NONE {
                continue;
            }
            let gi = switch gk.get(&skey_mix(0, target.module as u64 << 32 | target.node as u64)) {
                Some(v) => (*v) as i64,
                None => (-1) as i64,
            };
            if gi < 0 {
                continue;
            }
            for k9 in 0..groups[gi as usize].len() {
                let rec = *self.recs.at(groups[gi as usize][k9] as usize);
                self.argbuf.truncate(0);
                for k in 0..rec.args_len {
                    let k0 = *self.keys.at((rec.args_start + k) as usize);
                    self.argbuf.push(k0);
                }
                let mut fresh = false;
                let _ = self.add(IG_METHOD, md, &mut fresh);
            }
        }
    }

    // Interface default bodies: every extend that conforms `Target as Iface` emits one copy of each
    // default-bodied interface method per Target instance: record those pairs so the emitted-set
    // diff can find them (def = the INTERFACE's method decl, keys = the instance args).
    fn cross_defaults(self: &mut Self, gk: &Map<u64, u64>, groups: &Vector<Vector<u32>>) {
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let ed = a.at_const(row.enode).as_data.extend_def;
            if ed.interface_type == NODE_NONE {
                continue;
            }
            let mut iface = a.resolution_def(ed.interface_type);
            if iface.node == NODE_NONE && a.at_const(ed.interface_type).kind == NodeKind::NODE_TYPE_PATH {
                let ps = a.at_const(ed.interface_type).as_data.type_path.parts;
                if ps.len != 0 {
                    iface = a.resolution_def(unsafe a.list(ps)[(ps.len - 1) as usize]);
                }
            }
            if iface.node == NODE_NONE {
                continue;
            }
            let ia = unsafe &*(&*self.pkg).module_ast_const(iface.module);
            if ia.at_const(iface.node).kind != NodeKind::NODE_INTERFACE {
                continue;
            }
            // Default-bodied interface methods the extend does NOT override.
            let src = unsafe (&*self.pkg).modules.at(row.emod as usize).source.as_str();
            let isrc = unsafe (&*self.pkg).modules.at(iface.module as usize).source.as_str();
            let ims = ia.at_const(iface.node).as_data.interface_def.items;
            for j in 0..ims.len {
                let imid = unsafe ia.list(ims)[j as usize];
                let imf = ia.at_const(imid);
                if imf.kind != NodeKind::NODE_FUNCTION || imf.as_data.function.body == NODE_NONE {
                    continue;
                }
                let insp = ia.at_const(imf.as_data.function.name).as_data.name.text;
                let iname = isrc.slice(insp.start as usize, insp.end as usize);
                let mut overridden = false;
                for k in 0..ed.items.len {
                    let oid = unsafe a.list(ed.items)[k as usize];
                    let on = a.at_const(oid);
                    if on.kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let osp = a.at_const(on.as_data.function.name).as_data.name.text;
                    if src.slice(osp.start as usize, osp.end as usize) == iname {
                        overridden = true;
                    }
                }
                if overridden {
                    continue;
                }
                // Pair with every instance of the extend's target.
                let tg = self.ext_target(a, row.enode);
                let gi = switch gk.get(&skey_mix(0, tg.module as u64 << 32 | tg.node as u64)) {
                    Some(v) => (*v) as i64,
                    None => (-1) as i64,
                };
                if gi < 0 {
                    continue;
                }
                for r9 in 0..groups[gi as usize].len() {
                    let rec = *self.recs.at(groups[gi as usize][r9] as usize);
                    self.argbuf.truncate(0);
                    for k in 0..rec.args_len {
                        let k0 = *self.keys.at((rec.args_start + k) as usize);
                        self.argbuf.push(k0);
                    }
                    let mut fresh = false;
                    let _ = self.add(IG_METHOD, DefId { module: iface.module, node: imid }, &mut fresh);
                }
            }
        }
    }

    // Expand queued records: lower each generic body once and walk it under the record's frame.
    // Recursive instantiation terminates through the interning table.
    fn drain(self: &mut Self) {
        while self.cursor < self.recs.len() {
            let r = *self.recs.at(self.cursor);
            self.cursor += 1;
            if r.expanded || !self.spend(64) {
                continue;
            }
            self.recs[self.cursor - 1].expanded = true;
            if r.kind == IG_AGG {
                self.expand_fields(&r);
                self.expand_signatures(&r);
                continue;
            }
            if r.kind == IG_METHOD {
                self.expand_method(&r);
                continue;
            }
            if r.kind != IG_FN {
                continue;
            }
            // An extend member reached as a plain call (assoc fns, turbofish method values) still
            // binds the extend's params through its leading argument keys.
            if self.enclosing_extend(r.def) != NODE_NONE {
                self.expand_method(&r);
                continue;
            }
            let da = unsafe &*(&*self.pkg).module_ast_const(r.def.module);
            if da.at_const(r.def.node).kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let fd = da.at_const(r.def.node).as_data.function;
            if fd.body == NODE_NONE || fd.is_extern {
                continue;
            }
            // Bind the declaration's non-lifetime params to the record's arg keys.
            let mut frame = Vector::<Subst>::new();
            let mut ai: u32 = 0;
            for g in 0..fd.generics.len {
                let gp = unsafe da.list(fd.generics)[g as usize];
                if da.at_const(gp).as_data.generic_param.is_lifetime {
                    continue;
                }
                if ai < r.args_len {
                    frame.push(
                        Subst { pmod: r.def.module, pdecl: gp, key: *self.keys.at((r.args_start + ai) as usize) },
                    );
                }
                ai += 1;
            }
            let bi = self.body_idx(r.def.module, r.def.node, false);
            if bi >= 0 {
                self.walk_kept(bi, da, &frame);
                let mut cls = Vector::<NodeId>::new();
                {
                    let bp = self.kept.at(bi as usize) as *const irl::Lowerer;
                    for c in 0..(unsafe &*bp).closures.len() {
                        cls.push((unsafe &*bp).closures[c]);
                    }
                }
                self.expand_closures(&cls, r.def.module, &frame);
            }
        }
    }

    // The declaration an extend targets (the path node's resolution, else its last part's).
    const fn ext_target(self: &Self, a: &Ast, ext: NodeId) DefId {
        let tt = a.at_const(ext).as_data.extend_def.target_type;
        if tt == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let d = a.resolution_def(tt);
        if d.node != NODE_NONE {
            return d;
        }
        if a.at_const(tt).kind == NodeKind::NODE_TYPE_PATH {
            let parts = a.at_const(tt).as_data.type_path.parts;
            if parts.len != 0 {
                return a.resolution_def(unsafe a.list(parts)[(parts.len - 1) as usize]);
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // A fresh aggregate instantiation reaches its FIELD types: `Vector<String>` demands String and
    // the nested `RawParts<String>` the old propagation records through reintern_nested_type. Field
    // types are written over the declaration's params, so the record's keys bind them positionally.
    fn expand_fields(self: &mut Self, r: &InstRec) {
        let a = unsafe &*(&*self.pkg).module_ast_const(r.def.module);
        let n = a.at_const(r.def.node);
        let mut frame = Vector::<Subst>::new();
        let gs = n.as_data.aggregate.generics;
        let mut ai: u32 = 0;
        for g in 0..gs.len {
            let gp = unsafe a.list(gs)[g as usize];
            if a.at_const(gp).as_data.generic_param.is_lifetime {
                continue;
            }
            if ai < r.args_len {
                frame.push(Subst { pmod: r.def.module, pdecl: gp, key: *self.keys.at((r.args_start + ai) as usize) });
            }
            ai += 1;
        }
        let is_tuple = n.as_data.aggregate.is_tuple;
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            let mk = a.at_const(mid).kind;
            // Tuple members are bare type nodes; named members carry their type in field.ty.
            if mk == NodeKind::NODE_FIELD || is_tuple {
                let tnode = if mk == NodeKind::NODE_FIELD {
                    a.at_const(mid).as_data.field.ty;
                } else {
                    mid;
                };
                let mut t = a.type_of(mid);
                if t == TYPE_NONE && tnode != NODE_NONE {
                    t = a.type_of(tnode);
                }
                self.note_type(a, t, &frame, 0);
            } else if mk == NodeKind::NODE_VARIANT {
                let pl = a.at_const(mid).as_data.variant.payload;
                for j in 0..pl.len {
                    let pn = unsafe a.list(pl)[j as usize];
                    let mut t = a.type_of(pn);
                    if t == TYPE_NONE && a.at_const(pn).kind == NodeKind::NODE_PARAMETER {
                        t = a.type_of(a.at_const(pn).as_data.parameter.ty);
                    }
                    self.note_type(a, t, &frame, 0);
                }
            }
        }
    }

    // The interface a method decl belongs to, or NODE_NONE.
    fn enclosing_interface(self: &Self, d: DefId) NodeId {
        let hit = switch self.iface_of.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => (*v) as NodeId,
            None => NODE_NONE,
        };
        return hit;
    }

    // The interface an extend conforms to, resolved (module-qualified); node NODE_NONE when plain.
    const fn ext_interface(self: &Self, a: &Ast, ext: NodeId) DefId {
        let it = a.at_const(ext).as_data.extend_def.interface_type;
        if it == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        let d = a.resolution_def(it);
        if d.node != NODE_NONE {
            return d;
        }
        if a.at_const(it).kind == NodeKind::NODE_TYPE_PATH {
            let ps = a.at_const(it).as_data.type_path.parts;
            if ps.len != 0 {
                return a.resolution_def(unsafe a.list(ps)[(ps.len - 1) as usize]);
            }
        }
        return DefId { module: 0, node: NODE_NONE };
    }

    // Signature-level propagation (established reintern_method_signature_deps semantics): every
    // method SIGNATURE of every extend targeting a reachable instance contributes its substituted
    // types (Option<&T> from `first`, iterators from `iter`) regardless of demand.
    fn expand_signatures(self: &mut Self, r: &InstRec) {
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            if row.dmod != r.def.module || row.ddecl != r.def.node {
                continue;
            }
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let ed = a.at_const(row.enode).as_data.extend_def;
            // Bind the extend's params through the target's argument positions (as expand_method).
            let mut frame = Vector::<Subst>::new();
            let tt = ed.target_type;
            if tt != NODE_NONE && a.at_const(tt).kind == NodeKind::NODE_TYPE_PATH {
                let targs = a.at_const(tt).as_data.type_path.args;
                let mut pos: u32 = 0;
                for k in 0..targs.len {
                    let an = unsafe a.list(targs)[k as usize];
                    let mut bind = a.resolution_def(an);
                    if bind.node == NODE_NONE && a.at_const(an).kind == NodeKind::NODE_TYPE_PATH {
                        let ps = a.at_const(an).as_data.type_path.parts;
                        if ps.len != 0 {
                            bind = a.resolution_def(unsafe a.list(ps)[(ps.len - 1) as usize]);
                        }
                    }
                    if bind.node != NODE_NONE && pos < r.args_len {
                        let bk = unsafe (&*(&*self.pkg).module_ast_const(bind.module)).at_const(bind.node).kind;
                        if bk == NodeKind::NODE_GENERIC_PARAM {
                            frame.push(
                                Subst {
                                    pmod: bind.module,
                                    pdecl: bind.node,
                                    key: *self.keys.at((r.args_start + pos) as usize),
                                },
                            );
                        }
                    }
                    pos += 1;
                }
            }
            for j in 0..ed.items.len {
                let iid = unsafe a.list(ed.items)[j as usize];
                // Signatures come from the package item metadata (params then returns, owner-pool
                // TypeIds), not from re-walking the item's syntax; non-function items record none.
                let sg = (unsafe &*self.pkg).item_sig(row.emod, iid);
                if sg == null || unsafe sg.generic {
                    // Generic methods substitute per explicit (instance, targs) pair.
                    continue;
                }
                let sn = (unsafe sg.np) as u32 + (unsafe sg.nr) as u32;
                for si in 0..sn {
                    self.note_type(a, (unsafe &*self.pkg).sig_type(unsafe sg.start + si), &frame, 0);
                }
            }
        }
    }

    // The generic extend a method decl belongs to, or NODE_NONE.
    fn enclosing_extend(self: &Self, d: DefId) NodeId {
        let ext = switch self.ext_of.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => (*v) as NodeId,
            None => NODE_NONE,
        };
        if ext == NODE_NONE {
            return NODE_NONE;
        }
        let a = unsafe &*(&*self.pkg).module_ast_const(d.module);
        if a.at_const(ext).as_data.extend_def.generics.len == 0 {
            return NODE_NONE;
        }
        return ext;
    }

    // Walk a demanded method's body: the receiver-instance keys bind the extend's params (through
    // the target's argument positions), the trailing keys bind the method's own params.
    fn expand_method(self: &mut Self, r: &InstRec) {
        let a = unsafe &*(&*self.pkg).module_ast_const(r.def.module);
        let ext = self.enclosing_extend(r.def);
        if ext == NODE_NONE {
            return;
        }
        let ed = a.at_const(ext).as_data.extend_def;
        let mut frame = Vector::<Subst>::new();
        let tt = ed.target_type;
        let mut pos: u32 = 0;
        if tt != NODE_NONE && a.at_const(tt).kind == NodeKind::NODE_TYPE_PATH {
            let targs = a.at_const(tt).as_data.type_path.args;
            for k in 0..targs.len {
                let an = unsafe a.list(targs)[k as usize];
                let mut bind = a.resolution_def(an);
                if bind.node == NODE_NONE && a.at_const(an).kind == NodeKind::NODE_TYPE_PATH {
                    let ps = a.at_const(an).as_data.type_path.parts;
                    if ps.len != 0 {
                        bind = a.resolution_def(unsafe a.list(ps)[(ps.len - 1) as usize]);
                    }
                }
                if bind.node != NODE_NONE && pos < r.args_len {
                    let bk = unsafe (&*(&*self.pkg).module_ast_const(bind.module)).at_const(bind.node).kind;
                    if bk == NodeKind::NODE_GENERIC_PARAM {
                        frame.push(
                            Subst {
                                pmod: bind.module,
                                pdecl: bind.node,
                                key: *self.keys.at((r.args_start + pos) as usize),
                            },
                        );
                    }
                }
                pos += 1;
            }
        }
        let fd = a.at_const(r.def.node).as_data.function;
        let mut ai = pos;
        for g in 0..fd.generics.len {
            let gp = unsafe a.list(fd.generics)[g as usize];
            if a.at_const(gp).as_data.generic_param.is_lifetime {
                continue;
            }
            if ai < r.args_len {
                frame.push(Subst { pmod: r.def.module, pdecl: gp, key: *self.keys.at((r.args_start + ai) as usize) });
            }
            ai += 1;
        }
        if fd.body == NODE_NONE {
            return;
        }
        let bi = self.body_idx(r.def.module, r.def.node, false);
        if bi >= 0 {
            self.walk_kept(bi, a, &frame);
            let mut cls = Vector::<NodeId>::new();
            {
                let bp = self.kept.at(bi as usize) as *const irl::Lowerer;
                for c in 0..(unsafe &*bp).closures.len() {
                    cls.push((unsafe &*bp).closures[c]);
                }
            }
            self.expand_closures(&cls, r.def.module, &frame);
        }
    }

    // The `kept` index of `(m, node)`'s lowering, lowering it on first demand; -1 = cannot lower.
    fn body_idx(self: &mut Self, m: ModuleId, node: NodeId, closure: bool) i64 {
        let key = skey_mix(0, m as u64 << 32 | node as u64);
        let hit = switch self.kept_ix.get(&key) {
            Some(v) => (*v) as i64,
            None => (-2) as i64,
        };
        if hit != -2 {
            return hit;
        }
        if self.keep != null {
            let kp = unsafe &mut *self.keep;
            let ki = switch kp.ix.get(&key) {
                Some(v) => (*v) as i64,
                None => (-1) as i64,
            };
            if ki >= 0 {
                let klw = replace(&mut kp.kept[ki as usize], irl::Lowerer::new(self.pkg, m, node));
                let slot = self.kept.len() as i64;
                self.kept.push(klw);
                self.wcache.push(
                    WalkCache {
                        built: false,
                        tys: Vector::<TypeId>::new(),
                        consts: Vector::<u32>::new(),
                        calls: Vector::<u32>::new(),
                    },
                );
                self.kept_ix.insert(key, slot as u64);
                return slot;
            }
        }
        self.low.retarget(m);
        let ok = if closure {
            self.low.lower_closure_body(node);
        } else {
            self.low.lower_fn(node);
        };
        let mut slot = (-1) as i64;
        if ok {
            let mut klw = irl::Lowerer::new(self.pkg, m, node);
            klw.adopt(&self.low);
            slot = self.kept.len() as i64;
            self.kept.push(klw);
            self.wcache.push(
                WalkCache {
                    built: false,
                    tys: Vector::<TypeId>::new(),
                    consts: Vector::<u32>::new(),
                    calls: Vector::<u32>::new(),
                },
            );
        }
        self.kept_ix.insert(key, slot as u64);
        return slot;
    }

    // Walk kept body `ki` under `frame` through its walk cache (built on first use).
    fn walk_kept(self: &mut Self, ki: i64, a: &Ast, frame: &Vector<Subst>) {
        let bp = self.kept.at(ki as usize) as *const irl::Lowerer;
        if !self.wcache.at(ki as usize).built {
            self.wt_seen.clear();
            let b = unsafe &bp.body;
            for i in 0..b.locals.len() {
                let t = b.locals.at(i).ty;
                if t != TYPE_NONE && !self.wt_seen.contains_key(&(t as u64)) {
                    self.wt_seen.insert(t, 1);
                    self.wcache[ki as usize].tys.push(t);
                }
            }
            for i in 0..b.rvalues.len() {
                let t = b.rvalues.at(i).target;
                if t != TYPE_NONE && !self.wt_seen.contains_key(&(t as u64)) {
                    self.wt_seen.insert(t, 1);
                    self.wcache[ki as usize].tys.push(t);
                }
            }
            for i in 0..b.constants.len() {
                let c = b.constants.at(i);
                if c.kind == ir::CK_ITEM && c.targ_len != 0 {
                    self.wcache[ki as usize].consts.push(i as u32);
                }
            }
            for i in 0..b.blocks.len() {
                let t = b.blocks.at(i).term;
                if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
                    self.wcache[ki as usize].calls.push(i as u32);
                }
            }
            self.wcache[ki as usize].built = true;
        }
        self.bodies += 1;
        let b = unsafe &bp.body;
        let wp = self.wcache.at(ki as usize) as *const WalkCache;
        for i in 0..(unsafe &*wp).tys.len() {
            self.note_type(a, *(unsafe &*wp).tys.at(i), frame, 0);
        }
        for i in 0..(unsafe &*wp).consts.len() {
            let c = *b.constants.at((*(unsafe &*wp).consts.at(i)) as usize);
            self.note_call(a, c.item, b, c.targ_start, c.targ_len, frame);
        }
        for i in 0..(unsafe &*wp).calls.len() {
            let t = b.blocks.at((*(unsafe &*wp).calls.at(i)) as usize).term;
            if t.targs_len != 0 {
                self.note_call(a, t.callee, b, t.targs_start, t.targs_len, frame);
            }
            self.note_method(a, &t, b, frame);
        }
    }

    fn expand_closures(self: &mut Self, cls: &Vector<NodeId>, m: ModuleId, frame: &Vector<Subst>) {
        let a = unsafe &*(&*self.pkg).module_ast_const(m);
        for c in 0..cls.len() {
            let ci = self.body_idx(m, cls[c], true);
            if ci < 0 {
                continue;
            }
            // Nested closures append to the cached lowering's list; one level at a time keeps
            // this bounded. Raw borrow: walk_body never touches `kept`, but body_idx below can
            // grow it, so the nested ids are copied out first.
            self.walk_kept(ci, a, frame);
            let mut nested = Vector::<NodeId>::new();
            {
                let bp = self.kept.at(ci as usize) as *const irl::Lowerer;
                for c2 in 0..(unsafe &*bp).closures.len() {
                    nested.push((unsafe &*bp).closures[c2]);
                }
            }
            for c2 in 0..nested.len() {
                let ci2 = self.body_idx(m, nested[c2], true);
                if ci2 < 0 {
                    continue;
                }
                self.walk_kept(ci2, a, frame);
            }
        }
    }

    /// Seed every concrete body of every emitted module (functions, methods, constant initializers)
    /// and run the expansion worklist to its fixed point.
    pub fn collect(self: &mut Self) {
        let p = unsafe &*self.pkg;
        let empty = Vector::<Subst>::new();
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let nid = unsafe a.list(items)[i as usize];
                if a.at_const(nid).kind != NodeKind::NODE_EXTEND {
                    continue;
                }
                let d = self.ext_target(a, nid);
                if d.node != NODE_NONE {
                    self.exts.push(ExtRow { dmod: d.module, ddecl: d.node, emod: m as ModuleId, enode: nid });
                    let ms = a.at_const(nid).as_data.extend_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe a.list(ms)[j as usize];
                        self.ext_of.insert(skey_mix(0, m as u64 << 32 | mid as u64), nid);
                    }
                }
            }
        }
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let nid = unsafe a.list(items)[i as usize];
                if a.at_const(nid).kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                let ms = a.at_const(nid).as_data.interface_def.items;
                for j in 0..ms.len {
                    let mid = unsafe a.list(ms)[j as usize];
                    self.iface_of.insert(skey_mix(0, m as u64 << 32 | mid as u64), nid);
                }
            }
        }
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast || self.module_elided(m) {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let nid = unsafe a.list(items)[i as usize];
                let n = a.at_const(nid);
                if n.kind == NodeKind::NODE_FUNCTION {
                    if n.as_data.function.generics.len == 0 && !n.as_data.function.is_extern && n.as_data.function.body != NODE_NONE {
                        self.seed_body(m as ModuleId, nid, a, &empty);
                    }
                } else if n.kind == NodeKind::NODE_EXTEND {
                    if n.as_data.extend_def.generics.len != 0 {
                        // Generic-extend methods run under their instances' frames.
                        continue;
                    }
                    let inner = n.as_data.extend_def.items;
                    for j in 0..inner.len {
                        let iid = unsafe a.list(inner)[j as usize];
                        let it = a.at_const(iid);
                        if it.kind == NodeKind::NODE_FUNCTION && it.as_data.function.body != NODE_NONE && it.as_data.function.generics.len == 0 {
                            self.seed_body(m as ModuleId, iid, a, &empty);
                        }
                    }
                } else if n.kind == NodeKind::NODE_CONST {
                    if !n.as_data.const_def.is_extern && n.as_data.const_def.value != NODE_NONE {
                        let mut lw = irl::Lowerer::new(self.pkg, m as ModuleId, nid);
                        if lw.lower_const(nid) {
                            self.walk_body(&lw.body, a, &empty);
                        }
                    }
                } else if n.kind == NodeKind::NODE_TYPE_ALIAS {
                    // an exported alias of a concrete instantiation (`pub type u128 = UInt<128>`)
                    // is API surface: the instance is reachable without any body naming it.
                    if n.as_data.type_alias.is_public && n.as_data.type_alias.ty != NODE_NONE {
                        let t = a.type_of(n.as_data.type_alias.ty);
                        if t != TYPE_NONE {
                            self.note_type(a, t, &empty, 0);
                        }
                        let t2 = a.type_of(nid);
                        if t2 != TYPE_NONE {
                            self.note_type(a, t2, &empty, 0);
                        }
                    }
                }
            }
        }
        self.run();
    }

    // True for a prelude module the emitter skips (see `live`).
    fn module_elided(self: &Self, m: usize) bool {
        if self.live == null {
            return false;
        }
        let p = unsafe &*self.pkg;
        return p.modules.at(m).prelude && !unsafe self.live[m];
    }

    fn seed_body(self: &mut Self, m: ModuleId, fnode: NodeId, a: &Ast, empty: &Vector<Subst>) {
        let bi = self.body_idx(m, fnode, false);
        if bi < 0 {
            return;
        }
        self.walk_kept(bi, a, empty);
        let mut cls = Vector::<NodeId>::new();
        {
            let bp = self.kept.at(bi as usize) as *const irl::Lowerer;
            for c in 0..(unsafe &*bp).closures.len() {
                cls.push((unsafe &*bp).closures[c]);
            }
        }
        self.expand_closures(&cls, m, empty);
    }
}
