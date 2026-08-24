// Global-phase pipeline driver over a loaded Package: platform-filters items, runs resolve/typecheck/
// borrowck per module (each stage mutates the module's Ast in place through a raw pointer into its
// Package slot), flushes deferred const-eval errors, then prunes dead modules from
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
import hir::lower as hirl;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import borrowck::flow_ir as bfi;
import ir::core as irc;
import ir::lower as irl;
import ir::print as irp;
import ir::verify as irv;
import ir::drops as ird;
import ir::interp as iri;
import ir::layout as lay;
import emit::cemit as cbe;
import emit::cflow as cfl;
import emit::mangle as mbe;
import emit::tu as tbe;
import graph::instances as ig;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import borrowck::loans as bln;
import borrowck::explain as bex;
import utils::errors as diag;
import driver::tuc as tuc;
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
    let aptr = (&mut m.ast) as *mut Ast;
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    r.resolve();
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
    hirl::lower_module(p, i);
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
        let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
        t.check_cross_module_dup_conformances();
        if t.has_errors() {
            t.errors.finalize(str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
            t.log_errors();
            p.ok = false;
        }
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
            let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
            if t.discharge_foreign_obligations(starts.as_ptr()) {
                grew = true;
            }
            if t.discharge_conformance_obligations(starts.as_ptr(), ends.as_ptr()) {
                grew = true;
            }
            if t.has_errors() {
                t.errors.finalize(str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
                t.log_errors();
                p.ok = false;
            }
        }

        starts = ends;
        pass = pass + 1;
        if !grew || !p.ok || pass >= 16 {
            break;
        }
    }
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
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.lint = lint;
    t.check();
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
    return !had;
}

// Borrow-check module `i`, serially: the pipeline stage after typechecking. A fresh TypeChecker context
// over the typed AST carries the recorded types and resolutions; only the borrow/move/lifetime analyses
// run. This is the one-module primitive borrowck_all iterates.
// Dev gate (SC_FACTS_CHECK=1): snapshot every module's semantic-table watermarks right after
// type checking, then assert -- after borrow checking AND after codegen -- that no later stage
// changed a semantic decision table (intern pools excepted; see ast::facts). Off without the env var.
// Dev gate (SC_AST_STATS=1): per-kind node census plus arena byte totals over the whole package,
// printed after typechecking (post-HIR, so desugar-built nodes are counted). Off without the env var.
fn ast_stats(p: &loader::Package) {
    if stdlib::getenv("SC_AST_STATS") == null {
        return;
    }
    let mut counts = Vector::<u64>::new();
    counts.reserve(128);
    for _ in 0..128 {
        counts.push(0);
    }
    let mut nodes: u64 = 0;
    let mut children: u64 = 0;
    let mut bytes: u64 = 0;
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = &p.modules[m].ast;
        nodes += a.nodes.len() as u64;
        children += a.children.len() as u64;
        bytes += a.retained_bytes() as u64;
        for i in 0..a.nodes.len() {
            let k = a.nodes.at(i).kind as usize;
            if k < 128 {
                counts[k] += 1;
            }
        }
    }
    unsafe stdio::fprintf(
        stdio::stderr(),
        "ast-stats: %llu nodes, %llu children, %llu KiB retained, sizeof(Node)=%zu\n".ptr() as *const char,
        nodes,
        children,
        bytes / 1024,
        sizeof(Node),
    );
    for k in 0..counts.len() {
        if counts[k] != 0 {
            unsafe stdio::fprintf(stdio::stderr(), "  kind %3zu: %llu\n".ptr() as *const char, k, counts[k]);
        }
    }
}

fn facts_snapshot(p: &loader::Package, out: &mut Vector<facts::FactsWatermark>) {
    if stdlib::getenv("SC_FACTS_CHECK") == null {
        return;
    }
    for i in 0..p.modules.len() {
        out.push(facts::watermark(&p.modules[i].ast));
    }
}

// Compare the snapshot against the live tables; returns the number of changed tables (0 when the
// snapshot is empty, i.e. the gate is off). One strict set at every stage; see ast::facts.
fn facts_verify(p: &loader::Package, wms: &Vector<facts::FactsWatermark>, stage: str) u32 {
    if wms.len() == 0 {
        return 0;
    }
    let mut d: u32 = 0;
    for i in 0..p.modules.len() {
        if i < wms.len() {
            d += facts::watermark_check(&p.modules[i].ast, wms.at(i), i as u32);
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
    return (st.move_errs + st.loan_errs + st.ref_diffs) as u32;
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
        }
    }

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
}

// SC_CEMIT_TU=1: the backend's declaration layer over the whole package -- every concrete
// aggregate plus every anchored instance from a fresh graph, forward typedefs then dependency-first
// definitions -- gated by a strict-C11 syntax-only compile of the emitted scratch TU.
/// One assembled new-backend emission. TU texts carry NO include lines; the writer prepends the
/// layout-relative includes of the two shared headers. `skips` MUST be zero for the output to be
/// complete (every count is an emission the backend refused).
pub struct CemitOut {
    pub types_h: String,
    pub protos_h: String,
    pub tus: Vector<String>,
    pub inst_c: String,
    pub have_main: bool,
    pub main_mod: u64,
    pub main_argv: bool,
    pub skips: u64,
    pub edges: Vector<u64>, // (spelling TU << 32 | owner module): cross-TU symbol references
    /// Next per-TU cache image + its path ("" = caching off): run_package persists it only after a
    /// fully successful emission, so a failed build never publishes sections it did not finish.
    pub tuc_img: String,
    pub tuc_path: String,
}

extend CemitOut as Free {
    pub fn free(self: &mut Self) {
        self.types_h.free();
        self.protos_h.free();
        self.tus.free();
        self.inst_c.free();
        self.edges.free();
        self.tuc_img.free();
        self.tuc_path.free();
    }
}

extend CemitOut {
    pub fn new(n: usize) CemitOut {
        let mut o = CemitOut {
            types_h: String::new(),
            protos_h: String::new(),
            tus: Vector::<String>::new(),
            inst_c: String::new(),
            have_main: false,
            main_mod: 0,
            main_argv: false,
            skips: 0,
            edges: Vector::<u64>::new(),
            tuc_img: String::new(),
            tuc_path: String::new(),
        };
        for _i in 0..n {
            o.tus.push(String::new());
        }
        return o;
    }
}

// The C attribute prefix of fn `nid` (`inline __attribute__((always_inline)) ` etc.), mirroring
// the established emitter: inline/always_inline/noinline, cold (+noinline unless spelled),
// used/unused, section("name").
fn cemit_fn_attrs(p: &loader::Package, m: ModuleId, nid: NodeId, out: &mut String) {
    let a = unsafe &*p.module_ast_const(m);
    let mut always = false;
    let mut inl = false;
    let mut noinl = false;
    let mut cold = false;
    let mut used = false;
    let mut unused = false;
    let mut sec = tok::Span { start: 0, end: 0 };
    for k in 0..a.attrs.len() {
        if a.attrs.at(k).owner != nid {
            continue;
        }
        let kd = a.attrs.at(k).kind;
        if kd == AttrKind::ATTR_ALWAYS_INLINE as u8 {
            always = true;
        } else if kd == AttrKind::ATTR_INLINE as u8 {
            inl = true;
        } else if kd == AttrKind::ATTR_NOINLINE as u8 {
            noinl = true;
        } else if kd == AttrKind::ATTR_COLD as u8 {
            cold = true;
        } else if kd == AttrKind::ATTR_USED as u8 {
            used = true;
        } else if kd == AttrKind::ATTR_UNUSED as u8 {
            unused = true;
        } else if kd == AttrKind::ATTR_SECTION as u8 {
            sec = a.attrs.at(k).str_span;
        }
    }
    if inl || always {
        // C11 `extern inline`: the definition still provides the external symbol (plain `inline`
        // would not -- a non-inlined cross-TU caller then fails to link), and carries the hint.
        out.push_str("extern inline ");
    }
    let mut g = String::new();
    if always {
        g.push_str("always_inline");
    }
    if noinl {
        if g.len() != 0 {
            g.push_str(", ");
        }
        g.push_str("noinline");
    }
    if cold {
        if g.len() != 0 {
            g.push_str(", ");
        }
        if noinl {
            g.push_str("cold");
        } else {
            g.push_str("cold, noinline");
        }
    }
    if used {
        if g.len() != 0 {
            g.push_str(", ");
        }
        g.push_str("used");
    }
    if unused {
        if g.len() != 0 {
            g.push_str(", ");
        }
        g.push_str("unused");
    }
    if sec.end > sec.start {
        if g.len() != 0 {
            g.push_str(", ");
        }
        g.push_str("section(\"");
        g.push_str(p.modules.at(m as usize).source.as_str().slice(sec.start as usize, sec.end as usize));
        g.push_str("\")");
    }
    if g.len() != 0 {
        out.push_str("__attribute__((");
        out.push_string(&g);
        out.push_str(")) ");
    }
}

fn cemit_is_noreturn(a: &Ast, nid: NodeId) bool {
    for k in 0..a.attrs.len() {
        let at = a.attrs.at(k);
        if at.owner == nid && at.kind == AttrKind::ATTR_NORETURN as u8 {
            return true;
        }
    }
    return false;
}

// Is `nid` a test-family item (@test/@test_init/@test_free)? Skipped entirely outside --test.
fn cemit_is_test_item(a: &Ast, nid: NodeId) bool {
    for k in 0..a.attrs.len() {
        let at = a.attrs.at(k);
        if at.owner == nid && (at.kind == AttrKind::ATTR_TEST as u8 || at.kind == AttrKind::ATTR_TEST_INIT as u8 || at.kind == AttrKind::ATTR_TEST_FREE as u8) {
            return true;
        }
    }
    return false;
}

/// The whole-package new-backend emission: aggregates, bodies, instances, glue, consts, statics,
/// reflection, macros and (under `testing`) the test wrappers, assembled into shared headers plus
/// one TU per module and one shared instance TU.
// A short display name for the instantiation note: decl names for aggregates, the mangled
// spelling for builtins, "?" when unrenderable.
fn cemit_ty_disp(p: &loader::Package, m: ModuleId, t: TypeId, out: &mut String) {
    let a = unsafe &*p.module_ast_const(m);
    let y = *a.type_at(t);
    let mut dm = y.module;
    let mut dn = NODE_NONE;
    if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
        dn = y.as_data.decl;
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *a.instance(y.as_data.inst);
        dm = it.module;
        dn = it.decl;
    } else if y.kind == TypeKind::TYPE_BUILTIN {
        out.push_str(bt_name(y.as_data.builtin));
        return;
    }
    if dn == NODE_NONE {
        out.push_str("?");
        return;
    }
    let da = unsafe &*p.module_ast_const(dm);
    let mut nm = da.at_const(dn).as_data.aggregate.name;
    if da.at_const(dn).kind == NodeKind::NODE_TYPE_ALIAS {
        nm = da.at_const(dn).as_data.type_alias.name;
    }
    let ns = da.at_const(nm).as_data.name.text;
    out.push_str(p.modules[dm as usize].source.as_str().slice(ns.start as usize, ns.end as usize));
}

// Per-instantiation static_asserts inside a demanded generic body: evaluate each under the
// demand's substitution; false fails the build, naming the first type argument.
fn cemit_inst_asserts(
    p: &mut loader::Package,
    d_def: DefId,
    subs: &Vector<mbe::MSub>,
    dk: u64,
    seen: &mut Map<u64, u64>,
) {
    let hit = switch seen.get(&dk) {
        Some(_v) => true,
        None => false,
    };
    if hit || p.cir == null || subs.len() == 0 {
        return;
    }
    let a = unsafe &*p.module_ast_const(d_def.module);
    if a.at_const(d_def.node).kind != NodeKind::NODE_FUNCTION {
        return;
    }
    let fsp = a.at_const(d_def.node).span;
    let cev = p.cir as *mut iri::Interp;
    let pmod = subs.at(0).pm;
    let mut prm = Array::<NodeId, 8> {};
    let mut ams = Array::<ModuleId, 8> {};
    let mut ats = Array::<TypeId, 8> {};
    let mut np: u8 = 0;
    for k in 0..subs.len() {
        let sb = *subs.at(k);
        if sb.pm == pmod && np < 8 {
            prm[np as usize] = sb.pnode;
            ams[np as usize] = sb.am;
            ats[np as usize] = sb.at;
            np += 1;
        }
    }
    let src = p.modules[d_def.module as usize].source.as_str();
    let mut decided = true;
    for nid in 0..a.nodes.len() {
        let n = a.at_const(nid as NodeId);
        if n.kind != NodeKind::NODE_STATIC_ASSERT || n.span.start < fsp.start || n.span.end > fsp.end {
            continue;
        }
        let bd = n.as_data.binary;
        let cv = cev.eval_typed(d_def.module, bd.left, pmod, &prm[0], &ams[0], &ats[0], np);
        if cv.kind != iri::IV_INT && cv.kind != iri::IV_BOOL {
            decided = false;
            continue;
        }
        if cv.i != 0 {
            continue;
        }
        let mut msg = "static assertion failed";
        if bd.right != NODE_NONE {
            let rsp = a.at_const(bd.right).as_data.literal.raw;
            if rsp.end > rsp.start + 2 {
                msg = diag::span_str(src, rsp.start + 1, rsp.end - 1);
            }
        }
        let mut errs = diag::Errors::new();
        errs.emit(n.span.start, n.span.end - n.span.start, format("static assertion failed: {}", msg));
        if np > 0 {
            let mut tn = String::new();
            cemit_ty_disp(p, ams[0], ats[0], &mut tn);
            errs.note(format("in the instantiation where the first type parameter is '{}'", tn.as_str()));
        }
        errs.finalize(src, p.modules[d_def.module as usize].file.as_str());
        errs.log();
        p.ok = false;
    }
    if decided {
        seen.insert(dk, 1);
    }
}

// The FNV of every `struct <name> {` spelling in `text`: layout asserts probe once per aggregate
// per module, so definition membership must be a set lookup, not a header-wide substring scan.
fn struct_def_names(text: str, out: &mut Set<u64>) {
    let n = text.len();
    let mut i: usize = 0;
    while i + 7 <= n {
        if text.byte_at(i) == b's' && text.slice(i, i + 7) == "struct " {
            let mut j = i + 7;
            let s0 = j;
            while j < n {
                let c = text.byte_at(j);
                let idc = c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_';
                if !idc {
                    break;
                }
                j += 1;
            }
            if j > s0 && j + 2 <= n && text.byte_at(j) == b' ' && text.byte_at(j + 1) == b'{' {
                let mut h = 1469598103934665603u64;
                for k in s0..j {
                    h = (h ^ text.byte_at(k) as u64) * 1099511628211u64;
                }
                out.insert(h);
            }
            i = j;
        } else {
            i += 1;
        }
    }
}

const fn struct_def_hit(defined: &Set<u64>, nm: str) bool {
    let mut h = 1469598103934665603u64;
    for k in 0..nm.len() {
        h = (h ^ nm.byte_at(k) as u64) * 1099511628211u64;
    }
    return defined.contains(&h);
}

