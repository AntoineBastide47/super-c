// Global-phase pipeline driver over a loaded Package: platform-filters items, runs resolve/typecheck/
// borrowck per module (each stage moves the module's Ast out and restores it, with Package.override_*
// bridging package lookups meanwhile), flushes deferred consteval errors, then prunes dead modules from
// the emit set and codegens each live module into <gen_root> in dependency order. Entry points:
// run_package (build/run/test) and lint_package (report-only lints + `--fix` fix collection).
import stdio;
import stdlib;
import driver_shim as shim;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import ast::facts as facts;
import ast::parser as par;
import fmt::builder as fbld;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import consteval::consteval as ce;
import codegen::codegen as cg;
import ir::core as irc;
import ir::lower as irl;
import ir::print as irp;
import ir::verify as irv;
import ir::drops as ird;
import ir::interp as iri;
import ir::layout as lay;
import backend::cemit as cbe;
import backend::mangle as mbe;
import backend::tu as tbe;
import graph::instances as ig;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;
import borrowck::explain as bex;
import utils::errors as diag;
import driver::util as *;

import driver::extc as *;
import driver::test as *;

// ---------------------------------------------------------------------------------------------------------
// Dead-module pruning of the emit set: a live module reaches its own decls + everything it references.
// ---------------------------------------------------------------------------------------------------------
const fn mark_live(live: *mut bool, n: usize, m: ModuleId) bool {
    if m as usize >= n || unsafe live[m as usize] {
        return false;
    }
    unsafe live[m as usize] = true;
    return true;
}

fn ast_type_mentions_builtin(p: &loader::Package, am: ModuleId, t: TypeId) bool {
    if t == TYPE_NONE {
        return false;
    }
    let y = *mod_ast_c(p, am).type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN {
        return true;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return ast_type_mentions_builtin(p, am, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *mod_ast_c(p, am).instance(y.as_data.inst);
        for i in 0..it.n {
            if ast_type_mentions_builtin(p, am, unsafe it.args[i as usize]) {
                return true;
            }
        }
        return false;
    }
    return false;
}

fn mark_type_modules(p: &loader::Package, am: ModuleId, t: TypeId, live: *mut bool) bool {
    if t == TYPE_NONE {
        return false;
    }
    let y = *mod_ast_c(p, am).type_at(t);
    let mut changed = false;
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        if mark_type_modules(p, am, y.as_data.elem, live) {
            changed = true;
        }
    } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION {
        if p.builtin_of_decl(y.module, y.as_data.decl) < 0 {
            if mark_live(live, p.modules.len(), y.module) {
                changed = true;
            }
        }
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *mod_ast_c(p, am).instance(y.as_data.inst);
        let np = p.modules.len();
        if it.module as usize < np {
            if mark_live(live, np, it.module) {
                changed = true;
            }
        }
        let home = p.instance_home_mid(am, &it);
        if home as usize < np {
            if mark_live(live, np, home) {
                changed = true;
            }
        }
        for i in 0..it.n {
            if mark_type_modules(p, am, unsafe it.args[i as usize], live) {
                changed = true;
            }
            if p.core_seeded && ast_type_mentions_builtin(p, am, unsafe it.args[i as usize]) {
                if mark_live(live, np, p.core_module) {
                    changed = true;
                }
            }
        }
    }
    return changed;
}

fn compute_emit_live(p: &loader::Package) *mut bool {
    let n = p.modules.len();
    let sz = if n != 0 {
        n;
    } else {
        1 as usize;
    };
    let live = (unsafe stdlib::calloc(sz, 1)) as *mut bool;
    if live == null {
        return null;
    }
    for i in 0..n {
        if !p.modules[i].prelude {
            unsafe live[i] = true;
        }
    }
    let mut changed = true;
    while changed {
        changed = false;
        for m in 0..n {
            if !unsafe live[m] || !p.modules[m].has_ast {
                continue;
            }
            let a = mod_ast_c(p, m as ModuleId);
            let nr = a.resolutions_len();
            for r in 0..nr {
                let d = a.resolution_def(r as NodeId);
                if d.node != NODE_NONE && d.module as usize < n && d.module as usize != m && p.builtin_of_decl(
                    d.module,
                    d.node,
                ) < 0 {
                    if mark_live(live, n, d.module) {
                        changed = true;
                    }
                }
            }
            let nt = unsafe a.type_pool.len();
            for ti in 0..nt {
                if mark_type_modules(p, m as ModuleId, ti as TypeId, live) {
                    changed = true;
                }
            }
            let ni = unsafe a.instances.len();
            for ii in 0..ni {
                let it = *a.instance(ii as u32);
                if it.module as usize < n {
                    if mark_live(live, n, it.module) {
                        changed = true;
                    }
                }
                let home = p.instance_home_mid(m as ModuleId, &it);
                if home as usize < n {
                    if mark_live(live, n, home) {
                        changed = true;
                    }
                }
                for k in 0..it.n {
                    if mark_type_modules(p, m as ModuleId, unsafe it.args[k as usize], live) {
                        changed = true;
                    }
                    if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe it.args[k as usize]) {
                        if mark_live(live, n, p.core_module) {
                            changed = true;
                        }
                    }
                }
            }
            let nmo = unsafe a.mono.len();
            for moi in 0..nmo {
                let mu = unsafe a.mono[moi];
                for k in 0..mu.n {
                    if mark_type_modules(p, m as ModuleId, unsafe mu.args[k as usize], live) {
                        changed = true;
                    }
                    if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe mu.args[k as usize]) {
                        if mark_live(live, n, p.core_module) {
                            changed = true;
                        }
                    }
                }
            }
            let nmi = unsafe a.method_insts.len();
            for xi in 0..nmi {
                let miu = unsafe a.method_insts[xi];
                if mark_type_modules(p, m as ModuleId, miu.instance, live) {
                    changed = true;
                }
                for k in 0..miu.n {
                    if mark_type_modules(p, m as ModuleId, unsafe miu.targs[k as usize], live) {
                        changed = true;
                    }
                    if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe miu.targs[k as usize]) {
                        if mark_live(live, n, p.core_module) {
                            changed = true;
                        }
                    }
                }
            }
        }
    }
    return live;
}

// ---------------------------------------------------------------------------------------------------------
// Pipeline stages over one module (move the Ast out of its slot, run, and restore it).
// ---------------------------------------------------------------------------------------------------------
// `fixes != null` = `lint --fix`: machine-applicable fixes are drained into it and warning output is
// suppressed (the fix loop re-lints and the final plain pass prints what remains).
fn resolve_module(p: &mut loader::Package, i: usize, lint: bool, fixes: *mut Vector<diag::LintFix>) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut r = resolver::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    p.set_override(i as ModuleId, &mut r.ast);
    r.resolve();
    p.clear_override(i as ModuleId);
    let had = r.has_errors();
    if had || fixes == null && r.errors.has_warnings() {
        r.log_errors();
    }
    p.lint_warnings = p.lint_warnings + r.errors.warns.len() as u32;
    p.lint_errs = p.lint_errs + r.errors.errors.len() as u32;
    if fixes != null {
        for k in 0..r.errors.fixes.len() {
            let mut f = r.errors.fixes[k];
            f.module = i as u32;
            fixes.push(f);
        }
    }
    let back = r.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// Cross-module reflection-bound obligations: discharged once every module is typechecked, so a
