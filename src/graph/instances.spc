// The instance and reachability graph: discovers every concrete generic instantiation by walking
// lowered Core IR bodies from concrete roots, expanding generic bodies under substitution frames.
// Keys are package-stable: a declaration DefId plus the skey of every concrete argument, so records
// from different module pools compare equal without touching any pool. Runs in SHADOW mode behind
// SC_INSTANCES=1: the established propagation stays authoritative and the driver reports set
// differences; the graph becomes the production planner only after drop-glue edges join it.
//
// Comparison caveat (measured on the self-host corpus): the module pools OVERAPPROXIMATE -- the
// established propagation interns Slice/Option/tuple instances for every method of every instance
// regardless of demand, so raw-pool diffing reports the graph "missing" records nothing emits.
// The production switch must compare against the per-TU emitted set instead.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import ir::lower as irl;

/// Record kinds.
pub const IG_AGG: u8 = 0; // generic struct/enum instantiation
pub const IG_FN: u8 = 1; // generic function instantiation
pub const IG_METHOD: u8 = 2; // method demanded on a generic-aggregate instance

pub const IG_NONE: u32 = 0xFFFFFFFF;

/// One instance argument: its package-stable skey plus, for const-generic values, the folded
/// integer (what lets compound const-exprs like `{BITS*2}` evaluate under a frame).
pub struct ArgKey {
    pub skey: u64,
    pub val: i64,
    pub has_val: bool,
}

/// One discovered instance: the declaration plus its argument keys (flat pool range).
pub struct InstRec {
    pub kind: u8,
    pub def: DefId,
    pub args_start: u32,
    pub args_len: u32,
    pub hash: u64,
    pub expanded: bool,
    /// Pool anchor: the module + TypeId where this instance was first seen as a real pool type
    /// (TYPE_NONE = derived through substitution/cross product only). Homes compute from it.
    pub amod: ModuleId,
    pub aty: TypeId,
    pub home: ModuleId, // owner-emits home (anchored records; 0xFFFF = not computed)
    /// Argument anchor for FN/METHOD records: the pool whose REAL TypeIds first spelled this
    /// instance concretely -- what per-instance emission binds its substitution env from.
    /// `arty` = the receiver instance type (METHOD only), `aargs` = the fn's/method's own bound
    /// argument types. False = seen only under substitution frames.
    pub anchored: bool,
    pub amod2: ModuleId,
    pub arty: TypeId,
    pub aargs: [TypeId; 8],
}

/// One extend targeting a declaration (built once; aggregate expansion walks its methods).
struct ExtRow {
    pub dmod: ModuleId,
    pub ddecl: NodeId,
    pub emod: ModuleId,
    pub enode: NodeId,
}

/// One substitution frame entry: generic-param decl -> the argument's key (value included for
/// const params, so dependent const-exprs can fold).
struct Subst {
    pub pmod: ModuleId,
    pub pdecl: NodeId,
    pub key: ArgKey,
}

pub struct InstGraph {
    pub pkg: *const loader::Package,
    pub recs: Vector<InstRec>,
    pub keys: Vector<ArgKey>, // flat argument-key pool
    index: Vector<u32>, // open addressing over recs (hash lookup, exact compare)
    ix_used: u32,
    cursor: usize, // worklist: recs[cursor..] await expansion
    exts: Vector<ExtRow>, // every extend in the package, keyed by its target declaration
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
    }
}

