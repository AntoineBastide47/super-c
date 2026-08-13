// The streaming C backend's function emitter: one verified Core body at a time into one reusable
// buffer, strict C11 portable output -- explicit temporaries, no GNU statement expressions, no
// `__auto_type`. Locals spell as their stable `LocalId` (`_N`), blocks as `BlockId` labels
// (`bb_N`), so two serial runs are byte-identical by construction. Types and symbols come from the
// frozen mangler (backend::mangle); the emitter consumes ONLY Core IR and pool reads for spelling:
// it never resolves overloads, searches extends at emission time, infers, interns, or evaluates
// syntax. Bodies outside the currently emittable subset refuse with a reason instead of guessing.
import ast::ast as *;
import backend::mangle as mbe;
import ir::core as ir;
import lexer::token_type as tt;
import module::loader as loader;

pub struct CEmit {
    pub pkg: *const loader::Package,
    pub out: String, // the reusable output buffer (caller-owned lifecycle, cleared per TU)
    pub err: str<'static>, // first unsupported-construct reason ("" = ok)
    pub mg: mbe::Mangler,
    /// Demand-driven monomorphization: when collecting, every per-instance callee this emitter
    /// spells is queued with its SYMBOL and the substitution chain that spelled it, so a driver
    /// can drain the queue to the closed instance set (the propagation the old emitter computed).
    pub collect_demand: bool,
    pub demand: Vector<Demand>,
    // Closure env bridge: Core IR closure bodies take captures as TRAILING arg locals, but the C
    // ABI passes one env pointer -- locals >= cap_base spell `__env-><name>`. 0 = off.
    cap_base: u32,
    cap_names: Vector<String>,
    /// Out-of-line declarations a body needs BEFORE itself (its `_ret` struct); caller-cleared.
    pub aux: String,
    /// `extern <decl>;` stubs for every static/const item bodies reference (fusion-TU gate).
    pub stat_decls: String,
    stat_seen: Map<u64, u64>,
    /// The referenced items themselves (the definition pass folds each into `<T> <sym> = <v>;`).
    pub stat_items: Vector<StatRef>,
    /// Derived destructor worklist: every `__free__d` symbol bodies referenced, with the resolved
    /// type it destroys (the glue pass emits their definitions, recursing into fields).
    pub glue: Vector<StatRef>,
    glue_seen: Map<u64, u64>,
    /// Prototypes for every called EXTERN function (their headers may not be included).
    pub extern_protos: String,
    extern_seen: Map<u64, u64>,
    cur_name: String, // the symbol being emitted (multi-return pack sites name its ret struct)
    /// `SC_DYN_<stem>` typedef blocks (vtable + fat value + inline free) for every dyn stem any
    /// spelling touched; assembled between forward typedefs and aggregate definitions.
    pub dyn_defs: String,
    dyn_def_seen: Map<u64, u64>,
    /// Per-coercion thunks (static) + vtable definitions (extern const): exactly one TU owns them.
    pub dyn_tabs: String,
    dyn_tab_seen: Map<u64, u64>,
    /// `extern const <stem>__vt <pair>__vtbl;` for every referenced vtable (every TU sees these).
    pub dyn_decls: String,
    /// `type_info::<T>()` sites: each names an exported descriptor group the driver evaluates
    /// through the CTFE static graph and defines once (`__sc_ti__<mangle>`).
    pub ti_reqs: Vector<StatRef>,
    ti_seen: Map<u64, u64>,
}

/// One referenced const/static item: its declaration, C symbol, and the module whose prefix
/// spelled it (associated consts carry the emitting module's prefix).
pub struct StatRef {
    pub em: ModuleId,
    pub def: DefId,
    pub sym: String,
    /// The reference site's local type (pool `em`) -- what the stub declared, so the definition
    /// must spell the same C type (decl-side types may be unrecorded).
    pub ty: TypeId,
}

/// One demanded per-instance emission: the generic declaration, its C symbol, and the full
/// substitution chain (parent chain + this instance's own bindings, innermost last).
pub struct Demand {
    pub def: DefId,
    pub sym: String,
    pub subs: Vector<mbe::MSub>,
    /// The instantiation's closure suffix (receiver-args for methods, targs for fn specs) --
    /// hoisted closures of the instance body append it to their symbols.
    pub sfx: String,
}

extend CEmit as Free {
    pub fn free(self: &mut Self) {
        self.out.free();
        self.mg.free();
        self.demand.free();
        self.cap_names.free();
        self.aux.free();
        self.cur_name.free();
        self.stat_decls.free();
        self.stat_seen.free();
        self.stat_items.free();
        self.glue.free();
        self.glue_seen.free();
        self.extern_protos.free();
        self.extern_seen.free();
        self.dyn_defs.free();
        self.dyn_def_seen.free();
        self.dyn_tabs.free();
        self.dyn_tab_seen.free();
        self.dyn_decls.free();
        self.ti_reqs.free();
        self.ti_seen.free();
    }
}