// Layout-model verification asserts for module `m`: sizeof/_Alignof of every concrete aggregate
// (extern aggregates especially -- their layout is a CLAIM about a C header) checked against the
// layout service, so the C compiler proves the model on every target.
fn cemit_layout_asserts(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    m: ModuleId,
    defined: &Set<u64>,
    out: &mut String,
) {
    let mut svc = lay::Svc::new(p);
    let mut decls = Vector::<NodeId>::new();
    let mut exts = Vector::<NodeId>::new();
    {
        let a = unsafe &*p.module_ast_const(m);
        let items = a.at_const(a.root).as_data.program.items;
        for i in 0..items.len {
            let nid = unsafe a.list(items)[i as usize];
            let nk = a.at_const(nid).kind;
            if nk == NodeKind::NODE_EXTERN_BLOCK {
                let inner = a.at_const(nid).as_data.extern_block.items;
                for j in 0..inner.len {
                    let iid = unsafe a.list(inner)[j as usize];
                    let ik = a.at_const(iid).kind;
                    if ik == NodeKind::NODE_STRUCT || ik == NodeKind::NODE_ENUM {
                        decls.push(iid);
                        exts.push(iid);
                    }
                }
                continue;
            }
            if nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM {
                continue;
            }
            if a.at_const(nid).as_data.aggregate.generics.len != 0 {
                continue;
            }
            if nk == NodeKind::NODE_ENUM {
                let ms = a.at_const(nid).as_data.aggregate.members;
                let mut pay = false;
                for j in 0..ms.len {
                    let vid = unsafe a.list(ms)[j as usize];
                    if a.at_const(vid).kind == NodeKind::NODE_VARIANT && a.at_const(vid).as_data.variant.payload.len != 0 {
                        pay = true;
                        break;
                    }
                }
                if !pay {
                    continue; // tagless enums have no modelled layout claim
                }
            }
            decls.push(nid);
        }
    }
    let mut any = false;
    for i in 0..decls.len() {
        let nid = decls[i];
        let nk = unsafe (&*p.module_ast_const(m)).at_const(nid).kind;
        let tkind = if nk == NodeKind::NODE_ENUM {
            TypeKind::TYPE_ENUM;
        } else {
            TypeKind::TYPE_STRUCT;
        };
        let t = (&mut p.modules[m as usize].ast).intern_type(Ty { kind: tkind, module: m, as_data: TyAs { decl: nid } });
        let lo = svc.layout(m, t);
        if !lo.ok {
            continue;
        }
        let mut nm = String::new();
        if !cem.mg.ctype(m, t, "", &mut nm) {
            continue;
        }
        let mut is_ext = false;
        for j in 0..exts.len() {
            if exts[j] == nid {
                is_ext = true;
                break;
            }
        }
        if !is_ext {
            // demand-driven emission: only aggregates the plan actually DEFINED can be sized
            if !struct_def_hit(defined, nm.as_str()) {
                continue;
            }
        }
        out.push_str("_Static_assert(sizeof(");
        out.push_string(&nm);
        out.push_str(") == ");
        out.push_u64(lo.size);
        out.push_str(" && _Alignof(");
        out.push_string(&nm);
        out.push_str(") == ");
        out.push_u64(lo.align);
        out.push_str(", \"super-c layout model mismatch: ");
        out.push_string(&nm);
        out.push_str("\");\n");
        any = true;
    }
    {
        let ninst = unsafe (&*p.module_ast_const(m)).instances.len();
        for ii in 0..ninst {
            let it = *unsafe (&*p.module_ast_const(m)).instance(ii as u32);
            if it.module != m {
                continue;
            }
            let t = (&mut p.modules[m as usize].ast).intern_instance(it.module, it.decl, &it.args[0], it.n);
            let lo = svc.layout(m, t);
            if !lo.ok {
                continue;
            }
            let mut nm = String::new();
            if !cem.mg.ctype(m, t, "", &mut nm) {
                continue;
            }
            if !struct_def_hit(defined, nm.as_str()) {
                continue;
            }
            out.push_str("_Static_assert(sizeof(");
            out.push_string(&nm);
            out.push_str(") == ");
            out.push_u64(lo.size);
            out.push_str(" && _Alignof(");
            out.push_string(&nm);
            out.push_str(") == ");
            out.push_u64(lo.align);
            out.push_str(", \"super-c layout model mismatch: ");
            out.push_string(&nm);
            out.push_str("\");\n");
            any = true;
        }
    }
    if any {
        out.push_str("\n");
    }
    svc.free();
}

// Take the graph's cached lowering of `(m, nid)` into `lw_out` -- the graph lowered every body it
// walked exactly once -- lowering in place only when the cache has no live entry. A taken slot is
// removed, so a second taker (a generic body the seed loop lowered and skipped) re-lowers.
fn cemit_take_body(
    g: &mut ig::InstGraph,
    p: *const loader::Package,
    m: ModuleId,
    nid: NodeId,
    lw_out: &mut irl::Lowerer,
) bool {
    let key = skey_mix(0, m as u64 << 32 | nid as u64);
    let ki = switch g.kept_ix.get(&key) {
        Some(v) => (*v) as i64,
        None => (-2) as i64,
    };
    if ki >= 0 {
        *lw_out = replace(&mut g.kept[ki as usize], irl::Lowerer::new(p, m, nid));
        let _ = g.kept_ix.remove(&key);
        return true;
    }
    return lw_out.lower_fn(nid);
}

fn cemit_take_closure(
    g: &mut ig::InstGraph,
    p: *const loader::Package,
    m: ModuleId,
    cn: NodeId,
    lw_out: &mut irl::Lowerer,
) bool {
    let key = skey_mix(0, m as u64 << 32 | cn as u64);
    let ki = switch g.kept_ix.get(&key) {
        Some(v) => (*v) as i64,
        None => (-2) as i64,
    };
    if ki >= 0 {
        *lw_out = replace(&mut g.kept[ki as usize], irl::Lowerer::new(p, m, cn));
        let _ = g.kept_ix.remove(&key);
        return true;
    }
    return lw_out.lower_closure_body(cn);
}

/// Replay one cached module: pool interns first (verified id by id), then the journaled events
/// through the emitter's live dedup gates. 0 = replayed, 1 = clean reject (nothing landed; emit
/// live and re-record), 2 = dirty reject (side effects landed; void the section, skip recording).
fn cemit_tuc_replay(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    m: usize,
    t: &tuc::Tuc,
    bodies_all: &mut String,
    protos: &mut String,
    chunk_mod: &mut Vector<u64>,
    chunk_off: &mut Vector<u64>,
    env_names: &mut Vector<u64>,
    env_bodies: &mut Vector<String>,
    have_main: &mut bool,
    main_mod: &mut u64,
    main_argv: &mut bool,
) i32 {
    let mut rd = tuc::tuc_open(t, m);
    let a = unsafe &mut *(p.module_ast_const(m as ModuleId) as *mut Ast);
    let pr = tuc::replay_pool(&mut rd, a);
    if pr != 0 {
        return pr;
    }
    let nev = tuc::read_count(&mut rd) as usize;
    let mut ev = mbe::RecEv::blank(0);
    for _i in 0..nev {
        if !tuc::read_ev(&mut rd, &mut ev) {
            return 2;
        }
        if ev.kind == mbe::RK_CHUNK {
            chunk_mod.push(m as u64);
            chunk_off.push(bodies_all.len() as u64);
            proto_of(&ev.s1, protos);
            bodies_all.push_string(&ev.s1);
        } else if ev.kind == mbe::RK_ENV {
            env_names.push(ev.h);
            env_bodies.push(ev.s1.clone());
        } else if ev.kind == mbe::RK_AUX {
            cem.aux.push_str(ev.s1.as_str());
        } else if ev.kind == mbe::RK_EFWD {
            cem.env_fwd.push_str(ev.s1.as_str());
        } else if ev.kind == mbe::RK_EDGE {
            for k in 0..ev.xs.len() {
                cem.mg.mark_used(ev.xs[k] as ModuleId);
            }
        } else if ev.kind == mbe::RK_MAIN {
            *have_main = true;
            *main_mod = m as u64;
            *main_argv = ev.a != 0;
        } else {
            cem.tuc_replay(&ev);
        }
    }
    if !rd.ok || rd.at != rd.end {
        return 2;
    }
    return 0;
}