// callee's obligations exist regardless of check order (module order follows imports, not calls).
fn discharge_obligations(p: &mut loader::Package, n: usize) {
    // Package-wide duplicate conformances first: a per-module concern, but only decidable once
    // every module is typechecked, like the obligations below.
    for i in 0..n {
        let pkg = p as *mut loader::Package;
        let m = &mut p.modules[i];
        let src = m.source.as_str().ptr() as *const char;
        let len = m.source.len();
        let a = replace(&mut m.ast, Ast::new(0));
        let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
        p.set_override(i as ModuleId, t.ast.get());
        t.check_cross_module_dup_conformances();
        p.clear_override(i as ModuleId);
        if t.has_errors() {
            t.errors.finalize(str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
            t.log_errors();
            p.ok = false;
        }
        let back = t.take_ast();
        p.modules[i].ast = back;
    }
    // Pass k proves what pass k-1's re-deferrals made provable; the per-module cursors keep any
    // obligation from being run against a caller module twice. Chains are as deep as the module
    // graph at most, and the pass cap is a runaway backstop, not a real bound.
    let mut starts = Vector::<u32>::new();
    starts.resize_default(n);
    let mut pass = 0;
    loop {
        let mut ends = Vector::<u32>::new();
        for i in 0..n {
            ends.push((unsafe p.modules[i].ast.proj_obs).len() as u32);
        }
        let mut grew = false;
        for i in 0..n {
            let pkg = p as *mut loader::Package;
            let m = &mut p.modules[i];
            let src = m.source.as_str().ptr() as *const char;
            let len = m.source.len();
            let a = replace(&mut m.ast, Ast::new(0));
            let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
            p.set_override(i as ModuleId, t.ast.get());
            if t.discharge_foreign_obligations(starts.as_ptr()) {
                grew = true;
            }
            if t.discharge_conformance_obligations(starts.as_ptr(), ends.as_ptr()) {
                grew = true;
            }
            p.clear_override(i as ModuleId);
            if t.has_errors() {
                t.errors.finalize(str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
                t.log_errors();
                p.ok = false;
            }
            let back = t.take_ast();
            p.modules[i].ast = back;
        }
        starts.free();
        starts = ends;
        pass = pass + 1;
        if !grew || !p.ok || pass >= 16 {
            break;
        }
    }
    starts.free();
}

fn typecheck_module(
    p: &mut loader::Package,
    i: usize,
    lint: bool,
    fixes: *mut Vector<diag::LintFix>,
    ftexts: *mut Vector<String>,
) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    t.lint = lint;
    p.set_override(i as ModuleId, t.ast.get());
    t.check();
    p.clear_override(i as ModuleId);
    let had = t.has_errors();
    if had || fixes == null && t.errors.has_warnings() {
        t.log_errors();
    }
    p.lint_warnings = p.lint_warnings + t.errors.warns.len() as u32;
    p.lint_errs = p.lint_errs + t.errors.errors.len() as u32;
    p.lint_fixable = p.lint_fixable + t.errors.fixable_errs;
    if fixes != null {
        // kind-3 fixes index into the caller's shared fix_texts pool: rebase and copy the payloads
        let base = if ftexts != null {
            ftexts.len() as u32;
        } else {
            0u32;
        };
        for k in 0..t.errors.fixes.len() {
            let mut f = t.errors.fixes[k];
            if f.text != 0xFFFFFFFF {
                f.text = f.text + base;
            }
            f.module = i as u32;
            fixes.push(f);
        }
        if ftexts != null {
            for k in 0..t.errors.fix_texts.len() {
                ftexts.push(t.errors.fix_texts.at(k).clone());
            }
        }
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// Borrow-check module `i`, serially: the pipeline stage after typechecking. A fresh TypeChecker context
// over the typed AST carries the recorded types and resolutions; only the borrow/move/lifetime analyses
// run. This is the one-module primitive borrowck_all falls back to; it may not run while any pool is
// frozen or any other module's checker is live.
// Dev gate (SC_FACTS_CHECK=1): snapshot every module's semantic-table watermarks right after
// type checking, assert that borrow checking changed nothing, and report post-codegen arena growth
// against the documented allowlist (see ast::facts). Off (empty snapshot) without the env var.
fn facts_snapshot(p: &loader::Package, out: &mut Vector<facts::FactsWatermark>) {
    if stdlib::getenv("SC_FACTS_CHECK") == null {
        return;
    }
    for i in 0..p.modules.len() {
        out.push(facts::watermark(&p.modules[i].ast));
    }
}

// Compare the snapshot against the live tables; returns the number of changed tables (0 when the
// snapshot is empty, i.e. the gate is off). `allow_arenas` selects the codegen allowlist.
fn facts_verify(p: &loader::Package, wms: &Vector<facts::FactsWatermark>, mode: u8, stage: str) u32 {
    if wms.len() == 0 {
        return 0;
    }
    let mut d: u32 = 0;
    for i in 0..p.modules.len() {
        if i < wms.len() {
            d += facts::watermark_check(&p.modules[i].ast, wms.at(i), i as u32, mode);
        }
    }
    if d != 0 {
        eprint("facts-check: stage '{}' changed semantic type-check tables\n", stage);
    }
    return d;
}

// ---------------------------------------------------------------------------------------------------------
// Development mode (SC_CORE_IR=1): after borrow checking, lower every function, method,
// closure, and constant body to Core IR and run the structural verifier. Reports bodies/failures,
// lowering time, and retained bytes; failures name the module, node, and first unsupported reason.
// SC_CORE_IR=print additionally dumps each body's deterministic text form to stderr.
// ---------------------------------------------------------------------------------------------------------

struct CoreIrStats {
    pub bodies: u64,
    pub failed: u64,
    pub blocks: u64,
    pub stmts: u64,
    pub bytes: u64,
    pub print_all: bool,
}

fn core_ir_body(p: &loader::Package, m: usize, node: NodeId, is_const: bool, st: &mut CoreIrStats) {
    let mut lw = irl::Lowerer::new(p, m as ModuleId, node);
    let ok = if is_const {
        lw.lower_const(node);
    } else {
        lw.lower_fn(node);
    };
    st.bodies += 1;
    if !ok {
        st.failed += 1;
        let mut snip = "";
        if lw.err_node != NODE_NONE {
            let a2 = unsafe &*p.module_ast_const(m as ModuleId);
            let esp = a2.at_const(lw.err_node).span;
            let src = p.modules.at(m).source.as_str();
            let mut e2 = esp.end as usize;
            if e2 > esp.start as usize + 48 {
                e2 = esp.start as usize + 48;
            }
            if e2 > src.len() {
                e2 = src.len();
            }
            snip = src.slice(esp.start as usize, e2);
        }
        let mut ek: u32 = 0;
        if lw.err_node != NODE_NONE {
            let a3 = unsafe &*p.module_ast_const(m as ModuleId);
            ek = a3.at_const(lw.err_node).kind as u32;
        }
        eprint("core-ir: module {} node {}: {} k{} `{}`\n", m, node, lw.err, ek, snip);
        return;
    }
    let tp = unsafe (&*p.module_ast_const(m as ModuleId)).type_pool.len();
    let v = irv::verify(&lw.body, tp);
    if v.len() != 0 {
        st.failed += 1;
        eprint("core-ir: module {} node {}: verify: {}\n", m, node, v);
        let dump = irp::print_body(&lw.body);
        dump.eprintln();
        return;
    }
    st.blocks += lw.body.blocks.len() as u64;
    st.stmts += lw.body.statements.len() as u64;
    st.bytes += lw.body.retained_bytes() as u64;
    if st.print_all {
        let dump = irp::print_body(&lw.body);
        dump.eprintln();
    }
    // Closures lower as their own bodies against the parent's capture environment.
    for c in 0..lw.closures.len() {
        let cn = lw.closures[c];
        let mut cl = irl::Lowerer::new(p, m as ModuleId, cn);
        let cok = cl.lower_closure_body(cn);
        st.bodies += 1;
        if !cok {
            st.failed += 1;
            eprint("core-ir: module {} closure {}: {}\n", m, cn, cl.err);
        } else {
            let cv = irv::verify(&cl.body, tp);
            if cv.len() != 0 {
                st.failed += 1;
                eprint("core-ir: module {} closure {}: verify: {}\n", m, cn, cv);
            } else {
                st.blocks += cl.body.blocks.len() as u64;
                st.stmts += cl.body.statements.len() as u64;
                st.bytes += cl.body.retained_bytes() as u64;
            }
        }
    }
}

fn core_ir_pass(p: &mut loader::Package) u32 {
    let mode = stdlib::getenv("SC_CORE_IR");
    if mode == null {
        return 0;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut st = CoreIrStats { bodies: 0, failed: 0, blocks: 0, stmts: 0, bytes: 0, print_all: false };
    let ms = diag::cstr(mode);
    st.print_all = ms == "print";
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let n = a.at_const(nid);
            if n.kind == NodeKind::NODE_FUNCTION {
                if !n.as_data.function.is_extern && n.as_data.function.body != NODE_NONE {
                    core_ir_body(p, m, nid, false, &mut st);
                }
            } else if n.kind == NodeKind::NODE_CONST {
                if !n.as_data.const_def.is_extern && n.as_data.const_def.value != NODE_NONE {
                    core_ir_body(p, m, nid, true, &mut st);
                }
            } else if n.kind == NodeKind::NODE_EXTEND {
                let inner = n.as_data.extend_def.items;
                for j in 0..inner.len {
                    let iid = unsafe a.list(inner)[j as usize];
                    let it = a.at_const(iid);
                    if it.kind == NodeKind::NODE_FUNCTION && it.as_data.function.body != NODE_NONE {
                        core_ir_body(p, m, iid, false, &mut st);
                    } else if it.kind == NodeKind::NODE_CONST && it.as_data.const_def.value != NODE_NONE {
                        core_ir_body(p, m, iid, true, &mut st);
                    }
                }
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "core-ir: {} bodies, {} failed, {} blocks, {} stmts, {} KiB retained, {} ms\n",
        st.bodies,
        st.failed,
        st.blocks,
        st.stmts,
        st.bytes / 1024,
        dt,
    );
    return st.failed as u32;
}

// Differential mode (SC_BORROW_IR=1): run the Core IR loan analysis over every lowered body while
// the established AST checker stays authoritative. The corpus gate is zero reports here -- anything
// printed is either a false reject to fix or a reviewed precision case. SC_BORROW_IR=ref also runs
// the reference solver per body and compares required-point sets.
struct BorrowIrStats {
    pub bodies: u64,
    pub skipped: u64, // failed to lower (already counted by SC_CORE_IR)
    pub move_errs: u64,
    pub loan_errs: u64,
    pub ref_diffs: u64,
    pub ms_facts: u64,
    pub ms_solve: u64,
    pub s: bln::Stats,
}

fn borrow_ir_body(
    p: &loader::Package,
    ow: &mut bfx::Owner,
    m: usize,
    node: NodeId,
    is_const: bool,
    st: &mut BorrowIrStats,
    run_ref: bool,
) {
    let mut lw = irl::Lowerer::new(p, m as ModuleId, node);
    let ok = if is_const {
        lw.lower_const(node);
    } else {
        lw.lower_fn(node);
    };
    if !ok {
        st.skipped += 1;
        return;
    }
    borrow_ir_run(p, ow, m, &lw.body, st, run_ref);
    for c in 0..lw.closures.len() {
        let cn = lw.closures[c];
        let mut cl = irl::Lowerer::new(p, m as ModuleId, cn);
        if cl.lower_closure_body(cn) {
            borrow_ir_run(p, ow, m, &cl.body, st, run_ref);
        } else {
            st.skipped += 1;
        }
    }
}

fn borrow_ir_run(
    p: &loader::Package,
    ow: &mut bfx::Owner,
    m: usize,
    body: &irc::CoreBody,
    st: &mut BorrowIrStats,
    run_ref: bool,
) {
    st.bodies += 1;
    let t0 = unsafe shim::sc_ticks_ms();
    let forest = bmp::MoveForest::build(body);
    let bfacts = bfx::generate(ow, body, &forest);
    let cfg = bdf::build_cfg(body);
    let lv = bdf::solve_liveness(&bfacts, &cfg);
    let t1 = unsafe shim::sc_ticks_ms();
    let mv = bdf::solve_moves(body, &forest, &bfacts, &cfg);
    let sv = bln::solve(body, &bfacts, &cfg, &lv);
    let t2 = unsafe shim::sc_ticks_ms();
    st.ms_facts += (t1 - t0) as u64;
    st.ms_solve += (t2 - t1) as u64;
    bln::stats_add(&mut st.s, &sv.stats);
    // Deduplicate by (kind, source position): loops replay blocks, defers duplicate statements.
    let mut seen = Vector::<u64>::new();
    for e in 0..mv.errs.len() {
        let er = *mv.errs.at(e);
        let key = er.kind as u64 << 32 | er.span.start as u64;
        let mut dup = false;
        for k in 0..seen.len() {
            if seen[k] == key {
                dup = true;
            }
        }
        if dup {
            continue;
        }
        seen.push(key);
        st.move_errs += 1;
        let line = bex::render_move(p, m as ModuleId, er.kind, er.span);
        eprint("borrow-ir: module {} node {}: ", m, body.owner.node);
        line.eprintln();
    }
    if sv.errs.len() != 0 && stdlib::getenv("SC_BORROW_TRACE") != null {
        for li in 0..bfacts.loans.len() {
            let lo = *bfacts.loans.at(li);
            let pl = *body.places.at(lo.place as usize);
            eprint(
                "  loan {} kind {} base {} storage {} projs {} origin {} issued {} act {}\n",
                li,
                lo.kind,
                pl.base,
                body.locals.at(pl.base as usize).storage,
                pl.proj_len,
                lo.origin,
                lo.issued_at,
                lo.activated_at,
            );
        }
        for e2 in 0..sv.errs.len() {
            let er2 = *sv.errs.at(e2);
            eprint("  err kind {} loan {} point {}\n", er2.kind, er2.loan, er2.point);
        }
        eprint(
            "  origins {} uni {} subsets {} uniflows {}\n",
            bfacts.norigins,
            bfacts.nuniversal,
            bfacts.subsets.len(),
            bfacts.uni_flows.len(),
        );
        for si in 0..bfacts.subsets.len() {
            let sb = *bfacts.subsets.at(si);
            eprint("  sub {} -> {} @{}\n", sb.from, sb.to, sb.point);
        }
    }
    for e in 0..sv.errs.len() {
        let er = *sv.errs.at(e);
        let key = 0x8000000000000000u64 | er.kind as u64 << 32 | er.span.start as u64;
        let mut dup = false;
        for k in 0..seen.len() {
            if seen[k] == key {
                dup = true;
            }
        }
        if dup {
            continue;
        }
        seen.push(key);
        st.loan_errs += 1;
        let line = bex::render(p, m as ModuleId, &bfacts, &er);
        eprint("borrow-ir: module {} node {}: ", m, body.owner.node);
        line.eprintln();
    }
    seen.free();
    if run_ref && bfacts.npoints < 2000 {
        let rr = bln::solve_reference(body, &bfacts, &cfg, &lv);
        // Compare required-point sets loan by loan against a fresh optimized run.
        let mut sv2 = bln::solve(body, &bfacts, &cfg, &lv);
        for li in 0..bfacts.loans.len() {
            let row = sv2.required_row(li as u32);
            for w in 0..rr.pwords {
                if *rr.required.at((li as u32 * rr.pwords + w) as usize) != sv2.req_word(row, w) {
                    st.ref_diffs += 1;
                    eprint("borrow-ir: module {} node {}: ref-solver mismatch loan {}\n", m, body.owner.node, li);
                    break;
                }
            }
        }
    }
}

fn borrow_ir_pass(p: &mut loader::Package) u32 {
    let mode = stdlib::getenv("SC_BORROW_IR");
    if mode == null {
        return 0;
    }
    let run_ref = diag::cstr(mode) == "ref";
    let t0 = unsafe shim::sc_ticks_ms();
    let mut ow = bfx::Owner::new(p);
    let mut st = BorrowIrStats {
        bodies: 0,
        skipped: 0,
        move_errs: 0,
        loan_errs: 0,
        ref_diffs: 0,
        ms_facts: 0,
        ms_solve: 0,
        s: bln::stats_zero(),
    };
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let n = a.at_const(nid);
            if n.kind == NodeKind::NODE_FUNCTION {
                if !n.as_data.function.is_extern && n.as_data.function.body != NODE_NONE {
                    borrow_ir_body(p, &mut ow, m, nid, false, &mut st, run_ref);
                }
            } else if n.kind == NodeKind::NODE_CONST {
                if !n.as_data.const_def.is_extern && n.as_data.const_def.value != NODE_NONE {
                    borrow_ir_body(p, &mut ow, m, nid, true, &mut st, run_ref);
                }
            } else if n.kind == NodeKind::NODE_EXTEND {
                let inner = n.as_data.extend_def.items;
                for j in 0..inner.len {
                    let iid = unsafe a.list(inner)[j as usize];
                    let it = a.at_const(iid);
                    if it.kind == NodeKind::NODE_FUNCTION && it.as_data.function.body != NODE_NONE {
                        borrow_ir_body(p, &mut ow, m, iid, false, &mut st, run_ref);
                    } else if it.kind == NodeKind::NODE_CONST && it.as_data.const_def.value != NODE_NONE {
                        borrow_ir_body(p, &mut ow, m, iid, true, &mut st, run_ref);
                    }
                }
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "borrow-ir: {} bodies ({} skipped), {} move-errs, {} loan-errs, {} ref-diffs, {} ms ({} facts, {} solve)\n",
        st.bodies,
        st.skipped,
        st.move_errs,
        st.loan_errs,
        st.ref_diffs,
        dt,
        st.ms_facts,
        st.ms_solve,
    );
    eprint(
        "borrow-ir: origins {} (uni {}), loans {}, points {}, cfg-edges {}, subsets {}, kills {}, activations {}, accesses {}\n",
        st.s.origins,
        st.s.universals,
        st.s.loans,
        st.s.points,
        st.s.cfg_edges,
        st.s.subset_facts,
        st.s.kill_facts,
        st.s.activation_facts,
        st.s.access_facts,
    );
    eprint(
        "borrow-ir: candidates {}, clean {}, queries {} (hits {}), steps {}, loanset-KiB {}, scratch-KiB {}\n",
        st.s.candidates,
        st.s.clean_bodies,
        st.s.queries,
        st.s.cache_hits,
        st.s.steps,
        st.s.loanset_bytes / 1024,
        st.s.scratch_bytes / 1024,
    );
    ow.free();
    return (st.move_errs + st.loan_errs + st.ref_diffs) as u32;
}

// Comparison mode (SC_DROPS=1): elaborate destruction over every lowered body, rewrite the bodies
// with explicit drop terminators (verified), and stash the schedule; after (serial) codegen the
// emitter's recorded free sequence must match it per function.
struct DropsStats {
    pub bodies: u64,
    pub skipped: u64,
    pub drops: u64,
    pub cond: u64,
    pub fields: u64,
    pub planned_fns: u64,
}

fn drops_body(p: &mut loader::Package, ow: &mut bfx::Owner, m: usize, node: NodeId, st: &mut DropsStats) {
    let mut lw = irl::Lowerer::new(p, m as ModuleId, node);
    if !lw.lower_fn(node) {
        st.skipped += 1;
        return;
    }
    st.bodies += 1;
    let forest = bmp::MoveForest::build(&lw.body);
    let bfacts = bfx::generate(ow, &lw.body, &forest);
    let cfg = bdf::build_cfg(&lw.body);
    let mv = bdf::solve_moves(&lw.body, &forest, &bfacts, &cfg);
    let sched = ird::elaborate(ow, &lw.body, &forest, &bfacts, &mv);
    let mut plan = false;
    {
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        if a.at_const(node).kind == NodeKind::NODE_FUNCTION && a.at_const(node).as_data.function.generics.len == 0 {
            plan = sched.concrete;
        }
    }
    let mut ordered = Vector::<u64>::new(); // stmt << 33 | cond << 32 | decl
    for d in 0..sched.drops.len() {
        let da = *sched.drops.at(d);
        let dty = lw.body.locals.at(da.local as usize).ty;
        p.drop_tys.push(m as u64 << 32 | dty as u64);
        st.drops += 1;
        if da.kind == ird::DK_COND {
            st.cond += 1;
        }
        if da.kind == ird::DK_FIELD {
            st.fields += 1;
            continue;
        }
        if plan {
            let decl = lw.body.locals.at(da.local as usize).decl;
            let mut cond: u64 = 0;
            if da.kind == ird::DK_COND {
                cond = 1;
            }
            ordered.push(da.stmt as u64 << 33 | cond << 32 | decl as u64);
        }
    }
    // Statements append in lowering (= source) order; block indexes do not.
    for i in 1..ordered.len() {
        let v = ordered[i];
        let mut j = i;
        while j > 0 && ordered[j - 1] > v {
            ordered.set(j, ordered[j - 1]);
            j -= 1;
        }
        ordered.set(j, v);
    }
    for i in 0..ordered.len() {
        let v = ordered[i];
        p.drop_plan.push(
            loader::DropRec {
                mid: m as ModuleId,
                fnode: node,
                decl: (v & 0xFFFFFFFFu64) as NodeId,
                cond: (v >> 32 & 1u64) as u8,
            },
        );
    }
    ordered.free();
    if plan {
        st.planned_fns += 1;
    }
    // The rewrite must stay verifiable Core IR.
    ird::insert_drops(&mut lw.body, &sched);
    let tp = unsafe (&*p.module_ast_const(m as ModuleId)).type_pool.len();
    let v = irv::verify(&lw.body, tp);
    if v.len() != 0 {
        eprint("drops: module {} node {}: verify after insertion: {}\n", m, node, v);
    }
}

fn drops_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_DROPS") == null {
        return;
    }
    p.drops_on = true;
    let t0 = unsafe shim::sc_ticks_ms();
    let mut ow = bfx::Owner::new(p);
    let mut st = DropsStats { bodies: 0, skipped: 0, drops: 0, cond: 0, fields: 0, planned_fns: 0 };
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let n = a.at_const(nid);
            if n.kind == NodeKind::NODE_FUNCTION {
                if !n.as_data.function.is_extern && n.as_data.function.body != NODE_NONE {
                    drops_body(p, &mut ow, m, nid, &mut st);
                }
            } else if n.kind == NodeKind::NODE_EXTEND {
                let inner = n.as_data.extend_def.items;
                for j in 0..inner.len {
                    let iid = unsafe a.list(inner)[j as usize];
                    let it = a.at_const(iid);
                    if it.kind == NodeKind::NODE_FUNCTION && it.as_data.function.body != NODE_NONE {
                        drops_body(p, &mut ow, m, iid, &mut st);
                    }
                }
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "drops: {} bodies ({} skipped), {} drops ({} cond, {} field), {} planned fns, {} ms\n",
        st.bodies,
        st.skipped,
        st.drops,
        st.cond,
        st.fields,
        st.planned_fns,
        dt,
    );
    ow.free();
}

// Compare the emitter's recorded free sequence against the elaboration schedule, per function.
fn drops_compare(p: &loader::Package) {
    let mut fns = Vector::<u64>::new();
    for i in 0..p.drop_plan.len() {
        let r = p.drop_plan.at(i);
        let key = r.mid as u64 << 32 | r.fnode as u64;
        let mut have = false;
        for k in 0..fns.len() {
            if fns[k] == key {
                have = true;
            }
        }
        if !have {
            fns.push(key);
        }
    }
    let mut compared: u64 = 0;
    let mut mismatched: u64 = 0;
    let mut shown: u32 = 0;
    for k in 0..fns.len() {
        let key = fns[k];
        let mid = (key >> 32) as ModuleId;
        let fnode = (key & 0xFFFFFFFFu64) as NodeId;
        // The emitter only logs functions it actually emitted (dead code prunes).
        let mut old_n: usize = 0;
        for i in 0..p.drop_log.len() {
            if p.drop_log.at(i).mid == mid && p.drop_log.at(i).fnode == fnode {
                old_n += 1;
            }
        }
        if old_n == 0 {
            continue;
        }
        compared += 1;
        // The emitter guards a binding with ONE flag for the whole function, so it may emit a
        // guarded free where exact per-point analysis omits (the flag is false there) or keeps an
        // unconditional drop (the flag is true there). Both are behaviorally identical; only an
        // UNGUARDED emitter free the plan lacks, a plan entry the emitter lacks, or an order
        // difference is a real mismatch.
        let mut bad = false;
        let mut oi: usize = 0;
        for i in 0..p.drop_plan.len() {
            let pr = *p.drop_plan.at(i);
            if pr.mid != mid || pr.fnode != fnode {
                continue;
            }
            // A pattern-bound payload's destruction reaches the emitter as a scrutinee-temp
            // free (which the recorder cannot attribute); such plan entries are soft.
            let mut soft = false;
            {
                let a2 = unsafe &*p.module_ast_const(mid);
                let dk = a2.at_const(pr.decl).kind;
                if dk != NodeKind::NODE_LET && dk != NodeKind::NODE_PARAMETER {
                    soft = true;
                }
            }
            let mut hit = false;
            let save = oi;
            while oi < p.drop_log.len() && !hit {
                let orr = *p.drop_log.at(oi);
                oi += 1;
                if orr.mid != mid || orr.fnode != fnode {
                    continue;
                }
                if orr.decl == pr.decl && (pr.cond == 0 || orr.cond == 1) {
                    hit = true;
                } else if orr.cond == 1 {
                    continue; // guarded free of a value the plan knows is gone here
                } else if soft {
                    oi = save;
                    hit = true; // unmatched soft entry: leave the emitter record for its own match
                } else {
                    bad = true;
                    hit = true;
                }
            }
            if !hit && !soft {
                bad = true;
            }
        }
        // The emitter also prints frees on unreachable lexical exits (after an endless loop);
        // a leftover free of a binding the plan already destroyed elsewhere is benign.
        while oi < p.drop_log.len() {
            let orr = *p.drop_log.at(oi);
            oi += 1;
            if orr.mid != mid || orr.fnode != fnode || orr.cond != 0 {
                continue;
            }
            let mut planned = false;
            for i in 0..p.drop_plan.len() {
                let pr = *p.drop_plan.at(i);
                if pr.mid == mid && pr.fnode == fnode && pr.decl == orr.decl {
                    planned = true;
                }
            }
            if !planned {
                bad = true;
            }
        }
        if bad {
            mismatched += 1;
            if shown < 12 {
                shown += 1;
                eprint("drops: mismatch module {} fn {} (emitter {} frees)\n", mid, fnode, old_n);
                let src = p.modules.at(mid as usize).source.as_str();
                let a = unsafe &*p.module_ast_const(mid);
                eprint("  emitter:");
                for i in 0..p.drop_log.len() {
                    let r = *p.drop_log.at(i);
                    if r.mid == mid && r.fnode == fnode {
                        let sp = a.at_const(r.decl).span;
                        let mut e2 = sp.end as usize;
                        if e2 > sp.start as usize + 16 {
                            e2 = sp.start as usize + 16;
                        }
                        eprint(" [{}]{}c{}", r.decl, src.slice(sp.start as usize, e2), r.cond);
                    }
                }
                eprint("\n  plan:   ");
                for i in 0..p.drop_plan.len() {
                    let r = *p.drop_plan.at(i);
                    if r.mid == mid && r.fnode == fnode {
                        let sp = a.at_const(r.decl).span;
                        let mut e2 = sp.end as usize;
                        if e2 > sp.start as usize + 16 {
                            e2 = sp.start as usize + 16;
                        }
                        eprint(" [{}]{}c{}", r.decl, src.slice(sp.start as usize, e2), r.cond);
                    }
                }
                eprint("\n");
            }
        }
    }
    eprint(
        "drops: {} fns compared, {} mismatched, {} emitter records, {} planned\n",
        compared,
        mismatched,
        p.drop_log.len(),
        p.drop_plan.len(),
    );
    fns.free();
}

// Comparison mode (SC_CTFE_IR=1): execute every constant initializer on Core IR and compare
// scalar folds against the established AST evaluator. Aggregates and features the interpreter
// refuses count as coverage gaps, never as matches.
fn ctfe_ir_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_CTFE_IR") == null {
        return;
    }
    let ceptr = p.ceval as *mut ce::ConstEval;
    if ceptr == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut consts: u64 = 0;
    let mut scalar: u64 = 0;
    let mut matched: u64 = 0;
    let mut unsupported: u64 = 0;
    let mut mism: u64 = 0;
    let mut aggs: u64 = 0;
    let mut agg_ok: u64 = 0;
    let mut newfolds: u64 = 0;
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let n = a.at_const(nid);
            if n.kind != NodeKind::NODE_CONST || n.as_data.const_def.is_extern || n.as_data.const_def.value == NODE_NONE {
                continue;
            }
            consts += 1;
            let old = unsafe (&mut *ceptr).eval(m as ModuleId, n.as_data.const_def.value);
            let omemo = unsafe (&*ceptr).memo_kind(m as ModuleId, n.as_data.const_def.value);
            let budget = unsafe (&*ceptr).max_steps;
            if old.kind != ce::CONST_INT && old.kind != ce::CONST_BOOL && old.kind != ce::CONST_FLOAT {
                let nv2 = iri::eval_const(p, m as ModuleId, nid, budget);
                if omemo == ce::CONST_AGG_OK {
                    // non-scalar success parity: the new path must also produce a value
                    aggs += 1;
                    if nv2.kind != iri::IV_NONE {
                        agg_ok += 1;
                    } else if stdlib::getenv("SC_BORROW_TRACE") != null {
                        let sp = n.span;
                        let src = p.modules[m].source.as_str();
                        let mut e2 = sp.end as usize;
                        if e2 > sp.start as usize + 60 {
                            e2 = sp.start as usize + 60;
                        }
                        eprint("ctfe-ir: agg-miss module {} `{}`\n", m, src.slice(sp.start as usize, e2));
                    }
                } else if nv2.kind != iri::IV_NONE {
                    // the established evaluator refused; folding here would be semantic drift
                    newfolds += 1;
                    if newfolds <= 8 {
                        let sp = n.span;
                        let src = p.modules[m].source.as_str();
                        let mut e2 = sp.end as usize;
                        if e2 > sp.start as usize + 60 {
                            e2 = sp.start as usize + 60;
                        }
                        eprint("ctfe-ir: new-folds module {} `{}`\n", m, src.slice(sp.start as usize, e2));
                    }
                }
                continue;
            }
            scalar += 1;
            let nv = iri::eval_const(p, m as ModuleId, nid, budget);
            if nv.kind == iri::IV_NONE {
                unsupported += 1;
                if stdlib::getenv("SC_BORROW_TRACE") != null {
                    let sp = n.span;
                    let src = p.modules[m].source.as_str();
                    let mut e2 = sp.end as usize;
                    if e2 > sp.start as usize + 60 {
                        e2 = sp.start as usize + 60;
                    }
                    eprint("ctfe-ir: unsupported module {} `{}`\n", m, src.slice(sp.start as usize, e2));
                }
                continue;
            }
            let mut ok = false;
            if old.kind == ce::CONST_INT && nv.kind == iri::IV_INT {
                ok = old.as_data.i == nv.i;
            } else if old.kind == ce::CONST_FLOAT && nv.kind == iri::IV_FLOAT {
                let of = old.as_data.f;
                ok = of == nv.f || of != of && nv.f != nv.f;
            } else if old.kind == ce::CONST_BOOL && nv.kind == iri::IV_BOOL {
                let mut oi: i64 = 0;
                if old.as_data.i != 0 {
                    oi = 1;
                }
                ok = oi == nv.i;
            }
            if ok {
                matched += 1;
            } else {
                mism += 1;
                if mism <= 12 {
                    let sp = n.span;
                    let src = p.modules[m].source.as_str();
                    let mut e2 = sp.end as usize;
                    if e2 > sp.start as usize + 40 {
                        e2 = sp.start as usize + 40;
                    }
                    eprint(
                        "ctfe-ir: mismatch module {} `{}`: old {} new {}\n",
                        m,
                        src.slice(sp.start as usize, e2),
                        old.as_data.i,
                        nv.i,
                    );
                }
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "ctfe-ir: {} consts, {} scalar, {} matched, {} unsupported, {} mismatched, {} ms\n",
        consts,
        scalar,
        matched,
        unsupported,
        mism,
        dt,
    );
    eprint("ctfe-ir: {} aggregate successes, {} reproduced, {} new-folds\n", aggs, agg_ok, newfolds);
}

