// The target layout service: one pure implementation of size, alignment, field
// offsets, and enum shape for every stage (constant evaluation today, C planning later). Layout is a
// function of the type, the declaration attributes, and the TARGET data record -- never of host
// `sizeof`. Results for concrete env-free types cache per (module, type); an active-query mark turns
// a recursive by-value cycle into a clean not-layoutable answer instead of a runaway.
import ast::ast as *;
import module::loader as loader;
import ir::interp as iri;
import target::table as tgt;

/// Immutable target data. Every supported target currently shares the flat C data model except for
/// pointer width; new axes (endianness, aggregate rules) join here, not at call sites.
pub(package) struct Target {
    pub(package) ptr: u64, // pointer size == alignment
}

/// The target record for a package's instruction set (a `target::table::ISAS` index; -1, unknown,
/// lays out as 64-bit).
pub(package) const fn target_for(arch: i32) Target {
    return Target { ptr: tgt::isa(arch).ptr_bytes };
}

pub(package) struct Layout {
    pub(package) ok: bool,
    pub(package) size: u64,
    pub(package) align: u64,
    /// A failure because a generic parameter had no binding in the env: the query was asked
    /// under an incomplete substitution, as opposed to a type no env can lay out.
    pub(package) unbound: bool,
    /// A failure because the size exceeds the target's `isize::MAX`: no object can be that large.
    pub(package) big: bool,
}

/// One substitution frame for generic-parameter layout: parameter decls of `pmod` bound to argument
/// types of `argm`. A lookup that misses this frame continues at `parent`; a bound argument is read
/// under `penv`, the env it was written in (the emitter's substitution stack hides a binding's own
/// group from its payload, so the two chains can differ).
pub(package) struct LayoutEnv {
    pub(package) parent: *const LayoutEnv,
    pub(package) penv: *const LayoutEnv,
    pub(package) pmod: ModuleId,
    pub(package) params: *const NodeId,
    pub(package) argm: ModuleId,
    pub(package) args: [TypeId; 8],
    pub(package) n: u8,
}

struct LayoutAcc {
    pub(package) size: u64,
    pub(package) align: u64,
    pub(package) packed: bool,
    pub(package) is_union: bool,
    pub(package) unbound: bool, // set by acc_field on a failing field (see Layout.unbound)
    pub(package) big: bool, // set by acc_field on a field too large, or a sum past u64 (see Layout.big)
}

/// A payload-carrying enum's C shape: `{ tag; union payload; }`, with a one-byte tag when
/// `Ast::enum_tag_is_byte` holds and a 4-byte C enum tag otherwise. A niche enum (`niche`) is
/// `{ union payload; }`: no tag, the payload at offset 0.
pub(package) struct EnumLayout {
    pub(package) unbound: bool, // see Layout.unbound
    pub(package) ok: bool,
    pub(package) payload_off: u64, // tag sits at 0
    pub(package) size: u64,
    pub(package) align: u64,
    pub(package) niche: bool,
}

// The niche of a payload enum of `Ast::niche_shape`: its `some` variant's payload keeps the
// discriminant, and a null first pointer word of the payload is `none`. Every stage that lays out,
// reads or writes an enum (this service, the C emitter, the LIR lowering) decides it the same way.
/// No niche: the enum keeps its tag.
pub(package) const NK_NONE: u8 = 0;
/// The payload is a reference: never null.
pub(package) const NK_REF: u8 = 1;
/// The payload is a std `Box` of a value that is not `dyn`: its pointer is null only when it owns
/// nothing (a `zeroed` seed or a box freed in place), and such a value reads as `none`.
pub(package) const NK_BOX: u8 = 2;

/// The niche kind of a payload of concrete type `t` of `a` (`boxd`: the prelude `Box`). For
/// NK_BOX the caller checks, under its own substitution, that the box's value is not `dyn`.
pub(package) const fn niche_kind(a: &Ast, boxd: loader::LookupHit, t: TypeId) u8 {
    let y = *a.type_at(t);
    if y.kind == TypeKind::TYPE_REFERENCE {
        return NK_REF;
    }
    if y.kind != TypeKind::TYPE_INSTANCE || boxd.node == NODE_NONE {
        return NK_NONE;
    }
    let it = *a.instance(y.as_data.inst);
    if it.module != boxd.mid || it.decl != boxd.node || it.n == 0 {
        return NK_NONE;
    }
    return NK_BOX;
}