pub fn cemit_package(
    p: &mut loader::Package,
    testing: bool,
    tplan: &TestPlan,
    live: *const bool,
    target: i32,
    o: &mut CemitOut,
    irkeep: *mut irl::Keep,
) {
    let verbose = stdlib::getenv("SC_CEMIT_TU") != null || stdlib::getenv("SC_CEMIT_STATS") != null;
    p.ensure_sigs(); // the planner's signature-level propagation reads the package metadata
    let mut g = ig::InstGraph::new(p, irkeep);
    g.collect();
    let mut em = tbe::TuEmit::new(p);
    em.mg.agg_on = true;
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
    // dyn typedef blocks splice in AFTER these forward typedefs and BEFORE the definitions:
    // vtable signatures may name aggregates (fn-pointer params need only the typedef), and
    // aggregates may embed fat values (which need the complete dyn struct)
    let fwd_end = em.out.len();
    for i in 0..items.len() {
        let it = *items.at(i);
        let _ = em.emit_agg(&it);
    }
    // Demand-driven monomorphization: emit every concrete standalone body with demand collection
    // on, then drain the queue -- each demanded instance re-emits the generic Core body under its
    // recorded substitution chain. The drained symbol set is the closed instance set the old
    // propagation computed, derived from Core IR alone.
    let mut cem = cbe::CEmit::new(p);
    cem.collect_demand = true;
    cem.mg.agg_on = true;
    {
        let ne0 = em.env_defined.len();
        for ei in 0..ne0 {
            let h0 = *em.env_defined.at(ei);
            cem.env_skip.insert(h0, 1);
        }
    }
    // header-backed extern includes ship real prototypes: collect them (and the fns they declare,
    // so call sites never synthesize conflicting protos)
    let mut ext_incs = String::new();
    cemit_extern_includes(p, &mut ext_incs, &mut cem.ext_backed);
    let mut dow = DropCtx {
        ow: bfx::Owner::new(p),
        forest: bmp::MoveForest::empty(),
        facts: bfx::BodyFacts::empty(),
        cfg: bdf::Cfg::empty(),
        mv: bdf::MoveFlow::empty(),
        el: ird::ElabCtx::empty(),
    };
    let mut lw_cache = Map::<u64, u64>::new();
    let mut lws = Vector::<irl::Lowerer>::new();
    // closure lowerings, drops applied, shared by the seed and instance loops (a demanded generic
    // body re-emits its closures per instantiation; the lowering is instantiation-independent)
    let mut cl_cache = Map::<u64, u64>::new();
    let mut clws = Vector::<irl::Lowerer>::new();
    let mut seeds: u64 = 0;
    let mut seed_skip: u64 = 0;
    let mut clos_ok: u64 = 0;
    let mut clos_skip: u64 = 0;
    let mut bodies_all = String::new();
    let mut protos = String::new();
    // pre-size the two whole-package accumulators from the corpus (emitted C runs ~10 bytes per
    // AST node): one sized request instead of a doubling-growth chain over multi-MB buffers
    {
        let mut est_nodes: usize = 0;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast {
                est_nodes += p.modules[m].ast.nodes.len();
            }
        }
        bodies_all.reserve(est_nodes * 10);
        protos.reserve(est_nodes);
    }
    let mut envs_all = String::new();
    let mut env_bodies = Vector::<String>::new();
    let mut env_names = Vector::<u64>::new();
    let mut have_main = false;
    let mut main_argv = false;
    let mut main_mod: u64 = 0;
    // chunk provenance: proto_of precedes every body push, so prototype line k pairs with chunk k;
    // chunk_mod is the owning TU (65534 = the shared instance TU), chunk_off the bodies_all offset
    let mut chunk_mod = Vector::<u64>::new();
    let mut chunk_off = Vector::<u64>::new();
    // Per-TU cache: fingerprint every module up front; a hit replays the module's journaled side
    // effects instead of lowering it, a miss emits live under journaling. Test builds opt out (the
    // wrapper set would join the fingerprint for little gain).
    let mut tuc = tuc::tuc_setup(
        p,
        live,
        target,
        if testing {
            "";
        } else {
            p.gen_root.as_str();
        },
    );
    let mut tuc_pay = String::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || live != null && p.modules[m].prelude && !unsafe live[m] {
            // no seeds (missing AST / unreachable prelude): an empty section keeps the image indexed
            if tuc.on {
                tuc_pay.truncate(0);
                tuc::sec_add(&mut tuc, m, &tuc_pay);
            }
            continue;
        }
        cem.mg.mark_ctx = m as i64; // symbols the module spells about ITSELF are not cross-TU uses
        let mut tuc_rec = false;
        if tuc.on {
            if tuc.hit[m] {
                let rr = cemit_tuc_replay(
                    p,
                    &mut cem,
                    m,
                    &tuc,
                    &mut bodies_all,
                    &mut protos,
                    &mut chunk_mod,
                    &mut chunk_off,
                    &mut env_names,
                    &mut env_bodies,
                    &mut have_main,
                    &mut main_mod,
                    &mut main_argv,
                );
                if rr == 0 {
                    tuc::sec_keep(&mut tuc, m);
                    continue;
                }
                // clean rejects are ordinary churn (another module's typecheck moved this pool);
                // a DIRTY reject means interns landed before diverging -- warn and void the section
                if rr == 2 {
                    eprint("tu-cache: dirty replay reject for `{}`; emitting live\n", p.modules[m].path.as_str());
                    tuc::sec_void(&mut tuc, m);
                }
                tuc_rec = rr == 1;
            } else {
                tuc_rec = true;
            }
        }
        let mut tuc_seg0: usize = 0;
        let mut tuc_t0: usize = 0;
        let mut tuc_i0: usize = 0;
        let mut tuc_aux0: usize = 0;
        let mut tuc_efwd0: usize = 0;
        let mut tuc_eh0: usize = 0;
        if tuc_rec {
            cem.mg.rec_on = true;
            tuc_seg0 = cem.mg.rec.len();
            let a0 = unsafe &*p.module_ast_const(m as ModuleId);
            tuc_t0 = a0.type_pool.len();
            tuc_i0 = a0.instances.len();
            tuc_aux0 = cem.aux.len();
            tuc_efwd0 = cem.env_fwd.len();
            tuc_eh0 = cem.env_hashes.len();
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let its = a.at_const(a.root).as_data.program.items;
        let mut cands = Vector::<NodeId>::new();
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
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
            if !testing && cemit_is_test_item(a, nid) {
                continue; // test-family items exist only under --test
            }
            if cem.mg.in_generic_extend(m as ModuleId, nid) {
                continue; // its instances are demand-emitted; leave the cached body for them
            }
            let mut lw = irl::Lowerer::new(p, m as ModuleId, nid);
            if !cemit_take_body(&mut g, p, m as ModuleId, nid, &mut lw) {
                continue;
            }
            if lw.body.is_generic {
                continue;
            }
            cemit_apply_drops(&mut dow, &mut lw);
            let mut sym = String::new();
            let tgt = cem.mg.method_target(m as ModuleId, nid);
            if !cem.mg.fn_sym(m as ModuleId, nid, tgt, true, &mut sym) {
                continue;
            }
            if sym.as_str() == "assert" || sym.as_str() == "assert_eq" || sym.as_str() == "assert_ne" {
                continue; // desugared builtins; the C names collide with <assert.h>'s macro
            }
            cem.out.clear();
            let is_main = sym.as_str() == "main";
            if is_main {
                sym.truncate(0);
                sym.push_str("__sc_user_main"); // the argv wrapper below owns the C `main`
            }
            let mut gfs = Vector::<String>::new();
            let mut gts = Vector::<TypeId>::new();
            let is_glue = cemit_free_glue_fields(p, &mut cem, m as ModuleId, nid, &mut gfs, &mut gts);
            if is_glue {
                sym.push_str("__fb");
            }
            cem.noret = cemit_is_noreturn(a, nid);
            cem.fn_attrs.truncate(0);
            cemit_fn_attrs(p, m as ModuleId, nid, &mut cem.fn_attrs);
            if cem.emit_fn(&lw.body, sym.as_str()) {
                seeds += 1;
                if is_main {
                    have_main = true;
                    main_mod = m as u64;
                    main_argv = n.as_data.function.params.len != 0;
                    if cem.mg.rec_on {
                        let mut ev9 = mbe::RecEv::blank(mbe::RK_MAIN);
                        ev9.a = if main_argv {
                            1u32;
                        } else {
                            0;
                        };
                        cem.mg.rec.push(ev9);
                    }
                }
                {
                    chunk_mod.push(m as u64);
                    chunk_off.push(bodies_all.len() as u64);
                    proto_of(&cem.out, &mut protos);
                    bodies_all.push_string(&cem.out);
                    if cem.mg.rec_on {
                        let mut ev9 = mbe::RecEv::blank(mbe::RK_CHUNK);
                        ev9.a = chunk_off[chunk_off.len() - 1] as u32;
                        ev9.b = bodies_all.len() as u32;
                        cem.mg.rec.push(ev9);
                    }
                }
                if is_glue {
                    // the public wrapper: the sig is the __fb sig without the suffix
                    let mut wr = String::new();
                    let bs9 = cem.out.as_str();
                    let mut le = 0 as usize;
                    while le < bs9.len() && bs9.byte_at(le) != 10 {
                        le += 1;
                    }
                    let sig = bs9.slice(0, le);
                    let mut cut = 0 as usize;
                    while cut + 4 < sig.len() && sig.slice(cut, cut + 5) != "__fb(" {
                        cut += 1;
                    }
                    wr.push_str(sig.slice(0, cut));
                    wr.push_str(sig.slice(cut + 4, sig.len()));
                    // The receiver is the first argument (locals are return-slots then args): ask the
                    // emitter for its C spelling -- it may preserve the source name (`self`) over `_N`.
                    let mut selfp = String::new();
                    cem.local_cname(lw.body.returns, &mut selfp);
                    wr.push_str("\n  ");
                    wr.push_str(sym.as_str());
                    wr.push_str("(");
                    wr.push_string(&selfp);
                    wr.push_str(");\n");
                    let mut wok = true;
                    for gi in 0..gfs.len() {
                        if !wok {
                            break;
                        }
                        let mut fe9 = String::new();
                        let mut frm9 = m as ModuleId;
                        let mut frt9 = gts[gi];
                        let _ = cem.mg.resolve(m as ModuleId, gts[gi], &mut frm9, &mut frt9);
                        wok = cem.free_expr(frm9, frt9, &mut fe9);
                        if wok {
                            wr.push_str("  ");
                            wr.push_string(&fe9);
                            if cem.mg.is_zst(frm9, frt9) {
                                // the field has no C member: its destructor runs on the sentinel
                                wr.push_str("(");
                                let mut zr9 = String::new();
                                let _ = cem.zst_sentinel_ref(frm9, frt9, &mut zr9);
                                wr.push_string(&zr9);
                                wr.push_str(");\n");
                            } else {
                                wr.push_str("(&");
                                wr.push_string(&selfp);
                                wr.push_str("->");
                                wr.push_string(&gfs[gi]);
                                wr.push_str(");\n");
                            }
                        }
                    }
                    wr.push_str("}\n");
                    if wok {
                        chunk_mod.push(m as u64);
                        chunk_off.push(bodies_all.len() as u64);
                        proto_of(&wr, &mut protos);
                        bodies_all.push_string(&wr);
                        if cem.mg.rec_on {
                            let mut ev9 = mbe::RecEv::blank(mbe::RK_CHUNK);
                            ev9.a = chunk_off[chunk_off.len() - 1] as u32;
                            ev9.b = bodies_all.len() as u32;
                            cem.mg.rec.push(ev9);
                        }
                    }
                }
                let mut clsq = Vector::<NodeId>::new();
                for c2 in 0..lw.closures.len() {
                    clsq.push(lw.closures[c2]);
                }
                let mut cqi: usize = 0;
                while cqi < clsq.len() {
                    let cn = clsq[cqi];
                    cqi += 1;
                    let ckey = skey_mix(0, m as u64 << 32 | cn as u64);
                    let ci = switch cl_cache.get(&ckey) {
                        Some(v) => *v,
                        None => {
                            let mut cl = irl::Lowerer::new(p, m as ModuleId, cn);
                            let mut slot = 0xFFFFFFFFFFFFFFFFu64;
                            if cemit_take_closure(&mut g, p, m as ModuleId, cn, &mut cl) {
                                cemit_apply_drops(&mut dow, &mut cl);
                                slot = clws.len() as u64;
                                clws.push(cl);
                            }
                            cl_cache.insert(ckey, slot);
                            slot;
                        },
                    };
                    let mut csym = String::new();
                    cem.mg.closure_sym(m as ModuleId, cn, &mut csym);
                    let mut envs = String::new();
                    cem.out.clear();
                    let cok = ci != 0xFFFFFFFFFFFFFFFFu64;
                    if cok {
                        for x2 in 0..clws.at(ci as usize).closures.len() {
                            clsq.push(clws.at(ci as usize).closures[x2]); // closures nest: emit the inner ones too
                        }
                    }
                    if cok && cem.emit_closure(&clws.at(ci as usize).body, m as ModuleId, cn, csym.as_str(), &mut envs) {
                        clos_ok += 1;
                        {
                            if envs.len() != 0 {
                                let mut eh9 = 1469598103934665603u64;
                                {
                                    let mut en9 = String::from_str(csym.as_str());
                                    en9.push_str("_env");
                                    let es9 = en9.as_str();
                                    for k9 in 0..es9.len() {
                                        eh9 = (eh9 ^ es9.byte_at(k9) as u64) * 1099511628211u64;
                                    }
                                }
                                env_names.push(eh9);
                                env_bodies.push(envs.clone());
                                if cem.mg.rec_on {
                                    let mut ev9 = mbe::RecEv::blank(mbe::RK_ENV);
                                    ev9.h = eh9;
                                    ev9.s1 = envs.clone();
                                    cem.mg.rec.push(ev9);
                                }
                            }
                        }
                        chunk_mod.push(m as u64);
                        chunk_off.push(bodies_all.len() as u64);
                        proto_of(&cem.out, &mut protos);
                        bodies_all.push_string(&cem.out);
                        if cem.mg.rec_on {
                            let mut ev9 = mbe::RecEv::blank(mbe::RK_CHUNK);
                            ev9.a = chunk_off[chunk_off.len() - 1] as u32;
                            ev9.b = bodies_all.len() as u32;
                            cem.mg.rec.push(ev9);
                        }
                    } else {
                        clos_skip += 1;
                    }
                }
            } else {
                seed_skip += 1;
                if verbose {
                    eprint("seed-emit-fail: `{}` {}\n", sym.as_str(), cem.err);
                }
            }
        }
        if tuc_rec {
            cem.mg.rec_on = false;
            // trailing delta events: their accumulators are consumed whole at assembly, so only
            // their internal order matters
            if cem.aux.len() > tuc_aux0 {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_AUX);
                ev9.s1.push_str(cem.aux.as_str().slice(tuc_aux0, cem.aux.len()));
                cem.mg.rec.push(ev9);
            }
            if cem.env_fwd.len() > tuc_efwd0 {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_EFWD);
                ev9.s1.push_str(cem.env_fwd.as_str().slice(tuc_efwd0, cem.env_fwd.len()));
                cem.mg.rec.push(ev9);
            }
            for k9 in tuc_eh0..cem.env_hashes.len() {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_EDEF);
                ev9.h = *cem.env_hashes.at(k9);
                cem.mg.rec.push(ev9);
            }
            {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_EDGE);
                for dst in 0..p.modules.len() {
                    if cem.mg.um_hit(m as u64, dst) {
                        ev9.xs.push(dst as u32);
                    }
                }
                cem.mg.rec.push(ev9);
            }
            let a2 = unsafe &*p.module_ast_const(m as ModuleId);
            tuc_pay.truncate(0);
            tuc::ser_pool(&mut tuc_pay, a2, tuc_t0, a2.type_pool.len(), tuc_i0, a2.instances.len());
            tuc::ser_evs(&mut tuc_pay, &cem.mg.rec, tuc_seg0, bodies_all.as_str());
            tuc::sec_add(&mut tuc, m, &tuc_pay);
            cem.mg.rec.truncate(tuc_seg0);
        }
    }
    // @test wrappers: per-case runner entry points + the global-env hooks, emitted as ordinary
    // chunks of their owning module's TU (their fixture frees join the glue/demand worklists)
    let mut tw_ok: u64 = 0;
    let mut tw_skip: u64 = 0;
    if testing && tplan.ok && tplan.cases.len() != 0 {
        for ci in 0..tplan.cases.len() {
            let tc = tplan.cases[ci];
            let suite = tc.suite.node != NODE_NONE;
            let fxi = if suite {
                tc.suite_init;
            } else {
                tplan.fx_init[tc.mod as usize];
            };
            let fxf = if suite {
                tc.suite_free;
            } else {
                tplan.fx_free[tc.mod as usize];
            };
            cem.out.clear();
            if cem.emit_test_wrapper(tc.mod, tc.func, tc.wants, fxi, fxf, tplan.genv_mod, tplan.genv_init) {
                tw_ok += 1;
                chunk_mod.push(tc.mod);
                chunk_off.push(bodies_all.len() as u64);
                proto_of(&cem.out, &mut protos);
                bodies_all.push_string(&cem.out);
            } else {
                tw_skip += 1;
                eprint("cemit-test-miss: {}\n", cem.err);
            }
        }
        if tplan.genv_init != NODE_NONE {
            cem.out.clear();
            if cem.emit_test_genv(tplan.genv_mod, tplan.genv_init, tplan.genv_free) {
                tw_ok += 1;
                chunk_mod.push(tplan.genv_mod);
                chunk_off.push(bodies_all.len() as u64);
                proto_of(&cem.out, &mut protos);
                bodies_all.push_string(&cem.out);
            } else {
                tw_skip += 1;
                eprint("cemit-test-miss: {}\n", cem.err);
            }
        }
        if verbose {
            eprint("cemit-tests: {} wrappers, {} skipped\n", tw_ok, tw_skip);
        }
    }
    let mut done = Map::<u64, u64>::new();
    // per-lowering CFGs, built once and lent to every instantiation's emission (see CEmit.cf_ext)
    let mut cfs = Vector::<cfl::CFlow>::new();
    let mut cf_ok = Vector::<bool>::new();
    let mut sa_seen = Map::<u64, u64>::new();
    let mut inst_ok: u64 = 0;
    let mut inst_skip: u64 = 0;
    let mut glue_ok: u64 = 0;
    let mut glue_skip: u64 = 0;
    let mut gi9: usize = 0;
    let mut reasons = Vector::<str<'static>>::new();
    let mut rcounts = Vector::<u64>::new();
    cem.mg.mark_ctx = -1; // instance-TU emission: every spelled module is link-reachable
    let mut qi: usize = 0;
    while (qi < cem.demand.len() || gi9 < cem.glue.len()) && qi < 200000 {
        // derived destructors drain alongside instances (each may enqueue the other)
        while gi9 < cem.glue.len() {
            cem.out.clear();
            if cem.emit_glue(gi9) {
                glue_ok += 1;
                chunk_mod.push(65534);
                chunk_off.push(bodies_all.len() as u64);
                proto_of(&cem.out, &mut protos);
                bodies_all.push_string(&cem.out);
            } else {
                if verbose {
                    eprint("glue-emit-fail: `{}` {}\n", cem.glue.at(gi9).sym.as_str(), cem.err);
                }
                glue_skip += 1;
            }
            gi9 += 1;
        }
        if qi >= cem.demand.len() {
            continue;
        }
        let d_def = cem.demand.at(qi).def;
        let ds = cem.demand.at(qi).sym.as_str();
        let mut dk = 1469598103934665603u64;
        for k in 0..ds.len() {
            dk = (dk ^ ds.byte_at(k) as u64) * 1099511628211u64;
        }
        // dedup on SUCCESS only: two demands for one symbol can carry different substitution
        // chains, and the first may be the incomplete one -- a later, fuller chain must retry
        let seen = switch done.get(&dk) {
            Some(_v) => true,
            None => false,
        };
        if seen {
            qi += 1;
            continue;
        }
        let d_sym = cem.demand.at(qi).sym.clone();
        let mut d_subs = Vector::<mbe::MSub>::new();
        for i2 in 0..cem.demand.at(qi).subs.len() {
            d_subs.push(*cem.demand.at(qi).subs.at(i2));
        }
        qi += 1;
        let key = skey_mix(0, d_def.module as u64 << 32 | d_def.node as u64);
        let li = switch lw_cache.get(&key) {
            Some(v) => *v,
            None => {
                let mut lw = irl::Lowerer::new(p, d_def.module, d_def.node);
                let okl = cemit_take_body(&mut g, p, d_def.module, d_def.node, &mut lw);
                let mut slot = 0xFFFFFFFFFFFFFFFFu64;
                if okl {
                    cemit_apply_drops(&mut dow, &mut lw);
                    slot = lws.len() as u64;
                    lws.push(lw);
                } else {
                    eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw.err);
                }
                lw_cache.insert(key, slot);
                slot;
            },
        };
        if li == 0xFFFFFFFFFFFFFFFFu64 {
            inst_skip += 1;
            continue;
        }
        let d_sfx = cem.demand.at(qi - 1).sfx.clone();
        // per-instantiation static_asserts: under this demand's substitution the condition is
        // this instance's compile-time fact -- false is a COMPILE error naming the type argument
        cemit_inst_asserts(p, d_def, &d_subs, dk, &mut sa_seen);
        // a body with an UNEXPANDED reflection binder re-lowers per instance: the demand env
        // makes the binder's owner concrete, so the copies expand for real. A body whose only
        // env-dependence is `sizeof(T) <op> 0` branches re-lowers once per ZST-BIT SIGNATURE of
        // its args -- every material instantiation folds identically and shares one body.
        let mut li2 = li;
        if lws.at(li as usize).body.has_reflect {
            if stdlib::getenv("SC_PROJ_DBG") != null {
                eprint("proj-relower: `{}` subs {}\n", d_sym.as_str(), d_subs.len());
            }
            let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
            for i2 in 0..d_subs.len() {
                let sb2 = *d_subs.at(i2);
                lw2.env.push(irl::LSub { pm: sb2.pm, pnode: sb2.pnode, am: sb2.am, at: sb2.at });
            }
            if lw2.lower_fn(d_def.node) {
                cemit_apply_drops(&mut dow, &mut lw2);
                lws.push(lw2);
                li2 = lws.len() as u64 - 1;
            } else {
                if verbose {
                    eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
                }
                inst_skip += 1;
                continue;
            }
        } else if lws.at(li as usize).body.has_zst_cond {
            let mut zb: u64 = 1;
            for i2 in 0..d_subs.len() {
                let sb2 = *d_subs.at(i2);
                zb = zb << 1 | if cem.mg.is_zst(sb2.am, sb2.at) {
                    1u64;
                } else {
                    0 as u64;
                };
            }
            let zkey = skey_mix(zb, d_def.module as u64 << 32 | d_def.node as u64);
            let zi = switch lw_cache.get(&zkey) {
                Some(v) => *v,
                None => {
                    let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
                    for i2 in 0..d_subs.len() {
                        let sb2 = *d_subs.at(i2);
                        lw2.env.push(irl::LSub { pm: sb2.pm, pnode: sb2.pnode, am: sb2.am, at: sb2.at });
                    }
                    let mut slot2 = 0xFFFFFFFFFFFFFFFFu64;
                    if lw2.lower_fn(d_def.node) {
                        cemit_apply_drops(&mut dow, &mut lw2);
                        slot2 = lws.len() as u64;
                        lws.push(lw2);
                    } else {
                        if verbose {
                            eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
                        }
                    }
                    lw_cache.insert(zkey, slot2);
                    slot2;
                },
            };
            if zi == 0xFFFFFFFFFFFFFFFFu64 {
                inst_skip += 1;
                continue;
            }
            li2 = zi;
        }
        cem.mg.subs.truncate(0);
        for i2 in 0..d_subs.len() {
            cem.mg.push_msub(*d_subs.at(i2));
        }
        cem.mg.clos_sfx.truncate(0);
        cem.mg.clos_sfx.push_string(&d_sfx);
        cem.mg.clos_ids.truncate(0);
        for c2 in 0..lws.at(li2 as usize).closures.len() {
            cem.mg.clos_ids.push(lws.at(li2 as usize).closures[c2]);
        }
        {
            // every lws slot gets a cached CFlow: shared zst-signature bodies and reflect
            // re-lowers alike (a per-slot build amortizes across their instantiations)
            while cfs.len() <= li2 as usize {
                cfs.push(cfl::CFlow::new_empty());
                cf_ok.push(false);
            }
            if !cf_ok[li2 as usize] {
                let cfp = &mut cfs[li2 as usize];
                cfp.build_into(&lws.at(li2 as usize).body);
                cf_ok.set(li2 as usize, true);
            }
            cem.cf_ext = cfs.at(li2 as usize);
        }
        cem.out.clear();
        cem.fn_attrs.truncate(0);
        cemit_fn_attrs(p, d_def.module, d_def.node, &mut cem.fn_attrs);
        let em_ok9 = cem.emit_fn(&lws.at(li2 as usize).body, d_sym.as_str());
        cem.cf_ext = null;
        if em_ok9 {
            done.insert(dk, 1);
            inst_ok += 1;
            chunk_mod.push(65534);
            chunk_off.push(bodies_all.len() as u64);
            proto_of(&cem.out, &mut protos);
            bodies_all.push_string(&cem.out);
            let mut clsq = Vector::<NodeId>::new();
            for c2 in 0..lws.at(li2 as usize).closures.len() {
                clsq.push(lws.at(li2 as usize).closures[c2]);
            }
            let mut cqi: usize = 0;
            while cqi < clsq.len() {
                let cn = clsq[cqi];
                cqi += 1;
                let ckey = skey_mix(0, d_def.module as u64 << 32 | cn as u64);
                let ci = switch cl_cache.get(&ckey) {
                    Some(v) => *v,
                    None => {
                        let mut cl = irl::Lowerer::new(p, d_def.module, cn);
                        let mut slot = 0xFFFFFFFFFFFFFFFFu64;
                        if cemit_take_closure(&mut g, p, d_def.module, cn, &mut cl) {
                            cemit_apply_drops(&mut dow, &mut cl);
                            slot = clws.len() as u64;
                            clws.push(cl);
                        }
                        cl_cache.insert(ckey, slot);
                        slot;
                    },
                };
                let mut csym = String::new();
                cem.mg.closure_sym(d_def.module, cn, &mut csym);
                let mut envs = String::new();
                cem.out.clear();
                let cok = ci != 0xFFFFFFFFFFFFFFFFu64;
                if cok {
                    for x2 in 0..clws.at(ci as usize).closures.len() {
                        clsq.push(clws.at(ci as usize).closures[x2]); // closures nest: emit the inner ones too
                    }
                }
                if cok && cem.emit_closure(&clws.at(ci as usize).body, d_def.module, cn, csym.as_str(), &mut envs) {
                    clos_ok += 1;
                    {
                        if envs.len() != 0 {
                            let mut eh9 = 1469598103934665603u64;
                            {
                                let mut en9 = String::from_str(csym.as_str());
                                en9.push_str("_env");
                                let es9 = en9.as_str();
                                for k9 in 0..es9.len() {
                                    eh9 = (eh9 ^ es9.byte_at(k9) as u64) * 1099511628211u64;
                                }
                            }
                            env_names.push(eh9);
                            env_bodies.push(envs.clone());
                        }
                    }
                    chunk_mod.push(65534);
                    chunk_off.push(bodies_all.len() as u64);
                    proto_of(&cem.out, &mut protos);
                    bodies_all.push_string(&cem.out);
                } else {
                    clos_skip += 1;
                }
            }
        } else {
            if verbose {
                eprint("inst-emit-fail: `{}` {}\n", d_sym.as_str(), cem.err);
            }
            let mut found = false;
            for r2 in 0..reasons.len() {
                if reasons[r2] == cem.err {
                    rcounts.set(r2, rcounts[r2] + 1);
                    found = true;
                    break;
                }
            }
            if !found {
                reasons.push(cem.err);
                rcounts.push(1);
            }
        }
        cem.mg.subs.truncate(0);
        cem.mg.clos_sfx.truncate(0);
        cem.mg.clos_ids.truncate(0);
    }
    // true instance failures = demanded symbols that never emitted on ANY chain
    {
        let mut fseen = Map::<u64, u64>::new();
        for di9 in 0..cem.demand.len() {
            let fs9 = cem.demand.at(di9).sym.as_str();
            let mut fk9 = 1469598103934665603u64;
            for k9 in 0..fs9.len() {
                fk9 = (fk9 ^ fs9.byte_at(k9) as u64) * 1099511628211u64;
            }
            let emitted9 = switch done.get(&fk9) {
                Some(_v) => true,
                None => false,
            };
            let counted9 = switch fseen.get(&fk9) {
                Some(_v) => true,
                None => false,
            };
            if !emitted9 && !counted9 {
                fseen.insert(fk9, 1);
                inst_skip += 1;
            }
        }
    }
    if verbose {
        eprint(
            "cemit-tu-inst: {} seeds ({} skipped), {} instances, {} inst-skipped, {} demanded, {} closures ({} skipped), {} glue ({} skipped)\n",
            seeds,
            seed_skip,
            inst_ok,
            inst_skip,
            cem.demand.len(),
            clos_ok,
            clos_skip,
            glue_ok,
            glue_skip,
        );
    }
    for r2 in 0..reasons.len() {
        eprint("cemit-tu-inst-miss: {} x{}\n", reasons[r2], rcounts[r2]);
    }
    o.skips += seed_skip + inst_skip + clos_skip + glue_skip + tw_skip;
    if have_main && main_argv && !testing {
        let mut sn9 = String::new();
        cem.sentinel(1, &mut sn9); // the argv wrapper's Global allocator receiver
    }
    // `@emit_macro` C-reuse templates: `<STEM>_DECLARE/_DEFINE(<params>, NAME)` -- the struct body
    // plus every non-generic method of the type's plain generic extends, emitted through cemit
    // under macro spelling (unresolved params as their names; symbols pasted onto NAME)
    let mut macros_out = String::new();
    {
        let mut mac_ok: u64 = 0;
        let mut mac_skip: u64 = 0;
        for m9 in 0..p.modules.len() {
            if !p.modules[m9].has_ast {
                continue;
            }
            let a9 = unsafe &*p.module_ast_const(m9 as ModuleId);
            let its9 = a9.at_const(a9.root).as_data.program.items;
            for i9 in 0..its9.len {
                let nid9 = unsafe a9.list(its9)[i9 as usize];
                let n9 = a9.at_const(nid9);
                if n9.kind != NodeKind::NODE_STRUCT || n9.as_data.aggregate.generics.len == 0 {
                    continue;
                }
                let mut tagged = false;
                for k9 in 0..a9.attrs.len() {
                    if a9.attrs.at(k9).owner == nid9 && a9.attrs.at(k9).kind == AttrKind::ATTR_EMIT_MACRO as u8 {
                        tagged = true;
                        break;
                    }
                }
                if !tagged {
                    continue;
                }
                // the raw (pre-rewrite) bodies of the two templates
                let mut mb_dec = String::new();
                let mut mb_def = String::new();
                cem.mg.macro_on = true;
                let mut okm = true;
                mb_dec.push_str("typedef struct NAME NAME;\nstruct NAME {\n");
                let fs9 = n9.as_data.aggregate.members;
                for j9 in 0..fs9.len {
                    if !okm {
                        break;
                    }
                    let fid = unsafe a9.list(fs9)[j9 as usize];
                    if a9.at_const(fid).kind != NodeKind::NODE_FIELD {
                        continue;
                    }
                    let mut fnm = String::new();
                    cem.mg.ident(
                        m9 as ModuleId,
                        a9.at_const(a9.at_const(fid).as_data.field.name).as_data.name.text,
                        &mut fnm,
                    );
                    mb_dec.push_str("  ");
                    okm = cem.mg.ctype(
                        m9 as ModuleId,
                        a9.type_of(a9.at_const(fid).as_data.field.ty),
                        fnm.as_str(),
                        &mut mb_dec,
                    );
                    mb_dec.push_str(";\n");
                }
                mb_dec.push_str("};\n");
                // every non-generic single-return method of the type's plain generic extends
                for j9 in 0..its9.len {
                    if !okm {
                        break;
                    }
                    let eid = unsafe a9.list(its9)[j9 as usize];
                    let en = a9.at_const(eid);
                    if en.kind != NodeKind::NODE_EXTEND || en.as_data.extend_def.generics.len == 0 {
                        continue;
                    }
                    if en.as_data.extend_def.interface_type != NODE_NONE {
                        continue;
                    }
                    if a9.resolution(en.as_data.extend_def.target_type) != nid9 {
                        continue;
                    }
                    let ms9 = en.as_data.extend_def.items;
                    for k9 in 0..ms9.len {
                        if !okm {
                            break;
                        }
                        let mid9 = unsafe a9.list(ms9)[k9 as usize];
                        let mn9 = a9.at_const(mid9);
                        if mn9.kind != NodeKind::NODE_FUNCTION || mn9.as_data.function.generics.len != 0 || mn9.as_data.function.returns.len > 1 {
                            continue;
                        }
                        if mn9.as_data.function.body == NODE_NONE {
                            continue;
                        }
                        let mut mlw = irl::Lowerer::new(p, m9 as ModuleId, mid9);
                        if !mlw.lower_fn(mid9) {
                            okm = false;
                            break;
                        }
                        cemit_apply_drops(&mut dow, &mut mlw);
                        let mut msym = String::from_str("NAME");
                        msym.push_byte(1);
                        msym.push_str("__");
                        cem.mg.ident(
                            m9 as ModuleId,
                            a9.at_const(mn9.as_data.function.name).as_data.name.text,
                            &mut msym,
                        );
                        cem.out.clear();
                        if cem.emit_fn(&mlw.body, msym.as_str()) {
                            proto_of(&cem.out, &mut mb_dec);
                            mb_def.push_string(&cem.out);
                        } else {
                            okm = false;
                        }
                    }
                }
                cem.mg.macro_on = false;
                if okm {
                    let mut stem = String::new();
                    macro_stem(
                        &mut cem.mg,
                        m9 as ModuleId,
                        a9.at_const(n9.as_data.aggregate.name).as_data.name.text,
                        &mut stem,
                    );
                    macros_out.push_str("#define ");
                    macros_out.push_string(&stem);
                    macros_out.push_str("_DECLARE(");
                    macro_params(p, &mut cem.mg, m9 as ModuleId, n9.as_data.aggregate.generics, &mut macros_out);
                    macro_finish(mb_dec.as_str(), &mut macros_out);
                    macros_out.push_str("#define ");
                    macros_out.push_string(&stem);
                    macros_out.push_str("_DEFINE(");
                    macro_params(p, &mut cem.mg, m9 as ModuleId, n9.as_data.aggregate.generics, &mut macros_out);
                    macro_finish(mb_def.as_str(), &mut macros_out);
                    mac_ok += 1;
                } else {
                    mac_skip += 1;
                }
            }
        }
        if verbose && (mac_ok != 0 || mac_skip != 0) {
            eprint("cemit-macros: {} templates, {} skipped\n", mac_ok, mac_skip);
        }
        o.skips += mac_skip;
    }
    // dyn typedef blocks: drain every dyn spelling site both manglers recorded (rendering can
    // discover further stems; the index loop rides the growing vector to a fixed point)
    {
        for i in 0..em.mg.dyn_reqs.len() {
            let rq = *em.mg.dyn_reqs.at(i);
            cem.mg.dyn_reqs.push(rq);
        }
        let mut di: usize = 0;
        while di < cem.mg.dyn_reqs.len() {
            let rq = *cem.mg.dyn_reqs.at(di);
            let _ = cem.dyn_request(rq.pm, rq.t);
            di += 1;
        }
    }
    // const/static definitions: each referenced item folds through the Core IR interpreter; one
    // interpreter serves the whole pass (its lowered-callee cache, call memo, and captured static
    // groups persist), and the descriptor sections below render from the same store
    let mut cdit = iri::interp_new(p);
    let mut const_defs = String::new();
    {
        let mut cd_ok: u64 = 0;
        let mut cd_skip: u64 = 0;
        for ci in 0..cem.stat_items.len() {
            let em2 = cem.stat_items.at(ci).em;
            let cdef = cem.stat_items.at(ci).def;
            let csym = cem.stat_items.at(ci).sym.clone();
            let cda = unsafe &*p.module_ast_const(cdef.module);
            let cdn = cda.at_const(cdef.node);
            if cdn.kind == NodeKind::NODE_CONST && cdn.as_data.const_def.is_extern {
                continue; // the backing C header owns the definition; the extern stub suffices
            }
            if cdn.kind != NodeKind::NODE_CONST || cdn.as_data.const_def.value == NODE_NONE {
                cd_skip += 1;
                continue;
            }
            if cem.mg.method_target(cdef.module, cdef.node).node != NODE_NONE {
                cd_skip += 1; // associated consts fold under Self frames -- not through this path yet
                continue;
            }
            let v = iri::eval_const_in(&mut cdit, cdef.module, cdef.node, 1u32 << 20);
            let cty = cem.stat_items.at(ci).ty;
            // array-of-string consts render from their literal initializer directly
            if v.kind == iri::IV_OBJ || v.kind == iri::IV_NONE {
                let vn0 = cda.at_const(cdn.as_data.const_def.value);
                if vn0.kind == NodeKind::NODE_STRUCT_INITIALIZER && vn0.as_data.struct_initializer.fields.len == 0 {
                    let mut line3 = String::new();
                    if cem.mg.ctype(em2, cty, csym.as_str(), &mut line3) {
                        line3.push_str(" = {0};\n");
                        const_defs.push_string(&line3);
                        cd_ok += 1;
                        continue;
                    }
                }
                if vn0.kind == NodeKind::NODE_ARRAY_LITERAL {
                    let mut line2 = String::new();
                    let mut is_slice2 = false;
                    let mut ety2 = TYPE_NONE;
                    {
                        let ea2 = unsafe &*p.module_ast_const(em2);
                        let ty2 = *ea2.type_at(cty);
                        if ty2.kind == TypeKind::TYPE_INSTANCE {
                            let it2 = *ea2.instance(ty2.as_data.inst);
                            if it2.n > 0 {
                                is_slice2 = true; // slice-view consts: a hidden data array + the view
                                ety2 = it2.args[0];
                            }
                        }
                    }
                    let mut ok2 = true;
                    let mut ecty = String::new();
                    if is_slice2 {
                        ok2 = cem.mg.ctype(em2, ety2, "", &mut ecty);
                        if ok2 {
                            line2.push_str("static const ");
                            line2.push_string(&ecty);
                            line2.push_str(" ");
                            line2.push_string(&csym);
                            line2.push_str("__data[] = { ");
                        }
                    } else {
                        ok2 = cem.mg.ctype(em2, cty, csym.as_str(), &mut line2);
                        if ok2 {
                            line2.push_str(" = { ");
                        }
                    }
                    if ok2 {
                        let els = vn0.as_data.array_literal.elements;
                        let csrc2 = p.modules[cdef.module as usize].source.as_str();
                        for e2 in 0..els.len {
                            let eid = unsafe cda.list(els)[e2 as usize];
                            if e2 != 0 {
                                line2.push_str(", ");
                            }
                            if !render_const_elem(cda, csrc2, eid, &mut line2) {
                                ok2 = false;
                                break;
                            }
                        }
                        line2.push_str(" };\n");
                        if is_slice2 {
                            let mut view2 = String::new();
                            if cem.mg.ctype(em2, cty, csym.as_str(), &mut view2) {
                                line2.push_string(&view2);
                                line2.push_str(" = { ");
                                line2.push_string(&csym);
                                line2.push_str("__data, sizeof(");
                                line2.push_string(&csym);
                                line2.push_str("__data) / sizeof(");
                                line2.push_string(&ecty);
                                line2.push_str(") };\n");
                            } else {
                                ok2 = false;
                            }
                        }
                    }
                    if ok2 {
                        const_defs.push_string(&line2);
                        cd_ok += 1;
                        continue;
                    }
                }
                // any other aggregate: the CTFE static graph, captured straight from the
                // interpreter's live objects; a refusal falls back to the established
                // evaluator's graph, converted into the same store.
                let mut root3: i64 = 0 - 1;
                if v.kind == iri::IV_OBJ {
                    let sri = cdit.capture(v);
                    if sri.ok {
                        root3 = sri.root;
                    }
                }
                if root3 >= 0 {
                    let mut grp3 = String::new();
                    let mut rootd3 = String::new();
                    let okg3 = st_group(p, &mut cem.mg, &cdit, csym.as_str(), root3 as u32, &mut grp3);
                    let okc3 = st_ctype(p, &mut cem.mg, &cdit, root3 as u32, csym.as_str(), &mut rootd3);
                    let ok3 = okg3 && okc3;
                    if ok3 {
                        const_defs.push_string(&grp3);
                        const_defs.push_string(&rootd3);
                        const_defs.push_str(" = ");
                        if st_init(p, &mut cem.mg, &cdit, csym.as_str(), root3 as u32, &mut const_defs) {
                            const_defs.push_str(";\n");
                            cd_ok += 1;
                            continue;
                        }
                    }
                }
            }
            let mut line = String::new();
            // a NULL pointer constant is scalar data (`= 0`)
            let mut okc = v.kind == iri::IV_INT || v.kind == iri::IV_BOOL || v.kind == iri::IV_FLOAT || v.kind == iri::IV_STR || v.kind == iri::IV_PTR && v.i == 0;
            if okc {
                okc = cem.mg.ctype(em2, cty, csym.as_str(), &mut line);
            }
            if okc {
                line.push_str(" = ");
                if v.kind == iri::IV_PTR {
                    line.push_str("0");
                } else if v.kind == iri::IV_INT {
                    if v.i < 0 && line.len() != 0 && line.as_str().byte_at(0) == b'u' {
                        line.push_u64(v.i as u64);
                        line.push_str("ULL");
                    } else if v.i as u64 == 0x8000000000000000u64 {
                        line.push_str("(-9223372036854775807LL - 1)"); // C has no i64::MIN literal
                    } else {
                        line.push_i64(v.i);
                    }
                } else if v.kind == iri::IV_BOOL {
                    line.push_str(
                        if v.i != 0 {
                            "true";
                        } else {
                            "false";
                        },
                    );
                } else if v.kind == iri::IV_FLOAT {
                    line.push_f64(v.f);
                } else {
                    let csrc = p.modules[cdef.module as usize].source.as_str();
                    let mut a0 = (v.i >> 32) as usize;
                    let mut b0 = (v.i & 0xFFFFFFFF) as usize;
                    let mut mtext = false;
                    if b0 > csrc.len() || a0 >= b0 {
                        cd_skip += 1;
                        continue;
                    }
                    if b0 > a0 + 3 && csrc.byte_at(a0) == b'M' && csrc.byte_at(a0 + 1) == 34 && csrc.byte_at(a0 + 2) == b'(' {
                        a0 += 3;
                        b0 -= 2; // `)"` suffix
                        mtext = true;
                    } else if b0 > a0 + 1 && csrc.byte_at(a0) == 34 && csrc.byte_at(b0 - 1) == 34 {
                        a0 += 1;
                        b0 -= 1;
                    }
                    let mut esc = String::new();
                    if mtext {
                        cbe::push_c_escaped(csrc.slice(a0, b0), &mut esc);
                    } else {
                        esc.push_str(csrc.slice(a0, b0));
                    }
                    line.push_str("{ (const uint8_t *)\"");
                    line.push_string(&esc);
                    line.push_str("\", sizeof(\"");
                    line.push_string(&esc);
                    line.push_str("\") - 1 }");
                }
                line.push_str(";\n");
                const_defs.push_string(&line);
                cd_ok += 1;
            } else {
                if verbose {
                    eprint("const-skip: `{}` kind {}\n", csym.as_str(), v.kind);
                }
                cd_skip += 1;
            }
            let _ = em2;
        }
        o.skips += cd_skip;
        if verbose {
            eprint("cemit-consts: {} defined, {} skipped\n", cd_ok, cd_skip);
        }
    }
    // @reflect exports + `type_info` descriptor groups: the CTFE static graph rendered as file-
    // scope const data (extern roots; `__ct%u` auxiliaries static per group)
    let mut static_defs = String::new();
    if p.cir != null {
        let tih = p.prelude_lookup("TypeInfo", true);
        let mut ti_ok: u64 = 0;
        let mut ti_skip: u64 = 0;
        if tih.node != NODE_NONE {
            for ri in 0..cem.ti_reqs.len() {
                let em9 = cem.ti_reqs.at(ri).em;
                let ty9 = cem.ti_reqs.at(ri).ty;
                let sym9 = cem.ti_reqs.at(ri).sym.clone();
                let a9 = unsafe &mut *(p.module_ast_const(em9) as *mut Ast);
                let rty9 = a9.intern_type(
                    Ty { kind: TypeKind::TYPE_STRUCT, module: tih.mid, as_data: TyAs { decl: tih.node } },
                );
                let sr = cdit.eval_type_info_export(em9, rty9, em9, ty9);
                let mut ok9b = sr.ok;
                if ok9b {
                    let root9 = sr.root;
                    let mut grp = String::new();
                    let mut rootd = String::new();
                    ok9b = st_group(p, &mut cem.mg, &cdit, sym9.as_str(), root9, &mut grp) && st_ctype(
                        p,
                        &mut cem.mg,
                        &cdit,
                        root9,
                        sym9.as_str(),
                        &mut rootd,
                    );
                    if ok9b {
                        static_defs.push_string(&grp);
                        static_defs.push_str("const ");
                        static_defs.push_string(&rootd);
                        static_defs.push_str(" = ");
                        ok9b = st_init(p, &mut cem.mg, &cdit, sym9.as_str(), root9, &mut static_defs);
                        static_defs.push_str(";\n");
                        cem.stat_decls.push_str("extern const ");
                        cem.stat_decls.push_string(&rootd);
                        cem.stat_decls.push_str(";\n");
                    }
                }
                if ok9b {
                    ti_ok += 1;
                } else {
                    ti_skip += 1;
                }
            }
            // `@reflect`-tagged concrete aggregates export a registered descriptor
            for m9 in 0..p.modules.len() {
                if !p.modules[m9].has_ast {
                    continue;
                }
                let a9 = unsafe &mut *(p.module_ast_const(m9 as ModuleId) as *mut Ast);
                let its9 = a9.at_const(a9.root).as_data.program.items;
                for i9 in 0..its9.len {
                    let nid9 = unsafe a9.list(its9)[i9 as usize];
                    let nk9 = a9.at_const(nid9).kind;
                    if nk9 != NodeKind::NODE_STRUCT && nk9 != NodeKind::NODE_ENUM {
                        continue;
                    }
                    if a9.at_const(nid9).as_data.aggregate.generics.len != 0 {
                        continue;
                    }
                    let mut tagged = false;
                    for k9 in 0..a9.metas.len() {
                        if a9.metas.at(k9).owner == nid9 {
                            tagged = true;
                            break;
                        }
                    }
                    if !tagged {
                        continue;
                    }
                    let tk9 = if nk9 == NodeKind::NODE_ENUM {
                        TypeKind::TYPE_ENUM;
                    } else {
                        TypeKind::TYPE_STRUCT;
                    };
                    let tt9 = a9.intern_type(Ty { kind: tk9, module: m9 as ModuleId, as_data: TyAs { decl: nid9 } });
                    let rty9 = a9.intern_type(
                        Ty { kind: TypeKind::TYPE_STRUCT, module: tih.mid, as_data: TyAs { decl: tih.node } },
                    );
                    let sr = cdit.eval_type_info_export(m9 as ModuleId, rty9, m9 as ModuleId, tt9);
                    if !sr.ok {
                        ti_skip += 1;
                        continue;
                    }
                    let root9 = sr.root;
                    let mut qn = String::new();
                    cem.mg.modpfx(m9 as ModuleId, &mut qn);
                    cem.mg.ident(
                        m9 as ModuleId,
                        a9.at_const(a9.at_const(nid9).as_data.aggregate.name).as_data.name.text,
                        &mut qn,
                    );
                    let mut nm9 = String::from_str("sc_typeinfo_");
                    nm9.push_string(&qn);
                    let mut grp = String::new();
                    let mut rootd = String::new();
                    let mut ok9b = st_group(p, &mut cem.mg, &cdit, nm9.as_str(), root9, &mut grp) && st_ctype(
                        p,
                        &mut cem.mg,
                        &cdit,
                        root9,
                        nm9.as_str(),
                        &mut rootd,
                    );
                    if ok9b {
                        static_defs.push_str("/* @reflect export */\n");
                        static_defs.push_string(&grp);
                        static_defs.push_str("const ");
                        static_defs.push_string(&rootd);
                        static_defs.push_str(" = ");
                        ok9b = st_init(p, &mut cem.mg, &cdit, nm9.as_str(), root9, &mut static_defs);
                        static_defs.push_str(";\n__attribute__((constructor)) static void __sc_reg_");
                        static_defs.push_string(&qn);
                        static_defs.push_str("(void) { __sc_reflect_register((const void *)&");
                        static_defs.push_string(&nm9);
                        static_defs.push_str("); }\n");
                    }
                    if ok9b {
                        ti_ok += 1;
                    } else {
                        ti_skip += 1;
                    }
                }
            }
        }
        if verbose && (ti_ok != 0 || ti_skip != 0) {
            eprint("cemit-reflect: {} groups, {} skipped\n", ti_ok, ti_skip);
        }
        o.skips += ti_skip;
    }
    // Assembly: shared headers carry every aggregate/ret-struct/env typedef and all cross-TU
    // prototypes; each module TU holds its own bodies plus its static closures; the instance TU
    // holds every demanded instance, glue body, const/static definition and dyn table.
    {
        let ps = protos.as_str();
        let bs = bodies_all.as_str();
        let mut poff = Vector::<u64>::new();
        {
            let mut c0: usize = 0;
            for _i in 0..chunk_mod.len() {
                poff.push(c0 as u64);
                while c0 < ps.len() && ps.byte_at(c0) != 10 {
                    c0 += 1;
                }
                if c0 < ps.len() {
                    c0 += 1;
                }
            }
            poff.push(c0 as u64);
        }
        // aggregates first named by demand-driven bodies or by other aggregates' FIELDS (chains
        // the planner's closure never reached): replay each recorded spelling under its env; the
        // name-keyed state map skips everything already defined. em's own list GROWS while
        // replaying (a replayed body's field types record deeper instances) -- follow it.
        for ri9 in 0..cem.mg.agg_reqs.len() {
            let pm9 = cem.mg.agg_reqs.at(ri9).pm;
            let it9 = cem.mg.agg_reqs.at(ri9).it;
            let ns9 = cem.mg.agg_reqs.at(ri9).subs.len();
            for si9 in 0..ns9 {
                em.mg.push_msub(*cem.mg.agg_reqs.at(ri9).subs.at(si9));
            }
            let _ = em.emit_agg_inst(pm9, it9);
            em.mg.pop_subs(ns9);
        }
        let mut ri8: usize = 0;
        while ri8 < em.mg.agg_reqs.len() {
            let pm8 = em.mg.agg_reqs.at(ri8).pm;
            let it8 = em.mg.agg_reqs.at(ri8).it;
            let ns8 = em.mg.agg_reqs.at(ri8).subs.len();
            for si8 in 0..ns8 {
                let sb8 = *em.mg.agg_reqs.at(ri8).subs.at(si8);
                em.mg.push_msub(sb8);
            }
            let _ = em.emit_agg_inst(pm8, it8);
            em.mg.pop_subs(ns8);
            ri8 += 1;
        }
        // env bodies the declaration pass did NOT define inline (non-embedded closures): they
        // land after every aggregate body, deduped against the embedded ones
        {
            let nb0 = env_bodies.len();
            for bi0 in 0..nb0 {
                if !em.env_done(*env_names.at(bi0)) {
                    em.mark_env_done(*env_names.at(bi0));
                    envs_all.push_string(env_bodies.at(bi0));
                }
            }
        }
        let mut th = String::from_str(
            "#ifndef SC_CEMIT_TYPES_H\n#define SC_CEMIT_TYPES_H\n#include \"super_rt.h\"\n#include <math.h>\n#include <pthread.h>\ntypedef struct { const uint8_t *ptr; size_t len; } SCslice;\n#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"\n#pragma GCC diagnostic ignored \"-Wunused-variable\"\n#pragma GCC diagnostic ignored \"-Wunused-function\"\n#pragma GCC diagnostic ignored \"-Wunused-parameter\"\n#pragma GCC diagnostic ignored \"-Wunused-label\"\n",
        );
        th.reserve(
            ext_incs.len() + em.fwd2.len() + cem.env_fwd.len() + cem.dyn_defs.len() + em.out.len() + macros_out.len() + cem.aux.len() + envs_all.len() + 256,
        );
        th.push_string(&ext_incs);
        th.push_string(&em.fwd2);
        th.push_string(&cem.env_fwd);
        th.push_string(&cem.dyn_defs);
        th.push_str(em.out.as_str());
        th.push_string(&macros_out);
        if em.out.contains("struct str {") {
            th.push_str(
                "static inline bool __sc_str_eq(str a, str b) { return a.len == b.len && (a.len == 0 || memcmp(a.ptr, b.ptr, a.len) == 0); }\n",
            );
        }
        th.push_string(&cem.aux);
        th.push_string(&envs_all);
        th.push_str("#endif\n");
        let mut phh = String::from_str("#ifndef SC_CEMIT_PROTOS_H\n#define SC_CEMIT_PROTOS_H\n");
        phh.reserve(cem.extern_protos.len() + cem.stat_decls.len() + cem.dyn_decls.len() + ps.len() + 64);
        phh.push_string(&cem.extern_protos);
        phh.push_string(&cem.stat_decls);
        phh.push_string(&cem.dyn_decls);
        phh.push_string(&cem.sent_decls);
        for i in 0..chunk_mod.len() {
            let pl = ps.slice(poff[i] as usize, poff[i + 1] as usize);
            if !(pl.len() >= 7 && pl.slice(0, 7) == "static ") {
                phh.push_str(pl);
            }
        }
        phh.push_str("#endif\n");
        o.types_h = th;
        o.protos_h = phh;
        let mut sdefs = Set::<u64>::new();
        struct_def_names(o.types_h.as_str(), &mut sdefs);
        // chunk indexes per TU (the instance TU last), one pass over the chunk list: the per-TU
        // assembly below then touches only its own chunks and reserves its buffers exactly
        let mut tu_chunks = Vector::<Vector<u32>>::new();
        for _i in 0..p.modules.len() + 1 {
            tu_chunks.push(Vector::<u32>::new());
        }
        for i in 0..chunk_mod.len() {
            let w = if chunk_mod[i] == 65534 {
                p.modules.len();
            } else {
                chunk_mod[i] as usize;
            };
            tu_chunks[w].push(i as u32);
        }
        let mut lp = String::new();
        let mut lb = String::new();
        for t in 0..p.modules.len() + 1 {
            let is_inst = t == p.modules.len();
            lp.truncate(0);
            lb.truncate(0);
            {
                let mut bb: usize = 0;
                for k in 0..tu_chunks[t].len() {
                    let i = tu_chunks[t][k] as usize;
                    let b1 = if i + 1 < chunk_off.len() {
                        chunk_off[i + 1] as usize;
                    } else {
                        bs.len();
                    };
                    bb += b1 - chunk_off[i] as usize;
                }
                lb.reserve(bb);
            }
            for k in 0..tu_chunks[t].len() {
                let i = tu_chunks[t][k] as usize;
                let pl = ps.slice(poff[i] as usize, poff[i + 1] as usize);
                if pl.len() >= 7 && pl.slice(0, 7) == "static " {
                    lp.push_str(pl);
                }
                let b1 = if i + 1 < chunk_off.len() {
                    chunk_off[i + 1] as usize;
                } else {
                    bs.len();
                };
                lb.push_str(bs.slice(chunk_off[i] as usize, b1));
            }
            // under --test the fork-per-test runner owns the C `main`; the user main stays a
            // plain (unreferenced) `__sc_user_main`
            let has_wrap = have_main && !testing && !is_inst && t as u64 == main_mod;
            if lb.len() == 0 && !is_inst && !has_wrap {
                continue;
            }
            let mut tu2 = String::new();
            {
                let mut cap2 = lp.len() + lb.len() + 2048;
                if is_inst {
                    cap2 += cem.blk_defs.len() + const_defs.len() + static_defs.len() + cem.dyn_tabs.len();
                }
                tu2.reserve(cap2);
            }
            tu2.push_string(&lp);
            if !is_inst && p.modules[t].has_ast {
                // folded module-level static_asserts leave their record in the C (parity with
                // the checker: a false one already failed the build)
                let a9 = unsafe &*p.module_ast_const(t as ModuleId);
                let its9 = a9.at_const(a9.root).as_data.program.items;
                for i9 in 0..its9.len {
                    let nid9 = unsafe a9.list(its9)[i9 as usize];
                    if a9.at_const(nid9).kind != NodeKind::NODE_STATIC_ASSERT {
                        continue;
                    }
                    let bd9 = a9.at_const(nid9).as_data.binary;
                    tu2.push_str("_Static_assert(true, ");
                    if bd9.right != NODE_NONE {
                        let rsp9 = a9.at_const(bd9.right).as_data.literal.raw;
                        tu2.push_str(p.modules[t].source.as_str().slice(rsp9.start as usize, rsp9.end as usize));
                    } else {
                        tu2.push_str("\"static assertion failed\"");
                    }
                    tu2.push_str(");\n");
                }
                cemit_layout_asserts(p, &mut cem, t as ModuleId, &sdefs, &mut tu2);
            }
            if is_inst {
                tu2.push_string(&cem.blk_defs);
                tu2.push_string(&const_defs);
                tu2.push_string(&static_defs);
                tu2.push_string(&cem.dyn_tabs);
                tu2.push_string(&cem.sent_defs);
            }
            tu2.push_string(&lb);
            if has_wrap {
                cemit_main_wrapper(&mut tu2, main_argv);
            }
            if is_inst {
                o.inst_c = tu2;
            } else {
                o.tus.set(t, tu2);
            }
        }
    }
    {
        let nm9 = p.modules.len();
        for src in 0..nm9 + 1 {
            let sk = if src == nm9 {
                65534u64;
            } else {
                src as u64;
            };
            for dst in 0..nm9 {
                if cem.mg.um_hit(sk, dst) {
                    o.edges.push(sk << 32 | dst as u64);
                }
            }
        }
    }
    o.have_main = have_main;
    o.main_mod = main_mod;
    o.main_argv = main_argv;
    if tuc.on {
        o.tuc_img = tuc.out.clone();
        o.tuc_path = tuc.path.clone();
    }
    let _ = fwd_end;
}

