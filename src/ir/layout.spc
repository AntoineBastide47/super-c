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
pub struct Target {
    pub ptr: u64, // pointer size == alignment
}

/// The target record for a package's instruction set (a `target::table::ISAS` index; -1, unknown,
/// lays out as 64-bit).
pub const fn target_for(arch: i32) Target {
    return Target { ptr: tgt::isa(arch).ptr_bytes };
}

pub struct Layout {
    pub ok: bool,
    pub size: u64,
    pub align: u64,
    /// A failure because a generic parameter had no binding in the env: the query was asked
    /// under an incomplete substitution, as opposed to a type no env can lay out.
    pub unbound: bool,
    /// A failure because the size exceeds the target's `isize::MAX`: no object can be that large.
    pub big: bool,
}

/// One substitution frame for generic-parameter layout: parameter decls of `pmod` bound to argument
/// types of `argm`. A lookup that misses this frame continues at `parent`; a bound argument is read
/// under `penv`, the env it was written in (the emitter's substitution stack hides a binding's own
/// group from its payload, so the two chains can differ).
pub struct LayoutEnv {
    pub parent: *const LayoutEnv,
    pub penv: *const LayoutEnv,
    pub pmod: ModuleId,
    pub params: *const NodeId,
    pub argm: ModuleId,
    pub args: [TypeId; 8],
    pub n: u8,
}

struct LayoutAcc {
    pub size: u64,
    pub align: u64,
    pub packed: bool,
    pub is_union: bool,
    pub unbound: bool, // set by `ordered` on a failing member (see Layout.unbound)
    pub big: bool, // set by `ordered` on a member too large, or `acc_members` on a sum past u64 (see Layout.big)
}

/// A payload-carrying enum's C shape: `{ tag; union payload; }`, with a one-byte tag when
/// `Ast::enum_tag_is_byte` holds and a 4-byte C enum tag otherwise.
pub struct EnumLayout {
    pub unbound: bool, // see Layout.unbound
    pub ok: bool,
    pub payload_off: u64, // tag sits at 0
    pub size: u64,
    pub align: u64,
}

const NONE: u32 = 0xFFFFFFFF;

/// `Svc::ordered_prefix` of a type whose whole field list keeps its declared order.
pub const ORDER_ALL: u32 = 0xFFFFFFFF;

/// One member in layout order (`Svc::ordered`): its position in the declaration's member list, its
/// size and its alignment (1 in a `@packed` struct), and its offset (`place_members`).
pub struct MemberAt {
    pub pos: u32,
    pub size: u64,
    pub align: u64,
    pub off: u64,
}

extend MemberAt as Copy {}

// Recursion guard. A finite type stays far below it: instance arguments nest at most 256 levels
// (the instance graph and the emitter refuse deeper ones) and a declaration holds at most 64 nested
// aggregates by value (the checker's BYVAL_MAX_DEPTH), each level costing two steps here. Only a
// type the checker already reported as infinite (a generic holding itself with a growing
// argument) reaches it; the walk then fails instead of exhausting the stack.
const MAX_DEPTH: i32 = 1024;

/// Put members `ms[from..]` (in declared order, each with its size and alignment) in layout order: the
/// first `prefix` stay, the rest follow stable by alignment, largest first. Every stage that lays out a
/// struct's fields or a variant's payload orders them here (`Svc::ordered_prefix` gives `prefix`).
pub fn sort_members(ms: &mut Vector<MemberAt>, from: usize, prefix: u32) {
    let end = ms.len();
    let first = from + pick(prefix as usize > end - from, end - from, prefix as usize);
    if end - first < 2 {
        return;
    }
    // One pass per power of two, at most 64.
    let mut hi: u64 = 1;
    for k in first..end {
        hi = hi.max(ms[k].align);
    }
    let mut a = hi;
    while a != 0 {
        for k in first..end {
            if ms[k].align == a {
                ms.push(ms[k]);
            }
        }
        a /= 2;
    }
    assert(ms.len() - end == end - first, "layout: an alignment that is not a power of two");
    for k in 0..end - first {
        ms.set(first + k, ms[end + k]);
    }
    ms.truncate(end);
}

