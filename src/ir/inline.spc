// Core IR inliner (plans/1_bounds_check_elimination.md §8.5, §10): replaces qualifying direct
// TM_CALLs with the callee's lowered body so the caller-local BCE pass sees the callee's checks
// and guards. Runs on the emission path only, BEFORE drop elaboration: the callee's storage
// markers (params and user locals get ST_STORAGE_DEAD before every return) splice in verbatim,
// so the caller's single drop elaboration schedules the callee's drops at the same program
// points, in the same order, as the callee's own elaboration would have. Argument operands are
// reused in place (read order preserved); every early return becomes a jump to one join block
// that moves the return slots into the call's destinations.
//
// Candidate policy (conservative, tuned for the std index family): direct non-variadic calls to
// known function bodies of at most MAX_CALLEE_STMTS statements / MAX_CALLEE_BLOCKS blocks,
// non-recursive through the active splice chain, without asm, closures, variadic intrinsics,
// reflection, asserts, wide literals, static references, or `from` coercions, and without
// attributes beyond the inline hints (@c.noinline and @c.noreturn therefore reject). Inner calls
// and fn-value constants must target CONCRETE public functions -- anything else would need the
// emitter's demand machinery (symbols, prototypes, per-instantiation static_asserts) from a
// context the splice no longer has -- and a generic callee whose body defers a static_assert per
// instantiation stays a call so its demand still fires the guard. Generic callees inline when
// every generic parameter binds through the call (signature unification plus the recorded type
// arguments) and every body type translates into the caller's pool; const-generic types do not
// translate and reject the site. Never into a body holding IN_REFLECT binder placeholders.
//
// Spliced constants keep their raw spans and mark the callee module in `item` (the emitter's
// foreign-source convention for CK_STR, extended to CK_FLOAT and CK_INT); IR_NONE sentinels are
// preserved through every pool remap. Declared callee locals become LS_INL so the caller's drop
// elaboration schedules their storage-death drops exactly as the callee's own would have.
import ast::ast as *;
import lexer::token as tok;
import module::loader as loader;
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
pub const IJ_LOWER_FAIL: u8 = 7;
pub const IJ_ARITY: u8 = 8; // variadic call or argument/destination count mismatch
pub const IJ_COUNT: usize = 9;

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
/// Per caller body: total statements added by all splices (nested ones included).
const MAX_ADDED_STMTS: usize = 512;
/// Nested splice depth (a spliced call inlining its own calls).
const MAX_DEPTH: usize = 3;

// keep_ix value encoding: slot index, or REJ_BASE | reason for a cached rejection.
const REJ_BASE: u64 = 0xFFFFFFFF00000000u64;

/// One cached callee: its lowered pre-elaboration body plus the generic-parameter decl list in
/// targ order (extend parameters first, then the function's own).
struct CalleeInfo {
    pub body: ir::CoreBody,
    pub gp: Vector<NodeId>,
    pub fg: u32, // trailing entries of `gp` that are the function's own parameters
}

/// One generic-parameter binding: `(pm, pnode)` resolves to caller-pool type `at`.
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
    pub reasons: [u32; 9],
}

extend InlineStats {
    pub fn new() InlineStats {
        return InlineStats { considered: 0, inlined: 0, reasons: [[0] = 0u32] };
    }
}

/// Package-emission-lifetime state: one per DropCtx, so callee lowerings amortize across every
/// body that context emits. Decisions depend only on body and AST content, never on cache state.
pub struct InlineCtx {
    pub off: bool,
    pub stats_on: bool,
    pub keep_ix: Map<u64, u64>,
    pub kept: Vector<CalleeInfo>,
    /// Type-translation cache: one entry per distinct (callee slot, caller module, binds) call
    /// shape. Filling a map walks the whole callee type table through `xty`; the same shape
    /// repeats at every call site of a callee, so the walk runs once per shape instead.
    /// Pooled vet Lowerer (0 or 1): `callee_slot` re-lowers one candidate per cache miss, and a
    /// fresh Lowerer per miss dominated the analysis allocations.
    pub vlw: Vector<irl::Lowerer>,
    pub xm_ix: Map<u64, u64>, // shape hash -> xms index
    pub xm_key: Vector<Vector<u64>>, // exact shape per entry: slot, cm, then (pm<<32|pnode, at) pairs
    pub xms: Vector<Map<u64, u64>>,
}

