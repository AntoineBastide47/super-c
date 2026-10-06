// Core IR inliner: replaces qualifying direct TM_CALLs with the callee's lowered body so the
// caller-local BCE pass sees the callee's checks and guards. Runs on the emission path only, over ELABORATED bodies: the borrow pass rewrote
// every kept body with its drop terminators (`ir::drops`), so a callee splices in with its own
// drops, flag temps and storage markers, and no ownership analysis runs on the merged body (the
// caller was elaborated before its splices too). Argument operands are reused in place (read
// order preserved); every early return becomes a jump to one join block that moves the return
// slots into the call's destinations.
//
// Candidate policy (conservative, tuned for the std index family): direct non-variadic calls to
// known function bodies of at most MAX_CALLEE_STMTS statements / MAX_CALLEE_BLOCKS blocks,
// non-recursive through the active splice chain, without asm, closures, variadic intrinsics,
// reflection, asserts, wide literals, static references, or `from` coercions, and without
// attributes beyond the inline hints (@c.noinline and @c.noreturn therefore reject). Inner calls
// must target CONCRETE public functions or header-declared extern functions, and fn-value
// constants CONCRETE public functions -- anything else would need the
// emitter's demand machinery (symbols, prototypes, per-instantiation static_asserts) from a
// context the splice no longer has -- and a generic callee whose body defers a static_assert per
// instantiation stays a call so its demand still fires the guard. Generic callees inline when
// every generic parameter binds through the call (signature unification plus the recorded type
// arguments) and every body type substitutes into a package type; const-generic types do not
// substitute and reject the site. Never into a body holding IN_REFLECT binder placeholders.
//
// Spliced constants keep their raw spans and mark the callee module in `item` (the emitter's
// foreign-source convention for CK_STR, extended to CK_FLOAT and CK_INT); IR_NONE sentinels are
// preserved through every pool remap. Declared callee locals become LS_INL (a declared local of
// the merged body whose decl node lives in another module's syntax).
import ast::ast as *;
import lexer::token as tok;
import module::loader as loader;
import ir::layout as lay;
import ir::core as ir;
import ir::lower as irl;
import stdlib;

// Rejection reasons (SC_INLINE_STATS report order).
pub const IJ_NOT_FN: u8 = 0; // extern, bodiless, attributed, or not a plain function
pub const IJ_RECURSIVE: u8 = 1;
pub const IJ_SHAPE: u8 = 2; // asm/closure/reflect/assert/coercion/wide-literal body content
pub const IJ_TOO_BIG: u8 = 3;
pub const IJ_BUDGET: u8 = 4;
pub const IJ_DEPTH: u8 = 5;
pub const IJ_GENERIC: u8 = 6; // unbound generic parameter or untranslatable type
pub const IJ_ARITY: u8 = 7; // variadic call or argument/destination count mismatch
pub const IJ_COUNT: usize = 8;

/// Emission-mode env switches: every setting that changes the C a body renders to. Build stamps
/// and TU-cache keys read the list by index, so a new switch joins here once and every consumer
/// follows; the order is part of the recorded keys.
pub const EMIT_MODE_ENV_N: usize = 3;

pub fn emit_mode_env(i: usize) str<'static> {
    if i == 0 {
        return "SC_INLINE";
    }
    if i == 1 {
        return "SC_BCE";
    }
    assert(i == 2);
    return "SC_BCE_DISABLE";
}

const MAX_CALLEE_STMTS: usize = 40;
const MAX_CALLEE_BLOCKS: usize = 10;
const MAX_CALLEE_LOCALS: usize = 32;

/// The callee size gate over a body's current shape. The borrow pass records the answer for the
/// pre-elaboration shape in `CoreBody.inline_size_ok` (the shape the limits were tuned for), and
/// the vet reads that bit.
/// The blocks, statements and locals the counted-loop lowering added (`count_blocks`, `chunks`)
/// do not count.
pub const fn callee_size_ok(b: &ir::CoreBody) bool {
    let ns = b.statements.len() - 2 * b.chunks as usize;
    let nb = b.blocks.len() - b.count_blocks as usize;
    let nl = b.locals.len() - 2 * b.chunks as usize;
    return ns <= MAX_CALLEE_STMTS && nb <= MAX_CALLEE_BLOCKS && nl <= MAX_CALLEE_LOCALS;
}
/// Per caller body: total statements added by all splices (nested ones included).
const MAX_ADDED_STMTS: usize = 512;
/// Nested splice depth (a spliced call inlining its own calls).
const MAX_DEPTH: usize = 3;

// keep_ix value encoding: slot index, or REJ_BASE | reason for a cached rejection.
const REJ_BASE: u64 = 0xFFFFFFFF00000000u64;

/// One cached callee: its lowered, elaborated body plus the generic-parameter decl list in targ
/// order (extend parameters first, then the function's own).
struct CalleeInfo {
    pub body: ir::CoreBody,
    pub gp: Vector<NodeId>,
    pub fg: u32, // trailing entries of `gp` that are the function's own parameters
    pub demand: bool, // a generic body with a per-instantiation static_assert: the splice keeps the demand
}

/// One generic-parameter binding: `(pm, pnode)` resolves to the caller's type `at`.
struct GBind {
    pub pm: ModuleId,
    pub pnode: NodeId,
    pub at: TypeId,
}

/// Splice provenance of an appended block (recursion and depth guard for nested inlining).
struct Origin {
    pub parent: u32, // origin index of the block the call sat in; IR_NONE at top level
    pub key: u64, // callee identity key
}

pub struct InlineStats {
    pub considered: u32,
    pub inlined: u32,
    pub reasons: [u32; 8],
}

extend InlineStats {
    pub fn new() InlineStats {
        return InlineStats { considered: 0, inlined: 0, reasons: [[0] = 0u32] };
    }
}

/// The package's inline candidates: every kept env-free lowering vetted once before emission
/// (`build`; a verdict depends only on the body's own content), the accepted ones copied compact.
/// Read by every emission task through `Package.inl_store`; the kept bodies themselves move out to
/// the emitter and the body syntax is released, so this copy is the callee's only source.
pub struct InlineStore {
    pub keep_ix: Map<u64, u64>, // callee key -> kept slot, or REJ_BASE | reason
    pub kept: Vector<CalleeInfo>,
}

/// Per-DropCtx state: the type-translation caches over the shared store's slots, and the splice
/// scratch. Decisions depend only on body and AST content, never on cache state.
pub struct InlineCtx {
    pub off: bool,
    pub stats_on: bool,
    pub store: *const InlineStore,
    /// Type-translation cache: one entry per distinct (callee slot, caller module, binds) call
    /// shape. Filling a map walks the whole callee type table through `xty`; the same shape
    /// repeats at every call site of a callee, so the walk runs once per shape instead.
    pub xm_ix: Map<u64, u64>, // shape hash -> xms index
    pub xm_key: Vector<Vector<u64>>, // exact shape per entry: slot, cm, then (pm<<32|pnode, at) pairs
    pub xms: Vector<Map<u64, u64>>,
    /// Callees with vector index lists over their parameters (`CoreBody.has_lists`) re-lowered under
    /// one call shape's bindings, where the lists resolve: shape hash -> `rl` index, or a rejection.
    pub rl_ix: Map<u64, u64>,
    pub rl: Vector<CalleeInfo>,
    // `run` scratch (capacity survives across bodies).
    pub sc_blk_origin: Vector<u32>,
    pub sc_origins: Vector<Origin>,
    pub sc_binds: Vector<GBind>,
    pub sc_tymap: Map<u64, u64>,
    pub sc_wire: Vector<u8>,
    pub sc_probe: Vector<TypeId>,
    pub sc_shape: Vector<u64>,
}