// The size of members `ms[from..]` placed in their order, each at the next multiple of its alignment, rounded
// up to the largest alignment; u64::MAX when it passes u64.
fn extent(ms: &Vector<MemberAt>, from: usize) u64 {
    let mut size: u64 = 0;
    let mut align: u64 = 1;
    for k in from..ms.len() {
        if size > 0xFFFFFFFFFFFFFFFFu64 - ms[k].align - ms[k].size {
            return 0xFFFFFFFFFFFFFFFFu64;
        }
        size = round_up(size, ms[k].align) + ms[k].size;
        align = align.max(ms[k].align);
    }
    if size > 0xFFFFFFFFFFFFFFFFu64 - align {
        return 0xFFFFFFFFFFFFFFFFu64;
    }
    return round_up(size, align);
}

/// Place members `ms[from..]`, in layout order (`sort_members`), at their offsets: each at the next
/// multiple of its alignment, or at 0 in a union; their extent and largest alignment into `size` and
/// `align`. False when the size passes u64.
pub fn place_members(ms: &mut Vector<MemberAt>, from: usize, is_union: bool, size: &mut u64, align: &mut u64) bool {
    for k in from..ms.len() {
        let f = ms[k];
        if is_union {
            *size = size.max(f.size);
        } else {
            // Each member is below isize::MAX, so only the running sum can pass u64.
            if *size > 0xFFFFFFFFFFFFFFFFu64 - f.align - f.size {
                return false;
            }
            *size = round_up(*size, f.align);
            ms.index_mut(k).off = *size;
            *size += f.size;
        }
        *align = align.max(f.align);
    }
    return true;
}

/// `v` rounded up to a multiple of `a` (`a` <= 1: `v`).
pub const fn round_up(v: u64, a: u64) u64 {
    if a <= 1 {
        return v;
    }
    return (v + a - 1) / a * a;
}

/// The frame that binds instance `it`'s arguments (types of module `argm`) to the generic
/// parameters of its declaration in `da`, below `parent`.
pub fn inst_frame(da: &Ast, it: &TyInstance, argm: ModuleId, parent: *const LayoutEnv) LayoutEnv {
    let gens = da.at_const(it.decl).as_data.aggregate.generics;
    let mut frame = LayoutEnv { parent: parent, penv: parent, pmod: it.module, params: da.list(gens), argm: argm, n: 0 };
    let mut i: u32 = 0;
    while i < gens.len && i as u8 < it.n && frame.n < 8 {
        unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
        frame.n = frame.n + 1;
        i = i + 1;
    }
    return frame;
}

pub struct Svc {
    pub pkg: *const loader::Package,
    cache: Map<u64, Layout>, // (module << 32 | type) -> layout (env-free concrete only)
    active: Vector<u64>, // aggregate instantiations under query (declaration and arguments): cycle mark
    steps: Vector<ConstStep>, // `steps_hold` scratch
    // `ordered`'s members, a stack: each query appends its own above its callers' and truncates back.
    ms: Vector<MemberAt>,
    pending: u32, // answers that read a constant-expression attribute not evaluated yet: never cached
    /// The declarations (`module << 32 | node`) whose members a layout of this service put in another order
    /// than the declared one (`moved`), those of them whose size the order changed (`resized`), and those
    /// whose field offsets a query read (`offsets`): what may no longer change (`driver::emit::mark_c_reads`).
    pub moved: Set<u64>,
    pub resized: Set<u64>,
    pub offsets: Set<u64>,
    /// The compile-time evaluation this service answers for (null: none). A member of an item the
    /// reader does not see checked (`Interp::visible_node`) is pending.
    pub ev: *const iri::Interp,
}