extend CalleeInfo as Free {
    pub fn free(self: &mut Self) {
        self.body.free();
        self.gp.free();
    }
}

extend InlineCtx as Free {
    pub fn free(self: &mut Self) {
        self.keep_ix.free();
        self.kept.free();
        self.vlw.free();
        self.xm_ix.free();
        self.xm_key.free();
        self.xms.free();
    }
}

fn bind_add(binds: &mut Vector<GBind>, pm: ModuleId, pnode: NodeId, at: TypeId) {
    for i in 0..binds.len() {
        if binds.at(i).pm == pm && binds.at(i).pnode == pnode {
            return; // first binding wins (signature unification runs before targ fill)
        }
    }
    binds.push(GBind { pm: pm, pnode: pnode, at: at });
}

/// Structural unification of a callee-pool type against the caller-pool type the checker matched
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
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        unify(pkg, km, y.as_data.elem, cm, z.as_data.elem, binds, depth + 1);
        return;
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let yi = *(unsafe &*p.module_ast_const(km)).instance(y.as_data.inst);
        let zi = *(unsafe &*p.module_ast_const(cm)).instance(z.as_data.inst);
        if yi.module == zi.module && yi.decl == zi.decl && yi.n == zi.n {
            for i in 0..yi.n {
                unify(pkg, km, unsafe yi.args[i as usize], cm, unsafe zi.args[i as usize], binds, depth + 1);
            }
        }
    }
}

