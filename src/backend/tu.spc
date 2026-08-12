// The streaming backend's declaration layer: aggregate forward typedefs, tag enums, and struct
// bodies in dependency-first order, concrete and per-instance (spelled under the mangler's
// substitution env from each instance's graph anchor pool). Consumes package items + the instance
// graph only -- no resolution, search, or interning at emission time. Constructs outside the
// frozen subset are counted and skipped, never guessed.
import ast::ast as *;
import backend::mangle as mbe;
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
    pub skipped: u64, // aggregates outside the frozen subset (dyn/env fields, unbound params)
    pub emitted: u64,
    // emission state keyed by the FNV of the mangled type name: 0 absent / 1 in progress / 2 done
    state: Map<u64, u64>,
    fwds: Map<u64, u64>, // forward-typedef'd names (deps discovered mid-DFS need one too)
}

extend TuEmit as Free {
    pub fn free(self: &mut Self) {
        self.mg.free();
        self.out.free();
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
            skipped: 0,
            emitted: 0,
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
            nm.free();
            self.skipped += 1;
            return true;
        }
        let key = fnv(nm.as_str());
        let st = switch self.state.get(&key) {
            Some(v) => *v,
            None => 0u64,
        };
        if st != 0 {
            nm.free();
            return st != 1; // 1 = in progress: a by-value cycle would be an upstream bug
        }
        self.state.insert(key, 1);
        self.emit_fwd(it);
        let ok = self.emit_agg_body(it, nm.as_str());
        self.state.insert(key, 2);
        nm.free();
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
        body.free();
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
            let ok = self.mg.ctype(it.m, fty, fnm.as_str(), body);
            fnm.free();
            if !ok {
                return false;
            }
            body.push_str(";\n");
        }
        body.push_str("};\n");
        return true;
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
        }
        body.push_str(" } ");
        body.push_string(&q);
        if has_payload {
            body.push_str("Tag");
        }
        body.push_str(";\n#endif\n");
        q.free();
        if !has_payload {
            return true;
        }
        body.push_str("struct ");
        body.push_str(nm);
        body.push_str(" {\n  ");
        let mut q2 = String::new();
        self.mg.qualified(it.m, n.as_data.aggregate.name, &mut q2);
        body.push_string(&q2);
        q2.free();
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
                fnm.free();
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
        let da = self.p().module_ast_const(it.m);
        let n = da.at_const(it.decl);
        if n.as_data.aggregate.is_extern {
            return;
        }
        let mut nm = String::new();
        if !self.item_name(it, &mut nm) {
            nm.free();
            return;
        }
        let fk = fnv(nm.as_str());
        switch self.fwds.get(&fk) {
            Some(_v) => {
                nm.free();
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
                nm.free();
                return;
            }
        }
        let kw = if_str2(n.kind != NodeKind::NODE_ENUM && n.as_data.aggregate.is_union, "union", "struct");
        self.out.push_str("typedef ");
        self.out.push_str(kw);
        self.out.push_str(" ");
        self.out.push_string(&nm);
        self.out.push_str(" ");
        self.out.push_string(&nm);
        self.out.push_str(";\n");
        nm.free();
    }
}

const fn if_str2(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
