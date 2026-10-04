// The streaming backend's declaration layer: aggregate forward typedefs, tag enums, and struct
// bodies in dependency-first order, concrete and per-instance (spelled under the mangler's
// substitution env from each instance's graph anchor pool). Consumes package items + the instance
// graph only: no resolution, search, or interning at emission time. Constructs outside the
// frozen subset are counted and skipped, never guessed.
import ast::ast as *;
import emit::mangle as mbe;
import ir::interp as iri;
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

/// Declaration-layer emitter state for one TU; `out` collects the bodies, `fwd` the forward typedefs.
pub struct TuEmit {
    pub pkg: *const loader::Package,
    pub mg: mbe::Mangler,
    pub out: String,
    /// Every forward typedef, kept apart from `out`: the assembly puts each one ahead of the
    /// body in the definition header of its aggregate and copies it into every other file that
    /// spells it, so a pointer field may name an aggregate defined later (or replayed late).
    pub fwd2: String,
    pub skipped: u64, // aggregates outside the frozen subset (dyn/env fields, unbound params)
    /// FNVs of closure-env struct names this pass DEFINED (embedded in aggregates): the body
    /// emitter must not define them again.
    pub env_defined: Vector<u64>,
    pub emitted: u64,
    /// Every definition chunk of `out` in order: its start offset, its owner module (the
    /// declaring module; a generic instance's is the generic's), whether it is a payload-less
    /// enum, which prototypes need complete: the assembly copies it into every other header
    /// that spells it (its include guard makes the copies one definition), and the C name it
    /// defines (`chunk_name[chunk_name_end[i-1]..chunk_name_end[i]]`).
    pub chunk_off: Vector<u32>,
    pub chunk_own: Vector<ModuleId>,
    pub chunk_enum: Vector<bool>,
    pub chunk_name: String,
    pub chunk_name_end: Vector<u32>,
    // Emission state keyed by the FNV of the mangled type name: 0 absent / 1 in progress / 2 done.
    state: Map<u64, u64>,
    fwds: Map<u64, u64>, // forward-typedef'd names (deps discovered mid-DFS need one too)
    // Per module, the layout attributes by owner, indexed on the module's first query:
    // (module << 32 | owner) -> the `@c.align` value << 1 | packed.
    lay_built: Vector<bool>,
    lay_attrs: Map<u64, u64>,
}

