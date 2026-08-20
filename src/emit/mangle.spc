// The frozen C symbol-naming authority for the streaming backend. Every rule here reproduces the
// established emitter's output byte-for-byte and is verified against it by the SC_MANGLE replay
// (driver::emit): the old emitter records each replayable render as (pool module, TypeId, symbol)
// and this module must regenerate the identical bytes from the pools alone. Inputs are concrete,
// pool-local types under an empty substitution frame -- resolution happens before naming, never
// inside it. Renders outside the frozen subset refuse (false) instead of guessing.
import ast::ast as *;
import ir::layout as lay;
import lexer::token as tok;
import module::loader as loader;
import consteval::consteval as ce;

// The mangle spelling of a builtin ("void" doubles as the not-a-scalar fallback).
const fn bt_mangle(b: BuiltinType) str<'static> {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR {
        return "char";
    }
    if b == BuiltinType::BT_I8 {
        return "i8";
    }
    if b == BuiltinType::BT_I16 {
        return "i16";
    }
    if b == BuiltinType::BT_I32 {
        return "i32";
    }
    if b == BuiltinType::BT_I64 {
        return "i64";
    }
    if b == BuiltinType::BT_ISIZE {
        return "isize";
    }
    if b == BuiltinType::BT_U8 {
        return "u8";
    }
    if b == BuiltinType::BT_U16 {
        return "u16";
    }
    if b == BuiltinType::BT_U32 {
        return "u32";
    }
    if b == BuiltinType::BT_U64 {
        return "u64";
    }
    if b == BuiltinType::BT_USIZE {
        return "usize";
    }
    if b == BuiltinType::BT_F32 {
        return "f32";
    }
    if b == BuiltinType::BT_F64 {
        return "f64";
    }
    if b == BuiltinType::BT_C32 {
        return "c32";
    }
    if b == BuiltinType::BT_C64 {
        return "c64";
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list";
    }
    return "void";
}

// The C spelling of a builtin in declarations (usize is size_t, NOT uintptr_t; c32/c64 are the
// _Complex pair). "void" doubles as the fallback.
const fn bt_c_decl(b: BuiltinType) str<'static> {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR {
        return "char";
    }
    if b == BuiltinType::BT_I8 {
        return "int8_t";
    }
    if b == BuiltinType::BT_I16 {
        return "int16_t";
    }
    if b == BuiltinType::BT_I32 {
        return "int32_t";
    }
    if b == BuiltinType::BT_I64 {
        return "int64_t";
    }
    if b == BuiltinType::BT_ISIZE {
        return "intptr_t";
    }
    if b == BuiltinType::BT_U8 {
        return "uint8_t";
    }
    if b == BuiltinType::BT_U16 {
        return "uint16_t";
    }
    if b == BuiltinType::BT_U32 {
        return "uint32_t";
    }
    if b == BuiltinType::BT_U64 {
        return "uint64_t";
    }
    if b == BuiltinType::BT_USIZE {
        return "size_t";
    }
    if b == BuiltinType::BT_F32 {
        return "float";
    }
    if b == BuiltinType::BT_F64 {
        return "double";
    }
    if b == BuiltinType::BT_C32 {
        return "float _Complex";
    }
    if b == BuiltinType::BT_C64 {
        return "double _Complex";
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list";
    }
    return "void";
}

// Names an identifier cannot keep in C: keywords plus the <iso646.h> alternative-token macros
// (the runtime header includes it, so `and` would expand to `&&`).
const fn kw(s: str, lit: str) bool {
    return s.len() == lit.len() && s == lit;
}
pub const fn c_keyword(s: str) bool {
    if s.len() == 0 {
        return false;
    }
    let c0 = s.byte_at(0);
    if c0 == b'N' {
        return kw(s, "NULL");
    }
    if c0 == b'_' {
        return kw(s, "_Bool") || kw(s, "_Complex") || kw(s, "_Atomic") || kw(s, "_Noreturn") || kw(s, "_Generic") || kw(
            s,
            "_Static_assert",
        ) || kw(s, "_Thread_local");
    }
    if c0 == b'a' {
        return kw(s, "auto") || kw(s, "and") || kw(s, "and_eq");
    }
    if c0 == b'b' {
        return kw(s, "break") || kw(s, "bool") || kw(s, "bitand") || kw(s, "bitor");
    }
    if c0 == b'c' {
        return kw(s, "case") || kw(s, "char") || kw(s, "const") || kw(s, "continue") || kw(s, "compl");
    }
    if c0 == b'd' {
        return kw(s, "default") || kw(s, "do") || kw(s, "double");
    }
    if c0 == b'e' {
        return kw(s, "else") || kw(s, "enum") || kw(s, "extern");
    }
    if c0 == b'f' {
        return kw(s, "float") || kw(s, "for") || kw(s, "false");
    }
    if c0 == b'g' {
        return kw(s, "goto");
    }
    if c0 == b'i' {
        return kw(s, "if") || kw(s, "inline") || kw(s, "int");
    }
    if c0 == b'l' {
        return kw(s, "long");
    }
    if c0 == b'n' {
        return kw(s, "not") || kw(s, "not_eq");
    }
    if c0 == b'o' {
        return kw(s, "or") || kw(s, "or_eq");
    }
    if c0 == b'r' {
        return kw(s, "register") || kw(s, "restrict") || kw(s, "return");
    }
    if c0 == b's' {
        return kw(s, "short") || kw(s, "signed") || kw(s, "sizeof") || kw(s, "static") || kw(s, "struct") || kw(
            s,
            "switch",
        );
    }
    if c0 == b't' {
        return kw(s, "typedef") || kw(s, "true");
    }
    if c0 == b'u' {
        return kw(s, "union") || kw(s, "unsigned");
    }
    if c0 == b'v' {
        return kw(s, "void") || kw(s, "volatile");
    }
    if c0 == b'w' {
        return kw(s, "while");
    }
    if c0 == b'x' {
        return kw(s, "xor") || kw(s, "xor_eq");
    }
    return false;
}

// Byte offset just past the LAST `::` (0 for single-segment paths).
const fn path_base_start(path: str) usize {
    let n = path.len();
    let mut at: usize = 0;
    let mut i: usize = 0;
    while i + 1 < n {
        if path.byte_at(i) == b':' && path.byte_at(i + 1) == b':' {
            at = i + 2;
            i = i + 2;
        } else {
            i = i + 1;
        }
    }
    return at;
}

pub struct Mangler {
    pub pkg: *const loader::Package,
    /// Prefixing is on only when the package holds more than one non-prelude module (the single-
    /// module build emits one standalone TU with bare names).
    pub mangle: bool,
    ph_global: loader::LookupHit,
    // Per-module short-prefix verdict memo: 0 unknown / 1 full path / 2 short. A pure function of
    // the package's module path list, so every TU agrees.
    short_ok: Vector<u8>,
    /// Instance suffix appended to closure symbols while a generic body instance emits (closures
    /// hoist per instantiation; the bare name would collide across instances in one TU). Only the
    /// closures DECLARED IN that instance take it: `clos_ids` lists them -- a concrete closure
    /// passed IN as a type argument keeps its unsuffixed name.
    pub clos_sfx: String,
    pub clos_ids: Vector<NodeId>,
    /// Substitution stack for per-instance spelling: generic-param decl -> a CONCRETE pool type
    /// (module + TypeId, usually the instance's anchor pool). Innermost binding wins.
    pub subs: Vector<MSub>,
    /// Every TYPE_DYN whose C spelling was rendered: the backend drains this into `SC_DYN_<stem>`
    /// typedef blocks (the fat value + vtable types every dyn spelling presumes).
    pub dyn_reqs: Vector<DynReq>,
    /// `@emit_macro` template mode: an UNRESOLVED generic param spells as its own name in C types
    /// and as `<paste>_SCM_<name>` in mangles (byte 1 marks a `##` for the template rewriter).
    pub macro_on: bool,
    // TU-liveness floor: modules whose symbols were spelled outside their own TU (mark_ctx)
    /// Dense (spelling TU -> owner module) edge matrix, (n+1)*n bytes, row n = the shared
    /// instance TU (mark_ctx -1): modpfx marks an edge per cross-TU spelling, far too hot for a
    /// hashed set. Sized lazily on the first edge.
    pub used_mods: Vector<u8>,
    pub mark_ctx: i64,
    /// The impl fn `method_by_name` last resolved (node NONE when none): callers that must
    /// demand the instance body read it back (the return carries only the spelling).
    pub last_method_def: DefId,
    /// When set, every successful instance spelling records once (descriptor + the active subs
    /// env) so TU assembly can define aggregates the planner's closure never reached.
    pub agg_on: bool,
    pub agg_reqs: Vector<AggReq>,
    agg_seen: Map<u64, u64>,
    // fnode -> owning extend/interface, per module, built on first query: symbol resolution asks
    // per CALL SITE, so membership must be a lookup, not a rescan of the module's item list.
    own_built: Vector<bool>,
    own_idx: Map<u64, u64>, // (module << 32 | fnode) -> (extend << 32 | interface)
    ovl_memo: Map<u64, u64>, // overload_count keyed by (cur, tmod, tdecl, name) hash
    last_edge: u64, // the used_mods edge just recorded: spellings cluster, so most repeat it
    /// Spelling capture for memoized renders: while on, modpfx logs every module it spells so a
    /// cache hit can replay the used_mods edges exactly (under the hit's own mark_ctx).
    pub edge_log_on: bool,
    pub edge_log: Vector<ModuleId>,
    /// Per-TU emission journal (driver/tuc): while on, every cross-TU-gated attempt the emitter
    /// makes is logged pre-dedup, so a later build can replay a module's side effects through the
    /// SAME gates without lowering its bodies. Off during replay and outside the seed loop.
    pub rec_on: bool,
    pub rec: Vector<RecEv>,
    /// Attempts already journaled, keyed (gate key, mark_ctx): a dup attempt must be replayable
    /// once per module (its first claimant may vanish), and never more.
    pub rec_dups: Set<u64>,
    /// Target layout service for ZST decisions (`is_zst`): storage elision is a pure function of
    /// final layout, never of syntax, so both manglers (TU and body emitters) answer identically.
    pub lay: lay::Svc,
    /// Substitution-free classification memo keyed (module << 32 | type): bit0 computed, bit1
    /// zero-sized, bit2 unit/never. One resolve+layout then serves every emission gate probe.
    zmemo: Map<u64, u64>,
}