extend Svc {
    pub fn new(pkg: *const loader::Package) Svc {
        if unsafe TS_ON {
            ts_add(TS_LAY_SVC, 1);
        }
        return Svc {
            pkg: pkg,
            cache: Map::<u64, Layout>::new(),
            active: Vector::<u64>::new(),
            steps: Vector::<ConstStep>::new(),
            ms: Vector::<MemberAt>::new(),
        };
    }

    /// Drop every cached answer: the keys name type ids of one publication, so a checkpoint that
    /// renumbers them (and restarts every module's provisional ids) invalidates the whole cache.
    pub fn reset(self: &mut Self) {
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
    pub fn layout(self: &mut Self, m: ModuleId, t: TypeId) Layout {
        return self.layout_of(m, t, null, 0);
    }

    pub fn layout_of(self: &mut Self, m: ModuleId, t: TypeId, env: *const LayoutEnv, depth: i32) Layout {
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

    /// How many leading fields of struct `dn` (module `dm`) keep their declared positions: all of them
    /// (ORDER_ALL).
    pub const fn ordered_prefix(self: &Self, _dm: ModuleId, _dn: NodeId) u32 {
        return ORDER_ALL;
    }

    /// `ordered_prefix` of payload `pl` of a variant of enum `dn` (module `dm`).
    pub const fn payload_prefix(self: &Self, _dm: ModuleId, _dn: NodeId, _pl: NodeList) u32 {
        return ORDER_ALL;
    }

    // The members of `list` (of declaration `dn` of module `dm`; fields alone unless `all`, a tuple's or a
    // payload's type nodes) in layout order under `env`, appended to `ms` from the returned base: the first
    // `prefix` in declared order, the rest stable by alignment, largest first; alignment 1 when `packed`.
    // NONE when a member has no layout (its flags in `acc`). The caller truncates `ms` to the base.
    fn ordered(
        self: &mut Self,
        dm: ModuleId,
        dn: NodeId,
        list: NodeList,
        all: bool,
        prefix: u32,
        packed: bool,
        env: *const LayoutEnv,
        depth: i32,
        acc: *mut LayoutAcc,
    ) u32 {
        let base = self.ms.len();
        for i in 0..list.len {
            let mid = unsafe self.a(dm).list(list)[i as usize];
            if !all && self.a(dm).at_const(mid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            // A member's own query stacks its members above these and truncates back before returning.
            let fl = self.member_layout(dm, mid, env, depth);
            if !fl.ok {
                unsafe (*acc).unbound = fl.unbound;
                unsafe (*acc).big = fl.big;
                self.ms.truncate(base);
                return NONE;
            }
            self.ms.push(MemberAt { pos: i, size: fl.size, align: pick(packed, 1u64, fl.align), off: 0 });
        }
        let declared = extent(&self.ms, base);
        sort_members(&mut self.ms, base, prefix);
        for k in base + 1..self.ms.len() {
            if self.ms[k].pos < self.ms[k - 1].pos {
                self.moved.insert(dm as u64 << 32 | dn as u64);
                if extent(&self.ms, base) != declared {
                    self.resized.insert(dm as u64 << 32 | dn as u64);
                }
                break;
            }
        }
        return base as u32;
    }

    // Accumulate the members `ordered` stacked from `base` into `acc`, each member's offset into its
    // entry; false (`acc.big`) when the size passes u64.
    fn acc_members(self: &mut Self, acc: &mut LayoutAcc, base: u32) bool {
        if !place_members(&mut self.ms, base as usize, acc.is_union, &mut acc.size, &mut acc.align) {
            acc.big = true;
            return false;
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
        let is_union = ast.at_const(dn).as_data.aggregate.is_union;
        let is_tuple = ast.at_const(dn).as_data.aggregate.is_tuple;
        let mut acc = LayoutAcc { is_union: is_union };
        acc.packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let fs = ast.at_const(dn).as_data.aggregate.members;
        let base = self.ordered(dm, dn, fs, is_tuple, self.ordered_prefix(dm, dn), acc.packed, env, depth, &mut acc);
        if base == NONE {
            return Layout { ok: false, unbound: acc.unbound, big: acc.big };
        }
        let ok = self.acc_members(&mut acc, base);
        self.ms.truncate(base as usize);
        if !ok {
            return Layout { ok: false, unbound: acc.unbound, big: acc.big };
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
        let ms = ast.at_const(dn).as_data.aggregate.members;
        if !ast.enum_has_payload(dn) {
            return EnumLayout { ok: true, payload_off: 0, size: 4, align: 4 };
        }
        let mut un = LayoutAcc { is_union: true };
        for i in 0..ms.len {
            let mid = unsafe ast.list(ms)[i as usize];
            let pl = ast.at_const(mid).as_data.variant.payload;
            if pl.len == 0 {
                continue;
            }
            let mut vs = LayoutAcc {};
            let base = self.ordered(dm, dn, pl, true, self.payload_prefix(dm, dn, pl), false, env, depth, &mut vs);
            if base == NONE {
                return EnumLayout { ok: false, unbound: vs.unbound };
            }
            let ok = self.acc_members(&mut vs, base);
            self.ms.truncate(base as usize);
            if !ok {
                return EnumLayout { ok: false, unbound: vs.unbound };
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
    pub fn field_offset(self: &mut Self, m: ModuleId, t: TypeId, fdecl: NodeId) i64 {
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
    pub fn decl_layout(self: &mut Self, dm: ModuleId, dn: NodeId) Layout {
        return self.aggregate_layout(dm, dn, null, 0);
    }

    /// The byte offset of field `fdecl` of the struct or union `dn` of module `dm`, which has no
    /// generic parameters; -1 when it has no layout.
    pub fn decl_field_offset(self: &mut Self, dm: ModuleId, dn: NodeId, fdecl: NodeId) i64 {
        return self.offset_in(dm, dn, null, fdecl);
    }

    // The byte offset of field `fdecl` of declaration `(dm, dn)` under `env`, or -1.
    fn offset_in(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, fdecl: NodeId) i64 {
        let ast = unsafe &*self.p().module_ast_const(dm);
        if ast.at_const(dn).kind != NodeKind::NODE_STRUCT {
            return -1;
        }
        let fs = ast.at_const(dn).as_data.aggregate.members;
        let mut r: i64 = -1;
        let base = self.members(dm, dn, env);
        if base != NONE {
            for k in base as usize..self.ms.len() {
                if unsafe ast.list(fs)[self.ms[k].pos as usize] == fdecl {
                    r = self.ms[k].off as i64;
                }
            }
            self.ms.truncate(base as usize);
        }
        return r;
    }

    // The fields of struct or union `(dm, dn)` under `env` in layout order with their offsets, stacked on
    // `ms` from the returned base (NONE without a layout); the caller truncates.
    fn members(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv) u32 {
        self.offsets.insert(dm as u64 << 32 | dn as u64);
        let agg = self.a(dm).at_const(dn).as_data.aggregate;
        let mut acc = LayoutAcc { is_union: agg.is_union };
        acc.packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let base = self.ordered(
            dm,
            dn,
            agg.members,
            agg.is_tuple,
            self.ordered_prefix(dm, dn),
            acc.packed,
            env,
            1,
            &mut acc,
        );
        if base != NONE && !self.acc_members(&mut acc, base) {
            self.ms.truncate(base as usize);
            return NONE;
        }
        return base;
    }

    /// `decl_members` of struct, union or tuple type `(m, t)`. False when it has no layout.
    pub fn struct_members(self: &mut Self, m: ModuleId, t: TypeId, out: &mut Vector<MemberAt>) bool {
        let y = *self.a(m).type_at(t);
        if y.kind == TypeKind::TYPE_STRUCT {
            return self.decl_members(y.module, y.as_data.decl, null, out);
        }
        if y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *self.a(m).instance(y.as_data.inst);
        if self.a(it.module).at_const(it.decl).kind != NodeKind::NODE_STRUCT {
            return false;
        }
        let frame = inst_frame(self.a(it.module), &it, m, null);
        return self.decl_members(it.module, it.decl, &frame, out);
    }

    /// The members of struct, union or tuple declaration `(dm, dn)` under `env` in layout order into `out`:
    /// each one's position in the declaration's member list, size, alignment and offset. False when it
    /// has no layout.
    pub fn decl_members(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, out: &mut Vector<MemberAt>) bool {
        let base = self.members(dm, dn, env);
        if base == NONE {
            return false;
        }
        for k in base as usize..self.ms.len() {
            out.push(self.ms[k]);
        }
        self.ms.truncate(base as usize);
        return true;
    }

    /// The C shape of a payload enum `(m, t)`; `ok` false for non-enums or unlayoutable payloads.
    pub fn enum_layout(self: &mut Self, m: ModuleId, t: TypeId) EnumLayout {
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
}
