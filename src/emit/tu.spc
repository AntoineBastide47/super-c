// The streaming backend's declaration layer: aggregate forward typedefs, tag enums, and struct
// bodies in dependency-first order, concrete and per-instance (spelled under the mangler's
// substitution env from each instance's graph anchor pool). Consumes package items + the instance
// graph only -- no resolution, search, or interning at emission time. Constructs outside the
// frozen subset are counted and skipped, never guessed.
import ast::ast as *;
import emit::mangle as mbe;
import consteval::consteval as ce;
import lexer::token_type as tt;
import graph::instances as ig;
import module::loader as loader;

/// One aggregate to define: the declaration plus, for instances, the anchor pool type that binds
/// its generic parameters (`aty == TYPE_NONE` = concrete declaration).
pub struct AggItem {
    pub m: ModuleId,
    pub decl: NodeId,
    pub amod: ModuleId,
    pub aty: TypeId,
}

pub struct TuEmit {
    pub pkg: *const loader::Package,
    pub mg: mbe::Mangler,
    pub out: String,
    /// Every forward typedef, kept apart from `out`: the assembly splices ALL of them ahead of
    /// ALL bodies, so a pointer field may name an aggregate defined later (or replayed late).
    pub fwd2: String,
    pub skipped: u64, // aggregates outside the frozen subset (dyn/env fields, unbound params)
    /// FNVs of closure-env struct names this pass DEFINED (embedded in aggregates): the body
    /// emitter must not define them again.
    pub env_defined: Vector<u64>,
    pub emitted: u64,
    // emission state keyed by the FNV of the mangled type name: 0 absent / 1 in progress / 2 done
    state: Map<u64, u64>,
    fwds: Map<u64, u64>, // forward-typedef'd names (deps discovered mid-DFS need one too)
}

extend TuEmit as Free {
    pub fn free(self: &mut Self) {
        self.mg.free();
        self.out.free();
        self.fwd2.free();
        self.env_defined.free();
        self.state.free();
        self.fwds.free();
    }
}

const fn fnv(s: str) u64 {
    let mut h = 1469598103934665603u64;
    for i in 0..s.len() {
        h = (h ^ s.byte_at(i) as u64) * 1099511628211u64;
    }
    return h;
}