extend TuEmit {
    /// An emitter over `pkg` (which must outlive it) with empty buffers.
    pub fn new(pkg: *const loader::Package) TuEmit {
        return TuEmit {
            pkg: pkg,
            mg: mbe::Mangler::new(pkg),
            out: String::new(),
            fwd2: String::new(),
            skipped: 0,
            emitted: 0,
            chunk_off: Vector::<u32>::new(),
            chunk_own: Vector::<ModuleId>::new(),
            chunk_enum: Vector::<bool>::new(),
            chunk_name: String::new(),
            chunk_name_end: Vector::<u32>::new(),
            env_defined: Vector::<u64>::new(),
            state: Map::<u64, u64>::new(),
            fwds: Map::<u64, u64>::new(),
            lay_built: Vector::<bool>::new(),
            lay_attrs: Map::<u64, u64>::new(),
        };
    }

    // Append one finished definition body of C name `nm` as a chunk of `out` owned by `own`.
    fn push_chunk(self: &mut Self, body: &String, nm: str, own: ModuleId, is_enum: bool) {
        if body.len() == 0 {
            return;
        }
        self.chunk_off.push(self.out.len() as u32);
        self.chunk_own.push(own);
        self.chunk_enum.push(is_enum);
        self.chunk_name.push_str(nm);
        self.chunk_name_end.push(self.chunk_name.len() as u32);
        self.out.push_string(body);
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
        let y = *unsafe (*aa).type_at(it.aty);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return -1;
        }
        let inst = *unsafe (*aa).instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.m);
        let gens = unsafe (*da).at_const(it.decl).as_data.aggregate.generics;
        if gens.len as u8 > inst.n {
            return -1;
        }
        return self.mg.push_generics(it.m, gens, it.amod, &inst) as i64;
    }

    // The mangled C type name of the item (instance names come from the anchor).
    fn item_name(self: &mut Self, it: &AggItem, out: &mut String) bool {
        if it.aty == TYPE_NONE {
            self.mg.qualified(
                it.m,
                unsafe (*self.p().module_ast_const(it.m)).at_const(it.decl).as_data.aggregate.name,
                out,
            );
            return true;
        }
        return self.mg.type_name(it.amod, it.aty, out);
    }

    /// Emit `it` (and, first, every by-value aggregate it depends on). False only on cycle
    /// corruption; out-of-subset items count as skipped and emit nothing.
    pub fn emit_agg(self: &mut Self, it: &AggItem) bool {
        let mut nm = String::new();
        if !self.item_name(it, &mut nm) {
            self.skipped += 1;
            return true;
        }
        let key = nm.as_str().hash();
        let st = switch self.state.get(&key) {
            Some(v) => *v,
            None => 0u64,
        };
        if st != 0 {
            // 1 = in progress: a by-value cycle would be an upstream bug.
            return st != 1;
        }
        self.state.insert(key, 1);
        self.emit_fwd(it);
        let nb = self.bind_item(it);
        if nb < 0 {
            self.skipped += 1;
        } else {
            self.agg_chunk(it, nm.as_str(), nb as usize);
        }
        self.state.insert(key, 2);
        return true;
    }

    // Render the chunk of `it` with its generics bound (`nb` bindings, popped here) and define it,
    // owned by the declaring module (a generic instance's: the generic's); a body that leaves the
    // subset counts as skipped.
    fn agg_chunk(self: &mut Self, it: &AggItem, nm: str, nb: usize) {
        let da = self.p().module_ast_const(it.m);
        let is_enum = unsafe (*da).at_const(it.decl).kind == NodeKind::NODE_ENUM;
        let mut body = String::new();
        let ok = if is_enum {
            self.enum_body(it, nm, &mut body);
        } else {
            self.struct_body(it, nm, &mut body);
        };
        self.mg.pop_subs(nb);
        if !ok {
            self.skipped += 1;
            return;
        }
        self.finish_chunk(&body, nm, it.m, is_enum && !unsafe (*da).enum_has_payload(it.decl));
    }

    // Define the finished chunk `body` of C name `nm`, owned by `own`.
    fn finish_chunk(self: &mut Self, body: &String, nm: str, own: ModuleId, is_enum: bool) {
        self.push_chunk(body, nm, own, is_enum);
        self.emitted += 1;
    }

    /// Emit dependencies of a by-value field type, then spell it. Pointers/references need only the
    /// forward typedef (the assembly gives it to every header that spells it), so they never recurse. Descriptor data also calls it for the
    /// aggregates it names (`FieldInfo`, `MetaInfo`, ...) that no live body reaches.
    pub fn field_dep(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let mut rm = pm;
        let mut rt = t;
        if !self.mg.resolve(pm, t, &mut rm, &mut rt) {
            return false;
        }
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let dep = AggItem { m: y.module, decl: y.as_data.decl, amod: rm, aty: TYPE_NONE };
            return self.emit_agg(&dep);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let inst = *unsafe (*a).instance(y.as_data.inst);
            let dep = AggItem { m: inst.module, decl: inst.decl, amod: rm, aty: rt };
            return self.emit_agg(&dep);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.field_dep(rm, y.as_data.arr.elem);
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            // A pointer field needs only the pointee's forward typedef, which exists once the
            // pointee is defined anywhere; a pointee nothing defines (descriptor data pointing at
            // never-instantiated metadata) still gets its typedef.
            let mut em2 = rm;
            let mut et2 = y.as_data.elem;
            if self.mg.resolve(rm, y.as_data.elem, &mut em2, &mut et2) {
                let e = *unsafe (*self.p().module_ast_const(em2)).type_at(et2);
                if e.kind == TypeKind::TYPE_STRUCT || e.kind == TypeKind::TYPE_ENUM {
                    self.emit_fwd(&AggItem { m: e.module, decl: e.as_data.decl, amod: em2, aty: TYPE_NONE });
                } else if e.kind == TypeKind::TYPE_INSTANCE {
                    let inst = *unsafe (*self.p().module_ast_const(em2)).instance(e.as_data.inst);
                    self.emit_fwd(&AggItem { m: inst.module, decl: inst.decl, amod: em2, aty: et2 });
                }
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            // A stored CLOSURE VALUE embeds its env struct: define it here (captures first), and
            // record the name so the body emitter skips its own copy.
            let ca = self.p().module_ast_const(y.module);
            let cf = unsafe (*ca).closure_fact(y.as_data.decl);
            if cf != null && unsafe (&*cf).ncaps != 0 {
                let mut nm = String::new();
                self.mg.closure_sym(y.module, y.as_data.decl, &mut nm);
                nm.push_str("_env");
                let key = nm.as_str().hash();
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
                let mut body = String::from_str("struct ");
                body.push_str(nm.as_str());
                body.push_str(" { ");
                let mut ok = true;
                let mut cmat: usize = 0;
                for k in 0..unsafe (&*cf).ncaps {
                    let cty = unsafe (*ca).caps_of(cf)[k as usize].ty;
                    if cty == TYPE_NONE {
                        ok = false;
                        break;
                    }
                    if self.mg.is_zst(y.module, cty) {
                        // Zero-sized captures take no env storage (reads are erased).
                        continue;
                    }
                    cmat += 1;
                    if !self.field_dep(y.module, cty) {
                        ok = false;
                        break;
                    }
                    let csp = unsafe (*ca).caps_of(cf)[k as usize].name;
                    let mut cnm = String::new();
                    self.mg.ident(y.module, csp, &mut cnm);
                    if !self.mg.ctype(y.module, cty, cnm.as_str(), &mut body) {
                        ok = false;
                        break;
                    }
                    body.push_str("; ");
                }
                if cmat == 0 {
                    // Every capture is zero-sized: C cannot define an empty struct, so keep ONE
                    // byte; the env is a compiler-internal carrier with no semantic layout, and
                    // the body emitter must still pass a real env pointer for the captured drops.
                    body.push_str("unsigned char _sc_zenv; ");
                }
                body.push_str("};\n");
                if ok {
                    self.finish_chunk(&body, nm.as_str(), y.module, false);
                } else {
                    self.skipped += 1;
                }
                self.state.insert(key, 2);
            }
            return true;
        }
        return true;
    }

    // The layout attributes of declaration `decl` in module `m`: the `@c.align` value
    // (0 when none) << 1 | whether it is `@c.packed`.
    fn layout_attrs(self: &mut Self, m: ModuleId, decl: NodeId) u64 {
        if self.lay_built.len() == 0 {
            self.lay_built.resize_default(self.p().modules.len());
        }
        if !self.lay_built[m as usize] {
            self.lay_built.set(m as usize, true);
            let a = unsafe &*self.p().module_ast_const(m);
            for i in 0..a.attrs.len() {
                let at = a.attrs.at(i);
                let packed = at.kind == AttrKind::ATTR_PACKED as u8;
                if !packed && at.kind != AttrKind::ATTR_ALIGN as u8 {
                    continue;
                }
                let k = m as u64 << 32 | at.owner as u64;
                let mut al = at.arg as u64;
                if !packed && at.expr {
                    // Unevaluated only on an owner the platform filter removed: it never emits.
                    let av = a.attr_value(at.owner, AttrKind::ATTR_ALIGN);
                    if !av.ok {
                        continue;
                    }
                    al = av.v;
                }
                let old = switch self.lay_attrs.get(&k) {
                    Some(v) => *v,
                    None => 0u64,
                };
                self.lay_attrs.insert(
                    k,
                    if packed {
                        old | 1;
                    } else {
                        al << 1 | old & 1;
                    },
                );
            }
        }
        return switch self.lay_attrs.get(&(m as u64 << 32 | decl as u64)) {
            Some(v) => *v,
            None => 0u64,
        };
    }

    fn struct_body(self: &mut Self, it: &AggItem, nm: str, body: &mut String) bool {
        let da = self.p().module_ast_const(it.m);
        let n = unsafe (*da).at_const(it.decl);
        if n.as_data.aggregate.is_extern {
            // Extern aggregates are defined by their backing C header.
            return true;
        }
        let is_union = n.as_data.aggregate.is_union;
        let is_tuple = n.as_data.aggregate.is_tuple;
        let ms = n.as_data.aggregate.members;
        let la = self.layout_attrs(it.m, it.decl);
        let packed = (la & 1) != 0;
        let align_attr = la >> 1;
        // Field plan: a zero-sized field takes no C member (storage is a function of final layout,
        // and strict C11 has no zero-sized object). `keep`: 1 = stored, 0 = elided, 2 = not a
        // field node. A struct with no stored field is itself zero-sized: no C definition exists
        // (its forward typedef still supports pointers). Elided fields with alignment > 1 can
        // shift the semantic offsets flat elision produces, so that rare case takes a dual layout
        // walk and, on mismatch, explicit padding members (packed layouts ignore alignment, so
        // they can never diverge).
        let mut keep = Vector::<u8>::new();
        let mut mat: usize = 0;
        let mut zalign_hi = false;
        for i in 0..ms.len {
            let fid = unsafe (*da).list(ms)[i as usize];
            // Tuple members are bare type nodes named positionally `_i`; named members are NODE_FIELD.
            if !is_tuple && unsafe (*da).at_const(fid).kind != NodeKind::NODE_FIELD {
                keep.push(2);
                continue;
            }
            let fty = unsafe (*da).member_ty(fid);
            if fty == TYPE_NONE {
                return false;
            }
            // A void-typed member (a generic instantiated at `void`) has no storage either: every read
            // and write of it is erased, so its definition is too.
            if self.mg.is_zst(it.m, fty) || (self.mg.zclass(it.m, fty) & 4) != 0 {
                keep.push(0);
                if !packed && !zalign_hi {
                    let lo9 = self.mg.layout_sub(it.m, fty);
                    zalign_hi = lo9.ok && lo9.align > 1;
                }
            } else {
                keep.push(1);
                mat += 1;
            }
        }
        if mat == 0 {
            // The aggregate is zero-sized: forward typedef only, no definition.
            return true;
        }
        let mut pads = Vector::<u64>::new(); // per-member leading pad bytes (dual-walk mismatch only)
        let mut tail_pad: u64 = 0;
        let mut force_align: u64 = 0;
        if zalign_hi && !self.zst_pad_plan(it, &keep, is_union, align_attr, &mut pads, &mut tail_pad, &mut force_align) {
            // Over-aligned elided field with an unlayoutable sibling: no safe C shape.
            return false;
        }
        let kw = mbe::if_s(is_union, "union ", "struct ");
        body.push_str(kw);
        // layout attributes ride the keyword: `struct __attribute__((packed)) X { .. }`.
        if packed {
            body.push_str("__attribute__((packed)) ");
        }
        if align_attr != 0 {
            body.push_str("__attribute__((aligned(");
            body.push_u64(align_attr);
            body.push_str("))) ");
        }
        body.push_str(nm);
        body.push_str(" {\n");
        let mut mi: usize = 0; // stored-member ordinal (pad plan indexes stored members)
        for i in 0..ms.len {
            if keep[i as usize] != 1 {
                continue;
            }
            let fid = unsafe (*da).list(ms)[i as usize];
            let fty = unsafe (*da).member_ty(fid);
            if !self.field_dep(it.m, fty) {
                return false;
            }
            if mi < pads.len() && pads[mi] != 0 {
                body.push_str("  unsigned char _sc_pad");
                body.push_u64(mi as u64);
                body.push_str("[");
                body.push_u64(pads[mi]);
                body.push_str("];\n");
            }
            let mut fnm = String::new();
            if is_tuple {
                fnm.push_str("_");
                fnm.push_u64(i);
            } else {
                self.mg.ident(
                    it.m,
                    unsafe (*da).at_const(unsafe (*da).at_const(fid).as_data.field.name).as_data.name.text,
                    &mut fnm,
                );
            }
            body.push_str("  ");
            if mi == 0 && force_align != 0 {
                body.push_str("_Alignas(");
                body.push_u64(force_align);
                body.push_str(") ");
            }
            if !self.mg.ctype(it.m, fty, fnm.as_str(), body) {
                return false;
            }
            body.push_str(";\n");
            mi += 1;
        }
        if tail_pad != 0 {
            body.push_str("  unsigned char _sc_padt[");
            body.push_u64(tail_pad);
            body.push_str("];\n");
        }
        body.push_str("};\n");
        return true;
    }

    // Dual layout walk for the rare shape where an ELIDED field has alignment > 1: compare the
    // semantic offsets (all fields) against the natural C offsets of the stored fields alone.
    // On divergence, produce leading pads per stored member, a tail pad, and a forced alignment
    // so the flat C struct reproduces the semantic layout exactly. False = a sibling field has
    // no layout, so the shape cannot be validated.
    fn zst_pad_plan(
        self: &mut Self,
        it: &AggItem,
        keep: &Vector<u8>,
        is_union: bool,
        align_attr: u64,
        pads: &mut Vector<u64>,
        tail_pad: &mut u64,
        force_align: &mut u64,
    ) bool {
        let da = self.p().module_ast_const(it.m);
        let ms = unsafe (*da).at_const(it.decl).as_data.aggregate.members;
        let mut soff: u64 = 0; // semantic running offset (all fields)
        let mut moff: u64 = 0; // natural C offset (stored fields only)
        let mut samax: u64 = 1;
        let mut mamax: u64 = 1;
        let mut ssize: u64 = 0; // union: max member size
        let mut msize: u64 = 0;
        let mut diverged = false;
        for i in 0..ms.len {
            if keep[i as usize] == 2 {
                continue;
            }
            let fid = unsafe (*da).list(ms)[i as usize];
            let fty = unsafe (*da).member_ty(fid);
            let lo = self.mg.layout_sub(it.m, fty);
            if !lo.ok {
                return false;
            }
            if is_union {
                if lo.size > ssize {
                    ssize = lo.size;
                }
                if lo.align > samax {
                    samax = lo.align;
                }
                if keep[i as usize] == 1 {
                    if lo.size > msize {
                        msize = lo.size;
                    }
                    if lo.align > mamax {
                        mamax = lo.align;
                    }
                }
                continue;
            }
            soff = (soff + lo.align - 1) / lo.align * lo.align;
            if keep[i as usize] == 1 {
                moff = (moff + lo.align - 1) / lo.align * lo.align;
                if moff != soff {
                    diverged = true;
                    pads.push(soff - moff);
                    moff = soff;
                } else {
                    pads.push(0);
                }
                moff += lo.size;
                if lo.align > mamax {
                    mamax = lo.align;
                }
            }
            soff += lo.size;
            if lo.align > samax {
                samax = lo.align;
            }
        }
        if align_attr > samax {
            samax = align_attr;
        }
        if align_attr > mamax {
            mamax = align_attr;
        }
        if is_union {
            soff = ssize;
            moff = msize;
        }
        let stotal = (soff + samax - 1) / samax * samax;
        let mtotal = (moff + mamax - 1) / mamax * mamax;
        if !diverged && stotal == mtotal && samax == mamax {
            // The elided fields never moved anything: flat emission.
            pads.truncate(0);
            return true;
        }
        // With per-member pads the stored fields already sit at their semantic offsets (moff ends
        // equal to the last stored field's semantic end); an explicit tail brings the total to the
        // semantic size, and _Alignas on the first member pins the aggregate alignment.
        *force_align = samax;
        if is_union {
            // A union member must span the FULL semantic size by itself.
            *tail_pad = stotal;
        } else if stotal > moff {
            *tail_pad = stotal - moff;
        }
        return true;
    }

    fn enum_body(self: &mut Self, it: &AggItem, nm: str, body: &mut String) bool {
        let da = self.p().module_ast_const(it.m);
        let n = unsafe (*da).at_const(it.decl);
        if n.as_data.aggregate.is_extern {
            return true;
        }
        let ms = n.as_data.aggregate.members;
        let has_payload = unsafe (*da).enum_has_payload(it.decl);
        // The tag enum (or the whole payload-less enum) belongs to the GENERIC declaration and is
        // shared by every instance: guard it and spell it from the decl, not the anchor.
        let mut q = String::new();
        self.mg.qualified(it.m, n.as_data.aggregate.name, &mut q);
        body.push_str(mbe::if_s(has_payload, "#ifndef SUPER_ENUMTAG_", "#ifndef SUPER_ENUM_"));
        body.push_string(&q);
        body.push_str("\n");
        body.push_str(mbe::if_s(has_payload, "#define SUPER_ENUMTAG_", "#define SUPER_ENUM_"));
        body.push_string(&q);
        body.push_str("\ntypedef enum { ");
        let mut first = true;
        let mut cur: i64 = 0 - 1;
        for i in 0..ms.len {
            let vid = unsafe (*da).list(ms)[i as usize];
            if unsafe (*da).at_const(vid).kind != NodeKind::NODE_VARIANT {
                continue;
            }
            if !first {
                body.push_str(", ");
            }
            first = false;
            self.mg.enum_tag(it.m, it.decl, vid, body);
            // an explicit discriminant pins the C value (`Code_Bad = 404`): casts, tag tests and
            // switches observe it
            if unsafe (*da).at_const(vid).as_data.variant.value == NODE_NONE {
                cur += 1;
                continue;
            }
            let cev = self.p().cir as *mut iri::Interp;
            if cev == null || !unsafe (*cev).discr(it.m, vid, cur, &mut cur) {
                return false;
            }
            body.push_str(" = ");
            body.push_i64(cur);
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
        if unsafe (*da).enum_tag_is_byte(it.decl) {
            body.push_str("uint8_t tag;\n");
        } else {
            body.push_string(&q);
            body.push_str("Tag tag;\n");
        }
        // The payload union is buffered: when EVERY variant payload is zero-sized the union has no
        // members, and an empty union is not C; the enum then defines as `{ Tag tag; }` alone.
        let hold = body.len();
        body.push_str("  union {\n");
        let mut upay: usize = 0; // union members emitted (all-ZST variants take none)
        for i in 0..ms.len {
            let vid = unsafe (*da).list(ms)[i as usize];
            let vn = unsafe (*da).at_const(vid);
            if vn.kind != NodeKind::NODE_VARIANT || vn.as_data.variant.payload.len == 0 {
                continue;
            }
            let pl = vn.as_data.variant.payload;
            // Zero-sized payload members take no C storage; a variant with ONLY zero-sized payload
            // takes no union member at all (its accesses are erased with it).
            let mut vmat: usize = 0;
            for k in 0..pl.len {
                let pid = unsafe (*da).list(pl)[k as usize];
                let pty = unsafe (*da).member_ty(pid);
                if pty == TYPE_NONE {
                    return false;
                }
                if !self.mg.is_zst(it.m, pty) {
                    vmat += 1;
                }
            }
            if vmat == 0 {
                continue;
            }
            upay += 1;
            body.push_str("    struct { ");
            for k in 0..pl.len {
                let pid = unsafe (*da).list(pl)[k as usize];
                let pty = unsafe (*da).member_ty(pid);
                if self.mg.is_zst(it.m, pty) {
                    continue;
                }
                if !self.field_dep(it.m, pty) {
                    return false;
                }
                let mut fnm = String::new();
                if vn.as_data.variant.struct_payload && unsafe (*da).at_const(pid).kind == NodeKind::NODE_FIELD {
                    self.mg.ident(
                        it.m,
                        unsafe (*da).at_const(unsafe (*da).at_const(pid).as_data.field.name).as_data.name.text,
                        &mut fnm,
                    );
                } else {
                    fnm.push_str("_");
                    fnm.push_u64(k);
                }
                if !self.mg.ctype(it.m, pty, fnm.as_str(), body) {
                    return false;
                }
                body.push_str("; ");
            }
            body.push_str("} ");
            self.mg.ident(it.m, unsafe (*da).at_const(vn.as_data.variant.name).as_data.name.text, body);
            body.push_str(";\n");
        }
        if upay == 0 {
            body.truncate(hold);
            body.push_str("};\n");
            return true;
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
        let n = unsafe (*da).at_const(decl);
        if n.as_data.aggregate.is_extern {
            return;
        }
        let fk = nm.hash();
        switch self.fwds.get(&fk) {
            Some(_v) => {
                return;
            },
            None => {},
        };
        self.fwds.insert(fk, 1);
        if n.kind == NodeKind::NODE_ENUM {
            // Payload-less enums typedef in their own guarded block; payload enums fwd as structs.
            if !unsafe (*da).enum_has_payload(decl) {
                return;
            }
        }
        let kw = mbe::if_s(n.kind != NodeKind::NODE_ENUM && n.as_data.aggregate.is_union, "union", "struct");
        self.fwd2.push_str("typedef ");
        self.fwd2.push_str(kw);
        self.fwd2.push_str(" ");
        self.fwd2.push_str(nm);
        self.fwd2.push_str(" ");
        self.fwd2.push_str(nm);
        self.fwd2.push_str(";\n");
    }

    /// Mark an env-struct name (FNV) as defined; `env_done` queries it.
    pub fn mark_env_done(self: &mut Self, h: u64) {
        self.state.insert(h, 2);
    }
    /// True once mark_env_done recorded `h`.
    pub fn env_done(self: &Self, h: u64) bool {
        return switch self.state.get(&h) {
            Some(v) => *v == 2,
            None => false,
        };
    }

    /// Define an instance aggregate first named by a demand-driven body: no anchor TypeId exists,
    /// so the generics bind straight from the descriptor before the usual dependency DFS.
    pub fn emit_agg_inst(self: &mut Self, pm: ModuleId, inst0: TyInstance) bool {
        let inst = &inst0;
        let mut nm = String::new();
        if !self.mg.inst_type_name(pm, inst, &mut nm) {
            self.skipped += 1;
            return true;
        }
        let key = nm.as_str().hash();
        let st = switch self.state.get(&key) {
            Some(v) => *v,
            None => 0u64,
        };
        if st != 0 {
            return st != 1;
        }
        let gens = unsafe (*self.p().module_ast_const(inst.module)).at_const(inst.decl).as_data.aggregate.generics;
        if gens.len as u8 > inst.n {
            self.skipped += 1;
            return true;
        }
        self.state.insert(key, 1);
        self.emit_fwd_named(inst.module, inst.decl, nm.as_str());
        let nb = self.mg.push_generics(inst.module, gens, pm, inst);
        let it = AggItem { m: inst.module, decl: inst.decl, amod: pm, aty: TYPE_NONE };
        self.agg_chunk(&it, nm.as_str(), nb);
        self.state.insert(key, 2);
        return true;
    }
}
