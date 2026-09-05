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
import sc_runtime;
import std::parallel::runtime as prt;
import std::parallel::sync as psync;
import ir::core as irc;
import ir::lower as irl;
import ir::print as irp;
import ir::verify as irv;
import ir::drops as ird;
import ir::bce as bce;
import ir::inline as inl;
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
import utils::errors as diag;
import driver::tuc as tuc;
import driver::taskctl as tctl;
import driver::util as *;

import driver::extc as *;
import driver::test as *;

// Dead-module pruning of the emit set: a live module reaches its own decls + everything it references.
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
    let y = *p.module_ast_const(am).type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN {
        return true;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return ast_type_mentions_builtin(p, am, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *p.module_ast_const(am).instance(y.as_data.inst);
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
    let y = *p.module_ast_const(am).type_at(t);
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
        let it = *p.module_ast_const(am).instance(y.as_data.inst);
        let np = p.modules.len();
        if it.module as usize < np {
            if mark_live(live, np, it.module) {
                changed = true;
            }
        }
        let home = p.instance_home_in(am, &it);
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

// One module's outgoing liveness edges, written as a bool row. Pure reads of frozen pools, so the
// rows compute in parallel; the closure walk over them is order-insensitive (a set union).
fn emit_live_row(p: &loader::Package, m: usize, row: *mut bool) {
    let n = p.modules.len();
    let a = p.module_ast_const(m as ModuleId);
    let nr = a.resolutions_len();
    for r in 0..nr {
        let d = a.resolution_def(r as NodeId);
        if d.node != NODE_NONE && d.module as usize < n && d.module as usize != m && p.builtin_of_decl(d.module, d.node) < 0 {
            let _ = mark_live(row, n, d.module);
        }
    }
    let nt = unsafe a.type_pool.len();
    for ti in 0..nt {
        let _ = mark_type_modules(p, m as ModuleId, ti as TypeId, row);
    }
    let ni = unsafe a.instances.len();
    for ii in 0..ni {
        let it = *a.instance(ii as u32);
        if it.module as usize < n {
            let _ = mark_live(row, n, it.module);
        }
        let home = p.instance_home_in(m as ModuleId, &it);
        if home as usize < n {
            let _ = mark_live(row, n, home);
        }
        for k in 0..it.n {
            let _ = mark_type_modules(p, m as ModuleId, unsafe it.args[k as usize], row);
            if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe it.args[k as usize]) {
                let _ = mark_live(row, n, p.core_module);
            }
        }
    }
    let nmo = unsafe a.mono.len();
    for moi in 0..nmo {
        let mu = unsafe a.mono[moi];
        for k in 0..mu.n {
            let _ = mark_type_modules(p, m as ModuleId, unsafe mu.args[k as usize], row);
            if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe mu.args[k as usize]) {
                let _ = mark_live(row, n, p.core_module);
            }
        }
    }
    let nmi = unsafe a.method_insts.len();
    for xi in 0..nmi {
        let miu = unsafe a.method_insts[xi];
        let _ = mark_type_modules(p, m as ModuleId, miu.instance, row);
        for k in 0..miu.n {
            let _ = mark_type_modules(p, m as ModuleId, unsafe miu.targs[k as usize], row);
            if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, unsafe miu.targs[k as usize]) {
                let _ = mark_live(row, n, p.core_module);
            }
        }
    }
}

// `p` is opaque so the release bootstrap's borrow checker accepts the payload as 'static.
struct LiveTask {
    pub p: *const void,
    pub row: *mut bool,
    pub m: u64,
}

// Tasks only read the frozen package and write disjoint rows.
unsafe extend LiveTask as Send {}

fn compute_emit_live(p: &loader::Package) Vector<bool> {
    let n = p.modules.len();
    let sz = if n != 0 {
        n;
    } else {
        1 as usize;
    };
    let mut live = Vector::<bool>::new();
    live.resize_default(sz);
    for i in 0..n {
        if !p.modules[i].prelude {
            live[i] = true;
        }
    }
    let mut rows = Vector::<bool>::new();
    rows.resize_default(sz * sz);
    if p.jobs != 1 && n > 1 {
        let wg = psync::WaitGroup::new();
        let pv = (p as *const loader::Package) as *const void;
        for m in 0..n {
            if !p.modules[m].has_ast {
                continue;
            }
            wg.add(1);
            let t = LiveTask { p: pv, row: unsafe (rows.as_ptr() as *mut bool + m * n), m: m as u64 };
            let wgc = wg.clone();
            launch || {
                emit_live_row(unsafe &*(t.p as *const loader::Package), t.m as usize, t.row);
                wgc.done();
            };
        }
        wg.wait_masked();
    } else {
        for m in 0..n {
            if p.modules[m].has_ast {
                emit_live_row(p, m, unsafe (rows.as_ptr() as *mut bool + m * n));
            }
        }
    }
    let mut changed = true;
    while changed {
        changed = false;
        for m in 0..n {
            if !live[m] || !p.modules[m].has_ast {
                continue;
            }
            for d in 0..n {
                if rows[m * n + d] && !live[d] {
                    live[d] = true;
                    changed = true;
                }
            }
        }
    }
    return live;
}