// The verification lane (SC_CEMIT_TU=1|2): run the whole-package emission, write the scratch tree
// under build/cemit_mod, compile + link it against the runtime (plus the fork-per-test runner when
// the package has no main), and run the produced stage.
fn cemit_tu_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_CEMIT_TU") == null {
        return;
    }
    let t0 = unsafe shim::sc_ticks_ms();
    let mut tplan = TestPlan::new(p.modules.len());
    test_plan_build(p, &mut tplan);
    let mut o = CemitOut::new(p.modules.len());
    cemit_package(p, true, &tplan, null, -1, &mut o, null);
    let _ = unsafe shim::sc_run("mkdir -p build/cemit_mod".ptr() as *const char, null, null, null, null);
    write_super_rt("build/cemit_mod");
    let mut ok9 = cemit_write("build/cemit_mod/__sc_types.h", &o.types_h) && cemit_write(
        "build/cemit_mod/__sc_protos.h",
        &o.protos_h,
    );
    let mut cc_cmd = String::from_str(
        "cc -std=c11 -Wall -Werror -Wno-implicit-function-declaration -Wno-error=implicit-function-declaration -Wno-uninitialized -Wno-sometimes-uninitialized -Wno-unused-function",
    );
    let mut ntu: u64 = 0;
    for t in 0..p.modules.len() + 1 {
        let is_inst = t == p.modules.len();
        let src9 = if is_inst {
            o.inst_c.as_str();
        } else {
            o.tus.at(t).as_str();
        };
        if src9.len() == 0 {
            continue;
        }
        let mut tu2 = String::from_str("#include \"__sc_types.h\"\n#include \"__sc_protos.h\"\n");
        tu2.push_str(src9);
        let mut path = String::from_str("build/cemit_mod/");
        if is_inst {
            path.push_str("__sc_inst");
        } else {
            let mp = p.modules[t].path.as_str();
            for k in 0..mp.len() {
                let c2 = mp.byte_at(k);
                let okc = c2 >= b'a' && c2 <= b'z' || c2 >= b'A' && c2 <= b'Z' || c2 >= b'0' && c2 <= b'9';
                path.push_byte(
                    if okc {
                        c2;
                    } else {
                        b'_';
                    },
                );
            }
        }
        path.push_str(".c");
        ok9 = ok9 && cemit_write(path.as_str(), &tu2);
        cc_cmd.push_str(" ");
        cc_cmd.push_string(&path);
        ntu += 1;
    }
    if !o.have_main && tplan.ok && tplan.cases.len() != 0 {
        // no user main: the fork-per-test runner TU is the program (the lane runs before codegen
        // defaults gen_root and creates the tree, so do both here; idempotent)
        if p.gen_root.len() == 0 {
            p.gen_root = String::from_str(p.root_dir.as_str());
            p.gen_root.push_str("/build/raw");
        }
        let mut mk = String::from_str("mkdir -p ");
        mk.push_str(p.gen_root.as_str());
        let _ = unsafe shim::sc_run(mk.cstr(), null, null, null, null);
        switch write_test_main(p, &tplan) {
            Some(rp) => {
                cc_cmd.push_str(" ");
                cc_cmd.push_str(rp.as_str());
            },
            None => {
                ok9 = false;
            },
        };
    }
    cc_cmd.push_str(" build/raw/__ext*.c build/cemit_mod/super_rt.c -o build/cemit_mod/sc_gen1");
    let mut mrc: i32 = -1;
    if ok9 {
        mrc = unsafe shim::sc_run(cc_cmd.cstr(), null, "build/cemit_mod/cc.log", null, null);
    }
    let mut rrc: i32 = -1;
    if mrc == 0 {
        rrc = unsafe shim::sc_run("build/cemit_mod/sc_gen1 --help".ptr() as *const char, null, null, null, null);
    }
    let dt = unsafe shim::sc_ticks_ms() - t0;
    eprint("cemit-mod: {} TUs, {} skips, cc {}, run {}, {} ms\n", ntu, o.skips, mrc, rrc, dt);
}

