// The target layout service: one pure implementation of size, alignment, field
// offsets, and enum shape for every stage (constant evaluation today, C planning later). Layout is a
// function of the type, the declaration attributes, and the TARGET data record -- never of host
// `sizeof`. Results for concrete env-free types cache per (module, type); an active-query mark turns
// a recursive by-value cycle into a clean not-layoutable answer instead of a runaway.
import ast::ast as *;
import module::loader as loader;

/// Immutable target data. Every supported target currently shares the flat C data model except for
/// pointer width; new axes (endianness, aggregate rules) join here, not at call sites.
pub struct Target {
    pub ptr: u64, // pointer size == alignment
}

/// The target record for a package's instruction-set selection (loader arch codes; 2 = wasm32).
pub const fn target_for(arch: i32) Target {
    if arch == 2 {
        return Target { ptr: 4 };
    }
    return Target { ptr: 8 };
}

pub struct Layout {
    pub ok: bool,
    pub size: u64,
    pub align: u64,
}

/// One substitution frame for generic-parameter layout: parameter decls of `pmod` bound to argument
/// types of `argm` (chained through `parent`).
pub struct LayoutEnv {
    pub parent: *const LayoutEnv,
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
}

/// A payload-carrying enum's C shape: `{ u32 tag; union payload; }`.
pub struct EnumLayout {
    pub ok: bool,
    pub payload_off: u64, // tag sits at 0
    pub size: u64,
    pub align: u64,
}

const MAX_DEPTH: i32 = 32;

const fn round_up(v: u64, a: u64) u64 {
    if a <= 1 {
        return v;
    }
    return (v + a - 1) / a * a;
}

pub struct Svc {
    pub pkg: *const loader::Package,
    cache: Map<u64, u64>, // (module << 32 | type) -> size << 8 | align (env-free concrete only)
    active: Vector<u64>, // aggregate decls under query (module << 32 | decl): cycle mark
}

extend Svc as Free {
    pub fn free(self: &mut Self) {
        self.cache.free();
        self.active.free();
    }
}

