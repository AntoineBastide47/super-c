// Body-local inference state and the read-only package boundary.
// InferenceContext owns the mutable walk state one body's check may touch plus the solver core:
// inference variables, union-find with a rollback log, body-local compound types, occurs checks,
// and the per-call generic-argument session. PackageTypeDb owns the read-only declaration and type
// lookup a body job is allowed. TypeChecker composes both and keeps the current algorithms behind
// its existing methods as adapters.
import ast::ast as *;
import module::loader as loader;

// Tag in the top two bits; the payload never exceeds 30 bits (TypeIds and body-local ids are dense).
//   00 Published(TypeId)   an interned type in the current module's pool
//   01 Var(InferVarId)     a type inference variable
//   10 Local(LocalTypeId)  a body-local compound term that contains a variable
//   11 special: payload 0 = Error; payload >= 1 = ConstVar(payload - 1)
// Error is distinct from an unbound variable: an unbound variable is unresolved input, Error is a
// recovered diagnostic state that must not satisfy a bound or select a candidate.
/// A tagged inference-time type: a published TypeId, a variable, a body-local term, Error, or a
/// const variable (see the IT_TAG_* tags and the it_* constructors).
pub type InferTy = u32;
pub const IT_TAG_PUB: u32 = 0;
pub const IT_TAG_VAR: u32 = 1;
pub const IT_TAG_LOCAL: u32 = 2;
pub const IT_ERROR: InferTy = 3u32 << 30;
pub const IT_UNBOUND: u32 = 0xFFFFFFFF; // binding-slot sentinel, never a valid InferTy

/// The InferTy of an interned type of the current module.
pub const fn it_pub(t: TypeId) InferTy {
    return t;
}
/// The InferTy of inference variable `v`.
pub const fn it_var(v: u32) InferTy {
    return 1u32 << 30 | v;
}
/// The InferTy of body-local compound term `l`.
pub const fn it_local(l: u32) InferTy {
    return 2u32 << 30 | l;
}
/// The InferTy of const variable `c`.
pub const fn it_cvar(c: u32) InferTy {
    return 3u32 << 30 | c + 1;
}
/// The IT_TAG_* tag of `t` (3 for Error and const variables).
pub const fn it_tag(t: InferTy) u32 {
    return t >> 30;
}
/// The 30-bit payload of `t`: TypeId, variable, local, or const-variable id + 1.
pub const fn it_payload(t: InferTy) u32 {
    return t & 0x3FFFFFFF;
}
/// True for a const variable (tag 3 with a nonzero payload).
pub const fn it_is_cvar(t: InferTy) bool {
    return it_tag(t) == 3 && it_payload(t) >= 1;
}
/// The const-variable id of `t`; `it_is_cvar(t)` must hold.
pub const fn it_cvar_id(t: InferTy) u32 {
    return it_payload(t) - 1;
}

// Rollback log cell kinds.
const LK_PARENT: u8 = 0;
const LK_SIZE: u8 = 1;
const LK_BINDING: u8 = 2;
const LK_CBIND: u8 = 3;

struct LogEnt {
    pub kind: u8,
    pub idx: u32,
    pub old: u64,
}

/// A probe mark: a solver snapshot plus the session-map watermark, so a nested candidate probe can
/// map its own parameters and be rolled back without disturbing the enclosing call session.
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
    pub nlocals: u32,
    pub nlargs: u32,
    pub nbounds: u32,
    pub nconflicts: u32,
    pub ntype_conflicts: u32,
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
/// resets the function-scoped fields per body exactly as the flat TypeChecker fields were reset.
/// No pointer into this state is published: results land in the Ast side tables (the adapters'
/// contract) until the solution-application phase replaces them.
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

extend InferenceContext as Free {
    pub fn free(self: &mut Self) {
        self.sv.free();
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
            return unsafe &mut self.package.modules[m as usize].ast;
        }
        return self.ast;
    }

    /// Module `m`'s source text, for span rendering.
    pub const fn mod_src(self: &Self, m: ModuleId) str {
        if self.package != null && m != self.cur_module() {
            return unsafe self.package.modules[m as usize].source.as_str();
        }
        return self.source;
    }

    /// Number of modules in the package; 0 without one.
    pub const fn pkg_count(self: &Self) usize {
        if self.package == null {
            return 0;
        }
        return unsafe self.package.modules.len();
    }
}

