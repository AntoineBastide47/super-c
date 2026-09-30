// The instance and reachability graph: discovers every concrete generic instantiation by walking
// lowered Core IR bodies from concrete roots, expanding generic bodies under substitution frames.
// Keys are package-stable: a declaration DefId plus the final package id of every concrete
// argument (the substituted type, interned into the package table), so records from different
// modules compare by integer.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import ir::lower as irl;
import ir::layout as lay;
import lexer::token as tok;

/// Record kinds.
pub const IG_AGG: u8 = 0; // generic struct/enum instantiation
/// Instance record kinds (InstRec.kind).
pub const IG_FN: u8 = 1; // generic function instantiation
pub const IG_METHOD: u8 = 2; // method demanded on a generic-aggregate instance

/// The absent record index.
pub const IG_NONE: u32 = 0xFFFFFFFF;

// Deepest argument nesting (element types and instance arguments) a record is expanded with. A
// generic that reaches itself with a growing type argument discovers ever deeper records; past the
// bound a record stays unexpanded, and the emitter reports the instantiation that needs it.
const ARG_NEST_MAX: u32 = 256;

/// One instance argument: the final id of its (substituted) type plus, for const-generic values,
/// the folded integer, its two's complement bits and integer type (what lets compound const-exprs
/// like `{BITS*2}` evaluate under a frame).
pub struct ArgKey {
    pub val: i64,
    pub ty: TypeId,
    pub has_val: bool,
    pub bt: BuiltinType,
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
    pub meas: Vector<u32>, // statement ids assigning a `sizeof`/`alignof`
}

/// An array length an instance folds outside 0..=4294967295: a compile error the driver reports,
/// never an emitted type.
pub struct LenFault {
    pub module: ModuleId, // the module `span` indexes
    pub span: tok::Span, // the binding, field or expression whose type holds the length
    pub msg: String,
    /// The instantiated declaration (node NODE_NONE = a concrete type, no instance) and the site
    /// that demanded it (`site.end == 0`: not known).
    pub inst: DefId,
    pub site_module: ModuleId,
    pub site: tok::Span,
}

/// The package's closed set of generic instantiations, reached by walking every live body's
/// demands to a fixpoint; records are deduplicated by (kind, def, argument keys).
pub struct InstGraph {
    pub pkg: *const loader::Package,
    pub recs: Vector<InstRec>,
    pub keys: Vector<ArgKey>, // flat argument-key pool
    index: Vector<u32>, // open addressing over recs (hash lookup, exact compare)
    cursor: usize, // worklist: recs[cursor..] await expansion
    exts: Vector<ExtRow>, // every extend in the package with a resolved target declaration
    // Indexes over `exts`: expansion asks per call site and per aggregate record, so owner and
    // target lookups must not rescan the extend list.
    ext_of: Map<u64, u64>, // (module << 32 | fnode) -> owning extend node (rows of `exts` only)
    ext_head: Map<u64, u32>, // (target module << 32 | decl) -> its first `exts` row
    ext_next: Vector<u32>, // per `exts` row: the next row with the same target (IG_NONE = last)
    // Final ids already fully walked by note_type under an EMPTY frame: bodies name the same
    // interned types over and over, and a completed depth-0 walk covers every revisit.
    noted: Vector<bool>,
    // Demand cross product cursors: per demanded method declaration (and per interface default
    // per conforming extend), how many records of its target's instance group it has paired.
    // Groups only grow in record order, so a round pairs each declaration with the new records
    // alone and the insertion order equals a full re-pairing's (the earlier pairs exist).
    pair_cur: Map<u64, u64>,
    // The (interface default, conforming extend, instance) walks done (`walk_defaults`).
    dwalked: Set<u64>,
    nest: Map<u64, u64>, // nest_depth's memo, keyed like the type tables (module << 32 | type)
    /// One lowering per declaration, shared by every frame that walks it (lowering ignores the
    /// frame; only walking applies it). The emitter takes these bodies instead of re-lowering.
    /// `kept_ix` maps (module << 32 | node) to a `kept` index; 0xFFFFFFFFFFFFFFFF = lowering failed.
    pub kept: Vector<irl::KeptBody>,
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
    pub rounds: u64, // worklist drains until the demand cross product added nothing
    pub overflow: bool, // budget exhausted; the report marks itself partial
    budget: u32,
    pub faults: Vector<LenFault>,
    // The message of a length fault a type walk found and its caller has not located yet.
    fault_msg: String,
    fault_hit: bool,
    // The record being expanded failed one of its const-generic steps: that step is the
    // instantiation's error, and the type walks report no finding of their own for it (a step
    // that overflows usually makes the whole expression overflow too).
    step_fault: bool,
    // Per record: what created it, to locate its demand site: ORG_BODY | a kept body index, ORG_MEMBER
    // | (module << 32 | member type node), or 0.
    origin: Vector<u64>,
    cur_org: u64, // the origin of records added now
    cur_rec: u32, // the record being expanded (IG_NONE = a root)
    // Per record: RF_* bits. A speculative record comes from signature propagation or the demand
    // cross product (or from expanding such a record) and may never be emitted, so its length
    // faults are not errors. A demand from a root or a demanded record promotes it, and a promoted
    // record that was already walked walks again, demanded.
    flags: Vector<u8>,
    in_spec: bool, // records added now are speculative
    redo: Vector<u32>, // promoted records to walk again
    // `check_ty`'s finding: the aggregate member holding the length (decl node NODE_NONE = the
    // checked type itself holds it).
    chk_decl: DefId,
    chk_span: tok::Span,
}