/// Translate callee-pool type `kt` into the caller module's pool, substituting bound generic
/// parameters. TYPE_NONE on failure (unbound parameter, const-generic expression, or a function
/// type under an active substitution).
fn xty(pkg: *const loader::Package, km: ModuleId, kt: TypeId, cm: ModuleId, binds: &Vector<GBind>, depth: u32) TypeId {
    if kt == TYPE_NONE || depth > 24 {
        return TYPE_NONE;
    }
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
        TYPE_CONST_EXPR | TYPE_FIELD_PROJECTION | TYPE_ERROR => TYPE_NONE,
        TYPE_FUNCTION => {
            // the signature payload is module-relative and opaque here: only a substitution-free
            // copy is sound
            let mut r = TYPE_NONE;
            if binds.len() == 0 {
                r = ca.reintern(ka, kt);
            }
            r;
        },
        TYPE_POINTER | TYPE_REFERENCE | TYPE_SLICE | TYPE_ARRAY => {
            let e = xty(pkg, km, y.as_data.elem, cm, binds, depth + 1);
            let mut r = TYPE_NONE;
            if e != TYPE_NONE || y.as_data.elem == TYPE_NONE {
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
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let nid = unsafe a.list(items)[i as usize];
        if a.at_const(nid).kind != NodeKind::NODE_EXTEND {
            continue;
        }
        let ms = a.at_const(nid).as_data.extend_def.items;
        for j in 0..ms.len {
            if unsafe a.list(ms)[j as usize] == fnode {
                return nid;
            }
        }
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
    if !f.is_public || f.is_extern || f.body == NODE_NONE || f.generics.len != 0 {
        return false;
    }
    let ext = extend_of(a, d.node);
    if ext != NODE_NONE && a.at_const(ext).as_data.extend_def.generics.len != 0 {
        return false;
    }
    return true;
}

extend InlineCtx {
    pub fn new() InlineCtx {
        let e = stdlib::getenv("SC_INLINE");
        let mut off = false;
        if e != null && str::from_cstr(e) == "0" {
            off = true;
        }
        return InlineCtx {
            off: off,
            stats_on: stdlib::getenv("SC_INLINE_STATS") != null,
            keep_ix: Map::<u64, u64>::new(),
            kept: Vector::<CalleeInfo>::new(),
            vlw: Vector::<irl::Lowerer>::new(),
            xm_ix: Map::<u64, u64>::new(),
            xm_key: Vector::<Vector<u64>>::new(),
            xms: Vector::<Map<u64, u64>>::new(),
        };
    }

    /// Lower and vet one callee, caching the outcome. Returns the kept slot, or REJ_BASE|reason.
    fn callee_slot(self: &mut Self, pkg: *const loader::Package, d: DefId) u64 {
        let key = callee_key(d);
        switch self.keep_ix.get(&key) {
            Some(v) => {
                return *v;
            },
            None => {},
        };
        let mut lw = switch self.vlw.pop() {
            Some(l0) => {
                let mut l1 = l0;
                l1.retarget(d.module);
                l1;
            },
            _ => {
                irl::Lowerer::new(pkg, d.module, d.node);
            },
        };
        let r = self.callee_slot_i(pkg, d, &mut lw);
        self.vlw.push(lw);
        self.keep_ix.insert(key, r);
        return r;
    }

    fn callee_slot_i(self: &mut Self, pkg: *const loader::Package, d: DefId, lw: &mut irl::Lowerer) u64 {
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
        if f.is_extern || f.body == NODE_NONE {
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
        let ext = extend_of(a, d.node);
        // A GENERIC body carrying a static_assert defers it per instantiation; that guard fires
        // only when a call site DEMANDS the instance, and inlining the call erases the demand.
        // Such callees must stay calls.
        if f.generics.len != 0 || ext != NODE_NONE && a.at_const(ext).as_data.extend_def.generics.len != 0 {
            let bsp = a.at_const(f.body).span;
            for ni in 0..a.nodes.len() {
                let nd9 = a.at_const(ni as NodeId);
                if nd9.kind == NodeKind::NODE_STATIC_ASSERT && nd9.span.start >= bsp.start && nd9.span.end <= bsp.end {
                    return REJ_BASE | IJ_SHAPE as u64;
                }
            }
        }
        if !lw.lower_fn(d.node) {
            return REJ_BASE | IJ_LOWER_FAIL as u64;
        }
        let mut rej: u64 = 0;
        if lw.body.has_reflect || lw.body.has_zst_cond || lw.closures.len() != 0 {
            rej = REJ_BASE | IJ_SHAPE as u64;
        } else if lw.body.statements.len() > MAX_CALLEE_STMTS || lw.body.blocks.len() > MAX_CALLEE_BLOCKS || lw.body.locals.len() > MAX_CALLEE_LOCALS {
            rej = REJ_BASE | IJ_TOO_BIG as u64;
        }
        if rej == 0 {
            for i in 0..lw.body.blocks.len() {
                let tk = &lw.body.blocks.at(i).term;
                if tk.kind == ir::TM_ASSERT {
                    rej = REJ_BASE | IJ_SHAPE as u64; // the assert message renders from the callee module's source
                    break;
                }
                // Inner calls splice into a FOREIGN TU: only a public non-extern CONCRETE
                // function (no fn/extend generics, no call targs) is guaranteed a global symbol
                // and a shared prototype there -- a generic inner call would need the emitter's
                // demand machinery to re-derive substitutions it no longer has context for.
                if tk.kind == ir::TM_CALL && (tk.callee.node == NODE_NONE || tk.targs_len != 0 || !is_concrete_pub_fn(
                    pkg,
                    tk.callee,
                )) {
                    rej = REJ_BASE | IJ_SHAPE as u64;
                    break;
                }
            }
        }
        if rej == 0 {
            for i in 0..lw.body.locals.len() {
                if lw.body.locals.at(i).storage == ir::LS_STATIC_REF {
                    rej = REJ_BASE | IJ_SHAPE as u64; // item symbol/linkage is the owner TU's business
                    break;
                }
            }
        }
        if rej == 0 {
            for i in 0..lw.body.blocks.len() {
                let t9 = lw.body.blocks.at(i).term;
                if t9.kind == ir::TM_RETURN && t9.args_len == ir::RET_CANCEL {
                    // A cancellation-edge return unwinds the CALLER too; rewiring it as a goto
                    // would read the poison value and resume normal flow.
                    rej = REJ_BASE | IJ_SHAPE as u64;
                    break;
                }
            }
        }
        if rej == 0 {
            for i in 0..lw.body.rvalues.len() {
                let rv = lw.body.rvalues.at(i);
                let mut bad = rv.kind == ir::RV_CLOSURE;
                if rv.kind == ir::RV_CAST && rv.b == ir::CAST_COERCE_FROM as u32 {
                    bad = true;
                }
                if rv.kind == ir::RV_INTRINSIC && (rv.c == ir::IN_VA_START || rv.c == ir::IN_VA_ARG || rv.c == ir::IN_VA_END || rv.c == ir::IN_ASM || rv.c == ir::IN_REFLECT) {
                    bad = true;
                }
                if rv.kind == ir::RV_REPEAT && lw.body.is_generic {
                    bad = true; // a symbolic repeat count must re-lower per instance
                }
                if bad {
                    rej = REJ_BASE | IJ_SHAPE as u64;
                    break;
                }
            }
        }
        if rej == 0 {
            for i in 0..lw.body.constants.len() {
                let c9 = lw.body.constants.at(i);
                if c9.kind == ir::CK_WIDE {
                    rej = REJ_BASE | IJ_SHAPE as u64; // wide-literal records index the callee module's Ast
                    break;
                }
                if c9.kind == ir::CK_ITEM && (c9.targ_len != 0 || !is_concrete_pub_fn(pkg, c9.item)) {
                    rej = REJ_BASE | IJ_SHAPE as u64; // fn-value symbols follow the inner-call rule
                    break;
                }
            }
        }
        if rej != 0 {
            return rej;
        }
        let mut kb = ir::CoreBody::compact_from(&lw.body);
        kb.has_uninit_decl = lw.body.has_uninit_decl;
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
        self.kept.push(CalleeInfo { body: kb, gp: gp, fg: fgl.len });
        return slot;
    }
}

/// Emit `local = RV_USE(op)` into the body's pools (fresh place and rvalue; `op` may be a reused
/// caller operand or a fresh one).
fn assign_local_use(b: &mut ir::CoreBody, l: ir::LocalId, op: ir::OperandId, sp: tok::Span) {
    let ty = b.locals.at(l as usize).ty;
    b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ty });
    let pl = b.places.len() as u32 - 1;
    b.rvalues.push(
        ir::Rvalue { kind: ir::RV_USE, a: op, b: 0, c: 0, target: ty, item: DefId { module: 0, node: NODE_NONE } },
    );
    b.statements.push(
        ir::Statement { kind: ir::ST_ASSIGN, place: pl, rvalue: b.rvalues.len() as u32 - 1, a: 0, b: 0, span: sp },
    );
}

const fn goto_term(t0: ir::BlockId, sp: tok::Span) ir::Terminator {
    return ir::Terminator {
        kind: ir::TM_GOTO,
        a: ir::IR_NONE,
        args_start: 0,
        args_len: 0,
        dests_start: 0,
        dests_len: 0,
        sw_start: 0,
        sw_len: 0,
        t0: t0,
        callee: DefId { module: 0, node: NODE_NONE },
        targs_start: 0,
        targs_len: 0,
        is_variadic: false,
        span: sp,
    };
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
pub fn run(lw: &mut irl::Lowerer, cx: &mut InlineCtx, st: &mut InlineStats) {
    if cx.off {
        return;
    }
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
    let mut blk_origin = Vector::<u32>::new();
    blk_origin.resize_default(lw.body.blocks.len());
    for i in 0..lw.body.blocks.len() {
        blk_origin.set(i, ir::IR_NONE);
    }
    let mut origins = Vector::<Origin>::new();
    let mut added: usize = 0;
    let mut binds = Vector::<GBind>::new();
    let mut tymap = Map::<u64, u64>::new();
    let mut wire = Vector::<u8>::new();
    let mut probe = Vector::<TypeId>::new();
    let mut shape = Vector::<u64>::new();
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
        let slot = cx.callee_slot(pkg, t.callee);
        if slot >= REJ_BASE {
            let rr = (slot & 0xFFu64) as usize;
            unsafe {
                st.reasons[rr] = st.reasons[rr] + 1;
            }
            continue;
        }
        let ki = cx.kept.at(slot as usize);
        let k = &ki.body;
        if k.args != t.args_len || k.returns != t.dests_len {
            st.reasons[IJ_ARITY as usize] = st.reasons[IJ_ARITY as usize] + 1;
            continue;
        }
        if added + k.statements.len() + k.args as usize + k.returns as usize > MAX_ADDED_STMTS {
            st.reasons[IJ_BUDGET as usize] = st.reasons[IJ_BUDGET as usize] + 1;
            continue;
        }
        // ---- generic bindings: signature unification, then recorded type arguments -------------
        binds.truncate(0);
        let cm = lw.body.module;
        let km = t.callee.module;
        for j in 0..k.args {
            let opid = lw.body.oper_pool[(t.args_start + j) as usize];
            let cty = lw.body.operands.at(opid as usize).ty;
            unify(pkg, km, k.locals.at((k.returns + j) as usize).ty, cm, cty, &mut binds, 0);
        }
        for r in 0..k.returns {
            let dpl = lw.body.dest_pool[(t.dests_start + r) as usize];
            unify(pkg, km, k.locals.at(r as usize).ty, cm, lw.body.places.at(dpl as usize).ty, &mut binds, 0);
        }
        if t.targs_len as usize == ki.gp.len() && ki.gp.len() != 0 {
            for i in 0..ki.gp.len() {
                bind_add(&mut binds, km, ki.gp[i], lw.body.targ_pool[t.targs_start as usize + i]);
            }
        } else if ki.fg != 0 && t.targs_len >= ki.fg {
            let skip = (t.targs_len - ki.fg) as usize;
            let base0 = ki.gp.len() - ki.fg as usize;
            for i in 0..ki.fg as usize {
                bind_add(&mut binds, km, ki.gp[base0 + i], lw.body.targ_pool[t.targs_start as usize + skip + i]);
            }
        }
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
            h9 = (h9 ^ shape[i]) * 1099511628211;
        }
        let mut cix: i64 = -1;
        let mut collide = false;
        switch cx.xm_ix.get(&h9) {
            Some(v) => {
                let kk = cx.xm_key.at((*v) as usize);
                let mut same = kk.len() == shape.len();
                if same {
                    for i in 0..shape.len() {
                        if kk[i] != shape[i] {
                            same = false;
                            break;
                        }
                    }
                }
                if same {
                    cix = (*v) as i64;
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
                let mut sk = Vector::<u64>::new();
                for i in 0..shape.len() {
                    sk.push(shape[i]);
                }
                cix = cx.xms.len() as i64;
                cx.xm_key.push(sk);
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
                // &mut T into a &T parameter: the same C pointer value, no adjustment needed
                let py0 = *ca.type_at(pt);
                let sy0 = *ca.type_at(sty);
                if py0.kind == TypeKind::TYPE_REFERENCE && sy0.kind == TypeKind::TYPE_REFERENCE && py0.as_data.elem == sy0.as_data.elem {
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
                let dpl = lw.body.dest_pool[(t.dests_start + r) as usize];
                if mty(tyr, k.locals.at(r as usize).ty) != eff_pty(&lw.body, dpl) {
                    wok = false;
                    break;
                }
            }
        }
        if !wok {
            st.reasons[IJ_GENERIC as usize] = st.reasons[IJ_GENERIC as usize] + 1;
            continue;
        }
        // ---- splice (infallible from here) -----------------------------------------------------
        splice(lw, ki, &t, bi - 1, tyr, &wire, &mut blk_origin, &mut origins);
        added += k.statements.len() + k.args as usize + k.returns as usize;
        st.inlined += 1;
    }
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
    wire: &Vector<u8>,
    blk_origin: &mut Vector<u32>,
    origins: &mut Vector<Origin>,
) {
    let k = &ki.body;
    let pkg9 = lw.pkg;
    let b = &mut lw.body;
    let sp = t.span;
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
    let nkb = k.blocks.len() as u32;
    let prelude = b0 + nkb;
    let join = prelude + 1;
    // locals: return slots and parameters become plain temps; decl clears so no consumer indexes
    // the callee's Ast through the caller module (drop scheduling keys on the storage markers)
    for i in 0..k.locals.len() {
        let mut d = *k.locals.at(i);
        d.ty = mty(tymap, d.ty);
        // Declared callee locals (args and user bindings) become LS_INL so the caller's drop
        // elaboration schedules their storage-death drops exactly as the callee's own would
        // (the elaboration keys declaredness on `decl`, which must clear: it names a node in the
        // CALLEE module's Ast). Return slots become plain temps: the join moves them out.
        if d.storage == ir::LS_RET {
            d.storage = ir::LS_TEMP;
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
        if c.targ_len != 0 {
            c.targ_start += tg0;
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
        if o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE {
            o.data += p0;
        } else {
            o.data += c0;
        }
        o.ty = mty(tymap, o.ty);
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
        } else if rv.kind == ir::RV_AGGREGATE {
            rv.a += op0;
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
            tm = goto_term(join, sp);
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
                tm.t0 += b0;
            } else if tm.kind == ir::TM_CALL {
                if tm.a != ir::IR_NONE {
                    tm.a += o0;
                }
                tm.args_start += op0;
                tm.dests_start += d0;
                tm.targs_start += tg0;
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
                assign_local_use(b, al, opid, sp);
            } else if mode == 1 {
                // autoref: the callee's reference parameter takes the caller's place directly
                let aty = b.locals.at(al as usize).ty;
                let src9 = b.operands.at(opid as usize).data;
                let a9 = unsafe &*(&*pkg9).module_ast_const(b.module);
                let mut mf: u32 = 0;
                if a9.type_at(aty).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    mf = 1;
                }
                b.places.push(ir::Place { base: al, proj_start: 0, proj_len: 0, ty: aty });
                b.rvalues.push(
                    ir::Rvalue {
                        kind: ir::RV_REF,
                        a: src9,
                        b: mf,
                        c: 0,
                        target: aty,
                        item: DefId { module: 0, node: NODE_NONE },
                    },
                );
                b.statements.push(
                    ir::Statement {
                        kind: ir::ST_ASSIGN,
                        place: b.places.len() as u32 - 1,
                        rvalue: b.rvalues.len() as u32 - 1,
                        a: 0,
                        b: 0,
                        span: sp,
                    },
                );
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
                assign_local_use(b, al, b.operands.len() as u32 - 1, sp);
            }
        }
        b.blocks.push(
            ir::BasicBlock { stmt_start: ps, stmt_len: k.args, term: goto_term(b0 + k.entry, sp), sealed: true },
        );
        blk_origin.push(orec);
    }
    // join: move each return slot into the call's destination, then continue at the call's target
    {
        let js = b.statements.len() as u32;
        for r in 0..k.returns {
            let rl = l0 + r;
            b.places.push(ir::Place { base: rl, proj_start: 0, proj_len: 0, ty: b.locals.at(rl as usize).ty });
            b.operands.push(
                ir::Operand { kind: ir::OP_MOVE, data: b.places.len() as u32 - 1, ty: b.locals.at(rl as usize).ty },
            );
            let dpl = b.dest_pool[(t.dests_start + r) as usize];
            b.rvalues.push(
                ir::Rvalue {
                    kind: ir::RV_USE,
                    a: b.operands.len() as u32 - 1,
                    b: 0,
                    c: 0,
                    target: b.places.at(dpl as usize).ty,
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            b.statements.push(
                ir::Statement {
                    kind: ir::ST_ASSIGN,
                    place: dpl,
                    rvalue: b.rvalues.len() as u32 - 1,
                    a: 0,
                    b: 0,
                    span: sp,
                },
            );
        }
        b.blocks.push(ir::BasicBlock { stmt_start: js, stmt_len: k.returns, term: goto_term(t.t0, sp), sealed: true });
        blk_origin.push(orec);
    }
    b.blocks[call_blk].term = goto_term(prelude, sp);
    b.has_uninit_decl = b.has_uninit_decl || k.has_uninit_decl;
}