// A body-local compound term that contains at least one variable. Var-free terms use published
// `TypeId` values directly and never enter this arena.
struct LocalRec {
    pub kind: TypeKind,
    pub qual: u8,
    pub module: ModuleId,
    pub a: u32, // elem InferTy (ptr/ref/slice/array) or decl NodeId (instance)
    pub b: u32, // array: length InferTy; instance: args start in lt_args
    pub n: u32, // instance: argument count
}

/// Solver budgets; exceeding one is an inference failure, not a crash.
pub const SOLVER_MAX_PAIRS: u32 = 4096; // structural pairs per unify call (type nesting budget)
pub const SOLVER_MAX_RESOLVE: u32 = 256; // binding-chain hops before declaring a solver bug

/// The inference solver core: dense variable arrays, union-find by size, a rollback log of changed
/// cells, a body-local compound-term arena, and the per-call generic-argument session. All storage
/// is reused across bodies through clear(); nothing here is published.
pub struct Solver {
    pub ast: *mut Ast, // the module under check; set per checker, read-only pool access
    v_parent: Vector<u32>,
    v_size: Vector<u32>,
    v_binding: Vector<u32>, // InferTy or IT_UNBOUND
    c_ty: Vector<u32>, // TYPE_CONST or TYPE_CONST_EXPR TypeId; canonical interning makes id equality value equality
    c_bound: Vector<bool>,
    c_origin: Vector<u32>,
    locals: Vector<LocalRec>,
    lt_args: Vector<u32>, // InferTy argument pool for local instances
    log: Vector<LogEnt>,
    bounds: Vector<BoundRec>,
    pub cconflicts: Vector<CConflict>,
    pub type_conflicts: Vector<TypeConflict>,
    s_pd: Vector<DefId>,
    s_slot: Vector<u32>, // it_var(..) or it_cvar(..)
    st_a: Vector<u32>,
    st_b: Vector<u32>,
    oc: Vector<u32>,
}

