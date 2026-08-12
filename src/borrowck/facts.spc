// Input-fact generation for the Core IR loan analysis: dense points, origins, loans,
// point-local subset edges, accesses, kills, and the init/move event stream, produced in one walk of
// a verified CoreBody. Facts are integers in Core IR order -- two serial runs generate identical
// vectors. Raw pointers, `str`, and slice views carry no origin here: their storage discipline is the
// unsafe world's contract, and tracking them would reject programs the language accepts.
import ast::ast as *;
import lexer::token as tok;
import module::loader as loader;
import ir::core as ir;
import borrowck::move_paths as mp;

pub const BF_NONE: u32 = 0xFFFFFFFF;

/// Loan kinds.
pub const LK_SHARED: u8 = 0;
pub const LK_MUT: u8 = 1;
pub const LK_RESERVED: u8 = 2; // two-phase mutable: reads stay legal until activation
pub const LK_CAP: u8 = 3; // closure mutable capture: invalidated only by storage death (parity)

/// Access kinds. FREE and CAP invalidate like moves; they exist so diagnostics can name the
/// operation (an explicit `.free()`, a closure capture) instead of a generic move.
pub const ACC_READ: u8 = 0;
pub const ACC_WRITE: u8 = 1;
pub const ACC_MOVE: u8 = 2;
pub const ACC_FREE: u8 = 3;
pub const ACC_CAP: u8 = 4;
pub const ACC_ACT: u8 = 6; // a reserved (two-phase) loan's exclusivity claim at its activation

/// Init/move events (dataflow transfer replays these per block).
pub const EV_ASSIGN: u8 = 0; // path fully (re)initialized
pub const EV_MOVE: u8 = 1; // path moved out
pub const EV_USE: u8 = 2; // path read (init required)
pub const EV_DEAD: u8 = 3; // local storage ends (path = local root)

pub struct Loan {
    pub view: bool, // the borrowed place is itself a borrow-carrying VALUE (a view): reborrow,
    // never an escape of this body's storage
    pub pin: bool, // a receiver pin from a carrying call result: element views ride a whole-value
    // MOVE of the container (heap storage is stable), so moves do not invalidate it
    pub place: ir::PlaceId,
    pub kind: u8,
    pub origin: u32,
    pub issued_at: u32,
    pub activated_at: u32, // BF_NONE until a reserved loan's first use point is known
    pub span: tok::Span,
}

pub struct Access {
    pub place: ir::PlaceId, // BF_NONE for a whole-local access (storage death)
    pub local: u32, // BF_NONE for a place access
    pub kind: u8,
    pub point: u32,
    pub span: tok::Span,
}

pub struct SubsetAt {
    pub from: u32,
    pub to: u32,
    pub point: u32,
}

pub struct KillAt {
    pub loan: u32,
    pub point: u32,
}

pub struct Event {
    pub kind: u8,
    pub path: u32,
    pub point: u32,
    pub span: tok::Span,
}

pub struct BodyFacts {
    pub npoints: u32,
    pub block_base: Vector<u32>, // per block: first point (2 per statement + 2 for the terminator)
    pub norigins: u32,
    pub nuniversal: u32, // origins [0, nuniversal): 0 = 'static, then per-arg/declared placeholders
    pub local_origin: Vector<u32>, // per local: its origin, or BF_NONE (type carries no borrow)
    pub origin_local: Vector<u32>, // per origin: the owning local (BF_NONE for placeholders)
    pub uni_name: Vector<tok::Span>, // per universal origin: declared lifetime name (empty = elided)
    pub arg_universal: Vector<u32>, // per local: seeded placeholder, or BF_NONE
    pub ret_origin: Vector<u32>, // per return slot: placeholder origin
    pub ret_elided: Vector<bool>, // per return slot: no declared lifetime (accepts every input)
    pub known_subsets: Vector<u64>, // declared placeholder relations, from << 32 | to
    pub uni_flows: Vector<u64>, // omnipresent origin -> universal flows (stores through &mut args)
    pub loans: Vector<Loan>,
    pub subsets: Vector<SubsetAt>,
    pub accesses: Vector<Access>,
    pub kills: Vector<KillAt>,
    pub events: Vector<Event>,
    pub ev_start: Vector<u32>, // per block: first event (+ one sentinel entry at the end)
    pub freed: Vector<u32>, // move paths consumed by an explicit `.free()` (wording refinement)
    pub observed: Vector<bool>, // per local: owned carrier whose destruction observes stored borrows
    pub moved_whole: Vector<bool>, // per local: some path moves the WHOLE local (ownership travels)
    pub cuts: Vector<u64>, // origin << 32 | stmt entry: whole-local rebind severs earlier flows there
    pub lwords: u32, // liveness row width (ceil(nlocals/64))
    pub luse: Vector<u64>, // per block: locals read before any full definition
    pub ldef: Vector<u64>, // per block: locals fully defined
}

extend BodyFacts as Free {
    pub fn free(self: &mut Self) {
        self.block_base.free();
        self.local_origin.free();
        self.origin_local.free();
        self.uni_name.free();
        self.arg_universal.free();
        self.ret_origin.free();
        self.ret_elided.free();
        self.known_subsets.free();
        self.uni_flows.free();
        self.loans.free();
        self.subsets.free();
        self.accesses.free();
        self.kills.free();
        self.events.free();
        self.ev_start.free();
        self.freed.free();
        self.observed.free();
        self.moved_whole.free();
        self.cuts.free();
        self.luse.free();
        self.ldef.free();
    }
}

// ---- ownership and borrow-carrying oracle ---------------------------------------------------------

/// One substitution entry for member walks under a generic instance: parameter decl -> the argument
/// as a (module, TypeId) pair in the QUERYING pool.
struct OwnSubst {
    pub pmod: ModuleId,
    pub pdecl: NodeId,
    pub amod: ModuleId,
    pub aty: TypeId,
}

/// Package-level type classification, package-stable and independent of any checker state. `owns`
/// mirrors the emitter's Free verdicts (explicit conformance, bound-filtered generic conformance,
/// member-derived ownership); `carries` says whether a value of the type can HOLD a tracked borrow
/// (references, and aggregates/closures embedding them). Raw pointers never count for either.
pub struct Owner {
    pub pkg: *const loader::Package,
    free_ext: Map<u64, u64>, // (tmod << 32 | tdecl) -> extend (emod << 32 | enode) + 1; absent = none
    ext_built: bool,
    owns_memo: Map<u64, u64>, // (mid << 32 | ty) -> 1 no / 2 yes (concrete types only)
    carry_memo: Map<u64, u64>,
    busy: Vector<u64>,
    // Per-callee and per-type-node caches: call boundaries re-read the same signatures constantly.
    pub callee_flags: Map<u64, u64>, // (mod << 32 | node) -> 4 | self << 0 | free << 1
    pub kinds_memo: Map<u64, u64>, // (mod << 32 | node) -> start << 16 | len into kinds_pool
    pub kinds_pool: Vector<u8>,
    pub tok_memo: Map<u64, u64>, // (mod << 32 | type node) -> start << 16 | len into tok_pool
    pub tok_pool: Vector<u64>,
}

extend Owner as Free {
    pub fn free(self: &mut Self) {
        self.free_ext.free();
        self.owns_memo.free();
        self.carry_memo.free();
        self.busy.free();
        self.callee_flags.free();
        self.kinds_memo.free();
        self.kinds_pool.free();
        self.tok_memo.free();
        self.tok_pool.free();
    }
}