// Recursion guard. A finite type stays far below it: instance arguments nest at most 256 levels
// (the instance graph and the emitter refuse deeper ones) and a declaration holds at most 64 nested
// aggregates by value (the checker's BYVAL_MAX_DEPTH), each level costing two steps here. Only a
// type the checker already reported as infinite (a generic holding itself with a growing
// argument) reaches it; the walk then fails instead of exhausting the stack.
const MAX_DEPTH: i32 = 1024;

/// `v` rounded up to a multiple of `a` (`a` <= 1: `v`).
pub(package) const fn round_up(v: u64, a: u64) u64 {
    if a <= 1 {
        return v;
    }
    return (v + a - 1) / a * a;
}

/// The frame that binds instance `it`'s arguments (types of module `argm`) to the generic
/// parameters of its declaration in `da`, below `parent`.
pub(package) fn inst_frame(da: &Ast, it: &TyInstance, argm: ModuleId, parent: *const LayoutEnv) LayoutEnv {
    let gens = da.ext(it.decl).aggregate.generics;
    let mut frame = LayoutEnv { parent: parent, penv: parent, pmod: it.module, params: da.list(gens), argm: argm, n: 0 };
    let mut i: u32 = 0;
    while i < gens.len && i as u8 < it.n && frame.n < 8 {
        unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
        frame.n = frame.n + 1;
        i = i + 1;
    }
    return frame;
}

pub(package) struct Svc {
    pub(package) pkg: *const loader::Package,
    cache: Map<u64, Layout>, // (module << 32 | type) -> layout (env-free concrete only)
    active: Vector<u64>, // aggregate instantiations under query (declaration and arguments): cycle mark
    steps: Vector<ConstStep>, // `steps_hold` scratch
    pending: u32, // answers that read a constant-expression attribute not evaluated yet: never cached
    /// The compile-time evaluation this service answers for (null: none). A member of an item the
    /// reader does not see checked (`Interp::visible_node`) is pending.
    pub(package) ev: *const iri::Interp,
    boxd: loader::LookupHit, // the prelude `Box`, looked up on the first niche query (`box_on`)
    box_on: bool,
}

