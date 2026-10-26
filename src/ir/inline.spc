// Core IR inliner: replaces qualifying direct TM_CALLs with the callee's lowered body so the
// caller-local BCE pass sees the callee's checks and guards. Runs on the emission path only, over ELABORATED bodies: the borrow pass rewrote
// every kept body with its drop terminators (`ir::drops`), so a callee splices in with its own
// drops, flag temps and storage markers, and no ownership analysis runs on the merged body (the
// caller was elaborated before its splices too). A parameter the callee never writes, drops or
// addresses reads its argument in place (`param_facts`, `splice`): a constant argument is the
// constant, an autoref receiver's `(*self).f` is the caller's `x.f`, and any other argument's place
// is read where the parameter was when nothing the callee runs can change it (a callee that writes
// no memory, or a place in a local whose storage no pointer reaches: `exposed`). Every other
// parameter takes a prelude copy of its argument, in the call's argument order. Every early return
// becomes a jump to one join block that moves the return slots into the call's destinations.
//
// Candidate policy: direct non-variadic calls to known function bodies of at most
// MAX_CALLEE_STMTS statements / MAX_CALLEE_BLOCKS blocks / MAX_CALLEE_LOCALS locals (VEC_SCALE
// times more for a vector signature; a body past them with a switch on a const-generic parameter is
// sized per call by the arms its bindings take; `@always_inline` lifts them), non-recursive through
// the active splice chain, at
// most MAX_DEPTH splices deep and MAX_ADDED_STMTS statements per caller (VEC_SCALE times more in a
// caller that holds a vector), without asm, closures, variadic intrinsics, reflection, asserts, wide
// literals, statics of a generic scope, or `from` coercions, and without attributes beyond the
// inline hints, the build gates and `@target_feature` (@noinline and @noreturn therefore
// reject). The splice translates every type, type argument,
// receiver and interface of the callee into the caller's types, so an inner call spells and demands
// in the caller's unit as the caller's own call: a function with a body, an interface method, a
// function value, a non-variadic extern function (every unit sees its declaration) or a runtime
// atomic; not an associated function of a generic extend that names its
// receiver by no type of the call (`env_receiver`: the instance env names it). A callee that reads a
// module's constant or static, or whose inner call names another function than a concrete public
// one or a non-variadic extern one, inlines into a caller that holds a vector only
// (`CalleeInfo.vec_only`, `holds_vector`): vector code gains the most, and elsewhere the C compiler's
// own inlining serves without the larger C. A generic callee whose
// body defers a static_assert per instantiation records the call in the caller's `demands`, so the
// guard still fires. Generic callees inline when every generic parameter binds through the call
// (signature unification plus the recorded type arguments) and every body type substitutes into a
// package type; a const-generic parameter bound to a value reads as that constant, one bound to the
// caller's own parameter reads as that parameter. A switch whose scrutinee is then a constant takes
// its one edge (`CFlow` lays out no other), and a block no edge reaches inlines nothing. Never into a
// body holding IN_REFLECT binder placeholders. The emitter's bound variants (`ground_body`) turn a
// generic instance concrete, so a call through an interface the instance resolves inlines too.
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
import ir::facts as fx;
import ir::lower as irl;
import ir::cpu_features as cf;
import stdlib;

// Rejection reasons (SC_INLINE_STATS report order).
pub const IJ_NOT_FN: u8 = 0; // extern, bodiless, attributed, needing features the caller lacks, or not a plain function
pub const IJ_RECURSIVE: u8 = 1;
pub const IJ_SHAPE: u8 = 2; // asm/closure/reflect/assert/coercion/wide-literal body content
pub const IJ_TOO_BIG: u8 = 3;
pub const IJ_BUDGET: u8 = 4;
pub const IJ_DEPTH: u8 = 5;
pub const IJ_GENERIC: u8 = 6; // unbound generic parameter or untranslatable type
pub const IJ_ARITY: u8 = 7; // variadic call or argument/destination count mismatch
pub const IJ_COUNT: usize = 8;

/// Emission-mode env switches: every setting that changes the C a body renders to, and the LIR check
/// (`SC_LIR`), which a replayed module passed when its record was written. Build stamps and TU-cache
/// keys read the list by index, so a new switch joins here once and every consumer follows; the order
/// is part of the recorded keys.
pub const EMIT_MODE_ENV_N: usize = 5;

pub fn emit_mode_env(i: usize) str<'static> {
    if i == 0 {
        return "SC_INLINE";
    }
    if i == 1 {
        return "SC_BCE";
    }
    if i == 2 {
        return "SC_BCE_DISABLE";
    }
    if i == 3 {
        return "SC_SIMD_SCALAR";
    }
    assert(i == 4);
    return "SC_LIR";
}

const MAX_CALLEE_STMTS: usize = 40;
const MAX_CALLEE_BLOCKS: usize = 10;
const MAX_CALLEE_LOCALS: usize = 32;

/// A callee that passes or returns a vector takes limits this many times larger: its call spills
/// every live vector register (no x86-64 vector register survives a call) and returns several
/// vectors through memory.
const VEC_SCALE: usize = 4;

/// The callee size gate over a body's current shape (`VEC_SCALE` for a vector signature, package
/// `pkg`). The borrow pass records the answer for the pre-elaboration shape in
/// `CoreBody.inline_size_ok` (the shape the limits were tuned for), and the vet reads that bit.
/// The blocks, statements and locals the counted-loop lowering added (`count_blocks`, `chunks`)
/// do not count.
pub fn callee_size_ok(b: &ir::CoreBody, pkg: *const loader::Package) bool {
    let ns = b.statements.len() - 2 * b.chunks as usize;
    let nb = b.blocks.len() - b.count_blocks as usize;
    let nl = b.locals.len() - 2 * b.chunks as usize;
    let k = size_scale(b, pkg);
    return ns <= MAX_CALLEE_STMTS * k && nb <= MAX_CALLEE_BLOCKS * k && nl <= MAX_CALLEE_LOCALS * k;
}

/// Whether a local of `b` (package `pkg`) is a vector: vector code, where the inliner reaches further
/// (`CalleeInfo.vec_only`).
pub fn holds_vector(b: &ir::CoreBody, pkg: *const loader::Package) bool {
    let a = unsafe &*(&*pkg).module_ast_const(b.module);
    for i in 0..b.locals.len() {
        let t = b.locals.at(i).ty;
        if t != TYPE_NONE && a.type_at(t).kind == TypeKind::TYPE_SIMD {
            return true;
        }
    }
    return false;
}

/// `VEC_SCALE` when a parameter or result of `b` (package `pkg`) is a vector, else 1.
fn size_scale(b: &ir::CoreBody, pkg: *const loader::Package) usize {
    let a = unsafe &*(&*pkg).module_ast_const(b.module);
    for i in 0..(b.returns + b.args) as usize {
        let t = b.locals.at(i).ty;
        if t != TYPE_NONE && a.type_at(t).kind == TypeKind::TYPE_SIMD {
            return VEC_SCALE;
        }
    }
    return 1;
}
/// Per caller body: total statements added by all splices (nested ones included); VEC_SCALE times more
/// in a caller that holds a vector.
const MAX_ADDED_STMTS: usize = 512;
/// Nested splice depth (a spliced call inlining its own calls); the budget above bounds the growth.
pub const MAX_DEPTH: usize = 6;

// keep_ix value encoding: slot index, or REJ_BASE | reason for a cached rejection.
const REJ_BASE: u64 = 0xFFFFFFFF00000000u64;

// How an argument meets its parameter (`run`'s wire, one per argument).
const W_EXACT: u8 = 0; // the parameter's type
const W_AUTOREF: u8 = 1; // a place for a reference parameter: the callee receives its address
const W_DEREF: u8 = 2; // a reference for a by-value parameter: the callee receives the referent
const W_PTR: u8 = 3; // a pointer or reference of another qualifier: the same C value
const W_FN: u8 = 4; // a function for a function-pointer parameter

// Parameter facts of a callee (`param_facts`), one byte per parameter.
const PF_WRITE: u8 = 1; // a store, a call result or a drop names its own storage
const PF_ADDR: u8 = 2; // its own storage may be addressed: a borrow, a receiver, an array argument
const PF_PLACE: u8 = 4; // a place of it outside an operand, or a projected place
const PF_BARE: u8 = 8; // a place of it whose path does not start with a dereference

// How a parameter reads its argument (`splice`), kept in its facts byte from bit SUB_SHIFT.
const SUB_SHIFT: u8 = 4;
const SUB_NONE: u8 = 0; // a prelude copy
const SUB_PLACE: u8 = 1; // the argument's place: `a.f` reads `x.f`
const SUB_REF: u8 = 2; // through an autoref receiver: `(*self).f` reads `x.f`
const SUB_CONST: u8 = 3; // the argument constant

/// One cached callee: its lowered, elaborated body plus the generic-parameter decl list in targ
/// order (extend parameters first, then the function's own).
pub struct CalleeInfo {
    pub body: ir::CoreBody,
    pub gp: Vector<NodeId>,
    pub fg: u32, // trailing entries of `gp` that are the function's own parameters
    pub demand: bool, // a generic body with a per-instantiation static_assert: the splice keeps the demand
    pub big: bool, // past the size gate, with a switch on a const-generic parameter: sized per call (`live_size`)
    pub vec_only: bool, // inlines into a caller that holds a vector only (`vet_body`)
    /// `@always_inline` in a native build, whose backend inlines nothing: past the size, budget and
    /// vector gates (`always_native`).
    pub always: bool,
}

/// Whether `d` is `@always_inline`: the splice takes it whatever its size.
fn always_inline(p: &loader::Package, d: DefId) bool {
    return p.modules.at(d.module as usize).has_ast && unsafe (*p.module_ast_const(d.module)).attr_of(
        d.node,
        AttrKind::ATTR_ALWAYS_INLINE,
    ) != null;
}

/// Whether `d` is `@always_inline` in a native build of `pkg`: the splice is its only inlining, so it
/// also passes the budget and the vector gates (the C compiler inlines it in a C build).
pub fn always_native(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    return p.native && always_inline(p, d);
}

/// One generic-parameter binding: `(pm, pnode)` resolves to the caller's type `at`.
pub struct GBind {
    pub pm: ModuleId,
    pub pnode: NodeId,
    pub at: TypeId,
}

/// Splice provenance of an appended block (recursion and depth guard for nested inlining).
pub struct Origin {
    pub parent: u32, // origin index of the block the call sat in; IR_NONE at top level
    pub key: u64, // callee identity key
}

/// The elements splices add to each pool of a caller (`expect_growth`).
struct Growth {
    pub locals: usize,
    pub blocks: usize,
    pub statements: usize,
    pub places: usize,
    pub projections: usize,
    pub operands: usize,
    pub rvalues: usize,
    pub constants: usize,
    pub oper_pool: usize,
    pub dest_pool: usize,
    pub switch_pool: usize,
    pub targ_pool: usize,
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
    /// The kept functions whose bodies hold a vector and no closure: callee key -> `vec_bodies` slot.
    /// A call of one from a function with features beyond the build's runs a copy compiled with
    /// that function's features (the emitter's feature clones), lowered from this copy: the kept
    /// body itself moves to its own emission.
    pub vec_ix: Map<u64, u64>,
    pub vec_bodies: Vector<ir::CoreBody>,
}