// RecEv kinds; the payload schema per kind is fixed by its recording site.
pub const RK_CHUNK: u8 = 1; // s1 = TU chunk text (driver-recorded, replay re-derives the proto)
pub const RK_ENV: u8 = 2; // h = env name hash, s1 = env struct body
pub const RK_AUX: u8 = 3; // s1 = `_ret` typedef slice
pub const RK_EFWD: u8 = 4; // s1 = env forward-typedef slice
pub const RK_EDEF: u8 = 5; // h = env hash defined by this module (env_skip/env_hashes mark)
pub const RK_DEMAND: u8 = 6; // b/c = def, s1 = sym, s2 = sfx, subs; h = demand_seen key (0 = ungated)
pub const RK_GLUE: u8 = 7; // h = gate, a = em, d = ty, s1 = sym, subs = recorded env
pub const RK_STAT: u8 = 8; // h = gate, a = em, b/c = def, d = ty, s1 = sym
pub const RK_EXT: u8 = 9; // h = gate, s1 = extern prototype line
pub const RK_DYNREQ: u8 = 10; // a = pm, b = t (cem.dyn_request call)
pub const RK_DYNTAB: u8 = 11; // a = pm, b = dyn t, c = srm, d = srt, h = own flag (dyn_pair call)
pub const RK_TI: u8 = 12; // a = rm, b = rt (type_info descriptor request)
pub const RK_BLK: u8 = 13; // a/b = blocking callee DefId (blk_wrapper call)
pub const RK_AGG: u8 = 14; // h = gate, a = pm, b/c/d+xs = TyInstance, subs = spelling env
pub const RK_MDYN: u8 = 15; // a = pm, b = t (mangler dyn_reqs entry)
pub const RK_EDGE: u8 = 16; // xs = used_mods row of this module (driver-recorded)
pub const RK_MAIN: u8 = 17; // a = main_argv (driver-recorded, module holds `main`)
pub const RK_ZST: u8 = 18; // a = alignment (ZST sentinel demand)

/// One journaled emission side effect. Fields are kind-specific (see RK_*); unused ones stay zero.
pub struct RecEv {
    pub kind: u8,
    pub a: u32,
    pub b: u32,
    pub c: u32,
    pub d: u32,
    pub h: u64,
    pub s1: String,
    pub s2: String,
    pub subs: Vector<MSub>,
    pub xs: Vector<u32>,
}

extend RecEv as Free {
    pub fn free(self: &mut Self) {
        self.s1.free();
        self.s2.free();
        self.subs.free();
        self.xs.free();
    }
}

extend RecEv {
    pub fn blank(kind: u8) RecEv {
        return RecEv {
            kind: kind,
            a: 0,
            b: 0,
            c: 0,
            d: 0,
            h: 0,
            s1: String::new(),
            s2: String::new(),
            subs: Vector::<MSub>::new(),
            xs: Vector::<u32>::new(),
        };
    }
}

/// One recorded instance spelling: replaying `it` under `subs` re-derives the same C name.
pub struct AggReq {
    pub pm: ModuleId,
    pub it: TyInstance,
    pub subs: Vector<MSub>,
}

extend AggReq as Free {
    pub fn free(self: &mut Self) {
        self.subs.free();
    }
}

/// One dyn spelling site: the pool the TYPE_DYN lives in.
pub struct DynReq {
    pub pm: ModuleId,
    pub t: TypeId,
}

/// One substitution binding: param decl `(pm, pnode)` resolves to pool type `(am, at)`. `lim` is
/// the stack size when the binding's GROUP was pushed: the payload references that env, so its
/// resolution never consults this frame or its siblings (a param bound to a derived spelling of
/// itself substitutes exactly once).
pub struct MSub {
    pub pm: ModuleId,
    pub pnode: NodeId,
    pub am: ModuleId,
    pub at: TypeId,
    pub lim: u32,
}

extend Mangler as Free {
    pub fn free(self: &mut Self) {
        self.short_ok.free();
        self.subs.free();
        self.clos_sfx.free();
        self.clos_ids.free();
        self.dyn_reqs.free();
        self.agg_reqs.free();
        self.agg_seen.free();
        self.used_mods.free();
        self.own_built.free();
        self.own_idx.free();
        self.ovl_memo.free();
        self.edge_log.free();
        self.rec.free();
        self.rec_dups.free();
        self.lay.free();
        self.zmemo.free();
    }
}