extend Svc {
    pub(package) fn new(pkg: *const loader::Package) Svc {
        if unsafe TS_ON {
            ts_add(TS_LAY_SVC, 1);
        }
        return Svc {
            pkg: pkg,
            cache: Map::<u64, Layout>::new(),
            active: Vector::<u64>::new(),
            steps: Vector::<ConstStep>::new(),
            boxd: loader::LookupHit { node: NODE_NONE, mid: 0 },
        };
    }

    // `t` of `m` with its generic parameters followed through `env` (as `layout_raw` binds them):
    // the type and the env its own parameters resolve under.
    fn ground(
        self: &Self,
        m: ModuleId,
        t: TypeId,
        env: *const LayoutEnv,
        depth: i32,
        rm: &mut ModuleId,
        rt: &mut TypeId,
        renv: &mut *const LayoutEnv,
    ) bool {
        let y = *self.a(m).type_at(t);
        if y.kind != TypeKind::TYPE_GENERIC {
            *rm = m;
            *rt = t;
            *renv = env;
            return true;
        }
        if depth > MAX_DEPTH {
            return false;
        }
        let mut e = env;
        while e != null {
            for i in 0..unsafe (*e).n {
                if unsafe (*e).pmod == y.module && unsafe (*e).params[i as usize] == y.as_data.decl {
                    if self.ground(
                        unsafe (*e).argm,
                        unsafe (*e).args[i as usize],
                        unsafe (*e).penv,
                        depth + 1,
                        rm,
                        rt,
                        renv,
                    ) {
                        return true;
                    }
                }
            }
            e = unsafe (*e).parent;
        }
        return false;
    }

    // Whether a payload of type `t` of `m` under `env` keeps a niche (`niche_kind`).
    fn niche_on(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) bool {
        let mut rm: ModuleId = 0;
        let mut rt = TYPE_NONE;
        let mut renv: *const LayoutEnv = null;
        if t == TYPE_NONE || !self.ground(m, t, env, depth, &mut rm, &mut rt, &mut renv) {
            return false;
        }
        if !self.box_on {
            self.boxd = self.p().prelude_lookup("Box", true);
            self.box_on = true;
        }
        let k = niche_kind(self.a(rm), self.boxd, rt);
        if k != NK_BOX {
            return k == NK_REF;
        }
        let it = *self.a(rm).instance(self.a(rm).type_at(rt).as_data.inst);
        let mut vm: ModuleId = 0;
        let mut vt = TYPE_NONE;
        let mut venv: *const LayoutEnv = null;
        return self.ground(rm, it.args[0], renv, depth + 1, &mut vm, &mut vt, &mut venv) && self.a(vm).type_at(vt).kind != TypeKind::TYPE_DYN;
    }

    /// Drop every cached answer: the keys name type ids of one publication, so a checkpoint that
    /// renumbers them (and restarts every module's provisional ids) invalidates the whole cache.
    pub(package) fn reset(self: &mut Self) {
        self.cache.clear();
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    const fn tgt(self: &Self) Target {
        return target_for(self.p().arch);
    }

    const fn has_ast(self: &Self, m: ModuleId) bool {
        return m as usize < self.p().modules.len() && self.p().modules.at(m as usize).has_ast;
    }

    const fn a(self: &Self, m: ModuleId) &Ast {
        return unsafe &*self.p().module_ast_const(m);
    }

    fn attr(self: &Self, m: ModuleId, decl: NodeId, kind: AttrKind) *const Attr {
        return self.a(m).attr_of(decl, kind);
    }

    // The layout of aggregate or payload member `mid` (a field, or a tuple member's type node), from
    // its recorded type (`Ast::member_ty`): a field's own record is what the declaration's check
    // writes, while its annotation's type is recorded only when something resolves the annotation.
    fn member_layout(self: &mut Self, m: ModuleId, mid: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        let ast = self.a(m);
        if !ast.valid(mid) {
            return Layout { ok: false };
        }
        if self.ev != null && !unsafe (&*self.ev).visible_node(m, mid) {
            self.pending += 1;
            return Layout { ok: false };
        }
        let t = ast.member_ty(mid);
        if t == TYPE_NONE {
            // The declaration's check has not recorded the member yet: the layout is not known yet.
            self.pending += 1;
            return Layout { ok: false };
        }
        return self.layout_of(m, t, env, depth);
    }

    // The element count of array length type `lt` (pool `m`) under `env`: a count, a const
    // parameter's bound argument, or a linear form over such arguments; -1 when a parameter is
    // unbound, the form names a module constant, or the value is no array length.
    fn len_of(self: &Self, m: ModuleId, lt: TypeId, env: *const LayoutEnv, depth: i32) i64 {
        let mut v = i128::zero();
        if !self.cval_of(m, lt, env, depth, &mut v) {
            return -1;
        }
        return len_count(v);
    }

    // The exact value of const type `lt` (pool `m`) under `env` (`len_of`); false when it does not fold.
    fn cval_of(self: &Self, m: ModuleId, lt: TypeId, env: *const LayoutEnv, depth: i32, out: &mut i128) bool {
        if depth > MAX_DEPTH {
            return false;
        }
        let ly = *self.a(m).type_at(lt);
        if ly.kind == TypeKind::TYPE_CONST {
            *out = ly.cval();
            return true;
        }
        if ly.kind == TypeKind::TYPE_GENERIC {
            return self.param_val(ly.module, ly.as_data.decl, env, depth, out);
        }
        if ly.kind != TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        let l = *self.a(m).const_lin_at(ly.as_data.inst);
        let mut sum = l.k;
        for i in 0..l.n {
            let pd = unsafe l.p[i as usize];
            let mut v = i128::zero();
            if self.a(pd.module).at_const(pd.node).kind != NodeKind::NODE_GENERIC_PARAM || !self.param_val(
                pd.module,
                pd.node,
                env,
                depth,
                &mut v,
            ) || !lin_acc(&mut sum, unsafe l.c[i as usize], v) {
                return false;
            }
        }
        // A value outside the form's types is no value: the instantiation is an error.
        return l.finish(sum, self.tgt().ptr == 4, out);
    }

    // Whether the const-generic steps of aggregate `dn` (module `dm`, `Ast::steps_of`) hold under
    // `env`: the written member types compute each of them.
    fn steps_hold(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv) bool {
        let mut ss = replace(&mut self.steps, Vector::<ConstStep>::new());
        unsafe (*(self.p().module_ast_const(dm) as *mut Ast)).steps_of(dn, &mut ss);
        let mut ok = true;
        for i in 0..ss.len() {
            let s = ss.at(i);
            let mut sum = s.lin.k;
            let mut bound = true;
            for t in 0..s.lin.n {
                let c = unsafe s.lin.c[t as usize];
                if c.is_zero() {
                    continue;
                }
                let pd = unsafe s.lin.p[t as usize];
                let mut v = i128::zero();
                if !self.param_val(pd.module, pd.node, env, 0, &mut v) || !lin_acc(&mut sum, c, v) {
                    bound = false;
                    break;
                }
            }
            if bound && !s.holds(sum, self.tgt().ptr == 4) {
                ok = false;
                break;
            }
        }
        self.steps = ss;
        return ok;
    }

    // The value of const parameter `pd` (module `pm`) under `env`, innermost frame first; an
    // argument reads under the env it was written in, and one unbound there falls back to the
    // next-outer binding of the same parameter (as `layout_of` resolves a type parameter).
    fn param_val(self: &Self, pm: ModuleId, pd: NodeId, env: *const LayoutEnv, depth: i32, out: &mut i128) bool {
        let mut e = env;
        while e != null {
            for i in 0..unsafe (*e).n {
                if unsafe (*e).pmod == pm && unsafe (*e).params[i as usize] == pd && self.cval_of(
                    unsafe (*e).argm,
                    unsafe (*e).args[i as usize],
                    unsafe (*e).penv,
                    depth + 1,
                    out,
                ) {
                    return true;
                }
            }
            e = unsafe (*e).parent;
        }
        return false;
    }

    /// Size/align of `(m, t)` under the target data model; not-ok = not layoutable (opaque, header
    /// struct or union, unbound generic, recursive by-value cycle).
    pub(package) fn layout(self: &mut Self, m: ModuleId, t: TypeId) Layout {
        return self.layout_of(m, t, null, 0);
    }

    pub(package) fn layout_of(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) Layout {
        if depth > MAX_DEPTH || t == TYPE_NONE {
            return Layout { ok: false };
        }
        if !self.has_ast(m) {
            return Layout { ok: false };
        }
        let cacheable = env == null && self.a(m).type_concrete(t);
        // mixed: unmixed (module << 32 | type) keys collide across modules under the identity
        // u64 hash, and this cache sits on the emitter's storage-elision hot path
        let key = skey_mix(0, m as u64 << 32 | t as u64);
        if cacheable {
            let hit = self.cache.get(&key);
            if unsafe TS_ON {
                ts_add(TS_LAY, 1);
                if hit.is_some() {
                    ts_add(TS_LAY_HIT, 1);
                }
            }
            switch hit {
                Some(v) => {
                    return *v;
                },
                None => {},
            };
        }
        let mut t0: u64 = 0;
        if unsafe TS_ON && depth == 0 {
            ts_add(TS_LAY_RAW, 1);
            t0 = ts_now();
        }
        let pending = self.pending;
        let mut r = self.layout_raw(m, t, env, depth);
        if r.ok && r.size > (1u64 << self.tgt().ptr * 8 - 1) - 1 {
            r = Layout { ok: false, big: true };
        }
        if t0 != 0 {
            ts_add(TS_LAY_NS, ts_now() - t0);
        }
        if cacheable && self.pending == pending {
            self.cache.insert(key, r);
            if unsafe TS_ON {
                ts_add(TS_LAY_INS, 1);
            }
        }
        return r;
    }

    fn layout_raw(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) Layout {
        let y = *self.a(m).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let b = y.as_data.builtin;
            if b == BuiltinType::BT_BOOL || b == BuiltinType::BT_CHAR || b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 {
                return Layout { ok: true, size: 1, align: 1 };
            }
            if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
                return Layout { ok: true, size: 2, align: 2 };
            }
            if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_F32 {
                return Layout { ok: true, size: 4, align: 4 };
            }
            if b == BuiltinType::BT_ISIZE || b == BuiltinType::BT_USIZE {
                let w = self.tgt().ptr;
                return Layout { ok: true, size: w, align: w };
            }
            if b == BuiltinType::BT_I64 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_F64 {
                return Layout { ok: true, size: 8, align: 8 };
            }
            if b == BuiltinType::BT_C32 {
                return Layout { ok: true, size: 8, align: 4 };
            }
            if b == BuiltinType::BT_C64 {
                return Layout { ok: true, size: 16, align: 8 };
            }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_FUNCTION && self.has_ast(y.module) {
            let mut tys = Vector::<TypeId>::new();
            let mut by_ref: u64 = 0;
            if self.a(y.module).closure_env(y.as_data.decl, &mut tys, &mut by_ref) {
                return self.env_layout(y.module, &tys, by_ref, depth);
            }
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION {
            let w = self.tgt().ptr;
            return Layout { ok: true, size: w, align: w };
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            // A register type (`@value(size, align)`) and a C value (`@layout(size, align)`) state
            // their layout; any other opaque type has none the compiler knows.
            if !self.has_ast(y.module) {
                return Layout { ok: false };
            }
            let k = if self.attr(y.module, y.as_data.decl, AttrKind::ATTR_C_VALUE) != null {
                AttrKind::ATTR_C_VALUE;
            } else {
                AttrKind::ATTR_LAYOUT;
            };
            if self.attr(y.module, y.as_data.decl, k) == null {
                return Layout { ok: false };
            }
            let av = self.a(y.module).attr_value(y.as_data.decl, k);
            if !av.ok {
                self.pending += 1;
                return Layout { ok: false };
            }
            return Layout { ok: true, size: av.v, align: av.w[0] };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let el = self.layout_of(m, y.as_data.arr.elem, env, depth + 1);
            if !el.ok {
                return Layout { ok: false, unbound: el.unbound, big: el.big };
            }
            if el.size == 0 {
                // A zero-sized element gives size 0 for every length (and keeps the element
                // alignment for enclosing aggregates).
                return Layout { ok: true, size: 0, align: el.align };
            }
            let mut n = y.as_data.arr.len as i64;
            if y.arr_sym() {
                n = self.len_of(m, y.as_data.arr.len, env, depth + 1);
                if n < 0 {
                    return Layout { ok: false, unbound: true };
                }
            }
            if n as u64 > 0xFFFFFFFFFFFFFFFFu64 / el.size {
                return Layout { ok: false, big: true }; // length * element overflow: unrepresentable
            }
            return Layout { ok: true, size: el.size * n as u64, align: el.align };
        }
        if y.is_vec() {
            // A mask is the smallest unsigned integer holding its lane bits; a vector its lanes,
            // aligned to `max(alignof(T), min(size, 16))` on every target and feature set.
            let n = self.len_of(m, y.as_data.arr.len, env, depth + 1);
            let el = self.layout_of(m, y.as_data.arr.elem, env, depth + 1);
            if n < 0 || !el.ok {
                return Layout { ok: false, unbound: n < 0 || el.unbound };
            }
            if y.kind == TypeKind::TYPE_MASK {
                let w: u64 = if n <= 8 {
                    1;
                } else if n <= 16 {
                    2;
                } else if n <= 32 {
                    4;
                } else {
                    8;
                };
                return Layout { ok: true, size: w, align: w };
            }
            let size = el.size * n as u64;
            return Layout { ok: true, size: size, align: el.align.max(size.min(16)) };
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut e = env;
            while e != null {
                for i in 0..unsafe (*e).n {
                    if unsafe (*e).pmod == y.module && unsafe (*e).params[i as usize] == y.as_data.decl {
                        // An argument unbound in its own env falls back to the next-outer binding
                        // of the same parameter, as the emitter's substitution lookup does.
                        let r = self.layout_of(
                            unsafe (*e).argm,
                            unsafe (*e).args[i as usize],
                            unsafe (*e).penv,
                            depth + 1,
                        );
                        if r.ok || !r.unbound {
                            return r;
                        }
                    }
                }
                e = unsafe (*e).parent;
            }
            return Layout { ok: false, unbound: true };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.aggregate_layout(y.module, y.as_data.decl, null, depth + 1);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.a(m).instance(y.as_data.inst);
            if !self.has_ast(it.module) {
                return Layout { ok: false };
            }
            let frame = inst_frame(self.a(it.module), &it, m, env);
            return self.aggregate_layout(it.module, it.decl, &frame, depth + 1);
        }
        return Layout { ok: false };
    }

    // A closure with captures is its env struct, by value (`Mangler::env_field`): a field per capture
    // of nonzero size, a pointer for one the body mutates or borrows; one byte when every capture is
    // zero-sized.
    fn env_layout(self: &mut Self, m: ModuleId, tys: &Vector<TypeId>, by_ref: u64, depth: i32) Layout {
        let w = self.tgt().ptr;
        let mut size: u64 = 0;
        let mut align: u64 = 1;
        for k in 0..tys.len() {
            let mut fl = self.layout_of(m, tys[k], null, depth + 1);
            if !fl.ok {
                return fl;
            }
            if fl.size == 0 {
                continue;
            }
            if (by_ref >> k as u64 & 1u64) != 0 {
                fl = Layout { ok: true, size: w, align: w };
            }
            // Each capture is below isize::MAX, so only the running sum can pass u64.
            if size > 0xFFFFFFFFFFFFFFFFu64 - fl.align - fl.size {
                return Layout { ok: false, big: true };
            }
            size = round_up(size, fl.align) + fl.size;
            align = align.max(fl.align);
        }
        if size == 0 {
            return Layout { ok: true, size: 1, align: 1 };
        }
        return Layout { ok: true, size: round_up(size, align), align: align };
    }

    // Accumulate the member typed by annotation `tn` into `acc`; false = unfoldable.
    fn acc_field(self: &mut Self, acc: *mut LayoutAcc, m: ModuleId, mid: NodeId, env: *const LayoutEnv, depth: i32) bool {
        let fl = self.member_layout(m, mid, env, depth);
        if !fl.ok {
            unsafe (*acc).unbound = fl.unbound;
            unsafe (*acc).big = fl.big;
            return false;
        }
        let mut fa = fl.align;
        if unsafe (*acc).packed {
            fa = 1;
        }
        if unsafe (*acc).is_union {
            if fl.size > unsafe (*acc).size {
                unsafe (*acc).size = fl.size;
            }
        } else {
            // Each field is below isize::MAX, so only the running sum can pass u64.
            if unsafe (*acc).size > 0xFFFFFFFFFFFFFFFFu64 - fa - fl.size {
                unsafe (*acc).big = true;
                return false;
            }
            unsafe (*acc).size = round_up(unsafe (*acc).size, fa) + fl.size;
        }
        if fa > unsafe (*acc).align {
            unsafe (*acc).align = fa;
        }
        return true;
    }

    fn aggregate_layout(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        // The mark names the instantiation, not the declaration: `W<W<i32>>` holds `W<i32>`, which
        // is no cycle. A repeated argument list re-entered under the same declaration is one.
        let mut key = skey_mix(0, dm as u64 << 32 | dn as u64);
        if env != null {
            key = skey_mix(key, unsafe (*env).argm);
            for i in 0..unsafe (*env).n {
                key = skey_mix(key, unsafe (*env).args[i as usize]);
            }
        }
        for i in 0..self.active.len() {
            if self.active[i] == key {
                return Layout { ok: false }; // recursive by-value cycle
            }
        }
        self.active.push(key);
        let r = self.aggregate_layout_raw(dm, dn, env, depth);
        let _ = self.active.pop();
        return r;
    }

    fn aggregate_layout_raw(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        let ap = self.p().module_ast_const(dm);
        let ast = unsafe &*ap;
        let dkind = ast.at_const(dn).kind;
        if env != null && !self.steps_hold(dm, dn, env) {
            return Layout { ok: false };
        }
        if dkind == NodeKind::NODE_ENUM {
            let e = self.enum_shape(dm, dn, env, depth);
            return Layout { ok: e.ok, size: e.size, align: e.align, unbound: e.unbound };
        }
        if dkind != NodeKind::NODE_STRUCT {
            return Layout { ok: false };
        }
        let is_union = ast.ext(dn).aggregate.is_union;
        let is_tuple = ast.ext(dn).aggregate.is_tuple;
        let mut acc = LayoutAcc { is_union: is_union };
        acc.packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let fs = ast.ext(dn).aggregate.members;
        for i in 0..fs.len {
            let fid = unsafe ast.list(fs)[i as usize];
            let fkind = ast.at_const(fid).kind;
            if !is_tuple && fkind != NodeKind::NODE_FIELD {
                continue;
            }
            if !self.acc_field(&mut acc, dm, fid, env, depth) {
                return Layout { ok: false, unbound: acc.unbound, big: acc.big };
            }
        }
        let al = self.attr(dm, dn, AttrKind::ATTR_ALIGN);
        if al != null {
            let mut v = (unsafe (*al).arg) as u64;
            if unsafe (*al).expr {
                // Evaluated by the declaration's own check: before it, the layout is not known yet.
                let av = ast.attr_value(dn, AttrKind::ATTR_ALIGN);
                if !av.ok {
                    self.pending += 1;
                    return Layout { ok: false };
                }
                v = av.v;
            }
            if v > acc.align {
                acc.align = v;
            }
        }
        if acc.align == 0 {
            acc.align = 1;
        }
        return Layout { ok: true, size: round_up(acc.size, acc.align), align: acc.align };
    }

    // A payload enum's shape under `env` (payload-less enums are a bare 4-byte C enum).
    fn enum_shape(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) EnumLayout {
        let ap = self.p().module_ast_const(dm);
        let ast = unsafe &*ap;
        let ms = ast.ext(dn).aggregate.members;
        if !ast.enum_has_payload(dn) {
            return EnumLayout { ok: true, payload_off: 0, size: 4, align: 4 };
        }
        let mut sv = NODE_NONE;
        let mut nv = NODE_NONE;
        if ast.niche_shape(dn, &mut sv, &mut nv) {
            let pid = unsafe ast.list(ast.at_const(sv).as_data.variant.payload)[0];
            if self.niche_on(dm, ast.member_ty(pid), env, depth) {
                let pl = self.member_layout(dm, pid, env, depth);
                if !pl.ok {
                    return EnumLayout { ok: false, unbound: pl.unbound };
                }
                return EnumLayout { ok: true, payload_off: 0, size: pl.size, align: pl.align, niche: true };
            }
        }
        let mut un = LayoutAcc { is_union: true };
        for i in 0..ms.len {
            let mid = unsafe ast.list(ms)[i as usize];
            let pl = ast.at_const(mid).as_data.variant.payload;
            if pl.len == 0 {
                continue;
            }
            let mut vs = LayoutAcc {};
            for k in 0..pl.len {
                let pid = unsafe ast.list(pl)[k as usize];
                if !self.acc_field(&mut vs, dm, pid, env, depth) {
                    return EnumLayout { ok: false, unbound: vs.unbound };
                }
            }
            vs.size = round_up(vs.size, vs.align);
            if vs.size > un.size {
                un.size = vs.size;
            }
            if vs.align > un.align {
                un.align = vs.align;
            }
        }
        let tag: u64 = if ast.enum_tag_is_byte(dn) {
            1;
        } else {
            4;
        };
        let poff = round_up(tag, un.align);
        let ssize = poff + un.size;
        let mut salign: u64 = tag;
        if un.align > salign {
            salign = un.align;
        }
        return EnumLayout { ok: true, payload_off: poff, size: round_up(ssize, salign), align: salign };
    }

    /// The byte offset of field decl `fdecl` inside `(m, t)` (structs and struct instances), or -1.
    pub(package) fn field_offset(self: &mut Self, m: ModuleId, t: TypeId, fdecl: NodeId) i64 {
        let y = *self.a(m).type_at(t);
        let mut dm: ModuleId = 0;
        let mut dn = NODE_NONE;
        let mut frame = LayoutEnv { parent: null, pmod: 0, params: null, argm: m, n: 0 };
        let mut env: *const LayoutEnv = null;
        if y.kind == TypeKind::TYPE_STRUCT {
            dm = y.module;
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.a(m).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
            frame = inst_frame(self.a(dm), &it, m, null);
            env = &frame;
        } else {
            return -1;
        }
        return self.offset_in(dm, dn, env, fdecl);
    }

    /// The layout of the struct or union `dn` of module `dm`, which has no generic parameters.
    pub(package) fn decl_layout(self: &mut Self, dm: ModuleId, dn: NodeId) Layout {
        return self.aggregate_layout(dm, dn, null, 0);
    }

    /// The byte offset of field `fdecl` of the struct or union `dn` of module `dm`, which has no
    /// generic parameters; -1 when it has no layout.
    pub(package) fn decl_field_offset(self: &mut Self, dm: ModuleId, dn: NodeId, fdecl: NodeId) i64 {
        return self.offset_in(dm, dn, null, fdecl);
    }

    // The byte offset of field `fdecl` of declaration `(dm, dn)` under `env`, or -1.
    fn offset_in(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, fdecl: NodeId) i64 {
        let ap = self.p().module_ast_const(dm);
        let ast = unsafe &*ap;
        if ast.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return -1;
        }
        if ast.ext(dn).aggregate.is_union {
            // every union member sits at offset 0
            return 0;
        }
        let packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let is_tuple = ast.ext(dn).aggregate.is_tuple;
        let fs = ast.ext(dn).aggregate.members;
        let mut off: u64 = 0;
        for i in 0..fs.len {
            let fid = unsafe ast.list(fs)[i as usize];
            // tuple members are bare type nodes; a named member is a field
            if !is_tuple && ast.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fl = self.member_layout(dm, fid, env, 1);
            if !fl.ok {
                return -1;
            }
            let mut fa = fl.align;
            if packed {
                fa = 1;
            }
            off = round_up(off, fa);
            if fid == fdecl {
                return off as i64;
            }
            off += fl.size;
        }
        return -1;
    }

    /// The C shape of a payload enum `(m, t)`; `ok` false for non-enums or unlayoutable payloads.
    pub(package) fn enum_layout(self: &mut Self, m: ModuleId, t: TypeId) EnumLayout {
        let y = *self.a(m).type_at(t);
        if y.kind == TypeKind::TYPE_ENUM {
            return self.enum_shape(y.module, y.as_data.decl, null, 0);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.a(m).instance(y.as_data.inst);
            let da = self.a(it.module);
            if da.at_const(it.decl).kind != NodeKind::NODE_ENUM {
                return EnumLayout { ok: false };
            }
            let frame = inst_frame(da, &it, m, null);
            if !self.steps_hold(it.module, it.decl, &frame) {
                return EnumLayout { ok: false };
            }
            return self.enum_shape(it.module, it.decl, &frame, 0);
        }
        return EnumLayout { ok: false };
    }

    /// The bytes a value of variant `vdecl` of enum `(m, t)` occupies from the value's start: its
    /// tag and its own payload. The whole value for a niche enum (the payload holds the discriminant)
    /// and for an enum without payloads; -1 when `(m, t)` has no layout.
    pub(package) fn variant_extent(self: &mut Self, m: ModuleId, t: TypeId, vdecl: NodeId) i64 {
        let y = *self.a(m).type_at(t);
        let mut frame = LayoutEnv { parent: null, pmod: 0, params: null, argm: m, n: 0 };
        let mut env: *const LayoutEnv = null;
        let mut dm: ModuleId = y.module;
        let mut dn = NODE_NONE;
        if y.kind == TypeKind::TYPE_ENUM {
            dn = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.a(m).instance(y.as_data.inst);
            dm = it.module;
            dn = it.decl;
            if self.a(dm).at_const(dn).kind != NodeKind::NODE_ENUM {
                return -1;
            }
            frame = inst_frame(self.a(dm), &it, m, null);
            if !self.steps_hold(dm, dn, &frame) {
                return -1;
            }
            env = &frame;
        } else {
            return -1;
        }
        let el = self.enum_shape(dm, dn, env, 0);
        if !el.ok {
            return -1;
        }
        let ast = unsafe &*self.p().module_ast_const(dm);
        if el.niche || !ast.enum_has_payload(dn) {
            return el.size as i64;
        }
        let tag: i64 = if ast.enum_tag_is_byte(dn) {
            1;
        } else {
            4;
        };
        let pl = ast.at_const(vdecl).as_data.variant.payload;
        let mut vs = LayoutAcc {};
        for k in 0..pl.len {
            if !self.acc_field(&mut vs, dm, unsafe ast.list(pl)[k as usize], env, 0) {
                return -1;
            }
        }
        if vs.size == 0 {
            return tag;
        }
        return el.payload_off as i64 + vs.size as i64;
    }
}