extend TuEmit {
    pub fn new(pkg: *const loader::Package) TuEmit {
        return TuEmit {
            pkg: pkg,
            mg: mbe::Mangler::new(pkg),
            out: String::new(),
            fwd2: String::new(),
            skipped: 0,
            emitted: 0,
            env_defined: Vector::<u64>::new(),
            state: Map::<u64, u64>::new(),
            fwds: Map::<u64, u64>::new(),
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    // Bind the aggregate's generic parameters to the anchor instance's argument types; returns the
    // number of bindings pushed (pop after use), or -1 when the anchor cannot bind them.
    fn bind_item(self: &mut Self, it: &AggItem) i64 {
        if it.aty == TYPE_NONE {
            return 0;
        }
        let aa = self.p().module_ast_const(it.amod);
        let y = *aa.type_at(it.aty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return -1;
        }
        let inst = *aa.instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.m);
        let gens = da.at_const(it.decl).as_data.aggregate.generics;
        if gens.len as u8 > inst.n {
            return -1;
        }
        let mut n: i64 = 0;
        for i in 0..gens.len {
            let gid = unsafe da.list(gens)[i as usize];
            self.mg.push_sub(it.m, gid, it.amod, unsafe inst.args[i as usize]);
            n += 1;
        }
        return n;
    }

    // The mangled C type name of the item (instance names come from the anchor).
    fn item_name(self: &mut Self, it: &AggItem, out: &mut String) bool {
        if it.aty == TYPE_NONE {
            self.mg.qualified(it.m, self.p().module_ast_const(it.m).at_const(it.decl).as_data.aggregate.name, out);
            return true;
        }
        return self.mg.type_m(it.amod, it.aty, out);
    }

    /// Emit `it` (and, first, every by-value aggregate it depends on). False only on cycle
    /// corruption; out-of-subset items count as skipped and emit nothing.
    pub fn emit_agg(self: &mut Self, it: &AggItem) bool {
        let mut nm = String::new();
        if !self.item_name(it, &mut nm) {
            self.skipped += 1;
            return true;
        }
        let key = fnv(nm.as_str());
        let st = switch self.state.get(&key) {
            Some(v) => *v,
            None => 0u64,
        };
        if st != 0 {
            return st != 1; // 1 = in progress: a by-value cycle would be an upstream bug
        }
        self.state.insert(key, 1);
        self.emit_fwd(it);
        let ok = self.emit_agg_body(it, nm.as_str());
        self.state.insert(key, 2);
        return ok;
    }

    fn emit_agg_body(self: &mut Self, it: &AggItem, nm: str) bool {
        let da = self.p().module_ast_const(it.m);
        let n = da.at_const(it.decl);
        let is_enum = n.kind == NodeKind::NODE_ENUM;
        let nb = self.bind_item(it);
        if nb < 0 {
            self.skipped += 1;
            return true;
        }
        let mut body = String::new();
        let mut ok = true;
        if is_enum {
            ok = self.enum_body(it, nm, &mut body);
        } else {
            ok = self.struct_body(it, nm, &mut body);
        }
        self.mg.pop_subs(nb as usize);
        if ok {
            self.out.push_string(&body);
            self.emitted += 1;
        } else {
            self.skipped += 1;
        }
        return true;
    }

    // Emit dependencies of a by-value field type, then spell it. Pointers/references need only the
    // forward typedef (already global), so they never recurse.
    fn field_dep(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let mut rm = pm;
        let mut rt = t;
        if !self.mg.resolve(pm, t, &mut rm, &mut rt) {
            return false;
        }
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let dep = AggItem { m: y.module, decl: y.as_data.decl, amod: rm, aty: TYPE_NONE };
            return self.emit_agg(&dep);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = *a.instance(y.as_data.inst);
            let dep = AggItem { m: inst.module, decl: inst.decl, amod: rm, aty: rt };
            return self.emit_agg(&dep);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.field_dep(rm, y.as_data.arr.elem);
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            // a stored CLOSURE VALUE embeds its env struct: define it here (captures first), and
            // record the name so the body emitter skips its own copy
            let ca = self.p().module_ast_const(y.module);
            let cdn = ca.at_const(y.as_data.decl);
            if cdn.kind == NodeKind::NODE_CLOSURE && cdn.as_data.closure.captures.len != 0 {
                let mut nm = String::new();
                self.mg.closure_sym(y.module, y.as_data.decl, &mut nm);
                nm.push_str("_env");
                let key = fnv(nm.as_str());
                let st = switch self.state.get(&key) {
                    Some(v) => *v,
                    None => 0u64,
                };
                if st != 0 {
                    return st != 1;
                }
                self.state.insert(key, 1);
                self.env_defined.push(key);
                self.fwd2.push_str("typedef struct ");
                self.fwd2.push_str(nm.as_str());
                self.fwd2.push_str(" ");
                self.fwd2.push_str(nm.as_str());
                self.fwd2.push_str(";\n");
                let caps = cdn.as_data.closure.captures;
                let mut body = String::from_str("struct ");
                body.push_str(nm.as_str());
                body.push_str(" { ");
                let mut ok = true;
                for k in 0..caps.len {
                    let cdl = unsafe ca.list(caps)[k as usize];
                    let cty = ca.type_of(cdl);
                    if cty == TYPE_NONE {
                        ok = false;
                        break;
                    }
                    if !self.field_dep(y.module, cty) {
                        ok = false;
                        break;
                    }
                    let csp = self.mg.decl_name_span(y.module, cdl);
                    let mut cnm = String::new();
                    self.mg.ident(y.module, csp, &mut cnm);
                    if !self.mg.ctype(y.module, cty, cnm.as_str(), &mut body) {
                        ok = false;
                        break;
                    }
                    body.push_str("; ");
                }
                body.push_str("};\n");
                if ok {
                    self.out.push_string(&body);
                    self.emitted += 1;
                } else {
                    self.skipped += 1;
                }
                self.state.insert(key, 2);
            }
            return true;
        }
        return true;
    }

    fn struct_body(self: &mut Self, it: &AggItem, nm: str, body: &mut String) bool {
        let da = self.p().module_ast_const(it.m);
        let n = da.at_const(it.decl);
        if n.as_data.aggregate.is_extern {
            return true; // extern aggregates are defined by their backing C header
        }
        let kw = if_str2(n.as_data.aggregate.is_union, "union ", "struct ");
        body.push_str(kw);
        // layout attributes ride the keyword: `struct __attribute__((packed)) X { .. }`
        {
            let dax = unsafe &*self.p().module_ast_const(it.m);
            for k9 in 0..dax.attrs.len() {
                if dax.attrs.at(k9).owner != it.decl {
                    continue;
                }
                if dax.attrs.at(k9).kind == AttrKind::ATTR_PACKED as u8 {
                    body.push_str("__attribute__((packed)) ");
                } else if dax.attrs.at(k9).kind == AttrKind::ATTR_ALIGN as u8 {
                    body.push_str("__attribute__((aligned(");
                    body.push_u64(dax.attrs.at(k9).arg);
                    body.push_str("))) ");
                }
            }
        }
        body.push_str(nm);
        body.push_str(" {\n");
        let ms = n.as_data.aggregate.members;
        for i in 0..ms.len {
            let fid = unsafe da.list(ms)[i as usize];
            if da.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let mut fty = da.type_of(fid);
            if fty == TYPE_NONE {
                fty = da.type_of(da.at_const(fid).as_data.field.ty);
            }
            if fty == TYPE_NONE {
                return false;
            }
            if !self.field_dep(it.m, fty) {
                return false;
            }
            let mut fnm = String::new();
            self.mg.ident(it.m, da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text, &mut fnm);
            body.push_str("  ");
            // a `[T; N]` field interns len-0 in the generic pool (the length is symbolic, and a
            // len-0 array's frozen spelling is a POINTER): recover N from the annotation's length
            // expression under the instance env before the ctype rules see the type
            let mut ok = false;
            let mut done = false;
            let fyv = *da.type_at(fty);
            if fyv.kind == TypeKind::TYPE_ARRAY && fyv.as_data.arr.len == 0 {
                let mut alen: u64 = 0;
                let got9 = self.field_arr_len(it.m, fid, &mut alen);
                if got9 && alen != 0 {
                    let mut d2 = String::from_str(fnm.as_str());
                    d2.push_str("[");
                    d2.push_u64(alen);
                    d2.push_str("]");
                    ok = self.mg.ctype(it.m, fyv.as_data.arr.elem, d2.as_str(), body);
                    done = true;
                }
            }
            if !done {
                ok = self.mg.ctype(it.m, fty, fnm.as_str(), body);
            }
            if !ok {
                return false;
            }
            body.push_str(";\n");
        }
        body.push_str("};\n");
        return true;
    }

    // The concrete length of a generic `[T; N]` field: the annotation's length expression folded
    // under the instance env (its pool type interns len 0, indistinguishable from a real []).
    // Evaluate a symbolic `[T; expr]` length under the instance env: literals, + - * / % << >>
    // arithmetic, and params folded through the substitution stack (`(BITS + 63) / 64` = 2 at
    // BITS=128). The checker interns these fields at len 0, so the value only exists HERE.
    fn eval_len_expr(self: &mut Self, m: ModuleId, id: NodeId, out: &mut i64, depth: u32) bool {
        if depth > 8 {
            return false;
        }
        let da = self.p().module_ast_const(m);
        let n = da.at_const(id);
        if n.kind == NodeKind::NODE_LITERAL {
            let sp = n.span;
            let src = self.p().modules.at(m as usize).source.as_str();
            if sp.end as usize > src.len() || sp.end <= sp.start {
                return false;
            }
            let mut v: i64 = 0;
            let mut i = sp.start as usize;
            let hex = sp.end as usize - i > 2 && src.byte_at(i) == 48 && (src.byte_at(i + 1) | 32) == 120;
            if hex {
                i += 2;
            }
            let mut any = false;
            while i < sp.end as usize {
                let ch = src.byte_at(i);
                if ch == 95 {
                    i += 1;
                    continue;
                }
                let mut d: i64 = 0 - 1;
                if ch >= 48 && ch <= 57 {
                    d = ch as i64 - 48;
                } else if hex && (ch | 32) >= 97 && (ch | 32) <= 102 {
                    d = (ch | 32) as i64 - 87;
                }
                if d < 0 {
                    break; // a width suffix ends the digits
                }
                let base: i64 = if hex {
                    16;
                } else {
                    10;
                };
                v = v * base + d;
                any = true;
                i += 1;
            }
            if !any {
                return false;
            }
            *out = v;
            return true;
        }
        if n.kind == NodeKind::NODE_BINARY {
            let mut lv: i64 = 0;
            let mut rv: i64 = 0;
            if !self.eval_len_expr(m, n.as_data.binary.left, &mut lv, depth + 1) || !self.eval_len_expr(
                m,
                n.as_data.binary.right,
                &mut rv,
                depth + 1,
            ) {
                return false;
            }
            let opn = n.as_data.binary.op;
            if opn == tt::TokenType::Plus {
                *out = lv + rv;
            } else if opn == tt::TokenType::Minus {
                *out = lv - rv;
            } else if opn == tt::TokenType::Star {
                *out = lv * rv;
            } else if opn == tt::TokenType::Slash && rv != 0 {
                *out = lv / rv;
            } else if opn == tt::TokenType::Percent && rv != 0 {
                *out = lv % rv;
            } else if opn == tt::TokenType::LeftShift {
                *out = lv << rv;
            } else if opn == tt::TokenType::RightShift {
                *out = lv >> rv;
            } else {
                return false;
            }
            return true;
        }
        // an identifier naming a generic param folds through the env
        let ld = da.resolution_def(id);
        if ld.node == NODE_NONE || self.p().module_ast_const(ld.module).at_const(ld.node).kind != NodeKind::NODE_GENERIC_PARAM {
            return false;
        }
        let mut k9 = self.mg.subs.len();
        while k9 > 0 {
            k9 -= 1;
            let sb = *self.mg.subs.at(k9);
            if sb.pm != ld.module || sb.pnode != ld.node {
                continue;
            }
            let kl9 = if sb.lim as usize < k9 {
                sb.lim as usize;
            } else {
                k9;
            };
            if self.mg.fold_cval_at(sb.am, sb.at, out, kl9) {
                return true;
            }
        }
        return false;
    }

    fn field_arr_len(self: &mut Self, m: ModuleId, fid: NodeId, len_out: &mut u64) bool {
        let da = self.p().module_ast_const(m);
        let tn = da.at_const(fid).as_data.field.ty;
        if tn == NODE_NONE || da.at_const(tn).kind != NodeKind::NODE_ARRAY_TYPE {
            return false;
        }
        let ln = da.at_const(tn).as_data.array_type.length;
        if ln == NODE_NONE {
            return false;
        }
        // the length expression types as its const type (usize); its RESOLUTION names the
        // param decl, which the instance env binds to a TYPE_CONST (innermost binding wins)
        let ld = da.resolution_def(ln);
        if ld.node != NODE_NONE {
            let mut i9 = self.mg.subs.len();
            while i9 > 0 {
                i9 -= 1;
                let sb = *self.mg.subs.at(i9);
                if sb.pm == ld.module && sb.pnode == ld.node {
                    let by = *self.p().module_ast_const(sb.am).type_at(sb.at);
                    if by.kind == TypeKind::TYPE_CONST && by.as_data.value >= 0 {
                        *len_out = by.as_data.value as u64;
                        return true;
                    }
                    return false;
                }
            }
        }
        let lty = da.type_of(ln);
        if lty == TYPE_NONE || da.type_at(lty).kind == TypeKind::TYPE_BUILTIN {
            // an arithmetic length expression carries no const record: evaluate it under the env
            let mut ev: i64 = 0;
            if self.eval_len_expr(m, ln, &mut ev, 0) && ev > 0 {
                *len_out = ev as u64;
                return true;
            }
            return false;
        }
        if da.type_at(lty).kind == TypeKind::TYPE_GENERIC {
            let mut rm = m;
            let mut rt = lty;
            if self.mg.resolve(m, lty, &mut rm, &mut rt) {
                let ry = *self.p().module_ast_const(rm).type_at(rt);
                if ry.kind == TypeKind::TYPE_CONST && ry.as_data.value >= 0 {
                    *len_out = ry.as_data.value as u64;
                    return true;
                }
            }
            return false;
        }
        if da.type_at(lty).kind == TypeKind::TYPE_CONST {
            let cv = da.type_at(lty).as_data.value;
            if cv >= 0 {
                *len_out = cv as u64;
                return true;
            }
            return false;
        }
        if da.type_at(lty).kind != TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        let mut v: i64 = 0;
        if self.mg.fold_cexpr(m, lty, &mut v) && v >= 0 {
            *len_out = v as u64;
            return true;
        }
        return false;
    }

    fn enum_body(self: &mut Self, it: &AggItem, nm: str, body: &mut String) bool {
        let da = self.p().module_ast_const(it.m);
        let n = da.at_const(it.decl);
        if n.as_data.aggregate.is_extern {
            return true;
        }
        let ms = n.as_data.aggregate.members;
        let mut has_payload = false;
        for i in 0..ms.len {
            let vid = unsafe da.list(ms)[i as usize];
            if da.at_const(vid).kind == NodeKind::NODE_VARIANT && da.at_const(vid).as_data.variant.payload.len != 0 {
                has_payload = true;
            }
        }
        // the tag enum (or the whole payload-less enum) belongs to the GENERIC declaration and is
        // shared by every instance: guard it and spell it from the decl, not the anchor
        let mut q = String::new();
        self.mg.qualified(it.m, n.as_data.aggregate.name, &mut q);
        body.push_str(if_str2(has_payload, "#ifndef SUPER_ENUMTAG_", "#ifndef SUPER_ENUM_"));
        body.push_string(&q);
        body.push_str("\n");
        body.push_str(if_str2(has_payload, "#define SUPER_ENUMTAG_", "#define SUPER_ENUM_"));
        body.push_string(&q);
        body.push_str("\ntypedef enum { ");
        let mut first = true;
        for i in 0..ms.len {
            let vid = unsafe da.list(ms)[i as usize];
            if da.at_const(vid).kind != NodeKind::NODE_VARIANT {
                continue;
            }
            if !first {
                body.push_str(", ");
            }
            first = false;
            self.mg.enum_tag(it.m, it.decl, vid, body);
            // an explicit discriminant pins the C value (`Code_Bad = 404`): casts observe it
            let vv = da.at_const(vid).as_data.variant.value;
            if vv != NODE_NONE && self.p().ceval != null {
                let cevE = unsafe &mut *(self.p().ceval as *mut ce::ConstEval);
                let cvE = cevE.eval(it.m, vv);
                if cvE.kind == ce::CONST_INT {
                    body.push_str(" = ");
                    body.push_i64(cvE.as_data.i);
                }
            }
        }
        body.push_str(" } ");
        body.push_string(&q);
        if has_payload {
            body.push_str("Tag");
        }
        body.push_str(";\n#endif\n");
        if !has_payload {
            return true;
        }
        body.push_str("struct ");
        body.push_str(nm);
        body.push_str(" {\n  ");
        let mut q2 = String::new();
        self.mg.qualified(it.m, n.as_data.aggregate.name, &mut q2);
        body.push_string(&q2);
        body.push_str("Tag tag;\n  union {\n");
        for i in 0..ms.len {
            let vid = unsafe da.list(ms)[i as usize];
            let vn = da.at_const(vid);
            if vn.kind != NodeKind::NODE_VARIANT || vn.as_data.variant.payload.len == 0 {
                continue;
            }
            body.push_str("    struct { ");
            let pl = vn.as_data.variant.payload;
            for k in 0..pl.len {
                let pid = unsafe da.list(pl)[k as usize];
                let mut pty = da.type_of(pid);
                if pty == TYPE_NONE && da.at_const(pid).kind == NodeKind::NODE_FIELD {
                    pty = da.type_of(da.at_const(pid).as_data.field.ty);
                }
                if pty == TYPE_NONE {
                    return false;
                }
                if !self.field_dep(it.m, pty) {
                    return false;
                }
                let mut fnm = String::new();
                if vn.as_data.variant.struct_payload && da.at_const(pid).kind == NodeKind::NODE_FIELD {
                    self.mg.ident(it.m, da.at_const(da.at_const(pid).as_data.field.name).as_data.name.text, &mut fnm);
                } else {
                    fnm.push_str("_");
                    fnm.push_u64(k);
                }
                let ok = self.mg.ctype(it.m, pty, fnm.as_str(), body);

                if !ok {
                    return false;
                }
                body.push_str("; ");
            }
            body.push_str("} ");
            self.mg.ident(it.m, da.at_const(vn.as_data.variant.name).as_data.name.text, body);
            body.push_str(";\n");
        }
        body.push_str("  } payload;\n};\n");
        return true;
    }

    /// Forward-typedef every aggregate name so pointer fields never need definition order.
    pub fn emit_fwd(self: &mut Self, it: &AggItem) {
        let mut nm = String::new();
        if !self.item_name(it, &mut nm) {
            return;
        }
        self.emit_fwd_named(it.m, it.decl, nm.as_str());
    }

    fn emit_fwd_named(self: &mut Self, m: ModuleId, decl: NodeId, nm: str) {
        let da = self.p().module_ast_const(m);
        let n = da.at_const(decl);
        if n.as_data.aggregate.is_extern {
            return;
        }
        let fk = fnv(nm);
        switch self.fwds.get(&fk) {
            Some(_v) => {
                return;
            },
            None => {},
        };
        self.fwds.insert(fk, 1);
        if n.kind == NodeKind::NODE_ENUM {
            // payload-less enums typedef in their own guarded block; payload enums fwd as structs
            let ms = n.as_data.aggregate.members;
            let mut has_payload = false;
            for i in 0..ms.len {
                let vid = unsafe da.list(ms)[i as usize];
                if da.at_const(vid).kind == NodeKind::NODE_VARIANT && da.at_const(vid).as_data.variant.payload.len != 0 {
                    has_payload = true;
                }
            }
            if !has_payload {
                return;
            }
        }
        let kw = if_str2(n.kind != NodeKind::NODE_ENUM && n.as_data.aggregate.is_union, "union", "struct");
        self.fwd2.push_str("typedef ");
        self.fwd2.push_str(kw);
        self.fwd2.push_str(" ");
        self.fwd2.push_str(nm);
        self.fwd2.push_str(" ");
        self.fwd2.push_str(nm);
        self.fwd2.push_str(";\n");
    }

    /// Define an instance aggregate first named by a demand-driven body: no anchor TypeId exists,
    /// so the generics bind straight from the descriptor before the usual dependency DFS.
    /// Mark an env-struct name (FNV) as defined; `env_done` queries it.
    pub fn mark_env_done(self: &mut Self, h: u64) {
        self.state.insert(h, 2);
    }
    pub fn env_done(self: &Self, h: u64) bool {
        return switch self.state.get(&h) {
            Some(v) => *v == 2,
            None => false,
        };
    }

    pub fn emit_agg_inst(self: &mut Self, pm: ModuleId, inst0: TyInstance) bool {
        let inst = &inst0;
        let mut nm = String::new();
        if !self.mg.inst_name(pm, inst, &mut nm) {
            self.skipped += 1;
            return true;
        }
        let key = fnv(nm.as_str());
        let st = switch self.state.get(&key) {
            Some(v) => *v,
            None => 0u64,
        };
        if st != 0 {
            return st != 1;
        }
        let da = self.p().module_ast_const(inst.module);
        let n = da.at_const(inst.decl);
        let gens = n.as_data.aggregate.generics;
        if gens.len as u8 > inst.n {
            self.skipped += 1;
            return true;
        }
        self.state.insert(key, 1);
        self.emit_fwd_named(inst.module, inst.decl, nm.as_str());
        let mut nb: usize = 0;
        for i in 0..gens.len {
            let gid = unsafe da.list(gens)[i as usize];
            self.mg.push_sub(inst.module, gid, pm, unsafe inst.args[i as usize]);
            nb += 1;
        }
        let it = AggItem { m: inst.module, decl: inst.decl, amod: pm, aty: TYPE_NONE };
        let mut body = String::new();
        let ok = if n.kind == NodeKind::NODE_ENUM {
            self.enum_body(&it, nm.as_str(), &mut body);
        } else {
            self.struct_body(&it, nm.as_str(), &mut body);
        };
        self.mg.pop_subs(nb);
        if ok {
            self.out.push_string(&body);
            self.emitted += 1;
        } else {
            self.skipped += 1;
        }
        self.state.insert(key, 2);
        return true;
    }
}

const fn if_str2(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