const ORG_BODY: u64 = 1u64 << 63;
const ORG_MEMBER: u64 = 1u64 << 62;
const RF_SPEC: u8 = 1;
const RF_WALKED: u8 = 2;

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
            cursor: 0,
            exts: Vector::<ExtRow>::new(),
            ext_of: Map::<u64, u64>::new(),
            ext_head: Map::<u64, u32>::new(),
            ext_next: Vector::<u32>::new(),
            noted: Vector::<bool>::new(),
            pair_cur: Map::<u64, u64>::new(),
            dwalked: Set::<u64>::new(),
            nest: Map::<u64, u64>::new(),
            kept: Vector::<irl::KeptBody>::new(),
            kept_ix: Map::<u64, u64>::new(),
            argbuf: Vector::<ArgKey>::new(),
            low: irl::Lowerer::new(pkg, 0, NODE_NONE),
            wcache: Vector::<WalkCache>::new(),
            wt_seen: Map::<u64, u64>::new(),
            bodies: 0,
            rounds: 0,
            overflow: false,
            budget: 64000000,
            faults: Vector::<LenFault>::new(),
            fault_msg: String::new(),
            fault_hit: false,
            step_fault: false,
            origin: Vector::<u64>::new(),
            cur_org: 0,
            cur_rec: IG_NONE,
            flags: Vector::<u8>::new(),
            in_spec: false,
            redo: Vector::<u32>::new(),
            chk_decl: DefId { module: 0, node: NODE_NONE },
            chk_span: tok::Span { start: 0, end: 0 },
        };
    }

    /// Bytes the argument keys, records and index hold (SC_TYPE_STATS).
    pub const fn retained_bytes(self: &Self) u64 {
        return (self.keys.len() * sizeof(ArgKey) + self.recs.len() * sizeof(InstRec) + self.index.len() * 4) as u64;
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
    /// new. Hash + equality use the argument ids only (the value is derived data riding along for
    /// frame evaluation).
    pub fn add(self: &mut Self, kind: u8, def: DefId, fresh: &mut bool) u32 {
        let ts = unsafe TS_ON;
        let mut t0: u64 = 0;
        if ts {
            ts_add(TS_IGADD, 1);
            t0 = ts_now();
        }
        let mut h = skey_mix(skey_mix(0xcbf29ce484222325u64, kind), def.module);
        h = skey_mix(h, def.node);
        for i in 0..self.argbuf.len() {
            h = skey_mix(h, self.argbuf.at(i).ty);
        }
        if self.index.len() == 0 || (self.recs.len() + 1) * 4 >= self.index.len() * 3 {
            let mut cap: usize = 64;
            while cap < (self.recs.len() + 1) * 4 {
                cap = cap * 2;
            }
            let mut nix = Vector::<u32>::with_capacity(cap);
            for _ in 0..cap {
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
        }
        let mask = self.index.len() - 1;
        let mut i = h as usize & mask;
        let step = (h >> 32) as usize | 1;
        // An odd step visits every slot of the power-of-two table, and the load bound keeps one free.
        let mut probes: usize = 0;
        loop {
            assert(probes < self.index.len(), "the instance index keeps a free slot");
            probes += 1;
            let cur = self.index[i];
            if cur == IG_NONE {
                let start = self.keys.len() as u32;
                for k in 0..self.argbuf.len() {
                    self.keys.push(*self.argbuf.at(k));
                }
                let mut deep = false;
                let a = unsafe &*(&*self.pkg).module_ast_const(def.module);
                for k in 0..self.argbuf.len() {
                    deep = deep || self.nest_depth(a, self.argbuf.at(k).ty) > ARG_NEST_MAX;
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
                        expanded: deep,
                    },
                );
                self.origin.push(self.cur_org);
                self.flags.push(
                    if self.in_spec {
                        RF_SPEC;
                    } else {
                        0;
                    },
                );
                let id = self.recs.len() as u32 - 1;
                self.index.set(i, id);
                *fresh = true;
                if ts {
                    ts_add(TS_IGADD_NS, ts_now() - t0);
                }
                return id;
            }
            let r = self.recs.at(cur as usize);
            if r.hash == h && r.kind == kind && r.def.module == def.module && r.def.node == def.node && r.args_len as usize == self.argbuf.len() {
                let mut eq = true;
                for k in 0..r.args_len {
                    if self.keys.at((r.args_start + k) as usize).ty != self.argbuf.at(k as usize).ty {
                        eq = false;
                        break;
                    }
                }
                if eq {
                    let fl = self.flags[cur as usize];
                    if !self.in_spec && (fl & RF_SPEC) != 0 {
                        self.flags.set(cur as usize, fl & ~RF_SPEC);
                        if (fl & RF_WALKED) != 0 {
                            self.redo.push(cur);
                        }
                    }
                    *fresh = false;
                    if ts {
                        ts_add(TS_IGADD_HIT, 1);
                        ts_add(TS_IGADD_NS, ts_now() - t0);
                    }
                    return cur;
                }
            }
            i = i + step & mask;
        }
    }

    // The nesting depth of `t` through element types and instance arguments, capped at
    // ARG_NEST_MAX + 1 and memoized per type, so a type DAG costs one visit per distinct type.
    fn nest_depth(self: &mut Self, a: &Ast, t: TypeId) u32 {
        if t == TYPE_NONE {
            return 0;
        }
        let key = skey_mix(0, a.module as u64 << 32 | t as u64);
        switch self.nest.get(&key) {
            Some(v) => {
                return (*v) as u32;
            },
            None => {},
        };
        let y = *a.type_at(t);
        let mut d: u32 = 0;
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE {
            d = self.nest_depth(a, y.as_data.elem);
        } else if y.kind == TypeKind::TYPE_ARRAY {
            d = self.nest_depth(a, y.as_data.arr.elem);
        } else if y.kind == TypeKind::TYPE_INSTANCE || y.fn_sig() {
            let it = *a.instance(y.rec());
            for i in 0..it.n {
                d = d.max(self.nest_depth(a, unsafe it.args[i]));
            }
        }
        if d <= ARG_NEST_MAX {
            d += 1;
        }
        self.nest.insert(key, d);
        return d;
    }

    // The final id of `t` under `frame`: a generic parameter reads its bound argument, a const
    // expression its folded value, and every compound is rebuilt with substituted children and
    // interned into the package table (the graph runs serially, so the ids it appends are
    // deterministic). A shared reference's CONST qualifier (written `&'a T`) normalizes to NONE,
    // the checker-inserted form, so the two spellings of one borrow cannot split a record.
    fn subst_intern(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) TypeId {
        if t == TYPE_NONE || depth > 8 {
            return TYPE_NONE;
        }
        let y = *a.type_at(t);
        let g = self.g();
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl {
                    return frame.at(i).key.ty;
                }
            }
            return g.intern_g(y);
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let bound = self.const_expr_bound(a, &y, frame);
            if bound.ty != TYPE_NONE {
                return bound.ty;
            }
            return g.intern_clin_g(a.const_lin_at(y.as_data.inst));
        }
        return switch y.kind {
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => {
                let mut nt = y;
                nt.as_data.elem = self.subst_intern(a, y.as_data.elem, frame, depth + 1);
                if y.kind == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                    nt.qualifier = TypeQualifier::TYPE_QUAL_NONE as u8;
                }
                g.intern_g(nt);
            },
            TYPE_ARRAY => {
                let e = self.subst_intern(a, y.as_data.arr.elem, frame, depth + 1);
                let r9 = if y.arr_sym() {
                    g.intern_array_g(e, self.subst_intern(a, y.as_data.arr.len, frame, depth + 1));
                } else {
                    let mut nt = y;
                    nt.as_data.arr.elem = e;
                    g.intern_g(nt);
                };
                r9;
            },
            TYPE_FIELD_PROJECTION => {
                let mut nt = y;
                nt.as_data.proj.owner = self.subst_intern(a, y.as_data.proj.owner, frame, depth + 1);
                g.intern_g(nt);
            },
            TYPE_ASSOC => {
                let mut it = *a.instance(y.as_data.inst);
                for i in 0..it.n {
                    unsafe it.args[i as usize] = self.subst_intern(a, unsafe it.args[i as usize], frame, depth + 1);
                }
                let r9 = if a.type_concrete(it.args[0]) {
                    self.assoc_norm_g(&it, depth + 1);
                } else {
                    TYPE_NONE;
                };
                pick(r9 != TYPE_NONE, r9, g.intern_assoc_g(it.module, it.decl, &it.args[0], it.n));
            },
            TYPE_INSTANCE | TYPE_DYN => {
                let it = *a.instance(y.as_data.inst);
                let mut na: [TypeId; 8] = [[0] = TYPE_NONE];
                for i in 0..it.n {
                    unsafe na[i as usize] = self.subst_intern(a, unsafe it.args[i as usize], frame, depth + 1);
                }
                let r9 = if y.kind == TypeKind::TYPE_DYN {
                    g.intern_dyn_g(it.module, it.decl, &na[0], it.n, y.qualifier);
                } else {
                    g.intern_instance_g(it.module, it.decl, &na[0], it.n);
                };
                r9;
            },
            TYPE_FUNCTION => {
                let r9 = if y.fn_sig() {
                    let mut it = *a.instance(y.as_data.fnp.sig);
                    for i in 0..it.n {
                        unsafe it.args[i as usize] = self.subst_intern(a, unsafe it.args[i as usize], frame, depth + 1);
                    }
                    g.intern_sig_g(&it, y.qualifier);
                } else if (t & TYPE_PROV) == 0 {
                    t;
                } else {
                    g.intern_g(y);
                };
                r9;
            },
            _ => {
                let r9 = if (t & TYPE_PROV) == 0 {
                    t;
                } else {
                    g.intern_g(y);
                };
                r9;
            },
        };
    }

    // The type associated type record `ai` (an interface's `type Name;`, arguments final ids with the
    // projected type concrete) names: the `type Name = ..` of the conformance whose interface
    // arguments are `ai`'s, under the parameters its target solves, a final id (`Mangler::assoc_norm`
    // is emission's). TYPE_NONE when no conformance applies.
    fn assoc_norm_g(self: &Self, ai: &TyInstance, depth: i32) TypeId {
        let p = unsafe &*self.pkg;
        let ia = unsafe &*p.module_ast_const(ai.module);
        let y = *ia.type_at(ai.args[0]);
        let mut d = DefId { module: y.module, node: NODE_NONE };
        let mut keys = Vector::<ArgKey>::new();
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            d.node = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *ia.instance(y.as_data.inst);
            d = DefId { module: it.module, node: it.decl };
            for i in 0..it.n {
                let at = unsafe it.args[i as usize];
                let ay = *ia.type_at(at);
                let cv = ay.kind == TypeKind::TYPE_CONST;
                keys.push(
                    ArgKey {
                        ty: at,
                        val: pick(cv, ay.as_data.value, 0),
                        has_val: cv,
                        bt: pick(cv, ay.cbt(), BuiltinType::BT_COUNT),
                    },
                );
            }
        } else if y.kind == TypeKind::TYPE_BUILTIN {
            d = DefId { module: p.core_module, node: p.builtin_decl(y.as_data.builtin) };
        }
        let iface = iface_of_member(ia, ai.decl);
        if d.node == NODE_NONE || iface == NODE_NONE {
            return TYPE_NONE;
        }
        let want = self.g().intern_dyn_g(
            ai.module,
            iface,
            unsafe ((&ai.args[0]) as *const TypeId + 1),
            ai.n - 1,
            TypeQualifier::TYPE_QUAL_NONE as u8,
        );
        let an = ia.at_const(ia.at_const(ai.decl).as_data.type_alias.name).as_data.name.text;
        let aname = p.modules.at(ai.module as usize).source.as_str().slice(an.start as usize, an.end as usize);
        let mut r = self.ext_first(d);
        while r != IG_NONE {
            let row = *self.exts.at(r as usize);
            r = *self.ext_next.at(r as usize);
            let ea = unsafe &*p.module_ast_const(row.emod);
            let ed = ea.at_const(row.enode).as_data.extend_def;
            if ed.interface_type == NODE_NONE {
                continue;
            }
            let ir = ea.resolution_def(ed.interface_type);
            let dt = ea.type_of(ed.interface_type);
            if ir.module != ai.module || ir.node != iface || dt == TYPE_NONE || !self.ext_applies(
                ea,
                row.enode,
                &keys,
                0,
                keys.len() as u32,
            ) {
                continue;
            }
            let mut frame = Vector::<Subst>::new();
            let _ = self.bind_ext_keys(ea, row.enode, &keys, 0, keys.len() as u32, &mut frame);
            if self.subst_intern(ea, dt, &frame, depth + 1) != want {
                continue;
            }
            for j in 0..ed.items.len {
                let hid = unsafe ea.list(ed.items)[j as usize];
                let hn = ea.at_const(hid);
                if hn.kind != NodeKind::NODE_TYPE_ALIAS || hn.as_data.type_alias.ty == NODE_NONE {
                    continue;
                }
                let hs = ea.at_const(hn.as_data.type_alias.name).as_data.name.text;
                if p.modules.at(row.emod as usize).source.as_str().slice(hs.start as usize, hs.end as usize) != aname {
                    continue;
                }
                let at = ea.type_of(hn.as_data.type_alias.ty);
                if at == TYPE_NONE {
                    return TYPE_NONE;
                }
                return self.subst_intern(ea, at, &frame, depth + 1);
            }
            return TYPE_NONE;
        }
        return TYPE_NONE;
    }

    // The value const type `t` (a TYPE_CONST, a const parameter or a const expression) folds to under
    // `frame`, into `k` (bits and type); false when a parameter it names is unbound or a form's value
    // leaves its types.
    fn cval_key(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, k: &mut ArgKey) bool {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_CONST {
            k.val = y.as_data.value;
            k.bt = y.cbt();
            return true;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            for i in 0..frame.len() {
                if frame.at(i).pmod == y.module && frame.at(i).pdecl == y.as_data.decl && frame.at(i).key.has_val {
                    k.val = frame.at(i).key.val;
                    k.bt = frame.at(i).key.bt;
                    return true;
                }
            }
            return false;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let l = a.const_lin_at(y.as_data.inst);
            let mut v = i128::zero();
            if !self.lin_fold(l, frame, &mut v) {
                return false;
            }
            k.val = cval_bits(v);
            k.bt = l.to;
            return true;
        }
        return false;
    }

    // The exact value length type `lt` folds to under `frame` (`cval_key`). A length form's value
    // is not held to the form's type here: a negative or too large length has its own error.
    fn len_value(self: &Self, a: &Ast, lt: TypeId, frame: &Vector<Subst>, v: &mut i128) bool {
        let ly = *a.type_at(lt);
        if ly.kind == TypeKind::TYPE_CONST_EXPR {
            let l = a.const_lin_at(ly.as_data.inst);
            let mut sum = i128::zero();
            if !self.lin_sum(l, frame, &mut sum) {
                return false;
            }
            *v = l.floor_of(sum);
            return true;
        }
        let mut k = ArgKey { ty: TYPE_NONE, val: 0, has_val: false, bt: BuiltinType::BT_COUNT };
        if !self.cval_key(a, lt, frame, &mut k) {
            return false;
        }
        *v = cval_exact(k.val, k.bt);
        return true;
    }

    // Does `t` hold an array whose length folds outside 0..=4294967295 under `frame`, or a const
    // expression (a length or an argument) whose value leaves its types there?
    fn ty_bad(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) bool {
        if t == TYPE_NONE || depth > 8 {
            return false;
        }
        let y = *a.type_at(t);
        return switch y.kind {
            TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => self.ty_bad(a, y.as_data.elem, frame, depth + 1),
            TYPE_ARRAY => {
                let mut v = i128::zero();
                let bad = y.arr_sym() && (self.len_value(a, y.as_data.arr.len, frame, &mut v) && len_count(v) < 0 || self.cexpr_ovf(
                    a,
                    y.as_data.arr.len,
                    frame,
                ));
                bad || self.ty_bad(a, y.as_data.arr.elem, frame, depth + 1);
            },
            TYPE_INSTANCE | TYPE_DYN | TYPE_FUNCTION => {
                let mut bad = false;
                let r = y.rec();
                let it = if r != NO_REC {
                    *a.instance(r);
                } else {
                    TyInstance { module: 0, decl: NODE_NONE, n: 0 };
                };
                for i in 0..it.n {
                    bad = bad || self.cexpr_ovf(a, unsafe it.args[i as usize], frame) || self.ty_bad(
                        a,
                        unsafe it.args[i as usize],
                        frame,
                        depth + 1,
                    );
                }
                bad;
            },
            _ => false,
        };
    }

    // The error for length type `lt` folding to `v` under `frame`: the length as written (its
    // canonical form) and the bindings it folded with, when it names parameters.
    fn len_msg(self: &Self, a: &Ast, lt: TypeId, v: &i128, frame: &Vector<Subst>) String {
        let mut form = String::new();
        let mut binds = String::new();
        let terms = self.lin_text(a, lt, frame, &mut form, &mut binds);
        if terms == 0 {
            if v.is_negative() {
                return format("array length {} is negative", *v);
            }
            return format("array length {} exceeds the maximum array length 4294967295", *v);
        }
        if v.is_negative() {
            return format("array length {} is negative ({}){}", form.as_str(), *v, binds.as_str());
        }
        return format(
            "array length {} is {}{}, past the maximum array length 4294967295",
            form.as_str(),
            *v,
            binds.as_str(),
        );
    }

    // Spell const type `lt` (a parameter or a const expression) in its canonical form into `form`
    // and the `frame` values of the parameters it names into `binds` (` for N = 3, M = 4`); the
    // number of parameter terms.
    fn lin_text(self: &Self, a: &Ast, lt: TypeId, frame: &Vector<Subst>, form: &mut String, binds: &mut String) i32 {
        let ly = *a.type_at(lt);
        let mut l = ConstLin::new(BuiltinType::BT_COUNT);
        if ly.kind == TypeKind::TYPE_GENERIC {
            l.n = 1;
            l.p[0] = DefId { module: ly.module, node: ly.as_data.decl };
            l.c[0] = i128::one();
        } else if ly.kind == TypeKind::TYPE_CONST_EXPR {
            l = *a.const_lin_at(ly.as_data.inst);
        }
        return self.lin_text_of(&l, frame, form, binds);
    }

    // `lin_text` of form value `l`.
    fn lin_text_of(self: &Self, l: &ConstLin, frame: &Vector<Subst>, form: &mut String, binds: &mut String) i32 {
        let p = unsafe &*self.pkg;
        let mut terms = 0;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c.is_zero() {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            let pa = unsafe &*p.module_ast_const(pd.module);
            let ns = pa.at_const(pa.at_const(pd.node).as_data.generic_param.name).as_data.name.text;
            let name = p.modules.at(pd.module as usize).source.as_str().slice(ns.start as usize, ns.end as usize);
            if terms != 0 {
                form.push_str(pick(c.is_negative(), " - ", " + "));
            } else if c.is_negative() {
                form.push_str("-");
            }
            terms += 1;
            let mag = c.abs();
            if mag != i128::one() {
                form.format_into("{}", mag);
                form.push_str(" * ");
            }
            form.push_str(name);
            for f in 0..frame.len() {
                if frame.at(f).pmod == pd.module && frame.at(f).pdecl == pd.node {
                    binds.push_str(
                        if binds.len() == 0 {
                            " for ";
                        } else {
                            ", ";
                        },
                    );
                    binds.push_str(name);
                    binds.push_str(" = ");
                    binds.format_into("{}", cval_exact(frame.at(f).key.val, frame.at(f).key.bt));
                }
            }
        }
        if !l.k.is_zero() {
            form.push_str(pick(l.k.is_negative(), " - ", " + "));
            form.format_into("{}", l.k.abs());
        }
        let div = l.div_of();
        if div != i128::one() {
            form.insert_str(0, "(");
            form.push_str(") / ");
            form.format_into("{}", div);
        }
        return terms;
    }

    // Does const-expression argument `t` have a value for every parameter it names under `frame`,
    // but one outside its types (`{N * 2}` for an i64 N = 5000000000000000000)? The error lands in
    // `fault_msg`.
    fn cexpr_overflows(self: &mut Self, a: &Ast, t: TypeId, frame: &Vector<Subst>) bool {
        if !self.cexpr_ovf(a, t, frame) {
            return false;
        }
        let mut form = String::new();
        let mut binds = String::new();
        let _ = self.lin_text(a, t, frame, &mut form, &mut binds);
        // The type the value leaves: the one it computes in, else the one it stands for.
        let l = a.const_lin_at(a.type_at(t).as_data.inst);
        let mut sum = i128::zero();
        let ptr32 = self.ptr32();
        let bt = pick(self.lin_sum(l, frame, &mut sum) && bt_holds(l.ty, l.floor_of(sum), ptr32), l.to, l.ty);
        self.fault_msg = format("const expression {{{}}} overflows {}{}", form.as_str(), bt_name(bt), binds.as_str());
        return true;
    }

    // Check the const-generic steps of the item declared at `owner` in module `m` (`Ast::csteps`)
    // under `frame`: every step whose parameters the frame binds must hold. A whole expression is
    // left to the type walks, which check the type that holds it. A failing step is a fault at its
    // written span.
    fn check_steps(self: &mut Self, m: ModuleId, owner: NodeId, frame: &Vector<Subst>) {
        let a = unsafe &*(&*self.pkg).module_ast_const(m);
        for i in 0..a.csteps.len() {
            let s = *a.csteps.at(i);
            let mut sum = i128::zero();
            if s.owner != owner || s.root || !self.lin_sum(&s.lin, frame, &mut sum) || s.holds(sum, self.ptr32()) {
                continue;
            }
            self.fault_msg = self.step_msg(&s, sum, frame);
            self.step_fault = true;
            self.take_fault(s.module, s.span);
        }
    }

    // The error for step `s` failing with its constant and terms summing to `sum` under `frame`.
    fn step_msg(self: &Self, s: &ConstStep, sum: i128, frame: &Vector<Subst>) String {
        let mut form = String::new();
        let mut binds = String::new();
        let _ = self.lin_text_of(&s.lin, frame, &mut form, &mut binds);
        if !s.canon {
            let src = (unsafe &*self.pkg).modules.at(s.module as usize).source.as_str();
            form = String::from_str(src.slice(s.span.start as usize, s.span.end as usize));
        }
        if s.idx {
            return format(
                "index {} is out of bounds for an array of length {}{}",
                s.div,
                s.lin.floor_of(sum),
                binds.as_str(),
            );
        }
        if s.div.is_zero() {
            let bt = pick(bt_holds(s.lin.ty, s.lin.floor_of(sum), self.ptr32()), s.lin.to, s.lin.ty);
            return format("const expression {{{}}} overflows {}{}", form.as_str(), bt_name(bt), binds.as_str());
        }
        return format(
            "const expression {{{}}} truncates the negative quotient {} / {}{}: a const-generic division needs a dividend that is not negative or a divisor that divides it",
            form.as_str(),
            sum,
            s.div,
            binds.as_str(),
        );
    }

    // Report the type walks' pending finding at `span` of module `m`, unless a step of the record
    // already failed.
    fn take_type_fault(self: &mut Self, m: ModuleId, span: tok::Span) {
        if self.step_fault {
            self.fault_hit = false;
            self.fault_msg.clear();
            return;
        }
        self.take_fault(m, span);
    }

    // `cexpr_overflows` without the message.
    fn cexpr_ovf(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>) bool {
        let y = *a.type_at(t);
        if y.kind != TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        let l = a.const_lin_at(y.as_data.inst);
        for i in 0..l.n {
            let pd = unsafe l.p[i as usize];
            let mut bound = false;
            for f in 0..frame.len() {
                bound = bound || frame.at(f).pmod == pd.module && frame.at(f).pdecl == pd.node && frame.at(f).key.has_val;
            }
            if !unsafe l.c[i as usize].is_zero() && !bound {
                return false;
            }
        }
        let mut v = i128::zero();
        return !self.lin_fold(l, frame, &mut v);
    }

    // The first binding past the return slots, then the first statement, of body `b` whose type
    // holds the pending length fault under `frame`; the owner declaration when neither does.
    fn fault_span(self: &Self, b: &ir::CoreBody, a: &Ast, frame: &Vector<Subst>) tok::Span {
        for i in b.returns as usize..b.locals.len() {
            let l = b.locals.at(i);
            if l.span.end != 0 && self.ty_bad(a, l.ty, frame, 0) {
                return l.span;
            }
        }
        for i in 0..b.statements.len() {
            let st = b.statements.at(i);
            if st.kind != ir::ST_ASSIGN || st.span.end == 0 {
                continue;
            }
            let rv = b.rvalues.at(st.rvalue as usize);
            if self.ty_bad(a, rv.target, frame, 0) {
                return st.span;
            }
        }
        return a.at_const(b.owner.node).span;
    }

    // Record the pending length fault at `span` of module `m`, naming the record being expanded
    // and the site that demanded it.
    fn take_fault(self: &mut Self, m: ModuleId, span: tok::Span) {
        let mut f = LenFault {
            module: m,
            span: span,
            msg: replace(&mut self.fault_msg, String::new()),
            inst: DefId { module: 0, node: NODE_NONE },
            site_module: 0,
            site: tok::Span { start: 0, end: 0 },
        };
        self.fault_hit = false;
        if self.in_spec {
            return; // a speculative record may never be emitted
        }
        // Two walks of one instance (a method and a default body of one conformance) find its
        // failing steps twice.
        for i in 0..self.faults.len() {
            let o = self.faults.at(i);
            if o.module == m && o.span.start == span.start && o.span.end == span.end && o.msg.as_str() == f.msg.as_str() {
                return;
            }
        }
        if self.cur_rec != IG_NONE {
            let r = *self.recs.at(self.cur_rec as usize);
            f.inst = r.def;
            let org = self.origin[self.cur_rec as usize];
            if (org & ORG_BODY) != 0 {
                let b = &self.kept.at((org & 0xFFFFFFFFu64) as usize).body;
                f.site_module = b.module;
                f.site = self.demand_site(b, &r);
            } else if (org & ORG_MEMBER) != 0 {
                f.site_module = ((org & ~ORG_MEMBER) >> 32) as ModuleId;
                let ma = unsafe &*(&*self.pkg).module_ast_const(f.site_module);
                f.site = ma.at_const((org & 0xFFFFFFFFu64) as NodeId).span;
            }
        }
        self.faults.push(f);
    }

    // Does `t` under `frame` hold an out-of-range array length, also inside the members of the
    // generic aggregates it instantiates? Records nothing: the types a walk does not note (a
    // measured type, a concrete aggregate's members) are checked here. The finding lands in
    // `fault_msg` and `chk_*`.
    fn check_ty(self: &mut Self, a: &Ast, t: TypeId, frame: &Vector<Subst>, depth: i32) bool {
        if t == TYPE_NONE || depth > 8 {
            return false;
        }
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE {
            return self.check_ty(a, y.as_data.elem, frame, depth + 1);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let mut v = i128::zero();
            if y.arr_sym() && self.len_value(a, y.as_data.arr.len, frame, &mut v) && len_count(v) < 0 {
                self.fault_msg = self.len_msg(a, y.as_data.arr.len, &v, frame);
                self.chk_decl = DefId { module: 0, node: NODE_NONE };
                return true;
            }
            if y.arr_sym() && self.cexpr_overflows(a, y.as_data.arr.len, frame) {
                self.chk_decl = DefId { module: 0, node: NODE_NONE };
                return true;
            }
            return self.check_ty(a, y.as_data.arr.elem, frame, depth + 1);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *a.instance(y.as_data.inst);
        for i in 0..it.n {
            if self.check_ty(a, unsafe it.args[i as usize], frame, depth + 1) {
                return true;
            }
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(it.module);
        let dn = da.at_const(it.decl);
        if dn.kind != NodeKind::NODE_STRUCT && dn.kind != NodeKind::NODE_ENUM {
            return false;
        }
        // Bind the declaration's parameters to the argument VALUES (all a length reads).
        let mut inner = Vector::<Subst>::new();
        let gs = dn.as_data.aggregate.generics;
        let mut ai: u32 = 0;
        for g in 0..gs.len {
            let gp = unsafe da.list(gs)[g as usize];
            if da.at_const(gp).as_data.generic_param.is_lifetime || ai >= it.n as u32 {
                continue;
            }
            let mut key = ArgKey { ty: TYPE_NONE, val: 0, has_val: false, bt: BuiltinType::BT_COUNT };
            key.has_val = self.cval_key(a, unsafe it.args[ai as usize], frame, &mut key);
            inner.push(Subst { pmod: it.module, pdecl: gp, key: key });
            ai += 1;
        }
        let mut sp = tok::Span { start: 0, end: 0 };
        return self.check_decl(da, it.decl, &inner, depth + 1, &mut sp);
    }

    // `check_ty` over the member types (fields and variant payloads) of aggregate `decl` in `a`;
    // `span` receives the member that holds the length.
    fn check_decl(self: &mut Self, a: &Ast, decl: NodeId, frame: &Vector<Subst>, depth: i32, span: &mut tok::Span) bool {
        let n = a.at_const(decl);
        let is_tuple = n.as_data.aggregate.is_tuple;
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            let mk = a.at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD || is_tuple {
                let tnode = a.member_type_node(mid, is_tuple);
                let mut t = a.type_of(mid);
                if t == TYPE_NONE && tnode != NODE_NONE {
                    t = a.type_of(tnode);
                }
                *span = a.at_const(pick(tnode != NODE_NONE, tnode, mid)).span;
                if self.check_ty(a, t, frame, depth) {
                    self.chk_at(a.module, decl, *span);
                    return true;
                }
            } else if mk == NodeKind::NODE_VARIANT {
                let pl = a.at_const(mid).as_data.variant.payload;
                for j in 0..pl.len {
                    let pn = unsafe a.list(pl)[j as usize];
                    let mut t = a.type_of(pn);
                    if t == TYPE_NONE && a.at_const(pn).kind == NodeKind::NODE_PARAMETER {
                        t = a.type_of(a.at_const(pn).as_data.parameter.ty);
                    }
                    *span = a.at_const(pn).span;
                    if self.check_ty(a, t, frame, depth) {
                        self.chk_at(a.module, decl, *span);
                        return true;
                    }
                }
            }
        }
        return false;
    }

    // Locate a `check_ty` finding at member `span` of aggregate `decl` unless a deeper member holds it.
    fn chk_at(self: &mut Self, m: ModuleId, decl: NodeId, span: tok::Span) {
        if self.chk_decl.node == NODE_NONE {
            self.chk_decl = DefId { module: m, node: decl };
            self.chk_span = span;
        }
    }

    // Record `check_ty`'s finding for a type written at `span` of module `m`: at `span` itself, or
    // at the aggregate member that holds the length with `span` as its demand site.
    fn take_check(self: &mut Self, m: ModuleId, span: tok::Span) {
        if self.chk_decl.node == NODE_NONE {
            self.fault_hit = true;
            self.take_fault(m, span);
            return;
        }
        if self.in_spec {
            return;
        }
        self.faults.push(
            LenFault {
                module: self.chk_decl.module,
                span: self.chk_span,
                msg: replace(&mut self.fault_msg, String::new()),
                inst: self.chk_decl,
                site_module: m,
                site: span,
            },
        );
    }

    // Check the type statement `si` of body `b` measures with `sizeof`/`alignof`, if any.
    fn check_measured(self: &mut Self, b: &ir::CoreBody, si: u32, a: &Ast, frame: &Vector<Subst>) {
        let st = b.statements.at(si as usize);
        if st.kind != ir::ST_ASSIGN {
            return;
        }
        let mt = measured(b.rvalues.at(st.rvalue as usize));
        if mt != TYPE_NONE && self.check_ty(a, mt, frame, 0) {
            self.take_check(a.module, st.span);
        }
    }

    // Check the member types of concrete aggregate `decl`: the instances they hold are emitted with it.
    fn check_members(self: &mut Self, a: &Ast, decl: NodeId) {
        let empty = Vector::<Subst>::new();
        let mut sp = tok::Span { start: 0, end: 0 };
        if self.check_decl(a, decl, &empty, 0, &mut sp) {
            self.take_check(a.module, sp);
        }
    }

    // Where body `b` demands record `r`: the call of a function record, the first binding (then
    // statement) whose type names an aggregate record; an empty span when none does.
    fn demand_site(self: &Self, b: &ir::CoreBody, r: &InstRec) tok::Span {
        let a = unsafe &*(&*self.pkg).module_ast_const(b.module);
        if r.kind != IG_AGG {
            for i in 0..b.blocks.len() {
                let t = b.blocks.at(i).term;
                if t.kind == ir::TM_CALL && t.callee.module == r.def.module && t.callee.node == r.def.node {
                    return t.span;
                }
            }
            return tok::Span { start: 0, end: 0 };
        }
        for i in 0..b.locals.len() {
            let l = b.locals.at(i);
            if l.span.end != 0 && ty_names(a, l.ty, r.def, 0) {
                return l.span;
            }
        }
        for i in 0..b.statements.len() {
            let st = b.statements.at(i);
            if st.kind != ir::ST_ASSIGN || st.span.end == 0 {
                continue;
            }
            let rv = b.rvalues.at(st.rvalue as usize);
            if ty_names(a, rv.target, r.def, 0) {
                return st.span;
            }
        }
        return tok::Span { start: 0, end: 0 };
    }

    // The package type table (the graph is the serial stage that may append to it).
    const fn g(self: &Self) &mut TypePool {
        return unsafe &mut *((&*self.pkg).tt.as_ptr() as *mut TypePool);
    }

    // Whether usize and isize are 32-bit on the target.
    fn ptr32(self: &Self) bool {
        return lay::target_for(unsafe (&*self.pkg).arch).ptr == 4;
    }

    // The key a const-expr resolves to under `frame`: identity forms (`{N}` in N's own type) inherit
    // the bound key verbatim; every other form (`{BITS*2}`, `{(BITS+7)/8}`, `{N}` as a wider type)
    // EVALUATES when every param has a bound value, keying exactly as the emitter's folded TYPE_CONST
    // does. ty TYPE_NONE = unbound, or a value outside the form's types.
    fn const_expr_bound(self: &Self, a: &Ast, y: &Ty, frame: &Vector<Subst>) ArgKey {
        let none = ArgKey { ty: TYPE_NONE, val: 0, has_val: false, bt: BuiltinType::BT_COUNT };
        let l = a.const_lin_at(y.as_data.inst);
        // Identity: one coefficient-1 param, no constant, no divisor, no retyping.
        let mut nact: u32 = 0;
        let mut hit: i64 = -1;
        for i in 0..l.n {
            if !unsafe l.c[i as usize].is_zero() {
                nact += 1;
                hit = i;
            }
        }
        if l.k.is_zero() && l.div_of() == i128::one() && nact == 1 && unsafe l.c[hit as usize] == i128::one() && l.ty == l.to {
            let pd = unsafe l.p[hit as usize];
            for i in 0..frame.len() {
                if frame.at(i).pmod == pd.module && frame.at(i).pdecl == pd.node {
                    return frame.at(i).key;
                }
            }
            return none;
        }
        let mut v = i128::zero();
        if !self.lin_fold(l, frame, &mut v) {
            return none;
        }
        let bits = cval_bits(v);
        return ArgKey { ty: self.g().const_value_g(bits, l.to), val: bits, has_val: true, bt: l.to };
    }

    // The constant plus every term of form `l` at its bound VALUE, into `sum`; false when a parameter
    // is unbound or a step leaves i128.
    fn lin_sum(self: &Self, l: &ConstLin, frame: &Vector<Subst>, sum: &mut i128) bool {
        let mut v = l.k;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c.is_zero() {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            let mut bound = false;
            for f in 0..frame.len() {
                let k = frame.at(f).key;
                if frame.at(f).pmod == pd.module && frame.at(f).pdecl == pd.node && k.has_val && !bound {
                    if !lin_acc(&mut v, c, cval_exact(k.val, k.bt)) {
                        return false;
                    }
                    bound = true;
                }
            }
            if !bound {
                return false;
            }
        }
        *sum = v;
        return true;
    }

    // The value of compound form `l` under `frame`, floored as `ConstLin::value` floors; false when
    // a parameter is unbound or the value leaves the form's types.
    fn lin_fold(self: &Self, l: &ConstLin, frame: &Vector<Subst>, out: &mut i128) bool {
        let mut sum = i128::zero();
        return self.lin_sum(l, frame, &mut sum) && l.finish(sum, self.ptr32(), out);
    }

    // The full ArgKey of `t` under `frame`: the substituted type's final id plus the folded value
    // when the argument is a const (TYPE_CONST directly, or a const-expr the frame can evaluate).
    fn argkey_subst(self: &Self, a: &Ast, t: TypeId, frame: &Vector<Subst>) ArgKey {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_CONST {
            return ArgKey { ty: self.subst_intern(a, t, frame, 0), val: y.as_data.value, has_val: true, bt: y.cbt() };
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let b = self.const_expr_bound(a, &y, frame);
            if b.ty != TYPE_NONE {
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
        return ArgKey { ty: self.subst_intern(a, t, frame, 0), val: 0, has_val: false, bt: BuiltinType::BT_COUNT };
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
            TYPE_ARRAY => self.concrete_subst(a, y.as_data.arr.elem, frame, depth + 1) && (!y.arr_sym() || self.concrete_subst(
                a,
                y.as_data.arr.len,
                frame,
                depth + 1,
            )),
            TYPE_CONST_EXPR => self.const_expr_bound(a, &y, frame).ty != TYPE_NONE,
            TYPE_FIELD_PROJECTION => false,
            TYPE_INSTANCE | TYPE_DYN | TYPE_FUNCTION | TYPE_ASSOC => {
                let r = y.rec();
                let mut ok = true;
                if r != NO_REC {
                    let it = a.instance(r);
                    for i in 0..it.n {
                        if !self.concrete_subst(a, unsafe it.args[i], frame, depth + 1) {
                            ok = false;
                        }
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
        // Only final ids memoize: a provisional id belongs to one module's transient pool.
        let memo = frame.len() == 0 && (t & TYPE_PROV) == 0;
        if memo && t as usize < self.noted.len() && self.noted[t as usize] {
            return;
        }
        self.note_type_walk(a, t, frame, depth);
        if memo && depth == 0 {
            while self.noted.len() <= t as usize {
                self.noted.push(false);
            }
            self.noted.set(t as usize, true);
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
            if y.arr_sym() && !self.fault_hit {
                let mut v = i128::zero();
                if self.len_value(a, y.as_data.arr.len, frame, &mut v) && len_count(v) < 0 {
                    self.fault_hit = true;
                    self.fault_msg = self.len_msg(a, y.as_data.arr.len, &v, frame);
                } else if self.cexpr_overflows(a, y.as_data.arr.len, frame) {
                    self.fault_hit = true;
                }
            }
            self.note_type(a, y.as_data.arr.elem, frame, depth + 1);
            return;
        }
        if y.fn_sig() {
            let it = *a.instance(y.as_data.fnp.sig);
            for i in 0..it.n {
                self.note_type(a, unsafe it.args[i], frame, depth + 1);
            }
            return;
        }
        if y.kind == TypeKind::TYPE_ASSOC {
            // `T::Output`: whatever the conformance's type holds.
            let nt = self.subst_intern(a, t, frame, 0);
            if nt != TYPE_NONE && a.type_at(nt).kind != TypeKind::TYPE_ASSOC {
                let empty = Vector::<Subst>::new();
                self.note_type(a, nt, &empty, depth + 1);
            }
            return;
        }
        if y.kind != TypeKind::TYPE_INSTANCE && y.kind != TypeKind::TYPE_DYN {
            return;
        }
        let it = *a.instance(y.as_data.inst);
        // The declaration must be a real aggregate (a `dyn fn` carries its signature only).
        let da = unsafe &*(&*self.pkg).module_ast_const(it.module);
        let dk = da.at_const(it.decl).kind;
        for i in 0..it.n {
            if !self.fault_hit && self.cexpr_overflows(a, unsafe it.args[i], frame) {
                self.fault_hit = true;
            }
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
        if self.fault_hit {
            let sp = self.fault_span(b, a, frame);
            self.take_fault(a.module, sp);
        }
        for i in 0..b.statements.len() {
            self.check_measured(b, i as u32, a, frame);
        }
        for i in 0..b.constants.len() {
            let c = b.constants.at(i);
            if c.kind == ir::CK_ITEM && c.targ_len() != 0 {
                self.note_call(a, c.item, b, c.targ_start(), c.targ_len(), frame, c.raw);
            }
        }
        for i in 0..b.blocks.len() {
            let t = b.blocks.at(i).term;
            if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE {
                continue;
            }
            if t.targs_len != 0 && !self.note_iface_call(a, &t, b, frame) {
                self.note_call(a, t.callee, b, t.targs_start, t.targs_len, frame, t.span);
            }
            self.note_method(a, &t, b, frame);
        }
    }

    // Demand a generic-extend method from an explicit call site: the receiver operand's (peeled)
    // instance binds the extend's params; the method body walks under that frame. No extend search:
    // the checker already selected the method.
    fn note_method(self: &mut Self, a: &Ast, t: &ir::Terminator, b: &ir::CoreBody, frame: &Vector<Subst>) {
        // Only a method of a generic extend.
        if t.args_len == 0 || self.enclosing_extend(t.callee) == NODE_NONE {
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

    // A call of generic interface method `t.callee` (module AST `a`, under `frame`) dispatches per
    // instance to the method of the receiver's conformance, with the call's arguments bound to that
    // method's parameters by position, or runs the interface's default body under the conformance:
    // that method's record, or the default body's walk, once the receiver and the arguments are
    // concrete. False when the callee is no interface method.
    fn note_iface_call(self: &mut Self, a: &Ast, t: &ir::Terminator, b: &ir::CoreBody, frame: &Vector<Subst>) bool {
        let p = unsafe &*self.pkg;
        let ca = unsafe &*p.module_ast_const(t.callee.module);
        let inode = iface_of_member(ca, t.callee.node);
        let fg = ca.at_const(t.callee.node).as_data.function.generics;
        if inode == NODE_NONE || fg.len == 0 || t.targs_len < fg.len {
            return false;
        }
        let mut rt = t.recv;
        if rt == TYPE_NONE && t.args_len != 0 {
            rt = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
        }
        for _ in 0..4 {
            if rt == TYPE_NONE {
                break;
            }
            let y = *a.type_at(rt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            rt = y.as_data.elem;
        }
        if rt == TYPE_NONE || !self.concrete_subst(a, rt, frame, 0) {
            return true; // still symbolic: the enclosing instantiation walks it bound
        }
        // The method's own arguments are the call's trailing ones.
        let mut tk = Vector::<ArgKey>::new();
        for i in t.targs_len - fg.len..t.targs_len {
            let ta = b.targ_pool[(t.targs_start + i) as usize];
            if !self.concrete_subst(a, ta, frame, 0) {
                return true;
            }
            tk.push(self.argkey_subst(a, ta, frame));
        }
        let rk = self.argkey_subst(a, rt, frame);
        let ry = *a.type_at(rk.ty);
        let mut d = DefId { module: ry.module, node: NODE_NONE };
        let mut keys = Vector::<ArgKey>::new();
        if ry.kind == TypeKind::TYPE_STRUCT || ry.kind == TypeKind::TYPE_ENUM {
            d.node = ry.as_data.decl;
        } else if ry.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(ry.as_data.inst);
            d = DefId { module: it.module, node: it.decl };
            for i in 0..it.n {
                keys.push(self.argkey_subst(a, unsafe it.args[i as usize], frame));
            }
        } else if ry.kind == TypeKind::TYPE_BUILTIN {
            d = DefId { module: p.core_module, node: p.builtin_decl(ry.as_data.builtin) };
        }
        if d.node == NODE_NONE {
            return true;
        }
        let want = pick(t.iface != TYPE_NONE, self.subst_intern(a, t.iface, frame, 0), TYPE_NONE);
        let mn = ca.at_const(ca.at_const(t.callee.node).as_data.function.name).as_data.name.text;
        let mname = p.modules.at(t.callee.module as usize).source.as_str().slice(mn.start as usize, mn.end as usize);
        let mut r = self.ext_first(d);
        while r != IG_NONE {
            let ri = r;
            let row = *self.exts.at(r as usize);
            r = *self.ext_next.at(r as usize);
            let ea = unsafe &*p.module_ast_const(row.emod);
            let ed = ea.at_const(row.enode).as_data.extend_def;
            let ir = self.ext_interface(ea, row.enode);
            if ir.module != t.callee.module || ir.node != inode || !self.ext_applies(
                ea,
                row.enode,
                &keys,
                0,
                keys.len() as u32,
            ) {
                continue;
            }
            let mut ef = Vector::<Subst>::new();
            let _ = self.bind_ext_keys(ea, row.enode, &keys, 0, keys.len() as u32, &mut ef);
            let dt = ea.type_of(ed.interface_type);
            if want != TYPE_NONE && (dt == TYPE_NONE || self.subst_intern(ea, dt, &ef, 1) != want) {
                continue;
            }
            let esrc = p.modules.at(row.emod as usize).source.as_str();
            for j in 0..ed.items.len {
                let hid = unsafe ea.list(ed.items)[j as usize];
                let hn = ea.at_const(hid);
                if hn.kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let hs = ea.at_const(hn.as_data.function.name).as_data.name.text;
                if esrc.slice(hs.start as usize, hs.end as usize) != mname {
                    continue;
                }
                // The conformance's own method: the receiver's arguments (a generic extend's
                // method), then the call's.
                self.argbuf.truncate(0);
                let generic = ed.generics.len != 0;
                if generic {
                    for k in 0..keys.len() {
                        self.argbuf.push(*keys.at(k));
                    }
                }
                for k in 0..tk.len() {
                    self.argbuf.push(*tk.at(k));
                }
                let mut fresh = false;
                let _ = self.add(pick(generic, IG_METHOD, IG_FN), DefId { module: row.emod, node: hid }, &mut fresh);
                return true;
            }
            if ca.at_const(t.callee.node).as_data.function.body == NODE_NONE {
                return true;
            }
            // The inherited default body under `Self`, the conformance's interface arguments and
            // the call's.
            let mut wk = skey_mix(skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64), ri);
            wk = skey_mix(wk, rk.ty as u64 | 1u64 << 40);
            for k in 0..tk.len() {
                wk = skey_mix(wk, tk.at(k).ty);
            }
            if self.dwalked.contains(&wk) {
                return true;
            }
            self.dwalked.insert(wk);
            ef.push(Subst { pmod: t.callee.module, pdecl: inode, key: rk });
            if dt != TYPE_NONE {
                let di = *ea.instance(ea.type_at(dt).as_data.inst);
                let igens = ca.at_const(inode).as_data.interface_def.generics;
                let mut g: u32 = 0;
                while g < igens.len && g < di.n as u32 {
                    let at = unsafe di.args[g as usize];
                    if !self.concrete_subst(ea, at, &ef, 0) {
                        return true;
                    }
                    let k0 = self.argkey_subst(ea, at, &ef);
                    ef.push(Subst { pmod: t.callee.module, pdecl: unsafe ca.list(igens)[g as usize], key: k0 });
                    g += 1;
                }
            }
            for k in 0..fg.len {
                ef.push(Subst { pmod: t.callee.module, pdecl: unsafe ca.list(fg)[k as usize], key: *tk.at(k as usize) });
            }
            self.seed_body(t.callee.module, t.callee.node, ca, &ef);
            return true;
        }
        return true;
    }

    // A resolved call/value use of a generic function with bound arguments.
    fn note_call(
        self: &mut Self,
        a: &Ast,
        callee: DefId,
        b: &ir::CoreBody,
        ts: u32,
        tn: u32,
        frame: &Vector<Subst>,
        sp: tok::Span,
    ) {
        self.argbuf.truncate(0);
        for i in 0..tn {
            let t = b.targ_pool[(ts + i) as usize];
            if self.cexpr_overflows(a, t, frame) {
                self.take_type_fault(a.module, sp);
                return;
            }
            if !self.concrete_subst(a, t, frame, 0) {
                // Still symbolic here; the enclosing instantiation walks it bound.
                return;
            }
            let k0 = self.argkey_subst(a, t, frame);
            self.argbuf.push(k0);
        }
        if (unsafe &*(&*self.pkg).module_ast_const(callee.module)).at_const(callee.node).kind == NodeKind::NODE_CONST {
            // A generic extend's constant is static data evaluated at compile time: no body emits,
            // but its written const-generic expressions compute under the instance its arguments
            // (the target's, in order) name.
            let ext = self.enclosing_extend(callee);
            if ext != NODE_NONE {
                let ca = unsafe &*(&*self.pkg).module_ast_const(callee.module);
                let mut cf = Vector::<Subst>::new();
                let _ = self.bind_ext_keys(ca, ext, &self.argbuf, 0, tn, &mut cf);
                self.check_steps(callee.module, callee.node, &cf);
                self.check_steps(callee.module, ext, &cf);
            }
            return;
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
            self.rounds += 1;
            self.drain();
            let before = self.recs.len();
            self.in_spec = true;
            self.cross_demand();
            self.in_spec = false;
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
            // An interface-conforming extend emits EVERY bodied method per instance (so a demanded
            // interface method's override is always demanded); the method_used gate applies only
            // to plain extends.
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
            if target.node != NODE_NONE {
                let ck = skey_mix(skey_mix(0, md.module as u64 << 32 | md.node as u64), 1);
                self.pair_group(&gk, &groups, target, ck, md, md.module, ext);
            }
        }
    }

    // Pair decl `def` with every instance of aggregate `target` that cross-product cursor `ck` has
    // not paired yet and that extend `ext` (of module `em`) applies to.
    fn pair_group(
        self: &mut Self,
        gk: &Map<u64, u64>,
        groups: &Vector<Vector<u32>>,
        target: DefId,
        ck: u64,
        def: DefId,
        em: ModuleId,
        ext: NodeId,
    ) {
        let ea = unsafe &*(&*self.pkg).module_ast_const(em);
        let gi = switch gk.get(&skey_mix(0, target.module as u64 << 32 | target.node as u64)) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if gi < 0 {
            return;
        }
        let start: usize = switch self.pair_cur.get(&ck) {
            Some(v) => (*v) as usize,
            None => 0,
        };
        let glen = groups[gi as usize].len();
        for k9 in start..glen {
            let rec = *self.recs.at(groups[gi as usize][k9] as usize);
            if !self.ext_applies(ea, ext, &self.keys, rec.args_start, rec.args_len) {
                continue;
            }
            self.argbuf.truncate(0);
            for k in 0..rec.args_len {
                let k0 = *self.keys.at((rec.args_start + k) as usize);
                self.argbuf.push(k0);
            }
            let mut fresh = false;
            let _ = self.add(IG_METHOD, def, &mut fresh);
        }
        self.pair_cur.insert(ck, glen as u64);
    }

    // Interface default bodies: every extend that conforms `Target as Iface` emits one copy of each
    // default-bodied interface method per Target instance: record those pairs so the emitted-set
    // diff can find them (def = the INTERFACE's method decl, keys = the instance args).
    fn cross_defaults(self: &mut Self, gk: &Map<u64, u64>, groups: &Vector<Vector<u32>>) {
        for x in 0..self.exts.len() {
            let row = *self.exts.at(x);
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let ed = a.at_const(row.enode).as_data.extend_def;
            let iface = self.ext_interface(a, row.enode);
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
                        break;
                    }
                }
                if !overridden {
                    // Pair with every instance of the extend's target.
                    let tg = self.ext_target(a, row.enode);
                    let ck = skey_mix(skey_mix(0, x as u64 << 32 | imid as u64), 2);
                    self.pair_group(gk, groups, tg, ck, DefId { module: iface.module, node: imid }, row.emod, row.enode);
                    self.walk_defaults(gk, groups, &row, iface, imid, ck);
                }
            }
        }
    }

    // Walk default body `imid` of interface `iface` once for every demanded instance of extend
    // `row`'s target that the extend applies to (the target itself when it is not generic):
    // its steps are checked and the instances it names recorded under that conformance's frame.
    fn walk_defaults(
        self: &mut Self,
        gk: &Map<u64, u64>,
        groups: &Vector<Vector<u32>>,
        row: &ExtRow,
        iface: DefId,
        imid: NodeId,
        ck: u64,
    ) {
        let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
        let da = unsafe &*(&*self.pkg).module_ast_const(row.dmod);
        let dn = da.at_const(row.ddecl);
        let generic = (dn.kind == NodeKind::NODE_STRUCT || dn.kind == NodeKind::NODE_ENUM) && dn.as_data.aggregate.generics.len != 0;
        if !generic {
            if !self.dwalked.contains(&ck) {
                self.dwalked.insert(ck);
                self.walk_default(row, iface, imid, 0, 0, IG_NONE);
            }
            return;
        }
        let gi = switch gk.get(&skey_mix(0, row.dmod as u64 << 32 | row.ddecl as u64)) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if gi < 0 {
            return;
        }
        for k in 0..groups[gi as usize].len() {
            let id = groups[gi as usize][k];
            let wk = skey_mix(ck, id);
            let rec = *self.recs.at(id as usize);
            if self.dwalked.contains(&wk) || (self.flags[id as usize] & RF_SPEC) != 0 || !self.ext_applies(
                a,
                row.enode,
                &self.keys,
                rec.args_start,
                rec.args_len,
            ) {
                continue;
            }
            self.dwalked.insert(wk);
            self.walk_default(row, iface, imid, rec.args_start, rec.args_len, id);
        }
    }

    // Walk default body `imid` of interface `iface` for the instance of extend `row`'s target whose
    // arguments are the `n` keys from `start` (record `rec`, IG_NONE for a non-generic target): the
    // frame binds the extend's parameters, `Self` and the interface's parameters to the arguments
    // the conformance writes.
    fn walk_default(self: &mut Self, row: &ExtRow, iface: DefId, imid: NodeId, start: u32, n: u32, rec: u32) {
        let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
        let ia = unsafe &*(&*self.pkg).module_ast_const(iface.module);
        let ed = a.at_const(row.enode).as_data.extend_def;
        let mut frame = Vector::<Subst>::new();
        let _ = self.bind_ext_keys(a, row.enode, &self.keys, start, n, &mut frame);
        let mut pat = a.type_of(ed.target_type);
        if pat == TYPE_NONE && rec == IG_NONE {
            // A plain path is typed on its declaration.
            pat = (unsafe &*(&*self.pkg).module_ast_const(row.dmod)).type_of(row.ddecl);
        }
        if pat == TYPE_NONE || !self.concrete_subst(a, pat, &frame, 0) {
            return;
        }
        let sk = self.argkey_subst(a, pat, &frame);
        let igens = ia.at_const(iface.node).as_data.interface_def.generics;
        let mut iargs = Vector::<ArgKey>::new();
        if a.at_const(ed.interface_type).kind == NodeKind::NODE_TYPE_PATH {
            let targs = a.at_const(ed.interface_type).as_data.type_path.args;
            for g in 0..targs.len {
                let an = unsafe a.list(targs)[g as usize];
                let t = a.type_of(an);
                if iargs.len() as u32 >= igens.len || a.at_const(an).kind == NodeKind::NODE_LIFETIME {
                    continue;
                }
                if t != TYPE_NONE && self.cexpr_overflows(a, t, &frame) {
                    // The conformance's own argument fails for this instance.
                    let cur0 = self.cur_rec;
                    let spec0 = self.in_spec;
                    self.cur_rec = rec;
                    self.in_spec = false;
                    self.take_fault(row.emod, a.at_const(an).span);
                    self.cur_rec = cur0;
                    self.in_spec = spec0;
                    return;
                }
                if t == TYPE_NONE || !self.concrete_subst(a, t, &frame, 0) {
                    break;
                }
                iargs.push(self.argkey_subst(a, t, &frame));
            }
        }
        frame.push(Subst { pmod: iface.module, pdecl: iface.node, key: sk });
        for g in 0..iargs.len() {
            frame.push(Subst { pmod: iface.module, pdecl: unsafe ia.list(igens)[g], key: *iargs.at(g) });
        }
        let cur0 = self.cur_rec;
        let spec0 = self.in_spec;
        self.cur_rec = rec;
        self.in_spec = false;
        self.step_fault = false;
        self.check_steps(row.emod, row.enode, &frame);
        self.check_steps(iface.module, imid, &frame);
        if !self.step_fault && ia.at_const(imid).as_data.function.body != NODE_NONE {
            self.seed_body(iface.module, imid, ia, &frame);
        }
        self.cur_rec = cur0;
        self.in_spec = spec0;
    }

    // Expand queued records: lower each generic body once and walk it under the record's frame.
    // Recursive instantiation terminates through the interning table.
    fn drain(self: &mut Self) {
        let mut ri: usize = 0;
        while self.cursor < self.recs.len() || ri < self.redo.len() {
            let mut id = self.cursor as u32;
            if self.cursor < self.recs.len() {
                self.cursor += 1;
                if self.recs.at(id as usize).expanded {
                    continue;
                }
            } else {
                // A promoted record walks again (once: promotion is one-way).
                id = self.redo[ri];
                ri += 1;
            }
            if !self.spend(64) {
                continue;
            }
            self.recs[id as usize].expanded = true;
            self.flags.set(id as usize, self.flags[id as usize] | RF_WALKED);
            self.expand(id);
        }
        self.redo.truncate(0);
        self.cur_rec = IG_NONE;
        self.in_spec = false;
    }

    // Expand record `id`: an aggregate's fields and method signatures, a function's or method's body.
    fn expand(self: &mut Self, id: u32) {
        let r = *self.recs.at(id as usize);
        self.cur_rec = id;
        self.in_spec = (self.flags[id as usize] & RF_SPEC) != 0;
        self.step_fault = false;
        if r.kind == IG_AGG {
            self.expand_fields(&r);
            self.expand_signatures(&r);
            return;
        }
        // An extend member reached as a plain call (assoc fns, turbofish method values) still
        // binds the extend's params through its leading argument keys.
        if r.kind == IG_METHOD || r.kind == IG_FN && self.enclosing_extend(r.def) != NODE_NONE {
            self.expand_method(&r);
            return;
        }
        if r.kind != IG_FN {
            return;
        }
        let da = unsafe &*(&*self.pkg).module_ast_const(r.def.module);
        if da.at_const(r.def.node).kind != NodeKind::NODE_FUNCTION {
            return;
        }
        let fd = da.at_const(r.def.node).as_data.function;
        let mut frame = Vector::<Subst>::new();
        self.bind_generics(da, fd.generics, &r, 0, &mut frame);
        self.check_steps(r.def.module, r.def.node, &frame);
        if fd.body == NODE_NONE || fd.is_extern() {
            return;
        }
        self.seed_body(r.def.module, r.def.node, da, &frame);
    }

    // The declaration an extend targets (the path node's resolution, else its last part's).
    const fn ext_target(self: &Self, a: &Ast, ext: NodeId) DefId {
        let tt = a.at_const(ext).as_data.extend_def.target_type;
        if tt == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        return a.path_def(tt);
    }

    // A fresh aggregate instantiation reaches its FIELD types: `Vector<String>` demands String and
    // the nested `RawParts<String>` the old propagation records through reintern_nested_type. Field
    // types are written over the declaration's params, so the record's keys bind them positionally.
    fn expand_fields(self: &mut Self, r: &InstRec) {
        let a = unsafe &*(&*self.pkg).module_ast_const(r.def.module);
        let n = a.at_const(r.def.node);
        let mut frame = Vector::<Subst>::new();
        self.bind_generics(a, n.as_data.aggregate.generics, r, 0, &mut frame);
        self.check_steps(r.def.module, r.def.node, &frame);
        let is_tuple = n.as_data.aggregate.is_tuple;
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let mid = unsafe a.list(ms)[i as usize];
            let mk = a.at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD || is_tuple {
                let tnode = a.member_type_node(mid, is_tuple);
                let mut t = a.type_of(mid);
                if t == TYPE_NONE && tnode != NODE_NONE {
                    t = a.type_of(tnode);
                }
                let at = pick(tnode != NODE_NONE, tnode, mid);
                self.cur_org = ORG_MEMBER | a.module as u64 << 32 | at as u64;
                self.note_type(a, t, &frame, 0);
                if self.fault_hit {
                    self.take_type_fault(a.module, a.at_const(at).span);
                }
            } else if mk == NodeKind::NODE_VARIANT {
                let pl = a.at_const(mid).as_data.variant.payload;
                for j in 0..pl.len {
                    let pn = unsafe a.list(pl)[j as usize];
                    let mut t = a.type_of(pn);
                    if t == TYPE_NONE && a.at_const(pn).kind == NodeKind::NODE_PARAMETER {
                        t = a.type_of(a.at_const(pn).as_data.parameter.ty);
                    }
                    self.cur_org = ORG_MEMBER | a.module as u64 << 32 | pn as u64;
                    self.note_type(a, t, &frame, 0);
                    if self.fault_hit {
                        self.take_type_fault(a.module, a.at_const(pn).span);
                    }
                }
            }
        }
        self.cur_org = 0;
    }

    // The interface an extend conforms to, resolved (module-qualified); node NODE_NONE when plain.
    const fn ext_interface(self: &Self, a: &Ast, ext: NodeId) DefId {
        let it = a.at_const(ext).as_data.extend_def.interface_type;
        if it == NODE_NONE {
            return DefId { module: 0, node: NODE_NONE };
        }
        return a.path_def(it);
    }

    // Signature-level propagation (established reintern_method_signature_deps semantics): every
    // method SIGNATURE of every extend targeting a reachable instance contributes its substituted
    // types (Option<&T> from `first`, iterators from `iter`) regardless of demand.
    fn expand_signatures(self: &mut Self, r: &InstRec) {
        let spec0 = self.in_spec;
        self.in_spec = true;
        let mut x = self.ext_first(r.def);
        while x != IG_NONE {
            let row = *self.exts.at(x as usize);
            x = self.ext_next[x as usize];
            let a = unsafe &*(&*self.pkg).module_ast_const(row.emod);
            let ed = a.at_const(row.enode).as_data.extend_def;
            if !self.ext_applies(a, row.enode, &self.keys, r.args_start, r.args_len) {
                continue;
            }
            let mut frame = Vector::<Subst>::new();
            let _ = self.bind_ext_params(a, row.enode, r, &mut frame);
            for j in 0..ed.items.len {
                let iid = unsafe a.list(ed.items)[j as usize];
                // Signatures come from the package item metadata (params then returns, owner-pool
                // TypeIds), not from re-walking the item's syntax; non-function items record none.
                let sg = (unsafe &*self.pkg).item_sig(row.emod, iid);
                if sg == null || unsafe (*sg).generic {
                    // Generic methods substitute per explicit (instance, targs) pair.
                    continue;
                }
                let sn = (unsafe (*sg).np) as u32 + (unsafe (*sg).nr) as u32;
                for si in 0..sn {
                    self.note_type(a, (unsafe &*self.pkg).sig_type(unsafe (*sg).start + si), &frame, 0);
                }
                if self.fault_hit {
                    self.take_fault(row.emod, a.at_const(iid).span);
                }
            }
        }
        self.in_spec = spec0;
    }

    // Bind extend `ext`'s generic params through its target's arguments to instance `r`'s keys, into
    // `frame`; returns the target's argument count (where a method's own keys start).
    fn bind_ext_params(self: &Self, a: &Ast, ext: NodeId, r: &InstRec, frame: &mut Vector<Subst>) u32 {
        return self.bind_ext_keys(a, ext, &self.keys, r.args_start, r.args_len, frame);
    }

    // `bind_ext_params` over the `n` keys of `keys` from `start` on (the arguments of an instance of
    // extend `ext`'s target, `a` its module): each argument the target constrains binds by its kind
    // (`xarg_of`), a bare parameter to its key and a form's parameter to the value that inverts it.
    fn bind_ext_keys(
        self: &Self,
        a: &Ast,
        ext: NodeId,
        keys: &Vector<ArgKey>,
        start: u32,
        n: u32,
        frame: &mut Vector<Subst>,
    ) u32 {
        let pat = a.type_of(a.at_const(ext).as_data.extend_def.target_type);
        if pat == TYPE_NONE || a.type_at(pat).kind != TypeKind::TYPE_INSTANCE {
            return 0;
        }
        let pi = *a.instance(a.type_at(pat).as_data.inst);
        let gens = a.at_const(ext).as_data.extend_def.generics;
        let np = ext_arity(a, ext, pi.n);
        for j in 0..np {
            if j >= n {
                break;
            }
            let x = xarg_of(a, unsafe pi.args[j as usize], a, a.module, gens);
            let key = *keys.at((start + j) as usize);
            let gid = unsafe a.list(gens)[x.par as usize];
            if x.kind == XA_PARAM {
                frame.push(Subst { pmod: a.module, pdecl: gid, key: key });
            } else if x.kind == XA_FORM && key.has_val {
                let bt = (unsafe &*self.pkg).const_param_bt(a.module, gid);
                let mut q = i128::zero();
                if xarg_solve(&x, cval_exact(key.val, key.bt), bt, self.ptr32(), &mut q) {
                    let bits = cval_bits(q);
                    frame.push(
                        Subst {
                            pmod: a.module,
                            pdecl: gid,
                            key: ArgKey { ty: self.g().const_value_g(bits, bt), val: bits, has_val: true, bt: bt },
                        },
                    );
                }
            }
        }
        return pi.n;
    }

    // Whether extend `ext` (module `a`) applies to the instance of its target whose arguments are the
    // `n` keys of `keys` from `start` on: every argument the target constrains matches (`xarg_of`), a
    // form exactly and in its parameter's type, a parameter bound twice to one key.
    fn ext_applies(self: &Self, a: &Ast, ext: NodeId, keys: &Vector<ArgKey>, start: u32, n: u32) bool {
        let pat = a.type_of(a.at_const(ext).as_data.extend_def.target_type);
        if ext_is_identity(a, pat, a, a.module, ext) {
            return true;
        }
        let pi = *a.instance(a.type_at(pat).as_data.inst);
        let gens = a.at_const(ext).as_data.extend_def.generics;
        let np = ext_arity(a, ext, pi.n);
        if np > n || gens.len > 8 {
            return false;
        }
        let mut bound = [TYPE_NONE; 8];
        for j in 0..np {
            let x = xarg_of(a, unsafe pi.args[j as usize], a, a.module, gens);
            let key = *keys.at((start + j) as usize);
            let mut v = key.ty;
            if x.kind == XA_FIXED {
                if key.ty != unsafe pi.args[j as usize] {
                    return false;
                }
                continue;
            }
            if x.kind == XA_FORM {
                let bt = (unsafe &*self.pkg).const_param_bt(a.module, unsafe a.list(gens)[x.par as usize]);
                let mut q = i128::zero();
                if !key.has_val || !xarg_solve(&x, cval_exact(key.val, key.bt), bt, self.ptr32(), &mut q) {
                    return false;
                }
                v = self.g().const_value_g(cval_bits(q), bt);
            } else if x.kind != XA_PARAM {
                return false;
            }
            let prev = unsafe bound[x.par as usize];
            if prev != TYPE_NONE && prev != v {
                return false;
            }
            unsafe bound[x.par as usize] = v;
        }
        return true;
    }

    // Bind the non-lifetime generic params `gs` of record `r`'s declaration (in AST `a`) to the
    // record's keys from position `pos` on, into `frame`.
    fn bind_generics(self: &Self, a: &Ast, gs: NodeList, r: &InstRec, pos: u32, frame: &mut Vector<Subst>) {
        let mut ai = pos;
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
    }

    // The first `exts` row whose extend targets `d` (IG_NONE = none); `ext_next` chains the rest
    // in `exts` order.
    fn ext_first(self: &Self, d: DefId) u32 {
        return switch self.ext_head.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => *v,
            None => IG_NONE,
        };
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
        let mut frame = Vector::<Subst>::new();
        let pos = self.bind_ext_params(a, ext, r, &mut frame);
        let fd = a.at_const(r.def.node).as_data.function;
        self.bind_generics(a, fd.generics, r, pos, &mut frame);
        self.check_steps(r.def.module, r.def.node, &frame);
        self.check_steps(r.def.module, ext, &frame);
        if fd.body != NODE_NONE {
            self.seed_body(r.def.module, r.def.node, a, &frame);
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
        let mut kb = irl::KeptBody::empty(m, node);
        let mut ki: i64 = -1;
        if self.keep != null {
            let kp = unsafe &mut *self.keep;
            ki = (switch kp.ix.get(&key) {
                Some(v) => (*v) as i64,
                None => -1,
            });
            if ki >= 0 {
                assert(kp.viewers == 0);
                kb = replace(&mut kp.kept[ki as usize], irl::KeptBody::empty(m, node));
            }
        }
        if ki < 0 {
            self.low.retarget(m);
            let ok = if closure {
                self.low.lower_closure_body(node);
            } else {
                self.low.lower_fn(node);
            };
            if !ok {
                self.kept_ix.insert(key, ki as u64);
                return ki;
            }
            kb = irl::KeptBody::copy(&self.low.body, &self.low.closures);
        }
        let slot = self.kept.len() as i64;
        self.kept.push(kb);
        self.wcache.push(
            WalkCache {
                built: false,
                tys: Vector::<TypeId>::new(),
                consts: Vector::<u32>::new(),
                calls: Vector::<u32>::new(),
                meas: Vector::<u32>::new(),
            },
        );
        self.kept_ix.insert(key, slot as u64);
        return slot;
    }

    // Walk kept body `ki` under `frame` through its walk cache (built on first use).
    fn walk_kept(self: &mut Self, ki: i64, a: &Ast, frame: &Vector<Subst>) {
        let bp = self.kept.at(ki as usize) as *const irl::KeptBody;
        if !self.wcache.at(ki as usize).built {
            self.wt_seen.clear();
            let b = unsafe &(*bp).body;
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
                if c.kind == ir::CK_ITEM && c.targ_len() != 0 {
                    self.wcache[ki as usize].consts.push(i as u32);
                }
            }
            for i in 0..b.statements.len() {
                let st = b.statements.at(i);
                if st.kind == ir::ST_ASSIGN && measured(b.rvalues.at(st.rvalue as usize)) != TYPE_NONE {
                    self.wcache[ki as usize].meas.push(i as u32);
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
        let b = unsafe &(*bp).body;
        let wp = self.wcache.at(ki as usize) as *const WalkCache;
        let org0 = self.cur_org;
        self.cur_org = ORG_BODY | ki as u64;
        for i in 0..(unsafe &*wp).tys.len() {
            self.note_type(a, *(unsafe &*wp).tys.at(i), frame, 0);
        }
        if self.fault_hit {
            let sp = self.fault_span(b, a, frame);
            self.take_type_fault(a.module, sp);
        }
        for i in 0..(unsafe &*wp).meas.len() {
            self.check_measured(b, *(unsafe &*wp).meas.at(i), a, frame);
        }
        for i in 0..(unsafe &*wp).consts.len() {
            let c = *b.constants.at((*(unsafe &*wp).consts.at(i)) as usize);
            self.note_call(a, c.item, b, c.targ_start(), c.targ_len(), frame, c.raw);
        }
        for i in 0..(unsafe &*wp).calls.len() {
            let t = b.blocks.at((*(unsafe &*wp).calls.at(i)) as usize).term;
            if t.targs_len != 0 && !self.note_iface_call(a, &t, b, frame) {
                self.note_call(a, t.callee, b, t.targs_start, t.targs_len, frame, t.span);
            }
            self.note_method(a, &t, b, frame);
        }
        self.cur_org = org0;
    }

    // Walk the closures kept body `bi` holds under `frame`.
    fn expand_closures(self: &mut Self, bi: i64, m: ModuleId, frame: &Vector<Subst>) {
        let a = unsafe &*(&*self.pkg).module_ast_const(m);
        // A worklist to any depth: every closure a kept body holds is walked, and the closures IT
        // holds join the list, so a closure nested three deep is demanded here like its parents
        // (the emitter lowers what the graph never demanded from scratch, after the body arena is
        // gone). Bounded by the closure nodes of the body. Raw borrow: walk_body never touches
        // `kept`, but body_idx can grow it, so the nested ids are copied out first.
        let mut work = Vector::<NodeId>::new();
        let bp0 = self.kept.at(bi as usize) as *const irl::KeptBody;
        for c in 0..(unsafe &*bp0).closures.len() {
            work.push((unsafe &*bp0).closures[c]);
        }
        let mut i: usize = 0;
        while i < work.len() {
            let ci = self.body_idx(m, work[i], true);
            i += 1;
            if ci < 0 {
                continue;
            }
            self.walk_kept(ci, a, frame);
            let bp = self.kept.at(ci as usize) as *const irl::KeptBody;
            for c2 in 0..(unsafe &*bp).closures.len() {
                work.push((unsafe &*bp).closures[c2]);
            }
        }
    }

    /// Seed every concrete body of every emitted module (functions, methods, constant initializers)
    /// and run the expansion worklist to its fixed point.
    pub fn collect(self: &mut Self) {
        let p = unsafe &*self.pkg;
        let empty = Vector::<Subst>::new();
        if self.keep != null {
            // Every kept body moves in here: size the vectors once instead of doubling them
            // through a chain of multi-megabyte reallocations.
            let nk = (unsafe &*self.keep).kept.len();
            self.kept.reserve(nk);
            self.wcache.reserve(nk);
        }
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
        // Chain the rows per target back to front, so each chain lists its rows in `exts` order.
        self.ext_next.resize_default(self.exts.len());
        let mut x = self.exts.len();
        while x > 0 {
            x -= 1;
            let row = *self.exts.at(x);
            let d = DefId { module: row.dmod, node: row.ddecl };
            self.ext_next.set(x, self.ext_first(d));
            self.ext_head.insert(skey_mix(0, row.dmod as u64 << 32 | row.ddecl as u64), x as u32);
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
                    if n.as_data.function.generics.len == 0 && !n.as_data.function.is_extern() && n.as_data.function.body != NODE_NONE {
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
                } else if (n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM) && n.as_data.aggregate.generics.len == 0 {
                    // A concrete aggregate is emitted whether or not a body names it, and with it
                    // the instances its members hold.
                    self.check_members(a, nid);
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
                        self.note_type(a, a.type_of(n.as_data.type_alias.ty), &empty, 0);
                        self.note_type(a, a.type_of(nid), &empty, 0);
                        if self.fault_hit {
                            self.take_fault(m as ModuleId, n.span);
                        }
                    }
                }
            }
        }
        self.run();
    }

    // True for a prelude module the emitter skips (see `live`).
    const fn module_elided(self: &Self, m: usize) bool {
        if self.live == null {
            return false;
        }
        let p = unsafe &*self.pkg;
        return p.modules.at(m).prelude && !unsafe self.live[m];
    }

    // Walk function `fnode`'s body (lowered on first demand) and its closures under `frame`.
    fn seed_body(self: &mut Self, m: ModuleId, fnode: NodeId, a: &Ast, frame: &Vector<Subst>) {
        let bi = self.body_idx(m, fnode, false);
        if bi >= 0 {
            self.walk_kept(bi, a, frame);
            self.expand_closures(bi, m, frame);
        }
    }
}

// Does `t` name an instance of aggregate `d` (through elements and instance arguments)?
fn ty_names(a: &Ast, t: TypeId, d: DefId, depth: i32) bool {
    if t == TYPE_NONE || depth > 8 {
        return false;
    }
    let y = *a.type_at(t);
    return switch y.kind {
        TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE => ty_names(a, y.as_data.elem, d, depth + 1),
        TYPE_ARRAY => ty_names(a, y.as_data.arr.elem, d, depth + 1),
        TYPE_INSTANCE => {
            let it = *a.instance(y.as_data.inst);
            let mut hit = it.module == d.module && it.decl == d.node;
            for i in 0..it.n {
                hit = hit || ty_names(a, unsafe it.args[i as usize], d, depth + 1);
            }
            hit;
        },
        _ => false,
    };
}

// The type `sizeof`/`alignof` rvalue `rv` measures (TYPE_NONE for any other rvalue).
fn measured(rv: &ir::Rvalue) TypeId {
    if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF) {
        return rv.b;
    }
    return TYPE_NONE;
}