fn bind_add(binds: &mut Vector<GBind>, pm: ModuleId, pnode: NodeId, at: TypeId) {
    for i in 0..binds.len() {
        if binds.at(i).pm == pm && binds.at(i).pnode == pnode {
            return; // first binding wins (signature unification runs before targ fill)
        }
    }
    binds.push(GBind { pm: pm, pnode: pnode, at: at });
}

/// Structural unification of a callee type against the caller type the checker matched
/// it with: every callee generic parameter met in a matching position binds to the caller type.
/// Mismatched shapes (coercions) contribute nothing; the final translation decides viability.
fn unify(
    pkg: *const loader::Package,
    km: ModuleId,
    kt: TypeId,
    cm: ModuleId,
    ct: TypeId,
    binds: &mut Vector<GBind>,
    depth: u32,
) {
    if kt == TYPE_NONE || ct == TYPE_NONE || depth > 8 {
        return;
    }
    let p = unsafe &*pkg;
    let y = *(unsafe &*p.module_ast_const(km)).type_at(kt);
    if y.kind == TypeKind::TYPE_GENERIC {
        bind_add(binds, y.module, y.as_data.decl, ct);
        return;
    }
    let z = *(unsafe &*p.module_ast_const(cm)).type_at(ct);
    if z.kind != y.kind {
        // one-sided reference: the checker's autoref/deref adjustment is applied at the call
        // boundary, not in the operand type -- peel it and keep unifying (wire() decides validity)
        if y.kind == TypeKind::TYPE_REFERENCE {
            unify(pkg, km, y.as_data.elem, cm, ct, binds, depth + 1);
        } else if z.kind == TypeKind::TYPE_REFERENCE {
            unify(pkg, km, kt, cm, z.as_data.elem, binds, depth + 1);
        }
        return;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.arr_like() {
        unify(pkg, km, y.as_data.elem, cm, z.as_data.elem, binds, depth + 1);
        if y.arr_sym() {
            let ca = unsafe &mut *(p.module_ast_const(cm) as *mut Ast);
            // A count binds a bare length parameter as a value of that parameter's type.
            let ly = *(unsafe &*p.module_ast_const(km)).type_at(y.as_data.arr.len);
            let zl = if z.arr_sym() {
                z.as_data.arr.len;
            } else if ly.kind == TypeKind::TYPE_GENERIC {
                ca.const_value(z.as_data.arr.len, p.const_param_bt(ly.module, ly.as_data.decl));
            } else {
                TYPE_NONE;
            };
            unify(pkg, km, y.as_data.arr.len, cm, zl, binds, depth + 1);
        }
        return;
    }
    if y.kind == TypeKind::TYPE_INSTANCE || y.fn_sig() && z.fn_sig() {
        let yi = *(unsafe &*p.module_ast_const(km)).instance(y.rec());
        let zi = *(unsafe &*p.module_ast_const(cm)).instance(z.rec());
        if yi.module == zi.module && yi.decl == zi.decl && yi.n == zi.n {
            for i in 0..yi.n {
                unify(pkg, km, unsafe yi.args[i as usize], cm, unsafe zi.args[i as usize], binds, depth + 1);
            }
        }
    }
}

/// Callee type `kt` with the bound generic parameters substituted, interned for the caller
/// module. TYPE_NONE on failure (unbound parameter, const-generic expression, or a function or
/// closure item's type under an active substitution).
fn xty(pkg: *const loader::Package, km: ModuleId, kt: TypeId, cm: ModuleId, binds: &Vector<GBind>, depth: u32) TypeId {
    if kt == TYPE_NONE || depth > 24 {
        return TYPE_NONE;
    }
    let mut t0: u64 = 0;
    if unsafe TS_ON {
        ts_add(TS_XTY, 1);
        if unsafe TS_DEPTH == 0 {
            t0 = ts_now();
        }
        unsafe TS_DEPTH += 1;
    }
    let r = xty_i(pkg, km, kt, cm, binds, depth);
    if unsafe TS_ON {
        unsafe TS_DEPTH -= 1;
        if t0 != 0 {
            ts_add(TS_XTY_NS, ts_now() - t0);
        }
    }
    return r;
}

fn xty_i(pkg: *const loader::Package, km: ModuleId, kt: TypeId, cm: ModuleId, binds: &Vector<GBind>, depth: u32) TypeId {
    let p = unsafe &*pkg;
    let ka = unsafe &*p.module_ast_const(km);
    let ca = unsafe &mut *(p.module_ast_const(cm) as *mut Ast);
    let y = *ka.type_at(kt);
    return switch y.kind {
        TYPE_GENERIC => {
            let mut r = TYPE_NONE;
            for i in 0..binds.len() {
                if binds.at(i).pm == y.module && binds.at(i).pnode == y.as_data.decl {
                    r = binds.at(i).at;
                    break;
                }
            }
            r;
        },
        TYPE_CONST_EXPR => {
            // A form over const-generic parameters (`{N / 2}`): its value under the bindings.
            let l = *ka.const_lin_at(y.as_data.inst);
            let mut v = l.k;
            let mut ok = true;
            for i in 0..l.n {
                let pd = unsafe l.p[i as usize];
                let mut x = TYPE_NONE;
                for j in 0..binds.len() {
                    if binds.at(j).pm == pd.module && binds.at(j).pnode == pd.node {
                        x = binds.at(j).at;
                    }
                }
                ok = ok && x != TYPE_NONE && ca.type_at(x).kind == TypeKind::TYPE_CONST && lin_acc(
                    &mut v,
                    unsafe l.c[i as usize],
                    cval_exact(ca.type_at(x).as_data.value, ca.type_at(x).cbt()),
                );
            }
            let mut out = i128::zero();
            let mut r = TYPE_NONE;
            if ok && l.finish(v, lay::target_for(p.arch).ptr == 4, &mut out) {
                r = ca.const_value(cval_bits(out), l.to);
            }
            r;
        },
        TYPE_FIELD_PROJECTION | TYPE_ERROR => TYPE_NONE,
        TYPE_FUNCTION => {
            // A function-pointer type substitutes its signature; a function or closure item is
            // nominal (module, declaration): the package id itself, sound only without a
            // substitution to apply.
            let mut r = TYPE_NONE;
            if y.fn_sig() {
                let mut it = *ka.instance(y.as_data.fnp.sig);
                let mut ok = true;
                for i in 0..it.n {
                    let ai = xty(pkg, km, unsafe it.args[i as usize], cm, binds, depth + 1);
                    if ai == TYPE_NONE {
                        ok = false;
                    }
                    unsafe it.args[i as usize] = ai;
                }
                if ok {
                    r = ca.intern_sig_rec(&it, y.qualifier);
                }
            } else if binds.len() == 0 {
                r = kt;
            }
            r;
        },
        TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE | TYPE_ARRAY | TYPE_SIMD | TYPE_MASK => {
            let e = xty(pkg, km, y.as_data.elem, cm, binds, depth + 1);
            let mut r = TYPE_NONE;
            if y.arr_sym() {
                let lt = xty(pkg, km, y.as_data.arr.len, cm, binds, depth + 1);
                if e != TYPE_NONE && lt != TYPE_NONE {
                    r = ca.intern_array(y.kind, e, lt);
                }
            } else if e != TYPE_NONE || y.as_data.elem == TYPE_NONE {
                let mut nt = y;
                nt.as_data.elem = e;
                r = ca.intern_type(nt);
            }
            r;
        },
        TYPE_INSTANCE | TYPE_DYN => {
            let inst = *ka.instance(y.as_data.inst);
            let mut na: [TypeId; 8] = [[0] = TYPE_NONE];
            let mut ok = true;
            for i in 0..inst.n {
                let ai = xty(pkg, km, unsafe inst.args[i as usize], cm, binds, depth + 1);
                if ai == TYPE_NONE {
                    ok = false;
                }
                unsafe na[i as usize] = ai;
            }
            let mut r = TYPE_NONE;
            if ok && y.kind == TypeKind::TYPE_DYN {
                r = ca.intern_dyn(inst.module, inst.decl, &na[0], inst.n, y.qualifier);
            } else if ok {
                r = ca.intern_instance(inst.module, inst.decl, &na[0], inst.n);
            }
            r;
        },
        _ => ca.intern_type(y),
    };
}

/// The NODE_EXTEND whose item list contains `fnode`, or NODE_NONE.
fn extend_of(a: &Ast, fnode: NodeId) NodeId {
    let c = a.container_of(fnode);
    if c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_EXTEND {
        return c;
    }
    return NODE_NONE;
}

const fn callee_key(d: DefId) u64 {
    return skey_mix(3, d.module as u64 << 32 | d.node as u64);
}

/// A public non-extern CONCRETE function with a body (no generics of its own, and any enclosing
/// extend non-generic): the one item shape whose symbol and prototype every TU can spell.
fn is_concrete_pub_fn(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() || !p.modules.at(d.module as usize).has_ast {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    if n.kind != NodeKind::NODE_FUNCTION {
        return false;
    }
    let f = n.as_data.function;
    if !f.is_public() || f.is_extern() || f.body == NODE_NONE || f.generics.len != 0 {
        return false;
    }
    let ext = extend_of(a, d.node);
    if ext != NODE_NONE && a.at_const(ext).as_data.extend_def.generics.len != 0 {
        return false;
    }
    return true;
}

/// A non-variadic function of an `extern "C" "<header>"` block. Every TU includes that header
/// (through `__sc_fwd.h`), so a call to it spells the same in any TU.
fn is_header_extern_fn(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() || !p.modules.at(d.module as usize).has_ast {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    if n.kind != NodeKind::NODE_FUNCTION || !n.as_data.function.is_extern() || n.as_data.function.is_variadic() {
        return false;
    }
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let b = a.at_const(unsafe a.list(items)[i as usize]);
        if b.kind == NodeKind::NODE_EXTERN_BLOCK && b.as_data.extern_block.header != NODE_NONE {
            let fs = b.as_data.extern_block.items;
            for j in 0..fs.len {
                if unsafe a.list(fs)[j as usize] == d.node {
                    return true;
                }
            }
        }
    }
    return false;
}

extend InlineCtx {
    /// Bytes the translation maps hold (SC_TYPE_STATS): each map's slots at its load, plus the shape keys.
    pub fn xm_bytes(self: &Self) u64 {
        let mut b: u64 = 0;
        for i in 0..self.xms.len() {
            b += (self.xms.at(i).len() * 17 * 2 + self.xm_key.at(i).len() * 8) as u64;
        }
        return b + (self.xm_ix.len() * 17 * 2) as u64;
    }

    pub fn new(store: *const InlineStore) InlineCtx {
        let e = stdlib::getenv("SC_INLINE");
        let mut off = false;
        if e != null && str::from_cstr(e) == "0" {
            off = true;
        }
        return InlineCtx {
            off: off,
            stats_on: stdlib::getenv("SC_INLINE_STATS") != null,
            store: store,
            xm_ix: Map::<u64, u64>::new(),
            xm_key: Vector::<Vector<u64>>::new(),
            xms: Vector::<Map<u64, u64>>::new(),
            rl_ix: Map::<u64, u64>::new(),
            rl: Vector::<CalleeInfo>::new(),
            sc_blk_origin: Vector::<u32>::new(),
            sc_origins: Vector::<Origin>::new(),
            sc_binds: Vector::<GBind>::new(),
            sc_tymap: Map::<u64, u64>::new(),
            sc_wire: Vector::<u8>::new(),
            sc_probe: Vector::<TypeId>::new(),
            sc_shape: Vector::<u64>::new(),
        };
    }

    /// Callee `d` (kept as `ki`) re-lowered under the call's bindings `binds` (types of caller module
    /// `cm`), its index lists resolved; null when they do not resolve, or when the kept body drops
    /// something (a fresh lowering carries no elaborated drops).
    fn relowered(
        self: &mut Self,
        pkg: *const loader::Package,
        ki: *const CalleeInfo,
        d: DefId,
        cm: ModuleId,
        binds: &Vector<GBind>,
    ) *const CalleeInfo {
        let mut key = callee_key(d) ^ (cm as u64).wrapping_mul(1099511628211u64);
        for i in 0..binds.len() {
            let g = binds.at(i);
            key = (key ^ (g.pm as u64 << 32 | g.pnode as u64)).wrapping_mul(1099511628211u64);
            key = (key ^ g.at as u64).wrapping_mul(1099511628211u64);
        }
        switch self.rl_ix.get(&key) {
            Some(v) => {
                if *v == REJ_BASE {
                    return null;
                }
                return self.rl.at((*v) as usize);
            },
            None => {},
        };
        let k = unsafe &(*ki).body;
        let mut drops = false;
        for i in 0..k.blocks.len() {
            drops = drops || k.blocks.at(i).term.kind == ir::TM_DROP;
        }
        let mut lw = irl::Lowerer::new(pkg, d.module, d.node);
        for i in 0..binds.len() {
            let g = binds.at(i);
            lw.env.push(irl::LSub { pm: g.pm, pnode: g.pnode, am: cm, at: g.at });
        }
        if drops || !lw.lower_fn(d.node) || lw.body.has_lists || lw.body.has_reflect || lw.user_err != NODE_NONE {
            self.rl_ix.insert(key, REJ_BASE);
            return null;
        }
        let mut body = ir::CoreBody::compact_from(&lw.body);
        body.elaborated = true; // nothing to elaborate: the kept body drops nothing
        self.rl.push(
            CalleeInfo { body: body, gp: unsafe (*ki).gp.clone(), fg: unsafe (*ki).fg, demand: unsafe (*ki).demand },
        );
        self.rl_ix.insert(key, self.rl.len() as u64 - 1);
        return self.rl.at(self.rl.len() - 1);
    }

    /// The shared store's verdict for callee `d`: the kept slot, or REJ_BASE|reason (a body the
    /// keep never held is no candidate).
    fn callee_slot(self: &Self, d: DefId) u64 {
        let key = callee_key(d);
        switch unsafe (&*self.store).keep_ix.get(&key) {
            Some(v) => {
                return *v;
            },
            None => {
                return REJ_BASE | IJ_NOT_FN as u64;
            },
        };
    }
}

// Is `d` a generic parameter (an item local of a const-generic parameter names it)?
fn is_param(p: &loader::Package, d: DefId) bool {
    return d.node != NODE_NONE && (unsafe &*p.module_ast_const(d.module)).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM;
}

// Is operand `o` of `b` a constant, or a read of a const-generic parameter (a constant once spliced)?
fn const_or_param(p: &loader::Package, b: &ir::CoreBody, o: u32) bool {
    let op = *b.operands.at(o as usize);
    if op.kind == ir::OP_CONST {
        return true;
    }
    let pl = *b.places.at(op.data as usize);
    return pl.proj_len == 0 && b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF && is_param(
        p,
        b.locals.at(pl.base as usize).item,
    );
}

// The value of const-generic parameter `d` under `binds` (caller types of module `cm`), or false.
fn param_value(p: &loader::Package, d: DefId, cm: ModuleId, binds: &Vector<GBind>, v: &mut i64) bool {
    for i in 0..binds.len() {
        let g = binds.at(i);
        if g.pm == d.module && g.pnode == d.node {
            let y = *(unsafe &*p.module_ast_const(cm)).type_at(g.at);
            *v = y.as_data.value;
            return y.kind == TypeKind::TYPE_CONST;
        }
    }
    return false;
}

// A multi-return call's one destination is a temp the caller copies whole into other temps and
// reads only as members `0..nret` (`_t._0`). `alias` receives the temp and its copies; true when
// every other read of them is a member read, which the splice redirects to the return slots.
fn multi_alias(b: &ir::CoreBody, dpl: u32, nret: u32, alias: &mut Vector<u32>) bool {
    alias.truncate(0);
    alias.push(b.places.at(dpl as usize).base);
    let mut grew = true;
    let mut rounds = 0;
    while grew && rounds < 4 {
        grew = false;
        rounds += 1;
        for i in 0..b.statements.len() {
            let x = alias_copy(b, i, alias);
            if x != ir::IR_NONE && !alias.contains(&x) {
                alias.push(x);
                grew = true;
            }
        }
    }
    // the operands the alias copies read
    let mut cops = Vector::<u32>::new();
    for k in 0..b.statements.len() {
        if alias_copy(b, k, alias) != ir::IR_NONE {
            cops.push(b.rvalues.at(b.statements.at(k).rvalue as usize).a);
        }
    }
    for i in 0..b.operands.len() {
        let o = *b.operands.at(i);
        if o.kind == ir::OP_CONST || !alias.contains(&b.places.at(o.data as usize).base) {
            continue;
        }
        let p = *b.places.at(o.data as usize);
        if p.proj_len == 0 {
            // only an alias copy reads the whole temp
            if !cops.contains(&(i as u32)) {
                return false;
            }
        } else if b.projections.at(p.proj_start as usize).kind != ir::PJ_FIELD || b.projections.at(
            p.proj_start as usize,
        ).data >= nret {
            return false;
        }
    }
    return true;
}

// The local statement `i` of `b` copies a whole `alias` local into (`x = copy _t`), else IR_NONE.
fn alias_copy(b: &ir::CoreBody, i: usize, alias: &Vector<u32>) u32 {
    let st = *b.statements.at(i);
    if st.kind != ir::ST_ASSIGN || b.places.at(st.place as usize).proj_len != 0 {
        return ir::IR_NONE;
    }
    let rv = *b.rvalues.at(st.rvalue as usize);
    if rv.kind != ir::RV_USE {
        return ir::IR_NONE;
    }
    let o = *b.operands.at(rv.a as usize);
    if o.kind == ir::OP_CONST || b.places.at(o.data as usize).proj_len != 0 || !alias.contains(
        &b.places.at(o.data as usize).base,
    ) {
        return ir::IR_NONE;
    }
    return b.places.at(st.place as usize).base;
}

// The declaration-level checks: 0 = a candidate worth keeping, else the rejection. A candidate's
// enclosing extend block (or NODE_NONE) is written to `ext`.
fn vet_decl(pkg: *const loader::Package, d: DefId, asserts: &Vector<u64>, ext: &mut NodeId, demand: &mut bool) u64 {
    let p = unsafe &*pkg;
    if d.module as usize >= p.modules.len() || !p.modules.at(d.module as usize).has_ast {
        return REJ_BASE | IJ_NOT_FN as u64;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    if n.kind != NodeKind::NODE_FUNCTION {
        return REJ_BASE | IJ_NOT_FN as u64;
    }
    let f = n.as_data.function;
    if f.is_extern() || f.body == NODE_NONE {
        return REJ_BASE | IJ_NOT_FN as u64;
    }
    for k in 0..a.attrs.len() {
        if a.attrs.at(k).owner != d.node {
            continue;
        }
        let kd = a.attrs.at(k).kind;
        let benign = kd == AttrKind::ATTR_INLINE as u8 || kd == AttrKind::ATTR_ALWAYS_INLINE as u8 || kd == AttrKind::ATTR_USED as u8 || kd == AttrKind::ATTR_UNUSED as u8 || kd == AttrKind::ATTR_FMT_SKIP as u8 || kd == AttrKind::ATTR_NO_CONST as u8;
        if !benign {
            return REJ_BASE | IJ_NOT_FN as u64;
        }
    }
    *ext = extend_of(a, d.node);
    // A GENERIC body carrying a static_assert defers it per instantiation; that guard fires
    // only when a call site DEMANDS the instance, so a splice of it records the call in the
    // caller's `demands` (`demand`). `asserts` holds the module's static_assert spans.
    *demand = false;
    if f.generics.len != 0 || *ext != NODE_NONE && a.at_const(*ext).as_data.extend_def.generics.len != 0 {
        let bsp = a.at_const(f.body).span;
        for k in 0..asserts.len() {
            let sp = asserts[k];
            *demand = *demand || (sp >> 32) as u32 >= bsp.start && (sp & 0xFFFFFFFFu64) as u32 <= bsp.end;
        }
    }
    return 0;
}

// The spans of module `a`'s static_assert nodes, packed `start << 32 | end`: one scan per module,
// against one per vetted generic callee.
fn assert_spans(a: &Ast, out: &mut Vector<u64>) {
    out.clear();
    for ni in 0..a.nnodes() {
        let nd = a.at_const(a.nth_id(ni));
        if nd.kind == NodeKind::NODE_STATIC_ASSERT {
            out.push(nd.span.start as u64 << 32 | nd.span.end as u64);
        }
    }
}

extend InlineStore {
    pub fn new() InlineStore {
        return InlineStore { keep_ix: Map::<u64, u64>::new(), kept: Vector::<CalleeInfo>::new() };
    }

    /// Vet every kept env-free function lowering of `keep` (the borrow checker's product, the same
    /// lowering an on-demand vet would build) and copy the accepted callees.
    pub fn build(self: &mut Self, pkg: *const loader::Package, keep: &irl::Keep) {
        // Only a body some kept body calls can be inlined: collect the call targets first, so
        // the vetting (an attribute walk and a statement scan per body) runs for those alone.
        let mut called = Map::<u64, u8>::new();
        let mut asserts = Vector::<Vector<u64>>::new(); // per module, filled on first use
        let mut has_asserts = Vector::<u8>::new(); // 0 unknown, 1 filled
        let nm = unsafe (&*pkg).modules.len();
        for _ in 0..nm {
            asserts.push(Vector::<u64>::new());
            has_asserts.push(0);
        }
        for i in 0..keep.kept.len() {
            let b = &keep.kept.at(i).body;
            for k in 0..b.blocks.len() {
                let t = &b.blocks.at(k).term;
                if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
                    called.insert(callee_key(t.callee), 1);
                }
            }
        }
        for i in 0..keep.kept.len() {
            let lw = keep.kept.at(i);
            let d = lw.body.owner;
            // A closure of a releasable body: never a named callee, and its node may be released.
            if Ast::in_body(d.node) {
                continue;
            }
            let key = callee_key(d);
            if self.keep_ix.contains_key(&key) || !called.contains_key(&key) {
                continue;
            }
            // The size gate first: it rejects most bodies at once, before the declaration checks
            // walk the module's attributes.
            let mut r: u64 = 0;
            if !lw.body.inline_size_ok {
                r = REJ_BASE | IJ_TOO_BIG as u64;
            } else {
                let dm = d.module as usize;
                if dm < nm && has_asserts[dm] == 0 && unsafe (&*pkg).modules.at(dm).has_ast {
                    assert_spans(unsafe &*(&*pkg).module_ast_const(d.module), asserts.index_mut(dm));
                    has_asserts.set(dm, 1);
                }
                let mut ext = NODE_NONE;
                let mut demand = false;
                r = vet_decl(pkg, d, asserts.at(dm), &mut ext, &mut demand);
                if r == 0 {
                    r = self.vet_body(pkg, d, ext, &lw.body, lw.closures.len(), demand);
                }
            }
            self.keep_ix.insert(key, r);
        }
    }

    // The body-level checks on the env-free lowering of `d` (in extend block `ext`, or NODE_NONE)
    // with `nclosures` hoisted closures, after the size gate passed: the kept slot, or the rejection.
    fn vet_body(
        self: &mut Self,
        pkg: *const loader::Package,
        d: DefId,
        ext: NodeId,
        body: &ir::CoreBody,
        nclosures: usize,
        demand: bool,
    ) u64 {
        let p = unsafe &*pkg;
        let a = unsafe &*p.module_ast_const(d.module);
        let f = a.at_const(d.node).as_data.function;
        let shape = REJ_BASE | IJ_SHAPE as u64;
        if body.has_reflect || body.has_zst_cond || nclosures != 0 {
            return shape;
        }
        for i in 0..body.blocks.len() {
            let tk = &body.blocks.at(i).term;
            if tk.kind == ir::TM_RETURN && tk.args_len == ir::RET_CANCEL {
                // A cancellation-edge return unwinds the CALLER too; rewiring it as a goto
                // would read the poison value and resume normal flow.
                return shape;
            }
            if tk.kind == ir::TM_ASSERT {
                return shape; // the assert message renders from the callee module's source
            }
            // Inner calls splice into a FOREIGN TU: only a public non-extern CONCRETE
            // function (no fn/extend generics, no call targs) or a header-declared extern
            // function is guaranteed a global symbol and a shared prototype there -- a generic
            // inner call would need the emitter's demand machinery to re-derive substitutions it
            // no longer has context for.
            if tk.kind == ir::TM_CALL && (tk.callee.node == NODE_NONE || tk.targs_len != 0 || !is_concrete_pub_fn(
                pkg,
                tk.callee,
            ) && !is_header_extern_fn(pkg, tk.callee)) {
                return shape;
            }
        }
        for i in 0..body.locals.len() {
            // A const-generic parameter's value becomes a constant at the splice.
            if body.locals.at(i).storage == ir::LS_STATIC_REF && !is_param(p, body.locals.at(i).item) {
                return shape; // item symbol/linkage is the owner TU's business
            }
        }
        for i in 0..body.rvalues.len() {
            let rv = body.rvalues.at(i);
            let mut bad = rv.kind == ir::RV_CLOSURE;
            if rv.kind == ir::RV_CAST && rv.b == ir::CAST_COERCE_FROM as u32 {
                bad = true;
            }
            if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_VA_START || rv.c == ir::IN_VA_ARG || rv.c == ir::IN_VA_END || rv.c == ir::IN_ASM || rv.c == ir::IN_REFLECT) {
                bad = true;
            }
            if rv.kind == ir::RV_REPEAT && body.is_generic && !const_or_param(p, body, rv.b) {
                bad = true; // a symbolic repeat count must re-lower per instance
            }
            if bad {
                return shape;
            }
        }
        for i in 0..body.constants.len() {
            let c9 = body.constants.at(i);
            if c9.kind == ir::CK_WIDE {
                return shape; // wide-literal records index the callee module's Ast
            }
            if c9.kind == ir::CK_ITEM && (c9.targ_len() != 0 || !is_concrete_pub_fn(pkg, c9.item)) {
                return shape; // fn-value symbols follow the inner-call rule
            }
        }
        let kb = ir::CoreBody::compact_from(body);
        let mut gp = Vector::<NodeId>::new();
        if ext != NODE_NONE {
            let xg = a.at_const(ext).as_data.extend_def.generics;
            for i in 0..xg.len {
                gp.push(unsafe a.list(xg)[i as usize]);
            }
        }
        let fgl = f.generics;
        for i in 0..fgl.len {
            gp.push(unsafe a.list(fgl)[i as usize]);
        }
        let slot = self.kept.len() as u64;
        self.kept.push(CalleeInfo { body: kb, gp: gp, fg: fgl.len, demand: demand });
        return slot;
    }
}

/// Statistics line, bce::stats_line style.
pub fn stats_line(st: &InlineStats, out: &mut String) {
    out.push_str("inline considered ");
    out.push_u64(st.considered);
    out.push_str(" inlined ");
    out.push_u64(st.inlined);
    out.push_str(" reasons");
    for i in 0..IJ_COUNT {
        out.push_str(" ");
        out.push_u64(unsafe st.reasons[i]);
    }
}

/// Inline qualifying calls of `lw.body` in place. Appended blocks are revisited, so a spliced
/// body's own calls inline up to MAX_DEPTH; every decision depends only on the bodies and ASTs.
/// The caller skips the call when `cx.off`.
pub fn run(lw: &mut irl::Lowerer, cx: &mut InlineCtx, st: &mut InlineStats) {
    let mut any = false;
    for i in 0..lw.body.blocks.len() {
        let t = &lw.body.blocks.at(i).term;
        if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
            any = true;
            break;
        }
    }
    if !any {
        return;
    }
    // A body carrying reflection-binder forms is expanded by the emitter around its ORIGINAL
    // call/operand shapes: splicing into it breaks that pattern match. Leave it whole.
    for i in 0..lw.body.rvalues.len() {
        let rv = lw.body.rvalues.at(i);
        if rv.kind == ir::RV_INTRINSIC && rv.c == ir::IN_REFLECT {
            return;
        }
    }
    let pkg = lw.pkg;
    let owner_key = callee_key(lw.body.owner);
    // splice provenance: per block, an origin-record index (IR_NONE = original block)
    let mut blk_origin = replace(&mut cx.sc_blk_origin, Vector::<u32>::new());
    blk_origin.truncate(0);
    blk_origin.resize_default(lw.body.blocks.len());
    for i in 0..lw.body.blocks.len() {
        blk_origin.set(i, ir::IR_NONE);
    }
    let mut origins = replace(&mut cx.sc_origins, Vector::<Origin>::new());
    origins.truncate(0);
    let mut added: usize = 0;
    let mut binds = replace(&mut cx.sc_binds, Vector::<GBind>::new());
    let mut tymap = replace(&mut cx.sc_tymap, Map::<u64, u64>::new());
    tymap.clear();
    let mut wire = replace(&mut cx.sc_wire, Vector::<u8>::new());
    let mut probe = replace(&mut cx.sc_probe, Vector::<TypeId>::new());
    let mut shape = replace(&mut cx.sc_shape, Vector::<u64>::new());
    let mut alias = Vector::<u32>::new();
    let mut bi: usize = 0;
    while bi < lw.body.blocks.len() {
        let t = lw.body.blocks.at(bi).term;
        bi += 1;
        if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE {
            continue;
        }
        st.considered += 1;
        if t.is_variadic {
            st.reasons[IJ_ARITY as usize] = st.reasons[IJ_ARITY as usize] + 1;
            continue;
        }
        let key = callee_key(t.callee);
        // recursion and depth through the splice chain
        let mut depth: usize = 0;
        let mut cyc = key == owner_key;
        let mut oi = blk_origin[bi - 1];
        while oi != ir::IR_NONE {
            depth += 1;
            if origins.at(oi as usize).key == key {
                cyc = true;
            }
            oi = origins.at(oi as usize).parent;
        }
        if cyc {
            st.reasons[IJ_RECURSIVE as usize] = st.reasons[IJ_RECURSIVE as usize] + 1;
            continue;
        }
        if depth >= MAX_DEPTH {
            st.reasons[IJ_DEPTH as usize] = st.reasons[IJ_DEPTH as usize] + 1;
            continue;
        }
        let slot = cx.callee_slot(t.callee);
        if slot >= REJ_BASE {
            let rr = (slot & 0xFFu64) as usize;
            unsafe {
                st.reasons[rr] = st.reasons[rr] + 1;
            }
            continue;
        }
        let ki0 = unsafe (&*cx.store).kept.at(slot as usize);
        let k0 = &ki0.body;
        // A void callee has no return slot, but its call keeps the one void destination the
        // lowering gives every call; the splice leaves that destination unwritten.
        let mut void_dest = false;
        if k0.returns == 0 && t.dests_len == 1 {
            let dpl = lw.body.dest_pool[t.dests_start as usize];
            void_dest = eff_pty(&lw.body, dpl) == Ast::builtin(BuiltinType::BT_VOID);
        }
        let multi = k0.returns > 1 && t.dests_len == 1;
        if k0.args != t.args_len || k0.returns != t.dests_len && !void_dest && !multi {
            st.reasons[IJ_ARITY as usize] = st.reasons[IJ_ARITY as usize] + 1;
            continue;
        }
        if added + k0.statements.len() + k0.args as usize + k0.returns as usize > MAX_ADDED_STMTS {
            st.reasons[IJ_BUDGET as usize] = st.reasons[IJ_BUDGET as usize] + 1;
            continue;
        }
        // ---- generic bindings: signature unification, then recorded type arguments -------------
        binds.truncate(0);
        let cm = lw.body.module;
        let km = t.callee.module;
        for j in 0..k0.args {
            let opid = lw.body.oper_pool[(t.args_start + j) as usize];
            let cty = lw.body.operands.at(opid as usize).ty;
            unify(pkg, km, k0.locals.at((k0.returns + j) as usize).ty, cm, cty, &mut binds, 0);
        }
        for r in 0..k0.returns {
            if !multi {
                let dpl = lw.body.dest_pool[(t.dests_start + r) as usize];
                unify(pkg, km, k0.locals.at(r as usize).ty, cm, lw.body.places.at(dpl as usize).ty, &mut binds, 0);
            }
        }
        if t.targs_len as usize == ki0.gp.len() && ki0.gp.len() != 0 {
            for i in 0..ki0.gp.len() {
                bind_add(&mut binds, km, ki0.gp[i], lw.body.targ_pool[t.targs_start as usize + i]);
            }
        } else if ki0.fg != 0 && t.targs_len >= ki0.fg {
            let skip = (t.targs_len - ki0.fg) as usize;
            let base0 = ki0.gp.len() - ki0.fg as usize;
            for i in 0..ki0.fg as usize {
                bind_add(&mut binds, km, ki0.gp[base0 + i], lw.body.targ_pool[t.targs_start as usize + skip + i]);
            }
        }
        // A callee whose index lists name its parameters runs as re-lowered under these bindings.
        let mut kp = ki0 as *const CalleeInfo;
        if k0.has_lists {
            kp = cx.relowered(pkg, kp, t.callee, cm, &binds);
            if kp == null {
                st.reasons[IJ_GENERIC as usize] = st.reasons[IJ_GENERIC as usize] + 1;
                continue;
            }
        }
        let ki = unsafe &*kp;
        let k = &ki.body;
        // ---- translate every callee type up front; any failure rejects the site ----------------
        // The translation depends only on (callee slot, caller module, binds): repeated call
        // shapes reuse the finished map instead of re-walking the callee type table.
        tymap.clear();
        let mut tok9 = true;
        shape.truncate(0);
        shape.push(slot);
        shape.push(cm);
        for i in 0..binds.len() {
            shape.push(binds.at(i).pm as u64 << 32 | binds.at(i).pnode as u64);
            shape.push(binds.at(i).at);
        }
        let mut h9: u64 = 14695981039346656037;
        for i in 0..shape.len() {
            h9 = (h9 ^ shape[i]).wrapping_mul(1099511628211);
        }
        let mut cix: i64 = -1;
        let mut collide = false;
        switch cx.xm_ix.get(&h9) {
            Some(v) => {
                if cx.xm_key.at((*v) as usize).eq(&shape) {
                    cix = (*v) as i64;
                    if unsafe TS_ON {
                        ts_add(TS_XTY_HIT, 1);
                    }
                } else {
                    collide = true;
                }
            },
            _ => {},
        };
        if cix < 0 {
            probe.truncate(0);
            for i in 0..k.locals.len() {
                probe.push(k.locals.at(i).ty);
            }
            for i in 0..k.places.len() {
                probe.push(k.places.at(i).ty);
            }
            for i in 0..k.projections.len() {
                probe.push(k.projections.at(i).ty);
            }
            for i in 0..k.operands.len() {
                probe.push(k.operands.at(i).ty);
            }
            for i in 0..k.constants.len() {
                probe.push(k.constants.at(i).ty);
            }
            for i in 0..k.targ_pool.len() {
                probe.push(k.targ_pool[i]);
            }
            for i in 0..k.blocks.len() {
                probe.push(k.blocks.at(i).term.iface);
                probe.push(k.blocks.at(i).term.recv);
            }
            for i in 0..k.rvalues.len() {
                let rv = k.rvalues.at(i);
                probe.push(rv.target);
                if rv.kind == ir::RV_DYN {
                    probe.push(rv.b);
                }
                if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF || rv.c == ir::IN_TYPE_INFO || rv.c == ir::IN_DANGLING) {
                    probe.push(rv.b);
                }
            }
            for i in 0..probe.len() {
                let kt = probe[i];
                let kk: u64 = kt;
                if kt == TYPE_NONE || tymap.contains_key(&kk) {
                    continue;
                }
                let nt = xty(pkg, km, kt, cm, &binds, 0);
                if nt == TYPE_NONE {
                    tok9 = false;
                    break;
                }
                tymap.insert(kk, nt);
            }
            if tok9 && !collide {
                cix = cx.xms.len() as i64;
                cx.xm_key.push(shape.clone());
                cx.xms.push(replace(&mut tymap, Map::<u64, u64>::new()));
                cx.xm_ix.insert(h9, cix as u64);
            }
        }
        if !tok9 {
            st.reasons[IJ_GENERIC as usize] = st.reasons[IJ_GENERIC as usize] + 1;
            continue;
        }
        let tyx: *const Map<u64, u64> = if cix >= 0 {
            cx.xms.at(cix as usize);
        } else {
            &tymap;
        };
        let tyr = unsafe &*tyx;
        // ---- call-boundary shapes: exact match, or the one implicit autoref/deref adjustment ---
        // (the C call emitter applies autoref, Box hops, and array-to-slice wraps; only the
        // adjustments the splice reproduces in IR are accepted, anything else rejects the site)
        wire.truncate(0);
        let mut wok = true;
        for j in 0..k.args {
            let opid = lw.body.oper_pool[(t.args_start + j) as usize];
            let op = *lw.body.operands.at(opid as usize);
            let pt = mty(tyr, k.locals.at((k.returns + j) as usize).ty);
            // the C emitter reads a place operand as the PLACE's value: shapes compare against
            // the place type, not the operand's recorded (possibly post-adjustment) type
            let mut sty = op.ty;
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                sty = eff_pty(&lw.body, op.data);
            }
            if pt == sty && pt != TYPE_NONE {
                wire.push(0);
                continue;
            }
            let ca = unsafe &*(&*pkg).module_ast_const(cm);
            let mut mode: u8 = 255;
            if pt != TYPE_NONE && sty != TYPE_NONE {
                // &mut T into a &T parameter, *mut T into *const T: the same C pointer value, no
                // adjustment needed
                let py0 = *ca.type_at(pt);
                let sy0 = *ca.type_at(sty);
                if py0.kind == sy0.kind && (py0.kind == TypeKind::TYPE_REFERENCE || py0.kind == TypeKind::TYPE_POINTER) && py0.as_data.elem == sy0.as_data.elem {
                    mode = 0;
                }
            }
            if mode == 255 && pt != TYPE_NONE && op.kind == ir::OP_COPY {
                let py = *ca.type_at(pt);
                if py.kind == TypeKind::TYPE_REFERENCE && py.as_data.elem == sty {
                    mode = 1; // autoref: the callee receives a reference to the caller's place
                }
                if mode == 255 && sty != TYPE_NONE {
                    let oy = *ca.type_at(sty);
                    if oy.kind == TypeKind::TYPE_REFERENCE && oy.as_data.elem == pt {
                        mode = 2; // deref: a reference argument into a by-value parameter
                    }
                }
            }
            if mode == 255 {
                wok = false;
                break;
            }
            wire.push(mode);
        }
        if wok {
            for r in 0..k.returns {
                if !multi && mty(tyr, k.locals.at(r as usize).ty) != eff_pty(
                    &lw.body,
                    lw.body.dest_pool[(t.dests_start + r) as usize],
                ) {
                    wok = false;
                    break;
                }
            }
            if multi {
                wok = multi_alias(&lw.body, lw.body.dest_pool[t.dests_start as usize], k.returns, &mut alias);
            }
        }
        // Every const-generic parameter the body reads has a constant binding.
        for i in 0..k.locals.len() {
            let mut v: i64 = 0;
            let it = k.locals.at(i).item;
            if wok && k.locals.at(i).storage == ir::LS_STATIC_REF && !param_value(unsafe &*pkg, it, cm, &binds, &mut v) {
                wok = false;
            }
        }
        if !wok {
            st.reasons[IJ_GENERIC as usize] = st.reasons[IJ_GENERIC as usize] + 1;
            continue;
        }
        // ---- splice (infallible from here) -----------------------------------------------------
        if !multi {
            alias.truncate(0);
        }
        splice(lw, ki, &t, bi - 1, tyr, &binds, &alias, &wire, &mut blk_origin, &mut origins);
        added += k.statements.len() + k.args as usize + k.returns as usize;
        st.inlined += 1;
    }
    cx.sc_blk_origin = blk_origin;
    cx.sc_origins = origins;
    cx.sc_binds = binds;
    cx.sc_tymap = tymap;
    cx.sc_wire = wire;
    cx.sc_probe = probe;
    cx.sc_shape = shape;
}