// Validation mode (SC_LAYOUT=1): every concrete pool type must satisfy the C layout invariants --
// power-of-two alignment dividing the size, field offsets aligned, monotone, and inside the parent,
// and the enum view agreeing with the plain one.
fn layout_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_LAYOUT") == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut svc = lay::Svc::new(p);
    let mut typed: u64 = 0;
    let mut laid: u64 = 0;
    let mut fields: u64 = 0;
    let mut bad: u64 = 0;
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        for t in 0..a.type_pool.len() {
            let ty = t as TypeId;
            if !a.type_concrete(ty) {
                continue;
            }
            typed += 1;
            let l = svc.layout(m as ModuleId, ty);
            if !l.ok {
                continue; // opaque/zero-length/unlayoutable shapes are legitimate refusals
            }
            laid += 1;
            let mut ok = l.align != 0 && (l.align & l.align - 1) == 0 && l.size % l.align == 0;
            // struct fields: aligned, monotone, inside the parent
            let y = *a.type_at(ty);
            let mut dm: ModuleId = 0;
            let mut dn = NODE_NONE;
            if y.kind == TypeKind::TYPE_STRUCT {
                dm = y.module;
                dn = y.as_data.decl;
            } else if y.kind == TypeKind::TYPE_INSTANCE {
                let it = *a.instance(y.as_data.inst);
                dm = it.module;
                dn = it.decl;
            }
            if dn != NODE_NONE {
                let da = unsafe &*p.module_ast_const(dm);
                if da.at_const(dn).kind == NodeKind::NODE_STRUCT && !da.at_const(dn).as_data.aggregate.is_union {
                    let ms = da.at_const(dn).as_data.aggregate.members;
                    let mut prev: i64 = -1;
                    for k in 0..ms.len {
                        let fid = unsafe da.list(ms)[k as usize];
                        if da.at_const(fid).kind != NodeKind::NODE_FIELD {
                            continue;
                        }
                        let off = svc.field_offset(m as ModuleId, ty, fid);
                        if off < 0 {
                            continue;
                        }
                        fields += 1;
                        // zero-size members share offsets and may sit at the very end
                        if off < prev || off as u64 > l.size {
                            ok = false;
                        }
                        prev = off;
                    }
                } else if da.at_const(dn).kind == NodeKind::NODE_ENUM {
                    let el = svc.enum_layout(m as ModuleId, ty);
                    if el.ok && (el.size != l.size || el.align != l.align) {
                        ok = false;
                    }
                }
            }
            if !ok {
                bad += 1;
                if bad <= 8 {
                    eprint("layout: invariant violation module {} type {}\n", m, t);
                }
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "layout: {} concrete types, {} laid out, {} field offsets, {} violations, {} ms\n",
        typed,
        laid,
        fields,
        bad,
        dt,
    );
    svc.free();
}

