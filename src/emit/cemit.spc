// The streaming C backend's function emitter: one verified Core body at a time into one reusable
// buffer, strict C11 portable output -- explicit temporaries, no GNU statement expressions, no
// `__auto_type`. Locals spell as their stable `LocalId` (`_N`), blocks as `BlockId` labels
// (`bb_N`), so two serial runs are byte-identical by construction. Types and symbols come from the
// frozen mangler (emit::mangle); the emitter consumes ONLY Core IR and pool reads for spelling:
// it never resolves overloads, searches extends at emission time, infers, interns, or evaluates
// syntax. Bodies outside the currently emittable subset refuse with a reason instead of guessing.
import ast::ast as *;
import emit::mangle as mbe;
import consteval::consteval as ce;
import ir::core as ir;
import lexer::token as tok;
import lexer::token_type as tt;
import module::loader as loader;
import stdlib;

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
    pub glue_envs: Vector<GlueEnv>,
    // The current fn returns a fixed array by value (wrapped in its `_ret` struct).
    arr_ret: bool,
    /// Set by the caller before `emit_fn` for a `@c.noreturn` item: the signature (and so its
    /// prototype) gets the `_Noreturn` specifier -- without it -Werror flags the paths behind a
    /// panic as reading uninitialized locals. Cleared on every emission.
    pub noret: bool,
    // Closure env bridge: Core IR closure bodies take captures as TRAILING arg locals, but the C
    // ABI passes one env pointer -- locals >= cap_base spell `__env-><name>` while `cap_on` is
    // set (a void zero-param closure's captures start at local 0, so 0 is not a valid sentinel).
    cap_base: u32,
    cap_on: bool,
    cap_names: Vector<String>,
    /// Out-of-line declarations a body needs BEFORE itself (its `_ret` struct); caller-cleared.
    pub aux: String,
    /// Closure-env forward typedefs: spliced into the shared header's FORWARD section.
    pub env_fwd: String,
    /// Env structs the DECLARATION pass already defined (embedded in aggregates): skip ours.
    pub env_skip: Map<u64, u64>,
    /// Env structs THIS emitter defined (the late aggregate replay must skip them).
    pub env_hashes: Vector<u64>,
    /// `extern <decl>;` stubs for every static/const item bodies reference (fusion-TU gate).
    pub stat_decls: String,
    pub fn_attrs: String,
    pub blk_defs: String,
    pub blk_seen: Map<u64, u64>,
    pub uses_tasks: u8,
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
    /// Extern fns whose `extern "C" "<header>"` block ships real prototypes: the include supplies
    /// them, so a call-site proto would conflict. Keyed (module << 32 | node), driver-filled.
    pub ext_backed: Set<u64>,
}

/// One referenced const/static item: its declaration, C symbol, and the module whose prefix
/// spelled it (associated consts carry the emitting module's prefix).
/// The substitution env a glue entry was RECORDED under (its type may still name generics).
pub struct GlueEnv {
    pub subs: Vector<mbe::MSub>,
}