extend Svc {
    pub fn new(pkg: *const loader::Package) Svc {
        return Svc { pkg: pkg, cache: Map::<u64, u64>::new(), active: Vector::<u64>::new() };
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
        let ap = self.p().module_ast_const(m);
        let ast = unsafe &*ap;
        for i in 0..ast.attrs.len() {
            if ast.attrs.at(i).owner == decl && ast.attrs.at(i).kind == kind as u8 {
                return ast.attrs.at(i);
            }
        }
        return null;
    }

    // A member type node's recorded type (TYPE_NONE when the checker recorded none).
    const fn mtype(self: &Self, m: ModuleId, id: NodeId) TypeId {
        let ast = self.a(m);
        if ast.types.len() > id as usize {
            return ast.type_of(id);
        }
        return TYPE_NONE;
    }

    /// Size/align of `(m, t)` under the target data model; not-ok = not layoutable (opaque, unbound
    /// generic, recursive by-value cycle).
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
            let mut have = false;
            let mut enc: u64 = 0;
            switch self.cache.get(&key) {
                Some(v) => {
                    have = true;
                    enc = *v;
                },
                None => {},
            };
            if have {
                if enc == 0 {
                    return Layout { ok: false };
                }
                return Layout { ok: true, size: enc >> 8, align: enc & 0xFF };
            }
        }
        let r = self.layout_raw(m, t, env, depth);
        if cacheable {
            let mut enc: u64 = 0;
            if r.ok {
                enc = r.size << 8 | r.align;
            }
            self.cache.insert(key, enc);
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
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_FUNCTION {
            let w = self.tgt().ptr;
            return Layout { ok: true, size: w, align: w };
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let el = self.layout_of(m, y.as_data.arr.elem, env, depth + 1);
            if !el.ok {
                return Layout { ok: false };
            }
            let n = y.as_data.arr.len as u64;
            if n == 0 {
                // The pool interns BOTH a true `[T; 0]` and a symbolic generic `[T; N]` with len 0,
                // so a material element makes the size unknowable here: refuse. A zero-sized
                // element gives size 0 for EVERY reading, so that case is layoutable (and keeps
                // the element alignment for enclosing aggregates).
                if el.size != 0 {
                    return Layout { ok: false };
                }
                return Layout { ok: true, size: 0, align: el.align };
            }
            if el.size != 0 && n > 0xFFFFFFFFFFFFFFFFu64 / el.size {
                return Layout { ok: false }; // length * element overflow: unrepresentable
            }
            return Layout { ok: true, size: el.size * n, align: el.align };
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut e = env;
            while e != null {
                for i in 0..unsafe e.n {
                    if unsafe e.pmod == y.module && unsafe e.params[i as usize] == y.as_data.decl {
                        return self.layout_of(unsafe e.argm, unsafe e.args[i as usize], unsafe e.parent, depth + 1);
                    }
                }
                e = unsafe e.parent;
            }
            return Layout { ok: false };
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.aggregate_layout(y.module, y.as_data.decl, null, depth + 1);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *self.a(m).instance(y.as_data.inst);
            if !self.has_ast(it.module) {
                return Layout { ok: false };
            }
            let da = self.a(it.module);
            let gens = da.at_const(it.decl).as_data.aggregate.generics;
            let mut frame = LayoutEnv { parent: env, pmod: it.module, params: da.list(gens), argm: m, n: 0 };
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && frame.n < 8 {
                unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
                frame.n = frame.n + 1;
                i = i + 1;
            }
            return self.aggregate_layout(it.module, it.decl, &frame, depth + 1);
        }
        return Layout { ok: false };
    }

    // Accumulate one field into `acc`; false = unfoldable.
    fn acc_field(self: &mut Self, acc: *mut LayoutAcc, m: ModuleId, ft: TypeId, env: *const LayoutEnv, depth: i32) bool {
        let fl = self.layout_of(m, ft, env, depth);
        if !fl.ok {
            return false;
        }
        let mut fa = fl.align;
        if unsafe acc.packed {
            fa = 1;
        }
        if unsafe acc.is_union {
            if fl.size > unsafe acc.size {
                unsafe acc.size = fl.size;
            }
        } else {
            unsafe acc.size = round_up(unsafe acc.size, fa) + fl.size;
        }
        if fa > unsafe acc.align {
            unsafe acc.align = fa;
        }
        return true;
    }

    fn aggregate_layout(self: &mut Self, dm: ModuleId, dn: NodeId, env: *const LayoutEnv, depth: i32) Layout {
        let key = dm as u64 << 32 | dn as u64;
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
        if dkind == NodeKind::NODE_ENUM {
            let e = self.enum_shape(dm, dn, env, depth);
            return Layout { ok: e.ok, size: e.size, align: e.align };
        }
        if dkind != NodeKind::NODE_STRUCT {
            return Layout { ok: false };
        }
        let is_union = ast.at_const(dn).as_data.aggregate.is_union;
        let is_tuple = ast.at_const(dn).as_data.aggregate.is_tuple;
        let mut acc = LayoutAcc { is_union: is_union };
        acc.packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let fs = ast.at_const(dn).as_data.aggregate.members;
        for i in 0..fs.len {
            let fid = unsafe ast.list(fs)[i as usize];
            let fkind = ast.at_const(fid).kind;
            if !is_tuple && fkind != NodeKind::NODE_FIELD {
                continue;
            }
            let mut ftn = fid;
            if !is_tuple {
                ftn = ast.at_const(fid).as_data.field.ty;
            }
            let ft = self.mtype(dm, ftn);
            if ft == TYPE_NONE {
                return Layout { ok: false };
            }
            if !self.acc_field(&mut acc, dm, ft, env, depth) {
                return Layout { ok: false };
            }
        }
        let al = self.attr(dm, dn, AttrKind::ATTR_ALIGN);
        if al != null && unsafe al.arg != 0 {
            if (unsafe al.arg) as u64 > acc.align {
                acc.align = unsafe al.arg;
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
        let mut payload = false;
        for i in 0..ms.len {
            let mid = unsafe ast.list(ms)[i as usize];
            if ast.at_const(mid).as_data.variant.payload.len > 0 {
                payload = true;
            }
        }
        if !payload {
            return EnumLayout { ok: true, payload_off: 0, size: 4, align: 4 };
        }
        let mut un = LayoutAcc { is_union: true };
        for i in 0..ms.len {
            let mid = unsafe ast.list(ms)[i as usize];
            let pl = ast.at_const(mid).as_data.variant.payload;
            if pl.len == 0 {
                continue;
            }
            let struct_payload = ast.at_const(mid).as_data.variant.struct_payload;
            let mut vs = LayoutAcc {};
            for k in 0..pl.len {
                let pid = unsafe ast.list(pl)[k as usize];
                let mut tn = pid;
                if struct_payload {
                    tn = ast.at_const(pid).as_data.field.ty;
                }
                if !self.acc_field(&mut vs, dm, self.mtype(dm, tn), env, depth) {
                    return EnumLayout { ok: false };
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
        let poff = round_up(4, un.align);
        let ssize = poff + un.size;
        let mut salign: u64 = 4;
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
            let da = self.a(dm);
            let gens = da.at_const(dn).as_data.aggregate.generics;
            frame.pmod = dm;
            frame.params = da.list(gens);
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && frame.n < 8 {
                unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
                frame.n = frame.n + 1;
                i = i + 1;
            }
            env = &frame;
        } else {
            return -1;
        }
        let ap = self.p().module_ast_const(dm);
        let ast = unsafe &*ap;
        if ast.at_const(dn).kind != NodeKind::NODE_STRUCT || ast.at_const(dn).as_data.aggregate.is_union {
            if ast.at_const(dn).kind != NodeKind::NODE_STRUCT {
                return -1;
            }
            // every union member sits at offset 0
            return 0;
        }
        let packed = self.attr(dm, dn, AttrKind::ATTR_PACKED) != null;
        let is_tuple = ast.at_const(dn).as_data.aggregate.is_tuple;
        let fs = ast.at_const(dn).as_data.aggregate.members;
        let mut off: u64 = 0;
        for i in 0..fs.len {
            let fid = unsafe ast.list(fs)[i as usize];
            // tuple members are bare type nodes; named members carry their type in field.ty
            if !is_tuple && ast.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let ftn = if is_tuple {
                fid;
            } else {
                ast.at_const(fid).as_data.field.ty;
            };
            let ft = self.mtype(dm, ftn);
            let fl = self.layout_of(dm, ft, env, 1);
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
            let gens = da.at_const(it.decl).as_data.aggregate.generics;
            let mut frame = LayoutEnv { parent: null, pmod: it.module, params: da.list(gens), argm: m, n: 0 };
            let mut i: u32 = 0;
            while i < gens.len && i as u8 < it.n && frame.n < 8 {
                unsafe frame.args[frame.n as usize] = unsafe it.args[i as usize];
                frame.n = frame.n + 1;
                i = i + 1;
            }
            return self.enum_shape(it.module, it.decl, &frame, 0);
        }
        return EnumLayout { ok: false };
    }
}