// Coverage mode (SC_CEMIT=1): run the streaming C emitter over every lowered body, count the
// emittable subset, and verify two serial emissions hash identically.
fn cemit_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_CEMIT") == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut em = cbe::CEmit::new(p);
    let mut bodies: u64 = 0;
    let mut emitted: u64 = 0;
    let mut bytes: u64 = 0;
    let mut h1: u64 = 1469598103934665603u64;
    let mut h2: u64 = 1469598103934665603u64;
    let mut generic: u64 = 0;
    let mut reasons = Vector::<str<'static>>::new();
    let mut rcounts = Vector::<u64>::new();
    let mut cands = Vector::<NodeId>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let items = a.at_const(a.root).as_data.program.items;
        cands.truncate(0);
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let n = a.at_const(nid);
            if n.kind == NodeKind::NODE_FUNCTION {
                cands.push(nid);
            } else if n.kind == NodeKind::NODE_EXTEND {
                let ms = n.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid2 = unsafe a.list(ms)[j as usize];
                    if a.at_const(mid2).kind == NodeKind::NODE_FUNCTION {
                        cands.push(mid2);
                    }
                }
            }
        }
        for i in 0..cands.len() {
            let nid = cands[i];
            let n = a.at_const(nid);
            if n.as_data.function.is_extern || n.as_data.function.body == NODE_NONE {
                continue;
            }
            let mut lw = irl::Lowerer::new(p, m as ModuleId, nid);
            if !lw.lower_fn(nid) {
                continue;
            }
            if lw.body.is_generic || em.mg.in_generic_extend(m as ModuleId, nid) {
                generic += 1; // generic-extend methods emit per receiver instance, not standalone
                continue;
            }
            bodies += 1;
            let mut sym = String::new();
            let tgt = em.mg.method_target(m as ModuleId, nid);
            if !em.mg.fn_sym(m as ModuleId, nid, tgt, true, &mut sym) {
                sym.free();
                continue;
            }
            em.out.clear();
            if em.emit_fn(&lw.body, sym.as_str()) {
                emitted += 1;
                bytes += em.out.len() as u64;
                let s1 = em.out.as_str();
                for k in 0..s1.len() {
                    h1 = (h1 ^ s1.byte_at(k) as u64) * 1099511628211u64;
                }
                em.out.clear();
                let _ = em.emit_fn(&lw.body, sym.as_str());
                let s2 = em.out.as_str();
                for k in 0..s2.len() {
                    h2 = (h2 ^ s2.byte_at(k) as u64) * 1099511628211u64;
                }
            } else {
                let mut found = false;
                for r in 0..reasons.len() {
                    if reasons[r] == em.err {
                        rcounts.set(r, rcounts[r] + 1);
                        found = true;
                        break;
                    }
                }
                if !found {
                    reasons.push(em.err);
                    rcounts.push(1);
                }
            }
            sym.free();
        }
    }
    cands.free();
    let dt = unsafe shim::sc_ticks_ms() - t0;
    let mut det = "identical";
    if h1 != h2 {
        det = "DIVERGENT";
    }
    eprint(
        "cemit: {} bodies ({} generic skipped), {} emitted, {} KiB, serial hashes {}, {} ms\n",
        bodies,
        generic,
        emitted,
        bytes / 1024,
        det,
        dt,
    );
    for r in 0..reasons.len() {
        eprint("cemit-miss: {} x{}\n", reasons[r], rcounts[r]);
    }
    reasons.free();
    rcounts.free();
}

// SC_CEMIT_TU=1: the backend's declaration layer over the whole package -- every concrete
// aggregate plus every anchored instance from a fresh graph, forward typedefs then dependency-first
// definitions -- gated by a strict-C11 syntax-only compile of the emitted scratch TU.
fn cemit_tu_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_CEMIT_TU") == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut g = ig::InstGraph::new(p);
    g.collect();
    let mut em = tbe::TuEmit::new(p);
    let mut items = Vector::<tbe::AggItem>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            let n = a.at_const(nid);
            if (n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM) && n.as_data.aggregate.generics.len == 0 {
                items.push(tbe::AggItem { m: m as ModuleId, decl: nid, amod: m as ModuleId, aty: TYPE_NONE });
            }
        }
    }
    for r in 0..g.recs.len() {
        let rec = g.recs.at(r);
        if rec.kind == ig::IG_AGG && rec.aty != TYPE_NONE {
            items.push(tbe::AggItem { m: rec.def.module, decl: rec.def.node, amod: rec.amod, aty: rec.aty });
        }
    }
    for i in 0..items.len() {
        em.emit_fwd(items.at(i));
    }
    for i in 0..items.len() {
        let it = *items.at(i);
        let _ = em.emit_agg(&it);
    }
    let mut tu = String::from_str(
        "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n#include <stdarg.h>\n#include <complex.h>\n#include <stdio.h>\n#include <pthread.h>\ntypedef struct { const uint8_t *ptr; size_t len; } SCslice;\n",
    );
    tu.push_string(&em.out);
    let f = stdio::fopen("build/cemit_tu.c", "wb");
    let mut rc: i32 = -1;
    if f != null {
        let s = tu.as_str();
        let _ = unsafe stdio::fwrite(s.ptr(), 1, s.len(), f);
        unsafe stdio::fclose(f);
        rc = unsafe shim::sc_run(
            "cc -std=c11 -Wall -Werror -fsyntax-only build/cemit_tu.c".ptr() as *const char,
            null,
            null,
            null,
            null,
        );
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "cemit-tu: {} items, {} emitted, {} skipped, {} KiB, cc {}, {} ms\n",
        items.len(),
        em.emitted,
        em.skipped,
        tu.len() / 1024,
        rc,
        dt,
    );
    tu.free();
    items.free();
    em.free();
    g.free();
}

// Shadow mode (SC_INSTANCES=1): build the Core-IR instance graph after the established propagation
// and compare aggregate-instantiation sets both ways (package-stable keys). Report-only; the old
// propagation stays authoritative until drop-glue edges join the graph.
fn instance_graph_shadow(p: &mut loader::Package) {
    if stdlib::getenv("SC_INSTANCES") == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut g = ig::InstGraph::new(p);
    g.collect();
    // Scheduled destruction roots (SC_DROPS ran earlier) join the graph; collection reruns to a
    // fixed point so glue-reachable instances are first-class records.
    if p.drop_tys.len() != 0 {
        let before = g.recs.len();
        g.demand_drops();
        g.run();
        eprint("inst-graph: drop roots {} -> {} new records\n", p.drop_tys.len(), g.recs.len() - before);
    }
    let mut old = ig::InstGraph::new(p);
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        for i in 0..a.instances.len() {
            let it = *a.instance(i as u32);
            let da = unsafe &*p.module_ast_const(it.module);
            let dk = da.at_const(it.decl).kind;
            if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM {
                continue;
            }
            let mut args = Vector::<ig::ArgKey>::new();
            let mut conc = true;
            for k in 0..it.n {
                if !a.type_concrete(unsafe it.args[k]) {
                    conc = false;
                }
                args.push(ig::argkey_of(a, unsafe it.args[k]));
            }
            if !conc {
                continue;
            }
            let mut fresh = false;
            let _ = old.add(ig::IG_AGG, DefId { module: it.module, node: it.decl }, &args, &mut fresh);
        }
    }
    let new_n = g.recs.len();
    let old_n = old.recs.len();
    let mut n_fn: u32 = 0;
    let mut n_m: u32 = 0;
    for r in 0..new_n {
        if g.recs.at(r).kind == ig::IG_FN {
            n_fn += 1;
        } else if g.recs.at(r).kind == ig::IG_METHOD {
            n_m += 1;
        }
    }
    eprint("inst-graph: kinds: {} fn, {} method\n", n_fn, n_m);
    let mut missing: u32 = 0;
    let mut extra: u32 = 0;
    let mut aggs_new: u32 = 0;
    for r in 0..new_n {
        if g.recs.at(r).kind == ig::IG_AGG {
            aggs_new += 1;
        }
    }
    for r in 0..old_n {
        let rec = *old.recs.at(r);
        let mut args = Vector::<ig::ArgKey>::new();
        for k in 0..rec.args_len {
            args.push(*old.keys.at((rec.args_start + k) as usize));
        }
        let mut fresh = false;
        let _ = g.add(ig::IG_AGG, rec.def, &args, &mut fresh);
        if fresh {
            missing += 1;
            if stdlib::getenv("SC_INSTANCES_ALL") != null || missing <= 24 {
                let da = unsafe &*p.module_ast_const(rec.def.module);
                let nsp = da.at_const(da.at_const(rec.def.node).as_data.aggregate.name).as_data.name.text;
                let dsrc = p.modules.at(rec.def.module as usize).source.as_str();
                eprint(
                    "inst-graph: missing {} m{} n{} ({} args)\n",
                    dsrc.slice(nsp.start as usize, nsp.end as usize),
                    rec.def.module,
                    rec.def.node,
                    rec.args_len,
                );
            }
        }
    }
    for r in 0..new_n {
        let rec = *g.recs.at(r);
        if rec.kind != ig::IG_AGG {
            continue;
        }
        let mut args = Vector::<ig::ArgKey>::new();
        for k in 0..rec.args_len {
            args.push(*g.keys.at((rec.args_start + k) as usize));
        }
        let mut fresh = false;
        let _ = old.add(ig::IG_AGG, rec.def, &args, &mut fresh);
        if fresh {
            extra += 1;
            if extra <= 24 {
                let da = unsafe &*p.module_ast_const(rec.def.module);
                let nsp = da.at_const(da.at_const(rec.def.node).as_data.aggregate.name).as_data.name.text;
                let dsrc = p.modules.at(rec.def.module as usize).source.as_str();
                eprint(
                    "inst-graph: extra {} m{} n{} ({} args)\n",
                    dsrc.slice(nsp.start as usize, nsp.end as usize),
                    rec.def.module,
                    rec.def.node,
                    rec.args_len,
                );
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint(
        "inst-graph: {} old aggs, {} new aggs, {} missing, {} extra, {} records, {} bodies, {} ms{}\n",
        old_n,
        aggs_new,
        missing,
        extra,
        new_n,
        g.bodies,
        dt,
        if g.overflow {
            " (BUDGET OVERFLOW)";
        } else {
            "";
        },
    );
}

fn borrowck_module(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.set_override(i as ModuleId, t.ast.get());
    t.borrowck();
    p.clear_override(i as ModuleId);
    let had = t.has_errors();
    p.lint_errs = p.lint_errs + t.errors.errors.len() as u32;
    if had {
        t.log_errors();
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// Borrow-check every module, one worker per module on the coroutine pool. The stage is embarrassingly
// parallel EXCEPT that lowering interns types, so the discipline is: every in-flight Ast is published and
// every pool frozen serially BEFORE a worker runs (workers never write an override slot, and a frozen
// pool diverts its own worker's interns into module-local overflow -- see Ast.pool_frozen); each worker
// folds constants through a private evaluator (shared memo consulted read-only) so cycle marks are never
// shared; and everything ordered -- merging pools, logging diagnostics, moving Asts back -- happens
// serially after the join, in module order, so output is byte-identical to the serial stage.
pub fn borrowck_all(p: &mut loader::Package) bool {
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        if !borrowck_module(p, i) {
            ok = false;
        }
    }
    return ok;
}

// A deferred static_assert that failed once the whole package was typed: render it against the owning module.
fn flush_assert_err(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) {
    let p = ctx as *mut loader::Package;
    let sp = unsafe p.modules[m as usize].ast.at_const(cond).span;
    let src = unsafe p.modules[m as usize].source.as_str();
    let file = unsafe p.modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    if msg != null {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion cannot be evaluated: {}", diag::cstr(msg)));
    } else {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion failed"));
    }
    errs.finalize(src, file);
    errs.log();
    unsafe p.ok = false;
}

// A deferred call-bearing const initializer that still cannot be evaluated once the package is typed.
fn flush_const_err(ctx: *mut void, m: ModuleId, decl: NodeId, msg: *const char) {
    let p = ctx as *mut loader::Package;
    let sp = unsafe p.modules[m as usize].ast.at_const(decl).span;
    let src = unsafe p.modules[m as usize].source.as_str();
    let file = unsafe p.modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    errs.emit(sp.start, sp.end - sp.start, format("constant cannot be evaluated at compile time: {}", diag::cstr(msg)));
    errs.finalize(src, file);
    errs.log();
    unsafe p.ok = false;
}

// One module's test-plan slice, kept alive across codegen_emit (CgTestInfo holds a pointer into it).
type TCases = Array<cg::CgTestCase, 512>;

// ---------------------------------------------------------------------------------------------------------
// Global-phase compilation of a loaded package into a `<root>/build/` tree.
// ---------------------------------------------------------------------------------------------------------

/// Drop @platform-gated items that don't match the build target BEFORE resolution, so inactive code is
/// parsed-but-never-resolved and two same-named platform variants collapse to the single active one.
/// target: 0 windows, 1 macos, 2 linux; Attr.arg is the active-set mask (windows=bit0/macos=bit1/linux=bit2).
pub fn platform_filter(p: &mut loader::Package, target: i32) {
    let arch = p.arch; // the instruction-set axis rides on the package, so no caller has to thread it
    let n = p.modules.len();
    for mi in 0..n {
        let m = &mut p.modules[mi];
        let root = m.ast.root;
        if m.ast.at_const(root).kind != NodeKind::NODE_PROGRAM {
            continue;
        }
        let items = m.ast.at_const(root).as_data.program.items;
        let mut w: u32 = 0;
        for j in 0..items.len {
            let id = m.ast.children[(items.start + j) as usize];
            let mut keep = true;
            {
                for k in 0..m.ast.attrs.len() {
                    let at = m.ast.attrs.at(k);
                    if at.owner == id && at.kind == AttrKind::ATTR_PLATFORM as u8 && (at.arg >> target as u32 & 1u32) == 0 {
                        keep = false;
                    }
                    // `@arch` gates the same way on the instruction set. An unknown host arch (-1)
                    // keeps every gated item: dropping them all would silently empty the program.
                    if at.owner == id && at.kind == AttrKind::ATTR_ARCH as u8 && arch >= 0 && (at.arg >> arch as u32 & 1u32) == 0 {
                        keep = false;
                    }
                }
            }
            if keep {
                m.ast.children[(items.start + w) as usize] = id;
                w = w + 1;
            }
        }
        m.ast.at(root).as_data.program.items.len = w;
    }
}

// ---------------------------------------------------------------------------------------------------------
// --lint: unused non-pub items (functions/structs/unions/enums/interfaces/type aliases). Reachability v2:
// entries are top-level items + extend members (disjoint spans; extend HEADERS are deliberately not
// entries, so `extend Foo` alone is not a use of Foo). An item is live iff a root reaches it through the
// resolution graph -- dead cycles and dead-only callers are caught. Roots = everything exempt from
// reporting: `pub` (spc export layer), @c.export/@c.used/@emit_macro/extern (C export layer), @test*,
// main, bodyless fns, `extend X as Iface` conformance members, and every module outside the reported set
// (per-file `lint` invocations treat other modules as live; the full-build lint reports all non-prelude
// modules, so cross-module dead cycles are caught there).
fn item_has_attr(a: *const Ast, owner: NodeId, kind: AttrKind) bool {
    for i in 0..unsafe a.attrs.len() {
        let at = unsafe a.attrs.at(i);
        if at.owner == owner && at.kind == kind as u8 {
            return true;
        }
    }
    return false;
}

struct LintEnt {
    pub start: u32,
    pub end: u32,
    pub node: NodeId,
    pub root: bool,
}

const fn lint_ent_cmp(a: &LintEnt, b: &LintEnt) i32 {
    if a.start < b.start {
        return -1;
    }
    if a.start > b.start {
        return 1;
    }
    return 0;
}

const fn lint_edge_cmp(a: &u64, b: &u64) i32 {
    if *a < *b {
        return -1;
    }
    if *a > *b {
        return 1;
    }
    return 0;
}

// Innermost entry containing byte `pos`, or -1 (extend headers, imports, inter-item trivia).
fn lint_owner(ents: &Vector<LintEnt>, pos: u32) i64 {
    let mut lo: usize = 0;
    let mut hi = ents.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if ents[mid].start <= pos {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo == 0 {
        return -1;
    }
    let e = ents[lo - 1];
    if pos < e.end {
        return lo as i64 - 1;
    }
    return -1;
}

// Whether module `m` is in this lint run's reported set: the batch mask when present (multi-file
// `lint` sharing one package), else `only_mod` (single-file lint), else every non-prelude module.
const fn lint_reported(p: &loader::Package, m: usize, only_mod: i32) bool {
    if p.lint_set.len() != 0 {
        return p.lint_set[m];
    }
    if only_mod >= 0 {
        return m == only_mod as usize;
    }
    return !p.modules[m].prelude;
}

// Every batch-linted module is a lint root of its own (per-file parity: lint_one loads each file as
// module 0), so its `main` keeps the entry-point exemption there too.
const fn lint_root_mod(p: &loader::Package, m: usize) bool {
    return m == 0 || p.lint_set.len() != 0 && p.lint_set[m];
}

fn lint_build_entries(p: &loader::Package, m: usize, only_mod: i32, ents: &mut Vector<LintEnt>) {
    let a = mod_ast_c(p, m as ModuleId);
    // items of a module reported this run are candidates; everything else roots the graph
    let reported = lint_reported(p, m, only_mod);
    let src = p.modules[m].source.as_str();
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        let it = a.at_const(iid);
        if it.kind == NodeKind::NODE_IMPORT {
            continue;
        }
        if it.kind == NodeKind::NODE_EXTEND {
            let in_iface = it.as_data.extend_def.interface_type != NODE_NONE;
            let ms = it.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe a.list(ms)[j as usize];
                let msp = a.at_const(mid).span;
                ents.push(
                    LintEnt {
                        start: msp.start,
                        end: msp.end,
                        node: mid,
                        root: !(reported && lint_item_candidate(a, mid, in_iface, lint_pub_applies(p, m))),
                    },
                );
            }
            continue;
        }
        let mut root = !(reported && lint_item_candidate(a, iid, false, lint_pub_applies(p, m)));
        // `main` in the root module is the program entry: never reported, always a root
        if !root && lint_root_mod(p, m) && it.kind == NodeKind::NODE_FUNCTION {
            let nsp = a.at_const(it.as_data.function.name).as_data.name.text;
            if diag::span_str(src, nsp.start, nsp.end) == "main" {
                root = true;
            }
        }
        ents.push(LintEnt { start: it.span.start, end: it.span.end, node: iid, root: root });
    }
    ents.sort_by(lint_ent_cmp);
}

// Whether the binary-project pub lint applies to module `m`: never to the std/ffi trees -- they are
// libraries whose `pub` is API for downstream programs, even when they sit inside the workspace
// (nested std modules do not carry the prelude flag, so the file location is the reliable signal).
const fn lint_pub_applies(p: &loader::Package, m: usize) bool {
    if !p.lint_pub || p.modules[m].prelude {
        return false;
    }
    let f = p.modules[m].file.as_str();
    if f.starts_with("std/") || f.starts_with("ffi/") || f.starts_with("./std/") || f.starts_with("./ffi/") {
        return false;
    }
    let sr = p.std_root.as_str();
    if sr.len() != 0 && f.len() > sr.len() + 5 && f.starts_with(sr) {
        let rest = f.slice(sr.len() + 1, f.len());
        if rest.starts_with("std/") || rest.starts_with("ffi/") {
            return false;
        }
    }
    return true;
}

fn lint_item_candidate(a: *const Ast, iid: NodeId, in_iface_extend: bool, pub_too: bool) bool {
    let it = a.at_const(iid);
    // Everything inside a conformance is required BY the conformance: a method implements one of its
    // methods, a `type X = ..` binds one of its associated types. Neither is dead for want of a caller.
    if in_iface_extend {
        return false;
    }
    if it.kind == NodeKind::NODE_FUNCTION {
        let f = it.as_data.function;
        if f.is_public && !pub_too || f.is_extern || f.body == NODE_NONE {
            return false;
        }
        return !(item_has_attr(a, iid, AttrKind::ATTR_EXPORT) || item_has_attr(a, iid, AttrKind::ATTR_USED) || item_has_attr(
            a,
            iid,
            AttrKind::ATTR_TEST,
        ) || item_has_attr(a, iid, AttrKind::ATTR_TEST_INIT) || item_has_attr(a, iid, AttrKind::ATTR_TEST_FREE) || item_has_attr(
            a,
            iid,
            AttrKind::ATTR_BENCH,
        ));
    }
    if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
        return !it.as_data.aggregate.is_public && !item_has_attr(a, iid, AttrKind::ATTR_EXPORT) && !item_has_attr(
            a,
            iid,
            AttrKind::ATTR_USED,
        ) && !item_has_attr(a, iid, AttrKind::ATTR_EMIT_MACRO);
    }
    if it.kind == NodeKind::NODE_INTERFACE {
        return !it.as_data.interface_def.is_public && !item_has_attr(a, iid, AttrKind::ATTR_EXPORT) && !item_has_attr(
            a,
            iid,
            AttrKind::ATTR_USED,
        );
    }
    if it.kind == NodeKind::NODE_TYPE_ALIAS {
        return !it.as_data.type_alias.is_public && !item_has_attr(a, iid, AttrKind::ATTR_EXPORT) && !item_has_attr(
            a,
            iid,
            AttrKind::ATTR_USED,
        );
    }
    return false;
}

fn lint_report_item(
    p: &loader::Package,
    errs: &mut diag::Errors,
    a: *const Ast,
    m: ModuleId,
    iid: NodeId,
    root_mod: bool,
) {
    let it = a.at_const(iid);
    // a `@reflect`-tagged declaration is REACHED at startup: its exported descriptor registers
    // itself, and the metadata is the point even when no code names the type
    if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
        let nmet = (unsafe a.metas).len();
        for k in 0..nmet {
            if (unsafe a.metas).at(k).owner == iid {
                return;
            }
        }
    }
    let src = p.modules[m as usize].source.as_str();
    let mut what = "function";
    let mut nid = NODE_NONE;
    if it.kind == NodeKind::NODE_FUNCTION {
        nid = it.as_data.function.name;
    } else if it.kind == NodeKind::NODE_STRUCT {
        what = if it.as_data.aggregate.is_union {
            "union";
        } else {
            "struct";
        };
        nid = it.as_data.aggregate.name;
    } else if it.kind == NodeKind::NODE_ENUM {
        what = "enum";
        nid = it.as_data.aggregate.name;
    } else if it.kind == NodeKind::NODE_INTERFACE {
        what = "interface";
        nid = it.as_data.interface_def.name;
    } else {
        what = "type alias";
        nid = it.as_data.type_alias.name;
    }
    let nsp = a.at_const(nid).as_data.name.text;
    if root_mod && it.kind == NodeKind::NODE_FUNCTION && diag::span_str(src, nsp.start, nsp.end) == "main" {
        return;
    }
    if it.kind == NodeKind::NODE_FUNCTION && it.as_data.function.is_public {
        errs.warn(
            nsp.start,
            nsp.end - nsp.start,
            format(
                "unused public function '{}': nothing in this binary reaches it",
                diag::span_str(src, nsp.start, nsp.end),
            ),
        );
        return;
    }
    errs.warn(nsp.start, nsp.end - nsp.start, format("unused {} '{}'", what, diag::span_str(src, nsp.start, nsp.end)));
}