extend Owner {
    pub fn new(pkg: *const loader::Package) Owner {
        return Owner {
            pkg: pkg,
            free_ext: Map::<u64, u64>::new(),
            ext_built: false,
            owns_memo: Map::<u64, u64>::new(),
            carry_memo: Map::<u64, u64>::new(),
            busy: Vector::<u64>::new(),
            callee_flags: Map::<u64, u64>::new(),
            kinds_memo: Map::<u64, u64>::new(),
            kinds_pool: Vector::<u8>::new(),
            tok_memo: Map::<u64, u64>::new(),
            tok_pool: Vector::<u64>::new(),
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    const fn ast_of(self: &Self, m: ModuleId) &Ast {
        return unsafe &*self.p().module_ast_const(m);
    }

    fn src_of(self: &Self, m: ModuleId) str<'static> {
        let s = self.p().modules.at(m as usize).source.as_str();
        return str::from_raw(s.ptr(), s.len());
    }

    fn span_text_is(self: &Self, m: ModuleId, sp: tok::Span, what: str) bool {
        let s = self.src_of(m);
        if sp.end <= sp.start || sp.end as usize > s.len() {
            return false;
        }
        return s.slice(sp.start as usize, sp.end as usize) == what;
    }

    // Scan every module's items once for `extend T as Free`.
    fn build_ext(self: &mut Self) {
        if self.ext_built {
            return;
        }
        self.ext_built = true;
        let mut keys = Vector::<u64>::new();
        let mut vals = Vector::<u64>::new();
        for m in 0..self.p().modules.len() {
            if !self.p().modules.at(m).has_ast {
                continue;
            }
            let a = self.ast_of(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND {
                    continue;
                }
                if it.as_data.extend_def.interface_type == NODE_NONE || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tr = a.resolution_def(it.as_data.extend_def.interface_type);
                if tr.node == NODE_NONE {
                    continue;
                }
                let trn = self.ast_of(tr.module).at_const(tr.node);
                if trn.kind != NodeKind::NODE_INTERFACE {
                    continue;
                }
                if !self.span_text_is(
                    tr.module,
                    self.ast_of(tr.module).at_const(trn.as_data.interface_def.name).as_data.name.text,
                    "Free",
                ) {
                    continue;
                }
                let tg = a.resolution_def(it.as_data.extend_def.target_type);
                if tg.node == NODE_NONE {
                    continue;
                }
                keys.push(tg.module as u64 << 32 | tg.node as u64);
                vals.push((m as u64 << 32 | iid as u64) + 1u64);
            }
        }
        for i in 0..keys.len() {
            let key = keys[i];
            switch self.free_ext.get(&key) {
                Some(_v) => {},
                None => {
                    self.free_ext.insert(key, vals[i]);
                },
            };
        }
        keys.free();
        vals.free();
    }

    fn free_extend_of(self: &mut Self, tmod: ModuleId, tdecl: NodeId) DefId {
        self.build_ext();
        let key = tmod as u64 << 32 | tdecl as u64;
        return switch self.free_ext.get(&key) {
            Some(v) => {
                let e = *v - 1u64;
                DefId { module: (e >> 32) as ModuleId, node: (e & 0xFFFFFFFFu64) as NodeId };
            },
            None => DefId { module: 0, node: NODE_NONE },
        };
    }

    fn param_has_free_bound(self: &Self, m: ModuleId, gp: NodeId) bool {
        let a = self.ast_of(m);
        let bs = a.at_const(gp).as_data.generic_param.bounds;
        for i in 0..bs.len {
            let bid = unsafe a.list(bs)[i as usize];
            if a.at_const(bid).kind == NodeKind::NODE_FUNCTION_TYPE {
                if a.at_const(bid).as_data.function_type.is_move {
                    return true;
                }
                continue;
            }
            let bd = a.resolution_def(bid);
            if bd.node == NODE_NONE {
                continue;
            }
            let bn = self.ast_of(bd.module).at_const(bd.node);
            if bn.kind == NodeKind::NODE_INTERFACE && self.span_text_is(
                bd.module,
                self.ast_of(bd.module).at_const(bn.as_data.interface_def.name).as_data.name.text,
                "Free",
            ) {
                return true;
            }
        }
        return false;
    }

    /// Does a value of `(mid, ty)` own memory (Free semantics: value uses are moves)?
    pub fn owns(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        let frame = Vector::<OwnSubst>::new();
        let r = self.owns_f(mid, ty, &frame, 0);
        return r;
    }

    fn owns_f(self: &mut Self, mid: ModuleId, ty: TypeId, frame: &Vector<OwnSubst>, depth: i32) bool {
        if ty == TYPE_NONE || depth > 12 {
            return false;
        }
        let y = *self.ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl {
                    let am = frame.at(i).amod;
                    let at = frame.at(i).aty;
                    let empty = Vector::<OwnSubst>::new();
                    let r = self.owns_f(am, at, &empty, depth + 1);
                    return r;
                }
            }
            return self.param_has_free_bound(y.module, y.as_data.decl);
        }
        let key = mid as u64 << 32 | ty as u64;
        let cacheable = frame.len() == 0 && self.ast_of(mid).type_concrete(ty);
        if cacheable {
            let mut have = false;
            let mut hit = false;
            switch self.owns_memo.get(&key) {
                Some(v) => {
                    have = true;
                    hit = *v == 2u64;
                },
                None => {},
            };
            if have {
                return hit;
            }
        }
        let r = self.owns_raw(mid, &y, frame, depth);
        if cacheable {
            let mut enc: u64 = 1;
            if r {
                enc = 2;
            }
            self.owns_memo.insert(key, enc);
        }
        return r;
    }

    fn owns_raw(self: &mut Self, mid: ModuleId, y: &Ty, frame: &Vector<OwnSubst>, depth: i32) bool {
        if y.kind == TypeKind::TYPE_ARRAY {
            let e = y.as_data.arr.elem;
            return self.owns_f(mid, e, frame, depth + 1);
        }
        if y.kind == TypeKind::TYPE_DYN {
            return y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let mut cap_tys = Vector::<TypeId>::new();
            {
                let fa = self.ast_of(y.module);
                let fnn = *fa.at_const(y.as_data.decl);
                if fnn.kind != NodeKind::NODE_CLOSURE {
                    cap_tys.free();
                    return false;
                }
                let caps = fnn.as_data.closure.captures;
                let mut_caps = fnn.as_data.closure.mut_caps as u64;
                for i in 0..caps.len {
                    if (mut_caps >> i as u64 & 1u64) == 0 {
                        let cid = unsafe fa.list(caps)[i as usize];
                        cap_tys.push(fa.type_of(cid));
                    }
                }
            }
            let mut r = false;
            for i in 0..cap_tys.len() {
                let ct = cap_tys[i];
                let empty = Vector::<OwnSubst>::new();
                if self.owns_f(y.module, ct, &empty, depth + 1) {
                    r = true;
                    break;
                }
            }
            cap_tys.free();
            return r;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            if self.free_extend_of(y.module, y.as_data.decl).node != NODE_NONE {
                return true;
            }
            return self.derives(mid, y, frame, depth);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        if y.as_data.inst as usize >= self.ast_of(mid).instances.len() {
            return false;
        }
        let it = *self.ast_of(mid).instance(y.as_data.inst);
        let ext = self.free_extend_of(it.module, it.decl);
        if ext.node == NODE_NONE {
            return self.derives(mid, y, frame, depth);
        }
        let mut gid_list = Vector::<NodeId>::new();
        {
            let ia = self.ast_of(ext.module);
            let gens = ia.at_const(ext.node).as_data.extend_def.generics;
            for i in 0..gens.len {
                gid_list.push(unsafe ia.list(gens)[i as usize]);
            }
        }
        let mut i: u32 = 0;
        let mut r = true;
        while i < gid_list.len() as u32 && i as u8 < it.n {
            let gid = gid_list[i as usize];
            let arg = unsafe it.args[i as usize];
            if self.param_has_free_bound(ext.module, gid) && !self.owns_f(mid, arg, frame, depth + 1) {
                r = false;
                break;
            }
            i = i + 1;
        }
        gid_list.free();
        return r;
    }

    // Member-derived ownership: a non-union aggregate with no explicit conformance owns memory when
    // any member does. Instances judge members under their argument substitution.
    fn derives(self: &mut Self, mid: ModuleId, y: &Ty, frame: &Vector<OwnSubst>, depth: i32) bool {
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut sub = Vector::<OwnSubst>::new();
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
            let mut gid_list = Vector::<NodeId>::new();
            {
                let oa = self.ast_of(om);
                let ag = oa.at_const(od).as_data.aggregate;
                let gids = oa.list(ag.generics);
                for g in 0..ag.generics.len {
                    let gid = unsafe gids[g as usize];
                    if !oa.at_const(gid).as_data.generic_param.is_lifetime {
                        gid_list.push(gid);
                    }
                }
            }
            for g in 0..gid_list.len() {
                if g < it.n as usize {
                    sub.push(OwnSubst { pmod: om, pdecl: gid_list[g], amod: mid, aty: unsafe it.args[g] });
                }
            }
            gid_list.free();
        } else {
            om = y.module;
            od = y.as_data.decl;
            for i in 0..frame.len() {
                sub.push(*frame.at(i));
            }
        }
        let dn = *self.ast_of(om).at_const(od);
        let is_enum = dn.kind == NodeKind::NODE_ENUM;
        if dn.kind != NodeKind::NODE_STRUCT && !is_enum {
            sub.free();
            return false;
        }
        if !is_enum && dn.as_data.aggregate.is_union {
            sub.free();
            return false;
        }
        let key = om as u64 << 32 | od as u64;
        for b in 0..self.busy.len() {
            if self.busy[b] == key {
                sub.free();
                return false;
            }
        }
        self.busy.push(key);
        // Member types first (no ast borrow may live across the recursive walk).
        let mut mtys = Vector::<TypeId>::new();
        {
            let oa = self.ast_of(om);
            let ms = dn.as_data.aggregate.members;
            for i in 0..ms.len {
                let mid2 = unsafe oa.list(ms)[i as usize];
                let mn = *oa.at_const(mid2);
                if !is_enum && mn.kind == NodeKind::NODE_FIELD {
                    mtys.push(oa.type_of(mn.as_data.field.ty));
                } else if is_enum && mn.kind == NodeKind::NODE_VARIANT {
                    let pids = oa.list(mn.as_data.variant.payload);
                    for k in 0..mn.as_data.variant.payload.len {
                        let pid = unsafe pids[k as usize];
                        let pe = *oa.at_const(pid);
                        let mut tn = pid;
                        if pe.kind == NodeKind::NODE_FIELD {
                            tn = pe.as_data.field.ty;
                        }
                        mtys.push(oa.type_of(tn));
                    }
                }
            }
        }
        let mut r = false;
        for i in 0..mtys.len() {
            let mt = mtys[i];
            if self.owns_f(om, mt, &sub, depth + 1) {
                r = true;
            }
        }
        mtys.free();
        sub.free();
        let _ = self.busy.pop();
        return r;
    }

    /// The field declarations and member types of a struct (or struct instance) value; false for
    /// every other shape. Types are the OWNER module's recorded member types (`om`).
    pub fn agg_fields(
        self: &mut Self,
        mid: ModuleId,
        ty: TypeId,
        decls: &mut Vector<NodeId>,
        tys: &mut Vector<TypeId>,
        om_out: &mut ModuleId,
    ) bool {
        decls.clear();
        tys.clear();
        let y = *self.ast_of(mid).type_at(ty);
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT {
            om = y.module;
            od = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
        } else {
            return false;
        }
        let dn = *self.ast_of(om).at_const(od);
        if dn.kind != NodeKind::NODE_STRUCT || dn.as_data.aggregate.is_union {
            return false;
        }
        {
            let oa = self.ast_of(om);
            let ms = dn.as_data.aggregate.members;
            for i in 0..ms.len {
                let mid2 = unsafe oa.list(ms)[i as usize];
                let mn = *oa.at_const(mid2);
                if mn.kind == NodeKind::NODE_FIELD {
                    decls.push(mid2);
                    tys.push(oa.type_of(mn.as_data.field.ty));
                }
            }
        }
        *om_out = om;
        return true;
    }

    /// Can a value of `(mid, ty)` hold a tracked borrow? References and borrowed dyn values do;
    /// aggregates and closures do when a member/capture does. Raw pointers, `str`, and slice views
    /// (pointer-field structs) do not: their fields are handles, not tracked borrows.
    pub fn carries(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        return self.carries_f(mid, ty, 0);
    }

    fn carries_f(self: &mut Self, mid: ModuleId, ty: TypeId, depth: i32) bool {
        if ty == TYPE_NONE || depth > 8 {
            return false;
        }
        let y = *self.ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_REFERENCE {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let e = y.as_data.arr.elem;
            return self.carries_f(mid, e, depth + 1);
        }
        if y.kind == TypeKind::TYPE_DYN {
            return true; // an erased value can hold captured borrows whatever its ownership
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let mut cap_tys = Vector::<TypeId>::new();
            {
                let fa = self.ast_of(y.module);
                let fnn = *fa.at_const(y.as_data.decl);
                if fnn.kind != NodeKind::NODE_CLOSURE {
                    cap_tys.free();
                    return false;
                }
                if fnn.as_data.closure.mut_caps != 0 {
                    cap_tys.free();
                    return true;
                }
                let caps = fnn.as_data.closure.captures;
                for i in 0..caps.len {
                    let cid = unsafe fa.list(caps)[i as usize];
                    cap_tys.push(fa.type_of(cid));
                }
            }
            let mut r = false;
            for i in 0..cap_tys.len() {
                let ct = cap_tys[i];
                if self.carries_f(y.module, ct, depth + 1) {
                    r = true;
                    break;
                }
            }
            cap_tys.free();
            return r;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            om = y.module;
            od = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            if y.as_data.inst as usize >= self.ast_of(mid).instances.len() {
                return false;
            }
            let it = *self.ast_of(mid).instance(y.as_data.inst);
            om = it.module;
            od = it.decl;
            for k in 0..it.n {
                let arg = unsafe it.args[k as usize];
                if self.carries_f(mid, arg, depth + 1) {
                    return true;
                }
            }
        } else {
            return false;
        }
        // A view type (a `str`, a slice, any aggregate declaring lifetime params) is a borrow by
        // declaration even when its fields are raw: values of it pin what they were made from.
        if od != NODE_NONE && self.ast_of(om).lifetimes_of(od).len != 0 {
            return true;
        }
        let key = mid as u64 << 32 | ty as u64;
        let cacheable = self.ast_of(mid).type_concrete(ty);
        if cacheable {
            let mut have = false;
            let mut hit = false;
            switch self.carry_memo.get(&key) {
                Some(v) => {
                    have = true;
                    hit = *v == 2u64;
                },
                None => {},
            };
            if have {
                return hit;
            }
        }
        let dn = *self.ast_of(om).at_const(od);
        let mut r = false;
        if dn.kind == NodeKind::NODE_STRUCT || dn.kind == NodeKind::NODE_ENUM {
            let is_enum = dn.kind == NodeKind::NODE_ENUM;
            let mut mtys = Vector::<TypeId>::new();
            {
                let oa = self.ast_of(om);
                let ms = dn.as_data.aggregate.members;
                for i in 0..ms.len {
                    let mid2 = unsafe oa.list(ms)[i as usize];
                    let mn = *oa.at_const(mid2);
                    if !is_enum && mn.kind == NodeKind::NODE_FIELD {
                        mtys.push(oa.type_of(mn.as_data.field.ty));
                    } else if is_enum && mn.kind == NodeKind::NODE_VARIANT {
                        let pids = oa.list(mn.as_data.variant.payload);
                        for k in 0..mn.as_data.variant.payload.len {
                            let pid = unsafe pids[k as usize];
                            let pe = *oa.at_const(pid);
                            let mut tn = pid;
                            if pe.kind == NodeKind::NODE_FIELD {
                                tn = pe.as_data.field.ty;
                            }
                            mtys.push(oa.type_of(tn));
                        }
                    }
                }
            }
            for i in 0..mtys.len() {
                let mt = mtys[i];
                if self.carries_f(om, mt, depth + 1) {
                    r = true;
                    break;
                }
            }
            mtys.free();
        }
        if cacheable {
            let mut enc: u64 = 1;
            if r {
                enc = 2;
            }
            self.carry_memo.insert(key, enc);
        }
        return r;
    }
}