// A literal const-initializer element as C: string literals become str views, integers copy
// their digits, struct literals recurse positionally. Anything else refuses.
fn render_const_elem(a: &Ast, src: str, eid: NodeId, out: &mut String) bool {
    let n = a.at_const(eid);
    if n.kind == NodeKind::NODE_LITERAL {
        let rsp = n.as_data.literal.raw;
        let mut a2 = rsp.start as usize;
        let mut b2 = rsp.end as usize;
        if b2 > a2 + 1 && src.byte_at(a2) == 34 && src.byte_at(b2 - 1) == 34 {
            a2 += 1;
            b2 -= 1;
            out.push_str("{ (const uint8_t *)\"");
            out.push_str(src.slice(a2, b2));
            out.push_str("\", sizeof(\"");
            out.push_str(src.slice(a2, b2));
            out.push_str("\") - 1 }");
            return true;
        }
        out.push_str(src.slice(a2, b2));
        return true;
    }
    if n.kind == NodeKind::NODE_STRUCT_INITIALIZER {
        out.push_str("{ ");
        let fls = n.as_data.struct_initializer.fields;
        for i in 0..fls.len {
            if i != 0 {
                out.push_str(", ");
            }
            let fi = unsafe a.list(fls)[i as usize];
            if !render_const_elem(a, src, a.at_const(fi).as_data.field_initializer.value, out) {
                return false;
            }
        }
        out.push_str(" }");
        return true;
    }
    return false;
}

