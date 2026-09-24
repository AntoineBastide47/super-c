// Body-local inference state and the read-only package boundary.
// InferenceContext owns the mutable walk state one body's check may touch plus the solver core:
// inference variables with a rollback log and the per-call generic-argument session. PackageTypeDb owns the read-only declaration and type
// lookup a body job is allowed. TypeChecker composes both and keeps the current algorithms behind
// its existing methods as adapters.
import ast::ast as *;
import module::loader as loader;

// Tag in the top two bits; the payload never exceeds 30 bits (TypeIds and variable ids are dense).
//   00 Published(TypeId)   an interned type in the current module's pool
//   01 Var(InferVarId)     a type inference variable
//   11 ConstVar(id)        a const inference variable
/// A tagged inference-time type: a published TypeId, a type variable, or a const variable (see the
/// IT_TAG_* tags and the it_* constructors).
pub type InferTy = u32;
pub const IT_TAG_PUB: u32 = 0;
pub const IT_TAG_VAR: u32 = 1;
pub const IT_TAG_CVAR: u32 = 3;
pub const IT_UNBOUND: u32 = 0xFFFFFFFF; // binding-slot sentinel, never a valid InferTy

/// The InferTy of an interned type of the current module.
pub const fn it_pub(t: TypeId) InferTy {
    return t;
}
/// The InferTy of inference variable `v`.
pub const fn it_var(v: u32) InferTy {
    return IT_TAG_VAR << 30 | v;
}
/// The InferTy of const variable `c`.
pub const fn it_cvar(c: u32) InferTy {
    return IT_TAG_CVAR << 30 | c;
}
/// The IT_TAG_* tag of `t`.
pub const fn it_tag(t: InferTy) u32 {
    return t >> 30;
}
/// The 30-bit payload of `t`: TypeId, variable id, or const-variable id.
pub const fn it_payload(t: InferTy) u32 {
    return t & 0x3FFFFFFF;
}
/// True for a const variable.
pub const fn it_is_cvar(t: InferTy) bool {
    return it_tag(t) == IT_TAG_CVAR;
}
/// The const-variable id of `t`; `it_is_cvar(t)` must hold.
pub const fn it_cvar_id(t: InferTy) u32 {
    return it_payload(t);
}

// Rollback log cell kinds.
const LK_BINDING: u8 = 0;
const LK_CBIND: u8 = 1;

struct LogEnt {
    pub kind: u8,
    pub idx: u32,
    pub old: u64,
}

/// A probe mark: a solver snapshot plus the session-map watermark (relative to the active session),
/// so a nested candidate probe can map its own parameters and be rolled back without disturbing the
/// enclosing call session.
pub struct ProbeMark {
    pub snap: Snapshot,
    pub base: u32,
}

/// A snapshot is a group of integer watermarks; rollback truncates growth past them and replays the
/// log backwards. It never copies vectors, maps, or types.
pub struct Snapshot {
    pub log: u32,
    pub nvars: u32,
    pub ncvars: u32,
    pub nbounds: u32,
    pub nconflicts: u32,
    pub ntype_conflicts: u32,
}

/// Where the active call session starts in each session table. A call checked while another call's
/// session is open (a postponed closure body) opens its own session on top and closes it before the
/// enclosing session continues.
pub struct SessionMark {
    pub pd: u32,
    pub bounds: u32,
    pub cconflicts: u32,
    pub type_conflicts: u32,
}

// One recorded piece of directional evidence for a variable: `ty` flowed into the variable's
// position at `node`. `eq` marks a nested (invariant) position.
struct BoundRec {
    pub var: u32,
    pub ty: TypeId,
    pub node: NodeId,
    pub eq: bool,
}

/// A const-value conflict: two exact uses disagreed. Recorded, not emitted; the adapter turns
/// these into one diagnostic at the call.
pub struct CConflict {
    pub old: TypeId,
    pub later: TypeId,
}

/// Two directional uses of one type variable that have no unique safe-conversion join.
pub struct TypeConflict {
    pub first: TypeId,
    pub later: TypeId,
}