// ---- fact generation ------------------------------------------------------------------------------

/// One statement-order walk of a verified body. Reads happen at a statement's entry point, writes,
/// loan issues, and kills at its exit point, so an assignment's own read never conflicts with the
/// loan or kill it produces.
pub struct Gen {
    pub ow: *mut Owner,
    pub b: *const ir::CoreBody,
    pub mf: *const mp::MoveForest,
    pub f: BodyFacts,
    pub assign_sites: Vector<KillSite>, // every overwrite, paired against loans for kills afterwards
    pub cur_block: u32,
    pub in_caps: bool, // reading closure-capture operands: owned moves record ACC_CAP
    pub calling: bool, // reading a callee-position operand: calling borrows the env, never moves it
    pub plain_copy: bool, // reading an RV_USE operand: a `&mut` place copy consumes the binding
    pub seen: Vector<u64>, // per-block first-touch words for luse/ldef construction
}

/// One overwrite site for kill pairing: a place, or a whole local from a storage marker.
pub struct KillSite {
    pub place: ir::PlaceId, // BF_NONE for a whole-local site
    pub local: u32, // BF_NONE for a place site
    pub point: u32,
}

const fn no_span() tok::Span {
    return tok::Span { start: 0, end: 0 };
}

pub fn generate(ow: &mut Owner, b: &ir::CoreBody, mf: &mp::MoveForest) BodyFacts {
    let mut g = Gen {
        ow: ow,
        b: b,
        mf: mf,
        f: BodyFacts {
            npoints: 0,
            block_base: Vector::<u32>::new(),
            norigins: 0,
            nuniversal: 0,
            local_origin: Vector::<u32>::new(),
            origin_local: Vector::<u32>::new(),
            uni_name: Vector::<tok::Span>::new(),
            arg_universal: Vector::<u32>::new(),
            ret_origin: Vector::<u32>::new(),
            ret_elided: Vector::<bool>::new(),
            known_subsets: Vector::<u64>::new(),
            uni_flows: Vector::<u64>::new(),
            loans: Vector::<Loan>::new(),
            subsets: Vector::<SubsetAt>::new(),
            accesses: Vector::<Access>::new(),
            kills: Vector::<KillAt>::new(),
            events: Vector::<Event>::new(),
            ev_start: Vector::<u32>::new(),
            freed: Vector::<u32>::new(),
            observed: Vector::<bool>::new(),
            moved_whole: Vector::<bool>::new(),
            cuts: Vector::<u64>::new(),
            lwords: 0,
            luse: Vector::<u64>::new(),
            ldef: Vector::<u64>::new(),
        },
        assign_sites: Vector::<KillSite>::new(),
        cur_block: 0,
        in_caps: false,
        plain_copy: false,
        calling: false,
        seen: Vector::<u64>::new(),
    };
    g.number_points();
    g.build_origins();
    g.walk();
    g.finish();
    // Swap the result out whole: a partial move would leave the generator's scratch fields
    // (assign_sites, seen) unfreed.
    let out = replace(
        &mut g.f,
        BodyFacts {
            npoints: 0,
            block_base: Vector::<u32>::new(),
            norigins: 0,
            nuniversal: 0,
            local_origin: Vector::<u32>::new(),
            origin_local: Vector::<u32>::new(),
            uni_name: Vector::<tok::Span>::new(),
            arg_universal: Vector::<u32>::new(),
            ret_origin: Vector::<u32>::new(),
            ret_elided: Vector::<bool>::new(),
            known_subsets: Vector::<u64>::new(),
            uni_flows: Vector::<u64>::new(),
            loans: Vector::<Loan>::new(),
            subsets: Vector::<SubsetAt>::new(),
            accesses: Vector::<Access>::new(),
            kills: Vector::<KillAt>::new(),
            events: Vector::<Event>::new(),
            ev_start: Vector::<u32>::new(),
            freed: Vector::<u32>::new(),
            observed: Vector::<bool>::new(),
            moved_whole: Vector::<bool>::new(),
            cuts: Vector::<u64>::new(),
            lwords: 0,
            luse: Vector::<u64>::new(),
            ldef: Vector::<u64>::new(),
        },
    );
    return out;
}