// Copy one captured group from the established evaluator's store into the interpreter's,
// remapping intra-group indices; groups are self-contained (each capture evaluates from a fresh
// object store), so a constant offset relocates every parent/owner/child/target.

// ---- CTFE static-graph rendering (the new backend's `@reflect` / `type_info` data layer) -------

// The C declarator of statics entry `gi` around `decl`: heap/array groups spell as element arrays,
// aggregates by their (instance) names, cells by their value type.
fn st_ctype(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, gi: u32, decl: str, out: &mut String) bool {
    let g = cev.static_at(gi);
    let shape = unsafe g.shape;
    if shape == iri::SS_HEAP || shape == iri::SS_ARRAY {
        let mut n2 = unsafe g.n;
        if n2 == 0 {
            n2 = 1;
        }
        let mut d2 = String::from_str(decl);
        d2.push_str("[");
        d2.push_u64(n2);
        d2.push_str("]");
        let ok = mg.ctype(unsafe g.etm, unsafe g.ety, d2.as_str(), out);
        return ok;
    }
    if shape == iri::SS_CELL {
        return mg.ctype(unsafe g.etm, unsafe g.ety, decl, out);
    }
    // SS_STRUCT / SS_ENUM: the aggregate's (instance) C name
    let dm = unsafe g.dm;
    let dn = unsafe g.dn;
    let da = unsafe &*p.module_ast_const(dm);
    mg.modpfx(dm, out);
    mg.ident(dm, da.at_const(da.at_const(dn).as_data.aggregate.name).as_data.name.text, out);
    if shape == iri::SS_STRUCT && unsafe g.nargs != 0 {
        let mut last = unsafe g.nargs;
        while last > 0 && mg.is_global(unsafe g.am[(last - 1) as usize], unsafe g.at[(last - 1) as usize]) {
            last -= 1;
        }
        for i in 0..last {
            out.push_str("__");
            if !mg.type_m(unsafe g.am[i as usize], unsafe g.at[i as usize], out) {
                return false;
            }
        }
    }
    if decl.len() != 0 {
        out.push_str(" ");
        out.push_str(decl);
    }
    return true;
}

// `.field` designator for member index `idx` of aggregate `(dm, dn)` (`._N` for tuples).
// Is struct slot `idx` a zero-sized field (no C member exists for it)? Resolved under the
// StaticObj's recorded instance args, mirroring st_field's field-ordinal indexing.
fn st_field_zst(p: &loader::Package, mg: &mut mbe::Mangler, g: *const iri::StaticObj, idx: u32) bool {
    let dm = unsafe g.dm;
    let dn = unsafe g.dn;
    let a = unsafe &*p.module_ast_const(dm);
    let ms = a.at_const(dn).as_data.aggregate.members;
    let is_tuple = a.at_const(dn).as_data.aggregate.is_tuple;
    let mut fty = TYPE_NONE;
    let mut fi: u32 = 0;
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        if !is_tuple && a.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        if fi == idx {
            fty = a.type_of(fid);
            if fty == TYPE_NONE && !is_tuple {
                fty = a.type_of(a.at_const(fid).as_data.field.ty);
            }
            break;
        }
        fi += 1;
    }
    if fty == TYPE_NONE {
        return false;
    }
    let gens = a.at_const(dn).as_data.aggregate.generics;
    let mut nb: usize = 0;
    for i in 0..gens.len {
        if i as u8 >= unsafe g.nargs {
            break;
        }
        mg.push_sub(dm, unsafe a.list(gens)[i as usize], unsafe g.am[i as usize], unsafe g.at[i as usize]);
        nb += 1;
    }
    let z = mg.is_zst(dm, fty);
    mg.pop_subs(nb);
    return z;
}

fn st_field(p: &loader::Package, mg: &mut mbe::Mangler, dm: ModuleId, dn: NodeId, idx: u32, out: &mut String) {
    let a = unsafe &*p.module_ast_const(dm);
    if a.at_const(dn).as_data.aggregate.is_tuple {
        out.push_str("._");
        out.push_u64(idx);
        return;
    }
    let ms = a.at_const(dn).as_data.aggregate.members;
    let mut fi: u32 = 0;
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        if a.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        if fi == idx {
            out.push_str(".");
            mg.ident(dm, a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text, out);
            return;
        }
        fi += 1;
    }
    out.push_str("._");
    out.push_u64(idx);
}

// The C lvalue path of statics entry `gi`, rooted at its owner's name.
fn st_path(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, name: str, gi: u32, out: &mut String) {
    let g = cev.static_at(gi);
    if unsafe g.parent == iri::S_NO_PARENT {
        out.push_str(name);
        if unsafe g.ord != 0 {
            out.push_str("__ct");
            out.push_u64(unsafe g.ord - 1);
        }
        return;
    }
    let pi = unsafe g.parent;
    st_path(p, mg, cev, name, pi, out);
    let pg = cev.static_at(pi);
    let pshape = unsafe pg.shape;
    let pslot = unsafe g.pslot;
    if pshape == iri::SS_ARRAY || pshape == iri::SS_HEAP {
        out.push_str("[");
        out.push_u64(pslot);
        out.push_str("]");
    } else if pshape == iri::SS_STRUCT {
        st_field(p, mg, unsafe pg.dm, unsafe pg.dn, pslot, out);
    } else if pshape == iri::SS_ENUM {
        let a = unsafe &*p.module_ast_const(unsafe pg.dm);
        let ms = a.at_const(unsafe pg.dn).as_data.aggregate.members;
        let tag = (unsafe pg.slots.at(0).i) as u32;
        let vid = unsafe a.list(ms)[tag as usize];
        out.push_str(".payload.");
        mg.ident(unsafe pg.dm, a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text, out);
        let vdat = a.at_const(vid).as_data.variant;
        if vdat.struct_payload {
            let pfid = unsafe a.list(vdat.payload)[(pslot - 1) as usize];
            out.push_str(".");
            mg.ident(unsafe pg.dm, a.at_const(a.at_const(pfid).as_data.field.name).as_data.name.text, out);
        } else {
            out.push_str("._");
            out.push_u64(pslot - 1);
        }
    }
}

// One relocation: a function's address or a (possibly interior) pointer into a sibling static.
fn st_rel(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, name: str, r: &iri::SRel, out: &mut String) bool {
    if r.kind == iri::SREL_FN {
        let tgt = mg.method_target(r.fm, r.fnode);
        return mg.fn_sym(r.fm, r.fnode, tgt, true, out);
    }
    let tshape = unsafe cev.static_at(r.target).shape;
    if tshape == iri::SS_ARRAY || tshape == iri::SS_HEAP {
        if r.toff == 0 {
            out.push_str("(void *)");
            st_path(p, mg, cev, name, r.target, out);
        } else {
            out.push_str("(void *)&");
            st_path(p, mg, cev, name, r.target, out);
            out.push_str("[");
            out.push_u64(r.toff);
            out.push_str("]");
        }
        return true;
    }
    out.push_str("(void *)&");
    st_path(p, mg, cev, name, r.target, out);
    if tshape == iri::SS_STRUCT && r.toff != 0 {
        st_field(p, mg, unsafe cev.static_at(r.target).dm, unsafe cev.static_at(r.target).dn, r.toff, out);
    }
    return true;
}