/// The per-body mutable inference state. One live context serves one body at a time; check_item
/// resets the function-scoped fields per body. No pointer into this state is published: results land
/// in the Ast side tables.
pub struct InferenceContext {
    pub current_returns: NodeList,
    pub current_fn: NodeId,
    pub clos_stack: [NodeId; 8],
    pub nclos: u32,
    pub closure_depth: u32,
    pub unsafe_depth: u32,
    pub unsafe_used: u32, // ops inside the innermost active 'unsafe' that required it (lint)
    pub mret_call: NodeId,
    pub mret_types: [TypeId; 8],
    pub mret_n: u8,
    pub mret_total: u32,
    /// The argument list of the call whose callee is being resolved, so overload selection can look
    /// at what is being passed. Empty outside that window: a bare member access has no arguments.
    pub call_args: NodeList,
    pub addr_ctx: bool,
    pub place_use: bool,
    pub proj_obj_ok: bool, // one-shot: the identifier being checked is a member's object
    /// Guards tc_coerce_from against re-entering itself through the oracle it hangs off.
    pub coerce_depth: i32,
    /// The solver core: variables, union-find, rollback, local terms, and the call session.
    pub sv: Solver,
}

extend InferenceContext {
    /// Fresh walk state with no function in progress and an empty solver.
    pub fn new() InferenceContext {
        return InferenceContext {
            current_returns: NodeList { start: 0, len: 0 },
            current_fn: NODE_NONE,
            nclos: 0,
            closure_depth: 0,
            unsafe_depth: 0,
            unsafe_used: 0,
            mret_call: NODE_NONE,
            mret_n: 0,
            mret_total: 0,
            call_args: NodeList { start: 0, len: 0 },
            addr_ctx: false,
            place_use: false,
            proj_obj_ok: false,
            coerce_depth: 0,
            sv: Solver::new(),
        };
    }
}

/// Read-only access to published package state: module Asts, sources, and declaration lookup.
/// A body job reads through this boundary only; it never mutates another module's state. The
/// pointers borrow the Package (may be null for single-file checks without one).
pub struct PackageTypeDb<'a> {
    pub ast: *mut Ast,
    pub package: *mut loader::Package,
    pub source: str<'a>,
}

extend PackageTypeDb {
    /// The module whose body is being checked.
    pub const fn cur_module(self: &Self) ModuleId {
        return unsafe (&*self.ast).module;
    }

    @c.always_inline
    /// Module `m`'s live Ast (the current module's when `m` is it or no package is attached).
    pub const fn mod_ast(self: &Self, m: ModuleId) *mut Ast {
        if self.package != null && m != self.cur_module() {
            // Asts live in place in the module table, so the slot IS the live tree.
            return unsafe &mut (*self.package).modules[m as usize].ast;
        }
        return self.ast;
    }

    /// Module `m`'s source text, for span rendering.
    pub const fn mod_src(self: &Self, m: ModuleId) str {
        if self.package != null && m != self.cur_module() {
            return unsafe (*self.package).modules[m as usize].source.as_str();
        }
        return self.source;
    }

    /// Number of modules in the package; 0 without one.
    pub const fn pkg_count(self: &Self) usize {
        if self.package == null {
            return 0;
        }
        return unsafe (*self.package).modules.len();
    }
}

/// The inference solver core: dense variable arrays, a rollback log of changed cells, and the
/// per-call generic-argument session. Every binding is a published type, so a variable resolves in
/// one step. Storage is reused across calls; nothing here is published.
pub struct Solver {
    pub ast: *mut Ast, // the module under check; set per checker, read-only pool access
    v_binding: Vector<u32>, // InferTy or IT_UNBOUND
    c_ty: Vector<u32>, // TYPE_CONST or TYPE_CONST_EXPR TypeId; canonical interning makes id equality value equality
    c_bound: Vector<bool>,
    log: Vector<LogEnt>,
    bounds: Vector<BoundRec>,
    pub cconflicts: Vector<CConflict>,
    pub type_conflicts: Vector<TypeConflict>,
    s_pd: Vector<DefId>,
    s_slot: Vector<u32>, // it_var(..) or it_cvar(..)
    /// The active session's start in each session table; slots are relative to `sess.pd`.
    pub sess: SessionMark,
}