extend Gen {
    const fn body(self: &Self) &ir::CoreBody {
        return unsafe &*self.b;
    }

    const fn forest(self: &Self) &mp::MoveForest {
        return unsafe &*self.mf;
    }

    fn owner(self: &Self) &mut Owner {
        return unsafe &mut *self.ow;
    }

    // ---- points -----------------------------------------------------------------------------------

    fn number_points(self: &mut Self) {
        let mut acc: u32 = 0;
        let nb = self.body().blocks.len();
        for bi in 0..nb {
            self.f.block_base.push(acc);
            acc += self.body().blocks.at(bi).stmt_len * 2 + 2;
        }
        self.f.npoints = acc;
    }

    const fn stmt_entry(self: &Self, blk: u32, i: u32) u32 {
        return self.f.block_base[blk as usize] + i * 2;
    }

    const fn term_entry(self: &Self, blk: u32) u32 {
        return self.f.block_base[blk as usize] + self.body().blocks.at(blk as usize).stmt_len * 2;
    }

    // ---- origins ----------------------------------------------------------------------------------

    fn lt_name(self: &Self, a: &Ast, lt: NodeId) tok::Span {
        if lt == NODE_NONE {
            return no_span();
        }
        let n = a.at_const(lt);
        if n.kind == NodeKind::NODE_GENERIC_PARAM {
            return self.lt_name(a, n.as_data.generic_param.name);
        }
        return n.as_data.name.text;
    }

    // The declared lifetime on a parameter/return slot's outermost reference type, or empty.
    fn slot_lifetime(self: &Self, a: &Ast, slot: NodeId) tok::Span {
        if slot == NODE_NONE {
            return no_span();
        }
        let mut tyn = slot;
        if a.at_const(slot).kind == NodeKind::NODE_PARAMETER {
            tyn = a.at_const(slot).as_data.parameter.ty;
        }
        if tyn == NODE_NONE || a.at_const(tyn).kind != NodeKind::NODE_REFERENCE_TYPE {
            return no_span();
        }
        return self.lt_name(a, a.at_const(tyn).as_data.indirect_type.lifetime);
    }

    fn name_eq(self: &Self, a: tok::Span, bsp: tok::Span) bool {
        if a.end <= a.start || bsp.end <= bsp.start || a.end - a.start != bsp.end - bsp.start {
            return false;
        }
        let s = self.owner().src_of(self.body().module);
        return s.slice(a.start as usize, a.end as usize) == s.slice(bsp.start as usize, bsp.end as usize);
    }

    // The universal origin for declared name `nm` (empty = always fresh), created on first use.
    fn universal_for(self: &mut Self, nm: tok::Span) u32 {
        if nm.end > nm.start {
            for i in 1..self.f.nuniversal {
                if self.name_eq(self.f.uni_name[i as usize], nm) {
                    return i;
                }
            }
        }
        let id = self.f.norigins;
        self.f.norigins += 1;
        self.f.nuniversal += 1;
        self.f.origin_local.push(BF_NONE);
        self.f.uni_name.push(nm);
        return id;
    }

    fn build_origins(self: &mut Self) {
        // origin 0 = 'static.
        self.f.norigins = 1;
        self.f.nuniversal = 1;
        self.f.origin_local.push(BF_NONE);
        self.f.uni_name.push(no_span());
        let bmod = self.body().module;
        let fnode = self.body().owner.node;
        let nlocals = self.body().locals.len();
        let nrets = self.body().returns;
        let nargs = self.body().args;
        let mut params = NodeList { start: 0, len: 0 };
        let mut rets = NodeList { start: 0, len: 0 };
        if fnode != NODE_NONE {
            let a = self.owner().ast_of(bmod);
            let n = a.at_const(fnode);
            if n.kind == NodeKind::NODE_FUNCTION {
                params = n.as_data.function.params;
                rets = n.as_data.function.returns;
            } else if n.kind == NodeKind::NODE_CLOSURE {
                params = n.as_data.closure.params;
                rets = n.as_data.closure.returns;
            }
        }
        for _l in 0..nlocals {
            self.f.arg_universal.push(BF_NONE);
        }
        // Universal placeholders for borrow-carrying arguments, keyed by declared name.
        for i in 0..nargs {
            let l = (nrets + i) as usize;
            if l >= nlocals {
                break;
            }
            let lty = self.body().locals.at(l).ty;
            if !self.owner().carries(bmod, lty) {
                continue;
            }
            let mut nm = no_span();
            if i < params.len {
                let slot = unsafe self.owner().ast_of(bmod).list(params)[i as usize];
                nm = self.slot_lifetime(self.owner().ast_of(bmod), slot);
            }
            let u = self.universal_for(nm);
            self.f.arg_universal.set(l, u);
        }
        // Return-slot placeholders.
        for r in 0..nrets {
            let lty = self.body().locals.at(r as usize).ty;
            if !self.owner().carries(bmod, lty) {
                self.f.ret_origin.push(BF_NONE);
                self.f.ret_elided.push(false);
                continue;
            }
            let mut nm = no_span();
            if r < rets.len {
                let slot = unsafe self.owner().ast_of(bmod).list(rets)[r as usize];
                nm = self.slot_lifetime(self.owner().ast_of(bmod), slot);
            }
            if nm.end > nm.start {
                let u = self.universal_for(nm);
                self.f.ret_origin.push(u);
                self.f.ret_elided.push(false);
            } else {
                let u = self.universal_for(no_span());
                self.f.ret_origin.push(u);
                self.f.ret_elided.push(true);
            }
        }
        // Declared outlives bounds (`'a: 'b`) become known placeholder relations.
        if fnode != NODE_NONE {
            let mut names = Vector::<tok::Span>::new();
            let mut bounds = Vector::<tok::Span>::new();
            {
                let a = self.owner().ast_of(bmod);
                let n = a.at_const(fnode);
                if n.kind == NodeKind::NODE_FUNCTION {
                    let gens = n.as_data.function.generics;
                    for i in 0..gens.len {
                        let gid = unsafe a.list(gens)[i as usize];
                        let gp = a.at_const(gid);
                        if !gp.as_data.generic_param.is_lifetime {
                            continue;
                        }
                        let un = self.lt_name(a, gp.as_data.generic_param.name);
                        let bs = gp.as_data.generic_param.bounds;
                        for k in 0..bs.len {
                            names.push(un);
                            bounds.push(self.lt_name(a, unsafe a.list(bs)[k as usize]));
                        }
                    }
                }
                // Lifetime parameters live in the side table, not the generics list.
                let lts = a.lifetimes_of(fnode);
                for i in 0..lts.len {
                    let gid = unsafe a.list(lts)[i as usize];
                    let gp = a.at_const(gid);
                    if gp.kind != NodeKind::NODE_GENERIC_PARAM || !gp.as_data.generic_param.is_lifetime {
                        continue;
                    }
                    let un = self.lt_name(a, gp.as_data.generic_param.name);
                    let bs = gp.as_data.generic_param.bounds;
                    for k in 0..bs.len {
                        names.push(un);
                        bounds.push(self.lt_name(a, unsafe a.list(bs)[k as usize]));
                    }
                }
            }
            for i in 0..names.len() {
                let u = self.universal_for(names[i]);
                let v = self.universal_for(bounds[i]);
                self.f.known_subsets.push(u as u64 << 32 | v as u64);
            }
            names.free();
            bounds.free();
        }
        // Inference origins: one per borrow-carrying local.
        for l in 0..nlocals {
            let ld = *self.body().locals.at(l);
            if ld.storage == ir::LS_STATIC_REF {
                self.f.local_origin.push(BF_NONE);
                self.f.observed.push(false);
                continue;
            }
            let mut o = BF_NONE;
            // Untyped temps are multi-return call destinations; assume they carry so argument
            // borrows flow through the destructure into the bindings.
            let lcar = self.owner().carries(bmod, ld.ty);
            if lcar || ld.ty == TYPE_NONE && ld.storage == ir::LS_TEMP {
                o = self.f.norigins;
                self.f.norigins += 1;
                self.f.origin_local.push(l as u32);
            }
            self.f.observed.push(lcar && self.owner().owns(bmod, ld.ty));
            self.f.local_origin.push(o);
        }
        // Loans arriving through arguments: placeholder flows into the argument's own origin. A
        // mutable-reference argument also flows back out (stores through it reach the caller).
        for l in 0..nlocals {
            if self.f.arg_universal[l] == BF_NONE || self.f.local_origin[l] == BF_NONE {
                continue;
            }
            self.f.subsets.push(SubsetAt { from: self.f.arg_universal[l], to: self.f.local_origin[l], point: 0 });
            // Store-through-out-param escapes are the walk's declared-lifetime checks; no
            // omnipresent backflow edge in this direction.
        }
    }

    // ---- walk -------------------------------------------------------------------------------------

    const fn place_of(self: &Self, p: ir::PlaceId) ir::Place {
        return *self.body().places.at(p as usize);
    }

    const fn origin_of_place(self: &Self, p: ir::PlaceId) u32 {
        return self.f.local_origin[self.place_of(p).base as usize];
    }

    // A place rooted in a raw pointer belongs to the unsafe world: accesses are recorded, but no
    // tracked loan ever forms on it.
    fn base_is_raw(self: &Self, pid: ir::PlaceId) bool {
        let base = self.place_of(pid).base;
        let ty = self.body().locals.at(base as usize).ty;
        if ty == TYPE_NONE {
            return false;
        }
        return self.owner().ast_of(self.body().module).type_at(ty).kind == TypeKind::TYPE_POINTER;
    }

    // True when the place derefs a SHARED reference on the way: a `&mut` of such a place is the
    // language's unsafe interior-mutability escape (type checking already demanded the `unsafe`),
    // so no loan tracks it -- exactly like a raw-pointer base.
    fn shared_deref(self: &Self, p: ir::PlaceId) bool {
        let pl = self.place_of(p);
        let mut prev = self.body().locals.at(pl.base as usize).ty;
        for i in 0..pl.proj_len {
            let pj = *self.body().projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF && prev != TYPE_NONE {
                let y = *self.owner().ast_of(self.body().module).type_at(prev);
                if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    return true;
                }
            }
            prev = pj.ty;
        }
        return false;
    }

    // True when the place routes through a dereference (its storage is borrowed, not owned here).
    const fn through_deref(self: &Self, p: ir::PlaceId) bool {
        let pl = self.place_of(p);
        for i in 0..pl.proj_len {
            if self.body().projections.at((pl.proj_start + i) as usize).kind == ir::PJ_DEREF {
                return true;
            }
        }
        return false;
    }

    fn live_use(self: &mut Self, l: ir::LocalId) {
        let w = (l / 64) as usize;
        let bit = 1u64 << (l & 63);
        let base = self.cur_block as usize * self.f.lwords as usize;
        if (self.seen[w] & bit) == 0 {
            self.f.luse.set(base + w, self.f.luse[base + w] | bit);
        }
    }

    fn live_def(self: &mut Self, l: ir::LocalId) {
        let w = (l / 64) as usize;
        let bit = 1u64 << (l & 63);
        let base = self.cur_block as usize * self.f.lwords as usize;
        self.f.ldef.set(base + w, self.f.ldef[base + w] | bit);
        self.seen.set(w, self.seen[w] | bit);
    }

    fn subset(self: &mut Self, from: u32, to: u32, point: u32) {
        if from == BF_NONE || to == BF_NONE || from == to {
            return;
        }
        self.f.subsets.push(SubsetAt { from: from, to: to, point: point });
    }

    // A value read of a place: liveness, init/move event, and the matching access.
    fn op_read(self: &mut Self, opid: ir::OperandId, point: u32, sp: tok::Span) {
        let op = *self.body().operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return;
        }
        let pl = self.place_of(op.data);
        self.live_use(pl.base);
        let path = self.forest().place_path[op.data as usize];
        let base_st = self.body().locals.at(pl.base as usize).storage;
        if base_st == ir::LS_STATIC_REF {
            return;
        }
        let owned = self.owner().owns(self.body().module, pl.ty) && !self.calling;
        if owned && path != mp::MP_NONE {
            let mut ak = ACC_MOVE;
            if self.in_caps {
                ak = ACC_CAP;
            }
            self.f.events.push(Event { kind: EV_MOVE, path: path, point: point, span: sp });
            self.f.accesses.push(Access { place: op.data, local: BF_NONE, kind: ak, point: point, span: sp });
            return;
        }
        // A plain copy of a `&mut` place consumes the binding (exclusivity); passing one to a call
        // reborrows instead, so only RV_USE operands take this branch.
        if self.plain_copy && path != mp::MP_NONE && pl.ty != TYPE_NONE {
            let y = *self.owner().ast_of(self.body().module).type_at(pl.ty);
            if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                self.f.events.push(Event { kind: EV_MOVE, path: path, point: point, span: sp });
                self.f.accesses.push(Access { place: op.data, local: BF_NONE, kind: ACC_MOVE, point: point, span: sp });
                return;
            }
        }
        let mut upath = path;
        if upath == mp::MP_NONE {
            upath = self.forest().place_cut[op.data as usize];
        }
        if upath != mp::MP_NONE {
            self.f.events.push(Event { kind: EV_USE, path: upath, point: point, span: sp });
        }
        self.f.accesses.push(Access { place: op.data, local: BF_NONE, kind: ACC_READ, point: point, span: sp });
    }

    fn op_range_read(self: &mut Self, start: u32, len: u32, point: u32, sp: tok::Span) {
        for i in 0..len {
            let opid = self.body().oper_pool[(start + i) as usize];
            self.op_read(opid, point, sp);
        }
    }

    // A write of a place: liveness def, init event, write access, and a kill site. A whole-local
    // write of an origin-carrying value is a REBIND: earlier flows through that origin end here
    // (the solver's cut), which is what lets `r = p; return r` stop implicating the old borrow.
    fn write_place(self: &mut Self, pid: ir::PlaceId, point: u32, sp: tok::Span) {
        let pl = self.place_of(pid);
        if pl.proj_len == 0 {
            self.live_def(pl.base);
            let org = self.f.local_origin[pl.base as usize];
            if org != BF_NONE && point > 0 {
                self.f.cuts.push(org as u64 << 32 | (point - 1) as u64);
            }
        } else {
            self.live_use(pl.base);
        }
        let path = self.forest().place_path[pid as usize];
        if path != mp::MP_NONE {
            self.f.events.push(Event { kind: EV_ASSIGN, path: path, point: point, span: sp });
        } else {
            // Writing through a dereference READS the pointer: a moved `&mut` used as a store
            // target must still be a use-after-move.
            let upath = self.forest().place_cut[pid as usize];
            if upath != mp::MP_NONE && pl.proj_len != 0 {
                self.f.events.push(Event { kind: EV_USE, path: upath, point: point - 1, span: sp });
            }
        }
        self.f.accesses.push(Access { place: pid, local: BF_NONE, kind: ACC_WRITE, point: point, span: sp });
        self.assign_sites.push(KillSite { place: pid, local: BF_NONE, point: point });
    }

    // Parameter passing modes for a direct call: 0 = by value, 1 = &, 2 = &mut, 3 = raw pointer.
    // Super-C methods declare `self` explicitly, so terminator arguments align with the callee's
    // parameter list.
    fn arg_kinds(self: &mut Self, callee: DefId, n: u32, out: &mut Vector<u8>) {
        out.clear();
        for _i in 0..n {
            out.push(0);
        }
        if callee.node == NODE_NONE {
            return;
        }
        let kkey = callee.module as u64 << 32 | callee.node as u64;
        let mut hit = false;
        let mut range: u64 = 0;
        switch self.owner().kinds_memo.get(&kkey) {
            Some(v) => {
                hit = true;
                range = *v;
            },
            _ => {},
        };
        if hit {
            let kst = (range >> 16) as usize;
            let kl = (range & 0xFFFF) as u32;
            let mut lim2 = n;
            if kl < lim2 {
                lim2 = kl;
            }
            for i in 0..lim2 {
                out.set(i as usize, self.owner().kinds_pool[kst + i as usize]);
            }
            return;
        }
        let mut tys = Vector::<TypeId>::new();
        {
            let a = self.owner().ast_of(callee.module);
            let nd = a.at_const(callee.node);
            if nd.kind != NodeKind::NODE_FUNCTION {
                tys.free();
                return;
            }
            let ps = nd.as_data.function.params;
            for i in 0..ps.len {
                let pid = unsafe a.list(ps)[i as usize];
                tys.push(a.type_of(pid));
            }
        }
        let cm = callee.module;
        let kst2 = self.owner().kinds_pool.len();
        for i in 0..tys.len() {
            let t = tys[i];
            let mut k: u8 = 0;
            if t != TYPE_NONE {
                let y = *self.owner().ast_of(cm).type_at(t);
                if y.kind == TypeKind::TYPE_REFERENCE {
                    k = 1;
                    if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                        k = 2;
                    }
                } else if y.kind == TypeKind::TYPE_POINTER {
                    k = 3;
                }
            }
            self.owner().kinds_pool.push(k);
            if i as u32 < n {
                out.set(i, k);
            }
        }
        self.owner().kinds_memo.insert(kkey, kst2 as u64 << 16 | tys.len() as u64);
        tys.free();
    }

    // Can values of `ty` STORE borrows by type -- declared lifetime params, or borrow-carrying
    // instance arguments (`Vector<&T>`)? A struct merely embedding a view field has no slot a
    // caller-side store could legally fill, so it is not a store target.
    fn stores_borrows(self: &mut Self, mid: ModuleId, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let y = *self.owner().ast_of(mid).type_at(ty);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.owner().ast_of(y.module).lifetimes_of(y.as_data.decl).len != 0;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.owner().ast_of(mid).instance(y.as_data.inst);
            if self.owner().ast_of(it.module).lifetimes_of(it.decl).len != 0 {
                return true;
            }
            for k in 0..it.n {
                let arg = unsafe it.args[k as usize];
                if self.owner().carries(mid, arg) {
                    return true;
                }
            }
        }
        return false;
    }

    // Collect the lifetime-carrying TOKENS of a type node: FNV hashes of named-lifetime texts and
    // resolved generic-parameter decls. Two parameter positions sharing a token are tied by the
    // callee's signature. Memoized per (module, node): signatures are re-read at every call site.
    fn lt_tokens(self: &mut Self, m: ModuleId, tyn: NodeId, out: &mut Vector<u64>, depth: i32) {
        if tyn == NODE_NONE || depth > 6 {
            return;
        }
        let key = m as u64 << 32 | tyn as u64;
        let mut hit = false;
        let mut range: u64 = 0;
        switch self.owner().tok_memo.get(&key) {
            Some(v) => {
                hit = true;
                range = *v;
            },
            _ => {},
        };
        if hit {
            let tst = (range >> 16) as usize;
            for i in 0..range & 0xFFFF {
                let tv = self.owner().tok_pool[tst + i as usize];
                out.push(tv);
            }
            return;
        }
        let mark = out.len();
        self.lt_tokens_walk(m, tyn, out, depth);
        let start = self.owner().tok_pool.len();
        for i in mark..out.len() {
            let tv = out[i];
            self.owner().tok_pool.push(tv);
        }
        self.owner().tok_memo.insert(key, start as u64 << 16 | (out.len() - mark) as u64);
    }

    fn lt_tokens_walk(self: &mut Self, m: ModuleId, tyn: NodeId, out: &mut Vector<u64>, depth: i32) {
        let mut k = NodeKind::NODE_NONE_KIND;
        let mut lt = NODE_NONE;
        let mut inner = NODE_NONE;
        let mut args = NodeList { start: 0, len: 0 };
        {
            let a = self.owner().ast_of(m);
            let node = a.at_const(tyn);
            k = node.kind;
            if k == NodeKind::NODE_REFERENCE_TYPE {
                lt = node.as_data.indirect_type.lifetime;
                inner = node.as_data.indirect_type.ty;
            } else if k == NodeKind::NODE_ARRAY_TYPE {
                inner = node.as_data.array_type.element;
            } else if k == NodeKind::NODE_TYPE_PATH {
                args = node.as_data.type_path.args;
            }
        }
        if k == NodeKind::NODE_LIFETIME || k == NodeKind::NODE_GENERIC_PARAM {
            self.lt_name_token(m, tyn, out);
            return;
        }
        if k == NodeKind::NODE_REFERENCE_TYPE {
            self.lt_name_token(m, lt, out);
            self.lt_tokens(m, inner, out, depth + 1);
            return;
        }
        if k == NodeKind::NODE_ARRAY_TYPE {
            self.lt_tokens(m, inner, out, depth + 1);
            return;
        }
        if k == NodeKind::NODE_TYPE_PATH {
            // A path naming a generic parameter is a token itself (`x: T` ties into `Vector<T>`).
            let mut d = self.owner().ast_of(m).resolution_def(tyn);
            if d.node == NODE_NONE {
                let parts = self.owner().ast_of(m).at_const(tyn).as_data.type_path.parts;
                if parts.len != 0 {
                    let last = unsafe self.owner().ast_of(m).list(parts)[(parts.len - 1) as usize];
                    d = self.owner().ast_of(m).resolution_def(last);
                }
            }
            if d.node != NODE_NONE && self.owner().ast_of(d.module).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM {
                out.push(d.module as u64 << 32 | d.node as u64);
            }
            for i in 0..args.len {
                let aid = unsafe self.owner().ast_of(m).list(args)[i as usize];
                if self.owner().ast_of(m).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    self.lt_name_token(m, aid, out);
                } else {
                    self.lt_tokens(m, aid, out, depth + 1);
                }
            }
        }
    }

    fn lt_name_token(self: &mut Self, m: ModuleId, lt: NodeId, out: &mut Vector<u64>) {
        if lt == NODE_NONE {
            return;
        }
        let mut sp = tok::Span { start: 0, end: 0 };
        {
            let a = self.owner().ast_of(m);
            let mut n = a.at_const(lt);
            if n.kind == NodeKind::NODE_GENERIC_PARAM {
                n = a.at_const(n.as_data.generic_param.name);
            }
            sp = n.as_data.name.text;
        }
        if sp.end <= sp.start {
            return;
        }
        let src = self.owner().src_of(m);
        let mut h: u64 = 0xcbf29ce484222325;
        for i in sp.start..sp.end {
            h = (h ^ src[i as usize] as u64) * 0x100000001b3;
        }
        out.push(1u64 << 63 | h & 0x7FFFFFFFFFFFFFFF);
    }

    // Cached per-callee flags: bit0 = explicit `self` first parameter, bit1 = named `free`.
    fn callee_flag(self: &mut Self, callee: DefId) u64 {
        if callee.node == NODE_NONE {
            return 0;
        }
        let key = callee.module as u64 << 32 | callee.node as u64;
        switch self.owner().callee_flags.get(&key) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        let mut fl: u64 = 4;
        let mut pn = tok::Span { start: 0, end: 0 };
        let mut fn0 = tok::Span { start: 0, end: 0 };
        {
            let a = self.owner().ast_of(callee.module);
            let nd = a.at_const(callee.node);
            if nd.kind == NodeKind::NODE_FUNCTION {
                fn0 = a.at_const(nd.as_data.function.name).as_data.name.text;
                if nd.as_data.function.params.len != 0 {
                    let p0 = unsafe a.list(nd.as_data.function.params)[0];
                    pn = a.at_const(a.at_const(p0).as_data.parameter.name).as_data.name.text;
                }
            }
        }
        if pn.end > pn.start && self.owner().span_text_is(callee.module, pn, "self") {
            fl = fl | 1;
        }
        if fn0.end > fn0.start && self.owner().span_text_is(callee.module, fn0, "free") {
            fl = fl | 2;
        }
        self.owner().callee_flags.insert(key, fl);
        return fl;
    }

    fn is_self_callee(self: &mut Self, callee: DefId) bool {
        return (self.callee_flag(callee) & 1) != 0;
    }

    fn is_free_callee(self: &mut Self, callee: DefId) bool {
        return (self.callee_flag(callee) & 2) != 0;
    }

    // An argument the callee receives by reference while the operand names a non-reference place:
    // the checker's autoref, implicit in Core IR. It reads or claims the place for the call and,
    // when the call produces a borrow-carrying result, opens a loan owned by that result's origin.
    fn implicit_borrow(self: &mut Self, pid: ir::PlaceId, k: u8, entry: u32, dorigin: u32, sp: tok::Span) {
        let pl = self.place_of(pid);
        self.live_use(pl.base);
        let mut upath = self.forest().place_path[pid as usize];
        if upath == mp::MP_NONE {
            upath = self.forest().place_cut[pid as usize];
        }
        if upath != mp::MP_NONE {
            self.f.events.push(Event { kind: EV_USE, path: upath, point: entry, span: sp });
        }
        let mut ak = ACC_READ;
        if k == 2 {
            ak = ACC_WRITE;
        }
        self.f.accesses.push(Access { place: pid, local: BF_NONE, kind: ak, point: entry, span: sp });
        if dorigin != BF_NONE && !self.base_is_raw(pid) {
            // The pin a carrying RESULT holds is SHARED whatever the parameter's mutability -- the
            // exclusive claim lives in the access above and ends with the call. A receiver that
            // itself CARRIES borrows contributes what it holds instead of a fresh pin (the walk's
            // reborrow-inherit): a view-of-a-view chains, only the owning leaf pins.
            let vw = self.owner().carries(self.body().module, pl.ty);
            if vw {
                self.subset(self.origin_of_place(pid), dorigin, entry);
            } else {
                self.f.loans.push(
                    Loan {
                        view: false,
                        pin: true,
                        place: pid,
                        kind: LK_SHARED,
                        origin: dorigin,
                        issued_at: entry + 1,
                        activated_at: BF_NONE,
                        span: sp,
                    },
                );
            }
        }
    }

    fn walk(self: &mut Self) {
        let nlocals = self.body().locals.len() as u32;
        let nb = self.body().blocks.len();
        let mut lw = (nlocals + 63) / 64;
        if lw == 0 {
            lw = 1;
        }
        self.f.lwords = lw;
        for _i in 0..nb as u32 * lw {
            self.f.luse.push(0u64);
            self.f.ldef.push(0u64);
        }
        for bi in 0..nb {
            self.cur_block = bi as u32;
            let ne = self.f.events.len() as u32;
            self.f.ev_start.push(ne);
            self.seen.clear();
            for _w in 0..lw {
                self.seen.push(0u64);
            }
            let blk = *self.body().blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *self.body().statements.at((blk.stmt_start + si) as usize);
                let entry = self.stmt_entry(bi as u32, si);
                let exit = entry + 1;
                if s.kind == ir::ST_ASSIGN {
                    self.stmt_assign(&s, entry, exit);
                } else if s.kind == ir::ST_SET_DISCR {
                    self.live_use(self.place_of(s.place).base);
                    self.f.accesses.push(
                        Access { place: s.place, local: BF_NONE, kind: ACC_WRITE, point: exit, span: s.span },
                    );
                    self.assign_sites.push(KillSite { place: s.place, local: BF_NONE, point: exit });
                } else if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
                    let root = self.forest().local_root[s.a as usize];
                    self.f.events.push(Event { kind: EV_DEAD, path: root, point: exit, span: s.span });
                    self.assign_sites.push(KillSite { place: BF_NONE, local: s.a, point: exit });
                    if s.kind == ir::ST_STORAGE_DEAD {
                        // An owned carrier's destruction observes what it stores (`Free` runs), so
                        // the local counts as USED here -- stored borrows must survive to this point.
                        if self.f.observed[s.a as usize] {
                            self.live_use(s.a);
                        }
                        self.f.accesses.push(
                            Access { place: BF_NONE, local: s.a, kind: ACC_WRITE, point: exit, span: s.span },
                        );
                    }
                } else if s.kind == ir::ST_DEINIT {
                    let path = self.forest().place_path[s.place as usize];
                    if path != mp::MP_NONE {
                        self.f.events.push(Event { kind: EV_DEAD, path: path, point: exit, span: s.span });
                    }
                } else if s.kind == ir::ST_ASM {
                    self.op_range_read(s.a, s.b, entry, s.span);
                }
            }
            let t = blk.term;
            let entry = self.term_entry(bi as u32);
            let exit = entry + 1;
            if t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT {
                self.op_read(t.a, entry, t.span);
            } else if t.kind == ir::TM_CALL {
                if t.callee.node == NODE_NONE && t.a != ir::IR_NONE {
                    self.calling = true;
                    self.op_read(t.a, entry, t.span);
                    self.calling = false;
                    // A fn-value call has no named signature; conservatively derive carrying
                    // dests from every carrying argument AND the callee value's own captures.
                    for d2 in 0..t.dests_len {
                        let dp2 = self.body().dest_pool[(t.dests_start + d2) as usize];
                        let dor2 = self.origin_of_place(dp2);
                        if dor2 == BF_NONE {
                            continue;
                        }
                        let cop = *self.body().operands.at(t.a as usize);
                        if cop.kind == ir::OP_COPY || cop.kind == ir::OP_MOVE {
                            self.subset(self.origin_of_place(cop.data), dor2, entry);
                        }
                        for i2 in 0..t.args_len {
                            let oi2 = *self.body().operands.at(
                                self.body().oper_pool[(t.args_start + i2) as usize] as usize,
                            );
                            if oi2.kind == ir::OP_COPY || oi2.kind == ir::OP_MOVE {
                                self.subset(self.origin_of_place(oi2.data), dor2, entry);
                            }
                        }
                    }
                }
                // The first borrow-carrying destination owns loans the call opens on autoref args.
                let mut dor0 = BF_NONE;
                for d in 0..t.dests_len {
                    let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                    if dor0 == BF_NONE {
                        dor0 = self.origin_of_place(dp);
                    }
                }
                let mut kinds = Vector::<u8>::new();
                self.arg_kinds(t.callee, t.args_len, &mut kinds);
                // Explicit `.free()` consumes its receiver even though the parameter is `&mut`.
                let frees = t.args_len == 1 && self.is_free_callee(t.callee);
                for i in 0..t.args_len {
                    let opid = self.body().oper_pool[(t.args_start + i) as usize];
                    let op = *self.body().operands.at(opid as usize);
                    let mut implicit = false;
                    if kinds[i as usize] != 0 && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                        let bmod = self.body().module;
                        let pty = self.place_of(op.data).ty;
                        let yk = self.owner().ast_of(bmod).type_at(pty).kind;
                        if yk != TypeKind::TYPE_REFERENCE && yk != TypeKind::TYPE_POINTER {
                            implicit = true;
                        }
                    }
                    if implicit && frees && i == 0 && kinds[0] == 2 && self.forest().place_path[op.data as usize] != mp::MP_NONE {
                        let path = self.forest().place_path[op.data as usize];
                        self.live_use(self.place_of(op.data).base);
                        self.f.events.push(Event { kind: EV_MOVE, path: path, point: entry, span: t.span });
                        self.f.accesses.push(
                            Access { place: op.data, local: BF_NONE, kind: ACC_FREE, point: entry, span: t.span },
                        );
                        self.f.freed.push(path);
                    } else if implicit {
                        self.implicit_borrow(op.data, kinds[i as usize], entry, dor0, t.span);
                    } else {
                        self.op_read(opid, entry, t.span);
                        // ref -> pointer at an argument erases the borrow: the reference leaves the
                        // checked world here, exactly like the walk's erase rule.
                        if kinds[i as usize] == 3 && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                            let oty = self.place_of(op.data).ty;
                            if oty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(oty).kind == TypeKind::TYPE_REFERENCE {
                                let aor = self.origin_of_place(op.data);
                                for l in 0..self.f.loans.len() {
                                    if self.f.loans.at(l).origin == aor {
                                        self.f.kills.push(KillAt { loan: l as u32, point: entry });
                                    }
                                }
                            }
                        }
                    }
                }
                // Arguments the callee's SIGNATURE ties to a `&mut` parameter can be stored
                // through it (`put<'a>(s: &mut Slot<'a>, x: &'a i32)`, `push_into<T>(v: &mut
                // Vector<T>, x: T)`): flow them into that argument's origin, whose rebind backlink
                // carries them to the pointee's holder.
                if t.callee.node != NODE_NONE {
                    let mut ptyn = Vector::<NodeId>::new();
                    {
                        let a = self.owner().ast_of(t.callee.module);
                        let nd = a.at_const(t.callee.node);
                        if nd.kind == NodeKind::NODE_FUNCTION {
                            let ps = nd.as_data.function.params;
                            let mut lim = t.args_len;
                            if ps.len < lim {
                                lim = ps.len;
                            }
                            for i in 0..lim {
                                let pid = unsafe a.list(ps)[i as usize];
                                ptyn.push(a.at_const(pid).as_data.parameter.ty);
                            }
                        }
                    }
                    for j in 0..ptyn.len() {
                        if kinds[j] != 2 {
                            continue;
                        }
                        let mut jtok = Vector::<u64>::new();
                        self.lt_tokens(t.callee.module, ptyn[j], &mut jtok, 0);
                        if jtok.len() != 0 {
                            let oj = *self.body().operands.at(
                                self.body().oper_pool[(t.args_start + j as u32) as usize] as usize,
                            );
                            let mut tor = BF_NONE;
                            if oj.kind == ir::OP_COPY || oj.kind == ir::OP_MOVE {
                                tor = self.origin_of_place(oj.data);
                                // The store lands in the POINTEE: retarget through the loan the
                                // `&mut` temp holds to the borrowed container's own origin (the
                                // backlink subset only exists at the borrow point, not here).
                                for l in 0..self.f.loans.len() {
                                    if self.f.loans.at(l).origin == tor {
                                        let lb = self.place_of(self.f.loans.at(l).place).base;
                                        if self.f.local_origin[lb as usize] != BF_NONE {
                                            tor = self.f.local_origin[lb as usize];
                                        }
                                    }
                                }
                            }
                            for i in 0..ptyn.len() {
                                if i == j || tor == BF_NONE {
                                    continue;
                                }
                                let oi = *self.body().operands.at(
                                    self.body().oper_pool[(t.args_start + i as u32) as usize] as usize,
                                );
                                if oi.kind != ir::OP_COPY && oi.kind != ir::OP_MOVE {
                                    continue;
                                }
                                // A reference-typed source can only be STORED through its own
                                // named lifetime; its pointee's tokens matter only when the
                                // pointee value itself carries borrows (`swap<T>(&mut T, &mut T)`
                                // with T = &i32). By-value sources use all their tokens.
                                let mut itok = Vector::<u64>::new();
                                let oty = self.place_of(oi.data).ty;
                                let mut pointee_carries = false;
                                if oty != TYPE_NONE {
                                    let ya = *self.owner().ast_of(self.body().module).type_at(oty);
                                    if ya.kind == TypeKind::TYPE_REFERENCE {
                                        pointee_carries = self.owner().carries(self.body().module, ya.as_data.elem);
                                    }
                                }
                                if (kinds[i] == 1 || kinds[i] == 2) && !pointee_carries {
                                    let a2 = self.owner().ast_of(t.callee.module);
                                    if a2.at_const(ptyn[i]).kind == NodeKind::NODE_REFERENCE_TYPE {
                                        let lt2 = a2.at_const(ptyn[i]).as_data.indirect_type.lifetime;
                                        self.lt_name_token(t.callee.module, lt2, &mut itok);
                                    }
                                } else {
                                    self.lt_tokens(t.callee.module, ptyn[i], &mut itok, 0);
                                }
                                let mut tie = false;
                                for x in 0..itok.len() {
                                    for y in 0..jtok.len() {
                                        if itok[x] == jtok[y] {
                                            tie = true;
                                        }
                                    }
                                }
                                if tie {
                                    let aor = self.origin_of_place(oi.data);
                                    if aor != BF_NONE {
                                        self.subset(aor, tor, entry);
                                    }
                                }
                                itok.free();
                            }
                        }
                        jtok.free();
                    }
                    ptyn.free();
                }
                // A `&mut self` receiver whose pointee holds borrows is a STORE TARGET: argument
                // borrows can land in the container (`v.push(&x)`), so they flow into the
                // receiver's origin. Other cross-argument stores are the signature checks' job.
                if t.args_len != 0 && kinds[0] == 2 && self.is_self_callee(t.callee) {
                    let op0 = *self.body().operands.at(self.body().oper_pool[t.args_start as usize] as usize);
                    if op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE {
                        // Only a container the FRAME owns (no deref on the way, non-reference base)
                        // tracks stored borrows here; stores through a reference land in caller
                        // storage, which the declared-lifetime checks own.
                        let mut tor = BF_NONE;
                        let p0 = self.place_of(op0.data);
                        let mut owned0 = !self.through_deref(op0.data);
                        let b0ty = self.body().locals.at(p0.base as usize).ty;
                        if b0ty != TYPE_NONE {
                            let yk = self.owner().ast_of(self.body().module).type_at(b0ty).kind;
                            if yk == TypeKind::TYPE_REFERENCE || yk == TypeKind::TYPE_POINTER {
                                owned0 = false;
                            }
                        }
                        let p0ty = p0.ty;
                        if owned0 && p0ty != TYPE_NONE {
                            let y0 = *self.owner().ast_of(self.body().module).type_at(p0ty);
                            let mut inner = p0ty;
                            if y0.kind == TypeKind::TYPE_REFERENCE {
                                inner = y0.as_data.elem;
                            }
                            if self.stores_borrows(self.body().module, inner) {
                                tor = self.origin_of_place(op0.data);
                            }
                        }
                        if tor != BF_NONE {
                            // Same signature gate as the `&mut`-parameter ties: an argument lands
                            // in the container only when the receiver's type tokens admit it.
                            let mut jtok0 = Vector::<u64>::new();
                            {
                                let a5 = self.owner().ast_of(t.callee.module);
                                let nd5 = a5.at_const(t.callee.node);
                                if nd5.kind == NodeKind::NODE_FUNCTION && nd5.as_data.function.params.len != 0 {
                                    let p05 = unsafe a5.list(nd5.as_data.function.params)[0];
                                    let pt05 = a5.at_const(p05).as_data.parameter.ty;
                                    self.lt_tokens(t.callee.module, pt05, &mut jtok0, 0);
                                }
                            }
                            for j in 1..t.args_len {
                                let oj = *self.body().operands.at(
                                    self.body().oper_pool[(t.args_start + j) as usize] as usize,
                                );
                                if oj.kind != ir::OP_COPY && oj.kind != ir::OP_MOVE {
                                    continue;
                                }
                                let aor = self.origin_of_place(oj.data);
                                if aor == BF_NONE {
                                    continue;
                                }
                                let mut itok3 = Vector::<u64>::new();
                                let ojty = self.place_of(oj.data).ty;
                                let mut pc3 = false;
                                if ojty != TYPE_NONE {
                                    let yj = *self.owner().ast_of(self.body().module).type_at(ojty);
                                    if yj.kind == TypeKind::TYPE_REFERENCE {
                                        pc3 = self.owner().carries(self.body().module, yj.as_data.elem);
                                    }
                                }
                                let mut ptynj = NODE_NONE;
                                {
                                    let a6 = self.owner().ast_of(t.callee.module);
                                    let nd6 = a6.at_const(t.callee.node);
                                    if nd6.kind == NodeKind::NODE_FUNCTION && j < nd6.as_data.function.params.len {
                                        ptynj = a6.at_const(unsafe a6.list(nd6.as_data.function.params)[j as usize]).as_data.parameter.ty;
                                    }
                                }
                                if (kinds[j as usize] == 1 || kinds[j as usize] == 2) && !pc3 {
                                    let a7 = self.owner().ast_of(t.callee.module);
                                    if ptynj != NODE_NONE && a7.at_const(ptynj).kind == NodeKind::NODE_REFERENCE_TYPE {
                                        let ltj = a7.at_const(ptynj).as_data.indirect_type.lifetime;
                                        self.lt_name_token(t.callee.module, ltj, &mut itok3);
                                    }
                                } else if ptynj != NODE_NONE {
                                    self.lt_tokens(t.callee.module, ptynj, &mut itok3, 0);
                                }
                                let mut tie3 = false;
                                for x in 0..itok3.len() {
                                    for y in 0..jtok0.len() {
                                        if itok3[x] == jtok0[y] {
                                            tie3 = true;
                                        }
                                    }
                                }
                                if tie3 {
                                    self.subset(aor, tor, entry);
                                }
                                itok3.free();
                            }
                            jtok0.free();
                        }
                    }
                }
                for d in 0..t.dests_len {
                    let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                    self.write_place(dp, exit, t.span);
                }
                // A borrow-carrying result derives from its RECEIVER (the walk's result-pin hook)
                // and from the arguments the SIGNATURE ties to the return: shared lifetime/generic
                // tokens, or the elision rule (one borrowing input feeds an elided return).
                let recv = t.args_len != 0 && self.is_self_callee(t.callee);
                let mut rtok = Vector::<u64>::new();
                let mut relide = false;
                let mut nborrowing: u32 = 0;
                let mut bidx: u32 = 0;
                if t.callee.node != NODE_NONE {
                    let mut rets = NodeList { start: 0, len: 0 };
                    {
                        let a3 = self.owner().ast_of(t.callee.module);
                        let nd3 = a3.at_const(t.callee.node);
                        if nd3.kind == NodeKind::NODE_FUNCTION {
                            rets = nd3.as_data.function.returns;
                        }
                    }
                    for r3 in 0..rets.len {
                        let mut rn = unsafe self.owner().ast_of(t.callee.module).list(rets)[r3 as usize];
                        if self.owner().ast_of(t.callee.module).at_const(rn).kind == NodeKind::NODE_PARAMETER {
                            rn = self.owner().ast_of(t.callee.module).at_const(rn).as_data.parameter.ty;
                        }
                        self.lt_tokens(t.callee.module, rn, &mut rtok, 0);
                    }
                    // No named token on the return: any borrow-carrying result elides -- its
                    // borrows come from the single borrowing input (rule 2/3; receiver ties are
                    // separate). The dest-origin guard below keeps this to carrying results.
                    relide = rtok.len() == 0;
                    for i3 in 0..t.args_len {
                        if kinds[i3 as usize] == 1 || kinds[i3 as usize] == 2 {
                            nborrowing += 1;
                            bidx = i3;
                        }
                    }
                }
                for d in 0..t.dests_len {
                    let dp = self.body().dest_pool[(t.dests_start + d) as usize];
                    let dor = self.origin_of_place(dp);
                    if dor == BF_NONE {
                        continue;
                    }
                    let dty = self.place_of(dp).ty;
                    if dty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(dty).kind == TypeKind::TYPE_POINTER {
                        continue;
                    }
                    for i in 0..t.args_len {
                        let opid = self.body().oper_pool[(t.args_start + i) as usize];
                        let op = *self.body().operands.at(opid as usize);
                        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                            continue;
                        }
                        let mut tie = i == 0 && recv;
                        if !tie && relide && nborrowing == 1 && i == bidx {
                            tie = true; // elision: the single borrowing input feeds the return
                        }
                        if !tie && rtok.len() != 0 && t.callee.node != NODE_NONE {
                            let mut itok2 = Vector::<u64>::new();
                            let a4 = self.owner().ast_of(t.callee.module);
                            let nd4 = a4.at_const(t.callee.node);
                            if nd4.kind == NodeKind::NODE_FUNCTION && i < nd4.as_data.function.params.len {
                                let pid4 = unsafe a4.list(nd4.as_data.function.params)[i as usize];
                                let ptyn4 = a4.at_const(pid4).as_data.parameter.ty;
                                self.lt_tokens(t.callee.module, ptyn4, &mut itok2, 0);
                            }
                            for x in 0..itok2.len() {
                                for y in 0..rtok.len() {
                                    if itok2[x] == rtok[y] {
                                        tie = true;
                                    }
                                }
                            }
                            itok2.free();
                        }
                        if tie {
                            let aor = self.origin_of_place(op.data);
                            if aor != BF_NONE {
                                self.subset(aor, dor, entry);
                            }
                        }
                    }
                }
                rtok.free();
                kinds.free();
            } else if t.kind == ir::TM_RETURN {
                let nrets = self.body().returns;
                for r in 0..nrets {
                    self.live_use(r);
                }
                for r in 0..nrets {
                    if r as usize < self.f.ret_origin.len() && self.f.ret_origin[r as usize] != BF_NONE {
                        let lo = self.f.local_origin[r as usize];
                        let ro = self.f.ret_origin[r as usize];
                        self.subset(lo, ro, entry);
                    }
                }
            } else if t.kind == ir::TM_DROP {
                if t.a != ir::IR_NONE {
                    // At analysis time only USER-written destruction exists (`d.free()` on a dyn);
                    // elaboration inserts its drops afterwards. It consumes the place.
                    self.live_use(self.place_of(t.a).base);
                    let path = self.forest().place_path[t.a as usize];
                    if path != mp::MP_NONE {
                        self.f.events.push(Event { kind: EV_MOVE, path: path, point: entry, span: t.span });
                    }
                    self.f.accesses.push(
                        Access { place: t.a, local: BF_NONE, kind: ACC_FREE, point: entry, span: t.span },
                    );
                }
            }
        }
        let ne = self.f.events.len() as u32;
        self.f.ev_start.push(ne);
    }

    fn stmt_assign(self: &mut Self, s: &ir::Statement, entry: u32, exit: u32) {
        let rv = *self.body().rvalues.at(s.rvalue as usize);
        let mut dor = self.origin_of_place(s.place);
        // A raw-pointer destination is the unsafe world's handoff: the stored value's origins do
        // not flow through it.
        {
            let dty = self.place_of(s.place).ty;
            if dty != TYPE_NONE && self.owner().ast_of(self.body().module).type_at(dty).kind == TypeKind::TYPE_POINTER {
                dor = BF_NONE;
            }
        }
        if rv.kind == ir::RV_REF {
            let src = rv.a;
            let spl = self.place_of(src);
            self.live_use(spl.base);
            // The borrow itself reads (shared) or claims (mutable) the place. A two-phase `&mut`
            // (temp destination) claims nothing at issue -- its activation carries the claim.
            let mut ak = ACC_READ;
            if rv.b == 1 && self.body().locals.at(self.place_of(s.place).base as usize).storage != ir::LS_TEMP {
                ak = ACC_WRITE;
            }
            self.f.accesses.push(Access { place: src, local: BF_NONE, kind: ak, point: entry, span: s.span });
            // Init requirement: borrowing an uninitialized path is legal only for &mut (out-params);
            // record a use event for shared borrows of tracked paths.
            let path = self.forest().place_path[src as usize];
            if rv.b == 0 {
                let mut upath = path;
                if upath == mp::MP_NONE {
                    upath = self.forest().place_cut[src as usize];
                }
                if upath != mp::MP_NONE {
                    self.f.events.push(Event { kind: EV_USE, path: upath, point: entry, span: s.span });
                }
            } else if path != mp::MP_NONE {
                // `&mut x` passed onward may initialize x through the callee.
                self.f.events.push(Event { kind: EV_ASSIGN, path: path, point: exit, span: s.span });
            }
            let mut kind = LK_SHARED;
            if rv.b == 1 {
                kind = LK_MUT;
                if self.body().locals.at(self.place_of(s.place).base as usize).storage == ir::LS_TEMP {
                    kind = LK_RESERVED;
                }
            }
            let mut org = dor;
            if org == BF_NONE {
                org = 0;
            }
            if !self.base_is_raw(src) && !(rv.b == 1 && self.shared_deref(src)) {
                let vw = self.owner().carries(self.body().module, self.place_of(src).ty);
                self.f.loans.push(
                    Loan {
                        view: vw,
                        pin: false,
                        place: src,
                        kind: kind,
                        origin: org,
                        issued_at: exit,
                        activated_at: BF_NONE,
                        span: s.span,
                    },
                );
            }
            // A reborrow's validity chains to the reference it went through; a borrow of a slot
            // that itself HOLDS borrows links the slot's origin -- both ways when mutable, because
            // stores through the reference land in the slot (invariance).
            let src_carries = self.owner().carries(self.body().module, self.place_of(src).ty);
            if self.through_deref(src) || src_carries {
                self.subset(self.f.local_origin[spl.base as usize], org, entry);
            }
            if rv.b == 1 && src_carries {
                self.subset(org, self.f.local_origin[spl.base as usize], entry);
            }
            self.write_place(s.place, exit, s.span);
            return;
        }
        if rv.kind == ir::RV_ADDR {
            // Raw addresses live in the unsafe world; the base local stays live, nothing else.
            self.live_use(self.place_of(rv.a).base);
            self.write_place(s.place, exit, s.span);
            return;
        }
        if rv.kind == ir::RV_CLOSURE {
            let mut mut_caps: u64 = 0;
            if rv.item.node != NODE_NONE {
                let a = self.owner().ast_of(self.body().module);
                if a.at_const(rv.item.node).kind == NodeKind::NODE_CLOSURE {
                    mut_caps = a.at_const(rv.item.node).as_data.closure.mut_caps;
                }
            }
            let mut org = dor;
            if org == BF_NONE {
                org = 0;
            }
            for i in 0..rv.b {
                let opid = self.body().oper_pool[(rv.a + i) as usize];
                let op = *self.body().operands.at(opid as usize);
                if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                    continue;
                }
                if (mut_caps >> i as u64 & 1u64) != 0 {
                    // A mutable capture is a mutable borrow held by the closure value.
                    let pl = self.place_of(op.data);
                    self.live_use(pl.base);
                    self.f.accesses.push(
                        Access { place: op.data, local: BF_NONE, kind: ACC_WRITE, point: entry, span: s.span },
                    );
                    if !self.base_is_raw(op.data) {
                        self.f.loans.push(
                            Loan {
                                view: false,
                                pin: false,
                                place: op.data,
                                kind: LK_CAP,
                                origin: org,
                                issued_at: exit,
                                activated_at: BF_NONE,
                                span: s.span,
                            },
                        );
                    }
                } else {
                    self.in_caps = true;
                    self.op_read(opid, entry, s.span);
                    self.in_caps = false;
                    let aor = self.origin_of_place(op.data);
                    self.subset(aor, dor, entry);
                }
            }
            self.write_place(s.place, exit, s.span);
            return;
        }
        // Value-carrying rvalues: read operands, flow borrow-carrying operand origins into the
        // destination, then write.
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_DYN || rv.kind == ir::RV_REPEAT {
            // The `&mut`-copy-consumes rule is a REBIND rule: it applies only when the copy lands
            // whole in a reference-typed local (`let r2 = r1`), never on stores into fields or
            // coercions into the raw-pointer world.
            if rv.kind == ir::RV_USE {
                let dpl = self.place_of(s.place);
                if dpl.proj_len == 0 && dpl.ty != TYPE_NONE {
                    self.plain_copy = self.owner().ast_of(self.body().module).type_at(dpl.ty).kind == TypeKind::TYPE_REFERENCE;
                }
            }
            self.op_read(rv.a, entry, s.span);
            self.plain_copy = false;
            let op = *self.body().operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let aor = self.origin_of_place(op.data);
                self.subset(aor, dor, entry);
                // Reading a VIEW value out of a non-carrying container (`v[0..2]` copies a slice)
                // pins the container exactly like the call-result hook.
                if dor != BF_NONE && rv.kind == ir::RV_USE {
                    let opl = self.place_of(op.data);
                    let bty = self.body().locals.at(opl.base as usize).ty;
                    if opl.ty != TYPE_NONE && bty != TYPE_NONE && opl.proj_len != 0 && !self.base_is_raw(op.data) && !self.through_deref(
                        op.data,
                    ) && self.owner().carries(self.body().module, opl.ty) && !self.owner().carries(
                        self.body().module,
                        bty,
                    ) {
                        self.f.loans.push(
                            Loan {
                                view: false,
                                pin: true,
                                place: op.data,
                                kind: LK_SHARED,
                                origin: dor,
                                issued_at: exit,
                                activated_at: BF_NONE,
                                span: s.span,
                            },
                        );
                    }
                }
            }
        } else if rv.kind == ir::RV_SLICE {
            // structural slicing reads the container and yields a VIEW: origin flows from the
            // container, and a carrying view of a non-carrying container pins it (the same rule
            // as the projected-copy path above)
            let bpl = self.place_of(rv.a);
            self.live_use(bpl.base);
            self.f.accesses.push(Access { place: rv.a, local: BF_NONE, kind: ACC_READ, point: entry, span: s.span });
            if rv.b != ir::IR_NONE {
                self.op_read(rv.b, entry, s.span);
            }
            if rv.item.node != ir::IR_NONE {
                self.op_read(rv.item.node, entry, s.span);
            }
            let aor = self.origin_of_place(rv.a);
            self.subset(aor, dor, entry);
            if dor != BF_NONE {
                let bty = self.body().locals.at(bpl.base as usize).ty;
                if bty != TYPE_NONE && !self.base_is_raw(rv.a) && !self.through_deref(rv.a) && self.owner().carries(
                    self.body().module,
                    rv.target,
                ) && !self.owner().carries(self.body().module, bty) {
                    self.f.loans.push(
                        Loan {
                            view: false,
                            pin: true,
                            place: rv.a,
                            kind: LK_SHARED,
                            origin: dor,
                            issued_at: exit,
                            activated_at: BF_NONE,
                            span: s.span,
                        },
                    );
                }
            }
        } else if rv.kind == ir::RV_BINARY {
            self.op_read(rv.a, entry, s.span);
            self.op_read(rv.b, entry, s.span);
        } else if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF) {
            // no operands: `b` is the measured type
        } else if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_INTRINSIC {
            for i in 0..rv.b {
                let opid = self.body().oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue; // omitted struct member: no operand, C zero-fills
                }
                self.op_read(opid, entry, s.span);
                if rv.kind == ir::RV_AGGREGATE {
                    let op = *self.body().operands.at(opid as usize);
                    if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                        let aor = self.origin_of_place(op.data);
                        self.subset(aor, dor, entry);
                    }
                }
            }
        } else if rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            let pl = self.place_of(rv.a);
            self.live_use(pl.base);
            self.f.accesses.push(Access { place: rv.a, local: BF_NONE, kind: ACC_READ, point: entry, span: s.span });
        }
        self.write_place(s.place, exit, s.span);
    }

    // ---- post-passes ------------------------------------------------------------------------------

    // Kills: an assignment that overwrites a loan's borrowed storage (its path is a must-equal
    // prefix of the loan's) ends the loan. Storage markers kill every loan based on their local.
    fn finish(self: &mut Self) {
        let nlocals2 = self.body().locals.len();
        for _l in 0..nlocals2 {
            self.f.moved_whole.push(false);
        }
        for e in 0..self.f.events.len() {
            let ev = *self.f.events.at(e);
            if ev.kind == EV_MOVE {
                let mp2 = *self.forest().paths.at(ev.path as usize);
                if mp2.parent == mp::MP_NONE {
                    self.f.moved_whole.set(mp2.base as usize, true);
                }
            }
        }
        let na = self.assign_sites.len();
        let nl = self.f.loans.len();
        for a in 0..na {
            let site = *self.assign_sites.at(a);
            for l in 0..nl {
                let lp = self.f.loans.at(l).place;
                if site.local != BF_NONE {
                    if self.place_of(lp).base == site.local {
                        self.f.kills.push(KillAt { loan: l as u32, point: site.point });
                    }
                } else if self.kill_covers(site.place, lp) {
                    self.f.kills.push(KillAt { loan: l as u32, point: site.point });
                }
            }
        }
        // Reserved loans activate at the first later read of the holder temp.
        let nacc = self.f.accesses.len();
        for l in 0..nl {
            if self.f.loans.at(l).kind != LK_RESERVED {
                continue;
            }
            let ip = self.f.loans.at(l).issued_at;
            let mut holder = BF_NONE;
            for a in 0..nacc {
                let ac = *self.f.accesses.at(a);
                if ac.point == ip && ac.kind == ACC_WRITE && self.place_of(ac.place).proj_len == 0 {
                    holder = self.place_of(ac.place).base;
                    break;
                }
            }
            if holder == BF_NONE {
                continue;
            }
            let mut act = BF_NONE;
            for a in 0..nacc {
                let ac = *self.f.accesses.at(a);
                // A `&mut` holder temp is consumed (ACC_MOVE) when it lands in a user binding; that
                // copy is the activation read.
                if (ac.kind == ACC_READ || ac.kind == ACC_MOVE) && ac.place != BF_NONE && ac.point > ip && self.place_of(
                    ac.place,
                ).base == holder {
                    if act == BF_NONE || ac.point < act {
                        act = ac.point;
                    }
                }
            }
            self.f.loans[l].activated_at = act;
            if act != BF_NONE {
                // Activation asserts the mutable claim against every OTHER required loan.
                let lpl = self.f.loans.at(l).place;
                let lsp = self.f.loans.at(l).span;
                self.f.accesses.push(Access { place: lpl, local: BF_NONE, kind: ACC_ACT, point: act, span: lsp });
            }
        }
    }

    // Is `a`'s projection path a must-equal prefix of `b`'s (same base)?
    fn kill_covers(self: &Self, a: ir::PlaceId, bp: ir::PlaceId) bool {
        let pa = self.place_of(a);
        let pb = self.place_of(bp);
        if pa.base != pb.base || pa.proj_len > pb.proj_len {
            return false;
        }
        for i in 0..pa.proj_len {
            let ea = *self.body().projections.at((pa.proj_start + i) as usize);
            let eb = *self.body().projections.at((pb.proj_start + i) as usize);
            if ea.kind != eb.kind {
                return false;
            }
            if ea.kind == ir::PJ_FIELD || ea.kind == ir::PJ_DOWNCAST || ea.kind == ir::PJ_INDEX_CONST {
                if ea.data != eb.data || ea.sub != eb.sub {
                    return false;
                }
            }
            if ea.kind == ir::PJ_INDEX_OP {
                return false; // a dynamic index cannot prove it hits the borrowed element
            }
        }
        return true;
    }
}