// One slot's initializer expression.
fn st_slot(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, name: str, gi: u32, k: u32, out: &mut String) bool {
    let g = cev.static_at(gi);
    let sl = *unsafe g.slots.at(k as usize);
    if sl.kind == iri::SK_ZERO {
        out.push_str("{0}");
        return true;
    }
    if sl.kind == iri::SK_NULL {
        out.push_str("NULL");
        return true;
    }
    if sl.kind == iri::SK_AGG {
        return st_init(p, mg, cev, name, sl.child, out);
    }
    if sl.kind == iri::SK_REL {
        for ri in 0..unsafe g.rels.len() {
            if unsafe g.rels.at(ri).slot == k {
                return st_rel(p, mg, cev, name, unsafe g.rels.at(ri), out);
            }
        }
        out.push_str("NULL");
        return true;
    }
    if sl.kind == iri::SK_BOOL {
        out.push_str(
            if sl.i != 0 {
                "true";
            } else {
                "false";
            },
        );
        return true;
    }
    if sl.kind == iri::SK_FLOAT {
        out.push_f64(sl.f);
        return true;
    }
    // SK_INT: unsigned pool types print unsigned (with the 64-bit suffix when the sign bit is set)
    let mut usig = false;
    if sl.ty != TYPE_NONE {
        let y = *unsafe (&*p.module_ast_const(sl.tm)).type_at(sl.ty);
        if y.kind == TypeKind::TYPE_BUILTIN {
            let bt = y.as_data.builtin;
            usig = bt == BuiltinType::BT_U8 || bt == BuiltinType::BT_U16 || bt == BuiltinType::BT_U32 || bt == BuiltinType::BT_U64 || bt == BuiltinType::BT_USIZE;
        }
    }
    if usig && sl.i < 0 {
        out.push_u64(sl.i as u64);
        out.push_str("ULL");
    } else if sl.i as u64 == 0x8000000000000000u64 {
        out.push_str("(-9223372036854775807LL - 1)");
    } else {
        out.push_i64(sl.i);
    }
    return true;
}

// The braced initializer of statics entry `gi`.
fn st_init(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, name: str, gi: u32, out: &mut String) bool {
    let g = cev.static_at(gi);
    let shape = unsafe g.shape;
    let nslots = (unsafe g.slots.len()) as u32;
    if shape == iri::SS_CELL {
        return st_slot(p, mg, cev, name, gi, 0, out);
    }
    if shape == iri::SS_ARRAY || shape == iri::SS_HEAP {
        let mut allzero = true;
        for k in 0..nslots {
            if unsafe g.slots.at(k as usize).kind != iri::SK_ZERO {
                allzero = false;
                break;
            }
        }
        if allzero {
            out.push_str("{0}");
            return true;
        }
        let ek = unsafe (&*p.module_ast_const(unsafe g.etm)).type_at(unsafe g.ety).kind;
        let escalar = ek == TypeKind::TYPE_BUILTIN || ek == TypeKind::TYPE_POINTER || ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_FUNCTION;
        out.push_str("{ ");
        for k in 0..nslots {
            if k != 0 {
                out.push_str(", ");
            }
            if unsafe g.slots.at(k as usize).kind == iri::SK_ZERO && escalar {
                out.push_str("0");
            } else if !st_slot(p, mg, cev, name, gi, k, out) {
                return false;
            }
        }
        out.push_str(" }");
        return true;
    }
    if shape == iri::SS_ENUM {
        let dm = unsafe g.dm;
        let dn = unsafe g.dn;
        let a = unsafe &*p.module_ast_const(dm);
        let ms = a.at_const(dn).as_data.aggregate.members;
        let tag = (unsafe g.slots.at(0).i) as u32;
        if tag >= ms.len {
            out.push_str("{0}");
            return true;
        }
        let vid = unsafe a.list(ms)[tag as usize];
        out.push_str("{ .tag = ");
        mg.enum_tag(dm, dn, vid, out);
        let mut haspay = false;
        for k in 1..nslots {
            if unsafe g.slots.at(k as usize).kind != iri::SK_ZERO {
                haspay = true;
            }
        }
        if haspay {
            let vdat = a.at_const(vid).as_data.variant;
            out.push_str(", .payload.");
            mg.ident(dm, a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text, out);
            out.push_str(" = { ");
            let mut first = true;
            for k in 1..nslots {
                if unsafe g.slots.at(k as usize).kind == iri::SK_ZERO {
                    continue;
                }
                if !first {
                    out.push_str(", ");
                }
                first = false;
                if vdat.struct_payload {
                    let pfid = unsafe a.list(vdat.payload)[(k - 1) as usize];
                    out.push_str(".");
                    mg.ident(dm, a.at_const(a.at_const(pfid).as_data.field.name).as_data.name.text, out);
                    out.push_str(" = ");
                } else {
                    out.push_str("._");
                    out.push_u64(k - 1);
                    out.push_str(" = ");
                }
                if !st_slot(p, mg, cev, name, gi, k, out) {
                    return false;
                }
            }
            out.push_str(" }");
        }
        out.push_str(" }");
        return true;
    }
    // SS_STRUCT
    if nslots == 0 {
        out.push_str("{0}"); // strict C11: an empty initializer list is not C
        return true;
    }
    let uact = unsafe g.uactive;
    if uact >= 0 {
        out.push_str("{ ");
        st_field(p, mg, unsafe g.dm, unsafe g.dn, uact as u32, out);
        out.push_str(" = ");
        if !st_slot(p, mg, cev, name, gi, uact as u32, out) {
            return false;
        }
        out.push_str(" }");
        return true;
    }
    out.push_str("{ ");
    let mut ne9: u32 = 0;
    for k in 0..nslots {
        if st_field_zst(p, mg, g, k) {
            continue; // zero-sized field: no C member to initialize
        }
        if ne9 != 0 {
            out.push_str(", ");
        }
        ne9 += 1;
        st_field(p, mg, unsafe g.dm, unsafe g.dn, k, out);
        out.push_str(" = ");
        if !st_slot(p, mg, cev, name, gi, k, out) {
            return false;
        }
    }
    if ne9 == 0 {
        out.push_str("0"); // all fields erased inside a still-material carrier
    }
    out.push_str(" }");
    return true;
}

// A whole group at file scope: tentative forward declarations for every standalone auxiliary
// (back-references and cycles resolve against them), then their definitions. The ROOT is the
// caller's to define (its linkage differs per use).
fn st_group(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, name: str, root: u32, out: &mut String) bool {
    let groupn = unsafe cev.static_at(root).groupn;
    for gi in root + 1..root + groupn {
        if unsafe cev.static_at(gi).parent != iri::S_NO_PARENT {
            continue;
        }
        let mut nm2 = String::from_str(name);
        nm2.push_str("__ct");
        nm2.push_u64(unsafe cev.static_at(gi).ord - 1);
        let mut dl = String::new();
        let ok = st_ctype(p, mg, cev, gi, nm2.as_str(), &mut dl);
        if ok {
            out.push_str("static const ");
            out.push_string(&dl);
            out.push_str(";\n");
        }
        if !ok {
            return false;
        }
    }
    for gi in root + 1..root + groupn {
        if unsafe cev.static_at(gi).parent != iri::S_NO_PARENT {
            continue;
        }
        let mut nm2 = String::from_str(name);
        nm2.push_str("__ct");
        nm2.push_u64(unsafe cev.static_at(gi).ord - 1);
        let mut dl = String::new();
        let mut ok = st_ctype(p, mg, cev, gi, nm2.as_str(), &mut dl);
        if ok {
            out.push_str("__attribute__((unused)) static const ");
            out.push_string(&dl);
            out.push_str(" = ");
            ok = st_init(p, mg, cev, name, gi, out);
            out.push_str(";\n");
        }
        if !ok {
            return false;
        }
    }
    return true;
}

// `@emit_macro` template rewriting: trim trailing newlines, escape the rest as line
// continuations, expand the paste marker (byte 1) to `##`.
fn macro_finish(body: str, out: &mut String) {
    let mut endp = body.len();
    while endp > 0 && body.byte_at(endp - 1) == 10 {
        endp -= 1;
    }
    for i in 0..endp {
        let ch = body.byte_at(i);
        if ch == 10 {
            out.push_str(" \\\n");
        } else if ch == 1 {
            out.push_str("##");
        } else {
            out.push_byte(ch);
        }
    }
    out.push_str("\n");
}

// `<QUALIFIED>` uppercased with every non-alphanumeric flattened to `_` -- the template family stem.
fn macro_stem(mg: &mut mbe::Mangler, m: ModuleId, name: tok::Span, out: &mut String) {
    let mut q = String::new();
    mg.modpfx(m, &mut q);
    mg.ident(m, name, &mut q);
    let qs = q.as_str();
    for i in 0..qs.len() {
        let ch = qs.byte_at(i);
        if ch >= b'a' && ch <= b'z' {
            out.push_byte(ch - 32);
        } else if ch >= b'A' && ch <= b'Z' || ch >= b'0' && ch <= b'9' {
            out.push_byte(ch);
        } else {
            out.push_byte(b'_');
        }
    }
}

// The `(T, _SCM_T, ..., NAME) ` macro parameter list from the declaration's generics.
fn macro_params(p: &loader::Package, mg: &mut mbe::Mangler, m: ModuleId, gens: NodeList, out: &mut String) {
    let a = unsafe &*p.module_ast_const(m);
    for i in 0..gens.len {
        let gid = unsafe a.list(gens)[i as usize];
        let mut nm = String::new();
        mg.ident(m, a.at_const(a.at_const(gid).as_data.generic_param.name).as_data.name.text, &mut nm);
        out.push_string(&nm);
        out.push_str(", _SCM_");
        out.push_string(&nm);
        out.push_str(", ");
    }
    out.push_str("NAME) ");
}

// `extern "C" "<header>"` blocks across the package: emit each unique include (module-relative
// realpath when it resolves, else the local/system spelling heuristic) and record every fn the
// header prototypes (call-site protos would conflict with the real declarations).
fn cemit_extern_includes(p: &loader::Package, out: &mut String, backed: &mut Set<u64>) {
    let mut seen = Vector::<String>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let src = p.modules[m].source.as_str();
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_EXTERN_BLOCK {
                continue;
            }
            let eb = a.at_const(nid).as_data.extern_block;
            if eb.header == NODE_NONE {
                continue;
            }
            for j in 0..eb.items.len {
                let fnid = unsafe a.list(eb.items)[j as usize];
                if a.at_const(fnid).kind == NodeKind::NODE_FUNCTION {
                    backed.insert(skey_mix(0, m as u64 << 32 | fnid as u64));
                }
            }
            let hs = a.at_const(eb.header).span;
            let s0 = (hs.start + 1) as usize;
            let e0 = (hs.end - 1) as usize;
            if e0 <= s0 {
                continue;
            }
            let htxt = src.slice(s0, e0);
            let mut line = String::new();
            let mut done = false;
            if p.modules[m].file.len() != 0 {
                // resolve next to the declaring module's file; realpath makes the tree
                // compile from any location
                let fs2 = p.modules[m].file.as_str();
                let mut dend = fs2.len();
                while dend > 0 && fs2.byte_at(dend - 1) != b'/' {
                    dend -= 1;
                }
                let mut rel = String::new();
                if dend != 0 {
                    rel.push_str(fs2.slice(0, dend));
                } else {
                    rel.push_str("./");
                }
                rel.push_str(htxt);
                let mut absb = PathBuf {};
                let ra = unsafe shim::sc_realpath(rel.cstr(), &mut absb[0]);
                if ra != null {
                    line.push_str("#include \"");
                    line.push_str(diag::cstr(&absb[0]));
                    line.push_str("\"\n");
                    done = true;
                }
            }
            if !done {
                let local = htxt.byte_at(0) == b'.' || htxt.byte_at(0) == b'/';
                line.push_str(if_s2(local, "#include \"", "#include <"));
                line.push_str(htxt);
                line.push_str(if_s2(local, "\"\n", ">\n"));
            }
            let mut dup = false;
            for k in 0..seen.len() {
                if seen.at(k).as_str() == line.as_str() {
                    dup = true;
                    break;
                }
            }
            if dup {} else {
                out.push_string(&line);
                seen.push(line);
            }
        }
    }
}

const fn if_s2(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}

// Scope-end destruction for a lane body: elaborate the drop schedule and rewrite the body with
// drop terminators, exactly as the differential does -- WITHOUT this, emitted programs leak every
// non-moved owning local (explicit `.free()` calls are the only TM_DROPs lowering itself emits).
/// The drop-elaboration analyses, pooled: one instance rebuilds in place per body (capacity kept),
/// mirroring flow_ir's FlowCtx -- fresh builds per body dominated the elaboration's allocator cost.
struct DropCtx {
    pub ow: bfx::Owner,
    pub forest: bmp::MoveForest,
    pub facts: bfx::BodyFacts,
    pub cfg: bdf::Cfg,
    pub mv: bdf::MoveFlow,
    pub el: ird::ElabCtx,
}

fn cemit_apply_drops(dc: &mut DropCtx, lw: &mut irl::Lowerer) {
    dc.forest.build_into(&lw.body);
    bfx::generate_into(&mut dc.ow, &lw.body, &dc.forest, &mut dc.facts);
    dc.cfg.build_into(&lw.body);
    dc.mv.build_into(&lw.body, &dc.forest, &dc.facts, &dc.cfg);
    ird::elaborate_into(&mut dc.ow, &lw.body, &dc.forest, &dc.facts, &dc.mv, &mut dc.el);
    ird::insert_drops(&mut lw.body, &dc.el.sched, &dc.forest);
}

// The free-glue wrapper fields (frozen `__fb` convention): a CONCRETE struct's selected user
// `free` whose body never touches some destructible owning fields gets renamed `<sym>__fb`, and
// the public symbol wraps it, freeing each untouched field -- covering every early return.
fn cemit_free_glue_fields(
    p: &loader::Package,
    cem: &mut cbe::CEmit,
    m: ModuleId,
    fnid: NodeId,
    out_f: &mut Vector<String>,
    out_t: &mut Vector<TypeId>,
) bool {
    let tgt = cem.mg.method_target(m, fnid);
    if tgt.node == NODE_NONE || tgt.module != m {
        return false;
    }
    let a = unsafe &*p.module_ast_const(m);
    let f = a.at_const(fnid).as_data.function;
    if f.body == NODE_NONE || f.params.len == 0 {
        return false;
    }
    let src = p.modules[m as usize].source.as_str();
    let nsp = a.at_const(f.name).as_data.name.text;
    if src.slice(nsp.start as usize, nsp.end as usize) != "free" {
        return false;
    }
    let tn = a.at_const(tgt.node);
    if tn.kind != NodeKind::NODE_STRUCT || tn.as_data.aggregate.is_union || tn.as_data.aggregate.generics.len != 0 {
        return false;
    }
    let bsp = a.at_const(f.body).span;
    let is_tuple = tn.as_data.aggregate.is_tuple;
    let ms = tn.as_data.aggregate.members;
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        let fnode = a.at_const(fid);
        // tuple members are bare type nodes; named members are NODE_FIELD
        if !is_tuple && fnode.kind != NodeKind::NODE_FIELD {
            continue;
        }
        let ftn = if is_tuple {
            fid;
        } else {
            fnode.as_data.field.ty;
        };
        let ft = a.type_of(ftn);
        if ft == TYPE_NONE {
            continue;
        }
        let fk = a.type_at(ft).kind;
        if fk == TypeKind::TYPE_POINTER || fk == TypeKind::TYPE_REFERENCE {
            continue; // non-owning by rule: raw pointers are borrows
        }
        if !cem.is_destructible(m, ft, 0) {
            continue;
        }
        let mut touched = false;
        for r in 0..a.resolutions_len() {
            let d = a.resolution_def(r as NodeId);
            if d.node == fid && d.module == m {
                let ksp = a.at_const(r as NodeId).span;
                if ksp.start >= bsp.start && ksp.end <= bsp.end {
                    touched = true;
                    break;
                }
            }
        }
        if !touched {
            let mut fname = String::new();
            if is_tuple {
                fname.push_str("_");
                fname.push_u64(i);
            } else {
                cem.mg.ident(m, a.at_const(fnode.as_data.field.name).as_data.name.text, &mut fname);
            }
            out_f.push(fname);
            out_t.push(ft);
        }
    }
    return out_f.len() != 0;
}

