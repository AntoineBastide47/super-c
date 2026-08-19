// The streaming C backend's function emitter: one verified Core body at a time into one reusable
// buffer, strict C11 portable output -- explicit temporaries, no GNU statement expressions, no
// `__auto_type`. Locals spell as their stable `LocalId` (`_N`). Control flow is reconstructed by
// `emit::cflow` into structured `if`/`switch`/`while` (the goto layout with `BlockId` labels
// `bb_N` is the fallback for CFGs that do not structure cleanly); either way emission is a pure
// function of the Core body, so two serial runs are byte-identical by construction. Types and
// symbols come from the frozen mangler (emit::mangle); the emitter consumes ONLY Core IR and pool
// reads for spelling: it never resolves overloads, searches extends at emission time, infers,
// interns, or evaluates syntax. Bodies outside the emittable subset refuse with a reason.
import ast::ast as *;
import emit::mangle as mbe;
import emit::cflow as cfl;
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
    /// Reusable per-function scratch for structured emission: blocks already spelled, and blocks a
    /// forward goto targets (their label prints when the block is reached). Cleared per body.
    sx_emitted: Vector<bool>,
    sx_lbl: Vector<bool>,
    /// Set by emit_region when it returned by reaching its follow (control can continue past the
    /// region), cleared when it returned by a terminator/transfer. A switch case reads it to decide
    /// whether a trailing `break;` is reachable.
    sx_fell: bool,
    /// Set during the label-planning pass when the structure would need a `goto` (a cross edge or a
    /// secondary merge the region tree cannot place). Its presence makes the whole body fall back to
    /// the goto layout, so structured output never emits an unplaceable jump.
    sx_goto: bool,
    /// Per-body local spelling, rebuilt by setup_locals. `sx_coal[l]` is the local `l` coalesces
    /// into (itself when it does not): a transparent `_dst = move _src` where the source is used
    /// nowhere else shares one C variable. `sx_name[l]` is the C identifier for local `l` -- the
    /// preserved user name (keyword/collision-disambiguated) or `_N` for temps and return slots.
    sx_coal: Vector<u32>,
    sx_name: Vector<String>,
    /// `sx_used[l]` is false when local `l` is referenced nowhere in the body; its declaration is
    /// then dropped (a dead temporary the plan requires we not emit).
    sx_used: Vector<bool>,
    /// `sx_inline[l]` is the rvalue that defines a single-use pure temporary whose sole read is
    /// adjacent to its definition (nothing runs between them): the definition statement is skipped
    /// and the rvalue is spelled directly at the read, so `_t = a + b; x = _t;` reads `x = a + b;`.
    /// IR_NONE when local `l` is not inlined. Set by setup_locals; consumed by emit_operand.
    sx_inline: Vector<u32>,
    /// `sx_fuse[l]` is true when local `l` declares at its initializing write instead of up front:
    /// its first write is a plain whole-local store that dominates every access, so `int32_t t; t = 0;`
    /// becomes `int32_t t = 0;`. Set per body from the CFG; `sx_declared[l]` records that the fused
    /// declaration has been emitted (later writes to `l` then spell a plain assignment).
    sx_fuse: Vector<bool>,
    sx_declared: Vector<bool>,
    /// A single-return call whose result is used exactly once, in the continuation block with nothing
    /// effectful before the use, forwards into that use: `_r = f(..); return _r;` reads `return f(..);`.
    /// `sx_call_fwd[l]` marks such a destination; the call terminator writes its `f(..)` spelling into
    /// `sx_call_str[l]` (emitting nothing itself), which the single read then spells in place.
    sx_call_fwd: Vector<bool>,
    sx_call_str: Vector<String>,
    assert_helpers: u8,
    /// One induction update moved into the active C `for` clause.
    sx_skip_place: u32,
    sx_skip_rvalue: u32,
    // Newline offsets of every module source (CSR: per-module ranges into one pool), built on the
    // first assert line lookup: line numbers must not rescan the source per assert site.
    line_pool: Vector<u32>,
    line_off: Vector<u64>,
    // Plain concrete-call symbols per (fm, fnode), valid for one mark_ctx (cleared on change so
    // cross-TU used_mods edges still record once per spelling TU). Every body re-spells the same
    // callees; the mangle walk must not repeat per call site.
    sym_memo: Map<u64, String>,
    sym_memo_ctx: i64,
    // Reusable spelling buffers: the statement/place emitters build every C fragment in a
    // temporary String, so the pool keeps their capacity across the whole emission.
    scratch: Vector<String>,
    // Reusable per-function CFG analyses (a CFlow rebuilds in place without allocating).
    cf_pool: Vector<cfl::CFlow>,
    // setup_locals' reserved/assigned identifier sets, cleared per body (capacity retained).
    sx_reserved: Map<u64, u64>,
    sx_assigned: Map<u64, u64>,
    // Fingerprints of demands already queued: many call sites raise the identical
    // (sym, chain, sfx) demand, and a duplicate can never emit anything the first did not.
    demand_seen: Set<u64>,
    // Per (module, TypeId): the reserved-set ident hashes of the type's C spelling plus the
    // modules the spelling records used_mods edges for (CSR pools; empty-env spellings only).
    // setup_locals spells every local's type per body -- this makes revisits two pool scans.
    ti_memo2: Map<u64, u64>,
    tid_start: Vector<u32>,
    tmod_start: Vector<u32>,
    tid_pool: Vector<u64>,
    tmod_pool: Vector<ModuleId>,
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
        self.sx_emitted.free();
        self.sx_lbl.free();
        self.sx_coal.free();
        self.sx_name.free();
        self.sx_used.free();
        self.sx_inline.free();
        self.sx_fuse.free();
        self.sx_declared.free();
        self.sx_call_fwd.free();
        self.sx_call_str.free();
        self.line_pool.free();
        self.line_off.free();
        self.sym_memo.free();
        self.scratch.free();
        self.cf_pool.free();
        self.sx_reserved.free();
        self.sx_assigned.free();
        self.demand_seen.free();
        self.ti_memo2.free();
        self.tid_start.free();
        self.tmod_start.free();
        self.tid_pool.free();
        self.tmod_pool.free();
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
            sx_emitted: Vector::<bool>::new(),
            sx_lbl: Vector::<bool>::new(),
            sx_fell: false,
            sx_goto: false,
            sx_coal: Vector::<u32>::new(),
            sx_name: Vector::<String>::new(),
            sx_used: Vector::<bool>::new(),
            sx_inline: Vector::<u32>::new(),
            sx_call_fwd: Vector::<bool>::new(),
            sx_call_str: Vector::<String>::new(),
            assert_helpers: 0,
            sx_fuse: Vector::<bool>::new(),
            sx_declared: Vector::<bool>::new(),
            sx_skip_place: ir::IR_NONE,
            sx_skip_rvalue: ir::IR_NONE,
            line_pool: Vector::<u32>::new(),
            line_off: Vector::<u64>::new(),
            sym_memo: Map::<u64, String>::new(),
            sym_memo_ctx: -2,
            scratch: Vector::<String>::new(),
            cf_pool: Vector::<cfl::CFlow>::new(),
            sx_reserved: Map::<u64, u64>::new(),
            sx_assigned: Map::<u64, u64>::new(),
            demand_seen: Set::<u64>::new(),
            ti_memo2: Map::<u64, u64>::new(),
            tid_start: Vector::<u32>::new(),
            tmod_start: Vector::<u32>::new(),
            tid_pool: Vector::<u64>::new(),
            tmod_pool: Vector::<ModuleId>::new(),
        };
    }

    fn cfget(self: &mut Self) cfl::CFlow {
        let c9 = switch self.cf_pool.pop() {
            Some(c) => c,
            None => cfl::CFlow::new_empty(),
        };
        return c9;
    }

    fn cfput(self: &mut Self, cf: cfl::CFlow) {
        self.cf_pool.push(cf);
    }

    fn sget(self: &mut Self) String {
        let s9 = switch self.scratch.pop() {
            Some(s) => s,
            None => String::new(),
        };
        return s9;
    }

    fn sput(self: &mut Self, s: String) {
        let mut s9 = s;
        s9.clear();
        self.scratch.push(s9);
    }

    // Feed local type `(m, t)`'s C-spelling identifiers into the reserved set, through the
    // per-type cache when the substitution env is empty (edges replay via the logged modules).
    fn reserve_local_ty(self: &mut Self, m: ModuleId, t: TypeId) {
        if self.mg.subs.len() != 0 {
            let mut cs = self.sget();
            if self.mg.ctype(m, t, "", &mut cs) {
                collect_idents(cs.as_str(), &mut self.sx_reserved);
            }
            self.sput(cs);
            return;
        }
        if self.tid_start.len() == 0 {
            self.tid_start.push(0);
            self.tmod_start.push(0);
        }
        let key = skey_mix(0, m as u64 << 32 | t as u64);
        let hit = switch self.ti_memo2.get(&key) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if hit >= 0 {
            let ei = hit as usize;
            for k in *self.tid_start.at(ei)..*self.tid_start.at(ei + 1) {
                self.sx_reserved.insert(*self.tid_pool.at(k as usize), 1);
            }
            for k in *self.tmod_start.at(ei)..*self.tmod_start.at(ei + 1) {
                self.mg.mark_used(*self.tmod_pool.at(k as usize));
            }
            return;
        }
        let ei = self.tid_start.len() - 1;
        self.mg.edge_log.truncate(0);
        self.mg.edge_log_on = true;
        let mut cs = self.sget();
        let okc = self.mg.ctype(m, t, "", &mut cs);
        self.mg.edge_log_on = false;
        if okc {
            let h0 = self.tid_pool.len();
            collect_ident_hashes(cs.as_str(), &mut self.tid_pool);
            for k in h0..self.tid_pool.len() {
                self.sx_reserved.insert(*self.tid_pool.at(k), 1);
            }
        }
        self.sput(cs);
        for k in 0..self.mg.edge_log.len() {
            self.tmod_pool.push(*self.mg.edge_log.at(k));
        }
        self.tid_start.push(self.tid_pool.len() as u32);
        self.tmod_start.push(self.tmod_pool.len() as u32);
        self.ti_memo2.insert(key, ei as u64);
    }

    // 1-based line of byte offset `pos` in module `m`'s source (newlines strictly before `pos`).
    fn src_line(self: &mut Self, m: ModuleId, pos: u64) u64 {
        if self.line_off.len() == 0 {
            for mi in 0..self.p().modules.len() {
                self.line_off.push(self.line_pool.len() as u64);
                let src = self.p().modules.at(mi).source.as_str();
                for k in 0..src.len() {
                    if src.byte_at(k) == 10 {
                        self.line_pool.push(k as u32);
                    }
                }
            }
            self.line_off.push(self.line_pool.len() as u64);
        }
        let s = self.line_off[m as usize] as usize;
        let mut lo = s;
        let mut hi = self.line_off[m as usize + 1] as usize;
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.line_pool[mid] as u64 < pos {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return 1 + (lo - s) as u64;
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
        if pj.kind != ir::PJ_FIELD {
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
        // named field: sub is the NODE_FIELD; tuple member: sub is NODE_NONE and data is the index
        let ftn = if pj.sub != NODE_NONE {
            if da.at_const(pj.sub).kind != NodeKind::NODE_FIELD {
                return 0 - 1;
            }
            da.at_const(pj.sub).as_data.field.ty;
        } else {
            let decl = self.agg_decl_res(rm, rt);
            if decl == NODE_NONE {
                return 0 - 1;
            }
            let ms = da.at_const(decl).as_data.aggregate.members;
            if pj.data >= ms.len {
                return 0 - 1;
            }
            unsafe da.list(ms)[pj.data as usize];
        };
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
        self.cap_on = false; // a plain function has no captured locals
        self.setup_locals(b);
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
            let mut nm = String::new();
            self.lspell(l as u32, &mut nm);
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
            let mut nm2 = String::new();
            self.lspell(l, &mut nm2);
            let mut ts2 = String::new();
            if !self.ty_c(b.module, b.locals.at(l as usize).ty, nm2.as_str(), &mut ts2) {
                return false;
            }
            self.out.push_str("  ");
            self.out.push_string(&ts2);
            self.out.push_str(";\n  memcpy(&");
            self.out.push_string(&nm2);
            self.out.push_str(", ");
            self.out.push_string(&nm2);
            self.out.push_str("_p, sizeof(");
            self.out.push_string(&nm2);
            self.out.push_str("));\n");
        }
        return self.emit_body_core(b);
    }

    // A name that would collide with the `_N` temp spelling: `_` followed by only digits.
    const fn templike(s: str) bool {
        if s.len() < 2 || s.byte_at(0) != 95 {
            return false;
        }
        for i in 1..s.len() {
            let c = s.byte_at(i);
            if c < 48 || c > 57 {
                return false;
            }
        }
        return true;
    }

    // Count one reference to place `pid`'s base into refs (and a definition into defs when it is a
    // whole-local assignment target).
    fn count_place(
        self: &Self,
        b: &ir::CoreBody,
        pid: ir::PlaceId,
        is_def: bool,
        refs: &mut Vector<u32>,
        defs: &mut Vector<u32>,
    ) {
        let pl = *b.places.at(pid as usize);
        refs.set(pl.base as usize, *refs.at(pl.base as usize) + 1);
        if is_def && pl.proj_len == 0 {
            defs.set(pl.base as usize, *defs.at(pl.base as usize) + 1);
        }
    }

    // A rvalue with no side effect: its store can be dropped when the destination is never read.
    const fn pure_rvalue(k: u8) bool {
        return k == ir::RV_USE || k == ir::RV_UNARY || k == ir::RV_BINARY || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT || k == ir::RV_REPEAT || k == ir::RV_AGGREGATE;
    }

    // One pass over the body for every per-local counter: reference/definition counts (never
    // under-counting a use, so a coalesce guarded by `refs[src] == 1` is safe), use counts, read
    // counts (a taken address counts; over-counting only keeps more locals live), and the
    // hard-write flag (a whole-local write whose value must land: a call destination or a
    // side-effecting rvalue). A local with no reads and no hard write is dead.
    fn count_all(
        self: &Self,
        b: &ir::CoreBody,
        refs: &mut Vector<u32>,
        defs: &mut Vector<u32>,
        uses: &mut Vector<u32>,
        reads: &mut Vector<u32>,
        hardw: &mut Vector<bool>,
    ) {
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                self.count_place(b, op.data, false, refs, defs);
                let base = b.places.at(op.data as usize).base as usize;
                uses.set(base, *uses.at(base) + 1);
                reads.set(base, *reads.at(base) + 1);
            }
        }
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind == ir::ST_ASSIGN {
                self.count_place(b, s.place, true, refs, defs);
                let pl = *b.places.at(s.place as usize);
                let rv = *b.rvalues.at(s.rvalue as usize);
                if pl.proj_len != 0 {
                    reads.set(pl.base as usize, *reads.at(pl.base as usize) + 1);
                } else if !CEmit::pure_rvalue(rv.kind) {
                    hardw.set(pl.base as usize, true);
                }
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                    self.count_place(b, rv.a, false, refs, defs);
                    let rb = b.places.at(rv.a as usize).base as usize;
                    reads.set(rb, *reads.at(rb) + 1);
                }
            } else if s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
                self.count_place(b, s.place, false, refs, defs);
                reads.set(
                    b.places.at(s.place as usize).base as usize,
                    *reads.at(b.places.at(s.place as usize).base as usize) + 1,
                );
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_DROP {
                self.count_place(b, t.a, false, refs, defs);
                reads.set(
                    b.places.at(t.a as usize).base as usize,
                    *reads.at(b.places.at(t.a as usize).base as usize) + 1,
                );
                if t.args_len == 1 {
                    // a guarded drop reads its move flag (a local carried on args_start, not a place)
                    reads.set(t.args_start as usize, *reads.at(t.args_start as usize) + 1);
                }
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    self.count_place(b, b.dest_pool[(t.dests_start + d) as usize], true, refs, defs);
                    let pl = *b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize);
                    if pl.proj_len != 0 {
                        reads.set(pl.base as usize, *reads.at(pl.base as usize) + 1);
                    } else {
                        hardw.set(pl.base as usize, true);
                    }
                }
            }
        }
    }

    // Reserve the source name of item `node` (a referenced function/const/type/variant): a local
    // reusing it would hide the global.
    fn reserve_item(self: &mut Self, m: ModuleId, node: NodeId) {
        if node == NODE_NONE {
            return;
        }
        let a = self.p().module_ast_const(m);
        let nd = a.at_const(node);
        let mut nn = NODE_NONE;
        if nd.kind == NodeKind::NODE_FUNCTION {
            nn = nd.as_data.function.name;
        } else if nd.kind == NodeKind::NODE_CONST {
            nn = nd.as_data.const_def.name;
        } else if nd.kind == NodeKind::NODE_STRUCT || nd.kind == NodeKind::NODE_ENUM {
            nn = nd.as_data.aggregate.name;
        } else if nd.kind == NodeKind::NODE_VARIANT {
            nn = nd.as_data.variant.name;
        }
        if nn == NODE_NONE {
            return;
        }
        let sp = a.at_const(nn).as_data.name.text;
        let mut s = self.sget();
        self.mg.ident(m, sp, &mut s);
        self.sx_reserved.insert(ident_hash(s.as_str()), 1);
        self.sput(s);
    }

    fn same_local_type(self: &Self, b: &ir::CoreBody, a: TypeId, c: TypeId) bool {
        let mut am = b.module;
        let mut at = a;
        self.rty(b, a, &mut am, &mut at);
        let mut cm = b.module;
        let mut ct = c;
        self.rty(b, c, &mut cm, &mut ct);
        if am == cm && at == ct {
            return true;
        }
        let ay = *self.p().module_ast_const(am).type_at(at);
        let cy = *self.p().module_ast_const(cm).type_at(ct);
        if ay.kind != TypeKind::TYPE_ARRAY || cy.kind != TypeKind::TYPE_ARRAY || ay.as_data.arr.len != cy.as_data.arr.len {
            return false;
        }
        let mut aem = am;
        let mut aet = ay.as_data.elem;
        let _ = self.mg.resolve(am, ay.as_data.elem, &mut aem, &mut aet);
        let mut cem = cm;
        let mut cet = cy.as_data.elem;
        let _ = self.mg.resolve(cm, cy.as_data.elem, &mut cem, &mut cet);
        return aem == cem && aet == cet;
    }

    fn coal_type_compatible(self: &Self, b: &ir::CoreBody, dst: TypeId, src: TypeId, slocal: u32) bool {
        if self.same_local_type(b, dst, src) {
            return true;
        }
        let mut dm = b.module;
        let mut dt = dst;
        self.rty(b, dst, &mut dm, &mut dt);
        let mut sm = b.module;
        let mut st = src;
        self.rty(b, src, &mut sm, &mut st);
        let dy = *self.p().module_ast_const(dm).type_at(dt);
        let sy = *self.p().module_ast_const(sm).type_at(st);
        if dy.kind != TypeKind::TYPE_ARRAY || sy.kind != TypeKind::TYPE_ARRAY || dy.as_data.arr.len == 0 || self.filled_len(
            b,
            slocal,
        ) > dy.as_data.arr.len as u64 {
            return false;
        }
        let mut dem = dm;
        let mut det = dy.as_data.elem;
        let _ = self.mg.resolve(dm, dy.as_data.elem, &mut dem, &mut det);
        let mut sem = sm;
        let mut set = sy.as_data.elem;
        let _ = self.mg.resolve(sm, sy.as_data.elem, &mut sem, &mut set);
        return dem == sem && det == set;
    }

    // The source is defined immediately before this copy, apart from storage markers.
    fn adjacent_copy_source(self: &Self, b: &ir::CoreBody, copy: usize, source: u32) bool {
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            let start = blk.stmt_start as usize;
            let end = start + blk.stmt_len as usize;
            if copy < start || copy >= end {
                continue;
            }
            let mut i = copy;
            while i > start {
                i -= 1;
                let s = *b.statements.at(i);
                if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
                    continue;
                }
                if s.kind != ir::ST_ASSIGN {
                    return false;
                }
                let pl = *b.places.at(s.place as usize);
                return pl.base == source && pl.proj_len == 0;
            }
            return false;
        }
        return false;
    }

    // Rebuild the per-body local spelling: transparent-move coalescing, then preserved user names.
    // `_dst = move _src` where the source is used nowhere else and the destination is defined only
    // there shares one C variable (`_dst` never declares, its assignment never emits). Named user
    // parameters and locals keep their source spelling, C keywords and collisions disambiguated;
    // temporaries and return slots stay `_N`.
    fn setup_locals(self: &mut Self, b: &ir::CoreBody) {
        let n = b.locals.len();
        self.sx_coal.clear();
        self.sx_name.clear(); // frees each String, keeps the Vector's capacity across functions
        for l in 0..n {
            self.sx_coal.push(l as u32);
        }
        let mut refs = Vector::<u32>::new();
        let mut defs = Vector::<u32>::new();
        let mut uses = Vector::<u32>::new();
        let mut coal_root = Vector::<bool>::new();
        let mut reads = Vector::<u32>::new();
        let mut hardw = Vector::<bool>::new();
        refs.reserve(n);
        defs.reserve(n);
        uses.reserve(n);
        coal_root.reserve(n);
        reads.reserve(n);
        hardw.reserve(n);
        for _l in 0..n {
            refs.push(0);
            defs.push(0);
            uses.push(0);
            coal_root.push(false);
            reads.push(0);
            hardw.push(false);
        }
        self.count_all(b, &mut refs, &mut defs, &mut uses, &mut reads, &mut hardw);
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.proj_len != 0 || pl.base as usize < b.returns as usize {
                continue;
            }
            let dstore = b.locals.at(pl.base as usize).storage;
            if dstore != ir::LS_USER && dstore != ir::LS_TEMP {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind != ir::RV_USE {
                continue;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind != ir::OP_MOVE && op.kind != ir::OP_COPY {
                continue;
            }
            let sp = *b.places.at(op.data as usize);
            if sp.proj_len != 0 || sp.base == pl.base {
                continue;
            }
            let ss = b.locals.at(sp.base as usize).storage;
            let tempish = sp.base as usize >= b.returns as usize && ss != ir::LS_ARG && ss != ir::LS_STATIC_REF && b.locals.at(
                sp.base as usize,
            ).decl == NODE_NONE;
            let user_source = ss == ir::LS_USER && b.locals.at(sp.base as usize).decl != NODE_NONE && !b.locals.at(
                sp.base as usize,
            ).is_mutable && dstore == ir::LS_TEMP;
            let binding_source = ss == ir::LS_USER && dstore == ir::LS_USER && b.locals.at(pl.base as usize).is_mutable && self.adjacent_copy_source(
                b,
                si,
                sp.base,
            );
            let ddecl = b.locals.at(pl.base as usize).decl;
            let inline_pattern_dest = dstore == ir::LS_USER && ddecl != NODE_NONE && self.p().module_ast_const(b.module).at_const(
                ddecl,
            ).kind == NodeKind::NODE_PATTERN_NAME && *defs.at(pl.base as usize) == 1 && *uses.at(pl.base as usize) == 1;
            // A closure capture is an argument too, but it spells `__env->name`, not a plain local;
            // aliasing a local onto it would lose that env indirection.
            if self.cap_on && ss == ir::LS_ARG && sp.base >= self.cap_base {
                continue;
            }
            if !binding_source && *defs.at(pl.base as usize) != 1 {
                continue;
            }
            if ss == ir::LS_ARG && *refs.at(sp.base as usize) != 1 {
                continue;
            }
            // A temporary is counted once at its definition and once at this sole read.
            if tempish && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1) {
                continue;
            }
            if user_source && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1) {
                continue;
            }
            if binding_source && (*defs.at(sp.base as usize) != 1 || *uses.at(sp.base as usize) != 1 || *refs.at(
                sp.base as usize,
            ) != 2) {
                continue;
            }
            if ss != ir::LS_ARG && !tempish && !user_source && !binding_source {
                continue;
            }
            let dty = b.locals.at(pl.base as usize).ty;
            let sty = b.locals.at(sp.base as usize).ty;
            let mut types_ok = dty != TYPE_NONE && (sty == TYPE_NONE || self.coal_type_compatible(b, dty, sty, sp.base));
            if dty == TYPE_NONE && sty == TYPE_NONE {
                let mut ds = String::new();
                let mut ssym = String::new();
                types_ok = self.untyped_ret_struct(b, pl.base, &mut ds) && self.untyped_ret_struct(
                    b,
                    sp.base,
                    &mut ssym,
                ) && ds.as_str() == ssym.as_str();
            }
            if !types_ok {
                continue;
            }
            if dty != TYPE_NONE && self.is_unit(b, dty) {
                continue;
            }
            if binding_source {
                self.sx_coal.set(sp.base as usize, pl.base);
                coal_root.set(pl.base as usize, true);
            } else if ss == ir::LS_ARG {
                self.sx_coal.set(pl.base as usize, sp.base);
            } else if user_source {
                self.sx_coal.set(pl.base as usize, sp.base);
                coal_root.set(sp.base as usize, true);
            } else if tempish && !inline_pattern_dest && *refs.at(pl.base as usize) > *defs.at(pl.base as usize) {
                self.sx_coal.set(sp.base as usize, pl.base);
                coal_root.set(pl.base as usize, true);
            }
        }
        for l in 0..n {
            let mut r = l as u32;
            let mut g: usize = 0;
            while *self.sx_coal.at(r as usize) != r && g <= n {
                r = *self.sx_coal.at(r as usize);
                g += 1;
            }
            self.sx_coal.set(l, r);
        }
        // Every C ordinary-namespace identifier the body references is reserved: a local that reused
        // one would hide it and silently change what a later use means. Collected: the typedef names
        // of every local type, every enum-variant constant the body constructs, and the source names
        // of every function/const/static/type item it names. Over-approximation is safe (it only
        // suffixes more names); the set is a hash set, so collection and lookup are near-linear.
        self.sx_reserved.clear();
        for l in 0..n {
            let ty = b.locals.at(l).ty;
            if ty != TYPE_NONE {
                self.reserve_local_ty(b.module, ty);
            }
            if b.locals.at(l).storage == ir::LS_STATIC_REF {
                let it = b.locals.at(l).item;
                self.reserve_item(it.module, it.node);
            }
        }
        for ri in 0..b.rvalues.len() {
            let rv = *b.rvalues.at(ri);
            if rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_VARIANT {
                let edecl = self.agg_decl(b, rv.target);
                if edecl != NODE_NONE {
                    let am = self.agg_module(b, rv.target);
                    let mut tag = self.sget();
                    self.mg.enum_tag(am, edecl, rv.item.node, &mut tag);
                    self.sx_reserved.insert(ident_hash(tag.as_str()), 1);
                    self.sput(tag);
                }
            }
        }
        for ci in 0..b.constants.len() {
            let c = *b.constants.at(ci);
            if c.kind == ir::CK_ITEM {
                self.reserve_item(c.item.module, c.item.node);
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_CALL && t.callee.node != NODE_NONE {
                // Reserve the EXACT emitted call symbol -- the mangled name a generic/method/interface
                // /cross-module call spells (e.g. `id__i32`), which a source name alone misses.
                let mut rty2 = TYPE_NONE;
                if t.args_len > 0 {
                    rty2 = b.operands.at(b.oper_pool[t.args_start as usize] as usize).ty;
                }
                let mut dty2 = TYPE_NONE;
                if t.dests_len == 1 {
                    dty2 = b.places.at(b.dest_pool[t.dests_start as usize] as usize).ty;
                }
                let mut sym = self.sget();
                let saved = self.collect_demand;
                self.collect_demand = false;
                let ok = self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty2, dty2, &mut sym);
                self.collect_demand = saved;
                if ok {
                    self.sx_reserved.insert(ident_hash(sym.as_str()), 1);
                }
                self.sput(sym);
            }
        }
        // Names: preserve user identifiers, disambiguating keywords, type names, and collisions; the
        // `_<id>` fallback is always free because only local `id` itself ever spells `_<id>`. Already-
        // assigned names live in a hash set, so the whole pass is near-linear.
        self.sx_assigned.clear();
        for l in 0..n {
            let mut nm = String::new();
            if *self.sx_coal.at(l) == l as u32 && l >= b.returns as usize {
                let st = b.locals.at(l).storage;
                if st != ir::LS_TEMP && st != ir::LS_STATIC_REF {
                    let decl = b.locals.at(l).decl;
                    if decl != NODE_NONE {
                        let sp = self.mg.decl_name_span(b.module, decl);
                        if sp.end > sp.start {
                            self.mg.ident(b.module, sp, &mut nm);
                            if CEmit::templike(nm.as_str()) || ident_in(nm.as_str(), &self.sx_reserved) || self.sx_assigned.contains_key(
                                &ident_hash(nm.as_str()),
                            ) {
                                nm.push_str("_");
                                nm.push_u64(l as u64);
                                // the suffixed name must clear BOTH sets: `<name>_<id>` can itself be
                                // a reserved symbol or an earlier local's name
                                if ident_in(nm.as_str(), &self.sx_reserved) || self.sx_assigned.contains_key(
                                    &ident_hash(nm.as_str()),
                                ) {
                                    nm.truncate(0);
                                }
                            }
                            if nm.len() != 0 {
                                self.sx_assigned.insert(ident_hash(nm.as_str()), 1);
                            }
                        }
                    }
                }
            }
            self.sx_name.push(nm);
        }

        // Liveness for declaration + dead-store removal: a local needs a declaration when it is read
        // (a taken address counts) or written by something that must land in it (a call result or a
        // side-effecting rvalue). Neither -> dead: no declaration, and its pure stores are dropped.
        self.sx_used.clear();
        for l in 0..n {
            self.sx_used.push(*reads.at(l) != 0 || *hardw.at(l));
        }

        self.compute_inline(b, &coal_root);
    }

    // The C spelling of local `l` for the body most recently emitted through `emit_fn`: its coalesce
    // target's preserved name, or `_<id>`. A driver synthesizing a wrapper reads the receiver name
    // here instead of parsing emitted text.
    pub fn local_cname(self: &Self, l: u32, dst: &mut String) {
        self.lspell(l, dst);
    }

    // Append the C spelling of local `l`: its coalesce target's preserved name, or `_<id>`.
    fn lspell(self: &Self, l: u32, dst: &mut String) {
        let c = *self.sx_coal.at(l as usize);
        let nm = self.sx_name.at(c as usize);
        if nm.len() != 0 {
            dst.push_string(nm);
        } else {
            dst.push_str("_");
            dst.push_u64(c);
        }
    }

    // Whether this assignment became a no-op self-copy after coalescing (its declaration and store
    // are both elided).
    const fn is_coalesced_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 {
            return false;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        if rv.kind != ir::RV_USE {
            return false;
        }
        let op = *b.operands.at(rv.a as usize);
        if op.kind != ir::OP_MOVE && op.kind != ir::OP_COPY {
            return false;
        }
        let sp = *b.places.at(op.data as usize);
        if sp.proj_len != 0 {
            return false;
        }
        return *self.sx_coal.at(pl.base as usize) == *self.sx_coal.at(sp.base as usize);
    }

    // A store to a dead local (never read, no declaration): its pure rvalue has no side effect, so
    // the whole statement is dropped. Whole-local writes only; the local's liveness (sx_used) already
    // accounts for reads and hard writes, so `!sx_used` here guarantees the rvalue is pure.
    const fn is_dead_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 || pl.base as usize < b.returns as usize {
            return false;
        }
        let st = b.locals.at(pl.base as usize).storage;
        if st == ir::LS_ARG || st == ir::LS_STATIC_REF {
            return false;
        }
        if *self.sx_coal.at(pl.base as usize) != pl.base {
            return false; // coalesced: handled by is_coalesced_store
        }
        return !*self.sx_used.at(pl.base as usize);
    }

    // Two places name the same storage: identical base and identical projection sequence. A dynamic
    // index compares by its operand id (a conservative match -- distinct ids that happen to hold the
    // same value read as different, which only forgoes a rewrite).
    fn places_equal(self: &Self, b: &ir::CoreBody, a: u32, c: u32) bool {
        let pa = *b.places.at(a as usize);
        let pc = *b.places.at(c as usize);
        if pa.base != pc.base || pa.proj_len != pc.proj_len {
            return false;
        }
        for i in 0..pa.proj_len {
            let ja = *b.projections.at((pa.proj_start + i) as usize);
            let jc = *b.projections.at((pc.proj_start + i) as usize);
            if ja.kind != jc.kind || ja.data != jc.data || ja.sub != jc.sub {
                return false;
            }
        }
        return true;
    }

    // The C compound-assignment spelling for a binary operator token, or "" when the operator has no
    // `op=` form (comparisons, logical, equality).
    const fn compound_op(t: tt::TokenType) str<'static> {
        if t == tt::TokenType::Plus {
            return "+=";
        }
        if t == tt::TokenType::Minus {
            return "-=";
        }
        if t == tt::TokenType::Star {
            return "*=";
        }
        if t == tt::TokenType::Slash {
            return "/=";
        }
        if t == tt::TokenType::Percent {
            return "%=";
        }
        if t == tt::TokenType::Ampersand {
            return "&=";
        }
        if t == tt::TokenType::Pipe {
            return "|=";
        }
        if t == tt::TokenType::Caret {
            return "^=";
        }
        if t == tt::TokenType::LeftShift {
            return "<<=";
        }
        if t == tt::TokenType::RightShift {
            return ">>=";
        }
        return "";
    }

    // `x = x op y` reads better as `x op= y`, and evaluates the destination once. Applies only to the
    // scalar C-operator path (aggregates dispatch through a method) when the binary's left operand is
    // the destination place itself. Returns whether it emitted the statement.
    fn try_compound_assign(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        // See through a store of an inlined temporary (`x = _t` where `_t = x op y`): the binary
        // reaches the store directly, so the compound form still applies.
        let mut rvid = s.rvalue;
        let rv0 = *b.rvalues.at(rvid as usize);
        if rv0.kind == ir::RV_USE {
            let op = *b.operands.at(rv0.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let p = *b.places.at(op.data as usize);
                if p.proj_len == 0 && *self.sx_inline.at(p.base as usize) != ir::IR_NONE {
                    rvid = *self.sx_inline.at(p.base as usize);
                }
            }
        }
        let rv = *b.rvalues.at(rvid as usize);
        if rv.kind != ir::RV_BINARY || !self.is_scalar(b, pl.ty) {
            return false;
        }
        let opstr = CEmit::compound_op(rv.c as tt::TokenType);
        if opstr.len() == 0 {
            return false;
        }
        let la = *b.operands.at(rv.a as usize);
        if la.kind != ir::OP_COPY && la.kind != ir::OP_MOVE {
            return false;
        }
        if !self.places_equal(b, s.place, la.data) {
            return false;
        }
        // Committed: a later failure sets self.err rather than returning false, so the caller does not
        // re-run the general path and double emit_place's collection side effects.
        let mut lhs = String::new();
        let mut rhs = String::new();
        let mut bm = b.module;
        let mut bt = TYPE_NONE;
        let bref = self.bin_op_ty(b, rv.b, &mut bm, &mut bt);
        if self.emit_place(b, s.place, &mut lhs) && self.emit_op_d(b, rv.b, bref, &mut rhs) {
            self.out.push_str("  ");
            self.out.push_string(&lhs);
            self.out.push_str(" ");
            self.out.push_str(opstr);
            self.out.push_str(" ");
            self.out.push_string(&rhs);
            self.out.push_str(";\n");
        }
        return true;
    }

    // The whole-local definition of an inlined temporary: its statement is skipped, the rvalue
    // reappears at the single read (emit_operand). Whole-local writes only.
    const fn is_inlined_store(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        let pl = *b.places.at(s.place as usize);
        return pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE;
    }

    // A scalar type -- builtin (int/bool/float), pointer, or reference. Only scalar temporaries
    // inline: an aggregate operand is taken by address in the equality/ordering/overload dispatch
    // paths, and C forbids the address of a materialized rvalue. Scalars are never address-taken in
    // a statement right-hand side or switch discriminant, so folding them is always spellable.
    fn is_scalar(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            return true;
        }
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin != BuiltinType::BT_VOID;
    }

    // Pure, scalar rvalue kinds whose result is a self-contained C expression (parenthesized or
    // atomic), so folding one into its single use never reorders evaluation or breaks precedence.
    const fn inlinable_def_kind(k: u8) bool {
        return k == ir::RV_USE || k == ir::RV_UNARY || k == ir::RV_BINARY || k == ir::RV_CAST || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT;
    }

    // Whether operand `opid` reads local `l` through no projection (a whole-local copy/move).
    const fn op_is_bare_local(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        return pl.proj_len == 0 && pl.base == l;
    }

    // A call returning a pointer/reference can also fold through one direct dereference: `_p = f();
    // x = *_p` becomes `x = *f()`. No field/index chain is accepted here.
    const fn op_is_deref_local(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        return pl.base == l && pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF;
    }

    const fn op_is_call_use(self: &Self, b: &ir::CoreBody, opid: u32, l: u32) bool {
        return self.op_is_bare_local(b, opid, l) || self.op_is_deref_local(b, opid, l);
    }

    // Whether rvalue `rid` reads local `l` as a bare operand -- the adjacency probe for the one
    // statement that immediately follows an inline candidate's definition.
    fn rvalue_reads_local_bare(self: &Self, b: &ir::CoreBody, rid: u32, l: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
            return self.op_is_bare_local(b, rv.a, l);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_bare_local(b, rv.a, l) || self.op_is_bare_local(b, rv.b, l);
        }
        if rv.kind == ir::RV_AGGREGATE || rv.kind == ir::RV_CLOSURE {
            // b is a genuine operand count here (RV_INTRINSIC overloads b as a TypeId, so it is
            // excluded -- a temp used only inside an intrinsic stays declared, which is safe)
            for i in 0..rv.b {
                if self.op_is_bare_local(b, b.oper_pool[(rv.a + i) as usize], l) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    fn rvalue_reads_call_use(self: &Self, b: &ir::CoreBody, rid: u32, l: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_DYN {
            return self.op_is_call_use(b, rv.a, l);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_call_use(b, rv.a, l) || self.op_is_call_use(b, rv.b, l);
        }
        return false;
    }

    // Whether operand `opid` reads local `base` through any projection (a whole or field/element read).
    const fn op_reads_base(self: &Self, b: &ir::CoreBody, opid: u32, base: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        return b.places.at(op.data as usize).base == base;
    }

    // Whether an inlinable-kind rvalue reads local `base` (as an operand or the place it projects
    // from). Used to test whether a statement between a temp's definition and its use writes one of
    // the definition's inputs.
    fn rvalue_reads_base(self: &Self, b: &ir::CoreBody, rid: u32, base: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return self.op_reads_base(b, rv.a, base);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_reads_base(b, rv.a, base) || self.op_reads_base(b, rv.b, base);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            return b.places.at(rv.a as usize).base == base;
        }
        if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                if self.op_reads_base(b, b.oper_pool[(rv.a + i) as usize], base) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    // Whether an operand reads through a projection (dereference, field, or index) -- i.e. it reads
    // memory rather than a whole local value.
    const fn op_is_projected(self: &Self, b: &ir::CoreBody, opid: u32) bool {
        if opid == ir::IR_NONE || opid as usize >= b.operands.len() {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        return b.places.at(op.data as usize).proj_len > 0;
    }

    // Whether an inlinable-kind rvalue reads memory (any projected operand or projected place-read).
    // A memory-reading definition cannot be folded across a store that might alias that memory.
    fn rvalue_reads_mem(self: &Self, b: &ir::CoreBody, rid: u32) bool {
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_UNARY || rv.kind == ir::RV_CAST {
            return self.op_is_projected(b, rv.a);
        }
        if rv.kind == ir::RV_BINARY {
            return self.op_is_projected(b, rv.a) || self.op_is_projected(b, rv.b);
        }
        if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT {
            return b.places.at(rv.a as usize).proj_len > 0;
        }
        if rv.kind == ir::RV_AGGREGATE {
            for i in 0..rv.b {
                if self.op_is_projected(b, b.oper_pool[(rv.a + i) as usize]) {
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    // Whether statement `s`, sitting between a single-use temp's definition (rvalue `def_rv`, which
    // reads memory iff `reads_mem`) and its read, leaves that definition's value unchanged -- so the
    // definition may fold past it. Safe when: a marker; or a pure whole/projected store that neither
    // writes an input the definition reads nor writes memory the definition depends on. Any effecting
    // statement (asm, allocation, discriminant/deinit against a memory-reading definition) blocks it.
    fn inline_safe_between(self: &Self, b: &ir::CoreBody, s: &ir::Statement, def_rv: u32, reads_mem: bool) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true;
        }
        if s.kind == ir::ST_ASM {
            return false;
        }
        if s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
            if reads_mem {
                return false;
            }
            return !self.rvalue_reads_base(b, def_rv, b.places.at(s.place as usize).base);
        }
        if s.kind != ir::ST_ASSIGN {
            return false;
        }
        if b.rvalues.at(s.rvalue as usize).kind == ir::RV_INTRINSIC {
            return false; // asm/new/safepoint carry an effect
        }
        let pl = *b.places.at(s.place as usize);
        if self.rvalue_reads_base(b, def_rv, pl.base) {
            return false; // writes a local the definition reads
        }
        if pl.proj_len != 0 && reads_mem {
            return false; // a projected store may alias the definition's memory
        }
        return true;
    }

    // Select single-use pure temporaries whose one read is adjacent to their definition (nothing
    // executes between them) so the definition can be dropped and its rvalue spelled at the read.
    // Conservative by construction: any projected use, taken address, extra write, non-pure producer,
    // or non-adjacent read leaves the local as an ordinary declared temporary. Near-linear: one
    // operand pass, one statement/terminator pass, then a bounded per-candidate look-ahead.
    fn compute_inline(self: &mut Self, b: &ir::CoreBody, coal_root: &Vector<bool>) {
        let n = b.locals.len();
        self.sx_inline.clear();
        for _l in 0..n {
            self.sx_inline.push(ir::IR_NONE);
        }
        let mut bare_read = Vector::<u32>::new();
        let mut ndef = Vector::<u32>::new();
        let mut blocked = Vector::<bool>::new();
        let mut def_rv = Vector::<u32>::new();
        let mut def_blk = Vector::<u32>::new();
        let mut def_idx = Vector::<u32>::new();
        for _l in 0..n {
            bare_read.push(0);
            ndef.push(0);
            blocked.push(false);
            def_rv.push(ir::IR_NONE);
            def_blk.push(ir::IR_NONE);
            def_idx.push(0);
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let pl = *b.places.at(op.data as usize);
                if pl.proj_len == 0 {
                    bare_read.set(pl.base as usize, *bare_read.at(pl.base as usize) + 1);
                } else {
                    blocked.set(pl.base as usize, true);
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let blk = *b.blocks.at(bi);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(s.place as usize);
                    let rv = *b.rvalues.at(s.rvalue as usize);
                    if pl.proj_len == 0 {
                        // a non-array struct/tuple/variant literal folds too (spelled as one compound
                        // literal at its read); array-bearing aggregates keep their element-wise store
                        let agg_ok = rv.kind == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_VARIANT) && !self.agg_has_array_field(
                            b,
                            &rv,
                        );
                        if CEmit::inlinable_def_kind(rv.kind) || agg_ok {
                            ndef.set(pl.base as usize, *ndef.at(pl.base as usize) + 1);
                            def_rv.set(pl.base as usize, s.rvalue);
                            def_blk.set(pl.base as usize, bi as u32);
                            def_idx.set(pl.base as usize, si);
                        } else {
                            blocked.set(pl.base as usize, true);
                        }
                    } else {
                        blocked.set(pl.base as usize, true);
                    }
                    if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                        blocked.set(b.places.at(rv.a as usize).base as usize, true);
                    }
                } else if s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
                    blocked.set(b.places.at(s.place as usize).base as usize, true);
                } else if s.kind == ir::ST_ASM {
                    for i in 0..s.b {
                        let op = *b.operands.at(b.oper_pool[(s.a + i) as usize] as usize);
                        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                            blocked.set(b.places.at(op.data as usize).base as usize, true);
                        }
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_DROP {
                blocked.set(b.places.at(t.a as usize).base as usize, true);
                if t.args_len == 1 {
                    blocked.set(t.args_start as usize, true);
                }
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    blocked.set(b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize).base as usize, true);
                }
            }
        }
        for l in 0..n {
            let ls = b.locals.at(l).storage;
            let dn0 = b.locals.at(l).decl;
            let pattern = dn0 != NODE_NONE && self.p().module_ast_const(b.module).at_const(dn0).kind == NodeKind::NODE_PATTERN_NAME;
            if ls != ir::LS_TEMP && !(ls == ir::LS_USER && (!b.locals.at(l).is_mutable || pattern)) {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 || l < b.returns as usize {
                continue;
            }
            if *coal_root.at(l) {
                continue;
            }
            if *blocked.at(l) || *ndef.at(l) != 1 || *bare_read.at(l) != 1 {
                continue;
            }
            // a closure capture spells `__env->name`, never a plain local; never fold it. Captures
            // are the trailing arguments [cap_base, returns+args); temporaries come after and DO fold.
            if self.cap_on && l as u32 >= self.cap_base && l as u32 < b.returns + b.args {
                continue;
            }
            // An aggregate operand is taken by address in the equality/ordering/overload dispatch and
            // by-reference call paths, and C forbids the address of a materialized rvalue; so an
            // aggregate temporary folds only into a whole-value copy (`x = _agg`, including a return
            // slot store), never into a comparison, a discriminant test, or a call argument. Scalars
            // are never address-taken in those spots and fold anywhere.
            let scalar = self.is_scalar(b, b.locals.at(l).ty);
            let bd = *def_blk.at(l);
            let di = *def_idx.at(l);
            let blk = *b.blocks.at(bd as usize);
            let drv = *def_rv.at(l);
            let reads_mem = self.rvalue_reads_mem(b, drv);
            // Fold the definition forward to its single read, stepping over statements that provably
            // leave the definition's value intact (they neither write an input nor alias its memory).
            // The read is a later statement's operand or the block's switch discriminant; any statement
            // that could change the definition halts the search and the temp stays declared.
            let mut ok = true;
            let mut inlined = false;
            let mut sk = di + 1;
            while sk < blk.stmt_len {
                let s2 = *b.statements.at((blk.stmt_start + sk) as usize);
                if s2.kind == ir::ST_ASSIGN && self.rvalue_reads_local_bare(b, s2.rvalue, l as u32) {
                    if scalar || b.rvalues.at(s2.rvalue as usize).kind == ir::RV_USE {
                        self.sx_inline.set(l, drv);
                    }
                    inlined = true; // the sole read; stop whether or not it was a foldable position
                    break;
                }
                if !self.inline_safe_between(b, &s2, drv, reads_mem) {
                    ok = false;
                    break;
                }
                sk += 1;
            }
            if !inlined && ok && scalar && (blk.term.kind == ir::TM_SWITCH || blk.term.kind == ir::TM_ASSERT) && self.op_is_bare_local(
                b,
                blk.term.a,
                l as u32,
            ) {
                self.sx_inline.set(l, drv);
            }
        }
        // Multi-return slots (locals 0..returns) are read only by the synthesized carrier
        // `(name_ret){ ._0 = _0, .. }`, never as an operand, so the loop above skips them. A slot with
        // one pure definition and no operand reads folds into that carrier field -- provided its
        // definition reaches the return with nothing overwriting its inputs. Single-return `_0` is
        // left alone (return-slot forwarding owns it).
        if b.returns > 1 {
            for l in 0..b.returns as usize {
                if *blocked.at(l) || *ndef.at(l) != 1 || *bare_read.at(l) != 0 {
                    continue;
                }
                let bd = *def_blk.at(l);
                if bd == ir::IR_NONE || b.blocks.at(bd as usize).term.kind != ir::TM_RETURN {
                    continue;
                }
                let drv = *def_rv.at(l);
                let reads_mem = self.rvalue_reads_mem(b, drv);
                let blk = *b.blocks.at(bd as usize);
                let mut ok = true;
                let mut sk = *def_idx.at(l) + 1;
                while sk < blk.stmt_len {
                    let s = *b.statements.at((blk.stmt_start + sk) as usize);
                    if !self.inline_safe_between(b, &s, drv, reads_mem) {
                        ok = false;
                        break;
                    }
                    sk += 1;
                }
                if ok {
                    self.sx_inline.set(l, drv);
                }
            }
        }
    }

    // Inline a single-use slice/array length into a loop comparison when its source is not written
    // in that loop. Re-evaluating `value.len` is then equivalent and removes the bound temporary.
    fn compute_loop_inline(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        for h in 0..b.blocks.len() {
            if !*cf.is_header.at(h) {
                continue;
            }
            let t = b.blocks.at(h).term;
            if t.kind != ir::TM_SWITCH {
                continue;
            }
            let cop = *b.operands.at(t.a as usize);
            if cop.kind != ir::OP_COPY && cop.kind != ir::OP_MOVE {
                continue;
            }
            let cp = *b.places.at(cop.data as usize);
            if cp.proj_len != 0 || *self.sx_inline.at(cp.base as usize) == ir::IR_NONE {
                continue;
            }
            let crv = *b.rvalues.at((*self.sx_inline.at(cp.base as usize)) as usize);
            if crv.kind != ir::RV_BINARY {
                continue;
            }
            let ro = *b.operands.at(crv.b as usize);
            if ro.kind != ir::OP_COPY && ro.kind != ir::OP_MOVE {
                continue;
            }
            let rp = *b.places.at(ro.data as usize);
            let bound = rp.base as usize;
            if rp.proj_len != 0 || bound < b.returns as usize || *self.sx_inline.at(bound) != ir::IR_NONE {
                continue;
            }
            let mut nuse: u32 = 0;
            for oi in 0..b.operands.len() {
                let op = *b.operands.at(oi);
                if (op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE) && b.places.at(op.data as usize).base as usize == bound {
                    nuse += 1;
                }
            }
            if nuse != 1 {
                continue;
            }
            let mut def = ir::IR_NONE;
            let mut def_block = cfl::NONE;
            let mut source = ir::IR_NONE;
            for bi in 0..b.blocks.len() {
                let bb = *b.blocks.at(bi);
                for si in 0..bb.stmt_len {
                    let s = *b.statements.at((bb.stmt_start + si) as usize);
                    if s.kind != ir::ST_ASSIGN {
                        continue;
                    }
                    let dp = *b.places.at(s.place as usize);
                    if dp.proj_len != 0 || dp.base as usize != bound {
                        continue;
                    }
                    let rv = *b.rvalues.at(s.rvalue as usize);
                    if def != ir::IR_NONE || rv.kind != ir::RV_LEN {
                        def = ir::IR_NONE;
                        def_block = cfl::NONE;
                        break;
                    }
                    def = s.rvalue;
                    def_block = bi as u32;
                    source = b.places.at(rv.a as usize).base;
                }
                if def == ir::IR_NONE && def_block == cfl::NONE {
                    continue;
                }
            }
            if def == ir::IR_NONE || !cf.dominates(def_block, h as u32) {
                continue;
            }
            let mut changed = false;
            for bi in 0..b.blocks.len() {
                if *cf.loop_of.at(bi) != h as u32 {
                    continue;
                }
                let bb = *b.blocks.at(bi);
                for si in 0..bb.stmt_len {
                    let s = *b.statements.at((bb.stmt_start + si) as usize);
                    if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).base == source {
                        changed = true;
                    }
                }
            }
            if !changed {
                self.sx_inline.set(bound, def);
            }
        }
    }

    // A type with an ordinary single-declarator C spelling, so `T name = init;` is well-formed:
    // excludes arrays (special extent syntax, and C forbids array assignment), the unit/void and
    // never placeholders, and untyped temps (their type recovers at declaration).
    fn simple_decl_type(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind == TypeKind::TYPE_NEVER || y.kind == TypeKind::TYPE_ARRAY && y.as_data.arr.len == 0 {
            return false;
        }
        return !(y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID);
    }

    // An rvalue whose store emits through the general `lhs = rhs;` path as a single C initializer, so
    // its declaration can fuse. Excludes array literals, repeats, array-bearing aggregates, `new`,
    // dynamic-env construction, and other multi-statement stores.
    fn fusable_init_rvalue(self: &Self, b: &ir::CoreBody, rv: &ir::Rvalue) bool {
        let k = rv.kind;
        if k == ir::RV_USE || k == ir::RV_BINARY || k == ir::RV_UNARY || k == ir::RV_CAST || k == ir::RV_REF || k == ir::RV_ADDR || k == ir::RV_LEN || k == ir::RV_DISCRIMINANT || k == ir::RV_SLICE {
            return true;
        }
        if k == ir::RV_AGGREGATE && (rv.c == ir::AGG_STRUCT || rv.c == ir::AGG_TUPLE || rv.c == ir::AGG_VARIANT) {
            return !self.agg_has_array_field(b, rv);
        }
        if k == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY {
            return true;
        }
        if k == ir::RV_INTRINSIC && rv.c as u32 == ir::IN_NEW as u32 {
            return true;
        }
        if k == ir::RV_CLOSURE {
            return true;
        }
        return false;
    }

    // Domination probe over one written place: if local `p.base` is a fusion candidate whose init
    // block does not dominate the writing block `bi`, the fused declaration would not dominate that
    // write, so the candidate is withdrawn.
    fn dom_check_place(
        self: &Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        pid: u32,
        bi: u32,
        init_blk: &Vector<u32>,
        out: &mut Vector<bool>,
    ) {
        let base = (*self.sx_coal.at(b.places.at(pid as usize).base as usize)) as usize;
        if *init_blk.at(base) != cfl::NONE && !cf.dominates(*init_blk.at(base), bi) {
            out.set(base, true);
        }
    }

    // Choose locals that declare at their initializing write. A candidate's first write must be a
    // whole-local store with a single-initializer rvalue, and that write's block must dominate every
    // WRITE to the local -- which, with the checker's definite-init guarantee, also dominates every
    // read (a read the init did not dominate would need a write the init did not dominate). So the
    // fused declaration is in scope and has run before any use on every path. Two near-linear passes:
    // first write per local, then a write-domination sweep.
    fn compute_fusion(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        let n = b.locals.len();
        self.sx_fuse.clear();
        self.sx_declared.clear();
        for _l in 0..n {
            self.sx_fuse.push(false);
            self.sx_declared.push(false);
        }
        let mut init_blk = Vector::<u32>::new();
        let mut seen = Vector::<bool>::new();
        let mut bad = Vector::<bool>::new();
        let mut nread = Vector::<u32>::new();
        let mut direct_array = Vector::<bool>::new();
        for _l in 0..n {
            init_blk.push(cfl::NONE);
            seen.push(false);
            bad.push(false);
            nread.push(0);
            direct_array.push(false);
        }
        // Pass 1: first write per local, in emission (reverse-postorder) order.
        for oi in 0..cf.order.len() {
            let bi = *cf.order.at(oi);
            let blk = *b.blocks.at(bi as usize);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                let mut wl = ir::IR_NONE;
                let mut ok_init = false;
                let mut is_array_init = false;
                if s.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(s.place as usize);
                    let rv0 = *b.rvalues.at(s.rvalue as usize);
                    wl = *self.sx_coal.at(pl.base as usize);
                    ok_init = pl.proj_len == 0 && self.fusable_init_rvalue(b, &rv0);
                    is_array_init = rv0.kind == ir::RV_AGGREGATE && rv0.c == ir::AGG_ARRAY;
                } else if s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
                    wl = b.places.at(s.place as usize).base;
                } else if s.kind == ir::ST_ASM {
                    // an asm output writes a local through a form the fused declaration cannot host
                    for i in 0..s.b {
                        let op = *b.operands.at(b.oper_pool[(s.a + i) as usize] as usize);
                        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                            bad.set(b.places.at(op.data as usize).base as usize, true);
                        }
                    }
                }
                if wl != ir::IR_NONE && !*seen.at(wl as usize) {
                    seen.set(wl as usize, true);
                    if ok_init {
                        init_blk.set(wl as usize, bi);
                        direct_array.set(wl as usize, is_array_init);
                    } else {
                        bad.set(wl as usize, true);
                    }
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    let dp = b.dest_pool[(t.dests_start + d) as usize];
                    let pl = *b.places.at(dp as usize);
                    let wl = *self.sx_coal.at(pl.base as usize);
                    if !*seen.at(wl as usize) {
                        seen.set(wl as usize, true);
                        let mut call_init = t.dests_len == 1 && pl.proj_len == 0;
                        if call_init && pl.ty == TYPE_NONE {
                            let mut rs = String::new();
                            call_init = self.untyped_ret_struct(b, wl, &mut rs);
                        } else if call_init {
                            call_init = self.simple_decl_type(b, pl.ty);
                        }
                        if call_init && pl.ty != TYPE_NONE {
                            let mut rm = b.module;
                            let mut rt = pl.ty;
                            self.rty(b, pl.ty, &mut rm, &mut rt);
                            call_init = self.p().module_ast_const(rm).type_at(rt).kind != TypeKind::TYPE_ARRAY;
                        }
                        if call_init {
                            init_blk.set(wl as usize, bi);
                        } else {
                            bad.set(wl as usize, true);
                        }
                    }
                }
            }
        }
        // Pass 2: every WRITE must be dominated by its local's init block (definite-init then extends
        // this to reads); tally reads. Writes are whole/projected assigns, discriminant/deinit stores,
        // and call destinations.
        for oi in 0..cf.order.len() {
            let bi = *cf.order.at(oi);
            let blk = *b.blocks.at(bi as usize);
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN || s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
                    self.dom_check_place(b, cf, s.place, bi, &init_blk, &mut bad);
                }
            }
            let t = blk.term;
            if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    self.dom_check_place(b, cf, b.dest_pool[(t.dests_start + d) as usize], bi, &init_blk, &mut bad);
                }
            }
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let rb = *self.sx_coal.at(b.places.at(op.data as usize).base as usize);
                nread.set(rb as usize, *nread.at(rb as usize) + 1);
            }
        }
        for l in 0..n {
            let st = b.locals.at(l).storage;
            if st != ir::LS_USER && st != ir::LS_TEMP {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 || l < b.returns as usize {
                continue;
            }
            if *self.sx_inline.at(l) != ir::IR_NONE || *bad.at(l) || *init_blk.at(l) == cfl::NONE {
                continue;
            }
            // A general initializer must sit outside every loop because C dominance does not imply
            // lexical scope across a loop exit. A range-loop index is scoped to that loop and may
            // declare at its initializer even when the loop is nested.
            if *cf.loop_of.at((*init_blk.at(l)) as usize) != cfl::NONE {
                let decl = b.locals.at(l).decl;
                if decl == NODE_NONE || self.p().module_ast_const(b.module).at_const(decl).kind != NodeKind::NODE_FOR {
                    continue;
                }
            }
            let mut decl_ok = self.simple_decl_type(b, b.locals.at(l).ty);
            if b.locals.at(l).ty == TYPE_NONE {
                let mut rs = String::new();
                decl_ok = self.untyped_ret_struct(b, l as u32, &mut rs);
            }
            if *nread.at(l) == 0 || !decl_ok {
                continue;
            }
            {
                let mut rmA = b.module;
                let mut rtA = b.locals.at(l).ty;
                self.rty(b, b.locals.at(l).ty, &mut rmA, &mut rtA);
                if self.p().module_ast_const(rmA).type_at(rtA).kind == TypeKind::TYPE_ARRAY && !*direct_array.at(l) {
                    continue;
                }
            }
            if self.cap_on && l as u32 >= self.cap_base {
                continue;
            }
            self.sx_fuse.set(l, true);
        }
    }

    // Whether a statement produces C output (so it "runs" between a forwarded call and its use).
    fn stmt_emits(self: &Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return false;
        }
        if self.is_dead_store(b, s) || self.is_coalesced_store(b, s) || self.is_inlined_store(b, s) {
            return false;
        }
        if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).ty != TYPE_NONE && self.is_unit(
            b,
            b.places.at(s.place as usize).ty,
        ) {
            return false;
        }
        return true;
    }

    // Forward a single-return call result into its one use. `_r = f(..)` (a call terminator) followed
    // by a use of `_r` in the continuation block, with nothing emitted between them, folds to spelling
    // `f(..)` at the use -- `return _r;` becomes `return f(..);`, `x = _r;` becomes `x = f(..);`, and a
    // condition `_r != 5` becomes `f(..) != 5`. The call still executes at the same point (nothing runs
    // between), and the continuation's sole predecessor is this call, so no path skips it.
    fn compute_call_fwd(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) {
        let n = b.locals.len();
        self.sx_call_fwd.clear();
        self.sx_call_str.clear();
        for _l in 0..n {
            self.sx_call_fwd.push(false);
            self.sx_call_str.push(String::new());
        }
        let mut bare = Vector::<u32>::new();
        let mut deref = Vector::<u32>::new();
        let mut bad = Vector::<bool>::new();
        let mut ncall = Vector::<u32>::new();
        for _l in 0..n {
            bare.push(0);
            deref.push(0);
            bad.push(false);
            ncall.push(0);
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                let pl = *b.places.at(op.data as usize);
                if pl.proj_len == 0 {
                    bare.set(pl.base as usize, *bare.at(pl.base as usize) + 1);
                } else if pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF {
                    deref.set(pl.base as usize, *deref.at(pl.base as usize) + 1);
                } else {
                    bad.set(pl.base as usize, true);
                }
            }
        }
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind == ir::ST_ASSIGN {
                if !self.is_coalesced_store(b, &s) {
                    bad.set(b.places.at(s.place as usize).base as usize, true); // any other store defeats the single-def call dest
                }
                let rv = *b.rvalues.at(s.rvalue as usize);
                if rv.kind == ir::RV_REF || rv.kind == ir::RV_ADDR || rv.kind == ir::RV_LEN || rv.kind == ir::RV_DISCRIMINANT || rv.kind == ir::RV_SLICE {
                    bad.set(b.places.at(rv.a as usize).base as usize, true);
                }
            } else if s.kind == ir::ST_SET_DISCR || s.kind == ir::ST_DEINIT {
                bad.set(b.places.at(s.place as usize).base as usize, true);
            } else if s.kind == ir::ST_ASM {
                for i in 0..s.b {
                    let op = *b.operands.at(b.oper_pool[(s.a + i) as usize] as usize);
                    if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                        bad.set(b.places.at(op.data as usize).base as usize, true);
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            let t = b.blocks.at(bi).term;
            if t.kind == ir::TM_DROP {
                bad.set(b.places.at(t.a as usize).base as usize, true);
            } else if t.kind == ir::TM_CALL {
                for d in 0..t.dests_len {
                    let dp = *b.places.at(b.dest_pool[(t.dests_start + d) as usize] as usize);
                    if dp.proj_len == 0 {
                        ncall.set(dp.base as usize, *ncall.at(dp.base as usize) + 1);
                    } else {
                        bad.set(dp.base as usize, true);
                    }
                }
            }
        }
        for bi in 0..b.blocks.len() {
            if !*cf.reach.at(bi) {
                continue;
            }
            let t = b.blocks.at(bi).term;
            if t.kind != ir::TM_CALL || t.dests_len != 1 {
                continue;
            }
            let dp = *b.places.at(b.dest_pool[t.dests_start as usize] as usize);
            let r = dp.base;
            let root = *self.sx_coal.at(r as usize);
            if dp.proj_len != 0 || r as usize < b.returns as usize {
                continue;
            }
            let cont = cf.succ(b, bi as u32, 0);
            let cblk = *b.blocks.at(cont as usize);
            let assert_use = self.assert_call_use(b, &cblk, root);
            let uses = *bare.at(root as usize) + *deref.at(root as usize);
            if *ncall.at(r as usize) != 1 || *bad.at(r as usize) || *bad.at(root as usize) || uses != 1 && !(assert_use && uses == 2) {
                continue;
            }
            if self.is_unit(b, b.locals.at(root as usize).ty) {
                continue;
            }
            // a fixed-array result stores through a `_ret` carrier + memcpy, not a plain expression
            {
                let mut rmA = b.module;
                let mut rtA = b.locals.at(root as usize).ty;
                self.rty(b, b.locals.at(root as usize).ty, &mut rmA, &mut rtA);
                let ya = *self.p().module_ast_const(rmA).type_at(rtA);
                if ya.kind == TypeKind::TYPE_ARRAY && ya.as_data.arr.len != 0 {
                    continue;
                }
            }
            // an aggregate result is taken by address in the equality/ordering/overload dispatch, and
            // C forbids the address of a call rvalue; fold it only into a whole-value copy or return.
            let scalar = self.is_scalar(b, b.locals.at(root as usize).ty);
            // the use must sit in the continuation with nothing emitted before it
            let mut before = false;
            let mut used = false;
            for si in 0..cblk.stmt_len {
                let s = *b.statements.at((cblk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN && self.rvalue_reads_call_use(b, s.rvalue, root) {
                    // A use that emits no statement cannot receive the forwarded call. Keep the call
                    // as its own statement so its side effect remains, then elide the unused copy.
                    if !self.stmt_emits(b, &s) {
                        if assert_use && self.is_inlined_store(b, &s) {
                            used = true;
                        } else {
                            before = true;
                        }
                        break;
                    }
                    used = scalar || b.rvalues.at(s.rvalue as usize).kind == ir::RV_USE;
                    before = !used; // the sole read, but not a foldable position -> keep the temp
                    break;
                }
                if self.stmt_emits(b, &s) {
                    before = true;
                    break;
                }
            }
            if !used && !before && scalar {
                let ct = cblk.term;
                if (ct.kind == ir::TM_SWITCH || ct.kind == ir::TM_ASSERT) && self.op_is_bare_local(b, ct.a, root) {
                    used = true;
                }
            }
            if used && !before {
                self.sx_call_fwd.set(r as usize, true);
                self.sx_call_fwd.set(root as usize, true);
            }
        }
    }

    fn assert_call_use(self: &Self, b: &ir::CoreBody, blk: &ir::BasicBlock, l: u32) bool {
        let t = blk.term;
        if t.kind != ir::TM_ASSERT || t.args_len != 4 {
            return false;
        }
        let mut diag: u32 = 0;
        for i in 0..2 {
            if self.op_is_call_use(b, b.oper_pool[(t.args_start + i as u32) as usize], l) {
                diag += 1;
            }
        }
        if diag != 1 {
            return false;
        }
        for i in 0..blk.stmt_len {
            let s = *b.statements.at((blk.stmt_start + i) as usize);
            if s.kind == ir::ST_ASSIGN && self.rvalue_reads_call_use(b, s.rvalue, l) {
                return self.is_inlined_store(b, &s);
            }
            if self.stmt_emits(b, &s) {
                return false;
            }
        }
        return false;
    }

    // Locals, labels, blocks and the closing brace -- shared by plain functions and closures.
    fn emit_body_core(self: &mut Self, b: &ir::CoreBody) bool {
        let mut cf = self.cfget();
        cf.build_into(b);
        let ok9 = self.emit_body_core_cf(b, &cf);
        self.cfput(cf);
        return ok9;
    }

    fn emit_body_core_cf(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        self.compute_loop_inline(b, cf);
        self.compute_fusion(b, cf);
        self.compute_call_fwd(b, cf);
        let ret_dead = !self.ret_slot_live(b, cf);
        // every non-argument local declares up front, explicitly typed; unit locals carry no C
        for l in 0..b.locals.len() {
            let st = b.locals.at(l).storage;
            if st == ir::LS_ARG {
                continue;
            }
            if *self.sx_coal.at(l) != l as u32 {
                continue; // coalesced into another local; shares its declaration
            }
            if l >= b.returns as usize && !*self.sx_used.at(l) {
                continue; // referenced nowhere: a dead temporary, not declared
            }
            if *self.sx_inline.at(l) != ir::IR_NONE {
                continue; // single-use pure temp: inlined at its read, no declaration
            }
            if *self.sx_fuse.at(l) {
                continue; // declares at its initializing write instead of up front
            }
            if *self.sx_call_fwd.at(l) {
                continue; // a forwarded call result: its call spells `f(..)` at the read, no storage
            }
            if l == 0 && ret_dead {
                continue; // return-slot forwarding made `_0` dead; drop its declaration
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
                    let mut nm2 = String::new();
                    self.lspell(l as u32, &mut nm2);
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
            let mut nm = self.sget();
            self.lspell(l as u32, &mut nm);
            let mut ts = self.sget();
            let ok = self.ty_c(b.module, b.locals.at(l).ty, nm.as_str(), &mut ts);
            if ok {
                self.out.push_str("  ");
                self.out.push_string(&ts);
                self.out.push_str(";\n");
            }
            self.sput(nm);
            self.sput(ts);
            if !ok {
                return false;
            }
        }
        let mut ok2 = false;
        if cf.reducible && self.plan_structured(b, cf) {
            ok2 = self.emit_structured(b, cf);
        } else {
            ok2 = self.emit_layout(b, cf);
        }
        if !ok2 {
            return false;
        }
        if b.returns == 1 && self.is_unit(b, b.locals.at(0).ty) && self.out.as_str().ends_with("  return;\n") {
            self.out.truncate(self.out.len() - 10);
        }
        self.out.push_str("}\n");
        return self.err.len() == 0;
    }

    // Emit reachable blocks in reverse-postorder: a label only where a goto lands, fall-through
    // when the sole successor is the next block, one goto otherwise. Unreachable blocks, the dead
    // fall-off sentinels, and jump-to-next chains never appear. Structured `if`/`switch`/loops are
    // layered on this by emit_body_core's structural pass; this is the goto-correct fallback.
    fn emit_layout(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        let m = cf.order.len();
        let mut need = Vector::<bool>::new();
        let mut skip = Vector::<bool>::new();
        let mut chain_default = Vector::<u32>::new();
        let mut chain_target = Vector::<u32>::new();
        let mut chain_kind = Vector::<u8>::new();
        for _i in 0..b.blocks.len() {
            need.push(false);
            skip.push(false);
            chain_default.push(cfl::NONE);
            chain_target.push(cfl::NONE);
            chain_kind.push(0);
        }
        // Pattern OR arms lower as a chain of one-case switches. Merge a chain only when every
        // continuation has one predecessor and emits no statement.
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let t = b.blocks.at(x as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 {
                continue;
            }
            let target = cf.succ(b, x, 0);
            let mut cur = x;
            let mut d = cf.succ(b, cur, 1);
            while *cf.preds.at(d as usize) == 1 && self.block_output_empty(b, d) {
                let dt = b.blocks.at(d as usize).term;
                if dt.kind != ir::TM_SWITCH || dt.sw_len != 1 || cf.succ(b, d, 0) != target {
                    break;
                }
                skip.set(d as usize, true);
                cur = d;
                d = cf.succ(b, cur, 1);
            }
            if cur != x {
                chain_default.set(x as usize, d);
                chain_target.set(x as usize, target);
                chain_kind.set(x as usize, 1);
            }
        }
        // Inclusive ranges lower as two true-edge comparisons with the same false edge.
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let t = b.blocks.at(x as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 {
                continue;
            }
            let mid = cf.succ(b, x, 0);
            if *cf.preds.at(mid as usize) != 1 || !self.block_output_empty(b, mid) {
                continue;
            }
            let mt = b.blocks.at(mid as usize).term;
            let fail = cf.succ(b, x, 1);
            if mt.kind == ir::TM_SWITCH && mt.sw_len == 1 && cf.succ(b, mid, 1) == fail {
                skip.set(mid as usize, true);
                chain_default.set(x as usize, fail);
                chain_target.set(x as usize, cf.succ(b, mid, 0));
                chain_kind.set(x as usize, 2);
            }
        }
        for i in 0..m {
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let mut ni = i + 1;
            while ni < m && *skip.at((*cf.order.at(ni)) as usize) {
                ni += 1;
            }
            let next = if ni < m {
                *cf.order.at(ni);
            } else {
                cfl::NONE;
            };
            let t = b.blocks.at(x as usize).term;
            if t.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, x, &mut cs) {
                    if cs != next {
                        need.set(cs as usize, true);
                    }
                } else if *chain_default.at(x as usize) != cfl::NONE {
                    need.set((*chain_target.at(x as usize)) as usize, true);
                    let ot = *chain_default.at(x as usize);
                    if ot != next {
                        need.set(ot as usize, true);
                    }
                } else {
                    for k in 0..t.sw_len {
                        need.set(cf.succ(b, x, k) as usize, true);
                    }
                    let ot = cf.succ(b, x, t.sw_len);
                    if ot != next {
                        need.set(ot as usize, true);
                    }
                }
            } else if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
                let s = cf.succ(b, x, 0);
                if s != next {
                    need.set(s as usize, true);
                }
            }
        }
        let mut ok = true;
        for i in 0..m {
            if !ok {
                break;
            }
            let x = *cf.order.at(i);
            if *skip.at(x as usize) {
                continue;
            }
            let mut ni = i + 1;
            while ni < m && *skip.at((*cf.order.at(ni)) as usize) {
                ni += 1;
            }
            let next = if ni < m {
                *cf.order.at(ni);
            } else {
                cfl::NONE;
            };
            if *need.at(x as usize) {
                self.out.push_str("bb_");
                self.out.push_u64(x);
                self.out.push_str(": ;\n");
            }
            let blk = *b.blocks.at(x as usize);
            if !self.emit_block_content(b, &blk) {
                ok = false;
                break;
            }
            if blk.term.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, x, &mut cs) {
                    if cs != next {
                        self.out.push_str("  goto bb_");
                        self.out.push_u64(cs);
                        self.out.push_str(";\n");
                    }
                } else {
                    let cd = *chain_default.at(x as usize);
                    if cd != cfl::NONE {
                        if *chain_kind.at(x as usize) == 1 {
                            ok = self.emit_switch_or_chain(b, cf, x, *chain_target.at(x as usize), cd);
                        } else {
                            ok = self.emit_switch_and_pair(b, cf, x, *chain_target.at(x as usize), cd);
                        }
                    } else {
                        ok = self.emit_switch_gotos(b, cf, x);
                    }
                    if !ok {
                        ok = false;
                        break;
                    }
                    let ot = if cd != cfl::NONE {
                        cd;
                    } else {
                        cf.succ(b, x, blk.term.sw_len);
                    };
                    if ot != next {
                        self.out.push_str("  goto bb_");
                        self.out.push_u64(ot);
                        self.out.push_str(";\n");
                    }
                }
            } else if blk.term.kind != ir::TM_RETURN && blk.term.kind != ir::TM_UNREACHABLE {
                let s = cf.succ(b, x, 0);
                if s != next {
                    self.out.push_str("  goto bb_");
                    self.out.push_u64(s);
                    self.out.push_str(";\n");
                }
            }
        }

        return ok;
    }

    fn block_output_empty(self: &Self, b: &ir::CoreBody, x: u32) bool {
        let blk = *b.blocks.at(x as usize);
        for i in 0..blk.stmt_len {
            if self.stmt_emits(b, b.statements.at((blk.stmt_start + i) as usize)) {
                return false;
            }
        }
        return true;
    }

    fn emit_switch_or_chain(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32, target: u32, end: u32) bool {
        let mut cur = x;
        self.out.push_str("  if (");
        loop {
            let t = b.blocks.at(cur as usize).term;
            let mut d = String::new();
            if !self.emit_operand(b, t.a, &mut d) {
                return false;
            }
            if cur != x {
                self.out.push_str(" || ");
            }
            self.push_case_test(
                false,
                self.is_bool(b, b.operands.at(t.a as usize).ty),
                &d,
                b.switch_pool[t.sw_start as usize] >> 32,
            );
            let next = cf.succ(b, cur, 1);
            if next == end {
                break;
            }
            cur = next;
        }
        self.out.push_str(") goto bb_");
        self.out.push_u64(target);
        self.out.push_str(";\n");
        return true;
    }

    fn emit_switch_and_pair(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32, target: u32, end: u32) bool {
        let mut cur = x;
        self.out.push_str("  if (");
        for i in 0..2 {
            let t = b.blocks.at(cur as usize).term;
            let mut d = String::new();
            if !self.emit_operand(b, t.a, &mut d) {
                return false;
            }
            if i != 0 {
                self.out.push_str(" && ");
            }
            self.push_case_test(
                false,
                self.is_bool(b, b.operands.at(t.a as usize).ty),
                &d,
                b.switch_pool[t.sw_start as usize] >> 32,
            );
            if i == 0 {
                cur = cf.succ(b, cur, 0);
            }
        }
        self.out.push_str(") goto bb_");
        self.out.push_u64(target);
        self.out.push_str(";\n");
        return cf.succ(b, cur, 1) == end;
    }

    fn const_switch_succ(self: &Self, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32, out: &mut u32) bool {
        let t = b.blocks.at(x as usize).term;
        if t.kind != ir::TM_SWITCH {
            return false;
        }
        let op = *b.operands.at(t.a as usize);
        if op.kind != ir::OP_CONST {
            return false;
        }
        let c = *b.constants.at(op.data as usize);
        if c.kind != ir::CK_INT && c.kind != ir::CK_BOOL {
            return false;
        }
        for k in 0..t.sw_len {
            if (b.switch_pool[(t.sw_start + k) as usize] >> 32) as u32 == c.val as u32 {
                *out = cf.succ(b, x, k);
                return true;
            }
        }
        *out = cf.succ(b, x, t.sw_len);
        return true;
    }

    // The per-arm equality tests of a switch terminator: `if ((disc) == value) goto bb_target;`.
    fn emit_switch_gotos(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, x: u32) bool {
        let t = b.blocks.at(x as usize).term;
        let mut d = String::new();
        if !self.emit_operand(b, t.a, &mut d) {
            return false;
        }
        let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
        let mut k: u32 = 0;
        while k < t.sw_len {
            let pair = b.switch_pool[(t.sw_start + k) as usize];
            self.out.push_str("  if (");
            self.push_case_test(false, isb, &d, pair >> 32);
            let target = cf.succ(b, x, k);
            let mut j = k + 1;
            while j < t.sw_len && cf.succ(b, x, j) == target {
                self.out.push_str(" || ");
                self.push_case_test(false, isb, &d, b.switch_pool[(t.sw_start + j) as usize] >> 32);
                j += 1;
            }
            self.out.push_str(") goto bb_");
            self.out.push_u64(target);
            self.out.push_str(";\n");
            k = j;
        }
        return true;
    }

    // The block-relative index of a `_0 = <operand>` statement that can forward straight to
    // `return <operand>` -- the last real statement of a single-value return block, skipping trailing
    // storage/nop markers. IR_NONE when the block is not that exact shape.
    fn ret_fwd_idx(self: &Self, b: &ir::CoreBody, blk: &ir::BasicBlock) u32 {
        if blk.term.kind != ir::TM_RETURN || b.returns != 1 || self.arr_ret {
            return ir::IR_NONE;
        }
        if self.is_unit(b, b.locals.at(0).ty) {
            return ir::IR_NONE;
        }
        let mut i = blk.stmt_len;
        while i > 0 {
            let k = b.statements.at((blk.stmt_start + i - 1) as usize).kind;
            if k == ir::ST_STORAGE_LIVE || k == ir::ST_STORAGE_DEAD || k == ir::ST_NOP {
                i -= 1;
                continue;
            }
            break;
        }
        if i == 0 {
            return ir::IR_NONE;
        }
        let idx = i - 1;
        let s = *b.statements.at((blk.stmt_start + idx) as usize);
        if s.kind != ir::ST_ASSIGN {
            return ir::IR_NONE;
        }
        let pl = *b.places.at(s.place as usize);
        if pl.base != 0 || pl.proj_len != 0 {
            return ir::IR_NONE;
        }
        let rv = *b.rvalues.at(s.rvalue as usize);
        if rv.kind == ir::RV_INTRINSIC || rv.kind == ir::RV_REPEAT || rv.kind == ir::RV_AGGREGATE && rv.c == ir::AGG_ARRAY || !self.fusable_init_rvalue(
            b,
            &rv,
        ) {
            return ir::IR_NONE;
        }
        if rv.kind == ir::RV_USE {
            let op = *b.operands.at(rv.a as usize);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                if b.places.at(op.data as usize).base == 0 {
                    return ir::IR_NONE; // the slot reads itself; leave the copy in place
                }
            }
        }
        return idx;
    }

    // Whether the single return slot `_0` is still referenced after return-slot forwarding. When
    // every return forwards its value directly, the slot's declaration is dead and must be dropped
    // (it would otherwise trip -Werror=unused-variable). Conservative: any read, any non-forwarded
    // write, or any `return _0` keeps it live.
    fn ret_slot_live(self: &Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        if b.returns != 1 || self.arr_ret || self.is_unit(b, b.locals.at(0).ty) {
            return true;
        }
        for o in 0..b.operands.len() {
            let op = *b.operands.at(o);
            if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
                if b.places.at(op.data as usize).base == 0 {
                    return true;
                }
            }
        }
        for bi in 0..b.blocks.len() {
            if !*cf.reach.at(bi) {
                continue; // unreachable blocks (the fall-off return sentinel) never emit
            }
            let blk = *b.blocks.at(bi);
            let skip = self.ret_fwd_idx(b, &blk);
            if blk.term.kind == ir::TM_RETURN && skip == ir::IR_NONE {
                return true;
            }
            for si in 0..blk.stmt_len {
                if si == skip {
                    continue;
                }
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).base == 0 {
                    return true;
                }
            }
        }
        return false;
    }

    // Emit a block's statements and terminator effect, applying return-slot forwarding. Shared by the
    // structured driver and the goto layout so both spell the same body.
    fn emit_block_content(self: &mut Self, b: &ir::CoreBody, blk: &ir::BasicBlock) bool {
        let skip = self.ret_fwd_idx(b, blk);
        for si in 0..blk.stmt_len {
            if si == skip {
                continue;
            }
            let s = *b.statements.at((blk.stmt_start + si) as usize);
            if !self.emit_stmt(b, &s) {
                return false;
            }
        }
        if skip != ir::IR_NONE {
            let mut ov = String::new();
            if !self.emit_rvalue(b, b.statements.at((blk.stmt_start + skip) as usize).rvalue, &mut ov) {
                return false;
            }
            self.out.push_str("  return ");
            self.out.push_string(&ov);
            self.out.push_str(";\n");
            return true;
        }
        return self.emit_term_effect(b, &blk.term);
    }

    // Reconstruct structured C over a reducible, simple-loop CFG: straight-line runs, `if`/`else`,
    // native `switch`, and `while` loops with `break`/`continue`. Any control the structure cannot
    // express directly (a header that is a multi-way switch, a cross exit) becomes a forward `goto`
    // whose label prints when its block is reached. The goto layout is the fallback for CFGs that
    // are not simple; both are behavior-equivalent.
    // Label-planning pass: walk the region tree with no output or statement side effects. Returns
    // true when the body structures with no goto (so the real pass is safe), leaving self.sx_lbl
    // marking any block that still needs a label. A false result sends the body to the goto layout.
    fn plan_structured(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        self.sx_emitted.clear();
        self.sx_lbl.clear();
        for _i in 0..b.blocks.len() {
            self.sx_emitted.push(false);
            self.sx_lbl.push(false);
        }
        self.sx_goto = false;
        let _ = self.emit_region(b, cf, cf.entry, cfl::NONE, cfl::NONE, cfl::NONE, true);
        if self.sx_goto {
            return false;
        }
        for i in 0..b.blocks.len() {
            if *self.sx_lbl.at(i) && !*self.sx_emitted.at(i) {
                return false;
            }
        }
        return true;
    }

    // Real structured pass; run only after plan_structured returned true (no goto needed).
    fn emit_structured(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow) bool {
        for i in 0..b.blocks.len() {
            self.sx_emitted.set(i, false);
        }
        return self.emit_region(b, cf, cf.entry, cfl::NONE, cfl::NONE, cfl::NONE, false);
    }

    const fn w(self: &mut Self, dry: bool, s: str) {
        if !dry {
            self.out.push_str(s);
        }
    }

    const fn wu(self: &mut Self, dry: bool, x: u64) {
        if !dry {
            self.out.push_u64(x);
        }
    }

    const fn ws(self: &mut Self, dry: bool, s: &String) {
        if !dry {
            self.out.push_string(s);
        }
    }

    // A boolean-valued type: its switch discriminant carries only 0/1, so a one-case test reads as
    // the value itself (`cond`) or its negation (`!(cond)`) rather than `(cond) == 1`.
    fn is_bool(self: &Self, b: &ir::CoreBody, t: TypeId) bool {
        if t == TYPE_NONE {
            return false;
        }
        let mut rm = b.module;
        let mut rt = t;
        self.rty(b, t, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        return y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_BOOL;
    }

    // The condition text without one redundant enclosing paren pair. An inlined comparison already
    // wraps itself in `(...)`; the surrounding `if (...)`/`while (...)` would then spell `((x == y))`,
    // which -Wparentheses-equality rejects. Returns the inner text when `s` is exactly one balanced
    // `( .. )` group (and contains no string literal, whose bytes could unbalance the scan), else `s`.
    fn unwrap_parens(s: &String, out: &mut String) {
        let ss = s.as_str();
        let n = ss.len();
        let mut wrapped = n >= 2 && ss.byte_at(0) == 40 && ss.byte_at(n - 1) == 41;
        if wrapped {
            let mut depth = 0;
            for i in 0..n {
                let c = ss.byte_at(i);
                if c == 34 {
                    wrapped = false;
                    break;
                }
                if c == 40 {
                    depth += 1;
                } else if c == 41 {
                    depth -= 1;
                    if depth == 0 && i + 1 != n {
                        wrapped = false;
                        break;
                    }
                }
            }
        }
        if wrapped {
            out.push_str(ss.slice(1, n - 1));
        } else {
            out.push_string(s);
        }
    }

    // Append one switch-case test on the already-spelled discriminant `d`: a boolean discriminant
    // reads as `d` (value 1) or `!d` (value 0); any other discriminant as `(d) == value`. `d` for a
    // true case drops one redundant paren layer so an inlined comparison does not double up.
    fn push_case_test(self: &mut Self, dry: bool, is_bool: bool, d: &String, value: u64) {
        if is_bool && value == 1 {
            if !dry {
                let mut u = String::new();
                CEmit::unwrap_parens(d, &mut u);
                self.out.push_string(&u);
            }
        } else if is_bool && value == 0 {
            self.w(dry, "!");
            self.ws(dry, d);
        } else {
            self.w(dry, "(");
            self.ws(dry, d);
            self.w(dry, ") == ");
            self.wu(dry, value);
        }
    }

    // A labeled break may leave nested loops for the follow of an enclosing loop. This is a safe
    // forward goto; no other cross-region transfer is accepted by the structured plan.
    fn outer_break_target(self: &Self, cf: &cfl::CFlow, current: u32, target: u32) bool {
        if current == cfl::NONE || target == cfl::NONE || *cf.rpo.at(target as usize) <= *cf.rpo.at(current as usize) {
            return false;
        }
        for h in 0..cf.n {
            if h != current && *cf.is_header.at(h as usize) && *cf.loop_follow.at(h as usize) == target && cf.dominates(
                h,
                current,
            ) {
                return true;
            }
        }
        return false;
    }

    // Emit the region entered at `entry`, falling through when it reaches `stop`; `brk`/`cont` are
    // the enclosing loop's break/continue block targets (NONE outside a loop). Sets self.sx_fell to
    // whether control left by fall-through (vs a terminator or transfer). In `dry` mode it makes the
    // identical control decisions but writes no C and runs no statement side effects.
    fn emit_region(
        self: &mut Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        entry: u32,
        stop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
    ) bool {
        let mut node = entry;
        loop {
            if node == stop {
                self.sx_fell = true;
                return true;
            }
            if node == cont {
                self.w(dry, "  continue;\n");
                self.sx_fell = false;
                return true;
            }
            if node == brk {
                self.w(dry, "  break;\n");
                self.sx_fell = false;
                return true;
            }
            if self.outer_break_target(cf, cont, node) {
                self.w(dry, "  goto bb_");
                self.wu(dry, node);
                self.w(dry, ";\n");
                self.sx_lbl.set(node as usize, true);
                self.sx_fell = false;
                return true;
            }
            if *self.sx_emitted.at(node as usize) || !cf.dominates(entry, node) {
                self.sx_goto = true;
                self.w(dry, "  goto bb_");
                self.wu(dry, node);
                self.w(dry, ";\n");
                self.sx_lbl.set(node as usize, true);
                self.sx_fell = false;
                return true;
            }
            if *cf.is_header.at(node as usize) {
                if !self.emit_loop(b, cf, node, dry) {
                    return false;
                }
                let lf = *cf.loop_follow.at(node as usize);
                if lf == cfl::NONE {
                    self.sx_fell = false;
                    return true;
                }
                node = lf;
                continue;
            }
            self.sx_emitted.set(node as usize, true);
            if *self.sx_lbl.at(node as usize) {
                self.w(dry, "bb_");
                self.wu(dry, node);
                self.w(dry, ": ;\n");
            }
            let blk = *b.blocks.at(node as usize);
            if !dry {
                if !self.emit_block_content(b, &blk) {
                    return false;
                }
            }
            if blk.term.kind == ir::TM_RETURN || blk.term.kind == ir::TM_UNREACHABLE {
                self.sx_fell = false;
                return true;
            }
            if blk.term.kind == ir::TM_SWITCH {
                let mut cs = cfl::NONE;
                if self.const_switch_succ(b, cf, node, &mut cs) {
                    node = cs;
                    continue;
                }
                let f = *cf.follow.at(node as usize);
                if !self.emit_branch(b, cf, node, f, stop, brk, cont, dry) {
                    return false;
                }
                if f == cfl::NONE {
                    return true;
                }
                node = f;
                continue;
            }
            node = cf.succ(b, node, 0);
        }
    }

    // A switch terminator as an `if`/`else` (or `else if` chain), or a native C `switch` when the
    // arms are >= 2 integer cases outside any loop (so a case `break` cannot escape a loop). Arms
    // stop at the branch join `f`, or at the region stop when the arms do not rejoin.
    fn emit_branch(
        self: &mut Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        x: u32,
        f: u32,
        rstop: u32,
        brk: u32,
        cont: u32,
        dry: bool,
    ) bool {
        let arm_stop = if f != cfl::NONE {
            f;
        } else {
            rstop;
        };
        let t = b.blocks.at(x as usize).term;
        let mut d = String::new();
        if !dry && !self.emit_operand(b, t.a, &mut d) {
            return false;
        }
        if t.sw_len >= 2 && brk == cfl::NONE && cont == cfl::NONE {
            self.w(dry, "  switch (");
            self.ws(dry, &d);
            self.w(dry, ") {\n");
            let mut fell = false;
            for k in 0..t.sw_len {
                self.w(dry, "  case ");
                self.wu(dry, b.switch_pool[(t.sw_start + k) as usize] >> 32);
                self.w(dry, ": {\n");
                if !self.emit_region(b, cf, cf.succ(b, x, k), arm_stop, brk, cont, dry) {
                    return false;
                }
                if self.sx_fell {
                    self.w(dry, "  break;\n");
                    fell = true;
                }
                self.w(dry, "  }\n");
            }
            self.w(dry, "  default: {\n");
            if !self.emit_region(b, cf, cf.succ(b, x, t.sw_len), arm_stop, brk, cont, dry) {
                return false;
            }
            if self.sx_fell {
                self.w(dry, "  break;\n");
                fell = true;
            }
            self.w(dry, "  }\n  }\n");
            self.sx_fell = fell;
            return true;
        }
        let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
        if !dry && t.sw_len == 1 {
            let mark = self.out.len();
            self.out.push_str("  if (");
            self.push_case_test(false, isb, &d, b.switch_pool[t.sw_start as usize] >> 32);
            self.out.push_str(") {\n");
            let body_mark = self.out.len();
            if !self.emit_region(b, cf, cf.succ(b, x, 0), arm_stop, brk, cont, false) {
                return false;
            }
            let true_fell = self.sx_fell;
            let ot = cf.succ(b, x, 1);
            if true_fell && self.out.len() == body_mark {
                self.out.truncate(mark);
                if ot == arm_stop {
                    self.sx_fell = true;
                    return true;
                }
                self.out.push_str("  if (");
                if !self.push_case_test_negated(b, &t, isb, &d, b.switch_pool[t.sw_start as usize] >> 32) {
                    return false;
                }
                self.out.push_str(") {\n");
                if !self.emit_region(b, cf, ot, arm_stop, brk, cont, false) {
                    return false;
                }
                self.out.push_str("  }\n");
                self.sx_fell = true;
                return true;
            }
            self.out.push_str("  }");
            let mut fell = true_fell;
            if ot != arm_stop {
                if !true_fell {
                    self.out.push_str("\n");
                    if !self.emit_region(b, cf, ot, arm_stop, brk, cont, false) {
                        return false;
                    }
                    return true;
                }
                let else_mark = self.out.len();
                self.out.push_str(" else {\n");
                let else_body = self.out.len();
                if !self.emit_region(b, cf, ot, arm_stop, brk, cont, false) {
                    return false;
                }
                if self.sx_fell {
                    fell = true;
                }
                if self.sx_fell && self.out.len() == else_body {
                    self.out.truncate(else_mark);
                    self.out.push_str("\n");
                } else {
                    self.out.push_str("  }\n");
                }
            } else {
                self.out.push_str("\n");
                fell = true;
            }
            self.sx_fell = fell;
            return true;
        }
        let mut fell = false;
        for k in 0..t.sw_len {
            if k == 0 {
                self.w(dry, "  if (");
            } else {
                self.w(dry, " else if (");
            }
            self.push_case_test(dry, isb, &d, b.switch_pool[(t.sw_start + k) as usize] >> 32);
            self.w(dry, ") {\n");
            if !self.emit_region(b, cf, cf.succ(b, x, k), arm_stop, brk, cont, dry) {
                return false;
            }
            if self.sx_fell {
                fell = true;
            }
            self.w(dry, "  }");
        }
        let ot = cf.succ(b, x, t.sw_len);
        if ot != arm_stop {
            let else_mark = self.out.len();
            self.w(dry, " else {\n");
            let else_body = self.out.len();
            if !self.emit_region(b, cf, ot, arm_stop, brk, cont, dry) {
                return false;
            }
            if self.sx_fell {
                fell = true;
            }
            if !dry && self.sx_fell && self.out.len() == else_body {
                self.out.truncate(else_mark);
                self.out.push_str("\n");
            } else {
                self.w(dry, "  }\n");
            }
        } else {
            self.w(dry, "\n");
            fell = true;
        }
        self.sx_fell = fell;
        return true;
    }

    fn push_case_test_negated(
        self: &mut Self,
        b: &ir::CoreBody,
        t: &ir::Terminator,
        is_bool: bool,
        d: &String,
        value: u64,
    ) bool {
        if is_bool && value == 1 {
            let mut n = String::new();
            if !self.emit_cond_negated(b, t.a, &mut n) {
                return false;
            }
            self.out.push_string(&n);
        } else if is_bool && value == 0 {
            let mut u = String::new();
            CEmit::unwrap_parens(d, &mut u);
            self.out.push_string(&u);
        } else {
            self.out.push_str("(");
            self.out.push_string(d);
            self.out.push_str(") != ");
            self.out.push_u64(value);
        }
        return true;
    }

    // Whether a loop header carries no per-iteration statement -- every statement is a marker or is
    // elided (dead, coalesced, inlined, or unit). Such a header is pure condition evaluation, so it
    // reconstructs as a native `while (cond)` instead of `while (1) { if (cond) .. else break; }`.
    fn header_empty(self: &Self, b: &ir::CoreBody, h: u32) bool {
        let blk = *b.blocks.at(h as usize);
        for si in 0..blk.stmt_len {
            let s = *b.statements.at((blk.stmt_start + si) as usize);
            if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
                continue;
            }
            if self.is_dead_store(b, &s) || self.is_coalesced_store(b, &s) || self.is_inlined_store(b, &s) {
                continue;
            }
            if s.kind == ir::ST_ASSIGN && b.places.at(s.place as usize).ty != TYPE_NONE && self.is_unit(
                b,
                b.places.at(s.place as usize).ty,
            ) {
                continue;
            }
            return false;
        }
        return true;
    }

    // Find a unique `i = i +/- 1` back-edge update for a Boolean comparison header.
    fn counted_loop_step(
        self: &Self,
        b: &ir::CoreBody,
        cf: &cfl::CFlow,
        h: u32,
        index_out: &mut u32,
        place: &mut u32,
        rvalue: &mut u32,
        step: &mut String,
    ) bool {
        let t = b.blocks.at(h as usize).term;
        let cop = *b.operands.at(t.a as usize);
        if cop.kind != ir::OP_COPY && cop.kind != ir::OP_MOVE {
            return false;
        }
        let cp = *b.places.at(cop.data as usize);
        if cp.proj_len != 0 || *self.sx_inline.at(cp.base as usize) == ir::IR_NONE {
            return false;
        }
        let crv = *b.rvalues.at((*self.sx_inline.at(cp.base as usize)) as usize);
        if crv.kind != ir::RV_BINARY {
            return false;
        }
        let ct = crv.c as tt::TokenType;
        if ct != tt::TokenType::LessThan && ct != tt::TokenType::LessThanEqual && ct != tt::TokenType::GreaterThan && ct != tt::TokenType::GreaterThanEqual {
            return false;
        }
        let lo = *b.operands.at(crv.a as usize);
        if lo.kind != ir::OP_COPY && lo.kind != ir::OP_MOVE {
            return false;
        }
        let lp = *b.places.at(lo.data as usize);
        if lp.proj_len != 0 {
            return false;
        }
        let index = lp.base;
        let mut found = false;
        for bi in 0..b.blocks.len() {
            if !*cf.reach.at(bi) || bi as u32 == h {
                continue;
            }
            let bb = *b.blocks.at(bi);
            if bb.term.kind != ir::TM_GOTO || cf.succ(b, bi as u32, 0) != h {
                continue;
            }
            let mut si = bb.stmt_len;
            while si > 0 {
                si -= 1;
                let s = *b.statements.at((bb.stmt_start + si) as usize);
                if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
                    continue;
                }
                if s.kind != ir::ST_ASSIGN {
                    break;
                }
                let dp = *b.places.at(s.place as usize);
                let rv = *b.rvalues.at(s.rvalue as usize);
                if dp.proj_len != 0 || dp.base != index || rv.kind != ir::RV_BINARY || !self.op_is_bare_local(
                    b,
                    rv.a,
                    index,
                ) {
                    break;
                }
                let ot = rv.c as tt::TokenType;
                if ot != tt::TokenType::Plus && ot != tt::TokenType::Minus {
                    break;
                }
                let ro = *b.operands.at(rv.b as usize);
                if ro.kind != ir::OP_CONST {
                    break;
                }
                let c = *b.constants.at(ro.data as usize);
                if c.kind != ir::CK_INT || c.val != 1 {
                    break;
                }
                if found {
                    return false;
                }
                found = true;
                *index_out = index;
                *place = s.place;
                *rvalue = s.rvalue;
                self.lspell(index, step);
                step.push_str(if_s(ot == tt::TokenType::Plus, "++", "--"));
                break;
            }
        }
        return found;
    }

    // Move an immediately preceding fused zero-initializer into a counted `for` header.
    fn take_loop_init(self: &mut Self, b: &ir::CoreBody, index: u32, init: &mut String) bool {
        let local = *b.locals.at(index as usize);
        if local.decl != NODE_NONE && self.p().module_ast_const(b.module).at_const(local.decl).kind == NodeKind::NODE_LET {
            return false;
        }
        if !*self.sx_fuse.at(index as usize) || !*self.sx_declared.at(index as usize) {
            return false;
        }
        let mut rid = ir::IR_NONE;
        for si in 0..b.statements.len() {
            let s = *b.statements.at(si);
            if s.kind != ir::ST_ASSIGN {
                continue;
            }
            let pl = *b.places.at(s.place as usize);
            if pl.proj_len != 0 || pl.base != index {
                continue;
            }
            let rv = *b.rvalues.at(s.rvalue as usize);
            if rv.kind != ir::RV_USE {
                continue;
            }
            let op = *b.operands.at(rv.a as usize);
            if op.kind != ir::OP_CONST || b.constants.at(op.data as usize).kind != ir::CK_INT || b.constants.at(
                op.data as usize,
            ).val != 0 || rid != ir::IR_NONE {
                return false;
            }
            rid = s.rvalue;
        }
        if rid == ir::IR_NONE {
            return false;
        }
        let mut name = String::new();
        self.lspell(index, &mut name);
        let mut decl = String::new();
        let mut rhs = String::new();
        if !self.ty_c(b.module, local.ty, name.as_str(), &mut decl) || !self.emit_rvalue(b, rid, &mut rhs) {
            return false;
        }
        let mut line = String::from_str("  ");
        line.push_string(&decl);
        line.push_str(" = ");
        line.push_string(&rhs);
        line.push_str(";\n");
        if self.out.len() < line.len() {
            return false;
        }
        let start = self.out.len() - line.len();
        for i in 0..line.len() {
            if self.out.as_str().byte_at(start + i) != line.as_str().byte_at(i) {
                return false;
            }
        }
        self.out.truncate(start);
        init.push_string(&decl);
        init.push_str(" = ");
        init.push_string(&rhs);
        return true;
    }

    fn do_loop_latch(self: &Self, b: &ir::CoreBody, cf: &cfl::CFlow, h: u32, out: &mut u32) bool {
        if b.blocks.at(h as usize).term.kind != ir::TM_GOTO {
            return false;
        }
        let lf = *cf.loop_follow.at(h as usize);
        let mut found = cfl::NONE;
        for p in 0..cf.n {
            if !*cf.reach.at(p as usize) || *cf.loop_of.at(p as usize) != h {
                continue;
            }
            let t = b.blocks.at(p as usize).term;
            if t.kind != ir::TM_SWITCH || t.sw_len != 1 || !self.header_empty(b, p) {
                continue;
            }
            let raw_case = (b.switch_pool[t.sw_start as usize] & 0xFFFFFFFFu64) as u32;
            let case_t = *cf.thread.at(raw_case as usize);
            let other = *cf.thread.at(t.t0 as usize);
            if !(case_t == h && other == lf || case_t == lf && other == h) {
                continue;
            }
            if found != cfl::NONE {
                return false;
            }
            found = p;
        }
        *out = found;
        return found != cfl::NONE;
    }

    // A loop header as `while (cond) { body }` when it only tests a condition, otherwise
    // `while (1) { <header>; if (cond) { body } else break; }`: the body's stop is the header, so a
    // natural back-edge falls through to the closing brace (re-iterates) and only a real
    // `break`/`continue` spells one. An unconditional header is an infinite `while (1)`.
    fn emit_loop(self: &mut Self, b: &ir::CoreBody, cf: &cfl::CFlow, h: u32, dry: bool) bool {
        self.sx_emitted.set(h as usize, true);
        if *self.sx_lbl.at(h as usize) {
            self.w(dry, "bb_");
            self.wu(dry, h);
            self.w(dry, ": ;\n");
        }
        let lf = *cf.loop_follow.at(h as usize);
        let blk = *b.blocks.at(h as usize);
        let t = blk.term;
        let mut latch = cfl::NONE;
        if self.do_loop_latch(b, cf, h, &mut latch) {
            self.sx_emitted.set(latch as usize, true);
            self.w(dry, "  do {\n");
            if !dry && !self.emit_block_content(b, &blk) {
                return false;
            }
            if !self.emit_region(b, cf, cf.succ(b, h, 0), latch, lf, latch, dry) {
                return false;
            }
            let lt = b.blocks.at(latch as usize).term;
            let mut d = String::new();
            if !dry && !self.emit_operand(b, lt.a, &mut d) {
                return false;
            }
            self.w(dry, "  } while (");
            let raw_case = (b.switch_pool[lt.sw_start as usize] & 0xFFFFFFFFu64) as u32;
            let case_t = *cf.thread.at(raw_case as usize);
            let isb = self.is_bool(b, b.operands.at(lt.a as usize).ty);
            if case_t == h {
                self.push_case_test(dry, isb, &d, b.switch_pool[lt.sw_start as usize] >> 32);
            } else if !dry && !self.push_case_test_negated(b, &lt, isb, &d, b.switch_pool[lt.sw_start as usize] >> 32) {
                return false;
            }
            self.w(dry, ");\n");
            return true;
        }
        // A single-test header whose false edge leaves the loop and whose body carries no code before
        // the test reads as a direct `while (cond)`. The condition arm (succ 0) is the body; the
        // otherwise arm is the loop exit.
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 && self.header_empty(b, h) {
            let body = cf.succ(b, h, 0);
            let exit_tgt = cf.succ(b, h, 1);
            if exit_tgt == lf && body != lf {
                let mut d = String::new();
                if !dry && !self.emit_operand(b, t.a, &mut d) {
                    return false;
                }
                let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
                let mut loop_index = ir::IR_NONE;
                let mut skip_place = ir::IR_NONE;
                let mut skip_rvalue = ir::IR_NONE;
                let mut step = String::new();
                let counted = self.counted_loop_step(
                    b,
                    cf,
                    h,
                    &mut loop_index,
                    &mut skip_place,
                    &mut skip_rvalue,
                    &mut step,
                );
                let mut init = String::new();
                let took_init = counted && !dry && self.take_loop_init(b, loop_index, &mut init);
                if counted {
                    self.w(dry, "  for (");
                    if took_init {
                        self.ws(dry, &init);
                    }
                    self.w(dry, "; ");
                } else {
                    self.w(dry, "  while (");
                }
                self.push_case_test(dry, isb, &d, b.switch_pool[t.sw_start as usize] >> 32);
                if counted {
                    self.w(dry, "; ");
                    self.ws(dry, &step);
                }
                self.w(dry, ") {\n");
                let old_place = self.sx_skip_place;
                let old_rvalue = self.sx_skip_rvalue;
                if counted {
                    self.sx_skip_place = skip_place;
                    self.sx_skip_rvalue = skip_rvalue;
                }
                let body_ok = self.emit_region(b, cf, body, h, lf, h, dry);
                self.sx_skip_place = old_place;
                self.sx_skip_rvalue = old_rvalue;
                if !body_ok {
                    return false;
                }
                self.w(dry, "  }\n");
                return true;
            }
        }
        self.w(dry, "  while (1) {\n");
        if !dry {
            for si in 0..blk.stmt_len {
                let s = *b.statements.at((blk.stmt_start + si) as usize);
                if !self.emit_stmt(b, &s) {
                    return false;
                }
            }
            if !self.emit_term_effect(b, &t) {
                return false;
            }
        }
        if t.kind == ir::TM_SWITCH && t.sw_len == 1 {
            let mut d = String::new();
            if !dry && !self.emit_operand(b, t.a, &mut d) {
                return false;
            }
            let isb = self.is_bool(b, b.operands.at(t.a as usize).ty);
            self.w(dry, "  if (");
            self.push_case_test(dry, isb, &d, b.switch_pool[t.sw_start as usize] >> 32);
            self.w(dry, ") {\n");
            if !self.emit_region(b, cf, cf.succ(b, h, 0), h, lf, h, dry) {
                return false;
            }
            self.w(dry, "  }");
            let exit_tgt = cf.succ(b, h, 1);
            if exit_tgt == lf {
                self.w(dry, " else {\n  break;\n  }\n");
            } else {
                self.w(dry, " else {\n");
                if !self.emit_region(b, cf, exit_tgt, h, lf, h, dry) {
                    return false;
                }
                self.w(dry, "  }\n");
            }
        } else if t.kind == ir::TM_SWITCH {
            if !self.emit_branch(b, cf, h, cfl::NONE, h, lf, h, dry) {
                return false;
            }
        } else if t.kind != ir::TM_RETURN && t.kind != ir::TM_UNREACHABLE {
            if !self.emit_region(b, cf, cf.succ(b, h, 0), h, lf, h, dry) {
                return false;
            }
        }
        self.w(dry, "  }\n");
        return true;
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
        self.setup_locals(b);
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
            let mut nm = String::new();
            self.lspell(l as u32, &mut nm);
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
        let is_tuple = sa.at_const(sdecl).as_data.aggregate.is_tuple;
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
                if is_tuple {
                    fnm.push_str("_");
                    fnm.push_u64(i);
                } else {
                    self.mg.ident(am, sa.at_const(sa.at_const(fid).as_data.field.name).as_data.name.text, &mut fnm);
                }
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

    // A fixed-array literal whose temporary was coalesced with its final local can initialize that
    // local directly. C array assignment is illegal, so this must run at the declaration point.
    fn emit_array_init(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement, rv: &ir::Rvalue) bool {
        let pl = *b.places.at(s.place as usize);
        if pl.proj_len != 0 {
            return false;
        }
        let root = *self.sx_coal.at(pl.base as usize);
        if !*self.sx_fuse.at(root as usize) || *self.sx_declared.at(root as usize) {
            return false;
        }
        let mut name = String::new();
        self.lspell(root, &mut name);
        let mut decl = String::new();
        if !self.ty_c(b.module, b.locals.at(root as usize).ty, name.as_str(), &mut decl) {
            return false;
        }
        self.sx_declared.set(root as usize, true);
        self.out.push_str("  ");
        self.out.push_string(&decl);
        self.out.push_str(" = { ");
        let mut ok = true;
        let mut sparse = false;
        for i in 0..rv.b {
            if b.oper_pool[(rv.a + i) as usize] == ir::IR_NONE {
                sparse = true;
                break;
            }
        }
        let mut emitted: u32 = 0;
        for i in 0..rv.b {
            let op = b.oper_pool[(rv.a + i) as usize];
            if op == ir::IR_NONE {
                continue;
            }
            if emitted != 0 {
                self.out.push_str(", ");
            }
            if sparse {
                self.out.push_str("[");
                self.out.push_u64(i);
                self.out.push_str("] = ");
            }
            let mut value = String::new();
            ok = self.emit_operand(b, op, &mut value);
            self.out.push_string(&value);
            if !ok {
                break;
            }
            emitted += 1;
        }
        if emitted == 0 {
            self.out.push_str("0");
        }
        self.out.push_str(" };\n");
        return ok;
    }

    fn emit_stmt(self: &mut Self, b: &ir::CoreBody, s: &ir::Statement) bool {
        if s.kind == ir::ST_STORAGE_LIVE || s.kind == ir::ST_STORAGE_DEAD || s.kind == ir::ST_NOP {
            return true; // markers carry no C
        }
        if s.kind == ir::ST_ASSIGN && s.place == self.sx_skip_place && s.rvalue == self.sx_skip_rvalue {
            return true;
        }
        if self.is_dead_store(b, s) {
            return true; // store to a never-read local: the pure rvalue has no side effect
        }
        if self.is_coalesced_store(b, s) {
            return true; // `_dst = move _src` collapsed: both spell the same C variable
        }
        if self.is_inlined_store(b, s) {
            return true; // single-use pure temp: its rvalue reappears at the read
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
                let pl9 = *b.places.at(s.place as usize);
                let root9 = *self.sx_coal.at(pl9.base as usize);
                let mut rm9 = b.module;
                let mut rt9 = b.locals.at(root9 as usize).ty;
                self.rty(b, rt9, &mut rm9, &mut rt9);
                let root_array = self.p().module_ast_const(rm9).type_at(rt9).kind == TypeKind::TYPE_ARRAY;
                if root_array && pl9.proj_len == 0 && *self.sx_fuse.at(root9 as usize) && !*self.sx_declared.at(
                    root9 as usize,
                ) {
                    return self.emit_array_init(b, s, &rv0);
                }
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
                            let fuse9 = pl9.proj_len == 0 && *self.sx_fuse.at(root9 as usize) && !*self.sx_declared.at(
                                root9 as usize,
                            );
                            if fuse9 {
                                let mut decl9 = String::new();
                                ok9 = self.ty_c(b.module, b.locals.at(root9 as usize).ty, lhs9.as_str(), &mut decl9);
                                if ok9 {
                                    self.sx_declared.set(root9 as usize, true);
                                    self.out.push_string(&decl9);
                                }
                            } else {
                                self.out.push_string(&lhs9);
                            }
                            self.out.push_str(" = (");
                            self.out.push_string(&cast9);
                            self.out.push_str("){ .ptr = (");
                            self.out.push_string(&et9);
                            self.out.push_str("[");
                            self.out.push_u64(rv0.b);
                            self.out.push_str("]){ ");
                            let mut sparse9 = false;
                            for i9 in 0..rv0.b {
                                if b.oper_pool[(rv0.a + i9) as usize] == ir::IR_NONE {
                                    sparse9 = true;
                                    break;
                                }
                            }
                            let mut emitted9: u32 = 0;
                            for i9 in 0..rv0.b {
                                if !ok9 {
                                    break;
                                }
                                let op9 = b.oper_pool[(rv0.a + i9) as usize];
                                if op9 == ir::IR_NONE {
                                    continue;
                                }
                                if emitted9 != 0 {
                                    self.out.push_str(", ");
                                }
                                if sparse9 {
                                    self.out.push_str("[");
                                    self.out.push_u64(i9);
                                    self.out.push_str("] = ");
                                }
                                let mut ev9 = String::new();
                                ok9 = self.emit_operand(b, op9, &mut ev9);
                                self.out.push_string(&ev9);
                                emitted9 += 1;
                            }
                            if emitted9 == 0 {
                                self.out.push_str("0");
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
            if rv0.kind == ir::RV_AGGREGATE && (rv0.c == ir::AGG_STRUCT || rv0.c == ir::AGG_TUPLE) && self.agg_has_array_field(
                b,
                &rv0,
            ) {
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
                let plN = *b.places.at(s.place as usize);
                let rootN = *self.sx_coal.at(plN.base as usize);
                let fuseN = plN.proj_len == 0 && *self.sx_fuse.at(rootN as usize) && !*self.sx_declared.at(
                    rootN as usize,
                );
                if fuseN {
                    self.sx_declared.set(rootN as usize, true);
                    let mut declN = String::new();
                    if !self.ty_c(b.module, b.locals.at(rootN as usize).ty, lhs.as_str(), &mut declN) {
                        return false;
                    }
                    self.out.push_string(&declN);
                } else {
                    self.out.push_string(&lhs);
                }
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
        if self.try_compound_assign(b, s) {
            return self.err.len() == 0;
        }
        let pl0 = *b.places.at(s.place as usize);
        let root0 = *self.sx_coal.at(pl0.base as usize);
        let fuse_decl = pl0.proj_len == 0 && *self.sx_fuse.at(root0 as usize) && !*self.sx_declared.at(root0 as usize);
        if !fuse_decl {
            // the pieces appear in output order, so they spell straight into the output buffer
            // (a failed statement leaves partial text; every failure path discards the body)
            let mut o = replace(&mut self.out, String::new());
            o.push_str("  ");
            let mut ok = self.emit_place(b, s.place, &mut o);
            if ok {
                o.push_str(" = ");
                ok = self.emit_rvalue(b, s.rvalue, &mut o);
            }
            if ok {
                o.push_str(";\n");
            }
            self.out = o;
            return ok;
        }
        let mut lhs = self.sget();
        let mut rhs = self.sget();
        let ok = self.emit_place(b, s.place, &mut lhs) && self.emit_rvalue(b, s.rvalue, &mut rhs);
        if ok {
            self.out.push_str("  ");
            self.sx_declared.set(root0 as usize, true);
            let mut decl = self.sget();
            if !self.ty_c(b.module, b.locals.at(root0 as usize).ty, lhs.as_str(), &mut decl) {
                return false;
            }
            self.out.push_string(&decl);
            self.sput(decl);
            self.out.push_str(" = ");
            self.out.push_string(&rhs);
            self.out.push_str(";\n");
        }
        self.sput(lhs);
        self.sput(rhs);
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
    // Peel pointer/reference indirection ahead of a member access, leaving `pre` at the aggregate.
    // Returns true when at least one level was peeled, so the caller spells the final access with `->`
    // (which folds in that last dereference); the outer levels wrap as `(*..)`. False -> a direct
    // value member spelled with `.`.
    fn place_field_arrow(self: &Self, b: &ir::CoreBody, pre: &mut TypeId, cur: &mut String) bool {
        let mut levels = 0;
        let mut g = 0;
        while g < 4 {
            let mut rm = b.module;
            let mut rt = *pre;
            self.rty(b, *pre, &mut rm, &mut rt);
            let y = *self.p().module_ast_const(rm).type_at(rt);
            if y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                break;
            }
            *pre = y.as_data.elem;
            levels += 1;
            g += 1;
        }
        if levels == 0 {
            return false;
        }
        for _k in 0..levels - 1 {
            let mut w = String::from_str("(*");
            w.push_string(cur);
            w.push_str(")");
            cur.truncate(0);
            cur.push_string(&w);
        }
        return true;
    }

    fn emit_place(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, dst: &mut String) bool {
        return self.emit_place_lim(b, pid, b.places.at(pid as usize).proj_len, dst);
    }

    // Emit a place applying only its first `lim` projections. `&*p` collapses to `p` by emitting the
    // dereferenced place with its trailing deref dropped (lim = proj_len - 1), which the address-of
    // rvalue then spells without the `&`.
    // The base spelling of local `base` straight into `dst`: forwarded-call parens, static/const
    // symbols (with the demand-time stub record), captured-env members, or the local's C name.
    fn emit_place_base(self: &mut Self, b: &ir::CoreBody, base: u32, dst: &mut String) bool {
        let d0 = dst.len();
        if *self.sx_call_fwd.at(base as usize) {
            dst.push_str("(");
            dst.push_string(self.sx_call_str.at(base as usize));
            dst.push_str(")");
        } else if b.locals.at(base as usize).storage == ir::LS_STATIC_REF {
            let item = b.locals.at(base as usize).item;
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
                            dst.push_i64(cv8);
                            folded = true;
                            break;
                        }
                    }
                }
            }
            if !folded && (item.node == NODE_NONE || !self.mg.const_sym(b.module, item.module, item.node, dst)) {
                return self.fail("static-sym");
            }
            if self.collect_demand && !folded {
                let mut h = 1469598103934665603u64;
                {
                    let cs = dst.as_str();
                    for k in d0..cs.len() {
                        h = (h ^ cs.byte_at(k) as u64) * 1099511628211u64;
                    }
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
                        let mut symb = self.sget();
                        symb.push_str(dst.as_str().slice(d0, dst.len()));
                        let mut sd = String::from_str("extern ");
                        if self.ty_c(b.module, b.locals.at(base as usize).ty, symb.as_str(), &mut sd) {
                            sd.push_str(";\n");
                            self.stat_decls.push_string(&sd);
                            self.stat_items.push(
                                StatRef {
                                    em: b.module,
                                    def: item,
                                    sym: symb.clone(),
                                    ty: b.locals.at(base as usize).ty,
                                },
                            );
                        }
                        self.sput(symb);
                    }
                }
            }
        } else if self.cap_on && base >= self.cap_base && base as usize < self.cap_base as usize + self.cap_names.len() {
            dst.push_str("__env->");
            dst.push_string(self.cap_names.at((base - self.cap_base) as usize));
        } else {
            self.lspell(base, dst);
        }
        return true;
    }

    fn emit_place_lim(self: &mut Self, b: &ir::CoreBody, pid: ir::PlaceId, lim: u32, dst: &mut String) bool {
        let pl = *b.places.at(pid as usize);
        if lim == 0 {
            // no projections, no wraps: the base spells straight into the destination
            return self.emit_place_base(b, pl.base, dst);
        }
        let mut cur = self.sget();
        if !self.emit_place_base(b, pl.base, &mut cur) {
            self.sput(cur);
            return false;
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
        let mut pend_arrow = false; // a deferred deref whose member access folds it into `->`
        for i in 0..lim {
            if !ok {
                break;
            }
            let pre0 = pre;
            let pj = *b.projections.at((pl.proj_start + i) as usize);
            if pj.kind == ir::PJ_DEREF {
                // `(*p).f` reads worse than `p->f`: when this deref feeds directly into a member
                // access, defer it so the field/downcast spells the arrow instead of wrapping `(*..)`.
                let nxt = if i + 1 < lim {
                    b.projections.at((pl.proj_start + i + 1) as usize).kind;
                } else {
                    0 as u8;
                };
                if nxt == ir::PJ_FIELD || nxt == ir::PJ_DOWNCAST {
                    pend_arrow = true;
                } else {
                    let mut w = self.sget();
                    w.push_str("(*");
                    w.push_string(&cur);
                    w.push_str(")");
                    self.sput(replace(&mut cur, w));
                }
            } else if pj.kind == ir::PJ_FIELD {
                let mut arrow = pend_arrow;
                pend_arrow = false;
                if !arrow && !prev_dc {
                    arrow = self.place_field_arrow(b, &mut pre, &mut cur);
                }
                cur.push_str(
                    if arrow {
                        "->";
                    } else {
                        ".";
                    },
                );
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
                    let mut w2 = self.sget();
                    w2.push_str("(*");
                    w2.push_string(&cur);
                    w2.push_str(")");
                    self.sput(replace(&mut cur, w2));
                    rm2 = nm2;
                    rt2 = nt2;
                    g2 += 1;
                }
                let a2 = self.p().module_ast_const(rm2);
                let mut chk = false; // length-carrying views bounds-check every subscript
                let mut base_txt = self.sget();
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
                self.sput(base_txt);
            } else if pj.kind == ir::PJ_DOWNCAST {
                let mut arrow = pend_arrow;
                pend_arrow = false;
                if !arrow {
                    arrow = self.place_field_arrow(b, &mut pre, &mut cur);
                }
                cur.push_str(
                    if arrow {
                        "->payload.";
                    } else {
                        ".payload.";
                    },
                );
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
                    let mut w = self.sget();
                    w.push_str("(&");
                    w.push_string(&cur);
                    w.push_str(")");
                    self.sput(replace(&mut cur, w));
                }
            }
        }
        if ok {
            dst.push_string(&cur);
        }
        self.sput(cur);
        return ok;
    }

    fn emit_operand(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            let pl = *b.places.at(op.data as usize);
            if pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE {
                return self.emit_rvalue(b, *self.sx_inline.at(pl.base as usize), dst);
            }
            if pl.proj_len == 0 && *self.sx_call_fwd.at(pl.base as usize) {
                dst.push_string(self.sx_call_str.at(pl.base as usize));
                return true;
            }
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
            if tk9 == tt::TokenType::ByteStringLiteral as i64 && raw0.len() >= 1 && raw0.byte_at(0) == b'b' {
                raw0 = raw0.slice(1, raw0.len()); // strip the `b` prefix; the quotes fall to the next check
            }
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
                // quoted/byte-string bodies carry Super-C escapes: decode to bytes, then re-escape
                // for C (a verbatim copy mis-spells `\xNN`, greedy in C, and the C-invalid `\u{...}`)
                push_sc_str_c(raw0, &mut esc);
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

    fn const_operand_i64(self: &Self, b: &ir::CoreBody, opid: ir::OperandId, out: &mut i64, depth: u32) bool {
        if depth > 8 || opid == ir::IR_NONE {
            return false;
        }
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_CONST {
            let c = *b.constants.at(op.data as usize);
            if c.kind == ir::CK_INT || c.kind == ir::CK_BOOL {
                *out = c.val;
                return true;
            }
            return false;
        }
        if op.kind != ir::OP_COPY && op.kind != ir::OP_MOVE {
            return false;
        }
        let pl = *b.places.at(op.data as usize);
        if pl.proj_len != 0 || *self.sx_inline.at(pl.base as usize) == ir::IR_NONE {
            return false;
        }
        return self.const_rvalue_i64(b, *self.sx_inline.at(pl.base as usize), out, depth + 1);
    }

    fn const_rvalue_i64(self: &Self, b: &ir::CoreBody, rid: ir::RvalueId, out: &mut i64, depth: u32) bool {
        if depth > 8 {
            return false;
        }
        let rv = *b.rvalues.at(rid as usize);
        if rv.kind == ir::RV_USE || rv.kind == ir::RV_CAST {
            return self.const_operand_i64(b, rv.a, out, depth + 1);
        }
        if rv.kind == ir::RV_UNARY && rv.b as u8 == tt::TokenType::Bang as u8 {
            let mut a: i64 = 0;
            if self.const_operand_i64(b, rv.a, &mut a, depth + 1) {
                *out = if a == 0 {
                    1;
                } else {
                    0;
                };
                return true;
            }
            return false;
        }
        if rv.kind != ir::RV_BINARY {
            return false;
        }
        let mut a: i64 = 0;
        let mut c: i64 = 0;
        if !self.const_operand_i64(b, rv.a, &mut a, depth + 1) || !self.const_operand_i64(b, rv.b, &mut c, depth + 1) {
            return false;
        }
        let t = rv.c as tt::TokenType;
        if t == tt::TokenType::EqualEqual {
            *out = if a == c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::BangEqual {
            *out = if a != c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::LessThan {
            *out = if a < c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::LessThanEqual {
            *out = if a <= c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::GreaterThan {
            *out = if a > c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::GreaterThanEqual {
            *out = if a >= c {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::AmpersandAmpersand {
            *out = if a != 0 && c != 0 {
                1;
            } else {
                0;
            };
        } else if t == tt::TokenType::PipePipe {
            *out = if a != 0 || c != 0 {
                1;
            } else {
                0;
            };
        } else {
            return false;
        }
        return true;
    }

    fn assert_holds_const(self: &Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        let mut v: i64 = 0;
        return t.kind == ir::TM_ASSERT && self.const_operand_i64(b, t.a, &mut v, 0) && v != 0;
    }

    fn assert_helper_kind(self: &Self, b: &ir::CoreBody, opid: ir::OperandId) u8 {
        let mut rm = b.module;
        let mut rt = b.operands.at(opid as usize).ty;
        self.rty(b, rt, &mut rm, &mut rt);
        let y = *self.p().module_ast_const(rm).type_at(rt);
        if y.kind != TypeKind::TYPE_BUILTIN {
            return 0;
        }
        let bt = y.as_data.builtin;
        if bt == BuiltinType::BT_BOOL {
            return 4;
        }
        if bt == BuiltinType::BT_F32 || bt == BuiltinType::BT_F64 {
            return 3;
        }
        if bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE {
            return 2;
        }
        if bt == BuiltinType::BT_CHAR || bt == BuiltinType::BT_I8 || bt == BuiltinType::BT_I16 || bt == BuiltinType::BT_I32 || bt == BuiltinType::BT_I64 || bt == BuiltinType::BT_ISIZE {
            return 1;
        }
        return 0;
    }

    fn ensure_assert_helper(self: &mut Self, kind: u8) {
        let bit = 1u8 << kind;
        if (self.assert_helpers & bit) != 0u8 {
            return;
        }
        self.assert_helpers |= bit;
        if kind == 1 {
            self.aux.push_str(
                "static inline void __sc_assert_i64(int64_t l, int64_t r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %lld\\n  right: %lld\\n  at %s:%llu\\n\", e, (long long)l, (long long)r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 2 {
            self.aux.push_str(
                "static inline void __sc_assert_u64(uint64_t l, uint64_t r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %llu\\n  right: %llu\\n  at %s:%llu\\n\", e, (unsigned long long)l, (unsigned long long)r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 3 {
            self.aux.push_str(
                "static inline void __sc_assert_f64(double l, double r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %g\\n  right: %g\\n  at %s:%llu\\n\", e, l, r, f, n); fflush(stderr); abort(); } }\n",
            );
        } else if kind == 4 {
            self.aux.push_str(
                "static inline void __sc_assert_bool(bool l, bool r, bool eq, const char *e, const char *f, unsigned long long n) { if ((l == r) != eq) { fprintf(stderr, \"assertion failed: `%s`\\n  left:  %s\\n  right: %s\\n  at %s:%llu\\n\", e, l ? \"true\" : \"false\", r ? \"true\" : \"false\", f, n); fflush(stderr); abort(); } }\n",
            );
        }
    }

    fn emit_forwarded_assert(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator, line: u64, handled: &mut bool) bool {
        *handled = false;
        if t.args_len != 4 {
            return true;
        }
        let lo = b.oper_pool[t.args_start as usize];
        let ro = b.oper_pool[(t.args_start + 1) as usize];
        let mut forwarded = false;
        let lop = *b.operands.at(lo as usize);
        if lop.kind == ir::OP_COPY || lop.kind == ir::OP_MOVE {
            let pl = *b.places.at(lop.data as usize);
            forwarded = (pl.proj_len == 0 || pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF) && *self.sx_call_fwd.at(
                pl.base as usize,
            );
        }
        if !forwarded {
            let rop = *b.operands.at(ro as usize);
            if rop.kind == ir::OP_COPY || rop.kind == ir::OP_MOVE {
                let pl = *b.places.at(rop.data as usize);
                forwarded = (pl.proj_len == 0 || pl.proj_len == 1 && b.projections.at(pl.proj_start as usize).kind == ir::PJ_DEREF) && *self.sx_call_fwd.at(
                    pl.base as usize,
                );
            }
        }
        let kind = self.assert_helper_kind(b, lo);
        if !forwarded || kind == 0 || self.assert_helper_kind(b, ro) != kind {
            return true;
        }
        let mut lv = String::new();
        let mut rv = String::new();
        if !self.emit_operand(b, lo, &mut lv) || !self.emit_operand(b, ro, &mut rv) {
            return false;
        }
        self.ensure_assert_helper(kind);
        self.out.push_str("  __sc_assert_");
        self.out.push_str(
            if kind == 1 {
                "i64";
            } else if kind == 2 {
                "u64";
            } else if kind == 3 {
                "f64";
            } else {
                "bool";
            },
        );
        self.out.push_str("(");
        self.out.push_string(&lv);
        self.out.push_str(", ");
        self.out.push_string(&rv);
        self.out.push_str(", ");
        self.out.push_str(if_s(t.sw_len == 2, "true", "false"));
        self.out.push_str(", \"");
        let src = self.p().modules.at(b.module as usize).source.as_str();
        let lsp = *b.constants.at(b.operands.at(b.oper_pool[(t.args_start + 2) as usize] as usize).data as usize);
        let rsp = *b.constants.at(b.operands.at(b.oper_pool[(t.args_start + 3) as usize] as usize).data as usize);
        push_c_escaped(src.slice(lsp.raw.start as usize, lsp.raw.end as usize), &mut self.out);
        self.out.push_str(if_s(t.sw_len == 2, " == ", " != "));
        push_c_escaped(src.slice(rsp.raw.start as usize, rsp.raw.end as usize), &mut self.out);
        self.out.push_str("\", \"");
        push_c_escaped(self.p().modules.at(b.module as usize).file.as_str(), &mut self.out);
        self.out.push_str("\", ");
        self.out.push_u64(line);
        self.out.push_str(");\n");
        *handled = true;
        return true;
    }

    // `  left:  <value>` diagnostics for a failed assert_eq/ne, formatted per operand type;
    // unprintable types skip the line rather than fail the emission.
    // Emit the negation of a boolean operand into `dst`. When the operand is an inlined comparison,
    // its operator folds -- `!(a == b)` reads as `a != b` -- so a failing-assert test spells the
    // relation directly. Equality flips for any type; ordering flips only for non-float operands
    // (a NaN makes `!(x < y)` and `x >= y` differ). Anything else falls back to `!(operand)`.
    fn emit_cond_negated(self: &mut Self, b: &ir::CoreBody, opid: ir::OperandId, dst: &mut String) bool {
        let op = *b.operands.at(opid as usize);
        if op.kind == ir::OP_COPY || op.kind == ir::OP_MOVE {
            let pl = *b.places.at(op.data as usize);
            if pl.proj_len == 0 && *self.sx_inline.at(pl.base as usize) != ir::IR_NONE {
                let rv = *b.rvalues.at((*self.sx_inline.at(pl.base as usize)) as usize);
                if rv.kind == ir::RV_BINARY {
                    let mut rm = b.module;
                    let mut rt = TYPE_NONE;
                    let aref = self.bin_op_ty(b, rv.a, &mut rm, &mut rt);
                    if !self.is_str_ty(rm, rt) && !self.op_dispatch_agg(rm, rt) {
                        let yk = *self.p().module_ast_const(rm).type_at(rt);
                        let is_float = yk.kind == TypeKind::TYPE_BUILTIN && (yk.as_data.builtin == BuiltinType::BT_F32 || yk.as_data.builtin == BuiltinType::BT_F64);
                        let t = rv.c as tt::TokenType;
                        let mut fop: str<'static> = "";
                        if t == tt::TokenType::EqualEqual {
                            fop = "!=";
                        } else if t == tt::TokenType::BangEqual {
                            fop = "==";
                        } else if !is_float {
                            if t == tt::TokenType::LessThan {
                                fop = ">=";
                            } else if t == tt::TokenType::GreaterThan {
                                fop = "<=";
                            } else if t == tt::TokenType::LessThanEqual {
                                fop = ">";
                            } else if t == tt::TokenType::GreaterThanEqual {
                                fop = "<";
                            }
                        }
                        if fop.len() != 0 {
                            // no enclosing parentheses: the caller wraps this in `if (..)`, and a
                            // second pair around an equality would trip -Wparentheses-equality
                            let mut bm = b.module;
                            let mut bt = TYPE_NONE;
                            let bref = self.bin_op_ty(b, rv.b, &mut bm, &mut bt);
                            let mut ok = self.emit_op_d(b, rv.a, aref, dst);
                            dst.push_str(" ");
                            dst.push_str(fop);
                            dst.push_str(" ");
                            if ok {
                                ok = self.emit_op_d(b, rv.b, bref, dst);
                            }
                            return ok;
                        }
                    }
                }
            }
        }
        dst.push_str("!(");
        let ok = self.emit_operand(b, opid, dst);
        dst.push_str(")");
        return ok;
    }

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
            if targs_len == 0 {
                // plain concrete call: no targ suffix, no demand record -- the symbol depends
                // only on the declaration (and mark_ctx, for the cross-TU edge), so memoize
                if self.sym_memo_ctx != self.mg.mark_ctx {
                    self.sym_memo.clear();
                    self.sym_memo_ctx = self.mg.mark_ctx;
                }
                let mk = skey_mix(0, callee.module as u64 << 32 | callee.node as u64);
                let hit9 = switch self.sym_memo.get(&mk) {
                    Some(s) => {
                        dst.push_str(s.as_str());
                        true;
                    },
                    None => false,
                };
                if hit9 {
                    return true;
                }
                let tgt0 = self.mg.method_target(callee.module, callee.node);
                if !self.mg.fn_sym(callee.module, callee.node, tgt0, true, &mut sym) {
                    return self.fail("callee-sym");
                }
                self.sym_memo.insert(mk, sym.clone());
                dst.push_string(&sym);
                return true;
            }
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
                // fingerprint of what the snapshot + suffix WOULD hold (env, receiver, targs):
                // duplicates skip the clone/snapshot entirely
                let mut dk9 = 1469598103934665603u64;
                {
                    let ss9 = sym.as_str();
                    for k9 in 0..ss9.len() {
                        dk9 = (dk9 ^ ss9.byte_at(k9) as u64) * 1099511628211u64;
                    }
                    for k9 in 0..self.mg.subs.len() {
                        let sb9 = *self.mg.subs.at(k9);
                        dk9 = (dk9 ^ (sb9.pm as u64 << 32 | sb9.pnode as u64)) * 1099511628211u64;
                        dk9 = (dk9 ^ (sb9.am as u64 << 32 | sb9.at as u64)) * 1099511628211u64;
                        dk9 = (dk9 ^ sb9.lim as u64) * 1099511628211u64;
                    }
                    if is_minst {
                        dk9 = (dk9 ^ (rpm as u64 << 32 | rit.module as u64)) * 1099511628211u64;
                        dk9 = (dk9 ^ (rit.decl as u64 << 32 | rit.n as u64)) * 1099511628211u64;
                        for k9 in 0..rit.n {
                            dk9 = (dk9 ^ (unsafe rit.args[k9 as usize]) as u64) * 1099511628211u64;
                        }
                    }
                    dk9 = (dk9 ^ (b.module as u64 << 32 | targs_len as u64)) * 1099511628211u64;
                    for k9 in 0..targs_len {
                        dk9 = (dk9 ^ b.targ_pool[(targs_start + k9) as usize] as u64) * 1099511628211u64;
                    }
                    if recv_targs {
                        dk9 = (dk9 ^ 1) * 1099511628211u64;
                    }
                }
                if self.demand_seen.contains(&dk9) {
                    if ok {
                        dst.push_string(&sym);
                    }
                    return ok;
                }
                self.demand_seen.insert(dk9);
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

    fn ref_cast_needed(self: &mut Self, b: &ir::CoreBody, target: TypeId, place: ir::PlaceId) bool {
        if target == TYPE_NONE {
            return false;
        }
        let mut tm = b.module;
        let mut tt9 = target;
        self.rty(b, target, &mut tm, &mut tt9);
        let ty = *self.p().module_ast_const(tm).type_at(tt9);
        if ty.kind != TypeKind::TYPE_REFERENCE && ty.kind != TypeKind::TYPE_POINTER {
            return true;
        }
        if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            return true;
        }
        let mut em = tm;
        let mut et = ty.as_data.elem;
        let _ = self.mg.resolve(tm, ty.as_data.elem, &mut em, &mut et);
        let mut pm = b.module;
        let mut pt = b.places.at(place as usize).ty;
        self.rty(b, pt, &mut pm, &mut pt);
        return em != pm || et != pt;
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
            if rv.kind == ir::RV_ADDR || self.ref_cast_needed(b, rv.target, rv.a) {
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
            // `&*p` is `p`: a place ending in a dereference cancels the address-of, so emit the place
            // with its trailing deref dropped and no `&`.
            let rpl = *b.places.at(rv.a as usize);
            if rpl.proj_len != 0 && b.projections.at((rpl.proj_start + rpl.proj_len - 1) as usize).kind == ir::PJ_DEREF {
                return self.emit_place_lim(b, rv.a, rpl.proj_len - 1, dst);
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
            if y.kind == TypeKind::TYPE_INSTANCE {
                let dai = self.p().module_ast_const(rm);
                let it = *dai.instance(y.as_data.inst);
                let iai = self.p().module_ast_const(it.module);
                let ns = iai.at_const(iai.at_const(it.decl).as_data.aggregate.name).as_data.name.text;
                let nm = self.p().modules.at(it.module as usize).source.as_str().slice(
                    ns.start as usize,
                    ns.end as usize,
                );
                if nm == "Slice" || nm == "SliceMut" {
                    dst.push_str("(");
                    let ok = self.emit_place(b, rv.a, dst);
                    dst.push_str(").len");
                    return ok;
                }
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
            // a payload enum's tag reads through `->` on the last dereference: `self->tag`, not
            // `(*self).tag`. A bare enum has no member, so its value stays a plain dereference.
            let payload = self.enum_has_payload(am, decl);
            let arrow = payload && derefs >= 1;
            let outer = if arrow {
                derefs - 1;
            } else {
                derefs;
            };
            for _d in 0..outer {
                dst.push_str("(*");
            }
            let ok = self.emit_place(b, rv.a, dst);
            for _d in 0..outer {
                dst.push_str(")");
            }
            if ok && arrow {
                dst.push_str("->tag");
            } else if ok && payload {
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
        if self.ext_backed.contains(&skey_mix(0, t.callee.module as u64 << 32 | t.callee.node as u64)) {
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
        let is_tuple = da.at_const(decl).as_data.aggregate.is_tuple;
        for i in 0..ms2.len {
            let fid = unsafe da.list(ms2)[i as usize];
            let fk = da.at_const(fid).kind;
            // tuple members are bare type nodes; type_of reads either uniformly
            if fk == NodeKind::NODE_FIELD || is_tuple {
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
            let is_tuple = da.at_const(decl).as_data.aggregate.is_tuple;
            for i in 0..ms.len {
                if !ok {
                    break;
                }
                let fid = unsafe da.list(ms)[i as usize];
                // tuple members are bare type nodes named `_i`; named members are NODE_FIELD
                if !is_tuple && da.at_const(fid).kind != NodeKind::NODE_FIELD {
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
                    if is_tuple {
                        fnm.push_str("_");
                        fnm.push_u64(i);
                    } else {
                        self.mg.ident(am, da.at_const(da.at_const(fid).as_data.field.name).as_data.name.text, &mut fnm);
                    }
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

    // The side effect of a terminator -- a drop's free, a call's statement, an assert's check, a
    // return's value, an unreachable abort -- with NO control transfer: the structured driver owns
    // every goto, break, continue, and fall-through. GOTO and SWITCH carry no effect here.
    fn emit_term_effect(self: &mut Self, b: &ir::CoreBody, t: &ir::Terminator) bool {
        if t.kind == ir::TM_GOTO {
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
                let mut pv = self.sget();
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
                    self.out.push_str("\n");
                }
                self.sput(pv);
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
                        self.out.push_str("\n");
                    }
                    return ok9;
                }
            }
            if y.kind == TypeKind::TYPE_FUNCTION {
                // a closure value's captures are freed by ITS OWN body on the (exactly-once) call
                // -- a drop of the value itself owns nothing further
                return true;
            }
            if y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE {
                let mut fs = self.sget();
                if !self.mg.free_target(rm, rt, &mut fs) {
                    self.sput(fs);
                    return self.fail("drop");
                }
                if self.collect_demand {
                    self.note_free(rm, rt, fs.as_str());
                }
                let mut pv = self.sget();
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
                    self.out.push_str("\n");
                }
                self.sput(fs);
                self.sput(pv);
                return ok;
            }
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
                    self.out.push_str(" = ");
                    if *self.sx_inline.at(r as usize) != ir::IR_NONE {
                        let mut ev = String::new();
                        if !self.emit_rvalue(b, *self.sx_inline.at(r as usize), &mut ev) {
                            return false;
                        }
                        self.out.push_string(&ev);
                    } else {
                        self.out.push_str("_");
                        self.out.push_u64(r);
                    }
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
            if self.assert_holds_const(b, t) {
                return true;
            }
            let src = self.p().modules.at(b.module as usize).source.as_str();
            let file = self.p().modules.at(b.module as usize).file.as_str();
            let line = self.src_line(b.module, t.span.start);
            let mut handled = false;
            if !self.emit_forwarded_assert(b, t, line, &mut handled) {
                return false;
            }
            if handled {
                return true;
            }
            let mut cond = String::new();
            let mut ok = self.emit_cond_negated(b, t.a, &mut cond);
            if !ok {
                return false;
            }
            self.out.push_str("  if (");
            self.out.push_string(&cond);
            self.out.push_str(") { ");
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
            self.out.push_str("\\n\"); fflush(stderr); abort(); }\n");
            return true;
        }
        if t.kind == ir::TM_SWITCH {
            return true;
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
            // a forwarded destination: this call spells `f(..)` at its single read instead of storing
            // to a temporary, so it emits nothing here and builds the expression into sx_call_str.
            let mut fwd_r = ir::IR_NONE;
            if t.dests_len == 1 && b.places.at(b.dest_pool[t.dests_start as usize] as usize).proj_len == 0 {
                let rb = b.places.at(b.dest_pool[t.dests_start as usize] as usize).base;
                if *self.sx_call_fwd.at(rb as usize) {
                    fwd_r = rb;
                }
            }
            // destination analysis up front (no text): the common call then spells straight into
            // the output buffer, and only stashed/sliced/decl-fused forms build a side line
            let mut want = false;
            let mut arrdst = false; // fixed-array dest: `{ <sym>_ret __ar = f(..); memcpy(dst, __ar._a, ..); }`
            let mut fuse_sub = false;
            let mut droot: u32 = 0;
            if t.dests_len == 1 && fwd_r == ir::IR_NONE {
                let dp = b.dest_pool[t.dests_start as usize];
                let dty = b.places.at(dp as usize).ty;
                want = !self.is_unit(b, dty);
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
                if want && !arrdst {
                    let pl = *b.places.at(dp as usize);
                    droot = *self.sx_coal.at(pl.base as usize);
                    fuse_sub = pl.proj_len == 0 && *self.sx_fuse.at(droot as usize) && !*self.sx_declared.at(
                        droot as usize,
                    );
                }
            }
            let plain = fwd_r == ir::IR_NONE && !arrdst && !fuse_sub;
            let mut o = replace(&mut self.out, String::new());
            let mut line = self.sget();
            let mut dplace = self.sget();
            let mut ok = true;
            let mut cs_len: usize = 0;
            {
                let sink = if plain {
                    &mut o;
                } else {
                    &mut line;
                };
                if plain {
                    sink.push_str("  ");
                }
                if t.dests_len == 1 && fwd_r == ir::IR_NONE {
                    let dp = b.dest_pool[t.dests_start as usize];
                    if want && arrdst {
                        ok = self.emit_place(b, dp, &mut dplace);
                    } else if want {
                        if fuse_sub {
                            let mut lhs = self.sget();
                            ok = self.emit_place(b, dp, &mut lhs);
                            if ok {
                                let mut decl = self.sget();
                                let lty = b.locals.at(droot as usize).ty;
                                if lty == TYPE_NONE {
                                    ok = self.untyped_ret_struct(b, droot, &mut decl);
                                    if ok {
                                        decl.push_str("_ret ");
                                        decl.push_string(&lhs);
                                    }
                                } else {
                                    ok = self.ty_c(b.module, lty, lhs.as_str(), &mut decl);
                                }
                                if ok {
                                    self.sx_declared.set(droot as usize, true);
                                    sink.push_string(&decl);
                                }
                                self.sput(decl);
                            }
                            self.sput(lhs);
                        } else {
                            ok = self.emit_place(b, dp, sink);
                        }
                        sink.push_str(" = ");
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
                        ok = self.dyn_request(cmV, ctV);
                        if ok {
                            ok = self.emit_operand(b, t.a, sink);
                        }
                        sink.push_str(".vt->call");
                        dyn_val = true;
                    } else if cy.kind == TypeKind::TYPE_FUNCTION {
                        let cd = self.p().module_ast_const(cy.module).at_const(cy.as_data.decl);
                        if cd.kind == NodeKind::NODE_CLOSURE && cd.as_data.closure.captures.len != 0 {
                            self.mg.closure_sym(cy.module, cy.as_data.decl, sink);
                            env_first = true;
                        }
                    }
                    if ok && !env_first && !dyn_val {
                        ok = self.emit_operand(b, t.a, sink);
                    }
                } else if ok && dyn_recv != ir::IR_NONE {
                    ok = self.emit_operand(b, dyn_recv, sink);
                    sink.push_str(".vt->");
                    let ca0 = self.p().module_ast_const(t.callee.module);
                    self.mg.ident(
                        t.callee.module,
                        ca0.at_const(ca0.at_const(t.callee.node).as_data.function.name).as_data.name.text,
                        sink,
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
                    ok = self.callee_sym(b, t.callee, t.targs_start, t.targs_len, rty2, dty2, sink);
                }
                cs_len = sink.len();
                if ok {
                    sink.push_str("(");
                    if env_first {
                        sink.push_str("&");
                        ok = self.emit_operand(b, t.a, sink);
                        if t.args_len != 0 {
                            sink.push_str(", ");
                        }
                    }
                    if dyn_val {
                        ok = self.emit_operand(b, t.a, sink);
                        sink.push_str(".data");
                        if t.args_len != 0 {
                            sink.push_str(", ");
                        }
                    }
                    for i in 0..t.args_len {
                        if !ok {
                            break;
                        }
                        if dyn_recv != ir::IR_NONE && i == 0 {
                            // the erased receiver: its data pointer takes the self slot
                            ok = self.emit_operand(b, dyn_recv, sink);
                            sink.push_str(".data");
                            continue;
                        }
                        if i != 0 {
                            sink.push_str(", ");
                        }
                        let opid2 = b.oper_pool[(t.args_start + i) as usize];
                        ok = self.emit_call_arg(b, t.callee, i, opid2, sink);
                    }
                }
            }
            if ok && fwd_r != ir::IR_NONE {
                // `line` is `f(args` (no destination, no closing paren): close it and stash it for the
                // single read to spell. The call itself emits nothing here.
                line.push_str(")");
                let mut stored = String::new();
                stored.push_string(&line);
                let root = *self.sx_coal.at(fwd_r as usize);
                if root != fwd_r {
                    self.sx_call_str.set(root as usize, stored.clone());
                }
                self.sx_call_str.set(fwd_r as usize, stored);
            } else if ok && arrdst {
                o.push_str("  { ");
                o.push_str(line.as_str().slice(0, cs_len));
                o.push_str("_ret __ar = ");
                o.push_string(&line);
                o.push_str("); memcpy(");
                o.push_string(&dplace);
                o.push_str(", __ar._a, sizeof(__ar._a)); }\n");
            } else if ok && plain {
                o.push_str(");\n");
            } else if ok {
                o.push_str("  ");
                o.push_string(&line);
                o.push_str(");\n");
            }
            self.sput(line);
            self.sput(dplace);
            self.out = o;
            return ok;
        }
        if t.kind == ir::TM_ASSERT {
            let mut cnd = String::new();
            let mut msgv = String::new();
            let mut ok = self.emit_cond_negated(b, t.a, &mut cnd);
            if ok && t.args_len != 0 {
                ok = self.emit_operand(b, b.oper_pool[t.args_start as usize], &mut msgv);
            }
            if ok {
                let msrc = self.p().modules.at(b.module as usize).source.as_str();
                self.out.push_str("  if (");
                self.out.push_string(&cnd);
                self.out.push_str(") { ");
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
                let ln = self.src_line(b.module, t.span.start);
                self.out.push_u64(ln);
                self.out.push_str("\\n\"");
                if t.args_len != 0 {
                    self.out.push_str(", (int)__scm.len, (const char *)__scm.ptr");
                }
                self.out.push_str("); fflush(stderr); abort(); }\n");
            }
            return ok;
        }
        return self.fail("terminator");
    }
}

// FNV-1a hash of an identifier -- the key of the reserved-name set (dedup + O(1) lookup).
const fn ident_hash(s: str) u64 {
    let mut h = 1469598103934665603u64;
    for i in 0..s.len() {
        h = (h ^ s.byte_at(i) as u64) * 1099511628211u64;
    }
    return h;
}

// Insert every maximal C-identifier run in `s` into `out` (the typedef names inside a spelled type).
fn collect_idents(s: str, out: &mut Map<u64, u64>) {
    let mut i = 0 as usize;
    while i < s.len() {
        let c = s.byte_at(i);
        if c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 {
            let start = i;
            while i < s.len() {
                let d = s.byte_at(i);
                if d >= 48 && d <= 57 || d >= 65 && d <= 90 || d >= 97 && d <= 122 || d == 95 {
                    i += 1;
                } else {
                    break;
                }
            }
            out.insert(ident_hash(s.slice(start, i)), 1);
        } else {
            i += 1;
        }
    }
}

const fn ident_in(nm: str, v: &Map<u64, u64>) bool {
    return v.contains_key(&ident_hash(nm));
}

// collect_idents, but into a flat pool (the per-type reserved cache).
fn collect_ident_hashes(s: str, out: &mut Vector<u64>) {
    let mut i = 0 as usize;
    while i < s.len() {
        let c = s.byte_at(i);
        if c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 {
            let start = i;
            while i < s.len() {
                let d = s.byte_at(i);
                if d >= 48 && d <= 57 || d >= 65 && d <= 90 || d >= 97 && d <= 122 || d == 95 {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(ident_hash(s.slice(start, i)));
        } else {
            i += 1;
        }
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

const fn hexv(b: u8) u32 {
    if b >= 48 && b <= 57 {
        return b - 48;
    }
    if b >= 97 && b <= 102 {
        return b - 97 + 10;
    }
    if b >= 65 && b <= 70 {
        return b - 65 + 10;
    }
    return 0;
}

fn push_utf8(cp: u32, dst: &mut String) {
    if cp < 0x80 {
        dst.push_byte(cp as u8);
    } else if cp < 0x800 {
        dst.push_byte((0xC0 | cp >> 6) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else if cp < 0x10000 {
        dst.push_byte((0xE0 | cp >> 12) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    } else {
        dst.push_byte((0xF0 | cp >> 18) as u8);
        dst.push_byte((0x80 | cp >> 12 & 0x3F) as u8);
        dst.push_byte((0x80 | cp >> 6 & 0x3F) as u8);
        dst.push_byte((0x80 | cp & 0x3F) as u8);
    }
}

// A Super-C quoted/byte-string body (escapes intact) into a C string-literal body: decode each
// escape to its byte(s) -- `\xNN` is EXACTLY two hex digits and `\u{H..}` a codepoint (UTF-8) --
// then C-escape the raw bytes so C reads back the same value. A verbatim copy mis-handles both.
fn push_sc_str_c(raw: str, dst: &mut String) {
    let mut bytes = String::new();
    let mut i: usize = 0;
    while i < raw.len() {
        let b = raw.byte_at(i);
        if b != 92 || i + 1 >= raw.len() {
            bytes.push_byte(b);
            i += 1;
            continue;
        }
        let e = raw.byte_at(i + 1);
        i += 2;
        if e == b'n' {
            bytes.push_byte(10);
        } else if e == b'r' {
            bytes.push_byte(13);
        } else if e == b't' {
            bytes.push_byte(9);
        } else if e == b'0' {
            bytes.push_byte(0);
        } else if e == b'x' && i + 1 < raw.len() {
            bytes.push_byte((hexv(raw.byte_at(i)) << 4 | hexv(raw.byte_at(i + 1))) as u8);
            i += 2;
        } else if e == b'u' && i < raw.len() && raw.byte_at(i) == b'{' {
            i += 1;
            let mut cp: u32 = 0;
            while i < raw.len() && raw.byte_at(i) != b'}' {
                cp = cp << 4 | hexv(raw.byte_at(i));
                i += 1;
            }
            if i < raw.len() {
                i += 1;
            }
            push_utf8(cp, &mut bytes);
        } else {
            bytes.push_byte(e); // `\\`, `\"`, `\'`: the escaped byte itself
        }
    }
    push_c_escaped(bytes.as_str(), dst);
}

const fn if_s(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