extend Solver {
    /// An empty solver bound to no Ast.
    pub fn new() Solver {
        return Solver {
            ast: null,
            v_binding: Vector::<u32>::new(),
            c_ty: Vector::<u32>::new(),
            c_bound: Vector::<bool>::new(),
            log: Vector::<LogEnt>::new(),
            bounds: Vector::<BoundRec>::new(),
            cconflicts: Vector::<CConflict>::new(),
            type_conflicts: Vector::<TypeConflict>::new(),
            s_pd: Vector::<DefId>::new(),
            s_slot: Vector::<u32>::new(),
            sess: SessionMark { pd: 0, bounds: 0, cconflicts: 0, type_conflicts: 0 },
        };
    }

    /// A fresh unbound inference variable.
    pub fn var_new(self: &mut Self) u32 {
        let v = self.v_binding.len() as u32;
        self.v_binding.push(IT_UNBOUND);
        return v;
    }

    /// A fresh unbound const variable.
    pub fn cvar_new(self: &mut Self) u32 {
        let c = self.c_ty.len() as u32;
        self.c_ty.push(0);
        self.c_bound.push(false);
        return c;
    }

    /// Resolve a term to its current head: a bound variable resolves to its binding, an unbound one
    /// to itself.
    pub const fn resolve(self: &Self, t: InferTy) InferTy {
        if it_tag(t) != IT_TAG_VAR {
            return t;
        }
        let b = self.v_binding[it_payload(t) as usize];
        if b == IT_UNBOUND {
            return t;
        }
        return b;
    }

    /// The current lengths of every solver table; `rollback` restores them.
    pub const fn snapshot(self: &Self) Snapshot {
        return Snapshot {
            log: self.log.len() as u32,
            nvars: self.v_binding.len() as u32,
            ncvars: self.c_ty.len() as u32,
            nbounds: self.bounds.len() as u32,
            nconflicts: self.cconflicts.len() as u32,
            ntype_conflicts: self.type_conflicts.len() as u32,
        };
    }

    /// Undo every binding and allocation made since `s` was taken.
    pub fn rollback(self: &mut Self, s: &Snapshot) {
        // Replay the log backwards first: entries may touch cells that predate the snapshot.
        let mut i = self.log.len();
        while i > s.log as usize {
            i -= 1;
            let e = self.log[i];
            if e.kind == LK_BINDING {
                self.v_binding.set(e.idx as usize, e.old as u32);
            } else {
                // LK_CBIND packs the old TypeId into the low bits and the old bound flag into bit 63.
                self.c_bound.set(e.idx as usize, (e.old >> 63 & 1) == 1);
                self.c_ty.set(e.idx as usize, e.old as u32);
            }
        }
        self.log.truncate(s.log as usize);
        self.v_binding.truncate(s.nvars as usize);
        self.c_ty.truncate(s.ncvars as usize);
        self.c_bound.truncate(s.ncvars as usize);
        self.bounds.truncate(s.nbounds as usize);
        self.cconflicts.truncate(s.nconflicts as usize);
        self.type_conflicts.truncate(s.ntype_conflicts as usize);
    }

    fn log_binding(self: &mut Self, v: u32) {
        self.log.push(LogEnt { kind: LK_BINDING, idx: v, old: self.v_binding[v as usize] });
    }
    fn log_cbind(self: &mut Self, c: u32) {
        let mut packed = self.c_ty[c as usize] as u64;
        if self.c_bound[c as usize] {
            packed = packed | 1u64 << 63;
        }
        self.log.push(LogEnt { kind: LK_CBIND, idx: c, old: packed });
    }

    /// Bind unbound variable `v` to published type `t`. Logged.
    pub fn bind(self: &mut Self, v: u32, t: TypeId) {
        assert(self.v_binding[v as usize] == IT_UNBOUND, "bind on a bound variable");
        self.log_binding(v);
        self.v_binding.set(v as usize, it_pub(t));
    }

    /// Bind const variable `c` to an exact const argument (a TYPE_CONST or TYPE_CONST_EXPR id;
    /// canonical interning makes id equality value equality). A disagreeing later value records a
    /// conflict and keeps the first binding (the adapter reports the conflict once per call).
    pub fn cbind(self: &mut Self, c: u32, ty: TypeId) bool {
        if self.c_bound[c as usize] {
            if self.c_ty[c as usize] == ty {
                return true;
            }
            self.cconflicts.push(CConflict { old: self.c_ty[c as usize], later: ty });
            return false;
        }
        self.log_cbind(c);
        self.c_bound.set(c as usize, true);
        self.c_ty.set(c as usize, ty);
        return true;
    }

    /// Begin a nested candidate probe: parameters mapped after this mark stack on top of the
    /// enclosing session, and probe_end removes every trace of the probe's work.
    pub const fn probe_begin(self: &mut Self) ProbeMark {
        return ProbeMark { snap: self.snapshot(), base: self.s_pd.len() as u32 - self.sess.pd };
    }

    /// End the probe begun at `m`: every binding and parameter slot it created is discarded.
    pub fn probe_end(self: &mut Self, m: &ProbeMark) {
        self.rollback(&m.snap);
        self.s_pd.truncate((self.sess.pd + m.base) as usize);
        self.s_slot.truncate((self.sess.pd + m.base) as usize);
    }

    /// Start a call session: clears the active session's parameter map and evidence tables.
    /// Variables allocated by earlier sessions stay (dense ids); the session map is the only live
    /// entry point.
    pub fn session_begin(self: &mut Self) {
        self.s_pd.truncate(self.sess.pd as usize);
        self.s_slot.truncate(self.sess.pd as usize);
        self.bounds.truncate(self.sess.bounds as usize);
        self.cconflicts.truncate(self.sess.cconflicts as usize);
    }

    /// Open a session above the active one; returns the enclosing session's mark for
    /// `session_close`. The enclosing session's slots, evidence and conflicts stay untouched.
    pub fn session_open(self: &mut Self) SessionMark {
        let outer = self.sess;
        self.sess = SessionMark {
            pd: self.s_pd.len() as u32,
            bounds: self.bounds.len() as u32,
            cconflicts: self.cconflicts.len() as u32,
            type_conflicts: self.type_conflicts.len() as u32,
        };
        return outer;
    }

    /// Close the session opened by `session_open` and make `outer` active again.
    pub fn session_close(self: &mut Self, outer: &SessionMark) {
        self.s_pd.truncate(self.sess.pd as usize);
        self.s_slot.truncate(self.sess.pd as usize);
        self.bounds.truncate(self.sess.bounds as usize);
        self.cconflicts.truncate(self.sess.cconflicts as usize);
        self.type_conflicts.truncate(self.sess.type_conflicts as usize);
        self.sess = *outer;
    }

    /// Map one generic parameter declaration to a fresh variable; returns its session slot.
    pub fn map_param(self: &mut Self, d: DefId, is_const: bool) u32 {
        let slot = self.s_pd.len() as u32 - self.sess.pd;
        self.s_pd.push(d);
        if is_const {
            self.s_slot.push(it_cvar(self.cvar_new()));
        } else {
            self.s_slot.push(it_var(self.var_new()));
        }
        return slot;
    }

    /// The session slot mapped for generic parameter `d`, or -1. Linear over the active session.
    pub const fn slot_of(self: &Self, d: DefId) i32 {
        for i in self.sess.pd as usize..self.s_pd.len() {
            if self.s_pd[i].module == d.module && self.s_pd[i].node == d.node {
                return (i - self.sess.pd as usize) as i32;
            }
        }
        return -1;
    }

    // The slot's solver term.
    const fn slot_ty(self: &Self, slot: u32) InferTy {
        return self.s_slot[(self.sess.pd + slot) as usize];
    }

    // Const evidence for const-variable term `t`. TYPE_GENERIC covers a symbolic reference to another
    // const parameter: the binding propagates the reference.
    fn s_const_ev(self: &mut Self, t: InferTy, ty: TypeId) {
        let k = unsafe (&*self.ast).type_at(ty).kind;
        if k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR || k == TypeKind::TYPE_GENERIC {
            let _ = self.cbind(it_cvar_id(t), ty);
        }
    }

    /// Explicit evidence (turbofish): binds the slot exactly. First explicit binding wins; the
    /// argument-compatibility pass reports any later disagreement.
    pub fn s_explicit(self: &mut Self, slot: u32, ty: TypeId) {
        let t = self.slot_ty(slot);
        if it_is_cvar(t) {
            self.s_const_ev(t, ty);
            return;
        }
        let v = it_payload(t);
        if self.v_binding[v as usize] == IT_UNBOUND {
            self.bind(v, ty);
        }
    }

    /// Nested (invariant) evidence: bind-if-unbound. A later disagreeing nested use keeps the first
    /// binding; the argument-compatibility pass reports the mismatch at its own position.
    pub fn s_eq(self: &mut Self, slot: u32, ty: TypeId, node: NodeId) {
        let t = self.slot_ty(slot);
        if it_is_cvar(t) {
            self.s_const_ev(t, ty);
            return;
        }
        let v = it_payload(t);
        self.bounds.push(BoundRec { var: v, ty: ty, node: node, eq: true });
        if self.v_binding[v as usize] == IT_UNBOUND {
            self.bind(v, ty);
        }
    }

    /// Top-level directional evidence: the argument value flows into the parameter, so a safe
    /// conversion is allowed. Recorded; joined at resolve time.
    pub fn s_lb(self: &mut Self, slot: u32, ty: TypeId, node: NodeId) {
        let t = self.slot_ty(slot);
        if it_is_cvar(t) {
            self.s_const_ev(t, ty);
            return;
        }
        self.bounds.push(BoundRec { var: it_payload(t), ty: ty, node: node, eq: false });
    }

    /// Exact const-value evidence for a slot (the array-length walk counts elements directly).
    pub fn s_cval(self: &mut Self, slot: u32, v: i64) {
        let t = self.slot_ty(slot);
        if it_is_cvar(t) {
            let cv = unsafe (&mut *self.ast).const_value(v);
            let _ = self.cbind(it_cvar_id(t), cv);
        }
    }

    /// Resolve one session slot to a published TypeId. An existing exact binding wins. Directional
    /// bounds resolve only when one unique bound absorbs every use. Incomparable bounds stay
    /// unresolved so source order cannot select a type.
    pub fn s_resolve(self: &mut Self, slot: u32, conv: fn(*mut Ast, TypeId, TypeId) bool) TypeId {
        let t = self.slot_ty(slot);
        if it_is_cvar(t) {
            let c = it_cvar_id(t);
            if !self.c_bound[c as usize] {
                return TYPE_NONE;
            }
            return self.c_ty[c as usize];
        }
        let head = self.resolve(t);
        if it_tag(head) == IT_TAG_PUB {
            return it_payload(head);
        }
        let v = it_payload(head);
        // Join the directional bounds: the unique bound every other bound converts to.
        let mut best = TYPE_NONE;
        for i in self.sess.bounds as usize..self.bounds.len() {
            let bnd = self.bounds[i];
            if bnd.eq || bnd.var != v || bnd.ty == TYPE_NONE {
                continue;
            }
            if best == TYPE_NONE {
                best = bnd.ty;
            } else if best != bnd.ty {
                if conv(self.ast, best, bnd.ty) && !conv(self.ast, bnd.ty, best) {
                    best = bnd.ty;
                } else if !conv(self.ast, bnd.ty, best) {
                    self.type_conflicts.push(TypeConflict { first: best, later: bnd.ty });
                    best = TYPE_NONE;
                    break;
                }
            }
        }
        if best != TYPE_NONE {
            // The candidate must absorb every bound (a maximal element seen late can miss earlier
            // incomparable entries).
            for i in self.sess.bounds as usize..self.bounds.len() {
                let bnd = self.bounds[i];
                if bnd.eq || bnd.var != v || bnd.ty == TYPE_NONE {
                    continue;
                }
                if bnd.ty != best && !conv(self.ast, bnd.ty, best) {
                    best = TYPE_NONE;
                    break;
                }
            }
        }
        if best != TYPE_NONE {
            self.bind(v, best);
        }
        return best;
    }
}