extend GlueEnv as Free {
    pub fn free(self: &mut Self) {
        self.subs.free();
    }
}

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
        self.glue_envs.free();
        self.cap_names.free();
        self.aux.free();
        self.env_fwd.free();
        self.env_skip.free();
        self.env_hashes.free();
        self.cur_name.free();
        self.stat_decls.free();
        self.fn_attrs.free();
        self.blk_defs.free();
        self.blk_seen.free();
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
        self.ext_backed.free();
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
            arr_ret: false,
            noret: false,
            demand: Vector::<Demand>::new(),
            glue_envs: Vector::<GlueEnv>::new(),
            cap_base: 0,
            cap_on: false,
            cap_names: Vector::<String>::new(),
            aux: String::new(),
            env_fwd: String::new(),
            env_skip: Map::<u64, u64>::new(),
            env_hashes: Vector::<u64>::new(),
            cur_name: String::new(),
            stat_decls: String::new(),
            fn_attrs: String::new(),
            blk_defs: String::new(),
            blk_seen: Map::<u64, u64>::new(),
            uses_tasks: 0,
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
            ext_backed: Set::<u64>::new(),
        };
    }

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    const fn fail(self: &mut Self, why: str<'static>) bool {
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
            if stdlib::getenv("SC_CEMIT_STATS") != null {
                let y9 = *self.p().module_ast_const(m).type_at(t);
                eprint("ctype-fail: in `{}` m{} t{} kind {}", self.cur_name.as_str(), m, t, y9.kind as u32);
                if y9.kind == TypeKind::TYPE_INSTANCE {
                    let it9 = *self.p().module_ast_const(m).instance(y9.as_data.inst);
                    eprint(" decl n{}", it9.decl);
                    for k9 in 0..it9.n {
                        let ay9 = *self.p().module_ast_const(m).type_at(unsafe it9.args[k9 as usize]);
                        eprint(" a{}k{}", k9, ay9.kind as u32);
                        if ay9.kind == TypeKind::TYPE_GENERIC {
                            eprint("(pm{} pn{})", ay9.module, ay9.as_data.decl);
                        }
                    }
                    eprint(" subs:");
                    for si9 in 0..self.mg.subs.len() {
                        let sb9 = *self.mg.subs.at(si9);
                        eprint(" ({},{})->({},{})l{}", sb9.pm, sb9.pnode, sb9.am, sb9.at, sb9.lim);
                    }
                }
                eprint("\n");
            }
            return self.fail("ctype");
        }
        return true;
    }

    // Push a demand binding unless it is the identity (a receiver spelled with its own param:
    // `self.method()` inside the generic body) -- the outer chain already binds it, and an
    // identity entry would make resolution loop.
    // `lim` is the snapshot length where the bind GROUP starts: every payload references the env
    // below the group, never a sibling frame (extend + struct params alias the same spellings).
    fn push_bind(
        self: &Self,
        snap: &mut Vector<mbe::MSub>,
        pm: ModuleId,
        pnode: NodeId,
        am: ModuleId,
        at: TypeId,
        lim: u32,
    ) {
        let y = *self.p().module_ast_const(am).type_at(at);
        if y.kind == TypeKind::TYPE_GENERIC && y.module == pm && y.as_data.decl == pnode {
            return;
        }
        snap.push(mbe::MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
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
    const fn is_str_ty(self: &Self, rm: ModuleId, rt: TypeId) bool {
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

    // The C-visible fixed-array length of the value a place denotes, or -1: the recorded types may
    // say "slice" (a checker coercion), but a FIELD's declared type says what C emitted.
    fn place_c_arr_len(self: &mut Self, b: &ir::CoreBody, plid: ir::PlaceId) i64 {
        let pl = *b.places.at(plid as usize);
        if pl.proj_len == 0 {
            let mut rm = b.module;
            let mut rt = b.locals.at(pl.base as usize).ty;
            self.rty(b, b.locals.at(pl.base as usize).ty, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len != 0 {
                return y.as_data.arr.len;
            }
            return 0 - 1;
        }
        let pj = *b.projections.at((pl.proj_start + pl.proj_len - 1) as usize);
        if pj.kind != ir::PJ_FIELD || pj.sub == NODE_NONE {
            return 0 - 1;
        }
        let prev = if pl.proj_len >= 2 {
            b.projections.at((pl.proj_start + pl.proj_len - 2) as usize).ty;
        } else {
            b.locals.at(pl.base as usize).ty;
        };
        let mut rm = b.module;
        let mut rt = prev;
        self.rty(b, prev, &mut rm, &mut rt);
        let mut g = 0;
        while g < 4 {
            let y0 = *self.p().module_ast_const(rm).type_at(rt);
            if y0.kind != TypeKind::TYPE_POINTER && y0.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            let mut nm = rm;
            let mut nt = y0.as_data.elem;
            if !self.mg.resolve(rm, y0.as_data.elem, &mut nm, &mut nt) {
                break;
            }
            rm = nm;
            rt = nt;
            g += 1;
        }
        let dm = self.agg_module_res(rm, rt);
        let da = self.p().module_ast_const(dm);
        if da.at_const(pj.sub).kind != NodeKind::NODE_FIELD {
            return 0 - 1;
        }
        let ftn = da.at_const(pj.sub).as_data.field.ty;
        let ftl = da.type_of(ftn);
        if ftl == TYPE_NONE {
            return 0 - 1;
        }
        let yF = *da.type_at(ftl);
        if yF.kind == TypeKind::TYPE_ARRAY && yF.as_data.arr.len != 0 {
            return yF.as_data.arr.len;
        }
        return 0 - 1;
    }

    fn emit_call_arg(self: &mut Self, b: &ir::CoreBody, callee0: DefId, i: u32, opid: ir::OperandId, dst: &mut String) bool {
        if callee0.node == NODE_NONE {
            return self.emit_operand(b, opid, dst);
        }
        // A bound-dispatched interface member resolved to a concrete impl: the IMPL's params
        // decide the arg shapes (its `&mut Box<..>` self must not take the auto-deref hop).
        let mut callee = callee0;
        if self.mg.in_interface(callee0.module, callee0.node) != NODE_NONE && self.mg.last_method_def.node != NODE_NONE {
            callee = self.mg.last_method_def;
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
                    let mut pty = fa.type_of(pn.as_data.parameter.ty);
                    let mut fap = fa;
                    // a GENERIC param decides shapes by its BOUND type under the active
                    // substitution (T = &i64 is a reference param, not a by-value one); an
                    // UNRESOLVED generic decides nothing -- the lowered operand's shape stands
                    if pty != TYPE_NONE && fap.type_at(pty).kind == TypeKind::TYPE_GENERIC {
                        let mut xm = callee.module;
                        let mut xt = pty;
                        let grounded = self.mg.resolve(callee.module, pty, &mut xm, &mut xt);
                        if grounded && self.p().module_ast_const(xm).type_at(xt).kind != TypeKind::TYPE_GENERIC {
                            pty = xt;
                            fap = self.p().module_ast_const(xm);
                        } else {
                            pty = TYPE_NONE;
                        }
                    }
                    if pty != TYPE_NONE && fap.type_at(pty).kind != TypeKind::TYPE_REFERENCE && fap.type_at(pty).kind != TypeKind::TYPE_POINTER {
                        want_val = true;
                        // a wide-literal arg into a SCALAR param (a `from` widening shim):
                        // the value fits one limb by construction
                        if fap.type_at(pty).kind == TypeKind::TYPE_BUILTIN {
                            let op0 = *b.operands.at(opid as usize);
                            if op0.kind == ir::OP_CONST {
                                let c0 = *b.constants.at(op0.data as usize);
                                if c0.kind == ir::CK_WIDE {
                                    let aW = self.p().module_ast_const(b.module);
                                    let wW = *unsafe aW.wide_lits.at(c0.val as usize);
                                    dst.push_str("0x");
                                    dst.push_hex(wW.limbs[0], false);
                                    dst.push_str("ULL");
                                    return true;
                                }
                            }
                        }
                    }
                    if pty != TYPE_NONE && fap.type_at(pty).kind == TypeKind::TYPE_REFERENCE {
                        want_ref = true;
                        let pe = fap.type_at(pty).as_data.elem;
                        if pe != TYPE_NONE && fap.type_at(pe).kind == TypeKind::TYPE_INSTANCE {
                            let pit = *fap.instance(fap.type_at(pe).as_data.inst);
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
                let mut aty0 = b.operands.at(opid as usize).ty;
                if aty0 == TYPE_NONE {
                    let op0 = *b.operands.at(opid as usize);
                    if op0.kind == ir::OP_COPY || op0.kind == ir::OP_MOVE {
                        aty0 = b.places.at(op0.data as usize).ty;
                    }
                }
                let mut rm0 = b.module;
                let mut rt0 = aty0;
                self.rty(b, aty0, &mut rm0, &mut rt0);
                {
                    // a fixed array into a slice-view param: wrap `{ arr, N }` (the C array decays).
                    // The operand's node type may already be the COERCED slice: the PLACE's own
                    // type still says array.
                    let ya0 = *self.p().module_ast_const(rm0).type_at(rt0);
                    let mut alen0: i64 = 0 - 1;
                    if ya0.kind == TypeKind::TYPE_ARRAY && ya0.as_data.arr.len != 0 {
                        alen0 = ya0.as_data.arr.len;
                    } else {
                        let opP = *b.operands.at(opid as usize);
                        if opP.kind == ir::OP_COPY || opP.kind == ir::OP_MOVE {
                            alen0 = self.place_c_arr_len(b, opP.data);
                        }
                    }
                    if alen0 > 0 {
                        let ps0 = fa.at_const(callee.node).as_data.function.params;
                        if i < ps0.len {
                            let pn0 = fa.at_const(unsafe fa.list(ps0)[i as usize]);
                            if pn0.kind == NodeKind::NODE_PARAMETER && pn0.as_data.parameter.ty != NODE_NONE {
                                let pty0 = fa.type_of(pn0.as_data.parameter.ty);
                                if pty0 != TYPE_NONE && fa.type_at(pty0).kind == TypeKind::TYPE_INSTANCE {
                                    let it0 = *fa.instance(fa.type_at(pty0).as_data.inst);
                                    let dai = self.p().module_ast_const(it0.module);
                                    let nsi = dai.at_const(dai.at_const(it0.decl).as_data.aggregate.name).as_data.name.text;
                                    let nmi = self.p().modules.at(it0.module as usize).source.as_str().slice(
                                        nsi.start as usize,
                                        nsi.end as usize,
                                    );
                                    if nmi == "Slice" || nmi == "SliceMut" {
                                        let mut cs0 = String::new();
                                        if self.mg.ctype(callee.module, pty0, "", &mut cs0) {
                                            dst.push_str("(");
                                            dst.push_string(&cs0);
                                            dst.push_str("){ .ptr = ");
                                            let okA = self.emit_operand(b, opid, dst);
                                            dst.push_str(", .len = ");
                                            dst.push_i64(alen0);
                                            dst.push_str(" }");
                                            return okA;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
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

    const fn agg_module_res(self: &Self, rm: ModuleId, rt: TypeId) ModuleId {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return a.instance(y.as_data.inst).module;
        }
        return y.module;
    }
    const fn agg_decl_res(self: &Self, rm: ModuleId, rt: TypeId) NodeId {
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
        let ok = self.emit_fn_inner(b, name);
        self.noret = false;
        if !ok {
            self.out.truncate(mark);
            return false;
        }
        return true;
    }

    fn emit_fn_inner(self: &mut Self, b: &ir::CoreBody, name: str) bool {
        self.cur_name.truncate(0);
        self.cur_name.push_str(name);
        self.arr_ret = false;
        let mut ok0 = true;
        if self.fn_attrs.len() != 0 {
            self.out.push_string(&self.fn_attrs);
        }
        if b.returns > 1 {
            // multi-return: `typedef struct { <t> _0; ... } <name>_ret;` + struct-returning sig
            self.aux.push_str("typedef struct { ");
            for r in 0..b.returns {
                let mut nm = String::from_str("_");
                nm.push_u64(r);
                let okr = self.ty_c(b.module, b.locals.at(r as usize).ty, nm.as_str(), &mut self.aux);
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
            // a fixed array returned by value wraps in `<name>_ret` (C cannot return arrays)
            self.arr_ret = false;
            if rty != TYPE_NONE {
                let mut am9 = b.module;
                let mut at9 = rty;
                self.rty(b, rty, &mut am9, &mut at9);
                let y9 = *self.p().module_ast_const(am9).type_at(at9);
                self.arr_ret = y9.kind == TypeKind::TYPE_ARRAY && y9.as_data.arr.len != 0;
            }
            if self.arr_ret {
                self.aux.push_str("typedef struct { ");
                if !self.ty_c(b.module, rty, "_a", &mut self.aux) {
                    return false;
                }
                self.aux.push_str("; } ");
                self.aux.push_str(name);
                self.aux.push_str("_ret;\n");
                self.out.push_str(name);
                self.out.push_str("_ret ");
                self.out.push_str(name);
                self.out.push_str("(");
            } else {
                let mut rt = String::new();
                ok0 = self.ty_c(b.module, rty, "", &mut rt);
                if ok0 {
                    if self.noret {
                        self.out.push_str("_Noreturn ");
                    }
                    self.out.push_string(&rt);
                    self.out.push_str(" ");
                    self.out.push_str(name);
                    self.out.push_str("(");
                }
            }
        }
        if !ok0 {
            return false;
        }
        let mut arrcp = Vector::<u32>::new();
        for i in 0..b.args {
            if i != 0 {
                self.out.push_str(", ");
            }
            let l = (b.returns + i) as usize;
            let mut nm = String::from_str("_");
            nm.push_u64(l as u64);
            // a `mut` fixed-array VALUE param: C hands a pointer to the caller's array, so the
            // body works on an entry copy (writes must not reach the caller)
            {
                let mut rmA = b.module;
                let mut rtA = b.locals.at(l).ty;
                self.rty(b, b.locals.at(l).ty, &mut rmA, &mut rtA);
                let ya = *self.p().module_ast_const(rmA).type_at(rtA);
                if b.locals.at(l).is_mutable && ya.kind == TypeKind::TYPE_ARRAY && ya.as_data.arr.len != 0 {
                    nm.push_str("_p");
                    arrcp.push(l as u32);
                }
            }
            let mut ts = String::new();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_string(&ts);
            }
            if !ok {
                return false;
            }
        }
        if b.args == 0 {
            self.out.push_str("void");
        }
        self.out.push_str(") {\n");
        for k in 0..arrcp.len() {
            let l = arrcp[k];
            let mut nm2 = String::from_str("_");
            nm2.push_u64(l);
            let mut ts2 = String::new();
            if !self.ty_c(b.module, b.locals.at(l as usize).ty, nm2.as_str(), &mut ts2) {
                return false;
            }
            self.out.push_str("  ");
            self.out.push_string(&ts2);
            self.out.push_str(";\n  memcpy(&_");
            self.out.push_u64(l);
            self.out.push_str(", _");
            self.out.push_u64(l);
            self.out.push_str("_p, sizeof(_");
            self.out.push_u64(l);
            self.out.push_str("));\n");
        }
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
                    continue;
                }

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
                    let mut zero_len = false;
                    if n == 0 {
                        // an EMPTY array literal fill proves the length really is zero
                        for si9 in 0..b.statements.len() {
                            let s9 = *b.statements.at(si9);
                            if s9.kind != ir::ST_ASSIGN || s9.place == ir::IR_NONE {
                                continue;
                            }
                            let pl9 = *b.places.at(s9.place as usize);
                            if pl9.base != l as u32 || pl9.proj_len != 0 {
                                continue;
                            }
                            let rv9 = *b.rvalues.at(s9.rvalue as usize);
                            if rv9.kind == ir::RV_AGGREGATE && rv9.c == ir::AGG_ARRAY && rv9.b == 0 {
                                zero_len = true;
                                break;
                            }
                            if rv9.kind == ir::RV_USE {
                                let o9 = *b.operands.at(rv9.a as usize);
                                if o9.kind == ir::OP_COPY || o9.kind == ir::OP_MOVE {
                                    let sp9 = *b.places.at(o9.data as usize);
                                    if sp9.proj_len == 0 && self.filled_len(b, sp9.base) == 0 {
                                        // copied from another zero-length array local
                                        zero_len = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if n == 0 && !zero_len {
                        // a DECLARED `[T; 0]` is genuine (the checker interns len 0 for both the
                        // unsized sentinel and true zero): the LET's spelled length decides
                        let dn9 = b.locals.at(l).decl;
                        if dn9 != NODE_NONE {
                            let da9 = self.p().module_ast_const(b.module);
                            if da9.at_const(dn9).kind == NodeKind::NODE_LET {
                                let tn9 = da9.at_const(dn9).as_data.let_stmt.ty;
                                if tn9 != NODE_NONE && da9.at_const(tn9).kind == NodeKind::NODE_ARRAY_TYPE {
                                    let ln9 = da9.at_const(tn9).as_data.array_type.length;
                                    if ln9 != NODE_NONE && self.p().ceval != null {
                                        let cev9 = unsafe &mut *(self.p().ceval as *mut ce::ConstEval);
                                        let cv9 = cev9.eval(b.module, ln9);
                                        if cv9.kind == ce::CONST_INT && cv9.as_data.i == 0 {
                                            zero_len = true;
                                        }
                                    }
                                }
                            }
                        }
                        if !zero_len {
                            return self.fail("open-array");
                        }
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

        if !ok2 {
            return false;
        }
        self.out.push_str("}\n");
        return self.err.len() == 0;
    }

    /// Emit a closure body: `<ret> <sym>(<sym>_env *const __env, <params...>)` with
    /// captures read through the env; `env_out` receives the env struct typedef (empty when the
    /// closure captures nothing -- it is then a plain function taking only its params).
    pub fn emit_closure(self: &mut Self, b: &ir::CoreBody, cm: ModuleId, cnode: NodeId, sym: str, env_out: &mut String) bool {
        self.fn_attrs.truncate(0);
        self.err = "";
        self.arr_ret = false;
        let mark = self.out.len();
        if !self.emit_closure_inner(b, cm, cnode, sym, env_out) {
            self.out.truncate(mark);
            self.cap_base = 0;
            self.cap_on = false;
            self.cap_names.truncate(0);
            return false;
        }
        self.cap_base = 0;
        self.cap_on = false;
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
        self.cap_on = ncaps != 0;
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
        let mut env_pre = false; // the declaration pass defined this env (aggregate-embedded)
        if ncaps != 0 {
            let mut enm = String::from_str(sym);
            enm.push_str("_env");
            let mut eh = 1469598103934665603u64;
            {
                let es = enm.as_str();
                for k in 0..es.len() {
                    eh = (eh ^ es.byte_at(k) as u64) * 1099511628211u64;
                }
            }
            env_pre = (switch self.env_skip.get(&eh) {
                Some(_v) => true,
                None => false,
            });
            if !env_pre {
                // a closure can emit more than once (seed + drained instances): one env only
                self.env_skip.insert(eh, 1);
                self.env_hashes.push(eh);
            }
        }
        if ncaps != 0 && !env_pre {
            // named struct + a fwd typedef in the header's FORWARD section: aggregates and protos
            // may name the env before its body appears
            self.env_fwd.push_str("typedef struct ");
            self.env_fwd.push_str(sym);
            self.env_fwd.push_str("_env ");
            self.env_fwd.push_str(sym);
            self.env_fwd.push_str("_env;\n");
            env_out.push_str("struct ");
            env_out.push_str(sym);
            env_out.push_str("_env { ");
            for k in 0..ncaps {
                let l = (self.cap_base + k) as usize;
                if !self.mg.ctype(b.module, b.locals.at(l).ty, self.cap_names.at(k as usize).as_str(), env_out) {
                    return self.fail("closure-cap-ty");
                }
                env_out.push_str("; ");
            }
            env_out.push_str("};\n");
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
                self.out.push_str(sym);
                self.out.push_str("_env *const __env");
                if np != 0 {
                    self.out.push_str(", ");
                }
            }
        }

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
            if y.kind == TypeKind::TYPE_ARRAY {
                return true; // len 0 = a generic [T; N] interned unsized: still a C array field
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
                let is_arr = (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && y.kind == TypeKind::TYPE_ARRAY;
                if is_arr {
                    // Left out of the compound literal on purpose: C zero-inits any non-designated
                    // field, and the memcpy below fills it. Emitting `.arr = {0}` for an array of
                    // aggregates would trip -Werror=missing-braces on stricter cc lanes.
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
                    continue;
                }
                if emitted != 0 {
                    self.out.push_str(", ");
                }
                self.out.push_str(".");
                self.out.push_string(&fnm);
                self.out.push_str(" = ");
                let mut av = String::new();
                ok = self.emit_operand(b, opid, &mut av);
                self.out.push_string(&av);
                emitted += 1;
            }
            if emitted == 0 {
                self.out.push_str("0");
            }
            self.out.push_str(" };\n");
            self.out.push_string(&post);
        }
        return ok;
    }

    fn emit_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true; // markers carry no C
        }
        if s.kind != ir::ST_ASSIGN {
            return self.fail("stmt");
        }
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_ASM as u32 {
                return self.emit_asm_stmt(b, &rv0);
            }
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_SAFEPOINT as u32 {
                if self.safepoints_on(b.module) {
                    self.out.push_str("  __sc_safepoint();\n");
                }
                return true;
            }
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
                // an array literal COERCED to a slice view: `(Slice__T){ (T[N]){..}, N }` -- the
                // compound literal lives to the end of the enclosing block, like the old emitter's
                let mut rmS = b.module;
                let mut rtS = b.places.at(s.place as usize).ty;
                self.rty(b, b.places.at(s.place as usize).ty, &mut rmS, &mut rtS);
                let yS = *self.p().module_ast_const(rmS).type_at(rtS);
                if yS.kind == TypeKind::TYPE_INSTANCE {
                    let itS = *self.p().module_ast_const(rmS).instance(yS.as_data.inst);
                    let da9 = self.p().module_ast_const(itS.module);
                    let nsp9 = da9.at_const(da9.at_const(itS.decl).as_data.aggregate.name).as_data.name.text;
                    let nm9 = self.p().modules.at(itS.module as usize).source.as_str().slice(
                        nsp9.start as usize,
                        nsp9.end as usize,
                    );
                    if (nm9 == "Slice" || nm9 == "SliceMut") && itS.n >= 1 {
                        let mut lhs9 = String::new();
                        let mut cast9 = String::new();
                        let mut et9 = String::new();
                        let mut ok9 = self.emit_place(b, s.place, &mut lhs9) && self.ty_c(
                            b.module,
                            b.places.at(s.place as usize).ty,
                            "",
                            &mut cast9,
                        ) && self.mg.ctype(rmS, itS.args[0], "", &mut et9);
                        if ok9 {
                            self.out.push_str("  ");
                            self.out.push_string(&lhs9);
                            self.out.push_str(" = (");
                            self.out.push_string(&cast9);
                            self.out.push_str("){ .ptr = (");
                            self.out.push_string(&et9);
                            self.out.push_str("[");
                            self.out.push_u64(rv0.b);
                            self.out.push_str("]){ ");
                            for i9 in 0..rv0.b {
                                if !ok9 {
                                    break;
                                }
                                if i9 != 0 {
                                    self.out.push_str(", ");
                                }
                                let op9 = b.oper_pool[(rv0.a + i9) as usize];
                                if op9 == ir::IR_NONE {
                                    self.out.push_str("0");
                                } else {
                                    let mut ev9 = String::new();
                                    ok9 = self.emit_operand(b, op9, &mut ev9);
                                    self.out.push_string(&ev9);
                                }
                            }
                            self.out.push_str(" }, .len = ");
                            self.out.push_u64(rv0.b);
                            self.out.push_str(" };\n");
                        }
                        return ok9;
                    }
                }
                return self.emit_array_stores(b, s, &rv0);
            }
            if rv0.kind == ir::RV_REPEAT {
                return self.emit_repeat_stores(b, s, &rv0);
            }
            if rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_STRUCT && self.agg_has_array_field(b, &rv0) {
                return self.emit_struct_store_arrays(b, s, &rv0);
            }
        }
        // `new T { .. }`: allocate, then store the initializer through the fresh pointer
        {
            let rv0 = *b.rvalues.at(s.rvalue as usize);
            if rv0.kind == ir::RV_INTRINSIC && rv0.c as u32 == ir::IN_NEW as u32 {
                let mut rmN = b.module;
                let mut rtN = rv0.target;
                self.rty(b, rv0.target, &mut rmN, &mut rtN);
                let yN = *self.p().module_ast_const(rmN).type_at(rtN);
                if yN.kind != TypeKind::TYPE_POINTER && yN.kind != TypeKind::TYPE_REFERENCE {
                    return self.fail("new-target");
                }
                let mut es = String::new();
                if !self.ty_c(rmN, yN.as_data.elem, "", &mut es) {
                    return false;
                }
                let mut lhs = String::new();
                if !self.emit_place(b, s.place, &mut lhs) {
                    return false;
                }
                let mut iv = String::new();
                if rv0.b != 0 {
                    if !self.emit_operand(b, b.oper_pool[rv0.a as usize], &mut iv) {
                        return false;
                    }
                }
                self.out.push_str("  ");
                self.out.push_string(&lhs);
                self.out.push_str(" = malloc(sizeof(");
                self.out.push_string(&es);
                self.out.push_str("));\n");
                if iv.len() != 0 {
                    self.out.push_str("  *");
                    self.out.push_string(&lhs);
                    self.out.push_str(" = ");
                    self.out.push_string(&iv);
                    self.out.push_str(";\n");
                }
                return true;
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
            if ya.kind == TypeKind::TYPE_ARRAY && ya.as_data.arr.len == 0 {
                // a zero-length array store copies zero bytes: no C at all
                let rv0 = *b.rvalues.at(s.rvalue as usize);
                if rv0.kind == ir::RV_USE || rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY && rv0.b == 0 {
                    return true;
                }
            }
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
                    // a designated literal may carry FEWER elements than the destination (its
                    // recorded type keeps the spelled count): zero-fill, then copy what exists
                    let mut short_src = false;
                    {
                        let mut rmS = b.module;
                        let mut rtS = b.places.at(op0.data as usize).ty;
                        self.rty(b, b.places.at(op0.data as usize).ty, &mut rmS, &mut rtS);
                        let ys = *self.p().module_ast_const(rmS).type_at(rtS);
                        if ys.kind == TypeKind::TYPE_ARRAY && ys.as_data.arr.len != 0 && ys.as_data.arr.len as u64 < ya.as_data.arr.len as u64 {
                            short_src = true;
                        }
                    }
                    if short_src {
                        self.out.push_str("  memset(&");
                        self.out.push_string(&lhs2);
                        self.out.push_str(", 0, sizeof(");
                        self.out.push_string(&lhs2);
                        self.out.push_str("));\n");
                    }
                    self.out.push_str("  memcpy(&");
                    self.out.push_string(&lhs2);
                    self.out.push_str(", &");
                    self.out.push_string(&rhs2);
                    self.out.push_str(", sizeof(");
                    if short_src {
                        self.out.push_string(&rhs2);
                    } else {
                        self.out.push_string(&lhs2);
                    }
                    self.out.push_str("));\n");
                }
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
        return ok;
    }

    // C forbids array assignment: an array literal stores element-wise into the place.
    // `__asm__ volatile ("tpl" : "=r"(out).. : "r"(in).. : "clobber"..);` -- strings verbatim from
    // the NODE_ASM the rvalue's item names; outputs render the place a copy operand carries.
    fn emit_asm_stmt(self: &mut Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let a = self.p().module_ast_const(rv.item.module);
        let src = self.p().modules.at(rv.item.module as usize).source.as_str();
        let d = a.at_const(rv.item.node).as_data.asm_stmt;
        self.out.push_str("  __asm__ volatile (");
        if d.template == NODE_NONE {
            self.out.push_str("\"\"");
        } else {
            let ts = a.at_const(d.template).as_data.literal.raw;
            self.out.push_str(src.slice(ts.start as usize, ts.end as usize));
        }
        let nout = d.outputs.len / 2;
        let want = d.outputs.len != 0 || d.inputs.len != 0 || d.clobbers.len != 0;
        let mut ok = true;
        if want {
            self.out.push_str(" : ");
            let mut i: u32 = 0;
            while i + 1 < d.outputs.len && ok {
                if i != 0 {
                    self.out.push_str(", ");
                }
                let cs = a.at_const(unsafe a.list(d.outputs)[i as usize]).as_data.literal.raw;
                self.out.push_str(src.slice(cs.start as usize, cs.end as usize));
                self.out.push_str("(");
                let opid = b.oper_pool[(rv.a + i / 2) as usize];
                let op = *b.operands.at(opid as usize);
                if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                    let mut pv = String::new();
                    ok = self.emit_place(b, op.data, &mut pv);
                    self.out.push_string(&pv);
                } else {
                    ok = self.fail("asm-out");
                }
                self.out.push_str(")");
                i += 2;
            }
        }
        if (d.inputs.len != 0 || d.clobbers.len != 0) && ok {
            self.out.push_str(" : ");
            let mut i: u32 = 0;
            while i + 1 < d.inputs.len && ok {
                if i != 0 {
                    self.out.push_str(", ");
                }
                let cs = a.at_const(unsafe a.list(d.inputs)[i as usize]).as_data.literal.raw;
                self.out.push_str(src.slice(cs.start as usize, cs.end as usize));
                self.out.push_str("(");
                let opid = b.oper_pool[(rv.a + nout + i / 2) as usize];
                let mut ev = String::new();
                ok = self.emit_operand(b, opid, &mut ev);
                self.out.push_string(&ev);
                self.out.push_str(")");
                i += 2;
            }
        }
        if d.clobbers.len != 0 && ok {
            self.out.push_str(" : ");
            for k in 0..d.clobbers.len {
                if k != 0 {
                    self.out.push_str(", ");
                }
                let cs = a.at_const(unsafe a.list(d.clobbers)[k as usize]).as_data.literal.raw;
                self.out.push_str(src.slice(cs.start as usize, cs.end as usize));
            }
        }
        self.out.push_str(");\n");
        return ok;
    }

    fn emit_array_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let mut base = String::new();
        let mut ok = self.emit_place(b, s.place, &mut base);
        {
            // designated-init holes zero-fill: blank the storage before the written slots land
            let mut holes = false;
            for i in 0..rv.b {
                if b.oper_pool[(rv.a + i) as usize] == ir::IR_NONE {
                    holes = true;
                    break;
                }
            }
            if ok && holes {
                self.out.push_str("  memset(&");
                self.out.push_string(&base);
                self.out.push_str(", 0, sizeof(");
                self.out.push_string(&base);
                self.out.push_str("));\n");
            }
        }
        for i in 0..rv.b {
            if !ok {
                break;
            }
            let opid = b.oper_pool[(rv.a + i) as usize];
            if opid == ir::IR_NONE {
                continue;
            }
            let mut el = String::new();
            ok = self.emit_operand(b, opid, &mut el);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&base);
                self.out.push_str("[");
                self.out.push_u64(i);
                self.out.push_str("] = ");
                self.out.push_string(&el);
                self.out.push_str(";\n");
            }
        }
        return ok;
    }

    // `[v; N]` with a small constant count unrolls to element stores (the count operand id rides
    // rv.b); larger repeats stay unfrozen.
    fn emit_repeat_stores(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let cnt = *b.operands.at(rv.b as usize);
        let mut cv: i64 = 0 - 1;
        if cnt.kind == ir::OP_CONST {
            let c0 = *b.constants.at(cnt.data as usize);
            if c0.kind == ir::CK_INT && c0.val >= 0 {
                cv = c0.val;
            }
        }
        if cv < 0 {
            // a symbolic count (a named const or const-generic): the DESTINATION's array length
            // IS the count by typing
            let mut rmR = b.module;
            let mut rtR = b.places.at(s.place as usize).ty;
            self.rty(b, b.places.at(s.place as usize).ty, &mut rmR, &mut rtR);
            let yR = *self.p().module_ast_const(rmR).type_at(rtR);
            if yR.kind == TypeKind::TYPE_ARRAY && yR.as_data.arr.len != 0 {
                cv = yR.as_data.arr.len;
            }
        }
        if cv < 0 {
            return self.fail("repeat-count");
        }
        let c = ir::Constant {
            kind: ir::CK_INT,
            ty: TYPE_NONE,
            val: cv,
            raw: tok::Span { start: 0, end: 0 },
            item: DefId { module: 0, node: NODE_NONE },
            targ_start: 0,
            targ_len: 0,
        };
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
                        let kl8 = if sb8.lim as usize < k8 {
                            sb8.lim as usize;
                        } else {
                            k8;
                        };
                        let mut cv8: i64 = 0;
                        if self.mg.fold_cval_at(sb8.am, sb8.at, &mut cv8, kl8) {
                            cur.push_i64(cv8);
                            folded = true;
                            break;
                        }
                    }
                }
            }
            if !folded && (item.node == NODE_NONE || !self.mg.const_sym(b.module, item.module, item.node, &mut cur)) {
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
                    let idn = self.p().module_ast_const(item.module).at_const(item.node);
                    let hdr_owned = idn.kind == NodeKind::NODE_CONST && idn.as_data.const_def.is_extern;
                    if !hdr_owned {
                        // extern-block statics skip the stub: the backing header declares them
                        // (with qualifiers a re-declaration here could contradict)
                        let mut sd = String::from_str("extern ");
                        if self.ty_c(b.module, b.locals.at(pl.base as usize).ty, cur.as_str(), &mut sd) {
                            sd.push_str(";\n");
                            self.stat_decls.push_string(&sd);
                            self.stat_items.push(
                                StatRef {
                                    em: b.module,
                                    def: item,
                                    sym: cur.clone(),
                                    ty: b.locals.at(pl.base as usize).ty,
                                },
                            );
                        }
                    }
                }
            }
        } else if self.cap_on && pl.base >= self.cap_base && pl.base as usize < self.cap_base as usize + self.cap_names.len() {
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
                    cur = w2;
                    rm2 = nm2;
                    rt2 = nt2;
                    g2 += 1;
                }
                let a2 = self.p().module_ast_const(rm2);
                let mut chk = false; // length-carrying views bounds-check every subscript
                let mut base_txt = String::new();
                if a2.type_at(rt2).kind == TypeKind::TYPE_INSTANCE {
                    let it2 = *a2.instance(a2.type_at(rt2).as_data.inst);
                    let da2 = self.p().module_ast_const(it2.module);
                    let nsp2 = da2.at_const(da2.at_const(it2.decl).as_data.aggregate.name).as_data.name.text;
                    let nsrc2 = self.p().modules.at(it2.module as usize).source.as_str();
                    let nmv = nsrc2.slice(nsp2.start as usize, nsp2.end as usize);
                    if nmv == "Slice" || nmv == "SliceMut" || nmv == "Vector" {
                        chk = true;
                        base_txt.push_string(&cur);
                    }
                    if nmv == "Array" {
                        cur.push_str(".data");
                    } else {
                        cur.push_str(".ptr");
                    }
                } else if self.is_str_ty(rm2, rt2) {
                    chk = true;
                    base_txt.push_string(&cur);
                    cur.push_str(".ptr");
                }
                cur.push_str("[");
                if chk {
                    cur.push_str("__sc_bounds(");
                }
                if pj.kind == ir::PJ_INDEX_CONST {
                    cur.push_u64(pj.data);
                } else {
                    ok = self.emit_operand(b, pj.data, &mut cur);
                }
                if chk {
                    cur.push_str(", ");
                    cur.push_string(&base_txt);
                    cur.push_str(".len)");
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
                    cur = w;
                }
            }
        }
        if ok {
            dst.push_string(&cur);
        }
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

    // Resolve a binary operand's VALUE type, peeling one reference (operator position auto-derefs;
    // the C operand is then a pointer). True = a reference was peeled.
    fn bin_op_ty(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        let op = *b.operands.at(opid as usize);
        *rm = b.module;
        *rt = op.ty;
        self.rty(b, op.ty, rm, rt);
        let y = *self.p().module_ast_const(*rm).type_at(*rt);
        if y.kind == TypeKind::TYPE_REFERENCE {
            let em = *rm;
            let mut nm = em;
            let mut nt = y.as_data.elem;
            if self.mg.resolve(em, y.as_data.elem, &mut nm, &mut nt) {
                *rm = nm;
                *rt = nt;
                return true;
            }
        }
        return false;
    }

    fn emit_op_d(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, deref: bool, dst: &mut String) bool {
        if deref {
            dst.push_str("(*");
            let ok = self.emit_operand(b, opid, dst);
            dst.push_str(")");
            return ok;
        }
        return self.emit_operand(b, opid, dst);
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
            // are raw BYTES and re-escape byte-wise (the lowerer records the token kind in val's
            // low byte; bit 8 = a FORMAT SEGMENT, whose `{{`/`}}` collapse to one brace)
            let tk9 = c.val & 255;
            let seg9 = (c.val & 256) != 0;
            let plain = tk9 == tt::TokenType::StringLiteral as i64 || tk9 == tt::TokenType::ByteStringLiteral as i64;
            // reflection `name` constants span a FOREIGN module's source (item marks it)
            let src9 = if c.item.node != NODE_NONE {
                self.p().modules.at(c.item.module as usize).source.as_str();
            } else {
                src;
            };
            let mut raw0 = src9.slice(c.raw.start as usize, c.raw.end as usize);
            if raw0.len() >= 2 && raw0.byte_at(0) == 34 && raw0.byte_at(raw0.len() - 1) == 34 {
                raw0 = raw0.slice(1, raw0.len() - 1); // some spans keep their quotes
            } else if raw0.len() >= 5 && raw0.byte_at(0) == b'M' && raw0.byte_at(1) == 34 && raw0.byte_at(
                raw0.len() - 1,
            ) == 34 {
                // matchertext spans keep their M"( )" frame -- any matcher pair delimits
                let o9 = raw0.byte_at(2);
                let c9 = raw0.byte_at(raw0.len() - 2);
                let pair = o9 == b'(' && c9 == b')' || o9 == b'[' && c9 == b']' || o9 == b'{' && c9 == b'}' || o9 == b'<' && c9 == b'>';
                if pair {
                    raw0 = raw0.slice(3, raw0.len() - 2);
                }
            }
            let mut braced = String::new();
            if seg9 && (tk9 == tt::TokenType::StringLiteral as i64 || tk9 == tt::TokenType::RawStringLiteral as i64) {
                let mut i9: usize = 0;
                while i9 < raw0.len() {
                    let b9 = raw0.byte_at(i9);
                    braced.push_byte(b9);
                    if (b9 == 123 || b9 == 125) && i9 + 1 < raw0.len() && raw0.byte_at(i9 + 1) == b9 {
                        i9 += 2;
                    } else {
                        i9 += 1;
                    }
                }
                raw0 = braced.as_str();
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
                        // a C-string context: the bare (escaped) string, cast to the target pointer type
                        let mut cp = String::new();
                        if !self.ty_c(b.module, c.ty, "", &mut cp) {
                            return false;
                        }
                        dst.push_str("(");
                        dst.push_string(&cp);
                        dst.push_str(")\"");
                        dst.push_str(txt);
                        dst.push_str("\"");
                        return true;
                    }
                }
            }
            let is_slice = c.ty != TYPE_NONE && a.type_at(c.ty).kind == TypeKind::TYPE_INSTANCE;
            let mut cast = String::new();
            if c.ty == TYPE_NONE {
                cast.push_str("str"); // untyped string tests (switch patterns) are `str` views
            } else if !self.ty_c(b.module, c.ty, "", &mut cast) {
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
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
            return true;
        }
        if c.kind == ir::CK_ITEM {
            return self.callee_sym(b, c.item, c.targ_start, c.targ_len, TYPE_NONE, TYPE_NONE, dst);
        }
        if c.kind == ir::CK_WIDE {
            // the frozen wide-int shape: `((T){ .bits = { .limbs = { 0x..ULL, ... } } })`
            let a0 = self.p().module_ast_const(b.module);
            let w = *unsafe a0.wide_lits.at(c.val as usize);
            // the CONTEXTUAL type wins (`let mx: i128 = <lit>` spells Int__128, not the default)
            // -- but only when it resolves to a big-int instance (operand-position literals type
            // as the SCALAR the checker later widens)
            let mut ct = w.ty;
            if c.ty != TYPE_NONE {
                let mut cm9 = b.module;
                let mut ct9 = c.ty;
                self.rty(b, c.ty, &mut cm9, &mut ct9);
                if self.p().module_ast_const(cm9).type_at(ct9).kind == TypeKind::TYPE_INSTANCE {
                    ct = c.ty;
                }
            }
            let mut tn = String::new();
            if !self.ty_c(b.module, ct, "", &mut tn) {
                return false;
            }
            dst.push_str("((");
            dst.push_string(&tn);
            dst.push_str("){ .bits = { .limbs = { ");
            let mut last: usize = 0;
            for i in 0..16 {
                if unsafe w.limbs[i as usize] != 0 {
                    last = i as usize;
                }
            }
            for i in 0..last + 1 {
                if i != 0 {
                    dst.push_str(", ");
                }
                dst.push_str("0x");
                dst.push_hex(unsafe w.limbs[i], false);
                dst.push_str("ULL");
            }
            dst.push_str(" } } })");
            return true;
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
            if c.kind == ir::CK_INT {
                dst.push_str(if_s(self.int_is_unsigned(b, c.ty), "ULL", "LL"));
            }
            return true;
        }
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
    /// Demand the generic-extend impl method `method_by_name` just resolved (its `last_method_def`).
    /// These resolve by receiver spelling alone -- interface dispatch, switch `eq`, drop `free` --
    /// so an unplanned instance receiver reaches them with no demanding call edge.
    fn demand_impl(self: &mut Self, rm6: ModuleId, rt6: TypeId, sym: &String) {
        let idef = self.mg.last_method_def;
        if !self.collect_demand || idef.node == NODE_NONE || !self.mg.in_generic_extend(idef.module, idef.node) {
            return;
        }
        let y8 = *self.p().module_ast_const(rm6).type_at(rt6);
        if y8.kind != TypeKind::TYPE_INSTANCE {
            return;
        }
        let ia = self.p().module_ast_const(idef.module);
        let ifd = ia.at_const(idef.node);
        if ifd.kind != NodeKind::NODE_FUNCTION || ifd.as_data.function.is_extern || ifd.as_data.function.body == NODE_NONE {
            return;
        }
        let rit = *self.p().module_ast_const(rm6).instance(y8.as_data.inst);
        let mut snap = Vector::<mbe::MSub>::new();
        for i in 0..self.mg.subs.len() {
            snap.push(*self.mg.subs.at(i));
        }
        let g0 = snap.len() as u32;
        let eg = self.mg.extend_generics(idef.module, idef.node);
        let mut gi: u32 = 0;
        while gi < eg.len && gi as u8 < rit.n {
            self.push_bind(
                &mut snap,
                idef.module,
                unsafe ia.list(eg)[gi as usize],
                rm6,
                unsafe rit.args[gi as usize],
                g0,
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
                rm6,
                unsafe rit.args[gj as usize],
                g0,
            );
            gj += 1;
        }
        let mut sfx = String::new();
        for i2 in 0..rit.n {
            sfx.push_str("__");
            if !self.mg.type_m(rm6, unsafe rit.args[i2 as usize], &mut sfx) {
                return;
            }
        }
        self.demand.push(Demand { def: idef, sym: sym.clone(), subs: snap, sfx: sfx });
    }

    // Aggregate operands that dispatch operators through methods: structs, instances, and
    // payload-carrying enums (their C value is a struct; bare enums compare as integers).
    fn op_dispatch_agg(self: &mut Self, rm: ModuleId, rt: TypeId) bool {
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_INSTANCE {
            return true;
        }
        if y.kind == TypeKind::TYPE_ENUM {
            return self.enum_has_payload(y.module, y.as_data.decl);
        }
        return false;
    }

    // The interface-DEFAULT instance for `mname` on resolved receiver `(rm, rt)`: scan the decl's
    // conformances for an interface declaring `mname` with a default body, render + demand its
    // per-conformance symbol. False = no conformance supplies it.
    fn conf_default_sym(self: &mut Self, rm: ModuleId, rt: TypeId, mname: str, dst: &mut String) bool {
        let a = self.p().module_ast_const(rm);
        let y = *a.type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *a.instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE {
            return false;
        }
        let da = self.p().module_ast_const(dm);
        let items = unsafe da.at_const(da.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe da.list(items)[i as usize];
            let itn = da.at_const(iid);
            if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE || itn.as_data.extend_def.interface_type == NODE_NONE {
                continue;
            }
            let tg = da.resolution_def(itn.as_data.extend_def.target_type);
            if tg.module != dm || tg.node != dd {
                continue;
            }
            let ifd = da.resolution_def(itn.as_data.extend_def.interface_type);
            if ifd.node == NODE_NONE {
                continue;
            }
            let ia = self.p().module_ast_const(ifd.module);
            if ia.at_const(ifd.node).kind != NodeKind::NODE_INTERFACE {
                continue;
            }
            let ms = ia.at_const(ifd.node).as_data.interface_def.items;
            let isrc = self.p().modules.at(ifd.module as usize).source.as_str();
            for j in 0..ms.len {
                let mid = unsafe ia.list(ms)[j as usize];
                let mn = ia.at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION || mn.as_data.function.body == NODE_NONE {
                    continue;
                }
                let s2 = ia.at_const(mn.as_data.function.name).as_data.name.text;
                if isrc.slice(s2.start as usize, s2.end as usize) == mname {
                    return self.iface_target_sym(rm, rt, DefId { module: ifd.module, node: mid }, dst);
                }
            }
        }
        return false;
    }

    fn iface_target_sym(self: &mut Self, rm6: ModuleId, rt6: TypeId, callee: DefId, dst: &mut String) bool {
        let mut sym = String::new();
        {
            let ca8 = self.p().module_ast_const(callee.module);
            let msp8 = ca8.at_const(ca8.at_const(callee.node).as_data.function.name).as_data.name.text;
            let msrc8 = self.p().modules.at(callee.module as usize).source.as_str();
            let mname8 = msrc8.slice(msp8.start as usize, msp8.end as usize);
            let mut impl_sym = String::new();
            if self.mg.method_by_name(rm6, rt6, mname8, &mut impl_sym) {
                self.demand_impl(rm6, rt6, &impl_sym);
                dst.push_string(&impl_sym);
                return true;
            }
        }
        let y7 = *self.p().module_ast_const(rm6).type_at(rt6);
        if y7.kind == TypeKind::TYPE_BUILTIN {
            self.mg.modpfx(callee.module, &mut sym);
            if !self.mg.type_m(rm6, rt6, &mut sym) {
                return self.fail("iface-default-recv");
            }
        } else if y7.kind == TypeKind::TYPE_INSTANCE {
            let it7 = *self.p().module_ast_const(rm6).instance(y7.as_data.inst);
            if !self.mg.inst_name(rm6, &it7, &mut sym) {
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
                let l7 = snap.len() as u32;
                snap.push(mbe::MSub { pm: callee.module, pnode: idecl, am: rm6, at: rt6, lim: l7 });
                self.demand.push(Demand { def: callee, sym: sym.clone(), subs: snap, sfx: String::new() });
            }
        }
        dst.push_string(&sym);
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
            return self.fail("dyn-stem");
        }
        let mut src = String::new();
        if !self.mg.type_m(srm, srt, &mut src) {
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
        return ok;
    }

    // The declared single return type of `fnid` (pool `m`), or TYPE_NONE.
    const fn fn_ret_ty(self: &Self, m: ModuleId, fnid: NodeId) TypeId {
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
                }
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
        }
        if ok && (wants & 1) != 0 && self.is_destructible(tm, fxt, 0) {
            let mut fe = String::new();
            ok = self.free_expr(tm, fxt, &mut fe);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&fe);
                self.out.push_str("(&__fx);\n");
            }
        }
        self.out.push_str("}\n");
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
            }
            self.out.push_str("}\n");
        }

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
            }
        }
        let sy = *self.p().module_ast_const(srm).type_at(srt);
        if ok {
            head.push_str(") { ");
            if !is_void {
                head.push_str("return ");
            }
            if sy.kind == TypeKind::TYPE_FUNCTION {
                // the closure's env param is NON-const (the body frees its captures on call)
                let mut cs = String::new();
                self.mg.closure_sym(sy.module, sy.as_data.decl, &mut cs);
                head.push_string(&cs);
                head.push_str("((");
                head.push_str(srcc);
                head.push_str(" *)__self");
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
        return ok;
    }

    // Structural bind: match declared type `(dm, dt)` against concrete `(am, at)`, binding any
    // generic PARAM OF `gens` it names (refs/pointers peel in lockstep; instances match decls and
    // recurse arguments). Bindings append as (param node, pool, type).
    fn unify_bind(
        self: &mut Self,
        dm: ModuleId,
        dt: TypeId,
        am0: ModuleId,
        at0: TypeId,
        gm: ModuleId,
        gens: NodeList,
        out_p: &mut Vector<NodeId>,
        out_m: &mut Vector<ModuleId>,
        out_t: &mut Vector<TypeId>,
        depth: u32,
    ) {
        if depth > 8 || dt == TYPE_NONE || at0 == TYPE_NONE {
            return;
        }
        let mut am = am0;
        let mut at = at0;
        let _ = self.mg.resolve(am0, at0, &mut am, &mut at);
        let dy = *self.p().module_ast_const(dm).type_at(dt);
        let ay = *self.p().module_ast_const(am).type_at(at);
        if dy.kind == TypeKind::TYPE_GENERIC {
            let ga = self.p().module_ast_const(gm);
            for i in 0..gens.len {
                if dy.module == gm && dy.as_data.decl == unsafe ga.list(gens)[i as usize] {
                    out_p.push(dy.as_data.decl);
                    out_m.push(am);
                    out_t.push(at);
                    return;
                }
            }
            return;
        }
        if dy.kind == TypeKind::TYPE_REFERENCE || dy.kind == TypeKind::TYPE_POINTER {
            // one-sided peel: a by-ref param matches a VALUE argument (the call spelling adds `&`)
            let mut at2 = at;
            if ay.kind == TypeKind::TYPE_REFERENCE || ay.kind == TypeKind::TYPE_POINTER {
                at2 = ay.as_data.elem;
            }
            self.unify_bind(dm, dy.as_data.elem, am, at2, gm, gens, out_p, out_m, out_t, depth + 1);
            return;
        }
        if dy.kind == TypeKind::TYPE_INSTANCE && ay.kind == TypeKind::TYPE_INSTANCE {
            let dit = *self.p().module_ast_const(dm).instance(dy.as_data.inst);
            let ait = *self.p().module_ast_const(am).instance(ay.as_data.inst);
            if dit.module == ait.module && dit.decl == ait.decl {
                let mut k: u8 = 0;
                while k < dit.n && k < ait.n {
                    self.unify_bind(
                        dm,
                        unsafe dit.args[k as usize],
                        am,
                        unsafe ait.args[k as usize],
                        gm,
                        gens,
                        out_p,
                        out_m,
                        out_t,
                        depth + 1,
                    );
                    k += 1;
                }
            }
        }
    }

    /// A conversion method WITH its own generics: the receiver instance is the coercion TARGET;
    /// the method's params bind by unifying its first declared parameter against the argument.
    /// Symbol: `<InstName>__<method>__<bound mangles...>` (the spec rule), demanded accordingly.
    fn conv_sym(self: &mut Self, b: &ir::CoreBody, callee: DefId, arg_ty: TypeId, target_ty: TypeId, dst: &mut String) bool {
        let ca = self.p().module_ast_const(callee.module);
        let fd = ca.at_const(callee.node);
        let tgt = self.mg.method_target(callee.module, callee.node);
        let mut rpm = b.module;
        let rit = self.recv_inst(b, target_ty, tgt, &mut rpm);
        if rit.decl == NODE_NONE {
            return self.fail("conv-recv");
        }
        // bind the method's own generics from the first declared param vs the argument
        let gens = fd.as_data.function.generics;
        let ps = fd.as_data.function.params;
        let mut bp = Vector::<NodeId>::new();
        let mut bm = Vector::<ModuleId>::new();
        let mut bt = Vector::<TypeId>::new();
        if ps.len != 0 {
            let p0 = unsafe ca.list(ps)[0];
            let mut arm = b.module;
            let mut art = arg_ty;
            self.rty(b, arg_ty, &mut arm, &mut art);
            self.unify_bind(callee.module, ca.type_of(p0), arm, art, callee.module, gens, &mut bp, &mut bm, &mut bt, 0);
        }
        if bp.len() as u32 < gens.len {
            // generics the argument does not name bind from the RESULT (`from<const M>() UInt<M>`)
            let rt0 = self.fn_ret_ty(callee.module, callee.node);
            if rt0 != TYPE_NONE {
                let mut tm0 = b.module;
                let mut tt0 = target_ty;
                self.rty(b, target_ty, &mut tm0, &mut tt0);
                self.unify_bind(callee.module, rt0, tm0, tt0, callee.module, gens, &mut bp, &mut bm, &mut bt, 0);
            }
        }
        if bp.len() as u32 != gens.len {
            return self.fail("conv-bind");
        }
        let mut sym = String::new();
        if !self.mg.inst_name(rpm, &rit, &mut sym) {
            return self.fail("conv-inst");
        }
        sym.push_str("__");
        self.mg.ident(callee.module, ca.at_const(fd.as_data.function.name).as_data.name.text, &mut sym);
        let mut sfx = String::new();
        let mut sok = true;
        for i in 0..bp.len() {
            sfx.push_str("__");
            if !self.mg.type_m(bm[i], bt[i], &mut sfx) {
                sok = false;
                break;
            }
        }
        if !sok {
            return self.fail("conv-targ");
        }
        sym.push_string(&sfx);
        if self.collect_demand && !fd.as_data.function.is_extern && fd.as_data.function.body != NODE_NONE {
            let mut snap = Vector::<mbe::MSub>::new();
            for i in 0..self.mg.subs.len() {
                snap.push(*self.mg.subs.at(i));
            }
            let g0 = snap.len() as u32;
            let eg = self.mg.extend_generics(callee.module, callee.node);
            let mut gi: u32 = 0;
            while gi < eg.len && gi as u8 < rit.n {
                self.push_bind(
                    &mut snap,
                    callee.module,
                    unsafe ca.list(eg)[gi as usize],
                    rpm,
                    unsafe rit.args[gi as usize],
                    g0,
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
                    g0,
                );
                gj += 1;
            }
            for i in 0..bp.len() {
                self.push_bind(&mut snap, callee.module, bp[i], bm[i], bt[i], g0);
            }
            self.demand.push(Demand { def: callee, sym: sym.clone(), subs: snap, sfx: sfx });
        }
        dst.push_string(&sym);
        return true;
    }

    // `  left:  <value>` diagnostics for a failed assert_eq/ne, formatted per operand type;
    // unprintable types skip the line rather than fail the emission.
    fn assert_value_line(self: &mut Self, b: &ir::CoreBody, label: str, opid: ir::OperandId) bool {
        let mut ev = String::new();
        if !self.emit_operand(b, opid, &mut ev) {
            return false;
        }
        let mut rm = b.module;
        let mut rt = b.operands.at(opid as usize).ty;
        self.rty(b, b.operands.at(opid as usize).ty, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            if bt == BuiltinType::BT_BOOL {
                self.out.push_str("fprintf(stderr, \"  ");
                self.out.push_str(label);
                self.out.push_str(" %s\\n\", (");
                self.out.push_string(&ev);
                self.out.push_str(") ? \"true\" : \"false\"); ");
                return true;
            }
            if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 {
                self.out.push_str("fprintf(stderr, \"  ");
                self.out.push_str(label);
                self.out.push_str(" %g\\n\", (double)(");
                self.out.push_string(&ev);
                self.out.push_str(")); ");
                return true;
            }
            if bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE {
                self.out.push_str("fprintf(stderr, \"  ");
                self.out.push_str(label);
                self.out.push_str(" %llu\\n\", (unsigned long long)(");
                self.out.push_string(&ev);
                self.out.push_str(")); ");
                return true;
            }
            if bt == BuiltinType::BT_CHAR || bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE {
                self.out.push_str("fprintf(stderr, \"  ");
                self.out.push_str(label);
                self.out.push_str(" %lld\\n\", (long long)(");
                self.out.push_string(&ev);
                self.out.push_str(")); ");
                return true;
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_STRUCT {
            let da = self.p().module_ast_const(y.module);
            let ns = da.at_const(da.at_const(y.as_data.decl).as_data.aggregate.name).as_data.name.text;
            let nm = self.p().modules.at(y.module as usize).source.as_str().slice(ns.start as usize, ns.end as usize);
            if nm == "str" {
                self.out.push_str("fprintf(stderr, \"  ");
                self.out.push_str(label);
                self.out.push_str(" \\\"%.*s\\\"\\n\", (int)(");
                self.out.push_string(&ev);
                self.out.push_str(").len, (const char *)(");
                self.out.push_string(&ev);
                self.out.push_str(").ptr); ");
                return true;
            }
        }
        return true;
    }

    // Preemption safepoints print only when the package uses the coroutine runtime, and never
    // inside std::parallel itself (its loops hold internal locks across iterations).
    fn safepoints_on(self: &mut Self, m: ModuleId) bool {
        if self.uses_tasks == 0 {
            self.uses_tasks = 1;
            if self.p().find("std::parallel::runtime") >= 0 {
                self.uses_tasks = 2;
            }
        }
        if self.uses_tasks != 2 {
            return false;
        }
        if m as usize < self.p().modules.len() {
            return !self.p().modules.at(m as usize).path.as_str().starts_with("std::parallel");
        }
        return true;
    }

    // A `@blocking` extern function (non-variadic): calls route through a pool wrapper.
    fn blocking_callee(self: &Self, d: DefId) bool {
        let a = unsafe &*self.p().module_ast_const(d.module);
        if a.at_const(d.node).kind != NodeKind::NODE_FUNCTION || a.at_const(d.node).as_data.function.is_variadic {
            return false;
        }
        for k in 0..a.attrs.len() {
            if a.attrs.at(k).owner == d.node && a.attrs.at(k).kind == AttrKind::ATTR_BLOCKING as u8 {
                return true;
            }
        }
        return false;
    }

    // env typedef + pool trampoline + wrapper for one `@blocking` callee (emitted once, into the
    // shared instance TU; call sites everywhere link against the wrapper).
    fn blk_wrapper(self: &mut Self, d: DefId) bool {
        let key = d.module as u64 << 32 | d.node as u64;
        let hit = switch self.blk_seen.get(&key) {
            Some(_v) => true,
            None => false,
        };
        if hit {
            return true;
        }
        self.blk_seen.insert(key, 1);
        if self.blk_defs.len() == 0 {
            // the pool's C-callable entry point (std::parallel::blocking, symbol pinned @c.export)
            self.blk_defs.push_str("void __sc_blocking_run(void (*__r)(void *), void *__e);\n");
        }
        let a = self.p().module_ast_const(d.module);
        let f = a.at_const(d.node).as_data.function;
        let mut nm = String::new();
        self.mg.ident(d.module, a.at_const(f.name).as_data.name.text, &mut nm);
        let mut rt = TYPE_NONE;
        if f.returns.len == 1 {
            rt = a.type_of(unsafe a.list(f.returns)[0]);
        }
        let mut rty = String::new();
        let mut is_void = rt == TYPE_NONE;
        if !is_void {
            let y = *a.type_at(rt);
            is_void = y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID;
        }
        if is_void {
            rty.push_str("void");
        } else if !self.mg.ctype(d.module, rt, "", &mut rty) {
            return false;
        }
        let np = f.params.len;
        let mut env = String::from_str("typedef struct { ");
        let mut wrap_params = String::new();
        for k in 0..np {
            let pid = unsafe a.list(f.params)[k as usize];
            let pt = a.type_of(a.at_const(pid).as_data.parameter.ty);
            let mut an = String::from_str("a");
            an.push_u64(k);
            if !self.mg.ctype(d.module, pt, an.as_str(), &mut env) {
                return false;
            }
            env.push_str("; ");
            if k != 0 {
                wrap_params.push_str(", ");
            }
            if !self.mg.ctype(d.module, pt, an.as_str(), &mut wrap_params) {
                return false;
            }
        }
        if np == 0 {
            wrap_params.push_str("void");
        }
        if !is_void {
            if !self.mg.ctype(d.module, rt, "r", &mut env) {
                return false;
            }
            env.push_str("; ");
        }
        env.push_str("} __sc_blk_");
        env.push_string(&nm);
        env.push_str("_env;\n");
        self.blk_defs.push_string(&env);
        self.blk_defs.push_str("static void __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_run(void *__e) { __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env *__v = (__sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env *)__e; ");
        if !is_void {
            self.blk_defs.push_str("__v->r = ");
        }
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("(");
        for k in 0..np {
            if k != 0 {
                self.blk_defs.push_str(", ");
            }
            self.blk_defs.push_str("__v->a");
            self.blk_defs.push_u64(k);
        }
        self.blk_defs.push_str("); }\n");
        self.blk_defs.push_string(&rty);
        self.blk_defs.push_str(" __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("(");
        self.blk_defs.push_string(&wrap_params);
        self.blk_defs.push_str(") { __sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_env __v; ");
        for k in 0..np {
            self.blk_defs.push_str("__v.a");
            self.blk_defs.push_u64(k);
            self.blk_defs.push_str(" = a");
            self.blk_defs.push_u64(k);
            self.blk_defs.push_str("; ");
        }
        self.blk_defs.push_str("__sc_blocking_run(__sc_blk_");
        self.blk_defs.push_string(&nm);
        self.blk_defs.push_str("_run, &__v); ");
        if !is_void {
            self.blk_defs.push_str("return __v.r; ");
        }
        self.blk_defs.push_str("}\n");
        // cross-TU call sites see the wrapper through the shared protos
        self.extern_protos.push_string(&rty);
        self.extern_protos.push_str(" __sc_blk_");
        self.extern_protos.push_string(&nm);
        self.extern_protos.push_str("(");
        self.extern_protos.push_string(&wrap_params);
        self.extern_protos.push_str(");\n");
        return true;
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
        // freshness: `last_method_def` must reflect THIS call's resolution (arg emission reads it)
        self.mg.last_method_def = DefId { module: 0, node: NODE_NONE };
        // `@blocking`: the call goes to the generated wrapper, which hands the work to the
        // blocking pool and parks this coroutine rather than holding a worker thread
        if callee.node != NODE_NONE && self.blocking_callee(callee) {
            if !self.blk_wrapper(callee) {
                return self.fail("blocking-wrap");
            }
            let ba = self.p().module_ast_const(callee.module);
            dst.push_str("__sc_blk_");
            self.mg.ident(
                callee.module,
                ba.at_const(ba.at_const(callee.node).as_data.function.name).as_data.name.text,
                dst,
            );
            return true;
        }
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
                return self.fail("iface-default-recv");
            }
            return self.iface_target_sym(rm6, rt6, callee, dst);
        }
        let is_minst = self.mg.in_generic_extend(callee.module, callee.node);
        let mut rit = TyInstance { decl: NODE_NONE };
        let mut rpm = b.module; // the pool the receiver instance (and its args) live in
        let mut recv_targs = false; // the call's bound args NAME the receiver (turbofish assoc fn)
        if is_minst {
            // a generic extend's method emits per receiver instance: `<InstName>__<method>`
            let tgt = self.mg.method_target(callee.module, callee.node);
            // arg0 spells the receiver only for methods: a static assoc fn's first argument is an
            // unrelated value (`convert(&narrow)` targets the WIDE instance, named by the dest)
            let mut self0 = false;
            {
                let ca0 = self.p().module_ast_const(callee.module);
                let ps0 = ca0.at_const(callee.node).as_data.function.params;
                if ps0.len != 0 {
                    let p0 = unsafe ca0.list(ps0)[0];
                    let nm0 = ca0.at_const(ca0.at_const(p0).as_data.parameter.name).as_data.name.text;
                    let src0 = self.p().modules.at(callee.module as usize).source.as_str();
                    self0 = src0.slice(nm0.start as usize, nm0.end as usize) == "self";
                }
            }
            if self0 {
                rit = self.recv_inst(b, recv_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE {
                rit = self.recv_inst(b, dest_ty, tgt, &mut rpm);
            }
            if rit.decl == NODE_NONE && targs_len != 0 && tgt.node != NODE_NONE {
                // `Type::<Args>::assoc()`: no receiver value or typed dest -- the checker's bound
                // args ARE the target's generic arguments (inst_name resolves each through the env)
                let tda = self.p().module_ast_const(tgt.module);
                let tk9 = tda.at_const(tgt.node).kind;
                if (tk9 == NodeKind::NODE_STRUCT || tk9 == NodeKind::NODE_ENUM) && tda.at_const(tgt.node).as_data.aggregate.generics.len == targs_len && targs_len <= 8 {
                    rit.module = tgt.module;
                    rit.decl = tgt.node;
                    rit.n = targs_len as u8;
                    for k9 in 0..targs_len {
                        unsafe rit.args[k9 as usize] = b.targ_pool[(targs_start + k9) as usize];
                    }
                    rpm = b.module;
                    recv_targs = true;
                }
            }
            if rit.decl == NODE_NONE && tgt.node != NODE_NONE {
                // inside a generic-extend instance, `Type::<OwnParams>::assoc()` names the
                // CURRENT receiver: every target generic is bound in the active env (the demand
                // snapshot keys struct params by (target module, param node))
                let tda = self.p().module_ast_const(tgt.module);
                let tk9 = tda.at_const(tgt.node).kind;
                if tk9 == NodeKind::NODE_STRUCT || tk9 == NodeKind::NODE_ENUM {
                    let gs9 = tda.at_const(tgt.node).as_data.aggregate.generics;
                    if gs9.len != 0 && gs9.len <= 8 {
                        let mut all9 = true;
                        let mut pool9: ModuleId = 0;
                        let mut nb9: u32 = 0;
                        for g9 in 0..gs9.len {
                            let pn9 = unsafe tda.list(gs9)[g9 as usize];
                            let mut hit9 = false;
                            let mut i9 = self.mg.subs.len();
                            while i9 > 0 {
                                i9 -= 1;
                                let sb9 = *self.mg.subs.at(i9);
                                if sb9.pm == tgt.module && sb9.pnode == pn9 {
                                    if nb9 == 0 {
                                        pool9 = sb9.am;
                                    }
                                    if sb9.am == pool9 {
                                        unsafe rit.args[nb9 as usize] = sb9.at;
                                        nb9 += 1;
                                        hit9 = true;
                                    }
                                    break;
                                }
                            }
                            if !hit9 {
                                all9 = false;
                                break;
                            }
                        }
                        if all9 && nb9 == gs9.len {
                            rit.module = tgt.module;
                            rit.decl = tgt.node;
                            rit.n = nb9 as u8;
                            rpm = pool9;
                            recv_targs = targs_len == 0 || recv_targs;
                        }
                    }
                }
            }
            if rit.decl == NODE_NONE {
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
        if !recv_targs {
            for k in 0..targs_len {
                if !ok {
                    break;
                }
                sym.push_str("__");
                if !self.mg.type_m(b.module, b.targ_pool[(targs_start + k) as usize], &mut sym) {
                    ok = self.fail("callee-targ");
                }
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
                let g0 = snap.len() as u32;
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
                            g0,
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
                            g0,
                        );
                        gj += 1;
                    }
                }
                let gens = fd.as_data.function.generics;
                let mut gi2: u32 = 0;
                while !recv_targs && gi2 < gens.len && gi2 < targs_len {
                    self.push_bind(
                        &mut snap,
                        callee.module,
                        unsafe ca.list(gens)[gi2 as usize],
                        b.module,
                        b.targ_pool[(targs_start + gi2) as usize],
                        g0,
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
                }
            }
        }
        if ok {
            dst.push_string(&sym);
        }
        return ok;
    }

    // A fixed array flowing into a slice-typed destination wraps `{ arr, N }` (the C array decays).
    fn arr_slice_wrap(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, want: TypeId, dst: &mut String) bool {
        let opP = *b.operands.at(opid as usize);
        if opP.kind != ir::OP_COPY && opP.kind != ir::OP_MOVE {
            return false;
        }
        let alen = self.place_c_arr_len(b, opP.data);
        if alen <= 0 {
            return false;
        }
        let mut rm = b.module;
        let mut rt = want;
        self.rty(b, want, &mut rm, &mut rt);
        let yw = *self.p().module_ast_const(rm).type_at(rt);
        if yw.kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *self.p().module_ast_const(rm).instance(yw.as_data.inst);
        let dai = self.p().module_ast_const(it.module);
        let nsi = dai.at_const(dai.at_const(it.decl).as_data.aggregate.name).as_data.name.text;
        let nmi = self.p().modules.at(it.module as usize).source.as_str().slice(nsi.start as usize, nsi.end as usize);
        if nmi != "Slice" && nmi != "SliceMut" {
            return false;
        }
        let mut cs = String::new();
        if !self.mg.ctype(rm, rt, "", &mut cs) {
            return false;
        }
        dst.push_str("(");
        dst.push_string(&cs);
        dst.push_str("){ .ptr = ");
        let ok = self.emit_operand(b, opid, dst);
        dst.push_str(", .len = ");
        dst.push_i64(alen);
        dst.push_str(" }");
        return ok;
    }

    fn emit_rvalue(self: &mut Self, b: &ir::CoreBody, rid: ir::RvalueId, dst: &mut String) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE {
            if rv.target != TYPE_NONE && self.arr_slice_wrap(b, rv.a, rv.target, dst) {
                return true;
            }
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
                if !ok0 {
                    return false;
                }
            }
            dst.push_str("&");
            return self.emit_place(b, rv.a, dst);
        }
        if rv.kind == ir::RV_CAST {
            if rv.b == ir::CAST_COERCE_FROM {
                // the checker's selected conversion method, called as a plain C expression. A
                // conv with its OWN generics (widen<M>) binds them from the argument, and its
                // receiver is always the coercion TARGET.
                let cvr = b.operands.at(rv.a as usize).ty;
                let cga = self.p().module_ast_const(rv.item.module);
                let has_own = cga.at_const(rv.item.node).kind == NodeKind::NODE_FUNCTION && cga.at_const(rv.item.node).as_data.function.generics.len != 0;
                let mut ok = if has_own {
                    self.conv_sym(b, rv.item, cvr, rv.target, dst);
                } else {
                    self.callee_sym(b, rv.item, 0, 0, cvr, rv.target, dst);
                };
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
            let mut rm4 = b.module;
            let mut rt4 = TYPE_NONE;
            let aref = self.bin_op_ty(b, rv.a, &mut rm4, &mut rt4);
            let mut bm4 = b.module;
            let mut bt4 = TYPE_NONE;
            let bref = self.bin_op_ty(b, rv.b, &mut bm4, &mut bt4);
            if t == tt::TokenType::EqualEqual || t == tt::TokenType::BangEqual {
                // pattern tests compare `str` VALUES; C has no struct ==
                if self.is_str_ty(rm4, rt4) {
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    dst.push_str("__sc_str_eq(");
                    let mut ok4 = self.emit_op_d(b, rv.a, aref, dst);
                    dst.push_str(", ");
                    if ok4 {
                        ok4 = self.emit_op_d(b, rv.b, bref, dst);
                    }
                    dst.push_str(")");
                    return ok4;
                }
                if self.op_dispatch_agg(rm4, rt4) {
                    // aggregate equality dispatches through the type's `eq` (checker-approved)
                    let mut es = String::new();
                    if self.mg.method_by_name(rm4, rt4, "eq", &mut es) {
                        self.demand_impl(rm4, rt4, &es);
                    } else if !self.conf_default_sym(rm4, rt4, "eq", &mut es) {
                        return self.fail("struct-eq");
                    }
                    if t == tt::TokenType::BangEqual {
                        dst.push_str("!");
                    }
                    dst.push_string(&es);
                    dst.push_str("(");
                    if !aref {
                        dst.push_str("&");
                    }
                    let mut ok4 = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", ");
                    if !bref {
                        dst.push_str("&");
                    }
                    if ok4 {
                        ok4 = self.emit_operand(b, rv.b, dst);
                    }
                    dst.push_str(")");
                    return ok4;
                }
            }
            if t == tt::TokenType::LessThan || t == tt::TokenType::LessThanEqual || t == tt::TokenType::GreaterThan || t == tt::TokenType::GreaterThanEqual {
                if self.op_dispatch_agg(rm4, rt4) {
                    // aggregate ordering dispatches through the type's `cmp` (checker-approved)
                    let mut cs = String::new();
                    if self.mg.method_by_name(rm4, rt4, "cmp", &mut cs) {
                        self.demand_impl(rm4, rt4, &cs);
                    } else if !self.conf_default_sym(rm4, rt4, "cmp", &mut cs) {
                        return self.fail("struct-cmp");
                    }
                    dst.push_str("(");
                    dst.push_string(&cs);
                    dst.push_str("(");
                    if !aref {
                        dst.push_str("&");
                    }
                    let mut ok4 = self.emit_operand(b, rv.a, dst);
                    dst.push_str(", ");
                    if !bref {
                        dst.push_str("&");
                    }
                    if ok4 {
                        ok4 = self.emit_operand(b, rv.b, dst);
                    }
                    dst.push_str(") ");
                    dst.push_str(
                        if t == tt::TokenType::LessThan {
                            "<";
                        } else if t == tt::TokenType::LessThanEqual {
                            "<=";
                        } else if t == tt::TokenType::GreaterThan {
                            ">";
                        } else {
                            ">=";
                        },
                    );
                    dst.push_str(" 0)");
                    return ok4;
                }
            }
            {
                // arithmetic/bitwise on an AGGREGATE dispatches through the overload method the
                // checker approved (compound assigns carry no op_method record; the old emitter
                // re-derived the callee by name at emission, and so does this one)
                let mn: str<'static> = if t == tt::TokenType::Plus || t == tt::TokenType::PlusEqual {
                    "add";
                } else if t == tt::TokenType::Minus || t == tt::TokenType::MinusEqual {
                    "sub";
                } else if t == tt::TokenType::Star || t == tt::TokenType::StarEqual {
                    "mul";
                } else if t == tt::TokenType::Slash || t == tt::TokenType::SlashEqual {
                    "div";
                } else if t == tt::TokenType::Percent || t == tt::TokenType::PercentEqual {
                    "rem";
                } else if t == tt::TokenType::Ampersand || t == tt::TokenType::AmpersandEqual {
                    "bit_and";
                } else if t == tt::TokenType::Pipe || t == tt::TokenType::PipeEqual {
                    "bit_or";
                } else if t == tt::TokenType::Caret || t == tt::TokenType::CaretEqual {
                    "bit_xor";
                } else if t == tt::TokenType::LeftShift || t == tt::TokenType::LeftShiftEqual {
                    "shl";
                } else if t == tt::TokenType::RightShift || t == tt::TokenType::RightShiftEqual {
                    "shr";
                } else {
                    "";
                };
                if mn.len() != 0 {
                    if self.op_dispatch_agg(rm4, rt4) {
                        let mut ms5 = String::new();
                        if self.mg.method_by_name(rm4, rt4, mn, &mut ms5) {
                            self.demand_impl(rm4, rt4, &ms5);
                        } else if !self.conf_default_sym(rm4, rt4, mn, &mut ms5) {
                            return self.fail("struct-op");
                        }
                        dst.push_string(&ms5);
                        dst.push_str("(");
                        if !aref {
                            dst.push_str("&");
                        }
                        let mut ok5 = self.emit_operand(b, rv.a, dst);
                        dst.push_str(", ");
                        let bk5 = self.p().module_ast_const(bm4).type_at(bt4).kind;
                        let bagg5 = bk5 == TypeKind::TYPE_STRUCT || bk5 == TypeKind::TYPE_INSTANCE;
                        if bagg5 && !bref {
                            dst.push_str("&");
                        }
                        if ok5 {
                            ok5 = self.emit_op_d(b, rv.b, bref && !bagg5, dst);
                        }
                        dst.push_str(")");
                        return ok5;
                    }
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
            } else if t == tt::TokenType::PlusEqual {
                op = "+";
            } else if t == tt::TokenType::MinusEqual {
                op = "-";
            } else if t == tt::TokenType::StarEqual {
                op = "*";
            } else if t == tt::TokenType::SlashEqual {
                op = "/";
            } else if t == tt::TokenType::PercentEqual {
                op = "%";
            } else if t == tt::TokenType::AmpersandEqual {
                op = "&";
            } else if t == tt::TokenType::PipeEqual {
                op = "|";
            } else if t == tt::TokenType::CaretEqual {
                op = "^";
            } else if t == tt::TokenType::LeftShiftEqual {
                op = "<<";
            } else if t == tt::TokenType::RightShiftEqual {
                op = ">>";
            } else {
                return self.fail("binary");
            }
            dst.push_str("(");
            let mut ok = self.emit_op_d(b, rv.a, aref, dst);
            if ok {
                dst.push_str(" ");
                dst.push_str(op);
                dst.push_str(" ");
                ok = self.emit_op_d(b, rv.b, bref, dst);
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
                {
                    // an ARRAY type spells `sizeof(T[N])` (the bare ctype decays to `T *`)
                    let mut rmZ = b.module;
                    let mut rtZ = rv.b;
                    self.rty(b, rv.b, &mut rmZ, &mut rtZ);
                    let yz = *self.p().module_ast_const(rmZ).type_at(rtZ);
                    if yz.kind == TypeKind::TYPE_ARRAY {
                        let mut es = String::new();
                        let okz = self.mg.ctype(rmZ, yz.as_data.elem, "", &mut es);
                        if okz {
                            dst.push_str(if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                            dst.push_string(&es);
                            dst.push_str("[");
                            dst.push_u64(yz.as_data.arr.len);
                            dst.push_str("])");
                        }
                        return okz;
                    }
                }
                let mut ts = String::new();
                let ok = self.ty_c(b.module, rv.b, "", &mut ts);
                if ok {
                    dst.push_str(if_s(k == ir::IN_SIZEOF as u32, "sizeof(", "_Alignof("));
                    dst.push_string(&ts);
                    dst.push_str(")");
                }
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
        // an `Array<T, N>` value stores in `data` (a fixed C array), not `ptr`
        let mut is_arri = false;
        if !is_arr && by.kind == TypeKind::TYPE_INSTANCE {
            let itA = *self.p().module_ast_const(rm).instance(by.as_data.inst);
            let daA = self.p().module_ast_const(itA.module);
            let nsA = daA.at_const(daA.at_const(itA.decl).as_data.aggregate.name).as_data.name.text;
            is_arri = self.p().modules.at(itA.module as usize).source.as_str().slice(
                nsA.start as usize,
                nsA.end as usize,
            ) == "Array";
        }
        if ok {
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str("){ .ptr = ");
            dst.push_string(&bv);
            if is_arri {
                dst.push_str(".data");
            } else if !is_arr {
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
            } else if is_arri {
                dst.push_str("sizeof(");
                dst.push_string(&bv);
                dst.push_str(".data) / sizeof(");
                dst.push_string(&bv);
                dst.push_str(".data[0])");
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
            return ok;
        }
        if rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE {
            let mut cast = String::new();
            let mut ok = self.ty_c(b.module, rv.target, "", &mut cast);
            if !ok {
                return false;
            }
            dst.push_str("(");
            dst.push_string(&cast);
            dst.push_str(")");
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
            }
            self.out.push_str("); ");
            for d in 0..t.dests_len {
                if !ok {
                    break;
                }
                let mut dv = String::new();
                ok = self.emit_place(b, b.dest_pool[(t.dests_start + d) as usize], &mut dv);
                self.out.push_string(&dv);
                self.out.push_str(" = __mr._");
                self.out.push_u64(d);
                self.out.push_str("; ");
            }
            self.out.push_str("}\n  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
        }
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
        // Interface-default instances need NO stub here: the whole-package assembly prototypes
        // every emitted body (a call-site guess would conflict on const/Self shapes).
        let is_dflt = false;
        if !fd.as_data.function.is_extern {
            return;
        }
        if self.ext_backed.contains(&(t.callee.module as u64 << 32 | t.callee.node as u64)) {
            return; // the extern block's header ships the real prototype
        }
        let mut sym = String::new();
        {
            self.mg.ident(t.callee.module, ca.at_const(fd.as_data.function.name).as_data.name.text, &mut sym);
            let s0k = sym.as_str();
            let keep = s0k.len() > 3 && s0k.slice(0, 3) == "sc_";
            if !keep {
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
                                    // an unbound `Self` spells `void` (or `void *` behind a
                                    // pointer) -- either conflicts with the real definition;
                                    // the call-site type takes over instead
                                    let mut dok5 = self.mg.ctype(t.callee.module, pty5, "", &mut pr);
                                    if dok5 {
                                        let ds5 = pr.as_str().slice(mark5, pr.len());
                                        dok5 = !(ds5.len() >= 4 && ds5.slice(0, 4) == "void");
                                    }
                                    if dok5 {
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
            // the recorded type may still name generics: keep the ACTIVE env for emission
            let mut ge = GlueEnv { subs: Vector::<mbe::MSub>::new() };
            for gi in 0..self.mg.subs.len() {
                ge.subs.push(*self.mg.subs.at(gi));
            }
            self.glue_envs.push(ge);
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
                let g0 = snap.len() as u32;
                let eg = itn.as_data.extend_def.generics;
                let mut gi: u32 = 0;
                while gi < eg.len && gi as u8 < it.n {
                    self.push_bind(
                        &mut snap,
                        it.module,
                        unsafe da.list(eg)[gi as usize],
                        rm,
                        unsafe it.args[gi as usize],
                        g0,
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
                        g0,
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
                } else {}
                return;
            }
        }
    }

    // Is the resolved type destructible (needs a free call when dropped)?
    pub fn is_destructible(self: &mut Self, rm: ModuleId, rt: TypeId, depth: u32) bool {
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
    pub fn free_expr(self: &mut Self, rm: ModuleId, rt: TypeId, out: &mut String) bool {
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
        // re-establish the env the entry was recorded under (its type may name generics)
        let gn0 = self.glue_envs.at(idx).subs.len();
        for gi in 0..gn0 {
            let sb0 = *self.glue_envs.at(idx).subs.at(gi);
            self.mg.push_msub(sb0);
        }
        let ok0x = self.emit_glue_inner(idx);
        self.mg.pop_subs(gn0);
        return ok0x;
    }

    fn emit_glue_inner(self: &mut Self, idx: usize) bool {
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
                    }
                    if ok && any.len() != 0 {
                        let mut tag = String::new();
                        self.mg.enum_tag(am, decl, vid, &mut tag);
                        body.push_str("  case ");
                        body.push_string(&tag);
                        body.push_str(":\n");
                        body.push_string(&any);
                        body.push_str("    break;\n");
                    }
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
                }
            }
        }
        self.mg.pop_subs(nb);
        if ok {
            self.out.push_string(&body);
            self.out.push_str("}\n");
        }
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
                    if t.args_len == 1 {
                        // guarded: the rewrite's move flag rides args_start
                        self.out.push_str("if (_");
                        self.out.push_u64(t.args_start);
                        self.out.push_str(") { ");
                    }
                    self.out.push_string(&pv);
                    self.out.push_str(".vt->__free(");
                    self.out.push_string(&pv);
                    self.out.push_str(".data);");
                    self.out.push_str(if_s(t.args_len == 1, " }", ""));
                    self.out.push_str("\n  goto bb_");
                    self.out.push_u64(t.t0);
                    self.out.push_str(";\n");
                }
                return ok;
            }
            if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
                // an explicit `.free()` THROUGH a pointer (Box's payload drop): the pointee frees
                // by the pointer VALUE; scheduled drops never produce pointer places (borrows)
                let mut em9 = rm;
                let mut et9 = y.as_data.elem;
                if self.mg.resolve(rm, y.as_data.elem, &mut em9, &mut et9) && self.is_destructible(em9, et9, 0) {
                    let mut fs9 = String::new();
                    if !self.free_expr(em9, et9, &mut fs9) {
                        return self.fail("drop-ptr");
                    }
                    let mut pv9 = String::new();
                    let ok9 = self.emit_place(b, t.a, &mut pv9);
                    if ok9 {
                        self.out.push_str("  ");
                        if t.args_len == 1 {
                            self.out.push_str("if (_");
                            self.out.push_u64(t.args_start);
                            self.out.push_str(") { ");
                        }
                        self.out.push_string(&fs9);
                        self.out.push_str("(");
                        self.out.push_string(&pv9);
                        self.out.push_str(");");
                        self.out.push_str(if_s(t.args_len == 1, " }", ""));
                        self.out.push_str("\n  goto bb_");
                        self.out.push_u64(t.t0);
                        self.out.push_str(";\n");
                    }
                    return ok9;
                }
            }
            if y.kind == TypeKind::TYPE_FUNCTION {
                // a closure value's captures are freed by ITS OWN body on the (exactly-once) call
                // -- a drop of the value itself owns nothing further
                self.out.push_str("  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
                return true;
            }
            if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                let mut fs = String::new();
                if !self.mg.free_target(rm, rt, &mut fs) {
                    return self.fail("drop");
                }
                if self.collect_demand {
                    self.note_free(rm, rt, fs.as_str());
                }
                let mut pv = String::new();
                let ok = self.emit_place(b, t.a, &mut pv);
                if ok {
                    self.out.push_str("  ");
                    if t.args_len == 1 {
                        self.out.push_str("if (_");
                        self.out.push_u64(t.args_start);
                        self.out.push_str(") { ");
                    }
                    self.out.push_string(&fs);
                    self.out.push_str("(&");
                    self.out.push_string(&pv);
                    self.out.push_str(");");
                    self.out.push_str(if_s(t.args_len == 1, " }", ""));
                    self.out.push_str("\n  goto bb_");
                    self.out.push_u64(t.t0);
                    self.out.push_str(";\n");
                }
                return ok;
            }
            self.out.push_str("  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
        }
        if t.kind == ir::TM_RETURN {
            if b.returns == 1 && self.arr_ret {
                self.out.push_str("  { ");
                self.out.push_string(&self.cur_name);
                self.out.push_str("_ret __ar; memcpy(__ar._a, _0, sizeof(__ar._a)); return __ar; }\n");
            } else if b.returns == 1 {
                // a declared `void` return counts as one UNIT slot: no value to spell
                if self.is_unit(b, b.locals.at(0).ty) {
                    self.out.push_str("  return;\n");
                } else {
                    self.out.push_str("  return _0;\n");
                }
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
            } else if self.noret {
                self.out.push_str("  abort();\n"); // a noreturn fn's fall-off edge must not return
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
            let mut ok = self.emit_operand(b, t.a, &mut cond);
            if !ok {
                return false;
            }
            let src = self.p().modules.at(b.module as usize).source.as_str();
            let file = self.p().modules.at(b.module as usize).file.as_str();
            let mut line: u64 = 1;
            {
                let mut i9 = 0 as usize;
                while i9 < t.span.start as usize && i9 < src.len() {
                    if src.byte_at(i9) == 10 {
                        line += 1;
                    }
                    i9 += 1;
                }
            }
            self.out.push_str("  if (!(");
            self.out.push_string(&cond);
            self.out.push_str(")) { ");
            if t.args_len == 4 {
                // assert_eq/ne: expression spellings ride as CK_STR constants [2] and [3]
                let lsp = *b.constants.at(
                    b.operands.at(b.oper_pool[(t.args_start + 2) as usize] as usize).data as usize,
                );
                let rsp = *b.constants.at(
                    b.operands.at(b.oper_pool[(t.args_start + 3) as usize] as usize).data as usize,
                );
                self.out.push_str("fprintf(stderr, \"assertion failed: `");
                push_fmt_escaped(src.slice(lsp.raw.start as usize, lsp.raw.end as usize), &mut self.out);
                if t.sw_len == 2 {
                    self.out.push_str(" == ");
                } else {
                    self.out.push_str(" != ");
                }
                push_fmt_escaped(src.slice(rsp.raw.start as usize, rsp.raw.end as usize), &mut self.out);
                self.out.push_str("`\\n\"); ");
                ok = self.assert_value_line(b, "left: ", b.oper_pool[t.args_start as usize]) && self.assert_value_line(
                    b,
                    "right:",
                    b.oper_pool[(t.args_start + 1) as usize],
                );
                if !ok {
                    return false;
                }
            } else if t.args_len == 1 {
                let mut mv = String::new();
                if !self.emit_operand(b, b.oper_pool[t.args_start as usize], &mut mv) {
                    return false;
                }
                self.out.push_str("const str __scm = ");
                self.out.push_string(&mv);
                self.out.push_str("; fprintf(stderr, \"assertion failed: `");
                push_fmt_escaped(src.slice(t.span.start as usize, t.span.end as usize), &mut self.out);
                self.out.push_str("`: %.*s\\n\", (int)__scm.len, (const char *)__scm.ptr); ");
            } else {
                self.out.push_str("fprintf(stderr, \"assertion failed: `");
                push_fmt_escaped(src.slice(t.span.start as usize, t.span.end as usize), &mut self.out);
                self.out.push_str("`\\n\"); ");
            }
            self.out.push_str("fprintf(stderr, \"  at ");
            push_fmt_escaped(file, &mut self.out);
            self.out.push_str(":");
            self.out.push_u64(line);
            self.out.push_str("\\n\"); fflush(stderr); abort(); }\n  goto bb_");
            self.out.push_u64(t.t0);
            self.out.push_str(";\n");
            return true;
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
            let mut arrdst = false; // fixed-array dest: `{ <sym>_ret __ar = f(..); memcpy(dst, __ar._a, ..); }`
            let mut dplace = String::new();
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
                if want && dty != TYPE_NONE && t.callee.node != NODE_NONE && dyn_recv == ir::IR_NONE {
                    let mut am8 = b.module;
                    let mut at8 = dty;
                    self.rty(b, dty, &mut am8, &mut at8);
                    let y8 = *self.p().module_ast_const(am8).type_at(at8);
                    arrdst = y8.kind == TypeKind::TYPE_ARRAY && y8.as_data.arr.len != 0;
                }
                if want && arrdst {
                    ok = self.emit_place(b, dp, &mut dplace);
                } else if want {
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
            let cs_len = line.len();
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
                }
            }
            if ok && arrdst {
                self.out.push_str("  { ");
                self.out.push_str(line.as_str().slice(0, cs_len));
                self.out.push_str("_ret __ar = ");
                self.out.push_string(&line);
                self.out.push_str("); memcpy(");
                self.out.push_string(&dplace);
                self.out.push_str(", __ar._a, sizeof(__ar._a)); }\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            } else if ok {
                self.out.push_str("  ");
                self.out.push_string(&line);
                self.out.push_str(");\n  goto bb_");
                self.out.push_u64(t.t0);
                self.out.push_str(";\n");
            }
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
// Escape source text into an fprintf FORMAT string: C-escape quotes/backslashes/controls and
// double `%` so spelled operators never read as conversions.
pub fn push_fmt_escaped(txt: str, dst: &mut String) {
    for i in 0..txt.len() {
        let b = txt.byte_at(i);
        if b == 37 {
            dst.push_str("%%");
        } else if b == 34 {
            dst.push_str("\\\"");
        } else if b == 92 {
            dst.push_str("\\\\");
        } else if b == 10 {
            dst.push_str("\\n");
        } else if b < 32 {
            dst.push_str(" ");
        } else {
            dst.push_byte(b);
        }
    }
}

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