extend Mangler {
    pub fn new(pkg: *const loader::Package) Mangler {
        let p = unsafe &*pkg;
        let mut user_mods: usize = 0;
        for i in 0..p.modules.len() {
            if !p.modules.at(i).prelude {
                user_mods += 1;
            }
        }
        return Mangler {
            pkg: pkg,
            mangle: user_mods > 1,
            ph_global: p.prelude_lookup("Global", true),
            short_ok: Vector::<u8>::new(),
            subs: Vector::<MSub>::new(),
            clos_sfx: String::new(),
            clos_ids: Vector::<NodeId>::new(),
            dyn_reqs: Vector::<DynReq>::new(),
            macro_on: false,
            used_mods: Vector::<u8>::new(),
            mark_ctx: -1,
            last_method_def: DefId { module: 0, node: NODE_NONE },
            agg_on: false,
            agg_reqs: Vector::<AggReq>::new(),
            agg_seen: Map::<u64, u64>::new(),
            own_built: Vector::<bool>::new(),
            own_idx: Map::<u64, u64>::new(),
            ovl_memo: Map::<u64, u64>::new(),
            last_edge: 0xFFFFFFFFFFFFFFFFu64,
            edge_log_on: false,
            edge_log: Vector::<ModuleId>::new(),
            rec_on: false,
            rec: Vector::<RecEv>::new(),
            rec_dups: Set::<u64>::new(),
            lay: lay::Svc::new(pkg),
            zmemo: Map::<u64, u64>::new(),
        };
    }

    // The packed owner record of `fnode` (module `m`): extend node in the high half, interface
    // node in the low half, zero halves = not a member.
    fn owner_of(self: &mut Self, m: ModuleId, fnode: NodeId) u64 {
        if self.own_built.len() == 0 {
            for _i in 0..self.p().modules.len() {
                self.own_built.push(false);
            }
        }
        if !self.own_built[m as usize] {
            self.own_built.set(m as usize, true);
            let a = self.p().module_ast_const(m);
            let items = unsafe a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let k = a.at_const(iid).kind;
                if k == NodeKind::NODE_EXTEND {
                    let ms = a.at_const(iid).as_data.extend_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe a.list(ms)[j as usize];
                        self.own_idx.insert(skey_mix(0, m as u64 << 32 | mid as u64), iid as u64 << 32);
                    }
                } else if k == NodeKind::NODE_INTERFACE {
                    let ms = a.at_const(iid).as_data.interface_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe a.list(ms)[j as usize];
                        self.own_idx.insert(skey_mix(0, m as u64 << 32 | mid as u64), iid);
                    }
                }
            }
        }
        let rec = switch self.own_idx.get(&skey_mix(0, m as u64 << 32 | fnode as u64)) {
            Some(v) => *v,
            None => 0u64,
        };
        return rec;
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    /// Bind a generic param for per-instance spelling; pop with `pop_subs` (LIFO frames).
    pub fn push_sub(self: &mut Self, pm: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) {
        let lim = self.subs.len() as u32;
        self.subs.push(MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
    }
    /// Re-push a recorded binding, keeping its env boundary (demand chains rebuild from index 0).
    pub fn push_msub(self: &mut Self, sb: MSub) {
        self.subs.push(sb);
    }
    pub fn pop_subs(self: &mut Self, n: usize) {
        self.subs.truncate(self.subs.len() - n);
    }

    /// Fold a canonical const-generic expression under the substitution stack: every referenced
    /// parameter must bind to a TYPE_CONST. False when a parameter is unbound or non-const.
    pub fn fold_cexpr(self: &Self, pm: ModuleId, t: TypeId, out_val: &mut i64) bool {
        return self.fold_cexpr_d(pm, t, out_val, 0, self.subs.len());
    }
    /// Ground any const-valued payload (TYPE_CONST, expression, or bound param) below `lim`.
    pub fn fold_cval_at(self: &Self, am: ModuleId, at: TypeId, out_val: &mut i64, lim: usize) bool {
        let l = if lim < self.subs.len() {
            lim;
        } else {
            self.subs.len();
        };
        let y = *self.p().module_ast_const(am).type_at(at);
        if y.kind == TypeKind::TYPE_CONST {
            *out_val = y.as_data.value;
            return true;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            return self.fold_cexpr_d(am, at, out_val, 0, l);
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            return self.fold_generic_d(&y, out_val, 0, l);
        }
        return false;
    }

    /// Ground a const-bound GENERIC param to its value: frames innermost-first, each matched
    /// frame's payload folding strictly below that frame's env boundary.
    fn fold_generic_d(self: &Self, y: &Ty, out_val: &mut i64, depth: u32, lim: usize) bool {
        if depth > 8 {
            return false;
        }
        let mut k = lim;
        while k > 0 {
            k -= 1;
            let sb = *self.subs.at(k);
            if sb.pm != y.module || sb.pnode != y.as_data.decl {
                continue;
            }
            let kl = if sb.lim as usize < k {
                sb.lim as usize;
            } else {
                k;
            };
            let by = *self.p().module_ast_const(sb.am).type_at(sb.at);
            if by.kind == TypeKind::TYPE_CONST {
                *out_val = by.as_data.value;
                return true;
            }
            if by.kind == TypeKind::TYPE_CONST_EXPR {
                if self.fold_cexpr_d(sb.am, sb.at, out_val, depth + 1, kl) {
                    return true;
                }
            } else if by.kind == TypeKind::TYPE_GENERIC {
                if self.fold_generic_d(&by, out_val, depth + 1, kl) {
                    return true;
                }
            }
        }
        return false;
    }

    fn fold_cexpr_d(self: &Self, pm: ModuleId, t: TypeId, out_val: &mut i64, depth: u32, lim: usize) bool {
        if depth > 8 {
            return false;
        }
        let a = self.p().module_ast_const(pm);
        let y = *a.type_at(t);
        let l = *a.const_lin_at(y.as_data.inst);
        let mut v = l.k;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c == 0 {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            // bindings try innermost-first with backtracking, but a frame's payload resolves only
            // through frames BELOW it (its env when pushed) -- a width bound to a derived
            // expression of itself must apply exactly once, grounding in the outer value
            let mut bv: i64 = 0;
            let mut got = false;
            let mut k = lim;
            while k > 0 && !got {
                k -= 1;
                let sb = *self.subs.at(k);
                if sb.pm != pd.module || sb.pnode != pd.node {
                    continue;
                }
                let kl = if sb.lim as usize < k {
                    sb.lim as usize;
                } else {
                    k;
                };
                let mut rm = sb.am;
                let mut rt = sb.at;
                if !self.resolve_from(sb.am, sb.at, &mut rm, &mut rt, 0, kl) {
                    continue;
                }
                let by = *self.p().module_ast_const(rm).type_at(rt);
                if by.kind == TypeKind::TYPE_CONST {
                    bv = by.as_data.value;
                    got = true;
                } else if by.kind == TypeKind::TYPE_CONST_EXPR {
                    if self.fold_cexpr_d(rm, rt, &mut bv, depth + 1, kl) {
                        got = true;
                    }
                }
            }
            if !got {
                // a term naming a module CONST (not a generic param): the evaluator has its value
                let pa = self.p().module_ast_const(pd.module);
                if pa.at_const(pd.node).kind == NodeKind::NODE_CONST && self.p().ceval != null {
                    let cev = unsafe &mut *(self.p().ceval as *mut ce::ConstEval);
                    let cv = cev.eval(pd.module, pa.at_const(pd.node).as_data.const_def.value);
                    if cv.kind == ce::CONST_INT {
                        v += cv.as_data.i * c;
                        continue;
                    }
                }
                return false;
            }
            v += bv * c;
        }
        if lin_div_of(&l) != 1 {
            let folded = ConstLin { k: v, n: 0, div: l.div };
            v = lin_value(&folded);
        }
        *out_val = v;
        return true;
    }

    // Innermost-wins resolution of `(pm, t)` through the substitution stack: TYPE_GENERIC hops to
    // its binding's pool; anything else stays put. Returns false when an unbound param remains.
    pub fn resolve(self: &Self, pm: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        return self.resolve_from(pm, t, rm, rt, 0, self.subs.len());
    }

    /// Substitution-free-memoized classification behind `is_zst`/`erased`: one resolve + one
    /// (cached) layout query per (module, type). Instance emission (subs active) bypasses the memo
    /// -- the same pool TypeId legitimately resolves differently per instantiation.
    pub fn zclass(self: &mut Self, pm: ModuleId, t: TypeId) u64 {
        let memoable = self.subs.len() == 0;
        // mixed key: the map hashes u64 identically, and unmixed (module << 32 | type) keys
        // collide across modules in the masked low bits (probe chains grow with module count)
        let key = skey_mix(0, pm as u64 << 32 | t as u64);
        if memoable {
            switch self.zmemo.get(&key) {
                Some(v) => {
                    return *v;
                },
                None => {},
            };
        }
        let mut rm = pm;
        let mut rt = t;
        if !self.resolve(pm, t, &mut rm, &mut rt) {
            rm = pm;
            rt = t;
        }
        let y = *self.p().module_ast_const(rm).type_at(rt);
        let mut v: u64 = 1;
        if y.kind == TypeKind::TYPE_NEVER || y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID {
            v = v | 4;
        } else if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_FUNCTION && y.kind != TypeKind::TYPE_DYN {
            let lo = self.lay.layout(rm, rt);
            if lo.ok && lo.size == 0 {
                v = v | 2;
            }
        }
        if memoable {
            self.zmemo.insert(key, v);
        }
        return v;
    }

    /// Final-layout zero-sized test under the active substitution env (storage elision is a pure
    /// function of layout, never syntax). Scalar and pointer kinds can never be zero-sized, so
    /// only aggregate-shaped types pay for resolution and a (cached) layout query. The answer is
    /// an ABI decision every emission site must agree on: it is deterministic per concrete type,
    /// and unresolvable/unlayoutable types uniformly answer material.
    pub fn is_zst(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        if t == TYPE_NONE || self.macro_on {
            return false; // macro templates keep unresolved params: no per-instance layout exists
        }
        let k = self.p().module_ast_const(pm).type_at(t).kind;
        if k == TypeKind::TYPE_BUILTIN || k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_FUNCTION || k == TypeKind::TYPE_DYN {
            return false;
        }
        return (self.zclass(pm, t) & 2) != 0;
    }

    // Innermost-wins WITH BACKTRACKING: merged demand chains can bind one param both to a sibling
    // generic (a cycle that never grounds) and, further out, to the real concrete type -- when the
    // innermost route dead-ends, the next-outer binding of the same param is tried. A matched
    // frame's payload resolves only through frames BELOW it (its env when pushed), so a param
    // bound to a derived spelling of itself substitutes exactly once.
    fn resolve_from(self: &Self, pm: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId, guard: u32, lim: usize) bool {
        let y = *self.p().module_ast_const(pm).type_at(t);
        if y.kind != TypeKind::TYPE_GENERIC {
            *rm = pm;
            *rt = t;
            return true;
        }
        if guard > 16 {
            return false;
        }
        let mut i = lim;
        while i > 0 {
            i -= 1;
            let sb = *self.subs.at(i);
            if sb.pm == y.module && sb.pnode == y.as_data.decl {
                let il = if sb.lim as usize < i {
                    sb.lim as usize;
                } else {
                    i;
                };
                if self.resolve_from(sb.am, sb.at, rm, rt, guard + 1, il) {
                    return true;
                }
            }
        }
        return false;
    }

    // A module mangles as just its last path segment when no other non-prelude module shares that
    // basename; collisions keep the full form for every involved module.
    fn short_pfx(self: &mut Self, m: ModuleId) bool {
        if self.short_ok.len() == 0 {
            for _i in 0..self.p().modules.len() {
                self.short_ok.push(0u8);
            }
        }
        let cached = self.short_ok[m as usize];
        if cached != 0 {
            return cached == 2;
        }
        let path = self.p().modules.at(m as usize).path.as_str();
        let bs = path_base_start(path);
        let mut ok = bs != 0;
        if ok {
            let base = path.slice(bs, path.len());
            for o in 0..self.p().modules.len() {
                if o == m as usize || self.p().modules.at(o).prelude {
                    continue;
                }
                let op = self.p().modules.at(o).path.as_str();
                if op.slice(path_base_start(op), op.len()) == base {
                    ok = false;
                    break;
                }
            }
        }
        self.short_ok.set(m as usize, if_u8(ok, 2, 1));
        return ok;
    }

    /// `""` | `<seg>__` | `<a>__<b>__` -- the module prefix of every prefixed symbol.
    /// Record the cross-TU edge for module `m` exactly as spelling it would (replay path for
    /// memoized renders).
    pub fn mark_used(self: &mut Self, m: ModuleId) {
        if m as i64 != self.mark_ctx {
            let src = if self.mark_ctx < 0 {
                65534u64;
            } else {
                self.mark_ctx as u64;
            };
            let edge = src << 32 | m as u64;
            if edge != self.last_edge {
                self.last_edge = edge;
                self.um_set(src, m);
            }
        }
    }

    fn um_set(self: &mut Self, src: u64, dst: ModuleId) {
        let n = self.p().modules.len();
        if n == 0 {
            return;
        }
        if self.used_mods.len() == 0 {
            self.used_mods.resize_default((n + 1) * n);
        }
        let row = if src == 65534u64 {
            n;
        } else {
            src as usize;
        };
        self.used_mods.set(row * n + dst as usize, 1);
    }

    /// Was a (spelling TU `src` -> module `dst`) edge recorded? `src` 65534 = the instance TU.
    pub fn um_hit(self: &Self, src: u64, dst: usize) bool {
        if self.used_mods.len() == 0 {
            return false;
        }
        let n = self.p().modules.len();
        let row = if src == 65534u64 {
            n;
        } else {
            src as usize;
        };
        return *self.used_mods.at(row * n + dst) != 0;
    }

    pub fn modpfx(self: &mut Self, m: ModuleId, out: &mut String) {
        if self.edge_log_on {
            self.edge_log.push(m);
        }
        if m as i64 != self.mark_ctx {
            // a cross-TU symbol spelling: record the (spelling TU -> owner module) edge so the
            // writer can prune TUs no KEPT TU references (65534 = the shared instance TU)
            let src = if self.mark_ctx < 0 {
                65534u64;
            } else {
                self.mark_ctx as u64;
            };
            let edge = src << 32 | m as u64;
            if edge != self.last_edge {
                self.last_edge = edge;
                self.um_set(src, m);
            }
        }
        if !self.mangle || self.p().modules.at(m as usize).prelude {
            return;
        }
        let path = self.p().modules.at(m as usize).path.as_str();
        let n = path.len();
        let mut i: usize = 0;
        if self.short_pfx(m) {
            i = path_base_start(path);
        }
        while i < n {
            if path.byte_at(i) == b':' && i + 1 < n && path.byte_at(i + 1) == b':' {
                out.push_str("__");
                i += 2;
            } else {
                out.push_byte(path.byte_at(i));
                i += 1;
            }
        }
        out.push_str("__");
    }

    /// The identifier at `s` in module `m`'s source, C-keyword-suffixed with one `_` when needed.
    pub fn ident(self: &mut Self, m: ModuleId, s: tok::Span, out: &mut String) {
        let src = self.p().modules.at(m as usize).source.as_str();
        let txt = src.slice(s.start as usize, s.end as usize);
        out.push_str(txt);
        if c_keyword(txt) {
            out.push_str("_");
        }
    }

    /// `<modpfx><Ident>` where the ident is `name_node`'s name span in its owner module.
    pub fn qualified(self: &mut Self, owner: ModuleId, name_node: NodeId, out: &mut String) {
        self.modpfx(owner, out);
        let s = self.p().module_ast_const(owner).at_const(name_node).as_data.name.text;
        self.ident(owner, s, out);
    }

    /// `<modpfx>closure_<node>` -- a hoisted closure's C symbol (generic-instantiation suffixes are
    /// appended by the caller that knows the instantiation).
    pub fn closure_sym(self: &mut Self, m: ModuleId, id: NodeId, out: &mut String) {
        self.modpfx(m, out);
        out.push_str("closure_");
        out.push_u64(id);
        if self.clos_sfx.len() != 0 {
            for i in 0..self.clos_ids.len() {
                if *self.clos_ids.at(i) == id {
                    out.push_string(&self.clos_sfx);
                    break;
                }
            }
        }
    }

    /// The symbol-alphabet spelling of pool type `(pm, t)`. False when `t` is outside the frozen
    /// subset (symbolic, or a form not yet frozen); `out` may then hold a partial spelling the
    /// caller must discard.
    pub fn type_m(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            out.push_str(bt_mangle(y.as_data.builtin));
            return true;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let nm = self.p().module_ast_const(y.module).at_const(y.as_data.decl).as_data.aggregate.name;
            self.qualified(y.module, nm, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            // `&T` and `&mut T` are distinct C types (`const T*` vs `T*`), so they mangle apart.
            let mut is_const = y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
            if y.kind == TypeKind::TYPE_REFERENCE {
                is_const = y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            out.push_str(if_str(is_const, "ptr_", "ptrm_"));
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_SLICE {
            out.push_str("slice_");
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len != 0 {
                out.push_str("arr");
                out.push_u64(y.as_data.arr.len);
                out.push_str("_");
            } else {
                out.push_str("arr_");
            }
            return self.type_m(pm, y.as_data.arr.elem, out);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            return self.inst_name(pm, &it, out);
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let fd = self.p().module_ast_const(y.module).at_const(y.as_data.decl);
            if fd.kind == NodeKind::NODE_FUNCTION {
                self.qualified(y.module, fd.as_data.function.name, out);
                return true;
            }
            if fd.kind == NodeKind::NODE_CLOSURE {
                self.closure_sym(y.module, y.as_data.decl, out);
                return true;
            }
            out.push_str("fnt");
            out.push_u64(y.module);
            out.push_str("_");
            out.push_u64(y.as_data.decl);
            return true;
        }
        if y.kind == TypeKind::TYPE_CONST {
            out.push_i64(y.as_data.value);
            return true;
        }
        if y.kind == TypeKind::TYPE_FIELD_PROJECTION {
            // Reaching the mangler unresolved is an upstream bug; the distinctive symbol makes the
            // C error name the problem (mirrors the established emitter).
            out.push_str("__sc_unresolved_field_projection_");
            out.push_u64(y.as_data.proj.binder);
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                out.push_str("dynm_");
            } else if y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                out.push_str("dyn_");
            } else {
                out.push_str("dynb_");
            }
            return self.dyn_stem(pm, &y, out);
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            // const-bound params fold HERE: each frame's payload grounds strictly below its own
            // env boundary (resolve-then-fold would re-apply the frame on its own payload)
            let mut cv: i64 = 0;
            if self.fold_generic_d(&y, &mut cv, 0, self.subs.len()) {
                out.push_i64(cv);
                return true;
            }
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            if self.resolve(pm, t, &mut rm, &mut rt) {
                return self.type_m(rm, rt, out);
            }
            if self.macro_on {
                out.push_byte(1);
                out.push_str("_SCM_");
                self.generic_param_name(&y, out);
                return true;
            }
            return false; // unbound params never name symbols
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let mut v: i64 = 0;
            if !self.fold_cexpr(pm, t, &mut v) {
                return false;
            }
            out.push_i64(v);
            return true;
        }
        out.push_str("v");
        return true;
    }

    /// The source name of the generic-param decl behind an unresolved TYPE_GENERIC.
    fn generic_param_name(self: &mut Self, y: &Ty, out: &mut String) {
        let da = self.p().module_ast_const(y.module);
        let pn = da.at_const(y.as_data.decl);
        self.ident(y.module, da.at_const(pn.as_data.generic_param.name).as_data.name.text, out);
    }

    /// True when `(pm, t)` is the prelude `Global` allocator type (the trailing-arg elision rule).
    pub const fn is_global(self: &Self, pm: ModuleId, t: TypeId) bool {
        let y = *self.p().module_ast_const(pm).type_at(t);
        return y.kind == TypeKind::TYPE_STRUCT && y.module == self.ph_global.mid && y.as_data.decl == self.ph_global.node;
    }

    /// The dyn family's shared stem: the qualified interface (or the structural `dynfn` signature
    /// spelling), then each instance argument -- deliberately NOT resolved, mirroring the
    /// established emitter.
    pub fn dyn_stem(self: &mut Self, pm: ModuleId, dy: &Ty, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let it = *a.instance(dy.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        let fn2 = da.at_const(it.decl);
        if fn2.kind != NodeKind::NODE_FUNCTION_TYPE {
            self.qualified(it.module, fn2.as_data.interface_def.name, out);
        } else {
            let ftp = fn2.as_data.function_type;
            out.push_str("dynfn");
            for i in 0..ftp.params.len {
                let pid = unsafe da.list(ftp.params)[i as usize];
                out.push_str("__");
                if !self.type_m(it.module, da.type_of(pid), out) {
                    return false;
                }
            }
            if ftp.returns.len == 1 {
                let r0 = unsafe da.list(ftp.returns)[0];
                let rn = da.at_const(r0);
                let mut tn = r0;
                if rn.kind == NodeKind::NODE_PARAMETER {
                    tn = rn.as_data.parameter.ty;
                }
                out.push_str("__r_");
                if !self.type_m(it.module, da.type_of(tn), out) {
                    return false;
                }
            }
        }
        for i in 0..it.n {
            out.push_str("__");
            if !self.type_m(pm, unsafe it.args[i as usize], out) {
                return false;
            }
        }
        return true;
    }

    // A non-capturing function value's C declarator: `<ret> (*<decl>)(<params>)`, array params
    // forced const (they decay, so the immutable binding's const lands on the element). Reads the
    // declaring pool directly -- pool-parametric spelling needs no reintern.
    fn fn_ptr_ctype(self: &mut Self, y: &Ty, decl: str, out: &mut String) bool {
        let fa = self.p().module_ast_const(y.module);
        let fnn = *fa.at_const(y.as_data.decl);
        let mut ps = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        let mut body = NODE_NONE;
        if fnn.kind == NodeKind::NODE_FUNCTION {
            ps = fnn.as_data.function.params;
            rs = fnn.as_data.function.returns;
        } else if fnn.kind == NodeKind::NODE_CLOSURE {
            ps = fnn.as_data.closure.params;
            rs = fnn.as_data.closure.returns;
            if fnn.as_data.closure.expr_body {
                body = fnn.as_data.closure.body;
            }
        } else {
            ps = fnn.as_data.function_type.params;
            rs = fnn.as_data.function_type.returns;
        }
        let mut params = String::new();
        let mut ok = true;
        for i in 0..ps.len {
            let pid = unsafe fa.list(ps)[i as usize];
            let pn = fa.at_const(pid);
            let mut tn = pid;
            if pn.kind == NodeKind::NODE_PARAMETER {
                tn = pn.as_data.parameter.ty;
            }
            let mut anchor = tn;
            if tn == NODE_NONE {
                anchor = pid;
            }
            let pty = fa.type_of(anchor);
            if self.is_zst(y.module, pty) {
                continue; // zero-sized by-value params take no slot (must match every lowered sig)
            }
            if params.len() != 0 {
                params.push_str(", ");
            }
            if !self.ctype(y.module, pty, "", &mut params) {
                ok = false;
                break;
            }
        }
        if !ok {
            return false;
        }
        let mut inner = String::from_str("(*");
        inner.push_str(decl);
        inner.push_str(")(");
        if params.len() == 0 {
            inner.push_str("void");
        } else {
            inner.push_string(&params);
        }
        inner.push_str(")");

        if rs.len == 1 {
            let r0 = unsafe fa.list(rs)[0];
            let rn = fa.at_const(r0);
            let mut rtn = r0;
            if rn.kind == NodeKind::NODE_PARAMETER {
                rtn = rn.as_data.parameter.ty;
            }
            if self.is_zst(y.module, fa.type_of(rtn)) {
                out.push_str("void ");
                out.push_string(&inner);
            } else {
                ok = self.ctype(y.module, fa.type_of(rtn), inner.as_str(), out);
            }
        } else if rs.len == 0 {
            let mut rty = TYPE_NONE;
            if body != NODE_NONE {
                rty = fa.type_of(body);
            }
            if rty != TYPE_NONE {
                ok = self.ctype(y.module, rty, inner.as_str(), out);
            } else {
                out.push_str("void ");
                out.push_string(&inner);
            }
        } else {
            ok = false; // multi-return function pointers are unsupported everywhere
        }
        return ok;
    }

    /// A `@c.export`/`@c.import` symbol pin: the attribute string verbatim. False when `owner`
    /// carries neither.
    pub fn sym_override(self: &mut Self, m: ModuleId, owner: NodeId, out: &mut String) bool {
        let a = self.p().module_ast_const(m);
        for i in 0..unsafe a.attrs.len() {
            let at = unsafe a.attrs.at(i);
            if at.owner != owner {
                continue;
            }
            if at.kind == AttrKind::ATTR_EXPORT as u8 || at.kind == AttrKind::ATTR_IMPORT as u8 {
                let src = self.p().modules.at(m as usize).source.as_str();
                out.push_str(src.slice(at.str_span.start as usize, at.str_span.end as usize));
                return true;
            }
        }
        return false;
    }

    // The number of `from`/`try_from` (or same-named) methods across all extends targeting
    // (tmod, tdecl), scanning the target's module then `cur` -- the established two-module
    // compromise for overload counting without a package-wide walk. `name` is a span in `nmod`.
    fn overload_count(self: &mut Self, cur: ModuleId, tmod: ModuleId, tdecl: NodeId, nmod: ModuleId, name: tok::Span) i32 {
        let ntxt = self.p().modules.at(nmod as usize).source.as_str().slice(name.start as usize, name.end as usize);
        let mut key = 1469598103934665603u64;
        key = (key ^ cur as u64) * 1099511628211u64;
        key = (key ^ tmod as u64) * 1099511628211u64;
        key = (key ^ tdecl as u64) * 1099511628211u64;
        for i in 0..ntxt.len() {
            key = (key ^ ntxt.byte_at(i) as u64) * 1099511628211u64;
        }
        let hit = switch self.ovl_memo.get(&key) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if hit >= 0 {
            return hit as i32;
        }
        let mut n: i32 = 0;
        let mut ns = 2;
        if tmod == cur {
            ns = 1;
        }
        for s in 0..ns {
            let mut m = tmod;
            if s == 1 {
                m = cur;
            }
            let a = self.p().module_ast_const(m);
            let msrc = self.p().modules.at(m as usize).source.as_str();
            let items = unsafe a.at_const(a.root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe a.list(items)[i as usize];
                let it = a.at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tg = a.resolution_def(it.as_data.extend_def.target_type);
                if tg.module != tmod || tg.node != tdecl {
                    continue;
                }
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe a.list(ms)[j as usize];
                    let mn = a.at_const(mid);
                    if mn.kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let s2 = a.at_const(mn.as_data.function.name).as_data.name.text;
                    if msrc.slice(s2.start as usize, s2.end as usize) == ntxt {
                        n += 1;
                    }
                }
            }
        }
        self.ovl_memo.insert(key, n as u64);
        return n;
    }

    // Collision-conditional conformance suffix: when several extends of one target define the same
    // method name through different interface instantiations, the symbol carries the interface
    // name and its type arguments. `from`/`try_from` keep the param-derived conv suffix instead.
    fn iface_suffix(self: &mut Self, fm: ModuleId, fnode: NodeId, out: &mut String) bool {
        let ext = (self.owner_of(fm, fnode) >> 32) as NodeId;
        let a = self.p().module_ast_const(fm);
        if ext == NODE_NONE {
            return true;
        }
        let ity = a.at_const(ext).as_data.extend_def.interface_type;
        if ity == NODE_NONE {
            return true;
        }
        let name = a.at_const(a.at_const(fnode).as_data.function.name).as_data.name.text;
        let src = self.p().modules.at(fm as usize).source.as_str();
        let ntxt = src.slice(name.start as usize, name.end as usize);
        if ntxt == "from" || ntxt == "try_from" {
            return true;
        }
        let tg = a.resolution_def(a.at_const(ext).as_data.extend_def.target_type);
        if tg.node == NODE_NONE || self.overload_count(fm, tg.module, tg.node, fm, name) < 2 {
            return true;
        }
        let tr = a.resolution_def(ity);
        if tr.node == NODE_NONE {
            return true;
        }
        out.push_str("__");
        let inm = self.p().module_ast_const(tr.module).at_const(tr.node).as_data.interface_def.name;
        self.ident(tr.module, self.p().module_ast_const(tr.module).at_const(inm).as_data.name.text, out);
        if a.at_const(ity).kind != NodeKind::NODE_TYPE_PATH {
            return true;
        }
        let args = a.at_const(ity).as_data.type_path.args;
        for i in 0..args.len {
            let aid = unsafe a.list(args)[i as usize];
            if a.at_const(aid).kind == NodeKind::NODE_LIFETIME {
                continue;
            }
            let t = a.type_of(aid);
            if t == TYPE_NONE {
                continue;
            }
            out.push_str("__");
            if !self.type_m(fm, t, out) {
                return false;
            }
        }
        return true;
    }

    /// The C symbol of function `fnode` (module `fm`) with resolved extend target `target`
    /// (`target.node == NODE_NONE` = free function): pin | `[modpfx][Target__]name[suffix]`.
    pub fn fn_sym(self: &mut Self, fm: ModuleId, fnode: NodeId, target: DefId, prefixed: bool, out: &mut String) bool {
        if self.sym_override(fm, fnode, out) {
            return true;
        }
        let a = self.p().module_ast_const(fm);
        let fname = a.at_const(a.at_const(fnode).as_data.function.name).as_data.name.text;
        if a.at_const(fnode).as_data.function.is_extern {
            // an extern function IS its C symbol: never prefixed, never suffixed
            self.ident(fm, fname, out);
            return true;
        }
        let src = self.p().modules.at(fm as usize).source.as_str();
        let ftxt = src.slice(fname.start as usize, fname.end as usize);
        let is_main = target.node == NODE_NONE && ftxt == "main";
        if prefixed && !is_main {
            self.modpfx(fm, out);
        }
        if target.node != NODE_NONE {
            let bb = self.p().builtin_of_decl(target.module, target.node);
            if bb >= 0 {
                out.push_str(bt_mangle(bb as BuiltinType));
            } else {
                let dn = self.p().module_ast_const(target.module).at_const(target.node);
                let mut nm = dn.as_data.aggregate.name;
                if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                    nm = dn.as_data.type_alias.name;
                }
                self.ident(target.module, self.p().module_ast_const(target.module).at_const(nm).as_data.name.text, out);
            }
            out.push_str("__");
        }
        self.ident(fm, fname, out);
        let params = a.at_const(fnode).as_data.function.params;
        let is_conv = ftxt == "from" || ftxt == "try_from";
        if is_conv && target.node != NODE_NONE && params.len != 0 {
            if self.overload_count(fm, target.module, target.node, fm, fname) < 2 {
                return true;
            }
            let p0 = unsafe a.list(params)[0];
            let p0ty = a.type_of(a.at_const(p0).as_data.parameter.ty);
            if p0ty == TYPE_NONE {
                return true;
            }
            out.push_str("__");
            return self.type_m(fm, p0ty, out);
        }
        if target.node != NODE_NONE {
            return self.iface_suffix(fm, fnode, out);
        }
        return true;
    }

    /// The resolved extend target of method `fnode` in module `m`, or `node == NODE_NONE` when the
    /// function is free-standing. Plan-time item scan.
    pub fn method_target(self: &mut Self, m: ModuleId, fnode: NodeId) DefId {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return DefId { module: m, node: NODE_NONE };
        }
        let a = self.p().module_ast_const(m);
        if a.at_const(ext).as_data.extend_def.target_type == NODE_NONE {
            return DefId { module: m, node: NODE_NONE };
        }
        return a.resolution_def(a.at_const(ext).as_data.extend_def.target_type);
    }

    /// The generics list of the extend owning `fnode` (empty when free-standing).
    pub fn extend_generics(self: &mut Self, m: ModuleId, fnode: NodeId) NodeList {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return NodeList { start: 0, len: 0 };
        }
        return self.p().module_ast_const(m).at_const(ext).as_data.extend_def.generics;
    }

    /// The interface declaring member `fnode` (its default body emits per conforming type), or
    /// NODE_NONE when the function is not an interface member.
    pub fn in_interface(self: &mut Self, m: ModuleId, fnode: NodeId) NodeId {
        return (self.owner_of(m, fnode) & 0xFFFFFFFF) as NodeId;
    }

    /// Does the extend that owns `fnode` declare generic parameters (its methods emit per receiver
    /// instance, outside the frozen non-generic symbol families)?
    pub fn in_generic_extend(self: &mut Self, m: ModuleId, fnode: NodeId) bool {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return false;
        }
        return self.p().module_ast_const(m).at_const(ext).as_data.extend_def.generics.len != 0;
    }

    /// The C symbol of const/static item `cnode` (module `m`) read from a TU of module `em`:
    /// top-level items spell their qualified name; associated consts are per-TU statics prefixed
    /// with the EMITTING module (the established reader/emitter agreement).
    pub fn const_sym(self: &mut Self, em: ModuleId, m: ModuleId, cnode: NodeId, out: &mut String) bool {
        if self.sym_override(m, cnode, out) {
            return true;
        }
        let a = self.p().module_ast_const(m);
        if a.at_const(cnode).kind == NodeKind::NODE_CONST && a.at_const(cnode).as_data.const_def.is_extern {
            // an extern-block static binds the C symbol the header declares
            self.ident(m, a.at_const(a.at_const(cnode).as_data.const_def.name).as_data.name.text, out);
            return true;
        }
        let tgt = self.method_target(m, cnode);
        if tgt.node == NODE_NONE {
            self.qualified(m, a.at_const(cnode).as_data.const_def.name, out);
            return true;
        }
        self.modpfx(em, out);
        let bb = self.p().builtin_of_decl(tgt.module, tgt.node);
        if bb >= 0 {
            out.push_str(bt_mangle(bb as BuiltinType));
        } else {
            let dn = self.p().module_ast_const(tgt.module).at_const(tgt.node);
            let mut nm = dn.as_data.aggregate.name;
            if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                nm = dn.as_data.type_alias.name;
            }
            self.ident(tgt.module, self.p().module_ast_const(tgt.module).at_const(nm).as_data.name.text, out);
        }
        out.push_str("__");
        self.ident(m, a.at_const(a.at_const(cnode).as_data.const_def.name).as_data.name.text, out);
        return true;
    }

    /// The name span of binding decl `decl` in module `m` (let/parameter/for/pattern/identifier
    /// shapes -- the capture-entry set), empty when the shape is unknown.
    pub const fn decl_name_span(self: &mut Self, m: ModuleId, decl: NodeId) tok::Span {
        let a = self.p().module_ast_const(m);
        let n = a.at_const(decl);
        if n.kind == NodeKind::NODE_LET {
            return a.at_const(n.as_data.let_stmt.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_PARAMETER {
            return a.at_const(n.as_data.parameter.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_FOR || n.kind == NodeKind::NODE_INLINE_FOR {
            return a.at_const(n.as_data.for_stmt.binding).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_PATTERN_NAME {
            return a.at_const(n.as_data.pattern.name).as_data.name.text;
        }
        if n.kind == NodeKind::NODE_IDENTIFIER {
            return n.as_data.name.text;
        }
        return tok::Span { start: 0, end: 0 };
    }

    /// The C symbol of the method named `mname` extending resolved aggregate `(rm, rt)`, when one
    /// exists: instance receivers spell `<InstName>__<m>`, concrete ones the frozen fn symbol.
    pub fn method_by_name(self: &mut Self, rm: ModuleId, rt: TypeId, mname: str, out: &mut String) bool {
        self.last_method_def = DefId { module: 0, node: NODE_NONE };
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE {
            if y.kind == TypeKind::TYPE_BUILTIN {
                // builtin receivers: their extends usually live in the prelude, but any module
                // may extend a builtin (std::parallel's AtomicOps conformances do)
                let bt = y.as_data.builtin as i32;
                for pm2 in 0..self.p().modules.len() {
                    if !self.p().modules.at(pm2).has_ast {
                        continue;
                    }
                    let pa = self.p().module_ast_const(pm2 as ModuleId);
                    let pits = unsafe pa.at_const(pa.root).as_data.program.items;
                    let psrc = self.p().modules.at(pm2).source.as_str();
                    for i2 in 0..pits.len {
                        let iid2 = unsafe pa.list(pits)[i2 as usize];
                        let it2 = pa.at_const(iid2);
                        if it2.kind != NodeKind::NODE_EXTEND || it2.as_data.extend_def.target_type == NODE_NONE {
                            continue;
                        }
                        let tg2 = pa.resolution_def(it2.as_data.extend_def.target_type);
                        if tg2.node == NODE_NONE || self.p().builtin_of_decl(tg2.module, tg2.node) != bt {
                            continue;
                        }
                        let ms2 = it2.as_data.extend_def.items;
                        for j2 in 0..ms2.len {
                            let mid2 = unsafe pa.list(ms2)[j2 as usize];
                            let mn2 = pa.at_const(mid2);
                            if mn2.kind != NodeKind::NODE_FUNCTION {
                                continue;
                            }
                            let s3 = pa.at_const(mn2.as_data.function.name).as_data.name.text;
                            if psrc.slice(s3.start as usize, s3.end as usize) == mname {
                                self.last_method_def = DefId { module: pm2 as ModuleId, node: mid2 };
                                return self.fn_sym(pm2 as ModuleId, mid2, tg2, true, out);
                            }
                        }
                    }
                }
            }
            return false;
        }
        // extends may live in ANY module (a downstream module extending a foreign type): the
        // decl's own module first (the overwhelmingly common case), then the rest
        let mut xm: i64 = 0 - 1;
        while xm < self.p().modules.len() as i64 {
            let em2 = if xm < 0 {
                dm;
            } else {
                xm as ModuleId;
            };
            xm += 1;
            if xm > 0 && em2 == dm {
                continue; // already scanned first
            }
            if !self.p().modules.at(em2 as usize).has_ast {
                continue;
            }
            let da = self.p().module_ast_const(em2);
            let items = unsafe da.at_const(da.root).as_data.program.items;
            let dsrc = self.p().modules.at(em2 as usize).source.as_str();
            for i in 0..items.len {
                let iid = unsafe da.list(items)[i as usize];
                let itn = da.at_const(iid);
                if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tg = da.resolution_def(itn.as_data.extend_def.target_type);
                if tg.module != dm || tg.node != dd {
                    continue;
                }
                let ms = itn.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe da.list(ms)[j as usize];
                    let mn = da.at_const(mid);
                    if mn.kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let s2 = da.at_const(mn.as_data.function.name).as_data.name.text;
                    if dsrc.slice(s2.start as usize, s2.end as usize) == mname {
                        self.last_method_def = DefId { module: em2, node: mid };
                        if y.kind == TypeKind::TYPE_INSTANCE {
                            let it2 = *a.instance(y.as_data.inst);
                            if !self.inst_name(rm, &it2, out) {
                                return false;
                            }
                            out.push_str("__");
                            out.push_str(mname);
                            return true;
                        }
                        return self.fn_sym(em2, mid, DefId { module: dm, node: dd }, true, out);
                    }
                }
            }
        }
        return false;
    }

    /// The destructor call target for resolved aggregate type `(rm, rt)`: the user `free` method
    /// when one extends the declaration, else the derived per-TU glue `<name>__free__d`.
    pub fn free_target(self: &mut Self, rm: ModuleId, rt: TypeId, out: &mut String) bool {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE {
            return false;
        }
        // plan-time scan: a `free` method in any extend of the declaration (its own module)
        let da = self.p().module_ast_const(dm);
        let items = unsafe da.at_const(da.root).as_data.program.items;
        let dsrc = self.p().modules.at(dm as usize).source.as_str();
        for i in 0..items.len {
            let iid = unsafe da.list(items)[i as usize];
            let itn = da.at_const(iid);
            if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE {
                continue;
            }
            let tg = da.resolution_def(itn.as_data.extend_def.target_type);
            if tg.module != dm || tg.node != dd {
                continue;
            }
            let ms = itn.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe da.list(ms)[j as usize];
                let mn = da.at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let s2 = da.at_const(mn.as_data.function.name).as_data.name.text;
                if dsrc.slice(s2.start as usize, s2.end as usize) == "free" {
                    if y.kind == TypeKind::TYPE_INSTANCE {
                        let it2 = *a.instance(y.as_data.inst);
                        if !self.inst_name(rm, &it2, out) {
                            return false;
                        }
                        out.push_str("__free");
                        return true;
                    }
                    return self.fn_sym(dm, mid, DefId { module: dm, node: dd }, true, out);
                }
            }
        }
        if !self.type_m(rm, rt, out) {
            return false;
        }
        out.push_str("__free__d");
        return true;
    }

    /// The C constant naming variant `variant` of enum `decl` in module `m`: RAW source spans
    /// (deliberately no keyword suffix, unlike the enum's own typedef name); extern enums use the
    /// header's bare variant constant.
    pub fn enum_tag(self: &mut Self, m: ModuleId, decl: NodeId, variant: NodeId, out: &mut String) {
        let a = self.p().module_ast_const(m);
        let src = self.p().modules.at(m as usize).source.as_str();
        let vs = a.at_const(a.at_const(variant).as_data.variant.name).as_data.name.text;
        if a.at_const(decl).as_data.aggregate.is_extern {
            out.push_str(src.slice(vs.start as usize, vs.end as usize));
            return;
        }
        self.modpfx(m, out);
        let es = a.at_const(a.at_const(decl).as_data.aggregate.name).as_data.name.text;
        out.push_str(src.slice(es.start as usize, es.end as usize));
        out.push_str("_");
        out.push_str(src.slice(vs.start as usize, vs.end as usize));
    }

    // `<base><sep><decl>` where the separator is empty for an empty or `[`-leading declarator.
    fn join_decl(self: &mut Self, base: str, decl: str, out: &mut String) {
        out.push_str(base);
        if decl.len() != 0 && decl.byte_at(0) != b'[' {
            out.push_str(" ");
        }
        out.push_str(decl);
    }

    /// The full C declarator `<type> <decl>` of pool type `(pm, t)` -- the established emitter's
    /// spelling, including east-const on pointer-to-pointer and array/function spirals. False when
    /// `t` needs an unfrozen family (dyn value types, non-capturing fn pointers).
    pub fn ctype(self: &mut Self, pm: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            self.join_decl(bt_c_decl(y.as_data.builtin), decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let dn = self.p().module_ast_const(y.module).at_const(y.as_data.decl);
            let mut nm = String::new();
            if dn.as_data.aggregate.is_extern {
                if !self.sym_override(y.module, y.as_data.decl, &mut nm) {
                    self.ident(
                        y.module,
                        self.p().module_ast_const(y.module).at_const(dn.as_data.aggregate.name).as_data.name.text,
                        &mut nm,
                    );
                }
            } else {
                self.qualified(y.module, dn.as_data.aggregate.name, &mut nm);
            }
            self.join_decl(nm.as_str(), decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            let mut elm = pm;
            let mut elt = y.as_data.elem;
            if !self.resolve(pm, y.as_data.elem, &mut elm, &mut elt) {
                elm = pm;
                elt = y.as_data.elem; // unbound param: fall through to the void spelling
            }
            let el = *self.p().module_ast_const(elm).type_at(elt);
            let mut cp = y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
            if y.kind == TypeKind::TYPE_REFERENCE {
                cp = y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            if el.kind == TypeKind::TYPE_ARRAY && self.is_zst(elm, el.as_data.arr.elem) {
                // C forbids an array declarator over an incomplete element: a pointer to a
                // zero-sized-element array spells as a bare data pointer (never dereferenced).
                let mut inner0 = String::new();
                inner0.push_str("*");
                inner0.push_str(decl);
                if cp {
                    out.push_str("const ");
                }
                out.push_str("void ");
                out.push_str(inner0.as_str());
                return true;
            }
            if el.kind == TypeKind::TYPE_ARRAY && el.as_data.arr.len != 0 {
                // Pointer-to-fixed-array spirals: `(*decl)[N]`, const prefixing the element type.
                let mut inner = String::new();
                inner.push_str("(*");
                inner.push_str(decl);
                inner.push_str(")[");
                inner.push_u64(el.as_data.arr.len);
                inner.push_str("]");
                let mut base = String::new();
                let ok = self.ctype(elm, el.as_data.arr.elem, inner.as_str(), &mut base);
                if cp && !(base.len() >= 6 && base.as_str().slice(0, 6) == "const ") {
                    out.push_str("const ");
                }
                out.push_string(&base);
                return ok;
            }
            let mut inner = String::new();
            if cp && el.kind == TypeKind::TYPE_POINTER {
                // The element is itself a pointer: `const` must qualify the POINTER (east:
                // `char *const *`), not its pointee (an illegal second-level qualifier).
                inner.push_str("const *");
            } else {
                inner.push_str("*");
            }
            inner.push_str(decl);
            if cp && el.kind != TypeKind::TYPE_POINTER {
                let mut base = String::new();
                let ok = self.ctype(elm, elt, inner.as_str(), &mut base);
                if !(base.len() >= 6 && base.as_str().slice(0, 6) == "const ") {
                    out.push_str("const ");
                }
                out.push_string(&base);
                return ok;
            }
            let ok = self.ctype(elm, elt, inner.as_str(), out);
            return ok;
        }
        if y.kind == TypeKind::TYPE_SLICE {
            self.join_decl("SCslice", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let mut inner = String::new();
            if y.as_data.arr.len != 0 {
                inner.push_str(decl);
                inner.push_str("[");
                inner.push_u64(y.as_data.arr.len);
                inner.push_str("]");
            } else {
                inner.push_str("*");
                inner.push_str(decl);
            }
            let ok = self.ctype(pm, y.as_data.elem, inner.as_str(), out);
            return ok;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            let mut nm = String::new();
            let ok = self.inst_name(pm, &it, &mut nm);
            if ok {
                self.join_decl(nm.as_str(), decl, out);
            }
            return ok;
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            // An opaque handle is spelled as C spells it: the `@c.import` pin when present (headers
            // that only declare the TAG need `struct x` written out), else the source name.
            let mut nm = String::new();
            if !self.sym_override(y.module, y.as_data.decl, &mut nm) {
                let dn = self.p().module_ast_const(y.module).at_const(y.as_data.decl);
                self.ident(
                    y.module,
                    self.p().module_ast_const(y.module).at_const(dn.as_data.type_alias.name).as_data.name.text,
                    &mut nm,
                );
            }
            self.join_decl(nm.as_str(), decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let fnn = self.p().module_ast_const(y.module).at_const(y.as_data.decl);
            if fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0 {
                let mut nm = String::new();
                self.closure_sym(y.module, y.as_data.decl, &mut nm);
                nm.push_str("_env");
                self.join_decl(nm.as_str(), decl, out);
                return true;
            }
            return self.fn_ptr_ctype(&y, decl, out);
        }
        if y.kind == TypeKind::TYPE_DYN {
            let mut nm = String::new();
            let ok = self.dyn_stem(pm, &y, &mut nm);
            if ok {
                nm.push_str("__dyn");
                self.join_decl(nm.as_str(), decl, out);
                self.dyn_reqs.push(DynReq { pm: pm, t: t });
                if self.rec_on {
                    let mut ev = RecEv::blank(RK_MDYN);
                    ev.a = pm;
                    ev.b = t;
                    self.rec.push(ev);
                }
            }
            return ok;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            if self.resolve(pm, t, &mut rm, &mut rt) {
                return self.ctype(rm, rt, decl, out);
            }
            if self.macro_on {
                let mut nm = String::new();
                self.generic_param_name(&y, &mut nm);
                self.join_decl(nm.as_str(), decl, out);
                return true;
            }
        }
        // TYPE_NEVER, TYPE_ERROR, unbound TYPE_GENERIC and every remaining kind spell as `void`.
        self.join_decl("void", decl, out);
        return true;
    }

    /// `<Qualified>[__<arg>...]` with trailing prelude-Global (default allocator) args elided:
    /// `String<Global>` -> `String`, `Vector<T, Global>` -> `Vector__T`.
    pub fn inst_name(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
        let base9 = out.len();
        let nm = self.p().module_ast_const(it.module).at_const(it.decl).as_data.aggregate.name;
        self.qualified(it.module, nm, out);
        let mut ne = it.n;
        while ne > 0 {
            let mut gm = pm;
            let mut gt = unsafe it.args[(ne - 1) as usize];
            if !self.resolve(pm, gt, &mut gm, &mut gt) {
                break;
            }
            let y = *self.p().module_ast_const(gm).type_at(gt);
            if self.ph_global.node != NODE_NONE && y.kind == TypeKind::TYPE_STRUCT && y.module == self.ph_global.mid && y.as_data.decl == self.ph_global.node {
                ne -= 1;
            } else {
                break;
            }
        }
        for i in 0..ne {
            out.push_str("__");
            if !self.type_m(pm, unsafe it.args[i as usize], out) {
                return false;
            }
        }
        if self.agg_on {
            let s9 = out.as_str();
            let mut h9 = 1469598103934665603u64;
            for k9 in base9..s9.len() {
                h9 = (h9 ^ s9.byte_at(k9) as u64) * 1099511628211u64;
            }
            let new9 = switch self.agg_seen.get(&h9) {
                Some(_v) => false,
                None => true,
            };
            if new9 {
                self.agg_seen.insert(h9, 1);
                let mut sn9 = Vector::<MSub>::new();
                for k9 in 0..self.subs.len() {
                    sn9.push(*self.subs.at(k9));
                }
                self.agg_reqs.push(AggReq { pm: pm, it: *it, subs: sn9 });
            }
            if self.rec_on && self.rec_dup_once(h9 ^ 14) {
                let mut ev = RecEv::blank(RK_AGG);
                ev.h = h9;
                ev.a = pm;
                ev.b = it.module;
                ev.c = it.decl;
                ev.d = it.n;
                for k9 in 0..it.n {
                    ev.xs.push(unsafe it.args[k9 as usize]);
                }
                for k9 in 0..self.subs.len() {
                    ev.subs.push(*self.subs.at(k9));
                }
                self.rec.push(ev);
            }
        }
        return true;
    }

    /// One journaled dup attempt per (gate key, current module): true the first time only.
    pub fn rec_dup_once(self: &mut Self, k: u64) bool {
        let mixed = k * 1099511628211u64 ^ self.mark_ctx as u64;
        if self.rec_dups.contains(&mixed) {
            return false;
        }
        self.rec_dups.insert(mixed);
        return true;
    }

    /// Journal replay of one recorded instance-spelling attempt: the same agg_seen gate the live
    /// spelling ran, so first-claimant order across cached and re-emitted modules stays exact.
    pub fn tuc_replay_agg(self: &mut Self, ev: &RecEv) {
        let hit = switch self.agg_seen.get(&ev.h) {
            Some(_v) => true,
            None => false,
        };
        if hit {
            return;
        }
        self.agg_seen.insert(ev.h, 1);
        let mut it = TyInstance { module: ev.b as ModuleId, decl: ev.c, n: ev.d as u8 };
        for k in 0..it.n {
            unsafe it.args[k as usize] = ev.xs[k as usize];
        }
        let mut sn = Vector::<MSub>::new();
        for k in 0..ev.subs.len() {
            sn.push(*ev.subs.at(k));
        }
        self.agg_reqs.push(AggReq { pm: ev.a as ModuleId, it: it, subs: sn });
    }
}

const fn if_str(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
const fn if_u8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}