fn lint_unused_items(p: &mut loader::Package, only_mod: i32) {
    // one flat reachable-bitset over all modules' node ids
    let nm = p.modules.len();
    let mut starts = Vector::<usize>::new();
    let mut total: usize = 0;
    for m in 0..nm {
        starts.push(total);
        if p.modules[m].has_ast {
            total = total + p.modules[m].ast.nodes.len();
        }
    }
    let mut used = Vector::<bool>::new();
    used.reserve(total);
    for i in 0..total {
        used.push(false);
    }
    // Prelude modules only participate when a linted module IS prelude (std lint invocation): the
    // prelude never references user code, and std cross-references must count when linting std itself.
    let mut inc_prelude = false;
    if p.lint_set.len() != 0 {
        for m in 0..nm {
            if p.lint_set[m] && p.modules[m].prelude {
                inc_prelude = true;
            }
        }
    } else {
        inc_prelude = only_mod >= 0 && p.modules[only_mod as usize].prelude;
    }
    let mut ents = Vector::<Vector<LintEnt>>::new();
    for m in 0..nm {
        let mut e = Vector::<LintEnt>::new();
        if p.modules[m].has_ast && (!p.modules[m].prelude || inc_prelude) {
            lint_build_entries(p, m, only_mod, &mut e);
        }
        ents.push(e);
    }
    // seed roots, then edge list (src item -> referenced item) from every module's resolution table
    let mut queue = Vector::<u32>::new();
    for m in 0..nm {
        for k in 0..ents[m].len() {
            if ents[m][k].root {
                let slot = starts[m] + ents[m][k].node as usize;
                if !used[slot] {
                    used.set(slot, true);
                    queue.push(slot as u32);
                }
            }
        }
    }
    let mut edges = Vector::<u64>::new();
    for m in 0..nm {
        if ents[m].len() == 0 {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        for i in 0..a.resolutions_len() {
            let d = a.resolution_def(i as NodeId);
            if d.node == NODE_NONE || d.module as usize >= nm {
                continue;
            }
            let dm = d.module as usize;
            if ents[dm].len() == 0 {
                continue;
            }
            let si = lint_owner(ents.at(m), a.at_const(i as NodeId).span.start);
            if si < 0 {
                continue;
            }
            let ta = mod_ast_c(p, d.module);
            let di = lint_owner(ents.at(dm), ta.at_const(d.node).span.start);
            if di < 0 {
                continue;
            }
            let ss = (starts[m] + ents[m][si as usize].node as usize) as u64;
            let ds = (starts[dm] + ents[dm][di as usize].node as usize) as u64;
            if ss != ds {
                edges.push(ss << 32 | ds);
            }
        }
        // `a * b` resolves the method by NAME, so the resolution table holds no edge to it. The method
        // references the type checker recorded do, and they carry the body each one sits in.
        for i in 0..unsafe a.method_refs.len() {
            let r = *unsafe a.method_refs.at(i);
            let dm = r.callee.module as usize;
            if r.callee.node == NODE_NONE || dm >= nm || ents[dm].len() == 0 {
                continue;
            }
            let ta = mod_ast_c(p, r.callee.module);
            let di = lint_owner(ents.at(dm), ta.at_const(r.callee.node).span.start);
            if di < 0 {
                continue;
            }
            let ds = (starts[dm] + ents[dm][di as usize].node as usize) as u64;
            if r.owner == NODE_NONE {
                if !used[ds as usize] {
                    used.set(ds as usize, true);
                    queue.push(ds as u32);
                }
                continue;
            }
            let si2 = lint_owner(ents.at(m), a.at_const(r.owner).span.start);
            if si2 < 0 {
                continue;
            }
            let ss = (starts[m] + ents[m][si2 as usize].node as usize) as u64;
            if ss != ds {
                edges.push(ss << 32 | ds);
            }
        }
    }
    edges.sort_by(lint_edge_cmp);
    let mut qi: usize = 0;
    while qi < queue.len() {
        let sslot = queue[qi] as u64;
        qi = qi + 1;
        let key = sslot << 32;
        let mut lo: usize = 0;
        let mut hi = edges.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if edges[mid] < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        while lo < edges.len() && edges[lo] >> 32 == sslot {
            let dst = (edges[lo] & 0xFFFFFFFF) as usize;
            if !used[dst] {
                used.set(dst, true);
                queue.push(dst as u32);
            }
            lo = lo + 1;
        }
    }
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        let mut errs = diag::Errors::new();
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            let it = a.at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND {
                let in_iface = it.as_data.extend_def.interface_type != NODE_NONE;
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe a.list(ms)[j as usize];
                    if lint_item_candidate(a, mid, in_iface, lint_pub_applies(p, m)) && !used[starts[m] + mid as usize] {
                        lint_report_item(p, &mut errs, a, m as ModuleId, mid, lint_root_mod(p, m));
                    }
                }
            } else if lint_item_candidate(a, iid, false, lint_pub_applies(p, m)) && !used[starts[m] + iid as usize] {
                lint_report_item(p, &mut errs, a, m as ModuleId, iid, lint_root_mod(p, m));
            }
        }
        if errs.has_warnings() {
            p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
            errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
            errs.log();
        }
    }
}

fn ap_is_test_fn(a: *const Ast, fnode: NodeId) bool {
    for i in 0..unsafe a.attrs.len() {
        let at = unsafe a.attrs.at(i);
        if at.owner == fnode && (at.kind == AttrKind::ATTR_TEST as u8 || at.kind == AttrKind::ATTR_TEST_INIT as u8 || at.kind == AttrKind::ATTR_TEST_FREE as u8) {
            return true;
        }
    }
    return false;
}

fn ap_check_fn(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId) {
    if a.at_const(fnode).kind != NodeKind::NODE_FUNCTION || ap_is_test_fn(a, fnode) {
        return;
    }
    let cev = p.ceval as *mut ce::ConstEval;
    let hit = cev.ce_lint_body(m as ModuleId, fnode);
    if hit != NODE_NONE {
        let sp = a.at_const(hit).span;
        if ce::ce_trap_is_ub(cev.ce_trap_kind_get()) {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement is undefined behavior when executed: {}", cev.ce_trap_detail()),
            );
        } else {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement always panics at runtime: {}", cev.ce_trap_detail()),
            );
        }
    }
}

/// Always-panics check (the `unconditional_panic` analog, an ERROR like the raw-array provable-OOB
/// gate -- the same proof one tier up). A DRIVER phase, after every module has typechecked: the
/// sweep interprets cross-module `const fn` bodies, whose types only exist once their module is
/// typed -- an inline per-module pass would silently fold nothing (module order). @test fns are
/// exempt (panicking on purpose is a feature there), as are explicit `panic(..)` calls (only a
/// panic reached THROUGH a `const fn` frame classifies -- see ce_lint_body).
pub fn check_always_panics_module(p: &mut loader::Package, m: usize, errs: &mut diag::Errors) {
    if p.ceval == null || !p.modules[m].has_ast {
        return;
    }
    let a = mod_ast_c(p, m as ModuleId);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ms = a.at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                ap_check_fn(p, errs, a, m, unsafe a.list(ms)[j as usize]);
            }
        } else {
            ap_check_fn(p, errs, a, m, iid);
        }
    }
}