extend CEmit {
    pub fn new(pkg: *const loader::Package) CEmit {
        return CEmit {
            pkg: pkg,
            out: String::new(),
            err: "",
            mg: mbe::Mangler::new(pkg),
            collect_demand: false,
            demand: Vector::<Demand>::new(),
            cap_base: 0,
            cap_names: Vector::<String>::new(),
            aux: String::new(),
            cur_name: String::new(),
            stat_decls: String::new(),
            stat_seen: Map::<u64, u64>::new(),
            stat_items: Vector::<StatRef>::new(),
            glue: Vector::<StatRef>::new(),
            glue_seen: Map::<u64, u64>::new(),
            extern_protos: String::new(),
            extern_seen: Map::<u64, u64>::new(),
            dyn_defs: String::new(),
            dyn_def_seen: Map::<u64, u64>::new(),
            dyn_tabs: String::new(),
            dyn_tab_seen: Map::<u64, u64>::new(),
            dyn_decls: String::new(),
            ti_reqs: Vector::<StatRef>::new(),
            ti_seen: Map::<u64, u64>::new(),
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    fn fail(self: &mut Self, why: str<'static>) bool {
        if self.err.len() == 0 {
            self.err = why;
        }
        return false;
    }

    // `(pm, t)` as a C declarator around `decl`; TYPE_NONE (unit) spells `void`.
    fn ty_c(self: &mut Self, m: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        if t == TYPE_NONE {
            out.push_str("void");
            if decl.len() != 0 {
                out.push_str(" ");
                out.push_str(decl);
            }
            return true;
        }
        if !self.mg.ctype(m, t, decl, out) {
            return self.fail("ctype");
        }
        return true;
    }

    // Push a demand binding unless it is the identity (a receiver spelled with its own param:
    // `self.method()` inside the generic body) -- the outer chain already binds it, and an
    // identity entry would make resolution loop.
    fn push_bind(self: &Self, snap: &mut Vector<mbe::MSub>, pm: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) {
        let y = *self.p().module_ast_const(am).type_at(at);
        if y.kind == TypeKind::TYPE_GENERIC && y.module == pm && y.as_data.decl == pnode {
            return;
        }
        snap.push(mbe::MSub { pm: pm, pnode: pnode, am: am, at: at });
    }

    // The declared FIELD count of a resolved aggregate (zero-field structs initialize as `{}`).
    fn agg_field_count(self: &Self, rm: ModuleId, rt: TypeId) u32 {
        let decl = self.agg_decl_res(rm, rt);
        if decl == NODE_NONE {
            return 1;
        }
        let am = self.agg_module_res(rm, rt);
        let a = self.p().module_ast_const(am);
        let ms = a.at_const(decl).as_data.aggregate.members;
        let mut n: u32 = 0;
        for i in 0..ms.len {
            if a.at_const(unsafe a.list(ms)[i as usize]).kind == NodeKind::NODE_FIELD {
                n += 1;
            }
        }
        return n;
    }

    // The prelude `str` view type (STRUCT named `str` in a prelude module).
    fn is_str_ty(self: &Self, rm: ModuleId, rt: TypeId) bool {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind != TypeKind::TYPE_STRUCT || !self.p().modules.at(y.module as usize).prelude {
            return false;
        }
        let da = self.p().module_ast_const(y.module);
        let sp = da.at_const(da.at_const(y.as_data.decl).as_data.aggregate.name).as_data.name.text;
        let src = self.p().modules.at(y.module as usize).source.as_str();
        return src.slice(sp.start as usize, sp.end as usize) == "str";
    }

    // Render one call argument with the implicit adjustments the language applies at calls:
    // autoref (`&` when the param is a reference and the arg a value) and Box auto-deref
    // (`b.ptr` bridges Box<T> receivers to T* params).
    fn emit_call_arg(self: &mut Self, b: &ir::CoreBody, callee: DefId, i: u32, opid: ir::OperandId, dst: &mut String) bool {
        if callee.node == NODE_NONE {
            return self.emit_operand(b, opid, dst);
        }
        // the callee's declared param type kind (reference params take pointers)
        let fa = self.p().module_ast_const(callee.module);
        let fnn = fa.at_const(callee.node);
        let mut want_ref = false;
        let mut want_val = false; // the param takes the VALUE: reference args deref
        let mut param_box = false; // the param's own pointee IS a Box: no deref hop
        if fnn.kind == NodeKind::NODE_FUNCTION {
            let ps = fnn.as_data.function.params;
            if i < ps.len {
                let pn = fa.at_const(unsafe fa.list(ps)[i as usize]);
                if pn.kind == NodeKind::NODE_PARAMETER && pn.as_data.parameter.ty != NODE_NONE {
                    let pty = fa.type_of(pn.as_data.parameter.ty);
                    if pty != TYPE_NONE && fa.type_at(pty).kind != TypeKind::TYPE_REFERENCE && fa.type_at(pty).kind != TypeKind::TYPE_POINTER {
                        want_val = true;
                    }
                    if pty != TYPE_NONE && fa.type_at(pty).kind == TypeKind::TYPE_REFERENCE {
                        want_ref = true;
                        let pe = fa.type_at(pty).as_data.elem;
                        if pe != TYPE_NONE && fa.type_at(pe).kind == TypeKind::TYPE_INSTANCE {
                            let pit = *fa.instance(fa.type_at(pe).as_data.inst);
                            let pda = self.p().module_ast_const(pit.module);
                            let pns = pda.at_const(pda.at_const(pit.decl).as_data.aggregate.name).as_data.name.text;
                            let psrc = self.p().modules.at(pit.module as usize).source.as_str();
                            param_box = psrc.slice(pns.start as usize, pns.end as usize) == "Box";
                        }
                    }
                }
            }
        }
        if !want_ref {
            if want_val {
                let aty0 = b.operands.at(opid as usize).ty;
                let mut rm0 = b.module;
                let mut rt0 = aty0;
                self.rty(b, aty0, &mut rm0, &mut rt0);
                if self.p().module_ast_const(rm0).type_at(rt0).kind == TypeKind::TYPE_REFERENCE {
                    dst.push_str("(*");
                    let ok0 = self.emit_operand(b, opid, dst);
                    dst.push_str(")");
                    return ok0;
                }
            }
            return self.emit_operand(b, opid, dst);
        }
        let aty = b.operands.at(opid as usize).ty;
        let mut rm = b.module;
        let mut rt = aty;
        self.rty(b, aty, &mut rm, &mut rt);
        let mut ay = *self.p().module_ast_const(rm).type_at(rt);
        let mut through_ref = false;
        if ay.kind == TypeKind::TYPE_REFERENCE || ay.kind == TypeKind::TYPE_POINTER {
            // a reference arg may still need the Box hop: peel one level and check
            let mut em2 = rm;
            let mut et2 = ay.as_data.elem;
            if self.mg.resolve(rm, ay.as_data.elem, &mut em2, &mut et2) {
                let ey = *self.p().module_ast_const(em2).type_at(et2);
                if ey.kind == TypeKind::TYPE_INSTANCE {
                    rm = em2;
                    rt = et2;
                    ay = ey;
                    through_ref = true;
                } else {
                    return self.emit_operand(b, opid, dst);
                }
            } else {
                return self.emit_operand(b, opid, dst);
            }
        }
        // Box<T> receivers deref through their owning pointer
        if ay.kind == TypeKind::TYPE_INSTANCE {
            let a2 = self.p().module_ast_const(rm);
            let it = *a2.instance(ay.as_data.inst);
            let da = self.p().module_ast_const(it.module);
            let nsp = da.at_const(da.at_const(it.decl).as_data.aggregate.name).as_data.name.text;
            let nsrc = self.p().modules.at(it.module as usize).source.as_str();
            if !param_box && nsrc.slice(nsp.start as usize, nsp.end as usize) == "Box" {
                let ok = self.emit_operand(b, opid, dst);
                dst.push_str(if_s(through_ref, "->ptr", ".ptr"));
                return ok;
            }
        }
        if through_ref {
            return self.emit_operand(b, opid, dst); // an ordinary reference arg passes through
        }
        dst.push_str("&");
        return self.emit_operand(b, opid, dst);
    }

    // Unit-typed data carries no C: TYPE_NONE or the void builtin (what generic unit
    // instantiations resolve to).
    fn is_unit(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return true;
        }
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_NEVER {
            return true; // never-typed temps hold no value (their writers do not return)
        }
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
    }

    // Resolve `(b.module, t)` through the substitution env (identity when unbound).
    fn rty(self: &Self, b: &ir::CoreBody, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) {
        if !self.mg.resolve(b.module, t, rm, rt) {
            *rm = b.module;
            *rt = t;
        }
    }

    fn agg_module_res(self: &Self, rm: ModuleId, rt: TypeId) ModuleId {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).module;
        }
        return y.module;
    }
    fn agg_decl_res(self: &Self, rm: ModuleId, rt: TypeId) NodeId {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).decl;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.as_data.decl;
        }
        return NODE_NONE;
    }

    // The module whose ast declares the aggregate behind pool type `(b.module, t)` (instances
    // answer their owner). Used to spell member and variant names.
    fn agg_module(self: &Self, b: &ir::CoreBody, t: TypeId) ModuleId {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).module;
        }
        return y.module;
    }

    // The aggregate DECL node behind pool type `(b.module, t)` (instances answer the generic decl).
    fn agg_decl(self: &Self, b: &ir::CoreBody, t: TypeId) NodeId {
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).decl;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.as_data.decl;
        }
        return NODE_NONE;
    }

    // Does this enum (by decl) carry any payload -- i.e. emit as {tag, payload} instead of a C enum?
    fn enum_has_payload(self: &Self, m: ModuleId, decl: NodeId) bool {
        let a = self.p().module_ast_const(m);
        let ms = a.at_const(decl).as_data.aggregate.members;
        for i in 0..ms.len {
            let vid = unsafe a.list(ms)[i as usize];
            if a.at_const(vid).kind == NodeKind::NODE_VARIANT && a.at_const(vid).as_data.variant.payload.len != 0 {
                return true;
            }
        }
        return false;
    }

    /// Emit `b` as one C function named `name` into the shared buffer. False (with `err`) when the
    /// body leaves the portable subset; the buffer then holds no partial function.
    pub fn emit_fn(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.err = "";
        let mark = self.out.len();
        if !self.emit_fn_inner(b, name) {
            self.out.truncate(mark);
            return false;
        }
        return true;
    }

    fn emit_fn_inner(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.cur_name.truncate(0);
        self.cur_name.push_str(name);
        let mut ok0 = true;
        if b.returns > 1 {
            // multi-return: `typedef struct { <t> _0; ... } <name>_ret;` + struct-returning sig
            self.aux.push_str("typedef struct { ");
            for r in 0..b.returns {
                let mut nm = String::from_str("_");
                nm.push_u64(r);
                let okr = self.ty_c(b.module, b.locals.at(r as usize).ty, nm.as_str(), &mut self.aux);
                nm.free();
                if !okr {
                    return false;
                }
                self.aux.push_str("; ");
            }
            self.aux.push_str("} ");
            self.aux.push_str(name);
            self.aux.push_str("_ret;\n");
            self.out.push_str(name);
            self.out.push_str("_ret ");
            self.out.push_str(name);
            self.out.push_str("(");
        } else {
            let mut rty = TYPE_NONE;
            if b.returns == 1 {
                rty = b.locals.at(0).ty;
            }
            let mut rt = String::new();
            ok0 = self.ty_c(b.module, rty, "", &mut rt);
            if ok0 {
                self.out.push_string(&rt);
                self.out.push_str(" ");
                self.out.push_str(name);
                self.out.push_str("(");
            }
            rt.free();
        }
        if !ok0 {
            return false;
        }
        for i in 0..b.args {
            if i != 0 {
                self.out.push_str(", ");
            }
            let l = (b.returns + i) as usize;
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_string(&ts);
            }
            ts.free();
            nm.free();
            if !ok {
                return false;
            }
        }
        if b.args == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(") {\n");
        return self.emit_body_core(b);
    }

    // Locals, labels, blocks and the closing brace -- shared by plain functions and closures.
    fn emit_body_core(self: &mut Self, b: &ir::CoreBody) bool {
        // every non-argument local declares up front, explicitly typed; unit locals carry no C
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            if st == ir::LS_ARG {
                continue;
            }
            if b.locals.at(l).ty == TYPE_NONE {
                // untyped temps recover their type from whatever writes them (rvalue target or a
                // call destination); scalars fall back to int64_t
                let mut retsym = String::new();
                if self.untyped_ret_struct(b, l as u32, &mut retsym) {
                    self.out.push_str("  ");
                    self.out.push_string(&retsym);
                    self.out.push_str("_ret _");
                    self.out.push_u64(l as u64);
                    self.out.push_str(";\n");
                    retsym.free();
                    continue;
                }
                retsym.free();
                let rt0 = self.untyped_local_ty(b, l as u32);
                if rt0 != TYPE_NONE {
                    let mut nm3 = String::from_str("_");
                    nm3.push_u64(l as u64);
                    let mut ts3 = String::new();
                    let ok3 = self.ty_c(b.module, rt0, nm3.as_str(), &mut ts3);
                    if ok3 {
                        self.out.push_str("  ");
                        self.out.push_string(&ts3);
                        self.out.push_str(";\n");
                    }
                    ts3.free();
                    nm3.free();
                    if !ok3 {
                        return false;
                    }
                    continue;
                }
                self.out.push_str("  int64_t _");
                self.out.push_u64(l as u64);
                self.out.push_str(";\n");
                continue;
            }
            {
                // an OPEN array local ([T] with no length) recovers its extent from the literal
                // or repeat that fills it
                let mut rmL = b.module;
                let mut rtL = b.locals.at(l).ty;
                self.rty(b, b.locals.at(l).ty, &mut rmL, &mut rtL);
                let yl = *self.p().module_ast_const(rmL).type_at(rtL);
                if yl.kind == TypeKind::TYPE_ARRAY && yl.as_data.arr.len == 0 {
                    let n = self.filled_len(b, l as u32);
                    if n == 0 {
                        return self.fail("open-array");
                    }
                    let mut nm2 = String::from_str("_");
                    nm2.push_u64(l as u64);
                    nm2.push_str("[");
                    nm2.push_u64(n);
                    nm2.push_str("]");
                    let mut ts2 = String::new();
                    let ok3 = self.ty_c(rmL, yl.as_data.arr.elem, nm2.as_str(), &mut ts2);
                    if ok3 {
                        self.out.push_str("  ");
                        self.out.push_string(&ts2);
                        self.out.push_str(";\n");
                    }
                    ts2.free();
                    nm2.free();
                    if !ok3 {
                        return false;
                    }
                    continue;
                }
            }
            {
                let mut rmN = b.module;
                let mut rtN = b.locals.at(l).ty;
                self.rty(b, b.locals.at(l).ty, &mut rmN, &mut rtN);
                if self.p().module_ast_const(rmN).type_at(rtN).kind == TypeKind::TYPE_NEVER {
                    // never-typed temps only appear on dead paths; a scalar placeholder keeps
                    // their (unreachable) reads compilable
                    self.out.push_str("  int64_t _");
                    self.out.push_u64(l as u64);
                    self.out.push_str(";\n");
                    continue;
                }
            }
            if self.is_unit(b, b.locals.at(l).ty) {
                continue;
            }
            if st == ir::LS_STATIC_REF {
                continue; // reads spell the item's own symbol; the local never declares
            }
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&ts);
                self.out.push_str(";\n");
            }
            ts.free();
            nm.free();
            if !ok {
                return false;
            }
        }
        // labels only where a goto lands (strict builds reject unused labels)
        let mut targeted = Vector::<bool>::new();
        for _i in 0..b.blocks.len() {
            targeted.push(false);
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.t0 != ir::IR_NONE && t.t0 as usize < b.blocks.len() {
                targeted.set(t.t0 as usize, true);
            }
            if t.kind == ir::TM_SWITCH {
                for k in 0..t.sw_len {
                    let tgt = (b.switch_pool[(t.sw_start + k) as usize] & 0xFFFFFFFFu64) as usize;
                    if tgt < b.blocks.len() {
                        targeted.set(tgt, true);
                    }
                }
            }
        }
        let mut ok2 = true;
        for bi in 0..b.blocks.len() {
            if !ok2 {
                break;
            }
            if targeted[bi] {
                self.out.push_str("bb_");
                self.out.push_u64(bi as u64);
                self.out.push_str(": ;\n");
            }
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if !self.emit_stmt(b, &s) {
                    ok2 = false;
                    break;
                }
            }
            if ok2 && !self.emit_term(b, &blk.term) {
                ok2 = false;
            }
        }
        targeted.free();
        if !ok2 {
            return false;
        }
        self.out.push_str("}\n");
        return self.err.len() == 0;
    }

    /// Emit a closure body: `static <ret> <sym>(const <sym>_env *const __env, <params...>)` with
    /// captures read through the env; `env_out` receives the env struct typedef (empty when the
    /// closure captures nothing -- it is then a plain function taking only its params).
    pub fn emit_closure(self: &mut Self, b: &ir::CoreBody, cm: ModuleId, cnode: NodeId, sym: str, env_out: &mut String) bool {
        self.err = "";
        let mark = self.out.len();
        if !self.emit_closure_inner(b, cm, cnode, sym, env_out) {
            self.out.truncate(mark);
            self.cap_base = 0;
            self.cap_names.truncate(0);
            return false;
        }
        self.cap_base = 0;
        self.cap_names.truncate(0);
        return true;
    }

    fn emit_closure_inner(
        self: &mut Self,
        b: &ir::CoreBody,
        cm: ModuleId,
        cnode: NodeId,
        sym: str,
        env_out: &mut String,
    ) bool {
        if b.returns > 1 {
            return self.fail("multi-return");
        }
        let ca = self.p().module_ast_const(cm);
        let cd = ca.at_const(cnode).as_data.closure;
        if cd.mut_caps != 0 {
            return self.fail("closure-mut");
        }
        let np = cd.params.len;
        let ncaps = cd.captures.len;
        if b.args != np + ncaps {
            return self.fail("closure-args");
        }
        self.cap_base = b.returns + np;
        for k in 0..ncaps {
            let decl = unsafe ca.list(cd.captures)[k as usize];
            let csp = self.mg.decl_name_span(cm, decl);
            if csp.end <= csp.start {
                return self.fail("closure-cap-name");
            }
            let mut nm = String::new();
            self.mg.ident(cm, csp, &mut nm);
            self.cap_names.push(nm);
        }
        if ncaps != 0 {
            env_out.push_str("typedef struct { ");
            for k in 0..ncaps {
                let l = (self.cap_base + k) as usize;
                if !self.mg.ctype(b.module, b.locals.at(l).ty, self.cap_names.at(k as usize).as_str(), env_out) {
                    return self.fail("closure-cap-ty");
                }
                env_out.push_str("; ");
            }
            env_out.push_str("} ");
            env_out.push_str(sym);
            env_out.push_str("_env;\n");
        }
        let mut rty = TYPE_NONE;
        if b.returns == 1 {
            rty = b.locals.at(0).ty;
        }
        let mut rt = String::new();
        let ok0 = self.ty_c(b.module, rty, "", &mut rt);
        if ok0 {
            // extern: dyn-fn thunks in the instance TU call hoisted closures by name, and each
            // closure emits exactly once (its symbol carries module + node + instance suffix)
            self.out.push_string(&rt);
            self.out.push_str(" ");
            self.out.push_str(sym);
            self.out.push_str("(");
            if ncaps != 0 {
                self.out.push_str("const ");
                self.out.push_str(sym);
                self.out.push_str("_env *const __env");
                if np != 0 {
                    self.out.push_str(", ");
                }
            }
        }
        rt.free();
        if !ok0 {
            return false;
        }
        for i in 0..np {
            if i != 0 {
                self.out.push_str(", ");
            }
            let l = (b.returns + i) as usize;
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_string(&ts);
            }
            ts.free();
            nm.free();
            if !ok {
                return false;
            }
        }
        if np == 0 && ncaps == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(") {\n");
        return self.emit_body_core(b);
    }

    // When untyped local `l` receives a MULTI-return call, its C type is that callee's `_ret`
    // struct (field names `_N` match tuple reads).
    fn untyped_ret_struct(self: &mut Self, b: &ir::CoreBody, l: u32, sym: &mut String) bool {
        return self.untyped_ret_struct_d(b, l, sym, 0);
    }
    fn untyped_ret_struct_d(self: &mut Self, b: &ir::CoreBody, l: u32, sym: &mut String, depth: u32) bool {
        if depth > 4 {
            return false;
        }
        // an untyped COPY of an untyped local chases the source's writer
        for si in 0..b.statements.len() {
            let st = *b.statements.at(si);
            if st.kind != ir::ST_ASSIGN || st.place == ir::IR_NONE {
                continue;
            }
            let pl = *b.places.at(st.place as usize);
            if pl.base != l || pl.proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(st.rvalue as usize);
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.ty == TYPE_NONE && (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) {
                    let spl = *b.places.at(op.data as usize);
                    if spl.proj_len == 0 && spl.base != l && b.locals.at(spl.base as usize).ty == TYPE_NONE {
                        if self.untyped_ret_struct_d(b, spl.base, sym, depth + 1) {
                            return true;
                        }
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = *b.blocks.at(bi);
            let tm = t.term;
            if tm.kind != ir::TM_CALL || tm.dests_len != 1 || tm.callee.node == NODE_NONE {
                continue;
            }
            let dp = *b.places.at(b.dest_pool[tm.dests_start as usize] as usize);
            if dp.base != l || dp.proj_len != 0 {
                continue;
            }
            let ca = self.p().module_ast_const(tm.callee.module);
            let fd = ca.at_const(tm.callee.node);
            if fd.kind != NodeKind::NODE_FUNCTION || fd.as_data.function.returns.len < 2 {
                continue;
            }
            let mut rty2 = TYPE_NONE;
            if tm.args_len > 0 {
                rty2 = b.operands.at(b.oper_pool[tm.args_start as usize] as usize).ty;
            }
            return self.callee_sym(b, tm.callee, tm.targs_start, tm.targs_len, rty2, TYPE_NONE, sym);
        }
        return false;
    }

    // The recorded type of whatever writes untyped local `l` (an rvalue's target, an operand's
    // type, or a call destination's declared return); TYPE_NONE when nothing carries one.
    fn untyped_local_ty(self: &Self, b: &ir::CoreBody, l: u32) TypeId {
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN || s.place == ir::IR_NONE {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.base != l || pl.proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.target != TYPE_NONE {
                return rv.target;
            }
            if rv.kind == ir::RV_USE {
                let op = *b.operands.at(rv.a as usize);
                if op.ty != TYPE_NONE {
                    return op.ty;
                }
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    let spl = *b.places.at(op.data as usize);
                    if spl.proj_len == 0 && spl.base != l {
                        let src_ty = b.locals.at(spl.base as usize).ty;
                        if src_ty != TYPE_NONE {
                            return src_ty;
                        }
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || t.dests_len != 1 || t.callee.node == NODE_NONE || t.callee.module != b.module {
                continue; // foreign return types live in a foreign pool: unusable here
            }
            let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
            if dp.base != l || dp.proj_len != 0 {
                continue;
            }
            let ca = self.p().module_ast_const(t.callee.module);
            let fd = ca.at_const(t.callee.node);
            if fd.kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let rs = fd.as_data.function.returns;
            if rs.len == 1 {
                let r0 = unsafe ca.list(rs)[0];
                let rn = ca.at_const(r0);
                let mut rtn = r0;
                if rn.kind == NodeKind::NODE_PARAMETER {
                    rtn = rn.as_data.parameter.ty;
                }
                let rt = ca.type_of(rtn);
                if rt != TYPE_NONE {
                    return rt;
                }
            }
        }
        return TYPE_NONE;
    }

    // The element count an open-array local is filled with (its RV_REPEAT count or array-literal
    // arity); 0 = no filler found.
    fn filled_len(self: &Self, b: &ir::CoreBody, l: u32) u64 {
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN || s.place == ir::IR_NONE {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.base != l || pl.proj_len != 0 {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY {
                return rv.b;
            }
            if rv.kind == ir::RV_REPEAT {
                let cnt = *b.operands.at(rv.b as usize);
                if cnt.kind == ir::OP_CONST {
                    let c = *b.constants.at(cnt.data as usize);
                    if c.kind == ir::CK_INT && c.val > 0 {
                        return c.val as u64;
                    }
                }
            }
        }
        return 0;
    }

    // Does this struct literal fill any fixed-array member from a place (C cannot initialize an
    // array member from a variable)?
    fn agg_has_array_field(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        for i in 0..rv.b {
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == ir::IR_NONE {
                continue;
            }
            let op = *b.operands.at(opid as usize);
            if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
                continue;
            }
            let mut rm = b.module;
            let mut rt = op.ty;
            self.rty(b, op.ty, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0 {
                return true;
            }
        }
        return false;
    }

    // `lhs = (T){ ..., .arr = {0}, ... }; memcpy(&lhs.arr, &src, sizeof(lhs.arr)); ...`
    fn emit_struct_store_arrays(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let sdecl = self.agg_decl(b, rv.target);
        if sdecl == NODE_NONE {
            return self.fail("agg-struct");
        }
        let am = self.agg_module(b, rv.target);
        let sa = self.p().module_ast_const(am);
        let ms = sa.at_const(sdecl).as_data.aggregate.members;
        if ms.len != rv.b {
            return self.fail("agg-arity");
        }
        let mut lhs = String::new();
        let mut ok = self.emit_place(b, s.place, &mut lhs);
        let mut cast = String::new();
        if ok {
            ok = self.ty_c(b.module, rv.target, "", &mut cast);
        }
        let mut post = String::new();
        if ok {
            self.out.push_str("  ");
            self.out.push_string(&lhs);
            self.out.push_str(" = (");
            self.out.push_string(&cast);
            self.out.push_str("){ ");
            let mut emitted: u32 = 0;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue;
                }
                let fid = unsafe sa.list(ms)[i as usize];
                let mut fnm = String::new();
                self.mg.ident(am, sa.at_const(sa.at_const(fid).as_data.field.name).as_data.name.text, &mut fnm);
                let op = *b.operands.at(opid as usize);
                let mut rm = b.module;
                let mut rt = op.ty;
                self.rty(b, op.ty, &mut rm, &mut rt);
                let y = *self.p().module_ast_const(rm).type_at(rt);
                let is_arr = (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0;
                if emitted != 0 {
                    self.out.push_str(", ");
                }
                self.out.push_str(".");
                self.out.push_string(&fnm);
                self.out.push_str(" = ");
                if is_arr {
                    self.out.push_str("{0}");
                    post.push_str("  memcpy(&");
                    post.push_string(&lhs);
                    post.push_str(".");
                    post.push_string(&fnm);
                    post.push_str(", &");
                    ok = self.emit_place(b, op.data, &mut post);
                    post.push_str(", sizeof(");
                    post.push_string(&lhs);
                    post.push_str(".");
                    post.push_string(&fnm);
                    post.push_str("));\n");
                } else {
                    let mut av = String::new();
                    ok = self.emit_operand(b, opid, &mut av);
                    self.out.push_string(&av);
                    av.free();
                }
                fnm.free();
                emitted += 1;
            }
            if emitted == 0 {
                self.out.push_str("0");
            }
            self.out.push_str(" };\n");
            self.out.push_string(&post);
        }
        post.free();
        cast.free();
        lhs.free();
        return ok;
    }

    fn emit_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true; // markers carry no C
        }
        if s.kind != ir::ST_ASSIGN {
            return self.fail("stmt");
        }
        // rvalues are effect-free (calls are terminators), so a VOID-typed store carries no C
        // (untyped places are real data whose type recovers at declaration)
        if b.places.at(s.place as usize).ty != TYPE_NONE && self.is_unit(b, b.places.at(s.place as usize).ty) {
            return true;
        }
        // a stored CK_UNIT is the lowerer's "no meaningful value" marker (expression-statement
        // results); the established emitter never materializes it
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_USE {
                let op0 = *b.operands.at(rv0.a as usize);
                if op0.kind == ir::OP_CONST && b.constants.at(op0.data as usize).kind == ir::CK_UNIT {
                    return true;
                }
            }
        }
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY {
                return self.emit_array_stores(b, s, &rv0);
            }
            if rv0.kind == ir::RV_REPEAT {
                return self.emit_repeat_stores(b, s, &rv0);
            }
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_STRUCT && self.agg_has_array_field(b, &rv0) {
                return self.emit_struct_store_arrays(b, s, &rv0);
            }
        }
        // a capturing closure erased to `dyn fn` boxes its env first: statement-level emission
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_DYN {
                let mut omD = b.module;
                let mut otD = b.operands.at(rv0.a as usize).ty;
                self.rty(b, b.operands.at(rv0.a as usize).ty, &mut omD, &mut otD);
                if self.p().module_ast_const(omD).type_at(otD).kind == TypeKind::TYPE_FUNCTION {
                    return self.emit_dyn_env_store(b, s, &rv0, omD, otD);
                }
            }
        }
        // a store whose source is a NEVER-typed temp sits on a dead path: emit nothing
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_USE {
                let op0 = *b.operands.at(rv0.a as usize);
                if (op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE) && op0.ty != TYPE_NONE {
                    let mut rmD = b.module;
                    let mut rtD = op0.ty;
                    self.rty(b, op0.ty, &mut rmD, &mut rtD);
                    if self.p().module_ast_const(rmD).type_at(rtD).kind == TypeKind::TYPE_NEVER {
                        return true;
                    }
                }
            }
        }
        // fixed C arrays cannot assign: whole-array stores copy bytes
        {
            let mut rmA = b.module;
            let mut rtA = b.places.at(s.place as usize).ty;
            self.rty(b, rtA, &mut rmA, &mut rtA);
            let ya = *self.p().module_ast_const(rmA).type_at(rtA);
            if ya.kind == TypeKind::TYPE_ARRAY && ya.as_data.arr.len != 0 {
                let rv0 = *b.rvalues.at(s.rvalue as usize);
                if rv0.kind != ir::RV_USE {
                    return self.fail("array-store");
                }
                let op0 = *b.operands.at(rv0.a as usize);
                if op0.kind == ir::OP_CONST {
                    let c0 = *b.constants.at(op0.data as usize);
                    if c0.kind == ir::CK_INT && c0.val == 0 {
                        // zeroing a whole array is a byte fill
                        let mut zl = String::new();
                        let okz = self.emit_place(b, s.place, &mut zl);
                        if okz {
                            self.out.push_str("  memset(&");
                            self.out.push_string(&zl);
                            self.out.push_str(", 0, sizeof(");
                            self.out.push_string(&zl);
                            self.out.push_str("));\n");
                        }
                        zl.free();
                        return okz;
                    }
                }
                if op0.kind != ir::OP_COPY && op0.kind != ir::OP_MOVE {
                    return self.fail("array-store");
                }
                let mut lhs2 = String::new();
                let mut rhs2 = String::new();
                let ok2 = self.emit_place(b, s.place, &mut lhs2) && self.emit_place(b, op0.data, &mut rhs2);
                if ok2 {
                    self.out.push_str("  memcpy(&");
                    self.out.push_string(&lhs2);
                    self.out.push_str(", &");
                    self.out.push_string(&rhs2);
                    self.out.push_str(", sizeof(");
                    self.out.push_string(&lhs2);
                    self.out.push_str("));\n");
                }
                lhs2.free();
                rhs2.free();
                return ok2;
            }
        }
        let mut lhs = String::new();
        let mut rhs = String::new();
        let ok = self.emit_place(b, s.place, &mut lhs) && self.emit_rvalue(b, s.rvalue, &mut rhs);
        if ok {
            self.out.push_str("  ");
            self.out.push_string(&lhs);
            self.out.push_str(" = ");
            self.out.push_string(&rhs);
            self.out.push_str(";\n");
        }
        lhs.free();
        rhs.free();
        return ok;
    }

    // A capturing closure erased to `dyn fn`: box the env on the Global heap, then build the fat
    // value. The pair's `__free` only deallocates the env, so owning captures refuse.
    fn emit_dyn_env_store(
        self: &mut Self,
        b: &ir::CoreBody,
        s: &ir::Statement,
        rv: &ir::Rvalue,
        om: ModuleId,
        ot: TypeId,
    ) bool {
        let oy = *self.p().module_ast_const(om).type_at(ot);
        let cd = self.p().module_ast_const(oy.module).at_const(oy.as_data.decl);
        if cd.kind != NodeKind::NODE_CLOSURE || cd.as_data.closure.captures.len == 0 {
            return self.fail("dyn-fnval");
        }
        {
            let ca = self.p().module_ast_const(oy.module);
            let caps = cd.as_data.closure.captures;
            for i in 0..caps.len {
                let cid = unsafe ca.list(caps)[i as usize];
                let cty = ca.type_of(cid);
                if cty != TYPE_NONE {
                    let mut crm = oy.module;
                    let mut crt = cty;
                    if self.mg.resolve(oy.module, cty, &mut crm, &mut crt) && self.is_destructible(crm, crt, 0) {
                        return self.fail("dyn-env-free");
                    }
                }
            }
        }
        let mut dm = b.module;
        let mut dt = rv.target;
        self.rty(b, rv.target, &mut dm, &mut dt);
        let mut envc = String::new();
        let mut tc = String::new();
        let mut pair = String::new();
        let mut lhs = String::new();
        let mut opv = String::new();
        let mut ok = self.mg.ctype(om, ot, "", &mut envc) && self.ty_c(b.module, rv.target, "", &mut tc) && self.emit_place(
            b,
            s.place,
            &mut lhs,
        ) && self.emit_operand(b, rv.a, &mut opv);
        if ok {
            ok = self.dyn_pair(dm, dt, om, ot, true, &mut pair);
        }
        if ok {
            self.out.push_str("  { Global __g = (Global){}; ");
            self.out.push_string(&envc);
            self.out.push_str(" *__dp = (");
            self.out.push_string(&envc);
            self.out.push_str(" *)Global__alloc(&__g, sizeof(");
            self.out.push_string(&envc);
            self.out.push_str("), _Alignof(");
            self.out.push_string(&envc);
            self.out.push_str(")); *__dp = ");
            self.out.push_string(&opv);
            self.out.push_str("; ");
            self.out.push_string(&lhs);
            self.out.push_str(" = ((");
            self.out.push_string(&tc);
            self.out.push_str("){ .data = __dp, .vt = &");
            self.out.push_string(&pair);
            self.out.push_str("__vtbl }); }\n");
        }
        envc.free();
        tc.free();
        pair.free();
        lhs.free();
        opv.free();
        return ok;
    }

    // C forbids array assignment: an array literal stores element-wise into the place.
    fn emit_array_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let mut base = String::new();
        let mut ok = self.emit_place(b, s.place, &mut base);
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let mut el = String::new();
            ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], &mut el);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&base);
                self.out.push_str("[");
                self.out.push_u64(i);
                self.out.push_str("] = ");
                self.out.push_string(&el);
                self.out.push_str(";\n");
            }
            el.free();
        }
        base.free();
        return ok;
    }

    // `[v; N]` with a small constant count unrolls to element stores (the count operand id rides
    // rv.b); larger repeats stay unfrozen.
    fn emit_repeat_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let cnt = *b.operands.at(rv.b as usize);
        if cnt.kind != ir::OP_CONST {
            return self.fail("repeat-count");
        }
        let c = *b.constants.at(cnt.data as usize);
        if c.kind != ir::CK_INT || c.val < 0 {
            return self.fail("repeat-count");
        }
        let mut base = String::new();
        let mut el = String::new();
        let ok = self.emit_place(b, s.place, &mut base) && self.emit_operand(b, rv.a, &mut el);
        if ok && c.val <= 16 {
            for i in 0..c.val {
                self.out.push_str("  ");
                self.out.push_string(&base);
                self.out.push_str("[");
                self.out.push_u64(i as u64);
                self.out.push_str("] = ");
                self.out.push_string(&el);
                self.out.push_str(";\n");
            }
        } else if ok {
            self.out.push_str("  for (size_t __ri = 0; __ri < ");
            self.out.push_i64(c.val);
            self.out.push_str("; __ri++) { ");
            self.out.push_string(&base);
            self.out.push_str("[__ri] = ");
            self.out.push_string(&el);
            self.out.push_str("; }\n");
        }
        base.free();
        el.free();
        return ok;
    }

    // Member access through a pointer/reference wraps the deref the chain omitted (the checker's
    // auto-deref); updates the tracked pre-type to the pointee.
    fn place_autoderef(self: &Self, b: &ir::CoreBody, pre: &mut TypeId, cur: &mut String) {
        let mut g = 0;
        while g < 4 {
            let mut rm = b.module;
            let mut rt = *pre;
            self.rty(b, *pre, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                return;
            }
            let mut w = String::from_str("(*");
            w.push_string(cur);
            w.push_str(")");
            cur.truncate(0);
            cur.push_string(&w);
            w.free();
            *pre = y.as_data.elem;
            g += 1;
        }
    }

    fn emit_place(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, dst: &mut String) bool {
        let pl = *b.places.at(pid as usize);
        let mut cur = String::new();
        if b.locals.at(pl.base as usize).storage == ir::LS_STATIC_REF {
            let item = b.locals.at(pl.base as usize).item;
            // a CONST-GENERIC parameter bound by the active instantiation is a literal, not a symbol
            let mut folded = false;
            {
                let mut k8 = self.mg.subs.len();
                while k8 > 0 {
                    k8 -= 1;
                    let sb8 = *self.mg.subs.at(k8);
                    if sb8.pm == item.module && sb8.pnode == item.node {
                        let mut rm8 = sb8.am;
                        let mut rt8 = sb8.at;
                        if self.mg.resolve(sb8.am, sb8.at, &mut rm8, &mut rt8) {
                            let y8 = *self.p().module_ast_const(rm8).type_at(rt8);
                            if y8.kind == TypeKind::TYPE_CONST {
                                cur.push_i64(y8.as_data.value);
                                folded = true;
                            }
                        }
                        break;
                    }
                }
            }
            if !folded && (item.node == NODE_NONE || !self.mg.const_sym(b.module, item.module, item.node, &mut cur)) {
                cur.free();
                return self.fail("static-sym");
            }
            if self.collect_demand && !folded {
                let mut h = 1469598103934665603u64;
                let cs = cur.as_str();
                for k in 0..cs.len() {
                    h = (h ^ cs.byte_at(k) as u64) * 1099511628211u64;
                }
                let fresh = switch self.stat_seen.get(&h) {
                    Some(_v) => false,
                    None => true,
                };
                if fresh {
                    self.stat_seen.insert(h, 1);
                    let mut sd = String::from_str("extern ");
                    if self.ty_c(b.module, b.locals.at(pl.base as usize).ty, cur.as_str(), &mut sd) {
                        sd.push_str(";\n");
                        self.stat_decls.push_string(&sd);
                        self.stat_items.push(
                            StatRef { em: b.module, def: item, sym: cur.clone(), ty: b.locals.at(pl.base as usize).ty },
                        );
                    }
                    sd.free();
                }
            }
        } else if self.cap_base != 0 && pl.base >= self.cap_base && pl.base as usize < self.cap_base as usize + self.cap_names.len() {
            cur.push_str("__env->");
            cur.push_string(self.cap_names.at((pl.base - self.cap_base) as usize));
        } else {
            cur.push_str("_");
            cur.push_u64(pl.base);
        }
        let mut pre = b.locals.at(pl.base as usize).ty;
        let mut ok = true;
        let mut prev_dc = false; // payload members after a downcast never deref (the recorded
        // projection type is the BORROWED view; the C member is direct)
        let mut had_dc = false;
        let mut dc_m: ModuleId = 0;
        let mut dc_v = NODE_NONE; // the last downcast's variant decl (payload field types)
        let mut last_fidx: u32 = 0xFFFFFFFFu32;
        let mut last_after_dc = false;
        let mut dc_pre = TYPE_NONE; // the enum INSTANCE the downcast peeled (binds payload generics)
        for i in 0..pl.proj_len {
            if !ok {
                break;
            }
            let pre0 = pre;
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF {
                let mut w = String::from_str("(*");
                w.push_string(&cur);
                w.push_str(")");
                cur.free();
                cur = w;
            } else if pj.kind == ir::PJ_FIELD {
                if !prev_dc {
                    self.place_autoderef(b, &mut pre, &mut cur);
                }
                cur.push_str(".");
                if pj.sub == NODE_NONE {
                    // positional payload/tuple member: the emitted C names it `_<index>`
                    cur.push_str("_");
                    cur.push_u64(pj.data);
                } else {
                    let am = self.agg_module(b, pre);
                    let fa = self.p().module_ast_const(am);
                    self.mg.ident(am, fa.at_const(fa.at_const(pj.sub).as_data.field.name).as_data.name.text, &mut cur);
                }
            } else if pj.kind == ir::PJ_INDEX_CONST || pj.kind == ir::PJ_INDEX_OP {
                // container instances index through their storage member: Array wraps a C array
                // in `data`, Vector/Slice/SliceMut hold a `ptr`; indexing auto-derefs references
                let mut rm2 = b.module;
                let mut rt2 = pre;
                self.rty(b, pre, &mut rm2, &mut rt2);
                let mut g2 = 0;
                while g2 < 4 {
                    let py2 = *self.p().module_ast_const(rm2).type_at(rt2);
                    if py2.kind == TypeKind::TYPE_POINTER {
                        break; // raw pointers ARE element storage: C subscripts them directly
                    }
                    if py2.kind != TypeKind::TYPE_REFERENCE {
                        break;
                    }
                    let el2 = py2.as_data.elem;
                    let mut nm2 = rm2;
                    let mut nt2 = el2;
                    if !self.mg.resolve(rm2, el2, &mut nm2, &mut nt2) {
                        break;
                    }
                    let ek2 = self.p().module_ast_const(nm2).type_at(nt2).kind;
                    let mut hop = ek2 == TypeKind::TYPE_ARRAY;
                    if ek2 == TypeKind::TYPE_INSTANCE {
                        let a3 = self.p().module_ast_const(nm2);
                        let it3 = *a3.instance(a3.type_at(nt2).as_data.inst);
                        let da3 = self.p().module_ast_const(it3.module);
                        let ns3 = da3.at_const(da3.at_const(it3.decl).as_data.aggregate.name).as_data.name.text;
                        let sr3 = self.p().modules.at(it3.module as usize).source.as_str();
                        let nm3s = sr3.slice(ns3.start as usize, ns3.end as usize);
                        hop = nm3s == "Array" || nm3s == "Vector" || nm3s == "Slice" || nm3s == "SliceMut";
                    }
                    if !hop {
                        break; // raw pointer arithmetic subscripts the pointer itself
                    }
                    let mut w2 = String::from_str("(*");
                    w2.push_string(&cur);
                    w2.push_str(")");
                    cur.free();
                    cur = w2;
                    rm2 = nm2;
                    rt2 = nt2;
                    g2 += 1;
                }
                let a2 = self.p().module_ast_const(rm2);
                if a2.type_at(rt2).kind == TypeKind::TYPE_INSTANCE {
                    let it2 = *a2.instance(a2.type_at(rt2).as_data.inst);
                    let da2 = self.p().module_ast_const(it2.module);
                    let nsp2 = da2.at_const(da2.at_const(it2.decl).as_data.aggregate.name).as_data.name.text;
                    let nsrc2 = self.p().modules.at(it2.module as usize).source.as_str();
                    if nsrc2.slice(nsp2.start as usize, nsp2.end as usize) == "Array" {
                        cur.push_str(".data");
                    } else {
                        cur.push_str(".ptr");
                    }
                } else if self.is_str_ty(rm2, rt2) {
                    cur.push_str(".ptr");
                }
                cur.push_str("[");
                if pj.kind == ir::PJ_INDEX_CONST {
                    cur.push_u64(pj.data);
                } else {
                    ok = self.emit_operand(b, pj.data, &mut cur);
                }
                cur.push_str("]");
            } else if pj.kind == ir::PJ_DOWNCAST {
                self.place_autoderef(b, &mut pre, &mut cur);
                cur.push_str(".payload.");
                let am = self.agg_module(b, pre);
                let fa = self.p().module_ast_const(am);
                self.mg.ident(am, fa.at_const(fa.at_const(pj.sub).as_data.variant.name).as_data.name.text, &mut cur);
            } else {
                ok = self.fail("projection");
            }
            pre = pj.ty;
            if pj.kind == ir::PJ_DOWNCAST {
                dc_m = self.agg_module(b, pre0);
                dc_v = pj.sub;
                dc_pre = pre0;
                prev_dc = true;
                had_dc = true;
                last_after_dc = false;
            } else {
                last_after_dc = prev_dc && pj.kind == ir::PJ_FIELD;
                if last_after_dc {
                    last_fidx = pj.data;
                }
                prev_dc = false;
            }
        }
        if ok && had_dc && last_after_dc && dc_v != NODE_NONE {
            // a payload BINDING borrows inline storage: when the final place type is a reference
            // but the DECLARED payload slot holds the value, the C rendering takes the address
            let mut rmF = b.module;
            let mut rtF = pl.ty;
            self.rty(b, pl.ty, &mut rmF, &mut rtF);
            if self.p().module_ast_const(rmF).type_at(rtF).kind == TypeKind::TYPE_REFERENCE {
                let va = self.p().module_ast_const(dc_m);
                let plst = va.at_const(dc_v).as_data.variant.payload;
                let mut stored_ref = false;
                if last_fidx < plst.len {
                    let pe = unsafe va.list(plst)[last_fidx as usize];
                    let pty9 = va.type_of(pe);
                    let mut k9 = TypeKind::TYPE_ERROR;
                    if pty9 != TYPE_NONE {
                        k9 = va.type_at(pty9).kind;
                        if k9 == TypeKind::TYPE_GENERIC {
                            // a generic payload slot: its CONCRETE type is the matching instance arg
                            let mut rmP = b.module;
                            let mut rtP = dc_pre;
                            self.rty(b, dc_pre, &mut rmP, &mut rtP);
                            let ap = self.p().module_ast_const(rmP);
                            if ap.type_at(rtP).kind == TypeKind::TYPE_INSTANCE {
                                let itP = *ap.instance(ap.type_at(rtP).as_data.inst);
                                let ed = self.p().module_ast_const(itP.module);
                                let gens = ed.at_const(itP.decl).as_data.aggregate.generics;
                                let gdecl = va.type_at(pty9).as_data.decl;
                                let mut gi9: u32 = 0;
                                while gi9 < gens.len && gi9 as u8 < itP.n {
                                    if unsafe ed.list(gens)[gi9 as usize] == gdecl {
                                        let mut rmA = rmP;
                                        let mut rtA = unsafe itP.args[gi9 as usize];
                                        if !self.mg.resolve(rmP, unsafe itP.args[gi9 as usize], &mut rmA, &mut rtA) {
                                            rmA = rmP;
                                            rtA = unsafe itP.args[gi9 as usize];
                                        }
                                        k9 = self.p().module_ast_const(rmA).type_at(rtA).kind;
                                        break;
                                    }
                                    gi9 += 1;
                                }
                            }
                        }
                    }
                    stored_ref = k9 == TypeKind::TYPE_REFERENCE || k9 == TypeKind::TYPE_POINTER;
                }
                if !stored_ref {
                    let mut w = String::from_str("(&");
                    w.push_string(&cur);
                    w.push_str(")");
                    cur.free();
                    cur = w;
                }
            }
        }
        if ok {
            dst.push_string(&cur);
        }
        cur.free();
        return ok;
    }

    fn emit_operand(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            return self.emit_place(b, op.data, dst);
        }
        if op.kind != ir::OP_CONST {
            return self.fail("operand");
        }
        return self.emit_const(b, op.data, dst);
    }

    fn emit_const(self: &mut Self, b: &ir::CoreBody, cid: u32, dst: &mut String) bool {
        let c = *b.constants.at(cid as usize);
        let src = self.p().modules.at(b.module as usize).source.as_str();
        if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
            if c.kind == ir::CK_INT && c.ty != TYPE_NONE {
                let mut rmZ = b.module;
                let mut rtZ = c.ty;
                self.rty(b, c.ty, &mut rmZ, &mut rtZ);
                let kz = self.p().module_ast_const(rmZ).type_at(rtZ).kind;
                if kz == TypeKind::TYPE_STRUCT || kz == TypeKind::TYPE_INSTANCE {
                    // an integer constant carrying an aggregate type is the zeroed value
                    let mut ts = String::new();
                    let okz = self.ty_c(b.module, c.ty, "", &mut ts);
                    if okz {
                        dst.push_str("(");
                        dst.push_string(&ts);
                        dst.push_str(if_s(self.agg_field_count(rmZ, rtZ) == 0, "){}", "){0}"));
                    }
                    ts.free();
                    return okz;
                }
            }
            return self.emit_int(b, &c, dst);
        }
        if c.kind == ir::CK_FLOAT {
            // the exact source spelling, with the language width suffix mapped to C's
            let txt = src.slice(c.raw.start as usize, c.raw.end as usize);
            let n = txt.len();
            if n > 3 && txt.slice(n - 3, n) == "f32" {
                dst.push_str(txt.slice(0, n - 3));
                dst.push_str("f");
            } else if n > 3 && txt.slice(n - 3, n) == "f64" {
                dst.push_str(txt.slice(0, n - 3));
            } else {
                dst.push_str(txt);
            }
            return true;
        }
        if c.kind == ir::CK_STR {
            // quoted spellings carry C-valid escapes and copy verbatim; matchertext/raw segments
            // are raw BYTES and re-escape byte-wise (the lowerer records the token kind in val)
            let plain = c.val == tt::TokenType::StringLiteral as i64 || c.val == tt::TokenType::ByteStringLiteral as i64;
            let mut raw0 = src.slice(c.raw.start as usize, c.raw.end as usize);
            if raw0.len() >= 2 && raw0.byte_at(0) == 34 && raw0.byte_at(raw0.len() - 1) == 34 {
                raw0 = raw0.slice(1, raw0.len() - 1); // some spans keep their quotes
            } else if raw0.len() >= 5 && raw0.byte_at(0) == b'M' && raw0.byte_at(1) == 34 && raw0.byte_at(2) == b'(' && raw0.byte_at(
                raw0.len() - 2,
            ) == b')' && raw0.byte_at(raw0.len() - 1) == 34 {
                raw0 = raw0.slice(3, raw0.len() - 2); // matchertext spans keep their M"( )" frame
            }
            let mut esc = String::new();
            if plain {
                esc.push_str(raw0);
            } else {
                push_c_escaped(raw0, &mut esc);
            }
            let txt = esc.as_str();
            let a = self.p().module_ast_const(b.module);
            {
                let mut rmS = b.module;
                let mut rtS = c.ty;
                if c.ty != TYPE_NONE {
                    self.rty(b, c.ty, &mut rmS, &mut rtS);
                    if self.p().module_ast_const(rmS).type_at(rtS).kind == TypeKind::TYPE_POINTER {
                        // a C-string context: the literal is the bare (escaped) string
                        dst.push_str("(const char *)\"");
                        dst.push_str(txt);
                        dst.push_str("\"");
                        esc.free();
                        return true;
                    }
                }
            }
            let is_slice = c.ty != TYPE_NONE && a.type_at(c.ty).kind == TypeKind::TYPE_INSTANCE;
            let mut cast = String::new();
            if c.ty == TYPE_NONE {
                cast.push_str("str"); // untyped string tests (switch patterns) are `str` views
            } else if !self.ty_c(b.module, c.ty, "", &mut cast) {
                cast.free();
                esc.free();
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
            cast.free();
            if is_slice {
                dst.push_str("){ .ptr = (const uint8_t *)\"");
                dst.push_str(txt);
                dst.push_str("\", .len = sizeof(\"");
                dst.push_str(txt);
                dst.push_str("\") - 1 }");
            } else {
                dst.push_str("){ (const uint8_t *)\"");
                dst.push_str(txt);
                dst.push_str("\", sizeof(\"");
                dst.push_str(txt);
                dst.push_str("\") - 1 }");
            }
            esc.free();
            return true;
        }
        if c.kind == ir::CK_ITEM {
            return self.callee_sym(b, c.item, c.targ_start, c.targ_len, TYPE_NONE, TYPE_NONE, dst);
        }
        return self.fail("constant");
    }

    fn emit_int(self: &mut Self, b: &ir::CoreBody, c: &ir::Constant, dst: &mut String) bool {
        // spellings re-render from the span when present (hex etc. stay exact); the decimal
        // fast path covers synthesized constants
        let sp = c.raw;
        let mut digits = Vector::<u8>::new();
        let mut spelled = false;
        {
            let s0 = self.p().modules.at(b.module as usize).source.as_str();
            if sp.end > sp.start && sp.end as usize <= s0.len() {
                let txt = s0.slice(sp.start as usize, sp.end as usize);
                let b0 = txt.byte_at(0);
                if b0 >= 48 && b0 <= 57 {
                    // strip a width suffix C cannot parse; keep the digits exactly
                    let n = txt.len();
                    let mut i: usize = 0;
                    let hex = n > 2 && txt.byte_at(1) == 120;
                    while i < n {
                        let ch = txt.byte_at(i);
                        let is_digit = ch >= 48 && ch <= 57 || ch == 95 || i < 2 && (ch == 120 || ch == 98 || ch == 111) || hex && (ch >= 97 && ch <= 102 || ch >= 65 && ch <= 70);
                        if !is_digit {
                            break;
                        }
                        if ch != 95 {
                            digits.push(ch);
                        }
                        i += 1;
                    }
                    spelled = true;
                }
            }
        }
        if spelled {
            for k in 0..digits.len() {
                dst.push_byte(digits[k]);
            }
            digits.free();
            if c.kind == ir::CK_INT {
                dst.push_str(if_s(self.int_is_unsigned(b, c.ty), "ULL", "LL"));
            }
            return true;
        }
        digits.free();
        if c.kind == ir::CK_BOOL {
            if c.val != 0 {
                dst.push_str("true");
            } else {
                dst.push_str("false");
            }
            return true;
        }
        dst.push_i64(c.val);
        dst.push_str(if_s(self.int_is_unsigned(b, c.ty), "ULL", "LL"));
        return true;
    }

    fn int_is_unsigned(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let bt = y.as_data.builtin;
        return bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE;
    }

    // The callee's C symbol: the frozen fn symbol plus `__<targ>` per bound generic argument
    // (free-fn specializations and generic methods share that composition).
    // Peel references/pointers off `t` and answer the receiver instance when it instantiates the
    // generic decl `tgt`; TYPE_NONE-style miss = `it.decl == NODE_NONE`.
    fn recv_inst(self: &Self, b: &ir::CoreBody, t: TypeId, tgt: DefId, rpm: &mut ModuleId) TyInstance {
        let mut cm = b.module;
        let mut cur = t;
        let mut guard = 0;
        while cur != TYPE_NONE && guard < 8 {
            let mut rm = cm;
            let mut rt = cur;
            if !self.mg.resolve(cm, cur, &mut rm, &mut rt) {
                break;
            }
            cm = rm;
            cur = rt;
            let a = self.p().module_ast_const(cm);
            let y = *a.type_at(cur);
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                cur = y.as_data.elem;
                guard += 1;
                continue;
            }
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *a.instance(y.as_data.inst);
                if it.module == tgt.module && it.decl == tgt.node {
                    *rpm = cm;
                    return it;
                }
            }
            break;
        }
        return TyInstance { decl: NODE_NONE };
    }

    /// The symbol an interface-member call on RESOLVED receiver `(rm6, rt6)` dispatches to: a
    /// CUSTOM impl when one exists (bound dispatch resolves per instantiation), else the
    /// per-target default-method instantiation, whose body is demanded under `Self -> receiver`.
    fn iface_target_sym(self: &mut Self, rm6: ModuleId, rt6: TypeId, callee: DefId, dst: &mut String) bool {
        let mut sym = String::new();
        {
            let ca8 = self.p().module_ast_const(callee.module);
            let msp8 = ca8.at_const(ca8.at_const(callee.node).as_data.function.name).as_data.name.text;
            let msrc8 = self.p().modules.at(callee.module as usize).source.as_str();
            let mname8 = msrc8.slice(msp8.start as usize, msp8.end as usize);
            let mut impl_sym = String::new();
            if self.mg.method_by_name(rm6, rt6, mname8, &mut impl_sym) {
                dst.push_string(&impl_sym);
                impl_sym.free();
                sym.free();
                return true;
            }
            impl_sym.free();
        }
        let y7 = *self.p().module_ast_const(rm6).type_at(rt6);
        if y7.kind == TypeKind::TYPE_BUILTIN {
            self.mg.modpfx(callee.module, &mut sym);
            if !self.mg.type_m(rm6, rt6, &mut sym) {
                sym.free();
                return self.fail("iface-default-recv");
            }
        } else if y7.kind == TypeKind::TYPE_INSTANCE {
            let it7 = *self.p().module_ast_const(rm6).instance(y7.as_data.inst);
            if !self.mg.inst_name(rm6, &it7, &mut sym) {
                sym.free();
                return self.fail("iface-default-inst");
            }
        } else {
            self.mg.modpfx(callee.module, &mut sym);
            let da7 = self.p().module_ast_const(y7.module);
            self.mg.ident(
                y7.module,
                da7.at_const(da7.at_const(y7.as_data.decl).as_data.aggregate.name).as_data.name.text,
                &mut sym,
            );
        }
        sym.push_str("__");
        let ca7 = self.p().module_ast_const(callee.module);
        self.mg.ident(
            callee.module,
            ca7.at_const(ca7.at_const(callee.node).as_data.function.name).as_data.name.text,
            &mut sym,
        );
        // demand the default BODY under `Self -> receiver` (the interface DECL NODE is Self's
        // binding key -- the extend-frame convention)
        if self.collect_demand {
            let fd7 = ca7.at_const(callee.node);
            if fd7.kind == NodeKind::NODE_FUNCTION && !fd7.as_data.function.is_extern && fd7.as_data.function.body != NODE_NONE {
                let idecl = self.mg.in_interface(callee.module, callee.node);
                let mut snap = Vector::<mbe::MSub>::new();
                for i7 in 0..self.mg.subs.len() {
                    snap.push(*self.mg.subs.at(i7));
                }
                snap.push(mbe::MSub { pm: callee.module, pnode: idecl, am: rm6, at: rt6 });
                self.demand.push(Demand { def: callee, sym: sym.clone(), subs: snap, sfx: String::new() });
            }
        }
        dst.push_string(&sym);
        sym.free();
        return true;
    }

    // ---- dyn: fat values, vtables, thunks --------------------------------------------------------

    /// One vtable member declarator: `<ret> (*<name>)(void *self[, <param types>])`. `all_params`
    /// keeps every param (structural `dyn fn` stems); interfaces skip param 0 (the receiver).
    fn dyn_sig(self: &mut Self, dm: ModuleId, ps: NodeList, rs: NodeList, all_params: bool, name: str, o: &mut String) bool {
        let da = self.p().module_ast_const(dm);
        let mut ret = String::new();
        let mut ok = true;
        if rs.len == 0 {
            ret.push_str("void");
        } else if rs.len == 1 {
            let r0 = unsafe da.list(rs)[0];
            let rn = da.at_const(r0);
            let mut tn = r0;
            if rn.kind == NodeKind::NODE_PARAMETER {
                tn = rn.as_data.parameter.ty;
            }
            ok = self.mg.ctype(dm, da.type_of(tn), "", &mut ret);
        } else {
            ok = false; // multi-return never dyn-dispatches (fn-pointer rule)
        }
        if ok {
            o.push_string(&ret);
            o.push_str(" (*");
            o.push_str(name);
            o.push_str(")(void *self");
            let start: u32 = if all_params {
                0;
            } else {
                1;
            };
            for i in start..ps.len {
                if !ok {
                    break;
                }
                let pid = unsafe da.list(ps)[i as usize];
                o.push_str(", ");
                ok = self.mg.ctype(dm, da.type_of(pid), "", o);
            }
            o.push_str(")");
        }
        ret.free();
        if !ok {
            return self.fail("dyn-sig");
        }
        return true;
    }

    /// Ensure the `SC_DYN_<stem>` typedef block (vtable struct + fat value + inline free) is in
    /// `dyn_defs`. Interface vtables carry `__free`/`tid` then every self-taking member in decl
    /// order (defaults included); structural `dyn fn` vtables carry `__free` then `call`.
    pub fn dyn_request(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let y = *self.p().module_ast_const(pm).type_at(t);
        if y.kind != TypeKind::TYPE_DYN {
            return self.fail("dyn-req");
        }
        let mut stem = String::new();
        if !self.mg.dyn_stem(pm, &y, &mut stem) {
            stem.free();
            return self.fail("dyn-stem");
        }
        let mut h = 1469598103934665603u64;
        {
            let ss = stem.as_str();
            for k in 0..ss.len() {
                h = (h ^ ss.byte_at(k) as u64) * 1099511628211u64;
            }
        }
        let seen = switch self.dyn_def_seen.get(&h) {
            Some(_v) => true,
            None => false,
        };
        if seen {
            stem.free();
            return true;
        }
        self.dyn_def_seen.insert(h, 1);
        let a = self.p().module_ast_const(pm);
        let it = *a.instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        let dn = da.at_const(it.decl);
        let mut o = String::new();
        o.push_str("#ifndef SC_DYN_");
        o.push_string(&stem);
        o.push_str("\n#define SC_DYN_");
        o.push_string(&stem);
        o.push_str("\ntypedef struct ");
        o.push_string(&stem);
        o.push_str("__vt {\n    void (*__free)(void *self);\n");
        let mut ok = true;
        if dn.kind == NodeKind::NODE_FUNCTION_TYPE {
            o.push_str("    ");
            ok = self.dyn_sig(
                it.module,
                dn.as_data.function_type.params,
                dn.as_data.function_type.returns,
                true,
                "call",
                &mut o,
            );
            o.push_str(";\n");
        } else {
            o.push_str("    const char *tid;\n");
            // a generic interface's params bind to the dyn instance's args for signature spelling
            let gs = dn.as_data.interface_def.generics;
            let mut nb: usize = 0;
            let mut gi: u32 = 0;
            while gi < gs.len && gi as u8 < it.n {
                self.mg.push_sub(it.module, unsafe da.list(gs)[gi as usize], pm, unsafe it.args[gi as usize]);
                nb += 1;
                gi += 1;
            }
            let ms = dn.as_data.interface_def.items;
            for i in 0..ms.len {
                if !ok {
                    break;
                }
                let mid = unsafe da.list(ms)[i as usize];
                let mn = da.at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
                    continue; // receiver-less members never dyn-dispatch
                }
                o.push_str("    ");
                let mut nm = String::new();
                self.mg.ident(it.module, da.at_const(mn.as_data.function.name).as_data.name.text, &mut nm);
                ok = self.dyn_sig(
                    it.module,
                    mn.as_data.function.params,
                    mn.as_data.function.returns,
                    false,
                    nm.as_str(),
                    &mut o,
                );
                nm.free();
                o.push_str(";\n");
            }
            self.mg.pop_subs(nb);
        }
        o.push_str("} ");
        o.push_string(&stem);
        o.push_str("__vt;\ntypedef struct ");
        o.push_string(&stem);
        o.push_str("__dyn { void *data; const ");
        o.push_string(&stem);
        o.push_str("__vt *vt; } ");
        o.push_string(&stem);
        o.push_str("__dyn;\nstatic inline void ");
        o.push_string(&stem);
        o.push_str("__dyn_free(");
        o.push_string(&stem);
        o.push_str("__dyn *const d) { d->vt->__free(d->data); }\n#endif\n");
        if ok {
            self.dyn_defs.push_string(&o);
        }
        o.free();
        stem.free();
        return ok;
    }

    /// Thunks + the vtable definition for one coercion pair (source type -> dyn stem); `own` makes
    /// the vtable's `__free` destroy and deallocate the heap payload. Appends `<pair>` to `pair`.
    fn dyn_pair(self: &mut Self, pm: ModuleId, dt: TypeId, srm: ModuleId, srt: TypeId, own: bool, pair: &mut String) bool {
        let y = *self.p().module_ast_const(pm).type_at(dt);
        if y.kind != TypeKind::TYPE_DYN || !self.dyn_request(pm, dt) {
            return self.fail("dyn-req");
        }
        let mut stem = String::new();
        if !self.mg.dyn_stem(pm, &y, &mut stem) {
            stem.free();
            return self.fail("dyn-stem");
        }
        let mut src = String::new();
        if !self.mg.type_m(srm, srt, &mut src) {
            src.free();
            stem.free();
            return self.fail("dyn-src");
        }
        pair.push_string(&src);
        pair.push_str("__");
        pair.push_string(&stem);
        let mut h = 1469598103934665603u64;
        {
            let ps2 = pair.as_str();
            for k in 0..ps2.len() {
                h = (h ^ ps2.byte_at(k) as u64) * 1099511628211u64;
            }
        }
        let seen = switch self.dyn_tab_seen.get(&h) {
            Some(_v) => true,
            None => false,
        };
        if seen {
            src.free();
            stem.free();
            return true;
        }
        self.dyn_tab_seen.insert(h, 1);
        let sy = *self.p().module_ast_const(srm).type_at(srt);
        let is_clos = sy.kind == TypeKind::TYPE_FUNCTION;
        let mut srcc = String::new();
        let mut ok = self.mg.ctype(srm, srt, "", &mut srcc);
        let a = self.p().module_ast_const(pm);
        let it = *a.instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        let dn = da.at_const(it.decl);
        let mut tabs = String::new();
        let mut slots = String::new();
        if ok && dn.kind == NodeKind::NODE_FUNCTION_TYPE {
            // one `call` thunk into the hoisted closure body (env passed as the erased data)
            if !is_clos {
                ok = self.fail("dyn-fnval");
            }
            if ok {
                let cd = self.p().module_ast_const(sy.module).at_const(sy.as_data.decl);
                if cd.kind != NodeKind::NODE_CLOSURE || cd.as_data.closure.captures.len == 0 {
                    ok = self.fail("dyn-fnval");
                }
            }
            if ok {
                ok = self.dyn_thunk(
                    it.module,
                    NODE_NONE,
                    dn.as_data.function_type.params,
                    dn.as_data.function_type.returns,
                    true,
                    "call",
                    pair.as_str(),
                    srcc.as_str(),
                    srm,
                    srt,
                    &mut tabs,
                );
                slots.push_str(", ");
                slots.push_string(pair);
                slots.push_str("__call");
            }
        } else if ok {
            slots.push_str(", \"");
            slots.push_string(&src);
            slots.push_str("\"");
            let gs = dn.as_data.interface_def.generics;
            let mut nb: usize = 0;
            let mut gi: u32 = 0;
            while gi < gs.len && gi as u8 < it.n {
                self.mg.push_sub(it.module, unsafe da.list(gs)[gi as usize], pm, unsafe it.args[gi as usize]);
                nb += 1;
                gi += 1;
            }
            let ms = dn.as_data.interface_def.items;
            for i in 0..ms.len {
                if !ok {
                    break;
                }
                let mid = unsafe da.list(ms)[i as usize];
                let mn = da.at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.params.len == 0 {
                    continue;
                }
                let mut nm = String::new();
                self.mg.ident(it.module, da.at_const(mn.as_data.function.name).as_data.name.text, &mut nm);
                ok = self.dyn_thunk(
                    it.module,
                    mid,
                    mn.as_data.function.params,
                    mn.as_data.function.returns,
                    false,
                    nm.as_str(),
                    pair.as_str(),
                    srcc.as_str(),
                    srm,
                    srt,
                    &mut tabs,
                );
                if ok {
                    // the thunk body dispatches like a direct call would (custom impl or default)
                    slots.push_str(", ");
                    slots.push_string(pair);
                    slots.push_str("__");
                    slots.push_string(&nm);
                }
                nm.free();
            }
            self.mg.pop_subs(nb);
        }
        let mut fslot = String::from_str("0");
        if ok && own {
            fslot.truncate(0);
            fslot.push_string(pair);
            fslot.push_str("____free");
            tabs.push_str("static void ");
            tabs.push_string(&fslot);
            tabs.push_str("(void *__self) {\n");
            if self.is_destructible(srm, srt, 0) {
                let mut fe = String::new();
                ok = self.free_expr(srm, srt, &mut fe);
                if ok {
                    tabs.push_str("    ");
                    tabs.push_string(&fe);
                    tabs.push_str("((");
                    tabs.push_string(&srcc);
                    tabs.push_str(" *)__self);\n");
                }
                fe.free();
            }
            tabs.push_str("    Global __g = (Global){};\n    Global__dealloc(&__g, __self, sizeof(");
            tabs.push_string(&srcc);
            tabs.push_str("), _Alignof(");
            tabs.push_string(&srcc);
            tabs.push_str("));\n}\n");
        }
        if ok {
            tabs.push_str("const ");
            tabs.push_string(&stem);
            tabs.push_str("__vt ");
            tabs.push_string(pair);
            tabs.push_str("__vtbl = { ");
            tabs.push_string(&fslot);
            tabs.push_string(&slots);
            tabs.push_str(" };\n");
            self.dyn_tabs.push_string(&tabs);
            self.dyn_decls.push_str("extern const ");
            self.dyn_decls.push_string(&stem);
            self.dyn_decls.push_str("__vt ");
            self.dyn_decls.push_string(pair);
            self.dyn_decls.push_str("__vtbl;\n");
        }
        fslot.free();
        slots.free();
        tabs.free();
        srcc.free();
        src.free();
        stem.free();
        return ok;
    }

    // The declared single return type of `fnid` (pool `m`), or TYPE_NONE.
    fn fn_ret_ty(self: &Self, m: ModuleId, fnid: NodeId) TypeId {
        let a = self.p().module_ast_const(m);
        let rs = a.at_const(fnid).as_data.function.returns;
        if rs.len != 1 {
            return TYPE_NONE;
        }
        let r0 = unsafe a.list(rs)[0];
        let rn = a.at_const(r0);
        let mut tn = r0;
        if rn.kind == NodeKind::NODE_PARAMETER {
            tn = rn.as_data.parameter.ty;
        }
        return a.type_of(tn);
    }

    /// One `--test` wrapper: `void __sc_test_w_<m>_<node>(void *__genv)` constructing the fixture
    /// when the case wants one, calling the case, then tearing the fixture down (user teardown
    /// first, then the type's own free -- the established wrapper shape).
    pub fn emit_test_wrapper(
        self: &mut Self,
        tm: ModuleId,
        func: NodeId,
        wants: u8,
        fx_init: NodeId,
        fx_free: NodeId,
        genv_m: ModuleId,
        genv_init: NodeId,
    ) bool {
        self.err = "";
        let mut fname = String::new();
        let tgt = self.mg.method_target(tm, func);
        if !self.mg.fn_sym(tm, func, tgt, true, &mut fname) {
            fname.free();
            return self.fail("test-sym");
        }
        self.out.push_str("void __sc_test_w_");
        self.out.push_u64(tm);
        self.out.push_str("_");
        self.out.push_u64(func);
        self.out.push_str("(void *__genv) {\n  (void)__genv;\n");
        let mut ok = true;
        let mut fxt = TYPE_NONE;
        if (wants & 1) != 0 {
            fxt = self.fn_ret_ty(tm, fx_init);
            if fxt == TYPE_NONE {
                ok = self.fail("test-fx");
            }
            if ok {
                let mut dl = String::new();
                ok = self.mg.ctype(tm, fxt, "__fx", &mut dl);
                if ok {
                    let mut isym = String::new();
                    ok = self.mg.fn_sym(tm, fx_init, self.mg.method_target(tm, fx_init), true, &mut isym);
                    if ok {
                        self.out.push_str("  ");
                        self.out.push_string(&dl);
                        self.out.push_str(" = ");
                        self.out.push_string(&isym);
                        self.out.push_str("();\n");
                    }
                    isym.free();
                }
                dl.free();
            }
        }
        if ok {
            self.out.push_str("  ");
            self.out.push_string(&fname);
            self.out.push_str("(");
            if (wants & 1) != 0 {
                self.out.push_str("&__fx");
            }
            if (wants & 2) != 0 {
                if (wants & 1) != 0 {
                    self.out.push_str(", ");
                }
                let gt = self.fn_ret_ty(genv_m, genv_init);
                let mut gc = String::new();
                ok = gt != TYPE_NONE && self.mg.ctype(genv_m, gt, "", &mut gc);
                if ok {
                    self.out.push_str("(const ");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__genv");
                } else {
                    let _ = self.fail("test-genv");
                }
                gc.free();
            }
            self.out.push_str(");\n");
        }
        if ok && (wants & 1) != 0 && fx_free != NODE_NONE {
            let mut fsym = String::new();
            ok = self.mg.fn_sym(tm, fx_free, self.mg.method_target(tm, fx_free), true, &mut fsym);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&fsym);
                self.out.push_str("(&__fx);\n");
            }
            fsym.free();
        }
        if ok && (wants & 1) != 0 && self.is_destructible(tm, fxt, 0) {
            let mut fe = String::new();
            ok = self.free_expr(tm, fxt, &mut fe);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&fe);
                self.out.push_str("(&__fx);\n");
            }
            fe.free();
        }
        self.out.push_str("}\n");
        fname.free();
        return ok;
    }

    /// The global-env hooks: `__sc_test_genv_init` keeps the env in a static cell; `_free` runs the
    /// user teardown then the type's own free.
    pub fn emit_test_genv(self: &mut Self, gm: ModuleId, ginit: NodeId, gfree: NodeId) bool {
        self.err = "";
        let gt = self.fn_ret_ty(gm, ginit);
        if gt == TYPE_NONE {
            return self.fail("test-genv");
        }
        let mut gdecl = String::new();
        let mut gc = String::new();
        let mut isym = String::new();
        let mut ok = self.mg.ctype(gm, gt, "__sc_genv", &mut gdecl) && self.mg.ctype(gm, gt, "", &mut gc) && self.mg.fn_sym(
            gm,
            ginit,
            self.mg.method_target(gm, ginit),
            true,
            &mut isym,
        );
        if ok {
            self.out.push_str("void *__sc_test_genv_init(void) { static ");
            self.out.push_string(&gdecl);
            self.out.push_str("; __sc_genv = ");
            self.out.push_string(&isym);
            self.out.push_str("(); return &__sc_genv; }\n");
            self.out.push_str("void __sc_test_genv_free(void *__p) {\n  (void)__p;\n");
            if gfree != NODE_NONE {
                let mut fsym = String::new();
                ok = self.mg.fn_sym(gm, gfree, self.mg.method_target(gm, gfree), true, &mut fsym);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&fsym);
                    self.out.push_str("((");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__p);\n");
                }
                fsym.free();
            }
            if ok && self.is_destructible(gm, gt, 0) {
                let mut fe = String::new();
                ok = self.free_expr(gm, gt, &mut fe);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&fe);
                    self.out.push_str("((");
                    self.out.push_string(&gc);
                    self.out.push_str(" *)__p);\n");
                }
                fe.free();
            }
            self.out.push_str("}\n");
        }
        gdecl.free();
        gc.free();
        isym.free();
        if !ok && self.err.len() == 0 {
            return self.fail("test-genv");
        }
        return ok;
    }

    /// One dispatch thunk: `static <ret> <pair>__<name>(void *__self, ...) { [return] <impl>((<srcc> *)__self, ...); }`.
    /// Interface thunks number args by source param index (`_a1`...); `dyn fn` thunks from `_a0`.
    fn dyn_thunk(
        self: &mut Self,
        dm: ModuleId,
        mid: NodeId,
        ps: NodeList,
        rs: NodeList,
        all_params: bool,
        name: str,
        pair: str,
        srcc: str,
        srm: ModuleId,
        srt: TypeId,
        tabs: &mut String,
    ) bool {
        let da = self.p().module_ast_const(dm);
        let mut ret = String::new();
        let mut ok = true;
        let mut is_void = false;
        if rs.len == 0 {
            ret.push_str("void");
            is_void = true;
        } else if rs.len == 1 {
            let r0 = unsafe da.list(rs)[0];
            let rn = da.at_const(r0);
            let mut tn = r0;
            if rn.kind == NodeKind::NODE_PARAMETER {
                tn = rn.as_data.parameter.ty;
            }
            ok = self.mg.ctype(dm, da.type_of(tn), "", &mut ret);
        } else {
            ok = false;
        }
        let mut head = String::new();
        let start: u32 = if all_params {
            0;
        } else {
            1;
        };
        if ok {
            head.push_str("static ");
            head.push_string(&ret);
            head.push_str(" ");
            head.push_str(pair);
            head.push_str("__");
            head.push_str(name);
            head.push_str("(void *__self");
            for i in start..ps.len {
                if !ok {
                    break;
                }
                let pid = unsafe da.list(ps)[i as usize];
                head.push_str(", ");
                let mut an = String::from_str("_a");
                an.push_u64(i);
                ok = self.mg.ctype(dm, da.type_of(pid), an.as_str(), &mut head);
                an.free();
            }
        }
        let sy = *self.p().module_ast_const(srm).type_at(srt);
        if ok {
            head.push_str(") { ");
            if !is_void {
                head.push_str("return ");
            }
            if sy.kind == TypeKind::TYPE_FUNCTION {
                let mut cs = String::new();
                self.mg.closure_sym(sy.module, sy.as_data.decl, &mut cs);
                head.push_string(&cs);
                head.push_str("((const ");
                head.push_str(srcc);
                head.push_str(" *)__self");
                cs.free();
            } else if mid == NODE_NONE {
                ok = self.fail("dyn-thunk");
            } else {
                ok = self.iface_target_sym(srm, srt, DefId { module: dm, node: mid }, &mut head);
                head.push_str("((");
                head.push_str(srcc);
                head.push_str(" *)__self");
            }
            for i in start..ps.len {
                head.push_str(", _a");
                head.push_u64(i);
            }
            head.push_str("); }\n");
        }
        if ok {
            tabs.push_string(&head);
        }
        head.free();
        ret.free();
        return ok;
    }

    fn callee_sym(
        self: &mut Self,
        b: &ir::CoreBody,
        callee: DefId,
        targs_start: u32,
        targs_len: u32,
        recv_ty: TypeId,
        dest_ty: TypeId,
        dst: &mut String,
    ) bool {
        let mut sym = String::new();
        let mut ok = true;
        // an interface member with a DEFAULT body emits once per conforming type:
        // `<ifacepfx><Target>__<method>` for concrete receivers, `<InstName>__<method>` for instances
        if self.mg.in_interface(callee.module, callee.node) != NODE_NONE {
            let mut rm6 = b.module;
            let mut rt6 = recv_ty;
            let mut got = false;
            if recv_ty != TYPE_NONE {
                self.rty(b, recv_ty, &mut rm6, &mut rt6);
                let mut g6 = 0;
                while g6 < 4 {
                    let y6 = *self.p().module_ast_const(rm6).type_at(rt6);
                    if y6.kind != TypeKind::TYPE_POINTER && y6.kind != TypeKind::TYPE_REFERENCE {
                        break;
                    }
                    let mut nm6 = rm6;
                    let mut nt6 = y6.as_data.elem;
                    if !self.mg.resolve(rm6, y6.as_data.elem, &mut nm6, &mut nt6) {
                        break;
                    }
                    rm6 = nm6;
                    rt6 = nt6;
                    g6 += 1;
                }
                let k6 = self.p().module_ast_const(rm6).type_at(rt6).kind;
                got = k6 == TypeKind::TYPE_STRUCT || k6 == TypeKind::TYPE_ENUM || k6 == TypeKind::TYPE_INSTANCE || k6 == TypeKind::TYPE_BUILTIN;
            }
            if !got && dest_ty != TYPE_NONE {
                self.rty(b, dest_ty, &mut rm6, &mut rt6);
                let k6 = self.p().module_ast_const(rm6).type_at(rt6).kind;
                got = k6 == TypeKind::TYPE_STRUCT || k6 == TypeKind::TYPE_ENUM || k6 == TypeKind::TYPE_INSTANCE || k6 == TypeKind::TYPE_BUILTIN;
            }
            if !got {
                sym.free();
                return self.fail("iface-default-recv");
            }
            sym.free();
            return self.iface_target_sym(rm6, rt6, callee, dst);
        }
        let is_minst = self.mg.in_generic_extend(callee.module, callee.node);
        let mut rit = TyInstance { decl: NODE_NONE };
        let mut rpm = b.module; // the pool the receiver instance (and its args) live in
        if is_minst {
            // a generic extend's method emits per receiver instance: `<InstName>__<method>`
            let tgt = self.mg.method_target(callee.module, callee.node);
            rit = self.recv_inst(b, recv_ty, tgt, &mut rpm);
            if rit.decl == NODE_NONE {
                rit = self.recv_inst(b, dest_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE {
                sym.free();
                return self.fail("method-inst");
            }
            if !self.mg.inst_name(rpm, &rit, &mut sym) {
                ok = self.fail("callee-inst");
            }
            if ok {
                sym.push_str("__");
                let ca = self.p().module_ast_const(callee.module);
                self.mg.ident(
                    callee.module,
                    ca.at_const(ca.at_const(callee.node).as_data.function.name).as_data.name.text,
                    &mut sym,
                );
            }
        } else {
            let tgt = self.mg.method_target(callee.module, callee.node);
            if !self.mg.fn_sym(callee.module, callee.node, tgt, true, &mut sym) {
                ok = self.fail("callee-sym");
            }
        }
        for k in 0..targs_len {
            if !ok {
                break;
            }
            sym.push_str("__");
            if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k) as usize], &mut sym) {
                ok = self.fail("callee-targ");
            }
        }
        if ok && self.collect_demand && (is_minst || targs_len != 0) {
            let ca = self.p().module_ast_const(callee.module);
            let fd = ca.at_const(callee.node);
            if fd.kind == NodeKind::NODE_FUNCTION && !fd.as_data.function.is_extern && fd.as_data.function.body != NODE_NONE {
                let mut snap = Vector::<mbe::MSub>::new();
                for i in 0..self.mg.subs.len() {
                    snap.push(*self.mg.subs.at(i));
                }
                if is_minst {
                    // both the extend's params AND the struct declaration's own params bind to the
                    // receiver arguments: body types reference either decl
                    let eg = self.mg.extend_generics(callee.module, callee.node);
                    let mut gi: u32 = 0;
                    while gi < eg.len && gi as u8 < rit.n {
                        self.push_bind(
                            &mut snap,
                            callee.module,
                            unsafe ca.list(eg)[gi as usize],
                            rpm,
                            unsafe rit.args[gi as usize],
                        );
                        gi += 1;
                    }
                    let ra = self.p().module_ast_const(rit.module);
                    let sg = ra.at_const(rit.decl).as_data.aggregate.generics;
                    let mut gj: u32 = 0;
                    while gj < sg.len && gj as u8 < rit.n {
                        self.push_bind(
                            &mut snap,
                            rit.module,
                            unsafe ra.list(sg)[gj as usize],
                            rpm,
                            unsafe rit.args[gj as usize],
                        );
                        gj += 1;
                    }
                }
                let gens = fd.as_data.function.generics;
                let mut gi2: u32 = 0;
                while gi2 < gens.len && gi2 < targs_len {
                    self.push_bind(
                        &mut snap,
                        callee.module,
                        unsafe ca.list(gens)[gi2 as usize],
                        b.module,
                        b.targ_pool[(targs_start + gi2) as usize],
                    );
                    gi2 += 1;
                }
                let mut sfx = String::new();
                let mut sok = true;
                if is_minst {
                    for i2 in 0..rit.n {
                        sfx.push_str("__");
                        if !self.mg.type_m(rpm, unsafe rit.args[i2 as usize], &mut sfx) {
                            sok = false;
                            break;
                        }
                    }
                } else {
                    for k2 in 0..targs_len {
                        sfx.push_str("__");
                        if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k2) as usize], &mut sfx) {
                            sok = false;
                            break;
                        }
                    }
                }
                if sok {
                    self.demand.push(Demand { def: callee, sym: sym.clone(), subs: snap, sfx: sfx });
                } else {
                    sfx.free();
                    snap.free();
                }
            }
        }
        if ok {
            dst.push_string(&sym);
        }
        sym.free();
        return ok;
    }

    fn emit_rvalue(self: &mut Self, b: &ir::CoreBody, rid: ir::RvalueId, dst: &mut String) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            return self.emit_operand(b, rv.a, dst);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR {
            // cast to the recorded result type: u8 buffers reborrowed as char pointers (and
            // const-ness adjustments) are checker-approved
            if rv.target != TYPE_NONE {
                let mut ts = String::new();
                let ok0 = self.ty_c(b.module, rv.target, "", &mut ts);
                if ok0 {
                    dst.push_str("(");
                    dst.push_string(&ts);
                    dst.push_str(")");
                }
                ts.free();
                if !ok0 {
                    return false;
                }
            }
            dst.push_str("&");
            return self.emit_place(b, rv.a, dst);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b == ir::CAST_COERCE_FROM {
                // the checker's selected conversion method, called as a plain C expression
                let cvr = b.operands.at(rv.a as usize).ty;
                let mut ok = self.callee_sym(b, rv.item, 0, 0, cvr, rv.target, dst);
                if ok {
                    dst.push_str("(");
                    ok = self.emit_call_arg(b, rv.item, 0, rv.a, dst);
                    dst.push_str(")");
                }
                return ok;
            }
            if rv.b != ir::CAST_NUMERIC && rv.b != ir::CAST_POINTER {
                return self.fail("cast");
            }
            let mut ts = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut ts);
            if ok {
                dst.push_str("(");
                dst.push_string(&ts);
                dst.push_str(")");
            }
            ts.free();
            if ok {
                ok = self.emit_operand(b, rv.a, dst);
            }
            return ok;
        }
        if rv.kind == ir::RV_UNARY {
            let t = (rv.b as u8) as tt::TokenType;
            if t == tt::TokenType::Unsafe {
                // the `unsafe` prefix carries no C
            } else if t == tt::TokenType::Minus {
                dst.push_str("-");
            } else if t == tt::TokenType::Bang {
                dst.push_str("!");
            } else if t == tt::TokenType::Tilde {
                dst.push_str("~");
            } else {
                return self.fail("unary");
            }
            return self.emit_operand(b, rv.a, dst);
        }
        if rv.kind == ir::RV_BINARY {
            let t = rv.c as tt::TokenType;
            if t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual {
                // pattern tests compare `str` VALUES; C has no struct ==
                let aop = *b.operands.at(rv.a as usize);
                let mut rm4 = b.module;
                let mut rt4 = aop.ty;
                self.rty(b, aop.ty, &mut rm4, &mut rt4);
                if self.is_str_ty(rm4, rt4) {
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    dst.push_str("__sc_str_eq(");
                    let mut ok4 = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", ");
                    if ok4 {
                        ok4 = self.emit_operand(b, rv.b, dst);
                    }
                    dst.push_str(")");
                    return ok4;
                }
                let k4 = self.p().module_ast_const(rm4).type_at(rt4).kind;
                if k4 == TypeKind::TYPE_STRUCT || k4 == TypeKind::TYPE_INSTANCE {
                    // aggregate equality dispatches through the type's `eq` (checker-approved)
                    let mut es = String::new();
                    if !self.mg.method_by_name(rm4, rt4, "eq", &mut es) {
                        es.free();
                        return self.fail("struct-eq");
                    }
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    dst.push_string(&es);
                    es.free();
                    dst.push_str("(&");
                    let mut ok4 = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", &");
                    if ok4 {
                        ok4 = self.emit_operand(b, rv.b, dst);
                    }
                    dst.push_str(")");
                    return ok4;
                }
            }
            let mut op: str<'static> = "";
            if t == tt::TokenType::Plus {
                op = "+";
            } else if t == tt::TokenType::Minus {
                op = "-";
            } else if t == tt::TokenType::Star {
                op = "*";
            } else if t == tt::TokenType::Slash {
                op = "/";
            } else if t == tt::TokenType::Percent {
                op = "%";
            } else if t == tt::TokenType::Ampersand || t == tt::TokenType::AmpersandAmpersand {
                op = "&";
            } else if t == tt::TokenType::Pipe || t == tt::TokenType::PipePipe {
                op = "|";
            } else if t == tt::TokenType::Caret {
                op = "^";
            } else if t == tt::TokenType::LeftShift {
                op = "<<";
            } else if t == tt::TokenType::RightShift {
                op = ">>";
            } else if t == tt::TokenType::EqualEqual {
                op = "==";
            } else if t == tt::TokenType::BangEqual {
                op = "!=";
            } else if t == tt::TokenType::LessThan {
                op = "<";
            } else if t == tt::TokenType::LessThanEqual {
                op = "<=";
            } else if t == tt::TokenType::GreaterThan {
                op = ">";
            } else if t == tt::TokenType::GreaterThanEqual {
                op = ">=";
            } else {
                return self.fail("binary");
            }
            dst.push_str("(");
            let mut ok = self.emit_operand(b, rv.a, dst);
            if ok {
                dst.push_str(" ");
                dst.push_str(op);
                dst.push_str(" ");
                ok = self.emit_operand(b, rv.b, dst);
            }
            dst.push_str(")");
            return ok;
        }
        if rv.kind == ir::RV_AGGREGATE {
            return self.emit_aggregate(b, &rv, dst);
        }
        if rv.kind == ir::RV_SLICE {
            return self.emit_slice(b, &rv, dst);
        }
        if rv.kind == ir::RV_LEN {
            let pl = *b.places.at(rv.a as usize);
            let mut rm = b.module;
            let mut rt = pl.ty;
            self.rty(b, pl.ty, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0 {
                dst.push_u64(y.as_data.arr.len);
                return true;
            }
            return self.fail("len");
        }
        if rv.kind == ir::RV_DISCRIMINANT {
            let pl = *b.places.at(rv.a as usize);
            let mut rm0 = b.module;
            let mut rt0 = pl.ty;
            self.rty(b, pl.ty, &mut rm0, &mut rt0);
            let mut derefs: u32 = 0;
            let mut guard = 0;
            while guard < 4 {
                let y0 = *self.p().module_ast_const(rm0).type_at(rt0);
                if y0.kind != TypeKind::TYPE_POINTER && y0.kind != TypeKind::TYPE_REFERENCE {
                    break;
                }
                let el0 = y0.as_data.elem;
                let mut rm1 = rm0;
                let mut rt1 = el0;
                if !self.mg.resolve(rm0, el0, &mut rm1, &mut rt1) {
                    break;
                }
                rm0 = rm1;
                rt0 = rt1;
                derefs += 1;
                guard += 1;
            }
            let decl = self.agg_decl_res(rm0, rt0);
            if decl == NODE_NONE {
                return self.fail("discr");
            }
            let am = self.agg_module_res(rm0, rt0);
            for _d in 0..derefs {
                dst.push_str("(*");
            }
            let ok = self.emit_place(b, rv.a, dst);
            for _d in 0..derefs {
                dst.push_str(")");
            }
            if ok && self.enum_has_payload(am, decl) {
                dst.push_str(".tag");
            }
            return ok;
        }
        if rv.kind == ir::RV_INTRINSIC {
            let k = rv.c as u32;
            if k == ir::IN_SIZEOF as u32 || k == ir::IN_ALIGNOF as u32 {
                let mut ts = String::new();
                let ok = self.ty_c(b.module, rv.b, "", &mut ts);
                if ok {
                    dst.push_str(if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                    dst.push_string(&ts);
                    dst.push_str(")");
                }
                ts.free();
                return ok;
            }
            if k == ir::IN_TYPE_INFO as u32 {
                if rv.b == TYPE_NONE {
                    return self.fail("type-info");
                }
                let mut rm = b.module;
                let mut rt = rv.b;
                self.rty(b, rv.b, &mut rm, &mut rt);
                let mut mg9 = String::new();
                if !self.mg.type_m(rm, rt, &mut mg9) {
                    mg9.free();
                    return self.fail("type-info");
                }
                let mut sym = String::from_str("__sc_ti__");
                sym.push_string(&mg9);
                let mut h = 1469598103934665603u64;
                {
                    let ss = sym.as_str();
                    for k2 in 0..ss.len() {
                        h = (h ^ ss.byte_at(k2) as u64) * 1099511628211u64;
                    }
                }
                let fresh = switch self.ti_seen.get(&h) {
                    Some(_v) => false,
                    None => true,
                };
                if fresh {
                    self.ti_seen.insert(h, 1);
                    self.ti_reqs.push(
                        StatRef { em: rm, def: DefId { module: 0, node: NODE_NONE }, sym: sym.clone(), ty: rt },
                    );
                }
                dst.push_string(&sym);
                sym.free();
                mg9.free();
                return true;
            }
            if k == ir::IN_ZEROED as u32 {
                let mut ts = String::new();
                let ok = self.ty_c(b.module, rv.target, "", &mut ts);
                if ok {
                    dst.push_str("(");
                    dst.push_string(&ts);
                    dst.push_str("){0}");
                }
                ts.free();
                return ok;
            }
            return self.fail("intrinsic");
        }
        if rv.kind == ir::RV_CLOSURE {
            // env literal `(closure_N_env){ .cap = op, ... }`; a capture-less closure value is the
            // bare hoisted function; mutable captures (pointer cells) stay unfrozen
            let cm = rv.item.module;
            let cn = rv.item.node;
            let ca = self.p().module_ast_const(cm);
            if rv.b == 0 {
                self.mg.closure_sym(cm, cn, dst);
                return true;
            }
            if ca.at_const(cn).as_data.closure.mut_caps != 0 {
                return self.fail("closure-mut");
            }
            let caps = ca.at_const(cn).as_data.closure.captures;
            if caps.len != rv.b {
                return self.fail("closure-caps");
            }
            dst.push_str("(");
            let mut nm = String::new();
            self.mg.closure_sym(cm, cn, &mut nm);
            dst.push_string(&nm);
            nm.free();
            dst.push_str("_env){ ");
            let mut ok = true;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                if i != 0 {
                    dst.push_str(", ");
                }
                dst.push_str(".");
                let decl = unsafe ca.list(caps)[i as usize];
                let csp = self.mg.decl_name_span(cm, decl);
                if csp.end <= csp.start {
                    ok = self.fail("closure-cap-name");
                    break;
                }
                self.mg.ident(cm, csp, dst);
                dst.push_str(" = ");
                ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
            }
            dst.push_str(" }");
            return ok;
        }
        if rv.kind == ir::RV_DYN {
            // borrowed erasure: the operand is already a pointer. Owned erasures (Box payloads,
            // boxed closure envs) are statement-level (emit_stmt intercepts them).
            let oty = b.operands.at(rv.a as usize).ty;
            let mut om = b.module;
            let mut ot = oty;
            self.rty(b, oty, &mut om, &mut ot);
            let oy = *self.p().module_ast_const(om).type_at(ot);
            let mut dm = b.module;
            let mut dt = rv.target;
            self.rty(b, rv.target, &mut dm, &mut dt);
            let mut tc = String::new();
            let mut pair = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut tc);
            if ok && (oy.kind == TypeKind::TYPE_REFERENCE || oy.kind == TypeKind::TYPE_POINTER) {
                let mut em = om;
                let mut et = oy.as_data.elem;
                if !self.mg.resolve(om, oy.as_data.elem, &mut em, &mut et) {
                    ok = self.fail("dyn-src");
                }
                if ok {
                    ok = self.dyn_pair(dm, dt, em, et, false, &mut pair);
                }
                if ok {
                    dst.push_str("((");
                    dst.push_string(&tc);
                    dst.push_str("){ .data = (void *)");
                    ok = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", .vt = &");
                    dst.push_string(&pair);
                    dst.push_str("__vtbl })");
                }
            } else if ok {
                // owned Box source: the payload pointer moves into the fat value
                let mut boxed = false;
                if oy.kind == TypeKind::TYPE_INSTANCE {
                    let a9 = self.p().module_ast_const(om);
                    let it9 = *a9.instance(oy.as_data.inst);
                    let d9 = self.p().module_ast_const(it9.module);
                    let n9 = d9.at_const(d9.at_const(it9.decl).as_data.aggregate.name).as_data.name.text;
                    let s9 = self.p().modules.at(it9.module as usize).source.as_str();
                    if s9.slice(n9.start as usize, n9.end as usize) == "Box" && it9.n > 0 {
                        let mut em = om;
                        let mut et = it9.args[0];
                        if !self.mg.resolve(om, it9.args[0], &mut em, &mut et) {
                            ok = self.fail("dyn-src");
                        }
                        if ok {
                            ok = self.dyn_pair(dm, dt, em, et, true, &mut pair);
                        }
                        boxed = ok;
                        if ok {
                            dst.push_str("((");
                            dst.push_string(&tc);
                            dst.push_str("){ .data = (void *)(");
                            ok = self.emit_operand(b, rv.a, dst);
                            dst.push_str(").ptr, .vt = &");
                            dst.push_string(&pair);
                            dst.push_str("__vtbl })");
                        }
                    }
                }
                if ok && !boxed {
                    ok = self.fail("dyn-owned");
                }
            }
            tc.free();
            pair.free();
            return ok;
        }
        return self.fail("rvalue");
    }

    // `(View){ .ptr = <base storage> + lo, .len = (<hi>|<container len>) [+1] - lo }` -- str,
    // Slice-family instances (ptr/len members) and fixed arrays slice structurally.
    fn emit_slice(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, dst: &mut String) bool {
        let bpl = *b.places.at(rv.a as usize);
        let mut rm = b.module;
        let mut rt = bpl.ty;
        self.rty(b, bpl.ty, &mut rm, &mut rt);
        let by = *self.p().module_ast_const(rm).type_at(rt);
        let is_arr = by.kind == TypeKind::TYPE_ARRAY;
        if !is_arr && by.kind != TypeKind::TYPE_INSTANCE && !self.is_str_ty(rm, rt) {
            return self.fail("slice-base");
        }
        let mut bv = String::new();
        let mut sv = String::new();
        let mut ev = String::new();
        let mut ok = self.emit_place(b, rv.a, &mut bv);
        if ok && rv.b != ir::IR_NONE {
            ok = self.emit_operand(b, rv.b, &mut sv);
        }
        if ok && rv.item.node != ir::IR_NONE {
            ok = self.emit_operand(b, rv.item.node, &mut ev);
        }
        let mut cast = String::new();
        if ok {
            ok = self.ty_c(b.module, rv.target, "", &mut cast);
        }
        if ok {
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str("){ .ptr = ");
            dst.push_string(&bv);
            if !is_arr {
                dst.push_str(".ptr");
            }
            if sv.len() != 0 {
                dst.push_str(" + ");
                dst.push_string(&sv);
            }
            dst.push_str(", .len = ");
            if ev.len() != 0 {
                dst.push_str("(");
                dst.push_string(&ev);
                if (rv.c & 1) != 0 {
                    dst.push_str(" + 1");
                }
                dst.push_str(")");
            } else if is_arr {
                dst.push_u64(by.as_data.arr.len);
            } else {
                dst.push_string(&bv);
                dst.push_str(".len");
            }
            if sv.len() != 0 {
                dst.push_str(" - ");
                dst.push_string(&sv);
            }
            dst.push_str(" }");
        }
        cast.free();
        bv.free();
        sv.free();
        ev.free();
        return ok;
    }

    fn emit_aggregate(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue, dst: &mut String) bool {
        if rv.c == ir::AGG_VARIANT {
            let edecl = self.agg_decl(b, rv.target);
            if edecl == NODE_NONE {
                return self.fail("agg-enum");
            }
            let am = self.agg_module(b, rv.target);
            let mut tag = String::new();
            self.mg.enum_tag(am, edecl, rv.item.node, &mut tag);
            if !self.enum_has_payload(am, edecl) {
                dst.push_string(&tag);
                tag.free();
                return true;
            }
            let mut cast = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut cast);
            if ok {
                dst.push_str("(");
                dst.push_string(&cast);
                dst.push_str("){ .tag = ");
                dst.push_string(&tag);
                if rv.b != 0 {
                    dst.push_str(", .payload.");
                    let ea = self.p().module_ast_const(am);
                    self.mg.ident(
                        am,
                        ea.at_const(ea.at_const(rv.item.node).as_data.variant.name).as_data.name.text,
                        dst,
                    );
                    dst.push_str(" = { ");
                    for i in 0..rv.b {
                        if !ok {
                            break;
                        }
                        if i != 0 {
                            dst.push_str(", ");
                        }
                        ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
                    }
                    dst.push_str(" }");
                }
                dst.push_str(" }");
            }
            cast.free();
            tag.free();
            return ok;
        }
        if rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE {
            let mut cast = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut cast);
            if !ok {
                cast.free();
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str(")");
            cast.free();
            if rv.b == 0 {
                let mut rmE = b.module;
                let mut rtE = rv.target;
                self.rty(b, rv.target, &mut rmE, &mut rtE);
                dst.push_str(if_s(self.agg_field_count(rmE, rtE) == 0, "{}", "{0}"));
                return true;
            }
            dst.push_str("{ ");
            if rv.c == ir::AGG_TUPLE {
                for i in 0..rv.b {
                    if !ok {
                        break;
                    }
                    if i != 0 {
                        dst.push_str(", ");
                    }
                    dst.push_str("._");
                    dst.push_u64(i);
                    dst.push_str(" = ");
                    ok = self.emit_operand(b, b.oper_pool[(rv.a + i) as usize], dst);
                }
                dst.push_str(" }");
                return ok;
            }
            let sdecl = self.agg_decl(b, rv.target);
            if sdecl == NODE_NONE {
                return self.fail("agg-struct");
            }
            let am = self.agg_module(b, rv.target);
            let sa = self.p().module_ast_const(am);
            let ms = sa.at_const(sdecl).as_data.aggregate.members;
            if ms.len != rv.b {
                return self.fail("agg-arity");
            }
            // decl-order operands with IR_NONE holes: omitted members zero-fill in C
            let mut emitted: u32 = 0;
            for i in 0..rv.b {
                if !ok {
                    break;
                }
                let opid = b.oper_pool[(rv.a + i) as usize];
                if opid == ir::IR_NONE {
                    continue;
                }
                if emitted != 0 {
                    dst.push_str(", ");
                }
                dst.push_str(".");
                let fid = unsafe sa.list(ms)[i as usize];
                self.mg.ident(am, sa.at_const(sa.at_const(fid).as_data.field.name).as_data.name.text, dst);
                dst.push_str(" = ");
                ok = self.emit_operand(b, opid, dst);
                emitted += 1;
            }
            if emitted == 0 {
                dst.push_str("0");
            }
            dst.push_str(" }");
            return ok;
        }
        return self.fail("agg-kind");
    }

    // `{ <callee>_ret __mr = f(args); d0 = __mr._0; ... }` -- multi-return unpacking.
    fn emit_multi_call(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.callee.node == NODE_NONE {
            return self.fail("fn-value-call");
        }
        let mut rty2 = TYPE_NONE;
        if t.args_len > 0 {
            rty2 = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
        }
        let mut csym = String::new();
        let mut ok = self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty2, TYPE_NONE, &mut csym);
        if ok {
            self.out.push_str("  { ");
            self.out.push_string(&csym);
            self.out.push_str("_ret __mr = ");
            self.out.push_string(&csym);
            self.out.push_str("(");
            for i in 0..t.args_len {
                if !ok {
                    break;
                }
                if i != 0 {
                    self.out.push_str(", ");
                }
                let opid2 = b.oper_pool[(t.args_start + i) as usize];
                let mut av = String::new();
                ok = self.emit_call_arg(b, t.callee, i, opid2, &mut av);
                self.out.push_string(&av);
                av.free();
            }
            self.out.push_str("); ");
            for d in 0..t.dests_len {
                if !ok {
                    break;
                }
                let mut dv = String::new();
                ok = self.emit_place(b, b.dest_pool[(t.dests_start + d) as usize], &mut dv);
                self.out.push_string(&dv);
                dv.free();
                self.out.push_str(" = __mr._");
                self.out.push_u64(d);
                self.out.push_str("; ");
            }
            self.out.push_str("}\n  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
        }
        csym.free();
        return ok;
    }

    // A shim extern's prototype, typed from THIS call site (extern signatures carry no recorded
    // types; call-site operand/dest types resolve under the active env). First caller wins;
    // variadic tails past the declared params are cut at `...`.
    fn collect_extern_proto(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) {
        if t.callee.node == NODE_NONE {
            return;
        }
        let ca = self.p().module_ast_const(t.callee.module);
        let fd = ca.at_const(t.callee.node);
        if fd.kind != NodeKind::NODE_FUNCTION {
            return;
        }
        let is_dflt = self.mg.in_interface(t.callee.module, t.callee.node) != NODE_NONE;
        if !fd.as_data.function.is_extern && !is_dflt {
            return;
        }
        let mut sym = String::new();
        if is_dflt {
            // the per-conformance symbol, prototyped from this call site (definitions come with
            // the default-body pass)
            let mut rty0 = TYPE_NONE;
            if t.args_len > 0 {
                rty0 = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
            }
            let mut dty0 = TYPE_NONE;
            if t.dests_len == 1 {
                dty0 = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
            }
            if !self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty0, dty0, &mut sym) {
                sym.free();
                return;
            }
            self.err = ""; // a refused symbol only skips the proto, not the body
        } else {
            self.mg.ident(t.callee.module, ca.at_const(fd.as_data.function.name).as_data.name.text, &mut sym);
            let s0k = sym.as_str();
            let keep = s0k.len() > 3 && s0k.slice(0, 3) == "sc_";
            if !keep {
                sym.free();
                return;
            }
        }
        let mut h = 1469598103934665603u64;
        {
            let s0 = sym.as_str();
            for k in 0..s0.len() {
                h = (h ^ s0.byte_at(k) as u64) * 1099511628211u64;
            }
        }
        let fresh = switch self.extern_seen.get(&h) {
            Some(_v) => false,
            None => true,
        };
        if !fresh {
            sym.free();
            return;
        }
        self.extern_seen.insert(h, 1);
        let mut pr = String::from_str("extern ");
        let mut pok = true;
        let mut rty = TYPE_NONE;
        if t.dests_len == 1 {
            rty = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
        }
        pok = self.ty_c(b.module, rty, "", &mut pr);
        if pok {
            pr.push_str(" ");
            pr.push_string(&sym);
            pr.push_str("(");
            let np = fd.as_data.function.params.len;
            let mut i: u32 = 0;
            while i < t.args_len && i < np {
                if i != 0 {
                    pr.push_str(", ");
                }
                let aty = b.operands.at(b.oper_pool[(t.args_start + i) as usize] as usize).ty;
                if self.is_unit(b, aty) {
                    pok = false; // an untyped/null arg gives no parameter type: leave it implicit
                    break;
                }
                let mut rm5 = b.module;
                let mut rt5 = aty;
                self.rty(b, aty, &mut rm5, &mut rt5);
                let k5 = self.p().module_ast_const(rm5).type_at(rt5).kind;
                // the DECLARED param type wins when it renders (Self/generic decls fall back to
                // the call-site type; by-ref decls take the autoref'd pointer shape)
                let mut pref = false;
                let mut declared = false;
                if is_dflt {
                    let ps5 = fd.as_data.function.params;
                    if i < ps5.len {
                        let pn5 = ca.at_const(unsafe ca.list(ps5)[i as usize]);
                        if pn5.kind == NodeKind::NODE_PARAMETER && pn5.as_data.parameter.ty != NODE_NONE {
                            let pty5 = ca.type_of(pn5.as_data.parameter.ty);
                            if pty5 != TYPE_NONE {
                                if ca.type_at(pty5).kind == TypeKind::TYPE_REFERENCE {
                                    pref = true;
                                } else {
                                    let mark5 = pr.len();
                                    if self.mg.ctype(t.callee.module, pty5, "", &mut pr) {
                                        declared = true;
                                    } else {
                                        pr.truncate(mark5);
                                    }
                                }
                            }
                        }
                    }
                }
                if declared {
                    i += 1;
                    continue;
                }
                if !is_dflt && (k5 == TypeKind::TYPE_POINTER || k5 == TypeKind::TYPE_REFERENCE) {
                    pr.push_str("const void *"); // parameter-compatible with every pointer arg
                } else if !self.ty_c(b.module, aty, "", &mut pr) {
                    pok = false;
                    break;
                } else if pref && k5 != TypeKind::TYPE_POINTER && k5 != TypeKind::TYPE_REFERENCE {
                    pr.push_str(" *"); // the call autorefs VALUE args; reference args already point
                }
                i += 1;
            }
            if fd.as_data.function.is_variadic {
                pr.push_str(", ...");
            }
            if np == 0 && !fd.as_data.function.is_variadic {
                pr.push_str("void");
            }
            pr.push_str(");\n");
        }
        if pok {
            self.extern_protos.push_string(&pr);
        }
        pr.free();
        sym.free();
    }

    // Record a destructor use: derived `__free__d` symbols join the glue worklist; user `free`
    // methods on instances join the demand queue (their bodies emit like any method instance).
    fn note_free(self: &mut Self, rm: ModuleId, rt: TypeId, sym: str) {
        let mut h = 1469598103934665603u64;
        for k in 0..sym.len() {
            h = (h ^ sym.byte_at(k) as u64) * 1099511628211u64;
        }
        let fresh = switch self.glue_seen.get(&h) {
            Some(_v) => false,
            None => true,
        };
        if !fresh {
            return;
        }
        self.glue_seen.insert(h, 1);
        let n = sym.len();
        if n > 9 && sym.slice(n - 9, n) == "__free__d" {
            self.glue.push(
                StatRef { em: rm, def: DefId { module: 0, node: NODE_NONE }, sym: String::from_str(sym), ty: rt },
            );
            return;
        }
        // a user free method: demand its instance body when the receiver is generic
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind != TypeKind::TYPE_INSTANCE {
            return; // concrete frees are seeds already
        }
        let it = *a.instance(y.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        // find the extend member named `free` on the instance's decl
        let dsrc = self.p().modules.at(it.module as usize).source.as_str();
        let items = unsafe da.at_const(da.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe da.list(items)[i as usize];
            let itn = da.at_const(iid);
            if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE {
                continue;
            }
            let tg = da.resolution_def(itn.as_data.extend_def.target_type);
            if tg.module != it.module || tg.node != it.decl {
                continue;
            }
            let ms = itn.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe da.list(ms)[j as usize];
                let mn = da.at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.body == NODE_NONE {
                    continue;
                }
                let s2 = da.at_const(mn.as_data.function.name).as_data.name.text;
                if dsrc.slice(s2.start as usize, s2.end as usize) != "free" {
                    continue;
                }
                let mut snap = Vector::<mbe::MSub>::new();
                for i7 in 0..self.mg.subs.len() {
                    snap.push(*self.mg.subs.at(i7));
                }
                let eg = itn.as_data.extend_def.generics;
                let mut gi: u32 = 0;
                while gi < eg.len && gi as u8 < it.n {
                    self.push_bind(
                        &mut snap,
                        it.module,
                        unsafe da.list(eg)[gi as usize],
                        rm,
                        unsafe it.args[gi as usize],
                    );
                    gi += 1;
                }
                let sg = da.at_const(it.decl).as_data.aggregate.generics;
                let mut gj: u32 = 0;
                while gj < sg.len && gj as u8 < it.n {
                    self.push_bind(
                        &mut snap,
                        it.module,
                        unsafe da.list(sg)[gj as usize],
                        rm,
                        unsafe it.args[gj as usize],
                    );
                    gj += 1;
                }
                let mut sfx = String::new();
                let mut sok = true;
                for i2 in 0..it.n {
                    sfx.push_str("__");
                    if !self.mg.type_m(rm, unsafe it.args[i2 as usize], &mut sfx) {
                        sok = false;
                        break;
                    }
                }
                if sok {
                    self.demand.push(
                        Demand {
                            def: DefId { module: it.module, node: mid },
                            sym: String::from_str(sym),
                            subs: snap,
                            sfx: sfx,
                        },
                    );
                } else {
                    sfx.free();
                    snap.free();
                }
                return;
            }
        }
    }

    // Is the resolved type destructible (needs a free call when dropped)?
    fn is_destructible(self: &mut Self, rm: ModuleId, rt: TypeId, depth: u32) bool {
        if depth > 16 {
            return false;
        }
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_DYN {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.is_destructible(rm, y.as_data.arr.elem, depth + 1);
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM && y.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        {
            let mut ms = String::new();
            let has = self.mg.method_by_name(rm, rt, "free", &mut ms);
            ms.free();
            if has {
                return true;
            }
        }
        let decl = self.agg_decl_res(rm, rt);
        if decl == NODE_NONE {
            return false;
        }
        let am = self.agg_module_res(rm, rt);
        let da = self.p().module_ast_const(am);
        let ms2 = da.at_const(decl).as_data.aggregate.members;
        // bind the decl's generics for field resolution when this is an instance
        let mut nb: usize = 0;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            let sg = da.at_const(decl).as_data.aggregate.generics;
            let mut gj: u32 = 0;
            while gj < sg.len && gj as u8 < it.n {
                self.mg.push_sub(am, unsafe da.list(sg)[gj as usize], rm, unsafe it.args[gj as usize]);
                nb += 1;
                gj += 1;
            }
        }
        let mut res = false;
        for i in 0..ms2.len {
            let fid = unsafe da.list(ms2)[i as usize];
            let fk = da.at_const(fid).kind;
            if fk == NodeKind::NODE_FIELD {
                let fty = da.type_of(fid);
                if fty != TYPE_NONE {
                    let mut frm = am;
                    let mut frt = fty;
                    if self.mg.resolve(am, fty, &mut frm, &mut frt) && self.is_destructible(frm, frt, depth + 1) {
                        res = true;
                        break;
                    }
                }
            } else if fk == NodeKind::NODE_VARIANT {
                let pl = da.at_const(fid).as_data.variant.payload;
                for k in 0..pl.len {
                    let pid = unsafe da.list(pl)[k as usize];
                    let pty = da.type_of(pid);
                    if pty != TYPE_NONE {
                        let mut prm = am;
                        let mut prt = pty;
                        if self.mg.resolve(am, pty, &mut prm, &mut prt) && self.is_destructible(prm, prt, depth + 1) {
                            res = true;
                            break;
                        }
                    }
                }
                if res {
                    break;
                }
            }
        }
        self.mg.pop_subs(nb);
        return res;
    }

    // The C expression that frees resolved type `(rm, rt)` (a callable symbol); also records the
    // demand/glue the call needs.
    fn free_expr(self: &mut Self, rm: ModuleId, rt: TypeId, out: &mut String) bool {
        let yd = *self.p().module_ast_const(rm).type_at(rt);
        if yd.kind == TypeKind::TYPE_DYN {
            // owned dyn destroys through the stem's guarded inline helper
            if !self.dyn_request(rm, rt) {
                return false;
            }
            if !self.mg.dyn_stem(rm, &yd, out) {
                return self.fail("dyn-stem");
            }
            out.push_str("__dyn_free");
            return true;
        }
        if !self.mg.free_target(rm, rt, out) {
            return false;
        }
        self.note_free(rm, rt, out.as_str());
        return true;
    }

    /// Emit derived destructor `idx` from the glue worklist into the shared buffer:
    /// `static void <sym>(<T> *const self) { <memberwise frees> }`. Nested destructible fields
    /// enqueue their own glue/demand entries.
    pub fn emit_glue(self: &mut Self, idx: usize) bool {
        let rm = self.glue.at(idx).em;
        let rt = self.glue.at(idx).ty;
        let sym = self.glue.at(idx).sym.clone();
        self.err = "";
        let mut head = String::new();
        let ok0 = self.ty_c(rm, rt, "", &mut head);
        if ok0 {
            // extern: drop sites in every TU spell this symbol; the instance TU defines it once
            self.out.push_str("void ");
            self.out.push_string(&sym);
            self.out.push_str("(");
            self.out.push_string(&head);
            self.out.push_str(" *const self) {\n");
        }
        head.free();
        sym.free();
        if !ok0 {
            return false;
        }
        let decl = self.agg_decl_res(rm, rt);
        if decl == NODE_NONE {
            self.out.push_str("}\n");
            return true;
        }
        let am = self.agg_module_res(rm, rt);
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        let da = self.p().module_ast_const(am);
        let mut nb: usize = 0;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            let sg = da.at_const(decl).as_data.aggregate.generics;
            let mut gj: u32 = 0;
            while gj < sg.len && gj as u8 < it.n {
                self.mg.push_sub(am, unsafe da.list(sg)[gj as usize], rm, unsafe it.args[gj as usize]);
                nb += 1;
                gj += 1;
            }
        }
        let ms = da.at_const(decl).as_data.aggregate.members;
        let is_enum = da.at_const(decl).kind == NodeKind::NODE_ENUM;
        let mut body = String::new();
        let mut ok = true;
        if is_enum {
            if self.enum_has_payload(am, decl) {
                body.push_str("  switch (self->tag) {\n");
                for i in 0..ms.len {
                    if !ok {
                        break;
                    }
                    let vid = unsafe da.list(ms)[i as usize];
                    let vn = da.at_const(vid);
                    if vn.kind != NodeKind::NODE_VARIANT || vn.as_data.variant.payload.len == 0 {
                        continue;
                    }
                    let mut any = String::new();
                    let pl = vn.as_data.variant.payload;
                    for k in 0..pl.len {
                        if !ok {
                            break;
                        }
                        let pid = unsafe da.list(pl)[k as usize];
                        let pty = da.type_of(pid);
                        if pty == TYPE_NONE {
                            continue;
                        }
                        let mut prm = am;
                        let mut prt = pty;
                        if !self.mg.resolve(am, pty, &mut prm, &mut prt) || !self.is_destructible(prm, prt, 0) {
                            continue;
                        }
                        let mut fsym = String::new();
                        ok = self.free_expr(prm, prt, &mut fsym);
                        if ok {
                            any.push_str("    ");
                            any.push_string(&fsym);
                            any.push_str("(&self->payload.");
                            self.mg.ident(am, da.at_const(vn.as_data.variant.name).as_data.name.text, &mut any);
                            any.push_str("._");
                            any.push_u64(k);
                            any.push_str(");\n");
                        }
                        fsym.free();
                    }
                    if ok && any.len() != 0 {
                        let mut tag = String::new();
                        self.mg.enum_tag(am, decl, vid, &mut tag);
                        body.push_str("  case ");
                        body.push_string(&tag);
                        tag.free();
                        body.push_str(":\n");
                        body.push_string(&any);
                        body.push_str("    break;\n");
                    }
                    any.free();
                }
                body.push_str("  default: break;\n  }\n");
            }
        } else {
            for i in 0..ms.len {
                if !ok {
                    break;
                }
                let fid = unsafe da.list(ms)[i as usize];
                if da.at_const(fid).kind != NodeKind::NODE_FIELD {
                    continue;
                }
                let fty = da.type_of(fid);
                if fty == TYPE_NONE {
                    continue;
                }
                let mut frm = am;
                let mut frt = fty;
                if !self.mg.resolve(am, fty, &mut frm, &mut frt) || !self.is_destructible(frm, frt, 0) {
                    continue;
                }
                let mut fsym = String::new();
                ok = self.free_expr(frm, frt, &mut fsym);
                if ok {
                    let mut fnm = String::new();
                    self.mg.ident(am, da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text, &mut fnm);
                    body.push_str("  ");
                    body.push_string(&fsym);
                    body.push_str("(&self->");
                    body.push_string(&fnm);
                    body.push_str(");\n");
                    fnm.free();
                }
                fsym.free();
            }
        }
        self.mg.pop_subs(nb);
        if ok {
            self.out.push_string(&body);
            self.out.push_str("}\n");
        }
        body.free();
        return ok;
    }

    fn emit_term(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind == ir::TM_GOTO {
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_DROP {
            // scalar drops are pure control flow; a dyn value frees through its vtable; other
            // destructible values need the declaration plan's free glue and stay unfrozen
            let pl = *b.places.at(t.a as usize);
            let mut rm = b.module;
            let mut rt = pl.ty;
            self.rty(b, pl.ty, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind == TypeKind::TYPE_DYN {
                let mut pv = String::new();
                let ok = self.emit_place(b, t.a, &mut pv);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&pv);
                    self.out.push_str(".vt->__free(");
                    self.out.push_string(&pv);
                    self.out.push_str(".data);\n  goto bb_");
                    self.out.push_u64(t.t0);
                    self.out.push_str(";\n");
                }
                pv.free();
                return ok;
            }
            if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                let mut fs = String::new();
                if !self.mg.free_target(rm, rt, &mut fs) {
                    fs.free();
                    return self.fail("drop");
                }
                if self.collect_demand {
                    self.note_free(rm, rt, fs.as_str());
                }
                let mut pv = String::new();
                let ok = self.emit_place(b, t.a, &mut pv);
                if ok {
                    self.out.push_str("  ");
                    self.out.push_string(&fs);
                    self.out.push_str("(&");
                    self.out.push_string(&pv);
                    self.out.push_str(");\n  goto bb_");
                    self.out.push_u64(t.t0);
                    self.out.push_str(";\n");
                }
                pv.free();
                fs.free();
                return ok;
            }
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_RETURN {
            if b.returns == 1 {
                self.out.push_str("  return _0;\n");
            } else if b.returns > 1 {
                self.out.push_str("  return (");
                self.out.push_string(&self.cur_name);
                self.out.push_str("_ret){ ");
                for r in 0..b.returns {
                    if r != 0 {
                        self.out.push_str(", ");
                    }
                    self.out.push_str("._");
                    self.out.push_u64(r);
                    self.out.push_str(" = _");
                    self.out.push_u64(r);
                }
                self.out.push_str(" };\n");
            } else {
                self.out.push_str("  return;\n");
            }
            return true;
        }
        if t.kind == ir::TM_UNREACHABLE {
            self.out.push_str("  abort();\n");
            return true;
        }
        if t.kind == ir::TM_ASSERT {
            let mut cond = String::new();
            let ok = self.emit_operand(b, t.a, &mut cond);
            if ok {
                self.out.push_str("  if (!(");
                self.out.push_string(&cond);
                self.out.push_str(")) abort();\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            cond.free();
            return ok;
        }
        if t.kind == ir::TM_SWITCH {
            let mut d = String::new();
            let ok = self.emit_operand(b, t.a, &mut d);
            for k in 0..t.sw_len {
                if !ok {
                    break;
                }
                let pair = b.switch_pool[(t.sw_start + k) as usize];
                self.out.push_str("  if ((");
                self.out.push_string(&d);
                self.out.push_str(") == ");
                self.out.push_u64(pair >> 32);
                self.out.push_str(") goto bb_");
                self.out.push_u64(pair & 0xFFFFFFFFu64);
                self.out.push_str(";\n");
            }
            d.free();
            if ok {
                self.out.push_str("  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            return ok;
        }
        if t.kind == ir::TM_CALL {
            if t.dests_len > 1 {
                return self.emit_multi_call(b, t);
            }
            // an interface-member call whose receiver is a dyn value dispatches through the
            // vtable: no symbol, no call-site prototype
            let mut dyn_recv = ir::IR_NONE;
            if t.callee.node != NODE_NONE && t.args_len > 0 && self.mg.in_interface(t.callee.module, t.callee.node) != NODE_NONE {
                let a0 = b.oper_pool[t.args_start as usize];
                let mut om0 = b.module;
                let mut ot0 = b.operands.at(a0 as usize).ty;
                self.rty(b, b.operands.at(a0 as usize).ty, &mut om0, &mut ot0);
                if self.p().module_ast_const(om0).type_at(ot0).kind == TypeKind::TYPE_DYN {
                    dyn_recv = a0;
                    if !self.dyn_request(om0, ot0) {
                        return false;
                    }
                }
            }
            if self.collect_demand && dyn_recv == ir::IR_NONE {
                self.collect_extern_proto(b, t);
            }
            let mut line = String::new();
            let mut ok = true;
            if t.dests_len == 1 {
                let dp = b.dest_pool[t.dests_start as usize];
                let dty = b.places.at(dp as usize).ty;
                let mut want = !self.is_unit(b, dty);
                if dty == TYPE_NONE && t.callee.node != NODE_NONE {
                    // untyped dest: the callee's declared return count decides
                    let ca9 = self.p().module_ast_const(t.callee.module);
                    let fd9 = ca9.at_const(t.callee.node);
                    want = fd9.kind == NodeKind::NODE_FUNCTION && fd9.as_data.function.returns.len != 0;
                }
                if want {
                    ok = self.emit_place(b, dp, &mut line);
                    line.push_str(" = ");
                }
            }
            // a capturing closure value calls its hoisted function with the env first; a dyn fn
            // value dispatches through its vtable's `call` slot
            let mut env_first = false;
            let mut dyn_val = false;
            if ok && t.callee.node == NODE_NONE {
                let cop = *b.operands.at(t.a as usize);
                let mut cmV = b.module;
                let mut ctV = cop.ty;
                self.rty(b, cop.ty, &mut cmV, &mut ctV);
                let cy = *self.p().module_ast_const(cmV).type_at(ctV);
                if cy.kind == TypeKind::TYPE_DYN {
                    if !self.dyn_request(cmV, ctV) {
                        return false;
                    }
                    ok = self.emit_operand(b, t.a, &mut line);
                    line.push_str(".vt->call");
                    dyn_val = true;
                } else if cy.kind == TypeKind::TYPE_FUNCTION {
                    let cd = self.p().module_ast_const(cy.module).at_const(cy.as_data.decl);
                    if cd.kind == NodeKind::NODE_CLOSURE && cd.as_data.closure.captures.len != 0 {
                        self.mg.closure_sym(cy.module, cy.as_data.decl, &mut line);
                        env_first = true;
                    }
                }
                if !env_first && !dyn_val {
                    ok = self.emit_operand(b, t.a, &mut line);
                }
            } else if ok && dyn_recv != ir::IR_NONE {
                ok = self.emit_operand(b, dyn_recv, &mut line);
                line.push_str(".vt->");
                let ca0 = self.p().module_ast_const(t.callee.module);
                self.mg.ident(
                    t.callee.module,
                    ca0.at_const(ca0.at_const(t.callee.node).as_data.function.name).as_data.name.text,
                    &mut line,
                );
            } else if ok {
                let mut rty2 = TYPE_NONE;
                if t.args_len > 0 {
                    rty2 = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
                }
                let mut dty2 = TYPE_NONE;
                if t.dests_len == 1 {
                    dty2 = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
                }
                ok = self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty2, dty2, &mut line);
            }
            if ok {
                line.push_str("(");
                if env_first {
                    line.push_str("&");
                    ok = self.emit_operand(b, t.a, &mut line);
                    if t.args_len != 0 {
                        line.push_str(", ");
                    }
                }
                if dyn_val {
                    ok = self.emit_operand(b, t.a, &mut line);
                    line.push_str(".data");
                    if t.args_len != 0 {
                        line.push_str(", ");
                    }
                }
                for i in 0..t.args_len {
                    if !ok {
                        break;
                    }
                    if dyn_recv != ir::IR_NONE && i == 0 {
                        // the erased receiver: its data pointer takes the self slot
                        ok = self.emit_operand(b, dyn_recv, &mut line);
                        line.push_str(".data");
                        continue;
                    }
                    if i != 0 {
                        line.push_str(", ");
                    }
                    let opid2 = b.oper_pool[(t.args_start + i) as usize];
                    let mut av2 = String::new();
                    ok = self.emit_call_arg(b, t.callee, i, opid2, &mut av2);
                    line.push_string(&av2);
                    av2.free();
                }
            }
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&line);
                self.out.push_str(");\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            line.free();
            return ok;
        }
        if t.kind == ir::TM_ASSERT {
            let mut cnd = String::new();
            let mut msgv = String::new();
            let mut ok = self.emit_operand(b, t.a, &mut cnd);
            if ok && t.args_len != 0 {
                ok = self.emit_operand(b, b.oper_pool[t.args_start as usize], &mut msgv);
            }
            if ok {
                let msrc = self.p().modules.at(b.module as usize).source.as_str();
                self.out.push_str("  if (!(");
                self.out.push_string(&cnd);
                self.out.push_str(")) { ");
                if t.args_len != 0 {
                    self.out.push_str("const str __scm = ");
                    self.out.push_string(&msgv);
                    self.out.push_str("; ");
                }
                self.out.push_str("fprintf(stderr, \"assertion failed: `");
                push_pct_c_escaped(msrc.slice(t.span.start as usize, t.span.end as usize), &mut self.out);
                self.out.push_str("`");
                if t.args_len != 0 {
                    self.out.push_str(": %.*s");
                }
                self.out.push_str("\\n  at ");
                push_pct_c_escaped(self.p().modules.at(b.module as usize).file.as_str(), &mut self.out);
                self.out.push_str(":");
                let mut ln: u64 = 1;
                for k in 0..t.span.start as usize {
                    if msrc.byte_at(k) == 10 {
                        ln += 1;
                    }
                }
                self.out.push_u64(ln);
                self.out.push_str("\\n\"");
                if t.args_len != 0 {
                    self.out.push_str(", (int)__scm.len, (const char *)__scm.ptr");
                }
                self.out.push_str("); fflush(stderr); abort(); }\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
            cnd.free();
            msgv.free();
            return ok;
        }
        return self.fail("terminator");
    }
}

// push_c_escaped for printf format strings: `%` doubles so source text never reads as a conversion.
pub fn push_pct_c_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        let b = txt.byte_at(i);
        if b == 37 {
            dst.push_str("%%");
        } else {
            push_c_escaped(txt.slice(i, i + 1), dst);
        }
    }
}

// Raw bytes into a C string literal: printable ASCII stays, specials get named escapes, the rest
// three-digit octal (fixed width, so a following digit can never extend the escape).
pub fn push_c_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        let b = txt.byte_at(i);
        if b == 34 {
            dst.push_str("\\\"");
        } else if b == 92 {
            dst.push_str("\\\\");
        } else if b == 10 {
            dst.push_str("\\n");
        } else if b == 13 {
            dst.push_str("\\r");
        } else if b == 9 {
            dst.push_str("\\t");
        } else if b >= 32 && b <= 126 {
            dst.push_byte(b);
        } else {
            dst.push_str("\\");
            dst.push_byte(48 + (b >> 6 & 7));
            dst.push_byte(48 + (b >> 3 & 7));
            dst.push_byte(48 + (b & 7));
        }
    }
}

const fn if_s(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