fn mix(h: u64, v: u64) u64 {
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

/// The frame-free ArgKey of a pool type: its normalized skey, plus the value for a folded const.
pub fn argkey_of(a: &Ast, t: TypeId) ArgKey {
    let y = *a.type_at(t);
    if y.kind == TypeKind::TYPE_CONST {
        return ArgKey { skey: skey_norm(a, t, 0), val: y.as_data.value, has_val: true };
    }
    return ArgKey { skey: skey_norm(a, t, 0), val: 0, has_val: false };
}

extend InstGraph {
    pub fn new(pkg: *const loader::Package) InstGraph {
        return InstGraph {
            pkg: pkg,
            recs: Vector::<InstRec>::new(),
            keys: Vector::<ArgKey>::new(),
            index: Vector::<u32>::new(),
            ix_used: 0,
            cursor: 0,
            exts: Vector::<ExtRow>::new(),
            bodies: 0,
            overflow: false,
            budget: 64000000,
        };
    }

    fn spend(self: &mut Self, n: u32) bool {
        if self.budget < n {
            self.budget = 0;
            self.overflow = true;
            return false;
        }
        self.budget -= n;
        return true;
    }

    /// Probe-only record lookup (never inserts): IG_NONE when the instance was never discovered.
    pub const fn lookup(self: &Self, kind: u8, def: DefId, args: &Vector<ArgKey>) u32 {
        if self.index.len() == 0 {
            return IG_NONE;
        }
        let mut h = mix(mix(1469598103934665603u64, kind), def.module);
        h = mix(h, def.node);
        for i in 0..args.len() {
            h = mix(h, args.at(i).skey);
        }
        let mask = self.index.len() - 1;
        let mut i = h as usize & mask;
        loop {
            let cur = self.index[i];
            if cur == IG_NONE {
                return IG_NONE;
            }
            let r = self.recs.at(cur as usize);
            if r.hash == h && r.kind == kind && r.def.module == def.module && r.def.node == def.node && r.args_len as usize == args.len() {
                let mut eq = true;
                for k in 0..r.args_len {
                    if self.keys.at((r.args_start + k) as usize).skey != args.at(k as usize).skey {
                        eq = false;
                    }
                }
                if eq {
                    return cur;
                }
            }
            i = i + 1 & mask;
        }
    }

    /// The per-TU emission plan: record ids ordered by the ESTABLISHED emitter's own discovery
    /// sequence for `tu` (the order oracle the first backend switch must preserve), followed by
    /// graph-only records homed to `tu` (drop glue and the like) in record order. `unmapped` counts
    /// emitted instances the graph never discovered -- the coverage gate requires zero. Homes must
    /// be computed first.
    pub fn plan_tu(self: &Self, p: &loader::Package, tu: ModuleId, out: &mut Vector<u32>, unmapped: &mut u32) {
        let mut planned = Vector::<bool>::new();
        for _r in 0..self.recs.len() {
            planned.push(false);
        }
        for i in 0..p.shadow_insts.len() {
            let sh = *p.shadow_insts.at(i);
            if sh.tu != tu || sh.n == 0xFF {
                continue;
            }
            let mut args = Vector::<ArgKey>::new();
            for k in 0..sh.n {
                args.push(ArgKey { skey: unsafe sh.keys[k as usize], val: 0, has_val: false });
            }
            let mut id = self.lookup(IG_FN, sh.def, &args);
            if id == IG_NONE {
                id = self.lookup(IG_METHOD, sh.def, &args);
            }
            args.free();
            if id == IG_NONE {
                *unmapped += 1;
            } else if !planned[id as usize] {
                planned.set(id as usize, true);
                out.push(id);
            }
        }
        for r in 0..self.recs.len() {
            if !planned[r] && self.recs.at(r).home == tu && (self.recs.at(r).kind == IG_FN || self.recs.at(r).kind == IG_METHOD) {
                out.push(r as u32);
            }
        }
        planned.free();
    }

    // Intern a record; returns its id and whether it was new. Hash + equality use skeys only (the
    // value is derived data riding along for frame evaluation).
    pub fn add(self: &mut Self, kind: u8, def: DefId, args: &Vector<ArgKey>, fresh: &mut bool) u32 {
        let mut h = mix(mix(1469598103934665603u64, kind), def.module);
        h = mix(h, def.node);
        for i in 0..args.len() {
            h = mix(h, args.at(i).skey);
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
                let mut i2 = self.recs.at(r).hash as usize & cap - 1;
                while nix[i2] != IG_NONE {
                    i2 = i2 + 1 & cap - 1;
                }
                nix.set(i2, r as u32);
            }
            self.index = nix;
            self.ix_used = self.recs.len() as u32;
        }
        let mask = self.index.len() - 1;
        let mut i = h as usize & mask;
        loop {
            let cur = self.index[i];
            if cur == IG_NONE {
                let start = self.keys.len() as u32;
                for k in 0..args.len() {
                    self.keys.push(*args.at(k));
                }
                self.recs.push(
                    InstRec {
                        kind: kind,
                        def: def,
                        args_start: start,
                        args_len: args.len() as u32,
                        hash: h,
                        expanded: false,
                        amod: 0,
                        aty: TYPE_NONE,
                        home: 0xFFFF,
                    },
                );
                let id = self.recs.len() as u32 - 1;
                self.index.set(i, id);
                self.ix_used += 1;
                *fresh = true;
                return id;
            }
            let r = self.recs.at(cur as usize);
            if r.hash == h && r.kind == kind && r.def.module == def.module && r.def.node == def.node && r.args_len as usize == args.len() {
                let mut eq = true;
                for k in 0..r.args_len {
                    if self.keys.at((r.args_start + k) as usize).skey != args.at(k as usize).skey {
                        eq = false;
                    }
                }
                if eq {
                    *fresh = false;
                    return cur;
                }
            }
            i = i + 1 & mask;
        }
    }

    // ---- substitution-aware type keys -------------------------------------------------------------

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
        // identity: one coefficient-1 param, no constant, no divisor
        let mut nact: u32 = 0;
        let mut hit: i64 = -1;
        for i in 0..l.n {
            if unsafe l.c[i as usize] != 0 {
                nact += 1;
                hit = i;
            }
        }
        if l.k == 0 && lin_div_of(l) <= 1 && nact == 1 && unsafe l.c[hit as usize] == 1 {
            let pd = unsafe l.p[hit as usize];
            for i in 0..frame.len() {
                if frame.at(i).pmod == pd.module && frame.at(i).pdecl == pd.node {
                    return frame.at(i).key;
                }
            }
            return none;
        }
        // compound: fold value = (k + sum(c_i * v_i)) / div from bound VALUES
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
                    // widths are small; a huge operand means a non-width const rode in -- bail
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
        let d = lin_div_of(l);
        if d > 1 {
            v = v / d;
        }
        // key exactly as type_skey keys the folded TYPE_CONST (qualifier 0)
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
    fn note_type(self: &mut Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) {
        if t == TYPE_NONE || depth > 8 || !self.spend(1) {
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
                let mut args = Vector::<ArgKey>::new();
                args.push(self.argkey_subst(a, y.as_data.elem, frame));
                let mut fresh = false;
                let _ = self.add(IG_AGG, DefId { module: hit.mid, node: hit.node }, &args, &mut fresh);
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
        // the declaration must be a real aggregate (dyn fn carriers ride FUNCTION_TYPE decls)
        let da = unsafe &*(&*self.pkg).module_ast_const(it.module);
        let dk = da.at_const(it.decl).kind;
        for i in 0..it.n {
            self.note_type(a, unsafe it.args[i], frame, depth + 1);
        }
        if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM {
            return;
        }
        let mut args = Vector::<ArgKey>::new();
        for i in 0..it.n {
            if !self.concrete_subst(a, unsafe it.args[i], frame, depth + 1) {
                return;
            }
            args.push(self.argkey_subst(a, unsafe it.args[i], frame));
        }
        let mut fresh = false;
        let id = self.add(IG_AGG, DefId { module: it.module, node: it.decl }, &args, &mut fresh);
        if self.recs.at(id as usize).aty == TYPE_NONE && a.type_concrete(t) {
            // a pool-concrete spelling anchors the record (frames leave symbolic types unanchored)
            self.recs[id as usize].amod = a.module;
            self.recs[id as usize].aty = t;
        }
    }

    // ---- body walking -----------------------------------------------------------------------------

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
        // the method's enclosing extend, if it is generic
        let ma = unsafe &*(&*self.pkg).module_ast_const(t.callee.module);
        let mut ext = NODE_NONE;
        for x in 0..self.exts.len() {
            let row = self.exts.at(x);
            if row.emod != t.callee.module {
                continue;
            }
            let ed = ma.at_const(row.enode).as_data.extend_def;
            for j in 0..ed.items.len {
                if unsafe ma.list(ed.items)[j as usize] == t.callee.node {
                    ext = row.enode;
                }
            }
        }
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
        // peel the receiver to its instance
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
        // method key = receiver-instance args, then the method's own bound args (bail on symbolic)
        let mut key = Vector::<ArgKey>::new();
        for i in 0..it.n {
            if !self.concrete_subst(a, unsafe it.args[i], frame, 0) {
                return;
            }
            key.push(self.argkey_subst(a, unsafe it.args[i], frame));
        }
        for i in 0..t.targs_len {
            let ty2 = b.targ_pool[(t.targs_start + i) as usize];
            if !self.concrete_subst(a, ty2, frame, 0) {
                return;
            }
            key.push(self.argkey_subst(a, ty2, frame));
        }
        let mut fresh = false;
        let id = self.add(IG_METHOD, t.callee, &key, &mut fresh);
        if !self.recs.at(id as usize).anchored && t.targs_len <= 8 && a.type_concrete(rt) {
            let mut all = true;
            for i in 0..t.targs_len {
                if !a.type_concrete(b.targ_pool[(t.targs_start + i) as usize]) {
                    all = false;
                }
            }
            if all {
                let mut rc2 = *self.recs.at(id as usize);
                rc2.anchored = true;
                rc2.amod2 = a.module;
                rc2.arty = rt;
                for i in 0..t.targs_len {
                    unsafe rc2.aargs[i as usize] = b.targ_pool[(t.targs_start + i) as usize];
                }
                self.recs.set(id as usize, rc2);
            }
        }
    }

    // A resolved call/value use of a generic function with bound arguments.
    fn note_call(self: &mut Self, a: &Ast, callee: DefId, b: &ir::CoreBody, ts: u32, tn: u32, frame: &Vector<Subst>) {
        let mut args = Vector::<ArgKey>::new();
        for i in 0..tn {
            let t = b.targ_pool[(ts + i) as usize];
            if !self.concrete_subst(a, t, frame, 0) {
                return; // still symbolic here; the enclosing instantiation walks it bound
            }
            args.push(self.argkey_subst(a, t, frame));
        }
        let mut fresh = false;
        let id = self.add(IG_FN, callee, &args, &mut fresh);
        if !self.recs.at(id as usize).anchored && tn <= 8 {
            let mut all = true;
            for i in 0..tn {
                if !a.type_concrete(b.targ_pool[(ts + i) as usize]) {
                    all = false;
                }
            }
            if all {
                let mut rc2 = *self.recs.at(id as usize);
                rc2.anchored = true;
                rc2.amod2 = a.module;
                for i in 0..tn {
                    unsafe rc2.aargs[i as usize] = b.targ_pool[(ts + i) as usize];
                }
                self.recs.set(id as usize, rc2);
            }
        }
    }

    // Expand queued records to a fixed point, alternating the worklist with the demand cross
    // product: method demand is PER DECLARATION (one call to `.at` on any Vector<X> emits `at` for
    // every reachable Vector instance -- the established method_used semantics), so each demanded
    // non-generic method pairs with every instance of its extend's target.
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
        // demanded method decls, deduped
        let mut dm = Vector::<DefId>::new();
        for r in 0..self.recs.len() {
            let rec = self.recs.at(r);
            if rec.kind != IG_METHOD {
                continue;
            }
            let mut dup = false;
            for i in 0..dm.len() {
                if dm.at(i).module == rec.def.module && dm.at(i).node == rec.def.node {
                    dup = true;
                }
            }
            if !dup {
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
                    dm.push(DefId { module: m as ModuleId, node: n as NodeId });
                }
            }
        }
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let src = unsafe (&*self.pkg).modules.at(row.emod as usize).source.as_str();
            let ed = a.at_const(row.enode).as_data.extend_def;
            // an interface-conforming extend emits EVERY bodied method per instance -- the
            // method_used gate applies only to plain extends
            let conforming = ed.interface_type != NODE_NONE;
            for j in 0..ed.items.len {
                let iid = unsafe a.list(ed.items)[j as usize];
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_FUNCTION || it.as_data.function.body == NODE_NONE {
                    continue;
                }
                let nsp = a.at_const(it.as_data.function.name).as_data.name.text;
                if conforming || src.slice(nsp.start as usize, nsp.end as usize) == "free" {
                    let mut dup = false;
                    for i in 0..dm.len() {
                        if dm.at(i).module == row.emod && dm.at(i).node == iid {
                            dup = true;
                        }
                    }
                    if !dup {
                        dm.push(DefId { module: row.emod, node: iid });
                    }
                }
            }
        }
        // a demanded INTERFACE method maps to each conforming extend's override of the same name:
        // dispatch through a bound selects the impl per receiver, so the emitter emits the impl
        // decl -- the demand must follow it there
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
        self.cross_defaults();
        let nrec = self.recs.len();
        for d in 0..dm.len() {
            let md = *dm.at(d);
            let ext = self.enclosing_extend(md);
            if ext == NODE_NONE {
                continue;
            }
            let a = unsafe &*(&*self.pkg).module_ast_const(md.module);
            // a demanded method with own generics pairs only through explicit (instance, targs)
            if a.at_const(md.node).as_data.function.generics.len != 0 {
                continue;
            }
            let target = self.ext_target(a, ext);
            if target.node == NODE_NONE {
                continue;
            }
            for r in 0..nrec {
                let rec = *self.recs.at(r);
                if rec.kind != IG_AGG || rec.def.module != target.module || rec.def.node != target.node {
                    continue;
                }
                let mut args = Vector::<ArgKey>::new();
                for k in 0..rec.args_len {
                    args.push(*self.keys.at((rec.args_start + k) as usize));
                }
                let mut fresh = false;
                let id = self.add(IG_METHOD, md, &args, &mut fresh);
                if !self.recs.at(id as usize).anchored && rec.aty != TYPE_NONE {
                    // the receiver AGG anchor is the demanded method's receiver too
                    self.recs[id as usize].anchored = true;
                    self.recs[id as usize].amod2 = rec.amod;
                    self.recs[id as usize].arty = rec.aty;
                }
            }
        }
    }

    // Interface default bodies: every extend that conforms `Target as Iface` emits one copy of each
    // default-bodied interface method per Target instance -- record those pairs so the emitted-set
    // diff can find them (def = the INTERFACE's method decl, keys = the instance args).
    fn cross_defaults(self: &mut Self) {
        let nrec = self.recs.len();
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
            // default-bodied interface methods the extend does NOT override
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
                // pair with every instance of the extend's target
                for r in 0..nrec {
                    let rec = *self.recs.at(r);
                    if rec.kind != IG_AGG {
                        continue;
                    }
                    let mut tmatch = false;
                    let tg = self.ext_target(a, row.enode);
                    if tg.module == rec.def.module && tg.node == rec.def.node {
                        tmatch = true;
                    }
                    if !tmatch {
                        continue;
                    }
                    let mut args = Vector::<ArgKey>::new();
                    for k in 0..rec.args_len {
                        args.push(*self.keys.at((rec.args_start + k) as usize));
                    }
                    let mut fresh = false;
                    let id = self.add(IG_METHOD, DefId { module: iface.module, node: imid }, &args, &mut fresh);
                    if !self.recs.at(id as usize).anchored && rec.aty != TYPE_NONE {
                        self.recs[id as usize].anchored = true;
                        self.recs[id as usize].amod2 = rec.amod;
                        self.recs[id as usize].arty = rec.aty;
                    }
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
            // an extend member reached as a plain call (assoc fns, turbofish method values) still
            // binds the extend's params through its leading argument keys
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
            // bind the declaration's non-lifetime params to the record's arg keys
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
            let mut lw = irl::Lowerer::new(self.pkg, r.def.module, r.def.node);
            if lw.lower_fn(r.def.node) {
                self.walk_body(&lw.body, da, &frame);
                self.expand_closures(&mut lw, r.def.module, &frame);
            }
        }
    }

    // The declaration an extend targets (the path node's resolution, else its last part's).
    fn ext_target(self: &Self, a: &Ast, ext: NodeId) DefId {
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
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            let mk = a.at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD {
                let tnode = a.at_const(mid).as_data.field.ty;
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
        let a = unsafe &*(&*self.pkg).module_ast_const(d.module);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_INTERFACE {
                continue;
            }
            let ms = a.at_const(nid).as_data.interface_def.items;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == d.node {
                    return nid;
                }
            }
        }
        return NODE_NONE;
    }

    // The interface an extend conforms to, resolved (module-qualified); node NODE_NONE when plain.
    fn ext_interface(self: &Self, a: &Ast, ext: NodeId) DefId {
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
    // types -- Option<&T> from `first`, iterators from `iter` -- regardless of demand.
    fn expand_signatures(self: &mut Self, r: &InstRec) {
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            if row.dmod != r.def.module || row.ddecl != r.def.node {
                continue;
            }
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let ed = a.at_const(row.enode).as_data.extend_def;
            // bind the extend's params through the target's argument positions (as expand_method)
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
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let fd = it.as_data.function;
                if fd.generics.len != 0 {
                    continue; // generic methods substitute per explicit (instance, targs) pair
                }
                for pi in 0..fd.params.len {
                    let pn = unsafe a.list(fd.params)[pi as usize];
                    self.note_type(a, a.type_of(pn), &frame, 0);
                }
                for ri in 0..fd.returns.len {
                    let rn = unsafe a.list(fd.returns)[ri as usize];
                    self.note_type(a, a.type_of(rn), &frame, 0);
                }
            }
        }
    }

    // The generic extend a method decl belongs to, or NODE_NONE.
    fn enclosing_extend(self: &Self, d: DefId) NodeId {
        let a = unsafe &*(&*self.pkg).module_ast_const(d.module);
        for x in 0..self.exts.len() {
            let row = self.exts.at(x);
            if row.emod != d.module {
                continue;
            }
            let ed = a.at_const(row.enode).as_data.extend_def;
            if ed.generics.len == 0 {
                continue;
            }
            for j in 0..ed.items.len {
                if unsafe a.list(ed.items)[j as usize] == d.node {
                    return row.enode;
                }
            }
        }
        return NODE_NONE;
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
        let mut lw = irl::Lowerer::new(self.pkg, r.def.module, r.def.node);
        if lw.lower_fn(r.def.node) {
            self.walk_body(&lw.body, a, &frame);
            self.expand_closures(&mut lw, r.def.module, &frame);
        }
    }

    fn expand_closures(self: &mut Self, lw: &mut irl::Lowerer, m: ModuleId, frame: &Vector<Subst>) {
        let a = unsafe &*(&*self.pkg).module_ast_const(m);
        for c in 0..lw.closures.len() {
            let cn = lw.closures[c];
            let mut cl = irl::Lowerer::new(self.pkg, m, cn);
            if cl.lower_closure_body(cn) {
                self.walk_body(&cl.body, a, frame);
                // nested closures append to cl.closures; one level at a time keeps this bounded
                for c2 in 0..cl.closures.len() {
                    let cn2 = cl.closures[c2];
                    let mut cl2 = irl::Lowerer::new(self.pkg, m, cn2);
                    if cl2.lower_closure_body(cn2) {
                        self.walk_body(&cl2.body, a, frame);
                    }
                }
            }
        }
    }

    /// Seed every concrete body in the package (functions, methods, constant initializers) and run
    /// the expansion worklist to its fixed point.
    /// Feed every scheduled destruction root type into the graph (glue roots): the aggregate
    /// records and their `free` methods then join through the normal demand rules.
    pub fn demand_drops(self: &mut Self) {
        let p = unsafe &*self.pkg;
        let empty = Vector::<Subst>::new();
        for i in 0..p.drop_tys.len() {
            let rec = p.drop_tys[i];
            let mid = (rec >> 32) as ModuleId;
            let ty = (rec & 0xFFFFFFFFu64) as TypeId;
            let a = unsafe &*p.module_ast_const(mid);
            self.note_type(a, ty, &empty, 0);
        }
    }

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
                let n = a.at_const(nid);
                if n.kind == NodeKind::NODE_FUNCTION {
                    if n.as_data.function.generics.len == 0 && !n.as_data.function.is_extern && n.as_data.function.body != NODE_NONE {
                        self.seed_body(m as ModuleId, nid, a, &empty);
                    }
                } else if n.kind == NodeKind::NODE_EXTEND {
                    if n.as_data.extend_def.generics.len != 0 {
                        continue; // generic-extend methods run under their instances' frames
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
                    // is API surface: the instance is reachable without any body naming it
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

    /// Owner-emits homes for every anchored aggregate record (the loader's established rules),
    /// then verify anchor-independence: recompute the home from EVERY pool that holds the
    /// instance and count disagreements. Returns (computed, mismatches) through the out params.
    pub fn compute_homes(self: &mut Self, computed: &mut u32, mismatches: &mut u32) {
        let p = unsafe &*self.pkg;
        *computed = 0;
        *mismatches = 0;
        for r in 0..self.recs.len() {
            let rec = *self.recs.at(r);
            if rec.kind != IG_AGG || rec.aty == TYPE_NONE {
                continue;
            }
            let a = unsafe &*p.module_ast_const(rec.amod);
            let y = *a.type_at(rec.aty);
            if y.kind != TypeKind::TYPE_INSTANCE {
                continue;
            }
            let it = *a.instance(y.as_data.inst);
            self.recs[r].home = p.instance_home_mid(rec.amod, &it);
            *computed += 1;
        }
        // anchor-independence: every pool spelling of a record must agree on the home
        for m in 0..p.modules.len() {
            if !p.modules.at(m).has_ast {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            for ii in 0..a.instances.len() {
                let it = *a.instance(ii as u32);
                let da = unsafe &*p.module_ast_const(it.module);
                let dk = da.at_const(it.decl).kind;
                if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM {
                    continue;
                }
                let mut args = Vector::<ArgKey>::new();
                let mut conc = true;
                for k in 0..it.n {
                    if !a.type_concrete(unsafe it.args[k]) {
                        conc = false;
                    }
                    args.push(argkey_of(a, unsafe it.args[k]));
                }
                if !conc {
                    continue;
                }
                let mut fresh = false;
                let id = self.add(IG_AGG, DefId { module: it.module, node: it.decl }, &args, &mut fresh);
                if fresh {
                    continue;
                }
                let h = p.instance_home_mid(m as ModuleId, &it);
                if self.recs.at(id as usize).home == 0xFFFF {
                    // a frame-derived record meets its pool spelling here: home lands now
                    self.recs[id as usize].home = h;
                    *computed += 1;
                } else if h != self.recs.at(id as usize).home {
                    *mismatches += 1;
                }
            }
        }
    }

    /// Module-dependency edges from the final records (plan: sorted adjacency, not an n*n matrix):
    /// one (anchor-module, home) edge per anchored record, deduped and sorted.
    pub fn module_deps(self: &mut Self, out: &mut Vector<u32>) {
        for r in 0..self.recs.len() {
            let rec = self.recs.at(r);
            if rec.kind != IG_AGG || rec.aty == TYPE_NONE || rec.home == 0xFFFF || rec.amod == rec.home {
                continue;
            }
            out.push(rec.amod as u32 << 16 | rec.home as u32);
        }
        out.sort();
        let mut w: usize = 0;
        for i in 0..out.len() {
            if w == 0 || out[i] != out[w - 1] {
                out.set(w, out[i]);
                w += 1;
            }
        }
        out.truncate(w);
    }

    fn seed_body(self: &mut Self, m: ModuleId, fnode: NodeId, a: &Ast, empty: &Vector<Subst>) {
        let mut lw = irl::Lowerer::new(self.pkg, m, fnode);
        if lw.lower_fn(fnode) {
            self.walk_body(&lw.body, a, empty);
            self.expand_closures(&mut lw, m, empty);
        }
    }
}