// --lint: functions the deep (all-paths) CTFE scan proves always evaluable -- declaring them
// `const fn` passes the def-site check and unlocks folding. `const fn` is a semantic contract
// (folds with known arguments must succeed), so the fix (insert `const ` before the `fn` keyword,
// which lands AFTER any `pub`/`unsafe` -- the canonical order) applies only under `--fix`.
// Conformance members are skipped (the interface fixes the signature), as are @test fns and `main`.
// Prelude modules are ALWAYS excluded, even when linted in place: constifying a prelude helper
// promotes failed folds to errors in every downstream program, a blast radius the per-package
// `--fix` fixpoint cannot validate -- prelude const adoption must be a deliberate manual change.
fn cs_check_fn(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId, in_iface: bool) {
    if a.at_const(fnode).kind != NodeKind::NODE_FUNCTION || in_iface || ap_is_test_fn(a, fnode) {
        return;
    }
    let f = a.at_const(fnode).as_data.function;
    if f.is_const || f.is_extern || f.body == NODE_NONE {
        return;
    }
    let src = p.modules[m].source.as_str();
    let nsp = a.at_const(f.name).as_data.name.text;
    if lint_root_mod(p, m) && diag::span_str(src, nsp.start, nsp.end) == "main" {
        return;
    }
    let cev = p.ceval as *mut ce::ConstEval;
    if cev.ce_fn_const_suggest(m as ModuleId, fnode) {
        errs.warn(
            nsp.start,
            nsp.end - nsp.start,
            format("function '{}' can be declared 'const fn'", diag::span_str(src, nsp.start, nsp.end)),
        );
        // the `fn` keyword sits just before the name, across whitespace
        let mut i = nsp.start as usize;
        while i > 0 && (src[i - 1] == b' ' || src[i - 1] == b'\t' || src[i - 1] == b'\n' || src[i - 1] == b'\r') {
            i = i - 1;
        }
        if i >= 2 && src[i - 2] == b'f' && src[i - 1] == b'n' {
            errs.fix((i - 2) as u32, (i - 2) as u32, 2);
        }
    }
}

fn lint_const_suggest(p: &mut loader::Package, only_mod: i32, fixes: *mut Vector<diag::LintFix>) {
    if p.ceval == null {
        return;
    }
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || p.modules[m].prelude || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        let mut errs = diag::Errors::new();
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
                let in_iface = a.at_const(iid).as_data.extend_def.interface_type != NODE_NONE;
                let ms = a.at_const(iid).as_data.extend_def.items;
                for j in 0..ms.len {
                    cs_check_fn(p, &mut errs, a, m, unsafe a.list(ms)[j as usize], in_iface);
                }
            } else {
                cs_check_fn(p, &mut errs, a, m, iid, false);
            }
        }
        if fixes != null {
            for k in 0..errs.fixes.len() {
                let mut f = errs.fixes[k];
                f.module = m as u32;
                fixes.push(f);
            }
        }
        if errs.has_warnings() {
            p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
            if fixes == null {
                errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
                errs.log();
            }
        }
    }
}

// --lint: unused imports. An import is removable when neither its target module nor anything in the
// target's transitive closure defines a symbol this file resolves to (own-module hits are excluded:
// legal import cycles would otherwise self-justify). Modules whose closure carries link-time side
// effects (@c.source/@c.link) or extends a foreign type (methods/conformances reachable without a
// resolution edge) are exempt.
// A module with @platform-gated items is exempt from cross-item unused lints (imports, members):
// the dropped items' uses are invisible under the current target, so a per-target verdict would
// contradict another target's.
fn module_platform_gated(a: *const Ast) bool {
    for i in 0..unsafe a.attrs.len() {
        if unsafe a.attrs.at(i).kind == AttrKind::ATTR_PLATFORM as u8 {
            return true;
        }
    }
    return false;
}

fn import_side_effects(p: &loader::Package, mid: ModuleId) bool {
    if mid as usize >= p.modules.len() || !p.modules[mid as usize].has_ast {
        return true; // unknowable: keep the import
    }
    let a = mod_ast_c(p, mid);
    for i in 0..unsafe a.attrs.len() {
        let k = unsafe a.attrs.at(i).kind;
        if k == AttrKind::ATTR_C_SOURCE as u8 || k == AttrKind::ATTR_C_LINK as u8 {
            return true;
        }
    }
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
            let d = a.resolution_def(a.at_const(iid).as_data.extend_def.target_type);
            if d.node == NODE_NONE || d.module != mid {
                return true; // extends a foreign (or unresolved) type
            }
        }
    }
    return false;
}

fn lint_unused_imports(p: &mut loader::Package, only_mod: i32, fixes: *mut Vector<diag::LintFix>) {
    let nm = p.modules.len();
    for m in 0..nm {
        if !p.modules[m].has_ast || p.modules[m].prelude || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        if module_platform_gated(a) {
            continue;
        }
        let mut usedm = Vector::<bool>::new();
        for k in 0..nm {
            usedm.push(false);
        }
        for i in 0..a.resolutions_len() {
            let d = a.resolution_def(i as NodeId);
            if d.node != NODE_NONE && d.module as usize < nm && d.module as usize != m {
                usedm.set(d.module as usize, true);
            }
        }
        let src = p.modules[m].source.as_str();
        let mut errs = diag::Errors::new();
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            if a.at_const(iid).kind != NodeKind::NODE_IMPORT {
                continue;
            }
            let path = loader::join_parts(unsafe &*a, src, a.at_const(iid).as_data.import_decl.path, "::");
            let mid = p.find(path.as_str());
            if mid < 0 || mid as usize == m {
                continue;
            }
            let mut used = usedm[mid as usize] || import_side_effects(p, mid as ModuleId);
            if !used {
                let clo = p.import_closure(mid as ModuleId);
                for c in 0..clo.len() {
                    let cm = clo[c];
                    if cm as usize != m && (usedm[cm as usize] || import_side_effects(p, cm)) {
                        used = true;
                        break;
                    }
                }
            }
            if !used {
                let sp = a.at_const(iid).span;
                errs.warn(sp.start, sp.end - sp.start, format("unused import '{}'", path.as_str()));
                let mut fe = sp.end;
                if fe as usize < src.len() && src[fe as usize] == b'\n' {
                    fe = fe + 1;
                }
                errs.fix(sp.start, fe, 0);
            }
        }

        if fixes != null {
            for k in 0..errs.fixes.len() {
                let mut f = errs.fixes[k];
                f.module = m as u32;
                fixes.push(f);
            }
        }
        if errs.has_warnings() {
            p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
            if fixes == null {
                errs.finalize(src, p.modules[m].file.as_str());
                errs.log();
            }
        }
    }
}

// --lint: an expression statement calling a provably pure function (deep FX_YES, value-only params,
// non-generic) whose results are dropped computes nothing observable -- dead code. The trailing
// statement of every block is exempt (it may be the block's value in expression position).
fn dp_check_stmt(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, sid: NodeId) {
    if a.at_const(sid).kind != NodeKind::NODE_EXPRESSION_STATEMENT {
        return;
    }
    let mut v = a.at_const(sid).as_data.single.value;
    while a.at_const(v).kind == NodeKind::NODE_UNARY && (a.at_const(v).as_data.unary.op == TokenType::Move || a.at_const(
        v,
    ).as_data.unary.op == TokenType::Unsafe) {
        v = a.at_const(v).as_data.unary.operand;
    }
    if a.at_const(v).kind != NodeKind::NODE_CALL {
        return;
    }
    let mut callee = a.at_const(v).as_data.call.callee;
    if a.at_const(callee).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
        callee = a.at_const(callee).as_data.specialization.expression;
    }
    let ck = a.at_const(callee).kind;
    if ck != NodeKind::NODE_IDENTIFIER && !(ck == NodeKind::NODE_MEMBER && a.at_const(callee).as_data.member.path) {
        return;
    }
    let mut fd = a.resolution_def(callee);
    if fd.node == NODE_NONE && ck == NodeKind::NODE_MEMBER {
        fd = a.resolution_def(a.at_const(callee).as_data.member.member);
    }
    if fd.node == NODE_NONE && ck == NodeKind::NODE_IDENTIFIER {
        fd = DefId { module: m as ModuleId, node: a.resolution(callee) };
    }
    if fd.node == NODE_NONE || fd.module as usize >= p.modules.len() || !p.modules[fd.module as usize].has_ast {
        return;
    }
    let fa = mod_ast_c(p, fd.module);
    if fa.at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
        return;
    }
    let f = fa.at_const(fd.node).as_data.function;
    if f.is_extern || f.body == NODE_NONE || f.returns.len == 0 || f.generics.len != 0 {
        return;
    }
    for i in 0..f.params.len {
        let pid = unsafe fa.list(f.params)[i as usize];
        if fa.at_const(pid).kind != NodeKind::NODE_PARAMETER {
            return;
        }
        let tk = fa.at_const(fa.at_const(pid).as_data.parameter.ty).kind;
        if tk == NodeKind::NODE_POINTER_TYPE || tk == NodeKind::NODE_REFERENCE_TYPE || tk == NodeKind::NODE_SLICE_TYPE || tk == NodeKind::NODE_DYN_TYPE || tk == NodeKind::NODE_FUNCTION_TYPE {
            return; // a reference-carrying param could observe or mutate caller state
        }
    }
    let cev = p.ceval as *mut ce::ConstEval;
    if !cev.ce_fn_const_suggest(fd.module, fd.node) {
        return;
    }
    let csp = a.at_const(callee).span;
    let src = p.modules[m].source.as_str();
    let ssp = a.at_const(sid).span;
    errs.warn(
        ssp.start,
        ssp.end - ssp.start,
        format("unused result of pure function '{}': the call has no effect", diag::span_str(src, csp.start, csp.end)),
    );
}

fn lint_discarded_results(p: &mut loader::Package, only_mod: i32) {
    if p.ceval == null {
        return;
    }
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || p.modules[m].prelude || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        let mut errs = diag::Errors::new();
        let n = unsafe a.nodes.len();
        let mut i: u32 = 1;
        while i as usize < n {
            if a.at_const(i).kind == NodeKind::NODE_BLOCK {
                let stmts = a.at_const(i).as_data.block.statements;
                if stmts.len > 1 {
                    for j in 0..stmts.len - 1 {
                        dp_check_stmt(p, &mut errs, a, m, unsafe a.list(stmts)[j as usize]);
                    }
                }
            }
            i = i + 1;
        }
        if errs.has_warnings() {
            p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
            errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
            errs.log();
        }
    }
}

// --lint: private struct fields and tagged-enum variants no resolution anywhere targets. Fields of
// pub/attributed/union/tuple structs are exempt (FFI layout, positional access); plain enums are
// exempt entirely (int casts materialize variants without naming them).
fn lint_unused_members(p: &mut loader::Package, only_mod: i32) {
    let nm = p.modules.len();
    let mut starts = Vector::<usize>::new();
    let mut total: usize = 0;
    for m in 0..nm {
        starts.push(total);
        if p.modules[m].has_ast {
            total = total + p.modules[m].ast.nodes.len();
        }
    }
    let mut used = Vector::<bool>::new();
    used.reserve(total);
    for i in 0..total {
        used.push(false);
    }
    let mut read = Vector::<bool>::new();
    read.reserve(total);
    for i in 0..total {
        read.push(false);
    }
    for m in 0..nm {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        // struct-literal initializer names resolve to the field decl but only WRITE it: exclude
        // them from the read set (fields warn on never-READ, Rust semantics)
        let an = unsafe a.nodes.len();
        let mut init_src = Vector::<bool>::new();
        init_src.reserve(an);
        for i in 0..an {
            init_src.push(false);
        }
        let mut k: u32 = 1;
        while k as usize < an {
            if a.at_const(k).kind == NodeKind::NODE_FIELD_INITIALIZER {
                let fnn = a.at_const(k).as_data.field_initializer.name;
                if fnn as usize < an {
                    init_src.set(fnn as usize, true);
                }
            }
            k = k + 1;
        }
        for i in 0..a.resolutions_len() {
            let d = a.resolution_def(i as NodeId);
            if d.node != NODE_NONE && d.module as usize < nm && p.modules[d.module as usize].has_ast && d.node as usize < p.modules[d.module as usize].ast.nodes.len() {
                used.set(starts[d.module as usize] + d.node as usize, true);
                if i >= an || !init_src[i] {
                    read.set(starts[d.module as usize] + d.node as usize, true);
                }
            }
        }
    }
    for m in 0..nm {
        if !p.modules[m].has_ast || p.modules[m].prelude || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        if module_platform_gated(a) {
            continue;
        }
        let src = p.modules[m].source.as_str();
        let mut errs = diag::Errors::new();
        let items = unsafe a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe a.list(items)[i as usize];
            let it = a.at_const(iid);
            if it.kind != NodeKind::NODE_STRUCT && it.kind != NodeKind::NODE_ENUM {
                continue;
            }
            if it.as_data.aggregate.is_public || it.as_data.aggregate.is_union {
                continue;
            }
            if item_has_attr(a, iid, AttrKind::ATTR_EXPORT) || item_has_attr(a, iid, AttrKind::ATTR_USED) || item_has_attr(
                a,
                iid,
                AttrKind::ATTR_EMIT_MACRO,
            ) || item_has_attr(a, iid, AttrKind::ATTR_PACKED) || item_has_attr(a, iid, AttrKind::ATTR_ALIGN) {
                continue;
            }
            let ms = it.as_data.aggregate.members;
            if it.kind == NodeKind::NODE_ENUM {
                let mut tagged = false;
                for j in 0..ms.len {
                    if a.at_const(unsafe a.list(ms)[j as usize]).as_data.variant.payload.len > 0 {
                        tagged = true;
                    }
                }
                if !tagged {
                    continue;
                }
            }
            for j in 0..ms.len {
                let mid2 = unsafe a.list(ms)[j as usize];
                let mn = a.at_const(mid2);
                let mut nsp = tok::Span::empty();
                if it.kind == NodeKind::NODE_STRUCT {
                    if mn.kind != NodeKind::NODE_FIELD || mn.as_data.field.is_public {
                        continue;
                    }
                    nsp = a.at_const(mn.as_data.field.name).as_data.name.text;
                } else {
                    if mn.kind != NodeKind::NODE_VARIANT {
                        continue;
                    }
                    nsp = a.at_const(mn.as_data.variant.name).as_data.name.text;
                }
                let hit = if it.kind == NodeKind::NODE_STRUCT {
                    read[starts[m] + mid2 as usize];
                } else {
                    used[starts[m] + mid2 as usize];
                };
                if nsp.end <= nsp.start || src[nsp.start as usize] == b'_' || hit {
                    continue;
                }
                if it.kind == NodeKind::NODE_STRUCT {
                    errs.warn(
                        nsp.start,
                        nsp.end - nsp.start,
                        format("field '{}' is never read", diag::span_str(src, nsp.start, nsp.end)),
                    );
                } else {
                    errs.warn(
                        nsp.start,
                        nsp.end - nsp.start,
                        format("unused variant '{}'", diag::span_str(src, nsp.start, nsp.end)),
                    );
                }
            }
        }
        if errs.has_warnings() {
            p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
            errs.finalize(src, p.modules[m].file.as_str());
            errs.log();
        }
    }
}