// The two shared-header includes, spelled relative to a module's nested output location
// (one `../` per `::` segment; quote includes resolve against the including file).
fn cemit_shared_incs(mod_path: str, out: &mut String) {
    let mut depth: u32 = 0;
    let mut i: usize = 0;
    while i + 1 < mod_path.len() {
        if mod_path.byte_at(i) == b':' && mod_path.byte_at(i + 1) == b':' {
            depth += 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    out.push_str("#include \"");
    for _d in 0..depth {
        out.push_str("../");
    }
    out.push_str("__sc_types.h\"\n#include \"");
    for _d in 0..depth {
        out.push_str("../");
    }
    out.push_str("__sc_protos.h\"\n");
}

// Overwrite `path` with the buffer; false when the file cannot be opened.
fn cemit_write(path: str, s: &String) bool {
    let f = open_out(path);
    if f == null {
        return false;
    }
    let b = s.as_str();
    let _ = unsafe stdio::fwrite(b.ptr(), 1, b.len(), f);
    unsafe stdio::fclose(f);
    return true;
}

// The C `main`: argv marshalled into a Vector<str> when the user main takes one.
fn cemit_main_wrapper(out: &mut String, argv: bool) {
    if !argv {
        out.push_str("int main(void) { return __sc_user_main(); }\n");
        return;
    }
    out.push_str(
        "static Vector__str __sc_argv_to_vector(int argc, char **argv) {\n  Vector__str out = (Vector__str){0};\n  if (argc > 0) {\n    out.ptr = (str *)Global__alloc((Global *)&__sc_zst_1, sizeof(str) * (size_t)argc, _Alignof(str));\n    out.len = (size_t)argc;\n    out.cap = (size_t)argc;\n    for (int i = 0; i < argc; i++) { out.ptr[i] = str__from_cstr(argv[i]); }\n  }\n  return out;\n}\nint main(int argc, char **argv) { return __sc_user_main(__sc_argv_to_vector(argc, argv)); }\n",
    );
}

// The single-line signature prefix of an emitted function body, as a prototype.
fn proto_of(body: &String, out: &mut String) {
    let bs = body.as_str();
    let n = bs.len();
    // A shared declaration must not carry optimization-only specifiers: an `inline` prototype whose
    // TU has no definition is flagged (`-Werror` inline-never-defined), and `__attribute__((always_
    // inline, ...))` needs the `inline` keyword it would then lose. The definition keeps them; the
    // `_Noreturn` specifier and return type follow this prefix and stay.
    let mut start: usize = 0;
    loop {
        if start + 7 <= n && bs.slice(start, start + 7) == "extern " {
            start += 7;
        } else if start + 7 <= n && bs.slice(start, start + 7) == "inline " {
            start += 7;
        } else if start + 13 <= n && bs.slice(start, start + 13) == "__attribute__" {
            let mut j = start + 13;
            let mut depth: i32 = 0;
            let mut began = false;
            while j < n {
                let c = bs.byte_at(j);
                if c == 40 {
                    depth += 1;
                    began = true;
                } else if c == 41 {
                    depth -= 1;
                }
                j += 1;
                if began && depth == 0 {
                    break;
                }
            }
            while j < n && bs.byte_at(j) == 32 {
                j += 1;
            }
            start = j;
        } else {
            break;
        }
    }
    let mut i = start;
    while i + 1 < n {
        if bs.byte_at(i) == 32 && bs.byte_at(i + 1) == 123 {
            break;
        }
        i += 1;
    }
    out.push_str(bs.slice(start, i));
    out.push_str(";\n");
}

fn borrowck_module(p: &mut loader::Package, i: usize, ow: &mut bfx::Owner, ctx: &mut bfi::BorrowCtx) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.borrowck(ow, ctx);
    let had = t.has_errors();
    p.lint_errs = p.lint_errs + t.errors.errors.len() as u32;
    if had {
        t.log_errors();
    }
    return !had;
}

// Borrow-check every module, serially, in module order, through ONE ownership oracle and ONE
// borrow pipeline (their memo tables and capacities survive across modules). `keep` (null =
// discard) collects every lowered body for the backend, so codegen starts from finished lowerings.
pub fn borrowck_all(p: &mut loader::Package, keep: *mut irl::Keep) bool {
    let n = p.modules.len();
    let mut ow = bfx::Owner::new(p);
    let mut ctx = bfi::BorrowCtx::new();
    ctx.keep = keep;
    let mut ok = true;
    for i in 0..n {
        if !borrowck_module(p, i, &mut ow, &mut ctx) {
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

// Promoted fold failures (proven UB, failed mandatory `const fn` folds) recorded by the evaluator:
// errors against the owning module; only the outermost record of nested failures is reported.
fn report_fold_errs(p: &mut loader::Package) {
    // the engine's recorded fold failures drain here (lowering-time implicit folds; a node can
    // record more than once across passes, so duplicates collapse)
    let mut ms = Vector::<ModuleId>::new();
    let mut ids = Vector::<NodeId>::new();
    let mut kinds = Vector::<u8>::new();
    let mut details = Vector::<String>::new();
    let cirp = p.cir as *mut iri::Interp;
    if cirp != null {
        for i in 0..unsafe cirp.fold_errs.len() {
            let m2 = unsafe cirp.fold_errs.at(i).m;
            let id2 = unsafe cirp.fold_errs.at(i).id;
            let mut dup = false;
            for j in 0..ms.len() {
                if ms[j] == m2 && ids[j] == id2 {
                    dup = true;
                }
            }
            if dup {
                continue;
            }
            ms.push(m2);
            ids.push(id2);
            kinds.push(unsafe cirp.fold_errs.at(i).kind);
            let mut d = String::new();
            d.push_string(unsafe &cirp.fold_errs.at(i).detail);
            details.push(d);
        }
    }
    let nerr = ms.len();
    for i in 0..nerr {
        let m = ms[i];
        let rid = ids[i];
        let sp = p.modules[m as usize].ast.at_const(rid).span;
        let mut inner = false;
        for j in 0..nerr {
            if j == i || ms[j] != m {
                continue;
            }
            let sp2 = p.modules[m as usize].ast.at_const(ids[j]).span;
            if sp2.start <= sp.start && sp.end <= sp2.end && (sp2.start < sp.start || sp.end < sp2.end) {
                inner = true;
                break;
            }
        }
        if inner {
            continue;
        }
        let rkind = kinds[i];
        let mut errs = diag::Errors::new();
        if iri::it_trap_is_ub(rkind) {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("expression has undefined behavior when evaluated: {}", details.at(i).as_str()),
            );
        } else {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format(
                    "this 'const fn' call has compile-time-known arguments but failed to evaluate: {}",
                    details.at(i).as_str(),
                ),
            );
        }
        errs.finalize(p.modules[m as usize].source.as_str(), p.modules[m as usize].file.as_str());
        errs.log();
        p.ok = false;
    }
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

// ---------------------------------------------------------------------------------------------------------
// Global-phase compilation of a loaded package into a `<root>/build/` tree.
// ---------------------------------------------------------------------------------------------------------

/// Drop @platform-gated items that don't match the build target BEFORE resolution, so inactive code is
/// parsed-but-never-resolved and two same-named platform variants collapse to the single active one.
/// target: 0 windows, 1 macos, 2 linux; Attr.arg is the active-set mask (windows=bit0/macos=bit1/linux=bit2).
pub fn platform_filter(p: &mut loader::Package, target: i32) {
    let n = p.modules.len();
    for mi in 0..n {
        platform_filter_module(p, mi, target);
    }
}

/// Filter one module's item list (idempotent): the LSP's incremental rebuild re-filters just the
/// reparsed module.
pub fn platform_filter_module(p: &mut loader::Package, mi: usize, target: i32) {
    let arch = p.arch; // the instruction-set axis rides on the package, so no caller has to thread it
    let m = &mut p.modules[mi];
    let root = m.ast.root;
    if m.ast.at_const(root).kind != NodeKind::NODE_PROGRAM {
        return;
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
    let cev = p.cir as *mut iri::Interp;
    let sp = cev.lint_body(m as ModuleId, fnode);
    if sp.end > sp.start {
        if iri::it_trap_is_ub(cev.trap_kind_get()) {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement is undefined behavior when executed: {}", cev.trap_detail()),
            );
        } else {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement always panics at runtime: {}", cev.trap_detail()),
            );
        }
    }
}

/// Always-panics check (the `unconditional_panic` analog, an ERROR like the raw-array provable-OOB
/// gate -- the same proof one tier up). A DRIVER phase, after every module has typechecked: the
/// sweep interprets cross-module `const fn` bodies, whose types only exist once their module is
/// typed -- an inline per-module pass would silently fold nothing (module order). @test fns are
/// exempt (panicking on purpose is a feature there), as are explicit `panic(..)` calls (only a
/// panic reached THROUGH a `const fn` frame classifies -- see Interp::lint_body).
pub fn check_always_panics_module(p: &mut loader::Package, m: usize, errs: &mut diag::Errors) {
    if p.cir == null || !p.modules[m].has_ast {
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
    let cev = p.cir as *mut iri::Interp;
    if cev.fn_const_suggest(m as ModuleId, fnode) {
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
    if p.cir == null {
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
    let cev = p.cir as *mut iri::Interp;
    if !cev.fn_const_suggest(fd.module, fd.node) {
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
    if p.cir == null {
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
    p.ok = borrowck_all(p, null) && p.ok;
    if !p.ok {
        return 1;
    }
    if facts_verify(p, &wms, "borrowck") != 0 {
        return 1;
    }
    if core_ir_pass(p) != 0 {
        return 1;
    }
    let _ = borrow_ir_pass(p);
    layout_pass(p);
    cemit_pass(p);
    // Report-only passes: skipped while `--fix` iterates (they yield no fixes and would print
    // duplicates). The const suggestion is the exception: opt-in (`--const`, warning every
    // eligible function at once would swamp default lints), and under `--fix` it contributes its
    // `const `-insertion fixes instead of printing.
    if fixes == null {
        lint_unused_items(p, lint_mod as i32);
        let cirp0 = p.cir as *mut iri::Interp;
        if cirp0 != null {
            unsafe cirp0.all_typed = true;
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
    ast_stats(p);
    let mut wms = Vector::<facts::FactsWatermark>::new();
    facts_snapshot(p, &mut wms);
    // The backend consumes borrowck's lowerings (irkeep), so the evaluator must reach its final
    // state BEFORE the first body lowers: every module is typed here, and mandatory call-site
    // folds must behave exactly as they would under the backend's own lowering.
    {
        let cirp1 = p.cir as *mut iri::Interp;
        if cirp1 != null {
            unsafe cirp1.all_typed = true;
            unsafe cirp1.record_folds = true;
        }
    }
    let mut irkeep = irl::Keep::new();
    p.ok = borrowck_all(p, &mut irkeep) && p.ok;
    // Release the pool as soon as the one parallel stage is done: the test runner FORKS after this,
    // and a forked child inherits the pool's state but none of its worker threads. (Also what keeps
    // the leak gate green.) The bench calls borrowck_all directly, so its iterations keep a warm pool.
    if !p.ok {
        return 1;
    }
    if facts_verify(p, &wms, "borrowck") != 0 {
        return 1;
    }
    if core_ir_pass(p) != 0 {
        return 1;
    }
    let _ = borrow_ir_pass(p);
    layout_pass(p);
    cemit_pass(p);
    cemit_tu_pass(p);
    if lint {
        lint_unused_items(p, -1);
    }
    // static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let cirf = p.cir as *mut iri::Interp;
    if cirf != null {
        let pv = p as *mut loader::Package;
        unsafe cirf.all_typed = true;
        // an ERROR, not a lint: it runs on every build (user modules; std is gated by check.sh's
        // explicit std lint invocations)
        check_always_panics(p, -1);
        cirf.flush_asserts(flush_assert_err, pv);
        cirf.flush_consts(flush_const_err, pv);
    }
    if !p.ok {
        return 1;
    }
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
    // the whole-package Core-IR emission runs BEFORE the live-module list: it seeds every module
    // unconditionally, so any module with a non-empty TU must be written even when the reference
    // scan finds no direct use (prelude bodies the instance TU calls into)
    let mut co = CemitOut::new(n);
    {
        let cirg = p.cir as *mut iri::Interp;
        if cirg != null {
            unsafe cirg.record_folds = true; // the seed/instance lowering attempts mandatory folds
        }
    }
    cemit_package(p, testing, &plan, live, target, &mut co, &mut irkeep);
    report_fold_errs(p);
    if !p.ok {
        err = true;
    }
    if co.skips != 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "error: internal: the backend refused %llu emissions\n".ptr() as *const char,
            co.skips,
        );
        err = true;
    }
    // transitive TU pruning: keep scan-live modules, then everything a KEPT TU (or the always-
    // written instance TU) spells symbols from -- dead prelude chains drop out entirely
    let mut keep_mod = Vector::<bool>::new();
    for mi9 in 0..n {
        keep_mod.push(live == null || unsafe live[mi9]);
    }
    let mut changed9 = true;
    while changed9 {
        changed9 = false;
        for e9 in 0..co.edges.len() {
            let ed9 = co.edges[e9];
            let src9 = (ed9 >> 32) as usize;
            let dst9 = (ed9 & 0xFFFFFFFFu64) as usize;
            let on9 = src9 == 65534 || src9 < n && *keep_mod.at(src9);
            if on9 && dst9 < n && !*keep_mod.at(dst9) && co.tus.at(dst9).len() != 0 {
                keep_mod.set(dst9, true);
                changed9 = true;
            }
        }
    }
    let mut lm = Vector::<ModuleId>::new();
    for oi in 0..n {
        let mi = unsafe order[oi];
        let has_wrap = co.have_main && !testing && mi as u64 == co.main_mod;
        if co.tus.at(mi as usize).len() == 0 && !has_wrap {
            continue;
        }
        if live != null && !unsafe live[mi as usize] && !*keep_mod.at(mi as usize) {
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
    {
        // Shared headers land before any module file, then per-module header shims + sources in
        // emit order, then the shared instance TU.
        let thp = build_out_path(root, "__sc_types", ".h");
        let php = build_out_path(root, "__sc_protos", ".h");
        if !cemit_write(thp.as_str(), &co.types_h) || !cemit_write(php.as_str(), &co.protos_h) {
            err = true;
        }
        sink_notify(sink, thp.as_str(), 0);
        sink_notify(sink, php.as_str(), 0);
        keep.push(thp);
        keep.push(php);
        for k in 0..lm.len() {
            let mut sh = String::new();
            cemit_shared_incs(p.modules[lm[k] as usize].path.as_str(), &mut sh);
            if !cemit_write(keep.at(base_h + k).as_str(), &sh) {
                err = true;
            }
            sink_notify(sink, keep.at(base_h + k).as_str(), 0);
        }
        for k in 0..lm.len() {
            let mut sc9 = String::new();
            cemit_shared_incs(p.modules[lm[k] as usize].path.as_str(), &mut sc9);
            sc9.push_string(co.tus.at(lm[k] as usize));
            if !cemit_write(keep.at(base_c + k).as_str(), &sc9) {
                err = true;
            }
            sink_notify(sink, keep.at(base_c + k).as_str(), 1);
        }
        if co.inst_c.len() != 0 {
            let ip = build_out_path(root, "__sc_inst", ".c");
            let mut ic = String::from_str("#include \"__sc_types.h\"\n#include \"__sc_protos.h\"\n");
            ic.push_string(&co.inst_c);
            if !cemit_write(ip.as_str(), &ic) {
                err = true;
            }
            sink_notify(sink, ip.as_str(), 1);
            keep.push(ip);
        }
    }
    // publish the per-TU cache only after a fully successful emission; keep[] shields it from pruning
    if !err && co.skips == 0 && co.tuc_path.len() != 0 {
        if cemit_write(co.tuc_path.as_str(), &co.tuc_img) {
            keep.push(String::from_str(co.tuc_path.as_str()));
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
    // Report-only: emission must have read the semantic tables frozen (intern-pool growth is the one
    // sanctioned mutation; see ast::facts).
    let _ = facts_verify(p, &wms, "codegen");
    return rc;
}
