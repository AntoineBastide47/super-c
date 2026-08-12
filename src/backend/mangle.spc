// The frozen C symbol-naming authority for the streaming backend. Every rule here reproduces the
// established emitter's output byte-for-byte and is verified against it by the SC_MANGLE replay
// (driver::emit): the old emitter records each replayable render as (pool module, TypeId, symbol)
// and this module must regenerate the identical bytes from the pools alone. Inputs are concrete,
// pool-local types under an empty substitution frame -- resolution happens before naming, never
// inside it. Renders outside the frozen subset refuse (false) instead of guessing.
import ast::ast as *;
import lexer::token as tok;
import module::loader as loader;

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
    /// Substitution stack for per-instance spelling: generic-param decl -> a CONCRETE pool type
    /// (module + TypeId, usually the instance's anchor pool). Innermost binding wins.
    subs: Vector<MSub>,
}

/// One substitution binding: param decl `(pm, pnode)` resolves to pool type `(am, at)`.
pub struct MSub {
    pub pm: ModuleId,
    pub pnode: NodeId,
    pub am: ModuleId,
    pub at: TypeId,
}

extend Mangler as Free {
    pub fn free(self: &mut Self) {
        self.short_ok.free();
        self.subs.free();
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
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    /// Bind a generic param for per-instance spelling; pop with `pop_subs` (LIFO frames).
    pub fn push_sub(self: &mut Self, pm: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) {
        self.subs.push(MSub { pm: pm, pnode: pnode, am: am, at: at });
    }
    pub fn pop_subs(self: &mut Self, n: usize) {
        self.subs.truncate(self.subs.len() - n);
    }

    // Innermost-wins resolution of `(pm, t)` through the substitution stack: TYPE_GENERIC hops to
    // its binding's pool; anything else stays put. Returns false when an unbound param remains.
    pub fn resolve(self: &Self, pm: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        let mut cm = pm;
        let mut ct = t;
        let mut guard = 0;
        while guard < 16 {
            let y = *self.p().module_ast_const(cm).type_at(ct);
            if y.kind != TypeKind::TYPE_GENERIC {
                *rm = cm;
                *rt = ct;
                return true;
            }
            let mut hit = false;
            let mut i = self.subs.len();
            while i > 0 {
                i -= 1;
                let sb = *self.subs.at(i);
                if sb.pm == y.module && sb.pnode == y.as_data.decl {
                    cm = sb.am;
                    ct = sb.at;
                    hit = true;
                    break;
                }
            }
            if !hit {
                return false;
            }
            guard += 1;
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
    pub fn modpfx(self: &mut Self, m: ModuleId, out: &mut String) {
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
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            if self.resolve(pm, t, &mut rm, &mut rt) {
                return self.type_m(rm, rt, out);
            }
            return false; // unbound params never name symbols
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            return false; // const-expr folding under a frame is not frozen yet
        }
        out.push_str("v");
        return true;
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
            if i != 0 {
                params.push_str(", ");
            }
            let mut am2 = y.module;
            let mut at2 = pty;
            if !self.resolve(y.module, pty, &mut am2, &mut at2) {
                am2 = y.module;
                at2 = pty;
            }
            if self.p().module_ast_const(am2).type_at(at2).kind == TypeKind::TYPE_ARRAY {
                params.push_str("const ");
            }
            if !self.ctype(y.module, pty, "", &mut params) {
                ok = false;
                break;
            }
        }
        if !ok {
            params.free();
            return false;
        }
        let mut inner = String::from_str("(*");
        inner.push_str(decl);
        inner.push_str(")(");
        if ps.len == 0 {
            inner.push_str("void");
        } else {
            inner.push_string(&params);
        }
        inner.push_str(")");
        params.free();
        if rs.len == 1 {
            let r0 = unsafe fa.list(rs)[0];
            let rn = fa.at_const(r0);
            let mut rtn = r0;
            if rn.kind == NodeKind::NODE_PARAMETER {
                rtn = rn.as_data.parameter.ty;
            }
            ok = self.ctype(y.module, fa.type_of(rtn), inner.as_str(), out);
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
        inner.free();
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
        return n;
    }

    // Collision-conditional conformance suffix: when several extends of one target define the same
    // method name through different interface instantiations, the symbol carries the interface
    // name and its type arguments. `from`/`try_from` keep the param-derived conv suffix instead.
    fn iface_suffix(self: &mut Self, fm: ModuleId, fnode: NodeId, out: &mut String) bool {
        let a = self.p().module_ast_const(fm);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        let mut ext = NODE_NONE;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let ms = a.at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == fnode {
                    ext = iid;
                    break;
                }
            }
            if ext != NODE_NONE {
                break;
            }
        }
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
        let a = self.p().module_ast_const(m);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let ms = a.at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == fnode {
                    if a.at_const(iid).as_data.extend_def.target_type == NODE_NONE {
                        return DefId { module: m, node: NODE_NONE };
                    }
                    return a.resolution_def(a.at_const(iid).as_data.extend_def.target_type);
                }
            }
        }
        return DefId { module: m, node: NODE_NONE };
    }

    /// Does the extend that owns `fnode` declare generic parameters (its methods emit per receiver
    /// instance, outside the frozen non-generic symbol families)?
    pub fn in_generic_extend(self: &mut Self, m: ModuleId, fnode: NodeId) bool {
        let a = self.p().module_ast_const(m);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_EXTEND {
                continue;
            }
            let ms = a.at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                if unsafe a.list(ms)[j as usize] == fnode {
                    return a.at_const(iid).as_data.extend_def.generics.len != 0;
                }
            }
        }
        return false;
    }

    /// The C symbol of const/static item `cnode` (module `m`) read from a TU of module `em`:
    /// top-level items spell their qualified name; associated consts are per-TU statics prefixed
    /// with the EMITTING module (the established reader/emitter agreement).
    pub fn const_sym(self: &mut Self, em: ModuleId, m: ModuleId, cnode: NodeId, out: &mut String) bool {
        if self.sym_override(m, cnode, out) {
            return true;
        }
        let a = self.p().module_ast_const(m);
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
    pub fn decl_name_span(self: &mut Self, m: ModuleId, decl: NodeId) tok::Span {
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
            nm.free();
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
                inner.free();
                if cp && !(base.len() >= 6 && base.as_str().slice(0, 6) == "const ") {
                    out.push_str("const ");
                }
                out.push_string(&base);
                base.free();
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
                inner.free();
                if !(base.len() >= 6 && base.as_str().slice(0, 6) == "const ") {
                    out.push_str("const ");
                }
                out.push_string(&base);
                base.free();
                return ok;
            }
            let ok = self.ctype(elm, elt, inner.as_str(), out);
            inner.free();
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
            inner.free();
            return ok;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            let mut nm = String::new();
            let ok = self.inst_name(pm, &it, &mut nm);
            if ok {
                self.join_decl(nm.as_str(), decl, out);
            }
            nm.free();
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
            nm.free();
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let fnn = self.p().module_ast_const(y.module).at_const(y.as_data.decl);
            if fnn.kind == NodeKind::NODE_CLOSURE && fnn.as_data.closure.captures.len != 0 {
                let mut nm = String::new();
                self.closure_sym(y.module, y.as_data.decl, &mut nm);
                nm.push_str("_env");
                self.join_decl(nm.as_str(), decl, out);
                nm.free();
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
            }
            nm.free();
            return ok;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            if self.resolve(pm, t, &mut rm, &mut rt) {
                return self.ctype(rm, rt, decl, out);
            }
        }
        // TYPE_NEVER, TYPE_ERROR, unbound TYPE_GENERIC and every remaining kind spell as `void`.
        self.join_decl("void", decl, out);
        return true;
    }

    /// `<Qualified>[__<arg>...]` -- a generic function specialization's symbol; `args` are resolved
    /// concrete pool-`pm` TypeIds.
    pub fn spec_sym(self: &mut Self, pm: ModuleId, f: DefId, args: *const TypeId, n: u8, out: &mut String) bool {
        let fa = self.p().module_ast_const(f.module);
        self.qualified(f.module, fa.at_const(f.node).as_data.function.name, out);
        for i in 0..n {
            out.push_str("__");
            if !self.type_m(pm, unsafe args[i as usize], out) {
                return false;
            }
        }
        return true;
    }

    /// `<Qualified>[__<arg>...]` with trailing prelude-Global (default allocator) args elided:
    /// `String<Global>` -> `String`, `Vector<T, Global>` -> `Vector__T`.
    pub fn inst_name(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
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
        return true;
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