/// Fill `Package.extern_privates`: private, non-generic top-level functions referenced from inside a
/// GENERIC item of their own module. Full monomorphization emits that generic's body in whichever TU
/// instantiates it, and a `static` symbol is unreachable from there -- the C compiler reports the call as
/// undeclared. Their owner emits them with external linkage and a header prototype instead.
///
/// Containment is by SOURCE SPAN, the same way the unused-item lint maps a reference to its enclosing
/// entry: a generic item's span covers its whole body, and no walker over every node kind is needed.
/// Runs serially, between instance propagation and codegen, because the codegen workers are FORKED --
/// a set built inside one of them would not exist in the others.
fn mark_extern_privates(p: &mut loader::Package) {
    let nm = p.modules.len();
    for m in 0..nm {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        let items = unsafe a.at_const(a.root).as_data.program.items;
        if unsafe a.at_const(a.root).kind != NodeKind::NODE_PROGRAM {
            continue;
        }
        let ids = a.list(items);
        let mut gstart = Vector::<u32>::new();
        let mut gend = Vector::<u32>::new();
        for i in 0..items.len {
            let nid = unsafe ids[i as usize];
            let n = a.at_const(nid);
            let generic = n.kind == NodeKind::NODE_FUNCTION && n.as_data.function.generics.len != 0 || n.kind == NodeKind::NODE_EXTEND && n.as_data.extend_def.generics.len != 0;
            if generic {
                gstart.push(n.span.start);
                gend.push(n.span.end);
            } else if n.kind == NodeKind::NODE_EXTEND {
                // A generic METHOD of a non-generic extend is monomorphized the same way.
                let mids = a.list(n.as_data.extend_def.items);
                for j in 0..n.as_data.extend_def.items.len {
                    let mid = unsafe mids[j as usize];
                    let mn = a.at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && mn.as_data.function.generics.len != 0 {
                        gstart.push(mn.span.start);
                        gend.push(mn.span.end);
                    }
                }
            }
        }
        if gstart.len() != 0 {
            for r in 0..a.resolutions_len() {
                let d = a.resolution_def(r as NodeId);
                if d.node == NODE_NONE || d.module != m as ModuleId {
                    continue;
                }
                let dn = a.at_const(d.node);
                if dn.kind != NodeKind::NODE_FUNCTION || dn.as_data.function.is_public || dn.as_data.function.is_extern || dn.as_data.function.generics.len != 0 {
                    continue;
                }
                let sp = a.at_const(r as NodeId).span;
                for k in 0..gstart.len() {
                    if sp.start >= gstart[k] && sp.start < gend[k] {
                        p.extern_privates.insert(m as u64 << 32 | d.node as u64);
                        break;
                    }
                }
            }
        }
        gstart.free();
        gend.free();
    }
}

fn check_always_panics(p: &mut loader::Package, only_mod: i32) {
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
            continue;
        }
        let mut errs = diag::Errors::new();
        check_always_panics_module(p, m, &mut errs);
        if errs.errors.len() != 0 {
            p.ok = false;
            errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
            errs.log();
        }
    }
}