// Pipeline stages over one module (move the Ast out of its slot, run, and restore it).
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
fn discharge_obligations(p: &mut loader::Package, n: usize, dup_done: bool) {
    // Package-wide duplicate conformances first: a per-module concern, but only decidable once
    // every module is typechecked, like the obligations below. The parallel checking path already
    // ran this as its own level (dup_done); only the serial path sweeps here.
    let dup_n = if dup_done {
        0usize;
    } else {
        n;
    };
    for i in 0..dup_n {
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

struct RsOut {
    pub ok: bool,
    pub warns: u32,
    pub errs: u32,
    pub errors: diag::Errors,
}

struct RsTask {
    pub p: *mut loader::Package,
    pub outs: *mut RsOut,
    pub m: u64,
    pub lint: bool,
}

unsafe extend RsTask as Send {}

fn rs_run_one(t: RsTask) {
    let pkg = t.p as *const loader::Package;
    let p = unsafe &mut *t.p;
    let i = t.m as usize;
    let out = unsafe &mut *(t.outs + i);
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let aptr = (&mut m.ast) as *mut Ast;
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, str::from_raw(src as *const u8, len), pkg);
    r.lint = t.lint && !p.modules[i].prelude;
    r.resolve();
    out.ok = !r.has_errors();
    out.warns = r.errors.warns.len() as u32;
    out.errs = r.errors.errors.len() as u32;
    out.errors = replace(&mut r.errors, diag::Errors::new());
    hirl::lower_module(p, i);
}

// Resolution has no cross-module ordering: a module reads only parse-level foreign state through
// the package index. Build the index and every import closure up front (the shared lazy caches),
// pin the syntax arrays (prelude scans read foreign nodes while their owners append), run one task
// per module, then replay diagnostics and counters in module order.
fn resolve_all_par(p: &mut loader::Package, lint: bool) {
    let n = p.modules.len();
    p.ensure_index();
    for i in 0..n {
        // module_closure, not import_closure: only the former fills the clo_lists cache that
        // glob_lookup consults from the tasks.
        let _ = p.module_closure(i as ModuleId);
    }
    for i in 0..n {
        p.modules[i].ast.nodes.freeze();
        p.modules[i].ast.children.freeze();
    }
    let mut outs = Vector::<RsOut>::with_capacity(n);
    for _ in 0..n {
        outs.push(RsOut { ok: true, warns: 0, errs: 0, errors: diag::Errors::new() });
    }
    prt::set_stack_size(8usize << 20); // the resolver's expression recursion outgrows the default task stack
    let pp = p as *mut loader::Package;
    let ob = outs.index_mut(0) as *mut RsOut;
    let wg = psync::WaitGroup::new();
    for i in 0..n {
        wg.add(1);
        let t = RsTask { p: pp, outs: ob, m: i as u64, lint: lint };
        let wgc = wg.clone();
        launch || {
            rs_run_one(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    for i in 0..n {
        p.modules[i].ast.nodes.thaw();
        p.modules[i].ast.children.thaw();
    }
    for i in 0..n {
        let o = outs.index_mut(i);
        if !o.ok || o.errors.has_warnings() {
            o.errors.log();
        }
        p.lint_warnings = p.lint_warnings + o.warns;
        p.lint_errs = p.lint_errs + o.errs;
        p.ok = o.ok && p.ok;
    }
}

struct TcOut {
    pub ok: bool,
    pub warns: u32,
    pub errs: u32,
    pub fixable: u32,
    pub errors: diag::Errors,
    pub log: tc::TcMarkLog,
}

struct TcTask {
    pub p: *mut loader::Package,
    pub mods: *const u32, // this SCC's modules, ascending id order
    pub nmods: usize,
    pub outs: *mut TcOut, // outs base; slot per module id
    pub lint: bool,
    pub wc: *mut TcWaitSt,
}

unsafe extend TcTask as Send {}

// The waiter state behind Package.tc_wait: done flags live on the Package; the mutex/condvar pair
// serializes flag publication against parked waiters.
struct TcWaitSt {
    pub mu: psync::Mutex<i32>,
    pub cv: psync::Condvar,
    pub p: *mut loader::Package,
}

fn tc_wait_impl(ctx: *mut void, m: ModuleId) {
    let st = ctx as *mut TcWaitSt;
    let p = unsafe (&*st).p;
    let g = (unsafe &(&*st).mu).lock();
    while *(unsafe &*p).tc_mod_done.at(m as usize) == 0 {
        (unsafe &(&*st).cv).wait_masked(&g);
    }
}

fn tc_run_one(t: TcTask) {
    let pkg = t.p;
    for k in 0..t.nmods {
        let i = (unsafe t.mods[k]) as usize;
        let p = unsafe &mut *t.p;
        let out = unsafe (t.outs + i);
        let want = t.lint && !p.modules[i].prelude;
        let m = &mut p.modules[i];
        let src = m.source.as_str().ptr() as *const char;
        let len = m.source.len();
        let mut tck = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
        tck.lint = want;
        tck.mark_log = &mut (unsafe &mut *out).log;
        tck.check();
        {
            // Publish completion: everything check() wrote happens-before a waiter's wake.
            let st = t.wc;
            let _g = (unsafe &(&*st).mu).lock();
            (unsafe &mut *t.p).tc_mod_done.set(i, 1);
            (unsafe &(&*st).cv).notify_all();
        }
        let o = unsafe &mut *out;
        o.ok = !tck.has_errors();
        o.warns = tck.errors.warns.len() as u32;
        o.errs = tck.errors.errors.len() as u32;
        o.fixable = tck.errors.fixable_errs;
        o.errors = replace(&mut tck.errors, diag::Errors::new());
    }
}

// Type-check every module in parallel while preserving serial module-order OBSERVABILITY: the
// engine's index-aware gate + retry-wait give each module the exact tc_done visibility the serial
// sweep gave it, diagnostics buffer per task and print in module order, and the package-global
// method marks replay through the real functions in module order.
// One module's cross-module duplicate-conformance sweep, run as a parallel level after every
// module is typechecked (the check reads other modules' frozen syntax, so it is decidable only
// then, and it writes nothing shared: errors buffer per module and log in module order).
struct DupTask {
    pub p: *mut loader::Package,
    pub i: usize,
    pub out: *mut diag::Errors,
}

unsafe extend DupTask as Send {}

fn dup_run_one(t: DupTask) {
    let pkg = t.p;
    let p = unsafe &mut *t.p;
    let m = &mut p.modules[t.i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut tck = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    tck.check_cross_module_dup_conformances();
    if tck.has_errors() {
        tck.errors.finalize(str::from_raw(src as *const u8, len), unsafe (&*t.p).modules[t.i].file.as_str());
        let o = unsafe &mut *t.out;
        *o = replace(&mut tck.errors, diag::Errors::new());
    }
}

fn typecheck_all_par(p: &mut loader::Package, lint: bool) bool {
    let n = p.modules.len();
    p.ensure_index();
    for i in 0..n {
        let _ = p.import_closure(i as ModuleId);
    }
    p.tc_done.clear();
    p.tc_mod_done.clear();
    for _ in 0..n {
        p.tc_done.push(Set::<u64>::new());
        p.tc_mod_done.push(0);
    }
    let cirp = p.cir as *mut iri::Interp;
    if cirp != null {
        unsafe cirp.elock_on = true;
        unsafe cirp.tc_par = true;
        unsafe cirp.retry_mod = 0 - 1;
    }
    for i in 0..n {
        p.modules[i].ast.ilock_on = true;
        // Pin the syntax arrays: tc synthesizes nodes while other tasks read pre-existing ones.
        p.modules[i].ast.nodes.freeze();
        p.modules[i].ast.children.freeze();
        p.modules[i].ast.resolutions.freeze();
    }
    let mut wc = TcWaitSt { mu: psync::Mutex::<i32>::new(0), cv: psync::Condvar::new(), p: p };
    p.tc_wait = tc_wait_impl;
    p.tc_wait_ctx = &mut wc;
    p.tc_frontier = true;
    let mut outs = Vector::<TcOut>::with_capacity(n);
    for _ in 0..n {
        outs.push(
            TcOut { ok: true, warns: 0, errs: 0, fixable: 0, errors: diag::Errors::new(), log: tc::TcMarkLog::new() },
        );
    }
    prt::set_stack_size(8usize << 20); // the checker's expression recursion outgrows the default task stack
    // Conflict-free schedule: import-SCC condensation, IMPORTS-first levels. A module only ever
    // reads modules in its import closure, and those are complete before its level starts, so
    // no two live tasks touch each other's Asts, and the serial-order visibility rules above
    // resolve every remaining cross-module question deterministically.
    let mut nscc: u32 = 0;
    {
        let idx9 = &p.idx.scc_of;
        for i in 0..n {
            if *idx9.at(i) + 1 > nscc {
                nscc = *idx9.at(i) + 1;
            }
        }
    }
    let mut lvl = Vector::<u32>::new(); // per SCC: 1 + max(level of imported SCCs), 0 at the leaves
    for _ in 0..nscc {
        lvl.push(0);
    }
    let mut changed = true;
    while changed {
        changed = false;
        for i in 0..n {
            let si = *p.idx.scc_of.at(i);
            let e0 = (*p.idx.mod_imports.at(i)) as usize;
            let e1 = (*p.idx.mod_imports.at(i + 1)) as usize;
            for e in e0..e1 {
                let j = (*p.idx.imports.at(e)) as usize;
                let sj = *p.idx.scc_of.at(j);
                if sj != si && *lvl.at(sj as usize) + 1 > *lvl.at(si as usize) {
                    lvl.set(si as usize, *lvl.at(sj as usize) + 1);
                    changed = true;
                }
            }
        }
        // The prelude is AMBIENTLY visible (format shims, sugar hooks): every non-prelude module
        // depends on every prelude module even without an import edge.
        let mut plvl: u32 = 0;
        for i in 0..n {
            if p.modules[i].prelude && *lvl.at((*p.idx.scc_of.at(i)) as usize) + 1 > plvl {
                plvl = *lvl.at((*p.idx.scc_of.at(i)) as usize) + 1;
            }
        }
        for i in 0..n {
            let si = (*p.idx.scc_of.at(i)) as usize;
            if !p.modules[i].prelude && *lvl.at(si) < plvl {
                lvl.set(si, plvl);
                changed = true;
            }
        }
    }
    let mut maxlvl: u32 = 0;
    for c in 0..nscc as usize {
        if *lvl.at(c) > maxlvl {
            maxlvl = *lvl.at(c);
        }
    }
    // Per-SCC module lists, ascending id (intra-SCC checks stay serial in id order). The whole
    // PRELUDE is one sequential group: prelude names are ambiently visible to every module
    // (prelude modules included), so no import-edge order exists among them.
    let mut scc_mods = Vector::<Vector<u32>>::new();
    for _ in 0..nscc + 1 {
        scc_mods.push(Vector::<u32>::new());
    }
    // The prelude pseudo-group rides at level 0.
    lvl.push(0);
    for i in 0..n {
        if p.modules[i].prelude {
            scc_mods.index_mut(nscc as usize).push(i as u32);
        } else {
            scc_mods.index_mut((*p.idx.scc_of.at(i)) as usize).push(i as u32);
        }
    }
    let ngrp = nscc + 1;
    let pp = p as *mut loader::Package;
    let wcp = (&mut wc) as *mut TcWaitSt;
    let want_lint = lint;
    let mut level: u32 = 0;
    while level <= maxlvl {
        let wg = psync::WaitGroup::new();
        let mut launched: i64 = 0;
        for c in 0..ngrp as usize {
            if *lvl.at(c) != level || scc_mods.at(c).len() == 0 {
                continue;
            }
            wg.add(1);
            launched += 1;
            let t = TcTask {
                p: pp,
                mods: scc_mods.at(c).as_ptr(),
                nmods: scc_mods.at(c).len(),
                outs: outs.index_mut(0),
                lint: want_lint,
                wc: wcp,
            };
            let wgc = wg.clone();
            launch || {
                tc_run_one(t);
                wgc.done();
            };
        }
        if launched != 0 {
            wg.wait_masked();
        }
        level += 1;
    }
    // Duplicate-conformance level: independent per module, under the same freeze and ilock
    // discipline as the checking levels. Replaces the serial per-module sweep in
    // discharge_obligations for the parallel path.
    let mut douts = Vector::<diag::Errors>::new();
    for _ in 0..n {
        douts.push(diag::Errors::new());
    }
    {
        let wgd = psync::WaitGroup::new();
        for i in 0..n {
            wgd.add(1);
            let t = DupTask { p: pp, i: i, out: douts.index_mut(i) };
            let wgc = wgd.clone();
            launch || {
                dup_run_one(t);
                wgc.done();
            };
        }
        wgd.wait();
    }
    p.tc_frontier = false;
    p.tc_wait = loader::loader_no_wait;
    p.tc_wait_ctx = null;
    if cirp != null {
        unsafe cirp.tc_par = false;
        unsafe cirp.elock_on = false;
        unsafe cirp.retry_mod = 0 - 1;
    }
    for i in 0..n {
        p.modules[i].ast.ilock_on = false;
        p.modules[i].ast.nodes.thaw();
        p.modules[i].ast.children.thaw();
        p.modules[i].ast.resolutions.thaw();
    }
    let mut ok = true;
    for i in 0..n {
        let o = outs.index_mut(i);
        if !o.ok {
            ok = false;
        }
        if !o.ok || o.errors.has_warnings() {
            o.errors.log();
        }
        p.lint_warnings = p.lint_warnings + o.warns;
        p.lint_errs = p.lint_errs + o.errs;
        p.lint_fixable = p.lint_fixable + o.fixable;
        // Module-order replay of the package-global marks, through the real visibility checks.
        let lg = &o.log;
        for k in 0..lg.kinds.len() {
            let dv = lg.a[k];
            let d = DefId { module: (dv >> 32) as ModuleId, node: (dv & 0xFFFFFFFFu64) as NodeId };
            let kd = lg.kinds[k];
            if kd == 1 {
                p.always_methods.insert(dv);
            } else if kd == 2 {
                p.mark_method_used(d);
            } else if !p.method_used_get(d) {
                let fv = lg.b[k];
                p.record_method_edge(DefId { module: (fv >> 32) as ModuleId, node: (fv & 0xFFFFFFFFu64) as NodeId }, d);
            }
        }
    }
    for i in 0..n {
        let de = douts.index_mut(i);
        if de.errors.len() != 0 {
            de.log();
            ok = false;
        }
    }
    return ok;
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
        // Kind-3 fixes index into the caller's shared fix_texts pool: rebase and copy the payloads.
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

// Dev gate (SC_FACTS_CHECK=1): snapshot every module's semantic-table watermarks right after
// type checking, then assert (after borrow checking AND after codegen) that no later stage
// changed a semantic decision table (intern pools excepted; see ast::facts). Off without the env var.
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

// Validation mode (SC_LAYOUT=1): every concrete pool type must satisfy the C layout invariants:
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
                // Opaque/zero-length/unlayoutable shapes are legitimate refusals.
                continue;
            }
            laid += 1;
            let mut ok = l.align != 0 && (l.align & l.align - 1) == 0 && l.size % l.align == 0;
            // Struct fields: aligned, monotone, inside the parent.
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
                        // Zero-size members share offsets and may sit at the very end.
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

// SC_CEMIT_TU=1: the backend's declaration layer over the whole package (every concrete
// aggregate plus every anchored instance from a fresh graph, forward typedefs then dependency-first
// definitions), gated by a strict-C11 syntax-only compile of the emitted scratch TU.

/// One assembled new-backend emission. TU texts carry NO include lines; the writer prepends the
/// layout-relative includes of the two shared headers. `skips` MUST be zero for the output to be
/// complete (every count is an emission the backend refused).
pub struct CemitOut {
    pub types_h: String,
    pub protos_h: String,
    pub tus: Vector<String>,
    pub tu_extra: Vector<Vector<String>>, // parts 1.. of an oversized TU (part 0 stays in tus)
    pub inst_c: String,
    pub inst_extra: Vector<String>,
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

extend CemitOut {
    /// Empty output buffers for a package of `n` modules.
    pub fn new(n: usize) CemitOut {
        let mut o = CemitOut {
            types_h: String::new(),
            protos_h: String::new(),
            tus: Vector::<String>::new(),
            tu_extra: Vector::<Vector<String>>::new(),
            inst_c: String::new(),
            inst_extra: Vector::<String>::new(),
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
            o.tu_extra.push(Vector::<String>::new());
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
        // would not: a non-inlined cross-TU caller then fails to link), and carries the hint.
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
    ia: &mut Vector<Vector<NodeId>>,
    ia_built: &mut Vector<bool>,
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
    // One static_assert scan per module, not per demand: generic bodies are demanded thousands of
    // times and the node array is large, while asserts are rare.
    let dm = d_def.module as usize;
    if !*ia_built.at(dm) {
        ia_built.set(dm, true);
        let lst = ia.index_mut(dm);
        for nid0 in 0..a.nodes.len() {
            if a.at_const(nid0 as NodeId).kind == NodeKind::NODE_STATIC_ASSERT {
                lst.push(nid0 as NodeId);
            }
        }
    }
    if ia.at(dm).len() == 0 {
        seen.insert(dk, 1);
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
    for ni in 0..ia.at(dm).len() {
        let nid = *ia.at(dm).at(ni);
        let n = a.at_const(nid);
        if n.span.start < fsp.start || n.span.end > fsp.end {
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
// (extern aggregates especially: their layout is a CLAIM about a C header) checked against the
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
                    // Tagless enums have no modelled layout claim.
                    continue;
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
            // Demand-driven emission: only aggregates the plan DEFINED can be sized.
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

// Take the graph's cached lowering of `(m, nid)` into `lw_out` (the graph lowered every body it
// walked exactly once), lowering in place only when the cache has no live entry. A taken slot is
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

// Replay one cached module: pool interns first (verified id by id), then the journaled events
// through the emitter's live dedup gates. 0 = replayed, 1 = clean reject (nothing landed; emit
// live and re-record), 2 = dirty reject (side effects landed; void the section, skip recording).
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
    let mut rd = t.open(m);
    let mut tab = Vector::<tuc::TtEnt>::new();
    if !rd.read_table(&mut tab) {
        // Nothing mutated yet: emit live and re-record.
        return 1;
    }
    let mut idc = Map::<u64, u64>::new();
    let nev = rd.r32() as usize; // the event count follows the type table
    let mut ev = mbe::RecEv::blank(0);
    for _i in 0..nev {
        if !rd.read_ev(&mut ev) {
            return 2;
        }
        tuc::ev_patch(p, &tab, &mut idc, &mut ev);
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

// A destructive take from the shared keep, serialized when the frontier hands out `kl`.
fn cemit_seed_take(
    g: &mut ig::InstGraph,
    p: &mut loader::Package,
    m: ModuleId,
    nid: NodeId,
    lw: &mut irl::Lowerer,
    kl: *const psync::Semaphore,
    closure: bool,
) bool {
    if kl != null {
        (unsafe &*kl).acquire_masked();
    }
    let r = if closure {
        cemit_take_closure(&mut *g, p, m, nid, lw);
    } else {
        cemit_take_body(&mut *g, p, m, nid, lw);
    };
    if kl != null {
        (unsafe &*kl).release();
    }
    return r;
}

// One module's seed emission: candidates, bodies, free-glue wrappers, and the transitive closure
// worklist, shared by the serial loop (tuc journaling hooks stay live through mg.rec_on) and
// the parallel frontier (per-task CEmit shards; rec_on stays false there). `kl` (null =
// uncontended) serializes the destructive takes from the shared InstGraph keep.
fn cemit_seed_module(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    cl_cache: &mut Map<u64, u64>,
    clws: &mut Vector<irl::Lowerer>,
    m: usize,
    testing: bool,
    verbose: bool,
    kl: *const psync::Semaphore,
    bodies_all: &mut String,
    protos: &mut String,
    chunk_mod: &mut Vector<u64>,
    chunk_off: &mut Vector<u64>,
    env_names: &mut Vector<u64>,
    env_bodies: &mut Vector<String>,
    have_main: &mut bool,
    main_mod: &mut u64,
    main_argv: &mut bool,
    seeds: &mut u64,
    seed_skip: &mut u64,
    clos_ok: &mut u64,
    clos_skip: &mut u64,
) {
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
            // Test-family items exist only under --test.
            continue;
        }
        if cem.mg.in_generic_extend(m as ModuleId, nid) {
            // Its instances are demand-emitted; leave the cached body for them.
            continue;
        }
        let mut lw = irl::Lowerer::new(p, m as ModuleId, nid);
        if !cemit_seed_take(g, p, m as ModuleId, nid, &mut lw, kl, false) {
            continue;
        }
        if lw.body.is_generic {
            continue;
        }
        dow.apply_drops(&mut lw);
        let mut sym = String::new();
        let tgt = cem.mg.method_target(m as ModuleId, nid);
        if !cem.mg.fn_sym(m as ModuleId, nid, tgt, true, &mut sym) {
            continue;
        }
        if sym.as_str() == "assert" || sym.as_str() == "assert_eq" || sym.as_str() == "assert_ne" {
            // Desugared builtins; the C names collide with <assert.h>'s macro.
            continue;
        }
        cem.out.clear();
        let is_main = sym.as_str() == "main";
        if is_main {
            sym.truncate(0);
            // The argv wrapper below owns the C `main`.
            sym.push_str("__sc_user_main");
        }
        let mut gfs = Vector::<String>::new();
        let mut gts = Vector::<TypeId>::new();
        let is_glue = cemit_free_glue_fields(p, cem, m as ModuleId, nid, &mut gfs, &mut gts);
        if is_glue {
            sym.push_str("__fb");
        }
        cem.noret = cemit_is_noreturn(a, nid);
        cem.fn_attrs.truncate(0);
        cemit_fn_attrs(p, m as ModuleId, nid, &mut cem.fn_attrs);
        if cem.emit_fn(&lw.body, sym.as_str()) {
            *seeds += 1;
            if is_main {
                *have_main = true;
                *main_mod = m as u64;
                *main_argv = n.as_data.function.params.len != 0;
                if cem.mg.rec_on {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_MAIN);
                    ev9.a = if *main_argv {
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
                proto_of(&cem.out, protos);
                bodies_all.push_string(&cem.out);
                if cem.mg.rec_on {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_CHUNK);
                    ev9.a = chunk_off[chunk_off.len() - 1] as u32;
                    ev9.b = bodies_all.len() as u32;
                    cem.mg.rec.push(ev9);
                }
            }
            if is_glue {
                // The public wrapper: the sig is the __fb sig without the suffix.
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
                // emitter for its C spelling; it may preserve the source name (`self`) over `_N`.
                let mut selfp = String::new();
                cem.lspell(lw.body.returns, &mut selfp);
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
                            // The field has no C member: its destructor runs on the sentinel.
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
                    proto_of(&wr, protos);
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
                        if cemit_seed_take(g, p, m as ModuleId, cn, &mut cl, kl, true) {
                            dow.apply_drops(&mut cl);
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
                        // Closures nest: emit the inner ones too.
                        clsq.push(clws.at(ci as usize).closures[x2]);
                    }
                }
                if cok && cem.emit_closure(&clws.at(ci as usize).body, m as ModuleId, cn, csym.as_str(), &mut envs) {
                    *clos_ok += 1;
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
                    proto_of(&cem.out, protos);
                    bodies_all.push_string(&cem.out);
                    if cem.mg.rec_on {
                        let mut ev9 = mbe::RecEv::blank(mbe::RK_CHUNK);
                        ev9.a = chunk_off[chunk_off.len() - 1] as u32;
                        ev9.b = bodies_all.len() as u32;
                        cem.mg.rec.push(ev9);
                    }
                } else {
                    *clos_skip += 1;
                }
            }
        } else {
            *seed_skip += 1;
            if verbose {
                eprint("seed-emit-fail: `{}` {}\n", sym.as_str(), cem.err);
            }
        }
    }
}

struct SeedShard {
    pub cem: cbe::CEmit,
    pub bodies: String,
    pub protos: String,
    pub chunk_mod: Vector<u64>,
    pub chunk_off: Vector<u64>,
    pub env_names: Vector<u64>,
    pub env_bodies: Vector<String>,
    pub have_main: bool,
    pub main_mod: u64,
    pub main_argv: bool,
    pub seeds: u64,
    pub seed_skip: u64,
    pub clos_ok: u64,
    pub clos_skip: u64,
    pub used: bool,
    // Drain-slice state: one shard per SLICE of a wave in the parallel instance frontier;
    // per-demand capture marks let the merge replay each demand's claims at its exact queue slot.
    pub dmarks: Vector<CapMark>,
    pub douts: Vector<u8>, // per demand: 0 = emitted, 1 = lowering-path skip, 2 = emit failure
    pub derrs: Vector<str<'static>>,
    pub dvix: Vector<u64>, // per demand: index into dvars (0xFF.. = none)
    pub dvkeys: Vector<u64>, // per dvars entry: the zst-signature cache key
    pub dvars: Vector<irl::Lowerer>,
    pub dclo_keys: Vector<u64>, // closure lowerings this slice produced on a shared-cache miss
    pub dclo: Vector<irl::Lowerer>,
}

// Counts of a drain shard's capture rows and sink sizes at one demand boundary; every row carries
// its absolute text end, so counts alone define a replayable range.
struct CapMark {
    pub env: u32,
    pub stat: u32,
    pub statv: u32,
    pub glue: u32,
    pub gluev: u32,
    pub ext: u32,
    pub dyd: u32,
    pub dyt: u32,
    pub blk: u32,
    pub sent: u32,
    pub ti: u32,
    pub tiv: u32,
    pub aux: u32,
    pub dem: u32,
    pub agg: u32,
    pub dynr: u32,
    pub chunks: u32,
    pub bodies: u64,
    pub protos: u64,
    pub envn: u32,
    pub dclo: u32,
}

const fn cap_zero() CapMark {
    return CapMark {
        env: 0,
        stat: 0,
        statv: 0,
        glue: 0,
        gluev: 0,
        ext: 0,
        dyd: 0,
        dyt: 0,
        blk: 0,
        sent: 0,
        ti: 0,
        tiv: 0,
        aux: 0,
        dem: 0,
        agg: 0,
        dynr: 0,
        chunks: 0,
        bodies: 0,
        protos: 0,
        envn: 0,
        dclo: 0,
    };
}

extend SeedShard {
    const fn cap_of(self: &Self) CapMark {
        let sc = &self.cem;
        return CapMark {
            env: sc.sh_env_k.len() as u32,
            stat: sc.sh_stat_k.len() as u32,
            statv: sc.stat_items.len() as u32,
            glue: sc.sh_glue_k.len() as u32,
            gluev: sc.glue.len() as u32,
            ext: sc.sh_ext_k.len() as u32,
            dyd: sc.sh_dyd_k.len() as u32,
            dyt: sc.sh_dyt_k.len() as u32,
            blk: sc.sh_blk_k.len() as u32,
            sent: sc.sh_sent_k.len() as u32,
            ti: sc.sh_ti_k.len() as u32,
            tiv: sc.ti_reqs.len() as u32,
            aux: sc.sh_aux_k.len() as u32,
            dem: sc.demand.len() as u32,
            agg: sc.mg.sh_agg_k.len() as u32,
            dynr: sc.mg.dyn_reqs.len() as u32,
            chunks: self.chunk_mod.len() as u32,
            bodies: self.bodies.len() as u64,
            protos: self.protos.len() as u64,
            envn: self.env_names.len() as u32,
            dclo: self.dclo_keys.len() as u32,
        };
    }
}

struct SeedTask {
    pub p: *mut loader::Package,
    pub ctl: *const tctl::Ctl,
    pub est: u64,
    /// The graph and shard, OPAQUE on purpose: the payload transitively holds `str` fields, and the
    /// bootstrap compiler's carries-borrow walk peels typed pointers (fixed in this tree, but the
    /// release binary must still build this source).
    pub g: *mut void,
    pub out: *mut void,
    pub m: usize,
    pub testing: bool,
    pub verbose: bool,
    pub kl: *const psync::Semaphore,
}

unsafe extend SeedTask as Send {}

fn cemit_seed_task(t: SeedTask) {
    let mut dow = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let o = unsafe &mut *(t.out as *mut SeedShard);
    let g9 = t.g as *mut ig::InstGraph;
    let mut cl_cache = Map::<u64, u64>::new();
    let mut clws = Vector::<irl::Lowerer>::new();
    cemit_seed_module(
        p,
        &mut o.cem,
        unsafe &mut *g9,
        &mut dow,
        &mut cl_cache,
        &mut clws,
        t.m,
        t.testing,
        t.verbose,
        t.kl,
        &mut o.bodies,
        &mut o.protos,
        &mut o.chunk_mod,
        &mut o.chunk_off,
        &mut o.env_names,
        &mut o.env_bodies,
        &mut o.have_main,
        &mut o.main_mod,
        &mut o.main_argv,
        &mut o.seeds,
        &mut o.seed_skip,
        &mut o.clos_ok,
        &mut o.clos_skip,
    );
    if t.ctl != null {
        (unsafe &*t.ctl).release(t.est);
    }
    dctx_put(dow);
}

// Apply one shard's gated first-claimant emissions into the master emitter, in module order: the
// first module-order claimant of each key wins, exactly as the serial loop's shared seen-sets
// decided. Buffer segments are [previous end, end) of the shard's own (initially empty) buffers.
fn cemit_drain_demand(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    lw_cache: &mut Map<u64, u64>,
    lws: &mut Vector<irl::Lowerer>,
    cl_cache: &mut Map<u64, u64>,
    clws: &mut Vector<irl::Lowerer>,
    cfs: &mut Vector<cfl::CFlow>,
    cf_ok: &mut Vector<bool>,
    done: &mut Map<u64, u64>,
    sa_seen: &mut Map<u64, u64>,
    ia_idx: &mut Vector<Vector<NodeId>>,
    ia_built: &mut Vector<bool>,
    di: usize,
    verbose: bool,
    bodies_all: &mut String,
    protos: &mut String,
    chunk_mod: &mut Vector<u64>,
    chunk_off: &mut Vector<u64>,
    env_names: &mut Vector<u64>,
    env_bodies: &mut Vector<String>,
    inst_ok: &mut u64,
    inst_skip: &mut u64,
    clos_ok: &mut u64,
    clos_skip: &mut u64,
    reasons: &mut Vector<str<'static>>,
    rcounts: &mut Vector<u64>,
) {
    let d_def = cem.demand.at(di).def;
    let ds = cem.demand.at(di).sym.as_str();
    let mut dk = 1469598103934665603u64;
    for k in 0..ds.len() {
        dk = (dk ^ ds.byte_at(k) as u64) * 1099511628211u64;
    }
    // Dedup on SUCCESS only: two demands for one symbol can carry different substitution
    // chains, and the first may be the incomplete one; a later, fuller chain must retry.
    let seen = switch done.get(&dk) {
        Some(_v) => true,
        None => false,
    };
    if seen {
        return;
    }
    let d_sym = cem.demand.at(di).sym.clone();
    let mut d_subs = Vector::<mbe::MSub>::new();
    for i2 in 0..cem.demand.at(di).subs.len() {
        d_subs.push(*cem.demand.at(di).subs.at(i2));
    }
    let key = skey_mix(0, d_def.module as u64 << 32 | d_def.node as u64);
    let li = switch lw_cache.get(&key) {
        Some(v) => *v,
        None => {
            let mut lw = irl::Lowerer::new(p, d_def.module, d_def.node);
            let okl = cemit_take_body(&mut *g, p, d_def.module, d_def.node, &mut lw);
            let mut slot = 0xFFFFFFFFFFFFFFFFu64;
            if okl {
                dow.apply_drops(&mut lw);
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
        *inst_skip += 1;
        return;
    }
    let d_sfx = cem.demand.at(di).sfx.clone();
    // Per-instantiation static_asserts: under this demand's substitution the condition is
    // this instance's compile-time fact; false is a COMPILE error naming the type argument.
    cemit_inst_asserts(p, d_def, &d_subs, dk, sa_seen, ia_idx, ia_built);
    // A body with an UNEXPANDED reflection binder re-lowers per instance: the demand env
    // makes the binder's owner concrete, so the copies expand for real. A body whose only
    // env-dependence is `sizeof(T) <op> 0` branches re-lowers once per ZST-BIT SIGNATURE of
    // its args; every material instantiation folds identically and shares one body.
    let mut li2 = li;
    if lws.at(li as usize).body.has_reflect {
        let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
        for i2 in 0..d_subs.len() {
            let sb2 = *d_subs.at(i2);
            lw2.env.push(irl::LSub { pm: sb2.pm, pnode: sb2.pnode, am: sb2.am, at: sb2.at });
        }
        if lw2.lower_fn(d_def.node) {
            dow.apply_drops(&mut lw2);
            lws.push(lw2);
            li2 = lws.len() as u64 - 1;
        } else {
            if verbose {
                eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
            }
            *inst_skip += 1;
            return;
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
                    dow.apply_drops(&mut lw2);
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
            *inst_skip += 1;
            return;
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
        // Every lws slot gets a cached CFlow: shared zst-signature bodies and reflect
        // re-lowers alike (a per-slot build amortizes across their instantiations).
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
        *inst_ok += 1;
        chunk_mod.push(65534);
        chunk_off.push(bodies_all.len() as u64);
        proto_of(&cem.out, protos);
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
                    if cemit_take_closure(&mut *g, p, d_def.module, cn, &mut cl) {
                        dow.apply_drops(&mut cl);
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
                    // Closures nest: emit the inner ones too.
                    clsq.push(clws.at(ci as usize).closures[x2]);
                }
            }
            if cok && cem.emit_closure(&clws.at(ci as usize).body, d_def.module, cn, csym.as_str(), &mut envs) {
                *clos_ok += 1;
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
                proto_of(&cem.out, protos);
                bodies_all.push_string(&cem.out);
            } else {
                *clos_skip += 1;
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
    cem.mg.subs.truncate(0);
    cem.mg.clos_sfx.truncate(0);
    cem.mg.clos_ids.truncate(0);
}

// One demanded instance emitted into a private shard by the parallel instance frontier. Shared
// caches are READ-ONLY during a wave (the master mutates them only at merge); pointers are opaque
// where the payload transitively reaches `str` (the release bootstrap's carries-borrow walk).
struct DrainTask {
    pub p: *mut loader::Package,
    pub g: *mut void, // InstGraph
    pub out: *mut void, // SeedShard
    pub dem: *const void, // Vector<cbe::Demand>: frozen during the wave
    pub lws: *const void, // Vector<irl::Lowerer>: frozen during the wave
    pub cfs: *const void, // Vector<cfl::CFlow>: frozen during the wave
    pub lwc: *const void, // lw_cache: frozen during the wave
    pub clc: *const void, // cl_cache: frozen during the wave
    pub clw: *const void, // clws: frozen during the wave
    pub widx: *const u64, // tasked demand indices, ascending
    pub wli: *const u64, // their base lowering slots
    pub lo: u64, // this slice: widx[lo..hi)
    pub hi: u64,
    pub kl: *const psync::Semaphore,
    pub verbose: bool,
}

unsafe extend DrainTask as Send {}

fn cemit_drain_task(t: DrainTask) {
    // One drop/inline context for the whole task: the inliner's vetted-callee cache is the
    // expensive part (each miss lowers and copies the callee); per-demand contexts rebuilt it
    // from nothing.
    let mut dow = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let o = unsafe &mut *(t.out as *mut SeedShard);
    let dem = unsafe &*(t.dem as *const Vector<cbe::Demand>);
    let lws = unsafe &*(t.lws as *const Vector<irl::Lowerer>);
    let cfs = unsafe &*(t.cfs as *const Vector<cfl::CFlow>);
    let lwc = unsafe &*(t.lwc as *const Map<u64, u64>);
    let clc = unsafe &*(t.clc as *const Map<u64, u64>);
    let clws0 = unsafe &*(t.clw as *const Vector<irl::Lowerer>);
    for w in t.lo..t.hi {
        let di = (unsafe t.widx[w as usize]) as usize;
        let li = unsafe t.wli[w as usize];
        cemit_drain_slice_one(p, t.g, o, dem, lws, cfs, lwc, clc, clws0, di, li, t.kl, t.verbose, &mut dow);
        o.dmarks.push(o.cap_of());
    }
    dctx_put(dow);
}

fn cemit_drain_slice_one(
    p: &mut loader::Package,
    gv: *mut void,
    o: &mut SeedShard,
    dem: &Vector<cbe::Demand>,
    lws: &Vector<irl::Lowerer>,
    cfs: &Vector<cfl::CFlow>,
    lwc: &Map<u64, u64>,
    clc: &Map<u64, u64>,
    clws0: &Vector<irl::Lowerer>,
    di: usize,
    li: u64,
    kl: *const psync::Semaphore,
    verbose: bool,
    dow2: &mut DropCtx,
) {
    let d_def = dem.at(di).def;
    let d_sym = dem.at(di).sym.clone();
    let mut d_subs = Vector::<mbe::MSub>::new();
    for i2 in 0..dem.at(di).subs.len() {
        d_subs.push(*dem.at(di).subs.at(i2));
    }
    let d_sfx = dem.at(di).sfx.clone();
    let mut var_on = false;
    let mut var_zkey: u64 = 0;
    let mut var_lw = irl::Lowerer::new(p, 0, NODE_NONE);
    let mut li2 = li;
    let mut cfp: *const cfl::CFlow = null;
    let mut cf_own = cfl::CFlow::new_empty();
    if lws.at(li as usize).body.has_reflect {
        let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
        for i2 in 0..d_subs.len() {
            let sb2 = *d_subs.at(i2);
            lw2.env.push(irl::LSub { pm: sb2.pm, pnode: sb2.pnode, am: sb2.am, at: sb2.at });
        }
        if lw2.lower_fn(d_def.node) {
            dow2.apply_drops(&mut lw2);
            var_on = true;
            var_lw = lw2;
        } else {
            if verbose {
                eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
            }
            o.douts.push(1);
            o.derrs.push("");
            o.dvix.push(0xFFFFFFFFFFFFFFFFu64);
            return;
        }
    } else if lws.at(li as usize).body.has_zst_cond {
        let sh0 = &mut o.cem;
        let mut zb: u64 = 1;
        for i2 in 0..d_subs.len() {
            let sb2 = *d_subs.at(i2);
            zb = zb << 1 | if sh0.mg.is_zst(sb2.am, sb2.at) {
                1u64;
            } else {
                0 as u64;
            };
        }
        let zkey = skey_mix(zb, d_def.module as u64 << 32 | d_def.node as u64);
        let zi = switch lwc.get(&zkey) {
            Some(v) => *v,
            None => 0xFFFFFFFFFFFFFFFEu64,
        };
        if zi == 0xFFFFFFFFFFFFFFFFu64 {
            o.douts.push(1);
            o.derrs.push("");
            o.dvix.push(0xFFFFFFFFFFFFFFFFu64);
            return;
        }
        if zi != 0xFFFFFFFFFFFFFFFEu64 {
            li2 = zi;
        } else {
            // A slice-local earlier demand may have lowered this signature already.
            let mut own9 = 0xFFFFFFFFFFFFFFFFu64;
            for k2 in 0..o.dvkeys.len() {
                if o.dvkeys[k2] == zkey {
                    own9 = k2 as u64;
                    break;
                }
            }
            if own9 != 0xFFFFFFFFFFFFFFFFu64 {
                var_on = true;
                var_zkey = zkey;
                li2 = 0xFFFFFFFFFFFFFFFFu64;
                o.dvix.push(own9);
            } else {
                let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
                for i2 in 0..d_subs.len() {
                    let sb2 = *d_subs.at(i2);
                    lw2.env.push(irl::LSub { pm: sb2.pm, pnode: sb2.pnode, am: sb2.am, at: sb2.at });
                }
                if lw2.lower_fn(d_def.node) {
                    dow2.apply_drops(&mut lw2);
                    var_on = true;
                    var_zkey = zkey;
                    var_lw = lw2;
                } else {
                    if verbose {
                        eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
                    }
                    o.douts.push(1);
                    o.derrs.push("");
                    o.dvix.push(0xFFFFFFFFFFFFFFFFu64);
                    return;
                }
            }
        }
    }
    // Register the variant (if fresh) so the body reference below and later demands can find it.
    let mut vix = 0xFFFFFFFFFFFFFFFFu64;
    if var_on {
        if li2 == 0xFFFFFFFFFFFFFFFFu64 {
            // Slice-local zst reuse: dvix already pushed above.
            for k2 in 0..o.dvkeys.len() {
                if o.dvkeys[k2] == var_zkey {
                    vix = k2 as u64;
                    break;
                }
            }
        } else {
            vix = o.dvars.len() as u64;
            o.dvkeys.push(var_zkey);
            o.dvars.push(var_lw);
        }
    }
    let sh = &mut o.cem;
    sh.mg.subs.truncate(0);
    for i2 in 0..d_subs.len() {
        sh.mg.push_msub(*d_subs.at(i2));
    }
    sh.mg.clos_sfx.truncate(0);
    sh.mg.clos_sfx.push_string(&d_sfx);
    sh.mg.clos_ids.truncate(0);
    {
        let cls = if var_on {
            &o.dvars.at(vix as usize).closures;
        } else {
            &lws.at(li2 as usize).closures;
        };
        for c2 in 0..cls.len() {
            sh.mg.clos_ids.push(cls[c2]);
        }
    }
    if var_on {
        cf_own.build_into(&o.dvars.at(vix as usize).body);
        cfp = &cf_own;
    } else {
        cfp = cfs.at(li2 as usize);
    }
    sh.cf_ext = cfp;
    sh.out.clear();
    sh.fn_attrs.truncate(0);
    cemit_fn_attrs(p, d_def.module, d_def.node, &mut sh.fn_attrs);
    let bodyp = if var_on {
        &o.dvars.at(vix as usize).body;
    } else {
        &lws.at(li2 as usize).body;
    };
    let em_ok9 = sh.emit_fn(bodyp, d_sym.as_str());
    sh.cf_ext = null;
    if !em_ok9 {
        o.douts.push(2);
        o.derrs.push(sh.err);
        if li2 != 0xFFFFFFFFFFFFFFFFu64 || !var_on {
            o.dvix.push(vix);
        }
        return;
    }
    o.douts.push(0);
    o.derrs.push("");
    if li2 != 0xFFFFFFFFFFFFFFFFu64 || !var_on {
        o.dvix.push(vix);
    }
    o.chunk_mod.push(65534);
    o.chunk_off.push(o.bodies.len() as u64);
    proto_of(&sh.out, &mut o.protos);
    o.bodies.push_string(&sh.out);
    let mut clsq = Vector::<NodeId>::new();
    {
        let cls = if var_on {
            &o.dvars.at(vix as usize).closures;
        } else {
            &lws.at(li2 as usize).closures;
        };
        for c2 in 0..cls.len() {
            clsq.push(cls[c2]);
        }
    }
    let mut cqi: usize = 0;
    while cqi < clsq.len() {
        let cn = clsq[cqi];
        cqi += 1;
        let ckey = skey_mix(0, d_def.module as u64 << 32 | cn as u64);
        // Shared cache first (frozen), then this slice's own lowerings, then a fresh take.
        let mut shared_ci = switch clc.get(&ckey) {
            Some(v) => *v,
            None => 0xFFFFFFFFFFFFFFFEu64,
        };
        let mut own_ci = 0xFFFFFFFFFFFFFFFFu64;
        if shared_ci == 0xFFFFFFFFFFFFFFFEu64 {
            let mut known = false;
            for k2 in 0..o.dclo_keys.len() {
                if o.dclo_keys[k2] == ckey {
                    known = true;
                    if o.dclo.at(k2).body.blocks.len() != 0 {
                        own_ci = k2 as u64;
                    }
                    break;
                }
            }
            if !known {
                let mut cl = irl::Lowerer::new(p, d_def.module, cn);
                if cemit_seed_take(unsafe &mut *(gv as *mut ig::InstGraph), p, d_def.module, cn, &mut cl, kl, true) {
                    dow2.apply_drops(&mut cl);
                    own_ci = o.dclo.len() as u64;
                    o.dclo_keys.push(ckey);
                    o.dclo.push(cl);
                } else {
                    // Remembered as failed: an empty-body placeholder maps to -1 at merge.
                    o.dclo_keys.push(ckey);
                    o.dclo.push(irl::Lowerer::new(p, d_def.module, cn));
                }
            }
            shared_ci = 0xFFFFFFFFFFFFFFFFu64;
        }
        let cok = shared_ci < 0xFFFFFFFFFFFFFFFEu64 || own_ci != 0xFFFFFFFFFFFFFFFFu64;
        let clp: *const irl::Lowerer = if shared_ci < 0xFFFFFFFFFFFFFFFEu64 {
            clws0.at(shared_ci as usize);
        } else if own_ci != 0xFFFFFFFFFFFFFFFFu64 {
            o.dclo.at(own_ci as usize);
        } else {
            null;
        };
        let mut csym = String::new();
        sh.mg.closure_sym(d_def.module, cn, &mut csym);
        let mut envs = String::new();
        sh.out.clear();
        if cok {
            let cls2 = unsafe &(&*clp).closures;
            for x2 in 0..cls2.len() {
                // Closures nest: emit the inner ones too.
                clsq.push(cls2[x2]);
            }
        }
        if cok && sh.emit_closure(unsafe &(&*clp).body, d_def.module, cn, csym.as_str(), &mut envs) {
            o.clos_ok += 1;
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
                o.env_names.push(eh9);
                o.env_bodies.push(envs.clone());
            }
            o.chunk_mod.push(65534);
            o.chunk_off.push(o.bodies.len() as u64);
            proto_of(&sh.out, &mut o.protos);
            o.bodies.push_string(&sh.out);
        } else {
            o.clos_skip += 1;
        }
    }
    sh.mg.subs.truncate(0);
    sh.mg.clos_sfx.truncate(0);
    sh.mg.clos_ids.truncate(0);
}

// One slice of a wave's unique base-definition lowerings; results land in disjoint slots.
struct LowTask {
    pub p: *mut loader::Package,
    pub g: *mut void, // InstGraph
    pub defs: *const u64, // packed module << 32 | node
    pub res: *mut void, // irl::Lowerer slot base (disjoint writes per index)
    pub cfr: *mut void, // cfl::CFlow slot base
    pub oks: *mut bool,
    pub lo: u64,
    pub hi: u64,
    pub kl: *const psync::Semaphore,
}

unsafe extend LowTask as Send {}

fn cemit_low_task(t: LowTask) {
    let mut dow2 = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let res = t.res as *mut irl::Lowerer;
    let cfr = t.cfr as *mut cfl::CFlow;
    for i in t.lo..t.hi {
        let dv = unsafe t.defs[i as usize];
        let m = (dv >> 32) as ModuleId;
        let n = (dv & 0xFFFFFFFFu64) as NodeId;
        let mut lw = irl::Lowerer::new(p, m, n);
        let ok = cemit_seed_take(unsafe &mut *(t.g as *mut ig::InstGraph), p, m, n, &mut lw, t.kl, false);
        if ok {
            dow2.apply_drops(&mut lw);
            let mut cf = cfl::CFlow::new_empty();
            cf.build_into(&lw.body);
            let rp = unsafe &mut *(res + i as usize);
            *rp = lw;
            let cp = unsafe &mut *(cfr + i as usize);
            *cp = cf;
        }
        unsafe t.oks[i as usize] = ok;
    }
    dctx_put(dow2);
}

// The raw casts these launchers take live only for the call: the checker retains a laundered
// borrow for the enclosing function, so the casts must not share a body with the merge's writers.
fn cemit_low_launch(
    p: &mut loader::Package,
    g: &mut ig::InstGraph,
    kl9: &mut psync::Semaphore,
    defs: &Vector<u64>,
    res: &mut Vector<irl::Lowerer>,
    cfr: &mut Vector<cfl::CFlow>,
    oks: &mut Vector<bool>,
    jobs: u32,
) {
    let nd = defs.len();
    let mut nsl: usize = 1;
    if jobs >= 2 && nd > 1 {
        nsl = if nd < jobs as usize {
            nd;
        } else {
            jobs as usize;
        };
    }
    let wgl = psync::WaitGroup::new();
    let resb = (res.index_mut(0) as *mut irl::Lowerer) as *mut void;
    let cfrb = (cfr.index_mut(0) as *mut cfl::CFlow) as *mut void;
    let oksb = oks.index_mut(0) as *mut bool;
    let defb = defs.as_ptr();
    let ppd = p as *mut loader::Package;
    let ggd = (g as *mut ig::InstGraph) as *mut void;
    let klp9 = (kl9 as *mut psync::Semaphore) as *const psync::Semaphore;
    for sI in 0..nsl {
        let lo9 = nd * sI / nsl;
        let hi9 = nd * (sI + 1) / nsl;
        if lo9 == hi9 {
            continue;
        }
        wgl.add(1);
        let tl = LowTask {
            p: ppd,
            g: ggd,
            defs: defb,
            res: resb,
            cfr: cfrb,
            oks: oksb,
            lo: lo9 as u64,
            hi: hi9 as u64,
            kl: klp9,
        };
        let wgc = wgl.clone();
        launch || {
            cemit_low_task(tl);
            wgc.done();
        };
    }
    wgl.wait_masked();
}

fn cemit_drain_launch(
    p: &mut loader::Package,
    g: &mut ig::InstGraph,
    kl9: &mut psync::Semaphore,
    cem: &mut cbe::CEmit,
    lws: &Vector<irl::Lowerer>,
    cfs: &Vector<cfl::CFlow>,
    lw_cache: &Map<u64, u64>,
    cl_cache: &Map<u64, u64>,
    clws: &Vector<irl::Lowerer>,
    dsh: &mut Vector<SeedShard>,
    sbounds: &Vector<u64>, // per slice: exclusive end index into widx
    widx: &Vector<u64>,
    wli: &Vector<u64>,
    verbose: bool,
) {
    let wgd = psync::WaitGroup::new();
    let ppd = p as *mut loader::Package;
    let ggd = (g as *mut ig::InstGraph) as *mut void;
    let klp9 = (kl9 as *mut psync::Semaphore) as *const psync::Semaphore;
    let demp = ((&cem.demand) as *const Vector<cbe::Demand>) as *const void;
    let lwsp = (lws as *const Vector<irl::Lowerer>) as *const void;
    let cfsp = (cfs as *const Vector<cfl::CFlow>) as *const void;
    let lwcp = (lw_cache as *const Map<u64, u64>) as *const void;
    let clcp = (cl_cache as *const Map<u64, u64>) as *const void;
    let clwp = (clws as *const Vector<irl::Lowerer>) as *const void;
    let wip = widx.as_ptr();
    let wlp = wli.as_ptr();
    let mut lo9: u64 = 0;
    for i in 0..dsh.len() {
        let hi9 = *sbounds.at(i);
        if lo9 == hi9 {
            continue;
        }
        wgd.add(1);
        let td = DrainTask {
            p: ppd,
            g: ggd,
            out: dsh.index_mut(i),
            dem: demp,
            lws: lwsp,
            cfs: cfsp,
            lwc: lwcp,
            clc: clcp,
            clw: clwp,
            widx: wip,
            wli: wlp,
            lo: lo9,
            hi: hi9,
            kl: klp9,
            verbose: verbose,
        };
        let wgc = wgd.clone();
        launch || {
            cemit_drain_task(td);
            wgc.done();
        };
        lo9 = hi9;
    }
    wgd.wait_masked();
}

fn cemit_seed_merge_um(cem: &mut cbe::CEmit, o: &mut SeedShard) {
    cem.mg.sh_merge_um(&mut o.cem.mg, 65534);
}

fn cemit_seed_merge(cem: &mut cbe::CEmit, o: &mut SeedShard, m: u64) {
    let a = cap_zero();
    let b = o.cap_of();
    cemit_seed_merge_range(cem, o, &a, &b);
    cem.mg.sh_merge_um(&mut o.cem.mg, m);
}

// The end offset of row range [0..a) in a single-kind text buffer.
const fn cap_pe(rows: &Vector<u32>, a: u32) u32 {
    if a == 0 {
        return 0;
    }
    return rows[a as usize - 1];
}

fn cemit_seed_merge_range(cem: &mut cbe::CEmit, o: &mut SeedShard, a: &CapMark, b: &CapMark) {
    let sc = &mut o.cem;
    let mut pe = cap_pe(&sc.sh_env_e, a.env);
    for i in a.env as usize..b.env as usize {
        let k = sc.sh_env_k[i];
        let e = sc.sh_env_e[i];
        if !cem.env_skip.contains_key(&k) {
            cem.env_skip.insert(k, 1);
            cem.env_hashes.push(k);
            cem.env_fwd.push_str(sc.env_fwd.as_str().slice(pe as usize, e as usize));
        }
        pe = e;
    }
    pe = cap_pe(&sc.sh_stat_e, a.stat);
    let mut pv = if a.stat == 0 {
        0u32;
    } else {
        sc.sh_stat_v[a.stat as usize - 1];
    };
    for i in a.stat as usize..b.stat as usize {
        let k = sc.sh_stat_k[i];
        let e = sc.sh_stat_e[i];
        let v = sc.sh_stat_v[i];
        if !cem.stat_seen_has(k) {
            cem.stat_seen_add(k);
            cem.stat_decls.push_str(sc.stat_decls.as_str().slice(pe as usize, e as usize));
            for j in pv..v {
                let sr = replace(
                    sc.stat_items.index_mut(j as usize),
                    cbe::StatRef { em: 0, def: DefId { module: 0, node: NODE_NONE }, sym: String::new(), ty: TYPE_NONE },
                );
                cem.stat_items.push(sr);
            }
        }
        pe = e;
        pv = v;
    }
    pv = if a.glue == 0 {
        0u32;
    } else {
        sc.sh_glue_v[a.glue as usize - 1];
    };
    for i in a.glue as usize..b.glue as usize {
        let k = sc.sh_glue_k[i];
        let v = sc.sh_glue_v[i];
        if !cem.glue_seen_has(k) {
            cem.glue_seen_add(k);
            for j in pv..v {
                let sr = replace(
                    sc.glue.index_mut(j as usize),
                    cbe::StatRef { em: 0, def: DefId { module: 0, node: NODE_NONE }, sym: String::new(), ty: TYPE_NONE },
                );
                cem.glue.push(sr);
                let ge = replace(sc.glue_envs.index_mut(j as usize), cbe::GlueEnv { subs: Vector::<mbe::MSub>::new() });
                cem.glue_envs.push(ge);
            }
        }
        pv = v;
    }
    pe = cap_pe(&sc.sh_ext_e, a.ext);
    for i in a.ext as usize..b.ext as usize {
        let k = sc.sh_ext_k[i];
        let e = sc.sh_ext_e[i];
        if !cem.extern_seen_has(k) {
            cem.extern_seen_add(k);
            cem.extern_protos.push_str(sc.extern_protos.as_str().slice(pe as usize, e as usize));
        }
        pe = e;
    }
    let ext_tail0 = if sc.sh_ext_k.len() == 0 {
        0u32;
    } else {
        sc.sh_ext_e[sc.sh_ext_k.len() - 1];
    };
    pe = cap_pe(&sc.sh_dyd_e, a.dyd);
    for i in a.dyd as usize..b.dyd as usize {
        let k = sc.sh_dyd_k[i];
        let e = sc.sh_dyd_e[i];
        if !cem.dyn_def_seen_has(k) {
            cem.dyn_def_seen_add(k);
            cem.dyn_defs.push_str(sc.dyn_defs.as_str().slice(pe as usize, e as usize));
        }
        pe = e;
    }
    pe = cap_pe(&sc.sh_dyt_e, a.dyt);
    let mut pe2 = cap_pe(&sc.sh_dyt_e2, a.dyt);
    for i in a.dyt as usize..b.dyt as usize {
        let k = sc.sh_dyt_k[i];
        let e = sc.sh_dyt_e[i];
        let e2 = sc.sh_dyt_e2[i];
        if !cem.dyn_tab_seen_has(k) {
            cem.dyn_tab_seen_add(k);
            cem.dyn_tabs.push_str(sc.dyn_tabs.as_str().slice(pe as usize, e as usize));
            cem.dyn_decls.push_str(sc.dyn_decls.as_str().slice(pe2 as usize, e2 as usize));
        }
        pe = e;
        pe2 = e2;
    }
    pe = cap_pe(&sc.sh_blk_e, a.blk);
    pe2 = if a.blk == 0 {
        ext_tail0;
    } else {
        sc.sh_blk_e2[a.blk as usize - 1];
    };
    for i in a.blk as usize..b.blk as usize {
        let k = sc.sh_blk_k[i];
        let e = sc.sh_blk_e[i];
        let e2 = sc.sh_blk_e2[i];
        if !cem.blk_seen.contains_key(&k) {
            cem.blk_seen.insert(k, 1);
            if cem.blk_defs.len() == 0 {
                cem.blk_defs.push_str("void __sc_blocking_run(void (*__r)(void *), void *__e);\n");
            }
            cem.blk_defs.push_str(sc.blk_defs.as_str().slice(pe as usize, e as usize));
            cem.extern_protos.push_str(sc.extern_protos.as_str().slice(pe2 as usize, e2 as usize));
        }
        pe = e;
        pe2 = e2;
    }
    pe = cap_pe(&sc.sh_sent_e, a.sent);
    pe2 = cap_pe(&sc.sh_sent_e2, a.sent);
    for i in a.sent as usize..b.sent as usize {
        let k = sc.sh_sent_k[i];
        let e = sc.sh_sent_e[i];
        let e2 = sc.sh_sent_e2[i];
        if !cem.sent_seen_has(k) {
            cem.sent_seen_add(k);
            cem.sent_decls.push_str(sc.sent_decls.as_str().slice(pe as usize, e as usize));
            cem.sent_defs.push_str(sc.sent_defs.as_str().slice(pe2 as usize, e2 as usize));
        }
        pe = e;
        pe2 = e2;
    }
    pv = if a.ti == 0 {
        0u32;
    } else {
        sc.sh_ti_v[a.ti as usize - 1];
    };
    for i in a.ti as usize..b.ti as usize {
        let k = sc.sh_ti_k[i];
        let v = sc.sh_ti_v[i];
        if !cem.ti_seen_has(k) {
            cem.ti_seen_add(k);
            for j in pv..v {
                let sr = replace(
                    sc.ti_reqs.index_mut(j as usize),
                    cbe::StatRef { em: 0, def: DefId { module: 0, node: NODE_NONE }, sym: String::new(), ty: TYPE_NONE },
                );
                cem.ti_reqs.push(sr);
            }
        }
        pv = v;
    }
    pe = cap_pe(&sc.sh_aux_e, a.aux);
    for i in a.aux as usize..b.aux as usize {
        let k = sc.sh_aux_k[i];
        let e = sc.sh_aux_e[i];
        if k == 0 {
            cem.aux.push_str(sc.aux.as_str().slice(pe as usize, e as usize));
        } else {
            let bit = (k >> 1) as u8;
            if cem.assert_helpers_claim(bit) {
                cem.aux.push_str(sc.aux.as_str().slice(pe as usize, e as usize));
            }
        }
        pe = e;
    }
    for i in a.dem as usize..b.dem as usize {
        let dk = sc.demand.at(i).dk;
        if dk != 0 {
            if cem.demand_seen_has(dk) {
                continue;
            }
            cem.demand_seen_add(dk);
        }
        let d = replace(
            sc.demand.index_mut(i),
            cbe::Demand {
                def: DefId { module: 0, node: NODE_NONE },
                sym: String::new(),
                dk: 0,
                subs: Vector::<mbe::MSub>::new(),
                sfx: String::new(),
            },
        );
        cem.demand.push(d);
    }
    cem.mg.sh_merge_range(&mut sc.mg, a.agg as usize, b.agg as usize, a.dynr as usize, b.dynr as usize);
}

/// Emit the whole package through the streaming backend into `o`: the instance graph, every TU's
/// declarations and bodies, the shared instance TU, the test runner when `testing`, and the
/// per-module TU-cache sections. `live` (per module) and `target` select what is emitted;
/// `irkeep` (null = discard) supplies the borrow checker's kept lowerings.
pub fn cemit_package(
    p: &mut loader::Package,
    testing: bool,
    tplan: &TestPlan,
    live: *const bool,
    target: i32,
    o: &mut CemitOut,
    irkeep: *mut irl::Keep,
) {
    let verbose = stdlib::getenv("SC_CEMIT_STATS") != null;
    let tstat = stdlib::getenv("SC_CEMIT_STATS") != null;
    let mut tt0 = unsafe shim::sc_ticks_ms();
    // The planner's signature-level propagation reads the package metadata.
    p.ensure_sigs();
    let mut g = ig::InstGraph::new(p, irkeep, live);
    g.collect();
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage collect: {} ms\n", t9 - tt0);
        tt0 = t9;
    }
    let mut em = tbe::TuEmit::new(p);
    em.mg.agg_on = true;
    let mut items = Vector::<tbe::AggItem>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || live != null && p.modules[m].prelude && !unsafe live[m] {
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
    // Dyn typedef blocks splice in AFTER these forward typedefs and BEFORE the definitions:
    // vtable signatures may name aggregates (fn-pointer params need only the typedef), and
    // aggregates may embed fat values (which need the complete dyn struct).
    let fwd_end = em.out.len();
    for i in 0..items.len() {
        let it = *items.at(i);
        let _ = em.emit_agg(&it);
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage collect+aggs: {} ms\n", t9 - tt0);
        tt0 = t9;
    }
    // Demand-driven monomorphization: emit every concrete standalone body with demand collection
    // on, then drain the queue; each demanded instance re-emits the generic Core body under its
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
    // Header-backed extern includes ship real prototypes: collect them (and the fns they declare,
    // so call sites never synthesize conflicting protos).
    let mut ext_incs = String::new();
    cemit_extern_includes(p, &mut ext_incs, &mut cem.ext_backed);
    let mut dow = DropCtx::new(p);
    let mut lw_cache = Map::<u64, u64>::new();
    let mut lws = Vector::<irl::Lowerer>::new();
    // Closure lowerings, drops applied, shared by the seed and instance loops (a demanded generic
    // body re-emits its closures per instantiation; the lowering is instantiation-independent).
    let mut cl_cache = Map::<u64, u64>::new();
    let mut clws = Vector::<irl::Lowerer>::new();
    let mut seeds: u64 = 0;
    let mut seed_skip: u64 = 0;
    let mut clos_ok: u64 = 0;
    let mut clos_skip: u64 = 0;
    let mut bodies_all = String::new();
    let mut protos = String::new();
    // Pre-size the two whole-package accumulators from the corpus (emitted C runs ~10 bytes per
    // AST node): one sized request instead of a doubling-growth chain over multi-MB buffers.
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
    // Chunk provenance: proto_of precedes every body push, so prototype line k pairs with chunk k;
    // chunk_mod is the owning TU (65534 = the shared instance TU), chunk_off the bodies_all offset.
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
            // The wrapper set would join the fingerprint for little gain.
            "";
        } else {
            p.gen_root.as_str();
        },
    );
    let mut tuc_pay = String::new();
    let par9 = p.jobs != 1 && p.modules.len() > 1;
    if par9 {
        // Parallel seed frontier: one task per module with a private emitter shard; gated
        // first-claimant emissions replay into the master in module order afterwards, so the
        // shared headers and worklists come out byte-identical to the serial loop's. Cache-hit
        // modules skip their shard entirely and replay their journaled section at merge time;
        // missed shards journal under rec_on and their sections serialize at merge (the type
        // table makes sections pool-position-independent, so parallel intern order is harmless).
        let cirg9 = p.cir as *mut iri::Interp;
        if cirg9 != null {
            unsafe cirg9.elock_on = true;
        }
        for i2 in 0..p.modules.len() {
            p.modules[i2].ast.ilock_on = true;
        }
        let mut kl = psync::Semaphore::new(1);
        let mut shards = Vector::<SeedShard>::new();
        for m in 0..p.modules.len() {
            let mut sh = SeedShard {
                cem: cbe::CEmit::new(p),
                bodies: String::new(),
                protos: String::new(),
                chunk_mod: Vector::<u64>::new(),
                chunk_off: Vector::<u64>::new(),
                env_names: Vector::<u64>::new(),
                env_bodies: Vector::<String>::new(),
                have_main: false,
                main_mod: 0,
                main_argv: false,
                seeds: 0,
                seed_skip: 0,
                clos_ok: 0,
                clos_skip: 0,
                used: false,
                dmarks: Vector::<CapMark>::new(),
                douts: Vector::<u8>::new(),
                derrs: Vector::<str<'static>>::new(),
                dvix: Vector::<u64>::new(),
                dvkeys: Vector::<u64>::new(),
                dvars: Vector::<irl::Lowerer>::new(),
                dclo_keys: Vector::<u64>::new(),
                dclo: Vector::<irl::Lowerer>::new(),
            };
            if p.modules[m].has_ast && !(live != null && p.modules[m].prelude && !unsafe live[m]) && !(tuc.on && tuc.hit[m]) {
                sh.used = true;
                sh.cem.collect_demand = true;
                sh.cem.mg.agg_on = true;
                for ei in 0..em.env_defined.len() {
                    sh.cem.env_skip.insert(*em.env_defined.at(ei), 1);
                }
                let mut dumm9 = String::new();
                cemit_extern_includes(p, &mut dumm9, &mut sh.cem.ext_backed);
                dumm9.free();
                sh.cem.sh_on = true;
                sh.cem.mg.sh_on = true;
                sh.cem.mg.mark_ctx = m as i64;
                sh.cem.mg.rec_on = tuc.on;
            }
            shards.push(sh);
        }
        let wg = psync::WaitGroup::new();
        let pp9 = p as *mut loader::Package;
        let gg9 = ((&mut g) as *mut ig::InstGraph) as *mut void;
        let klp = ((&mut kl) as *mut psync::Semaphore) as *const psync::Semaphore;
        // Longest-job-first submission (the runtime still executes in any order), gated by the
        // build memory budget; the merge below stays in module order regardless.
        let mctl = tctl::Ctl::new(tctl::budget_from_env());
        let mut order9 = Vector::<u64>::new();
        for m in 0..p.modules.len() {
            if shards.at(m).used {
                order9.push(0xFFFFFFFFFFFFFFFFu64 - p.modules[m].source.len() as u64 << 20 | m as u64);
            }
        }
        order9.sort();
        let mut launched9: i64 = 0;
        for oi9 in 0..order9.len() {
            let m = (order9[oi9] & 0xFFFFFu64) as usize;
            let est9 = p.modules[m].source.len() as u64 * 12 + (1u64 << 20);
            mctl.acquire(est9);
            wg.add(1);
            launched9 += 1;
            let op9 = (shards.index_mut(m) as *mut SeedShard) as *mut void;
            let t = SeedTask {
                p: pp9,
                ctl: &mctl,
                est: est9,
                g: gg9,
                out: op9,
                m: m,
                testing: testing,
                verbose: verbose,
                kl: klp,
            };
            let wgc = wg.clone();
            launch || {
                cemit_seed_task(t);
                wgc.done();
            };
        }
        if launched9 != 0 {
            wg.wait_masked();
        }
        if tstat {
            eprint("cemit-frontier seed: {} tasks\n", launched9);
        }
        for m in 0..p.modules.len() {
            let eligible9 = p.modules[m].has_ast && !(live != null && p.modules[m].prelude && !unsafe live[m]);
            if !eligible9 {
                if tuc.on {
                    tuc_pay.truncate(0);
                    tuc.sec_add(m, &tuc_pay);
                }
                continue;
            }
            if tuc.on && tuc.hit[m] {
                // hit: no shard ran; replay the journaled section through the master's gates at
                // exactly this module-order position.
                cem.mg.mark_ctx = m as i64;
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
                    tuc.sec_keep(m);
                    continue;
                }
                if rr == 2 {
                    eprint("tu-cache: dirty replay reject for `{}`; emitting live\n", p.modules[m].path.as_str());
                    tuc.sec_void(m);
                }
                // rejected: emit live on the master, serially, at this position (the merge point
                // is serial-state-equivalent); a clean reject re-records.
                let rec9 = rr == 1;
                let mut seg9: usize = 0;
                let mut aux9: usize = 0;
                let mut efwd9: usize = 0;
                let mut eh9: usize = 0;
                if rec9 {
                    cem.mg.rec_on = true;
                    seg9 = cem.mg.rec.len();
                    aux9 = cem.aux.len();
                    efwd9 = cem.env_fwd.len();
                    eh9 = cem.env_hashes.len();
                }
                cemit_seed_module(
                    p,
                    &mut cem,
                    &mut g,
                    &mut dow,
                    &mut cl_cache,
                    &mut clws,
                    m,
                    testing,
                    verbose,
                    null,
                    &mut bodies_all,
                    &mut protos,
                    &mut chunk_mod,
                    &mut chunk_off,
                    &mut env_names,
                    &mut env_bodies,
                    &mut have_main,
                    &mut main_mod,
                    &mut main_argv,
                    &mut seeds,
                    &mut seed_skip,
                    &mut clos_ok,
                    &mut clos_skip,
                );
                if rec9 {
                    cem.mg.rec_on = false;
                    if cem.aux.len() > aux9 {
                        let mut ev9 = mbe::RecEv::blank(mbe::RK_AUX);
                        ev9.s1.push_str(cem.aux.as_str().slice(aux9, cem.aux.len()));
                        cem.mg.rec.push(ev9);
                    }
                    if cem.env_fwd.len() > efwd9 {
                        let mut ev9 = mbe::RecEv::blank(mbe::RK_EFWD);
                        ev9.s1.push_str(cem.env_fwd.as_str().slice(efwd9, cem.env_fwd.len()));
                        cem.mg.rec.push(ev9);
                    }
                    for k9 in eh9..cem.env_hashes.len() {
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
                    tuc_pay.truncate(0);
                    tuc::ser_evs(p, &mut tuc_pay, &cem.mg.rec, seg9, bodies_all.as_str());
                    tuc.sec_add(m, &tuc_pay);
                    cem.mg.rec.truncate(seg9);
                }
                continue;
            }
            let o = shards.index_mut(m);
            if !o.used {
                continue;
            }
            if tuc.on {
                // The shard's journal becomes the module's section: trailing deltas are the whole
                // shard-local accumulators, chunk texts materialize from the shard's bodies buffer.
                if o.cem.aux.len() != 0 {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_AUX);
                    ev9.s1.push_str(o.cem.aux.as_str());
                    o.cem.mg.rec.push(ev9);
                }
                if o.cem.env_fwd.len() != 0 {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_EFWD);
                    ev9.s1.push_str(o.cem.env_fwd.as_str());
                    o.cem.mg.rec.push(ev9);
                }
                for k9 in 0..o.cem.env_hashes.len() {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_EDEF);
                    ev9.h = *o.cem.env_hashes.at(k9);
                    o.cem.mg.rec.push(ev9);
                }
                {
                    let mut ev9 = mbe::RecEv::blank(mbe::RK_EDGE);
                    for dst in 0..p.modules.len() {
                        if o.cem.mg.um_hit(m as u64, dst) {
                            ev9.xs.push(dst as u32);
                        }
                    }
                    o.cem.mg.rec.push(ev9);
                }
                tuc_pay.truncate(0);
                tuc::ser_evs(p, &mut tuc_pay, &o.cem.mg.rec, 0, o.bodies.as_str());
                tuc.sec_add(m, &tuc_pay);
            }
            let base9 = bodies_all.len() as u64;
            for k2 in 0..o.chunk_mod.len() {
                chunk_mod.push(o.chunk_mod[k2]);
                chunk_off.push(o.chunk_off[k2] + base9);
            }
            bodies_all.push_string(&o.bodies);
            protos.push_string(&o.protos);
            for k2 in 0..o.env_names.len() {
                env_names.push(o.env_names[k2]);
                env_bodies.push(replace(o.env_bodies.index_mut(k2), String::new()));
            }
            if o.have_main {
                have_main = true;
                main_mod = o.main_mod;
                main_argv = o.main_argv;
            }
            seeds += o.seeds;
            seed_skip += o.seed_skip;
            clos_ok += o.clos_ok;
            clos_skip += o.clos_skip;
            cemit_seed_merge(&mut cem, o, m as u64);
        }
        for i2 in 0..p.modules.len() {
            p.modules[i2].ast.ilock_on = false;
        }
        if cirg9 != null {
            unsafe cirg9.elock_on = false;
        }
    } else {
        for m in 0..p.modules.len() {
            if !p.modules[m].has_ast || live != null && p.modules[m].prelude && !unsafe live[m] {
                // No seeds (missing AST / unreachable prelude): an empty section keeps the image indexed.
                if tuc.on {
                    tuc_pay.truncate(0);
                    tuc.sec_add(m, &tuc_pay);
                }
                continue;
            }
            // Symbols the module spells about ITSELF are not cross-TU uses.
            cem.mg.mark_ctx = m as i64;
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
                        tuc.sec_keep(m);
                        continue;
                    }
                    // Clean rejects are ordinary churn (another module's typecheck moved this pool);
                    // a DIRTY reject means interns landed before diverging: warn and void the section.
                    if rr == 2 {
                        eprint("tu-cache: dirty replay reject for `{}`; emitting live\n", p.modules[m].path.as_str());
                        tuc.sec_void(m);
                    }
                    tuc_rec = rr == 1;
                } else {
                    tuc_rec = true;
                }
            }
            let mut tuc_seg0: usize = 0;
            let mut tuc_aux0: usize = 0;
            let mut tuc_efwd0: usize = 0;
            let mut tuc_eh0: usize = 0;
            if tuc_rec {
                cem.mg.rec_on = true;
                tuc_seg0 = cem.mg.rec.len();
                tuc_aux0 = cem.aux.len();
                tuc_efwd0 = cem.env_fwd.len();
                tuc_eh0 = cem.env_hashes.len();
            }
            cemit_seed_module(
                p,
                &mut cem,
                &mut g,
                &mut dow,
                &mut cl_cache,
                &mut clws,
                m,
                testing,
                verbose,
                null,
                &mut bodies_all,
                &mut protos,
                &mut chunk_mod,
                &mut chunk_off,
                &mut env_names,
                &mut env_bodies,
                &mut have_main,
                &mut main_mod,
                &mut main_argv,
                &mut seeds,
                &mut seed_skip,
                &mut clos_ok,
                &mut clos_skip,
            );
            if tuc_rec {
                cem.mg.rec_on = false;
                // Trailing delta events: their accumulators are consumed whole at assembly, so only
                // their internal order matters.
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
                tuc_pay.truncate(0);
                tuc::ser_evs(p, &mut tuc_pay, &cem.mg.rec, tuc_seg0, bodies_all.as_str());
                tuc.sec_add(m, &tuc_pay);
                cem.mg.rec.truncate(tuc_seg0);
            }
        }
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage seed: {} ms\n", t9 - tt0);
        tt0 = t9;
    }
    // @test wrappers: per-case runner entry points + the global-env hooks, emitted as ordinary
    // chunks of their owning module's TU (their fixture frees join the glue/demand worklists).
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
    // Per-lowering CFGs, built once and lent to every instantiation's emission (see CEmit.cf_ext).
    let mut cfs = Vector::<cfl::CFlow>::new();
    let mut cf_ok = Vector::<bool>::new();
    let mut sa_seen = Map::<u64, u64>::new();
    let mut ia_idx = Vector::<Vector<NodeId>>::new();
    let mut ia_built = Vector::<bool>::new();
    for _i in 0..p.modules.len() {
        ia_idx.push(Vector::<NodeId>::new());
        ia_built.push(false);
    }
    let mut inst_ok: u64 = 0;
    let mut inst_skip: u64 = 0;
    let mut glue_ok: u64 = 0;
    let mut glue_skip: u64 = 0;
    let mut gi9: usize = 0;
    let mut reasons = Vector::<str<'static>>::new();
    let mut rcounts = Vector::<u64>::new();
    // Instance-TU emission: every spelled module is link-reachable.
    cem.mg.mark_ctx = -1;
    let mut kl9 = psync::Semaphore::new(1);
    let cird = p.cir as *mut iri::Interp;
    if par9 {
        if cird != null {
            unsafe cird.elock_on = true;
        }
        for i2 in 0..p.modules.len() {
            p.modules[i2].ast.ilock_on = true;
        }
    }
    let mut qi: usize = 0;
    let mut dwaves: u64 = 0;
    let mut dtasks: u64 = 0;
    let mut dslices: u64 = 0;
    while (qi < cem.demand.len() || gi9 < cem.glue.len()) && qi < 200000 {
        // Derived destructors drain alongside instances (each may enqueue the other).
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
        if !par9 {
            let di0 = qi;
            qi += 1;
            cemit_drain_demand(
                p,
                &mut cem,
                &mut g,
                &mut dow,
                &mut lw_cache,
                &mut lws,
                &mut cl_cache,
                &mut clws,
                &mut cfs,
                &mut cf_ok,
                &mut done,
                &mut sa_seen,
                &mut ia_idx,
                &mut ia_built,
                di0,
                verbose,
                &mut bodies_all,
                &mut protos,
                &mut chunk_mod,
                &mut chunk_off,
                &mut env_names,
                &mut env_bodies,
                &mut inst_ok,
                &mut inst_skip,
                &mut clos_ok,
                &mut clos_skip,
                &mut reasons,
                &mut rcounts,
            );
            continue;
        }
        dwaves += 1;
        let len0 = cem.demand.len();
        let mut widx = Vector::<u64>::new(); // tasked demand indices, ascending
        let mut wli = Vector::<u64>::new(); // their base lowering slots (0xFF.. = pending phase L)
        let mut wdef = Vector::<u64>::new(); // their packed defs
        let mut wave_seen = Map::<u64, u64>::new();
        let mut newdefs = Vector::<u64>::new();
        let mut newsyms = Vector::<String>::new(); // first demanding symbol, for the failure print
        let mut newdef_seen = Map::<u64, u64>::new();
        for j in qi..len0 {
            let js9 = cem.demand.at(j).sym.clone();
            let js = js9.as_str();
            let mut dkj = 1469598103934665603u64;
            for k in 0..js.len() {
                dkj = (dkj ^ js.byte_at(k) as u64) * 1099511628211u64;
            }
            let seenj = switch done.get(&dkj) {
                Some(_v) => true,
                None => false,
            };
            if seenj {
                continue;
            }
            let wavedup = switch wave_seen.get(&dkj) {
                Some(_v) => true,
                None => false,
            };
            if wavedup {
                // A later chain retries on the master only if the first fails.
                continue;
            }
            wave_seen.insert(dkj, 1);
            let jd = cem.demand.at(j).def;
            let jkey = jd.module as u64 << 32 | jd.node as u64;
            let base = switch lw_cache.get(&skey_mix(0, jkey)) {
                Some(v) => *v,
                None => 0xFFFFFFFFFFFFFFFEu64,
            };
            if base == 0xFFFFFFFFFFFFFFFFu64 {
                // Known-unlowerable: the merge fallback counts the skip.
                continue;
            }
            if base == 0xFFFFFFFFFFFFFFFEu64 {
                let nds = switch newdef_seen.get(&jkey) {
                    Some(_v) => true,
                    None => false,
                };
                if !nds {
                    newdef_seen.insert(jkey, 1);
                    newdefs.push(jkey);
                    newsyms.push(cem.demand.at(j).sym.clone());
                }
            }
            widx.push(j as u64);
            wli.push(base);
            wdef.push(jkey);
        }
        // Phase L: lower this wave's missing base definitions in parallel slices.
        if newdefs.len() != 0 {
            let nd = newdefs.len();
            let mut res9 = Vector::<irl::Lowerer>::new();
            let mut cfr9 = Vector::<cfl::CFlow>::new();
            let mut oks9 = Vector::<bool>::new();
            for _i in 0..nd {
                res9.push(irl::Lowerer::new(p, 0, NODE_NONE));
                cfr9.push(cfl::CFlow::new_empty());
                oks9.push(false);
            }
            cemit_low_launch(p, &mut g, &mut kl9, &newdefs, &mut res9, &mut cfr9, &mut oks9, p.jobs);
            for i in 0..nd {
                let jkey = newdefs[i];
                if oks9[i] {
                    while cfs.len() < lws.len() {
                        cfs.push(cfl::CFlow::new_empty());
                        cf_ok.push(false);
                    }
                    let slot = lws.len() as u64;
                    lws.push(replace(res9.index_mut(i), irl::Lowerer::new(p, 0, NODE_NONE)));
                    cfs.push(replace(cfr9.index_mut(i), cfl::CFlow::new_empty()));
                    cf_ok.push(true);
                    lw_cache.insert(skey_mix(0, jkey), slot);
                } else {
                    eprint("inst-lower-fail: `{}` {}\n", newsyms.at(i).as_str(), "");
                    lw_cache.insert(skey_mix(0, jkey), 0xFFFFFFFFFFFFFFFFu64);
                }
            }
        }
        // Resolve pending base slots; drop entries whose base failed (merge fallback counts them).
        {
            let mut w2 = Vector::<u64>::new();
            let mut l2 = Vector::<u64>::new();
            for i in 0..widx.len() {
                let mut li9 = wli[i];
                if li9 == 0xFFFFFFFFFFFFFFFEu64 {
                    li9 = (switch lw_cache.get(&skey_mix(0, wdef[i])) {
                        Some(v) => *v,
                        None => 0xFFFFFFFFFFFFFFFFu64,
                    });
                }
                if li9 == 0xFFFFFFFFFFFFFFFFu64 {
                    continue;
                }
                w2.push(widx[i]);
                l2.push(li9);
            }
            widx = w2;
            wli = l2;
        }
        // Phase E: contiguous demand slices, each emitting into one private shard.
        let mut envh9 = Vector::<u64>::new();
        for ei in 0..cem.env_hashes.len() {
            envh9.push(*cem.env_hashes.at(ei));
        }
        let mut nsl9: usize = 1;
        if p.jobs >= 2 && widx.len() > 1 {
            nsl9 = 2 * p.jobs as usize;
            if nsl9 > widx.len() {
                nsl9 = widx.len();
            }
        }
        let mut sbounds = Vector::<u64>::new();
        for i in 0..nsl9 {
            sbounds.push((widx.len() * (i + 1) / nsl9) as u64);
        }
        let mut dsh = Vector::<SeedShard>::new();
        for _i in 0..nsl9 {
            let mut sh = SeedShard {
                cem: cbe::CEmit::new(p),
                bodies: String::new(),
                protos: String::new(),
                chunk_mod: Vector::<u64>::new(),
                chunk_off: Vector::<u64>::new(),
                env_names: Vector::<u64>::new(),
                env_bodies: Vector::<String>::new(),
                have_main: false,
                main_mod: 0,
                main_argv: false,
                seeds: 0,
                seed_skip: 0,
                clos_ok: 0,
                clos_skip: 0,
                used: true,
                dmarks: Vector::<CapMark>::new(),
                douts: Vector::<u8>::new(),
                derrs: Vector::<str<'static>>::new(),
                dvix: Vector::<u64>::new(),
                dvkeys: Vector::<u64>::new(),
                dvars: Vector::<irl::Lowerer>::new(),
                dclo_keys: Vector::<u64>::new(),
                dclo: Vector::<irl::Lowerer>::new(),
            };
            sh.cem.collect_demand = true;
            sh.cem.mg.agg_on = true;
            for ei in 0..em.env_defined.len() {
                sh.cem.env_skip.insert(*em.env_defined.at(ei), 1);
            }
            for ei in 0..envh9.len() {
                sh.cem.env_skip.insert(envh9[ei], 1);
            }
            let mut dumm9 = String::new();
            cemit_extern_includes(p, &mut dumm9, &mut sh.cem.ext_backed);
            dumm9.free();
            sh.cem.sh_on = true;
            sh.cem.mg.sh_on = true;
            sh.cem.mg.mark_ctx = -1;
            dsh.push(sh);
        }
        dtasks += widx.len() as u64;
        dslices += nsl9 as u64;
        cemit_drain_launch(
            p,
            &mut g,
            &mut kl9,
            &mut cem,
            &lws,
            &cfs,
            &lw_cache,
            &cl_cache,
            &clws,
            &mut dsh,
            &sbounds,
            &widx,
            &wli,
            verbose,
        );
        // Merge in exact queue order, glue interleaved exactly as the serial loop drains it.
        let mut wcur: usize = 0;
        let mut scur: usize = 0;
        let mut slo: usize = 0;
        for j in qi..len0 {
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
            let tasked = wcur < widx.len() && widx[wcur] == j as u64;
            if !tasked {
                cemit_drain_demand(
                    p,
                    &mut cem,
                    &mut g,
                    &mut dow,
                    &mut lw_cache,
                    &mut lws,
                    &mut cl_cache,
                    &mut clws,
                    &mut cfs,
                    &mut cf_ok,
                    &mut done,
                    &mut sa_seen,
                    &mut ia_idx,
                    &mut ia_built,
                    j,
                    verbose,
                    &mut bodies_all,
                    &mut protos,
                    &mut chunk_mod,
                    &mut chunk_off,
                    &mut env_names,
                    &mut env_bodies,
                    &mut inst_ok,
                    &mut inst_skip,
                    &mut clos_ok,
                    &mut clos_skip,
                    &mut reasons,
                    &mut rcounts,
                );
                continue;
            }
            let d_ord = wcur - slo;
            wcur += 1;
            let js9 = cem.demand.at(j).sym.clone();
            let js = js9.as_str();
            let mut dkj = 1469598103934665603u64;
            for k in 0..js.len() {
                dkj = (dkj ^ js.byte_at(k) as u64) * 1099511628211u64;
            }
            {
                let jd = cem.demand.at(j).def;
                let mut jsubs = Vector::<mbe::MSub>::new();
                for i2 in 0..cem.demand.at(j).subs.len() {
                    jsubs.push(*cem.demand.at(j).subs.at(i2));
                }
                cemit_inst_asserts(p, jd, &jsubs, dkj, &mut sa_seen, &mut ia_idx, &mut ia_built);
            }
            {
                let o = dsh.index_mut(scur);
                let ma = if d_ord == 0 {
                    cap_zero();
                } else {
                    *o.dmarks.at(d_ord - 1);
                };
                let mb = *o.dmarks.at(d_ord);
                let out9 = o.douts[d_ord];
                if out9 == 0 {
                    done.insert(dkj, 1);
                    inst_ok += 1;
                    let vix = o.dvix[d_ord];
                    if vix != 0xFFFFFFFFFFFFFFFFu64 && o.dvkeys[vix as usize] != 0 {
                        let zk = o.dvkeys[vix as usize];
                        let zseen = switch lw_cache.get(&zk) {
                            Some(_v) => true,
                            None => false,
                        };
                        if !zseen && o.dvars.at(vix as usize).body.blocks.len() != 0 {
                            while cfs.len() < lws.len() {
                                cfs.push(cfl::CFlow::new_empty());
                                cf_ok.push(false);
                            }
                            let slot = lws.len() as u64;
                            let mv9 = replace(o.dvars.index_mut(vix as usize), irl::Lowerer::new(p, 0, NODE_NONE));
                            let mut cf9 = cfl::CFlow::new_empty();
                            cf9.build_into(&mv9.body);
                            lws.push(mv9);
                            cfs.push(cf9);
                            cf_ok.push(true);
                            lw_cache.insert(zk, slot);
                        }
                    }
                    for k2 in ma.dclo as usize..mb.dclo as usize {
                        let ckey = o.dclo_keys[k2];
                        let cseen = switch cl_cache.get(&ckey) {
                            Some(_v) => true,
                            None => false,
                        };
                        if !cseen {
                            let lw9 = replace(o.dclo.index_mut(k2), irl::Lowerer::new(p, 0, NODE_NONE));
                            if lw9.body.blocks.len() != 0 {
                                let slot = clws.len() as u64;
                                clws.push(lw9);
                                cl_cache.insert(ckey, slot);
                            } else {
                                cl_cache.insert(ckey, 0xFFFFFFFFFFFFFFFFu64);
                            }
                        }
                    }
                    let base9 = bodies_all.len() as u64;
                    for k2 in ma.chunks as usize..mb.chunks as usize {
                        chunk_mod.push(o.chunk_mod[k2]);
                        chunk_off.push(o.chunk_off[k2] - ma.bodies + base9);
                    }
                    bodies_all.push_str(o.bodies.as_str().slice(ma.bodies as usize, mb.bodies as usize));
                    protos.push_str(o.protos.as_str().slice(ma.protos as usize, mb.protos as usize));
                    for k2 in ma.envn as usize..mb.envn as usize {
                        env_names.push(o.env_names[k2]);
                        env_bodies.push(replace(o.env_bodies.index_mut(k2), String::new()));
                    }
                    cemit_seed_merge_range(&mut cem, o, &ma, &mb);
                } else if out9 == 1 {
                    inst_skip += 1;
                } else {
                    if verbose {
                        eprint("inst-emit-fail: `{}` {}\n", js, o.derrs[d_ord]);
                    }
                    let mut found = false;
                    for r2 in 0..reasons.len() {
                        if reasons[r2] == o.derrs[d_ord] {
                            rcounts.set(r2, rcounts[r2] + 1);
                            found = true;
                            break;
                        }
                    }
                    if !found {
                        reasons.push(o.derrs[d_ord]);
                        rcounts.push(1);
                    }
                }
            }
            // Slice exhausted: absorb its order-insensitive remainder once.
            if scur < sbounds.len() && wcur == sbounds[scur] as usize {
                let o = dsh.index_mut(scur);
                clos_ok += o.clos_ok;
                clos_skip += o.clos_skip;
                cemit_seed_merge_um(&mut cem, o);
                slo = wcur;
                scur += 1;
            }
        }
        qi = len0;
    }
    if par9 {
        for i2 in 0..p.modules.len() {
            p.modules[i2].ast.ilock_on = false;
        }
        if cird != null {
            unsafe cird.elock_on = false;
        }
    }
    // True instance failures are demanded symbols that never emitted on ANY chain.
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
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage drain: {} ms\n", t9 - tt0);
        tt0 = t9;
        if dwaves != 0 {
            eprint("cemit-frontier inst: {} waves, {} tasks, {} slices\n", dwaves, dtasks, dslices);
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
        // The argv wrapper's Global allocator receiver.
        cem.sentinel(1, &mut sn9);
    }
    // `@emit_macro` C-reuse templates: `<STEM>_DECLARE/_DEFINE(<params>, NAME)`, the struct body
    // plus every non-generic method of the type's plain generic extends, emitted through cemit
    // under macro spelling (unresolved params as their names; symbols pasted onto NAME).
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
                // The raw (pre-rewrite) bodies of the two templates.
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
                // Every non-generic single-return method of the type's plain generic extends.
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
                        // Macro-template bodies keep symbolic generics: never inline into them.
                        dow.apply_drops_of(&mut mlw, false);
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
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage macros: {} ms\n", t9 - tt0);
        tt0 = t9;
    }
    // Dyn typedef blocks: drain every dyn spelling site both manglers recorded (rendering can
    // discover further stems; the index loop rides the growing vector to a fixed point).
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
    // Const/static definitions: each referenced item folds through the Core IR interpreter; one
    // interpreter serves the whole pass (its lowered-callee cache, call memo, and captured static
    // groups persist), and the descriptor sections below render from the same store.
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
                // The backing C header owns the definition; the extern stub suffices.
                continue;
            }
            if cdn.kind != NodeKind::NODE_CONST || cdn.as_data.const_def.value == NODE_NONE {
                cd_skip += 1;
                continue;
            }
            if cem.mg.method_target(cdef.module, cdef.node).node != NODE_NONE {
                // Associated consts fold under Self frames, not through this path.
                cd_skip += 1;
                continue;
            }
            let v = cdit.eval_const_in(cdef.module, cdef.node, 1u32 << 20);
            let cty = cem.stat_items.at(ci).ty;
            // Array-of-string consts render from their literal initializer directly.
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
                                // Slice-view consts: a hidden data array + the view.
                                is_slice2 = true;
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
                // Any other aggregate: the CTFE static graph, captured straight from the
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
            // A NULL pointer constant is scalar data (`= 0`).
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
                        // C has no i64::MIN literal.
                        line.push_str("(-9223372036854775807LL - 1)");
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
                        // `)"` suffix.
                        b0 -= 2;
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
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage consts: {} ms\n", t9 - tt0);
        tt0 = t9;
    }
    // @reflect exports + `type_info` descriptor groups: the CTFE static graph rendered as file-
    // scope const data (extern roots; `__ct%u` auxiliaries static per group).
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
            // `@reflect`-tagged concrete aggregates export a registered descriptor.
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
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage statics+ti: {} ms\n", t9 - tt0);
        tt0 = t9;
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
        // Aggregates first named by demand-driven bodies or by other aggregates' FIELDS (chains
        // the planner's closure never reached): replay each recorded spelling under its env; the
        // name-keyed state map skips everything already defined. em's own list GROWS while
        // replaying (a replayed body's field types record deeper instances); follow it.
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
        // Env bodies the declaration pass did NOT define inline (non-embedded closures): they
        // land after every aggregate body, deduped against the embedded ones.
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
        // Chunk indexes per TU (the instance TU last), one pass over the chunk list: the per-TU
        // assembly below then touches only its own chunks and reserves its buffers exactly.
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
        let mut lps = Vector::<String>::new();
        let mut lbs = Vector::<String>::new();
        for _k in 0..8 {
            lps.push(String::new());
            lbs.push(String::new());
        }
        for t in 0..p.modules.len() + 1 {
            let is_inst = t == p.modules.len();
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
            // Partition an oversized TU into deterministic units so the C compiler parallelizes
            // its critical path. The part count is a pure function of the body bytes, and a part
            // boundary sits only BEFORE a non-static chunk: a `static` chunk is a closure that
            // must share a unit with the body it belongs to.
            let mut nparts = 1 + bb / 262144;
            if nparts > 8 {
                nparts = 8;
            }
            for k in 0..nparts {
                lps.index_mut(k).truncate(0);
                lbs.index_mut(k).truncate(0);
            }
            let target = bb / nparts + 1;
            let mut cur: usize = 0;
            for k in 0..tu_chunks[t].len() {
                let i = tu_chunks[t][k] as usize;
                let pl = ps.slice(poff[i] as usize, poff[i + 1] as usize);
                let is_static = pl.len() >= 7 && pl.slice(0, 7) == "static ";
                if !is_static && cur + 1 < nparts && lbs.at(cur).len() >= target {
                    cur += 1;
                }
                if is_static {
                    lps.index_mut(cur).push_str(pl);
                }
                let b1 = if i + 1 < chunk_off.len() {
                    chunk_off[i + 1] as usize;
                } else {
                    bs.len();
                };
                lbs.index_mut(cur).push_str(bs.slice(chunk_off[i] as usize, b1));
            }
            // Under --test the fork-per-test runner owns the C `main`; the user main stays a
            // plain (unreferenced) `__sc_user_main`.
            let has_wrap = have_main && !testing && !is_inst && t as u64 == main_mod;
            if bb == 0 && !is_inst && !has_wrap {
                continue;
            }
            let mut tu2 = String::new();
            {
                let mut cap2 = lps.at(0).len() + lbs.at(0).len() + 2048;
                if is_inst {
                    cap2 += cem.blk_defs.len() + const_defs.len() + static_defs.len() + cem.dyn_tabs.len();
                }
                tu2.reserve(cap2);
            }
            tu2.push_string(lps.at(0));
            if !is_inst && p.modules[t].has_ast {
                // Folded module-level static_asserts leave their record in the C (parity with
                // the checker: a false one already failed the build).
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
            tu2.push_string(lbs.at(0));
            if has_wrap && nparts == 1 {
                cemit_main_wrapper(&mut tu2, main_argv);
            }
            if is_inst {
                o.inst_c = tu2;
            } else {
                o.tus.set(t, tu2);
            }
            for k in 1..nparts {
                let mut px = String::new();
                px.reserve(lps.at(k).len() + lbs.at(k).len() + 256);
                px.push_string(lps.at(k));
                px.push_string(lbs.at(k));
                if has_wrap && k == nparts - 1 {
                    cemit_main_wrapper(&mut px, main_argv);
                }
                if px.len() == 0 {
                    continue;
                }
                if is_inst {
                    o.inst_extra.push(px);
                } else {
                    o.tu_extra.index_mut(t).push(px);
                }
            }
        }
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("cemit-stage assembly: {} ms\n", t9 - tt0);
        tt0 = t9;
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
    dctx_drop();
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
    // SS_STRUCT / SS_ENUM: the aggregate's (instance) C name.
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
    // SK_INT: unsigned pool types print unsigned (with the 64-bit suffix when the sign bit is set).
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
    // SS_STRUCT.
    if nslots == 0 {
        // Strict C11: an empty initializer list is not C.
        out.push_str("{0}");
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
            // Zero-sized field: no C member to initialize.
            continue;
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
        // All fields erased inside a still-material carrier.
        out.push_str("0");
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

// `<QUALIFIED>` uppercased with every non-alphanumeric flattened to `_`: the template family stem.
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
                // Resolve next to the declaring module's file; realpath makes the tree
                // compile from any location.
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
// drop terminators, exactly as the differential does; WITHOUT this, emitted programs leak every
// non-moved owning local (explicit `.free()` calls are the only TM_DROPs lowering itself emits).
// The drop-elaboration analyses, pooled: one instance rebuilds in place per body (capacity kept),
// mirroring flow_ir's FlowCtx; fresh builds per body dominated the elaboration's allocator cost.
// Emission-phase pool of DropCtx instances: a task checks one out and returns it, so the
// inliner's vetted-callee cache (whose misses lower and copy whole callees) warms once per pooled
// slot (about the worker count) instead of once per task. Valid within one emission phase:
// every cached decision is a pure function of the frozen package. `cemit_package` resets it.
static mut G_DPOOL: *mut Vector<DropCtx> = null;
static mut G_DPOOL_LOCK: i32 = 0;

fn dctx_take(p: *const loader::Package) DropCtx {
    unsafe sc_runtime::sc_rt_spin_lock(&mut G_DPOOL_LOCK);
    if unsafe G_DPOOL != null {
        switch (unsafe &mut *G_DPOOL).pop() {
            Some(d9) => {
                unsafe sc_runtime::sc_rt_spin_unlock(&mut G_DPOOL_LOCK);
                return d9;
            },
            _ => {},
        };
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut G_DPOOL_LOCK);
    return DropCtx::new(p);
}

fn dctx_put(d: DropCtx) {
    unsafe sc_runtime::sc_rt_spin_lock(&mut G_DPOOL_LOCK);
    if unsafe G_DPOOL == null {
        let mut g9 = Global {};
        let pv = (unsafe g9.alloc(sizeof(Vector<DropCtx>), alignof(Vector<DropCtx>))) as *mut Vector<DropCtx>;
        unsafe pv[0] = Vector::<DropCtx>::new();
        unsafe G_DPOOL = pv;
    }
    (unsafe &mut *G_DPOOL).push(d);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut G_DPOOL_LOCK);
}

// End-of-phase teardown: the pooled contexts and the pool holder itself are released, so a compile
// exits with no live pool allocation (the leak gate audits every process).
fn dctx_drop() {
    unsafe sc_runtime::sc_rt_spin_lock(&mut G_DPOOL_LOCK);
    if unsafe G_DPOOL != null {
        let pv = unsafe G_DPOOL;
        unsafe G_DPOOL = null;
        pv.free();
        let mut g9 = Global {};
        unsafe g9.dealloc(pv, sizeof(Vector<DropCtx>), alignof(Vector<DropCtx>));
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut G_DPOOL_LOCK);
}

struct DropCtx {
    pub ow: bfx::Owner,
    pub forest: bmp::MoveForest,
    pub facts: bfx::BodyFacts,
    pub cfg: bdf::Cfg,
    pub mv: bdf::MoveFlow,
    pub el: ird::ElabCtx,
    pub inl: inl::InlineCtx,
    pub bce: bce::Bce,
    pub core_ir: bool, // SC_CORE_IR development re-verification
    pub bce_stats: bool, // SC_BCE_STATS per-owner report lines
}

extend DropCtx {
    fn new(p: *const loader::Package) DropCtx {
        return DropCtx {
            ow: bfx::Owner::new(p),
            forest: bmp::MoveForest::empty(),
            facts: bfx::BodyFacts::empty(),
            cfg: bdf::Cfg::empty(),
            mv: bdf::MoveFlow::empty(),
            el: ird::ElabCtx::empty(),
            inl: inl::InlineCtx::new(),
            bce: bce::Bce::new(p),
            core_ir: stdlib::getenv("SC_CORE_IR") != null,
            bce_stats: stdlib::getenv("SC_BCE_STATS") != null,
        };
    }

    fn apply_drops(self: &mut Self, lw: &mut irl::Lowerer) {
        self.apply_drops_of(lw, true);
    }

    fn apply_drops_of(self: &mut Self, lw: &mut irl::Lowerer, allow_inline: bool) {
        // The inliner runs FIRST so drop elaboration and BCE see the merged body; the callee's
        // own storage markers make the merged elaboration reproduce the callee's drops in place.
        if allow_inline && !self.inl.off {
            let mut ist = inl::InlineStats::new();
            inl::run(lw, &mut self.inl, &mut ist);
            if self.inl.stats_on && ist.considered != 0 {
                let mut iline = String::new();
                inl::stats_line(&ist, &mut iline);
                eprint("{} owner {}:{}\n", iline.as_str(), lw.body.module, lw.body.owner.node);
            }
            if ist.inlined != 0 && self.core_ir {
                let tp9 = unsafe (&*(&*lw.pkg).module_ast_const(lw.body.module)).type_pool.len();
                let iv9 = irv::verify(&lw.body, tp9, lw.pkg);
                if iv9.len() != 0 {
                    eprintln("SC_CORE_IR: inline verify: {}", iv9);
                }
            }
        }
        self.forest.build_into(&lw.body);
        self.ow.generate_into(&lw.body, &self.forest, &mut self.facts);
        self.cfg.build_into(&lw.body);
        self.mv.build_into(&lw.body, &self.forest, &self.facts, &self.cfg);
        ird::elaborate_into(&mut self.ow, &lw.body, &self.forest, &self.facts, &self.mv, &mut self.el);
        ird::insert_drops(&mut lw.body, &self.el.sched, &self.forest);
        // Bounds-check elimination runs HERE, on the final elaborated body, so every emission
        // path (seed, instance, closure, wrapper) proves against the exact statements it emits.
        let mut bst = bce::BceStats::new();
        let _ = bce::run(&mut lw.body, lw.pkg, &mut self.bce, &mut bst, false);
        if self.core_ir {
            // Development re-verification: every PROVEN operation must re-prove.
            let be = bce::run(&mut lw.body, lw.pkg, &mut self.bce, &mut bst, true);
            if be.len() != 0 {
                eprintln("SC_CORE_IR: {}", be);
            }
        }
        if self.bce_stats && (bst.total != 0 || bst.ranges_total != 0 || bst.folded != 0) {
            let mut line = String::new();
            bce::stats_line(&bst, &mut line);
            eprint("{} owner {}:{}\n", line.as_str(), lw.body.module, lw.body.owner.node);
            line.free();
        }
    }
}

// The free-glue wrapper fields (frozen `__fb` convention): a CONCRETE struct's selected user
// `free` whose body never touches some destructible owning fields gets renamed `<sym>__fb`, and
// the public symbol wraps it, freeing each untouched field, covering every early return.
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
    let mut touched = Vector::<NodeId>::new();
    for r in 0..a.resolutions_len() {
        let ksp = a.at_const(r as NodeId).span;
        if ksp.start >= bsp.start && ksp.end <= bsp.end {
            let d = a.resolution_def(r as NodeId);
            if d.module == m {
                touched.push(d.node);
            }
        }
    }
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        let fnode = a.at_const(fid);
        // Tuple members are bare type nodes; named members are NODE_FIELD.
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
            // Non-owning by rule: raw pointers are borrows.
            continue;
        }
        if !cem.is_destructible(m, ft, 0) {
            continue;
        }
        let mut field_touched = false;
        for r in 0..touched.len() {
            if touched[r] == fid {
                field_touched = true;
                break;
            }
        }
        if !field_touched {
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

// Borrow-check module `i`, serially: the pipeline stage after typechecking. A fresh TypeChecker context
// over the typed AST carries the recorded types and resolutions; only the borrow/move/lifetime analyses
// run. This is the one-module primitive borrowck_all iterates.
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

// One parallel borrow-check unit of work: a private oracle, pipeline, checker and diagnostics per
// module. The finished (already finalized) diagnostics and the module's lowered bodies land in
// `out`; nothing prints and nothing outside the module's own Ast is written; the const engine
// serializes behind its gate, interning behind each Ast's lock.
struct BcOut {
    pub ok: bool,
    pub lint: u32,
    pub errors: diag::Errors,
    pub keep: irl::Keep,
}

struct BcTask {
    pub p: *mut loader::Package,
    pub i: usize,
    pub out: *mut BcOut,
    pub want_keep: bool,
}

// The task closure crosses to a worker; the package and slots it points at are partitioned by
// module and outlive the WaitGroup join.
unsafe extend BcTask as Send {}

fn bc_run_one(t: BcTask) {
    let pkg = t.p;
    let p = unsafe &mut *t.p;
    let mut ow = bfx::Owner::new(p);
    let mut ctx = bfi::BorrowCtx::new();
    if t.want_keep {
        ctx.keep = &mut (unsafe &mut *t.out).keep;
    }
    let m = &mut p.modules[t.i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut tck = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    tck.borrowck(&mut ow, &mut ctx);
    let o = unsafe &mut *t.out;
    o.ok = !tck.has_errors();
    o.lint = tck.errors.errors.len() as u32;
    o.errors = replace(&mut tck.errors, diag::Errors::new());
}

/// Borrow-check every module through ONE ownership oracle and ONE borrow pipeline when serial
/// (their memo tables and capacities survive across modules), or one of each per module task when
/// `p.jobs` asks for workers; outputs merge in module order, so both paths print and lower
/// identically. `keep` (null = discard) collects every lowered body for the backend. False when
/// any module reported an error.
pub fn borrowck_all(p: &mut loader::Package, keep: *mut irl::Keep) bool {
    let n = p.modules.len();
    if p.jobs != 1 && n > 1 {
        return borrowck_all_par(p, keep);
    }
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

fn borrowck_all_par(p: &mut loader::Package, keep: *mut irl::Keep) bool {
    let n = p.modules.len();
    // Package-wide lazy state the tasks would otherwise race to build.
    if p.co_state == 0 {
        p.co_compute();
    }
    if p.cancel_state == 0 {
        p.cancel_compute();
    }
    let cirp = p.cir as *mut iri::Interp;
    if cirp != null {
        unsafe cirp.elock_on = true;
    }
    for i in 0..n {
        p.modules[i].ast.ilock_on = true;
    }
    let mut outs = Vector::<BcOut>::with_capacity(n);
    for _ in 0..n {
        outs.push(BcOut { ok: true, lint: 0, errors: diag::Errors::new(), keep: irl::Keep::new() });
    }
    if p.jobs >= 2 {
        prt::set_worker_count(p.jobs as usize);
    }
    prt::set_stack_size(8usize << 20); // no-op if the pool already runs (set again for direct callers)
    let wg = psync::WaitGroup::new();
    wg.add(n as i64);
    let pp = p as *mut loader::Package;
    let want = keep != null;
    for i in 0..n {
        let t = BcTask { p: pp, i: i, out: outs.index_mut(i), want_keep: want };
        let wgc = wg.clone();
        launch || {
            bc_run_one(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    let mut ok = true;
    for i in 0..n {
        let o = outs.index_mut(i);
        if !o.ok {
            ok = false;
        }
        p.lint_errs = p.lint_errs + o.lint;
        if !o.ok {
            o.errors.log();
        }
        if keep != null {
            unsafe (&mut *keep).absorb(&mut o.keep);
        }
    }
    for i in 0..n {
        p.modules[i].ast.ilock_on = false;
    }
    if cirp != null {
        unsafe cirp.elock_on = false;
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
    // The engine's recorded fold failures drain here (lowering-time implicit folds; a node can
    // record more than once across passes, so duplicates collapse).
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
    // Canonical report order (module, then source position): recording order is scheduling order
    // under the parallel stages, and diagnostics must not depend on it.
    let nerr = ms.len();
    for a3 in 1..nerr {
        let mut b3 = a3;
        while b3 > 0 {
            let spb = p.modules[ms[b3] as usize].ast.at_const(ids[b3]).span.start;
            let spa = p.modules[ms[b3 - 1] as usize].ast.at_const(ids[b3 - 1]).span.start;
            if ms[b3] < ms[b3 - 1] || ms[b3] == ms[b3 - 1] && spb < spa {
                let tm = ms[b3];
                ms.set(b3, ms[b3 - 1]);
                ms.set(b3 - 1, tm);
                let ti = ids[b3];
                ids.set(b3, ids[b3 - 1]);
                ids.set(b3 - 1, ti);
                let tk = kinds[b3];
                kinds.set(b3, kinds[b3 - 1]);
                kinds.set(b3 - 1, tk);
                let td = replace(details.index_mut(b3), String::new());
                let td2 = replace(details.index_mut(b3 - 1), td);
                let _ = replace(details.index_mut(b3), td2);
                b3 -= 1;
            } else {
                break;
            }
        }
    }
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

// Global-phase compilation of a loaded package into a `<root>/build/` tree.

/// Drop @platform-gated items that don't match the build target BEFORE resolution, so inactive code is
/// parsed-but-never-resolved and two same-named platform variants collapse to the single active one.
/// target: 0 windows, 1 macos, 2 linux; Attr.arg is the active-set mask (windows=bit0/macos=bit1/linux=bit2).
pub fn platform_filter(p: &mut loader::Package, target: i32) {
    let n = p.modules.len();
    for mi in 0..n {
        platform_filter_module(p, mi, target);
    }
}

/// Filter one module's item list (idempotent): the LSP's incremental rebuild re-filters only the
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
        let id = *m.ast.children.at((items.start + j) as usize);
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
            m.ast.children.set((items.start + w) as usize, id);
            w = w + 1;
        }
    }
    m.ast.at(root).as_data.program.items.len = w;
}

// --lint: unused non-pub items (functions/structs/unions/enums/interfaces/type aliases). Reachability v2:
// entries are top-level items + extend members (disjoint spans; extend HEADERS are deliberately not
// entries, so `extend Foo` alone is not a use of Foo). An item is live iff a root reaches it through the
// resolution graph, so dead cycles and dead-only callers are caught. Roots = everything exempt from
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
    let a = p.module_ast_const(m as ModuleId);
    // Items of a module reported this run are candidates; everything else roots the graph.
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
        // `main` in the root module is the program entry: never reported, always a root.
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

// Whether the binary-project pub lint applies to module `m`: never to the std/ffi trees, which are
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
    // A `@reflect`-tagged declaration is REACHED at startup: its exported descriptor registers
    // itself, and the metadata is the point even when no code names the type.
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
    // One flat reachable-bitset over all modules' node ids.
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
    // Seed roots, then the edge list (src item -> referenced item) from every module's resolution table.
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
        let a = p.module_ast_const(m as ModuleId);
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
            let ta = p.module_ast_const(d.module);
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
            let ta = p.module_ast_const(r.callee.module);
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
        let a = p.module_ast_const(m as ModuleId);
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

fn ap_check_fn(errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId, cev: *mut iri::Interp) {
    if a.at_const(fnode).kind != NodeKind::NODE_FUNCTION || ap_is_test_fn(a, fnode) {
        return;
    }
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
/// gate: the same proof one tier up). A DRIVER phase, after every module has typechecked: the
/// sweep interprets cross-module `const fn` bodies, whose types only exist once their module is
/// typed; an inline per-module pass would silently fold nothing (module order). @test fns are
/// exempt (panicking on purpose is a feature there), as are explicit `panic(..)` calls (only a
/// panic reached THROUGH a `const fn` frame classifies; see Interp::lint_body).
pub fn check_always_panics_module(p: &mut loader::Package, m: usize, errs: &mut diag::Errors) {
    if p.cir == null {
        return;
    }
    ap_check_module_on(p, m, errs, p.cir as *mut iri::Interp);
}

fn ap_check_module_on(p: &mut loader::Package, m: usize, errs: &mut diag::Errors, cev: *mut iri::Interp) {
    if !p.modules[m].has_ast {
        return;
    }
    let a = p.module_ast_const(m as ModuleId);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe a.list(items)[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ms = a.at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                ap_check_fn(errs, a, m, unsafe a.list(ms)[j as usize], cev);
            }
        } else {
            ap_check_fn(errs, a, m, iid, cev);
        }
    }
}

// --lint: functions the deep (all-paths) CTFE scan proves always evaluable; declaring them
// `const fn` passes the def-site check and unlocks folding. `const fn` is a semantic contract
// (folds with known arguments must succeed), so the fix (insert `const ` before the `fn` keyword,
// which lands AFTER any `pub`/`unsafe`, the canonical order) applies only under `--fix`.
// Conformance members are skipped (the interface fixes the signature), as are @test fns and `main`.
// Prelude modules are ALWAYS excluded, even when linted in place: constifying a prelude helper
// promotes failed folds to errors in every downstream program, a blast radius the per-package
// `--fix` fixpoint cannot validate; prelude const adoption must be a deliberate manual change.
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
        // The `fn` keyword sits right before the name, across whitespace.
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
        let a = p.module_ast_const(m as ModuleId);
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
        // Unknowable: keep the import.
        return true;
    }
    let a = p.module_ast_const(mid);
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
                // Extends a foreign (or unresolved) type.
                return true;
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
        let a = p.module_ast_const(m as ModuleId);
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
// non-generic) whose results are dropped computes nothing observable: dead code. The trailing
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
    let fa = p.module_ast_const(fd.module);
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
            // A reference-carrying param could observe or mutate caller state.
            return;
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
        let a = p.module_ast_const(m as ModuleId);
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
        let a = p.module_ast_const(m as ModuleId);
        // Struct-literal initializer names resolve to the field decl but only WRITE it: exclude
        // them from the read set (fields warn on never-READ, Rust semantics).
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
        let a = p.module_ast_const(m as ModuleId);
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

struct ApTask {
    pub p: *mut loader::Package,
    pub outs: *mut diag::Errors,
    pub m: u64,
}

unsafe extend ApTask as Send {}

fn ap_run_one(t: ApTask) {
    // A private engine per task: the scan is a query, and the shared engine's caches must not be
    // contended per interpreted call. Budgets copy from the master so traps classify identically.
    let mut cev = iri::interp_new(t.p);
    {
        let master = (unsafe (&*t.p).cir) as *mut iri::Interp;
        cev.all_typed = true;
        cev.max_steps = unsafe (&*master).max_steps;
        cev.max_slots = unsafe (&*master).max_slots;
    }
    let p = unsafe &mut *t.p;
    let i = t.m as usize;
    ap_check_module_on(p, i, unsafe &mut *(t.outs + i), &mut cev);
}

fn check_always_panics(p: &mut loader::Package, only_mod: i32) {
    let n = p.modules.len();
    if p.jobs != 1 && n > 1 && only_mod < 0 {
        // Per-module tasks: fold failures recorded through the master's lowering callbacks land
        // behind its lock and dedup canonically in report_fold_errs; diagnostics replay in module
        // order below.
        let cirp = p.cir as *mut iri::Interp;
        if cirp != null {
            unsafe cirp.elock_on = true;
        }
        for i in 0..n {
            p.modules[i].ast.ilock_on = true;
        }
        let mut outs = Vector::<diag::Errors>::with_capacity(n);
        for _ in 0..n {
            outs.push(diag::Errors::new());
        }
        prt::set_stack_size(8usize << 20);
        let wg = psync::WaitGroup::new();
        let pp = p as *mut loader::Package;
        let ob = outs.index_mut(0) as *mut diag::Errors;
        let mut launched: i64 = 0;
        for m in 0..n {
            if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
                continue;
            }
            wg.add(1);
            launched += 1;
            let t = ApTask { p: pp, outs: ob, m: m as u64 };
            let wgc = wg.clone();
            launch || {
                ap_run_one(t);
                wgc.done();
            };
        }
        if launched != 0 {
            wg.wait_masked();
        }
        for i in 0..n {
            p.modules[i].ast.ilock_on = false;
        }
        if cirp != null {
            unsafe cirp.elock_on = false;
        }
        for m in 0..n {
            let errs = outs.index_mut(m);
            if errs.errors.len() != 0 {
                p.ok = false;
                errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
                errs.log();
            }
        }
        return;
    }
    for m in 0..n {
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
/// `lint_mod` only, or, when `p.lint_set` is non-empty, for every module in that mask (the batch
/// driver loads all listed files into ONE package; each module still warns exactly once), then the
/// report-only passes restricted to the same set. No code is emitted. Returns 0 only when clean; any
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
    let rc0 = lint_package_i(p, target, lint_mod, fixes, ftexts, suggest_const);
    if p.jobs != 1 {
        prt::shutdown(); // early-error net, same as run_package
    }
    return rc0;
}

fn lint_package_i(
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
    if p.jobs != 1 {
        prt::shutdown();
    }
    if !p.ok {
        return 1;
    }
    if facts_verify(p, &wms, "borrowck") != 0 {
        return 1;
    }
    layout_pass(p);
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

/// Then codegen of the live modules (headers first, then sources across `jobs` forked workers),
/// pruning stale outputs afterwards. A non-empty `out_bin` also compiles + links the program there
/// (`build`); `topts.enabled` synthesizes the test runner and, without a `sink`, builds and runs it
/// too. `sink` (may be null) hears about every finished output file, which is what lets the build
/// engine compile a TU while later ones are still being emitted; the engine then owns the runner's
/// compile, link and launch. `jobs` 0 means the online core count. Returns the
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
    let rc0 = run_package_i(p, topts, out_bin, target, lint, cflags, sink);
    // Safety net for every early-error return: parallel loading may have started the pool, and
    // the leak gate (and any later fork) needs it gone; shutdown is idempotent.
    if p.jobs != 1 {
        prt::shutdown();
    }
    return rc0;
}

fn run_package_i(
    p: &mut loader::Package,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    lint: bool,
    cflags: str,
    sink: *mut EmitSink,
) i32 {
    let tstat = stdlib::getenv("SC_CEMIT_STATS") != null;
    let mut tp0 = unsafe shim::sc_ticks_ms();
    platform_filter(p, target);
    let n = p.modules.len();
    if p.jobs != 1 && n > 1 {
        resolve_all_par(p, lint);
    } else {
        for i in 0..n {
            let ok = resolve_module(p, i, lint && !p.modules[i].prelude, null);
            p.ok = ok && p.ok;
        }
    }
    if !p.ok {
        return 1;
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase resolve: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    if p.jobs != 1 && n > 1 {
        p.ok = typecheck_all_par(p, lint) && p.ok;
    } else {
        for i in 0..n {
            let ok = typecheck_module(p, i, lint && !p.modules[i].prelude, null, null);
            p.ok = ok && p.ok;
        }
    }
    if p.ok {
        discharge_obligations(p, n, p.jobs != 1 && n > 1);
    }
    if !p.ok {
        return 1;
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase typecheck: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
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
    // Release the pool as soon as the one parallel stage is done: the test runner FORKS after
    // this, and a forked child inherits the pool's state but none of its worker threads. (Also
    // what keeps the leak gate green.)
    if p.jobs != 1 {
        prt::shutdown();
    }
    if !p.ok {
        return 1;
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase borrowck: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    if facts_verify(p, &wms, "borrowck") != 0 {
        return 1;
    }
    layout_pass(p);
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase verify+layout: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    if lint {
        lint_unused_items(p, -1);
    }
    // The static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let cirf = p.cir as *mut iri::Interp;
    if cirf != null {
        let pv = p as *mut loader::Package;
        unsafe cirf.all_typed = true;
        // An ERROR, not a lint: it runs on every build (user modules; std is gated by check.sh's
        // explicit std lint invocations).
        check_always_panics(p, -1);
        if tstat {
            let t9 = unsafe shim::sc_ticks_ms();
            eprint("phase panics: {} ms\n", t9 - tp0);
            tp0 = t9;
        }
        cirf.flush_asserts(flush_assert_err, pv);
        cirf.flush_consts(flush_const_err, pv);
    }
    if !p.ok {
        return 1;
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase lint+panics: {} ms\n", t9 - tp0);
        tp0 = t9;
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
    // Self-contained: carries its own includes.
    sink_notify(sink, keep.at(1).as_str(), 1);
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
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase rt+ext: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    let live = compute_emit_live(p);
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase live: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    let mut order = Vector::<ModuleId>::new();
    p.emit_order(&mut order);
    // The whole-package Core-IR emission runs BEFORE the live-module list: it seeds every module
    // unconditionally, so any module with a non-empty TU must be written even when the reference
    // scan finds no direct use (prelude bodies the instance TU calls into).
    let mut co = CemitOut::new(n);
    {
        let cirg = p.cir as *mut iri::Interp;
        if cirg != null {
            // The seed/instance lowering attempts mandatory folds.
            unsafe cirg.record_folds = true;
        }
    }
    if tstat {
        let t9 = unsafe shim::sc_ticks_ms();
        eprint("phase mid: {} ms\n", t9 - tp0);
        tp0 = t9;
    }
    cemit_package(p, testing, &plan, live.as_ptr(), target, &mut co, &mut irkeep);
    // The emission frontier restarted the pool; release it again before any test-runner fork.
    if p.jobs != 1 {
        prt::shutdown();
    }
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
    // Transitive TU pruning: keep scan-live modules, then everything a KEPT TU (or the always-
    // written instance TU) spells symbols from; dead prelude chains drop out entirely.
    let mut keep_mod = Vector::<bool>::new();
    for mi9 in 0..n {
        keep_mod.push(live[mi9]);
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
        let mi = order[oi];
        let has_wrap = co.have_main && !testing && mi as u64 == co.main_mod;
        if co.tus.at(mi as usize).len() == 0 && !has_wrap {
            continue;
        }
        if !live[mi as usize] && !*keep_mod.at(mi as usize) {
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
    let tw0 = unsafe shim::sc_ticks_ms();
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
            let ex = co.tu_extra.at(lm[k] as usize);
            for x in 0..ex.len() {
                let mut stem = String::from_str(p.modules[lm[k] as usize].path.as_str());
                stem.push_str("__p");
                stem.push_u64(x as u64 + 1);
                let xp = build_out_path(root, stem.as_str(), ".c");
                let mut sx = String::new();
                cemit_shared_incs(p.modules[lm[k] as usize].path.as_str(), &mut sx);
                sx.push_string(ex.at(x));
                if !cemit_write(xp.as_str(), &sx) {
                    err = true;
                }
                sink_notify(sink, xp.as_str(), 1);
                keep.push(xp);
            }
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
            for x in 0..co.inst_extra.len() {
                let mut stem = String::from_str("__sc_inst__p");
                stem.push_u64(x as u64 + 1);
                let xp = build_out_path(root, stem.as_str(), ".c");
                let mut ix = String::from_str("#include \"__sc_types.h\"\n#include \"__sc_protos.h\"\n");
                ix.push_string(co.inst_extra.at(x));
                if !cemit_write(xp.as_str(), &ix) {
                    err = true;
                }
                sink_notify(sink, xp.as_str(), 1);
                keep.push(xp);
            }
        }
    }
    if stdlib::getenv("SC_CEMIT_STATS") != null {
        eprint("cemit-stage write: {} ms\n", unsafe shim::sc_ticks_ms() - tw0);
    }
    // Publish the per-TU cache only after a fully successful emission; keep[] shields it from pruning.
    if !err && co.skips == 0 && co.tuc_path.len() != 0 {
        if cemit_write(co.tuc_path.as_str(), &co.tuc_img) {
            keep.push(String::from_str(co.tuc_path.as_str()));
        }
    }
    // Drop outputs of an earlier build that this program does not emit, so the tree matches the current
    // sources. Skip on a keep-list OOM: never risk deleting a live output.
    let mut broot = PathBuf {};
    // Root is a str view (not nul-terminated); bound the copy with %.*s or %s runs off the buffer end.
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
                    if sink == null {
                        rc = test_build_and_run(p, topts, &keep, "", cflags, target);
                    }
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