/// The C-authoritative type of a place: the base local's declared type for a bare place, else the
/// last projection's result type. `Place.ty` may carry a checker coercion (an autoref'd view) the
/// emitted storage does not have.
const fn eff_pty(b: &ir::CoreBody, plid: ir::PlaceId) TypeId {
    let pl = *b.places.at(plid as usize);
    if pl.proj_len == 0 {
        return b.locals.at(pl.base as usize).ty;
    }
    return b.projections.at((pl.proj_start + pl.proj_len - 1) as usize).ty;
}

fn mty(tymap: &Map<u64, u64>, t: TypeId) TypeId {
    if t == TYPE_NONE {
        return t;
    }
    let v = switch tymap.get(&(t as u64)) {
        Some(x) => (*x) as TypeId,
        None => TYPE_NONE,
    };
    return v;
}

/// Append the callee body to the caller with every index rebased, rewrite the call block to jump
/// into it, and join every callee return back to the call's continuation.
fn splice(
    lw: &mut irl::Lowerer,
    ki: &CalleeInfo,
    t: &ir::Terminator,
    call_blk: usize,
    tymap: &Map<u64, u64>,
    binds: &Vector<GBind>,
    alias: &Vector<u32>,
    wire: &Vector<u8>,
    blk_origin: &mut Vector<u32>,
    origins: &mut Vector<Origin>,
) {
    let k = &ki.body;
    let pkg9 = lw.pkg;
    let b = &mut lw.body;
    let sp = t.span;
    // A spliced loop keeps its callee's tick rule: the merged body prints ticks by the instance only
    // when both do.
    if !k.inst_ticks && k.has_safepoint() {
        b.inst_ticks = false;
    }
    let km = k.owner.module;
    let l0 = b.locals.len() as u32;
    let b0 = b.blocks.len() as u32;
    let s0 = b.statements.len() as u32;
    let p0 = b.places.len() as u32;
    let j0 = b.projections.len() as u32;
    let o0 = b.operands.len() as u32;
    let r0 = b.rvalues.len() as u32;
    let c0 = b.constants.len() as u32;
    let op0 = b.oper_pool.len() as u32;
    let d0 = b.dest_pool.len() as u32;
    let sw0 = b.switch_pool.len() as u32;
    let tg0 = b.targ_pool.len() as u32;
    let ax0 = b.simd_aux.len() as u32;
    let nkb = k.blocks.len() as u32;
    let prelude = b0 + nkb;
    let join = prelude + 1;
    // locals: return slots and parameters become plain temps; decl clears so no consumer indexes
    // the callee's Ast through the caller module
    for i in 0..k.locals.len() {
        let mut d = *k.locals.at(i);
        d.ty = mty(tymap, d.ty);
        // Declared callee locals (args and user bindings) become LS_INL: still declared for every
        // consumer that asks (`decl` must clear: it names a node in the CALLEE module's Ast).
        // Return slots become plain temps: the join moves them out.
        if d.storage == ir::LS_RET || d.storage == ir::LS_STATIC_REF {
            // a const-generic parameter's reads became its constant: the local stays unused
            d.storage = ir::LS_TEMP;
            d.item = DefId { module: 0, node: NODE_NONE };
        } else if d.storage == ir::LS_ARG || d.decl != NODE_NONE {
            d.storage = ir::LS_INL;
        }
        d.decl = NODE_NONE;
        d.span = sp;
        b.locals.push(d);
    }
    for i in 0..k.projections.len() {
        let mut pj = *k.projections.at(i);
        if pj.kind == ir::PJ_INDEX_OP {
            pj.data += o0;
        }
        pj.ty = mty(tymap, pj.ty);
        b.projections.push(pj);
    }
    for i in 0..k.places.len() {
        let mut pl = *k.places.at(i);
        pl.base += l0;
        pl.proj_start += j0;
        pl.ty = mty(tymap, pl.ty);
        b.places.push(pl);
    }
    for i in 0..k.constants.len() {
        let mut c = *k.constants.at(i);
        c.ty = mty(tymap, c.ty);
        if c.kind == ir::CK_ITEM && c.targ_len() != 0 {
            c.val = ir::targ_val(c.targ_start() + tg0, c.targ_len());
        }
        if c.kind == ir::CK_STR || c.kind == ir::CK_FLOAT || c.kind == ir::CK_INT {
            // the spelling spans a FOREIGN module's source; item marks it (established CK_STR
            // convention, extended to CK_FLOAT and CK_INT in the emitter -- an integer literal's
            // `val` is only the decimal fast path, hex/binary spellings live in the span)
            if c.item.node == NODE_NONE {
                c.item = DefId { module: km, node: k.owner.node };
            }
        }
        b.constants.push(c);
    }
    for i in 0..k.operands.len() {
        let mut o = *k.operands.at(i);
        o.ty = mty(tymap, o.ty);
        let mut v: i64 = 0;
        if (o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE) && k.places.at(o.data as usize).proj_len == 0 && param_value(
            unsafe &*pkg9,
            k.locals.at(k.places.at(o.data as usize).base as usize).item,
            b.module,
            binds,
            &mut v,
        ) {
            // A const-generic parameter read: its bound value.
            b.constants.push(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: o.ty,
                    val: v,
                    raw: tok::Span::empty(),
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            o.kind = ir::OP_CONST;
            o.data = b.constants.len() as u32 - 1;
        } else if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
            o.data += p0;
        } else {
            o.data += c0;
        }
        b.operands.push(o);
    }
    for i in 0..k.rvalues.len() {
        let mut rv = *k.rvalues.at(i);
        rv.target = mty(tymap, rv.target);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            rv.a += o0;
        } else if rv.kind == ir::RV_BINARY {
            rv.a += o0;
            rv.b += o0;
        } else if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            rv.a += p0;
        } else if rv.kind == ir::RV_REPEAT {
            rv.a += o0;
            rv.b += o0;
        } else if rv.kind == ir::RV_DYN {
            rv.a += o0;
            rv.b = mty(tymap, rv.b);
        } else if rv.kind == ir::RV_SLICE {
            rv.a += p0;
            if rv.b != ir::IR_NONE {
                rv.b += o0;
            }
            if rv.item.node != ir::IR_NONE {
                rv.item.node += o0;
            }
        } else if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_SIMD {
            rv.a += op0;
            if rv.kind == ir::RV_SIMD && rv.item.node != ir::IR_NONE {
                rv.item.node += ax0;
            }
        } else if rv.kind == ir::RV_INTRINSIC {
            if rv.c == ir::IN_SIZEOF || rv.c == ir::IN_ALIGNOF || rv.c == ir::IN_TYPE_INFO || rv.c == ir::IN_DANGLING {
                rv.b = mty(tymap, rv.b);
            } else if rv.b != 0 {
                rv.a += op0;
            }
        }
        b.rvalues.push(rv);
    }
    for i in 0..k.oper_pool.len() {
        let e = k.oper_pool[i];
        b.oper_pool.push(
            if e == ir::IR_NONE {
                e;
            } else {
                e + o0;
            },
        );
    }
    for i in 0..k.dest_pool.len() {
        let e = k.dest_pool[i];
        b.dest_pool.push(
            if e == ir::IR_NONE {
                e;
            } else {
                e + p0;
            },
        );
    }
    for i in 0..k.switch_pool.len() {
        let pair = k.switch_pool[i];
        b.switch_pool.push(pair & 0xFFFFFFFF00000000u64 | (pair & 0xFFFFFFFFu64) + b0 as u64);
    }
    for i in 0..k.targ_pool.len() {
        b.targ_pool.push(mty(tymap, k.targ_pool[i]));
    }
    for i in 0..k.simd_aux.len() {
        b.simd_aux.push(k.simd_aux[i]);
    }
    for i in 0..k.statements.len() {
        let mut s = *k.statements.at(i);
        if s.place != ir::IR_NONE {
            s.place += p0;
        }
        if s.rvalue != ir::IR_NONE {
            s.rvalue += r0;
        }
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD {
            s.a += l0;
        }
        s.span = sp;
        b.statements.push(s);
    }
    // callee blocks (returns become jumps to the join block)
    let orec = origins.len() as u32;
    origins.push(Origin { parent: blk_origin[call_blk], key: callee_key(k.owner) });
    for i in 0..k.blocks.len() {
        let kb = *k.blocks.at(i);
        let mut tm = kb.term;
        if tm.kind == ir::TM_RETURN {
            tm = ir::goto_term(join, sp);
        } else {
            tm.span = sp;
            if tm.kind == ir::TM_GOTO {
                tm.t0 += b0;
            } else if tm.kind == ir::TM_SWITCH {
                tm.a += o0;
                tm.sw_start += sw0;
                tm.t0 += b0;
            } else if tm.kind == ir::TM_DROP {
                tm.a += p0;
                if tm.args_len == 1 {
                    tm.args_start += l0; // the guard flag is a callee local
                }
                tm.t0 += b0;
            } else if tm.kind == ir::TM_CALL {
                if tm.a != ir::IR_NONE {
                    tm.a += o0;
                }
                tm.args_start += op0;
                tm.dests_start += d0;
                tm.targs_start += tg0;
                tm.iface = mty(tymap, tm.iface);
                tm.recv = mty(tymap, tm.recv);
                tm.t0 += b0;
            }
        }
        b.blocks.push(ir::BasicBlock { stmt_start: kb.stmt_start + s0, stmt_len: kb.stmt_len, term: tm, sealed: true });
        blk_origin.push(orec);
    }
    // prelude: parameter temps take the call's argument operands (original read order), each with
    // the call's own implicit adjustment (autoref/deref) reproduced in IR, then jump to the entry
    {
        let ps = b.statements.len() as u32;
        for j in 0..k.args {
            let al = l0 + k.returns + j;
            let opid = b.oper_pool[(t.args_start + j) as usize];
            let mode = wire[j as usize];
            if mode == 0 {
                b.assign_local_use(al, opid, sp);
            } else if mode == 1 {
                // autoref: the callee's reference parameter takes the caller's place directly
                let aty = b.locals.at(al as usize).ty;
                let src9 = b.operands.at(opid as usize).data;
                let a9 = unsafe &*(&*pkg9).module_ast_const(b.module);
                let mut mf: u32 = 0;
                if a9.type_at(aty).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    mf = 1;
                }
                b.assign_local(al, ir::rv(ir::RV_REF, src9, mf, 0, aty), sp);
            } else {
                // deref: a reference argument feeds a by-value parameter through one more hop
                let aty = b.locals.at(al as usize).ty;
                let spl = *b.places.at(b.operands.at(opid as usize).data as usize);
                for q in 0..spl.proj_len {
                    let pj9 = *b.projections.at((spl.proj_start + q) as usize);
                    b.projections.push(pj9);
                }
                b.projections.push(ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: aty });
                b.places.push(
                    ir::Place {
                        base: spl.base,
                        proj_start: b.projections.len() as u32 - 1 - spl.proj_len,
                        proj_len: spl.proj_len + 1,
                        ty: aty,
                    },
                );
                b.operands.push(ir::Operand { kind: ir::OP_COPY, data: b.places.len() as u32 - 1, ty: aty });
                b.assign_local_use(al, b.operands.len() as u32 - 1, sp);
            }
        }
        b.blocks.push(
            ir::BasicBlock { stmt_start: ps, stmt_len: k.args, term: ir::goto_term(b0 + k.entry, sp), sealed: true },
        );
        blk_origin.push(orec);
    }
    // join: move each return slot into the call's destination, then continue at the call's target.
    // A multi-return call's member reads of its one destination read the return slots instead.
    {
        let js = b.statements.len() as u32;
        let multi = alias.len() != 0;
        if multi {
            for i in 0..p0 as usize {
                let p = *b.places.at(i);
                if p.proj_len != 0 && alias.contains(&p.base) {
                    let pl = b.places.index_mut(i);
                    pl.base = l0 + b.projections.at(p.proj_start as usize).data;
                    pl.proj_start += 1;
                    pl.proj_len -= 1;
                }
            }
            // the copies of the temp become storage markers of their destination, and their
            // operands read return slot 0 (the operand pool is scanned whole): nothing reads the temps
            let slot0 = b.places.len() as u32;
            b.places.push(ir::Place { base: l0, proj_start: 0, proj_len: 0, ty: b.locals.at(l0 as usize).ty });
            for i in 0..s0 as usize {
                let x = alias_copy(b, i, alias);
                if x != ir::IR_NONE {
                    let oi = b.rvalues.at(b.statements.at(i).rvalue as usize).a as usize;
                    b.operands.index_mut(oi).data = slot0;
                    b.operands.index_mut(oi).ty = b.locals.at(l0 as usize).ty;
                    let st = b.statements.index_mut(i);
                    st.kind = ir::ST_STORAGE_LIVE;
                    st.a = x;
                }
            }
        }
        for r in 0..pick(multi, 0u32, k.returns) {
            let rl = l0 + r;
            b.places.push(ir::Place { base: rl, proj_start: 0, proj_len: 0, ty: b.locals.at(rl as usize).ty });
            b.operands.push(
                ir::Operand { kind: ir::OP_MOVE, data: b.places.len() as u32 - 1, ty: b.locals.at(rl as usize).ty },
            );
            let dpl = b.dest_pool[(t.dests_start + r) as usize];
            b.push_assign(dpl, ir::rv(ir::RV_USE, b.operands.len() as u32 - 1, 0, 0, b.places.at(dpl as usize).ty), sp);
        }
        if ki.demand {
            b.demands.push(*t);
        }
        b.blocks.push(
            ir::BasicBlock {
                stmt_start: js,
                stmt_len: b.statements.len() as u32 - js,
                term: ir::goto_term(t.t0, sp),
                sealed: true,
            },
        );
        blk_origin.push(orec);
    }
    b.blocks[call_blk].term = ir::goto_term(prelude, sp);
}