/// May accesses of `a` and `b` touch overlapping storage? Same base local, and neither path proves
/// disjointness (differing fields, variants, or constant indexes) before one ends.
pub fn places_conflict(b: &ir::CoreBody, a: ir::PlaceId, c: ir::PlaceId) bool {
    let pa = *b.places.at(a as usize);
    let pc = *b.places.at(c as usize);
    if pa.base != pc.base {
        return false;
    }
    let mut n = pa.proj_len;
    if pc.proj_len < n {
        n = pc.proj_len;
    }
    for i in 0..n {
        let ea = *b.projections.at((pa.proj_start + i) as usize);
        let ec = *b.projections.at((pc.proj_start + i) as usize);
        if ea.kind != ec.kind {
            // Differing shapes at the same depth still reach overlapping storage only through the
            // same chain; stay conservative and report overlap.
            return true;
        }
        if ea.kind == ir::PJ_FIELD && ea.data == ir::IR_NONE && ea.sub == NODE_NONE {
            // A reflection-binder member has no per-field identity yet; expansion re-proves each
            // copy, so two such projections never conflict here.
            return false;
        }
        if ea.kind == ir::PJ_FIELD && ea.data == ir::PJ_UNION_FIELD && ec.data == ir::PJ_UNION_FIELD {
            return true; // union members share storage whatever the field
        }
        if ea.kind == ir::PJ_FIELD || ea.kind == ir::PJ_DOWNCAST || ea.kind == ir::PJ_INDEX_CONST {
            if ea.data != ec.data || ea.sub != ec.sub {
                return false;
            }
        }
    }
    return true;
}