/// Per-DropCtx state: the type-translation caches over the shared store's slots, and the splice
/// scratch. Decisions depend only on body and AST content, never on cache state.
pub struct InlineCtx {
    pub off: bool,
    /// Splice only the callees whose result the caller's instance fixes (`fixed_result`): a bound
    /// variant of scalar code (`driver::emit::bind_calls`).
    pub only_fixed: bool,
    pub stats_on: bool,
    pub store: *const InlineStore,
    /// Type-translation cache: one entry per distinct (callee slot, caller module, binds) call
    /// shape. Filling a table walks the whole callee type table through `xty`; the same shape
    /// repeats at every call site of a callee, so the walk runs once per shape instead. The
    /// entries fill two shared pools in order: entry `e` starts at `xm_ko[e]` in `xm_keys` and at
    /// `xm_to[e]` in `xm_tys`, and ends where entry `e + 1` starts (the last at the pool's end).
    pub xm_ix: Map<u64, u64>, // shape hash -> entry index
    pub xm_keys: Vector<u64>, // exact shape per entry: slot, cm, then (pm<<32|pnode, at) pairs
    pub xm_ko: Vector<u32>,
    pub xm_tys: Vector<u64>, // translation table per entry (`ty_table`)
    pub xm_to: Vector<u32>,
    /// Per entry: where the callee's parameter facts under that translation start in `xm_pfs`
    /// (`param_facts`, one byte per parameter), and whether it writes no memory (0 not computed, 1
    /// no, 2 yes).
    pub xm_pfo: Vector<u32>,
    pub xm_wf: Vector<u8>,
    pub xm_pfs: Vector<u8>,
    /// Callees with vector index lists over their parameters (`CoreBody.has_lists`) re-lowered under
    /// one call shape's bindings, where the lists resolve: shape hash -> `rl` index, or a rejection.
    pub rl_ix: Map<u64, u64>,
    pub rl: Vector<CalleeInfo>,
    // `run` scratch (capacity survives across bodies).
    pub sc_blk_origin: Vector<u32>,
    pub sc_origins: Vector<Origin>,
    pub sc_binds: Vector<GBind>,
    pub sc_tymap: Map<u64, u64>, // the callee types translated so far: callee type -> caller type
    pub sc_pairs: Vector<u64>, // the same, as `ty_table` input
    pub sc_tys: Vector<u64>, // the table of a shape the cache cannot index (a hash collision)
    pub sc_wire: Vector<u8>,
    pub sc_probe: Vector<TypeId>,
    pub sc_shape: Vector<u64>,
    pub sc_live: Vector<bool>,
    pub sc_stack: Vector<u32>,
    pub sc_expo: Vector<u32>, // per caller local: the operations that may address its storage (`exposed`)
    pub sc_writes: Writes, // per caller local: its writes (`once_aggregate`, `agg_field`)
    pub sc_oref: Vector<u32>, // per caller operand: a mark (`unread`)
    pub sc_orph: Vector<u32>, // the call operands of arguments read in place (`unread`)
    pub sc_pf: Vector<u8>, // per callee parameter: its `PF_*` facts
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

/// A function with a body, or an interface method a call dispatches per receiver: its call spells
/// from the call's own types (the splice translates them) and demands what it names, in any TU.
fn is_spelled_fn(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() || !p.modules.at(d.module as usize).has_ast {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    if n.kind != NodeKind::NODE_FUNCTION || n.as_data.function.is_extern() {
        return false;
    }
    let c = a.container_of(d.node);
    return n.as_data.function.body != NODE_NONE || c != NODE_NONE && a.at_const(c).kind == NodeKind::NODE_INTERFACE;
}

/// A public non-extern CONCRETE function with a body (no generics of its own, and any enclosing
/// extend non-generic): an inner call of it keeps a callee a candidate for any caller (`vet_body`).
fn is_concrete_pub_fn(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    if n.kind != NodeKind::NODE_FUNCTION {
        return false;
    }
    let f = n.as_data.function;
    if !vis_exported(f.vis) || f.is_extern() || f.body == NODE_NONE || f.generics.len != 0 {
        return false;
    }
    let ext = extend_of(a, d.node);
    return ext == NODE_NONE || a.at_const(ext).as_data.extend_def.generics.len == 0;
}

/// A non-variadic extern function whose header is not scoped. Every TU sees its declaration: the
/// header of its block in `__sc_fwd.h`, a header the runtime includes, or the prototype the emitter
/// writes into `__sc_fwd.h` (`CEmit::collect_extern_proto`), so a call to it spells the same in any
/// TU. A scoped header (`Package::extern_header_scoped`) would bring its macros into the caller's.
fn is_global_extern_fn(pkg: *const loader::Package, d: DefId) bool {
    let p = unsafe &*pkg;
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() || !p.modules.at(d.module as usize).has_ast || p.extern_item_scoped(
        d,
    ) {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let n = a.at_const(d.node);
    return n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.is_extern() && !n.as_data.function.is_variadic();
}

// Whether type `t` of module `m` is, or reaches through pointers, references, slices and arrays, a
// type of an extern block whose header is scoped (`Package::extern_item_scoped`).
fn ty_scoped(p: &loader::Package, m: ModuleId, t: TypeId) bool {
    let a = unsafe &*p.module_ast_const(m);
    let mut x = t;
    // An element chain is acyclic: it ends at a type of another kind.
    for _d in 0..ELEM_CHAIN_MAX {
        if x == TYPE_NONE {
            return false;
        }
        let y = *a.type_at(x);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_OPAQUE {
            return p.extern_item_scoped(DefId { module: y.module, node: y.as_data.decl });
        }
        if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_SLICE && !y.arr_like() {
            return false;
        }
        x = y.as_data.elem;
    }
    panic("an element chain longer than ELEM_CHAIN_MAX");
}

// The most element levels a type holds (`ty_scoped`).
const ELEM_CHAIN_MAX: u32 = 4096;

extend InlineCtx {
    /// Bytes the translation tables hold (SC_TYPE_STATS): the tables, the shape keys and their index.
    pub const fn xm_bytes(self: &Self) u64 {
        let b = (self.xm_tys.len() + self.xm_keys.len()) * 8 + self.xm_ko.len() * 13;
        return (b + self.xm_ix.len() * 17 * 2 + self.xm_pfs.len()) as u64;
    }

    pub fn new(store: *const InlineStore) InlineCtx {
        let off = stdlib::env_is("SC_INLINE", "0");
        return InlineCtx {
            off: off,
            only_fixed: false,
            stats_on: stdlib::getenv("SC_INLINE_STATS") != null,
            store: store,
            xm_ix: Map::<u64, u64>::new(),
            xm_keys: Vector::<u64>::new(),
            xm_ko: Vector::<u32>::new(),
            xm_tys: Vector::<u64>::new(),
            xm_to: Vector::<u32>::new(),
            xm_pfo: Vector::<u32>::new(),
            xm_wf: Vector::<u8>::new(),
            xm_pfs: Vector::<u8>::new(),
            rl_ix: Map::<u64, u64>::new(),
            rl: Vector::<CalleeInfo>::new(),
            sc_blk_origin: Vector::<u32>::new(),
            sc_origins: Vector::<Origin>::new(),
            sc_binds: Vector::<GBind>::new(),
            sc_tymap: Map::<u64, u64>::new(),
            sc_pairs: Vector::<u64>::new(),
            sc_tys: Vector::<u64>::new(),
            sc_wire: Vector::<u8>::new(),
            sc_probe: Vector::<TypeId>::new(),
            sc_shape: Vector::<u64>::new(),
            sc_live: Vector::<bool>::new(),
            sc_stack: Vector::<u32>::new(),
            sc_expo: Vector::<u32>::new(),
            sc_writes: Writes { cnt: Vector::<u32>::new(), rv: Vector::<u32>::new() },
            sc_oref: Vector::<u32>::new(),
            sc_orph: Vector::<u32>::new(),
            sc_pf: Vector::<u8>::new(),
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
            CalleeInfo {
                body: body,
                gp: unsafe (*ki).gp.clone(),
                fg: unsafe (*ki).fg,
                demand: unsafe (*ki).demand,
                big: unsafe (*ki).big,
                vec_only: unsafe (*ki).vec_only,
                always: unsafe (*ki).always,
            },
        );
        self.rl_ix.insert(key, self.rl.len() as u64 - 1);
        return self.rl.at(self.rl.len() - 1);
    }

    /// Whether the shared store keeps callee `d` as a candidate.
    pub fn kept(self: &Self, d: DefId) bool {
        return unsafe (*self.store).keeps(d);
    }

    /// Whether kept callee `d` (package `pkg`) computes its result from the instance's arguments
    /// alone: no parameter, no call, and no static it reads but its const-generic parameters
    /// (`V<N>::len()`, `return N;`), so its splice is a constant of the caller's instance.
    pub fn fixed_result(self: &Self, pkg: *const loader::Package, d: DefId) bool {
        let slot = self.callee_slot(d);
        if slot >= REJ_BASE {
            return false;
        }
        let k = &(unsafe &*self.store).kept.at(slot as usize).body;
        if k.args != 0 {
            return false;
        }
        for i in 0..k.blocks.len() {
            if k.blocks.at(i).term.kind == ir::TM_CALL {
                return false;
            }
        }
        for i in 0..k.locals.len() {
            if k.locals.at(i).storage == ir::LS_STATIC_REF && !is_param(unsafe &*pkg, k.locals.at(i).item) {
                return false;
            }
        }
        return true;
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
const fn is_param(p: &loader::Package, d: DefId) bool {
    return d.node != NODE_NONE && (unsafe &*p.module_ast_const(d.module)).at_const(d.node).kind == NodeKind::NODE_GENERIC_PARAM;
}

// The operand switch scrutinee `o` of `b` copies: through locals of `l0..`, each written once among
// statements `s0..` (blocks `bl0..` for call destinations) and never borrowed there, and through the
// discriminant of a payload-less enum (its value): what a `switch` on a value lowers into. `o` itself
// when it reads no such temp.
fn scrutinee(p: &loader::Package, b: &ir::CoreBody, o0: u32, s0: usize, l0: u32, bl0: usize) u32 {
    let mut o = o0;
    // Each hop crosses one temp: a scrutinee lowers through two at most.
    for _ in 0..4 {
        let op = *b.operands.at(o as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return o;
        }
        let rv = temp_source(b, op.data, s0, l0, bl0);
        if rv.kind == ir::RV_USE {
            o = rv.a;
            continue;
        }
        if rv.kind != ir::RV_DISCRIMINANT || b.places.at(rv.a as usize).proj_len != 0 {
            return o;
        }
        let y = *(unsafe &*p.module_ast_const(b.module)).type_at(b.places.at(rv.a as usize).ty);
        if y.kind != TypeKind::TYPE_ENUM || (unsafe &*p.module_ast_const(y.module)).enum_has_payload(y.as_data.decl) {
            return o;
        }
        let src = temp_source(b, rv.a, s0, l0, bl0);
        if src.kind != ir::RV_USE {
            return o;
        }
        o = src.a;
    }
    return o;
}

// The one assignment's rvalue of the local place `pl` of `b` names (`scrutinee`: a temp or a binding,
// not a parameter, result or item), else an rvalue of kind RV_CLOSURE (no such assignment).
const fn temp_source(b: &ir::CoreBody, pl0: u32, s0: usize, l0: u32, bl0: usize) ir::Rvalue {
    let none = ir::rv(ir::RV_CLOSURE, 0, 0, 0, TYPE_NONE);
    let pl = *b.places.at(pl0 as usize);
    let sk = b.locals.at(pl.base as usize).storage;
    if pl.proj_len != 0 || pl.base < l0 || sk != ir::LS_TEMP && sk != ir::LS_USER && sk != ir::LS_INL {
        return none;
    }
    let mut src = none;
    let mut n: u32 = 0;
    for i in s0..b.statements.len() {
        let st = *b.statements.at(i);
        if st.kind != ir::ST_ASSIGN || st.place == ir::IR_NONE {
            continue;
        }
        let rv = *b.rvalues.at(st.rvalue as usize);
        if (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR) && b.places.at(rv.a as usize).base == pl.base {
            return none;
        }
        if b.places.at(st.place as usize).base == pl.base {
            n += 1;
            if b.places.at(st.place as usize).proj_len != 0 {
                return none;
            }
            src = rv;
        }
    }
    for i in bl0..b.blocks.len() {
        let t = b.blocks.at(i).term;
        for j in 0..pick(t.kind == ir::TM_CALL, t.dests_len, 0) {
            let d = b.dest_pool[(t.dests_start + j) as usize];
            if d != ir::IR_NONE && b.places.at(d as usize).base == pl.base {
                return none;
            }
        }
    }
    return pick(n == 1, src, none);
}

// The exact value of integer or boolean constant `c` of `b`, an integer's read from its spelling
// (`Constant::int_value`).
const fn const_value(p: &loader::Package, b: &ir::CoreBody, c: &ir::Constant, v: &mut i64) bool {
    *v = c.val;
    if c.kind != ir::CK_INT {
        return c.kind == ir::CK_BOOL;
    }
    // An inlined constant's span indexes its own module (`item` marks it).
    let m = if c.item.node != NODE_NONE {
        c.item.module;
    } else {
        b.module;
    };
    return c.int_value(p.modules.at(m as usize).source.as_str(), v);
}

// Whether a switch may read scrutinee `o` of `b` in place of its temp: a constant whose `val`, the
// value `CFlow` and `reach` match the cases against, is the value its spelling holds.
const fn switch_on_const(p: &loader::Package, b: &ir::CoreBody, o: u32) bool {
    if b.operands.at(o as usize).kind != ir::OP_CONST {
        return false;
    }
    let c = b.constants.at(b.operands.at(o as usize).data as usize);
    let mut v: i64 = 0;
    return c.kind != ir::CK_INT || const_value(p, b, c, &mut v) && v == c.val;
}

// The integer value of operand `o` of `b` when it is a constant or a read of a const-generic
// parameter `binds` bind (types of module `cm`).
fn int_operand(p: &loader::Package, b: &ir::CoreBody, o: u32, cm: ModuleId, binds: &Vector<GBind>, v: &mut i64) bool {
    let op = *b.operands.at(o as usize);
    if op.kind == ir::OP_CONST {
        return const_value(p, b, b.constants.at(op.data as usize), v);
    }
    let pl = *b.places.at(op.data as usize);
    let l = *b.locals.at(pl.base as usize);
    return pl.proj_len == 0 && l.storage == ir::LS_STATIC_REF && is_param(p, l.item) && param_value(
        p,
        l.item,
        cm,
        binds,
        v,
    );
}

// The block switch `tm` of `b` goes to when its operand, or the scrutinee temp it reads
// (`scrutinee`), has a known value (`int_operand`); IR_NONE otherwise. A value past the u32 case
// encoding stays unknown.
fn switch_goes(p: &loader::Package, b: &ir::CoreBody, tm: &ir::Terminator, cm: ModuleId, binds: &Vector<GBind>) u32 {
    let mut v: i64 = 0;
    let mut o = tm.a;
    if b.operands.at(o as usize).kind != ir::OP_CONST && !b_param_read(p, b, o) {
        o = scrutinee(p, b, o, 0, 0, 0);
    }
    if !int_operand(p, b, o, cm, binds, &mut v) || v < 0 || v > 0xFFFFFFFF {
        return ir::IR_NONE;
    }
    for k in 0..tm.sw_len {
        let pair = b.switch_pool[(tm.sw_start + k) as usize];
        if pair >> 32 == v as u64 {
            return (pair & 0xFFFFFFFFu64) as u32;
        }
    }
    return tm.t0;
}

// Mark in `live` the blocks of `b` reachable from `from` that are not marked yet, a switch with a
// constant operand taking its one edge (as `CFlow` lays the C out); the statements of the marked
// blocks. `live` covers every block; `stack` is scratch.
fn reach(b: &ir::CoreBody, from: u32, live: &mut Vector<bool>, stack: &mut Vector<u32>) usize {
    let mut ns: usize = 0;
    stack.clear();
    stack.push(from);
    // Each block is pushed once per in-edge at most, and marked once.
    while stack.len() != 0 {
        let x = stack.pop().unwrap();
        if live[x as usize] {
            continue;
        }
        live.set(x as usize, true);
        let blk = *b.blocks.at(x as usize);
        ns += blk.stmt_len as usize;
        let t = blk.term;
        if t.kind == ir::TM_SWITCH && b.operands.at(t.a as usize).kind == ir::OP_CONST {
            let c = *b.constants.at(b.operands.at(t.a as usize).data as usize);
            let mut to = t.t0;
            for k in 0..t.sw_len {
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                if (pair >> 32) as u32 == c.val as u32 {
                    to = (pair & 0xFFFFFFFFu64) as u32;
                    break;
                }
            }
            stack.push(to);
            continue;
        }
        if t.kind == ir::TM_SWITCH {
            for k in 0..t.sw_len {
                stack.push((b.switch_pool[(t.sw_start + k) as usize] & 0xFFFFFFFFu64) as u32);
            }
        }
        if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE && t.t0 != ir::IR_NONE {
            stack.push(t.t0);
        }
    }
    return ns;
}

// The statements and blocks of callee `k` reachable from its entry when every switch on a const-generic
// parameter `binds` bind (types of caller module `cm`) takes its one edge.
fn live_size(p: &loader::Package, k: &ir::CoreBody, cm: ModuleId, binds: &Vector<GBind>, nb: &mut usize) usize {
    let mut live = Vector::<bool>::new();
    live.resize_default(k.blocks.len());
    let mut stack = Vector::<u32>::new();
    stack.push(k.entry);
    let mut ns: usize = 0;
    *nb = 0;
    while stack.len() != 0 {
        let x = stack.pop().unwrap();
        if live[x as usize] {
            continue;
        }
        live.set(x as usize, true);
        *nb += 1;
        let blk = *k.blocks.at(x as usize);
        ns += blk.stmt_len as usize;
        let t = blk.term;
        if t.kind == ir::TM_SWITCH {
            let to = switch_goes(p, k, &t, cm, binds);
            if to != ir::IR_NONE {
                stack.push(to);
                continue;
            }
            for j in 0..t.sw_len {
                stack.push((k.switch_pool[(t.sw_start + j) as usize] & 0xFFFFFFFFu64) as u32);
            }
        }
        if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE && t.t0 != ir::IR_NONE {
            stack.push(t.t0);
        }
    }
    return ns;
}

// Whether `k` holds a switch on a const-generic parameter (`scrutinee`): its live size depends on the
// call's bindings (`live_size`).
fn param_switch(p: &loader::Package, k: &ir::CoreBody) bool {
    // Most bodies read no const-generic parameter: one pass over the locals answers for them.
    let mut reads = false;
    for i in 0..k.locals.len() {
        reads = reads || k.locals.at(i).storage == ir::LS_STATIC_REF && is_param(p, k.locals.at(i).item);
    }
    if !reads {
        return false;
    }
    for i in 0..k.blocks.len() {
        let t = k.blocks.at(i).term;
        if t.kind != ir::TM_SWITCH {
            continue;
        }
        if b_param_read(p, k, scrutinee(p, k, t.a, 0, 0, 0)) {
            return true;
        }
    }
    return false;
}

// Whether operand `o` of `b` reads a const-generic parameter.
const fn b_param_read(p: &loader::Package, b: &ir::CoreBody, o: u32) bool {
    let op = *b.operands.at(o as usize);
    if op.kind == ir::OP_CONST {
        return false;
    }
    let pl = *b.places.at(op.data as usize);
    let l = *b.locals.at(pl.base as usize);
    return pl.proj_len == 0 && l.storage == ir::LS_STATIC_REF && is_param(p, l.item);
}

// Whether call `t` of `b` reaches a function of a generic extend without a `self` parameter whose
// receiver instance no type of the call names: not the call's receiver type, not its one result's
// type, not its type arguments (`Type::<Args>::f()`). The emitter then takes it from the active
// bindings (`CEmit::callee_sym_i`).
fn env_receiver(p: &loader::Package, b: &ir::CoreBody, t: &ir::Terminator) bool {
    let d = t.callee;
    let a = unsafe &*p.module_ast_const(d.module);
    if a.extend_arity(d.node) <= 0 || a.at_const(d.node).kind != NodeKind::NODE_FUNCTION || t.recv != TYPE_NONE {
        return false;
    }
    let ps = a.at_const(d.node).as_data.function.params;
    if ps.len != 0 {
        let nm = a.at_const(a.at_const(unsafe a.list(ps)[0]).as_data.parameter.name).as_data.name.text;
        if p.modules.at(d.module as usize).source.as_str().slice(nm.start as usize, nm.end as usize) == "self" {
            return false;
        }
    }
    // The extend's target declaration.
    let tn = a.at_const(a.container_of(d.node)).as_data.extend_def.target_type;
    let mut tg = TyInstance {};
    let mut tdecl = a.resolution_def(tn);
    if a.targs_of(a.type_of(tn), &mut tg) {
        tdecl = DefId { module: tg.module, node: tg.decl };
    }
    if t.dests_len == 1 {
        let ba = unsafe &*p.module_ast_const(b.module);
        let mut dt = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
        for _ in 0..4 {
            let y = *ba.type_at(dt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            dt = y.as_data.elem;
        }
        let mut it = TyInstance {};
        if ba.targs_of(dt, &mut it) && it.module == tdecl.module && it.decl == tdecl.node {
            return false;
        }
    }
    if tdecl.node == NODE_NONE || t.targs_len == 0 {
        return true;
    }
    let td = (unsafe &*p.module_ast_const(tdecl.module)).at_const(tdecl.node);
    return !((td.kind == NodeKind::NODE_STRUCT || td.kind == NodeKind::NODE_ENUM) && td.as_data.aggregate.generics.len == t.targs_len);
}

// Is `d` a const or static outside any generic scope: a module's, or a non-generic extend's? Every TU
// spells it as its symbol and declares it at the use (`CEmit`'s static stubs), as the caller's own.
fn is_plain_item(p: &loader::Package, d: DefId) bool {
    if d.node == NODE_NONE || Ast::in_body(d.node) {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let c = a.container_of(d.node);
    return c == NODE_NONE || a.at_const(c).kind == NodeKind::NODE_EXTEND && a.at_const(c).as_data.extend_def.generics.len == 0;
}

// Is operand `o` of `b` a constant, or a read of a const-generic parameter (a constant once spliced)?
const fn const_or_param(p: &loader::Package, b: &ir::CoreBody, o: u32) bool {
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

// The caller's own const-generic parameter `d` binds to under `binds` (caller types of module `cm`),
// node NONE when it binds to none: a symbolic count (`N`) the caller's instance env folds.
fn param_param(p: &loader::Package, d: DefId, cm: ModuleId, binds: &Vector<GBind>) DefId {
    for i in 0..binds.len() {
        let g = binds.at(i);
        if g.pm == d.module && g.pnode == d.node {
            let y = *(unsafe &*p.module_ast_const(cm)).type_at(g.at);
            let q = DefId { module: y.module, node: y.as_data.decl };
            return pick(y.kind == TypeKind::TYPE_GENERIC && is_param(p, q), q, DefId { module: 0, node: NODE_NONE });
        }
    }
    return DefId { module: 0, node: NODE_NONE };
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
const fn alias_copy(b: &ir::CoreBody, i: usize, alias: &Vector<u32>) u32 {
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
fn vet_decl(pkg: *const loader::Package, d: DefId, ext: &mut NodeId, demand: &mut bool) u64 {
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
        // The build filter and the feature checks have read the gates and features: no code of theirs.
        let kd = a.attrs.at(k).kind;
        let benign = kd == AttrKind::ATTR_INLINE as u8 || kd == AttrKind::ATTR_ALWAYS_INLINE as u8 || kd == AttrKind::ATTR_USED as u8 || kd == AttrKind::ATTR_UNUSED as u8 || kd == AttrKind::ATTR_FMT_SKIP as u8 || kd == AttrKind::ATTR_NO_CONST as u8 || kd == AttrKind::ATTR_PLATFORM as u8 || kd == AttrKind::ATTR_ARCH as u8 || kd == AttrKind::ATTR_WHEN as u8 || kd == AttrKind::ATTR_TARGET_FEATURE as u8 || kd == AttrKind::ATTR_TAIL_RECURSE as u8;
        if !benign {
            return REJ_BASE | IJ_NOT_FN as u64;
        }
    }
    *ext = extend_of(a, d.node);
    // A GENERIC body carrying a static_assert (`Ast.assert_fns`) defers it per instantiation; that
    // guard fires only when a call site DEMANDS the instance, so a splice of it records the call in
    // the caller's `demands` (`demand`).
    *demand = (f.generics.len != 0 || *ext != NODE_NONE && a.at_const(*ext).as_data.extend_def.generics.len != 0) && a.assert_fns.contains(
        &d.node,
    );
    return 0;
}

// The bit of function `d` in a called set whose per-module first words are `base` (one entry per
// module and a last one: a module's words end where the next one's start), or -1 when its module
// holds no such bit: a module without an Ast, or a node of the body arena, which `build` never vets.
const fn called_bit(base: &Vector<usize>, d: DefId) i64 {
    let m = d.module as usize;
    if Ast::in_body(d.node) || d.node as usize >= (base[m + 1] - base[m]) * 64 {
        return -1;
    }
    return (base[m] * 64 + d.node as usize) as i64;
}

extend InlineStore {
    /// Whether callee `d` is an inline candidate.
    pub fn keeps(self: &Self, d: DefId) bool {
        return switch self.keep_ix.get(&callee_key(d)) {
            Some(v) => *v < REJ_BASE,
            None => false,
        };
    }

    pub fn new() InlineStore {
        return InlineStore {
            keep_ix: Map::<u64, u64>::new(),
            kept: Vector::<CalleeInfo>::new(),
            vec_ix: Map::<u64, u64>::new(),
            vec_bodies: Vector::<ir::CoreBody>::new(),
        };
    }

    /// The copy of kept function `d`'s body when it holds a vector and no closure (`vec_ix`), else null.
    pub fn vec_body(self: &Self, d: DefId) *const ir::CoreBody {
        return switch self.vec_ix.get(&callee_key(d)) {
            Some(v) => self.vec_bodies.at((*v) as usize),
            None => null,
        };
    }

    /// Vet every kept env-free function lowering of `keep` (the borrow checker's product, the same
    /// lowering an on-demand vet would build) and copy the accepted callees.
    pub fn build(self: &mut Self, pkg: *const loader::Package, keep: &irl::Keep) {
        // Only a body some kept body calls can be inlined: collect the call targets first, so
        // the vetting (an attribute walk and a statement scan per body) runs for those alone.
        // A bit per module node (`called_bit`): a call costs a store, not a table insert.
        let p = unsafe &*pkg;
        let mut base = Vector::<usize>::new();
        let mut words: usize = 0;
        for m in 0..p.modules.len() {
            base.push(words);
            if p.modules.at(m).has_ast {
                words += ((unsafe &*p.module_ast_const(m as ModuleId)).nodes.len() + 63) / 64;
            }
        }
        base.push(words);
        let mut called = Vector::<u64>::new();
        called.resize_default(words);
        let vec_prog = p.names_vectors();
        for i in 0..keep.kept.len() {
            let b = &keep.kept.at(i).body;
            for k in 0..b.blocks.len() {
                let t = &b.blocks.at(k).term;
                if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
                    let at = called_bit(&base, t.callee);
                    if at >= 0 {
                        called[at as usize / 64] |= 1u64 << at as u64 % 64;
                    }
                }
            }
            // A conformance's method: a call through its interface reaches it once an instance names
            // the receiver (the emitter's bound variants).
            let d = b.owner;
            let at = called_bit(&base, d);
            if at >= 0 {
                let a = unsafe &*p.module_ast_const(d.module);
                let ext = extend_of(a, d.node);
                if ext != NODE_NONE && a.at_const(ext).as_data.extend_def.interface_type != NODE_NONE {
                    called[at as usize / 64] |= 1u64 << at as u64 % 64;
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
            if vec_prog && lw.closures.len() == 0 && !self.vec_ix.contains_key(&key) && holds_vector(&lw.body, pkg) {
                self.vec_ix.insert(key, self.vec_bodies.len() as u64);
                self.vec_bodies.push(ir::CoreBody::compact_from(&lw.body));
            }
            // A body without a bit is no candidate: an absent entry reads as `vet_decl`'s rejection
            // of a module without an Ast (`callee_slot`).
            let at = called_bit(&base, d);
            if self.keep_ix.contains_key(&key) || at < 0 || (called[at as usize / 64] >> at as u64 % 64 & 1) == 0 {
                continue;
            }
            // The size gate first: it rejects most bodies at once, before the declaration checks
            // walk the module's attributes. `@always_inline` asks past it.
            let mut r: u64 = 0;
            if !lw.body.inline_size_ok && !param_switch(p, &lw.body) && !always_inline(p, d) {
                r = REJ_BASE | IJ_TOO_BIG as u64;
            } else {
                let mut ext = NODE_NONE;
                let mut demand = false;
                r = vet_decl(pkg, d, &mut ext, &mut demand);
                if r == 0 {
                    r = self.vet_body(pkg, d, ext, &lw.body, lw.closures.len(), demand, vec_prog);
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
        vec_prog: bool,
    ) u64 {
        let p = unsafe &*pkg;
        let a = unsafe &*p.module_ast_const(d.module);
        let f = a.at_const(d.node).as_data.function;
        let shape = REJ_BASE | IJ_SHAPE as u64;
        // A callee that reads a module's constant or static, or makes an inner call another function
        // than a concrete public one or a non-variadic extern one names, inlines into vector code
        // only: there each call spills the live vector registers, and kernel helpers read their
        // tables; elsewhere the C compiler's own inlining serves, without the larger C.
        let mut vec_only = false;
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
            // Inner calls splice into a FOREIGN TU: a function with a body or an interface method
            // (`is_spelled_fn`; the splice translates its type arguments, receiver and interface
            // into the caller's types, so the emitter spells and demands it there as the caller's
            // own call), a call through a function value, a non-variadic extern function (its
            // declaration is global, `is_global_extern_fn`) or a runtime atomic (a verified
            // intrinsic call, `static inline` in every TU's runtime header).
            vec_only = vec_only || tk.kind == ir::TM_CALL && tk.intr < ir::CI_ATOMIC_LOAD && (tk.targs_len != 0 || tk.callee.node == NODE_NONE || !is_concrete_pub_fn(
                pkg,
                tk.callee,
            ) && !is_global_extern_fn(pkg, tk.callee));
            if tk.kind == ir::TM_CALL && tk.intr < ir::CI_ATOMIC_LOAD && tk.callee.node != NODE_NONE && !is_spelled_fn(
                pkg,
                tk.callee,
            ) && !is_global_extern_fn(pkg, tk.callee) {
                return shape;
            }
            // An associated function of a generic extend whose call names its receiver by no type
            // names it by the instance's own bindings, which the caller's do not hold.
            if tk.kind == ir::TM_CALL && tk.callee.node != NODE_NONE && env_receiver(p, body, tk) {
                return shape;
            }
        }
        for i in 0..body.locals.len() {
            // A value of a scoped extern header's type, or its static, would bring the header, and its
            // macros, into the caller's unit (`Package::extern_header_scoped`).
            if ty_scoped(p, body.module, body.locals.at(i).ty) || body.locals.at(i).storage == ir::LS_STATIC_REF && p.extern_item_scoped(
                body.locals.at(i).item,
            ) {
                return shape;
            }
            // A const-generic parameter's value becomes a constant at the splice.
            if body.locals.at(i).storage == ir::LS_STATIC_REF && !is_param(p, body.locals.at(i).item) && !is_plain_item(
                p,
                body.locals.at(i).item,
            ) {
                return shape;
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
            if c9.kind == ir::CK_ITEM && !is_spelled_fn(pkg, c9.item) {
                return shape; // fn-value symbols follow the inner-call rule
            }
            vec_only = vec_only || c9.kind == ir::CK_ITEM && (c9.targ_len() != 0 || !is_concrete_pub_fn(pkg, c9.item));
        }
        for i in 0..body.locals.len() {
            vec_only = vec_only || body.locals.at(i).storage == ir::LS_STATIC_REF && !is_param(
                p,
                body.locals.at(i).item,
            );
        }
        let always = always_native(pkg, d);
        vec_only = vec_only && !always;
        // A program without vectors has no caller for it.
        if vec_only && !vec_prog {
            return shape;
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
        self.kept.push(
            CalleeInfo {
                body: kb,
                gp: gp,
                fg: fgl.len,
                demand: demand,
                big: !body.inline_size_ok && a.attr_of(d.node, AttrKind::ATTR_ALWAYS_INLINE) == null,
                vec_only: vec_only,
                always: always,
            },
        );
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
    let mut pairs = replace(&mut cx.sc_pairs, Vector::<u64>::new());
    let mut tys = replace(&mut cx.sc_tys, Vector::<u64>::new());
    let mut wire = replace(&mut cx.sc_wire, Vector::<u8>::new());
    let mut probe = replace(&mut cx.sc_probe, Vector::<TypeId>::new());
    let mut shape = replace(&mut cx.sc_shape, Vector::<u64>::new());
    let mut alias = Vector::<u32>::new();
    // A block a constant switch skips (a callee's arm another binding takes) inlines nothing.
    let mut live = replace(&mut cx.sc_live, Vector::<bool>::new());
    let mut stack = replace(&mut cx.sc_stack, Vector::<u32>::new());
    live.clear();
    live.resize_default(lw.body.blocks.len());
    let _ = reach(&lw.body, lw.body.entry, &mut live, &mut stack);
    let vec_caller = holds_vector(&lw.body, pkg);
    // Built at the first splice (`exposed`).
    let mut expo = replace(&mut cx.sc_expo, Vector::<u32>::new());
    let mut oref = replace(&mut cx.sc_oref, Vector::<u32>::new());
    let mut orph = replace(&mut cx.sc_orph, Vector::<u32>::new());
    orph.truncate(0);
    let mut expo_on = false;
    // Built at the first splice (`once_aggregate`, `agg_field`).
    let mut wr = replace(&mut cx.sc_writes, Writes { cnt: Vector::<u32>::new(), rv: Vector::<u32>::new() });
    let mut wr_on = false;
    let mut pf = replace(&mut cx.sc_pf, Vector::<u8>::new());
    // A closure's captures live in its environment, which the closure value owns.
    let cl = unsafe (&*(*pkg).module_ast_const(lw.body.owner.module)).closure_fact(lw.body.owner.node) != null;
    let budget = MAX_ADDED_STMTS * pick(vec_caller, VEC_SCALE, 1usize);
    let mut reserved = false;
    let mut bi: usize = 0;
    while bi < lw.body.blocks.len() {
        let t = lw.body.blocks.at(bi).term;
        bi += 1;
        if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE || !live[bi - 1] {
            continue;
        }
        st.considered += 1;
        if cx.only_fixed && !cx.fixed_result(pkg, t.callee) && !always_native(pkg, t.callee) {
            st.reasons[IJ_SHAPE as usize] = st.reasons[IJ_SHAPE as usize] + 1;
            continue;
        }
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
        // A callee that needs features its caller lacks runs only after the caller's run-time check:
        // its body never splices into the caller (whose C has no `target` attribute for them).
        let ca = unsafe &*(*pkg).module_ast_const(t.callee.module);
        if ca.at_const(t.callee.node).kind == NodeKind::NODE_FUNCTION && ca.at_const(t.callee.node).as_data.function.needs_features() && !cf::contains(
            unsafe (*pkg).fn_set(lw.body.owner.module, lw.body.owner.node),
            unsafe (*pkg).fn_features(t.callee.module, t.callee.node),
        ) {
            st.reasons[IJ_NOT_FN as usize] = st.reasons[IJ_NOT_FN as usize] + 1;
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
        if ki0.vec_only && !vec_caller {
            st.reasons[IJ_SHAPE as usize] = st.reasons[IJ_SHAPE as usize] + 1;
            continue;
        }
        if !ki0.big && !ki0.always && added + k0.statements.len() + k0.args as usize + k0.returns as usize > budget {
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
        // A function of a generic extend called through its receiver type (`V::<3>::len()`, a bound
        // call made direct) binds the extend's parameters from that type, `Terminator.recv`.
        let ka = unsafe &*(&*pkg).module_ast_const(km);
        if t.recv != TYPE_NONE && ka.extend_arity(t.callee.node) > 0 {
            let xt = ka.at_const(ka.container_of(t.callee.node)).as_data.extend_def.target_type;
            unify(pkg, km, ka.type_of(xt), cm, t.recv, &mut binds, 0);
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
        // A callee past the size gate inlines when the arms its bindings take fit it.
        let mut kstmts = k.statements.len();
        if ki.big {
            let mut nb: usize = 0;
            kstmts = live_size(unsafe &*pkg, k, cm, &binds, &mut nb);
            let sc = size_scale(k, pkg);
            if kstmts > MAX_CALLEE_STMTS * sc || nb > MAX_CALLEE_BLOCKS * sc {
                st.reasons[IJ_TOO_BIG as usize] = st.reasons[IJ_TOO_BIG as usize] + 1;
                continue;
            }
            if added + kstmts + k.args as usize + k.returns as usize > budget {
                st.reasons[IJ_BUDGET as usize] = st.reasons[IJ_BUDGET as usize] + 1;
                continue;
            }
        }
        // ---- translate every callee type up front; any failure rejects the site ----------------
        // The translation depends only on (callee slot, caller module, binds): repeated call
        // shapes reuse the finished table instead of re-walking the callee type table.
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
                let e = (*v) as usize;
                let ks = cx.xm_ko[e] as usize;
                if same_words(cx.xm_keys[ks..pool_end(&cx.xm_ko, cx.xm_keys.len(), e)], &shape) {
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
            body_types(k, &mut probe);
            tymap.clear();
            pairs.truncate(0);
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
                pairs.push(kk << 32 | nt as u64);
            }
            if tok9 && !collide {
                cix = cx.xm_ko.len() as i64;
                cx.xm_ko.push(cx.xm_keys.len() as u32);
                for i in 0..shape.len() {
                    cx.xm_keys.push(shape[i]);
                }
                cx.xm_to.push(cx.xm_tys.len() as u32);
                ty_table(&pairs, &mut cx.xm_tys);
                cx.xm_pfo.push(0);
                cx.xm_wf.push(0);
                cx.xm_ix.insert(h9, cix as u64);
            } else if tok9 {
                tys.truncate(0);
                ty_table(&pairs, &mut tys);
            }
        }
        if !tok9 {
            st.reasons[IJ_GENERIC as usize] = st.reasons[IJ_GENERIC as usize] + 1;
            continue;
        }
        let tyr = if cix >= 0 {
            cx.xm_tys[cx.xm_to[cix as usize] as usize..pool_end(&cx.xm_to, cx.xm_tys.len(), cix as usize)];
        } else {
            tys[0..tys.len()];
        };
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
                wire.push(W_EXACT);
                continue;
            }
            let ca = unsafe &*(&*pkg).module_ast_const(cm);
            let mut mode: u8 = 255;
            if pt != TYPE_NONE && sty != TYPE_NONE {
                // &mut T into a &T parameter, *mut T into *const T, a reference into a pointer
                // parameter, any pointer into a `*void` one, a function into a function-pointer
                // parameter (the checker matched the signatures): the same C value, no adjustment
                // needed
                let py0 = *ca.type_at(pt);
                let sy0 = *ca.type_at(sty);
                let ptr_like = py0.kind == sy0.kind && (py0.kind == TypeKind::TYPE_REFERENCE || py0.kind == TypeKind::TYPE_POINTER) || py0.kind == TypeKind::TYPE_POINTER && sy0.kind == TypeKind::TYPE_REFERENCE;
                let to_void = py0.kind == TypeKind::TYPE_POINTER && ca.type_at(py0.as_data.elem).kind == TypeKind::TYPE_BUILTIN && ca.type_at(
                    py0.as_data.elem,
                ).as_data.builtin == BuiltinType::BT_VOID;
                if ptr_like && (py0.as_data.elem == sy0.as_data.elem || to_void) {
                    mode = W_PTR;
                } else if py0.kind == TypeKind::TYPE_FUNCTION && py0.fn_sig() && sy0.kind == TypeKind::TYPE_FUNCTION && !sy0.fn_sig() {
                    mode = W_FN;
                }
            }
            if mode == 255 && pt != TYPE_NONE && op.kind == ir::OP_COPY {
                let py = *ca.type_at(pt);
                if py.kind == TypeKind::TYPE_REFERENCE && py.as_data.elem == sty {
                    mode = W_AUTOREF; // the callee receives a reference to the caller's place
                }
                if mode == 255 && sty != TYPE_NONE {
                    let oy = *ca.type_at(sty);
                    if oy.kind == TypeKind::TYPE_REFERENCE && oy.as_data.elem == pt {
                        mode = W_DEREF; // a reference argument into a by-value parameter
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
            if wok && k.locals.at(i).storage == ir::LS_STATIC_REF && is_param(unsafe &*pkg, it) && !param_value(
                unsafe &*pkg,
                it,
                cm,
                &binds,
                &mut v,
            ) && param_param(unsafe &*pkg, it, cm, &binds).node == NODE_NONE {
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
        let prelude = lw.body.blocks.len() + k.blocks.len();
        let cma = unsafe &*(*pkg).module_ast_const(cm);
        let b_old = lw.body.blocks.len();
        // The facts depend on the callee and its translation only: one computation per call shape.
        let mut wfree = false;
        if cix >= 0 && cx.xm_wf[cix as usize] != 0 {
            pf.truncate(0);
            let o = cx.xm_pfo[cix as usize] as usize;
            for q in 0..k.args as usize {
                pf.push(cx.xm_pfs[o + q]);
            }
            wfree = cx.xm_wf[cix as usize] == 2;
        } else {
            wfree = param_facts(unsafe &*pkg, k, cma, tyr, &mut pf);
            if cix >= 0 {
                cx.xm_pfo.set(cix as usize, cx.xm_pfs.len() as u32);
                for q in 0..pf.len() {
                    cx.xm_pfs.push(pf[q]);
                }
                cx.xm_wf.set(cix as usize, pick(wfree, 2u8, 1u8));
            }
        }
        // The exposure counts (`exposed`), built at the first decision that reads them; from then on
        // the call leaves them and what the splice adds joins them.
        if !expo_on && !wfree && reads_exposure(&lw.body, cma, &t, &wire, &pf) {
            scan_all(unsafe &*pkg, &lw.body, cma, &mut expo);
            expo_on = true;
        }
        if expo_on {
            expose_term(unsafe &*pkg, &lw.body, cma, &t, &mut expo, false);
        }
        if !reserved {
            // A kept caller's pools hold no slack (`compact_from`): grow each once for the run's
            // splices instead of at each one.
            reserved = true;
            expect_growth(cx, &lw.body, bi - 1, &live, owner_key, budget).reserve_in(&mut lw.body);
        }
        if !wr_on {
            writes_all(&lw.body, &mut wr);
            wr_on = true;
        }
        splice(
            lw,
            ki,
            &t,
            bi - 1,
            tyr,
            &binds,
            &alias,
            &wire,
            &mut blk_origin,
            &mut origins,
            &expo,
            &wr,
            &mut pf,
            wfree,
            cl,
        );
        if expo_on && multi {
            // The splice moved member reads of the call's temporary onto the return slots.
            scan_all(unsafe &*pkg, &lw.body, cma, &mut expo);
        } else if expo_on {
            expo.resize_default(lw.body.locals.len());
            scan_from(unsafe &*pkg, &lw.body, cma, b_old, &mut expo);
        }
        // The call's results now come from the spliced returns.
        if multi {
            writes_all(&lw.body, &mut wr);
        } else {
            writes_term(&lw.body, &t, &mut wr, false);
            writes_from(&lw.body, b_old, &mut wr);
        }
        // An argument read in place leaves the call's operand unread (`unread`).
        if !ki.demand {
            for j in 0..t.args_len {
                let o = lw.body.oper_pool[(t.args_start + j) as usize];
                if pf[j as usize] >> SUB_SHIFT != SUB_NONE && lw.body.operands.at(o as usize).kind != ir::OP_CONST {
                    orph.push(o);
                }
            }
        }
        live.resize_default(lw.body.blocks.len());
        let _ = reach(&lw.body, prelude as u32, &mut live, &mut stack);
        added += kstmts + k.args as usize + k.returns as usize;
        st.inlined += 1;
    }
    cx.sc_blk_origin = blk_origin;
    cx.sc_origins = origins;
    cx.sc_binds = binds;
    cx.sc_tymap = tymap;
    cx.sc_pairs = pairs;
    cx.sc_tys = tys;
    cx.sc_wire = wire;
    cx.sc_probe = probe;
    cx.sc_shape = shape;
    cx.sc_live = live;
    cx.sc_stack = stack;
    if orph.len() != 0 {
        unread(&mut lw.body, &orph, &mut oref);
    }
    cx.sc_expo = expo;
    cx.sc_writes = wr;
    cx.sc_oref = oref;
    cx.sc_orph = orph;
    cx.sc_pf = pf;
}

/// What the splices of a run are expected to add to caller `b`: from block `from` on, each live
/// call of a kept callee other than `owner` adds that callee, its prelude and its join, and so does
/// each kept callee it calls other than itself and `owner`, until the statement `budget` is spent.
fn expect_growth(cx: &InlineCtx, b: &ir::CoreBody, from: usize, live: &Vector<bool>, owner: u64, budget: usize) Growth {
    let mut g = Growth {};
    let kept = unsafe &(&*cx.store).kept;
    for i in from..b.blocks.len() {
        let t = &b.blocks.at(i).term;
        if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE || !live[i] || callee_key(t.callee) == owner {
            continue;
        }
        let slot = cx.callee_slot(t.callee);
        if slot >= REJ_BASE {
            continue;
        }
        let k = &kept.at(slot as usize).body;
        let key = callee_key(t.callee);
        g.add(k);
        for j in 0..k.blocks.len() {
            let kt = &k.blocks.at(j).term;
            if kt.kind == ir::TM_CALL && kt.callee.node != NODE_NONE {
                let kk = callee_key(kt.callee);
                let ks = cx.callee_slot(kt.callee);
                if kk != key && kk != owner && ks < REJ_BASE {
                    g.add(&kept.at(ks as usize).body);
                }
            }
        }
        if g.statements >= budget {
            break;
        }
    }
    return g;
}

/// Every type `k` names, into `out`: the ones a splice or `ground_body` translates.
fn body_types(k: &ir::CoreBody, out: &mut Vector<TypeId>) {
    out.truncate(0);
    out.reserve(
        k.locals.len() + k.places.len() + k.projections.len() + k.operands.len() + k.constants.len() + k.targ_pool.len() + 2 * (k.blocks.len() + k.rvalues.len()),
    );
    for i in 0..k.locals.len() {
        out.push(k.locals.at(i).ty);
    }
    for i in 0..k.places.len() {
        out.push(k.places.at(i).ty);
    }
    for i in 0..k.projections.len() {
        out.push(k.projections.at(i).ty);
    }
    for i in 0..k.operands.len() {
        out.push(k.operands.at(i).ty);
    }
    for i in 0..k.constants.len() {
        out.push(k.constants.at(i).ty);
    }
    for i in 0..k.targ_pool.len() {
        out.push(k.targ_pool[i]);
    }
    for i in 0..k.blocks.len() {
        out.push(k.blocks.at(i).term.iface);
        out.push(k.blocks.at(i).term.recv);
    }
    for i in 0..k.rvalues.len() {
        let rv = k.rvalues.at(i);
        out.push(rv.target);
        if takes_type(rv) {
            out.push(rv.b);
        }
    }
}

// Whether `rv.b` is a type (`body_types`).
const fn takes_type(rv: &ir::Rvalue) bool {
    return rv.kind == ir::RV_DYN || rv.kind == ir::RV_INTRINSIC && ir::type_payload(rv.c);
}

/// Body `lw.body` with every generic parameter `binds` names substituted (`xty`): one instance's
/// concrete body, so a call the instance resolves to a concrete method splices with matching types
/// (`run`). False, the body unchanged, when a type does not substitute.
pub fn ground_body(lw: &mut irl::Lowerer, binds: &Vector<GBind>) bool {
    let pkg = lw.pkg;
    let m = lw.body.module;
    let mut tys = Vector::<TypeId>::new();
    body_types(&lw.body, &mut tys);
    let mut map = Map::<u64, u64>::new();
    let mut pairs = Vector::<u64>::new();
    for i in 0..tys.len() {
        let t = tys[i];
        if t == TYPE_NONE || map.contains_key(&(t as u64)) {
            continue;
        }
        let g = xty(pkg, m, t, m, binds, 0);
        if g == TYPE_NONE {
            return false;
        }
        map.insert(t, g);
        pairs.push(t as u64 << 32 | g as u64);
    }
    let mut tab = Vector::<u64>::new();
    ty_table(&pairs, &mut tab);
    let tr = tab[0..tab.len()];
    let b = &mut lw.body;
    for i in 0..b.locals.len() {
        b.locals.index_mut(i).ty = mty(tr, b.locals.at(i).ty);
    }
    for i in 0..b.places.len() {
        b.places.index_mut(i).ty = mty(tr, b.places.at(i).ty);
    }
    for i in 0..b.projections.len() {
        b.projections.index_mut(i).ty = mty(tr, b.projections.at(i).ty);
    }
    for i in 0..b.operands.len() {
        b.operands.index_mut(i).ty = mty(tr, b.operands.at(i).ty);
    }
    for i in 0..b.constants.len() {
        b.constants.index_mut(i).ty = mty(tr, b.constants.at(i).ty);
    }
    for i in 0..b.targ_pool.len() {
        b.targ_pool.set(i, mty(tr, b.targ_pool[i]));
    }
    for i in 0..b.blocks.len() {
        let tm = &mut b.blocks.index_mut(i).term;
        tm.iface = mty(tr, tm.iface);
        tm.recv = mty(tr, tm.recv);
    }
    for i in 0..b.rvalues.len() {
        let rv = b.rvalues.index_mut(i);
        rv.target = mty(tr, rv.target);
        if takes_type(rv) {
            rv.b = mty(tr, rv.b);
        }
    }
    // A const-generic parameter read is its value, and a switch on one takes its one edge, as in a
    // splice.
    for i in 0..b.operands.len() {
        let mut v: i64 = 0;
        if b.operands.at(i).kind != ir::OP_CONST && int_operand(unsafe &*pkg, b, i as u32, m, binds, &mut v) {
            b.constants.push(
                ir::Constant {
                    kind: ir::CK_INT,
                    ty: b.operands.at(i).ty,
                    val: v,
                    raw: tok::Span::empty(),
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            let o = b.operands.index_mut(i);
            o.kind = ir::OP_CONST;
            o.data = b.constants.len() as u32 - 1;
        }
    }
    for i in 0..b.blocks.len() {
        let tm = b.blocks.at(i).term;
        if tm.kind == ir::TM_SWITCH && b.operands.at(tm.a as usize).kind != ir::OP_CONST {
            let o = scrutinee(unsafe &*pkg, b, tm.a, 0, 0, 0);
            if switch_on_const(unsafe &*pkg, b, o) {
                b.blocks.index_mut(i).term.a = o;
            }
        }
    }
    return true;
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

/// Where entry `e` of a pool its entries fill in order ends: where entry `e + 1` starts (`starts`),
/// or at the pool's length `n` for the last.
const fn pool_end(starts: &Vector<u32>, n: usize, e: usize) usize {
    if e + 1 < starts.len() {
        return starts[e + 1] as usize;
    }
    return n;
}

/// Whether `a` holds the words of `b`.
const fn same_words(a: []u64, b: &Vector<u64>) bool {
    if a.len() != b.len() {
        return false;
    }
    for i in 0..a.len() {
        if a[i] != b[i] {
            return false;
        }
    }
    return true;
}

/// The slot of type `t` in a translation table of `n` slots (a power of two).
const fn ty_slot(t: TypeId, n: usize) usize {
    return ((t as u64).wrapping_mul(0x9E3779B97F4A7C15u64) >> 32) as usize & n - 1;
}

/// Append the translation table of `pairs` (`callee type << 32 | caller type` words, each callee type
/// once) to `out`: open addressing with linear probing over a power-of-two slot count at least twice
/// the pairs, 0 a free slot (`TYPE_NONE` is 0 and never translates). One table per call shape fills a
/// shared pool, so a new shape costs no allocation of its own.
fn ty_table(pairs: &Vector<u64>, out: &mut Vector<u64>) {
    let mut n: usize = 2;
    while n < 2 * pairs.len() {
        n *= 2;
    }
    let s = out.len();
    out.resize_default(s + n);
    for i in 0..pairs.len() {
        // At most half the slots are taken: the probe meets a free one.
        let mut j = ty_slot((pairs[i] >> 32) as TypeId, n);
        for _ in 0..n {
            if out[s + j] == 0 {
                break;
            }
            j = j + 1 & n - 1;
        }
        out.set(s + j, pairs[i]);
    }
}

/// Type `t` of a callee in the caller, through translation table `tymap` (`ty_table`); TYPE_NONE
/// stays TYPE_NONE, and so does a type the table lacks.
// Whether a drop of a callee place of type `t` drops a value the substitution `tymap` makes a reference
// or a pointer, where the callee's own type is neither (types of the package table, read through
// module `m`).
fn drop_of_borrow(p: &loader::Package, m: ModuleId, t: TypeId, tymap: []u64) bool {
    let a = unsafe &*p.module_ast_const(m);
    let st = mty(tymap, t);
    if st == t || t == TYPE_NONE {
        return false;
    }
    let k = a.type_at(t).kind;
    let sk = a.type_at(st).kind;
    return k != TypeKind::TYPE_REFERENCE && k != TypeKind::TYPE_POINTER && (sk == TypeKind::TYPE_REFERENCE || sk == TypeKind::TYPE_POINTER);
}

const fn mty(tymap: []u64, t: TypeId) TypeId {
    if t == TYPE_NONE {
        return t;
    }
    let n = tymap.len();
    let mut j = ty_slot(t, n);
    for _ in 0..n {
        let w = tymap[j];
        if w == 0 {
            break;
        }
        if (w >> 32) as TypeId == t {
            return w as TypeId;
        }
        j = j + 1 & n - 1;
    }
    return TYPE_NONE;
}

// ---- argument substitution ------------------------------------------------------------------
// A substituted parameter reads its argument where it was read, so the argument must keep its value
// (or, for an autoref receiver, its address) from the call to the callee's last read. Only the
// callee's own code runs in between: it writes its fresh locals, and caller storage only through a
// pointer, a call, a drop or a substituted receiver. So a place keeps its value when the callee
// writes no memory (`param_facts`), or when it lies in a local's own storage (`resident`) that no
// pointer can reach (`exposed`).

/// Whether a value of type `t` (a type of `a`) passes as a pointer or a reference: a call never
/// takes its address.
fn ref_like(a: &Ast, t: TypeId) bool {
    if t == TYPE_NONE {
        return false;
    }
    let k = a.type_at(t).kind;
    return k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_POINTER;
}

/// Whether type `t` (of `a`) is an array or may bind to one: C passes an array by its address.
fn maybe_array(a: &Ast, t: TypeId) bool {
    if t == TYPE_NONE {
        return true;
    }
    let k = a.type_at(t).kind;
    return k == TypeKind::TYPE_ARRAY || k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_ASSOC || k == TypeKind::TYPE_ERROR || k == TypeKind::TYPE_CONST || k == TypeKind::TYPE_CONST_EXPR || k == TypeKind::TYPE_FIELD_PROJECTION;
}

/// Whether place `p` of `b` (types of `a`) is a part of its base local's own storage at a fixed
/// offset: no dereference, no operand index, and only arrays indexed (a slice's elements are
/// memory).
fn resident(b: &ir::CoreBody, a: &Ast, p: ir::PlaceId) bool {
    let pl = *b.places.at(p as usize);
    let mut pre = b.locals.at(pl.base as usize).ty;
    for i in 0..pl.proj_len {
        let pj = *b.projections.at((pl.proj_start + i) as usize);
        if pj.kind == ir::PJ_DEREF || pj.kind == ir::PJ_INDEX_OP {
            return false;
        }
        if pj.kind == ir::PJ_INDEX_CONST && (pre == TYPE_NONE || a.type_at(pre).kind != TypeKind::TYPE_ARRAY) {
            return false;
        }
        pre = pj.ty;
    }
    return true;
}

/// Count (`up`) or uncount the operations of `b` that may address the storage of place `p`'s base.
fn expose(b: &ir::CoreBody, p: ir::PlaceId, cnt: &mut Vector<u32>, up: bool) {
    if b.place_has_deref(p) {
        return;
    }
    let x = b.places.at(p as usize).base as usize;
    if up {
        cnt.set(x, cnt[x] + 1);
    } else {
        assert(cnt[x] != 0);
        cnt.set(x, cnt[x] - 1);
    }
}

fn expose_op(b: &ir::CoreBody, o: ir::OperandId, cnt: &mut Vector<u32>, up: bool) {
    if o != ir::IR_NONE && b.operands.at(o as usize).kind != ir::OP_CONST {
        expose(b, b.operands.at(o as usize).data, cnt, up);
    }
}

// An intrinsic that writes or addresses its operands' storage.
const fn effect_intrinsic(c: u8) bool {
    return c == ir::IN_ASM || c == ir::IN_VA_START || c == ir::IN_VA_ARG || c == ir::IN_VA_END;
}

/// Count the operations of statement `s` that may address a local's storage: a borrow, a slice
/// view, an array's slice view, a conversion method's receiver, a `dyn` or closure operand, an
/// effect intrinsic's operand, and an aggregate comparison (dispatched by address).
fn expose_stmt(b: &ir::CoreBody, a: &Ast, s: &ir::Statement, cnt: &mut Vector<u32>, up: bool) {
    if s.kind != ir::ST_ASSIGN {
        return;
    }
    let rv = *b.rvalues.at(s.rvalue as usize);
    if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE {
        expose(b, rv.a, cnt, up);
    } else if rv.kind == ir::RV_USE && rv.b != 0 || rv.kind == ir::RV_CAST && rv.b == ir::CAST_COERCE_FROM || rv.kind == ir::RV_DYN {
        expose_op(b, rv.a, cnt, up);
    } else if rv.kind == ir::RV_CLOSURE || rv.kind == ir::RV_INTRINSIC && effect_intrinsic(rv.c) {
        for i in 0..rv.b {
            expose_op(b, b.oper_pool[(rv.a + i) as usize], cnt, up);
        }
    } else if rv.kind == ir::RV_BINARY && rv.target == Ast::builtin(BuiltinType::BT_BOOL) {
        expose_cmp(b, a, rv.a, cnt, up);
        expose_cmp(b, a, rv.b, cnt, up);
    }
}

// An aggregate operand of a comparison: compared through its address.
fn expose_cmp(b: &ir::CoreBody, a: &Ast, o: ir::OperandId, cnt: &mut Vector<u32>, up: bool) {
    let op = *b.operands.at(o as usize);
    if op.kind != ir::OP_CONST {
        let t = eff_pty(b, op.data);
        if t == TYPE_NONE || a.type_at(t).kind != TypeKind::TYPE_BUILTIN && !ref_like(a, t) {
            expose(b, op.data, cnt, up);
        }
    }
}

/// Count the operations of terminator `t` that may address a local's storage: a drop, a called
/// value (a closure takes its environment by address), a receiver that is no pointer (an implicit
/// `&`), and an array argument.
fn expose_term(p: &loader::Package, b: &ir::CoreBody, a: &Ast, t: &ir::Terminator, cnt: &mut Vector<u32>, up: bool) {
    if t.kind == ir::TM_DROP {
        expose(b, t.a, cnt, up);
    } else if t.kind == ir::TM_CALL {
        if t.callee.node == NODE_NONE {
            expose_op(b, t.a, cnt, up);
        }
        for i in 0..t.args_len {
            let op = *b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize);
            if op.kind != ir::OP_CONST {
                let ty = eff_pty(b, op.data);
                if i == 0 && !ref_like(a, ty) && recv_ref(p, t) || maybe_array(a, ty) {
                    expose(b, op.data, cnt, up);
                }
            }
        }
    }
}

/// Count the blocks of `b` from `b0`: per local, the operations that may address its storage
/// (`expose_stmt`, `expose_term`).
fn scan_from(p: &loader::Package, b: &ir::CoreBody, a: &Ast, b0: usize, expo: &mut Vector<u32>) {
    for bi in b0..b.blocks.len() {
        let blk = *b.blocks.at(bi);
        for si in 0..blk.stmt_len {
            expose_stmt(b, a, b.statements.at((blk.stmt_start + si) as usize), expo, true);
        }
        expose_term(p, b, a, &blk.term, expo, true);
    }
}

/// `scan_from` over the whole body.
fn scan_all(p: &loader::Package, b: &ir::CoreBody, a: &Ast, expo: &mut Vector<u32>) {
    expo.truncate(0);
    expo.resize_default(b.locals.len());
    scan_from(p, b, a, 0, expo);
}

/// Whether a substitution decision for call `t` of `b` (types of `a`) reads the exposure counts
/// (`splice`, for a callee that writes memory): an argument read in place at a fixed offset of a
/// local, or an autoref receiver elsewhere, of a parameter that admits it (`pf`).
fn reads_exposure(b: &ir::CoreBody, a: &Ast, t: &ir::Terminator, wire: &Vector<u8>, pf: &Vector<u8>) bool {
    for j in 0..t.args_len {
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        let f = pf[j as usize];
        let w = wire[j as usize];
        if op.kind == ir::OP_CONST {
            continue;
        }
        if w == W_AUTOREF && (f & (PF_BARE | PF_WRITE)) == 0 && !resident(b, a, op.data) {
            return true;
        }
        if w != W_AUTOREF && w != W_FN && w != W_DEREF && (f & (PF_WRITE | PF_ADDR)) == 0 && resident(b, a, op.data) {
            return true;
        }
    }
    return false;
}

// Mark (`mark[o] = 2`) operand `o` when it is a candidate (`mark[o] == 1`): something references it.
fn ref_mark(o: ir::OperandId, mark: &mut Vector<u32>) {
    if o != ir::IR_NONE && mark[o as usize] == 1 {
        mark.set(o as usize, 2);
    }
}

/// The call operands `orph` of arguments read in place that nothing in `b` references any more
/// become a unit constant, so no pass that scans the operand pool counts them as reads. One that a
/// statement, a terminator or a projection still references (an operand the lowering shared) stays.
fn unread(b: &mut ir::CoreBody, orph: &Vector<u32>, mark: &mut Vector<u32>) {
    mark.truncate(0);
    mark.resize_default(b.operands.len());
    for i in 0..orph.len() {
        mark.set(orph[i] as usize, 1);
    }
    for bi in 0..b.blocks.len() {
        let blk = *b.blocks.at(bi);
        for si in 0..blk.stmt_len {
            let s = *b.statements.at((blk.stmt_start + si) as usize);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_DYN {
                ref_mark(rv.a, mark);
            } else if rv.kind == ir::RV_BINARY || rv.kind == ir::RV_REPEAT {
                ref_mark(rv.a, mark);
                ref_mark(rv.b, mark);
            } else if rv.kind == ir::RV_SLICE {
                ref_mark(rv.b, mark);
                ref_mark(rv.item.node, mark);
            } else if ir::has_op_range(&rv) {
                for i in 0..rv.b {
                    ref_mark(b.oper_pool[(rv.a + i) as usize], mark);
                }
            }
        }
        let t = blk.term;
        if t.kind == ir::TM_SWITCH || t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL && t.callee.node == NODE_NONE {
            ref_mark(t.a, mark);
        }
        if t.kind == ir::TM_ASSERT || t.kind == ir::TM_CALL {
            for i in 0..t.args_len {
                ref_mark(b.oper_pool[(t.args_start + i) as usize], mark);
            }
        }
    }
    for q in 0..b.projections.len() {
        let pj = *b.projections.at(q);
        if pj.kind == ir::PJ_INDEX_OP {
            ref_mark(pj.data, mark);
        }
    }
    // The body's own unit constant, else a new one.
    let mut unit = ir::IR_NONE;
    for c in 0..b.constants.len() {
        if b.constants.at(c).kind == ir::CK_UNIT {
            unit = c as u32;
            break;
        }
    }
    for i in 0..orph.len() {
        let o = orph[i] as usize;
        if mark[o] != 1 {
            continue;
        }
        mark.set(o, 0);
        if unit == ir::IR_NONE {
            b.constants.push(
                ir::Constant {
                    kind: ir::CK_UNIT,
                    ty: Ast::builtin(BuiltinType::BT_VOID),
                    val: 0,
                    raw: tok::Span::empty(),
                    item: DefId { module: 0, node: NODE_NONE },
                },
            );
            unit = b.constants.len() as u32 - 1;
        }
        let od = b.operands.index_mut(o);
        od.kind = ir::OP_CONST;
        od.data = unit;
    }
}

/// Whether call `t`'s first parameter may be a reference, so the C call takes a receiver that is
/// no pointer by its address (`CEmit::emit_call_arg`). A function value takes its arguments as
/// they are.
fn recv_ref(p: &loader::Package, t: &ir::Terminator) bool {
    if t.callee.node == NODE_NONE {
        return false;
    }
    if Ast::in_body(t.callee.node) {
        return true;
    }
    let fa = unsafe &*p.module_ast_const(t.callee.module);
    let fnn = fa.at_const(t.callee.node);
    if fnn.kind != NodeKind::NODE_FUNCTION {
        return true;
    }
    let ps = fnn.as_data.function.params;
    if ps.len == 0 {
        return false;
    }
    let pn = fa.at_const(unsafe fa.list(ps)[0]);
    if pn.kind != NodeKind::NODE_PARAMETER || pn.as_data.parameter.ty == NODE_NONE {
        return true;
    }
    let pty = fa.type_of(pn.as_data.parameter.ty);
    if pty == TYPE_NONE {
        return true;
    }
    let k = fa.type_at(pty).kind;
    return k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_ASSOC || k == TypeKind::TYPE_ERROR;
}

/// Whether item `d` (an item local's) holds one value for the whole program: a constant that is no
/// static and no extern, a const-generic parameter, or a function.
fn item_fixed(p: &loader::Package, d: DefId) bool {
    if d.node == NODE_NONE || Ast::in_body(d.node) || !p.modules.at(d.module as usize).has_ast {
        return false;
    }
    let n = (unsafe &*p.module_ast_const(d.module)).at_const(d.node);
    if n.kind == NodeKind::NODE_FUNCTION || n.kind == NodeKind::NODE_GENERIC_PARAM {
        return true;
    }
    return n.kind == NodeKind::NODE_CONST && !n.as_data.const_def.is_static_mut && !n.as_data.const_def.is_extern;
}

/// Whether local `x` of `b` can change while code that holds no pointer it was given runs: an
/// operation addresses it (`cnt`), or it is an item that can change (`item_fixed`), an array
/// argument (a pointer in C) or a closure's capture (`cl`: the environment is the closure value's).
fn exposed(p: &loader::Package, b: &ir::CoreBody, a: &Ast, x: u32, cnt: &Vector<u32>, cl: bool) bool {
    let d = b.locals.at(x as usize);
    if d.storage == ir::LS_STATIC_REF {
        return !item_fixed(p, d.item);
    }
    if d.storage == ir::LS_ARG && (cl || maybe_array(a, d.ty)) {
        return true;
    }
    return cnt[x as usize] != 0;
}

/// Whether call `t` of `b` hands the storage of local `x` to its callee: an autoref receiver
/// (`wire`) whose place lies in `x`.
const fn receives(b: &ir::CoreBody, t: &ir::Terminator, wire: &Vector<u8>, x: u32) bool {
    for j in 0..t.args_len {
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        if wire[j as usize] == W_AUTOREF && op.kind != ir::OP_CONST && b.places.at(op.data as usize).base == x {
            return true;
        }
    }
    return false;
}

/// Whether the address of place `p` of `b` stays the same while the callee runs: the callee
/// writes no memory (`wfree`), or `p` lies at a fixed offset in a local (`resident`), or in the
/// referent of a local pointer that nothing else can change (`exposed`).
fn addr_kept(pk: &loader::Package, b: &ir::CoreBody, a: &Ast, p: ir::PlaceId, cnt: &Vector<u32>, cl: bool, wfree: bool) bool {
    if wfree || resident(b, a, p) {
        return true;
    }
    let pl = *b.places.at(p as usize);
    if pl.proj_len == 0 || b.projections.at(pl.proj_start as usize).kind != ir::PJ_DEREF {
        return false;
    }
    let mut pre = b.projections.at(pl.proj_start as usize).ty;
    for i in 1..pl.proj_len {
        let pj = *b.projections.at((pl.proj_start + i) as usize);
        if pj.kind == ir::PJ_DEREF || pj.kind == ir::PJ_INDEX_OP {
            return false;
        }
        if pj.kind == ir::PJ_INDEX_CONST && (pre == TYPE_NONE || a.type_at(pre).kind != TypeKind::TYPE_ARRAY) {
            return false;
        }
        pre = pj.ty;
    }
    return !exposed(pk, b, a, pl.base, cnt, cl);
}

// The intrinsics that write no memory.
const fn pure_intrinsic(c: u8) bool {
    return ir::type_payload(c) || c == ir::IN_ZEROED || c == ir::IN_DYN_TID || c == ir::IN_DYN_DATA || c == ir::IN_LIKELY || c == ir::IN_UNLIKELY || c == ir::IN_GROUP_FITS || ir::is_check(
        c,
    );
}

// Add `bits` to the facts of the parameter place `p` of `k` names, if any.
fn pmark(k: &ir::CoreBody, p: ir::PlaceId, bits: u8, pf: &mut Vector<u8>) {
    let x = k.places.at(p as usize).base;
    if x >= k.returns && x < k.returns + k.args {
        let j = (x - k.returns) as usize;
        pf.set(j, pf[j] | bits);
    }
}

fn pmark_op(k: &ir::CoreBody, o: ir::OperandId, bits: u8, pf: &mut Vector<u8>) {
    if o != ir::IR_NONE && k.operands.at(o as usize).kind != ir::OP_CONST {
        let p = k.operands.at(o as usize).data;
        if !k.place_has_deref(p) {
            pmark(k, p, bits, pf);
        }
    }
}

// Mark a use of place `p` of `k` (an operand's read when `operand`): a projected place or another
// use is PF_PLACE, a path that does not start with a dereference PF_BARE; its index operands are reads.
fn pf_use(k: &ir::CoreBody, p: ir::PlaceId, operand: bool, pf: &mut Vector<u8>) {
    let pl = *k.places.at(p as usize);
    let lead = pl.proj_len != 0 && k.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF;
    pmark(k, p, pick(pl.proj_len != 0 || !operand, PF_PLACE, 0u8) | pick(lead, 0u8, PF_BARE), pf);
    for q in 0..pl.proj_len {
        let pj = *k.projections.at((pl.proj_start + q) as usize);
        if pj.kind == ir::PJ_INDEX_OP {
            pf_use_op(k, pj.data, pf);
        }
    }
}

fn pf_use_op(k: &ir::CoreBody, o: ir::OperandId, pf: &mut Vector<u8>) {
    if o != ir::IR_NONE && k.operands.at(o as usize).kind != ir::OP_CONST {
        pf_use(k, k.operands.at(o as usize).data, true, pf);
    }
}

// Mark the uses of rvalue `rv`'s places and operands (`pf_use`).
fn pf_uses(k: &ir::CoreBody, rv: &ir::Rvalue, pf: &mut Vector<u8>) {
    if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_DYN {
        pf_use_op(k, rv.a, pf);
    } else if rv.kind == ir::RV_BINARY || rv.kind == ir::RV_REPEAT {
        pf_use_op(k, rv.a, pf);
        pf_use_op(k, rv.b, pf);
    } else if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
        pf_use(k, rv.a, false, pf);
    } else if rv.kind == ir::RV_SLICE {
        pf_use(k, rv.a, false, pf);
        pf_use_op(k, rv.b, pf);
        pf_use_op(k, rv.item.node, pf);
    } else if ir::has_op_range(rv) {
        for i in 0..rv.b {
            pf_use_op(k, k.oper_pool[(rv.a + i) as usize], pf);
        }
    }
}

/// The `PF_*` facts of each parameter of callee `k` (into `pf`; types translated by `tymap` into
/// those of caller module `a`), and whether `k` writes no memory a caller place can name: no call,
/// no drop, no store through a dereference, an index or into a static, no effect operation.
fn param_facts(p: &loader::Package, k: &ir::CoreBody, a: &Ast, tymap: []u64, pf: &mut Vector<u8>) bool {
    pf.truncate(0);
    pf.resize_default(k.args as usize);
    let mut wfree = true;
    for bi in 0..k.blocks.len() {
        let blk = *k.blocks.at(bi);
        for si in 0..blk.stmt_len {
            let s = *k.statements.at((blk.stmt_start + si) as usize);
            // A storage marker of a substituted parameter marks a local nothing reads.
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let own = !k.place_has_deref(s.place);
            pf_use(k, s.place, false, pf);
            pmark(k, s.place, pick(own, PF_WRITE, 0u8), pf);
            let dp = *k.places.at(s.place as usize);
            if !own || k.locals.at(dp.base as usize).storage == ir::LS_STATIC_REF {
                wfree = false;
            }
            for q in 0..dp.proj_len {
                let pk = k.projections.at((dp.proj_start + q) as usize).kind;
                if pk == ir::PJ_INDEX_OP || pk == ir::PJ_INDEX_CONST {
                    wfree = false; // a slice's element is memory
                }
            }
            let rv = *k.rvalues.at(s.rvalue as usize);
            pf_uses(k, &rv, pf);
            if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_SLICE {
                pmark(k, rv.a, pick(!k.place_has_deref(rv.a), PF_ADDR, 0u8), pf);
            } else if rv.kind == ir::RV_USE && rv.b != 0 || rv.kind == ir::RV_CAST && rv.b == ir::CAST_COERCE_FROM {
                pmark_op(k, rv.a, PF_ADDR, pf);
            } else if rv.kind == ir::RV_DYN {
                pmark_op(k, rv.a, PF_ADDR, pf);
                wfree = false;
            } else if rv.kind == ir::RV_CLOSURE || rv.kind == ir::RV_INTRINSIC && effect_intrinsic(rv.c) {
                for i in 0..rv.b {
                    pmark_op(k, k.oper_pool[(rv.a + i) as usize], PF_ADDR, pf);
                }
                wfree = false;
            } else if rv.kind == ir::RV_INTRINSIC && !pure_intrinsic(rv.c) || rv.kind == ir::RV_SIMD && ir::simd_writes(
                rv.c,
            ) {
                wfree = false;
            }
        }
        let t = blk.term;
        if t.kind == ir::TM_SWITCH {
            pf_use_op(k, t.a, pf);
        } else if t.kind == ir::TM_ASSERT {
            pf_use_op(k, t.a, pf);
            for i in 0..t.args_len {
                pf_use_op(k, k.oper_pool[(t.args_start + i) as usize], pf);
            }
        }
        if t.kind == ir::TM_DROP {
            pf_use(k, t.a, false, pf);
            pmark(k, t.a, pick(!k.place_has_deref(t.a), PF_WRITE, 0u8), pf);
            if t.args_len == 1 && t.args_start >= k.returns && t.args_start < k.returns + k.args {
                let j = (t.args_start - k.returns) as usize;
                pf.set(j, pf[j] | PF_WRITE);
            }
            wfree = false;
        } else if t.kind == ir::TM_CALL {
            for d in 0..t.dests_len {
                let dp = k.dest_pool[(t.dests_start + d) as usize];
                pf_use(k, dp, false, pf);
                pmark(k, dp, pick(!k.place_has_deref(dp), PF_WRITE, 0u8), pf);
            }
            if t.callee.node == NODE_NONE {
                pf_use_op(k, t.a, pf);
                pmark_op(k, t.a, PF_ADDR, pf);
            }
            for i in 0..t.args_len {
                let o = k.oper_pool[(t.args_start + i) as usize];
                pf_use_op(k, o, pf);
                if k.operands.at(o as usize).kind != ir::OP_CONST {
                    let ty = mty(tymap, eff_pty(k, k.operands.at(o as usize).data));
                    if i == 0 && !ref_like(a, ty) && recv_ref(p, &t) || maybe_array(a, ty) {
                        pmark_op(k, o, PF_ADDR, pf);
                    }
                }
            }
            wfree = false;
        } else if t.kind != ir::TM_GOTO && t.kind != ir::TM_SWITCH && t.kind != ir::TM_RETURN && t.kind != ir::TM_ASSERT && t.kind != ir::TM_UNREACHABLE {
            wfree = false;
        }
    }
    return wfree;
}

/// Append the callee body to the caller with every index rebased, rewrite the call block to jump
/// into it, and join every callee return back to the call's continuation.
// Per caller local: how many operations may write it (an assignment to it or into it, a borrow of
// it, a call result into it), and its one whole assignment's rvalue + 1 (0: none, WR_MULTI: a
// second one, or an assignment into it). Kept in step with the splices (`writes_from`).
pub struct Writes {
    pub cnt: Vector<u32>,
    pub rv: Vector<u32>,
}

const WR_MULTI: u32 = 0xFFFFFFFF;

// Add the writes of statement `st`.
fn writes_stmt(b: &ir::CoreBody, st: &ir::Statement, w: &mut Writes) {
    if st.kind != ir::ST_ASSIGN {
        return;
    }
    let pl = *b.places.at(st.place as usize);
    let x = pl.base as usize;
    w.cnt.set(x, w.cnt[x] + 1);
    w.rv.set(
        x,
        if pl.proj_len == 0 && w.rv[x] == 0 {
            st.rvalue + 1;
        } else {
            WR_MULTI;
        },
    );
    let rv = *b.rvalues.at(st.rvalue as usize);
    if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
        let y = b.places.at(rv.a as usize).base as usize;
        w.cnt.set(y, w.cnt[y] + 1);
    }
}

// Add (`up`) or remove the call results of terminator `t`.
fn writes_term(b: &ir::CoreBody, t: &ir::Terminator, w: &mut Writes, up: bool) {
    if t.kind != ir::TM_CALL {
        return;
    }
    for d in 0..t.dests_len {
        let x = b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize).base as usize;
        if up {
            w.cnt.set(x, w.cnt[x] + 1);
        } else {
            w.cnt.set(x, w.cnt[x] - 1);
        }
    }
}

// Add the writes of the blocks of `b` from `b0`.
fn writes_from(b: &ir::CoreBody, b0: usize, w: &mut Writes) {
    w.cnt.resize_default(b.locals.len());
    w.rv.resize_default(b.locals.len());
    for bi in b0..b.blocks.len() {
        let blk = *b.blocks.at(bi);
        for si in 0..blk.stmt_len {
            writes_stmt(b, b.statements.at((blk.stmt_start + si) as usize), w);
        }
        writes_term(b, &blk.term, w, true);
    }
}

// `writes_from` over the whole body.
fn writes_all(b: &ir::CoreBody, w: &mut Writes) {
    w.cnt.truncate(0);
    w.rv.truncate(0);
    writes_from(b, 0, w);
}

// The struct aggregate rvalue that alone defines place `p`, a whole caller temporary; IR_NONE when it
// is no such place or another operation writes it.
fn once_aggregate(b: &ir::CoreBody, w: &Writes, p: ir::PlaceId) u32 {
    let pl = *b.places.at(p as usize);
    if pl.proj_len != 0 || b.locals.at(pl.base as usize).storage != ir::LS_TEMP {
        return ir::IR_NONE;
    }
    let x = pl.base as usize;
    if w.cnt[x] != 1 || w.rv[x] == 0 || w.rv[x] == WR_MULTI {
        return ir::IR_NONE;
    }
    let r = w.rv[x] - 1;
    let rv = *b.rvalues.at(r as usize);
    if rv.kind != ir::RV_AGGREGATE || rv.c != ir::AGG_STRUCT {
        return ir::IR_NONE;
    }
    return r;
}

// The operand of struct aggregate rvalue `r` for the field projection `pj` names, when it is a
// constant, or a whole local of a builtin type that keeps its value (a temporary one operation
// defines, a parameter nothing writes), else IR_NONE.
fn agg_field(p: &loader::Package, b: &ir::CoreBody, w: &Writes, r: u32, pj: &ir::Projection) u32 {
    let rv = *b.rvalues.at(r as usize);
    let a = unsafe &*p.module_ast_const(b.module);
    let mut i = pj.data;
    if i == ir::IR_NONE {
        // The struct's declaration: the aggregate's item, else its type's.
        let mut d = rv.item;
        if d.node == NODE_NONE && rv.target != TYPE_NONE {
            let y = *a.type_at(rv.target);
            if y.kind == TypeKind::TYPE_STRUCT {
                d = DefId { module: y.module, node: y.as_data.decl };
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                d = DefId { module: a.instance(y.as_data.inst).module, node: a.instance(y.as_data.inst).decl };
            }
        }
        if d.node != NODE_NONE {
            let da = unsafe &*p.module_ast_const(d.module);
            let ms = da.at_const(d.node).as_data.aggregate.members;
            for j in 0..ms.len {
                if unsafe da.list(ms)[j as usize] == pj.sub {
                    i = j;
                }
            }
        }
    }
    if i >= rv.b {
        return ir::IR_NONE;
    }
    let oi = b.oper_pool[(rv.a + i) as usize];
    if oi == ir::IR_NONE {
        return ir::IR_NONE;
    }
    let o = *b.operands.at(oi as usize);
    if o.kind == ir::OP_CONST {
        return oi;
    }
    let pl = *b.places.at(o.data as usize);
    let sg = b.locals.at(pl.base as usize).storage;
    if pl.proj_len != 0 || sg != ir::LS_TEMP && sg != ir::LS_ARG || o.ty == TYPE_NONE || a.type_at(o.ty).kind != TypeKind::TYPE_BUILTIN {
        return ir::IR_NONE;
    }
    // A temporary's one definition, or a parameter nothing writes (a borrow of it counts: a store
    // through it could write).
    if w.cnt[pl.base as usize] != pick(sg == ir::LS_ARG, 0u32, 1u32) {
        return ir::IR_NONE;
    }
    return oi;
}

fn splice(
    lw: &mut irl::Lowerer,
    ki: &CalleeInfo,
    t: &ir::Terminator,
    call_blk: usize,
    tymap: []u64,
    binds: &Vector<GBind>,
    alias: &Vector<u32>,
    wire: &Vector<u8>,
    blk_origin: &mut Vector<u32>,
    origins: &mut Vector<Origin>,
    expo: &Vector<u32>,
    wr: &Writes,
    pf: &mut Vector<u8>,
    wfree: bool,
    cl: bool,
) {
    let k = &ki.body;
    let pkg9 = lw.pkg;
    let b = &mut lw.body;
    let sp = t.span;
    // How each parameter reads its argument, decided over the caller as the call left it.
    {
        let ca = unsafe &*(&*pkg9).module_ast_const(b.module);
        for j in 0..k.args {
            let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
            let f = pf[j as usize];
            let w = wire[j as usize];
            let mut sub = SUB_NONE;
            if op.kind == ir::OP_CONST {
                let ck = b.constants.at(op.data as usize).kind;
                if w == W_EXACT && (ck == ir::CK_INT || ck == ir::CK_FLOAT || ck == ir::CK_BOOL || ck == ir::CK_STR) && (f & (PF_WRITE | PF_ADDR | PF_PLACE)) == 0 {
                    sub = SUB_CONST;
                }
            } else if w == W_AUTOREF {
                if (f & (PF_BARE | PF_WRITE)) == 0 && !maybe_array(ca, eff_pty(b, op.data)) && addr_kept(
                    unsafe &*pkg9,
                    b,
                    ca,
                    op.data,
                    expo,
                    cl,
                    wfree,
                ) {
                    sub = SUB_REF;
                }
            } else if w != W_FN && (f & (PF_WRITE | PF_ADDR)) == 0 {
                let x = b.places.at(op.data as usize).base;
                if wfree || w != W_DEREF && resident(b, ca, op.data) && !exposed(unsafe &*pkg9, b, ca, x, expo, cl) && !receives(
                    b,
                    t,
                    wire,
                    x,
                ) {
                    sub = SUB_PLACE;
                }
            }
            pf.set(j as usize, f | sub << SUB_SHIFT);
        }
    }
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
        let mut v: i64 = 0;
        if d.storage == ir::LS_STATIC_REF && !is_param(unsafe &*pkg9, d.item) {
            // a const or static (`is_plain_item`): the caller spells it by its item
        } else if d.storage == ir::LS_STATIC_REF && !param_value(unsafe &*pkg9, d.item, b.module, binds, &mut v) {
            // a const-generic parameter bound to the caller's own (`param_param`): read as that one
            d.item = param_param(unsafe &*pkg9, d.item, b.module, binds);
        } else if d.storage == ir::LS_RET || d.storage == ir::LS_STATIC_REF {
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
        let x = pl.base;
        pl.base += l0;
        pl.proj_start += j0;
        pl.ty = mty(tymap, pl.ty);
        let sub = if x >= k.returns && x < k.returns + k.args {
            pf[(x - k.returns) as usize] >> SUB_SHIFT;
        } else {
            SUB_NONE;
        };
        if sub == SUB_PLACE || sub == SUB_REF {
            // The argument's path, then the parameter's: past its dereference for a receiver.
            let j = x - k.returns;
            let ap = *b.places.at(b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize).data as usize);
            let skip = pick(sub == SUB_REF, 1u32, 0u32);
            if ap.proj_len == 0 && !(sub == SUB_PLACE && wire[j as usize] == W_DEREF) {
                // A whole local: the parameter's own path, already copied (a receiver place no use
                // names has no dereference to drop).
                pl.base = ap.base;
                if pl.proj_len != 0 {
                    pl.proj_start += skip;
                    pl.proj_len -= skip;
                }
                b.places.push(pl);
                continue;
            }
            let start = b.projections.len() as u32;
            for q in 0..ap.proj_len {
                let pj = *b.projections.at((ap.proj_start + q) as usize);
                b.projections.push(pj);
            }
            if sub == SUB_PLACE && wire[j as usize] == W_DEREF {
                b.projections.push(
                    ir::Projection { kind: ir::PJ_DEREF, data: 0, sub: 0, ty: b.locals.at(pl.base as usize).ty },
                );
            }
            for q in skip..pl.proj_len {
                let pj = *b.projections.at((pl.proj_start + q) as usize);
                b.projections.push(pj);
            }
            pl.base = ap.base;
            pl.proj_start = start;
            pl.proj_len = b.projections.len() as u32 - start;
        }
        b.places.push(pl);
    }
    for i in 0..k.constants.len() {
        let mut c = *k.constants.at(i);
        c.ty = mty(tymap, c.ty);
        if c.kind == ir::CK_ITEM && c.targ_len() != 0 {
            c.val = ir::targ_val(c.targ_start() + tg0, c.targ_len());
        }
        if c.kind == ir::CK_BYTES {
            // The bytes move to the caller's pool.
            let at = b.bytes.len() as i64;
            for q in 0..c.val & 0xFFFFFFFF {
                b.bytes.push(k.bytes[((c.val >> 32) + q) as usize]);
            }
            c.val = at << 32 | c.val & 0xFFFFFFFF;
        }
        if c.kind == ir::CK_STR || c.kind == ir::CK_FLOAT || c.kind == ir::CK_INT {
            // the spelling spans a FOREIGN module's source; item marks it (established CK_STR
            // convention, extended to CK_FLOAT and CK_INT in the emitter, which spells an integer
            // literal from its span)
            if c.item.node == NODE_NONE {
                c.item = DefId { module: km, node: k.owner.node };
            }
        }
        b.constants.push(c);
    }
    // Per parameter read in place: the struct aggregate its argument (a caller temporary) was built
    // by once, or IR_NONE.
    let mut agg = Vector::<u32>::new();
    for j in 0..k.args {
        let mut r = ir::IR_NONE;
        let op = *b.operands.at(b.oper_pool[(t.args_start + j) as usize] as usize);
        if pf[j as usize] >> SUB_SHIFT == SUB_PLACE && op.kind != ir::OP_CONST {
            r = once_aggregate(b, wr, op.data);
        }
        agg.push(r);
    }
    for i in 0..k.operands.len() {
        let mut o = *k.operands.at(i);
        o.ty = mty(tymap, o.ty);
        let mut v: i64 = 0;
        let px = if o.kind == ir::OP_CONST {
            ir::IR_NONE;
        } else {
            k.places.at(o.data as usize).base;
        };
        let mut fo = ir::IR_NONE;
        if px >= k.returns && px < k.returns + k.args && agg[(px - k.returns) as usize] != ir::IR_NONE && k.places.at(
            o.data as usize,
        ).proj_len == 1 {
            let pj = *k.projections.at(k.places.at(o.data as usize).proj_start as usize);
            if pj.kind == ir::PJ_FIELD {
                fo = agg_field(unsafe &*pkg9, b, wr, agg[(px - k.returns) as usize], &pj);
            }
        }
        if px >= k.returns && px < k.returns + k.args && pf[(px - k.returns) as usize] >> SUB_SHIFT == SUB_CONST {
            // A read of a parameter whose argument is a constant: the constant.
            o.kind = ir::OP_CONST;
            o.data = b.operands.at(b.oper_pool[(t.args_start + px - k.returns) as usize] as usize).data;
        } else if fo != ir::IR_NONE {
            // A field of an argument built once from a constant or a scalar temporary: that value.
            let f = *b.operands.at(fo as usize);
            o.kind = if f.kind == ir::OP_CONST {
                ir::OP_CONST;
            } else {
                ir::OP_COPY;
            };
            o.data = f.data;
        } else if (o.kind == ir::OP_COPY || o.kind == ir::OP_MOVE) && k.places.at(o.data as usize).proj_len == 0 && param_value(
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
            if ir::type_payload(rv.c) {
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
            } else if tm.kind == ir::TM_DROP && drop_of_borrow(
                unsafe &*pkg9,
                b.module,
                k.places.at(tm.a as usize).ty,
                tymap,
            ) {
                // The scheduled drop of a value of a parameter the call binds to a reference or a
                // pointer owns nothing; as a drop of a reference-typed place it would read as an
                // explicit free of the referent (`p.free()`).
                tm = ir::goto_term(tm.t0 + b0, sp);
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
    // prelude: the parameters that read no argument in place take the call's argument operands
    // (original read order), each with the call's own implicit adjustment (autoref/deref) reproduced
    // in IR, then jump to the entry
    {
        let ps = b.statements.len() as u32;
        for j in 0..k.args {
            if pf[j as usize] >> SUB_SHIFT != SUB_NONE {
                continue;
            }
            let al = l0 + k.returns + j;
            let opid = b.oper_pool[(t.args_start + j) as usize];
            let mode = wire[j as usize];
            if mode == W_EXACT || mode == W_PTR || mode == W_FN {
                b.assign_local_use(al, opid, sp);
            } else if mode == W_AUTOREF {
                // the callee's reference parameter takes the caller's place directly
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
            ir::BasicBlock {
                stmt_start: ps,
                stmt_len: b.statements.len() as u32 - ps,
                term: ir::goto_term(b0 + k.entry, sp),
                sealed: true,
            },
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
    // A switch on a const-generic parameter, through the temp a `switch` lowers it into, now reads a
    // constant: the C layout takes its one edge (`CFlow`).
    for i in b0..b0 + nkb {
        let tm = b.blocks.at(i as usize).term;
        if tm.kind != ir::TM_SWITCH || b.operands.at(tm.a as usize).kind == ir::OP_CONST {
            continue;
        }
        let o = scrutinee(unsafe &*pkg9, b, tm.a, s0 as usize, l0, b0 as usize);
        if switch_on_const(unsafe &*pkg9, b, o) {
            b.blocks.index_mut(i as usize).term.a = o;
        }
    }
    // So does a switch on the tag of an enum value whose variant the splice sees: one a variant
    // aggregate of the callee built, or of the caller as the argument (`known_variant`). The other
    // arms would read payload bytes the value never set.
    for i in b0..b0 + nkb {
        let tm = lw.body.blocks.at(i as usize).term;
        if tm.kind != ir::TM_SWITCH {
            continue;
        }
        let op = *lw.body.operands.at(tm.a as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            continue;
        }
        let rv = temp_source(&lw.body, op.data, s0 as usize, l0, b0 as usize);
        if rv.kind != ir::RV_DISCRIMINANT {
            continue;
        }
        let vd = known_variant(&lw.body, rv.a, s0 as usize, l0, b0 as usize, call_blk);
        if vd.node == NODE_NONE {
            continue;
        }
        let mut ord: i64 = 0;
        let en = unsafe (&*pkg9).variant_enum(vd, &mut ord);
        let tag = lw.tag_of_decl(vd.module, en, ord);
        lw.body.constants.push(
            ir::Constant { kind: ir::CK_INT, ty: op.ty, val: tag, raw: sp, item: DefId { module: 0, node: NODE_NONE } },
        );
        // The operand reads that tag wherever it is read: it becomes the constant, and nothing reads
        // the discriminant's temp any more.
        let c = lw.body.constants.len() as u32 - 1;
        let o = lw.body.operands.index_mut(tm.a as usize);
        o.kind = ir::OP_CONST;
        o.data = c;
    }
}

// The variant enum place `pl0` of `b` holds when copies of whole locals lead to a variant aggregate:
// each copy the one write of a spliced local (`temp_source` over statements `s0..`, locals `l0..`,
// blocks `bl0..`), or the caller local's value as call block `cb` leaves it (`block_source`). Its
// node is NODE_NONE otherwise.
fn known_variant(b: &ir::CoreBody, pl0: u32, s0: usize, l0: u32, bl0: usize, cb: usize) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    let mut pl = pl0;
    // Each hop crosses one copy: a parameter's scrutinee copies its argument through two.
    for _ in 0..4 {
        if b.places.at(pl as usize).proj_len != 0 {
            return none;
        }
        let rv = if b.places.at(pl as usize).base >= l0 {
            temp_source(b, pl, s0, l0, bl0);
        } else {
            block_source(b, pl, cb);
        };
        if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_VARIANT {
            return rv.item;
        }
        if rv.kind != ir::RV_USE {
            return none;
        }
        let op = *b.operands.at(rv.a as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return none;
        }
        pl = op.data;
    }
    return none;
}

// The rvalue whole-local place `pl` of `b` holds at the end of block `cb`: its last assignment in the
// block, when no later statement there can write it (through a pointer, or after taking its
// address); else an rvalue of kind RV_CLOSURE. A call ends a block, so none runs in between.
fn block_source(b: &ir::CoreBody, pl: u32, cb: usize) ir::Rvalue {
    let none = ir::rv(ir::RV_CLOSURE, 0, 0, 0, TYPE_NONE);
    let x = b.places.at(pl as usize).base;
    let blk = *b.blocks.at(cb);
    let mut i = blk.stmt_len;
    while i > 0 {
        i -= 1;
        let st = *b.statements.at((blk.stmt_start + i) as usize);
        if st.kind != ir::ST_ASSIGN {
            continue;
        }
        let rv = *b.rvalues.at(st.rvalue as usize);
        if b.places.at(st.place as usize).base == x {
            return pick(b.places.at(st.place as usize).proj_len == 0, rv, none);
        }
        let taken = (rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR) && b.places.at(rv.a as usize).base == x;
        if taken || b.place_has_deref(st.place) || fx::stmt_effect(b, &st).kind != fx::EF_WRITE {
            return none;
        }
    }
    return none;
}

extend Growth {
    /// Count one splice of callee `k`: its pools, and the prelude and join it brings.
    const fn add(self: &mut Self, k: &ir::CoreBody) {
        let io = (k.args + k.returns) as usize;
        self.locals += k.locals.len();
        self.blocks += k.blocks.len() + 2;
        self.statements += k.statements.len() + io;
        self.places += k.places.len() + io;
        self.projections += k.projections.len();
        self.operands += k.operands.len() + k.returns as usize;
        self.rvalues += k.rvalues.len() + io;
        self.constants += k.constants.len();
        self.oper_pool += k.oper_pool.len();
        self.dest_pool += k.dest_pool.len();
        self.switch_pool += k.switch_pool.len();
        self.targ_pool += k.targ_pool.len();
    }

    /// Room for the growth in every pool of `b`, plus a quarter for what the estimate leaves out (deeper
    /// splices, argument paths read in place): on the self-build fewer allocations and bytes than
    /// none or a half.
    fn reserve_in(self: &Self, b: &mut ir::CoreBody) {
        b.locals.reserve_exact(self.locals + self.locals / 4);
        b.blocks.reserve_exact(self.blocks + self.blocks / 4);
        b.statements.reserve_exact(self.statements + self.statements / 4);
        b.places.reserve_exact(self.places + self.places / 4);
        b.projections.reserve_exact(self.projections + self.projections / 4);
        b.operands.reserve_exact(self.operands + self.operands / 4);
        b.rvalues.reserve_exact(self.rvalues + self.rvalues / 4);
        b.constants.reserve_exact(self.constants + self.constants / 4);
        b.oper_pool.reserve_exact(self.oper_pool + self.oper_pool / 4);
        b.dest_pool.reserve_exact(self.dest_pool + self.dest_pool / 4);
        b.switch_pool.reserve_exact(self.switch_pool + self.switch_pool / 4);
        b.targ_pool.reserve_exact(self.targ_pool + self.targ_pool / 4);
    }
}