/// `super-c lint`: resolve + typecheck + borrowck the whole closure with lints enabled for module
/// `lint_mod` only -- or, when `p.lint_set` is non-empty, for every module in that mask (the batch
/// driver loads all listed files into ONE package; each module still warns exactly once) -- then the
/// report-only passes restricted to the same set. No code is emitted. Returns 0 only when clean -- any
/// error or remaining warning returns 1. `fixes != null` (`lint --fix`) collects machine fixes instead
/// of printing.
pub fn lint_package(
    p: &mut loader::Package,
    target: i32,
    lint_mod: usize,
    fixes: *mut Vector<diag::LintFix>,
    ftexts: *mut Vector<String>,
    suggest_const: bool,
) i32 {
    platform_filter(p, target);
    let n = p.modules.len();
    for i in 0..n {
        let sel = lint_reported(p, i, lint_mod as i32);
        let fx = if sel {
            fixes;
        } else {
            null;
        };
        let ok = resolve_module(p, i, sel, fx);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    for i in 0..n {
        let sel = lint_reported(p, i, lint_mod as i32);
        let fx = if sel {
            fixes;
        } else {
            null;
        };
        let ok = typecheck_module(p, i, sel, fx, ftexts);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    let mut wms = Vector::<facts::FactsWatermark>::new();
    facts_snapshot(p, &mut wms);
    p.ok = borrowck_all(p) && p.ok;
    if !p.ok {
        return 1;
    }
    if facts_verify(p, &wms, facts::FACTS_AFTER_BORROWCK, "borrowck") != 0 {
        return 1;
    }
    if core_ir_pass(p) != 0 {
        return 1;
    }
    let _ = borrow_ir_pass(p);
    drops_pass(p);
    ctfe_ir_pass(p);
    layout_pass(p);
    cemit_pass(p);
    // Report-only passes: skipped while `--fix` iterates (they yield no fixes and would print
    // duplicates). The const suggestion is the exception: opt-in (`--suggest-const`, warning every
    // eligible function at once would swamp default lints), and under `--fix` it contributes its
    // `const `-insertion fixes instead of printing.
    if fixes == null {
        lint_unused_items(p, lint_mod as i32);
        let ceptr = p.ceval as *mut ce::ConstEval;
        if ceptr != null {
            unsafe ceptr.all_typed = true;
        }
        check_always_panics(p, lint_mod as i32);
        lint_discarded_results(p, lint_mod as i32);
        lint_unused_members(p, lint_mod as i32);
    }
    lint_unused_imports(p, lint_mod as i32, fixes);
    if suggest_const {
        lint_const_suggest(p, lint_mod as i32, fixes);
    }
    if !p.ok || p.lint_warnings != 0 {
        return 1;
    }
    return 0;
}

/// Compile a loaded package into the <gen_root> C tree: full per-module pipeline, instance propagation,
/// Per-file completion callback for the streaming build: the engine starts compiling a finished TU
/// while later ones are still being emitted. `kind` 0 = header, 1 = C source. Paths are full paths
/// under the package's gen_root. Notifications for one build arrive from a single thread.
pub struct EmitSink {
    pub ctx: *mut void,
    pub notify: fn(*mut void, str, i32) void,
}

fn sink_notify(sink: *mut EmitSink, path: str, kind: i32) {
    if sink != null {
        let f = unsafe sink.notify;
        f(unsafe sink.ctx, path, kind);
    }
}

/// Construct module `mi`'s multifile Codegen. The instance lives across both emit passes:
/// codegen_emit reuses the header pass's collect_insts, exactly as the fused per-TU loop did.
/// Boxed because Codegen may hold pointers into its own fixed arrays once emission starts; it must
/// never move again.
fn make_tu<'a>(p: &mut loader::Package, mi: ModuleId) Box<cg::Codegen<'a>> {
    let m_ast = mod_ast_m(p, mi);
    let src = p.modules[mi as usize].source.as_str().ptr() as *const char;
    let slen = p.modules[mi as usize].source.len();
    let pkg = p as *mut loader::Package;
    let mut c = Box::new(cg::Codegen::new(m_ast, str::from_raw(src as *const u8, slen), pkg));
    c.set_multifile(true);
    return c;
}

/// Wire module `mi`'s test cases into `c`. Re-done before EVERY emit call on `c`: CgTestInfo stores
/// a raw pointer into `tcases`, which each pass reuses for the TU it is currently emitting.
fn set_tu_test_info(c: &mut Box<cg::Codegen>, mi: ModuleId, plan: &TestPlan, tcases: &mut TCases) {
    let mut nt: u32 = 0;
    let mut tk: usize = 0;
    while tk < plan.cases.len() && nt < 512 {
        let tc = plan.cases[tk];
        if tc.mod == mi {
            tcases[nt as usize] = cg::CgTestCase {
                func: tc.func,
                wants: tc.wants,
                suite: tc.suite,
                suite_is_enum: tc.suite_is_enum,
                suite_init: tc.suite_init,
                suite_free: tc.suite_free,
            };
            nt = nt + 1;
        }
        tk = tk + 1;
    }
    let gi = if plan.genv_mod == mi {
        plan.genv_init;
    } else {
        NODE_NONE;
    };
    let gf = if plan.genv_mod == mi {
        plan.genv_free;
    } else {
        NODE_NONE;
    };
    let ti = cg::CgTestInfo {
        enabled: true,
        cases: &tcases[0],
        ncases: nt,
        fx_init: plan.fx_init[mi as usize],
        fx_free: plan.fx_free[mi as usize],
        fx_type: plan.fx_type[mi as usize],
        fx_is_enum: plan.fx_is_enum[mi as usize],
        genv_init: gi,
        genv_free: gf,
        genv_type: plan.genv_type,
        genv_is_enum: plan.genv_is_enum,
    };
    c.set_test_info(&ti);
}

/// Emit one prepared TU's header into `root`, borrowing the package's recycled output buffer.
fn emit_tu_header(p: &mut loader::Package, c: &mut Box<cg::Codegen>, mi: ModuleId, root: str) {
    c.adopt_buf(replace(&mut p.cg_scratch, String::new()));
    let hpath = build_out_path(root, p.modules[mi as usize].path.as_str(), ".h");
    let hout = open_out(hpath.as_str());
    if hout != null {
        c.codegen_emit_header(hout);
        unsafe stdio::fclose(hout);
    }
    p.cg_scratch = c.take_buf();
}

/// Emit one prepared TU's C source into `root`; false on an emission error.
fn emit_tu_source(p: &mut loader::Package, c: &mut Box<cg::Codegen>, mi: ModuleId, root: str) bool {
    c.adopt_buf(replace(&mut p.cg_scratch, String::new()));
    let mut ok = true;
    let mut opath = build_out_path(root, p.modules[mi as usize].path.as_str(), ".c");
    let out = open_out(opath.as_str());
    if out == null {
        unsafe stdio::perror(opath.cstr());
        ok = false;
    } else {
        c.codegen_emit(out);
        unsafe stdio::fclose(out);
        if c.has_errors() {
            c.log_errors();
            ok = false;
        }
    }
    p.cg_scratch = c.take_buf();
    return ok;
}

/// Fork `w` workers, worker `wk` rendering the sources of stride `k % w == wk` of `lm` from the
/// prepared Codegens inherited across the fork. Every header is already on disk (the serial
/// header pass runs first -- header rendering deposits re-homed instances into other modules'
/// pools, so its ORDER is part of the emitted bytes and it cannot be split across workers). A
/// worker's own source rendering is independent: it only APPENDS to foreign type pools inside a
/// reintern/restore_arena window, and its whole address space is COW-private. Each finished TU is
/// reported as a 2-byte index packet on a shared pipe (atomic under PIPE_BUF); the parent turns
/// packets into sink notifications in arrival order, then reaps the workers. `keep[base_c..]`
/// holds the .c paths, indexed like `lm`. Workers leave through sc_exit_now, so the inherited
/// leak registry and stdio buffers are never replayed. Returns false when no worker could be
/// forked (Windows) -- the caller then runs the serial source loop instead.
fn emit_sources_parallel(
    p: &mut loader::Package,
    cgs: &mut Vector<Box<cg::Codegen>>,
    lm: &Vector<ModuleId>,
    w: u32,
    root: str,
    testing: bool,
    plan: &TestPlan,
    sink: *mut EmitSink,
    keep: &Vector<String>,
    base_c: usize,
    err: &mut bool,
) bool {
    let mut fds = Array::<i32, 2>::new();
    if unsafe shim::sc_pipe(&mut fds[0]) != 0 {
        return false;
    }
    let mut tcases = TCases {}; // per-process: each worker wires its own current TU into it
    let mut pids = Vector::<i64>::new();
    let mut inline_strides = Vector::<u32>::new();
    for wk in 0..w {
        let pid = unsafe shim::sc_fork();
        if pid == 0 {
            unsafe shim::sc_fd_close(fds[0]);
            let mut cerr = false;
            let mut k = wk as usize;
            while k < lm.len() {
                if testing {
                    set_tu_test_info(&mut cgs[k], lm[k], plan, &mut tcases);
                }
                if !emit_tu_source(p, &mut cgs[k], lm[k], root) {
                    cerr = true;
                }
                let idx = k as u16;
                unsafe shim::sc_fd_write(fds[1], (&idx) as *const u16, 2);
                k = k + w as usize;
            }
            unsafe shim::sc_fd_close(fds[1]);
            unsafe shim::sc_exit_now(
                if cerr {
                    1;
                } else {
                    0 as i32;
                },
            );
        } else if pid < 0 {
            inline_strides.push(wk);
        } else {
            pids.push(pid);
        }
    }
    unsafe shim::sc_fd_close(fds[1]);
    if pids.len() == 0 {
        unsafe shim::sc_fd_close(fds[0]);
        return false;
    }
    // Strides whose fork failed run in the parent, notifying inline; the workers keep running meanwhile.
    for s in 0..inline_strides.len() {
        let mut k = inline_strides[s] as usize;
        while k < lm.len() {
            if testing {
                set_tu_test_info(&mut cgs[k], lm[k], plan, &mut tcases);
            }
            if !emit_tu_source(p, &mut cgs[k], lm[k], root) {
                *err = true;
            }
            sink_notify(sink, keep.at(base_c + k).as_str(), 1);
            k = k + w as usize;
        }
    }
    loop {
        let mut idx: u16 = 0;
        let r = unsafe shim::sc_fd_read(fds[0], (&mut idx) as *mut u16, 2);
        if r != 2 {
            break; // EOF: every worker closed its write end
        }
        sink_notify(sink, keep.at(base_c + idx as usize).as_str(), 1);
    }
    unsafe shim::sc_fd_close(fds[0]);
    for i in 0..pids.len() {
        let mut code: i32 = 0;
        if unsafe shim::sc_waitpid(pids[i], &mut code) != 0 || code != 0 {
            *err = true;
        }
    }
    return true;
}

/// then codegen of the live modules (headers first, then sources across `jobs` forked workers),
/// pruning stale outputs afterwards. A non-empty `out_bin` also compiles + links the program there
/// (`build`); `topts.enabled` synthesizes, builds and runs the test runner instead. `sink` (may be
/// null) hears about every finished output file, which is what lets the build engine compile a TU
/// while later ones are still being emitted. `jobs` 0 means the online core count. Returns the
/// process exit code (0 = success).
pub fn run_package(
    p: &mut loader::Package,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    lint: bool,
    cflags: str,
    sink: *mut EmitSink,
    jobs: u32,
) i32 {
    platform_filter(p, target);
    let n = p.modules.len();
    for i in 0..n {
        let ok = resolve_module(p, i, lint && !p.modules[i].prelude, null);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    for i in 0..n {
        let ok = typecheck_module(p, i, lint && !p.modules[i].prelude, null, null);
        p.ok = ok && p.ok;
    }
    if p.ok {
        discharge_obligations(p, n);
    }
    if !p.ok {
        return 1;
    }
    let mut wms = Vector::<facts::FactsWatermark>::new();
    facts_snapshot(p, &mut wms);
    p.ok = borrowck_all(p) && p.ok;
    // Release the pool as soon as the one parallel stage is done: the test runner FORKS after this,
    // and a forked child inherits the pool's state but none of its worker threads. (Also what keeps
    // the leak gate green.) The bench calls borrowck_all directly, so its iterations keep a warm pool.
    if !p.ok {
        return 1;
    }
    if facts_verify(p, &wms, facts::FACTS_AFTER_BORROWCK, "borrowck") != 0 {
        return 1;
    }
    if core_ir_pass(p) != 0 {
        return 1;
    }
    let _ = borrow_ir_pass(p);
    drops_pass(p);
    ctfe_ir_pass(p);
    layout_pass(p);
    cemit_pass(p);
    cemit_tu_pass(p);
    if lint {
        lint_unused_items(p, -1);
    }
    // static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let ceptr = p.ceval as *mut ce::ConstEval;
    if ceptr != null {
        let pv = p as *mut loader::Package;
        unsafe ceptr.all_typed = true;
        // an ERROR, not a lint: it runs on every build (user modules; std is gated by check.sh's
        // explicit std lint invocations)
        check_always_panics(p, -1);
        ceptr.flush_asserts(flush_assert_err, pv);
        ceptr.flush_consts(flush_const_err, pv);
    }
    if !p.ok {
        return 1;
    }
    loader::package_propagate_instances(p);
    mark_extern_privates(p);
    instance_graph_shadow(p);
    p.shadow_on = stdlib::getenv("SC_INSTANCES") != null;
    p.drops_on = stdlib::getenv("SC_DROPS") != null;
    p.mangle_on = stdlib::getenv("SC_MANGLE") != null;

    let testing = topts != null && unsafe topts.enabled;
    let mut plan = TestPlan::new(n);
    if testing {
        test_plan_build(p, &mut plan);
        if !plan.ok {
            return 1;
        }
    }

    // Manifest builds point gen_root into their out-dir; bare invocations default next to the sources.
    if p.gen_root.len() == 0 {
        p.gen_root = String::from_str(p.root_dir.as_str());
        p.gen_root.push_str("/build/raw");
    }
    write_super_rt(p.gen_root.as_str());
    let root = p.gen_root.as_str();
    let mut keep = Vector::<String>::new();
    keep.push(build_out_path(root, "super_rt", ".h"));
    keep.push(build_out_path(root, "super_rt", ".c"));
    sink_notify(sink, keep.at(0).as_str(), 0);
    sink_notify(sink, keep.at(1).as_str(), 1); // self-contained: carries its own includes
    let mut err = false;
    // `@c.source` wrapper TUs land in keep[]; `@c.link` flags feed build/__ldflags for the link line.
    let pre_ext = keep.len();
    ext_c_collect(p, &mut keep, &mut err, target);
    for i in pre_ext..keep.len() {
        let s = keep.at(i).as_str();
        sink_notify(
            sink,
            s,
            if s.ends_with(".c") {
                1;
            } else {
                0 as i32;
            },
        );
    }
    let live = compute_emit_live(p);
    let osz = if n != 0 {
        n;
    } else {
        1 as usize;
    };
    let order = (unsafe stdlib::malloc(osz * 2)) as *mut ModuleId;
    if order == null {
        if live != null {
            unsafe stdlib::free(live);
        }
        return 1;
    }
    loader::package_emit_order(p, order);
    let mut lm = Vector::<ModuleId>::new();
    for oi in 0..n {
        let mi = unsafe order[oi];
        if live != null && !unsafe live[mi as usize] {
            continue;
        }
        lm.push(mi);
    }
    // The parent owns keep[] whichever mode runs, so every output path exists up front:
    // keep[base_h + k] / keep[base_c + k] are TU k's header/source, indexed like lm.
    let base_h = keep.len();
    for k in 0..lm.len() {
        keep.push(build_out_path(root, p.modules[lm[k] as usize].path.as_str(), ".h"));
    }
    let base_c = keep.len();
    for k in 0..lm.len() {
        keep.push(build_out_path(root, p.modules[lm[k] as usize].path.as_str(), ".c"));
    }
    let mut w: u32 = if jobs != 0 {
        jobs;
    } else {
        (unsafe shim::sc_ncpu()) as u32;
    };
    if w as usize > lm.len() {
        w = lm.len() as u32;
    }
    // Fork is pathological under ASan (each child COW-faults the whole shadow), so a sanitized
    // binary keeps the serial path; SC_SERIAL_EMIT=1 forces it for A/B byte-diffs.
    if unsafe shim::sc_asan() != 0 || stdlib::getenv("SC_SERIAL_EMIT") != null || p.shadow_on || p.drops_on || p.mangle_on {
        w = 1; // shadow export: forked workers would drop their record_inst halves
    }
    // One Codegen per TU, alive across both passes, so codegen_emit reuses the header pass's
    // collect_insts (the fused loop's behavior).
    let mut cgs = Vector::<Box<cg::Codegen>>::with_capacity(lm.len());
    for k in 0..lm.len() {
        let c = make_tu(p, lm[k]);
        cgs.push(c);
    }
    let mut tcases = TCases {}; // reused per emit call; CgTestInfo points into it (see set_tu_test_info)
    // Pass 1: every header, serially IN EMIT ORDER -- header rendering deposits re-homed instances
    // into other modules' pools, so this order is part of the emitted bytes. It also puts all .h
    // on disk before the first source: a streamed source compile can never miss an include.
    for k in 0..lm.len() {
        if testing {
            set_tu_test_info(&mut cgs[k], lm[k], &plan, &mut tcases);
        }
        emit_tu_header(p, &mut cgs[k], lm[k], root);
        sink_notify(sink, keep.at(base_h + k).as_str(), 0);
    }
    // Pass 2: sources, forked workers when possible.
    let mut done_par = false;
    if w > 1 {
        done_par = emit_sources_parallel(p, &mut cgs, &lm, w, root, testing, &plan, sink, &keep, base_c, &mut err);
    }
    if !done_par {
        for k in 0..lm.len() {
            if testing {
                set_tu_test_info(&mut cgs[k], lm[k], &plan, &mut tcases);
            }
            if !emit_tu_source(p, &mut cgs[k], lm[k], root) {
                err = true;
            }
            sink_notify(sink, keep.at(base_c + k).as_str(), 1);
        }
    }
    unsafe stdlib::free(order);
    if live != null {
        unsafe stdlib::free(live);
    }
    // Drop outputs from a previous build that this program no longer emits, so the tree matches the current
    // sources. Skip on a keep-list OOM -- never risk deleting a live output.
    let mut broot = PathBuf {};
    // root is a str view (not nul-terminated); bound the copy with %.*s or %s runs off the buffer end.
    let bn = unsafe stdio::snprintf(
        &mut broot[0],
        4096,
        "%.*s".ptr() as *const char,
        root.len() as i32,
        root.ptr() as *const char,
    );
    if bn > 0 && bn as usize < 4096 {
        prune_orphans(&broot[0], &keep);
    }
    let mut rc: i32 = if err {
        1;
    } else {
        0 as i32;
    };
    if out_bin.len() != 0 {
        if !err {
            rc = test_build_and_run(p, null, &keep, out_bin, cflags, target);
        }
    } else if testing && !err {
        if plan.cases.len() == 0 {
            unsafe stdio::fputs("super-c: no '@test' functions found\n".ptr() as *const char, stdio::stderr());
            rc = 1;
        } else {
            switch write_test_main(p, &plan) {
                Some(runner) => {
                    sink_notify(sink, runner.as_str(), 1);
                    keep.push(runner);
                    rc = test_build_and_run(p, topts, &keep, "", cflags, target);
                },
                None => {
                    rc = 1;
                },
            };
        }
    }
    // Report-only: post-codegen arena growth must stay inside the documented allowlist (the strict
    // tables are still compared; see ast::facts for what each later stage removes).
    let _ = facts_verify(p, &wms, facts::FACTS_AFTER_CODEGEN, "codegen");
    if p.shadow_on {
        emitted_inst_diff(p);
    }
    if p.drops_on {
        drops_compare(p);
    }
    if p.mangle_on {
        mangle_diff(p);
    }
    return rc;
}

// The mangling-freeze comparison: replay every symbol render the established emitter recorded
// through the frozen backend mangler and demand identical bytes. Records outside the frozen
// subset (dyn stems today) count as skipped, never as agreement.
fn mangle_diff(p: &mut loader::Package) {
    let mut mg = mbe::Mangler::new(p);
    let mut replayed: usize = 0;
    let mut skipped: usize = 0;
    let mut bad: usize = 0;
    let mut s = String::new();
    for i in 0..p.mangle_log.len() {
        let r = p.mangle_log.at(i);
        s.truncate(0);
        let ok = if r.kind == 0 {
            mg.type_m(r.m, r.t, &mut s);
        } else if r.kind == 1 {
            mg.inst_name(r.m, &r.it, &mut s);
        } else if r.kind == 2 {
            mg.fn_sym(r.m, r.node, r.target, (r.flags & 1) != 0, &mut s);
        } else if r.kind == 3 {
            mg.spec_sym(r.m, DefId { module: r.it.module, node: r.it.decl }, &r.it.args[0], r.it.n, &mut s);
        } else {
            mg.ctype(r.m, r.t, r.decl.as_str(), &mut s);
        };
        if !ok {
            skipped += 1;
            continue;
        }
        replayed += 1;
        if s.as_str() != r.sym.as_str() {
            bad += 1;
            if bad <= 8 {
                eprint("mangle-diff: module {} type {}: old `{}` new `{}`\n", r.m, r.t, r.sym.as_str(), s.as_str());
            }
        }
    }
    s.free();
    mg.free();
    eprint("mangle: {} records, {} replayed, {} skipped, {} mismatched\n", p.mangle_log.len(), replayed, skipped, bad);
}

// The exit-gate comparison: every fn instance codegen actually RECORDED FOR EMISSION must exist in
// the Core-IR instance graph (the graph may legitimately hold more -- codegen prunes per-TU).
// Symbolic records (n == 0xFF) belong to enclosing generic bodies and are skipped: their concrete
// forms re-record under each substitution.
fn emitted_inst_diff(p: &mut loader::Package) {
    let t0 = unsafe shim::sc_ticks_ms();
    let mut g = ig::InstGraph::new(p);
    g.collect();
    let mut total: u32 = 0;
    let mut missing: u32 = 0;
    let mut miss_pair: u32 = 0;
    let mut miss_inst: u32 = 0;
    for i in 0..p.shadow_insts.len() {
        let sh = *p.shadow_insts.at(i);
        if sh.n == 0xFF {
            continue;
        }
        total += 1;
        let mut args = Vector::<ig::ArgKey>::new();
        for k in 0..sh.n {
            args.push(ig::ArgKey { skey: unsafe sh.keys[k as usize], val: 0, has_val: false });
        }
        let mut fresh = false;
        let _ = g.add(ig::IG_FN, sh.def, &args, &mut fresh);
        if fresh {
            // not an IG_FN record; an IG_METHOD record with the same keys also proves discovery
            let mut fresh2 = false;
            let _ = g.add(ig::IG_METHOD, sh.def, &args, &mut fresh2);
            fresh = fresh2;
        }
        if fresh {
            missing += 1;
            // attribution: is the receiver instance itself known? (key prefix as an AGG record)
            let mut agg_known = false;
            for r in 0..g.recs.len() {
                let gr = *g.recs.at(r);
                if gr.kind != ig::IG_AGG || gr.args_len as usize > args.len() {
                    continue;
                }
                let mut eq = gr.args_len != 0;
                for k in 0..gr.args_len {
                    if g.keys.at((gr.args_start + k) as usize).skey != args.at(k as usize).skey {
                        eq = false;
                    }
                }
                if eq {
                    agg_known = true;
                }
            }
            if agg_known {
                miss_pair += 1;
            } else {
                miss_inst += 1;
            }
            if stdlib::getenv("SC_INSTANCES_ALL") != null || missing <= 24 {
                let da = unsafe &*p.module_ast_const(sh.def.module);
                let nsp = da.at_const(da.at_const(sh.def.node).as_data.function.name).as_data.name.text;
                let dsrc = p.modules.at(sh.def.module as usize).source.as_str();
                let _ = da;
                eprint(
                    "inst-emit: missing {} m{} n{} ({} args)\n",
                    dsrc.slice(nsp.start as usize, nsp.end as usize),
                    sh.def.module,
                    sh.def.node,
                    sh.n,
                );
            }
        }
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint("inst-emit: attribution: {} pair-missing (agg known), {} instance-missing\n", miss_pair, miss_inst);
    // owner-emits homes: computed from anchors, verified anchor-independent across every pool
    let mut homed: u32 = 0;
    let mut hmiss: u32 = 0;
    g.compute_homes(&mut homed, &mut hmiss);
    let mut deps = Vector::<u32>::new();
    g.module_deps(&mut deps);
    let mut anchored: u32 = 0;
    let mut derived: u32 = 0;
    for r in 0..g.recs.len() {
        let rec = g.recs.at(r);
        if rec.kind != ig::IG_AGG {
            continue;
        }
        if rec.aty != TYPE_NONE {
            anchored += 1;
        } else {
            derived += 1;
        }
    }
    eprint(
        "inst-home: {} homes computed, {} anchor mismatches, {} dep edges; aggs {} pool-anchored + {} derived\n",
        homed,
        hmiss,
        deps.len(),
        anchored,
        derived,
    );
    eprint(
        "inst-emit: {} emitted fn instances, {} missing from the graph, {} graph records, {} ms{}\n",
        total,
        missing,
        g.recs.len(),
        dt,
        if g.overflow {
            " (BUDGET OVERFLOW)";
        } else {
            "";
        },
    );
    // Per-TU emission plans: the established emitter's own per-TU discovery sequence mapped onto
    // graph records (the order the backend switch preserves), plus graph-only homed records. The
    // gate is zero unmapped entries.
    let mut plan_entries: u32 = 0;
    let mut plan_extra: u32 = 0;
    let mut plan_unmapped: u32 = 0;
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let mut tu_plan = Vector::<u32>::new();
        let mut um: u32 = 0;
        g.plan_tu(p, m as ModuleId, &mut tu_plan, &mut um);
        let mut mapped: u32 = 0;
        for i in 0..p.shadow_insts.len() {
            if p.shadow_insts.at(i).tu == m as ModuleId && p.shadow_insts.at(i).n != 0xFF {
                mapped += 1;
            }
        }
        plan_entries += tu_plan.len() as u32;
        if tu_plan.len() as u32 + um > mapped {
            plan_extra += tu_plan.len() as u32 + um - mapped;
        }
        plan_unmapped += um;
        tu_plan.free();
    }
    eprint(
        "inst-plan: {} planned entries across TUs ({} graph-only), {} unmapped emitted instances\n",
        plan_entries,
        plan_extra,
        plan_unmapped,
    );
}