extend Solver {
    /// An empty solver bound to no Ast.
    pub fn new() Solver {
        return Solver {
            ast: null,
            v_parent: Vector::<u32>::new(),
            v_size: Vector::<u32>::new(),
            v_binding: Vector::<u32>::new(),
            c_ty: Vector::<u32>::new(),
            c_bound: Vector::<bool>::new(),
            c_origin: Vector::<u32>::new(),
            locals: Vector::<LocalRec>::new(),
            lt_args: Vector::<u32>::new(),
            log: Vector::<LogEnt>::new(),
            bounds: Vector::<BoundRec>::new(),
            cconflicts: Vector::<CConflict>::new(),
            type_conflicts: Vector::<TypeConflict>::new(),
            s_pd: Vector::<DefId>::new(),
            s_slot: Vector::<u32>::new(),
            st_a: Vector::<u32>::new(),
            st_b: Vector::<u32>::new(),
            oc: Vector::<u32>::new(),
        };
    }

    /// A fresh unbound inference variable (its own union-find root).
    pub fn var_new(self: &mut Self) u32 {
        let v = self.v_parent.len() as u32;
        self.v_parent.push(v);
        self.v_size.push(1);
        self.v_binding.push(IT_UNBOUND);
        return v;
    }

    /// A fresh unbound const variable; `origin` is the node it was created for (diagnostics).
    pub fn cvar_new(self: &mut Self, origin: u32) u32 {
        let c = self.c_ty.len() as u32;
        self.c_ty.push(0);
        self.c_bound.push(false);
        self.c_origin.push(origin);
        return c;
    }

    /// Union-find root. No path compression: union by size keeps the tree depth logarithmic, and an
    /// uncompressed find never needs a log entry, so snapshot probes stay cheap to roll back.
    pub const fn find(self: &Self, v: u32) u32 {
        let mut r = v;
        let mut hops: u32 = 0;
        while self.v_parent[r as usize] != r {
            r = self.v_parent[r as usize];
            hops += 1;
            assert(hops < SOLVER_MAX_RESOLVE, "union-find parent cycle");
        }
        return r;
    }

    /// Resolve a term to its current head: follow variable roots and their bindings. An unbound
    /// variable resolves to its root var handle.
    pub const fn resolve(self: &Self, t: InferTy) InferTy {
        let mut cur = t;
        let mut hops: u32 = 0;
        while it_tag(cur) == IT_TAG_VAR {
            let r = self.find(it_payload(cur));
            let b = self.v_binding[r as usize];
            if b == IT_UNBOUND {
                return it_var(r);
            }
            cur = b;
            hops += 1;
            assert(hops < SOLVER_MAX_RESOLVE, "binding chain cycle");
        }
        return cur;
    }

    /// The current lengths of every solver table; `rollback` restores them.
    pub const fn snapshot(self: &Self) Snapshot {
        return Snapshot {
            log: self.log.len() as u32,
            nvars: self.v_parent.len() as u32,
            ncvars: self.c_ty.len() as u32,
            nlocals: self.locals.len() as u32,
            nlargs: self.lt_args.len() as u32,
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
            if e.kind == LK_PARENT {
                self.v_parent.set(e.idx as usize, e.old as u32);
            } else if e.kind == LK_SIZE {
                self.v_size.set(e.idx as usize, e.old as u32);
            } else if e.kind == LK_BINDING {
                self.v_binding.set(e.idx as usize, e.old as u32);
            } else {
                // LK_CBIND packs the old TypeId into the low bits and the old bound flag into bit 63.
                self.c_bound.set(e.idx as usize, (e.old >> 63 & 1) == 1);
                self.c_ty.set(e.idx as usize, e.old as u32);
            }
        }
        self.log.truncate(s.log as usize);
        self.v_parent.truncate(s.nvars as usize);
        self.v_size.truncate(s.nvars as usize);
        self.v_binding.truncate(s.nvars as usize);
        self.c_ty.truncate(s.ncvars as usize);
        self.c_bound.truncate(s.ncvars as usize);
        self.c_origin.truncate(s.ncvars as usize);
        self.locals.truncate(s.nlocals as usize);
        self.lt_args.truncate(s.nlargs as usize);
        self.bounds.truncate(s.nbounds as usize);
        self.cconflicts.truncate(s.nconflicts as usize);
        self.type_conflicts.truncate(s.ntype_conflicts as usize);
    }

    fn log_parent(self: &mut Self, v: u32) {
        self.log.push(LogEnt { kind: LK_PARENT, idx: v, old: self.v_parent[v as usize] });
    }
    fn log_size(self: &mut Self, v: u32) {
        self.log.push(LogEnt { kind: LK_SIZE, idx: v, old: self.v_size[v as usize] });
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

    /// A body-local wrapper term (reference, pointer, array, ..) of `kind` around `elem`.
    pub fn local_elem(self: &mut Self, kind: TypeKind, qual: u8, elem: InferTy) InferTy {
        let l = self.locals.len() as u32;
        self.locals.push(LocalRec { kind: kind, qual: qual, module: 0, a: elem, b: 0, n: 0 });
        return it_local(l);
    }

    /// A body-local generic instance term of decl `(m, decl)` over `n` InferTy args.
    /// Safety: `args` must point at `n` readable entries.
    pub fn local_inst(self: &mut Self, m: ModuleId, decl: NodeId, args: *const u32, n: u32) InferTy {
        let start = self.lt_args.len() as u32;
        for i in 0..n {
            self.lt_args.push(unsafe args[i as usize]);
        }
        let l = self.locals.len() as u32;
        self.locals.push(LocalRec { kind: TypeKind::TYPE_INSTANCE, qual: 0, module: m, a: decl, b: start, n: n });
        return it_local(l);
    }

    /// True when variable root `r` occurs inside term `t`. Iterative; used before binding a
    /// variable to a compound term.
    pub fn occurs(self: &mut Self, r: u32, t: InferTy) bool {
        self.oc.clear();
        self.oc.push(t);
        let mut steps: u32 = 0;
        while self.oc.len() > 0 {
            steps += 1;
            if steps > SOLVER_MAX_PAIRS {
                // Budget hit: treat as occurring (refuses the bind, no cycle risk).
                return true;
            }
            let cur = self.resolve(*self.oc.at(self.oc.len() - 1));
            let _ = self.oc.pop();
            if it_tag(cur) == IT_TAG_VAR {
                if self.find(it_payload(cur)) == r {
                    return true;
                }
            } else if it_tag(cur) == IT_TAG_LOCAL {
                let rec = self.locals[it_payload(cur) as usize];
                if rec.kind == TypeKind::TYPE_INSTANCE {
                    for i in 0..rec.n {
                        self.oc.push(self.lt_args[(rec.b + i) as usize]);
                    }
                } else {
                    self.oc.push(rec.a);
                    if rec.kind == TypeKind::TYPE_ARRAY {
                        self.oc.push(rec.b);
                    }
                }
            }
        }
        return false;
    }

    /// Bind root variable `r` to term `t` (not a variable). Occurs-checked; logged.
    pub fn bind(self: &mut Self, r: u32, t: InferTy) bool {
        assert(self.v_binding[r as usize] == IT_UNBOUND, "bind on a bound root");
        if it_tag(t) == IT_TAG_LOCAL && self.occurs(r, t) {
            return false;
        }
        self.log_binding(r);
        self.v_binding.set(r as usize, t);
        return true;
    }

    // Join two variable classes; both must be roots with no binding (`unify`'s resolve step
    // guarantees that). Union by size.
    fn union_roots(self: &mut Self, ra: u32, rb: u32) {
        if ra == rb {
            return;
        }
        assert(self.v_binding[ra as usize] == IT_UNBOUND, "union of a bound root");
        assert(self.v_binding[rb as usize] == IT_UNBOUND, "union of a bound root");
        let mut win = ra;
        let mut lose = rb;
        if self.v_size[rb as usize] > self.v_size[ra as usize] {
            win = rb;
            lose = ra;
        }
        self.log_parent(lose);
        self.log_size(win);
        self.v_parent.set(lose as usize, win);
        self.v_size.set(win as usize, self.v_size[win as usize] + self.v_size[lose as usize]);
    }

    /// Join two variables through full unification (bindings included).
    pub fn union_vars(self: &mut Self, a: u32, b: u32) bool {
        return self.unify(it_var(a), it_var(b));
    }

    /// Structural unification over an iterative pair stack. Every pair must agree exactly; the
    /// caller supplies conversion tolerance through directional bounds, never here.
    pub fn unify(self: &mut Self, a0: InferTy, b0: InferTy) bool {
        self.st_a.clear();
        self.st_b.clear();
        self.st_a.push(a0);
        self.st_b.push(b0);
        let mut steps: u32 = 0;
        while self.st_a.len() > 0 {
            steps += 1;
            if steps > SOLVER_MAX_PAIRS {
                return false;
            }
            let a = self.resolve(*self.st_a.at(self.st_a.len() - 1));
            let b = self.resolve(*self.st_b.at(self.st_b.len() - 1));
            let _ = self.st_a.pop();
            let _ = self.st_b.pop();
            if a == b {
                continue;
            }
            if a == IT_ERROR || b == IT_ERROR {
                // An error term unifies with anything and proves nothing.
                continue;
            }
            let ta = it_tag(a);
            let tb = it_tag(b);
            if ta == IT_TAG_VAR && tb == IT_TAG_VAR {
                self.union_roots(it_payload(a), it_payload(b));
                continue;
            }
            if ta == IT_TAG_VAR {
                if !self.bind(it_payload(a), b) {
                    return false;
                }
                continue;
            }
            if tb == IT_TAG_VAR {
                if !self.bind(it_payload(b), a) {
                    return false;
                }
                continue;
            }
            if it_is_cvar(a) || it_is_cvar(b) {
                if !self.unify_cvar(a, b) {
                    return false;
                }
                continue;
            }
            // Published vs published: interning makes structural equality identity, so unequal
            // ids are unequal types.
            if ta == IT_TAG_PUB && tb == IT_TAG_PUB {
                return false;
            }
            // At least one side is a local compound: decompose.
            if !self.decompose(a, b) {
                return false;
            }
        }
        return true;
    }

    fn unify_cvar(self: &mut Self, a: InferTy, b: InferTy) bool {
        let mut cv = a;
        let mut other = b;
        if !it_is_cvar(cv) {
            cv = b;
            other = a;
        }
        let c = it_cvar_id(cv);
        if it_is_cvar(other) {
            let d = it_cvar_id(other);
            if c == d {
                return true;
            }
            if self.c_bound[c as usize] && self.c_bound[d as usize] {
                return self.c_ty[c as usize] == self.c_ty[d as usize];
            }
            // Copy a known value across; a full const union-find waits for the const solver phase.
            if self.c_bound[c as usize] {
                return self.cbind(d, self.c_ty[c as usize]);
            }
            if self.c_bound[d as usize] {
                return self.cbind(c, self.c_ty[d as usize]);
            }
            return true;
        }
        if it_tag(other) != IT_TAG_PUB {
            return false;
        }
        let y = unsafe (&*self.ast).type_at(it_payload(other));
        if y.kind != TypeKind::TYPE_CONST && y.kind != TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        return self.cbind(c, it_payload(other));
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

    fn decompose(self: &mut Self, a: InferTy, b: InferTy) bool {
        // Normalize: `a` local, `b` local or published.
        let mut l = a;
        let mut o = b;
        if it_tag(l) != IT_TAG_LOCAL {
            l = b;
            o = a;
        }
        let lr = self.locals[it_payload(l) as usize];
        if it_tag(o) == IT_TAG_LOCAL {
            let orr = self.locals[it_payload(o) as usize];
            if lr.kind != orr.kind || lr.qual != orr.qual {
                return false;
            }
            if lr.kind == TypeKind::TYPE_INSTANCE {
                if lr.module != orr.module || lr.a != orr.a || lr.n != orr.n {
                    return false;
                }
                for i in 0..lr.n {
                    self.st_a.push(self.lt_args[(lr.b + i) as usize]);
                    self.st_b.push(self.lt_args[(orr.b + i) as usize]);
                }
                return true;
            }
            self.st_a.push(lr.a);
            self.st_b.push(orr.a);
            if lr.kind == TypeKind::TYPE_ARRAY {
                self.st_a.push(lr.b);
                self.st_b.push(orr.b);
            }
            return true;
        }
        if it_tag(o) != IT_TAG_PUB {
            return false;
        }
        let y = *unsafe (&*self.ast).type_at(it_payload(o));
        if y.kind != lr.kind || y.qualifier != lr.qual {
            return false;
        }
        if lr.kind == TypeKind::TYPE_INSTANCE {
            let inst = *unsafe (&*self.ast).instance(y.as_data.inst);
            if inst.module != lr.module || inst.decl != lr.a || inst.n as u32 != lr.n {
                return false;
            }
            for i in 0..lr.n {
                self.st_a.push(self.lt_args[(lr.b + i) as usize]);
                self.st_b.push(it_pub(unsafe inst.args[i as usize]));
            }
            return true;
        }
        if lr.kind == TypeKind::TYPE_ARRAY {
            self.st_a.push(lr.a);
            self.st_b.push(it_pub(y.as_data.arr.elem));
            self.st_a.push(lr.b);
            self.st_b.push(it_pub(unsafe (&mut *self.ast).const_value(y.as_data.arr.len)));
            return true;
        }
        if lr.kind == TypeKind::TYPE_POINTER || lr.kind == TypeKind::TYPE_REFERENCE || lr.kind == TypeKind::TYPE_SLICE {
            self.st_a.push(lr.a);
            self.st_b.push(it_pub(y.as_data.elem));
            return true;
        }
        return false;
    }

    /// FNV over every mutable solver cell: the rollback oracle. Two states with equal hashes after
    /// a snapshot/rollback pair demonstrate that every changed cell and mark was restored.
    pub fn state_hash(self: &Self) u64 {
        let mut h: u64 = 1469598103934665603u64;
        for i in 0..self.v_parent.len() {
            h = fnv(h, self.v_parent[i]);
            h = fnv(h, self.v_size[i]);
            h = fnv(h, self.v_binding[i]);
        }
        for i in 0..self.c_ty.len() {
            h = fnv(h, self.c_ty[i]);
            h = fnv(h, if_u64(self.c_bound[i], 1, 0));
        }
        for i in 0..self.locals.len() {
            let r = self.locals[i];
            h = fnv(h, r.kind as u64);
            h = fnv(h, r.a);
            h = fnv(h, r.b);
            h = fnv(h, r.n);
        }
        for i in 0..self.lt_args.len() {
            h = fnv(h, self.lt_args[i]);
        }
        h = fnv(h, self.log.len() as u64);
        h = fnv(h, self.bounds.len() as u64);
        h = fnv(h, self.cconflicts.len() as u64);
        return h;
    }

    /// Begin a nested candidate probe: parameters mapped after this mark stack on top of the
    /// enclosing session, and probe_end removes every trace of the probe's work.
    pub fn probe_begin(self: &mut Self) ProbeMark {
        return ProbeMark { snap: self.snapshot(), base: self.s_pd.len() as u32 };
    }

    /// End the probe begun at `m`: every binding and parameter slot it created is discarded.
    pub fn probe_end(self: &mut Self, m: &ProbeMark) {
        self.rollback(&m.snap);
        self.s_pd.truncate(m.base as usize);
        self.s_slot.truncate(m.base as usize);
    }

    /// Start a call session: clears the parameter map and the evidence tables. Variables allocated
    /// by earlier sessions stay (dense ids); the session map is the only live entry point.
    pub fn session_begin(self: &mut Self) {
        self.s_pd.clear();
        self.s_slot.clear();
        self.bounds.clear();
        self.cconflicts.clear();
    }

    /// Map one generic parameter declaration to a fresh variable; returns its session slot.
    pub fn map_param(self: &mut Self, d: DefId, is_const: bool, origin: u32) u32 {
        let slot = self.s_pd.len() as u32;
        self.s_pd.push(d);
        if is_const {
            self.s_slot.push(it_cvar(self.cvar_new(origin)));
        } else {
            self.s_slot.push(it_var(self.var_new()));
        }
        return slot;
    }

    /// The session slot mapped for generic parameter `d`, or -1. Linear over the active session.
    pub const fn slot_of(self: &Self, d: DefId) i32 {
        for i in 0..self.s_pd.len() {
            if self.s_pd[i].module == d.module && self.s_pd[i].node == d.node {
                return i as i32;
            }
        }
        return -1;
    }

    /// Explicit evidence (turbofish): binds the slot exactly. First explicit binding wins; the
    /// argument-compatibility pass reports any later disagreement, exactly as before.
    pub fn s_explicit(self: &mut Self, slot: u32, ty: TypeId) {
        let t = self.s_slot[slot as usize];
        if it_is_cvar(t) {
            let k = unsafe (&*self.ast).type_at(ty).kind;
            // TYPE_GENERIC covers a symbolic reference to another const parameter: the binding
            // propagates the reference exactly as the pre-rewrite array did.
            if k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR || k == TypeKind::TYPE_GENERIC {
                let _ = self.cbind(it_cvar_id(t), ty);
            }
            return;
        }
        let r = self.find(it_payload(t));
        if self.v_binding[r as usize] == IT_UNBOUND {
            let _ = self.bind(r, it_pub(ty));
        }
    }

    /// Nested (invariant) evidence: bind-if-unbound. A later disagreeing nested use keeps the first
    /// binding; the argument-compatibility pass reports the mismatch at its own position.
    pub fn s_eq(self: &mut Self, slot: u32, ty: TypeId, node: NodeId) {
        let t = self.s_slot[slot as usize];
        if it_is_cvar(t) {
            let k = unsafe (&*self.ast).type_at(ty).kind;
            // TYPE_GENERIC covers a symbolic reference to another const parameter: the binding
            // propagates the reference exactly as the pre-rewrite array did.
            if k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR || k == TypeKind::TYPE_GENERIC {
                let _ = self.cbind(it_cvar_id(t), ty);
            }
            return;
        }
        self.bounds.push(BoundRec { var: it_payload(t), ty: ty, node: node, eq: true });
        let r = self.find(it_payload(t));
        if self.v_binding[r as usize] == IT_UNBOUND {
            let _ = self.bind(r, it_pub(ty));
        }
    }

    /// Top-level directional evidence: the argument value flows into the parameter, so a safe
    /// conversion is allowed. Recorded; joined at resolve time.
    pub fn s_lb(self: &mut Self, slot: u32, ty: TypeId, node: NodeId) {
        let t = self.s_slot[slot as usize];
        if it_is_cvar(t) {
            let k = unsafe (&*self.ast).type_at(ty).kind;
            // TYPE_GENERIC covers a symbolic reference to another const parameter: the binding
            // propagates the reference exactly as the pre-rewrite array did.
            if k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR || k == TypeKind::TYPE_GENERIC {
                let _ = self.cbind(it_cvar_id(t), ty);
            }
            return;
        }
        self.bounds.push(BoundRec { var: it_payload(t), ty: ty, node: node, eq: false });
    }

    /// Exact const-value evidence for a slot (the array-length walk counts elements directly).
    pub fn s_cval(self: &mut Self, slot: u32, v: i64) {
        let t = self.s_slot[slot as usize];
        if it_is_cvar(t) {
            let cv = unsafe (&mut *self.ast).const_value(v);
            let _ = self.cbind(it_cvar_id(t), cv);
        }
    }

    /// Resolve one session slot to a published TypeId. An existing exact binding wins. Directional
    /// bounds resolve only when one unique bound absorbs every use. Incomparable bounds stay
    /// unresolved so source order cannot select a type.
    pub fn s_resolve(self: &mut Self, slot: u32, conv: fn(*mut Ast, TypeId, TypeId) bool) TypeId {
        let t = self.s_slot[slot as usize];
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
        if it_tag(head) != IT_TAG_VAR {
            // A local compound cannot publish in the adapter phase.
            return TYPE_NONE;
        }
        let r = it_payload(head);
        // Join the directional bounds: the unique bound every other bound converts to.
        let mut best = TYPE_NONE;
        for i in 0..self.bounds.len() {
            let bnd = self.bounds[i];
            if bnd.eq || self.find(bnd.var) != r || bnd.ty == TYPE_NONE {
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
            for i in 0..self.bounds.len() {
                let bnd = self.bounds[i];
                if bnd.eq || self.find(bnd.var) != r || bnd.ty == TYPE_NONE {
                    continue;
                }
                if bnd.ty != best && !conv(self.ast, bnd.ty, best) {
                    best = TYPE_NONE;
                    break;
                }
            }
        }
        if best != TYPE_NONE {
            let _ = self.bind(r, it_pub(best));
        }
        return best;
    }
}

extend Solver as Free {
    pub fn free(self: &mut Self) {
        self.v_parent.free();
        self.v_size.free();
        self.v_binding.free();
        self.c_ty.free();
        self.c_bound.free();
        self.c_origin.free();
        self.locals.free();
        self.lt_args.free();
        self.log.free();
        self.bounds.free();
        self.cconflicts.free();
        self.type_conflicts.free();
        self.s_pd.free();
        self.s_slot.free();
        self.st_a.free();
        self.st_b.free();
        self.oc.free();
    }
}

const fn if_u64(c: bool, a: u64, b: u64) u64 {
    if c {
        return a;
    }
    return b;
}

const fn fnv(h: u64, x: u64) u64 {
    return (h ^ x) * 1099511628211u64;
}
