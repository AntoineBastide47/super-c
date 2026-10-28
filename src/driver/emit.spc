// Global-phase pipeline driver over a loaded Package: platform-filters items, runs resolve/typecheck/
// borrowck per module (each stage mutates the module's Ast in place through a raw pointer into its
// Package slot), flushes deferred const-eval errors, then prunes dead modules from
// the emit set and codegens each live module into <gen_root> in dependency order. Entry points:
// run_package (build/run/test) and lint_package (report-only lints + `--fix` fix collection).
import stdio;
import stdlib;
import std::platform::fs;
import std::platform::process;
import graph::items as gitems;
import driver::stats as bst;
import lexer::token as tok;
import ast::ast as *;
import ast::facts as facts;
import module::loader as loader;
import resolver::resolver as resolver;
import hir::lower as hirl;
import target::table as tgt;
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
import ir::tailcall as irt;
import ir::bce as bce;
import ir::inline as inl;
import ir::interp as iri;
import ir::recursion as recur;
import ir::layout as lay;
import ir::cpu_features as cf;
import emit::cemit as cbe;
import lir::lower as lw;
import lir::ir as lir_ir;
import lir::print as lprint;
import lir::parse as lparse;
import lir::opt as lopt;
import lir::inline as il;
import lir::loops as lu;
import lir::hold as lhold;
import target::native as nat;
import bindgen::bindgen as bg;
import bindgen::ctarget as ct;
import build_system::manifest as bman;
import build_system::objcache as ocache;
import emit::cflow as cfl;
import emit::probe as prb;
import emit::mangle as mbe;
import emit::simd_plan as sp;
import emit::tu as tbe;
import graph::instances as ig;
import borrowck::move_paths as bmp;
import borrowck::facts as bfx;
import borrowck::dataflow as bdf;
import utils::errors as diag;
import driver::tuc as tuc;
import driver::taskctl as tctl;
import driver::sched as sch;
import driver::prelude_image as pimg;
import atomic;
import driver::util as *;

import driver::extc as *;
import driver::test as *;
import utils::diag_codes as dc;
import build_system::ext as ext;

extern "C" {
    fn memchr(s: *const void, c: i32, n: usize) *mut void;
}

// The instance drain's bound on demand-queue entries: a program over it is a runaway instantiation.
const DEMAND_CAP: usize = 200000;

// Dead-module pruning of the emit set: a live module reaches its own decls + everything it references.
// `row` is one module's edge bit row.
const fn mark_live(row: *mut u64, n: usize, m: ModuleId) {
    if m as usize < n {
        unsafe row[m as usize / 64] |= 1u64 << (m as u64 & 63);
    }
}

fn ast_type_mentions_builtin(p: &loader::Package, am: ModuleId, t: TypeId) bool {
    if t == TYPE_NONE {
        return false;
    }
    let y = *unsafe (*p.module_ast_const(am)).type_at(t);
    if y.kind == TypeKind::TYPE_BUILTIN {
        return true;
    }
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        return ast_type_mentions_builtin(p, am, y.as_data.elem);
    }
    if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *unsafe (*p.module_ast_const(am)).instance(y.as_data.inst);
        for i in 0..it.n {
            if ast_type_mentions_builtin(p, am, unsafe it.args[i as usize]) {
                return true;
            }
        }
        return false;
    }
    return false;
}

fn mark_type_modules(p: &loader::Package, am: ModuleId, t: TypeId, row: *mut u64) {
    if t == TYPE_NONE {
        return;
    }
    let y = *unsafe (*p.module_ast_const(am)).type_at(t);
    if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.kind == TypeKind::TYPE_ARRAY {
        mark_type_modules(p, am, y.as_data.elem, row);
    } else if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_FUNCTION && !y.fn_sig() {
        if p.builtin_of_decl(y.module, y.as_data.decl) < 0 {
            mark_live(row, p.modules.len(), y.module);
        }
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *unsafe (*p.module_ast_const(am)).instance(y.as_data.inst);
        let np = p.modules.len();
        mark_live(row, np, it.module);
        mark_live(row, np, p.instance_home_in(am, &it));
        for i in 0..it.n {
            mark_type_modules(p, am, unsafe it.args[i as usize], row);
            if p.core_seeded && ast_type_mentions_builtin(p, am, unsafe it.args[i as usize]) {
                mark_live(row, np, p.core_module);
            }
        }
    }
}

// The modules each final type id keeps live, for every module that names it: `mark_type_modules`, and
// with `core` set the core module too when the type mentions a builtin (`mono_live_arg`). One row of
// `w` words per id, filled before the rows read it.
struct TypeMarks {
    pub(package) w: usize,
    pub(package) rows: Vector<u64>,
    pub(package) state: Vector<u8>, // per id: TM_UNSET, TM_SET, or TM_CORE (the type mentions a builtin)
}

const TM_UNSET: u8 = 0;
const TM_SET: u8 = 1;
const TM_CORE: u8 = 2;

extend TypeMarks {
    // Fill the row of type `t` named in module `am`, once; a provisional id (a module's own) has none.
    fn fill(self: &mut Self, p: &loader::Package, am: ModuleId, t: TypeId) {
        if t == TYPE_NONE || (t & TYPE_PROV) != 0 || self.state[t as usize] != TM_UNSET {
            return;
        }
        mark_type_modules(p, am, t, unsafe (self.rows.as_ptr() as *mut u64 + t as usize * self.w));
        self.state.set(t as usize, pick(ast_type_mentions_builtin(p, am, t), TM_CORE, TM_SET));
    }

    // Mark what type `t` of module `am` keeps live in `row`.
    fn mark(self: &Self, p: &loader::Package, am: ModuleId, t: TypeId, core: bool, row: *mut u64) {
        if t == TYPE_NONE {
            return;
        }
        if (t & TYPE_PROV) != 0 {
            if core {
                mono_live_arg(p, am as usize, t, row);
            } else {
                mark_type_modules(p, am, t, row);
            }
            return;
        }
        let r0 = t as usize * self.w;
        for k in 0..self.w {
            unsafe row[k] |= self.rows[r0 + k];
        }
        if core && p.core_seeded && self.state[t as usize] == TM_CORE {
            mark_live(row, p.modules.len(), p.core_module);
        }
    }
}

// Fill the rows of every type module `m` names (`TypeMarks`).
fn type_marks_fill(p: &loader::Package, m: usize, tm: &mut TypeMarks) {
    let a = p.module_ast_const(m as ModuleId);
    for ti in 0..unsafe (*a).ntypes() {
        tm.fill(p, m as ModuleId, unsafe (*a).used_type(ti));
    }
    for ii in 0..unsafe (*a).ninstances() {
        let it = *unsafe (*a).used_instance(ii);
        for k in 0..it.n {
            tm.fill(p, m as ModuleId, unsafe it.args[k as usize]);
        }
    }
    for moi in 0..unsafe (*a).mono.len() {
        let mu = unsafe (*a).mono[moi];
        for k in 0..mu.n {
            tm.fill(p, m as ModuleId, unsafe mu.args[k as usize]);
        }
    }
    for k in 0..unsafe (*a).mono_live.len() {
        tm.fill(p, m as ModuleId, unsafe (*a).mono_live[k]);
    }
}

// One module's outgoing liveness edges, written as a bit row. Pure reads of frozen pools and of the
// filled type rows, so the rows compute in parallel; the closure walk over them is order-insensitive
// (a set union).
fn emit_live_row(p: &loader::Package, tm: &TypeMarks, m: usize, row: *mut u64) {
    let n = p.modules.len();
    let a = p.module_ast_const(m as ModuleId);
    // The module arena's resolutions (declarations, signatures, constants, pinned bodies, import
    // paths), then the item index's dependency edges for the releasable bodies, whose syntax is
    // freed after the borrow pass.
    let nr = unsafe (*a).nodes.len();
    for r in 0..nr {
        let d = unsafe (*a).resolution_def(r as NodeId);
        if d.node != NODE_NONE && d.module as usize < n && d.module as usize != m && p.builtin_of_decl(d.module, d.node) < 0 {
            mark_live(row, n, d.module);
        }
    }
    assert(p.sched.final_edges, "the post-typecheck item edges precede emission liveness");
    let i0 = p.idx.mod_items[m] as usize;
    let i1 = p.idx.mod_items[m + 1] as usize;
    for it in i0..i1 {
        for e in p.sched.fin_off[it] as usize..p.sched.fin_off[it + 1] as usize {
            let tm9 = p.idx.items.at(p.sched.fin_edges[e] as usize);
            if tm9.module as usize != m && p.builtin_of_decl(tm9.module, tm9.node) < 0 {
                mark_live(row, n, tm9.module);
            }
        }
    }
    // The runtime names no prelude item (`std/rt/base.spc`): the one prelude type it touches is `str`, of
    // its literals, which lower to C strings. Its type marks would emit the prelude into every program.
    let nt = pick(m as i32 == p.rt_module, 0, unsafe (*a).ntypes());
    for ti in 0..nt {
        tm.mark(p, m as ModuleId, unsafe (*a).used_type(ti), false, row);
    }
    let ni = unsafe (*a).ninstances();
    for ii in 0..ni {
        let it = *unsafe (*a).used_instance(ii);
        mark_live(row, n, it.module);
        mark_live(row, n, p.instance_home_in(m as ModuleId, &it));
        for k in 0..it.n {
            tm.mark(p, m as ModuleId, unsafe it.args[k as usize], true, row);
        }
    }
    let nmo = unsafe (*a).mono.len();
    for moi in 0..nmo {
        let mu = unsafe (*a).mono[moi];
        for k in 0..mu.n {
            tm.mark(p, m as ModuleId, unsafe mu.args[k as usize], true, row);
        }
    }
    // The body-arena entries freed with the bodies leave their distinct type arguments.
    for k in 0..unsafe (*a).mono_live.len() {
        tm.mark(p, m as ModuleId, unsafe (*a).mono_live[k], true, row);
    }
}

// The modules type argument `t` of a recorded instantiation in module `m` keeps live.
fn mono_live_arg(p: &loader::Package, m: usize, t: TypeId, row: *mut u64) {
    mark_type_modules(p, m as ModuleId, t, row);
    if p.core_seeded && ast_type_mentions_builtin(p, m as ModuleId, t) {
        mark_live(row, p.modules.len(), p.core_module);
    }
}

// `p` and `tm` are opaque so the release bootstrap's borrow checker accepts the payload as 'static.
struct LiveTask {
    pub(package) p: *const void,
    pub(package) tm: *const void,
    pub(package) row: *mut u64,
    pub(package) m: u64,
}

// Tasks only read the frozen package and the filled type rows, and write disjoint rows.
unsafe extend LiveTask as Send {}

/// Whether module `m` holds a module-level `asm` the platform filter kept.
fn module_has_asm(p: &loader::Package, m: usize) bool {
    if !p.modules[m].has_ast || p.modules[m].backend {
        return false;
    }
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let its = a.at_const(a.root).as_data.program.items;
    for i in 0..its.len {
        if a.at_const(unsafe a.list(its)[i as usize]).kind == NodeKind::NODE_ASM {
            return true;
        }
    }
    return false;
}

// The text of module `m`'s module-level assembly the platform filter kept, its statements in source
// order (one unit, as the C path's).
fn module_asm(p: &loader::Package, m: usize) String {
    let mut out = String::new();
    if !p.modules[m].has_ast || p.modules[m].backend {
        return out;
    }
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let its = a.at_const(a.root).as_data.program.items;
    for i in 0..its.len {
        let it = unsafe a.list(its)[i as usize];
        if a.at_const(it).kind != NodeKind::NODE_ASM {
            continue;
        }
        let sp = a.at_const(a.ext(it).asm_stmt.template).as_data.literal.raw;
        cbe::asm_bytes(p.modules[m].source.as_str().slice(sp.start as usize, sp.end as usize), &mut out);
        out.push_byte(b'\n');
    }
    return out;
}

fn compute_emit_live(p: &loader::Package) Vector<bool> {
    let n = p.modules.len();
    let sz = if n != 0 {
        n;
    } else {
        1 as usize;
    };
    let mut live = Vector::<bool>::new();
    live.resize_default(sz);
    // The backend file emits no unit (`module_emits`): what it alone imports or names stays dead
    // until live code names it. `by`: 1 imported by the backend file, 2 by another module.
    let mut by = Vector::<u8>::new();
    by.resize_default(sz);
    for x in 0..n {
        for e in p.idx.mod_imports[x]..p.idx.mod_imports[x + 1] {
            let d = p.idx.imports[e as usize] as usize;
            by[d] |= pick(p.modules[x].backend, 1u8, 2u8);
        }
    }
    for i in 0..n {
        if !p.modules[i].prelude && !p.modules[i].backend && by[i] != 1 {
            live[i] = true;
        }
    }
    let w = (n + 63) / 64;
    let ntt = p.tt.deref().len();
    let mut tm = TypeMarks { w: w, rows: Vector::<u64>::new(), state: Vector::<u8>::new() };
    tm.rows.resize_default(ntt * w);
    tm.state.resize_default(ntt);
    for m in 0..n {
        if p.modules[m].has_ast {
            type_marks_fill(p, m, &mut tm);
        }
    }
    let mut rows = Vector::<u64>::new();
    rows.resize_default(sz * w);
    if p.jobs != 1 && n > 1 {
        let wg = psync::WaitGroup::new();
        let pv = (p as *const loader::Package) as *const void;
        let tv = ((&tm) as *const TypeMarks) as *const void;
        for m in 0..n {
            if !p.modules[m].has_ast {
                continue;
            }
            wg.add(1);
            let t = LiveTask { p: pv, tm: tv, row: unsafe (rows.as_ptr() as *mut u64 + m * w), m: m as u64 };
            let wgc = wg.clone();
            launch || {
                emit_live_row(
                    unsafe &*(t.p as *const loader::Package),
                    unsafe &*(t.tm as *const TypeMarks),
                    t.m as usize,
                    t.row,
                );
                wgc.done();
            };
        }
        wg.wait_masked();
    } else {
        for m in 0..n {
            if p.modules[m].has_ast {
                emit_live_row(p, &tm, m, unsafe (rows.as_ptr() as *mut u64 + m * w));
            }
        }
    }
    // The closure: a module enters the stack once, when it turns live.
    let mut stack = Vector::<usize>::with_capacity(n);
    for m in 0..n {
        if live[m] {
            stack.push(m);
        }
    }
    while let Some(m) = stack.pop() {
        if !p.modules[m].has_ast {
            continue;
        }
        for k in 0..w {
            let mut b = rows[m * w + k];
            while b != 0 {
                let d = k * 64 + b.trailing_zeros();
                b &= b - 1;
                if !live[d] {
                    live[d] = true;
                    stack.push(d);
                }
            }
        }
    }
    return live;
}

// Whether module `m` emits a unit: it has an AST, is not an unreachable prelude module (`live`), and
// is not the vector backend file, whose entries render apart (`cemit_simd_entries`).
// The module whose files hold module `m`'s definitions: the core module for the backend file, which
// emits no unit of its own.
const fn emit_owner(p: &loader::Package, m: ModuleId) ModuleId {
    return pick(p.modules[m as usize].backend, p.core_module, m);
}

const fn module_emits(p: &loader::Package, live: *const bool, m: usize) bool {
    return p.modules[m].has_ast && !(live != null && p.modules[m].prelude && !unsafe live[m]) && !p.modules[m].backend;
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
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, unsafe str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    r.resolve();
    let had = r.has_errors();
    if had || fixes == null && r.errors.has_warnings() {
        r.log_errors();
    }
    p.lint_warnings = p.lint_warnings + r.errors.warns.len() as u32;
    if fixes != null {
        for k in 0..r.errors.fixes.len() {
            let mut f = r.errors.fixes[k];
            f.module = i as u32;
            unsafe (*fixes).push(f);
        }
    }
    hirl::lower_module(p, i);
    return !had;
}

// Cross-module reflection-bound obligations: discharged once every module is typechecked, so a
// callee's obligations exist regardless of check order (module order follows imports, not calls).
fn discharge_obligations(p: &mut loader::Package, n: usize, dup_done: bool, dup_idx: &Map<tc::ConfKey, u64>) {
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
        let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
        t.check_cross_module_dup_conformances(dup_idx);
        t.check_cross_module_dup_items();
        if t.has_errors() {
            t.errors.finalize(unsafe str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
            t.log_errors();
            p.ok = false;
        }
    }
    // Pass k proves what pass k-1's re-deferrals made provable; the per-module cursors keep any
    // obligation from being run against a caller module twice. A pass that adds no obligation ends
    // the loop: every other pass adds at least one, a module never holds the same one twice, and a
    // module past tc::PROJ_OBS_MAX of them is an error, so the loop ends.
    let mut starts = Vector::<u32>::new();
    starts.resize_default(n);
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
            let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
            if t.discharge_foreign_obligations(starts.as_ptr()) {
                grew = true;
            }
            t.discharge_conformance_obligations(starts.as_ptr(), ends.as_ptr());
            if t.has_errors() {
                t.errors.finalize(unsafe str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
                t.log_errors();
                p.ok = false;
            }
        }

        starts = ends;
        if !grew || !p.ok {
            break;
        }
    }
    // Every obligation list is complete: run the default-method instances the calls demand.
    for i in 0..pick(p.ok, n, 0) {
        let pkg = p as *mut loader::Package;
        let m = &mut p.modules[i];
        if (unsafe m.ast.dmd_uses).len() == 0 {
            continue;
        }
        let src = m.source.as_str().ptr() as *const char;
        let len = m.source.len();
        let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
        t.run_dmd_uses();
        if t.has_errors() {
            t.errors.finalize(unsafe str::from_raw(src as *const u8, len), p.modules[i].file.as_str());
            t.log_errors();
            p.ok = false;
        }
    }
}

struct RsOut {
    pub(package) ok: bool,
    pub(package) warns: u32,
    pub(package) errors: diag::Errors,
    pub(package) edges: Vector<u64>, // the module's item dependency edges (graph::items)
}

struct RsTask {
    pub(package) p: *mut loader::Package,
    pub(package) outs: *mut RsOut,
    pub(package) m: u64,
    pub(package) lint: bool,
    pub(package) spans: *const Vector<gitems::Spans>, // every module's declaration spans, read-only
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
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, unsafe str::from_raw(src as *const u8, len), pkg);
    r.lint = t.lint && lint_reported(p, i, -1);
    r.resolve();
    out.ok = !r.has_errors();
    out.warns = r.errors.warns.len() as u32;
    out.errors = replace(&mut r.errors, diag::Errors::new());
    hirl::lower_module(p, i);
    gitems::module_edges(unsafe &*t.p, i, unsafe &*t.spans, &mut (&mut *out).edges);
    gitems::builtin_edges(unsafe &*t.p, i, unsafe &*t.spans, &mut (&mut *out).edges);
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
        p.modules[i].ast.freeze_nodes();
    }
    let mut outs = Vector::<RsOut>::with_capacity(n);
    for _ in 0..n {
        outs.push(RsOut { ok: true, warns: 0, errors: diag::Errors::new(), edges: Vector::<u64>::new() });
    }
    prt::set_stack_size(8usize << 20); // the resolver's expression recursion outgrows the default task stack
    gitems::open(p);
    let spans = gitems::spans_all(p);
    let pp = p as *mut loader::Package;
    let ob = outs.index_mut(0) as *mut RsOut;
    let wg = psync::WaitGroup::new();
    let from = p.root_module as usize; // the prelude stage resolved the modules before it
    for i in from..n {
        wg.add(1);
        let t = RsTask { p: pp, outs: ob, m: i as u64, lint: lint, spans: &spans };
        let wgc = wg.clone();
        launch || {
            rs_run_one(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    for i in 0..n {
        p.modules[i].ast.thaw_nodes(); // all four arrays: a body arena a lowering spilled into included
    }
    let mut edges = replace(&mut p.carry.rs_edges, Vector::<u64>::new());
    for i in from..n {
        let o = outs.index_mut(i);
        if !o.ok || o.errors.has_warnings() {
            o.errors.log();
        }
        p.lint_warnings = p.lint_warnings + o.warns;
        p.ok = o.ok && p.ok;
        for k in 0..o.edges.len() {
            edges.push(o.edges[k]);
        }
    }
    gitems::build(p, &edges);
    if p.carry.keep {
        p.carry.rs_edges = edges;
    }
}

// ---- The type check stage -------------------------------------------------------------------
// One job per component of the item schedule graph (`ItemSched.comp`), started by the
// completion of its last dependency (`driver::sched`); every prelude component completes
// before any non-prelude one starts (prelude items are visible to every item). A job checks
// its component's top-level items in index order under the module's lease: one checker per
// module, so the module's side tables have one writer at a time, and the same checker serves
// every item of the module until its last one closes it. Diagnostics and method marks come out
// per item and publish in item order, so no worker order enters the output.

/// Per-item outputs: the item's diagnostics in emission order, and its range in the module's
/// method-mark log (`TcStage.logs`: one log per module, its entries in check order).
struct TcOut {
    pub(package) errors: Option<Box<diag::Errors>>,
    pub(package) log_lo: u32,
    pub(package) log_hi: u32,
}

// One item's diagnostics as its result slot: the checker's buffer moves out only when it holds
// something, so the many silent items keep no buffer of their own.
fn take_errs(e: &mut diag::Errors) Option<Box<diag::Errors>> {
    if e.errors.len() == 0 && e.warns.len() == 0 && e.fixes.len() == 0 {
        return Option::<Box<diag::Errors>>::None;
    }
    return Option::<Box<diag::Errors>>::Some(Box::new(replace(e, diag::Errors::new())));
}

// Move a result slot's diagnostics, if any, into `dst`.
fn append_errs(dst: &mut diag::Errors, slot: &mut Option<Box<diag::Errors>>) {
    switch slot.take() {
        Some(b) => {
            let mut e = b;
            dst.append(e.deref_mut());
        },
        None => {},
    };
}

struct TcStage {
    pub(package) p: *mut loader::Package,
    pub(package) outs: *mut TcOut, // per item
    pub(package) logs: *mut tc::TcMarkLog, // per module
    pub(package) tail: *mut diag::Errors, // per module: the close step's diagnostics (the whole-module lints)
    pub(package) orphans: *mut Vector<diag::Errors>, // per module: the non-item nodes' diagnostics, declaration order
    pub(package) chk: *mut Vector<Box<tc::TypeChecker>>, // per module: its checker while it has items left (one at most)
    pub(package) lease: *mut psync::Mutex<u8>, // per module: one job checks a module at a time
    pub(package) left: *mut u32, // per module: top-level items not yet checked (atomic)
    pub(package) edges: *mut Vector<u64>, // per module: the post-typecheck item edges, written at its close
    pub(package) spans: *const Vector<gitems::Spans>,
    pub(package) lint: *const bool, // per module
}

// One component: its top-level items in index order (members go with their extend).
fn tc_job(ctx: *mut void, j: u32) {
    let st = unsafe &*(ctx as *const TcStage);
    let p = unsafe &mut *st.p;
    if j as usize >= p.sched.ncomp as usize {
        // The prelude gate: every prelude item and every item they depend on is typed and no other
        // item has started, so the prelude's types publish here (no reader, no writer: the gate's
        // job alone runs). Every later checker then takes a prelude declaration's type from the owner's record (a final
        // id, the same in every module) instead of lowering its syntax again.
        let tg0 = ticks_ms();
        publish_checkpoint(p, null);
        if stdlib::getenv("SC_CEMIT_STATS") != null {
            eprint("typecheck-stage gate publication: {} ms\n", ticks_ms() - tg0);
        }
        return;
    }
    for k in p.sched.citem_off[j as usize] as usize..p.sched.citem_off[j as usize + 1] as usize {
        let it = p.sched.citem[k];
        let meta = *p.idx.items.at(it as usize);
        // A member goes with its extend; the prelude stage checked the items before `root_module`.
        if meta.owner != loader::ITEM_NONE || meta.module as u32 < p.root_module {
            continue;
        }
        if p.jobs != 1 {
            let _g = (unsafe &*(st.lease + meta.module as usize)).lock();
            let a = (&mut p.modules[meta.module as usize].ast) as *mut Ast;
            unsafe (*a).wl_enter();
            tc_item(st, it, meta);
            unsafe (*a).wl_leave();
        } else {
            tc_item(st, it, meta);
        }
    }
}

fn tc_item(st: &TcStage, it: loader::ItemId, meta: loader::ItemMeta) {
    let p = unsafe &mut *st.p;
    let m = meta.module as usize;
    let chk = unsafe &mut *(st.chk + m);
    if chk.len() == 0 {
        let pkg = st.p;
        let mm = &mut p.modules[m];
        let src = mm.source.as_str().ptr() as *const char;
        let len = mm.source.len();
        let mut t = tc::TypeChecker::new(&mut mm.ast, unsafe str::from_raw(src as *const u8, len), pkg);
        t.lint = unsafe st.lint[m];
        t.check_open();
        chk.push(Box::new(t));
    }
    let tck = chk.index_mut(0).deref_mut();
    let out = unsafe &mut *(st.outs + it as usize);
    let lg = unsafe (st.logs + m);
    tck.mark_log = lg;
    out.log_lo = (unsafe (&*lg).kinds.len()) as u32;
    tck.check_one(meta.node, p.sched.top_lo[it as usize]);
    out.log_hi = (unsafe (&*lg).kinds.len()) as u32;
    out.errors = take_errs(&mut tck.errors);
    tck.mark_log = null;
    if unsafe atomic::sub_u32(unsafe (st.left + m), 1, 3) != 1 {
        return;
    }
    // The module's last item: close it (the whole-module lints), record the result-attributability
    // verdicts and the post-typecheck item edges (the lint and the emission liveness read them)
    // while its body syntax is live, and free its checker.
    tck.check_orphans();
    tck.check_close();
    tck.share_last_use();
    *unsafe &mut *(st.tail + m) = replace(&mut tck.errors, diag::Errors::new());
    *unsafe &mut *(st.orphans + m) = replace(&mut tck.orphan_errs, Vector::<diag::Errors>::new());
    tck.bc_record_ret_attr();
    gitems::module_edges(unsafe &*st.p, m, unsafe &*st.spans, unsafe &mut *(st.edges + m));
    chk.clear();
}

// The serial order of the components, module-major: the modules by import level (prelude
// modules first, a module after the modules it imports, ties by id), each module's components
// in item order with their unfinished dependencies before them (a depth-first walk, every
// component once). A module's checker then lives from its first item to its last with as few
// other modules open as the dependencies allow.
fn tc_order(p: &loader::Package, order: &mut Vector<u32>) {
    let s = &p.sched;
    let nc = s.ncomp as usize;
    let nm = p.modules.len();
    let mut lvl = Vector::<u32>::new();
    gitems::import_levels(p, false, &mut lvl);
    let mut mods = Vector::<u64>::with_capacity(nm);
    for m in 0..nm {
        mods.push(lvl[p.idx.scc_of[m] as usize] as u64 << 32 | m as u64);
    }
    mods.sort();
    let mut done = Vector::<bool>::new();
    done.resize_default(nc);
    let mut stack = Vector::<u32>::new(); // (component, next dependency) pairs
    for pass in 0..2 {
        for mi in 0..nm {
            let m = (mods[mi] & 0xFFFFFFFFu64) as usize;
            if p.modules.at(m).prelude != (pass == 0) {
                continue;
            }
            for it in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
                let root = s.comp[it] as usize;
                if done[root] {
                    continue;
                }
                done.set(root, true);
                stack.push(root as u32);
                stack.push(s.cdep_off[root]);
                for _ in 0..2 * s.cdep.len() + 2 * nc + 2 {
                    if stack.len() == 0 {
                        break;
                    }
                    let v = stack[stack.len() - 2] as usize;
                    let e = stack[stack.len() - 1];
                    if e < s.cdep_off[v + 1] {
                        stack.set(stack.len() - 1, e + 1);
                        let d = s.cdep[e as usize] as usize;
                        if !done[d] {
                            done.set(d, true);
                            stack.push(d as u32);
                            stack.push(s.cdep_off[d]);
                        }
                        continue;
                    }
                    order.push(v as u32);
                    stack.truncate(stack.len() - 2);
                }
            }
        }
        if pass == 0 {
            order.push(nc as u32); // the prelude gate
        }
    }
}

// The job graph over the components: their dependency graph plus the prelude gate (a virtual
// job after every prelude component and before every other one).
fn tc_jobs(p: &loader::Package) sch::Jobs {
    let s = &p.sched;
    let nc = s.ncomp as usize;
    let gate = nc as u64;
    // The components the gate waits for: the prelude's, and every component they depend on (a module
    // a prelude file imports), as `tc_order` places them before the gate.
    let mut pre = Vector::<bool>::new();
    pre.resize_default(nc);
    let mut stack = Vector::<u32>::new();
    for c in 0..nc {
        let first = s.citem[s.citem_off[c] as usize];
        if p.modules.at(p.idx.items.at(first as usize).module as usize).prelude {
            pre.set(c, true);
            stack.push(c as u32);
        }
    }
    // Each component enters the stack once.
    for _ in 0..nc {
        if stack.len() == 0 {
            break;
        }
        let c = stack.pop().unwrap() as usize;
        for e in s.cdep_off[c] as usize..s.cdep_off[c + 1] as usize {
            let d = s.cdep[e] as usize;
            if !pre[d] {
                pre.set(d, true);
                stack.push(d as u32);
            }
        }
    }
    let mut edges = Vector::<u64>::new();
    for c in 0..nc {
        for e in s.cdep_off[c] as usize..s.cdep_off[c + 1] as usize {
            edges.push(s.cdep[e] as u64 << 32 | c as u64);
        }
        if pre[c] {
            edges.push(c as u64 << 32 | gate);
        } else {
            edges.push(gate << 32 | c as u64);
        }
    }
    let mut order = Vector::<u32>::with_capacity(nc + 1);
    tc_order(p, &mut order);
    if p.icost_on {
        // The measurement: how many module checkers the serial order keeps open at once (a
        // module's checker lives from its first component to its last).
        let nm = p.modules.len();
        let mut first = Vector::<u32>::new();
        first.resize_default(nm);
        let mut last = Vector::<u32>::new();
        last.resize_default(nm);
        for k in 0..order.len() {
            let c = order[k] as usize;
            if c >= nc {
                continue;
            }
            for i in s.citem_off[c] as usize..s.citem_off[c + 1] as usize {
                let m = p.idx.items.at(s.citem[i] as usize).module as usize;
                if first[m] == 0 {
                    first.set(m, k as u32 + 1);
                }
                last.set(m, k as u32 + 1);
            }
        }
        let mut live: u32 = 0;
        let mut peak: u32 = 0;
        for k in 1..order.len() + 1 {
            for m in 0..nm {
                if first[m] == k as u32 {
                    live += 1;
                }
            }
            if live > peak {
                peak = live;
            }
            for m in 0..nm {
                if last[m] == k as u32 {
                    live -= 1;
                }
            }
        }
        eprint("item-stats typecheck serial order: {} module checkers open at once at the peak\n", peak);
    }
    let mut g = sch::Jobs::from_edges(nc + 1, &edges, order);
    // The memory gate's estimate: the component's module-arena nodes.
    for c in 0..nc {
        let mut nodes: u64 = 0;
        for k in s.citem_off[c] as usize..s.citem_off[c + 1] as usize {
            let it = s.citem[k] as usize;
            if p.idx.items.at(it).owner == loader::ITEM_NONE {
                nodes += p.idx.items.at(it).node - s.top_lo[it];
            }
        }
        g.est.set(c, nodes * 96);
    }
    return g;
}

/// Type-check every module as item jobs (`tc_job`), then publish in module and item order:
/// diagnostics (logged unless `fixes` collects them), the lint counters, the package-global
/// method marks (replayed through the real visibility checks), and the post-typecheck item
/// edges as the final ranges. `lint[m]` selects the modules that lint. False when any module
/// reported an error.
fn typecheck_stage(
    p: &mut loader::Package,
    lint: &Vector<bool>,
    fixes: *mut Vector<diag::LintFix>,
    ftexts: *mut Vector<String>,
) bool {
    let n = p.modules.len();
    let ni = p.idx.items.len();
    let par = p.jobs != 1 && n > 1;
    if par {
        set_stage_locks(p, true);
        p.wl_on = true;
        for i in 0..n {
            // Pin the syntax arrays: a checker synthesizes nodes while other tasks read
            // pre-existing ones.
            p.modules[i].ast.freeze_nodes();
            p.modules[i].ast.freeze_resolutions();
        }
    }
    let mut outs = Vector::<TcOut>::with_capacity(ni);
    for _ in 0..ni {
        outs.push(TcOut { errors: Option::<Box<diag::Errors>>::None, log_lo: 0, log_hi: 0 });
    }
    let mut logs = Vector::<tc::TcMarkLog>::with_capacity(n);
    let mut tail = Vector::<diag::Errors>::with_capacity(n);
    let mut orphans = Vector::<Vector<diag::Errors>>::with_capacity(n);
    let mut chk = Vector::<Vector<Box<tc::TypeChecker>>>::with_capacity(n);
    let mut lease = Vector::<psync::Mutex<u8>>::with_capacity(n);
    let mut left = Vector::<u32>::with_capacity(n);
    let mut edges = Vector::<Vector<u64>>::with_capacity(n);
    for m in 0..n {
        logs.push(tc::TcMarkLog::new());
        tail.push(diag::Errors::new());
        orphans.push(Vector::<diag::Errors>::new());
        chk.push(Vector::<Box<tc::TypeChecker>>::new());
        lease.push(psync::Mutex::<u8>::new(0));
        edges.push(Vector::<u64>::new());
        let mut tops: u32 = 0;
        for it in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
            if p.idx.items.at(it).owner == loader::ITEM_NONE {
                tops += 1;
            }
        }
        left.push(tops);
    }
    let spans = gitems::spans_all(p);
    let mut st = TcStage {
        p: p,
        outs: outs.index_mut(0),
        logs: logs.index_mut(0),
        tail: tail.index_mut(0),
        orphans: orphans.index_mut(0),
        chk: chk.index_mut(0),
        lease: lease.index_mut(0),
        left: left.index_mut(0),
        edges: edges.index_mut(0),
        spans: &spans,
        lint: lint.as_ptr(),
    };
    let tstat = stdlib::getenv("SC_CEMIT_STATS") != null;
    let tg9 = ticks_ms();
    let mut g = tc_jobs(p);
    if tstat {
        eprint("typecheck-stage graph: {} ms\n", ticks_ms() - tg9);
    }
    let ctl = tctl::Ctl::new(tctl::budget_from_env());
    let tj0 = ticks_ms();
    sch::run_jobs(&mut g, p.jobs, tc_job, &mut st, &ctl);
    if tstat {
        eprint("typecheck-stage jobs: {} ms over {} components\n", ticks_ms() - tj0, g.n - 1);
    }
    if par {
        for i in 0..n {
            p.modules[i].ast.thaw_nodes();
            p.modules[i].ast.thaw_resolutions();
        }
        p.wl_on = false;
        set_stage_locks(p, false);
    }
    // A module without items has no job: its top-level nodes (a `static_assert`) check now, once
    // every item is typed.
    for m in 0..n {
        if p.modules[m].has_ast && p.idx.mod_items[m] == p.idx.mod_items[m + 1] {
            let pkg = p as *mut loader::Package;
            let mm = &mut p.modules[m];
            let src = mm.source.as_str().ptr() as *const char;
            let len = mm.source.len();
            let mut t = tc::TypeChecker::new(&mut mm.ast, unsafe str::from_raw(src as *const u8, len), pkg);
            t.lint = lint[m];
            t.check_open();
            t.check_orphans();
            t.check_close();
            tail.set(m, replace(&mut t.errors, diag::Errors::new()));
            orphans.set(m, replace(&mut t.orphan_errs, Vector::<diag::Errors>::new()));
        }
    }
    // Publication, in module then item order.
    let mut ok = true;
    let mut tedges = replace(&mut p.carry.tc_edges, Vector::<u64>::new()); // the prelude stage's
    for m in 0..n {
        // The module's top-level nodes in declaration order: an item's output, or the next
        // non-item node's.
        let mut errs = diag::Errors::new();
        if p.modules[m].has_ast {
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            let items = a.at_const(a.root).as_data.program.items;
            let mut oi: usize = 0;
            for i in 0..items.len {
                let nd = unsafe a.list(items)[i as usize];
                let it = p.item_of(m as ModuleId, nd);
                if it != loader::ITEM_NONE {
                    append_errs(&mut errs, &mut outs.index_mut(it as usize).errors);
                } else if oi < orphans.at(m).len() {
                    errs.append(orphans.index_mut(m).index_mut(oi));
                    oi += 1;
                }
            }
        }
        errs.append(tail.index_mut(m));
        errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
        let had = errs.has_errors();
        if had {
            ok = false;
        }
        if had || fixes == null && errs.has_warnings() {
            errs.log();
        }
        p.lint_warnings = p.lint_warnings + errs.warns.len() as u32;
        if fixes != null && lint[m] {
            // Replace fixes index into the caller's shared fix_texts pool: rebase and copy the payloads.
            let base = if ftexts != null {
                (unsafe (*ftexts).len()) as u32;
            } else {
                0u32;
            };
            for k in 0..errs.fixes.len() {
                let mut f = errs.fixes[k];
                if f.text != 0xFFFFFFFF {
                    f.text = f.text + base;
                }
                f.module = m as u32;
                unsafe (*fixes).push(f);
            }
            if ftexts != null {
                for k in 0..errs.fix_texts.len() {
                    unsafe (*ftexts).push(errs.fix_texts.at(k).clone());
                }
            }
        }
        for it in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
            let lg = logs.at(m);
            for k in outs.at(it).log_lo as usize..outs.at(it).log_hi as usize {
                let dv = lg.a[k];
                let d = DefId { module: (dv >> 32) as ModuleId, node: (dv & 0xFFFFFFFFu64) as NodeId };
                let kd = lg.kinds[k];
                if kd == 1 {
                    p.always_methods.insert(dv);
                } else if kd == 3 {
                    p.c_reads.push(dv);
                } else {
                    p.mark_method_used(d);
                }
            }
        }
        let oe = edges.at(m);
        for k in 0..oe.len() {
            tedges.push(oe[k]);
        }
    }
    gitems::build_final(p, &tedges);
    if p.carry.keep {
        p.carry.tc_edges = tedges;
    }
    if tstat {
        eprint("typecheck-stage publish: {} ms\n", ticks_ms() - tj0);
    }
    if ok {
        assert_no_error_type(p);
        ok = mark_c_reads(p);
    }
    return ok;
}

// Every TYPE_ERROR is produced after its diagnostic, so a package the checker accepted holds none:
// one left is a checker defect whose silent acceptance would reach the later passes.
fn assert_no_error_type(p: &loader::Package) {
    for i in p.root_module as usize..p.modules.len() {
        let a = &p.modules[i].ast;
        if !p.modules[i].has_ast {
            continue;
        }
        for k in 0..a.types.len() {
            if *a.types.at(k) == TYPE_ERROR {
                error_type_abort(p, i, k as NodeId);
            }
        }
        for k in 0..a.b.types.len() {
            if *a.b.types.at(k) == TYPE_ERROR {
                error_type_abort(p, i, k as NodeId | NODE_BODY);
            }
        }
        for k in 0..a.mono.len() {
            let u = a.mono.at(k);
            for j in 0..u.n {
                if unsafe u.args[j] == TYPE_ERROR {
                    error_type_abort(p, i, u.node);
                }
            }
        }
    }
}

@cold
fn error_type_abort(p: &loader::Package, m: usize, n: NodeId) {
    let sp = p.modules[m].ast.at_const(n).span;
    eprint("internal error: {}: offset {}: TYPE_ERROR without a diagnostic\n", p.modules[m].file.as_str(), sp.start);
    panic("a checked module holds TYPE_ERROR without a diagnostic");
}

// One module's cross-module duplicate-conformance sweep, run as a parallel level after every
// module is typechecked (the check reads other modules' frozen syntax, so it is decidable only
// then, and it writes nothing shared: errors buffer per module and log in module order).
struct DupTask {
    pub(package) p: *mut loader::Package,
    pub(package) i: usize,
    pub(package) out: *mut diag::Errors,
    pub(package) idx: *const Map<tc::ConfKey, u64>,
}

unsafe extend DupTask as Send {}

fn dup_run_one(t: DupTask) {
    let pkg = t.p;
    let p = unsafe &mut *t.p;
    let m = &mut p.modules[t.i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut tck = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    tck.check_cross_module_dup_conformances(unsafe &*t.idx);
    tck.check_cross_module_dup_items();
    if tck.has_errors() {
        tck.errors.finalize(unsafe str::from_raw(src as *const u8, len), unsafe (&*t.p).modules[t.i].file.as_str());
        let o = unsafe &mut *t.out;
        *o = replace(&mut tck.errors, diag::Errors::new());
    }
}

// The checks only decidable once every module is typechecked: duplicate conformances across modules,
// then the cross-module obligations. A build and a lint both run them, so both report the same errors.
fn check_package_wide(p: &mut loader::Package, n: usize) {
    let dup_par = p.jobs != 1 && n > 1;
    let dup_idx = tc::dup_conformance_index(p);
    if dup_par {
        p.ok = dup_conformances_par(p, &dup_idx) && p.ok;
    }
    discharge_obligations(p, n, dup_par, &dup_idx);
    check_feature_calls(p, n);
    let _ = build_simd_table(p, n);
}

/// The backend table (`Package::simd_table`) from every checked `@simd_impl` entry, ordered by key
/// and then by feature count, the largest first. Two entries with one key and the same feature count
/// are an error naming both: either is the same entry twice, or the planner could not choose. Returns
/// the first error as rendered (empty when none); every error is logged.
pub(package) fn build_simd_table(p: &mut loader::Package, n: usize) String {
    let mut first = String::new();
    p.simd_table.clear();
    for i in 0..n {
        let a = &p.modules[i].ast;
        for k in 0..a.attrs.len() {
            let at = *a.attrs.at(k);
            if at.kind != AttrKind::ATTR_SIMD_IMPL as u8 || !at.expr {
                continue;
            }
            let v = a.attr_value_of(k as u32);
            if v.ok {
                p.simd_table.push(
                    cf::SimdEntry {
                        key: v.v,
                        fs: cf::close(cf::CpuFeatureSet { w: v.w }),
                        module: i as u16,
                        node: at.owner,
                    },
                );
            }
        }
    }
    p.simd_table.sort_by(sp::entry_cmp);
    for k in 1..p.simd_table.len() {
        let x = *p.simd_table.at(k - 1);
        let y = *p.simd_table.at(k);
        if x.key != y.key || x.fs.w[0] != y.fs.w[0] || x.fs.w[1] != y.fs.w[1] {
            continue;
        }
        let ya = &p.modules[y.module as usize].ast;
        let xa = &p.modules[x.module as usize].ast;
        let xn = xa.at_const(xa.ext_name(x.node)).as_data.name.text;
        let mut errs = diag::Errors::new();
        errs.emit_span(
            dc::TWO_SIMD_IMPL_ENTRIES_ONE_OPERATION_LANE,
            ya.at_const(y.node).span,
            format(
                "two '@simd_impl' entries for one operation, lane type, lane count and feature set: this one and '{}' ({})",
                p.modules[x.module as usize].source.as_str().slice(xn.start as usize, xn.end as usize),
                p.modules[x.module as usize].file.as_str(),
            ),
        );
        errs.finalize(p.modules[y.module as usize].source.as_str(), p.modules[y.module as usize].file.as_str());
        errs.log();
        if first.len() == 0 {
            first = errs.rendered_errors.at(0).clone();
        }
        p.ok = false;
    }
    return first;
}

// Each call or value use of a function that needs CPU features (`@target_feature`, `@simd_impl`) is
// valid where the caller's effective features (`Package::fn_set`) hold them, else only inside `unsafe`
// (`feature_use`); a function the program's environment calls (`main`, `@test`, `@bench`) needs them in
// the build, and a `@export` function cannot need any. Read after every module is typed, when every
// attribute holds its value.
pub(package) fn check_feature_calls(p: &mut loader::Package, n: usize) {
    p.fn_union = p.features;
    for i in 0..n {
        let a = &p.modules[i].ast;
        for k in 0..a.attrs.len() {
            let at = *a.attrs.at(k);
            // The entries a function of the program may call render; a binding's features say what
            // its caller needs, not what any caller has.
            if at.kind == AttrKind::ATTR_TARGET_FEATURE as u8 && !a.ext(at.owner).function.is_extern() {
                p.fn_union = cf::join(p.fn_union, p.fn_set(i as ModuleId, at.owner));
            }
        }
        let mut errs = diag::Errors::new();
        feature_errors(p, i, &mut errs);
        if errs.has_errors() {
            errs.finalize(p.modules[i].source.as_str(), p.modules[i].file.as_str());
            errs.log();
            p.ok = false;
        }
    }
}

/// The errors of module `i`'s functions that need CPU features (`check_feature_calls`) into `errs`: the
/// uses beyond their callers' features, and the functions called from outside the program.
pub(package) fn feature_errors(p: &loader::Package, i: usize, errs: &mut diag::Errors) {
    let a = &p.modules[i].ast;
    for k in 0..a.attrs.len() {
        let at = *a.attrs.at(k);
        if at.kind != AttrKind::ATTR_TARGET_FEATURE as u8 {
            continue;
        }
        let f = at.owner;
        let need = p.fn_features(i as ModuleId, f);
        let ks: [AttrKind; 4] = [
            AttrKind::ATTR_TEST,
            AttrKind::ATTR_TEST_INIT,
            AttrKind::ATTR_TEST_FREE,
            AttrKind::ATTR_BENCH,
        ];
        let nsp = a.at_const(a.ext_name(f)).as_data.name.text;
        // The program entry `main` is called from outside the program.
        let mut outer = p.is_entry(i as ModuleId, f);
        for kd in ks {
            outer = outer || a.attr_of(f, kd) != null;
        }
        if a.attr_of(f, AttrKind::ATTR_EXPORT) != null {
            errs.emit_span(
                dc::EXPORT_FUNCTION_CANNOT_NEED_CPU_FEATURES,
                nsp,
                format("a '@export' function cannot need CPU features: C code calls it without a check"),
            );
        } else if outer && !cf::contains(p.features, need) {
            feature_err(p, errs, nsp, i as ModuleId, f, need, p.features, 2, "; it is called from outside the program");
        }
    }
    for k in 0..a.feature_calls.len() {
        let fc = *a.feature_calls.at(k);
        let u = feature_use(p, i, &fc);
        if u == 0 || u == 1 && fc.in_unsafe {
            continue;
        }
        let need = p.fn_features(fc.callee.module, fc.callee.node);
        feature_err(p, errs, fc.span, fc.callee.module, fc.callee.node, need, p.fn_set(i as ModuleId, fc.caller), u, "");
    }
}

// How use `fc` of module `m` stands: 0 its caller's effective features hold the callee's; 1 it needs
// `unsafe` (the program checks the features at run time); 2 it is an error even there: features are
// per build on wasm32, and an extern binding or an `@always_inline` function inlines into its C
// caller, which then lacks them.
fn feature_use(p: &loader::Package, m: usize, fc: &FeatureCall) u8 {
    // On wasm32 too a function's own features cover its calls: it is emitted only where the build
    // has them.
    let have = cf::close(cf::join(p.features, p.fn_features(m as ModuleId, fc.caller)));
    if cf::contains(have, p.fn_features(fc.callee.module, fc.callee.node)) {
        return 0;
    }
    let ca = &p.modules[fc.callee.module as usize].ast;
    let inl = ca.ext(fc.callee.node).function.is_extern() || ca.attr_of(fc.callee.node, AttrKind::ATTR_ALWAYS_INLINE) != null;
    return pick(!tgt::isa(p.arch).fn_features || inl, 2u8, 1u8);
}

// Each reported module's `feature_lints`, as lints.
fn lint_feature_unsafe(p: &mut loader::Package, only_mod: i32, fixes: *mut Vector<diag::LintFix>) {
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
            continue;
        }
        let mut errs = diag::Errors::new();
        feature_lints(p, m, &mut errs);
        lint_flush(p, m, &mut errs, fixes);
    }
}

/// The lints of module `m`'s uses of functions that need CPU features, into `errs`: a dispatch row
/// whose feature does not imply its function's, and an `unsafe` marker whose only reason is such a call
/// where no such call needs it (`feature_use`: "unnecessary 'unsafe'", with the prefix form's removal).
pub(package) fn feature_lints(p: &loader::Package, m: usize, errs: &mut diag::Errors) {
    let a = &p.modules[m].ast;
    // A dispatch row runs its function where the machine has the row's feature: that feature, with the
    // build's and what they imply, must hold the function's.
    for k in 0..a.feature_rows.len() {
        let fr = *a.feature_rows.at(k);
        let need = p.fn_features(fr.callee.module, fr.callee.node);
        let have = cf::close(cf::with(p.features, fr.feature as usize));
        if tgt::isa(p.arch).fn_features && !cf::contains(have, need) {
            let mut miss = String::new();
            for b in 0..cf::FEATURE_COUNT {
                if cf::has(need, b) && !cf::has(have, b) {
                    miss.format_into("{}+{}", mbe::if_s(miss.len() == 0, "", ","), cf::row(b).name);
                }
            }
            errs.warn_span(
                dc::ROW_S_FEATURE_DOES_NOT_IMPLY,
                fr.span,
                format(
                    "the row's feature `{}` does not imply `{}`, which this function needs: a machine without them would run it; key the row by a feature that implies them, or check them first (`detect::has_level`)",
                    cf::row(fr.feature as usize).name,
                    miss.as_str(),
                ),
            );
        }
    }
    if a.unsafe_lints.len() == 0 {
        return;
    }
    let mut need = Set::<u32>::new();
    for k in 0..a.feature_calls.len() {
        let fc = *a.feature_calls.at(k);
        if fc.marker != 0 && feature_use(p, m, &fc) != 0 {
            need.insert(fc.marker - 1);
        }
    }
    for k in 0..a.unsafe_lints.len() {
        let ul = *a.unsafe_lints.at(k);
        if !need.contains(&ul.start) {
            errs.warn(
                dc::UNNECESSARY_UNSAFE_NOTHING_INSIDE_REQUIRES,
                ul.start,
                6,
                format("unnecessary 'unsafe': nothing inside requires it"),
            );
            if ul.fix_end != 0 {
                errs.fix(ul.start, ul.fix_end, 0);
            }
        }
    }
}

// The error of use `sp` of function `m`/`f`, whose features `need` the caller's `have` lacks: `u` from
// `feature_use`, then `why`.
fn feature_err(
    p: &loader::Package,
    errs: &mut diag::Errors,
    sp: tok::Span,
    m: ModuleId,
    f: NodeId,
    need: cf::CpuFeatureSet,
    have: cf::CpuFeatureSet,
    u: u8,
    why: str,
) {
    let mut miss = String::new();
    for k in 0..cf::FEATURE_COUNT {
        if cf::has(need, k) && !cf::has(have, k) {
            miss.push_str(
                if miss.len() == 0 {
                    "+";
                } else {
                    ",+";
                },
            );
            miss.push_str(cf::row(k).name);
        }
    }
    let ca = &p.modules[m as usize].ast;
    let nm = ca.at_const(ca.ext_name(f)).as_data.name.text;
    let fname = p.modules[m as usize].source.as_str().slice(nm.start as usize, nm.end as usize);
    if !tgt::isa(p.arch).fn_features || why.len() != 0 {
        errs.emit_span(
            dc::NEEDS_TARGET_FEATURE,
            sp,
            format("`{}` needs `{}` (`--target-feature={}`){}", fname, miss.as_str(), miss.as_str(), why),
        );
    } else if u == 2 {
        errs.emit_span(
            dc::NEEDS_INLINES_INTO_CALLER_CALL_FUNCTION,
            sp,
            format(
                "`{}` needs `{}` and inlines into its caller: call it from a function whose `@target_feature` enables it",
                fname,
                miss.as_str(),
            ),
        );
    } else {
        errs.emit_span(
            dc::NEEDS_USE_FUNCTION_WHOSE_TARGET_FEATURE_ENABLES,
            sp,
            format(
                "`{}` needs `{}`: use it in a function whose `@target_feature` enables it, or inside `unsafe` after a run-time check (`std::cpu::detect::has`)",
                fname,
                miss.as_str(),
            ),
        );
    }
}

// Turn the evaluator lock and every module's interner lock on or off around a parallel stage.
const fn set_stage_locks(p: &mut loader::Package, on: bool) {
    let cirp = p.cir as *mut iri::Interp;
    if cirp != null {
        unsafe (*cirp).elock_on = on;
    }
    for i in 0..p.modules.len() {
        p.modules[i].ast.ilock_on = on;
    }
}

// The duplicate-conformance level of a parallel build: independent per module, under the same
// freeze and lock discipline as the checking jobs. The serial path sweeps in
// discharge_obligations instead.
fn dup_conformances_par(p: &mut loader::Package, idx: &Map<tc::ConfKey, u64>) bool {
    let n = p.modules.len();
    set_stage_locks(p, true);
    for i in 0..n {
        p.modules[i].ast.freeze_nodes();
        p.modules[i].ast.freeze_resolutions();
    }
    let mut douts = Vector::<diag::Errors>::new();
    for _ in 0..n {
        douts.push(diag::Errors::new());
    }
    let pp = p as *mut loader::Package;
    {
        let wgd = psync::WaitGroup::new();
        for i in 0..n {
            wgd.add(1);
            let t = DupTask { p: pp, i: i, out: douts.index_mut(i), idx: idx };
            let wgc = wgd.clone();
            launch || {
                dup_run_one(t);
                wgc.done();
            };
        }
        wgd.wait();
    }
    for i in 0..n {
        p.modules[i].ast.thaw_nodes();
        p.modules[i].ast.thaw_resolutions();
    }
    set_stage_locks(p, false);
    let mut ok = true;
    for i in 0..n {
        let de = douts.index_mut(i);
        if de.errors.len() != 0 {
            de.log();
            ok = false;
        }
    }
    return ok;
}

// Dev gate (SC_FACTS_CHECK=1): snapshot every module's semantic-table watermarks right after
// type checking, then assert (after borrow checking AND after codegen) that no later stage
// changed a semantic decision table (intern pools excepted) and that the tables freed at their last
// reader were freed there (see ast::facts). Off without the env var.
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
            d += facts::watermark_check(&p.modules[i].ast, wms.at(i), i as u32, stage == "codegen");
        }
    }
    if d != 0 {
        eprint("facts-check: stage '{}' changed semantic type-check tables\n", stage);
    }
    return d;
}

// Validation mode (SC_LAYOUT=1): every concrete pool type must satisfy the C layout invariants:
// power-of-two alignment dividing the size, fields aligned, apart in layout order and inside the
// parent, and the enum view agreeing with the plain one.
fn layout_pass(p: &mut loader::Package) {
    if stdlib::getenv("SC_LAYOUT") == null {
        return;
    }
    let t0 = ticks_ms();
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
        for t in 0..a.ntypes() {
            let ty = a.used_type(t);
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
                if da.at_const(dn).kind == NodeKind::NODE_STRUCT && !da.ext(dn).aggregate.is_union {
                    // In layout order, which need not be the declared one. Zero-size members share
                    // offsets and may sit at the very end.
                    let mut ms = Vector::<lay::MemberAt>::new();
                    if svc.struct_members(m as ModuleId, ty, &mut ms) {
                        let mut end: u64 = 0;
                        for k in 0..ms.len() {
                            fields += 1;
                            if ms[k].off % ms[k].align != 0 || ms[k].off < end || ms[k].off + ms[k].size > l.size {
                                ok = false;
                            }
                            end = ms[k].off + ms[k].size;
                        }
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
    let dt = ticks_ms() - t0;
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

/// Rendered bodies, one buffer per translation unit (slot `n` is the shared instance TU), plus the
/// chunk table in emission order: `chunk_mod[i]` is chunk i's TU (65534 = the instance TU) and
/// `chunk_off[i] .. chunk_end[i]` its bytes inside that TU's buffer. A TU's chunks are contiguous
/// and in table order, so its parts are offset ranges of its own buffer: nothing is copied between
/// rendering and the file write. A seed shard holds module `lo`'s buffer alone (`one`).
pub(package) struct TuBufs {
    pub(package) bufs: Vector<String>,
    pub(package) chunk_mod: Vector<u64>,
    pub(package) chunk_own: Vector<ModuleId>, // the chunk's owner module (its prototype header and shard)
    pub(package) chunk_off: Vector<u64>,
    pub(package) chunk_end: Vector<u64>,
    pub(package) n: usize,
    pub(package) lo: usize, // the module of bufs[0]
}

extend TuBufs {
    pub(package) fn new(n: usize) TuBufs {
        let mut t = TuBufs {
            bufs: Vector::<String>::new(),
            chunk_mod: Vector::<u64>::new(),
            chunk_own: Vector::<ModuleId>::new(),
            chunk_off: Vector::<u64>::new(),
            chunk_end: Vector::<u64>::new(),
            n: n,
            lo: 0,
        };
        t.bufs.resize_default(n + 1);
        return t;
    }

    /// Module `m`'s TU buffer `buf` alone: a seed shard renders into no other TU.
    pub(package) fn one(m: usize, buf: String) TuBufs {
        let mut t = TuBufs::new(0);
        t.lo = m;
        t.bufs.set(0, buf);
        return t;
    }

    pub(package) const fn slot(self: &Self, m: u64) usize {
        if m == 65534 {
            return self.n;
        }
        return m as usize - self.lo;
    }

    /// Append one chunk owned by module `own` to TU `m`'s buffer and record it.
    pub(package) fn add(self: &mut Self, m: u64, own: ModuleId, text: &String) {
        let sl = self.slot(m);
        let off = self.bufs.at(sl).len() as u64;
        self.bufs.index_mut(sl).push_string(text);
        self.chunk_mod.push(m);
        self.chunk_own.push(own);
        self.chunk_off.push(off);
        self.chunk_end.push(self.bufs.at(sl).len() as u64);
    }

    pub(package) const fn last_off(self: &Self) u64 {
        return self.chunk_off[self.chunk_off.len() - 1];
    }

    pub(package) const fn last_end(self: &Self) u64 {
        return self.chunk_end[self.chunk_end.len() - 1];
    }
}

/// What one emission pass accumulates: TU buffers and chunk table, prototype lines (line k pairs
/// with chunk k), closure environment structs, the C `main` choice and the counters. The master
/// holds one; each parallel shard holds its own, merged into the master in module order.
struct SeedAcc {
    pub(package) ch: TuBufs,
    pub(package) protos: String,
    pub(package) env_names: Vector<u64>,
    pub(package) env_bodies: Vector<String>,
    pub(package) env_own: Vector<ModuleId>,
    pub(package) have_main: bool,
    pub(package) main_mod: u64,
    pub(package) main_argv: bool,
    pub(package) seeds: u64,
    pub(package) seed_skip: u64,
    pub(package) clos_ok: u64,
    pub(package) clos_skip: u64,
    pub(package) inst_ok: u64,
    pub(package) inst_skip: u64,
    pub(package) glue_ok: u64,
    pub(package) glue_skip: u64,
}

extend SeedAcc {
    fn new(ch: TuBufs) SeedAcc {
        return SeedAcc {
            ch: ch,
            protos: String::new(),
            env_names: Vector::<u64>::new(),
            env_bodies: Vector::<String>::new(),
            env_own: Vector::<ModuleId>::new(),
            have_main: false,
            main_mod: 0,
            main_argv: false,
            seeds: 0,
            seed_skip: 0,
            clos_ok: 0,
            clos_skip: 0,
            inst_ok: 0,
            inst_skip: 0,
            glue_ok: 0,
            glue_skip: 0,
        };
    }

    /// Move environment structs `a..b` of `o` to the end of this pass's.
    fn take_envs(self: &mut Self, o: &mut SeedAcc, a: usize, b: usize) {
        for k in a..b {
            self.env_names.push(o.env_names[k]);
            self.env_bodies.push(replace(o.env_bodies.index_mut(k), String::new()));
            self.env_own.push(o.env_own[k]);
        }
    }

    /// Append chunk `text` of TU `key` owned by `own`, with its prototype line; `rec` journals it
    /// in `evs` for the per-TU cache.
    fn chunk(self: &mut Self, key: u64, own: ModuleId, text: &String, rec: bool, evs: &mut Vector<mbe::RecEv>) {
        proto_of(text, &mut self.protos);
        self.ch.add(key, own, text);
        if rec {
            let mut ev = mbe::RecEv::blank(mbe::RK_CHUNK);
            ev.a = self.ch.last_off() as u32;
            ev.b = self.ch.last_end() as u32;
            evs.push(ev);
        }
    }

    /// Take seed shard `o`'s output for module `m`: its buffer becomes TU m's (its offsets are
    /// already module-relative; a module is either replayed or shard-emitted, never both), and its
    /// chunks, prototypes, environments, `main` and counters join this pass's.
    fn absorb_seed(self: &mut Self, o: &mut SeedAcc, m: usize) {
        assert(self.ch.bufs.at(m).len() == 0);
        for k in 0..o.ch.chunk_mod.len() {
            self.ch.chunk_mod.push(o.ch.chunk_mod[k]);
            self.ch.chunk_own.push(o.ch.chunk_own[k]);
            self.ch.chunk_off.push(o.ch.chunk_off[k]);
            self.ch.chunk_end.push(o.ch.chunk_end[k]);
        }
        self.ch.bufs.set(m, replace(o.ch.bufs.index_mut(0), String::new()));
        self.protos.push_string(&o.protos);
        self.take_envs(o, 0, o.env_names.len());
        if o.have_main {
            self.have_main = true;
            self.main_mod = o.main_mod;
            self.main_argv = o.main_argv;
        }
        self.seeds += o.seeds;
        self.seed_skip += o.seed_skip;
        self.clos_ok += o.clos_ok;
        self.clos_skip += o.clos_skip;
    }
}

/// One assembled new-backend emission. TU texts carry NO include lines; the writer prepends the
/// layout-relative include of the forward header. `skips` MUST be zero for the output to be
/// complete (every count is an emission the backend refused).
pub(package) struct CemitOut {
    /// The forward header (runtime and extern-block includes, declarations shared by every TU).
    pub(package) fwd_h: String,
    /// The definition headers (text, file stem under `__sc_t/`, owner module) and, per module,
    /// its prototype header (empty when it has none).
    pub(package) defs_h: Vector<String>,
    pub(package) defs_stem: Vector<String>,
    pub(package) defs_own: Vector<ModuleId>,
    pub(package) protos_h: Vector<String>,
    /// Per module: the TU's include prefix, body buffer, chunk indexes, one head per shard
    /// (static closure prototypes; shard 0 also carries the asserts), and the tail of shard 0
    /// (the C `main` wrapper). A module with no shards emits no TU.
    pub(package) tu_incs: Vector<String>,
    pub(package) tus: Vector<String>,
    pub(package) tu_chunks: Vector<Vector<u32>>,
    pub(package) tu_heads: Vector<Vector<String>>,
    pub(package) tu_tail: Vector<String>,
    /// The chunk table: bounds in the owning buffer and the shard each chunk landed in.
    pub(package) ck_off: Vector<u32>,
    pub(package) ck_end: Vector<u32>,
    pub(package) ck_shard: Vector<u8>,
    /// The instance buffer and, per owner module, its instance shards shaped like a TU (head 0
    /// carries the owner's data definitions).
    pub(package) inst_c: String,
    pub(package) inst_incs: Vector<String>,
    /// Per module: its TU, or its instance unit, includes a scoped extern header, directly or through
    /// a definition header (`cemit_extern_includes`), or belongs to wasm's C library
    /// (`loader::libc_unit`): the unit compiles alone (`pack_plan`).
    pub(package) tu_x: Vector<bool>,
    pub(package) inst_x: Vector<bool>,
    /// The registry TU includes a scoped extern header: it compiles alone too (`pack_plan`).
    pub(package) reg_x: bool,
    pub(package) inst_chunks: Vector<Vector<u32>>,
    pub(package) inst_heads: Vector<Vector<String>>,
    /// The registry TU (ZST sentinels, reflection registry) and its sorted root symbols.
    pub(package) registry_c: String,
    pub(package) reg_inputs: String,
    /// The alignments of the ZST sentinels the registry defines, ascending.
    pub(package) zst: Vector<u64>,
    pub(package) have_main: bool,
    pub(package) main_mod: u64,
    pub(package) main_argv: bool,
    pub(package) skips: u64,
    /// An instance folded an array length out of range: the located errors are reported, and the
    /// refusals of the bodies that hold the length are their consequence.
    pub(package) len_faults: bool,
    /// The refused bodies behind `skips` that carry a source location.
    pub(package) refused: Vector<cbe::Refusal>,
    pub(package) edges: Vector<u64>, // (spelling TU << 32 | owner module): cross-TU symbol references
    /// Next per-TU cache image + its path ("" = caching off): run_package persists it only after a
    /// fully successful emission, so a failed build never publishes sections it did not finish.
    pub(package) tuc_img: String,
    pub(package) tuc_path: String,
    /// The emission cache's module keys and hits (empty when it is off), for the native objects' reuse.
    pub(package) tuc_keys: Vector<u64>,
    pub(package) tuc_hit: Vector<bool>,
    /// Merged emission counters (SC_CEMIT_STATS); the write stage adds publication and reports.
    pub(package) pr: prb::Probe,
    /// The LIR of every body of a native build (`cbe::native_on`), for the write stage's objects.
    pub(package) lir: Option<Box<lw::Lower>>,
}

extend CemitOut {
    /// Empty output buffers for a package of `n` modules.
    pub(package) fn new(n: usize) CemitOut {
        let mut o = CemitOut {
            fwd_h: String::new(),
            defs_h: Vector::<String>::new(),
            defs_stem: Vector::<String>::new(),
            defs_own: Vector::<ModuleId>::new(),
            protos_h: Vector::<String>::new(),
            tu_incs: Vector::<String>::new(),
            tus: Vector::<String>::new(),
            tu_chunks: Vector::<Vector<u32>>::new(),
            tu_heads: Vector::<Vector<String>>::new(),
            tu_tail: Vector::<String>::new(),
            ck_off: Vector::<u32>::new(),
            ck_end: Vector::<u32>::new(),
            ck_shard: Vector::<u8>::new(),
            inst_c: String::new(),
            inst_incs: Vector::<String>::new(),
            tu_x: Vector::<bool>::new(),
            inst_x: Vector::<bool>::new(),
            reg_x: false,
            inst_chunks: Vector::<Vector<u32>>::new(),
            inst_heads: Vector::<Vector<String>>::new(),
            registry_c: String::new(),
            reg_inputs: String::new(),
            zst: Vector::<u64>::new(),
            have_main: false,
            main_mod: 0,
            main_argv: false,
            skips: 0,
            len_faults: false,
            refused: Vector::<cbe::Refusal>::new(),
            edges: Vector::<u64>::new(),
            tuc_img: String::new(),
            tuc_path: String::new(),
            tuc_keys: Vector::<u64>::new(),
            tuc_hit: Vector::<bool>::new(),
            pr: prb::Probe::new(false, false),
            lir: Option::<Box<lw::Lower>>::None,
        };
        o.protos_h.resize_default(n);
        o.tu_incs.resize_default(n);
        o.tus.resize_default(n);
        o.tu_chunks.resize_default(n);
        o.tu_heads.resize_default(n);
        o.tu_tail.resize_default(n);
        o.inst_incs.resize_default(n);
        o.tu_x.resize_default(n);
        o.inst_x.resize_default(n);
        o.inst_chunks.resize_default(n);
        o.inst_heads.resize_default(n);
        return o;
    }
}

// The C attribute prefix of fn `nid` (`inline __attribute__((always_inline)) ` etc.), mirroring
// the established emitter: naked (+noinline), inline/always_inline/noinline, cold (+noinline unless
// spelled), used/unused, section("name").
fn cemit_fn_attrs(p: &loader::Package, m: ModuleId, nid: NodeId, fs: cf::CpuFeatureSet, out: &mut String) {
    let a = unsafe &*p.module_ast_const(m);
    let naked = (a.unsafe_claims(nid) & UNSAFE_NAKED) != 0;
    let mut always = false;
    let mut inl = false;
    let mut noinl = naked;
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
        } else if kd == AttrKind::ATTR_UNSAFE as u8 && (a.attrs.at(k).arg & UNSAFE_LINK_SECTION) != 0 {
            // Kept: link-time optimization would otherwise inline or drop it, and its section with it.
            sec = a.attrs.at(k).str_span;
            used = true;
        }
    }
    if inl || always {
        out.push_str("inline ");
    }
    let mut g = String::new();
    if naked {
        g.push_str("naked");
    }
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
    // The features the function states beyond the build's: the C compiler's `target` attribute.
    let mut ta = String::new();
    cf::push_target_attr(fs, p.features, p.build_target, &mut ta);
    if ta.len() != 0 {
        if g.len() != 0 {
            g.push_str(", ");
        }
        g.push_string(&ta);
    }
    if g.len() != 0 {
        out.push_str("__attribute__((");
        out.push_string(&g);
        out.push_str(")) ");
    }
}

// A short display name for the instantiation note: decl names for aggregates (an instance's with
// its arguments), the mangled spelling for builtins, "?" when unrenderable.
fn cemit_ty_disp(p: &loader::Package, m: ModuleId, t: TypeId, out: &mut String) {
    let a = unsafe &*p.module_ast_const(m);
    let y = *a.type_at(t);
    let mut dm = y.module;
    let mut dn = NODE_NONE;
    let mut it = TyInstance {};
    if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
        dn = y.as_data.decl;
    } else if a.targs_of(t, &mut it) {
        dm = it.module;
        dn = it.decl;
    } else if y.kind == TypeKind::TYPE_BUILTIN {
        out.push_str(bt_name(y.as_data.builtin));
        return;
    } else if y.kind == TypeKind::TYPE_CONST {
        out.format_into("{}", y.cval());
        return;
    }
    if dn == NODE_NONE {
        out.push_str("?");
        return;
    }
    let da = unsafe &*p.module_ast_const(dm);
    let nm = if da.at_const(dn).kind == NodeKind::NODE_TYPE_ALIAS {
        da.at_const(dn).as_data.type_alias.name;
    } else {
        da.ext_name(dn);
    };
    let ns = da.at_const(nm).as_data.name.text;
    out.push_str(p.modules[dm as usize].source.as_str().slice(ns.start as usize, ns.end as usize));
    // The arguments are types of `a`; a type nests a finite depth.
    for i in 0..it.n {
        out.push_str(pick(i == 0, "<", ", "));
        cemit_ty_disp(p, m, unsafe it.args[i as usize], out);
    }
    if it.n != 0 {
        out.push_str(">");
    }
}

// The note naming an instance's bindings, `in the instantiation where T = f32, N = 4`: the `np`
// parameters `prm` of module `pmod` bound to `(ams, ats)`. A method also binds its type's parameters
// under the extend's names: each name prints once.
fn inst_where(
    p: &loader::Package,
    pmod: ModuleId,
    prm: &Array<NodeId, 8>,
    ams: &Array<ModuleId, 8>,
    ats: &Array<TypeId, 8>,
    np: u8,
) String {
    let mut tn = String::from_str("in the instantiation where ");
    let pa = unsafe &*p.module_ast_const(pmod);
    let psrc = p.modules[pmod as usize].source.as_str();
    let mut names = Array::<u64, 8> {};
    let mut nn: usize = 0;
    for k in 0..np {
        // An interface node stands for the interface's `Self`.
        let pn = pa.at_const(prm[k as usize]);
        let gn = if pn.kind == NodeKind::NODE_GENERIC_PARAM {
            let gs = pa.at_const(pa.ext_name(prm[k as usize])).as_data.name.text;
            psrc.slice(gs.start as usize, gs.end as usize);
        } else {
            "Self";
        };
        let mut seen = false;
        for j in 0..nn {
            seen = seen || names[j] == fnv(gn);
        }
        if seen {
            continue;
        }
        names[nn] = fnv(gn);
        nn += 1;
        if nn != 1 {
            tn.push_str(", ");
        }
        tn.push_str(gn);
        tn.push_str(" = ");
        cemit_ty_disp(p, ams[k as usize], ats[k as usize], &mut tn);
    }
    return tn;
}

// The program error the per-instance re-lowering `lw` of `d` under `subs` found (`Lowerer::user_err`:
// an index list that does not evaluate or names a lane past its operands for these arguments),
// reported at its node with the instance's bindings.
fn cemit_inst_error(p: &mut loader::Package, d: DefId, subs: &Vector<mbe::MSub>, lw: &irl::Lowerer) {
    if lw.user_err == NODE_NONE {
        return;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    let mut prm = Array::<NodeId, 8> {};
    let mut ams = Array::<ModuleId, 8> {};
    let mut ats = Array::<TypeId, 8> {};
    let mut np: u8 = 0;
    for k in 0..subs.len() {
        let sb = *subs.at(k);
        if sb.pm == d.module && np < 8 {
            prm[np as usize] = sb.pnode;
            ams[np as usize] = sb.am;
            ats[np as usize] = sb.at;
            np += 1;
        }
    }
    let mut errs = diag::Errors::new();
    errs.emit_span(dc::STATIC_ASSERTION_FAILED, a.at_const(lw.user_err).span, format("{}", lw.user_msg));
    errs.note(inst_where(p, d.module, &prm, &ams, &ats, np));
    errs.finalize(p.modules[d.module as usize].source.as_str(), p.modules[d.module as usize].file.as_str());
    errs.log();
    p.ok = false;
}

// Per-instantiation static_asserts inside a demanded generic body: evaluate each under the
// demand's substitution; false fails the build, naming every binding. `mg` (null when `subs` is
// flat and concrete) grounds an emission demand's chain.
fn cemit_inst_asserts(
    p: &mut loader::Package,
    mg: *mut mbe::Mangler,
    d_def: DefId,
    subs: &Vector<mbe::MSub>,
    dk: u64,
    seen: &mut Map<u64, u64>,
    ia: &mut Vector<Vector<NodeId>>,
    ia_built: &mut Vector<bool>,
) {
    let hit = seen.contains_key(&dk);
    if hit || p.cir == null || subs.len() == 0 || unsafe (*(p.cir as *mut iri::Interp)).inst_asserts_failed {
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
        for k0 in 0..a.nnodes() {
            let nid0 = a.nth_id(k0);
            if a.at_const(nid0).kind == NodeKind::NODE_STATIC_ASSERT {
                lst.push(nid0);
            }
        }
    }
    if ia.at(dm).len() == 0 {
        seen.insert(dk, 1);
        return;
    }
    let fsp = a.at_const(d_def.node).span;
    let mut held = false;
    for ni in 0..ia.at(dm).len() {
        let sp = a.at_const(*ia.at(dm).at(ni)).span;
        held = held || sp.start >= fsp.start && sp.end <= fsp.end;
    }
    if !held {
        seen.insert(dk, 1);
        return;
    }
    let cev = p.cir as *mut iri::Interp;
    // The instance's own bindings: the innermost entry of each of its parameters. A demand from a
    // generic body lists the caller's frames first, and its entries may name them: `mg` grounds
    // each through the frames below its group (`MSub.lim`).
    let pmod = d_def.module;
    let mut prm = Array::<NodeId, 8> {};
    let mut ams = Array::<ModuleId, 8> {};
    let mut ats = Array::<TypeId, 8> {};
    let mut np: u8 = 0;
    let mut saved = Vector::<mbe::MSub>::new();
    if mg != null {
        saved = mbe::subs_copy(unsafe &(*mg).subs);
        unsafe (*mg).clear_subs();
        for k in 0..subs.len() {
            unsafe (*mg).push_msub(*subs.at(k));
        }
    }
    for k in 0..subs.len() {
        let sb = *subs.at(k);
        let mut inner = true;
        for j in k + 1..subs.len() {
            inner = inner && (subs.at(j).pm != sb.pm || subs.at(j).pnode != sb.pnode);
        }
        if sb.pm != pmod || !inner || np >= 8 {
            continue;
        }
        let mut at = sb.at;
        if mg != null && !unsafe (*mg).ground_l(sb.am, sb.at, sb.am, sb.lim as usize, &mut at, 0) {
            continue;
        }
        prm[np as usize] = sb.pnode;
        ams[np as usize] = sb.am;
        ats[np as usize] = at;
        np += 1;
    }
    if mg != null {
        unsafe (*mg).clear_subs();
        for k in 0..saved.len() {
            unsafe (*mg).push_msub(*saved.at(k));
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
        let cv = unsafe (*cev).eval_typed(d_def.module, bd.left, pmod, &prm[0], &ams[0], &ats[0], np);
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
        errs.emit_span(dc::STATIC_ASSERTION_FAILED, n.span, format("static assertion failed: {}", msg));
        if np > 0 {
            errs.note(inst_where(p, pmod, &prm, &ams, &ats, np));
        }
        errs.finalize(src, p.modules[d_def.module as usize].file.as_str());
        errs.log();
        p.ok = false;
    }
    if decided {
        seen.insert(dk, 1);
    }
}

// The static_asserts of the generic-function instances the checker's concrete calls queued
// (`Interp::inst_asserts`), evaluated while the kept bodies are readable: a false one fails the
// build, naming the instance. Instances only emission discovers are checked there.
fn flush_inst_asserts(p: &mut loader::Package) {
    let cev = p.cir as *mut iri::Interp;
    if cev == null || unsafe (*cev).inst_asserts.len() == 0 {
        return;
    }
    let recs = replace(unsafe &mut (*cev).inst_asserts, Vector::<iri::InstAssert>::new());
    let mut seen = Map::<u64, u64>::new();
    let mut ia = Vector::<Vector<NodeId>>::new();
    let mut ia_built = Vector::<bool>::new();
    ia.resize_default(p.modules.len());
    ia_built.resize_default(p.modules.len());
    let mut subs = Vector::<mbe::MSub>::new();
    for i in 0..recs.len() {
        let r = recs.at(i);
        subs.clear();
        let mut dk = skey_mix(0, r.f.module as u64 << 32 | r.f.node as u64);
        for k in 0..r.np {
            let at = unsafe r.ats[k as usize];
            subs.push(
                mbe::MSub {
                    pnode: unsafe r.prm[k as usize],
                    at: at,
                    lim: 0,
                    pm: r.f.module,
                    am: unsafe r.ams[k as usize],
                },
            );
            dk = skey_mix(dk, (unsafe r.ams[k as usize]) as u64 << 32 | at as u64);
        }
        cemit_inst_asserts(p, null, r.f, &subs, dk, &mut seen, &mut ia, &mut ia_built);
    }
}

// The static_asserts of every demanded instance of a generic function or method the instance graph
// found, evaluated while the body syntax is live: the checker queues only its concrete calls
// (`flush_inst_asserts`), not the instances other generic bodies reach. A failure stops the
// emission-time check (`cemit_inst_asserts`) from reporting it again.
// Returns the number of instances checked.
fn graph_inst_asserts(p: &mut loader::Package, g: &mut ig::InstGraph) u64 {
    let cev = p.cir as *mut iri::Interp;
    if cev == null {
        return 0;
    }
    let mut n: u64 = 0;
    let ok0 = p.ok;
    p.ok = true;
    let mut seen = Map::<u64, u64>::new();
    let mut ia = Vector::<Vector<NodeId>>::new();
    let mut ia_built = Vector::<bool>::new();
    ia.resize_default(p.modules.len());
    ia_built.resize_default(p.modules.len());
    let mut subs = Vector::<mbe::MSub>::new();
    let mut prm = Vector::<NodeId>::new();
    let mut tys = Vector::<TypeId>::new();
    for id in 0..g.recs.len() {
        prm.clear();
        tys.clear();
        if !g.assert_binds(id as u32, &mut prm, &mut tys) {
            continue;
        }
        let f = g.recs.at(id).def;
        subs.clear();
        let mut dk = skey_mix(0, f.module as u64 << 32 | f.node as u64);
        for k in 0..prm.len() {
            subs.push(mbe::MSub { pnode: prm[k], at: tys[k], lim: 0, pm: f.module, am: f.module });
            dk = skey_mix(dk, tys[k]);
        }
        cemit_inst_asserts(p, null, f, &subs, dk, &mut seen, &mut ia, &mut ia_built);
        n += 1;
    }
    unsafe (*cev).inst_asserts_failed = !p.ok;
    p.ok = ok0 && p.ok;
    return n;
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
                out.insert(fnv(text.slice(s0, j)));
            }
            i = j;
        } else {
            i += 1;
        }
    }
}

const fn struct_def_hit(defined: &Set<u64>, nm: str) bool {
    return defined.contains(&fnv(nm));
}

// Every module's instance records by the module that declares the generic: a module checks the
// layout of its instances whichever module's code named them (`cemit_layout_asserts`). A record a
// module holds under a provisional id names that module's pool: only the module itself reads it.
struct InstRecs {
    pub(package) off: Vector<u32>, // per declaring module + 1: its range of `rec`
    pub(package) rec: Vector<u64>, // recording module << 32 | record index
}

fn inst_recs(p: &loader::Package) InstRecs {
    let n = p.modules.len();
    let mut r = InstRecs { off: Vector::<u32>::new(), rec: Vector::<u64>::new() };
    r.off.resize_default(n + 1);
    for pass in 0..2 {
        for om in 0..n {
            if !p.modules[om].has_ast {
                continue;
            }
            let a = &p.modules[om].ast;
            for ii in 0..a.ninstances() {
                let d = a.used_instance(ii).module as usize;
                if d != om && (a.gt.p == null || (a.used_inst[ii] & TYPE_PROV) != 0) {
                    continue;
                }
                if pass == 0 {
                    r.off.set(d, r.off[d] + 1);
                } else {
                    r.off.set(d, r.off[d] - 1);
                    r.rec.set(r.off[d] as usize, om as u64 << 32 | ii as u64);
                }
            }
        }
        if pass == 0 {
            for d in 1..n + 1 {
                r.off.set(d, r.off[d] + r.off[d - 1]);
            }
            r.rec.resize_default(r.off[n] as usize);
        }
    }
    return r;
}

// Layout-model verification asserts for module `m`: sizeof/_Alignof of every concrete aggregate
// checked against the layout service, so the C compiler proves the model on every target. An
// emitted aggregate's check goes to its definition header (`lay`, indexed like `ds`), so a unit
// checks what it includes and a new type changes no unit; an extern enum's goes to `out`, the
// module's first shard. `header_type_checks` checks a header struct or union with its fields.
fn cemit_layout_asserts(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    m: ModuleId,
    recs: &InstRecs,
    defined: &Set<u64>,
    ds: &DefSet,
    lay: &mut Vector<String>,
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
                    if a.at_const(iid).kind == NodeKind::NODE_ENUM {
                        decls.push(iid);
                        exts.push(iid);
                    }
                }
                continue;
            }
            if nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM {
                continue;
            }
            if a.ext(nid).aggregate.generics.len != 0 {
                continue;
            }
            if nk == NodeKind::NODE_ENUM && !a.enum_has_payload(nid) {
                // Tagless enums have no modelled layout claim.
                continue;
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
        if is_ext {
            push_layout_assert(out, nm.as_str(), lo.size, lo.align);
            any = true;
        } else {
            push_layout_assert(
                lay.index_mut((*ds.idx.get(&nkey(fnv(nm.as_str()))).unwrap()) as usize),
                nm.as_str(),
                lo.size,
                lo.align,
            );
        }
    }
    {
        // The module's instances in type-id order (the package identity), not in the order checks
        // first touched them: that order follows the item schedule.
        let r0 = recs.off[m as usize] as usize;
        let r1 = recs.off[m as usize + 1] as usize;
        let mut tids = Vector::<TypeId>::with_capacity(r1 - r0);
        for k in r0..r1 {
            let it = *p.modules[(recs.rec[k] >> 32) as usize].ast.used_instance((recs.rec[k] & 0xFFFFFFFF) as usize);
            tids.push((&mut p.modules[m as usize].ast).intern_instance(it.module, it.decl, &it.args[0], it.n));
        }
        tids.sort();
        tids.dedup();
        for ii in 0..tids.len() {
            let t = tids[ii];
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
            push_layout_assert(
                lay.index_mut((*ds.idx.get(&nkey(fnv(nm.as_str()))).unwrap()) as usize),
                nm.as_str(),
                lo.size,
                lo.align,
            );
        }
    }
    if any {
        out.push_str("\n");
    }
    svc.free();
}

// One layout-model check: C type `nm` must have the modelled size and alignment.
fn push_layout_assert(out: &mut String, nm: str, size: u64, align: u64) {
    out.push_str("_Static_assert(sizeof(");
    out.push_str(nm);
    out.push_str(") == ");
    out.push_u64(size);
    out.push_str(" && _Alignof(");
    out.push_str(nm);
    out.push_str(") == ");
    out.push_u64(align);
    out.push_str(", \"super-c layout model mismatch: ");
    out.push_str(nm);
    out.push_str("\");\n");
}

// Tally a template: a generic body whose shared lowering must re-lower per instance (an
// unexpanded reflection binder, or a vector index list over a parameter) or per zero-size signature.
fn count_template(b: &irc::CoreBody, pr: &mut prb::Probe) {
    if b.has_reflect || b.has_lists {
        pr.count(prb::C_TPL_REFLECT, 1);
    } else if b.has_zst_cond {
        pr.count(prb::C_TPL_ZST, 1);
    }
}

// The re-lowering census (SC_CEMIT_STATS), after the instance drain: per marked template, the
// distinct instances emitted from it, the re-lowerings `lws` retains, how many of those repeat an
// earlier re-lowering's printed IR, and the bytes they hold. A base slot is the one `lw_cache`
// names under the declaration; every other slot with the same owner is a re-lowering of it. One
// worker retains every re-lowering; the parallel frontier drops a slice's reflection
// re-lowerings with the slice, so those are absent from a many-worker census.
fn cemit_relower_census(
    p: &loader::Package,
    cem: &cbe::CEmit,
    lws: &Vector<irl::Lowerer>,
    lw_cache: &Map<u64, u64>,
    done: &Map<u64, u64>,
    pr: &mut prb::Probe,
) {
    let n = lws.len();
    let mut base = Vector::<u64>::new(); // per slot: its template's base slot
    let mut hashes = Vector::<u64>::new(); // per re-lowered slot: the printed body's hash
    let mut nrel = Vector::<u64>::new(); // per base slot: re-lowerings, identical ones, bytes, instances
    let mut nsame = Vector::<u64>::new();
    let mut nbytes = Vector::<u64>::new();
    let mut ninst = Vector::<u64>::new();
    for i in 0..n {
        let d = lws.at(i).body.owner;
        let b = switch lw_cache.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => *v,
            None => i as u64,
        };
        base.push(b);
        hashes.push(0);
        nrel.push(0);
        nsame.push(0);
        nbytes.push(0);
        ninst.push(0);
    }
    for i in 0..n {
        let b = base[i];
        if b == i as u64 || b >= n as u64 {
            continue;
        }
        let txt = irp::print_body(&lws.at(i).body);
        let ts = txt.as_str();
        let h = fnv(ts);
        hashes.set(i, h);
        let mut same = false;
        for j in 0..i {
            if base[j] == b && base[j] != j as u64 && hashes[j] == h {
                same = true;
                break;
            }
        }
        nrel.set(b as usize, nrel[b as usize] + 1);
        if same {
            nsame.set(b as usize, nsame[b as usize] + 1);
        }
        nbytes.set(b as usize, nbytes[b as usize] + lws.at(i).retained_bytes());
    }
    // Instances: the distinct symbols that emitted from each template.
    let mut seen = Set::<u64>::new();
    for di in 0..cem.demand.len() {
        let ds = cem.demand.at(di).sym.as_str();
        let dk = fnv(ds);
        if !done.contains_key(&dk) || seen.contains(&dk) {
            continue;
        }
        seen.insert(dk);
        let d = cem.demand.at(di).def;
        let b = switch lw_cache.get(&skey_mix(0, d.module as u64 << 32 | d.node as u64)) {
            Some(v) => *v,
            None => n as u64,
        };
        if b < n as u64 {
            ninst.set(b as usize, ninst[b as usize] + 1);
        }
    }
    for b in 0..n {
        if base[b] != b as u64 {
            continue;
        }
        let body = &lws.at(b).body;
        let reflect = body.has_reflect || body.has_lists;
        if !reflect && !body.has_zst_cond {
            continue;
        }
        pr.count(
            if reflect {
                prb::C_INST_REFLECT;
            } else {
                prb::C_INST_ZST;
            },
            ninst[b],
        );
        pr.count(
            if reflect {
                prb::C_SAME_REFLECT;
            } else {
                prb::C_SAME_ZST;
            },
            nsame[b],
        );
        pr.count(
            if reflect {
                prb::C_KEEP_REFLECT;
            } else {
                prb::C_KEEP_ZST;
            },
            nbytes[b],
        );
        let d = body.owner;
        let a = unsafe &*p.module_ast_const(d.module);
        let src = p.modules.at(d.module as usize).source.as_str();
        let nsp = a.at_const(a.ext_name(d.node)).as_data.name.text;
        eprint(
            "cemit-relower {}::{} ({}): {} instances, {} re-lowerings, {} identical, {} KiB retained\n",
            p.modules.at(d.module as usize).path.as_str(),
            src.slice(nsp.start as usize, nsp.end as usize),
            if reflect {
                "reflection";
            } else {
                "zero-size";
            },
            ninst[b],
            nrel[b],
            nsame[b],
            nbytes[b] >> 10,
        );
    }
}

// Take the graph's cached lowering of `(m, nid)` into `lw_out` (the graph lowered every body it
// walked exactly once), lowering in place only when the cache has no live entry. A taken slot is
// removed, so a second taker (a generic body the seed loop lowered and skipped) re-lowers.
// `closure` selects a closure body (`nid` is the closure node) over a function body.
// `__sc_simd_lvl()`, which the dispatch prologues read (`CEmit::dispatch_prologue`): the highest level
// k (1-based) of `simd_levels` whose features the CPU detector reports (`sc_cpu_words`, which
// `SC_CPU_OFF` masks), else 0, read once per TU. Only for a program with vector code: the loader
// links the detector for it.
fn simd_level_fn(p: &loader::Package, out: &mut String) {
    if p.simd_levels.len() == 0 || !p.names_vectors() {
        return;
    }
    out.push_str("void sc_cpu_words(uint64_t __out[2]);\n");
    // `SC_SIMD_LEVEL=<k>` (a test switch) sets the level: a host whose detector hides features it
    // runs (an emulator) runs the copies, and any host the bodies without them.
    out.format_into(
        "static __attribute__((noinline, cold, unused)) unsigned __sc_simd_lvl_init(void) {{\n  const char *__e = getenv(\"SC_SIMD_LEVEL\");\n  if (__e != 0 && *__e >= '0' && *__e <= '9') {{\n    unsigned __k = (unsigned)(*__e - '0');\n    return __k < {} ? __k : {};\n  }}\n  uint64_t __w[2];\n  sc_cpu_words(__w);\n",
        p.simd_levels.len(),
        p.simd_levels.len(),
    );
    let mut k = p.simd_levels.len();
    while k > 0 {
        let w = p.simd_levels[k - 1].w;
        out.format_into(
            "  if ((__w[0] & {}ULL) == {}ULL && (__w[1] & {}ULL) == {}ULL) return {};\n",
            w[0],
            w[0],
            w[1],
            w[1],
            k,
        );
        k -= 1;
    }
    out.push_str("  return 0;\n}\n");
    out.push_str(
        "static inline __attribute__((unused)) unsigned __sc_simd_lvl(void) {\n  static unsigned char __lv = 0xFF;\n  unsigned __v = __atomic_load_n(&__lv, __ATOMIC_RELAXED);\n  if (__builtin_expect(__v == 0xFF, 0)) {\n    __v = __sc_simd_lvl_init();\n    __atomic_store_n(&__lv, (unsigned char)__v, __ATOMIC_RELAXED);\n  }\n  return __v;\n}\n",
    );
}

// The features demand `d`'s body emits under: a feature clone's set, else its function's.
fn demand_set(p: &loader::Package, d: &cbe::Demand) cf::CpuFeatureSet {
    if !cf::is_empty(d.fs) {
        return d.fs;
    }
    return p.fn_set(d.def.module, d.def.node);
}

fn cemit_take_body(
    g: &mut ig::InstGraph,
    p: *const loader::Package,
    m: ModuleId,
    nid: NodeId,
    closure: bool,
    lw_out: &mut irl::Lowerer,
    pr: &mut prb::Probe,
) bool {
    let am = pr.start();
    let key = skey_mix(0, m as u64 << 32 | nid as u64);
    let ki = switch g.kept_ix.get(&key) {
        Some(v) => (*v) as i64,
        None => (-2) as i64,
    };
    if ki >= 0 {
        *lw_out = irl::Lowerer::take_kept(p, g.kept_mut(ki as usize));
        let _ = g.kept_ix.remove(&key);
        pr.count(prb::C_TAKEN, 1);
        pr.stop(prb::P_ACQUIRE, am);
        return true;
    }
    // A feature clone's body, its kept lowering taken by its own emission: the inline store's copy.
    if !closure && unsafe (&*p).inl_store != null {
        let vb = unsafe (*((&*p).inl_store as *const inl::InlineStore)).vec_body(DefId { module: m, node: nid });
        if vb != null {
            lw_out.body = irc::CoreBody::compact_from(unsafe &*vb);
            pr.count(prb::C_TAKEN, 1);
            pr.stop(prb::P_ACQUIRE, am);
            return true;
        }
    }
    let ok = if closure {
        lw_out.lower_closure_body(nid);
    } else {
        lw_out.lower_fn(nid);
    };
    pr.count(prb::C_LOWERED, 1);
    pr.stop(prb::P_ACQUIRE, am);
    return ok;
}

// The roots of the functions a program uses (`InstGraph::reach`): into `fns`, every concrete function
// called from outside the emitted C: the program entry, the runtime (the C runtime calls it), a test
// build's test items, a library build's exported functions, every function of the project's package
// when the build has no entry and no tests (a translation without a program: its functions are its
// interface), and each function C code, the linker or a
// section walk finds by its symbol or its section (`@export`, `@used`, a link section), and the methods
// the emitter's fixed text calls: `Global`'s `alloc` and `dealloc` (closure environments, boxed `dyn`
// values) and `str::from_cstr` (the C `main` wrapper); and every constant or static the emitter defines
// whatever names it.
fn reach_roots(p: &loader::Package, g: &ig::InstGraph, live: *const bool, testing: bool, fns: &mut Vector<DefId>) {
    let mut entry = testing || p.lib_build;
    for m in 0..p.modules.len() {
        if !entry && p.is_root_module(m as ModuleId) && p.modules[m].has_ast {
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            let its = a.at_const(a.root).as_data.program.items;
            for i in 0..its.len {
                let nid = unsafe a.list(its)[i as usize];
                entry = entry || a.at_const(nid).kind == NodeKind::NODE_FUNCTION && p.is_entry(m as ModuleId, nid);
            }
        }
    }
    for m in 0..p.modules.len() {
        if !module_emits(p, live, m) {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let proj = p.modules[m].pkg == loader::PKG_PROJECT;
        let lib = p.lib_build && proj;
        let all = !entry && proj;
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            let n = a.at_const(nid);
            if n.kind == NodeKind::NODE_FUNCTION {
                if reach_root(p, a, m as ModuleId, nid, testing, all || lib && vis_exported(a.ext(nid).function.vis)) {
                    fns.push(DefId { module: m as ModuleId, node: nid });
                }
            } else if n.kind == NodeKind::NODE_CONST {
                // A constant or static the emitter defines whatever names it (`stat_item`'s roots).
                if !n.as_data.const_def.is_extern && reach_root(p, a, m as ModuleId, nid, false, false) {
                    fns.push(DefId { module: m as ModuleId, node: nid });
                }
            } else if n.kind == NodeKind::NODE_EXTEND && a.ext(nid).extend_def.generics.len == 0 {
                let ms = a.ext(nid).extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe a.list(ms)[j as usize];
                    let mn = a.at_const(mid);
                    if mn.kind == NodeKind::NODE_FUNCTION && reach_root(
                        p,
                        a,
                        m as ModuleId,
                        mid,
                        testing,
                        all || lib && vis_exported(a.ext(mid).function.vis),
                    ) {
                        fns.push(DefId { module: m as ModuleId, node: mid });
                    }
                }
            }
        }
    }
    let fixed: [(str, str); 3] = [("Global", "alloc"), ("Global", "dealloc"), ("str", "from_cstr")];
    for (ty, name) in fixed {
        let h = p.prelude_lookup(ty, true);
        if h.node != NODE_NONE {
            let md = g.method_named(DefId { module: h.mid, node: h.node }, name);
            if md.node != NODE_NONE {
                fns.push(md);
            }
        }
    }
}

// Whether function or constant `nid` of module `m` (tree `a`) is a reachability root (`reach_roots`);
// `api`: it is a library build's exported function.
fn reach_root(p: &loader::Package, a: &Ast, m: ModuleId, nid: NodeId, testing: bool, api: bool) bool {
    if api || p.is_rt(m) || a.at_const(nid).kind == NodeKind::NODE_FUNCTION && p.is_entry(m, nid) || testing && is_test_item(
        a,
        nid,
    ) {
        return true;
    }
    return a.attr_of(nid, AttrKind::ATTR_EXPORT) != null || a.attr_of(nid, AttrKind::ATTR_USED) != null || (a.unsafe_claims(
        nid,
    ) & UNSAFE_LINK_SECTION) != 0;
}

// Replay one cached module: pool interns first (verified id by id), then the journaled events
// through the emitter's live dedup gates. 0 = replayed, 1 = clean reject (nothing landed; emit
// live and re-record), 2 = dirty reject (side effects landed; void the section, skip recording).
fn cemit_tuc_replay(p: &mut loader::Package, cem: &mut cbe::CEmit, m: usize, t: &tuc::Tuc, acc: &mut SeedAcc) i32 {
    let mut rd = t.open(m);
    let mut tab = Vector::<tuc::TtEnt>::new();
    if !rd.read_table(&mut tab) {
        // Nothing mutated yet: emit live and re-record.
        return 1;
    }
    let mut idc = Map::<u64, u64>::new();
    let nev = rd.r32() as usize;
    let mut ev = mbe::RecEv::blank(0);
    for _i in 0..nev {
        if !rd.read_ev(&mut ev) || !tuc::ev_patch(p, &tab, &mut idc, &mut ev) {
            return 2;
        }
        if ev.kind == mbe::RK_CHUNK {
            acc.chunk(m as u64, m as ModuleId, &ev.s1, false, &mut cem.mg.rec);
        } else if ev.kind == mbe::RK_ENV {
            acc.env_names.push(ev.h);
            acc.env_bodies.push(ev.s1.clone());
            acc.env_own.push(m as ModuleId);
        } else if ev.kind == mbe::RK_AUX {
            cem.aux_replay(ev.h, ev.a as ModuleId, ev.s1.as_str());
        } else if ev.kind == mbe::RK_EFWD {
            cem.env_fwd.push_str(ev.s1.as_str());
        } else if ev.kind == mbe::RK_EDGE {
            for k in 0..ev.xs.len() {
                cem.mg.mark_used(ev.xs[k] as ModuleId);
            }
        } else if ev.kind == mbe::RK_TNEED {
            let mut k: usize = 0;
            while k + 1 < ev.xs.len() {
                let key = ev.xs[k] as u64 | ev.xs[k + 1] as u64 << 32;
                cem.mg.need_name(key, (key & 1) != 0);
                k += 2;
            }
        } else if ev.kind == mbe::RK_HEDGE {
            cem.hdr_k.push(ev.a as ModuleId);
            cem.hdr_h.push(ev.h);
        } else if ev.kind == mbe::RK_MAIN {
            acc.have_main = true;
            acc.main_mod = m as u64;
            acc.main_argv = ev.a != 0;
        } else if ev.kind == mbe::RK_FNREF {
            cem.mg.fn_ref(ev.a as ModuleId, ev.b);
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
    pr: &mut prb::Probe,
) bool {
    if kl != null {
        (unsafe &*kl).acquire_masked();
    }
    let r = cemit_take_body(&mut *g, p, m, nid, closure, lw, pr);
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
    acc: &mut SeedAcc,
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
            let ms = a.ext(nid).extend_def.items;
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
        // The seed pass emits the functions the reachability walk predicts (`fn_pred`); a function
        // only the emitted text names comes later (`cemit_drain_late`).
        if cem.mg.fn_pred != null && !unsafe (*cem.mg.fn_pred).contains(&(m as u64 << 32 | nid as u64)) {
            continue;
        }
        cemit_seed_fn(p, cem, g, dow, cl_cache, clws, m, nid, testing, verbose, kl, acc);
    }
}

// Whether `cemit_seed_fn` lowers function `nid` of module `m` (and emits it unless the body is
// generic). Not an extern or bodyless function; not a vector-backend entry (its definition is its definition header,
// `cemit_simd_entries`) nor, on wasm32, a function needing features the build lacks (no call reaches
// it, and its body may name them); not a test item outside --test; not a generic extend's member
// (its instances are demand-emitted).
fn seed_emits(p: &loader::Package, cem: &mut cbe::CEmit, m: ModuleId, nid: NodeId, testing: bool) bool {
    let a = unsafe &*p.module_ast_const(m);
    let n = a.at_const(nid);
    if n.kind != NodeKind::NODE_FUNCTION || a.ext(nid).function.is_extern() || a.ext(nid).function.body == NODE_NONE {
        return false;
    }
    if a.ext(nid).function.needs_features() && (a.attr_of(nid, AttrKind::ATTR_SIMD_IMPL) != null || !tgt::isa(p.arch).fn_features && !cf::contains(
        p.features,
        p.fn_features(m, nid),
    )) {
        return false;
    }
    return (testing || !is_test_item(a, nid)) && !cem.mg.in_generic_extend(m, nid);
}

// Emit concrete function `nid` of module `m` (a top-level function or a method of a non-generic
// extend) as chunks of `m`'s TU, with its closures; a function the build does not emit (extern,
// bodyless, a vector-backend entry, a test item outside --test, a generic extend's member) adds nothing.
fn cemit_seed_fn(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    cl_cache: &mut Map<u64, u64>,
    clws: &mut Vector<irl::Lowerer>,
    m: usize,
    nid: NodeId,
    testing: bool,
    verbose: bool,
    kl: *const psync::Semaphore,
    acc: &mut SeedAcc,
) {
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    if !seed_emits(p, cem, m as ModuleId, nid, testing) {
        return;
    }
    let mut lw = irl::Lowerer::new(p, m as ModuleId, nid);
    if !cemit_seed_take(g, p, m as ModuleId, nid, &mut lw, kl, false, &mut dow.pr) {
        return;
    }
    if lw.body.is_generic {
        return;
    }
    dow.apply_drops(&mut lw);
    if !dow.inl.off && inl::holds_vector(&lw.body, p) {
        // A call a splice brought through an interface binds and inlines too.
        let mut sites = Vector::<BoundSite>::new();
        bind_calls(cem, dow, &mut lw, &mut sites);
    }
    let mut sym = String::new();
    let sm9 = cem.pr.start();
    let tgt = cem.mg.method_target(m as ModuleId, nid);
    let sym_ok9 = cem.mg.fn_sym(m as ModuleId, nid, tgt, &mut sym);
    cem.pr.stop(prb::P_SYM, sm9);
    if !sym_ok9 {
        return;
    }
    if sym.as_str() == "assert" || sym.as_str() == "assert_eq" || sym.as_str() == "assert_ne" {
        // Desugared builtins; the C names collide with <assert.h>'s macro.
        return;
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
    let mut gns = Vector::<NodeId>::new();
    let is_glue = cemit_free_glue_fields(p, cem, m as ModuleId, nid, &mut gfs, &mut gts, &mut gns);
    if is_glue {
        sym.push_str("__fb");
    }
    cem.noret = a.attr_of(nid, AttrKind::ATTR_NORETURN) != null;
    cem.fn_attrs.truncate(0);
    cem.fs = p.fn_set(m as ModuleId, nid);
    cemit_fn_attrs(p, m as ModuleId, nid, cem.fs, &mut cem.fn_attrs);
    if cem.emit_fn(&lw.body, sym.as_str()) {
        acc.seeds += 1;
        if is_main {
            acc.have_main = true;
            acc.main_mod = m as u64;
            acc.main_argv = a.ext(nid).function.params.len != 0;
            if cem.mg.rec_on {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_MAIN);
                ev9.a = acc.main_argv as u32;
                cem.mg.rec.push(ev9);
            }
        }
        acc.chunk(m as u64, m as ModuleId, &cem.out, cem.mg.rec_on, &mut cem.mg.rec);
        cem.lir_claim(m as u32, "a function", true);
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
                acc.chunk(m as u64, m as ModuleId, &wr, cem.mg.rec_on, &mut cem.mg.rec);
                let tgt9 = cem.mg.method_target(m as ModuleId, nid);
                let a9 = unsafe &mut *(p.module_ast_const(m as ModuleId) as *mut Ast);
                let st9 = a9.intern_type(
                    Ty { kind: TypeKind::TYPE_STRUCT, module: m as ModuleId, as_data: TyAs { decl: tgt9.node } },
                );
                let wsym = sym.as_str().slice(0, sym.len() - 4);
                cem.lir_free_wrapper(m as ModuleId, st9, wsym, sym.as_str(), gns[0..gns.len()]);
                cem.lir_claim(m as u32, "a `free` wrapper", true);
            }
        }
        cemit_closure_queue(
            p,
            cem,
            g,
            dow,
            cl_cache,
            clws,
            kl,
            m as ModuleId,
            m as u64,
            &lw.closures,
            cem.mg.rec_on,
            acc,
        );
    } else {
        acc.seed_skip += 1;
        if verbose {
            eprint("seed-emit-fail: `{}` {}\n", sym.as_str(), cem.err);
        }
    }
}

// Emit the closures `roots` of one emitted body, then the closures nested in them, in queue order.
// Each closure is lowered once (`cl_cache` maps it to its slot in `clws`), lands in `ch` under chunk
// key `key`, and puts its environment struct, if any, in the env vectors. `rec` journals both
// for the per-TU cache.
fn cemit_closure_queue(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    cl_cache: &mut Map<u64, u64>,
    clws: &mut Vector<irl::Lowerer>,
    kl: *const psync::Semaphore,
    m: ModuleId,
    key: u64,
    roots: &Vector<NodeId>,
    rec: bool,
    acc: &mut SeedAcc,
) {
    let mut clsq = roots.clone();
    let mut cqi: usize = 0;
    while cqi < clsq.len() {
        let cn = clsq[cqi];
        cqi += 1;
        let ckey = skey_mix(0, m as u64 << 32 | cn as u64);
        let ci = switch cl_cache.get(&ckey) {
            Some(v) => *v,
            None => {
                let mut cl = irl::Lowerer::new(p, m, cn);
                let mut slot = 0xFFFFFFFFFFFFFFFFu64;
                if cemit_seed_take(g, p, m, cn, &mut cl, kl, true, &mut dow.pr) {
                    dow.apply_drops(&mut cl);
                    slot = clws.len() as u64;
                    clws.push(cl);
                }
                cl_cache.insert(ckey, slot);
                slot;
            },
        };
        let clp: *const irl::Lowerer = if ci != 0xFFFFFFFFFFFFFFFFu64 {
            clws.at(ci as usize);
        } else {
            null;
        };
        let mut csym = String::new();
        let mut envs = String::new();
        if !cemit_queued_closure(cem, m, cn, clp, &mut clsq, &mut csym, &mut envs) {
            acc.clos_skip += 1;
            continue;
        }
        acc.clos_ok += 1;
        if envs.len() != 0 {
            let eh9 = fnv_cont(fnv(csym.as_str()), "_env");
            if rec {
                let mut ev9 = mbe::RecEv::blank(mbe::RK_ENV);
                ev9.h = eh9;
                ev9.s1 = envs.clone();
                cem.mg.rec.push(ev9);
            }
            acc.env_names.push(eh9);
            acc.env_bodies.push(envs);
            acc.env_own.push(m);
        }
        acc.chunk(key, m, &cem.out, rec, &mut cem.mg.rec);
        cem.lir_claim(m, "a closure", key != 65534);
    }
}

// One queued closure: spell its symbol into `csym`, queue the closures nested in its lowering `clp`
// (null: it did not lower), and emit it into `cem.out`, its environment struct into `envs`.
fn cemit_queued_closure(
    cem: &mut cbe::CEmit,
    m: ModuleId,
    cn: NodeId,
    clp: *const irl::Lowerer,
    clsq: &mut Vector<NodeId>,
    csym: &mut String,
    envs: &mut String,
) bool {
    cem.mg.closure_sym(m, cn, csym);
    cem.out.clear();
    if clp == null {
        return false;
    }
    let cl = unsafe &*clp;
    for x in 0..cl.closures.len() {
        clsq.push(cl.closures[x]);
    }
    return cem.emit_closure(&cl.body, m, cn, csym.as_str(), envs);
}

struct SeedShard {
    pub(package) cem: cbe::CEmit,
    // Seed shards: module m's chunks in m's own buffer. Drain shards: this slice's instance-TU
    // chunks, in the one buffer of a TuBufs::new(0).
    pub(package) acc: SeedAcc,
    pub(package) used: bool,
    // Drain-slice state: one shard per SLICE of a wave in the parallel instance frontier;
    // per-demand capture marks let the merge replay each demand's claims at its exact queue slot.
    pub(package) dmarks: Vector<CapMark>,
    pub(package) douts: Vector<u8>, // per demand: 0 = emitted, 1 = lowering-path skip, 2 = emit failure, 3 = emitted with a program error the merge reports
    pub(package) derrs: Vector<str<'static>>,
    pub(package) dvix: Vector<u64>, // per demand: index into dvars (0xFF.. = none)
    pub(package) dvkeys: Vector<u64>, // per dvars entry: the zst-signature cache key
    pub(package) dvars: Vector<irl::Lowerer>,
    pub(package) dclo_keys: Vector<u64>, // closure lowerings this slice produced on a shared-cache miss
    pub(package) dclo: Vector<irl::Lowerer>,
}

// Counts of a drain shard's capture rows and sink sizes at one demand boundary; every row carries
// its absolute text end, so counts alone define a replayable range.
struct CapMark {
    pub(package) env: u32,
    pub(package) stat: u32,
    pub(package) glue: u32,
    pub(package) ext: u32,
    pub(package) dyd: u32,
    pub(package) dyt: u32,
    pub(package) blk: u32,
    pub(package) sent: u32,
    pub(package) ti: u32,
    pub(package) aux: u32,
    pub(package) dem: u32,
    pub(package) agg: u32,
    pub(package) dynr: u32,
    pub(package) wrap: u32,
    pub(package) pack: u32,
    pub(package) chunks: u32,
    pub(package) bodies: u64,
    pub(package) protos: u64,
    pub(package) envn: u32,
    pub(package) dclo: u32,
    pub(package) hedge: u32,
    pub(package) fndem: u32,
}

const fn cap_zero() CapMark {
    return CapMark {
        env: 0,
        stat: 0,
        glue: 0,
        ext: 0,
        dyd: 0,
        dyt: 0,
        blk: 0,
        sent: 0,
        ti: 0,
        aux: 0,
        dem: 0,
        agg: 0,
        dynr: 0,
        wrap: 0,
        pack: 0,
        chunks: 0,
        bodies: 0,
        protos: 0,
        envn: 0,
        dclo: 0,
        hedge: 0,
        fndem: 0,
    };
}

extend SeedShard {
    /// A shard rendering into `ch`. A `used` one collects demands, skips the environments and
    /// extern-backed keys the master already has, and marks symbol uses as context `ctx`.
    fn new(
        p: *const loader::Package,
        ch: TuBufs,
        used: bool,
        env_defined: &Vector<u64>,
        ext_keys: &Vector<u64>,
        ctx: i64,
        pred: *const Set<u64>,
    ) SeedShard {
        let mut sh = SeedShard {
            cem: cbe::CEmit::new(p),
            acc: SeedAcc::new(ch),
            used: used,
            dmarks: Vector::<CapMark>::new(),
            douts: Vector::<u8>::new(),
            derrs: Vector::<str<'static>>::new(),
            dvix: Vector::<u64>::new(),
            dvkeys: Vector::<u64>::new(),
            dvars: Vector::<irl::Lowerer>::new(),
            dclo_keys: Vector::<u64>::new(),
            dclo: Vector::<irl::Lowerer>::new(),
        };
        sh.cem.mg.fn_pred = pred;
        if used {
            sh.cem.collect_demand = true;
            sh.cem.mg.agg_on = true;
            for ei in 0..env_defined.len() {
                sh.cem.env_skip.insert(env_defined[ei], 1);
            }
            for k in 0..ext_keys.len() {
                sh.cem.ext_backed.insert(ext_keys[k]);
            }
            sh.cem.sh_on = true;
            sh.cem.mg.sh_on = true;
            sh.cem.mg.mark_ctx = ctx;
        }
        return sh;
    }

    const fn cap_of(self: &Self) CapMark {
        let sc = &self.cem;
        return CapMark {
            env: sc.sh_env_k.len() as u32,
            stat: sc.sh_stat_k.len() as u32,
            glue: sc.sh_glue_k.len() as u32,
            ext: sc.sh_ext_k.len() as u32,
            dyd: sc.sh_dyd_k.len() as u32,
            dyt: sc.sh_dyt_k.len() as u32,
            blk: sc.sh_blk_k.len() as u32,
            sent: sc.sh_sent_k.len() as u32,
            ti: sc.sh_ti_k.len() as u32,
            aux: sc.sh_aux_k.len() as u32,
            dem: sc.demand.len() as u32,
            agg: sc.mg.sh_agg_k.len() as u32,
            dynr: sc.mg.dyn_reqs.len() as u32,
            wrap: sc.mg.wrap_reqs.len() as u32,
            pack: sc.mg.pack_reqs.len() as u32,
            chunks: self.acc.ch.chunk_mod.len() as u32,
            bodies: self.acc.ch.bufs.at(0).len() as u64,
            protos: self.acc.protos.len() as u64,
            envn: self.acc.env_names.len() as u32,
            dclo: self.dclo_keys.len() as u32,
            hedge: sc.hdr_k.len() as u32,
            fndem: sc.mg.fn_dem.len() as u32,
        };
    }
}

struct SeedTask {
    pub(package) p: *mut loader::Package,
    pub(package) ctl: *const tctl::Ctl,
    pub(package) est: u64,
    pub(package) g: *mut ig::InstGraph,
    pub(package) out: *mut SeedShard,
    pub(package) m: usize,
    pub(package) testing: bool,
    pub(package) verbose: bool,
    pub(package) kl: *const psync::Semaphore,
}

unsafe extend SeedTask as Send {}

fn cemit_seed_task(t: SeedTask) {
    let mut dow = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let o = unsafe &mut *t.out;
    let g9 = t.g;
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
        &mut o.acc,
    );
    if t.ctl != null {
        (unsafe &*t.ctl).release(t.est);
    }
    dctx_put(dow);
}

// Lower `lw`'s definition `node` again under the instantiation `subs` (a reflection binder or a
// ZST-conditional body lowers per instance), drops applied on success; timed as probe phase `ph`
// and counted as `ct` in `dow.pr`.
fn relower(lw: &mut irl::Lowerer, node: NodeId, subs: &Vector<mbe::MSub>, dow: &mut DropCtx, ph: usize, ct: usize) bool {
    for i in 0..subs.len() {
        let sb = *subs.at(i);
        lw.env.push(irl::LSub { pm: sb.pm, pnode: sb.pnode, am: sb.am, at: sb.at });
    }
    let t0 = dow.pr.start();
    let ok = lw.lower_fn(node);
    dow.pr.stop(ph, t0);
    dow.pr.count(ct, 1);
    if ok {
        dow.apply_drops(lw);
    }
    return ok;
}

// The bound variant of instance body `base` under `subs`: when a call of an interface method through a
// type parameter dispatches, for this instance, to a conformance method the inliner keeps
// (`CEmit::bound_target`), the body grounded for the instance (`inl::ground_body`) calls that method
// directly and inlines it, for up to `inl::MAX_DEPTH` rounds of the calls the splices bring (`bind_calls`;
// in scalar code only the methods whose result the instance fixes, `G::len()` of `Vec<T, 3>`: a
// constant of the instance). None when no call qualifies or the body does not ground.
fn bound_variant(cem: &mut cbe::CEmit, dow: &mut DropCtx, base: &irl::Lowerer, subs: &Vector<mbe::MSub>) Option<
    irl::Lowerer
> {
    if dow.inl.off {
        return Option::<irl::Lowerer>::None;
    }
    cem.mg.clear_subs();
    for i in 0..subs.len() {
        cem.mg.push_msub(*subs.at(i));
    }
    let r = bound_variant_in(cem, dow, base, subs);
    cem.mg.clear_subs();
    return r;
}

fn bound_variant_in(cem: &mut cbe::CEmit, dow: &mut DropCtx, base: &irl::Lowerer, subs: &Vector<mbe::MSub>) Option<
    irl::Lowerer
> {
    let mut sites = Vector::<BoundSite>::new();
    dow.inl.only_fixed = !inl::holds_vector(&base.body, base.pkg);
    bound_calls(cem, dow, base.pkg, &base.body, &mut sites);
    dow.inl.only_fixed = false;
    if sites.len() == 0 {
        return Option::<irl::Lowerer>::None;
    }
    let m = base.body.module;
    // Innermost first: the first binding of a parameter wins.
    let mut binds = Vector::<inl::GBind>::new();
    let mut i = subs.len();
    while i > 0 {
        i -= 1;
        let sb = *subs.at(i);
        let mut g = TYPE_NONE;
        if cem.mg.ground(sb.am, sb.at, m, &mut g) {
            binds.push(inl::GBind { pm: sb.pm, pnode: sb.pnode, at: g });
        }
    }
    let mut out = irl::Lowerer::new(base.pkg, m, base.body.owner.node);
    out.body = irc::CoreBody::compact_from(&base.body);
    out.closures = base.closures.clone();
    if !inl::ground_body(&mut out, &binds) {
        return Option::<irl::Lowerer>::None;
    }
    bind_calls(cem, dow, &mut out, &mut sites);
    return Option::<irl::Lowerer>::Some(out);
}

// The calls of concrete body `lw` that dispatch through an interface to a method the inliner keeps
// (`bound_calls`, scratch `sites`) call it directly and inline, for up to `inl::MAX_DEPTH` rounds of
// the calls the splices bring: a round inlines to `inl::MAX_DEPTH` levels, the next goes on from
// where its depth stopped. Nothing changes when no call binds at first. In a body without vectors
// only the methods whose result the instance fixes bind and inline (`inl::InlineCtx::fixed_result`):
// the C compiler inlines the rest after the link, where splicing them earlier made some loops slower.
fn bind_calls(cem: &mut cbe::CEmit, dow: &mut DropCtx, lw: &mut irl::Lowerer, sites: &mut Vector<BoundSite>) {
    let fixed = !inl::holds_vector(&lw.body, lw.pkg);
    dow.inl.only_fixed = fixed;
    bind_rounds(cem, dow, lw, sites);
    dow.inl.only_fixed = false;
}

fn bind_rounds(cem: &mut cbe::CEmit, dow: &mut DropCtx, lw: &mut irl::Lowerer, sites: &mut Vector<BoundSite>) {
    for r in 0..inl::MAX_DEPTH {
        bound_calls(cem, dow, lw.pkg, &lw.body, sites);
        if r == 0 && sites.len() == 0 {
            return;
        }
        for k in 0..sites.len() {
            let st = *sites.at(k);
            let tm = &mut lw.body.blocks.index_mut(st.blk as usize).term;
            tm.callee = st.md;
            tm.iface = TYPE_NONE;
            tm.recv = st.recv;
            tm.targs_start += tm.targs_len - st.own;
            tm.targs_len = st.own;
        }
        if dow.apply_drops(lw) == 0 {
            return;
        }
    }
}

// A call `bound_calls` found: its block, the method it dispatches to, the receiver, and the method's
// own type-argument count.
struct BoundSite {
    pub(package) blk: u32,
    pub(package) md: DefId,
    pub(package) recv: TypeId,
    pub(package) own: u32,
}

// The calls of `b` whose interface method dispatches to a method the inliner keeps
// (`bound_variant`), into `sites`: each becomes a direct call of that method, with the receiver
// and the method's own type arguments (the call's trailing ones).
fn bound_calls(
    cem: &mut cbe::CEmit,
    dow: &DropCtx,
    pkg: *const loader::Package,
    b: &irc::CoreBody,
    sites: &mut Vector<BoundSite>,
) {
    sites.clear();
    for i in 0..b.blocks.len() {
        let t = b.blocks.at(i).term;
        let mut rv = TYPE_NONE;
        let md = cem.bound_target(b, &t, &mut rv);
        if md.node == NODE_NONE || !dow.inl.kept(md) || dow.inl.only_fixed && !dow.inl.fixed_result(pkg, md) && !inl::always_native(
            pkg,
            md,
        ) {
            continue;
        }
        let own = (unsafe &*(&*pkg).module_ast_const(md.module)).ext(md.node).function.generics.len;
        if t.targs_len >= own {
            sites.push(BoundSite { blk: i as u32, md: md, recv: rv, own: own });
        }
    }
}

// The re-lowering cache key of definition `d` under `subs`: one bit per type argument (ZST or not),
// the only part of an instantiation a ZST-conditional body's lowering depends on.
fn zst_key(mg: &mut mbe::Mangler, d: DefId, subs: &Vector<mbe::MSub>) u64 {
    let mut zb: u64 = 1;
    for i in 0..subs.len() {
        let sb = *subs.at(i);
        zb = zb << 1 | mg.is_zst(sb.am, sb.at) as u64;
    }
    return skey_mix(skey_mix(0, d.module as u64 << 32 | d.node as u64), zb);
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
    acc: &mut SeedAcc,
    reasons: &mut Vector<str<'static>>,
    rcounts: &mut Vector<u64>,
) {
    let d_def = cem.demand.at(di).def;
    let ds = cem.demand.at(di).sym.as_str();
    let dk = fnv(ds);
    // Dedup on SUCCESS only: two demands for one symbol can carry different substitution
    // chains, and the first may be the incomplete one; a later, fuller chain must retry.
    let seen = done.contains_key(&dk);
    if seen {
        return;
    }
    let d_sym = cem.demand.at(di).sym.clone();
    let d_subs = mbe::subs_copy(&cem.demand.at(di).subs);
    let key = skey_mix(0, d_def.module as u64 << 32 | d_def.node as u64);
    let li = switch lw_cache.get(&key) {
        Some(v) => *v,
        None => {
            let mut lw = irl::Lowerer::new(p, d_def.module, d_def.node);
            let okl = cemit_take_body(&mut *g, p, d_def.module, d_def.node, false, &mut lw, &mut dow.pr);
            let mut slot = 0xFFFFFFFFFFFFFFFFu64;
            if okl {
                count_template(&lw.body, &mut dow.pr);
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
        acc.inst_skip += 1;
        return;
    }
    let d_sfx = cem.demand.at(di).sfx.clone();
    // Per-instantiation static_asserts: under this demand's substitution the condition is
    // this instance's compile-time fact; false is a COMPILE error naming the type argument.
    cemit_inst_asserts(p, &mut cem.mg, d_def, &d_subs, dk, sa_seen, ia_idx, ia_built);
    // A body with an UNEXPANDED reflection binder re-lowers per instance: the demand env
    // makes the binder's owner concrete, so the copies expand for real. A body whose only
    // env-dependence is `sizeof(T) <op> 0` branches re-lowers once per ZST-BIT SIGNATURE of
    // its args; every material instantiation folds identically and shares one body.
    let mut li2 = li;
    // The reflection re-lowering serves this demand only; its slots, from `own_at` on, are dropped at
    // the end.
    let mut own_slot = false;
    let mut own_at: u64 = 0;
    if lws.at(li as usize).body.has_reflect || lws.at(li as usize).body.has_lists {
        let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
        let okr9 = relower(&mut lw2, d_def.node, &d_subs, dow, prb::P_RELOWER_REFLECT, prb::C_RELOWER_REFLECT);
        if okr9 {
            cemit_inst_error(p, d_def, &d_subs, &lw2);
            lws.push(lw2);
            li2 = lws.len() as u64 - 1;
            own_slot = true;
            own_at = li2;
        } else {
            if verbose {
                eprint("inst-lower-fail: `{}` {}\n", d_sym.as_str(), lw2.err);
            }
            acc.inst_skip += 1;
            return;
        }
    } else if lws.at(li as usize).body.has_zst_cond {
        let zkey = zst_key(&mut cem.mg, d_def, &d_subs);
        let zi = switch lw_cache.get(&zkey) {
            Some(v) => *v,
            None => {
                let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
                let mut slot2 = 0xFFFFFFFFFFFFFFFFu64;
                let okr9 = relower(&mut lw2, d_def.node, &d_subs, dow, prb::P_RELOWER_ZST, prb::C_RELOWER_ZST);
                if okr9 {
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
            acc.inst_skip += 1;
            return;
        }
        li2 = zi;
    }
    // The bound variant serves this demand only, as the reflection re-lowering does.
    switch bound_variant(cem, dow, lws.at(li2 as usize), &d_subs) {
        Some(bv) => {
            if !own_slot {
                own_slot = true;
                own_at = lws.len() as u64;
            }
            lws.push(bv);
            li2 = lws.len() as u64 - 1;
        },
        None => {},
    };
    cem.mg.clear_subs();
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
    cem.fs = demand_set(p, cem.demand.at(di));
    cemit_fn_attrs(p, d_def.module, d_def.node, cem.fs, &mut cem.fn_attrs);
    // The instance lands in its generic's module instance shard: spell under that context.
    cem.mg.mark_ctx = mbe::CTX_INST | d_def.module as i64;
    let em_ok9 = cem.emit_fn(&lws.at(li2 as usize).body, d_sym.as_str());
    cem.cf_ext = null;
    if em_ok9 {
        done.insert(dk, 1);
        acc.inst_ok += 1;
        cem.pr.count(prb::C_INSTANCES, 1);
        acc.chunk(65534, d_def.module, &cem.out, false, &mut cem.mg.rec);
        cem.lir_claim(d_def.module, "an instance", false);
        cemit_closure_queue(
            p,
            cem,
            g,
            dow,
            cl_cache,
            clws,
            null,
            d_def.module,
            65534,
            &lws.at(li2 as usize).closures,
            false,
            acc,
        );
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
    cem.mg.clear_subs();
    cem.mg.clos_sfx.truncate(0);
    cem.mg.clos_ids.truncate(0);
    if own_slot {
        lws.truncate(own_at as usize);
        cfs.truncate(own_at as usize);
        cf_ok.truncate(own_at as usize);
    }
}

// One demanded instance emitted into a private shard by the parallel instance frontier. Shared
// caches are READ-ONLY during a wave (the master mutates them only at merge).
struct DrainTask {
    pub(package) p: *mut loader::Package,
    pub(package) g: *mut ig::InstGraph,
    pub(package) out: *mut SeedShard,
    pub(package) dem: *const Vector<cbe::Demand>, // frozen during the wave, like the five below
    pub(package) lws: *const Vector<irl::Lowerer>,
    pub(package) cfs: *const Vector<cfl::CFlow>,
    pub(package) lwc: *const Map<u64, u64>, // lw_cache
    pub(package) clc: *const Map<u64, u64>, // cl_cache
    pub(package) clw: *const Vector<irl::Lowerer>, // clws
    pub(package) widx: *const u64, // tasked demand indices, ascending
    pub(package) wli: *const u64, // their base lowering slots
    pub(package) lo: u64, // this slice: widx[lo..hi)
    pub(package) hi: u64,
    pub(package) kl: *const psync::Semaphore,
    pub(package) verbose: bool,
}

unsafe extend DrainTask as Send {}

fn cemit_drain_task(t: DrainTask) {
    // One drop/inline context for the whole task: the inliner's vetted-callee cache is the
    // expensive part (each miss lowers and copies the callee); per-demand contexts rebuilt it
    // from nothing.
    let mut dow = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let o = unsafe &mut *t.out;
    let dem = unsafe &*t.dem;
    let lws = unsafe &*t.lws;
    let cfs = unsafe &*t.cfs;
    let lwc = unsafe &*t.lwc;
    let clc = unsafe &*t.clc;
    let clws0 = unsafe &*t.clw;
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
    gv: *mut ig::InstGraph,
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
    // The demand vector is frozen during the wave: read the demand in place.
    let d_def = dem.at(di).def;
    let d_sym = dem.at(di).sym.as_str();
    let d_subs = &dem.at(di).subs;
    let d_sfx = dem.at(di).sfx.as_str();
    let mut var_on = false;
    let mut user_err = false;
    let mut var_zkey: u64 = 0;
    let mut var_lw = irl::Lowerer::new(p, 0, NODE_NONE);
    let mut li2 = li;
    let mut cfp: *const cfl::CFlow = null;
    let mut cf_own = cfl::CFlow::new_empty();
    if lws.at(li as usize).body.has_reflect || lws.at(li as usize).body.has_lists {
        let mut lw2 = irl::Lowerer::new(p, d_def.module, d_def.node);
        let okr9 = relower(&mut lw2, d_def.node, d_subs, dow2, prb::P_RELOWER_REFLECT, prb::C_RELOWER_REFLECT);
        if okr9 {
            // A program error is reported in demand order by the merge (`cemit_inst_error`).
            user_err = lw2.user_err != NODE_NONE;
            var_on = true;
            var_lw = lw2;
        } else {
            if verbose {
                eprint("inst-lower-fail: `{}` {}\n", d_sym, lw2.err);
            }
            o.douts.push(1);
            o.derrs.push("");
            o.dvix.push(0xFFFFFFFFFFFFFFFFu64);
            return;
        }
    } else if lws.at(li as usize).body.has_zst_cond {
        let sh0 = &mut o.cem;
        let zkey = zst_key(&mut sh0.mg, d_def, d_subs);
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
                let okr9 = relower(&mut lw2, d_def.node, d_subs, dow2, prb::P_RELOWER_ZST, prb::C_RELOWER_ZST);
                if okr9 {
                    var_on = true;
                    var_zkey = zkey;
                    var_lw = lw2;
                } else {
                    if verbose {
                        eprint("inst-lower-fail: `{}` {}\n", d_sym, lw2.err);
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
    // The bound variant serves this demand only: it stays out of the slice's variants.
    let base = if var_on {
        o.dvars.at(vix as usize);
    } else {
        lws.at(li2 as usize);
    };
    let mut bvs = Vector::<irl::Lowerer>::new();
    switch bound_variant(&mut o.cem, dow2, base, d_subs) {
        Some(x) => bvs.push(x),
        None => {},
    };
    let bv_on = bvs.len() != 0;
    let sh = &mut o.cem;
    sh.mg.mark_ctx = mbe::CTX_INST | d_def.module as i64;
    sh.mg.clear_subs();
    for i2 in 0..d_subs.len() {
        sh.mg.push_msub(*d_subs.at(i2));
    }
    sh.mg.clos_sfx.truncate(0);
    sh.mg.clos_sfx.push_str(d_sfx);
    sh.mg.clos_ids.truncate(0);
    let blw = if bv_on {
        bvs.at(0);
    } else if var_on {
        o.dvars.at(vix as usize);
    } else {
        lws.at(li2 as usize);
    };
    for c2 in 0..blw.closures.len() {
        sh.mg.clos_ids.push(blw.closures[c2]);
    }
    if bv_on || var_on {
        cf_own.build_into(&blw.body);
        cfp = &cf_own;
    } else {
        cfp = cfs.at(li2 as usize);
    }
    sh.cf_ext = cfp;
    sh.out.clear();
    sh.fn_attrs.truncate(0);
    sh.fs = demand_set(p, dem.at(di));
    cemit_fn_attrs(p, d_def.module, d_def.node, sh.fs, &mut sh.fn_attrs);
    let em_ok9 = sh.emit_fn(&blw.body, d_sym);
    sh.cf_ext = null;
    if !em_ok9 {
        o.douts.push(2);
        o.derrs.push(sh.err);
        if li2 != 0xFFFFFFFFFFFFFFFFu64 || !var_on {
            o.dvix.push(vix);
        }
        return;
    }
    o.douts.push(pick(user_err, 3u8, 0u8));
    o.derrs.push("");
    if li2 != 0xFFFFFFFFFFFFFFFFu64 || !var_on {
        o.dvix.push(vix);
    }
    proto_of(&sh.out, &mut o.acc.protos);
    o.acc.ch.add(65534, d_def.module, &sh.out);
    sh.lir_claim(d_def.module, "an instance", false);
    let mut clsq = Vector::<NodeId>::new();
    for c2 in 0..blw.closures.len() {
        clsq.push(blw.closures[c2]);
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
                if cemit_seed_take(unsafe &mut *gv, p, d_def.module, cn, &mut cl, kl, true, &mut dow2.pr) {
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
        let clp: *const irl::Lowerer = if shared_ci < 0xFFFFFFFFFFFFFFFEu64 {
            clws0.at(shared_ci as usize);
        } else if own_ci != 0xFFFFFFFFFFFFFFFFu64 {
            o.dclo.at(own_ci as usize);
        } else {
            null;
        };
        let mut csym = String::new();
        let mut envs = String::new();
        if cemit_queued_closure(sh, d_def.module, cn, clp, &mut clsq, &mut csym, &mut envs) {
            o.acc.clos_ok += 1;
            if envs.len() != 0 {
                o.acc.env_names.push(fnv_cont(fnv(csym.as_str()), "_env"));
                o.acc.env_bodies.push(envs);
                o.acc.env_own.push(d_def.module);
            }
            proto_of(&sh.out, &mut o.acc.protos);
            o.acc.ch.add(65534, d_def.module, &sh.out);
            sh.lir_claim(d_def.module, "a closure", false);
        } else {
            o.acc.clos_skip += 1;
        }
    }
    sh.mg.clear_subs();
    sh.mg.clos_sfx.truncate(0);
    sh.mg.clos_ids.truncate(0);
}

// One slice of a wave's unique base-definition lowerings; results land in disjoint slots.
struct LowTask {
    pub(package) p: *mut loader::Package,
    pub(package) g: *mut ig::InstGraph,
    pub(package) defs: *const u64, // packed module << 32 | node
    pub(package) res: *mut irl::Lowerer, // slot base (disjoint writes per index)
    pub(package) cfr: *mut cfl::CFlow, // slot base
    pub(package) oks: *mut bool,
    pub(package) lo: u64,
    pub(package) hi: u64,
    pub(package) kl: *const psync::Semaphore,
}

unsafe extend LowTask as Send {}

fn cemit_low_task(t: LowTask) {
    let mut dow2 = dctx_take(t.p);
    let p = unsafe &mut *t.p;
    let res = t.res;
    let cfr = t.cfr;
    for i in t.lo..t.hi {
        let dv = unsafe t.defs[i as usize];
        let m = (dv >> 32) as ModuleId;
        let n = (dv & 0xFFFFFFFFu64) as NodeId;
        let mut lw = irl::Lowerer::new(p, m, n);
        let ok = cemit_seed_take(unsafe &mut *t.g, p, m, n, &mut lw, t.kl, false, &mut dow2.pr);
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
    let resb = res.index_mut(0) as *mut irl::Lowerer;
    let cfrb = cfr.index_mut(0) as *mut cfl::CFlow;
    let oksb = oks.index_mut(0) as *mut bool;
    let defb = defs.as_ptr();
    let ppd = p as *mut loader::Package;
    let ggd = g as *mut ig::InstGraph;
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
    let ggd = g as *mut ig::InstGraph;
    let klp9 = (kl9 as *mut psync::Semaphore) as *const psync::Semaphore;
    let demp = (&cem.demand) as *const Vector<cbe::Demand>;
    let lwsp = lws as *const Vector<irl::Lowerer>;
    let cfsp = cfs as *const Vector<cfl::CFlow>;
    let lwcp = lw_cache as *const Map<u64, u64>;
    let clcp = cl_cache as *const Map<u64, u64>;
    let clwp = clws as *const Vector<irl::Lowerer>;
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
    cem.mg.sh_merge_inst(&o.cem.mg);
    cemit_take_refused(cem, o);
}

fn cemit_take_refused(cem: &mut cbe::CEmit, o: &mut SeedShard) {
    cem.lir_absorb(&mut o.cem);
    for i in 0..o.cem.refused.len() {
        cem.refused.push(o.cem.refused[i]);
    }
    o.cem.refused.clear();
}

fn cemit_seed_merge(cem: &mut cbe::CEmit, o: &mut SeedShard, m: u64) {
    cemit_take_refused(cem, o);
    let a = cap_zero();
    let b = o.cap_of();
    cemit_seed_merge_range(cem, o, &a, &b);
    cem.mg.sh_merge_um(&mut o.cem.mg, m);
    cem.mg.sh_merge_inst(&o.cem.mg);
}

// Emit module `m` on the master at this module-order position: replay its cached section on a
// cache hit, else (or on a rejected replay) lower and emit it live, journaling a new section while
// the cache is on and no replay dirtied the old one.
fn cemit_seed_master(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    cl_cache: &mut Map<u64, u64>,
    clws: &mut Vector<irl::Lowerer>,
    m: usize,
    testing: bool,
    verbose: bool,
    tuc: &mut tuc::Tuc,
    acc: &mut SeedAcc,
) {
    // Symbols the module spells about ITSELF are not cross-TU uses.
    cem.mg.mark_ctx = m as i64;
    let mut rec = tuc.on;
    if tuc.on && tuc.hit[m] {
        let rr = cemit_tuc_replay(p, cem, m, &*tuc, acc);
        if rr == 0 {
            tuc.sec_keep(m);
            return;
        }
        // Clean rejects are ordinary churn (another module's typecheck moved this pool);
        // a DIRTY reject means interns landed before diverging: warn and void the section.
        if rr == 2 {
            eprint("tu-cache: dirty replay reject for `{}`; emitting live\n", p.modules[m].path.as_str());
            tuc.sec_void(m);
        }
        rec = rr == 1;
    }
    let mk = RecMark {
        seg: cem.mg.rec.len(),
        aux: cem.sh_aux_k.len(),
        efwd: cem.env_fwd.len(),
        eh: cem.env_hashes.len(),
        hedge: cem.hdr_k.len(),
        tn: cem.mg.tn_key.len(),
    };
    cem.mg.rec_on = rec;
    let ts0 = if p.icost_on {
        std::parallel::platform::now_ns();
    } else {
        0u64;
    };
    cemit_seed_module(p, cem, g, dow, cl_cache, clws, m, testing, verbose, null, acc);
    if p.icost_on {
        gitems::mod_cost(p, m, 0, std::parallel::platform::now_ns() - ts0);
    }
    if rec {
        cem.mg.rec_on = false;
        rec_close(p, cem, &mk, m, acc.ch.bufs.at(m).as_str(), tuc);
        cem.mg.rec.truncate(mk.seg);
    }
}

// The journal and accumulator lengths a module's TU-cache section starts at.
struct RecMark {
    pub(package) seg: usize, // journal events
    pub(package) aux: usize,
    pub(package) efwd: usize,
    pub(package) eh: usize, // environment hashes
    pub(package) hedge: usize, // header edges
    pub(package) tn: usize, // type-need log entries
}

// Close module `m`'s section: journal the trailing deltas past `mk` (their accumulators are consumed
// whole at assembly, so only their internal order matters), then serialize the events from
// `mk.seg` on, with chunk texts from `text`, as the module's section.
fn rec_close(p: &loader::Package, cem: &mut cbe::CEmit, mk: &RecMark, m: usize, text: str, tuc: &mut tuc::Tuc) {
    rec_aux(cem, mk.aux, mk.hedge);
    if cem.env_fwd.len() > mk.efwd {
        let mut ev9 = mbe::RecEv::blank(mbe::RK_EFWD);
        ev9.s1.push_str(cem.env_fwd.as_str().slice(mk.efwd, cem.env_fwd.len()));
        cem.mg.rec.push(ev9);
    }
    for k9 in mk.eh..cem.env_hashes.len() {
        let mut ev9 = mbe::RecEv::blank(mbe::RK_EDEF);
        ev9.h = *cem.env_hashes.at(k9);
        cem.mg.rec.push(ev9);
    }
    rec_edges(cem, m, p.modules.len(), mk.tn);
    tuc.sec_rec(p, m, &cem.mg.rec, mk.seg, text);
}

// Journal the `aux` entries from row `a0` on (one event each: owner, key, text) and the header
// edges from `h0` on, which the section replays through `aux_replay` and `hdr_k`/`hdr_h`.
fn rec_aux(cem: &mut cbe::CEmit, a0: usize, h0: usize) {
    let mut pe = cap_pe(&cem.sh_aux_e, a0 as u32);
    for i in a0..cem.sh_aux_k.len() {
        let e = cem.sh_aux_e[i];
        let mut ev9 = mbe::RecEv::blank(mbe::RK_AUX);
        ev9.a = cem.aux_own[i];
        ev9.h = cem.sh_aux_k[i];
        ev9.s1.push_str(cem.aux.as_str().slice(pe as usize, e as usize));
        cem.mg.rec.push(ev9);
        pe = e;
    }
    for i in h0..cem.hdr_k.len() {
        let mut ev9 = mbe::RecEv::blank(mbe::RK_HEDGE);
        ev9.a = cem.hdr_k[i];
        ev9.h = cem.hdr_h[i];
        cem.mg.rec.push(ev9);
    }
}

// Journal module `m`'s cross-TU row: each owner it spelled a type name of (bit 15) or another
// symbol of, replayed through `mark_used`; then its type needs recorded from log entry `tn0` on,
// replayed through `need_name`.
fn rec_edges(cem: &mut cbe::CEmit, m: usize, nmods: usize, tn0: usize) {
    let mut ev9 = mbe::RecEv::blank(mbe::RK_EDGE);
    for k in 0..cem.mg.um_w() {
        let ty = cem.mg.um_word(m as u64, k, true);
        let sy = cem.mg.um_word(m as u64, k, false);
        let mut b = ty | sy;
        while b != 0 {
            let d = b.trailing_zeros();
            b &= b - 1;
            if k * 64 + d >= nmods {
                break;
            }
            let dst = (k * 64 + d) as u32;
            if (ty >> d as u64 & 1) != 0 {
                ev9.xs.push(dst | 0x8000);
            }
            if (sy >> d as u64 & 1) != 0 {
                ev9.xs.push(dst);
            }
        }
    }
    cem.mg.rec.push(ev9);
    let mut ks = Vector::<u64>::new();
    for i in tn0..cem.mg.tn_key.len() {
        if cem.mg.tn_row[i] as usize == m {
            ks.push(cem.mg.tn_key[i]);
        }
    }
    if ks.len() != 0 {
        ks.sort();
        let mut ev8 = mbe::RecEv::blank(mbe::RK_TNEED);
        for k in 0..ks.len() {
            if k == 0 || ks[k] != ks[k - 1] {
                ev8.xs.push((ks[k] & 0xFFFFFFFF) as u32);
                ev8.xs.push((ks[k] >> 32) as u32);
            }
        }
        cem.mg.rec.push(ev8);
    }
}

// Emit every derived destructor queued from `*gi` on into the instance TU; each may queue more.
fn cemit_drain_glue(cem: &mut cbe::CEmit, gi: &mut usize, acc: &mut SeedAcc, verbose: bool) {
    while *gi < cem.glue.len() {
        let go = glue_owner(cem, *gi);
        cem.mg.mark_ctx = mbe::CTX_INST | go as i64;
        cem.out.clear();
        if cem.emit_glue(*gi) {
            acc.glue_ok += 1;
            acc.chunk(65534, go, &cem.out, false, &mut cem.mg.rec);
            cem.lir_claim(go, "a destructor", false);
        } else {
            if verbose {
                eprint("glue-emit-fail: `{}` {}\n", cem.glue.at(*gi).sym.as_str(), cem.err);
            }
            acc.glue_skip += 1;
        }
        *gi += 1;
    }
}

// The module whose instance shard defines glue entry `gi`: the destroyed type's owner, else the
// module that demanded it.
fn glue_owner(cem: &mut cbe::CEmit, gi: usize) ModuleId {
    let em = cem.glue.at(gi).em;
    let od = cem.mg.owner_dep(em, cem.glue.at(gi).ty);
    if od >= 0 {
        return od as ModuleId;
    }
    return em;
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
    // The functions the range's text named outside the seed set, at the master's slot: the late
    // queue's order is the serial loop's.
    for i in a.fndem as usize..b.fndem as usize {
        cem.mg.fn_take(*sc.mg.fn_dem.at(i));
    }
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
    let mut pv = cap_pe(&sc.sh_stat_v, a.stat);
    for i in a.stat as usize..b.stat as usize {
        let k = sc.sh_stat_k[i];
        let v = sc.sh_stat_v[i];
        if !cem.stat_seen.contains(&k) {
            cem.stat_seen.insert(k);
            for j in pv..v {
                let sr = replace(
                    sc.stat_items.index_mut(j as usize),
                    cbe::StatRef {
                        em: 0,
                        def: DefId { module: 0, node: NODE_NONE },
                        sym: String::new(),
                        ty: TYPE_NONE,
                        args: Vector::<mbe::MSub>::new(),
                    },
                );
                cem.stat_items.push(sr);
                cem.stat_decls.push_str(
                    sc.stat_decls.as_str().slice(cap_pe(&sc.stat_end, j) as usize, sc.stat_end[j as usize] as usize),
                );
                cem.stat_end.push(cem.stat_decls.len() as u32);
            }
        }
        pv = v;
    }
    pv = cap_pe(&sc.sh_glue_v, a.glue);
    for i in a.glue as usize..b.glue as usize {
        let k = sc.sh_glue_k[i];
        let v = sc.sh_glue_v[i];
        if !cem.glue_seen.contains(&k) {
            cem.glue_seen.insert(k);
            for j in pv..v {
                let sr = replace(
                    sc.glue.index_mut(j as usize),
                    cbe::StatRef {
                        em: 0,
                        def: DefId { module: 0, node: NODE_NONE },
                        sym: String::new(),
                        ty: TYPE_NONE,
                        args: Vector::<mbe::MSub>::new(),
                    },
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
        if !cem.extern_seen.contains(&k) {
            cem.extern_seen.insert(k);
            cem.extern_protos.push_str(sc.extern_protos.as_str().slice(pe as usize, e as usize));
        }
        pe = e;
    }
    pe = cap_pe(&sc.sh_dyd_e, a.dyd);
    for i in a.dyd as usize..b.dyd as usize {
        let k = sc.sh_dyd_k[i];
        let e = sc.sh_dyd_e[i];
        if !cem.dyn_def_seen.contains(&k) {
            cem.dyn_def_seen.insert(k);
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
        if !cem.dyn_tab_seen.contains(&k) {
            cem.dyn_tab_seen.insert(k);
            cem.dyn_tabs.push_str(sc.dyn_tabs.as_str().slice(pe as usize, e as usize));
            cem.dyn_decls.push_str(sc.dyn_decls.as_str().slice(pe2 as usize, e2 as usize));
            cem.sh_dyt_k.push(k);
            cem.sh_dyt_e.push(cem.dyn_tabs.len() as u32);
            cem.sh_dyt_e2.push(cem.dyn_decls.len() as u32);
            cem.dyt_own.push(sc.dyt_own[i]);
            cem.dyt_sym.push(sc.dyt_sym.at(i).clone());
        }
        pe = e;
        pe2 = e2;
    }
    pe = cap_pe(&sc.sh_blk_e, a.blk);
    pe2 = cap_pe(&sc.sh_blk_e2, a.blk);
    for i in a.blk as usize..b.blk as usize {
        let k = sc.sh_blk_k[i];
        let e = sc.sh_blk_e[i];
        let e2 = sc.sh_blk_e2[i];
        if !cem.blk_seen.contains(&k) {
            cem.blk_seen.insert(k);
            cem.blk_defs.push_str(sc.blk_defs.as_str().slice(pe as usize, e as usize));
            cem.blk_protos.push_str(sc.blk_protos.as_str().slice(pe2 as usize, e2 as usize));
            cem.sh_blk_k.push(k);
            cem.sh_blk_e.push(cem.blk_defs.len() as u32);
            cem.sh_blk_e2.push(cem.blk_protos.len() as u32);
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
        if !cem.sent_seen.contains(&k) {
            cem.sent_seen.insert(k);
            cem.sent_decls.push_str(sc.sent_decls.as_str().slice(pe as usize, e as usize));
            cem.sent_defs.push_str(sc.sent_defs.as_str().slice(pe2 as usize, e2 as usize));
        }
        pe = e;
        pe2 = e2;
    }
    pv = cap_pe(&sc.sh_ti_v, a.ti);
    for i in a.ti as usize..b.ti as usize {
        let k = sc.sh_ti_k[i];
        let v = sc.sh_ti_v[i];
        if !cem.ti_seen.contains(&k) {
            cem.ti_seen.insert(k);
            for j in pv..v {
                let sr = replace(
                    sc.ti_reqs.index_mut(j as usize),
                    cbe::StatRef {
                        em: 0,
                        def: DefId { module: 0, node: NODE_NONE },
                        sym: String::new(),
                        ty: TYPE_NONE,
                        args: Vector::<mbe::MSub>::new(),
                    },
                );
                cem.ti_reqs.push(sr);
            }
        }
        pv = v;
    }
    pe = cap_pe(&sc.sh_aux_e, a.aux);
    for i in a.aux as usize..b.aux as usize {
        let e = sc.sh_aux_e[i];
        cem.aux_replay(sc.sh_aux_k[i], sc.aux_own[i], sc.aux.as_str().slice(pe as usize, e as usize));
        pe = e;
    }
    for i in a.hedge as usize..b.hedge as usize {
        cem.hdr_k.push(sc.hdr_k[i]);
        cem.hdr_h.push(sc.hdr_h[i]);
    }
    for i in a.dem as usize..b.dem as usize {
        let dk = sc.demand.at(i).dk;
        if dk != 0 {
            if cem.demand_seen.contains(&dk) {
                continue;
            }
            cem.demand_seen.insert(dk);
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
    for i in a.wrap as usize..b.wrap as usize {
        let rq = replace(sc.mg.wrap_reqs.index_mut(i), mbe::WrapReq { h: 0, elem: String::new(), body: String::new() });
        cem.mg.wrap_take(rq);
    }
    for i in a.pack as usize..b.pack as usize {
        let rq = replace(sc.mg.pack_reqs.index_mut(i), mbe::WrapReq { h: 0, elem: String::new(), body: String::new() });
        cem.mg.pack_take(rq);
    }
}

/// Emit the whole package through the streaming backend into `o`: the instance graph, every TU's
/// declarations and bodies, the shared instance TU, the test runner when `testing`, and the
/// per-module TU-cache sections. `live` (per module) and `target` select what is emitted;
/// `irkeep` (null = discard) supplies the borrow checker's kept lowerings.
pub(package) fn cemit_package(
    p: &mut loader::Package,
    testing: bool,
    tplan: &TestPlan,
    live: *const bool,
    target: i32,
    o: &mut CemitOut,
    irkeep: *mut irl::Keep,
) {
    let verbose = stdlib::getenv("SC_CEMIT_STATS") != null;
    let mut tt0 = ticks_ms();
    let mut prd = prb::Probe::new(verbose, stdlib::getenv("SC_BUILD_MEM") != null);
    publish_checkpoint(p, irkeep);
    // The evaluator's view of the keep (opened by the borrow frontier) closes before the graph
    // takes the bodies: the driver closes it after its constant pre-pass, any other pipeline here.
    if p.cir != null {
        unsafe (*(p.cir as *mut iri::Interp)).keep_view_clear();
    }
    // The planner's signature-level propagation reads the package metadata.
    let ts9 = ticks_ms();
    p.ensure_sigs();
    let gm9 = prd.start();
    // The inliner and the emitter read which extern items have a scoped header.
    p.scope_extern_items();
    // The inline candidates come from the kept lowerings, before the graph takes them.
    let mut inls = inl::InlineStore::new();
    let ti9 = ticks_ms();
    if irkeep != null {
        inls.build(p, unsafe &*irkeep);
    }
    p.inl_store = &inls;
    if verbose {
        eprint(
            "cemit-stage publish: {} ms, sigs: {} ms, inline-store build: {} ms\n",
            ts9 - tt0,
            ti9 - ts9,
            ticks_ms() - ti9,
        );
        let t9 = ticks_ms();
        eprint(
            "cemit-stage inline-store: {} ms, {} callees kept of {} vetted\n",
            t9 - tt0,
            inls.kept.len(),
            inls.keep_ix.len(),
        );
        tt0 = t9;
    }
    let mut g = ig::InstGraph::new(p, irkeep, live);
    g.collect();
    // Only the collection takes bodies from the keep: every body a root reaches has moved into the
    // graph, and the rest (bodies no root reaches, the emptied slots, the index) has no reader.
    if irkeep != null {
        *unsafe &mut *irkeep = irl::Keep::new();
    }
    if g.faults.len() != 0 {
        report_len_faults(p, &g.faults);
        o.len_faults = true;
    }
    prd.stop(prb::P_GRAPH, gm9);
    if unsafe TS_ON {
        ts_add(TS_IG_BYTES, g.retained_bytes());
    }
    if verbose {
        let t9 = ticks_ms();
        let mut nagg: u64 = 0;
        let mut nfn: u64 = 0;
        for r in 0..g.recs.len() {
            if g.recs.at(r).kind == ig::IG_AGG {
                nagg += 1;
            } else if g.recs.at(r).kind == ig::IG_FN {
                nfn += 1;
            }
        }
        eprint(
            "cemit-stage collect: {} ms, {} records ({} aggregates, {} functions, {} methods), {} bodies walked in {} rounds{}\n",
            t9 - tt0,
            g.recs.len(),
            nagg,
            nfn,
            g.recs.len() as u64 - nagg - nfn,
            g.bodies,
            g.rounds,
            if g.overflow {
                ", budget exhausted";
            } else {
                "";
            },
        );
        tt0 = t9;
    }
    let ian = graph_inst_asserts(p, &mut g);
    if verbose {
        let t9 = ticks_ms();
        eprint("cemit-stage inst-asserts: {} ms, {} instances\n", t9 - tt0, ian);
        tt0 = t9;
    }
    // SC_LIR_EVAL compares each test's CTFE run with the evaluator's: CTFE reads the syntax.
    let mut ctfe = Vector::<lw::CtfeRes>::new();
    if testing && stdlib::getenv("SC_LIR") != null && stdlib::getenv("SC_LIR_EVAL") != null {
        let mut ts = Vector::<u64>::new();
        let mut sp = Vector::<bool>::new();
        for i in 0..tplan.cases.len() {
            let tc = tplan.cases[i];
            if tc.wants == 0 {
                ts.push(tc.mod as u64 << 32 | tc.func as u64);
                sp.push(tc.should_panic);
            }
        }
        ctfe = lw::probe_tests(p, &ts, &sp);
    }
    // The concrete functions the seed pass emits: what the walks reach from the roots. A function only
    // the emitted text names is emitted late, so the set predicts the seeds and never decides output.
    let mut pred = Set::<u64>::new();
    {
        let mut rf = Vector::<DefId>::new();
        reach_roots(p, &g, live, testing, &mut rf);
        // A call of an inline candidate splices its body: with the inliner on, the call alone does
        // not make the callee emitted (`InstGraph::reach`).
        let st = if stdlib::env_is("SC_INLINE", "0") {
            null;
        } else {
            (&inls) as *const inl::InlineStore;
        };
        g.reach(&rf, st);
        pred = replace(&mut g.reached, Set::<u64>::new());
    }
    let predp = (&pred) as *const Set<u64>;
    // Every body is lowered and kept, every constant and static_assert is evaluated, and the live
    // set and the emit order have read their last reference: the body syntax has no reader left.
    p.release_bodies();
    syntax_stats_report(p, "release");
    let mut em = tbe::TuEmit::new(p);
    em.mg.agg_on = true;
    em.mg.fn_pred = predp;
    let mut items = Vector::<tbe::AggItem>::new();
    for m in 0..p.modules.len() {
        if !module_emits(p, live, m) {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            let n = a.at_const(nid);
            if (n.kind == NodeKind::NODE_STRUCT || n.kind == NodeKind::NODE_ENUM) && a.ext(nid).aggregate.generics.len == 0 {
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
    bst::mark(bst::B_PLAN);
    ts_phase("graph");
    stage_ms(verbose, &mut tt0, "cemit-stage collect+aggs");
    // Demand-driven monomorphization: emit every concrete standalone body with demand collection
    // on, then drain the queue; each demanded instance re-emits the generic Core body under its
    // recorded substitution chain. The drained symbol set is the closed instance set the old
    // propagation computed, derived from Core IR alone.
    let mut cem = cbe::CEmit::new(p);
    if let Some(l) = &mut cem.lir {
        l.deref_mut().ctfe = ctfe;
    }
    cem.mg.fn_pred = predp;
    cem.collect_demand = true;
    cem.mg.agg_on = true;
    cem.mg.share_short(&mut em.mg);
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
    let mut gated_incs = String::new();
    let mut xhdrs = Vector::<XHdr>::new();
    cemit_extern_includes(p, &mut ext_incs, &mut gated_incs, &mut cem.ext_backed, &mut xhdrs);
    // Every emitter shard starts from the same header-backed fn set.
    let mut ext_keys = Vector::<u64>::new();
    for k in cem.ext_backed.iter() {
        ext_keys.push(*k);
    }
    let mut dow = DropCtx::new(p);
    let mut lw_cache = Map::<u64, u64>::new();
    let mut lws = Vector::<irl::Lowerer>::new();
    // Closure lowerings, drops applied, shared by the seed and instance loops (a demanded generic
    // body re-emits its closures per instantiation; the lowering is instantiation-independent).
    let mut cl_cache = Map::<u64, u64>::new();
    let mut clws = Vector::<irl::Lowerer>::new();
    let mut acc = SeedAcc::new(TuBufs::new(p.modules.len()));
    // Pre-size every buffer from the corpus: a module's C runs about 1.7 bytes per source byte (two
    // leave most modules one allocation), the instance TU under a quarter of the whole, prototypes a
    // byte per AST node. Growth past an estimate stays geometric.
    let mut src_total: usize = 0;
    {
        let mut est_nodes: usize = 0;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast {
                est_nodes += p.modules[m].ast.nnodes();
            }
            if module_emits(p, live, m) {
                acc.ch.bufs.index_mut(m).reserve(2 * p.modules[m].source.len());
                src_total += p.modules[m].source.len();
            }
        }
        acc.ch.bufs.index_mut(p.modules.len()).reserve(src_total / 4);
        acc.protos.reserve(est_nodes);
    }
    // Chunk provenance: proto_of precedes every chunk append, so prototype line k pairs with chunk k.
    // Per-TU cache: fingerprint every module up front; a hit replays the module's journaled side
    // effects instead of lowering it, a miss emits live under journaling. Test builds opt out (the
    // wrapper set would join the fingerprint for little gain).
    // A cached section replays the seeds of the prediction it recorded: each module's prediction keys it.
    let mut salt = Vector::<u64>::new();
    salt.resize_default(p.modules.len());
    for k in pred.iter() {
        let m = (*k >> 32) as usize;
        if m < salt.len() {
            salt.set(m, salt[m].wrapping_add(skey_mix(0x9E3779B97F4A7C15u64, *k)));
        }
    }
    let mut tuc = tuc::tuc_setup(
        p,
        live,
        &salt,
        target,
        if testing {
            // The wrapper set would join the fingerprint for little gain.
            "";
        } else {
            p.gen_root.as_str();
        },
        // A section carries its module's C text, as large as the module's TU buffer.
        2 * src_total,
    );
    let mut held = Vector::<Option<lhold::Rec>>::new();
    nat_trust(p, &mut tuc, &mut held);
    let par9 = p.jobs != 1 && p.modules.len() > 1;
    if par9 {
        // Parallel seed frontier: one task per module with a private emitter shard; gated
        // first-claimant emissions replay into the master in module order afterwards, so the
        // shared headers and worklists come out byte-identical to the serial loop's. Cache-hit
        // modules skip their shard entirely and replay their journaled section at merge time;
        // missed shards journal under rec_on and their sections serialize at merge (the type
        // table makes sections pool-position-independent, so parallel intern order is harmless).
        set_stage_locks(p, true);
        let mut kl = psync::Semaphore::new(1);
        let mut shards = Vector::<SeedShard>::new();
        for m in 0..p.modules.len() {
            let used = module_emits(p, live, m) && !(tuc.on && tuc.hit[m]);
            // A shard renders into the buffer reserved for its module above; a hit module keeps it.
            let buf = if used {
                replace(acc.ch.bufs.index_mut(m), String::new());
            } else {
                String::new();
            };
            let mut sh = SeedShard::new(p, TuBufs::one(m, buf), used, &em.env_defined, &ext_keys, m as i64, predp);
            sh.cem.mg.share_short(&mut em.mg);
            sh.cem.mg.rec_on = used && tuc.on;
            shards.push(sh);
        }
        let wg = psync::WaitGroup::new();
        let pp9 = p as *mut loader::Package;
        let gg9 = (&mut g) as *mut ig::InstGraph;
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
            let op9 = shards.index_mut(m) as *mut SeedShard;
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
        if verbose {
            eprint("cemit-frontier seed: {} tasks\n", launched9);
        }
        for m in 0..p.modules.len() {
            let eligible9 = module_emits(p, live, m);
            if !eligible9 {
                if tuc.on {
                    tuc.sec_void(m);
                }
                continue;
            }
            if tuc.on && tuc.hit[m] {
                // hit: no shard ran; replay the journaled section through the master's gates at
                // exactly this module-order position (a reject emits live there: the merge point
                // is serial-state-equivalent).
                cemit_seed_master(
                    p,
                    &mut cem,
                    &mut g,
                    &mut dow,
                    &mut cl_cache,
                    &mut clws,
                    m,
                    testing,
                    verbose,
                    &mut tuc,
                    &mut acc,
                );
                continue;
            }
            let o = shards.index_mut(m);
            if !o.used {
                continue;
            }
            if tuc.on {
                // The shard's journal becomes the module's section: trailing deltas are the whole
                // shard-local accumulators, chunk texts materialize from the shard's bodies buffer.
                let zero = RecMark { seg: 0, aux: 0, efwd: 0, eh: 0, hedge: 0, tn: 0 };
                rec_close(p, &mut o.cem, &zero, m, o.acc.ch.bufs.at(0).as_str(), &mut tuc);
            }
            acc.absorb_seed(&mut o.acc, m);
            cem.pr.merge(&o.cem.pr);
            cemit_seed_merge(&mut cem, o, m as u64);
        }
        set_stage_locks(p, false);
    } else {
        for m in 0..p.modules.len() {
            if !module_emits(p, live, m) {
                // No seeds (missing AST / unreachable prelude): an empty section keeps the image indexed.
                if tuc.on {
                    tuc.sec_void(m);
                }
                continue;
            }
            cemit_seed_master(
                p,
                &mut cem,
                &mut g,
                &mut dow,
                &mut cl_cache,
                &mut clws,
                m,
                testing,
                verbose,
                &mut tuc,
                &mut acc,
            );
        }
    }
    // Every replay and carried section has read the previous image: release it before the rest of
    // the emission grows the heap.
    tuc.raw = String::new();
    stage_ms(verbose, &mut tt0, "cemit-stage seed");
    // The aggregate pass's own spellings join the late queue.
    for i in 0..em.mg.fn_dem.len() {
        cem.mg.fn_take(*em.mg.fn_dem.at(i));
    }
    em.mg.fn_dem.truncate(0);
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
                acc.chunk(tc.mod, tc.mod, &cem.out, false, &mut cem.mg.rec);
                cem.lir_test_wrapper(tc.mod, tc.func, tc.wants, fxi, fxf);
                cem.lir_claim(tc.mod, "a test wrapper", false);
            } else {
                tw_skip += 1;
                eprint("cemit-test-miss: {}\n", cem.err);
            }
        }
        if tplan.genv_init != NODE_NONE {
            cem.out.clear();
            if cem.emit_test_genv(tplan.genv_mod, tplan.genv_init, tplan.genv_free) {
                tw_ok += 1;
                acc.chunk(tplan.genv_mod, tplan.genv_mod, &cem.out, false, &mut cem.mg.rec);
                cem.lir_test_genv(tplan.genv_mod, tplan.genv_init, tplan.genv_free);
                cem.lir_claim(tplan.genv_mod, "the test environment", false);
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
    ia_idx.resize_default(p.modules.len());
    ia_built.resize_default(p.modules.len());
    let mut gi9: usize = 0;
    let mut reasons = Vector::<str<'static>>::new();
    let mut rcounts = Vector::<u64>::new();
    // Instance-TU emission: every spelled module is link-reachable.
    cem.mg.mark_ctx = -1;
    let mut kl9 = psync::Semaphore::new(1);
    if par9 {
        set_stage_locks(p, true);
    }
    let mut qi: usize = 0;
    let mut dwaves: u64 = 0;
    let mut dtasks: u64 = 0;
    let mut dslices: u64 = 0;
    // The functions only the emitted text names (`fn_ref`) render between full drains, so the serial
    // loop and the waves queue them alike; each may demand instances, glue and more such functions.
    let mut fi: usize = 0;
    loop {
        while (qi < cem.demand.len() || gi9 < cem.glue.len()) && qi < DEMAND_CAP {
            // Derived destructors drain alongside instances (each may enqueue the other).
            cemit_drain_glue(&mut cem, &mut gi9, &mut acc, verbose);
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
                    &mut acc,
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
            let mut wkey = Vector::<u64>::new(); // their symbol hashes
            let mut wave_seen = Map::<u64, u64>::new();
            let mut newdefs = Vector::<u64>::new();
            let mut newsyms = Vector::<String>::new(); // first demanding symbol, for the failure print
            let mut newdef_seen = Map::<u64, u64>::new();
            for j in qi..len0 {
                let dkj = fnv(cem.demand.at(j).sym.as_str());
                let seenj = done.contains_key(&dkj);
                if seenj {
                    continue;
                }
                let wavedup = wave_seen.contains_key(&dkj);
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
                    let nds = newdef_seen.contains_key(&jkey);
                    if !nds {
                        newdef_seen.insert(jkey, 1);
                        newdefs.push(jkey);
                        newsyms.push(cem.demand.at(j).sym.clone());
                    }
                }
                widx.push(j as u64);
                wli.push(base);
                wdef.push(jkey);
                wkey.push(dkj);
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
                        count_template(&res9.at(i).body, &mut prd);
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
                let mut k2 = Vector::<u64>::new();
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
                    k2.push(wkey[i]);
                }
                widx = w2;
                wli = l2;
                wkey = k2;
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
                let mut sh = SeedShard::new(p, TuBufs::new(0), true, &em.env_defined, &ext_keys, -1, predp);
                sh.cem.mg.share_short(&mut em.mg);
                for ei in 0..envh9.len() {
                    sh.cem.env_skip.insert(envh9[ei], 1);
                }
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
                cemit_drain_glue(&mut cem, &mut gi9, &mut acc, verbose);
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
                        &mut acc,
                        &mut reasons,
                        &mut rcounts,
                    );
                    continue;
                }
                let d_ord = wcur - slo;
                let dkj = wkey[wcur];
                wcur += 1;
                {
                    let jd = cem.demand.at(j).def;
                    let jsubs = mbe::subs_copy(&cem.demand.at(j).subs);
                    cemit_inst_asserts(p, &mut cem.mg, jd, &jsubs, dkj, &mut sa_seen, &mut ia_idx, &mut ia_built);
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
                    if out9 == 3 {
                        // Emitted, with the program error its re-lowering found: reported here, in demand
                        // order. A bare lowering finds the node again (no drops, no probe counts).
                        let mut lw9 = irl::Lowerer::new(p, cem.demand.at(j).def.module, cem.demand.at(j).def.node);
                        let js9 = mbe::subs_copy(&cem.demand.at(j).subs);
                        for k9 in 0..js9.len() {
                            let sb9 = *js9.at(k9);
                            lw9.env.push(irl::LSub { pm: sb9.pm, pnode: sb9.pnode, am: sb9.am, at: sb9.at });
                        }
                        let _ = lw9.lower_fn(cem.demand.at(j).def.node);
                        cemit_inst_error(p, cem.demand.at(j).def, &js9, &lw9);
                    }
                    if out9 == 0 || out9 == 3 {
                        done.insert(dkj, 1);
                        acc.inst_ok += 1;
                        let vix = o.dvix[d_ord];
                        if vix != 0xFFFFFFFFFFFFFFFFu64 && o.dvkeys[vix as usize] != 0 {
                            let zk = o.dvkeys[vix as usize];
                            let zseen = lw_cache.contains_key(&zk);
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
                            let cseen = cl_cache.contains_key(&ckey);
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
                        let oc = &o.acc.ch;
                        let base9 = acc.ch.bufs.at(acc.ch.n).len() as u64;
                        for k2 in ma.chunks as usize..mb.chunks as usize {
                            acc.ch.chunk_mod.push(oc.chunk_mod[k2]);
                            acc.ch.chunk_own.push(oc.chunk_own[k2]);
                            acc.ch.chunk_off.push(oc.chunk_off[k2] - ma.bodies + base9);
                            acc.ch.chunk_end.push(oc.chunk_end[k2] - ma.bodies + base9);
                        }
                        acc.ch.bufs.index_mut(acc.ch.n).push_str(
                            oc.bufs.at(0).as_str().slice(ma.bodies as usize, mb.bodies as usize),
                        );
                        acc.protos.push_str(o.acc.protos.as_str().slice(ma.protos as usize, mb.protos as usize));
                        acc.take_envs(&mut o.acc, ma.envn as usize, mb.envn as usize);
                        cemit_seed_merge_range(&mut cem, o, &ma, &mb);
                    } else if out9 == 1 {
                        acc.inst_skip += 1;
                    } else {
                        if verbose {
                            eprint("inst-emit-fail: `{}` {}\n", cem.demand.at(j).sym.as_str(), o.derrs[d_ord]);
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
                    acc.clos_ok += o.acc.clos_ok;
                    acc.clos_skip += o.acc.clos_skip;
                    cem.pr.merge(&o.cem.pr);
                    cemit_seed_merge_um(&mut cem, o);
                    slo = wcur;
                    scur += 1;
                }
            }
            qi = len0;
        }
        if qi >= DEMAND_CAP || fi >= cem.mg.fn_dem.len() {
            break;
        }
        while fi < cem.mg.fn_dem.len() {
            let d = *cem.mg.fn_dem.at(fi);
            fi += 1;
            if !module_emits(p, live, d.module as usize) {
                continue;
            }
            cem.mg.mark_ctx = d.module;
            cemit_seed_fn(
                p,
                &mut cem,
                &mut g,
                &mut dow,
                &mut cl_cache,
                &mut clws,
                d.module as usize,
                d.node,
                testing,
                verbose,
                null,
                &mut acc,
            );
        }
        cem.mg.mark_ctx = -1;
    }
    if qi < cem.demand.len() || gi9 < cem.glue.len() {
        // The drain stopped at its bound: every demand and destructor left is code not emitted.
        eprint("error: more than {} generic instance demands; the rest are not emitted\n", DEMAND_CAP);
        acc.inst_skip += (cem.demand.len() - qi) as u64;
        acc.glue_skip += (cem.glue.len() - gi9) as u64;
    }
    if par9 {
        set_stage_locks(p, false);
    }
    // True instance failures are demanded symbols that never emitted on ANY chain.
    {
        let mut fseen = Map::<u64, u64>::new();
        for di9 in 0..cem.demand.len() {
            let fs9 = cem.demand.at(di9).sym.as_str();
            let fk9 = fnv(fs9);
            let emitted9 = done.contains_key(&fk9);
            let counted9 = fseen.contains_key(&fk9);
            if !emitted9 && !counted9 {
                fseen.insert(fk9, 1);
                acc.inst_skip += 1;
            }
        }
    }
    stage_ms(verbose, &mut tt0, "cemit-stage drain");
    // Every task that takes a pooled DropCtx has joined: free the pool now, not after assembly.
    dctx_drop(&mut prd);
    let mut si_names = Vector::<String>::new();
    let mut si_defs = Vector::<String>::new();
    let mut si_packs = Vector::<mbe::WrapReq>::new();
    o.skips += cemit_simd_entries(p, &mut cem, &mut g, &mut dow, &ext_keys, &mut si_names, &mut si_defs, &mut si_packs);
    // The backend entries are the instance graph's last reader: free its records and bodies before
    // the constant, static and assembly steps grow the heap.
    g = ig::InstGraph::new(p, null, live);
    if verbose {
        if dwaves != 0 {
            eprint("cemit-frontier inst: {} waves, {} tasks, {} slices\n", dwaves, dtasks, dslices);
        }
        cemit_relower_census(p, &cem, &lws, &lw_cache, &done, &mut prd);
    }
    if verbose {
        eprint(
            "cemit-tu-inst: {} seeds ({} predicted, {} late, {} skipped), {} instances, {} inst-skipped, {} demanded, {} closures ({} skipped), {} glue ({} skipped)\n",
            acc.seeds,
            pred.len(),
            fi,
            acc.seed_skip,
            acc.inst_ok,
            acc.inst_skip,
            cem.demand.len(),
            acc.clos_ok,
            acc.clos_skip,
            acc.glue_ok,
            acc.glue_skip,
        );
    }
    for r2 in 0..reasons.len() {
        if reasons[r2] != cbe::inst_depth_why() && !o.len_faults {
            eprint("cemit-tu-inst-miss: {} x{}\n", reasons[r2], rcounts[r2]);
        }
    }
    o.skips += acc.seed_skip + acc.inst_skip + acc.clos_skip + acc.glue_skip + tw_skip;
    if acc.have_main && acc.main_argv && !testing {
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
                if n9.kind != NodeKind::NODE_STRUCT || a9.ext(nid9).aggregate.generics.len == 0 {
                    continue;
                }
                if a9.attr_of(nid9, AttrKind::ATTR_EMIT_MACRO) == null {
                    continue;
                }
                // The raw (pre-rewrite) bodies of the two templates.
                let mut mb_dec = String::new();
                let mut mb_def = String::new();
                cem.mg.macro_on = true;
                let mut okm = true;
                mb_dec.push_str("typedef struct NAME NAME;\nstruct NAME {\n");
                let fs9 = a9.ext(nid9).aggregate.members;
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
                    if en.kind != NodeKind::NODE_EXTEND || a9.ext(eid).extend_def.generics.len == 0 {
                        continue;
                    }
                    if a9.ext(eid).extend_def.interface_type != NODE_NONE {
                        continue;
                    }
                    if a9.resolution(a9.ext(eid).extend_def.target_type) != nid9 {
                        continue;
                    }
                    let ms9 = a9.ext(eid).extend_def.items;
                    for k9 in 0..ms9.len {
                        if !okm {
                            break;
                        }
                        let mid9 = unsafe a9.list(ms9)[k9 as usize];
                        let mn9 = a9.at_const(mid9);
                        if mn9.kind != NodeKind::NODE_FUNCTION || a9.ext(mid9).function.generics.len != 0 || a9.ext(
                            mid9,
                        ).function.returns.len > 1 {
                            continue;
                        }
                        if a9.ext(mid9).function.body == NODE_NONE {
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
                        cem.mg.ident(m9 as ModuleId, a9.at_const(a9.ext_name(mid9)).as_data.name.text, &mut msym);
                        cem.out.clear();
                        cem.fn_attrs.truncate(0);
                        cem.fs = p.fn_set(m9 as ModuleId, mid9);
                        cemit_fn_attrs(p, m9 as ModuleId, mid9, cem.fs, &mut cem.fn_attrs);
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
                    macro_stem(&mut cem.mg, m9 as ModuleId, a9.at_const(a9.ext_name(nid9)).as_data.name.text, &mut stem);
                    macros_out.push_str("#define ");
                    macros_out.push_string(&stem);
                    macros_out.push_str("_DECLARE(");
                    macro_params(p, &mut cem.mg, m9 as ModuleId, a9.ext(nid9).aggregate.generics, &mut macros_out);
                    macro_finish(mb_dec.as_str(), &mut macros_out);
                    macros_out.push_str("#define ");
                    macros_out.push_string(&stem);
                    macros_out.push_str("_DEFINE(");
                    macro_params(p, &mut cem.mg, m9 as ModuleId, a9.ext(nid9).aggregate.generics, &mut macros_out);
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
    stage_ms(verbose, &mut tt0, "cemit-stage macros");
    // Dyn typedef blocks: drain every dyn spelling site both manglers recorded (rendering can
    // discover further stems; the index loop rides the growing vector to a fixed point).
    {
        for i in 0..em.mg.dyn_reqs.len() {
            let rq = *em.mg.dyn_reqs.at(i);
            cem.mg.dyn_reqs.push(rq);
        }
        let mut di: usize = 0;
        cem.mg.mark_ctx = -1;
        while di < cem.mg.dyn_reqs.len() {
            let rq = *cem.mg.dyn_reqs.at(di);
            let _ = cem.dyn_request(rq.pm, rq.t);
            di += 1;
        }
    }
    // Const/static definitions: each referenced item folds through the Core IR interpreter; one
    // interpreter serves the whole pass (its lowered-callee cache, constant memos, and captured
    // static groups persist), and the descriptor sections below render from the same store.
    let mut cdit = iri::interp_new(p);
    cdit.parent = p.cir as *const iri::Interp;
    if cdit.parent != null {
        // the type check's budgets: a constant it accepted must evaluate here too
        cdit.max_steps = unsafe (*cdit.parent).max_steps;
        cdit.max_slots = unsafe (*cdit.parent).max_slots;
    }
    let mut cdefs = Segs::new();
    let mut cd_own9: ModuleId = 0;
    {
        let mut cd_ok: u64 = 0;
        let mut cd_skip: u64 = 0;
        // A constant or `static mut` that is `@used`, `@export`ed or in a named section is defined
        // also when no code names it: C code, the linker or a section walk finds it by its symbol or
        // its section.
        for m in 0..p.modules.len() {
            if !p.modules[m].has_ast {
                continue;
            }
            let a = unsafe &*p.module_ast_const(m as ModuleId);
            for k in 0..a.attrs.len() {
                let at = *a.attrs.at(k);
                let keep = at.kind == AttrKind::ATTR_USED as u8 || at.kind == AttrKind::ATTR_EXPORT as u8 || at.kind == AttrKind::ATTR_UNSAFE as u8 && (at.arg & UNSAFE_LINK_SECTION) != 0;
                if keep && a.at_const(at.owner).kind == NodeKind::NODE_CONST && !a.at_const(at.owner).as_data.const_def.is_extern {
                    cem.mg.mark_ctx = mbe::CTX_INST | emit_owner(p, m as ModuleId) as i64;
                    let _ = cem.stat_item(DefId { module: m as ModuleId, node: at.owner });
                }
            }
        }
        // A definition that addresses another item appends it (`stat_item`): each item once.
        let mut ci: usize = 0;
        while ci < cem.stat_items.len() {
            let si = ci;
            ci += 1;
            let em2 = cem.stat_items.at(si).em;
            let cdef = cem.stat_items.at(si).def;
            cdefs.close(cd_own9);
            cd_own9 = emit_owner(p, cdef.module);
            cem.mg.mark_ctx = mbe::CTX_INST | cd_own9 as i64;
            let csym = cem.stat_items.at(si).sym.clone();
            let cda = unsafe &*p.module_ast_const(cdef.module);
            let cdn = cda.at_const(cdef.node);
            // The C attribute that starts its definition: `used` for `@used` or a section, which
            // `@unsafe(link_section = "s")` names (as for a function), and for a section entry no
            // sanitizer padding (`SC_SECTION_DATA`).
            let mut csec = String::new();
            let cua = cda.attr_of(cdef.node, AttrKind::ATTR_UNSAFE);
            let sec = cua != null && (unsafe (*cua).arg & UNSAFE_LINK_SECTION) != 0;
            if sec || cda.attr_of(cdef.node, AttrKind::ATTR_USED) != null {
                csec.push_str("__attribute__((used");
                if sec {
                    let ss = unsafe (*cua).str_span;
                    csec.push_str(", section(\"");
                    csec.push_str(
                        p.modules[cdef.module as usize].source.as_str().slice(ss.start as usize, ss.end as usize),
                    );
                    csec.push_str("\")");
                }
                csec.push_str(")) ");
                if sec {
                    csec.push_str("SC_SECTION_DATA ");
                }
            }
            if cdn.kind == NodeKind::NODE_CONST && cdn.as_data.const_def.is_extern {
                // The backing C header owns the definition; the extern stub suffices.
                continue;
            }
            // A constant this pass cannot define is reported at its name.
            let csp = if cdn.kind == NodeKind::NODE_CONST {
                cda.at_const(cdn.as_data.const_def.name).as_data.name.text;
            } else {
                cdn.span;
            };
            let crefuse = cbe::Refusal {
                m: cdef.module,
                start: csp.start,
                end: csp.end,
                why: "a constant value that cannot be materialized as static data",
            };
            if cdn.kind != NodeKind::NODE_CONST || cdn.as_data.const_def.value == NODE_NONE {
                cem.refused.push(crefuse);
                cd_skip += 1;
                continue;
            }
            let cty = cem.stat_items.at(si).ty;
            // `@align` of a static and `const` of a read-only one: the specifiers its declarations
            // spell too.
            let mut al9 = String::new();
            cem.stat_specs(cdef, em2, cty, &mut al9);
            // The definition's prefix: its section and `used` (`csec`), then those specifiers.
            csec.push_string(&al9);
            // A generic extend's constant evaluates for the instance its reference named.
            let cargs = &cem.stat_items.at(si).args;
            let mut cpm: [ModuleId; 8] = [[0] = 0];
            let mut cpn: [NodeId; 8] = [[0] = NODE_NONE];
            let mut cam: [ModuleId; 8] = [[0] = 0];
            let mut cat: [TypeId; 8] = [[0] = TYPE_NONE];
            for k in 0..cargs.len() {
                unsafe cpm[k] = cargs.at(k).pm;
                unsafe cpn[k] = cargs.at(k).pnode;
                unsafe cam[k] = cargs.at(k).am;
                unsafe cat[k] = cargs.at(k).at;
            }
            let mut v = if cargs.len() == 0 {
                cdit.eval_const_in(cdef.module, cdef.node);
            } else {
                cdit.eval_const_inst(cdef.module, cdef.node, &cpm[0], &cpn[0], &cam[0], &cat[0], cargs.len());
            };
            if v.kind == iri::IV_NONE && cargs.len() != 0 {
                // A per-instance constant first evaluates here, for the instance its reference named:
                // its failure is the program's error, located at the constant.
                let why = if cdit.trap_get().len() != 0 {
                    cdit.trap_detail();
                } else {
                    "the initializer does not fold to a constant";
                };
                let csrc = p.modules[cdef.module as usize].source.as_str();
                let mut errs = diag::Errors::new();
                errs.emit(
                    dc::CONSTANT_CANNOT_EVALUATED_COMPILE_TIME_INSTANCE,
                    csp.start,
                    csp.end - csp.start,
                    format(
                        "constant '{}' cannot be evaluated at compile time for an instance: {}",
                        csrc.slice(csp.start as usize, csp.end as usize),
                        why,
                    ),
                );
                errs.finalize(csrc, p.modules[cdef.module as usize].file.as_str());
                errs.log();
                p.ok = false;
                continue;
            }
            if v.kind == iri::IV_PTR && v.i != 0 || v.kind == iri::IV_FN || cdit.c_zero(v) {
                // A pointer, a function value or a zero C object serializes as the one slot of a cell
                // of the constant's type.
                v = cdit.cell_of(v, em2, cty);
            }
            // The LIR check defines the item as data too: its read-only, thread-local and alignment.
            let mut lro = false;
            let mut ltls = false;
            let mut lal: u64 = 0;
            if cem.lir.is_some() {
                lro = cem.stat_ro(cdef, em2, cty);
                ltls = cda.attr_of(cdef.node, AttrKind::ATTR_THREAD_LOCAL) != null;
                let at = cda.attr_of(cdef.node, AttrKind::ATTR_ALIGN);
                if at != null {
                    lal = if unsafe (*at).expr {
                        cda.attr_value(cdef.node, AttrKind::ATTR_ALIGN).v;
                    } else {
                        unsafe (*at).arg;
                    };
                }
            }
            // Array-of-string consts render from their literal initializer directly.
            if v.kind == iri::IV_OBJ || v.kind == iri::IV_NONE {
                let vn0 = cda.at_const(cdn.as_data.const_def.value);
                if vn0.kind == NodeKind::NODE_STRUCT_INITIALIZER && vn0.as_data.struct_initializer.fields.len == 0 {
                    let mut line3 = csec.clone();
                    if cem.mg.ctype(em2, cty, csym.as_str(), &mut line3) {
                        line3.push_str(" = {0};\n");
                        cdefs.txt.push_string(&line3);
                        cd_ok += 1;
                        lir_zero(&mut cem, csym.as_str(), em2, cty, lro, ltls, lal);
                        lir_own_item(&mut cem, csym.as_str(), cd_own9, cdef);
                        continue;
                    }
                }
                // A repeat `[v; N]` holds the value and the count, not the elements: the static graph spells it.
                if vn0.kind == NodeKind::NODE_ARRAY_LITERAL && !vn0.as_data.array_literal.repeat {
                    let mut line2 = String::new();
                    let mut is_slice2 = false;
                    let mut ety2 = TYPE_NONE;
                    // A vector's lanes are the array inside its struct.
                    let vec2 = unsafe (*p.module_ast_const(em2)).type_at(cty).kind == TypeKind::TYPE_SIMD;
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
                    if vn0.as_data.array_literal.elements.len == 0 {
                        // `[]`: no data array (C has no empty initializer or zero-length object). A
                        // view points at the aligned sentinel; a zero-length array spells as a
                        // pointer nothing reads.
                        line2.push_string(&csec);
                        ok2 = cem.mg.ctype(em2, cty, csym.as_str(), &mut line2);
                        if ok2 && is_slice2 {
                            line2.push_str(" = { ");
                            ok2 = cem.zst_sentinel_ref(em2, ety2, &mut line2);
                            line2.push_str(", 0 };\n");
                        } else {
                            line2.push_str(" = 0;\n");
                        }
                    } else if is_slice2 {
                        ok2 = cem.mg.ctype(em2, ety2, "", &mut ecty);
                        if ok2 {
                            line2.push_str("static const ");
                            line2.push_string(&ecty);
                            line2.push_str(" ");
                            line2.push_string(&csym);
                            line2.push_str("__data[] = { ");
                        }
                    } else {
                        line2.push_string(&csec);
                        ok2 = cem.mg.ctype(em2, cty, csym.as_str(), &mut line2);
                        if ok2 {
                            line2.push_str(mbe::if_s(vec2, " = { { ", " = { "));
                        }
                    }
                    if ok2 && vn0.as_data.array_literal.elements.len != 0 {
                        let els = vn0.as_data.array_literal.elements;
                        let csrc2 = p.modules[cdef.module as usize].source.as_str();
                        for e2 in 0..els.len {
                            let eid = unsafe cda.list(els)[e2 as usize];
                            if e2 != 0 {
                                line2.push_str(", ");
                            }
                            if !render_const_elem(p, &mut cem.mg, cda, csrc2, eid, &mut line2) {
                                ok2 = false;
                                break;
                            }
                        }
                        line2.push_str(mbe::if_s(vec2, " } };\n", " };\n"));
                        if is_slice2 {
                            let mut view2 = csec.clone();
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
                        cdefs.txt.push_string(&line2);
                        cd_ok += 1;
                        lir_elems(
                            &mut cem,
                            &mut cdit,
                            csym.as_str(),
                            em2,
                            cty,
                            cdef.module,
                            vn0.as_data.array_literal.elements,
                            lro,
                            ltls,
                            lal,
                        );
                        lir_own_item(&mut cem, csym.as_str(), cd_own9, cdef);
                        continue;
                    }
                }
                // Any other aggregate: the CTFE static graph, captured straight from the
                // interpreter's live objects; a refusal falls back to the established
                // evaluator's graph, converted into the same store.
                let mut root3: i64 = 0 - 1;
                if v.kind == iri::IV_OBJ {
                    let mut sri = cdit.capture(v, true);
                    // The items the group addresses are defined and declared like referenced ones;
                    // when one has no storage of its own, the group copies every item instead.
                    let mut stored = true;
                    if sri.ok {
                        for gi in sri.root..sri.root + unsafe (*cdit.static_at(sri.root)).groupn {
                            let g = cdit.static_at(gi);
                            stored = stored && (unsafe (*g).inode == NODE_NONE || cem.stat_item(
                                DefId { module: unsafe (*g).im, node: unsafe (*g).inode },
                            ));
                        }
                    }
                    if sri.ok && !stored {
                        sri = cdit.capture(v, false);
                    }
                    if sri.ok {
                        root3 = sri.root;
                    }
                }
                let mut rootd3 = String::new();
                if root3 >= 0 && st_define(
                    p,
                    &mut cem,
                    &cdit,
                    csym.as_str(),
                    root3 as u32,
                    csec.as_str(),
                    &mut cdefs.txt,
                    &mut rootd3,
                ) {
                    cd_ok += 1;
                    lir_group(&mut cem, &cdit, csym.as_str(), root3 as u32, lro, ltls, lal);
                    lir_own_item(&mut cem, csym.as_str(), cd_own9, cdef);
                    continue;
                }
            }
            let mut line = csec.clone();
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
                    let usig = line.len() > csec.len() && line.as_str().byte_at(csec.len()) == b'u';
                    push_c_i64(&mut line, v.i, usig);
                } else if v.kind == iri::IV_BOOL {
                    line.push_str(
                        if v.i != 0 {
                            "true";
                        } else {
                            "false";
                        },
                    );
                } else if v.kind == iri::IV_FLOAT {
                    push_c_float(&mut line, v.f);
                } else {
                    // The literal's span indexes its own module's source (`tm`); `f` carries its form.
                    let csrc = p.modules[v.tm as usize].source.as_str();
                    let a0 = (v.i >> 32) as usize;
                    let b0 = (v.i & 0xFFFFFFFF) as usize;
                    if b0 > csrc.len() || a0 >= b0 {
                        cem.refused.push(crefuse);
                        cd_skip += 1;
                        continue;
                    }
                    let mut tmp = String::new();
                    let mut bytes = String::new();
                    cbe::str_const_bytes(csrc.slice(a0, b0), v.f as i64, &mut tmp, &mut bytes);
                    cbe::push_c_str_data(bytes.as_str(), &mut line);
                }
                line.push_str(";\n");
                cdefs.txt.push_string(&line);
                cd_ok += 1;
                lir_value(&mut cem, &mut cdit, csym.as_str(), em2, cty, v, lro, ltls, lal);
                lir_own_item(&mut cem, csym.as_str(), cd_own9, cdef);
            } else {
                if verbose {
                    eprint("const-skip: `{}` kind {}\n", csym.as_str(), v.kind);
                }
                cem.refused.push(crefuse);
                cd_skip += 1;
            }
        }
        cdefs.close(cd_own9);
        o.skips += cd_skip;
        if verbose {
            eprint("cemit-consts: {} defined, {} skipped\n", cd_ok, cd_skip);
        }
    }
    stage_ms(verbose, &mut tt0, "cemit-stage consts");
    // @reflect exports + `type_info` descriptor groups: the CTFE static graph rendered as file-
    // scope const data (extern roots; `__ct%u` auxiliaries static per group).
    // Descriptor roots the registry indexes carry hidden visibility where the target supports it.
    let vis9 = if tgt::obj_of(target).hidden {
        "__attribute__((visibility(\"hidden\"))) ";
    } else {
        "";
    };
    let mut sdefs = Segs::new();
    let mut tdecl = Segs::new();
    let mut sd_own9: ModuleId = 0;
    let mut reg_names = Vector::<String>::new();
    let mut reg_decls = Vector::<String>::new();
    if p.cir != null {
        let tih = p.prelude_lookup("TypeInfo", true);
        let mut ti_ok: u64 = 0;
        let mut ti_skip: u64 = 0;
        if tih.node != NODE_NONE {
            for ri in 0..cem.ti_reqs.len() {
                let em9 = cem.ti_reqs.at(ri).em;
                let ty9 = cem.ti_reqs.at(ri).ty;
                let sym9 = cem.ti_reqs.at(ri).sym.clone();
                sdefs.close(sd_own9);
                tdecl.close(sd_own9);
                sd_own9 = ti_owner(&mut cem, p.core_module, em9, ty9);
                cem.mg.mark_ctx = mbe::CTX_INST | sd_own9 as i64;
                let a9 = unsafe &mut *(p.module_ast_const(em9) as *mut Ast);
                let rty9 = a9.intern_type(
                    Ty { kind: TypeKind::TYPE_STRUCT, module: tih.mid, as_data: TyAs { decl: tih.node } },
                );
                let sr = cdit.eval_type_info_export(em9, rty9, em9, ty9);
                let mut ok9b = sr.ok;
                if ok9b {
                    let root9 = sr.root;
                    st_group_types(&mut em, &cdit, root9);
                    let mut rootd = String::new();
                    ok9b = st_define(p, &mut cem, &cdit, sym9.as_str(), root9, "const ", &mut sdefs.txt, &mut rootd);
                    if ok9b {
                        lir_group(&mut cem, &cdit, sym9.as_str(), root9, true, false, 0);
                        lir_own(&mut cem, sym9.as_str(), sd_own9);
                        tdecl.txt.push_str("extern const ");
                        tdecl.txt.push_string(&rootd);
                        tdecl.txt.push_str(";\n");
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
                    if a9.ext(nid9).aggregate.generics.len != 0 {
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
                    st_group_types(&mut em, &cdit, root9);
                    sdefs.close(sd_own9);
                    tdecl.close(sd_own9);
                    sd_own9 = m9 as ModuleId;
                    cem.mg.mark_ctx = mbe::CTX_INST | sd_own9 as i64;
                    let mut qn = String::new();
                    cem.mg.modpfx(m9 as ModuleId, &mut qn);
                    cem.mg.ident(m9 as ModuleId, a9.at_const(a9.ext_name(nid9)).as_data.name.text, &mut qn);
                    let mut nm9 = String::from_str("sc_typeinfo_");
                    nm9.push_string(&qn);
                    let mut rootd = String::new();
                    let mut pfx = String::from_str(vis9);
                    pfx.push_str("const ");
                    sdefs.txt.push_str("/* @reflect export */\n");
                    let ok9b = st_define(
                        p,
                        &mut cem,
                        &cdit,
                        nm9.as_str(),
                        root9,
                        pfx.as_str(),
                        &mut sdefs.txt,
                        &mut rootd,
                    );
                    if ok9b {
                        reg_names.push(nm9.clone());
                        reg_decls.push(rootd.clone());
                        lir_group(&mut cem, &cdit, nm9.as_str(), root9, true, false, 0);
                        lir_own(&mut cem, nm9.as_str(), sd_own9);
                    }
                    if ok9b {
                        ti_ok += 1;
                    } else {
                        ti_skip += 1;
                    }
                }
            }
        }
        sdefs.close(sd_own9);
        tdecl.close(sd_own9);
        if verbose && (ti_ok != 0 || ti_skip != 0) {
            eprint("cemit-reflect: {} groups, {} skipped\n", ti_ok, ti_skip);
        }
        o.skips += ti_skip;
    }
    stage_ms(verbose, &mut tt0, "cemit-stage statics+ti");
    // The graph freed its bodies after the drain: a function the text named since is a reference the
    // reachability walk missed, which no later step can emit.
    for i in 0..em.mg.fn_dem.len() {
        cem.mg.fn_take(*em.mg.fn_dem.at(i));
    }
    while fi < cem.mg.fn_dem.len() {
        let d = *cem.mg.fn_dem.at(fi);
        fi += 1;
        if module_emits(p, live, d.module as usize) && seed_emits(p, &mut cem, d.module, d.node, testing) && (unsafe &*p.module_ast_const(
            d.module,
        )).ext(d.node).function.generics.len == 0 {
            let mut sym9 = String::new();
            let _ = cem.mg.fn_sym(d.module, d.node, cem.mg.method_target(d.module, d.node), &mut sym9);
            eprint("error: internal: the emitted C names '{}' after the functions were emitted\n", sym9.as_str());
            o.skips += 1;
        }
    }
    let asm9 = prd.start();
    cemit_assemble(
        p,
        &mut cem,
        &mut em,
        &mut acc,
        &ext_incs,
        &gated_incs,
        &xhdrs,
        &si_names,
        &si_defs,
        &mut si_packs,
        &macros_out,
        &cdefs,
        &sdefs,
        &tdecl,
        &reg_names,
        &reg_decls,
        vis9,
        testing,
        o,
    );
    prd.stop(prb::P_ASSEMBLE, asm9);
    stage_ms(verbose, &mut tt0, "cemit-stage assembly");
    {
        // Cross-TU edges for pruning: module rows as themselves, every always-written context
        // (package-level text and the instance shards) as 65534.
        let nm9 = p.modules.len();
        let w9 = cem.mg.um_w();
        for src in 0..nm9 + 1 {
            // Past the modules: 65534, the union of the package-level row and every instance shard's.
            let s9 = if src < nm9 {
                src as u64;
            } else {
                65534u64;
            };
            for k in 0..w9 {
                let mut b = cem.mg.um_word(s9, k, true) | cem.mg.um_word(s9, k, false);
                if src == nm9 {
                    for q in 0..nm9 {
                        let cq = (mbe::CTX_INST | q as i64) as u64;
                        b |= cem.mg.um_word(cq, k, true) | cem.mg.um_word(cq, k, false);
                    }
                }
                while b != 0 {
                    let dst = k * 64 + b.trailing_zeros();
                    b &= b - 1;
                    if dst >= nm9 {
                        break;
                    }
                    o.edges.push(s9 << 32 | dst as u64);
                }
            }
        }
    }
    o.have_main = acc.have_main;
    o.main_mod = acc.main_mod;
    o.main_argv = acc.main_argv;
    prd.merge(&dow.pr);
    prd.merge(&cem.pr);
    // Per module, the held record this build writes (`lir::hold`; empty: the previous one when it
    // replays), under its native key.
    let mut recs = Vector::<String>::new();
    let mut nks = Vector::<u64>::new();
    if tuc.on {
        for m in 0..p.modules.len() {
            nks.push(nat_key(p, &tuc.keys, m));
        }
    }
    // An optimizing build optimizes the finished LIR: every constant's data is defined by now.
    if p.lir_opt && p.ok && cem.lir.is_some() {
        let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
        // A module's own assembly may give its symbols what a reference elsewhere cannot carry (a wasm
        // import module): its bodies stay in its object.
        let mut sealed = Vector::<bool>::with_capacity(p.modules.len());
        for m in 0..p.modules.len() {
            sealed.push(module_has_asm(p, m));
        }
        let pkg = &mut l.deref_mut().pkg;
        // A replayed unit's bodies the others may inline, its call graph and its data come from its record.
        for m in 0..held.len() {
            if let Some(h) = held.at(m) {
                lhold::add_free(pkg, h);
            }
        }
        for m in 0..held.len() {
            if let Some(h) = held.at(m) {
                lhold::add(pkg, m as u32, h);
            }
        }
        let mut r = lopt::Run::new(
            pkg,
            &sealed,
            lopt::Config { inline: inline_budget(p.opt, p.cg), loops: loop_budgets(p.opt, p.cg) },
        );
        // Each body starts once the callees it may inline are done.
        let mut g = sch::Jobs::from_edges(r.order.len(), &r.edges, replace(&mut r.order, Vector::<u32>::new()));
        sch::run_jobs(&mut g, p.jobs, lopt::job, &mut r, null);
        r.finish(pkg);
        if tuc.on {
            let mut want = Vector::<bool>::with_capacity(p.modules.len());
            for m in 0..p.modules.len() {
                want.push(!tuc.hit[m]);
            }
            lhold::save(pkg, &r, &want, &mut recs);
        }
        pkg.drop_held();
        cem.lir_put(l);
    }
    if tuc.on {
        tuc::held_put(&mut tuc, &recs, &nks);
        o.tuc_img = replace(&mut tuc.out, String::new());
        o.tuc_path = replace(&mut tuc.path, String::new());
        o.tuc_keys = replace(&mut tuc.keys, Vector::<u64>::new());
        o.tuc_hit = replace(&mut tuc.hit, Vector::<bool>::new());
    }
    // The LIR check of the bodies this build rendered (a refused one fails the build already). A module
    // the per-TU cache replayed passed it in the build that recorded it: SC_LIR is part of the key. A
    // build that asks for the LIR text (`lir_out`) runs without that cache, so every body is rendered.
    if cem.lir.is_some() && p.ok && cem.refused.len() == 0 && cbe::lir_requested(p) {
        let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
        if !l.deref_mut().check_all(p) {
            p.ok = false;
        }
        let tp = stdlib::get_env("SC_LIR_TEXT");
        if tp.is_some() || p.lir_out != null {
            let mut text = String::new();
            lprint::print_package(&l.deref().pkg, &mut text);
            if let Some(path) = &tp {
                let _ = write_file(path.as_str(), text.as_str());
            }
            if p.lir_out != null {
                unsafe *p.lir_out = text;
            }
        }
        // The hooks that read the LIR (`build_system::ext::reads_ir`): this build rendered every body.
        if p.ok && ext::reads_ir() && !ext::run_stage(ext::STAGE_AFTER_IR, p, &mut l.deref_mut().pkg) {
            p.ok = false;
        }
        cem.lir_put(l);
    }
    if cbe::native_on(p) {
        o.lir = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None);
    }
    o.refused = replace(&mut cem.refused, Vector::<cbe::Refusal>::new());
    p.inl_store = null;
    bst::relower(prd.c[prb::C_RELOWER_REFLECT], prd.c[prb::C_RELOWER_ZST]);
    o.pr = prd;
    if unsafe TS_ON {
        ty_stats_report(p);
    }
    let dumpp = stdlib::get_env("SC_TYPE_TABLE");
    if dumpp.is_some() {
        let mut txt = String::new();
        p.type_table_dump(&mut txt);
        let path = dumpp.unwrap();
        let f = stdio::fopen(path.as_str(), "wb");
        if f != null {
            unsafe stdio::fwrite(txt.as_ptr(), 1, txt.len(), f);
            unsafe stdio::fclose(f);
        }
    }
    bst::mark(bst::B_RENDER);
    ts_phase("render");
}

/// A type publication checkpoint: the whole-package typecheck frontier (before borrow checking)
/// and the borrow-check frontier (before emission) each end with every provisional type
/// published under a final package id and every retained store remapped: the module tables, the
/// constant engine, and the kept lowerings.
pub(package) fn publish_checkpoint(p: &mut loader::Package, keep: *mut irl::Keep) {
    if p.tt.deref().len() == 0 {
        return; // module-local identity (no bind_types): nothing to publish
    }
    p.publish_types();
    if p.cir != null {
        let ci = unsafe &mut *(p.cir as *mut iri::Interp);
        ci.remap_types(p);
    }
    if keep != null {
        let t0 = std::parallel::platform::now_ns();
        let n9 = unsafe (&mut *keep).remap_types(p);
        if stdlib::getenv("SC_TYPE_STATS") != null {
            eprintln(
                "type-stats: publication {} remapped {} of {} kept bodies in {} us",
                p.publications,
                n9,
                unsafe (&*keep).kept.len(),
                (std::parallel::platform::now_ns() - t0) / 1000,
            );
        }
    }
    if stdlib::getenv("SC_TYPE_VALIDATE") != null && !p.check_published() {
        unsafe stdlib::exit(1);
    }
}

/// One line of syntax accounting for the package at phase `label` (SC_SYNTAX_STATS): node and
/// child counts with the share inside bodies, the retained bytes of every syntax and side-table
/// container, the source text, and the module that retains the most.
fn syntax_stats_report(p: &loader::Package, label: str) {
    if stdlib::getenv("SC_SYNTAX_STATS") == null {
        return;
    }
    let mut st = SyntaxStats {};
    let mut src: usize = 0;
    let mut modules: usize = 0;
    let mut big: usize = 0;
    let mut big_m: usize = 0;
    for i in 0..p.modules.len() {
        let m = p.modules.at(i);
        if !m.has_ast {
            continue;
        }
        modules += 1;
        src += m.source.capacity();
        m.ast.syntax_stats(&mut st);
        let r = m.ast.retained_bytes() + m.source.capacity();
        if r > big {
            big = r;
            big_m = i;
        }
    }
    eprintln(
        "syntax-stats[{}]: peak rss {} MiB | modules {} node {} B | nodes {} ({} KiB) bodies {} body-nodes {} | children {} body-children {} ({} KiB) | resolutions {} KiB types {} KiB pool {} KiB tables {} KiB source {} KiB | largest {} {} KiB (module {}/{} body {}/{} nodes/capacity)",
        label,
        process::peak_rss().unwrap_or(0) / 1048576,
        modules,
        sizeof(Node),
        st.nodes,
        st.nodes_cap / 1024,
        st.bodies,
        st.body_nodes,
        st.children,
        st.body_children,
        st.children_cap / 1024,
        st.resolutions / 1024,
        st.types / 1024,
        st.pool / 1024,
        st.tables / 1024,
        src / 1024,
        p.modules.at(big_m).path.as_str(),
        big / 1024,
        p.modules.at(big_m).ast.nodes.len(),
        p.modules.at(big_m).ast.nodes.retained() / sizeof(Node),
        p.modules.at(big_m).ast.b.nodes.len(),
        p.modules.at(big_m).ast.b.nodes.retained() / sizeof(Node),
    );
}

/// The SC_TYPE_STATS report: the identity-path counters, the bytes the per-module type pools and
/// their indexes retain, and the structural census (how many pool entries stand for one type).
fn ty_stats_report(p: &loader::Package) {
    let mut types: u64 = 0;
    let mut insts: u64 = 0;
    let mut pool_bytes: u64 = 0;
    let mut index_bytes: u64 = 0;
    let mut nominal: u64 = 0;
    let g = p.tt.deref();
    for t in 1..g.len() {
        let k = g.at(t).kind;
        if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_ENUM || k == TypeKind::TYPE_OPAQUE || k == TypeKind::TYPE_FUNCTION || k == TypeKind::TYPE_GENERIC {
            nominal += 1;
        }
    }
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        types += a.ntypes() as u64;
        insts += a.ninstances() as u64;
        pool_bytes += a.pool.retained() as u64;
        index_bytes += ((a.used.len() + a.used_inst.len()) * 4 + a.used_bits.len() * 8) as u64;
    }
    eprintln(
        "type-stats: sizeof Ty {} TyInstance {} InstRec {} ArgKey {}",
        sizeof(Ty),
        sizeof(TyInstance),
        sizeof(ig::InstRec),
        sizeof(ig::ArgKey),
    );
    eprintln(
        "type-stats: intern calls {} hits {} probe-steps {} rebuilds {} | instance calls {} hits {} probe-steps {}",
        ts_get(TS_INTERN),
        ts_get(TS_INTERN_HIT),
        ts_get(TS_INTERN_PROBE),
        ts_get(TS_INTERN_REBUILD),
        ts_get(TS_INST),
        ts_get(TS_INST_HIT),
        ts_get(TS_INST_PROBE),
    );
    eprintln(
        "type-stats: reintern calls {} ({} us) | xty calls {} map-hits {} ({} us) | foreign lower calls {} memo-hits {} ({} us) memo entries {}",
        ts_get(TS_REINTERN),
        ts_get(TS_REINTERN_NS) / 1000,
        ts_get(TS_XTY),
        ts_get(TS_XTY_HIT),
        ts_get(TS_XTY_NS) / 1000,
        ts_get(TS_LOWER),
        ts_get(TS_LOWER_HIT),
        ts_get(TS_LOWER_NS) / 1000,
        ts_get(TS_LOWER_MEMO_N),
    );
    eprintln(
        "type-stats: instance-graph adds {} hits {} ({} us) retained {} B | layout services {} queries {} hits {} computed {} ({} us) | fn_sig calls {}",
        ts_get(TS_IGADD),
        ts_get(TS_IGADD_HIT),
        ts_get(TS_IGADD_NS) / 1000,
        ts_get(TS_IG_BYTES),
        ts_get(TS_LAY_SVC),
        ts_get(TS_LAY),
        ts_get(TS_LAY_HIT),
        ts_get(TS_LAY_RAW),
        ts_get(TS_LAY_NS) / 1000,
        ts_get(TS_FNSIG),
    );
    eprintln(
        "type-stats: layout cache entries {} (~{} B) | foreign lowerings in signatures {} of {}",
        ts_get(TS_LAY_INS),
        ts_get(TS_LAY_INS) * 34,
        ts_get(TS_LOWER_SIG),
        ts_get(TS_LOWER),
    );
    eprintln(
        "type-stats: package table: {} types ({} nominal), {} instance records, {} const forms, {} B retained; module use lists: {} type uses, {} instance uses, {} B, provisional pools {} B; translation maps: lower-memo {} entries (~{} B), inliner {} B",
        g.len(),
        nominal,
        g.ninst(),
        g.nclin(),
        g.retained(),
        types,
        insts,
        index_bytes,
        pool_bytes,
        ts_get(TS_LOWER_MEMO_N),
        ts_get(TS_LOWER_MEMO_N) * 24,
        ts_get(TS_XM_BYTES),
    );
}

// A literal const-initializer element as C: string literals become str views, integers copy
// their digits, `null` is 0, struct literals recurse with designated members (a zero-sized
// field has none). Anything else refuses.
fn render_const_elem(p: &loader::Package, mg: &mut mbe::Mangler, a: &Ast, src: str, eid: NodeId, out: &mut String) bool {
    let n = a.at_const(eid);
    if n.kind == NodeKind::NODE_LITERAL {
        let rsp = n.as_data.literal.raw;
        let txt = src.slice(rsp.start as usize, rsp.end as usize);
        let tk = n.as_data.literal.token_type;
        if tk == TokenType::StringLiteral || tk == TokenType::ByteStringLiteral || tk == TokenType::MatchertextLiteral {
            let mut tmp = String::new();
            let mut bytes = String::new();
            cbe::str_const_bytes(txt, tk as i64, &mut tmp, &mut bytes);
            cbe::push_c_str_data(bytes.as_str(), out);
            return true;
        }
        if tk == TokenType::FloatLiteral {
            let ty = a.type_of(eid);
            let y = *a.type_at(ty);
            cbe::push_c_float_lit(
                txt,
                ty != TYPE_NONE && y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_F32,
                out,
            );
        } else if txt.len() != 0 && txt.byte_at(0) >= 48 && txt.byte_at(0) <= 57 {
            cbe::push_c_number(txt, out);
            // An unsigned constant past `INT64_MAX` is no implicitly unsigned C literal.
            let y = *a.type_at(a.type_of(eid));
            if y.kind == TypeKind::TYPE_BUILTIN && bt_is_unsigned(y.as_data.builtin) {
                out.push_str("ULL");
            }
        } else if n.as_data.literal.token_type == TokenType::Null {
            out.push_str("0");
        } else if tk == TokenType::CharacterLiteral || tk == TokenType::ByteCharacterLiteral {
            // The decoded value: C spells no byte literal, and a char above 127 narrows with a cast.
            let v = tok::char_literal_value(src, rsp).unwrap_or(0);
            if tk == TokenType::CharacterLiteral && v > 127 {
                out.push_str("(char)");
            }
            out.push_i64(v);
        } else {
            out.push_str(txt);
        }
        return true;
    }
    if n.kind == NodeKind::NODE_STRUCT_INITIALIZER {
        out.push_str("{ ");
        let fls = n.as_data.struct_initializer.fields;
        let mut first = true;
        for i in 0..fls.len {
            let fi = unsafe a.list(fls)[i as usize];
            let fd = a.resolution_def(a.at_const(fi).as_data.field_initializer.name);
            if fd.node == NODE_NONE {
                return false;
            }
            let fa = p.module_ast_const(fd.module);
            if unsafe (*fa).at_const(fd.node).kind != NodeKind::NODE_FIELD {
                return false;
            }
            if mg.is_zst(fd.module, unsafe (*fa).member_ty(fd.node)) {
                continue;
            }
            if !first {
                out.push_str(", ");
            }
            first = false;
            out.push_str(".");
            mg.field_ident(fd.module, fd.node, out);
            out.push_str(" = ");
            if !render_const_elem(p, mg, a, src, a.at_const(fi).as_data.field_initializer.value, out) {
                return false;
            }
        }
        out.push_str(" }");
        return true;
    }
    return false;
}

// Define every aggregate a descriptor group embeds by value: descriptor data names `FieldInfo`,
// `MetaInfo`, ... whether or not a live body ever spells them.
fn st_group_types(em: &mut tbe::TuEmit, cev: &iri::Interp, root: u32) {
    let groupn = unsafe (*cev.static_at(root)).groupn;
    for gi in root..root + groupn {
        let g = cev.static_at(gi);
        let shape = unsafe (*g).shape;
        if shape == iri::SS_STRUCT || shape == iri::SS_ENUM {
            if unsafe (*g).nargs == 0 {
                let dm = unsafe (*g).dm;
                let _ = em.emit_agg(&tbe::AggItem { m: dm, decl: unsafe (*g).dn, amod: dm, aty: TYPE_NONE });
            }
        } else {
            let _ = em.field_dep(unsafe (*g).etm, unsafe (*g).ety);
        }
    }
}

// The C declarator of statics entry `gi` around `decl`: heap/array groups spell as element arrays,
// aggregates by their (instance) names, cells by their value type.
fn st_ctype(p: &loader::Package, mg: &mut mbe::Mangler, cev: &iri::Interp, gi: u32, decl: str, out: &mut String) bool {
    let g = cev.static_at(gi);
    let shape = unsafe (*g).shape;
    if unsafe (*g).vt != TYPE_NONE {
        return mg.ctype(unsafe (*g).vm, unsafe (*g).vt, decl, out);
    }
    if shape == iri::SS_HEAP || shape == iri::SS_ARRAY {
        let mut n2 = unsafe (*g).n;
        if n2 == 0 {
            n2 = 1;
        }
        let mut d2 = String::from_str(decl);
        d2.push_str("[");
        d2.push_u64(n2);
        d2.push_str("]");
        let ok = mg.ctype(unsafe (*g).etm, unsafe (*g).ety, d2.as_str(), out);
        return ok;
    }
    if shape == iri::SS_CELL {
        return mg.ctype(unsafe (*g).etm, unsafe (*g).ety, decl, out);
    }
    // SS_STRUCT / SS_ENUM: the aggregate's (instance) C name, a type spelling.
    let dm = unsafe (*g).dm;
    let dn = unsafe (*g).dn;
    let da = unsafe &*p.module_ast_const(dm);
    if da.ext(dn).aggregate.is_extern {
        // C's own type, spelled as `Mangler::ctype` spells it (a scoped header's by alias); no
        // definition header.
        extern_c_name(p, dm, dn, out);
        if decl.len() != 0 {
            out.push_str(" ");
            out.push_str(decl);
        }
        return true;
    }
    let st = out.len();
    mg.type_depth += 1;
    mg.qualified(dm, da.ext_name(dn), out);
    let mut ok = true;
    if unsafe (*g).nargs != 0 {
        let mut last = unsafe (*g).nargs;
        while last > 0 && mg.is_default_arg(
            dm,
            dn,
            last - 1,
            unsafe (*g).am[(last - 1) as usize],
            unsafe (*g).at[(last - 1) as usize],
        ) {
            last -= 1;
        }
        for i in 0..last {
            if !ok {
                break;
            }
            out.push_str("__");
            ok = mg.type_m(unsafe (*g).am[i as usize], unsafe (*g).at[i as usize], out);
        }
    }
    mg.type_depth -= 1;
    if !ok {
        return false;
    }
    mg.need_name(fnv(out.as_str().slice(st, out.len())), true);
    if decl.len() != 0 {
        out.push_str(" ");
        out.push_str(decl);
    }
    return true;
}

// Is struct slot `idx` a zero-sized field (no C member exists for it)? Resolved under the
// StaticObj's recorded instance args, mirroring st_field's field-ordinal indexing.
fn st_field_zst(p: &loader::Package, mg: &mut mbe::Mangler, g: *const iri::StaticObj, idx: u32) bool {
    let dm = unsafe (*g).dm;
    let dn = unsafe (*g).dn;
    let a = unsafe &*p.module_ast_const(dm);
    let ms = a.ext(dn).aggregate.members;
    let is_tuple = a.ext(dn).aggregate.is_tuple;
    let mut fty = TYPE_NONE;
    let mut fi: u32 = 0;
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        if !is_tuple && a.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        if fi == idx {
            fty = a.member_ty(fid);
            break;
        }
        fi += 1;
    }
    return st_zst(p, mg, g, fty);
}

// Is member type `fty` of the aggregate of statics entry `g` zero-sized under its recorded
// instance args?
fn st_zst(p: &loader::Package, mg: &mut mbe::Mangler, g: *const iri::StaticObj, fty: TypeId) bool {
    if fty == TYPE_NONE {
        return false;
    }
    let nb = st_push_args(p, mg, g);
    let z = mg.is_zst(unsafe (*g).dm, fty);
    mg.pop_subs(nb);
    return z;
}

// Bind the generic parameters of static object `g`'s aggregate to its recorded arguments; the count
// is what `pop_subs` takes.
fn st_push_args(p: &loader::Package, mg: &mut mbe::Mangler, g: *const iri::StaticObj) usize {
    let dm = unsafe (*g).dm;
    let a = unsafe &*p.module_ast_const(dm);
    let gens = a.ext(unsafe (*g).dn).aggregate.generics;
    let mut nb: usize = 0;
    for i in 0..gens.len {
        if i as u8 >= unsafe (*g).nargs {
            break;
        }
        mg.push_sub(dm, unsafe a.list(gens)[i as usize], unsafe (*g).am[i as usize], unsafe (*g).at[i as usize]);
        nb += 1;
    }
    return nb;
}

// `.field` designator for member index `idx` of aggregate `(dm, dn)` (`._N` for tuples).
fn st_field(p: &loader::Package, mg: &mut mbe::Mangler, dm: ModuleId, dn: NodeId, idx: u32, out: &mut String) {
    let a = unsafe &*p.module_ast_const(dm);
    if a.ext(dn).aggregate.is_tuple {
        out.push_str("._");
        out.push_u64(idx);
        return;
    }
    let ms = a.ext(dn).aggregate.members;
    let mut fi: u32 = 0;
    for i in 0..ms.len {
        let fid = unsafe a.list(ms)[i as usize];
        if a.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        if fi == idx {
            out.push_str(".");
            mg.field_ident(dm, fid, out);
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
    if unsafe (*g).inode != NODE_NONE {
        let _ = mg.const_sym(unsafe (*g).im, unsafe (*g).inode, out);
        return;
    }
    if unsafe (*g).parent == iri::S_NO_PARENT {
        out.push_str(name);
        if unsafe (*g).ord != 0 {
            out.push_str("__ct");
            out.push_u64(unsafe (*g).ord - 1);
        }
        return;
    }
    let pi = unsafe (*g).parent;
    let s0 = out.len();
    st_path(p, mg, cev, name, pi, out);
    let pg = cev.static_at(pi);
    let pshape = unsafe (*pg).shape;
    let pslot = unsafe (*g).pslot;
    if (pshape == iri::SS_ARRAY || pshape == iri::SS_HEAP) && unsafe (*pg).vt != TYPE_NONE {
        // A vector's lane through a pointer to its lane type: a register-sized vector's has no address.
        let v = String::from_str(out.as_str().slice(s0, out.len()));
        out.truncate(s0);
        out.format_into("((__typeof__({}.l[0]) *)&{})[{}]", v.as_str(), v.as_str(), pslot);
    } else if pshape == iri::SS_ARRAY || pshape == iri::SS_HEAP {
        out.push_str("[");
        out.push_u64(pslot);
        out.push_str("]");
    } else if pshape == iri::SS_STRUCT {
        st_field(p, mg, unsafe (*pg).dm, unsafe (*pg).dn, pslot, out);
    } else if pshape == iri::SS_ENUM {
        let a = unsafe &*p.module_ast_const(unsafe (*pg).dm);
        let ms = a.ext(unsafe (*pg).dn).aggregate.members;
        let tag = (unsafe (*pg).slots.at(0).i) as u32;
        let vid = unsafe a.list(ms)[tag as usize];
        out.push_str(".payload.");
        mg.ident(unsafe (*pg).dm, a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text, out);
        let vdat = a.at_const(vid).as_data.variant;
        if vdat.struct_payload {
            let pfid = unsafe a.list(vdat.payload)[(pslot - 1) as usize];
            out.push_str(".");
            mg.ident(unsafe (*pg).dm, a.at_const(a.at_const(pfid).as_data.field.name).as_data.name.text, out);
        } else {
            out.push_str("._");
            out.push_u64(pslot - 1);
        }
    }
}

// Is statics entry `gi` zero-sized: no C object, its references spell a sentinel?
fn st_zobj(mg: &mut mbe::Mangler, cev: &iri::Interp, gi: u32) bool {
    let g = cev.static_at(gi);
    return unsafe (*g).ety != TYPE_NONE && mg.is_zst(unsafe (*g).etm, unsafe (*g).ety);
}

// One relocation: a function's address or a (possibly interior) pointer into a sibling static.
fn st_rel(p: &loader::Package, cem: &mut cbe::CEmit, cev: &iri::Interp, name: str, r: &iri::SRel, out: &mut String) bool {
    if r.kind == iri::SREL_FN {
        let tgt = cem.mg.method_target(r.fm, r.fnode);
        return cem.mg.fn_sym(r.fm, r.fnode, tgt, out);
    }
    if st_zobj(&mut cem.mg, cev, r.target) {
        // A zero-sized object has no C storage: its address is the aligned sentinel.
        let t = cev.static_at(r.target);
        let lo = cem.mg.layout_sub(unsafe (*t).etm, unsafe (*t).ety);
        out.push_str("(void *)&");
        cem.sentinel(pick(lo.ok && lo.align > 1, lo.align, 1u64), out);
        return true;
    }
    let tshape = unsafe (*cev.static_at(r.target)).shape;
    if tshape == iri::SS_ARRAY || tshape == iri::SS_HEAP {
        let vec = unsafe (*cev.static_at(r.target)).vt != TYPE_NONE;
        if r.toff == 0 && !vec {
            out.push_str("(void *)");
            st_path(p, &mut cem.mg, cev, name, r.target, out);
        } else if vec {
            let mut v = String::new();
            st_path(p, &mut cem.mg, cev, name, r.target, &mut v);
            out.format_into("(void *)((__typeof__({}.l[0]) *)&{} + {})", v.as_str(), v.as_str(), r.toff);
        } else {
            out.push_str("(void *)&");
            st_path(p, &mut cem.mg, cev, name, r.target, out);
            out.format_into("[{}]", r.toff);
        }
        return true;
    }
    out.push_str("(void *)&");
    st_path(p, &mut cem.mg, cev, name, r.target, out);
    if tshape == iri::SS_STRUCT && r.toff != 0 {
        st_field(
            p,
            &mut cem.mg,
            unsafe (*cev.static_at(r.target)).dm,
            unsafe (*cev.static_at(r.target)).dn,
            r.toff,
            out,
        );
    }
    return true;
}

// A float constant as a C literal that converts back to the same double: 17 significant digits, a
// `.0` when the digits alone would spell an integer constant, and compiler builtins for infinity and
// NaN, which have no literal spelling. An f32 destination rounds this exact double as C does.
fn push_c_float(out: &mut String, v: f64) {
    if v.is_nan() {
        out.push_str("__builtin_nan(\"\")");
        return;
    }
    if v.is_infinite() {
        out.push_str(
            if v < 0.0 {
                "-__builtin_inf()";
            } else {
                "__builtin_inf()";
            },
        );
        return;
    }
    let mut buf = Buf64 {};
    let n = (unsafe stdio::snprintf(&mut buf[0], 64, "%.17g".ptr() as *const char, v)) as usize;
    out.push_str(str::from_cbuf(buf.as_slice()));
    for i in 0..n {
        let c = buf[i] as u8;
        if c == b'.' || c == b'e' {
            return;
        }
    }
    out.push_str(".0");
}

// One slot's initializer expression.
fn st_slot(p: &loader::Package, cem: &mut cbe::CEmit, cev: &iri::Interp, name: str, gi: u32, k: u32, out: &mut String) bool {
    let g = cev.static_at(gi);
    let sl = *unsafe (*g).slots.at(k as usize);
    if sl.kind == iri::SK_ZERO {
        out.push_str("{0}");
        return true;
    }
    if sl.kind == iri::SK_NULL {
        out.push_str("NULL");
        return true;
    }
    if sl.kind == iri::SK_AGG {
        return st_init(p, cem, cev, name, sl.child(), out);
    }
    if sl.kind == iri::SK_REL {
        for ri in 0..unsafe (*g).rels.len() {
            if unsafe (*g).rels.at(ri).slot == k {
                return st_rel(p, cem, cev, name, unsafe (*g).rels.at(ri), out);
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
        push_c_float(out, sl.f());
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
    push_c_i64(out, sl.i, usig);
    return true;
}

// `v` as a C integer literal: a negative value of an unsigned type (`usig`) prints its unsigned
// bits with the 64-bit suffix, and i64::MIN (no C literal) prints as an expression.
fn push_c_i64(out: &mut String, v: i64, usig: bool) {
    if usig && v < 0 {
        out.push_u64(v as u64);
        out.push_str("ULL");
    } else if v as u64 == 0x8000000000000000u64 {
        out.push_str("(-9223372036854775807LL - 1)");
    } else {
        out.push_i64(v);
    }
}

// Whether statics entry `gi` is all zero bits: every slot a zero scalar (+0.0 for a float), a null
// pointer or an all-zero aggregate. An enum is never: its tag constant need not be 0.
fn st_all_zero(cev: &iri::Interp, gi: u32) bool {
    let g = cev.static_at(gi);
    if unsafe (*g).shape == iri::SS_ENUM {
        return false;
    }
    for k in 0..unsafe (*g).slots.len() {
        let sl = *unsafe (*g).slots.at(k);
        let zero = if sl.kind == iri::SK_INT || sl.kind == iri::SK_BOOL || sl.kind == iri::SK_FLOAT {
            sl.i == 0;
        } else if sl.kind == iri::SK_AGG {
            st_all_zero(cev, sl.child());
        } else {
            sl.kind == iri::SK_ZERO || sl.kind == iri::SK_NULL;
        };
        if !zero {
            return false;
        }
    }
    return true;
}

// Whether slot `k` of statics entry `gi` is all zero bits: an initializer leaves it out, as C zero-fills
// a member or element it does not name. A nested `{0}` for an aggregate whose first member is an
// aggregate (glibc's `pthread_mutex_t`) is an error under gcc's -Wmissing-braces.
fn st_slot_zero(cev: &iri::Interp, gi: u32, k: u32) bool {
    let sl = *unsafe (*cev.static_at(gi)).slots.at(k as usize);
    return sl.kind == iri::SK_ZERO || sl.kind == iri::SK_AGG && st_all_zero(cev, sl.child());
}

// The braced initializer of statics entry `gi`.
fn st_init(p: &loader::Package, cem: &mut cbe::CEmit, cev: &iri::Interp, name: str, gi: u32, out: &mut String) bool {
    let g = cev.static_at(gi);
    let shape = unsafe (*g).shape;
    let nslots = (unsafe (*g).slots.len()) as u32;
    if shape == iri::SS_CELL {
        return st_slot(p, cem, cev, name, gi, 0, out);
    }
    if shape == iri::SS_ARRAY || shape == iri::SS_HEAP {
        if st_all_zero(cev, gi) {
            out.push_str("{0}");
            return true;
        }
        let ek = unsafe (&*p.module_ast_const(unsafe (*g).etm)).type_at(unsafe (*g).ety).kind;
        let escalar = ek == TypeKind::TYPE_BUILTIN || ek == TypeKind::TYPE_POINTER || ek == TypeKind::TYPE_REFERENCE || ek == TypeKind::TYPE_FUNCTION;
        // A vector's lanes are the array inside its struct.
        let vec = unsafe (*g).vt != TYPE_NONE;
        out.push_str(mbe::if_s(vec, "{ { ", "{ "));
        // An all-zero aggregate element is left out; the next element names its index.
        let mut ne: u32 = 0;
        let mut gap = false;
        for k in 0..nslots {
            if !escalar && st_slot_zero(cev, gi, k) {
                gap = true;
                continue;
            }
            if ne != 0 {
                out.push_str(", ");
            }
            ne += 1;
            if gap {
                out.format_into("[{}] = ", k);
                gap = false;
            }
            if unsafe (*g).slots.at(k as usize).kind == iri::SK_ZERO && escalar {
                out.push_str("0");
            } else if !st_slot(p, cem, cev, name, gi, k, out) {
                return false;
            }
        }
        out.push_str(mbe::if_s(vec, " } }", " }"));
        return true;
    }
    if shape == iri::SS_ENUM {
        let dm = unsafe (*g).dm;
        let dn = unsafe (*g).dn;
        let a = unsafe &*p.module_ast_const(dm);
        let ms = a.ext(dn).aggregate.members;
        let tag = (unsafe (*g).slots.at(0).i) as u32;
        if tag >= ms.len {
            out.push_str("{0}");
            return true;
        }
        let vid = unsafe a.list(ms)[tag as usize];
        let vdat = a.at_const(vid).as_data.variant;
        let nb = st_push_args(p, &mut cem.mg, g);
        let mut ns = NODE_NONE;
        let mut nn = NODE_NONE;
        let nk = cem.mg.niche(dm, dn, &mut ns, &mut nn);
        cem.mg.pop_subs(nb);
        // A zero-sized payload member has no C storage: it takes no initializer.
        let mut pay = Vector::<u32>::new();
        for k in 1..nslots {
            if !st_slot_zero(cev, gi, k) && !st_zst(
                p,
                &mut cem.mg,
                g,
                a.member_ty(unsafe a.list(vdat.payload)[(k - 1) as usize]),
            ) {
                pay.push(k);
            }
        }
        if nk != lay::NK_NONE && pay.len() == 0 {
            // A niche enum has no tag: `none` is the all-zero value.
            out.push_str("{0}");
            return true;
        }
        out.push_str("{ ");
        if nk == lay::NK_NONE {
            out.push_str(".tag = ");
            cem.mg.enum_tag(dm, dn, vid, out);
        }
        if pay.len() != 0 {
            out.push_str(mbe::if_s(nk == lay::NK_NONE, ", .payload.", ".payload."));
            cem.mg.ident(dm, a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text, out);
            out.push_str(" = { ");
            for i in 0..pay.len() {
                let k = pay[i];
                if i != 0 {
                    out.push_str(", ");
                }
                if vdat.struct_payload {
                    let pfid = unsafe a.list(vdat.payload)[(k - 1) as usize];
                    out.push_str(".");
                    cem.mg.ident(dm, a.at_const(a.at_const(pfid).as_data.field.name).as_data.name.text, out);
                    out.push_str(" = ");
                } else {
                    out.push_str("._");
                    out.push_u64(k - 1);
                    out.push_str(" = ");
                }
                if !st_slot(p, cem, cev, name, gi, k, out) {
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
    let uact = unsafe (*g).uactive;
    if uact >= 0 && st_slot_zero(cev, gi, uact as u32) {
        out.push_str("{0}");
        return true;
    }
    if uact >= 0 {
        out.push_str("{ ");
        st_field(p, &mut cem.mg, unsafe (*g).dm, unsafe (*g).dn, uact as u32, out);
        out.push_str(" = ");
        if !st_slot(p, cem, cev, name, gi, uact as u32, out) {
            return false;
        }
        out.push_str(" }");
        return true;
    }
    out.push_str("{ ");
    let mut ne9: u32 = 0;
    for k in 0..nslots {
        if st_field_zst(p, &mut cem.mg, g, k) || st_slot_zero(cev, gi, k) {
            // A zero-sized field has no C member to initialize; an all-zero one is C's default.
            continue;
        }
        if ne9 != 0 {
            out.push_str(", ");
        }
        ne9 += 1;
        st_field(p, &mut cem.mg, unsafe (*g).dm, unsafe (*g).dn, k, out);
        out.push_str(" = ");
        if !st_slot(p, cem, cev, name, gi, k, out) {
            return false;
        }
    }
    if ne9 == 0 {
        // Every field erased or all zero.
        out.push_str("0");
    }
    out.push_str(" }");
    return true;
}

// A whole group at file scope: tentative forward declarations for every standalone auxiliary
// (back-references and cycles resolve against them), then their definitions. The ROOT is the
// caller's to define (its linkage differs per use).
fn st_group(p: &loader::Package, cem: &mut cbe::CEmit, cev: &iri::Interp, name: str, root: u32, out: &mut String) bool {
    let groupn = unsafe (*cev.static_at(root)).groupn;
    let mut gis = Vector::<u32>::new();
    let mut decls = Vector::<String>::new();
    for gi in root + 1..root + groupn {
        if unsafe (*cev.static_at(gi)).parent != iri::S_NO_PARENT || unsafe (*cev.static_at(gi)).inode != NODE_NONE || st_zobj(
            &mut cem.mg,
            cev,
            gi,
        ) {
            continue;
        }
        let mut nm2 = String::from_str(name);
        nm2.push_str("__ct");
        nm2.push_u64(unsafe (*cev.static_at(gi)).ord - 1);
        let mut dl = String::new();
        if !st_ctype(p, &mut cem.mg, cev, gi, nm2.as_str(), &mut dl) {
            return false;
        }
        // A declarator that spells a const pointee already (`const T *p`) takes no second `const`.
        if !dl.as_str().starts_with("const ") {
            dl.insert_str(0, "const ");
        }
        out.push_str("static ");
        out.push_string(&dl);
        out.push_str(";\n");
        gis.push(gi);
        decls.push(dl);
    }
    for k in 0..gis.len() {
        out.push_str("__attribute__((unused)) static ");
        out.push_string(decls.at(k));
        out.push_str(" = ");
        let ok = st_init(p, cem, cev, name, gis[k], out);
        out.push_str(";\n");
        if !ok {
            return false;
        }
    }
    return true;
}

// Define static object `root` as `name` into `out`: its group (st_group), then
// `<prefix><declarator> = <initializer>;`. `rootd` receives the root's declarator. False when a part
// cannot be rendered.
fn st_define(
    p: &loader::Package,
    cem: &mut cbe::CEmit,
    cev: &iri::Interp,
    name: str,
    root: u32,
    prefix: str,
    out: &mut String,
    rootd: &mut String,
) bool {
    let mut grp = String::new();
    let okg = st_group(p, cem, cev, name, root, &mut grp);
    let okc = st_ctype(p, &mut cem.mg, cev, root, name, rootd);
    if !okg || !okc {
        return false;
    }
    out.push_string(&grp);
    out.push_str(prefix);
    out.push_string(rootd);
    out.push_str(" = ");
    if !st_init(p, cem, cev, name, root, out) {
        return false;
    }
    out.push_str(";\n");
    return true;
}

// The LIR check's data for an emitted constant or static: its CTFE value `v`, its zero bytes, or its
// captured group `root` (`Lower::static_value`, `static_zero`, `static_group`).
// Static `name` defined in a TU of module `unit`: its LIR data is that unit's, or the unit does not
// compile when the lowering could not define it.
fn lir_own(cem: &mut cbe::CEmit, name: str, unit: u32) {
    if let Some(l) = &mut cem.lir {
        l.claim_data(name, unit);
    }
}

// `lir_own` of constant or static item `d`, with its `@used` and section.
fn lir_own_item(cem: &mut cbe::CEmit, name: str, unit: u32, d: DefId) {
    lir_own(cem, name, unit);
    if cem.lir.is_some() {
        let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
        l.deref_mut().item_attrs_named(cem, name, d.module, d.node);
        cem.lir_put(l);
    }
}

fn lir_value(
    cem: &mut cbe::CEmit,
    cev: &mut iri::Interp,
    name: str,
    em: ModuleId,
    ty: TypeId,
    v: iri::IVal,
    ro: bool,
    tls: bool,
    al: u64,
) {
    if cem.lir.is_none() {
        return;
    }
    let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
    l.deref_mut().static_value(cem, cev, name, em, ty, v, ro, tls, al);
    cem.lir_put(l);
}

fn lir_elems(
    cem: &mut cbe::CEmit,
    cev: &mut iri::Interp,
    name: str,
    em: ModuleId,
    ty: TypeId,
    cm: ModuleId,
    els: NodeList,
    ro: bool,
    tls: bool,
    al: u64,
) {
    if cem.lir.is_none() {
        return;
    }
    let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
    l.deref_mut().static_elems(cem, cev, name, em, ty, cm, els, ro, tls, al);
    cem.lir_put(l);
}

fn lir_zero(cem: &mut cbe::CEmit, name: str, em: ModuleId, ty: TypeId, ro: bool, tls: bool, al: u64) {
    if cem.lir.is_none() {
        return;
    }
    let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
    l.deref_mut().static_zero(cem, name, em, ty, ro, tls, al);
    cem.lir_put(l);
}

fn lir_group(cem: &mut cbe::CEmit, cev: &iri::Interp, name: str, root: u32, ro: bool, tls: bool, al: u64) {
    if cem.lir.is_none() {
        return;
    }
    let mut l = replace(&mut cem.lir, Option::<Box<lw::Lower>>::None).unwrap();
    l.deref_mut().static_group(cem, cev, name, root, ro, tls, al);
    cem.lir_put(l);
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
        mg.ident(m, a.at_const(a.ext_name(gid)).as_data.name.text, &mut nm);
        out.push_string(&nm);
        out.push_str(", _SCM_");
        out.push_string(&nm);
        out.push_str(", ");
    }
    out.push_str("NAME) ");
}

// The definition of every `@simd_impl` entry the build's features hold, in table order: its body as
// a `static inline` always-inlined C function named `__sc_si_<symbol>` (`CEmit::entry_name`),
// rendered by a scratch emitter, so no spelling it does lands in a unit's records. The assembly gives
// each its definition header, written only when a unit calls it.
fn cemit_simd_entries(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    g: &mut ig::InstGraph,
    dow: &mut DropCtx,
    ext_keys: &Vector<u64>,
    names: &mut Vector<String>,
    defs: &mut Vector<String>,
    packs: &mut Vector<mbe::WrapReq>,
) u64 {
    if !cem.simd_on {
        return 0; // no unit calls an entry
    }
    let mut skips: u64 = 0;
    let mut sc = cbe::CEmit::new(p);
    // An entry is a `static inline` C function of a header: no native object defines it.
    sc.render_all = true;
    // An entry's own vector operations keep their lane loops: no entry calls another.
    sc.simd_on = false;
    // The planner spells an entry's call with the struct ABI.
    sc.no_split = true;
    // A constant an entry addresses queues its definition (merged into `cem` below).
    sc.collect_demand = true;
    sc.mg.agg_on = true;
    sc.mg.share_short(&mut cem.mg);
    for k in 0..ext_keys.len() {
        sc.ext_backed.insert(ext_keys[k]);
    }
    for e in 0..p.simd_table.len() {
        let en = *p.simd_table.at(e);
        if !cf::contains(cf::join(p.features, p.fn_union), en.fs) {
            continue;
        }
        // A unit (a replayed one too) may call any usable entry: one that does not render is a build
        // error.
        let mut lw = irl::Lowerer::new(p, en.module, en.node);
        let mut nm = String::from_str("__sc_si_");
        let tg = sc.mg.method_target(en.module, en.node);
        sc.out.clear();
        sc.fn_attrs.clear();
        sc.fn_attrs.push_str("static inline __attribute__((always_inline");
        let mut ta = String::new();
        cf::push_target_attr(cf::close(cf::join(p.features, en.fs)), p.features, p.build_target, &mut ta);
        if ta.len() != 0 {
            sc.fn_attrs.format_into(", {}", ta.as_str());
        }
        sc.fn_attrs.push_str(")) ");
        let mut ok = cemit_take_body(g, p, en.module, en.node, false, &mut lw, &mut dow.pr) && sc.mg.fn_sym(
            en.module,
            en.node,
            tg,
            &mut nm,
        );
        if ok {
            // The backend file emits no unit: its helpers (`reg`, `vec`) splice into the entry
            // whatever the inlining switch says, and a call left would name no definition.
            let off = dow.inl.off;
            dow.inl.off = false;
            dow.apply_drops(&mut lw);
            dow.inl.off = off;
            for k in 0..lw.body.blocks.len() {
                let t = lw.body.blocks.at(k).term;
                ok = ok && !(t.kind == irc::TM_CALL && t.callee.module == en.module);
            }
        }
        let r0 = sc.refused.len();
        // A native build has no object for a function only a C compile defines.
        let mut why = "the vector entry does not lower, or calls a function of its file that does not inline";
        if ok && sc.emit_fn(&lw.body, nm.as_str()) {
            if !sc.lir_take_pend_c() {
                names.push(nm);
                defs.push(sc.out.clone());
                continue;
            }
            why = "the vector entry calls a function no object defines (an intrinsic the native backend lacks)";
        }
        skips += 1;
        if sc.refused.len() == r0 {
            let fsp = p.modules[en.module as usize].ast.at_const(en.node).span;
            sc.refused.push(cbe::Refusal { m: en.module, start: fsp.start, end: fsp.end, why: why });
        }
    }
    cem.lir_absorb(&mut sc);
    for i in 0..sc.refused.len() {
        cem.refused.push(sc.refused[i]);
    }
    // The constants the entries address (a shuffle's index table): defined with every other one.
    for j in 0..sc.stat_items.len() {
        let k = fnv(sc.stat_items.at(j).sym.as_str()); // before the move below
        if cem.stat_seen.contains(&k) {
            continue;
        }
        cem.stat_seen.insert(k);
        let sr = replace(
            sc.stat_items.index_mut(j),
            cbe::StatRef {
                em: 0,
                def: DefId { module: 0, node: NODE_NONE },
                sym: String::new(),
                ty: TYPE_NONE,
                args: Vector::<mbe::MSub>::new(),
            },
        );
        cem.stat_items.push(sr);
        cem.stat_decls.push_str(
            sc.stat_decls.as_str().slice(cap_pe(&sc.stat_end, j as u32) as usize, sc.stat_end[j] as usize),
        );
        cem.stat_end.push(cem.stat_decls.len() as u32);
    }
    // The vector structs the definitions spell: each written when a written entry needs it.
    *packs = replace(&mut sc.mg.pack_reqs, Vector::<mbe::WrapReq>::new());
    return skips;
}

// Whether every function of an extern block (`items` of module `m`) needs CPU features (`lacking`:
// features the build lacks): its header is included where its functions are
// (`cemit_extern_includes`), and with `lacking` it may not compile (`<wasm_simd128.h>` without
// `-msimd128`) while no call can name its functions.
fn extern_block_gated(p: &loader::Package, m: ModuleId, items: NodeList, lacking: bool) bool {
    let a = &p.modules[m as usize].ast;
    let mut fns = false;
    for j in 0..items.len {
        let f = unsafe a.list(items)[j as usize];
        if a.at_const(f).kind == NodeKind::NODE_FUNCTION {
            let fs = p.fn_features(m, f);
            if cf::is_empty(fs) || lacking && cf::contains(p.features, fs) {
                return false;
            }
            fns = true;
        }
    }
    return fns;
}

// Whether a module other than the backend file imports module `m`.
const fn imported_beyond_backends(p: &loader::Package, m: ModuleId) bool {
    let ix = &p.idx;
    for x in 0..p.modules.len() {
        let mut imp = false;
        for e in ix.mod_imports[x]..ix.mod_imports[x + 1] {
            imp = imp || ix.imports[e as usize] == m;
        }
        if !imp {
            continue;
        }
        if !p.modules[x].backend {
            return true;
        }
    }
    return false;
}

// One scoped header of `extern "C" "<header>"` blocks (`cemit_extern_includes`): its include line
// seen from `__sc_t/`, the alias definitions of its blocks' items (`mbe::x_alias`), their tokens, the
// checks of its blocks' types and constants, and the headers it needs before it (`pre`).
struct XHdr {
    pub(package) line: String,
    pub(package) defs: String,
    pub(package) names: Vector<String>,
    pub(package) checks: String,
    pub(package) pre: Vector<u32>,
}

// `extern "C" "<header>"` blocks across the package: each unique header (module-relative realpath
// when it resolves, else the local/system spelling heuristic) into `hdrs`, and every fn the header
// prototypes, and every static it declares, into `backed` (call-site protos would conflict with the real
// declarations). A scoped
// header (`Package::extern_header_scoped`) reaches only the files that use one of its items
// (`cemit_assemble`), which the emitter spells by alias (`mbe::x_alias`): its macros would rename any
// other file's identifiers (`near` and `far` of <windows.h>). A header may need the headers of its
// module's earlier blocks (`<psapi.h>` after `<windows.h>`): it includes those that come before it
// in `hdrs`, which keeps every module's block order where the modules agree (a file includes
// `<ws2tcpip.h>` before the `<windows.h>` another module declares first, as Winsock requires).
// A header `super_rt.h` includes reaches every file already: it and its checks join `out`.
// A block whose functions all need CPU features joins `gated` instead (the entries' definition
// headers include it), and `out` only when a module beyond the backend files imports it: a program
// that uses no vector operation keeps its forward header.
fn cemit_extern_includes(
    p: &loader::Package,
    out: &mut String,
    gated: &mut String,
    backed: &mut Set<u64>,
    hdrs: &mut Vector<XHdr>,
) {
    let mut seen = Vector::<String>::new();
    // The checks of the headers in `out`, after every include: a field may name a type another
    // header defines.
    let mut checks = String::new();
    // The forward header sits at the tree's root, the definition headers in `__sc_t/`.
    let gen_real = loader::real_path_of(p.gen_root.as_str());
    let mut t_real = gen_real.clone();
    t_real.push_str("/__sc_t");
    let mut toks = Set::<u64>::new(); // the alias tokens defined so far: the first header owns one
    let mut mod_x = Vector::<u32>::new(); // the scoped headers of the module's blocks so far
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let src = p.modules[m].source.as_str();
        let its = a.at_const(a.root).as_data.program.items;
        mod_x.clear();
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            if a.at_const(nid).kind != NodeKind::NODE_EXTERN_BLOCK {
                continue;
            }
            let eb = a.at_const(nid).as_data.extern_block;
            if eb.header == NODE_NONE {
                continue;
            }
            // The header declares its statics: `stat_demand` declares only a header-less block's.
            for j in 0..eb.items.len {
                let sid = unsafe a.list(eb.items)[j as usize];
                if a.at_const(sid).kind == NodeKind::NODE_CONST && a.at_const(sid).as_data.const_def.is_extern {
                    backed.insert(skey_mix(0, m as u64 << 32 | sid as u64));
                }
            }
            if extern_block_gated(p, m as ModuleId, eb.items, true) {
                continue;
            }
            let gated_block = extern_block_gated(p, m as ModuleId, eb.items, false);
            let mut hchk = String::new();
            header_type_checks(p, m as ModuleId, eb.items, &mut hchk);
            let mut vchk = String::new();
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
            let mut gline = String::new(); // the same, from `__sc_t/`
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
                if let Ok(real) = fs::realpath(rel.as_str()) {
                    let abs = real.as_str();
                    line.format_into("#include \"{}\"\n", include_name(abs, gen_real.as_str()).as_str());
                    gline.format_into("#include \"{}\"\n", include_name(abs, t_real.as_str()).as_str());
                    done = true;
                }
            }
            if !done {
                let local = htxt.byte_at(0) == b'.' || htxt.byte_at(0) == b'/';
                line.push_str(mbe::if_s(local, "#include \"", "#include <"));
                line.push_str(htxt);
                line.push_str(mbe::if_s(local, "\"\n", ">\n"));
                gline.push_string(&line);
            }
            // Each register type's layout (`@value`) is the header's: the C compiler checks it. The
            // alignment is a lower bound: GCC aligns `__m256` to 16 bytes without AVX, to 32 with it.
            // A C value's layout (`@layout`) is exact.
            for j in 0..eb.items.len {
                let tid = unsafe a.list(eb.items)[j as usize];
                if a.attr_of(tid, AttrKind::ATTR_LAYOUT) != null {
                    let lv = a.attr_value(tid, AttrKind::ATTR_LAYOUT);
                    assert(lv.ok, "the checker folds every '@layout'");
                    let tn = a.at_const(a.at_const(tid).as_data.type_alias.name).as_data.name.text;
                    let mut nm = String::new();
                    extern_c_raw(p, m as ModuleId, tid, &mut nm);
                    let chk = format(
                        "_Static_assert(sizeof({}) == {}u && _Alignof({}) == {}u, \"super-c: '{}' must have {} bytes aligned to {} in C\");\n",
                        nm.as_str(),
                        lv.v,
                        nm.as_str(),
                        lv.w[0],
                        src.slice(tn.start as usize, tn.end as usize),
                        lv.v,
                        lv.w[0],
                    );
                    hchk.push_string(&chk);
                    continue;
                }
                if a.attr_of(tid, AttrKind::ATTR_C_VALUE) == null {
                    continue;
                }
                let av = a.attr_value(tid, AttrKind::ATTR_C_VALUE);
                if av.ok {
                    let tn = a.at_const(a.at_const(tid).as_data.type_alias.name).as_data.name.text;
                    let nm = src.slice(tn.start as usize, tn.end as usize);
                    let chk = format(
                        "_Static_assert(sizeof({}) == {} && _Alignof({}) >= {}, \"@value of {}\");\n",
                        nm,
                        av.v,
                        nm,
                        av.w[0],
                        nm,
                    );
                    vchk.push_string(&chk);
                }
            }
            if !gated_block && !p.extern_header_scoped(m as ModuleId, nid) {
                checks.push_string(&vchk);
                checks.push_string(&hchk);
                let mut dup = false;
                for k in 0..seen.len() {
                    dup = dup || seen.at(k).as_str() == line.as_str();
                }
                if !dup {
                    out.push_string(&line);
                    seen.push(line);
                }
                continue;
            }
            if !gated_block {
                let mut x = hdrs.len();
                for k in 0..hdrs.len() {
                    if hdrs[k].line.as_str() == gline.as_str() {
                        x = k;
                        break;
                    }
                }
                if x == hdrs.len() {
                    hdrs.push(
                        XHdr {
                            line: gline,
                            defs: String::new(),
                            names: Vector::<String>::new(),
                            checks: String::new(),
                            pre: Vector::<u32>::new(),
                        },
                    );
                }
                let h = hdrs.index_mut(x);
                // First-seen indices; the order below keeps the earlier ones.
                for k in 0..mod_x.len() {
                    if mod_x[k] as usize != x && !h.pre.contains(&mod_x[k]) {
                        h.pre.push(mod_x[k]);
                    }
                }
                if !mod_x.contains(&(x as u32)) {
                    mod_x.push(x as u32);
                }
                h.checks.push_string(&vchk);
                h.checks.push_string(&hchk);
                extern_block_aliases(p, m as ModuleId, eb.items, &mut toks, &mut h.names, &mut h.defs);
                continue;
            }
            line.push_string(&vchk);
            gline.push_string(&vchk);
            line.push_string(&hchk);
            gline.push_string(&hchk);
            let mut dup = false;
            for k in 0..seen.len() {
                if seen.at(k).as_str() == line.as_str() {
                    dup = true;
                    break;
                }
            }
            if !dup {
                gated.push_string(&gline);
                if imported_beyond_backends(p, m as ModuleId) {
                    out.push_string(&line);
                }
                seen.push(line);
            }
        }
    }
    out.push_string(&checks);
    // Each step places the first seen header whose `pre` are all placed, or on a cycle (two
    // modules order two headers apart) the first seen header left.
    let nh = hdrs.len();
    let mut rank = Vector::<u32>::new(); // first-seen index -> place, `nh` while unplaced
    let mut at = Vector::<u32>::new(); // place -> first-seen index
    for _i in 0..nh {
        rank.push(nh as u32);
    }
    for _t in 0..nh {
        let mut c = nh;
        let mut f = nh;
        for i in 0..nh {
            if rank[i] as usize != nh {
                continue;
            }
            f = pick(f == nh, i, f);
            let mut ready = true;
            for k in 0..hdrs[i].pre.len() {
                ready = ready && rank[hdrs[i].pre[k] as usize] as usize != nh;
            }
            if ready {
                c = i;
                break;
            }
        }
        c = pick(c == nh, f, c);
        rank.set(c, at.len() as u32);
        at.push(c as u32);
    }
    // Move each header to its place (`slot`: first-seen index -> current position, `cur` the
    // inverse), then keep the `pre` placed before it, as places.
    let mut slot = Vector::<u32>::new();
    let mut cur = Vector::<u32>::new();
    for i in 0..nh {
        slot.push(i as u32);
        cur.push(i as u32);
    }
    for t in 0..nh {
        let o = at[t];
        let s = slot[o as usize];
        hdrs.swap(t, s as usize);
        let ot = cur[t];
        cur.set(s as usize, ot);
        slot.set(ot as usize, s);
        cur.set(t, o);
        slot.set(o as usize, t as u32);
    }
    for t in 0..nh {
        let h = hdrs.index_mut(t);
        let mut j: usize = 0;
        for k in 0..h.pre.len() {
            let r = rank[h.pre[k] as usize];
            if r as usize < t {
                h.pre.set(j, r);
                j += 1;
            }
        }
        h.pre.truncate(j);
    }
}

// The alias tokens (`mbe::x_token`) of the items of extern block `items` of module `m` that C spells
// by name into `names`, and their definitions (`#define <token> <C name>`) into `defs`: its
// functions, statics and types as the emitter spells them, and its enumerators. A token another
// header defines already (`toks`) stays that header's.
fn extern_block_aliases(
    p: &loader::Package,
    m: ModuleId,
    items: NodeList,
    toks: &mut Set<u64>,
    names: &mut Vector<String>,
    defs: &mut String,
) {
    let a = &p.modules[m as usize].ast;
    let src = p.modules[m as usize].source.as_str();
    let mut c = String::new();
    for j in 0..items.len {
        let id = unsafe a.list(items)[j as usize];
        let k = a.at_const(id).kind;
        c.clear();
        if k == NodeKind::NODE_FUNCTION || k == NodeKind::NODE_CONST && a.at_const(id).as_data.const_def.is_extern && !a.at_const(
            id,
        ).as_data.const_def.c_macro {
            // `Mangler::fn_sym` and `Mangler::const_sym`: the pin, else the name.
            let mut pin = a.attr_of(id, AttrKind::ATTR_IMPORT);
            if pin == null {
                pin = a.attr_of(id, AttrKind::ATTR_EXPORT);
            }
            if pin != null {
                c.push_str(src.slice((unsafe (*pin).str_span.start) as usize, (unsafe (*pin).str_span.end) as usize));
            } else {
                let nm = if k == NodeKind::NODE_FUNCTION {
                    a.ext_name(id);
                } else {
                    a.at_const(id).as_data.const_def.name;
                };
                let ns = a.at_const(nm).as_data.name.text;
                let txt = src.slice(ns.start as usize, ns.end as usize);
                c.push_str(txt);
                if mbe::c_keyword(txt) {
                    c.push_str("_");
                }
            }
        } else if k == NodeKind::NODE_STRUCT || k == NodeKind::NODE_ENUM || k == NodeKind::NODE_TYPE_ALIAS {
            extern_c_raw(p, m, id, &mut c);
        } else {
            continue;
        }
        x_define(c.as_str(), toks, names, defs);
        if k == NodeKind::NODE_ENUM {
            // `Mangler::enum_tag`: the variant's own name.
            let ms = a.ext(id).aggregate.members;
            for v in 0..ms.len {
                let vid = unsafe a.list(ms)[v as usize];
                let vs = a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text;
                x_define(src.slice(vs.start as usize, vs.end as usize), toks, names, defs);
            }
        }
    }
}

// Define the alias of C name `c` (`extern_block_aliases`) unless a header defines it already.
fn x_define(c: str, toks: &mut Set<u64>, names: &mut Vector<String>, defs: &mut String) {
    let mut t = String::new();
    mbe::x_token(c, &mut t);
    let h = fnv(t.as_str());
    if !toks.contains(&h) {
        toks.insert(h);
        defs.format_into("#define {} {}\n", t.as_str(), c);
        names.push(t);
    }
}

// The C spelling of extern type `decl` of module `m`, as `Mangler::ctype` writes it: the alias of a
// scoped header's type (`mbe::x_alias`), else `extern_c_raw`.
fn extern_c_name(p: &loader::Package, m: ModuleId, decl: NodeId, out: &mut String) {
    let st = out.len();
    extern_c_raw(p, m, decl, out);
    mbe::x_alias(p, DefId { module: m, node: decl }, out, st);
}

// The C name of extern type `decl` of module `m`: the `@import` pin, else the name, after `struct `,
// `union ` or `enum ` for a header type.
fn extern_c_raw(p: &loader::Package, m: ModuleId, decl: NodeId, out: &mut String) {
    let a = &p.modules[m as usize].ast;
    let src = p.modules[m as usize].source.as_str();
    let at = a.attr_of(decl, AttrKind::ATTR_IMPORT);
    if at != null {
        out.push_str(src.slice((unsafe (*at).str_span.start) as usize, (unsafe (*at).str_span.end) as usize));
        return;
    }
    let dn = a.at_const(decl);
    let nm = if dn.kind == NodeKind::NODE_TYPE_ALIAS {
        dn.as_data.type_alias.name;
    } else {
        a.ext_name(decl);
    };
    if dn.kind == NodeKind::NODE_STRUCT {
        out.push_str(mbe::if_s(a.ext(decl).aggregate.is_union, "union ", "struct "));
    } else if dn.kind == NodeKind::NODE_ENUM {
        out.push_str("enum ");
    }
    let ns = a.at_const(nm).as_data.name.text;
    let txt = src.slice(ns.start as usize, ns.end as usize);
    out.push_str(txt);
    if mbe::c_keyword(txt) {
        out.push_str("_");
    }
}

// The C condition (`cond`) that member expression `e0` has the type `t0` (pool of module `m`) a
// header type declares for it, and its description for the message (`desc`): an integer by
// signedness (`_Generic` over the standard integer types) and size, `_Bool`, `float`, `double`, a
// complex type, a pointer (no arithmetic type, the size of a pointer), an extern type by exact type,
// an array by its length at each level and then its element.
fn header_field_check(p: &loader::Package, m: ModuleId, t0: TypeId, e0: str, cond: &mut String, desc: &mut String) {
    let a = &p.modules[m as usize].ast;
    let mut t = t0;
    let mut e = String::from_str(e0);
    for _ in 0..64 {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            let n = y.as_data.arr.len as u64;
            // A length of 0 declares C's flexible array member (`char d_name[];`), whose type is
            // incomplete: `sizeof` rejects it, so only its element is checked.
            if n == 0 {
                desc.push_str("a flexible array, each element ");
            } else {
                cond.format_into("sizeof({}) == {} * sizeof(({})[0]) && ", e.as_str(), n, e.as_str());
                desc.format_into("an array of {} elements, each ", n);
            }
            e = format("({})[0]", e.as_str());
            t = y.as_data.arr.elem;
            continue;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION {
            cond.format_into(
                "sizeof({}) == sizeof(void *) && _Generic({}, _Bool: 0, char: 0, signed char: 0, unsigned char: 0, short: 0, unsigned short: 0, int: 0, unsigned int: 0, long: 0, unsigned long: 0, long long: 0, unsigned long long: 0, float: 0, double: 0, long double: 0, default: 1)",
                e.as_str(),
                e.as_str(),
            );
            desc.push_str("a pointer");
            return;
        }
        if y.kind == TypeKind::TYPE_OPAQUE || y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            // The condition names another header's type by alias, so the file includes that header;
            // the message by its C name.
            let mut nm = String::new();
            extern_c_name(p, y.module, y.as_data.decl, &mut nm);
            cond.format_into("_Generic({}, {}: 1, default: 0)", e.as_str(), nm.as_str());
            desc.push_str("a '");
            extern_c_raw(p, y.module, y.as_data.decl, desc);
            desc.push_str("'");
            return;
        }
        assert(y.kind == TypeKind::TYPE_BUILTIN, "the checker admits only C field types in a header type");
        let b = y.as_data.builtin;
        let signed = b == BuiltinType::BT_I8 || b == BuiltinType::BT_I16 || b == BuiltinType::BT_I32 || b == BuiltinType::BT_I64 || b == BuiltinType::BT_ISIZE;
        let unsigned = b == BuiltinType::BT_U8 || b == BuiltinType::BT_U16 || b == BuiltinType::BT_U32 || b == BuiltinType::BT_U64 || b == BuiltinType::BT_USIZE;
        if signed || unsigned {
            let w = if b == BuiltinType::BT_I8 || b == BuiltinType::BT_U8 {
                "1";
            } else if b == BuiltinType::BT_I16 || b == BuiltinType::BT_U16 {
                "2";
            } else if b == BuiltinType::BT_I32 || b == BuiltinType::BT_U32 {
                "4";
            } else if b == BuiltinType::BT_I64 || b == BuiltinType::BT_U64 {
                "8";
            } else {
                "sizeof(void *)";
            };
            cond.format_into(
                "sizeof({}) == {} && _Generic({}, {}, default: 0)",
                e.as_str(),
                w,
                e.as_str(),
                mbe::if_s(
                    signed,
                    "signed char: 1, short: 1, int: 1, long: 1, long long: 1",
                    "char: 1, unsigned char: 1, unsigned short: 1, unsigned int: 1, unsigned long: 1, unsigned long long: 1",
                ),
            );
            desc.push_str(mbe::if_s(signed, "a signed integer of ", "an unsigned integer of "));
            desc.push_str(
                if w.len() != 1 {
                    "pointer size";
                } else if w == "1" {
                    "1 byte";
                } else {
                    w;
                },
            );
            if w.len() == 1 && w != "1" {
                desc.push_str(" bytes");
            }
            return;
        }
        let c = if b == BuiltinType::BT_BOOL {
            "_Bool";
        } else if b == BuiltinType::BT_CHAR {
            "char: 1, signed char: 1, unsigned char";
        } else if b == BuiltinType::BT_F32 {
            "float";
        } else if b == BuiltinType::BT_F64 {
            "double";
        } else if b == BuiltinType::BT_C32 {
            "float _Complex";
        } else {
            assert(b == BuiltinType::BT_C64, "the checker admits only C field types in a header type");
            "double _Complex";
        };
        cond.format_into("_Generic({}, {}: 1, default: 0)", e.as_str(), c);
        desc.push_str(
            if b == BuiltinType::BT_CHAR {
                "a char";
            } else {
                c;
            },
        );
        return;
    }
    assert(false, "a header type's field nests arrays at most 64 levels deep");
}

// The check of constant `cid` of an extern block of module `m` (`c_macro`): its C name, the `@import`
// pin or its own, has the constant's value in C.
fn header_const_check(p: &loader::Package, m: ModuleId, cid: NodeId, out: &mut String) {
    let a = &p.modules[m as usize].ast;
    let src = p.modules[m as usize].source.as_str();
    let ns = a.at_const(a.at_const(cid).as_data.const_def.name).as_data.name.text;
    let name = src.slice(ns.start as usize, ns.end as usize);
    let pin = a.attr_of(cid, AttrKind::ATTR_IMPORT);
    let cname = if pin != null {
        src.slice((unsafe (*pin).str_span.start) as usize, (unsafe (*pin).str_span.end) as usize);
    } else {
        name;
    };
    let v = unsafe (*(p.cir as *mut iri::Interp)).eval_const_in(m, cid);
    assert(v.kind == iri::IV_INT || v.kind == iri::IV_BOOL, "the checker folds every constant of an extern block");
    let mut lit = String::new();
    if v.kind == iri::IV_BOOL {
        lit.push_i64(v.i);
    } else if v.i < 0 && !bt_is_unsigned(unsafe (*p.module_ast_const(v.tm)).type_at(v.ty).as_data.builtin) {
        // `-9223372036854775808LL` negates a literal too wide for `long long`.
        if v.i as u64 == 0x8000000000000000u64 {
            lit.push_str("(-9223372036854775807LL - 1)");
        } else {
            lit.format_into("({}LL)", v.i);
        }
    } else {
        lit.format_into("{}ULL", v.i as u64);
    }
    let mut shown = String::new();
    if v.kind != iri::IV_BOOL && lit.as_str().ends_with("ULL") {
        shown.push_u64(v.i as u64);
    } else {
        shown.push_i64(v.i);
    }
    out.format_into(
        "_Static_assert(({}) == {}, \"super-c: constant '{}' must be {} in C\");\n",
        cname,
        lit.as_str(),
        name,
        shown.as_str(),
    );
}

// The layout checks of the header types (`struct`, `union`, `enum`) of extern block `items` of module
// `m`. The type is complete: a wrong spelling (a typedef'd type declared without its `@import`)
// stops here, at its first use in the unit. The declaration lists every member, so the layout
// Super-C computes from it is the header's: the size, the alignment and each field's offset must
// match, and each declared field matches its C member (`header_field_check`), spelled as every
// access spells it. A wrong declaration fails the C compile with a message that names it, in every
// unit, once: the checks go into the forward header.
fn header_type_checks(p: &loader::Package, m: ModuleId, items: NodeList, out: &mut String) {
    let a = &p.modules[m as usize].ast;
    let src = p.modules[m as usize].source.as_str();
    let mut svc = lay::Svc::new(p);
    for j in 0..items.len {
        let sid = unsafe a.list(items)[j as usize];
        let sk = a.at_const(sid).kind;
        if sk == NodeKind::NODE_CONST && a.at_const(sid).as_data.const_def.c_macro {
            header_const_check(p, m, sid, out);
            continue;
        }
        if sk != NodeKind::NODE_STRUCT && sk != NodeKind::NODE_ENUM {
            continue;
        }
        let agg = a.ext(sid).aggregate;
        let ns = a.at_const(agg.name).as_data.name.text;
        let sname = src.slice(ns.start as usize, ns.end as usize);
        let mut ct = String::new();
        extern_c_raw(p, m, sid, &mut ct);
        out.format_into(
            "_Static_assert(sizeof({}) != 0, \"super-c: '{}' must be a complete C type\");\n",
            ct.as_str(),
            sname,
        );
        if sk == NodeKind::NODE_ENUM {
            // Its constants are the header's own names, of the values Super-C gives them.
            let it = p.cir as *mut iri::Interp;
            let mut cur: i64 = -1;
            for k in 0..agg.members.len {
                let vid = unsafe a.list(agg.members)[k as usize];
                let ok = unsafe (*it).discr(m, vid, cur, &mut cur);
                assert(ok, "the checker folds every enumerator of an extern block");
                let mut cn = String::new();
                let vs = a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text;
                cn.push_str(src.slice(vs.start as usize, vs.end as usize));
                mbe::x_alias(p, DefId { module: m, node: sid }, &mut cn, 0);
                out.format_into(
                    "_Static_assert(({}) == {}, \"super-c: '{}::{}' must be {} in C: declare every enumerator of the header's type, in its order\");\n",
                    cn.as_str(),
                    cur,
                    sname,
                    src.slice(vs.start as usize, vs.end as usize),
                    cur,
                );
            }
            continue;
        }
        let l = svc.decl_layout(m, sid);
        assert(l.ok, "the checker lays out every header struct and union");
        out.format_into(
            "_Static_assert(sizeof({}) == {}u && _Alignof({}) == {}u, \"super-c: '{}' must have {} bytes aligned to {} in C: declare every member of the header's type, in its order\");\n",
            ct.as_str(),
            l.size,
            ct.as_str(),
            l.align,
            sname,
            l.size,
            l.align,
        );
        for k in 0..agg.members.len {
            let fid = unsafe a.list(agg.members)[k as usize];
            if a.at_const(fid).kind != NodeKind::NODE_FIELD {
                continue;
            }
            let fs = a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text;
            let fname = src.slice(fs.start as usize, fs.end as usize);
            // The member as every access spells it (`Mangler::field_ident`).
            let mut cf = String::new();
            let pin = a.attr_of(fid, AttrKind::ATTR_IMPORT);
            if pin != null {
                cf.push_str(src.slice((unsafe (*pin).str_span.start) as usize, (unsafe (*pin).str_span.end) as usize));
            } else {
                cf.push_str(fname);
                if mbe::escaped_stem(fname, |w: str| mbe::c_keyword(w) || mbe::c_std_macro(w)) {
                    cf.push_str("_");
                }
            }
            let e = format("(({} *)0)->{}", ct.as_str(), cf.as_str());
            let mut cond = String::new();
            let mut desc = String::new();
            header_field_check(p, m, a.member_ty(fid), e.as_str(), &mut cond, &mut desc);
            out.format_into(
                "_Static_assert({}, \"super-c: field '{}.{}' must be {} in C\");\n",
                cond.as_str(),
                sname,
                fname,
                desc.as_str(),
            );
            let off = svc.decl_field_offset(m, sid, fid);
            assert(off >= 0, "a laid-out header struct has every field's offset");
            out.format_into(
                "_Static_assert(offsetof({}, {}) == {}u, \"super-c: field '{}.{}' must sit at byte {} in C: declare every member of the header's type, in its order\");\n",
                ct.as_str(),
                cf.as_str(),
                off,
                sname,
                fname,
                off,
            );
        }
    }
}

// Per-body emission preparation for a lane body: drop elaboration for the bodies emission lowers
// itself (the borrow pass elaborated every kept body already), the inliner, then bounds-check
// elimination. The elaboration analyses, pooled: one instance rebuilds in place per body (capacity
// kept), mirroring flow_ir's BorrowCtx; fresh builds per body dominated the allocator cost.
// Emission-phase pool of DropCtx instances: a task checks one out and returns it, so the
// inliner's type-translation caches warm once per pooled slot (about the worker count) instead of
// once per task. Valid within one emission phase: every cached decision is a pure function of the
// frozen package and its inline store. `cemit_package` resets it.
/// A program whose module, instance and registry units hold at most this many bytes of C compiles them
/// as one unit (`__sc_unity.c`).
const UNITY_MAX: usize = 2 << 20;

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
fn dctx_drop(acc: &mut prb::Probe) {
    unsafe sc_runtime::sc_rt_spin_lock(&mut G_DPOOL_LOCK);
    if unsafe G_DPOOL != null {
        let pv = unsafe G_DPOOL;
        unsafe G_DPOOL = null;
        for i in 0..(unsafe &*pv).len() {
            let d9 = (unsafe &mut *pv).index_mut(i);
            acc.merge(&d9.pr);
            if unsafe TS_ON {
                ts_add(TS_XM_BYTES, d9.inl.xm_bytes());
            }
        }
        unsafe (*pv).free();
        let mut g9 = Global {};
        unsafe g9.dealloc(pv, sizeof(Vector<DropCtx>), alignof(Vector<DropCtx>));
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut G_DPOOL_LOCK);
}

struct DropCtx {
    pub(package) ow: bfx::Owner,
    pub(package) forest: bmp::MoveForest,
    pub(package) facts: bfx::BodyFacts,
    pub(package) cfg: bdf::Cfg,
    pub(package) mv: bdf::MoveFlow,
    pub(package) el: ird::ElabCtx,
    pub(package) inl: inl::InlineCtx,
    pub(package) bce: bce::Bce,
    pub(package) core_ir: bool, // SC_CORE_IR development re-verification
    pub(package) bce_stats: bool, // SC_BCE_STATS per-owner report lines
    pub(package) validate: bool, // SC_BC_VALIDATE: every body elaborated here is verified like a kept one
    /// Emission counters (SC_CEMIT_STATS): acquisition, re-lowering, inlining, drop preparation.
    pub(package) pr: prb::Probe,
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
            inl: inl::InlineCtx::new((unsafe (&*p).inl_store) as *const inl::InlineStore),
            bce: bce::Bce::new(),
            core_ir: stdlib::getenv("SC_CORE_IR") != null,
            bce_stats: stdlib::getenv("SC_BCE_STATS") != null,
            validate: stdlib::getenv("SC_BC_VALIDATE") != null,
            pr: prb::Probe::new(stdlib::getenv("SC_CEMIT_STATS") != null, stdlib::getenv("SC_BUILD_MEM") != null),
        };
    }

    // The calls inlined.
    fn apply_drops(self: &mut Self, lw: &mut irl::Lowerer) u32 {
        return self.apply_drops_of(lw, true);
    }

    // The calls inlined.
    fn apply_drops_of(self: &mut Self, lw: &mut irl::Lowerer, allow_inline: bool) u32 {
        let dm = self.pr.start();
        let i0 = self.pr.ns[prb::P_INLINE];
        let ia0 = self.pr.an[prb::P_INLINE];
        let ib0 = self.pr.ab[prb::P_INLINE];
        let n = self.apply_drops_i(lw, allow_inline);
        self.pr.stop_less(prb::P_DROPS, dm, prb::P_INLINE, i0, ia0, ib0);
        return n;
    }

    fn apply_drops_i(self: &mut Self, lw: &mut irl::Lowerer, allow_inline: bool) u32 {
        // A body emission lowered itself (a per-instance re-lowering, a wrapper) elaborates its
        // drops here, BEFORE the inliner: every callee splices in elaborated, so the merged body
        // is never analyzed for ownership. A kept body arrives elaborated by the borrow pass.
        if !lw.body.elaborated {
            lw.body.elaborated = true;
            // A body that can schedule no drop skips the move facts and the elaboration outright.
            if ird::may_schedule(&mut self.ow, &lw.body) {
                self.forest.build_into(&lw.body);
                // Drop elaboration reads the move facts only: no loan discovery here.
                self.ow.generate_into(&lw.body, &self.forest, &mut self.facts, false);
                self.cfg.build_into(&lw.body);
                self.mv.build_into(&lw.body, &self.forest, &self.facts, &self.cfg);
                ird::elaborate_into(&mut self.ow, &lw.body, &self.forest, &self.facts, &self.mv, &mut self.el);
                ird::insert_drops(&mut lw.body, &mut self.el, &self.forest);
            }
            // Its calls to itself become jumps, as the borrow pass converts a kept body's; the borrow
            // pass reported the ones that cannot.
            let mut misses = Vector::<irt::TailMiss>::new();
            let _ = irt::convert(&mut lw.body, &mut self.ow, &mut misses);
            if self.validate {
                bfi::bc_validate_elaborated(&mut self.ow, &lw.body);
            }
        }
        let mut ist = inl::InlineStats::new();
        if allow_inline && !self.inl.off {
            let im = self.pr.start();
            inl::run(lw, &mut self.inl, &mut ist);
            if self.inl.stats_on && ist.considered != 0 {
                let mut iline = String::new();
                inl::stats_line(&ist, &mut iline);
                eprint("{} owner {}:{}\n", iline.as_str(), lw.body.module, lw.body.owner.node);
            }
            if ist.inlined != 0 && self.core_ir {
                let tp9 = unsafe (&*(&*lw.pkg).module_ast_const(lw.body.module)).type_bound();
                let iv9 = irv::verify(&lw.body, tp9, lw.pkg);
                if iv9.len() != 0 {
                    eprintln("SC_CORE_IR: inline verify: {}", iv9);
                }
            }
            self.pr.stop(prb::P_INLINE, im);
        }
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
        return ist.inlined;
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
    out_n: &mut Vector<NodeId>,
) bool {
    let tgt = cem.mg.method_target(m, fnid);
    if tgt.node == NODE_NONE || tgt.module != m {
        return false;
    }
    let a = unsafe &*p.module_ast_const(m);
    let f = a.ext(fnid).function;
    if f.body == NODE_NONE || f.params.len == 0 {
        return false;
    }
    let src = p.modules[m as usize].source.as_str();
    let nsp = a.at_const(f.name).as_data.name.text;
    if src.slice(nsp.start as usize, nsp.end as usize) != "free" {
        return false;
    }
    let tn = a.at_const(tgt.node);
    if tn.kind != NodeKind::NODE_STRUCT || a.ext(tgt.node).aggregate.is_union || a.ext(tgt.node).aggregate.generics.len != 0 {
        return false;
    }
    let is_tuple = a.ext(tgt.node).aggregate.is_tuple;
    let ms = a.ext(tgt.node).aggregate.members;
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
        if !cem.is_destructible(m, ft) {
            continue;
        }
        if !a.free_touches(fnid, fid) {
            let mut fname = String::new();
            if is_tuple {
                fname.push_str("_");
                fname.push_u64(i);
            } else {
                cem.mg.ident(m, a.at_const(fnode.as_data.field.name).as_data.name.text, &mut fname);
            }
            out_f.push(fname);
            out_t.push(ft);
            out_n.push(fid);
        }
    }
    return out_f.len() != 0;
}

// The two shared-header includes, spelled relative to a module's nested output location
// (one `../` per `::` segment; quote includes resolve against the including file).
// Assembly: the forward header, one type header per by-value SCC, one prototype header per
// module, the chunk table with each chunk's shard, the shard heads and include lists of every
// module TU and instance shard, and the registry TU (see references/output-layout.md).
fn cemit_assemble(
    p: &mut loader::Package,
    cem: &mut cbe::CEmit,
    em: &mut tbe::TuEmit,
    acc: &mut SeedAcc,
    ext_incs: &String,
    gated_incs: &String,
    xhdrs: &Vector<XHdr>,
    si_names: &Vector<String>,
    si_defs: &Vector<String>,
    si_packs: &mut Vector<mbe::WrapReq>,
    macros_out: &String,
    cdefs: &Segs,
    sdefs: &Segs,
    tdecl: &Segs,
    reg_names: &Vector<String>,
    reg_decls: &Vector<String>,
    vis9: str,
    testing: bool,
    o: &mut CemitOut,
) {
    let n = p.modules.len();
    // The previous build's shard counts: the size policy keeps them while they fit.
    let mut prev_tus = Vector::<u32>::new();
    let mut prev_insts = Vector::<u32>::new();
    shard_meta_read(p.gen_root.as_str(), p, &mut prev_tus, &mut prev_insts);
    let ps = acc.protos.as_str();
    let mut poff = Vector::<u64>::new();
    {
        let mut c0: usize = 0;
        for _i in 0..acc.ch.chunk_mod.len() {
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
    o.skips += em.refused;
    // Definition headers: one per aggregate, closure environment and payload-less enum, em's
    // chunks in their global by-value order, then the environment structs the declaration pass
    // did not define. A payload-less enum is also a declaration other headers copy (prototypes
    // take it by value).
    let mut ds = DefSet::new();
    let mut fd = FwdDecls::new();
    // The scoped extern headers (`cemit_extern_includes`) first: definition header `i` holds the
    // headers it needs before it, header `i`'s include, its aliases and its checks, and a file
    // includes it when its text spells one of the aliases.
    let nx = xhdrs.len() as u32;
    for i in 0..xhdrs.len() {
        let mut nm = String::from_str("__scx");
        let mut w: usize = 1000;
        while w > 1 && i < w {
            nm.push_str("0");
            w /= 10;
        }
        nm.push_u64(i as u64);
        let mut body = xhdrs[i].defs.clone();
        body.push_string(&xhdrs[i].checks);
        let d = ds.add(nm.as_str(), body.as_str(), p.core_module);
        assert(d == i as u32, "the extern headers are the first definition headers");
        for k in 0..xhdrs[i].names.len() {
            fd.add_header(xhdrs[i].names[k].as_str(), d);
        }
    }
    // Array wrapper structs (`Mangler::ptr_wraps`): each is defined in the definition header of
    // its innermost element, after the element, and its typedef line leads that header's body
    // (the element's own members may point at it). Ordered by element, then name: the order the
    // requests merged in never shows.
    let mut ws = Vector::<mbe::WrapReq>::new();
    {
        let mut seen = Set::<u64>::new();
        wrap_collect(&mut em.mg.wrap_reqs, &mut seen, &mut ws);
        wrap_collect(&mut cem.mg.wrap_reqs, &mut seen, &mut ws);
    }
    ws.sort_by(wrap_req_cmp);
    let mut wfirst = Map::<u64, u32>::new(); // element name key -> its first wrapper in `ws`
    for j in 0..ws.len() {
        let k = nkey(fnv(ws[j].elem.as_str()));
        if !wfirst.contains_key(&k) {
            wfirst.insert(k, j as u32);
        }
    }
    let mut wplaced = Vector::<bool>::new();
    wplaced.resize_default(ws.len());
    let nck = em.chunk_off.len();
    for i in 0..nck {
        let a = em.chunk_off[i] as usize;
        let b = if i + 1 < nck {
            em.chunk_off[i + 1] as usize;
        } else {
            em.out.len();
        };
        let body = em.out.as_str().slice(a, b);
        let nm = em.chunk_name.as_str().slice(
            cap_pe(&em.chunk_name_end, i as u32) as usize,
            em.chunk_name_end[i] as usize,
        );
        let w0 = switch wfirst.get(&nkey(fnv(nm))) {
            Some(v) => (*v) as usize,
            None => ws.len(),
        };
        let mut w1 = w0;
        while w1 < ws.len() && ws[w1].elem.as_str() == nm {
            w1 += 1;
        }
        let d = if w0 == w1 {
            ds.add(nm, body, em.chunk_own[i]);
        } else {
            let mut wt = String::new();
            for j in w0..w1 {
                wrap_typedef(struct_def_name(ws[j].body.as_str()), &mut wt);
            }
            wt.push_str(body);
            for j in w0..w1 {
                wt.push_string(&ws[j].body);
            }
            ds.add(nm, wt.as_str(), em.chunk_own[i]);
        };
        for j in w0..w1 {
            let mut line = String::new();
            let wn = struct_def_name(ws[j].body.as_str());
            wrap_typedef(wn, &mut line);
            fd.add(wn, line.as_str(), d);
            wplaced.set(j, true);
        }
        if em.chunk_enum[i] {
            fd.add(nm, body, d);
        }
        if nm == "str" {
            ds.body.txt.push_str(
                "static inline bool __sc_str_eq(str a, str b) { return a.len == b.len && (a.len == 0 || memcmp(a.ptr, b.ptr, a.len) == 0); }\n",
            );
            ds.body.end.set(d as usize, ds.body.txt.len() as u32);
        }
    }
    for bi in 0..acc.env_bodies.len() {
        if !em.env_done(*acc.env_names.at(bi)) {
            em.mark_env_done(*acc.env_names.at(bi));
            let body = acc.env_bodies.at(bi).as_str();
            let _ = ds.add(struct_def_name(body), body, acc.env_own[bi]);
        }
    }
    // A wrapper whose element has no definition here is only ever named through pointers.
    for j in 0..ws.len() {
        if !wplaced[j] {
            let mut line = String::new();
            let wn = struct_def_name(ws[j].body.as_str());
            wrap_typedef(wn, &mut line);
            fd.add(wn, line.as_str(), ANY_HOME);
        }
    }
    // Result packs (`Mangler::ret_pack`): each in its own definition header, by name; any other
    // file that spells one gets its typedef line.
    let mut lp0 = 0xFFFFFFFFFFFFFFFFu64 as usize;
    {
        let mut pks = Vector::<mbe::WrapReq>::new();
        let mut seen = Set::<u64>::new();
        wrap_collect(&mut em.mg.pack_reqs, &mut seen, &mut pks);
        wrap_collect(&mut cem.mg.pack_reqs, &mut seen, &mut pks);
        pks.sort_by(wrap_req_cmp);
        // The packs only the entries' definitions spell follow: written only when one is used.
        let np = pks.len();
        let mut spk = Vector::<mbe::WrapReq>::new();
        wrap_collect(si_packs, &mut seen, &mut spk);
        spk.sort_by(wrap_req_cmp);
        for j in 0..spk.len() {
            pks.push(replace(spk.index_mut(j), mbe::WrapReq { h: 0, elem: String::new(), body: String::new() }));
        }
        for j in 0..pks.len() {
            let d = ds.add(pks[j].elem.as_str(), pks[j].body.as_str(), p.core_module);
            if j == np {
                lp0 = d as usize;
            }
            let mut line = String::new();
            wrap_typedef(pks[j].elem.as_str(), &mut line);
            fd.add(pks[j].elem.as_str(), line.as_str(), d);
        }
    }
    // The `@simd_impl` entries' definitions (`cemit_simd_entries`), each after the headers of the
    // feature-gated extern blocks: a unit that calls one includes its header, and the header of an
    // entry no unit calls is not written.
    let si0 = ds.key.len();
    for i in 0..si_names.len() {
        let def = si_defs.at(i).as_str();
        let mut body = gated_incs.clone();
        body.push_str(def);
        let d = ds.add(si_names.at(i).as_str(), body.as_str(), p.core_module);
        let mut line = String::from_str(def.slice(0, def.find("{") as usize).trim_end());
        line.push_str(";\n");
        fd.add(si_names.at(i).as_str(), line.as_str(), d);
    }
    // A backend constant (defined with the core module's) is declared in each header that names it.
    for j in 0..cem.stat_items.len() {
        if p.modules[cem.stat_items.at(j).def.module as usize].backend {
            let sl = cem.stat_decls.as_str().slice(cap_pe(&cem.stat_end, j as u32) as usize, cem.stat_end[j] as usize);
            fd.add(cem.stat_items.at(j).sym.as_str(), sl, ANY_HOME);
        }
    }
    let nd = ds.key.len();
    let mut def_used = Vector::<u8>::new();
    def_used.resize_default(nd);
    ds.stems();
    // Typedef homes: the definition header of the aggregate; a typedef nothing defines (a
    // zero-sized aggregate, a pointee no body needs) has no file and every header or unit that
    // spells it gets a copy.
    let mut tf = Vector::<u32>::with_capacity(nd); // per definition header: its typedef line (fd index + 1, 0 none)
    tf.resize_default(nd);
    for pass in 0..2 {
        let src = if pass == 0 {
            em.fwd2.as_str();
        } else {
            cem.env_fwd.as_str();
        };
        let mut a: usize = 0;
        while a < src.len() {
            let mut b = a;
            while src.byte_at(b) != 10 {
                b += 1;
            }
            let line = src.slice(a, b + 1);
            let name = typedef_name(line);
            let home = switch ds.idx.get(&nkey(fnv(name))) {
                Some(v) => *v,
                None => ANY_HOME,
            };
            if fd.add(name, line, home) && home != ANY_HOME {
                tf.set(home as usize, fd.seg.end.len() as u32);
            }
            a = b + 1;
        }
    }
    let mut incd = Vector::<u8>::new(); // per definition header: included by the file being built
    incd.resize_default(nd);
    // Prototype headers include the carriers their `_ret` typedefs name and (`scan_def`) the
    // element types of their array declarators: parameters and constants.
    let mut needp = Vector::<Vector<u32>>::with_capacity(n);
    needp.resize_default(n);
    for i in 0..cem.hdr_k.len() {
        let own = cem.hdr_k[i] as usize;
        let k = nkey(cem.hdr_h[i]);
        switch ds.idx.get(&k) {
            Some(d) => needp.index_mut(own).push(*d),
            None => {},
        };
    }
    // Prototype header bodies: `_ret` typedefs, cross-TU prototypes, constant and
    // descriptor declarations, each by owner. Shared assert helpers go to the forward header.
    let mut ph = Vector::<String>::with_capacity(n);
    for _i in 0..n {
        ph.push(String::new());
    }
    let mut fwd_aux = String::new();
    {
        let mut pe: u32 = 0;
        for i in 0..cem.sh_aux_k.len() {
            let e = cem.sh_aux_e[i];
            let text = cem.aux.as_str().slice(pe as usize, e as usize);
            if cem.aux_own[i] == 0xFFFF as ModuleId {
                fwd_aux.push_str(text);
            } else {
                ph.index_mut(cem.aux_own[i] as usize).push_str(text);
            }
            pe = e;
        }
    }
    for i in 0..acc.ch.chunk_mod.len() {
        let pl = ps.slice(poff[i] as usize, poff[i + 1] as usize);
        if !(pl.len() >= 7 && pl.slice(0, 7) == "static ") {
            ph.index_mut(acc.ch.chunk_own[i] as usize).push_str(pl);
        }
    }
    for j in 0..cem.stat_items.len() {
        let sl = cem.stat_decls.as_str().slice(cap_pe(&cem.stat_end, j as u32) as usize, cem.stat_end[j] as usize);
        ph.index_mut(emit_owner(p, cem.stat_items.at(j).def.module) as usize).push_str(sl);
    }
    for i in 0..tdecl.end.len() {
        ph.index_mut(tdecl.own[i] as usize).push_str(tdecl.at(i));
    }
    // Every unit declares the cross-TU declarations its text spells (`XDecls`), and includes no
    // prototype header.
    let mut xd = XDecls::new();
    for i in 0..xhdrs.len() {
        for k in 0..xhdrs[i].names.len() {
            xd.add_header(xhdrs[i].names[k].as_str(), i as u32);
        }
    }
    for m in 0..n {
        xd.add_all(ph[m].as_str(), &fd);
    }
    {
        // The forward header: fixed runtime text, extern headers, then the copies its other
        // declarations spell. The forward header includes no definition header: a prototype that
        // needs one (an array declarator of an aggregate, which C needs complete, or the alias of a
        // scoped extern header's type) is a declaration of the units that call it (`split_protos`).
        let mut protos = String::new();
        let mut xp = String::new();
        let mut deps = Vector::<u32>::new();
        split_protos(cem.extern_protos.as_str(), &mut fd, &mut incd, &mut deps, &mut protos, &mut xp);
        if cem.blk_protos.len() != 0 {
            // The pool's C-callable entry point (std::parallel::blocking, symbol pinned @export).
            protos.push_str("void __sc_blocking_run(void (*__r)(void *), void *__e);\n");
        }
        split_protos(cem.blk_protos.as_str(), &mut fd, &mut incd, &mut deps, &mut protos, &mut xp);
        xd.add_all(xp.as_str(), &fd);
        let mut rest = String::new();
        rest.reserve(
            cem.dyn_defs.len() + macros_out.len() + fwd_aux.len() + protos.len() + cem.dyn_decls.len() + cem.sent_decls.len(),
        );
        rest.push_string(&cem.dyn_defs);
        rest.push_string(macros_out);
        rest.push_string(&fwd_aux);
        rest.push_string(&protos);
        rest.push_string(&cem.dyn_decls);
        rest.push_string(&cem.sent_decls);
        let mut fh = String::from_str(
            "#ifndef SC_CEMIT_FWD_H\n#define SC_CEMIT_FWD_H\n#include \"super_rt.h\"\n#include <math.h>\n#include <pthread.h>\ntypedef struct { const uint8_t *ptr; size_t len; } SCslice;\ninline void *__sc_wrap(const void *p) { return (void *)p; }\n#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"\n#pragma GCC diagnostic ignored \"-Wunused-variable\"\n#pragma GCC diagnostic ignored \"-Wunused-function\"\n#pragma GCC diagnostic ignored \"-Wunused-parameter\"\n#pragma GCC diagnostic ignored \"-Wunused-label\"\n",
        );
        fh.push_string(ext_incs);
        // A scoped extern header a declaration or a check here names (a dyn table of a header type):
        // every file sees it.
        deps.clear();
        fd.scan_def(ext_incs.as_str(), NO_HOME, 0, &mut incd, &mut deps);
        fd.scan_def(rest.as_str(), NO_HOME, 0, &mut incd, &mut deps);
        ds.sort_by_stem(&mut deps);
        for k in 0..deps.len() {
            if deps[k] < nx {
                def_inc(0, ds.stem[deps[k] as usize].as_str(), &mut fh);
            }
            incd.set(deps[k] as usize, 0);
        }
        simd_level_fn(p, &mut fh);
        fd.copy(rest.as_str(), NO_HOME, &incd, &mut fh);
        fh.push_string(&rest);
        fh.push_str("#endif\n");
        o.fwd_h = fh;
    }
    // Chunk table and per-TU / per-owner chunk lists.
    for i in 0..acc.ch.chunk_mod.len() {
        o.ck_off.push(acc.ch.chunk_off[i] as u32);
        o.ck_end.push(acc.ch.chunk_end[i] as u32);
        o.ck_shard.push(0);
        if acc.ch.chunk_mod[i] == 65534 {
            o.inst_chunks.index_mut(acc.ch.chunk_own[i] as usize).push(i as u32);
        } else {
            o.tu_chunks.index_mut(acc.ch.chunk_mod[i] as usize).push(i as u32);
        }
    }
    // Prototype headers (a module with a TU always gets one).
    for m in 0..n {
        let has_tu = o.tu_chunks[m].len() != 0 || acc.have_main && !testing && m as u64 == acc.main_mod;
        if ph[m].len() == 0 && !has_tu {
            continue;
        }
        let path = p.modules[m].path.as_str();
        let d = mod_depth(path);
        let mut t = String::new();
        t.reserve(ph[m].len() + 256);
        hdr_open("SC_P_", path, &mut t);
        inc_line(d, "__sc_fwd", ".h", &mut t);
        let np = needp.index_mut(m);
        np.sort();
        np.dedup();
        for k in 0..np.len() {
            incd.set(np[k] as usize, 1);
        }
        fd.scan_def(ph[m].as_str(), NO_HOME, 0, &mut incd, np);
        ds.sort_by_stem(np);
        for k in 0..np.len() {
            def_inc(d, ds.stem[np[k] as usize].as_str(), &mut t);
        }
        fd.flush_unseen(NO_HOME, &incd, &mut t);
        for k in 0..np.len() {
            incd.set(np[k] as usize, 0);
        }
        t.push_string(&ph[m]);
        t.push_str("#endif\n");
        o.protos_h.set(m, t);
    }
    let mut sdefs9 = Set::<u64>::new();
    struct_def_names(ds.body.txt.as_str(), &mut sdefs9);
    let recs9 = inst_recs(p);
    // Instance-shard data heads by owner: block wrappers, constant definitions, descriptor
    // groups and dyn tables.
    let mut ih = Vector::<String>::with_capacity(n);
    for _i in 0..n {
        ih.push(String::new());
    }
    {
        let mut pe: u32 = 0;
        for i in 0..cem.sh_blk_k.len() {
            let e = cem.sh_blk_e[i];
            ih.index_mut((cem.sh_blk_k[i] >> 32) as usize).push_str(
                cem.blk_defs.as_str().slice(pe as usize, e as usize),
            );
            pe = e;
        }
        for i in 0..cdefs.end.len() {
            ih.index_mut(cdefs.own[i] as usize).push_str(cdefs.at(i));
        }
        for i in 0..sdefs.end.len() {
            ih.index_mut(sdefs.own[i] as usize).push_str(sdefs.at(i));
        }
        pe = 0;
        for i in 0..cem.sh_dyt_k.len() {
            let e = cem.sh_dyt_e[i];
            ih.index_mut(cem.dyt_own[i] as usize).push_str(cem.dyn_tabs.as_str().slice(pe as usize, e as usize));
            pe = e;
            if let Some(l) = &mut cem.lir {
                l.claim_data(cem.dyt_sym.at(i).as_str(), cem.dyt_own[i]);
            }
        }
    }
    // Per-module TU shards and per-owner instance shards: chunk shards from the stable item hash
    // (a static closure follows the body before it), shard heads (static prototypes; head 0 of a
    // module TU also carries its asserts, of an instance shard its data definitions), then the
    // include lists from the spelling rows (the heads spell types too).
    if acc.have_main && !testing && acc.main_argv {
        // The C `main` wrapper (a fixed text) allocates a Vector<str> through Global.
        cem.mg.mark_ctx = acc.main_mod as i64;
        let g9 = p.prelude_lookup("Global", true);
        let s9 = p.prelude_lookup("str", true);
        let v9 = p.prelude_lookup("Vector", true);
        cem.mg.mark_used(g9.mid);
        cem.mg.mark_used(g9.mid | 0x8000);
        cem.mg.mark_used(s9.mid);
        cem.mg.mark_used(s9.mid | 0x8000);
        cem.mg.mark_used(v9.mid | 0x8000);
        cem.mg.need_name(fnv("Vector__str"), true);
        cem.mg.need_name(fnv("str"), true);
        cem.mg.need_name(fnv("Global"), false);
    }
    let tnr = TnRows::new(&cem.mg, 2 * n + 1);
    let mut pend = Vector::<u32>::new();
    let mut dv = Vector::<u32>::new();
    // Per module: the definition headers its TU and its instance unit include (`tu_x`, `inst_x`).
    let mut tu_dv = Vector::<Vector<u32>>::new();
    tu_dv.resize_default(n);
    let mut inst_dv = Vector::<Vector<u32>>::new();
    inst_dv.resize_default(n);
    // The declarations each module TU (row t) and instance unit (row n + t) spells: its chunks, the
    // instance data heads and the C `main` wrapper. The other head text (static prototypes, the
    // asserts) names no declaration but its own `_ret` typedefs, which the definitions name too.
    let mut tail9 = String::new();
    if acc.have_main && !testing {
        cemit_main_wrapper(&mut tail9, acc.main_argv);
    }
    let mut rsel = Vector::<Vector<u32>>::new();
    xd_rows(
        &xd,
        &o.tu_chunks,
        &o.inst_chunks,
        &acc.ch.bufs,
        &o.ck_off,
        &o.ck_end,
        &ih,
        acc.main_mod as usize,
        tail9.as_str(),
        p.jobs,
        &mut rsel,
    );
    let mut lay = Vector::<String>::with_capacity(nd); // per definition header: its layout checks
    lay.resize_default(nd);
    for pass in 0..2 {
        for t in 0..n {
            let is_inst = pass == 1;
            let has_wrap = !is_inst && acc.have_main && !testing && t as u64 == acc.main_mod;
            let cks = if is_inst {
                o.inst_chunks.at(t);
            } else {
                o.tu_chunks.at(t);
            };
            if cks.len() == 0 && !has_wrap && (!is_inst || ih[t].len() == 0) && (is_inst || !module_has_asm(p, t)) {
                continue;
            }
            let path = p.modules[t].path.as_str();
            let d = mod_depth(path);
            let src9 = if is_inst {
                (mbe::CTX_INST | t as i64) as u64;
            } else {
                t as u64;
            };
            let mut nsh = shard_rule(p, t, is_inst) as usize;
            if nsh == 0 {
                // The module's rendered C: its chunks (bounds in the chunk table) plus the
                // prototype lines walked below (the static ones become the shard heads).
                let mut bytes: usize = 0;
                for k in 0..cks.len() {
                    let i = cks[k] as usize;
                    bytes += (o.ck_end[i] - o.ck_off[i]) as usize + (poff[i + 1] - poff[i]) as usize;
                }
                let prev = if is_inst {
                    prev_insts[t];
                } else {
                    prev_tus[t];
                };
                nsh = shard_policy(bytes, prev) as usize;
            }
            let mut heads = Vector::<String>::with_capacity(nsh);
            for _k in 0..nsh {
                heads.push(String::new());
            }
            let mut last: u8 = 0;
            for k in 0..cks.len() {
                let i = cks[k] as usize;
                let pl = ps.slice(poff[i] as usize, poff[i + 1] as usize);
                let is_static = pl.len() >= 7 && pl.slice(0, 7) == "static ";
                if !is_static {
                    last = if nsh == 1 {
                        0u8;
                    } else {
                        (item_hash(pl) % nsh as u64) as u8;
                    };
                } else {
                    heads.index_mut(last as usize).push_str(pl);
                }
                o.ck_shard.set(i, last);
            }
            if is_inst {
                heads.index_mut(0).push_string(&ih[t]);
                let inc = unit_incs(
                    cem,
                    &ds,
                    &mut fd,
                    &mut incd,
                    &xd,
                    rsel.at(n + t),
                    src9,
                    d,
                    &tnr,
                    &mut pend,
                    &mut dv,
                    &mut def_used,
                );
                o.inst_incs.set(t, inc);
                inst_dv.set(t, dv.clone());
                o.inst_heads.set(t, heads);
                continue;
            }
            if p.modules[t].has_ast {
                // Folded module-level static_asserts leave their record in the C (parity with
                // the checker: a false one already failed the build).
                let head0 = heads.index_mut(0);
                let a9 = unsafe &*p.module_ast_const(t as ModuleId);
                let its9 = a9.at_const(a9.root).as_data.program.items;
                for i9 in 0..its9.len {
                    let nid9 = unsafe a9.list(its9)[i9 as usize];
                    if a9.at_const(nid9).kind == NodeKind::NODE_ASM {
                        // A module-level `asm` is file-scope basic assembly in its module's unit.
                        let tsp9 = a9.at_const(a9.ext(nid9).asm_stmt.template).as_data.literal.raw;
                        head0.push_str("__asm__(");
                        cbe::push_c_asm_str(
                            p.modules[t].source.as_str().slice(tsp9.start as usize, tsp9.end as usize),
                            head0,
                        );
                        head0.push_str(");\n");
                        continue;
                    }
                    if a9.at_const(nid9).kind != NodeKind::NODE_STATIC_ASSERT {
                        continue;
                    }
                    let bd9 = a9.at_const(nid9).as_data.binary;
                    head0.push_str("_Static_assert(true, ");
                    if bd9.right != NODE_NONE {
                        let rsp9 = a9.at_const(bd9.right).as_data.literal.raw;
                        head0.push_str(p.modules[t].source.as_str().slice(rsp9.start as usize, rsp9.end as usize));
                    } else {
                        head0.push_str("\"static assertion failed\"");
                    }
                    head0.push_str(");\n");
                }
                cem.mg.mark_ctx = t as i64;
                // The checks of emitted types land in their headers: the unit spells only extern
                // types, which need no edge.
                cem.mg.no_edges = true;
                cemit_layout_asserts(p, cem, t as ModuleId, &recs9, &sdefs9, &ds, &mut lay, head0);
                cem.mg.no_edges = false;
            }
            let mut tail = String::new();
            if has_wrap {
                cemit_main_wrapper(&mut tail, acc.main_argv);
                cem.lir_main_wrapper(t as ModuleId, acc.main_argv);
                cem.lir_claim(t as u32, "the C `main`", false);
            }
            let inc = unit_incs(
                cem,
                &ds,
                &mut fd,
                &mut incd,
                &xd,
                rsel.at(t),
                src9,
                d,
                &tnr,
                &mut pend,
                &mut dv,
                &mut def_used,
            );
            o.tu_incs.set(t, inc);
            tu_dv.set(t, dv.clone());
            o.tu_heads.set(t, heads);
            o.tu_tail.set(t, tail);
        }
    }
    // Definition header texts: the forward header, the headers of the types the body embeds by
    // value (the by-value graph is acyclic, so no header needs its own include), its typedef
    // line, copies of the other declarations it spells, the body, its layout checks.
    let mut deps = Vector::<u32>::new();
    // Per definition header: the definition headers it includes (`x_reach`).
    let mut ddeps = Vector::<Vector<u32>>::new();
    ddeps.resize_default(nd);
    // The used entries' vector structs: lazy packs a used entry spells by value, then the 16-byte
    // chunk pack a used wide one names (`Mangler::vec_def`), which names no pack.
    let ne = nd - si0;
    let lazy = if lp0 < si0 {
        si0 - lp0;
    } else {
        0;
    };
    for j in 0..ne + lazy {
        let x = if j < ne {
            si0 + j;
        } else {
            lp0 + j - ne;
        };
        if def_used[x] == 0 {
            continue;
        }
        deps.clear();
        fd.scan_def(ds.body.at(x), x as u32, pick(j < ne, 2u32, 1u32), &mut incd, &mut deps);
        for k in 0..deps.len() {
            def_used.set(deps[k] as usize, 1);
            incd.set(deps[k] as usize, 0);
        }
    }
    for d in 0..nd {
        if (d >= si0 || d >= lp0) && def_used[d] == 0 {
            o.defs_h.push(String::new());
            o.defs_own.push(ds.body.own[d]);
            continue;
        }
        let body = ds.body.at(d);
        deps.clear();
        fd.scan_def(body, d as u32, pick(d >= si0, 2u32, 1u32), &mut incd, &mut deps);
        ddeps.set(d, deps.clone());
        if d as u32 < nx {
            for k in 0..xhdrs[d].pre.len() {
                let x = xhdrs[d].pre[k];
                if incd[x as usize] == 0 {
                    incd.set(x as usize, 1);
                    deps.push(x);
                }
            }
        }
        ds.sort_by_stem(&mut deps);
        let mut t = String::new();
        t.reserve(body.len() + 64 * deps.len() + 128);
        def_guard(ds.stem[d].as_str(), &mut t);
        t.push_str("#include \"../__sc_fwd.h\"\n");
        for k in 0..deps.len() {
            let x = deps[k] as usize;
            t.push_str("#include \"");
            t.push_string(&ds.stem[x]);
            t.push_str(".h\"\n");
        }
        // A scoped header after the headers it needs.
        if d as u32 < nx {
            t.push_string(&xhdrs[d].line);
        }
        if tf[d] != 0 {
            t.push_str(fd.seg.at((tf[d] - 1) as usize));
        }
        fd.flush_unseen(d as u32, &incd, &mut t);
        t.push_str(body);
        t.push_string(&lay[d]);
        t.push_str("#endif\n");
        for k in 0..deps.len() {
            incd.set(deps[k] as usize, 0);
        }
        o.defs_h.push(t);
        o.defs_own.push(ds.body.own[d]);
    }
    let xr = x_reach(nx, &ddeps);
    for t in 0..n {
        // wasm's C library compiles with its own flags (`loader::libc_unit`).
        let lc = p.is_libc(t as i32);
        o.tu_x.set(t, lc || x_any(&xr, &tu_dv[t]));
        o.inst_x.set(t, lc || x_any(&xr, &inst_dv[t]));
    }
    // The registry TU includes every scoped extern header that has checks and that no unit includes, so
    // they run once also where no unit uses the header's items (a constant that folds to its value). In a
    // native build, whose modules' units may not compile, it includes every one, and it is the C unit that
    // checks the extern blocks against their headers.
    let used = unit_reach(ddeps.len(), &ddeps, &tu_dv, &inst_dv);
    let mut xall = String::new();
    for d in 0..nx {
        if xhdrs[d as usize].checks.len() != 0 && (!used[d as usize] || p.native) {
            def_inc(0, ds.stem[d as usize].as_str(), &mut xall);
        }
    }
    o.reg_x = xall.len() != 0;
    o.defs_stem = replace(&mut ds.stem, Vector::<String>::new());
    for t in 0..n {
        o.tus.set(t, replace(acc.ch.bufs.index_mut(t), String::new()));
    }
    o.inst_c = replace(acc.ch.bufs.index_mut(n), String::new());
    // The registry TU, in every program: the external definitions of the inline helpers of
    // `super_rt.h` and `__sc_fwd.h` (`SC_RT_EXTERNS`), ZST sentinels and the reflection registry (sorted
    // roots, one pointer table, one registration entry point; lookups never depend on constructor order).
    {
        let mut rg = String::new();
        rg.push_string(&cem.sent_defs);
        let mut zi = cem.sent_seen.iter();
        while let Some(a) = zi.next() {
            o.zst.push(*a);
        }
        o.zst.sort();
        if reg_names.len() != 0 {
            let mut ord = Vector::<u32>::with_capacity(reg_names.len());
            for i in 0..reg_names.len() {
                ord.push(i as u32);
            }
            {
                let mut kv = Vector::<KeyIdx>::with_capacity(ord.len());
                for i in 0..ord.len() {
                    kv.push(KeyIdx { key: reg_names[i].as_str(), idx: i as u32 });
                }
                kv.sort_by(key_idx_cmp);
                for i in 0..ord.len() {
                    ord.set(i, kv[i].idx);
                }
            }
            for k in 0..ord.len() {
                rg.push_str("extern ");
                rg.push_str(vis9);
                rg.push_str("const ");
                rg.push_string(&reg_decls[ord[k] as usize]);
                rg.push_str(";\n");
            }
            rg.push_str("static const void *const __sc_reflect_roots[] = {");
            for k in 0..ord.len() {
                rg.push_str(mbe::if_s(k == 0, " &", ", &"));
                rg.push_string(&reg_names[ord[k] as usize]);
                if k != 0 {
                    o.reg_inputs.push_str(" ");
                }
                o.reg_inputs.push_string(&reg_names[ord[k] as usize]);
            }
            rg.push_str(
                " };\n__attribute__((constructor)) static void __sc_reflect_init(void) { __sc_reflect_register(__sc_reflect_roots, sizeof(__sc_reflect_roots) / sizeof(__sc_reflect_roots[0])); }\n",
            );
        }
        let mut rc = String::from_str("#include \"__sc_fwd.h\"\n");
        rc.push_string(&xall);
        rc.push_str("SC_RT_EXTERNS\nSC_RT_X(__sc_wrap)\n");
        fd.copy(rg.as_str(), NO_HOME, &incd, &mut rc);
        rc.push_string(&rg);
        o.registry_c = rc;
    }
}

/// The key of C name FNV `h` in the declaration and definition tables: bit 0 is free for the
/// definition flag of the spelling rows (see `Mangler::tn_key`).
const fn nkey(h: u64) u64 {
    return h & 0xFFFFFFFFFFFFFFFE;
}

/// The home of a declaration the forward header holds.
const NO_HOME: u32 = 0xFFFFFFFF;
/// The home of a declaration no file holds: every header or unit that spells it gets a copy.
const ANY_HOME: u32 = 0xFFFFFFFE;

/// The forward declarations of the emitted C, each in at most one home: an aggregate typedef and
/// a payload-less enum in the definition header of the type. Any other header gets a copy of each
/// one its text spells (C11 allows a repeated typedef; an enum copy keeps its include guard), so
/// no file depends on the declarations of types it does not spell.
struct FwdDecls {
    pub(package) seg: Segs, // declaration texts
    pub(package) home: Vector<u32>, // per declaration: its definition header, NO_HOME or ANY_HOME
    pub(package) always: Vector<bool>, // per declaration: an alias of a scoped extern header, whose file every use includes
    keys: Map<u64, u32>, // name FNV -> declaration index
    filt: Vector<u64>, // 65536-bit filter over the name FNVs: most identifiers stop here
    stamp: Vector<u32>, // per declaration: the serial of the last header that took it
    hits: Vector<u32>,
    serial: u32,
}

extend FwdDecls {
    fn new() FwdDecls {
        let mut filt = Vector::<u64>::new();
        filt.resize_default(1024);
        return FwdDecls {
            seg: Segs::new(),
            home: Vector::<u32>::new(),
            always: Vector::<bool>::new(),
            keys: Map::<u64, u32>::new(),
            filt: filt,
            stamp: Vector::<u32>::new(),
            hits: Vector::<u32>::new(),
            serial: 0,
        };
    }

    /// Record declaration `text` of `name` homed in `home`; false when `name` already has one.
    fn add(self: &mut Self, name: str, text: str, home: u32) bool {
        let h = nkey(fnv(name));
        if self.keys.contains_key(&h) {
            return false;
        }
        self.keys.insert(h, self.seg.end.len() as u32);
        let w = (h & 0xFFFF) as usize / 64;
        self.filt.set(w, self.filt[w] | 1u64 << (h & 63));
        self.seg.txt.push_str(text);
        self.seg.close(0);
        self.home.push(home);
        self.always.push(false);
        self.stamp.push(0);
        return true;
    }

    /// Record alias token `name` of the scoped extern header of definition header `home`
    /// (`mbe::x_alias`): a file that spells it includes that header (`scan`). False when `name`
    /// already has a declaration.
    fn add_header(self: &mut Self, name: str, home: u32) bool {
        let h = nkey(fnv(name));
        if self.keys.contains_key(&h) {
            return false;
        }
        self.keys.insert(h, self.seg.end.len() as u32);
        let w = (h & 0xFFFF) as usize / 64;
        self.filt.set(w, self.filt[w] | 1u64 << (h & 63));
        self.seg.push_empty(0);
        self.home.push(home);
        self.always.push(true);
        self.stamp.push(0);
        return true;
    }

    // Whether a file whose included definition headers are marked in `inc` (and that is itself
    // `own`) already sees declaration `k`.
    const fn seen(self: &Self, k: u32, own: u32, inc: &Vector<u8>) bool {
        let home = self.home[k as usize];
        return home == own || home == NO_HOME || home != ANY_HOME && inc[home as usize] != 0;
    }

    /// Append to `out`, in declaration order, every declaration `text` spells that the file
    /// (`own`, including the definition headers marked in `inc`) does not already see.
    fn copy(self: &mut Self, text: str, own: u32, inc: &Vector<u8>, out: &mut String) {
        self.serial += 1;
        self.hits.clear();
        let n = text.len();
        let mut i: usize = 0;
        while i < n {
            let cls = c_class(text.byte_at(i));
            if cls != C_IDENT {
                i = if cls == C_OPEN {
                    c_skip(text, i);
                } else {
                    i + 1;
                };
                continue;
            }
            let mut h: u64 = 0xcbf29ce484222325;
            while i < n && c_ident_byte(text.byte_at(i)) {
                h = (h ^ text.byte_at(i) as u64).wrapping_mul(0x100000001b3);
                i += 1;
            }
            h = nkey(h);
            if (self.filt[(h & 0xFFFF) as usize / 64] >> (h & 63) & 1) == 0 {
                continue;
            }
            let k = switch self.keys.get(&h) {
                Some(v) => *v,
                None => 0xFFFFFFFFu32,
            };
            if k == 0xFFFFFFFF || self.stamp[k as usize] == self.serial {
                continue;
            }
            self.stamp.set(k as usize, self.serial);
            if !self.seen(k, own, inc) {
                self.hits.push(k);
            }
        }
        self.flush(out);
    }

    /// Queue every declaration header text `text` (of definition header `own`) spells, and append
    /// to `deps` (once each, marked in `inc`) the definition headers of the types C needs complete
    /// there: the element type of every array declarator (`T x[2]`, `T (*p)[2]`, also in a
    /// function-pointer parameter) and a declared name followed by a declarator name rather than
    /// `*` or `(` within `by_val` levels of parentheses: none, 1 for a definition body (outside
    /// parentheses), 2 for a function definition (its parameters too); and the scoped extern header
    /// of every alias (`add_header`). `flush_unseen` then writes the copies the file still needs.
    fn scan_def(self: &mut Self, text: str, own: u32, by_val: u32, inc: &mut Vector<u8>, deps: &mut Vector<u32>) {
        self.begin();
        self.scan(text, own, by_val, inc, deps);
    }

    /// `scan_def` into the declarations already queued since `begin`.
    fn scan(self: &mut Self, text: str, own: u32, by_val: u32, inc: &mut Vector<u8>, deps: &mut Vector<u32>) {
        let n = text.len();
        let mut i: usize = 0;
        let mut depth: u32 = 0;
        while i < n {
            let c = text.byte_at(i);
            let cls = c_class(c);
            if cls != C_IDENT {
                if c == b'(' {
                    depth += 1;
                } else if c == b')' && depth > 0 {
                    depth -= 1;
                }
                i = if cls == C_OPEN {
                    c_skip(text, i);
                } else {
                    i + 1;
                };
                continue;
            }
            let mut h: u64 = 0xcbf29ce484222325;
            while i < n && c_ident_byte(text.byte_at(i)) {
                h = (h ^ text.byte_at(i) as u64).wrapping_mul(0x100000001b3);
                i += 1;
            }
            h = nkey(h);
            if (self.filt[(h & 0xFFFF) as usize / 64] >> (h & 63) & 1) == 0 {
                continue;
            }
            let k = switch self.keys.get(&h) {
                Some(v) => *v,
                None => 0xFFFFFFFFu32,
            };
            if k == 0xFFFFFFFF {
                continue;
            }
            let home = self.home[k as usize];
            if home < ANY_HOME && home != own && inc[home as usize] == 0 {
                let mut j = i;
                while j < n && text.byte_at(j) == b' ' {
                    j += 1;
                }
                if self.always[k as usize] || depth < by_val && j < n && c_ident_byte(text.byte_at(j)) || arr_declarator(
                    text,
                    j,
                ) {
                    inc.set(home as usize, 1);
                    deps.push(home);
                }
            }
            if self.stamp[k as usize] != self.serial {
                self.stamp.set(k as usize, self.serial);
                self.hits.push(k);
            }
        }
    }

    /// Append to `out`, in declaration order, the queued declarations the file (see `seen`) does
    /// not already see.
    fn flush_unseen(self: &mut Self, own: u32, inc: &Vector<u8>, out: &mut String) {
        self.hits.sort();
        for j in 0..self.hits.len() {
            if !self.seen(self.hits[j], own, inc) {
                out.push_str(self.seg.at(self.hits[j] as usize));
            }
        }
    }

    /// The declaration of name key `h` (`nkey`), 0xFFFFFFFF when none.
    fn find(self: &Self, h: u64) u32 {
        return switch self.keys.get(&h) {
            Some(v) => *v,
            None => 0xFFFFFFFFu32,
        };
    }

    /// Queue declaration `k` for the next `flush` unless the file (see `seen`) already sees it.
    fn want(self: &mut Self, k: u32, own: u32, inc: &Vector<u8>) {
        if self.stamp[k as usize] != self.serial && !self.seen(k, own, inc) {
            self.stamp.set(k as usize, self.serial);
            self.hits.push(k);
        }
    }

    /// Start a new file for `want`.
    fn begin(self: &mut Self) {
        self.serial += 1;
        self.hits.clear();
    }

    /// Append the queued declarations to `out` in declaration order.
    fn flush(self: &mut Self, out: &mut String) {
        self.hits.sort();
        for j in 0..self.hits.len() {
            out.push_str(self.seg.at(self.hits[j] as usize));
        }
    }
}

/// The definition headers: per header its C name and body (`own` = the owner module), the FNV of
/// its name, the index by FNV and the file stem.
struct DefSet {
    pub(package) name: Segs,
    pub(package) body: Segs,
    pub(package) key: Vector<u64>,
    pub(package) idx: Map<u64, u32>, // name key (`nkey`) -> header
    pub(package) stem: Vector<String>,
    rank: Vector<u32>, // per header: its position in stem order
    order: Vector<u32>, // per position in stem order: the header
}

extend DefSet {
    fn new() DefSet {
        return DefSet {
            name: Segs::new(),
            body: Segs::new(),
            key: Vector::<u64>::new(),
            idx: Map::<u64, u32>::new(),
            stem: Vector::<String>::new(),
            rank: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
        };
    }

    /// Add the definition `body` of C name `nm` owned by `own`; its index.
    fn add(self: &mut Self, nm: str, body: str, own: ModuleId) u32 {
        let d = self.key.len() as u32;
        let h = nkey(fnv(nm));
        assert(!self.idx.contains_key(&h));
        self.idx.insert(h, d);
        self.key.push(h);
        self.name.txt.push_str(nm);
        self.name.own.push(own);
        self.name.end.push(self.name.txt.len() as u32);
        self.body.txt.push_str(body);
        self.body.own.push(own);
        self.body.end.push(self.body.txt.len() as u32);
        return d;
    }

    /// Name every header: its C name when that has at most STEM_MAX bytes, else the first
    /// STEM_KEEP bytes and the 16 hex digits of the name's FNV. Names that fold to one stem
    /// case-insensitively (macOS and Windows file systems) all take the hashed form.
    fn stems(self: &mut Self) {
        let nd = self.key.len();
        let mut fv = Vector::<u64>::with_capacity(nd);
        for d in 0..nd {
            let mut st = String::new();
            stem_of(self.name.at(d), self.key[d], false, &mut st);
            fv.push(fold_hash(st.as_str()));
            self.stem.push(st);
        }
        let mut sorted = fv.clone();
        sorted.sort();
        let mut clash = false;
        for d in 1..nd {
            if sorted[d] == sorted[d - 1] {
                clash = true;
            }
        }
        if clash {
            let mut cnt = Map::<u64, u32>::new();
            for d in 0..nd {
                let c = switch cnt.get(&fv[d]) {
                    Some(v) => *v,
                    None => 0u32,
                };
                cnt.insert(fv[d], c + 1);
            }
            let mut again = Set::<u64>::new();
            for d in 0..nd {
                if *cnt.get(&fv[d]).unwrap() > 1 {
                    let mut st = String::new();
                    stem_of(self.name.at(d), self.key[d], true, &mut st);
                    self.stem.set(d, st);
                }
                // Distinct 64-bit name hashes cannot fold together.
                let f = fold_hash(self.stem[d].as_str());
                assert(!again.contains(&f));
                again.insert(f);
            }
        }
        // Stem order by a merge sort over the indexes: the first eight bytes compare as one
        // big-endian word, the rest only on a tie (`sort_by` spent its time in indirect
        // byte-wise comparisons of the long shared prefixes).
        let mut pre = Vector::<u64>::with_capacity(nd);
        for d in 0..nd {
            let st = self.stem[d].as_str();
            let mut w: u64 = 0;
            for b in 0..pick(st.len() < 8, st.len(), 8) {
                w = w | st.byte_at(b) as u64 << 56 - 8 * b as u64;
            }
            pre.push(w);
        }
        let mut src = Vector::<u32>::with_capacity(nd);
        let mut dst = Vector::<u32>::with_capacity(nd);
        for d in 0..nd {
            src.push(d as u32);
            dst.push(0);
        }
        let mut width: usize = 1;
        while width < nd {
            let mut lo: usize = 0;
            while lo < nd {
                let mid = pick(lo + width < nd, lo + width, nd);
                let hi = pick(lo + 2 * width < nd, lo + 2 * width, nd);
                let mut i = lo;
                let mut j = mid;
                for k in lo..hi {
                    let take_left = j >= hi || i < mid && self.stem_le(&pre, src[i], src[j]);
                    if take_left {
                        dst.set(k, src[i]);
                        i += 1;
                    } else {
                        dst.set(k, src[j]);
                        j += 1;
                    }
                }
                lo = hi;
            }
            let t = src;
            src = dst;
            dst = t;
            width *= 2;
        }
        self.order = src;
        self.rank.resize_default(nd);
        for r in 0..nd {
            self.rank.set(self.order[r] as usize, r as u32);
        }
    }

    // Stem `a` sorts before or equal to stem `b` (`pre`: their first eight bytes, big-endian).
    const fn stem_le(self: &Self, pre: &Vector<u64>, a: u32, b: u32) bool {
        let pa = pre[a as usize];
        let pb = pre[b as usize];
        if pa != pb {
            return pa < pb;
        }
        return str_cmp(self.stem[a as usize].as_str(), self.stem[b as usize].as_str()) <= 0;
    }

    /// Order distinct header indexes by stem (the include order of every file).
    fn sort_by_stem(self: &Self, v: &mut Vector<u32>) {
        for i in 0..v.len() {
            v.set(i, self.rank[v[i] as usize]);
        }
        v.sort();
        for i in 0..v.len() {
            v.set(i, self.order[v[i] as usize]);
        }
    }
}

/// Longest C name used as a file stem as is.
const STEM_MAX: usize = 40;
/// Bytes of a longer name a hashed stem keeps.
const STEM_KEEP: usize = 23;

// The stem of definition header `nm` (name FNV `h`): see `DefSet::stems`.
fn stem_of(nm: str, h: u64, hashed: bool, out: &mut String) {
    if !hashed && nm.len() <= STEM_MAX {
        out.push_str(nm);
        return;
    }
    out.push_str(nm.slice(0, pick(nm.len() < STEM_KEEP, nm.len(), STEM_KEEP)));
    out.push_str("_");
    out.push_hex(h, false);
}

// The FNV of `s` with ASCII letters folded to lower case.
const fn fold_hash(s: str) u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for i in 0..s.len() {
        let c = s.byte_at(i);
        h = (h ^ pick(c >= b'A' && c <= b'Z', c + 32, c) as u64).wrapping_mul(0x100000001b3);
    }
    return h;
}

// The include prefix of a module's TU shards or instance shards (spelling context `src`, directory
// depth `d`): the forward header, the definition headers of the types its text and the declarations
// `sel` (of `xd`, the ones the text spells) need complete, copies of the type declarations it and
// those declarations name only through pointers, then the declarations: no prototype header.
// `pend` and `dv` are scratch.
fn unit_incs(
    cem: &cbe::CEmit,
    ds: &DefSet,
    fd: &mut FwdDecls,
    incd: &mut Vector<u8>,
    xd: &XDecls,
    sel: &Vector<u32>,
    src: u64,
    d: u32,
    rows: &TnRows,
    pend: &mut Vector<u32>,
    dv: &mut Vector<u32>,
    used: &mut Vector<u8>,
) String {
    let mut inc = String::new();
    inc_line(d, "__sc_fwd", ".h", &mut inc);
    // The row holds repeats: `incd` and the declaration stamps drop them without a sort.
    pend.clear();
    dv.clear();
    {
        let r = cem.mg.um_row(src);
        for k in rows.off[r] as usize..rows.off[r + 1] as usize {
            // One lookup per entry: a type's declaration is homed in its definition header.
            let key = rows.key[k];
            let dk = fd.find(nkey(key));
            if dk == 0xFFFFFFFF {
                continue;
            }
            let home = fd.home[dk as usize];
            if (key & 1) == 0 && !fd.always[dk as usize] || home >= ANY_HOME {
                pend.push(dk);
            } else if incd[home as usize] == 0 {
                incd.set(home as usize, 1);
                used.set(home as usize, 1);
                dv.push(home);
            }
        }
    }
    // The declarations: the `_ret` typedefs first (a prototype's result names one), which need their
    // result carrier complete; the array declarators of the others need their element types.
    let mut tdefs = String::new();
    let mut decls = String::new();
    for k in 0..sel.len() {
        let xh = xd.hdr[sel[k] as usize];
        if xh != NO_HOME {
            // An alias of a scoped extern header: the unit includes the header's definition header.
            if incd[xh as usize] == 0 {
                incd.set(xh as usize, 1);
                used.set(xh as usize, 1);
                dv.push(xh);
            }
            continue;
        }
        let dt = xd.seg.at(sel[k] as usize);
        if xd.tdef[sel[k] as usize] {
            tdefs.push_str(dt);
        } else {
            decls.push_str(dt);
        }
    }
    fd.begin();
    fd.scan(tdefs.as_str(), NO_HOME, 1, incd, dv);
    fd.scan(decls.as_str(), NO_HOME, 0, incd, dv);
    for k in 0..pend.len() {
        fd.want(pend[k], NO_HOME, incd);
    }
    for k in 0..dv.len() {
        used.set(dv[k] as usize, 1);
    }
    ds.sort_by_stem(dv);
    for k in 0..dv.len() {
        def_inc(d, ds.stem[dv[k] as usize].as_str(), &mut inc);
    }
    fd.flush_unseen(NO_HOME, incd, &mut inc);
    inc.push_string(&tdefs);
    inc.push_string(&decls);
    for k in 0..dv.len() {
        incd.set(dv[k] as usize, 0);
    }
    return inc;
}

/// The cross-TU declarations of the prototype headers, one per declared name: `_ret` typedefs,
/// prototypes, constant and descriptor declarations. A unit declares the ones its text spells
/// (`xd_rows`) in place of including the prototype headers: most units call few of the functions
/// a header declares, and C parses every declaration it includes (on the compiler's build, about 10%
/// of the clang compile and 4% of the gcc one).
struct XDecls {
    pub(package) seg: Segs, // declaration texts, in prototype-header order
    pub(package) tdef: Vector<bool>, // per declaration: a `_ret` typedef
    pub(package) hdr: Vector<u32>, // per declaration: the definition header of a scoped extern header's alias, else NO_HOME
    keys: Map<u64, u32>, // name FNV -> declaration
    filt: Vector<u64>, // 65536-bit filter over the name FNVs: most identifiers stop here
}

extend XDecls {
    fn new() XDecls {
        let mut filt = Vector::<u64>::new();
        filt.resize_default(1024);
        return XDecls {
            seg: Segs::new(),
            tdef: Vector::<bool>::new(),
            hdr: Vector::<u32>::new(),
            keys: Map::<u64, u32>::new(),
            filt: filt,
        };
    }

    // Record alias token `name` of the scoped extern header of definition header `d`: a unit that
    // spells it includes that header. A name recorded already keeps its entry.
    fn add_header(self: &mut Self, name: str, d: u32) {
        let h = nkey(fnv(name));
        if self.keys.contains_key(&h) {
            return;
        }
        self.keys.insert(h, self.seg.end.len() as u32);
        let w = (h & 0xFFFF) as usize / 64;
        self.filt.set(w, self.filt[w] | 1u64 << (h & 63));
        self.seg.push_empty(0);
        self.tdef.push(false);
        self.hdr.push(d);
    }

    // Record each declaration of prototype header body `text` (one per line; a line that does not end
    // a declaration continues it) under its declared name, unless `fd` declares that name (a backend
    // constant every file that names it copies) or a declaration of it is recorded already.
    fn add_all(self: &mut Self, text: str, fd: &FwdDecls) {
        let mut a: usize = 0;
        let mut b: usize = 0;
        while b < text.len() {
            // A guarded block (a thread-local's accessor, `CEmit::tls_accessor`) is one declaration
            // through its `#endif` line, whatever its other lines end with.
            let blk = b == a && text.slice(a, text.len()).starts_with("#ifndef ");
            if blk {
                let k = text.slice(a, text.len()).find("\n#endif\n");
                assert(k >= 0, "a guarded declaration block ends with its '#endif' line");
                b = a + k as usize + 7;
            } else {
                while b < text.len() && text.byte_at(b) != 10 {
                    b += 1;
                }
            }
            let end = pick(b < text.len(), b + 1, b);
            if !blk && b > a && text.byte_at(b - 1) != b';' && end < text.len() {
                b = end;
                continue;
            }
            let dl = text.slice(a, end);
            let h = nkey(fnv(decl_name(dl)));
            if fd.find(h) == 0xFFFFFFFF && !self.keys.contains_key(&h) {
                self.keys.insert(h, self.seg.end.len() as u32);
                let w = (h & 0xFFFF) as usize / 64;
                self.filt.set(w, self.filt[w] | 1u64 << (h & 63));
                self.seg.txt.push_str(dl);
                self.seg.close(0);
                self.tdef.push(dl.starts_with("typedef "));
                self.hdr.push(NO_HOME);
            }
            a = end;
            b = end;
        }
    }

    // Append to `out` each declaration `text` names that `stamp` (per declaration) has not marked
    // with `serial` yet, and mark it.
    fn spells(self: &Self, text: str, stamp: &mut Vector<u32>, serial: u32, out: &mut Vector<u32>) {
        let n = text.len();
        let mut i: usize = 0;
        while i < n {
            let cls = c_class(text.byte_at(i));
            if cls != C_IDENT {
                i = if cls == C_OPEN {
                    c_skip(text, i);
                } else {
                    i + 1;
                };
                continue;
            }
            let mut h: u64 = 0xcbf29ce484222325;
            while i < n && c_ident_byte(text.byte_at(i)) {
                h = (h ^ text.byte_at(i) as u64).wrapping_mul(0x100000001b3);
                i += 1;
            }
            h = nkey(h);
            if (self.filt[(h & 0xFFFF) as usize / 64] >> (h & 63) & 1) == 0 {
                continue;
            }
            switch self.keys.get(&h) {
                Some(v) => {
                    if stamp[(*v) as usize] != serial {
                        stamp.set((*v) as usize, serial);
                        out.push(*v);
                    }
                },
                None => {},
            };
        }
    }
}

/// The most workers `xd_rows` takes: the largest row (the compiler's type checker, a sixth of its C)
/// bounds the time from about six on.
const XD_WORKERS: usize = 8;

/// One worker's share of `xd_rows`: the rows `rows[lo..hi]` of `n` modules.
struct XdTask {
    pub(package) xd: *const XDecls,
    pub(package) tu: *const Vector<Vector<u32>>,
    pub(package) inst: *const Vector<Vector<u32>>,
    pub(package) bufs: *const Vector<String>,
    pub(package) off: *const Vector<u32>,
    pub(package) end: *const Vector<u32>,
    pub(package) ih: *const Vector<String>,
    pub(package) main_mod: usize,
    pub(package) tail: *const u8,
    pub(package) tail_len: usize,
    pub(package) out: *mut Vector<u32>,
    pub(package) rows: *const u32,
    pub(package) n: usize,
    pub(package) lo: usize,
    pub(package) hi: usize,
}

// Tasks only read the texts and the declarations, and write disjoint result rows.
unsafe extend XdTask as Send {}

fn xd_range(t: XdTask) {
    let xd = unsafe &*t.xd;
    let n = t.n;
    let mut stamp = Vector::<u32>::new();
    stamp.resize_default(xd.tdef.len());
    for j in t.lo..t.hi {
        let r = (unsafe t.rows[j]) as usize;
        let inst = r >= n;
        let m = if inst {
            r - n;
        } else {
            r;
        };
        let cks = if inst {
            unsafe (*t.inst).at(m);
        } else {
            unsafe (*t.tu).at(m);
        };
        let buf = unsafe (*t.bufs).at(pick(inst, n, m)).as_str();
        let out = unsafe &mut t.out[r];
        let serial = (r + 1) as u32;
        for k in 0..cks.len() {
            let i = cks[k] as usize;
            xd.spells(buf.slice((unsafe (*t.off)[i]) as usize, (unsafe (*t.end)[i]) as usize), &mut stamp, serial, out);
        }
        if inst {
            xd.spells(unsafe (*t.ih).at(m).as_str(), &mut stamp, serial, out);
        } else if m == t.main_mod {
            xd.spells(unsafe str::from_raw(t.tail, t.tail_len), &mut stamp, serial, out);
        }
        // A prototype names the `_ret` typedef of its result, which the text may not.
        let nsel = out.len();
        for k in 0..nsel {
            if !xd.tdef[out[k] as usize] {
                xd.spells(xd.seg.at(out[k] as usize), &mut stamp, serial, out);
            }
        }
        out.sort();
    }
}

// The declarations of `xd` each unit row spells, ascending, into `out`: row `t` the module TU of `t`
// (chunks `tu[t]` of `bufs[t]`, and `tail` for module `main_mod`), row `n + t` its instance shards
// (chunks `inst[t]` of `bufs[n]`, and the data heads `ih[t]`). Every row is independent: on up to
// XD_WORKERS workers (one when `jobs` is 1), each taking the largest unassigned row while it has the
// fewest bytes.
fn xd_rows(
    xd: &XDecls,
    tu: &Vector<Vector<u32>>,
    inst: &Vector<Vector<u32>>,
    bufs: &Vector<String>,
    off: &Vector<u32>,
    end: &Vector<u32>,
    ih: &Vector<String>,
    main_mod: usize,
    tail: str,
    jobs: u32,
    out: &mut Vector<Vector<u32>>,
) {
    let n = tu.len();
    out.resize_default(2 * n);
    let nw = pick(jobs == 1, 1, XD_WORKERS.min(jobs as usize));
    // Rows by bytes, largest first, dealt to the least loaded worker: `rows` holds each worker's
    // rows in turn, from `at[w]`.
    let mut size = Vector::<u64>::with_capacity(2 * n);
    for r in 0..2 * n {
        let cks = if r < n {
            tu.at(r);
        } else {
            inst.at(r - n);
        };
        let mut b: u64 = pick(r < n, 0, ih.at(r % n).len() as u64);
        for k in 0..cks.len() {
            b += end[cks[k] as usize] - off[cks[k] as usize];
        }
        size.push(b);
    }
    let mut ord = Vector::<ModuleId>::with_capacity(2 * n);
    for r in 0..2 * n {
        ord.push(r as ModuleId);
    }
    sort_big_first(&mut ord, &size);
    let mut load = Vector::<u64>::new();
    load.resize_default(nw);
    let mut cnt = Vector::<usize>::new();
    cnt.resize_default(nw + 1);
    let mut wof = Vector::<u32>::with_capacity(2 * n);
    for k in 0..ord.len() {
        let mut w: usize = 0;
        for v in 1..nw {
            if load[v] < load[w] {
                w = v;
            }
        }
        load.set(w, load[w] + size[ord[k] as usize]);
        cnt.set(w + 1, cnt[w + 1] + 1);
        wof.push(w as u32);
    }
    for w in 0..nw {
        cnt.set(w + 1, cnt[w + 1] + cnt[w]);
    }
    let mut rows = Vector::<u32>::new();
    rows.resize_default(2 * n);
    let mut at = cnt.clone();
    for k in 0..ord.len() {
        let w = wof[k] as usize;
        rows.set(at[w], ord[k]);
        at.set(w, at[w] + 1);
    }
    let t0 = XdTask {
        xd: xd,
        tu: tu,
        inst: inst,
        bufs: bufs,
        off: off,
        end: end,
        ih: ih,
        main_mod: main_mod,
        tail: tail.ptr(),
        tail_len: tail.len(),
        out: out.index_mut(0),
        rows: rows.as_ptr(),
        n: n,
        lo: 0,
        hi: 2 * n,
    };
    if nw == 1 {
        xd_range(t0);
        return;
    }
    let wg = psync::WaitGroup::new();
    for w in 0..nw {
        let mut t = t0;
        t.lo = cnt[w];
        t.hi = cnt[w + 1];
        wg.add(1);
        let wgc = wg.clone();
        launch || {
            xd_range(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    prt::shutdown();
}

// The name declaration `dl` (one C declaration of a prototype header) declares: a typedef's last
// identifier; a function's, the first identifier a `(` follows but an attribute's, or a parenthesized
// `(name)(` one; a pointer object's, the one after `(*`; another object's (`extern`), the last
// identifier before `[`, `=` or `;` outside parentheses.
const fn decl_name(dl: str) str {
    let n = dl.len();
    let mut i: usize = 0;
    if dl.starts_with("typedef ") {
        let mut e = n;
        while e > 0 && dl.byte_at(e - 1) != b';' {
            e -= 1;
        }
        let mut s = e - 1;
        while s > 0 && c_ident_byte(dl.byte_at(s - 1)) {
            s -= 1;
        }
        return dl.slice(s, e - 1);
    }
    // An object declaration (`extern _Alignas(64) float A[16];`) is no function.
    let obj = dl.starts_with("extern ");
    let mut last = dl.slice(0, 0);
    while i < n {
        let c = dl.byte_at(i);
        if c == b'[' || c == b'=' || c == b';' {
            break;
        }
        if c == b'(' && i + 1 < n && dl.byte_at(i + 1) == b'*' {
            let mut j = i + 2;
            while j < n && (dl.byte_at(j) == b' ' || dl.byte_at(j) == b'*') {
                j += 1;
            }
            let s = j;
            while j < n && c_ident_byte(dl.byte_at(j)) {
                j += 1;
            }
            if j > s && j < n && dl.byte_at(j) == b')' {
                return dl.slice(s, j);
            }
        }
        if c == b'(' && !obj {
            // An `@export` function's parenthesized declarator name (`CEmit::decl_name`): `(name)(`.
            let mut j = i + 1;
            while j < n && c_ident_byte(dl.byte_at(j)) {
                j += 1;
            }
            if j > i + 1 && j + 1 < n && dl.byte_at(j) == b')' && dl.byte_at(j + 1) == b'(' {
                return dl.slice(i + 1, j);
            }
        }
        if !c_ident_byte(c) {
            i += 1;
            continue;
        }
        let s = i;
        while i < n && c_ident_byte(dl.byte_at(i)) {
            i += 1;
        }
        let id = dl.slice(s, i);
        if i < n && dl.byte_at(i) == b'(' {
            if obj || id == "__attribute__" {
                // Skip the parenthesized arguments of an attribute (or of an object's `_Alignas`).
                let mut depth: i32 = 0;
                while i < n {
                    let c2 = dl.byte_at(i);
                    i += 1;
                    if c2 == b'(' {
                        depth += 1;
                    } else if c2 == b')' {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                }
                continue;
            }
            return id;
        }
        last = id;
    }
    return last;
}

/// The type-need log (`Mangler::tn_key`) grouped by row: row `r`'s keys are
/// `key[off[r]..off[r + 1]]`, in log order.
struct TnRows {
    pub(package) off: Vector<u32>,
    pub(package) key: Vector<u64>,
}

extend TnRows {
    // Group the log of `mg` into `nrows` rows (a counting sort: one pass to count, one to place).
    fn new(mg: &mbe::Mangler, nrows: usize) TnRows {
        let mut off = Vector::<u32>::new();
        off.resize_default(nrows + 1);
        for i in 0..mg.tn_row.len() {
            let r = mg.tn_row[i] as usize + 1;
            off.set(r, off[r] + 1);
        }
        for r in 0..nrows {
            off.set(r + 1, off[r + 1] + off[r]);
        }
        let mut at = off.clone();
        let mut key = Vector::<u64>::new();
        key.resize_default(mg.tn_key.len());
        for i in 0..mg.tn_key.len() {
            let r = mg.tn_row[i] as usize;
            key.set(at[r] as usize, mg.tn_key[i]);
            at.set(r, at[r] + 1);
        }
        return TnRows { off: off, key: key };
    }
}

// Append each prototype line of `text` to `unit` when it needs a definition header
// (`FwdDecls::scan_def`: an array declarator's element, a scoped extern header's alias), else to
// `fwd`. A unit that calls one declares it (`XDecls`) after the headers it needs (`unit_incs`).
fn split_protos(
    text: str,
    fd: &mut FwdDecls,
    incd: &mut Vector<u8>,
    deps: &mut Vector<u32>,
    fwd: &mut String,
    unit: &mut String,
) {
    let mut a: usize = 0;
    while a < text.len() {
        let mut b = a;
        while text.byte_at(b) != 10 {
            b += 1;
        }
        let line = text.slice(a, b + 1);
        deps.clear();
        fd.scan_def(line, NO_HOME, 0, incd, deps);
        for k in 0..deps.len() {
            incd.set(deps[k] as usize, 0);
        }
        if deps.len() == 0 {
            fwd.push_str(line);
        } else {
            // A unit declaration (`XDecls`) keys a function by its name: `decl_name` reads an
            // `extern` line as an object's, and C needs no `extern` on a prototype.
            unit.push_str(
                if line.starts_with("extern ") {
                    line.slice(7, line.len());
                } else {
                    line;
                },
            );
        }
        a = b + 1;
    }
}

// `#include "<../ x depth>__sc_t/<stem>.h"`: a definition header seen from depth `depth`.
fn def_inc(depth: u32, stem: str, out: &mut String) {
    out.push_str("#include \"");
    for _d in 0..depth {
        out.push_str("../");
    }
    out.push_str("__sc_t/");
    out.push_str(stem);
    out.push_str(".h\"\n");
}

// The include guard of definition header `stem`.
fn def_guard(stem: str, out: &mut String) {
    out.push_str("#ifndef SC_D_");
    out.push_str(stem);
    out.push_str("\n#define SC_D_");
    out.push_str(stem);
    out.push_str("\n");
}

// The name a `struct NAME {` definition (an environment struct body) defines.
// Move every request of `src` whose name is not in `seen` to `out`.
fn wrap_collect(src: &mut Vector<mbe::WrapReq>, seen: &mut Set<u64>, out: &mut Vector<mbe::WrapReq>) {
    for i in 0..src.len() {
        if !seen.contains(&src[i].h) {
            seen.insert(src[i].h);
            out.push(replace(src.index_mut(i), mbe::WrapReq { h: 0, elem: String::new(), body: String::new() }));
        }
    }
}

// Wrapper requests by element name, then by definition (which starts with the wrapper's name).
const fn wrap_req_cmp(a: &mbe::WrapReq, b: &mbe::WrapReq) i32 {
    let c = str_cmp(a.elem.as_str(), b.elem.as_str());
    if c != 0 {
        return c;
    }
    return str_cmp(a.body.as_str(), b.body.as_str());
}

// The typedef line of struct `nm`.
fn wrap_typedef(nm: str, out: &mut String) {
    out.push_str("typedef struct ");
    out.push_str(nm);
    out.push_str(" ");
    out.push_str(nm);
    out.push_str(";\n");
}

const fn struct_def_name(body: str) str {
    let mut e: usize = 7;
    while body.byte_at(e) != b' ' {
        e += 1;
    }
    return body.slice(7, e);
}

// The class of each byte for the C text scans: C_IDENT for a byte of a C identifier (or of a number,
// which never names a declaration), C_OPEN for a quote or a slash, which can start a literal or a
// comment (`c_skip`), 0 for any other. One load per byte instead of a chain of compares.
const C_IDENT: u8 = 1;
const C_OPEN: u8 = 2;
const C_CLASS: [u8; 256] = c_classes();

const fn c_classes() [u8; 256] {
    let mut t = [0u8; 256];
    for i in 0..256usize {
        let c = i as u8;
        // `i` stays below the 256 entries.
        if c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_' {
            unsafe {
                t[i] = C_IDENT;
            }
        } else if c == b'"' || c == b'\'' || c == b'/' {
            unsafe {
                t[i] = C_OPEN;
            }
        }
    }
    return t;
}

// The C_CLASS entry of `c`: a byte indexes the 256 entries in bounds.
const fn c_class(c: u8) u8 {
    return unsafe C_CLASS[c as usize];
}

// True for a byte of a C identifier (or of a number, which never names a declaration).
const fn c_ident_byte(c: u8) bool {
    return c_class(c) == C_IDENT;
}

// The index past the byte at `i` of C text `text`, or past the string or character literal or the comment
// that starts there: the declaration scans read the identifiers of code only (a word of a message is no use).
const fn c_skip(text: str, i: usize) usize {
    let n = text.len();
    let c = text.byte_at(i);
    if c == b'"' || c == b'\'' {
        let mut j = i + 1;
        while j < n && text.byte_at(j) != c {
            j += pick(text.byte_at(j) == b'\\', 2, 1);
        }
        return pick(j < n, j + 1, n);
    }
    if c == b'/' && i + 1 < n && text.byte_at(i + 1) == b'*' {
        let mut j = i + 2;
        while j + 1 < n && !(text.byte_at(j) == b'*' && text.byte_at(j + 1) == b'/') {
            j += 1;
        }
        return pick(j + 1 < n, j + 2, n);
    }
    if c == b'/' && i + 1 < n && text.byte_at(i + 1) == b'/' {
        let mut j = i + 2;
        while j < n && text.byte_at(j) != b'\n' {
            j += 1;
        }
        return j;
    }
    return i + 1;
}

// Whether the declarator at `j` of `text` (right after a type name) declares an array of that type
// (`x[2]`, `(*p)[2]`, `[2]`, `x[1][2]`, also after a `const`): C rejects an array declarator over an
// incomplete type.
const fn arr_declarator(text: str, j0: usize) bool {
    let n = text.len();
    let mut j = j0;
    // A `const` after the type name qualifies the element (`S const x[2]`, an array parameter).
    while j + 6 <= n && text.slice(j, j + 5) == "const" && text.byte_at(j + 5) == b' ' {
        j += 6;
        while j < n && text.byte_at(j) == b' ' {
            j += 1;
        }
    }
    if j < n && text.byte_at(j) == b'(' {
        let mut depth: u32 = 0;
        while j < n {
            let c = text.byte_at(j);
            j += 1;
            if c == b'(' {
                depth += 1;
            } else if c == b')' {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
        }
    } else {
        while j < n && c_ident_byte(text.byte_at(j)) {
            j += 1;
        }
    }
    while j < n && text.byte_at(j) == b' ' {
        j += 1;
    }
    return j < n && text.byte_at(j) == b'[';
}

// The name a `typedef struct|union NAME NAME;` line declares.
const fn typedef_name(line: str) str {
    let e = line.len() - 2;
    let mut b = e;
    while b > 0 && line.byte_at(b - 1) != b' ' {
        b -= 1;
    }
    return line.slice(b, e);
}

/// Text entries with one owner module each: `end[i]` closes entry i (it starts at `end[i-1]`).
struct Segs {
    pub(package) txt: String,
    pub(package) own: Vector<ModuleId>,
    pub(package) end: Vector<u32>,
}

extend Segs {
    fn new() Segs {
        return Segs { txt: String::new(), own: Vector::<ModuleId>::new(), end: Vector::<u32>::new() };
    }

    // Close the text appended since the last entry as one entry owned by `own` (none when empty).
    fn close(self: &mut Self, own: ModuleId) {
        if self.txt.len() as u32 != cap_pe(&self.end, self.end.len() as u32) {
            self.own.push(own);
            self.end.push(self.txt.len() as u32);
        }
    }

    // An empty segment, which `close` would not record.
    fn push_empty(self: &mut Self, own: ModuleId) {
        self.own.push(own);
        self.end.push(self.txt.len() as u32);
    }

    const fn at(self: &Self, i: usize) str {
        return self.txt.as_str().slice(cap_pe(&self.end, i as u32) as usize, self.end[i] as usize);
    }
}

/// A module with its size and its position before sorting (the tie break).
struct SizePos {
    pub(package) size: u64,
    pub(package) pos: u32,
    pub(package) m: ModuleId,
}

const fn size_pos_cmp(a: &SizePos, b: &SizePos) i32 {
    if a.size != b.size {
        return pick(a.size > b.size, -1, 1);
    }
    return a.pos as i32 - b.pos as i32;
}

// Order modules `idx` by `size` descending, ties in their current order.
fn sort_big_first(idx: &mut Vector<ModuleId>, size: &Vector<u64>) {
    let mut kv = Vector::<SizePos>::with_capacity(idx.len());
    for i in 0..idx.len() {
        kv.push(SizePos { size: size[idx[i] as usize], pos: i as u32, m: idx[i] });
    }
    kv.sort_by(size_pos_cmp);
    for i in 0..idx.len() {
        idx.set(i, kv[i].m);
    }
}

/// A sort key with the index it orders (module paths, registry roots).
struct KeyIdx<'a> {
    pub(package) key: str<'a>,
    pub(package) idx: u32,
}

const fn key_idx_cmp(a: &KeyIdx, b: &KeyIdx) i32 {
    return str_cmp(a.key, b.key);
}

// Byte-wise order of two names (a stable key for headers, shards and registry roots).
const fn str_cmp(a: str, b: str) i32 {
    let n = if a.len() < b.len() {
        a.len();
    } else {
        b.len();
    };
    for i in 0..n {
        if a.byte_at(i) != b.byte_at(i) {
            return a.byte_at(i) as i32 - b.byte_at(i) as i32;
        }
    }
    return a.len() as i32 - b.len() as i32;
}

// The directory depth of module `mod_path` in the output tree (one level per `::`).
const fn mod_depth(mod_path: str) u32 {
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
    return depth;
}

// `#include "<../ x depth><module path as a directory path><suffix>"`.
fn inc_line(depth: u32, mod_path: str, suffix: str, out: &mut String) {
    out.push_str("#include \"");
    for _d in 0..depth {
        out.push_str("../");
    }
    let n = mod_path.len();
    let mut i: usize = 0;
    while i < n {
        if mod_path.byte_at(i) == b':' && i + 1 < n && mod_path.byte_at(i + 1) == b':' {
            out.push_byte(b'/');
            i += 2;
        } else {
            out.push_byte(mod_path.byte_at(i));
            i += 1;
        }
    }
    out.push_str(suffix);
    out.push_str("\"\n");
}

// The include guard of a generated header: `#ifndef <pfx><module path, `::` as `__`>`.
fn hdr_open(pfx: str, mod_path: str, out: &mut String) {
    let mut g = String::from_str(pfx);
    for i in 0..mod_path.len() {
        let c = mod_path.byte_at(i);
        let idc = c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9';
        g.push_byte(pick(idc, c, b'_'));
    }
    out.push_str("#ifndef ");
    out.push_string(&g);
    out.push_str("\n#define ");
    out.push_string(&g);
    out.push_str("\n");
}

// The stable item hash of a prototype line: FNV-1a of the identifier before its first `(`.
const fn item_hash(pl: str) u64 {
    let mut e: usize = 0;
    while e < pl.len() && pl.byte_at(e) != b'(' {
        e += 1;
    }
    let mut s = e;
    while s > 0 {
        let c = pl.byte_at(s - 1);
        let idc = c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_';
        if !idc {
            break;
        }
        s -= 1;
    }
    return fnv(pl.slice(s, e));
}

// Module `m`'s shard count under the policy: its TU shards, or its instance shards (`inst`).
// The manifest's `[shards]` / `[instance-shards]` count for module `m`, or 0 when the manifest
// names none: the compiler then decides from the rendered size (`shard_policy`).
const fn shard_rule(p: &loader::Package, m: usize, inst: bool) u32 {
    for i in 0..p.shard_rules.len() {
        if p.shard_rules.at(i).module.as_str() == p.modules[m].path.as_str() {
            return if inst {
                p.shard_rules.at(i).insts;
            } else {
                p.shard_rules.at(i).tus;
            };
        }
    }
    return 0;
}

/// Bytes of C per shard the policy aims at (the most shards one module may have is `SHARD_MAX`).
const SHARD_TARGET: usize = 262144;

/// The shard count for a module that rendered `bytes` of C: one shard per target size. A count
/// is an output schema (changing it rewrites every shard of the module), so when the previous
/// build's count `prev` is known (0 = unknown) it stays while it keeps every shard within half
/// and one and a half times the target.
const fn shard_policy(bytes: usize, prev: u32) u32 {
    if prev != 0 {
        let per = bytes / prev as usize;
        if per < SHARD_TARGET + SHARD_TARGET / 2 && (prev == 1 || per >= SHARD_TARGET / 2) {
            return prev;
        }
    }
    let want = ((bytes + SHARD_TARGET - 1) / SHARD_TARGET) as u32;
    if want < 1 {
        return 1;
    }
    if want > SHARD_MAX {
        return SHARD_MAX;
    }
    return want;
}

/// A unit of less than this many bytes of C compiles in a pack (`pack_plan`).
const PACK_UNIT: usize = SHARD_TARGET / 4;

/// The fewest units of a tree that compile `__sc_fwd.h` through its precompiled header: the header's
/// compile costs about three units' parse of it.
const PCH_UNITS: usize = 4;

// The packs of a program's units (`__sc_unity.c`, `__sc_pack<k>.c`, each including its member units):
// per module, the pack of its TU and of its instance unit in `tu_pk` and `in_pk` (1 + the pack's index;
// 0: the unit compiles alone), the registry's in `reg_pk`; returns the pack count. A small program
// (`unity`) compiles every unit in one pack, `__sc_unity.c`. Else every unit of one shard and less than
// PACK_UNIT bytes (`lm` its modules, `iq` its instance owners, `tsz` and `isz` their bytes) joins a pack
// of about SHARD_TARGET bytes: a header those units share is parsed once per pack. The count is a
// shard count of all such bytes (`shard_policy`, from `prev`, the previous build's), and a unit's pack
// is the hash of its file stem modulo the count: an edit, or a unit that crosses the limit, changes
// its own pack only. A unit that includes a scoped extern header (`tu_x`, `inst_x`, `reg_x`) compiles alone. Fewer than two
// such units, or `alone` (SC_UNITY_MAX=0): every unit compiles alone.
fn pack_plan(
    p: &loader::Package,
    co: &CemitOut,
    lm: &Vector<ModuleId>,
    iq: &Vector<ModuleId>,
    tsz: &Vector<u64>,
    isz: &Vector<u64>,
    unity: bool,
    alone: bool,
    prev: u32,
    tu_pk: &mut Vector<u32>,
    in_pk: &mut Vector<u32>,
    reg_pk: &mut u32,
) u32 {
    let n = p.modules.len();
    tu_pk.resize_default(n);
    in_pk.resize_default(n);
    if !unity && alone {
        return 0;
    }
    // A registry that includes a scoped extern header compiles alone: the header's declarations would
    // meet the names of the members before it (`typedef unsigned char byte` of <windows.h>).
    let small_reg = co.registry_c.len() != 0 && !co.reg_x && pack_small(unity, 1, co.registry_c.len() as u64);
    let mut bytes: u64 = pick(small_reg, co.registry_c.len() as u64, 0);
    let mut units: usize = small_reg as usize;
    for k in 0..lm.len() {
        let t = lm[k] as usize;
        let s9 = pack_small(unity, co.tu_heads.at(t).len(), tsz[t]) && !co.tu_x[t];
        bytes += pick(s9, tsz[t], 0);
        units += s9 as usize;
    }
    for k in 0..iq.len() {
        let q = iq[k] as usize;
        let s9 = pack_small(unity, co.inst_heads.at(q).len(), isz[q]) && !co.inst_x[q];
        bytes += pick(s9, isz[q], 0);
        units += s9 as usize;
    }
    if units < 2 {
        return 0;
    }
    let np = if unity {
        1u32;
    } else {
        shard_policy(bytes as usize, prev);
    };
    for k in 0..lm.len() {
        let t = lm[k] as usize;
        if pack_small(unity, co.tu_heads.at(t).len(), tsz[t]) && !co.tu_x[t] {
            tu_pk.set(t, (fnv(p.modules[t].path.as_str()) % np as u64) as u32 + 1);
        }
    }
    for k in 0..iq.len() {
        let q = iq[k] as usize;
        if pack_small(unity, co.inst_heads.at(q).len(), isz[q]) && !co.inst_x[q] {
            in_pk.set(q, (fnv(format("{}__inst", p.modules[q].path.as_str()).as_str()) % np as u64) as u32 + 1);
        }
    }
    if small_reg {
        *reg_pk = (fnv("__sc_registry") % np as u64) as u32 + 1;
    }
    return np;
}

// Per definition header (`ddeps` its includes): whether it includes a scoped extern header (the
// first `nx`), directly or through another. The includes are acyclic, so each pass settles at least
// the headers one include deeper: at most one pass per header, and one more to see no change.
fn x_reach(nx: u32, ddeps: &Vector<Vector<u32>>) Vector<bool> {
    let nd = ddeps.len();
    let mut r = Vector::<bool>::new();
    r.resize_default(nd);
    for d in 0..nx as usize {
        r.set(d, true);
    }
    for _pass in 0..nd + 1 {
        let mut changed = false;
        for d in 0..nd {
            if !r[d] && x_any(&r, &ddeps[d]) {
                r.set(d, true);
                changed = true;
            }
        }
        if !changed {
            return r;
        }
    }
    panic("the definition headers include each other in a cycle");
}

// Per definition header: whether a unit (`tu_dv`, `inst_dv`: per module, the headers its TU and its
// instance unit include) includes it, directly or through another.
fn unit_reach(nd: usize, ddeps: &Vector<Vector<u32>>, tu_dv: &Vector<Vector<u32>>, inst_dv: &Vector<Vector<u32>>) Vector<
    bool
> {
    let mut seen = Vector::<bool>::new();
    seen.resize_default(nd);
    let mut stack = Vector::<u32>::new();
    for dv in [tu_dv, inst_dv] {
        for t in 0..dv.len() {
            for k in 0..dv[t].len() {
                let d = dv[t][k];
                if !seen[d as usize] {
                    seen.set(d as usize, true);
                    stack.push(d);
                }
            }
        }
    }
    // Each header enters the stack once: at most `nd` pops.
    while let Some(d) = stack.pop() {
        for k in 0..ddeps[d as usize].len() {
            let x = ddeps[d as usize][k];
            if !seen[x as usize] {
                seen.set(x as usize, true);
                stack.push(x);
            }
        }
    }
    return seen;
}

// Whether one of definition headers `ds` reaches a scoped extern header (`x_reach`).
const fn x_any(r: &Vector<bool>, ds: &Vector<u32>) bool {
    for k in 0..ds.len() {
        if r[ds[k] as usize] {
            return true;
        }
    }
    return false;
}

// Whether a unit of `nsh` shards and `bytes` bytes of C joins a pack (`pack_plan`).
const fn pack_small(unity: bool, nsh: usize, bytes: u64) bool {
    return unity || nsh == 1 && bytes < PACK_UNIT as u64;
}

// Unit `path` (below `root`) joins pack `pk` (`pack_plan`; 0: none).
fn pack_join(packs: &mut Vector<String>, members: &mut Vector<String>, root: str, path: &String, pk: u32) {
    if pk != 0 {
        packs.index_mut(pk as usize - 1).format_into(
            "#include \"{}\"\n",
            path.as_str().slice(root.len() + 1, path.len()),
        );
        members.push(path.clone());
    }
}

/// The previous build's pack count from the `packs` line of `<root>/__sc_shards` (`pack_plan`); 0 when
/// it names none.
fn packs_read(root: str) u32 {
    let textv = loader::read_file(build_out_path(root, "__sc_shards", "").as_str());
    if textv.is_none() {
        return 0;
    }
    let text = textv.unwrap();
    for line in text.as_str().lines() {
        if line.starts_with("packs\t") {
            return line.slice(6, line.len()).parse_u64_radix(10).unwrap_or(0) as u32;
        }
    }
    return 0;
}

/// The previous build's shard counts from `<root>/__sc_shards` (one line per module that had
/// more than one shard of either kind: `module<TAB>tus<TAB>insts`), by module index: 1 for a
/// module the file omits, 0 everywhere when there is no file (a fresh tree).
fn shard_meta_read(root: str, p: &loader::Package, tus: &mut Vector<u32>, insts: &mut Vector<u32>) {
    tus.resize_default(p.modules.len());
    insts.resize_default(p.modules.len());
    if root.len() == 0 {
        return;
    }
    let mp = build_out_path(root, "__sc_shards", "");
    let textv = loader::read_file(mp.as_str());
    if textv.is_none() {
        return;
    }
    let text = textv.unwrap();
    for m in 0..p.modules.len() {
        tus.set(m, 1);
        insts.set(m, 1);
    }
    let s = text.as_str();
    let mut i: usize = 0;
    while i < s.len() {
        let mut e = i;
        while e < s.len() && s.byte_at(e) != 10 {
            e += 1;
        }
        let line = s.slice(i, e);
        i = e + 1;
        let t1 = line.find_byte(b'\t');
        if t1 <= 0 {
            continue;
        }
        let rest = line.slice((t1 + 1) as usize, line.len());
        let t2 = rest.find_byte(b'\t');
        if t2 <= 0 {
            continue;
        }
        let a = rest.slice(0, t2 as usize).parse_u64_radix(10);
        let b = rest.slice((t2 + 1) as usize, rest.len()).parse_u64_radix(10);
        if a.is_none() || b.is_none() {
            continue;
        }
        let name = line.slice(0, t1 as usize);
        for m in 0..p.modules.len() {
            if p.modules[m].path.as_str() == name {
                let av: u64 = a.unwrap();
                let bv: u64 = b.unwrap();
                tus.set(m, av as u32);
                insts.set(m, bv as u32);
            }
        }
    }
}

/// The effective shard counts of this build as `__sc_shards` text (the manifest's `shards` lines
/// carry the same counts): a module TU with `k` heads was written in `k` shards.
fn shard_meta_text(p: &loader::Package, co: &CemitOut) String {
    let mut out = String::from_str("super-c-shards\t1\n");
    for m in 0..p.modules.len() {
        let tus = if co.tu_heads.at(m).len() > 1 {
            co.tu_heads.at(m).len();
        } else {
            1usize;
        };
        let insts = if co.inst_heads.at(m).len() > 1 {
            co.inst_heads.at(m).len();
        } else {
            1usize;
        };
        if tus == 1 && insts == 1 {
            continue;
        }
        out.push_str(p.modules[m].path.as_str());
        out.push_byte(b'\t');
        out.push_u64(tus as u64);
        out.push_byte(b'\t');
        out.push_u64(insts as u64);
        out.push_byte(b'\n');
    }
    return out;
}

// The module whose prototype header declares and whose instance shard defines the descriptor
// of `(em, t)`: the type's owner, else `core` (builtins), so every requester agrees.
fn ti_owner(cem: &mut cbe::CEmit, core: ModuleId, em: ModuleId, t: TypeId) ModuleId {
    let od = cem.mg.owner_dep(em, t);
    if od >= 0 {
        return od as ModuleId;
    }
    return core;
}

// The manifest's content hash of an output file's text.
fn out_hash(text: str) u64 {
    return skey_mix(FNV_BASIS, str_id(text));
}

// The text of shard `x` of module `t`'s TU (or of owner `t`'s instance shards, `inst`) into `body`:
// the include prefix, the shard head, its chunks (`sg.ord[sg.off[x]..sg.off[x + 1]]`, in emission
// order), `tail`. A shard past the first with nothing in it has no file: false, `body` untouched.
fn shard_text(co: &CemitOut, t: usize, x: u8, inst: bool, tail: str, sg: &ShardGroups, body: &mut String) bool {
    let head = if inst {
        co.inst_heads.at(t).at(x as usize).as_str();
    } else {
        co.tu_heads.at(t).at(x as usize).as_str();
    };
    let inc = if inst {
        co.inst_incs.at(t).as_str();
    } else {
        co.tu_incs.at(t).as_str();
    };
    let buf = if inst {
        co.inst_c.as_str();
    } else {
        co.tus.at(t).as_str();
    };
    let lo = sg.off[x as usize] as usize;
    let hi = sg.off[x as usize + 1] as usize;
    if x != 0 && head.len() + tail.len() == 0 && lo == hi {
        return false;
    }
    let mut n = inc.len() + head.len() + tail.len();
    for k in lo..hi {
        let i = sg.ord[k] as usize;
        n += (co.ck_end[i] - co.ck_off[i]) as usize;
    }
    body.clear();
    body.reserve(n);
    body.push_str(inc);
    body.push_str(head);
    for k in lo..hi {
        let i = sg.ord[k] as usize;
        body.push_str(buf.slice(co.ck_off[i] as usize, co.ck_end[i] as usize));
    }
    body.push_str(tail);
    return true;
}

/// A module's chunks grouped by shard, each group in emission order: shard x's chunk indexes are
/// `ord[off[x]..off[x + 1]]`.
struct ShardGroups {
    pub(package) off: Vector<u32>,
    pub(package) ord: Vector<u32>,
}

extend ShardGroups {
    fn new() ShardGroups {
        return ShardGroups { off: Vector::<u32>::new(), ord: Vector::<u32>::new() };
    }

    // Group chunks `cks` over `nsh` shards (a counting sort: one pass to count, one to place;
    // placing advances `off[x + 1]` from shard x's start to its end, which is shard x + 1's start).
    fn fill(self: &mut Self, ck_shard: &Vector<u8>, cks: &Vector<u32>, nsh: usize) {
        self.off.clear();
        self.off.resize_default(nsh + 2);
        for k in 0..cks.len() {
            let x = ck_shard[cks[k] as usize] as usize + 2;
            self.off.set(x, self.off[x] + 1);
        }
        for x in 2..nsh + 1 {
            self.off.set(x, self.off[x] + self.off[x - 1]);
        }
        self.ord.clear();
        self.ord.resize_default(cks.len());
        for k in 0..cks.len() {
            let x = ck_shard[cks[k] as usize] as usize + 1;
            self.ord.set(self.off[x] as usize, cks[k]);
            self.off.set(x, self.off[x] + 1);
        }
    }
}

// One manifest record: kind, root-relative path, content hash, owner module (0xFFFF = none),
// shard index, the generated headers `text` includes (root-relative), then `extra`.
fn man_line(man: &mut String, kind: str, root: str, path: str, h: u64, own: u32, shard: u32, text: str, extra: str) {
    man.push_str(kind);
    man.push_str("\t");
    man.push_str(path.slice(root.len() + 1, path.len()));
    man.push_str("\t");
    man.push_hex(h, false);
    man.push_str("\t");
    if own == 0xFFFF {
        man.push_str("-");
    } else {
        man.push_u64(own);
    }
    man.push_str("\t");
    man.push_u64(shard);
    man.push_str("\t");
    let n = text.len();
    let mut i: usize = 0;
    let mut first = true;
    while i + 10 < n {
        if (i == 0 || text.byte_at(i - 1) == 10) && text.slice(i, i + 10) == "#include \"" {
            let mut a = i + 10;
            while a + 3 <= n && text.slice(a, a + 3) == "../" {
                a += 3;
            }
            let mut e = a;
            while e < n && text.byte_at(e) != b'"' && text.byte_at(e) != 10 {
                e += 1;
            }
            if e > a && text.byte_at(a) != b'/' {
                if !first {
                    man.push_str(" ");
                }
                first = false;
                man.push_str(text.slice(a, e));
            }
            i = e;
        } else {
            i += 1;
        }
    }
    if extra.len() != 0 {
        man.push_str("\t");
        man.push_str(extra);
    }
    man.push_str("\n");
}

// Publish `__sc_manifest` atomically (temporary + rename). A shard count that differs from the
// previous manifest's is a schema migration: name it, so the full-module rewrite it causes is
// never mistaken for an ordinary edit.
/// The math functions a C compiler would replace with its builtins: they compile as written, so the C
/// program computes what the native one does.
const LIBM_AS_WRITTEN: str<'static> = " -fno-builtin-sin -fno-builtin-cos -fno-builtin-tan -fno-builtin-asin -fno-builtin-acos -fno-builtin-atan -fno-builtin-atan2 -fno-builtin-sinh -fno-builtin-cosh -fno-builtin-tanh -fno-builtin-asinh -fno-builtin-acosh -fno-builtin-atanh -fno-builtin-exp -fno-builtin-exp2 -fno-builtin-expm1 -fno-builtin-log -fno-builtin-log2 -fno-builtin-log10 -fno-builtin-log1p -fno-builtin-pow -fno-builtin-cbrt -fno-builtin-hypot -fno-builtin-sinf -fno-builtin-cosf -fno-builtin-tanf -fno-builtin-asinf -fno-builtin-acosf -fno-builtin-atanf -fno-builtin-atan2f -fno-builtin-sinhf -fno-builtin-coshf -fno-builtin-tanhf -fno-builtin-asinhf -fno-builtin-acoshf -fno-builtin-atanhf -fno-builtin-expf -fno-builtin-exp2f -fno-builtin-expm1f -fno-builtin-logf -fno-builtin-log2f -fno-builtin-log10f -fno-builtin-log1pf -fno-builtin-powf -fno-builtin-cbrtf -fno-builtin-hypotf";

/// What a C compiler needs to build the C tree at `root` (`--emit-c`): `__units`, the units to compile
/// (one tree-relative path per line; the members of the packs `members` are not units), `__cflags`, the
/// flags of every compile (the dialect and the target's defines, the target and its CPU features, the
/// profile's optimization, debug information and overflow wrapping), and the target's link flags after
/// the `@link` flags in `__ldflags`, one per line. The written paths join `keep`; false when a write
/// fails.
fn c_build_files(p: &loader::Package, root: str, members: &Vector<String>, keep: &mut Vector<String>, target: i32) bool {
    let mut ms = Set::<String>::new();
    for i in 0..members.len() {
        ms.insert(members.at(i).clone());
    }
    let mut units = String::new();
    for i in 0..keep.len() {
        let f = keep.at(i).as_str();
        if f.ends_with(".c") && !ms.contains(keep.at(i)) {
            units.push_str(f.slice(root.len() + 1, f.len()));
            units.push_byte(b'\n');
        }
    }
    let mut fl = String::new();
    push_c_env(&mut fl, target);
    // gcc 14 rejects incompatible pointer arguments; clang only warns. One rule on every compiler.
    fl.push_str(" -ffp-contract=off -Werror=incompatible-pointer-types");
    fl.push_str(LIBM_AS_WRITTEN);
    if p.pic {
        fl.push_str(" -fPIC");
    }
    push_sdk_flags(&mut fl, target, p.arch, p.features);
    if p.opt == bman::OPT_S {
        fl.push_str(" -Os");
    } else if p.opt == bman::OPT_Z {
        fl.push_str(" -Oz");
    } else if p.opt >= 0 {
        fl.format_into(" -O{}", p.opt);
    }
    if p.debug_info {
        fl.push_str(" -g");
    }
    if (p.build_cfg >> (BC_OVERFLOW_CHECKS - BC_LOCKDEP) as u32 & 1u32) != 0 {
        fl.push_str(" -DSC_ARITH_WRAP");
    }
    fl.push_byte(b'\n');
    let lp = build_out_path(root, "__ldflags", "");
    let mut ld = loader::read_file(lp.as_str()).unwrap_or(String::new());
    let mut lw = Vector::<String>::new();
    split_args(&mut lw, tgt::os(target).exe_link);
    for i in 0..lw.len() {
        ld.format_into("{}\n", lw.at(i).as_str());
    }
    let up = build_out_path(root, "__units", "");
    let fp = build_out_path(root, "__cflags", "");
    if !write_file_atomic(up.as_str(), units.as_str()) || !write_file_atomic(fp.as_str(), fl.as_str()) || ld.len() != 0 && !write_file_atomic(
        lp.as_str(),
        ld.as_str(),
    ) {
        eprintln("super-c: cannot write the C build files under '{}'", root);
        return false;
    }
    keep.push(up);
    keep.push(fp);
    return true;
}

fn manifest_publish(root: str, man: &String, keep: &mut Vector<String>) {
    let mp = build_out_path(root, "__sc_manifest", "");
    switch loader::read_file(mp.as_str()) {
        Some(old) => {
            let os = old.as_str();
            let ns = man.as_str();
            let mut i: usize = 0;
            while i < os.len() {
                let mut e = i;
                while e < os.len() && os.byte_at(e) != 10 {
                    e += 1;
                }
                let line = os.slice(i, e);
                if line.len() > 7 && line.slice(0, 7) == "shards\t" {
                    let mut t2 = line.len();
                    let mut tabs = 0;
                    for k in 0..line.len() {
                        if line.byte_at(k) == b'\t' {
                            tabs += 1;
                            if tabs == 2 {
                                t2 = k + 1;
                            }
                        }
                    }
                    let mut pat = String::from_str("\n");
                    pat.push_str(line.slice(0, t2));
                    let mut full = String::from_str("\n");
                    full.push_str(line);
                    full.push_str("\n");
                    if ns.contains(pat.as_str()) && !ns.contains(full.as_str()) {
                        eprint(
                            "super-c: shard policy migration for {}: every shard of the module is rewritten\n",
                            line.slice(7, t2 - 1),
                        );
                    }
                }
                i = e + 1;
            }
        },
        None => {},
    };
    if write_file_atomic(mp.as_str(), man.as_str()) {
        keep.push(mp);
    }
}

// Whether `w` is a word of space-separated list `list`.
const fn word_in(list: str, w: str) bool {
    let mut rest = list;
    for _ in 0..list.len() + 1 {
        let sp = rest.find_byte(b' ');
        let item = if sp < 0 {
            rest;
        } else {
            rest.slice(0, sp as usize);
        };
        if item == w {
            return true;
        }
        if sp < 0 {
            return false;
        }
        rest = rest.slice(sp as usize + 1, rest.len());
    }
    return false;
}

// Every module's line starts (`Package.lines`), which the parallel LIR lowerings share.
fn lir_lines(p: &mut loader::Package) {
    p.lines.truncate(0);
    for m in 0..p.modules.len() {
        let src = p.modules[m].source.as_str();
        let mut ls = Vector::<u32>::with_capacity(src.len() / 32 + 1);
        ls.push(0);
        let mut at: usize = 0;
        // Each step passes one newline: at most one step per byte.
        for _ in 0..src.len() {
            let f = (unsafe memchr(src.ptr() + at, b'\n', src.len() - at)) as *const u8;
            if f == null {
                break;
            }
            at = f as usize - src.ptr() as usize + 1;
            ls.push(at as u32);
        }
        p.lines.push(ls);
    }
}

// The C facts of every extern block with a header a native build's objects need, the headers of each
// module read once, in its C unit's order, under the target's C environment: the values of its integer
// constants (`Package.extern_ints`), the `extern` objects its other constants name (`Package.extern_objs`),
// and its functions that only a C compile defines (`Package.c_fns`): every one of an intrinsics header, else
// the header's `static` ones. A constant the header defines as neither stays without one, and the modules
// that read it do not compile. Each `@layout` type's size
// and alignment must be the header's, each `@value` type's size too and its alignment at least the
// header's (`check_type`); each constant with a value must have it in the header (`check_const`), each
// header struct, union and enum the header's layout and values (`check_agg`), and each function the
// header's prototype (`check_fn`): an error else. Without a C environment (no sysroot) a header has no
// facts.
fn native_header_facts(p: &mut loader::Package) {
    let intr = tgt::isa(p.arch).intrinsics;
    // One scan per module's set of headers: the `#include` lines of every header its extern blocks name, in
    // their order, as its C unit includes them (`psapi.h` reads `windows.h`'s types). Per group, the names
    // the scan looks up, each with its item and the header its block names as the source spells it.
    let mut heads = Map::<String, u32>::new();
    let mut hincs = Vector::<String>::new();
    let mut names = Vector::<Vector<String>>::new();
    let mut keys = Vector::<Vector<u64>>::new();
    let mut nsp = Vector::<Vector<String>>::new();
    let mut fnames = Vector::<Vector<String>>::new();
    let mut fkeys = Vector::<Vector<u64>>::new();
    let mut fsp = Vector::<Vector<String>>::new();
    let mut tnames = Vector::<Vector<String>>::new();
    let mut tkeys = Vector::<Vector<u64>>::new();
    let mut tsp = Vector::<Vector<String>>::new();
    // Per type of `tnames`: its `@layout` (`exact`) or `@value` size << 32 | alignment.
    let mut texp = Vector::<Vector<(bool, u64)>>::new();
    // The header structs, unions and enums (their C names and members), and the C types their fields and
    // the functions' parameters and results name.
    let mut anames = Vector::<Vector<String>>::new();
    let mut akeys = Vector::<Vector<u64>>::new();
    let mut asp = Vector::<Vector<String>>::new();
    let mut snames = Vector::<Vector<String>>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let src = p.modules[m].source.as_str();
        let its = a.at_const(a.root).as_data.program.items;
        let mut inc = String::new();
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            let htxt = block_header(a, src, nid);
            if htxt.len() != 0 {
                let line = format("#include {}\n", include_operand(p, m, htxt).as_str());
                if !inc.as_str().contains(line.as_str()) {
                    inc.push_string(&line);
                }
            }
        }
        if inc.len() == 0 {
            continue;
        }
        let hi = (switch heads.get(&inc) {
            Some(k) => *k,
            None => {
                let k = hincs.len() as u32;
                heads.insert(inc.clone(), k);
                hincs.push(inc);
                names.push(Vector::<String>::new());
                keys.push(Vector::<u64>::new());
                nsp.push(Vector::<String>::new());
                fnames.push(Vector::<String>::new());
                fkeys.push(Vector::<u64>::new());
                fsp.push(Vector::<String>::new());
                tnames.push(Vector::<String>::new());
                tkeys.push(Vector::<u64>::new());
                tsp.push(Vector::<String>::new());
                texp.push(Vector::<(bool, u64)>::new());
                anames.push(Vector::<String>::new());
                akeys.push(Vector::<u64>::new());
                asp.push(Vector::<String>::new());
                snames.push(Vector::<String>::new());
                k;
            },
        }) as usize;
        for i in 0..its.len {
            let nid = unsafe a.list(its)[i as usize];
            let htxt = block_header(a, src, nid);
            if htxt.len() == 0 {
                continue;
            }
            let spell = format("\"{}\"", htxt);
            let eb = a.at_const(nid).as_data.extern_block;
            // An intrinsics header's functions are the C compiler's (`target::intrin` expands them); its
            // register types are scanned as any header's.
            let intrinsics = word_in(intr, htxt);
            for j in 0..eb.items.len {
                let sid = unsafe a.list(eb.items)[j as usize];
                let sn = a.at_const(sid);
                let key = m as u64 << 32 | sid as u64;
                if sn.kind == NodeKind::NODE_FUNCTION && intrinsics {
                    p.c_fns.insert(key);
                    continue;
                }
                if sn.kind == NodeKind::NODE_FUNCTION {
                    // The C name (the `@import` pin, else its own), and the C types its signature names.
                    let fd = a.ext(sid).function;
                    fnames.index_mut(hi).push(c_item_name(a, src, sid, fd.name));
                    fkeys.index_mut(hi).push(key);
                    fsp.index_mut(hi).push(spell.clone());
                    for q in 0..fd.params.len {
                        let pid = unsafe a.list(fd.params)[q as usize];
                        let pt = a.type_of(a.at_const(pid).as_data.parameter.ty);
                        if pt != TYPE_NONE {
                            sc_shape_names(p, m as ModuleId, pt, snames.index_mut(hi));
                        }
                    }
                    for q in 0..fd.returns.len {
                        let rt = a.type_of(unsafe a.list(fd.returns)[q as usize]);
                        if rt != TYPE_NONE {
                            sc_shape_names(p, m as ModuleId, rt, snames.index_mut(hi));
                        }
                    }
                    continue;
                }
                if sn.kind == NodeKind::NODE_TYPE_ALIAS && sn.as_data.type_alias.ty == NODE_NONE && (a.attr_of(
                    sid,
                    AttrKind::ATTR_LAYOUT,
                ) != null || a.attr_of(sid, AttrKind::ATTR_C_VALUE) != null) {
                    let ts = a.at_const(sn.as_data.type_alias.name).as_data.name.text;
                    tnames.index_mut(hi).push(String::from_str(src.slice(ts.start as usize, ts.end as usize)));
                    tkeys.index_mut(hi).push(key);
                    tsp.index_mut(hi).push(spell.clone());
                    let exact = a.attr_of(sid, AttrKind::ATTR_LAYOUT) != null;
                    let av = a.attr_value(
                        sid,
                        if exact {
                            AttrKind::ATTR_LAYOUT;
                        } else {
                            AttrKind::ATTR_C_VALUE;
                        },
                    );
                    assert(av.ok, "the checker folds every '@layout' and '@value'");
                    texp.index_mut(hi).push((exact, av.v << 32 | av.w[0]));
                    continue;
                }
                if sn.kind == NodeKind::NODE_STRUCT || sn.kind == NodeKind::NODE_ENUM {
                    // The C type, then `|<member>` per field (`bindgen::agg_facts`).
                    let mut q = String::new();
                    extern_c_raw(p, m as ModuleId, sid, &mut q);
                    let agg = a.ext(sid).aggregate;
                    for f in 0..agg.members.len {
                        let fid = unsafe a.list(agg.members)[f as usize];
                        if a.at_const(fid).kind == NodeKind::NODE_FIELD {
                            q.push_byte(b'|');
                            field_c_name(p, m as ModuleId, fid, &mut q);
                            sc_shape_names(p, m as ModuleId, a.member_ty(fid), snames.index_mut(hi));
                        }
                    }
                    anames.index_mut(hi).push(q);
                    akeys.index_mut(hi).push(key);
                    asp.index_mut(hi).push(spell.clone());
                    continue;
                }
                // A constant whose value the header gives (`is_extern`), or one with a value it must have there.
                let cd = sn.as_data.const_def;
                if sn.kind != NodeKind::NODE_CONST || !(cd.is_extern || cd.c_macro) || cd.is_static_mut {
                    continue;
                }
                names.index_mut(hi).push(c_item_name(a, src, sid, cd.name));
                keys.index_mut(hi).push(key);
                nsp.index_mut(hi).push(spell.clone());
                if cd.ty != NODE_NONE {
                    sc_shape_names(p, m as ModuleId, a.type_of(cd.ty), snames.index_mut(hi));
                }
            }
        }
    }
    // The dialect and macro flags the headers are read under (`push_c_env`), which select what they define,
    // and the sysroot whose headers they are.
    let mut flags = String::new();
    push_c_env(&mut flags, p.build_target);
    let sysroot = p.sysroot.clone();
    // Each header's facts: the record of an earlier build's scan when every file it read is unchanged,
    // else a scan, the headers in parallel.
    let cpath = if p.gen_root.len() != 0 {
        build_out_path(p.gen_root.as_str(), HF_RECORD, "");
    } else {
        String::new();
    };
    let read = loader::read_file(cpath.as_str()).unwrap_or(String::new());
    // A record of another format has no entry for this one.
    let old = if read.as_str().starts_with(HF_FORMAT) {
        read.as_str().slice(HF_FORMAT.len(), read.len());
    } else {
        "";
    };
    let mut tasks = Vector::<HfTask>::new();
    for k in 0..hincs.len() {
        if names.at(k).len() + fnames.at(k).len() + tnames.at(k).len() + anames.at(k).len() == 0 {
            continue;
        }
        let mut t = HfTask {
            target: p.build_target,
            arch: p.arch,
            sysroot: &sysroot,
            flags: &flags,
            env: null,
            pre: hincs.at(k),
            names: names.at(k),
            fnames: fnames.at(k),
            tnames: tnames.at(k),
            anames: anames.at(k),
            snames: snames.at(k),
            k: k as u32,
            key: 0,
            vals: Vector::<i64>::new(),
            oks: Vector::<bool>::new(),
            objs: Vector::<String>::new(),
            sts: Vector::<bool>::new(),
            cls: Vector::<u8>::new(),
            lays: Vector::<String>::new(),
            szs: Vector::<u64>::new(),
            afacts: Vector::<String>::new(),
            shapes: Vector::<String>::new(),
            sigs: Vector::<String>::new(),
            read: Vector::<String>::new(),
            ok: false,
            hit: false,
        };
        t.key = hf_key(&t);
        t.hit = hf_find(old, &mut t);
        tasks.push(t);
    }
    let mut miss: usize = 0;
    for q in 0..tasks.len() {
        miss += (!tasks[q].hit) as usize;
    }
    // One C environment for every scan: each would build the same.
    let mut env = ct::CTarget::new();
    if miss != 0 && bg::header_env(p.build_target, p.arch, sysroot.as_str(), flags.as_str(), &mut env) {
        for q in 0..tasks.len() {
            tasks.index_mut(q).env = &env;
        }
    }
    if p.jobs != 1 && miss > 1 {
        let wg = psync::WaitGroup::new();
        for q in 0..tasks.len() {
            if tasks[q].hit {
                continue;
            }
            wg.add(1);
            let r = HfRef { t: tasks.index_mut(q) };
            let wgc = wg.clone();
            launch || {
                hf_run(unsafe &mut *r.t);
                wgc.done();
            };
        }
        wg.wait_masked();
    } else {
        for q in 0..tasks.len() {
            if !tasks[q].hit {
                hf_run(tasks.index_mut(q));
            }
        }
    }
    let mut rec = String::from_str(HF_FORMAT);
    for q in 0..tasks.len() {
        let t = tasks.index_mut(q);
        let k = t.k as usize;
        if !t.hit && t.env == null {
            // No C environment for the target (no sysroot): a C compile reads no header either, so the
            // functions are the library's exports. Nothing is recorded: a sysroot may appear.
            continue;
        }
        hf_write(&mut rec, t);
        for j in 0..t.read.len() {
            if !p.header_files.contains(&t.read[j]) {
                p.header_files.push(t.read[j].clone());
            }
        }
        if !t.ok {
            // A header the preprocessor cannot read: its functions may be anything.
            for j in 0..fkeys.at(k).len() {
                p.c_fns.insert(fkeys.at(k)[j]);
            }
            continue;
        }
        for j in 0..t.oks.len() {
            let key = keys.at(k)[j];
            let ca = unsafe &*p.module_ast_const((key >> 32) as ModuleId);
            if !ca.at_const((key & 0xFFFFFFFF) as NodeId).as_data.const_def.c_macro {
                if t.oks[j] {
                    p.extern_ints.insert(key, t.vals[j]);
                }
                continue;
            }
            check_const(p, key, t.oks[j], t.vals[j], nsp.at(k).at(j).as_str());
        }
        let mut smap = Map::<String, String>::new();
        for j in 0..t.shapes.len() {
            smap.insert(snames.at(k).at(j).clone(), t.shapes.at(j).clone());
        }
        for j in 0..t.afacts.len() {
            check_agg(p, akeys.at(k)[j], t.afacts.at(j).as_str(), &smap, asp.at(k).at(j).as_str());
        }
        for j in 0..t.objs.len() {
            if t.objs.at(j).len() != 0 {
                check_obj(p, keys.at(k)[j], t.objs.at(j).as_str(), &smap, nsp.at(k).at(j).as_str());
            }
        }
        for j in 0..t.sigs.len() {
            if !t.sts[j] {
                check_fn(p, fkeys.at(k)[j], t.sigs.at(j).as_str(), &smap, fsp.at(k).at(j).as_str());
            }
        }
        for j in 0..t.sts.len() {
            if t.sts[j] {
                p.c_fns.insert(fkeys.at(k)[j]);
            }
        }
        for j in 0..t.cls.len() {
            p.opaque_cls.insert(tkeys.at(k)[j], t.cls[j]);
            if t.cls[j] == bg::SC_REC {
                p.opaque_lay.insert(tkeys.at(k)[j], t.lays.at(j).clone());
            }
            let (exact, want) = texp.at(k)[j];
            check_type(p, tkeys.at(k)[j], exact, want, t.szs[j], tsp.at(k).at(j).as_str());
        }
    }
    if cpath.len() != 0 && rec.as_str() != read.as_str() {
        let _ = write_file_atomic(cpath.as_str(), rec.as_str());
    }
}

// The check of extern type `key` (module << 32 | node) against header `header` (as the source spells it),
// which gives it `got` (size << 32 | alignment, 0: unknown): its `@layout` (`exact`) or `@value` `want`.
// An error at the type when they differ.
fn check_type(p: &mut loader::Package, key: u64, exact: bool, want: u64, got: u64, header: str) {
    let ok = if exact {
        got == want;
    } else {
        got >> 32 == want >> 32 && (got & 0xFFFFFFFF) >= (want & 0xFFFFFFFF);
    };
    if ok {
        return;
    }
    let m = (key >> 32) as usize;
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let sid = (key & 0xFFFFFFFF) as NodeId;
    let name = a.at_const(a.at_const(sid).as_data.type_alias.name).as_data.name.text;
    let src = p.modules[m].source.as_str();
    let tn = src.slice(name.start as usize, name.end as usize);
    let what = if exact {
        "@layout";
    } else {
        "@value";
    };
    let mut msg = format(
        "'{}' must have {} bytes aligned to {}{} in C ('{}'), ",
        tn,
        want >> 32,
        pick(exact, "", "at least "),
        want & 0xFFFFFFFF,
        what,
    );
    if got == 0 {
        msg.format_into("but its layout does not follow from {}", header);
    } else {
        msg.format_into("but {} gives {} bytes aligned to {}", header, got >> 32, got & 0xFFFFFFFF);
    }
    hf_err(p, m, sid, msg);
}

// The check of extern constant `key` (module << 32 | node) against header `header` (as the source spells
// it), which defines it as an integer of value `v` when `ok`: a constant with a value must have it there. A
// value bindgen does not evaluate (a cast to a pointer) is not checked.
fn check_const(p: &mut loader::Package, key: u64, ok: bool, v: i64, header: str) {
    if !ok {
        return;
    }
    let m = (key >> 32) as usize;
    let cid = (key & 0xFFFFFFFF) as NodeId;
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let want = unsafe (*(p.cir as *mut iri::Interp)).eval_const_in(m as ModuleId, cid);
    assert(want.kind == iri::IV_INT || want.kind == iri::IV_BOOL, "the checker folds every constant of an extern block");
    // The value's 64 bits, as `header_facts` gives them.
    if v == want.i {
        return;
    }
    let ns = a.at_const(a.at_const(cid).as_data.const_def.name).as_data.name.text;
    let src = p.modules[m].source.as_str();
    let mut shown = String::new();
    if want.kind != iri::IV_BOOL && want.i < 0 && bt_is_unsigned(
        unsafe (*p.module_ast_const(want.tm)).type_at(want.ty).as_data.builtin,
    ) {
        shown.push_u64(want.i as u64);
    } else {
        shown.push_i64(want.i);
    }
    let mut msg = format(
        "constant '{}' must be {} in C, ",
        src.slice(ns.start as usize, ns.end as usize),
        shown.as_str(),
    );
    if shown.as_str().starts_with("-") == v < 0 {
        msg.format_into("but {} gives {}", header, v);
    } else {
        msg.format_into("but {} gives {}", header, v as u64);
    }
    hf_err(p, m, cid, msg);
}

// The check of constant `key` (module << 32 | node) whose expansion in header `header` (as the source
// spells it) names a C object, `obj` (`<symbol> <shape>`, `bindgen::header_facts`), with the shapes `smap`
// of the C types its type names: its type has the object's shape, and the object is its storage
// (`Package.extern_objs`); an error else. A constant with a value (`c_macro`) is the value's.
fn check_obj(p: &mut loader::Package, key: u64, obj: str, smap: &Map<String, String>, header: str) {
    let m = (key >> 32) as usize;
    let cid = (key & 0xFFFFFFFF) as NodeId;
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let cd = a.at_const(cid).as_data.const_def;
    if cd.c_macro {
        return;
    }
    let mut rest = obj;
    let sym = hf_word(&mut rest);
    let mut want = String::new();
    sc_shape(p, m as ModuleId, a.type_of(cd.ty), smap, &mut want);
    let ptr = format("{}", lay::target_for(p.arch).ptr);
    if abi_eq(want.as_str(), rest, ptr.as_str()) {
        p.extern_objs.insert(key, String::from_str(sym));
        return;
    }
    let ns = a.at_const(cd.name).as_data.name.text;
    let src = p.modules[m].source.as_str();
    let mut wd = String::new();
    let mut od = String::new();
    shape_desc(want.as_str(), &mut wd);
    shape_desc(rest, &mut od);
    let msg = format(
        "constant '{}' must be {} in C, but {} declares {}",
        src.slice(ns.start as usize, ns.end as usize),
        wd.as_str(),
        header,
        od.as_str(),
    );
    hf_err(p, m, cid, msg);
}

// The check of header struct, union or enum `key` (module << 32 | node) against its facts `facts` in
// header `header` (as the source spells it; `bindgen::agg_facts`), with the shapes `smap` of the C types
// its fields name: the type is the header's, of the size, alignment, member offsets and member types its
// declaration gives it, or of its enumerators' values, as the emitted C checks them (`header_type_checks`).
fn check_agg(p: &mut loader::Package, key: u64, facts: str, smap: &Map<String, String>, header: str) {
    let m = (key >> 32) as usize;
    let sid = (key & 0xFFFFFFFF) as NodeId;
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let src = p.modules[m].source.as_str();
    let agg = a.ext(sid).aggregate;
    let ns = a.at_const(agg.name).as_data.name.text;
    let sname = src.slice(ns.start as usize, ns.end as usize);
    if facts.len() == 0 {
        hf_err(p, m, sid, format("'{}' must be a complete C type, but {} does not define it", sname, header));
        return;
    }
    if a.at_const(sid).kind == NodeKind::NODE_ENUM {
        if facts == "?" || !facts.starts_with("E") {
            hf_err(
                p,
                m,
                sid,
                format("'{}' must be an enum in C, but the values of {} for it do not follow from it", sname, header),
            );
            return;
        }
        let it = p.cir as *mut iri::Interp;
        let mut cur: i64 = -1;
        for k in 0..agg.members.len {
            let vid = unsafe a.list(agg.members)[k as usize];
            let ok = unsafe (*it).discr(m as ModuleId, vid, cur, &mut cur);
            assert(ok, "the checker folds every enumerator of an extern block");
            let vs = a.at_const(a.at_const(vid).as_data.variant.name).as_data.name.text;
            let vname = src.slice(vs.start as usize, vs.end as usize);
            let got = hf_entry(facts, vname);
            if got.len() == 0 {
                hf_err(
                    p,
                    m,
                    vid,
                    format("'{}::{}' must be {} in C, but {} does not define it", sname, vname, cur, header),
                );
            } else if got.parse_i64().unwrap_or(cur ^ 1) != cur {
                hf_err(
                    p,
                    m,
                    vid,
                    format(
                        "'{}::{}' must be {} in C, but {} gives {}: declare every enumerator of the header's type, in its order",
                        sname,
                        vname,
                        cur,
                        header,
                        got,
                    ),
                );
            }
        }
        return;
    }
    let mut svc = lay::Svc::new(p);
    let l = svc.decl_layout(m as ModuleId, sid);
    assert(l.ok, "the checker lays out every header struct and union");
    let mut fl = facts;
    let kind = hf_word(&mut fl);
    let cs = hf_word(&mut fl).parse_u64().unwrap_or(0);
    let ca = hf_word(&mut fl).parse_u64().unwrap_or(0);
    if kind != "R" {
        hf_err(
            p,
            m,
            sid,
            format(
                "'{}' must have {} bytes aligned to {} in C, but {}",
                sname,
                l.size,
                l.align,
                if kind == "E" {
                    format("{} defines it as an enum", header);
                } else {
                    format("its layout does not follow from {}", header);
                },
            ),
        );
        return;
    }
    if cs != l.size || ca != l.align {
        hf_err(
            p,
            m,
            sid,
            format(
                "'{}' must have {} bytes aligned to {} in C, but {} gives {} bytes aligned to {}: declare every member of the header's type, in its order",
                sname,
                l.size,
                l.align,
                header,
                cs,
                ca,
            ),
        );
    }
    for k in 0..agg.members.len {
        let fid = unsafe a.list(agg.members)[k as usize];
        if a.at_const(fid).kind != NodeKind::NODE_FIELD {
            continue;
        }
        let fs = a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text;
        let fname = src.slice(fs.start as usize, fs.end as usize);
        let mut cf = String::new();
        field_c_name(p, m as ModuleId, fid, &mut cf);
        let got = hf_entry(facts, cf.as_str());
        if got.len() == 0 {
            hf_err(
                p,
                m,
                fid,
                format(
                    "field '{}.{}' must be a member in C, but {} declares no '{}'",
                    sname,
                    fname,
                    header,
                    cf.as_str(),
                ),
            );
            continue;
        }
        let eq = got.find_byte(b'=');
        let coff = got.slice(0, eq as usize).parse_i64().unwrap_or(-1);
        let cshape = got.slice(eq as usize + 1, got.len());
        let off = svc.decl_field_offset(m as ModuleId, sid, fid);
        assert(off >= 0, "a laid-out header struct has every field's offset");
        if off != coff {
            hf_err(
                p,
                m,
                fid,
                format(
                    "field '{}.{}' must sit at byte {} in C, but {} puts it at byte {}: declare every member of the header's type, in its order",
                    sname,
                    fname,
                    off,
                    header,
                    coff,
                ),
            );
            continue;
        }
        let mut want = String::new();
        sc_shape(p, m as ModuleId, a.member_ty(fid), smap, &mut want);
        if want.as_str().contains("?") || cshape.contains("?") || shape_eq(want.as_str(), cshape) {
            continue;
        }
        let mut wd = String::new();
        let mut cd = String::new();
        shape_desc(want.as_str(), &mut wd);
        shape_desc(cshape, &mut cd);
        hf_err(
            p,
            m,
            fid,
            format("field '{}.{}' must be {} in C, but {} declares {}", sname, fname, wd.as_str(), header, cd.as_str()),
        );
    }
}

// The check of extern function `key` (module << 32 | node) against its prototype `sig` in header `header`
// (as the source spells it; `bindgen::header_facts`'s `sigs`), with the shapes `smap` of the C types its
// signature names. A native call passes each argument as the declaration gives it, with no C conversion,
// so each parameter and the result must pass as the C ones do (`abi_eq`), in the same number, and the
// declaration is variadic exactly when the C one is. A function the headers do not declare is not checked.
fn check_fn(p: &mut loader::Package, key: u64, sig: str, smap: &Map<String, String>, header: str) {
    if sig.len() == 0 {
        return;
    }
    let m = (key >> 32) as usize;
    let sid = (key & 0xFFFFFFFF) as NodeId;
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let src = p.modules[m].source.as_str();
    let fd = a.ext(sid).function;
    let fs = a.at_const(fd.name).as_data.name.text;
    let fname = src.slice(fs.start as usize, fs.end as usize);
    let mut rest = sig;
    let variadic = hf_word(&mut rest) == "v";
    let cret = hf_word(&mut rest);
    let sv = (fd.flags & FN_VARIADIC) != 0;
    if sv != variadic {
        hf_err(
            p,
            m,
            sid,
            format(
                "'{}' must {}be variadic in C, but {} declares it {}",
                fname,
                pick(sv, "", "not "),
                header,
                pick(variadic, "variadic", "with a fixed parameter list"),
            ),
        );
        return;
    }
    let ptr = format("{}", lay::target_for(p.arch).ptr);
    let mut cps = Vector::<str>::new();
    for _ in 0..sig.len() {
        if rest.len() == 0 {
            break;
        }
        cps.push(hf_word(&mut rest));
    }
    // `f(void)`: no parameter.
    if cps.len() == 1 && cps[0] == "-" {
        cps.truncate(0);
    }
    if cps.len() != fd.params.len as usize {
        hf_err(
            p,
            m,
            sid,
            format(
                "'{}' must take {} {} in C, but {} declares {}",
                fname,
                fd.params.len,
                pick(fd.params.len == 1, "parameter", "parameters"),
                header,
                cps.len(),
            ),
        );
        return;
    }
    for q in 0..cps.len() {
        let pid = unsafe a.list(fd.params)[q];
        let mut want = String::new();
        sc_shape(p, m as ModuleId, a.type_of(a.at_const(pid).as_data.parameter.ty), smap, &mut want);
        if !abi_eq(want.as_str(), cps[q], ptr.as_str()) {
            let mut wd = String::new();
            let mut cd = String::new();
            shape_desc(want.as_str(), &mut wd);
            shape_desc(cps[q], &mut cd);
            hf_err(
                p,
                m,
                pid,
                format(
                    "parameter {} of '{}' must be {} in C, but {} declares {}",
                    q + 1,
                    fname,
                    wd.as_str(),
                    header,
                    cd.as_str(),
                ),
            );
        }
    }
    let mut want = String::new();
    if fd.returns.len == 0 {
        want.push_str("-");
    } else if fd.returns.len == 1 {
        sc_shape(p, m as ModuleId, a.type_of(unsafe a.list(fd.returns)[0]), smap, &mut want);
    } else {
        want.push_str("?");
    }
    if !abi_eq(want.as_str(), cret, ptr.as_str()) {
        let mut wd = String::new();
        let mut cd = String::new();
        shape_desc(want.as_str(), &mut wd);
        shape_desc(cret, &mut cd);
        hf_err(
            p,
            m,
            sid,
            format("the result of '{}' must be {} in C, but {} declares {}", fname, wd.as_str(), header, cd.as_str()),
        );
    }
}

// Whether an argument or a result of shape `want` (`sc_shape`) passes as one of C shape `got`
// (`bindgen::c_shape`) does on a target of `ptr`-byte pointers: the same shape (`shape_eq`), an integer of
// 4 or 8 bytes of the other signedness (no register needs an extension), or a pointer for an integer of
// pointer size (WASI's `clockid_t` is a pointer); `?` on either side is not checked.
const fn abi_eq(want: str, got: str, ptr: str) bool {
    if want.contains("?") || got.contains("?") || shape_eq(want, got) {
        return true;
    }
    let wi = want.starts_with("s") || want.starts_with("u");
    let gi = got.starts_with("s") || got.starts_with("u");
    let w = want.slice(1, want.len());
    let g = got.slice(1, got.len());
    return wi && gi && w == g && (w == "4" || w == "8") || want == "p" && gi && g == ptr || got == "p" && wi && w == ptr;
}

// The C name of header-type field `fid` of module `m` as every access spells it (`Mangler::field_ident`),
// appended to `out`: its `@import` pin, else its own name.
fn field_c_name(p: &loader::Package, m: ModuleId, fid: NodeId, out: &mut String) {
    let a = &p.modules[m as usize].ast;
    let src = p.modules[m as usize].source.as_str();
    let pin = a.attr_of(fid, AttrKind::ATTR_IMPORT);
    if pin != null {
        out.push_str(src.slice((unsafe (*pin).str_span.start) as usize, (unsafe (*pin).str_span.end) as usize));
        return;
    }
    let fs = a.at_const(a.at_const(fid).as_data.field.name).as_data.name.text;
    let fname = src.slice(fs.start as usize, fs.end as usize);
    out.push_str(fname);
    if mbe::escaped_stem(fname, |w: str| mbe::c_keyword(w) || mbe::c_std_macro(w)) {
        out.push_str("_");
    }
}

// The `<value>` of entry `<name>=<value>` of facts line `facts` (`check_agg`); empty when it has none.
const fn hf_entry<'a>(facts: str<'a>, name: str) str<'a> {
    let mut rest = facts;
    let _ = hf_word(&mut rest);
    for _ in 0..facts.len() {
        if rest.len() == 0 {
            break;
        }
        let w = hf_word(&mut rest);
        let eq = w.find_byte(b'=');
        if eq >= 0 && w.slice(0, eq as usize) == name {
            return w.slice(eq as usize + 1, w.len());
        }
    }
    return facts.slice(0, 0);
}

// The C names of the extern types type `t` (pool of module `m`) names through its arrays, each added to
// `out` once: the shapes `check_agg` asks the header for.
fn sc_shape_names(p: &loader::Package, m: ModuleId, t0: TypeId, out: &mut Vector<String>) {
    let a = &p.modules[m as usize].ast;
    let mut t = t0;
    for _ in 0..64 {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            t = y.as_data.arr.elem;
            continue;
        }
        if y.kind == TypeKind::TYPE_OPAQUE || y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let mut nm = String::new();
            extern_c_raw(p, y.module, y.as_data.decl, &mut nm);
            for i in 0..out.len() {
                if out[i] == nm {
                    return;
                }
            }
            out.push(nm);
        }
        return;
    }
}

// The shape of type `t` (pool of module `m`) as `bindgen::c_shape` gives a C type's, appended to `out`: an
// extern type's from the header's shapes `smap` (`?` without one), `?` for a complex type.
fn sc_shape(p: &loader::Package, m: ModuleId, t0: TypeId, smap: &Map<String, String>, out: &mut String) {
    let a = &p.modules[m as usize].ast;
    let pb = lay::target_for(p.arch).ptr;
    let mut t = t0;
    for _ in 0..64 {
        let y = *a.type_at(t);
        if y.kind == TypeKind::TYPE_ARRAY && !y.arr_sym() {
            out.format_into("[{}]", y.as_data.arr.len);
            t = y.as_data.arr.elem;
            continue;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_FUNCTION {
            out.push_str("p");
            return;
        }
        if y.kind == TypeKind::TYPE_OPAQUE || y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let mut nm = String::new();
            extern_c_raw(p, y.module, y.as_data.decl, &mut nm);
            out.push_str(
                switch smap.get(&nm) {
                    Some(sh) => sh.as_str(),
                    None => "?",
                },
            );
            return;
        }
        let b = y.as_data.builtin;
        out.push_str(
            if y.kind != TypeKind::TYPE_BUILTIN {
                "?";
            } else if b == BuiltinType::BT_I8 {
                "s1";
            } else if b == BuiltinType::BT_I16 {
                "s2";
            } else if b == BuiltinType::BT_I32 {
                "s4";
            } else if b == BuiltinType::BT_I64 {
                "s8";
            } else if b == BuiltinType::BT_ISIZE {
                pick(pb == 8, "s8", "s4");
            } else if b == BuiltinType::BT_U8 {
                "u1";
            } else if b == BuiltinType::BT_U16 {
                "u2";
            } else if b == BuiltinType::BT_U32 {
                "u4";
            } else if b == BuiltinType::BT_U64 {
                "u8";
            } else if b == BuiltinType::BT_USIZE {
                pick(pb == 8, "u8", "u4");
            } else if b == BuiltinType::BT_CHAR {
                "c";
            } else if b == BuiltinType::BT_BOOL {
                "b";
            } else if b == BuiltinType::BT_F32 {
                "f4";
            } else if b == BuiltinType::BT_F64 {
                "f8";
            } else {
                "?";
            },
        );
        return;
    }
    out.push_str("?");
}

// Whether a field of shape `want` (`sc_shape`) has the C member type of shape `got` (`bindgen::c_shape`):
// the same shape, or a `char` for a byte of either signedness and an unsigned byte for a `char` (the C
// compile's `-funsigned-char`), as the emitted C's checks accept them.
const fn shape_eq(want: str, got: str) bool {
    if want == got {
        return true;
    }
    let wl = leaf_at(want);
    let gl = leaf_at(got);
    if want.slice(0, wl) != got.slice(0, gl) {
        return false;
    }
    let w = want.slice(wl, want.len());
    let g = got.slice(gl, got.len());
    return w == "c" && (g == "s1" || g == "u1") || w == "u1" && g == "c";
}

// Where the leaf of shape `s` starts: after its last array extent.
const fn leaf_at(s: str) usize {
    let mut at: usize = 0;
    for i in 0..s.len() {
        if s.byte_at(i) == b']' {
            at = i + 1;
        }
    }
    return at;
}

// The description of shape `s` (`sc_shape`) in a message, appended to `out`.
fn shape_desc(s: str, out: &mut String) {
    let mut r = s;
    for _ in 0..s.len() {
        if !r.starts_with("[") {
            break;
        }
        let e = r.find_byte(b']') as usize;
        out.format_into("an array of {} elements, each ", r.slice(1, e));
        r = r.slice(e + 1, r.len());
    }
    if r == "p" {
        out.push_str("a pointer");
    } else if r == "-" {
        out.push_str("void");
    } else if r == "c" {
        out.push_str("a char");
    } else if r == "b" {
        out.push_str("a _Bool");
    } else if r == "f4" {
        out.push_str("a float");
    } else if r == "f8" {
        out.push_str("a double");
    } else if r.starts_with("s") || r.starts_with("u") {
        let n = r.slice(1, r.len());
        out.format_into(
            "{} integer of {} {}",
            pick(r.starts_with("s"), "a signed", "an unsigned"),
            n,
            pick(n == "1", "byte", "bytes"),
        );
    } else if r.starts_with("v") {
        out.format_into("a vector of {} bytes", r.slice(1, r.len()));
    } else if r.starts_with("r:") {
        out.format_into("'{}'", r.slice(2, r.len()));
    } else {
        out.push_str("a type of its own");
    }
}

// An error at node `n` of module `m` from the header checks (`native_header_facts`).
fn hf_err(p: &mut loader::Package, m: usize, n: NodeId, msg: String) {
    let a = unsafe &*p.module_ast_const(m as ModuleId);
    let src = p.modules[m].source.as_str();
    let mut errs = diag::Errors::new();
    errs.emit_span(dc::EXTERN_DECLARATION_DISAGREES_WITH_C_HEADER, a.at_const(n).span, msg);
    errs.finalize(src, p.modules[m].file.as_str());
    errs.log();
    p.ok = false;
}

// The header extern block `nid` of module source `src` names, without its quotes; empty for another item or
// a block without one.
fn block_header<'a>(a: &Ast, src: str<'a>, nid: NodeId) str<'a> {
    if a.at_const(nid).kind != NodeKind::NODE_EXTERN_BLOCK {
        return src.slice(0, 0);
    }
    let hn = a.at_const(nid).as_data.extern_block.header;
    if hn == NODE_NONE || a.at_const(hn).span.end <= a.at_const(hn).span.start + 2 {
        return src.slice(0, 0);
    }
    let hs = a.at_const(hn).span;
    return src.slice((hs.start + 1) as usize, (hs.end - 1) as usize);
}

// The `#include` operand of header `htxt` of module `m`: the header beside the module's file when it is
// there, as the C units include it, else the name on the search path.
fn include_operand(p: &loader::Package, m: usize, htxt: str) String {
    let mf = p.modules[m].file.as_str();
    if mf.len() != 0 {
        let mut dend = mf.len();
        while dend > 0 && mf.byte_at(dend - 1) != b'/' {
            dend -= 1;
        }
        let rel = format(
            "{}{}",
            if dend != 0 {
                mf.slice(0, dend);
            } else {
                "./";
            },
            htxt,
        );
        if let Ok(real) = fs::realpath(rel.as_str()) {
            return format("\"{}\"", real.as_str());
        }
    }
    return format("<{}>", htxt);
}

// The C name of extern item `sid` named `name` (module source `src`): its `@import` pin, else its own.
fn c_item_name(a: &Ast, src: str, sid: NodeId, name: NodeId) String {
    let pin = a.attr_of(sid, AttrKind::ATTR_IMPORT);
    if pin != null {
        return String::from_str(
            src.slice((unsafe (*pin).str_span.start) as usize, (unsafe (*pin).str_span.end) as usize),
        );
    }
    let ns = a.at_const(name).as_data.name.text;
    return String::from_str(src.slice(ns.start as usize, ns.end as usize));
}

/// The record of a native build's header scan (`native_header_facts`): per scanned header, its key, the
/// files the scan read with their sizes and modification times, and the facts.
const HF_RECORD: str = "__sc_hfacts";
// The first line of `HF_RECORD`: its format.
const HF_FORMAT: str = "hfacts 5\n";

// One header's scan (`bg::header_facts`) for `native_header_facts`: under the build's target and C
// flags, header `header`'s constants `names`, functions `fnames`, opaque types `tnames`, structs, unions
// and enums `anames` and the types `snames` their fields name (the `k`-th header, key `key`); the
// constants' values `vals` where `oks`, the `static` functions `sts`, the types' scalar classes `cls`,
// records' layouts `lays` and sizes `szs`, the aggregates' facts `afacts`, the shapes `shapes`, the files
// the scan read, and whether the preprocessor read the header (`ok`); `hit` when an earlier build's record
// gave them.
struct HfTask {
    pub(package) target: i32,
    pub(package) arch: i32,
    pub(package) sysroot: *const String,
    pub(package) flags: *const String,
    pub(package) env: *const ct::CTarget, // the C environment the scan runs under, null when none applies
    pub(package) pre: *const String, // the `#include` lines of the headers (`native_header_facts`)
    pub(package) names: *const Vector<String>,
    pub(package) fnames: *const Vector<String>,
    pub(package) tnames: *const Vector<String>,
    pub(package) anames: *const Vector<String>,
    pub(package) snames: *const Vector<String>,
    pub(package) k: u32,
    pub(package) key: u64,
    pub(package) vals: Vector<i64>,
    pub(package) oks: Vector<bool>,
    pub(package) objs: Vector<String>,
    pub(package) sts: Vector<bool>,
    pub(package) cls: Vector<u8>,
    pub(package) lays: Vector<String>,
    pub(package) szs: Vector<u64>,
    pub(package) afacts: Vector<String>,
    pub(package) shapes: Vector<String>,
    pub(package) sigs: Vector<String>,
    pub(package) read: Vector<String>,
    pub(package) ok: bool,
    pub(package) hit: bool,
}

// One header scan for a task of its own; each task writes only its own.
struct HfRef {
    pub(package) t: *mut HfTask,
}

unsafe extend HfRef as Send {}

fn hf_run(t: &mut HfTask) {
    let names = unsafe &*t.names;
    let fnames = unsafe &*t.fnames;
    let mut ns = Vector::<str>::with_capacity(names.len());
    for j in 0..names.len() {
        ns.push(names.at(j).as_str());
    }
    let mut fs9 = Vector::<str>::with_capacity(fnames.len());
    for j in 0..fnames.len() {
        fs9.push(fnames.at(j).as_str());
    }
    let tnames = unsafe &*t.tnames;
    let mut ts9 = Vector::<str>::with_capacity(tnames.len());
    for j in 0..tnames.len() {
        ts9.push(tnames.at(j).as_str());
    }
    let anames = unsafe &*t.anames;
    let mut as9 = Vector::<str>::with_capacity(anames.len());
    for j in 0..anames.len() {
        as9.push(anames.at(j).as_str());
    }
    let snames = unsafe &*t.snames;
    let mut ss9 = Vector::<str>::with_capacity(snames.len());
    for j in 0..snames.len() {
        ss9.push(snames.at(j).as_str());
    }
    if t.env == null {
        t.ok = false;
        return;
    }
    t.ok = bg::header_facts(
        unsafe &*t.env,
        unsafe (*t.pre).as_str(),
        ns[0..ns.len()],
        &mut t.vals,
        &mut t.oks,
        &mut t.objs,
        fs9[0..fs9.len()],
        &mut t.sts,
        &mut t.sigs,
        ts9[0..ts9.len()],
        &mut t.cls,
        &mut t.lays,
        &mut t.szs,
        as9[0..as9.len()],
        &mut t.afacts,
        ss9[0..ss9.len()],
        &mut t.shapes,
        &mut t.read,
    );
}

// The key of `t`'s scan: the compiler (`compiler_id`: another one may scan differently), the target, the
// flags, the header and the names it asks for.
fn hf_key(t: &HfTask) u64 {
    let mut h = (t.target as u64 << 32 ^ t.arch as u64 ^ compiler_id()).wrapping_mul(0x100000001B3);
    h = (h ^ fnv(unsafe (*t.sysroot).as_str())).wrapping_mul(0x100000001B3);
    h = (h ^ fnv(unsafe (*t.flags).as_str())).wrapping_mul(0x100000001B3);
    h = (h ^ fnv(unsafe (*t.pre).as_str())).wrapping_mul(0x100000001B3);
    let names = unsafe &*t.names;
    for j in 0..names.len() {
        h = (h ^ fnv(names.at(j).as_str())).wrapping_mul(0x100000001B3);
    }
    h = (h ^ 0x2F).wrapping_mul(0x100000001B3);
    let fnames = unsafe &*t.fnames;
    for j in 0..fnames.len() {
        h = (h ^ fnv(fnames.at(j).as_str())).wrapping_mul(0x100000001B3);
    }
    h = (h ^ 0x2F).wrapping_mul(0x100000001B3);
    let tnames = unsafe &*t.tnames;
    for j in 0..tnames.len() {
        h = (h ^ fnv(tnames.at(j).as_str())).wrapping_mul(0x100000001B3);
    }
    h = (h ^ 0x2F).wrapping_mul(0x100000001B3);
    let anames = unsafe &*t.anames;
    for j in 0..anames.len() {
        h = (h ^ fnv(anames.at(j).as_str())).wrapping_mul(0x100000001B3);
    }
    h = (h ^ 0x2F).wrapping_mul(0x100000001B3);
    let snames = unsafe &*t.snames;
    for j in 0..snames.len() {
        h = (h ^ fnv(snames.at(j).as_str())).wrapping_mul(0x100000001B3);
    }
    return h;
}

// `t`'s record line (`HF_RECORD`): `<key> <ok> <files> <constants> <aggregates> <shapes>`, then per file
// `<size> <mtime> <path>`, per constant `<0|1> <value> <object>`, the `static` flags as one line of `0` and `1`,
// the types' classes as one line of their `bindgen::SC_*` bytes, their sizes, per type its layout
// (`bindgen::SC_REC`'s, else empty), per aggregate its facts, per shape name its shape, and per function
// its prototype (one per `static` flag).
fn hf_write(out: &mut String, t: &HfTask) {
    out.format_into(
        "{} {} {} {} {} {}\n",
        t.key,
        t.ok as u32,
        t.read.len(),
        t.vals.len(),
        t.afacts.len(),
        t.shapes.len(),
    );
    for j in 0..t.read.len() {
        let (sz, mt) = hf_stat(t.read.at(j).as_str());
        out.format_into("{} {} {}\n", sz, mt, t.read.at(j).as_str());
    }
    for j in 0..t.vals.len() {
        out.format_into("{} {} {}\n", t.oks[j] as u32, t.vals[j], t.objs.at(j).as_str());
    }
    for j in 0..t.sts.len() {
        out.push_byte(
            if t.sts[j] {
                b'1';
            } else {
                b'0';
            },
        );
    }
    out.push_byte(b'\n');
    for j in 0..t.cls.len() {
        out.push_byte(t.cls[j]);
    }
    out.push_byte(b'\n');
    for j in 0..t.szs.len() {
        out.format_into("{} ", t.szs[j]);
    }
    out.push_byte(b'\n');
    for j in 0..t.lays.len() {
        out.push_string(t.lays.at(j));
        out.push_byte(b'\n');
    }
    for j in 0..t.afacts.len() {
        out.push_string(t.afacts.at(j));
        out.push_byte(b'\n');
    }
    for j in 0..t.shapes.len() {
        out.push_string(t.shapes.at(j));
        out.push_byte(b'\n');
    }
    for j in 0..t.sigs.len() {
        out.push_string(t.sigs.at(j));
        out.push_byte(b'\n');
    }
}

// File `path`'s size and modification time in nanoseconds; zeros when it is gone.
fn hf_stat(path: str) (u64, i64) {
    if let Ok(m) = fs::stat(path) {
        return m.size, m.modified_ns;
    }
    return 0, 0;
}

// `t`'s facts from record `rec` (`hf_write`) when it holds `t`'s key and every file the scan read is
// unchanged.
fn hf_find(rec: str, t: &mut HfTask) bool {
    let mut rest = rec;
    let nf = unsafe (*t.fnames).len();
    for _ in 0..rec.len() {
        let mut line = hf_line(&mut rest);
        if line.len() == 0 {
            return false;
        }
        let key = hf_word(&mut line).parse_u64().unwrap_or(0);
        let ok = hf_word(&mut line) == "1";
        let nr = hf_word(&mut line).parse_u64().unwrap_or(0) as usize;
        let nv = hf_word(&mut line).parse_u64().unwrap_or(0) as usize;
        let na = hf_word(&mut line).parse_u64().unwrap_or(0) as usize;
        let nsh = hf_word(&mut line).parse_u64().unwrap_or(0) as usize;
        if key != t.key {
            // Another scan's entry: its files and constants, its `static` flags (one per function), its
            // classes, the sizes, a layout per class, its aggregates' facts, its shapes, then a prototype per
            // function.
            for _ in 0..nr + nv {
                let _ = hf_line(&mut rest);
            }
            let nfn = hf_line(&mut rest).len();
            let ncl = hf_line(&mut rest).len();
            let _ = hf_line(&mut rest);
            for _ in 0..ncl + na + nsh + nfn {
                let _ = hf_line(&mut rest);
            }
            continue;
        }
        let mut same = true;
        for _ in 0..nr {
            let mut fl = hf_line(&mut rest);
            let sz = hf_word(&mut fl).parse_u64().unwrap_or(U64_MAX9);
            let mt = hf_word(&mut fl).parse_i64().unwrap_or(-1);
            let (sz2, mt2) = hf_stat(fl);
            same = same && sz == sz2 && mt == mt2;
            t.read.push(String::from_str(fl));
        }
        for _ in 0..nv {
            let mut vl = hf_line(&mut rest);
            t.oks.push(hf_word(&mut vl) == "1");
            t.vals.push(hf_word(&mut vl).parse_i64().unwrap_or(0));
            t.objs.push(String::from_str(vl));
        }
        let sl = hf_line(&mut rest);
        let cl = hf_line(&mut rest);
        let mut zl = hf_line(&mut rest);
        same = same && nv == unsafe (*t.names).len() && (!ok || sl.len() == nf && cl.len() == unsafe (*t.tnames).len());
        for j in 0..sl.len() {
            t.sts.push(sl.byte_at(j) == b'1');
        }
        for j in 0..cl.len() {
            t.cls.push(cl.byte_at(j));
            t.szs.push(hf_word(&mut zl).parse_u64().unwrap_or(0));
            t.lays.push(String::from_str(hf_line(&mut rest)));
        }
        for _ in 0..na {
            t.afacts.push(String::from_str(hf_line(&mut rest)));
        }
        for _ in 0..nsh {
            t.shapes.push(String::from_str(hf_line(&mut rest)));
        }
        for _ in 0..sl.len() {
            t.sigs.push(String::from_str(hf_line(&mut rest)));
        }
        same = same && (!ok || na == unsafe (*t.anames).len() && nsh == unsafe (*t.snames).len());
        if !same {
            t.read.truncate(0);
            t.oks.truncate(0);
            t.vals.truncate(0);
            t.objs.truncate(0);
            t.sts.truncate(0);
            t.cls.truncate(0);
            t.szs.truncate(0);
            t.lays.truncate(0);
            t.afacts.truncate(0);
            t.shapes.truncate(0);
            t.sigs.truncate(0);
            return false;
        }
        t.ok = ok;
        return true;
    }
    return false;
}

const U64_MAX9: u64 = 0xFFFFFFFFFFFFFFFF;

// The next line of `rest`, without its newline, and `rest` past it; "" at the end.
const fn hf_line<'a>(rest: &mut str<'a>) str<'a> {
    let r = *rest;
    let nl = r.find_byte(b'\n');
    if nl < 0 {
        *rest = r.slice(r.len(), r.len());
        return r;
    }
    *rest = r.slice(nl as usize + 1, r.len());
    return r.slice(0, nl as usize);
}

// The next space-separated word of `line`, and `line` past it.
const fn hf_word<'a>(line: &mut str<'a>) str<'a> {
    let r = *line;
    let sp = r.find_byte(b' ');
    if sp < 0 {
        *line = r.slice(r.len(), r.len());
        return r;
    }
    *line = r.slice(sp as usize + 1, r.len());
    return r.slice(0, sp as usize);
}

// One object of a native build: its unit's own part (`own`: the module's own items) or the part the
// build adds (instances, glue, data, wrappers): its bytes, or the reused object's (`old`).
struct NatObj {
    pub(package) m: ModuleId,
    pub(package) own: bool,
    pub(package) bytes: Vector<u8>,
    pub(package) old: String,
}

// One part of one unit to compile: its functions `fs` and data `ds` of LIR package `pk` for `(os, isa)`
// into `bytes`, `ok` when it compiles, else the reason in `why`.
struct NatTask {
    pub(package) pk: *const lir_ir::Package,
    pub(package) os: i32,
    pub(package) isa: i32,
    pub(package) fs: *const Vector<u32>,
    pub(package) ds: *const Vector<u32>,
    pub(package) text: *const String,
    pub(package) bytes: *mut Vector<u8>,
    pub(package) why: *mut String,
    pub(package) ok: *mut bool,
}

// Tasks read the finished LIR and their part's symbol lists, and write their own slots.
unsafe extend NatTask as Send {}

fn nat_task(t: NatTask) {
    let fs = unsafe &*t.fs;
    let ds = unsafe &*t.ds;
    unsafe *t.ok = nat::object(
        unsafe &*t.pk,
        t.os,
        t.isa,
        fs[0..fs.len()],
        ds[0..ds.len()],
        unsafe (*t.text).as_str(),
        unsafe &mut *t.bytes,
        unsafe &mut *t.why,
    );
}

// The native objects' record (`__sc_native` in the tree): per module, the key its own part was compiled
/// under (`nat_key`), its low bit `NAT_OBJ` when that part has an object (`<key> <path>` lines). A cached
/// emission of a module counts only under its record's key.
const NAT_RECORD: str = "__sc_native";
const NAT_OBJ: u64 = 1;

// The native record at `path`: each module path's key and flags (`NAT_RECORD`); empty without one.
fn nat_record(path: str) Map<String, u64> {
    let mut rec = Map::<String, u64>::new();
    let rt = loader::read_file(path).unwrap_or(String::new());
    let mut rest = rt.as_str();
    for _ in 0..rt.len() {
        let nl = rest.find_byte(b'\n');
        let sp = rest.find_byte(b' ');
        if nl < 0 || sp < 0 || sp > nl {
            break;
        }
        let k = rest.slice(0, sp as usize).parse_u64().unwrap_or(0);
        rec.insert(String::from_str(rest.slice(sp as usize + 1, nl as usize)), k);
        rest = rest.slice(nl as usize + 1, rest.len());
    }
    return rec;
}

// A native build replays a module's cached emission only when the record holds it under its key, with
// its own object when it has one, and, when the LIR optimizer runs, with its held record, which `held`
// gets (`lir::hold`: the other units then optimize as with the module rendered). The rest emit again.
fn nat_trust(p: &loader::Package, t: &mut tuc::Tuc, held: &mut Vector<Option<lhold::Rec>>) {
    held.resize_default(p.modules.len());
    if !t.on || !p.native {
        return;
    }
    let rec = nat_record(build_out_path(p.gen_root.as_str(), NAT_RECORD, "").as_str());
    let pb = lay::target_for(p.arch).ptr as u32;
    for m in 0..p.modules.len() {
        if !t.hit[m] {
            continue;
        }
        let r = switch rec.get(&p.modules[m].path) {
            Some(v) => *v,
            None => 0,
        };
        let nk = nat_key(p, &t.keys, m);
        if r == 0 || (r & ~3u64) != (nk & ~3u64) {
            t.hit.set(m, false);
            continue;
        }
        if p.lir_opt {
            held.set(m, lhold::read(tuc::held_of(t, m, nk), pb));
            t.hit.set(m, held.at(m).is_some());
        }
    }
}

// The inline budget of `opt-level` `opt` and code-generation flags `cg`.
fn inline_budget(opt: i32, cg: u64) il::Budget {
    if (cg & bman::CG_INLINE) == 0 {
        return il::NONE_INLINES;
    }
    if (cg & bman::CG_INLINE_FUNCTIONS) == 0 {
        return il::SHRINK;
    }
    return if opt == bman::OPT_S || opt == bman::OPT_Z {
        il::SIZE;
    } else if opt == 3 {
        il::FAST;
    } else {
        il::SPEED;
    };
}

// The loop transforms' budgets at `opt-level` `opt` with code-generation flags `cg`:
// a fully unrolled loop's copies take up to LLVM's full unroll thresholds (300 instructions at 3, 150 at
// 2), counted once the counter is a constant (`lir::loops::LoopOpt::residual`, as LLVM counts the copies
// after simplification); a loop versions on its bounds checks up to 200 (GCC's complete peeling limit),
// and unswitches up to GCC's and LLVM's 50; a header of up to 8 instructions rotates, but at "s" and "z" (the copy grows the
// code: 1.6% on the compiler, for 1.1% of its build's processor time); a vectorized loop interleaves 4
// vectors (LLVM's AArch64 maximum; 2 left a sum's accumulator latency exposed: 0.20 against 0.15 s), 1 at
// "s"; a loop's final values take up to 512 instructions of copied iterations at every level (LLVM's
// IndVarSimplify runs from 1).
fn loop_budgets(opt: i32, cg: u64) lu::Budgets {
    return lu::Budgets {
        peel: if (cg & bman::CG_UNROLL) == 0 {
            0u32;
        } else if opt == 3 {
            300u32;
        } else {
            150u32;
        },
        version: if (cg & bman::CG_VERSION_LOOPS) != 0 {
            200u32;
        } else {
            0u32;
        },
        unswitch: if (cg & bman::CG_UNSWITCH) != 0 {
            50u32;
        } else {
            0u32;
        },
        rotate: if opt == bman::OPT_S || opt == bman::OPT_Z {
            0u32;
        } else {
            8u32;
        },
        vector: if (cg & bman::CG_VECTORIZE) == 0 {
            0u32;
        } else if opt == bman::OPT_S {
            1u32;
        } else {
            4u32;
        },
        fin: 512,
    };
}

// The key of module `m`'s own object: its emission cache key (`keys`, which covers the bodies the LIR
// inliner can copy: its imports') and what the native code reads beyond the C text: the build
// configuration, the CPU features, the LIR optimizer's switches, the C headers' constants, the functions
// only C defines, and with debug information the directory its file names are relative to.
fn nat_key(p: &loader::Package, keys: &Vector<u64>, m: usize) u64 {
    let mut h = keys[m] ^ p.build_cfg as u64 << 40 ^ p.features.w[0].wrapping_mul(0x9E3779B97F4A7C15) ^ p.features.w[1];
    h = h ^ p.build_target as u64 << 8 ^ p.arch as u64 ^ p.pic as u64 << 7;
    if p.debug_info {
        h = h ^ (fnv(process::current_dir().unwrap_or(String::new()).as_str()) | 1).wrapping_mul(0xC4CEB9FE1A85EC53);
    }
    // The level and code-generation flags, and whether the LIR optimizer runs, inlines and promotes.
    h = h ^ (p.opt as u64 & 0xFF) << 48 ^ p.cg.wrapping_mul(0xFF51AFD7ED558CCD);
    h = h ^ p.lir_opt as u64 << 47 ^ fnv(stdlib::get_env("SC_LIR_INLINE").unwrap_or(String::from_str("1")).as_str()).wrapping_mul(
        0x94D049BB133111EB,
    );
    h = h ^ fnv(stdlib::get_env("SC_LIR_PROMOTE").unwrap_or(String::from_str("1")).as_str()).wrapping_mul(
        0xD6E8FEB86659FD93,
    );
    let mut ci = p.c_fns.iter();
    loop {
        switch ci.next() {
            Some(k) => {
                h = h ^ k.wrapping_mul(0xC2B2AE3D27D4EB4F);
            },
            None => {
                break;
            },
        };
    }
    // Order-free sums over the opaque types' classes and layouts and the constants.
    let mut ot = p.opaque_cls.keys();
    loop {
        switch ot.next() {
            Some(k) => {
                let lay = switch p.opaque_lay.get(k) {
                    Some(l) => fnv(l.as_str()),
                    None => 0,
                };
                h = h ^ (k.wrapping_mul(0xD6E8FEB86659FD93) ^ (*p.opaque_cls.get(k).unwrap()) as u64 ^ lay).wrapping_mul(
                    0x100000001B3,
                );
            },
            None => {
                break;
            },
        };
    }
    let mut it = p.extern_ints.keys();
    loop {
        switch it.next() {
            Some(k) => {
                let v = (*p.extern_ints.get(k).unwrap()) as u64;
                h = h ^ (k.wrapping_mul(0x9E3779B97F4A7C15) ^ v).wrapping_mul(0x100000001B3);
            },
            None => {
                break;
            },
        };
    }
    let mut xo = p.extern_objs.keys();
    loop {
        switch xo.next() {
            Some(k) => {
                let v = fnv(p.extern_objs.get(k).unwrap().as_str());
                h = h ^ (k.wrapping_mul(0xBF58476D1CE4E5B9) ^ v).wrapping_mul(0x100000001B3);
            },
            None => {
                break;
            },
        };
    }
    return h;
}

// The objects of a native build: each module of `lm` and `iq` (those with units) compiles, its objects into
// `objs`; `isnat` marks them. A module the emission cache replayed (`hit`) takes the object its record
// `rec` holds (`nat_trust`). A module the backend cannot compile (module-level assembly the target's
// assembler does not take, a body the lowering or the backend refuses) is an error, which names the
// module and why: false then. SC_NATIVE_STATS reports each module.
fn native_plan(
    p: &loader::Package,
    l: &lw::Lower,
    lm: &Vector<ModuleId>,
    iq: &Vector<ModuleId>,
    root: str,
    hit: &Vector<bool>,
    rec: &Map<String, u64>,
    isnat: &mut Vector<bool>,
    objs: &mut Vector<NatObj>,
) bool {
    let n = p.modules.len();
    let t0 = ticks_ms();
    isnat.truncate(0);
    isnat.resize_default(n);
    let mut unit = Vector::<bool>::new();
    unit.resize_default(n);
    for k in 0..lm.len() {
        unit.set(lm[k] as usize, true);
    }
    for k in 0..iq.len() {
        unit.set(iq[k] as usize, true);
    }
    // Per unit, 1 + the index in `l.conly_why` of the first reason it does not compile, 0 for none.
    let mut conly = Vector::<u32>::new();
    conly.resize_default(n);
    for k in 0..l.conly.len() {
        let u = l.conly[k] as usize;
        if u < n && conly[u] == 0 {
            conly.set(u, k as u32 + 1);
        }
    }
    // Each part's symbols, in symbol order: part 2m is unit m's own, 2m + 1 the rest.
    let mut funcs = Vector::<Vector<u32>>::new();
    let mut datas = Vector::<Vector<u32>>::new();
    funcs.resize_default(2 * n);
    datas.resize_default(2 * n);
    for i in 0..l.pkg.syms.len() {
        let y = l.pkg.syms[i];
        if y.def == lir_ir::NONE || y.unit as usize >= n {
            continue;
        }
        let part = 2 * y.unit as usize + (!y.own) as usize;
        if y.kind == lir_ir::SK_FUNC {
            funcs.index_mut(part).push(i as u32);
        } else {
            datas.index_mut(part).push(i as u32);
        }
    }
    // In name order (by a 64-bit hash of the name): the symbols' order follows the emission's, which a
    // cached emission changes.
    let mut key = Vector::<u128>::new();
    for q in 0..2 * n {
        for d in 0..2usize {
            let v = if d == 0 {
                funcs.index_mut(q);
            } else {
                datas.index_mut(q);
            };
            if v.len() < 2 {
                continue;
            }
            key.truncate(0);
            for k in 0..v.len() {
                key.push(fnv(l.pkg.spell(l.pkg.syms[v[k] as usize].name)) as u128 << 32 | v[k]);
            }
            key.sort();
            for k in 0..v.len() {
                v.set(k, (key[k] & 0xFFFFFFFF) as u32);
            }
        }
    }
    let stats = stdlib::getenv("SC_NATIVE_STATS") != null;
    // Each unit's reason it does not compile, else its parts, compiled in parallel; a replayed unit's own
    // part is its recorded object.
    let mut bytes = Vector::<Vector<u8>>::new();
    let mut olds = Vector::<String>::new();
    olds.resize_default(n);
    let mut whys = Vector::<String>::new();
    let mut oks = Vector::<bool>::new();
    bytes.resize_default(2 * n);
    whys.resize_default(2 * n);
    oks.resize_default(2 * n);
    let mut todo = Vector::<u64>::new();
    let mut texts = Vector::<String>::new();
    texts.resize_default(2 * n);
    for m in 0..n {
        if !*unit.at(m) {
            continue;
        }
        let why = whys.index_mut(2 * m);
        if module_has_asm(p, m) {
            if !nat::asm_native(p.build_target, p.arch) {
                why.push_str("module-level assembly, which the assembler does not take for this target");
                continue;
            }
            texts.set(2 * m, module_asm(p, m));
        }
        if conly[m] != 0 {
            why.push_string(l.conly_why.at(conly[m] as usize - 1));
            continue;
        }
        if hit.len() != 0 && hit[m] {
            // The record holds the module under its key (`nat_trust`).
            let r = *rec.get(&p.modules[m].path).unwrap();
            if (r & NAT_OBJ) != 0 {
                let old = loader::read_file(build_out_path(root, p.modules[m].path.as_str(), ".o").as_str());
                if old.is_none() {
                    why.push_str("its cached emission has no native object");
                    continue;
                }
                olds.set(m, old.unwrap());
            }
            oks.set(2 * m, true);
        } else if funcs.at(2 * m).len() + datas.at(2 * m).len() + texts.at(2 * m).len() != 0 {
            todo.push(0xFFFFFFFFu64 - funcs.at(2 * m).len() as u64 << 32 | (2 * m) as u64);
        } else {
            oks.set(2 * m, true);
        }
        if funcs.at(2 * m + 1).len() + datas.at(2 * m + 1).len() != 0 {
            todo.push(0xFFFFFFFFu64 - funcs.at(2 * m + 1).len() as u64 << 32 | (2 * m + 1) as u64);
        } else {
            oks.set(2 * m + 1, true);
        }
    }
    // Largest first, for the balance of the pool.
    todo.sort();
    let pk = (&l.pkg) as *const lir_ir::Package;
    let wg = psync::WaitGroup::new();
    for k in 0..todo.len() {
        let q = (todo[k] & 0xFFFFFFFF) as usize;
        let t = NatTask {
            pk: pk,
            os: p.build_target,
            isa: p.arch,
            fs: funcs.at(q),
            ds: datas.at(q),
            text: texts.at(q),
            bytes: bytes.index_mut(q),
            why: whys.index_mut(q),
            ok: oks.index_mut(q),
        };
        if p.jobs == 1 || todo.len() == 1 {
            nat_task(t);
            continue;
        }
        wg.add(1);
        let wgc = wg.clone();
        launch || {
            nat_task(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    let mut nc: u64 = 0;
    let mut nn: u64 = 0;
    let mut ok = true;
    for m in 0..n {
        if !*unit.at(m) {
            continue;
        }
        if whys.at(2 * m).len() == 0 && oks[2 * m] && oks[2 * m + 1] {
            isnat.set(m, true);
            nn += 1;
            for part in 0..2usize {
                let old = if part == 0 {
                    replace(olds.index_mut(m), String::new());
                } else {
                    String::new();
                };
                if bytes.at(2 * m + part).len() != 0 || old.len() != 0 {
                    let b = replace(bytes.index_mut(2 * m + part), Vector::<u8>::new());
                    objs.push(NatObj { m: m as ModuleId, own: part == 0, bytes: b, old: old });
                }
            }
            if stats {
                eprint("native: {} native\n", p.modules[m].path.as_str());
            }
            continue;
        }
        nc += 1;
        ok = false;
        let w = if whys.at(2 * m).len() != 0 {
            whys.at(2 * m).as_str();
        } else {
            whys.at(2 * m + 1).as_str();
        };
        eprint("error: module '{}' does not compile: {}\n", p.modules[m].path.as_str(), w);
    }
    if stats {
        eprint("native: {} modules compiled, {} refused, {} ms\n", nn, nc, ticks_ms() - t0);
    }
    return ok;
}

// The C `main`: argv marshalled into a Vector<str> when the user main takes one. It always takes the
// arguments: on wasm the C compiler names a `main(void)` `__main_void` and the two-argument form
// `__main_argc_argv`, and the entry point of `std::rt::libc` calls the second.
fn cemit_main_wrapper(out: &mut String, argv: bool) {
    if !argv {
        out.push_str("int main(int argc, char **argv) { (void)argc; (void)argv; return __sc_user_main(); }\n");
        return;
    }
    out.push_str(
        "static Vector__str __sc_argv_to_vector(int argc, char **argv) {\n  Vector__str out = (Vector__str){0};\n  if (argc > 0) {\n    out.ptr = (str *)Global__alloc((Global *)&__sc_zst_1, sizeof(str) * (size_t)argc, _Alignof(str));\n    out.len = (size_t)argc;\n    out.cap = (size_t)argc;\n    for (int i = 0; i < argc; i++) { out.ptr[i] = str__from_cstr(argv[i]); }\n  }\n  return out;\n}\nint main(int argc, char **argv) { return __sc_user_main(__sc_argv_to_vector(argc, argv)); }\n",
    );
}

// The single-line signature prefix of an emitted function body (up to its ` {`, or the `;` of a
// declaration the body's file-scope assembly defines), as a prototype.
fn proto_of(body: &String, out: &mut String) {
    let bs = body.as_str();
    let n = bs.len();
    // A shared declaration must not carry optimization-only specifiers: an `inline` prototype whose
    // TU has no definition is flagged (`-Werror` inline-never-defined), and `__attribute__((always_
    // inline, ...))` needs the `inline` keyword it would then lose. The definition keeps them; the
    // `_Noreturn` specifier and return type follow this prefix and stay.
    let mut start: usize = 0;
    loop {
        if start + 7 <= n && bs.slice(start, start + 7) == "inline " {
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
        if bs.byte_at(i) == 32 && bs.byte_at(i + 1) == 123 || bs.byte_at(i) == 59 {
            break;
        }
        i += 1;
    }
    out.push_str(bs.slice(start, i));
    out.push_str(";\n");
}

// ---- The borrow check stage -----------------------------------------------------------------
// One independent job per module over its function, method and aggregate items in source
// order. A body split of a module was measured and refused: the bodies of one module intern
// into one type pool under one lock, and concurrent jobs of a module spent forty times the
// lowering CPU waiting on it (the phase took twice as long at fourteen workers). The pass
// writes its diagnostics (per item), its lowered bodies (a private keep per job, absorbed into
// the package keep under the engine lock) and each closure's own capture facts. A module
// closes (Core IR ready) when its job ends; its body syntax stays until the instance graph.

/// One job: the items at by_node positions `[lo, hi)` (source order) of module `m`.
struct BcJob {
    pub(package) m: u32,
    pub(package) lo: u32,
    pub(package) hi: u32,
}

/// One analysis slot: an ownership oracle and a borrow pipeline. A job leases one from the pool
/// for its whole run and returns it, so at most as many exist as jobs ever ran at once, and each
/// keeps its memo tables and scratch capacity across the bodies it served (the serial path's
/// single slot). Memo answers depend only on (module, type), so which slot serves a body never
/// changes an outcome.
struct BcSlot {
    pub(package) ow: bfx::Owner,
    pub(package) ctx: bfi::BorrowCtx,
}

unsafe extend BcSlot as Send {}

/// The idle slots and the count of jobs that have not leased a slot yet. When that count is zero,
/// a returned slot has no next lease and is freed at once, unless `reported`: the borrow probe and
/// the item measurement read every slot after the stage.
struct BcPool {
    pub(package) idle: Vector<BcSlot>,
    pub(package) unleased: usize,
    pub(package) reported: bool,
}

struct BcStage {
    pub(package) p: *mut loader::Package,
    pub(package) jobs: *const Vector<BcJob>,
    pub(package) outs: *mut Option<Box<diag::Errors>>, // per item
    pub(package) slots: *mut psync::Mutex<BcPool>,
    pub(package) master: *mut irl::Keep, // null = discard the lowerings
    pub(package) validate: bool,
}

fn bc_slot_new(p: *const loader::Package) BcSlot {
    let mut s = BcSlot { ow: bfx::Owner::new(p), ctx: bfi::BorrowCtx::new() };
    s.ctx.st = bc_stats_new();
    return s;
}

// The guard lives exactly as long as these bodies: a job never holds the pool lock while it runs.
fn bc_slot_take(pool: &psync::Mutex<BcPool>, p: *const loader::Package) BcSlot {
    let mut g = pool.lock();
    assert(g.unleased != 0, "each borrow job leases one slot");
    g.unleased -= 1;
    switch g.idle.pop() {
        Some(s) => {
            return s;
        },
        _ => {},
    };
    return bc_slot_new(p);
}

fn bc_slot_give(pool: &psync::Mutex<BcPool>, slot: BcSlot) {
    let mut g = pool.lock();
    if g.unleased != 0 || g.reported {
        g.idle.push(slot);
    }
}

fn bc_job(ctx: *mut void, j: u32) {
    let st = unsafe &*(ctx as *const BcStage);
    let p = unsafe &mut *st.p;
    let job = *(unsafe &*st.jobs).at(j as usize);
    let m = job.m as usize;
    let pkg = st.p;
    let mut slot = bc_slot_take(unsafe &*st.slots, st.p);
    let ts = slot.ctx.st.pr.start();
    let mm = &mut p.modules[m];
    let src = mm.source.as_str().ptr() as *const char;
    let len = mm.source.len();
    let mut tck = tc::TypeChecker::new(&mut mm.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    // The serial path lowers straight into the package keep; a parallel job keeps its own and
    // publishes it under the evaluator's lock (its lookups read the index).
    let mut keep = irl::Keep::new();
    if st.master != null {
        slot.ctx.keep = if p.jobs == 1 {
            st.master;
        } else {
            &mut keep;
        };
    }
    slot.ctx.validate = st.validate;
    // The lowered bodies of the function under analysis: one vector for the job, emptied after
    // every function (a per-function vector reserves eight Lowerer slots on its first push).
    let mut bodies = Vector::<irl::Lowerer>::new();
    slot.ctx.st.pr.stop(bfi::BP_SETUP, ts);
    for k in job.lo as usize..job.hi as usize {
        let it = p.sched.by_node[k] as usize;
        let meta = *p.idx.items.at(it);
        if meta.owner != loader::ITEM_NONE && p.idx.items.at(meta.owner as usize).kind != loader::ItemKind::IK_EXTEND as u8 {
            continue; // an interface's members have no body of their own to analyze
        }
        let kd = meta.kind;
        if kd == loader::ItemKind::IK_EXTEND as u8 {
            // Its methods are items of their own; the extend checks only its declaration.
            tck.bc_check_assoc_lifetimes(meta.node);
            *unsafe &mut *(st.outs + it) = take_errs(&mut tck.errors);
            continue;
        }
        if kd != loader::ItemKind::IK_FUNCTION as u8 && kd != loader::ItemKind::IK_METHOD as u8 && kd != loader::ItemKind::IK_STRUCT as u8 && kd != loader::ItemKind::IK_ENUM as u8 {
            continue;
        }
        tck.bc_item(meta.node, &mut slot.ow, &mut slot.ctx, &mut bodies);
        *unsafe &mut *(st.outs + it) = take_errs(&mut tck.errors);
    }
    slot.ctx.keep = null;
    let ce = p.cir as *mut iri::Interp;
    if st.master != null && p.jobs != 1 {
        let tk = slot.ctx.st.pr.start();
        if ce != null {
            unsafe (*ce).eng_lock();
        }
        unsafe (&mut *st.master).absorb(&mut keep);
        if ce != null {
            unsafe (*ce).eng_unlock();
        }
        slot.ctx.st.pr.stop(bfi::BP_KEEP, tk);
    }
    bc_slot_give(unsafe &*st.slots, slot);
    // The module's Core IR is ready. Its body syntax stays until the instance graph has evaluated
    // the per-instance static_asserts (`graph_inst_asserts`).
    p.set_module_states(m, loader::IS_IR_READY);
    // The shared last-use table served the type check and this pass.
    let _ = replace(&mut p.modules[m].ast.last_use, Vector::<NodeId>::new());
}

/// The borrow jobs: one per module with syntax, its items in source order.
fn bc_jobs(p: &loader::Package, out: &mut Vector<BcJob>) {
    for m in 0..p.modules.len() {
        if !p.modules.at(m).has_ast {
            continue;
        }
        out.push(BcJob { m: m as u32, lo: p.idx.mod_items[m], hi: p.idx.mod_items[m + 1] });
    }
}

/// The borrow stage's prologue: per module, its row of the reference table the borrow jobs query
/// concurrently (`refs`, `w` words a row), its function and closure bodies (`bodies`), and its
/// reachability scan (`scans`, null when the package's reachability is known). Each job writes
/// only its module's entries.
struct BcPre {
    pub(package) p: *const loader::Package,
    pub(package) cx: *const loader::ReachCtx,
    pub(package) refs: *mut u64,
    pub(package) w: usize,
    pub(package) bodies: *mut usize,
    pub(package) scans: *mut loader::ReachScan,
}

fn bc_pre_job(ctx: *mut void, j: u32) {
    let st = unsafe &*(ctx as *const BcPre);
    let p = unsafe &*st.p;
    let m = j as usize;
    p.mod_refs_row(m, unsafe SliceMut::<u64> { ptr: st.refs + m * st.w, len: st.w });
    *unsafe &mut *(st.bodies + m) = irl::module_bodies(p, m);
    if st.scans != null {
        *unsafe &mut *(st.scans + m) = p.co_scan(m, unsafe &*st.cx);
    }
}

/// Borrow-check every module as a job (`bc_job`): one ownership oracle and one borrow pipeline
/// per slot in flight (the serial path's single slot serves every body), outputs published in
/// module and item order, so both paths print and lower identically. `keep` (null = discard)
/// collects every lowered body for the backend. False when any module reported an error.
pub(package) fn borrowck_all(p: &mut loader::Package, keep: *mut irl::Keep) bool {
    // The stage's own regions (the slots' probes hold the per-body ones).
    let mut st0 = bc_stats_new();
    let tp = st0.pr.start();
    publish_checkpoint(p, keep);
    st0.pr.stop(bfi::BP_PUBLISH, tp);
    let n = p.modules.len();
    // The prologue (`bc_pre_job`), then the package-wide reachability the borrow jobs would
    // otherwise race to build.
    let tr = st0.pr.start();
    let reach = p.co_state == 0 || p.cancel_state == 0;
    let cx = p.reach_ctx();
    let w = (n + 63) / 64;
    let mut refs = Vector::<u64>::new();
    refs.resize_default(n * w);
    let mut bodies = Vector::<usize>::new();
    bodies.resize_default(n);
    let mut scans = Vector::<loader::ReachScan>::new();
    if reach {
        scans.reserve(n);
        for _ in 0..n {
            scans.push(loader::ReachScan::new());
        }
    }
    let mut pre = BcPre {
        p: p,
        cx: &cx,
        refs: refs.as_ptr() as *mut u64,
        w: w,
        bodies: bodies.as_ptr() as *mut usize,
        scans: if reach {
            scans.as_ptr() as *mut loader::ReachScan;
        } else {
            null;
        },
    };
    let mut gp = sch::Jobs::independent(n);
    sch::run_jobs(&mut gp, p.jobs, bc_pre_job, &mut pre, null);
    p.mod_refs = refs;
    p.mod_refs_w = w;
    p.mod_refs_ready = true;
    if reach {
        p.reach_solve(&scans);
    }
    st0.pr.stop(bfi::BP_REACH, tr);
    // The keep holds every body from here on, and the evaluator views it while the stage runs
    // so a fold executes the kept bodies in place; the reserve keeps every slot in place under
    // that view.
    let tk = st0.pr.start();
    if keep != null {
        let mut nb: usize = 0;
        for m in 0..n {
            nb += bodies[m];
        }
        unsafe (&mut *keep).reserve_bodies(nb);
        let cirk = p.cir as *mut iri::Interp;
        if cirk != null {
            unsafe (*cirk).keep_view_set(keep);
        }
    }
    st0.pr.stop(bfi::BP_KEEP, tk);
    let ts = st0.pr.start();
    let par = p.jobs != 1 && n > 1;
    if par {
        set_stage_locks(p, true);
    }
    let mut jobs = Vector::<BcJob>::new();
    bc_jobs(p, &mut jobs);
    let ni = p.idx.items.len();
    let mut outs = Vector::<Option<Box<diag::Errors>>>::with_capacity(ni);
    for _ in 0..ni {
        outs.push(Option::<Box<diag::Errors>>::None);
    }
    let slots = psync::Mutex::<BcPool>::new(
        BcPool {
            idle: Vector::<BcSlot>::new(),
            unleased: jobs.len(),
            reported: p.icost_on || stdlib::getenv("SC_BORROW_STATS") != null,
        },
    );
    let mut st = BcStage {
        p: p,
        jobs: &jobs,
        outs: outs.index_mut(0),
        slots: ((&slots) as *const psync::Mutex<BcPool>) as *mut psync::Mutex<BcPool>,
        master: keep,
        validate: stdlib::getenv("SC_BC_VALIDATE") != null,
    };
    let mut g = sch::Jobs::independent(jobs.len());
    for j in 0..jobs.len() {
        // The memory gate's estimate: the module's source bytes, several times over for its IR.
        g.est.set(j, p.modules[jobs[j].m as usize].source.len() as u64 * 8);
    }
    let ctl = tctl::Ctl::new(tctl::budget_from_env());
    // The serial path's slot records the measurement (SC_ITEM_STATS).
    if p.icost_on {
        let mut s0 = bc_slot_new(p);
        s0.ctx.st.all = true;
        let mut g0 = slots.lock();
        g0.idle.push(s0);
    }
    st0.pr.stop(bfi::BP_SETUP, ts);
    sch::run_jobs(&mut g, p.jobs, bc_job, &mut st, &ctl);
    let tf = st0.pr.start();
    if par {
        set_stage_locks(p, false);
    }
    // Modules without a job (no syntax) are ready too.
    for m in 0..n {
        if !p.modules[m].has_ast {
            p.set_module_states(m, loader::IS_IR_READY);
        }
    }
    let mut ok = true;
    for m in 0..n {
        let mut errs = diag::Errors::new();
        for it in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
            append_errs(&mut errs, outs.index_mut(it));
        }
        errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
        if errs.has_errors() {
            ok = false;
            errs.log();
        }
    }
    st0.pr.stop(bfi::BP_SETUP, tf);
    {
        // Every slot's probe folds into one report; the retained-capacity line reads the first
        // slot (the serial path's only one).
        let mut pool = slots.lock();
        let all = &mut pool.idle;
        let mut st9 = st0;
        for i in 0..all.len() {
            st9.merge(&all.at(i).ctx.st);
        }
        if all.len() != 0 {
            bc_stats_print(&st9, &all.at(0).ctx);
            if p.icost_on {
                let c0 = all.index_mut(0);
                p.icost_bc = replace(&mut c0.ctx.st.body_ns, Vector::<u64>::new());
                p.icost_lw = replace(&mut c0.ctx.st.lower_ns, Vector::<u64>::new());
            }
        }
    }
    return ok;
}

fn bc_stats_new() bfi::BcStats {
    return bfi::BcStats::new(stdlib::getenv("SC_BORROW_STATS") != null, stdlib::getenv("SC_BUILD_MEM") != null);
}

fn bc_stats_print(st: &bfi::BcStats, ctx: &bfi::BorrowCtx) {
    if st.pr.on {
        let mut rep = String::new();
        st.report(ctx, &mut rep);
        rep.eprint();
    }
}

/// The message of a deferred static_assert that failed once the whole package was typed (`msg`:
/// the engine's detail, null for a condition that folded to false).
pub(package) fn flush_assert_text(msg: *const char) String {
    if msg != null {
        return format("static assertion cannot be evaluated: {}", unsafe str::from_cstr(msg));
    }
    return format("static assertion failed");
}

/// The message of a deferred call-bearing const initializer that still cannot be evaluated once
/// the package is typed.
pub(package) fn flush_const_text(msg: *const char) String {
    return format("constant cannot be evaluated at compile time: {}", unsafe str::from_cstr(msg));
}

// A deferred static_assert that failed: render it against the owning module.
fn flush_assert_err(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) {
    flush_err(ctx, dc::STATIC_ASSERTION_FAILED, m, cond, flush_assert_text(msg));
}

// A deferred const initializer that failed: render it against the owning module.
fn flush_const_err(ctx: *mut void, m: ModuleId, decl: NodeId, msg: *const char) {
    flush_err(ctx, dc::CONST_EVAL_FAILED, m, decl, flush_const_text(msg));
}

// Log error `msg` of `code` at node `id` of module `m` of the package `ctx` points to, and fail the package.
fn flush_err(ctx: *mut void, code: u16, m: ModuleId, id: NodeId, msg: String) {
    let p = ctx as *mut loader::Package;
    let mut errs = diag::Errors::new();
    errs.emit_span(code, unsafe (*p).modules[m as usize].ast.at_const(id).span, msg);
    errs.finalize(unsafe (*p).modules[m as usize].source.as_str(), unsafe (*p).modules[m as usize].file.as_str());
    errs.log();
    unsafe (*p).ok = false;
}

// (module, source position, record index) order of fold-failure references.
struct FoldRef {
    pub(package) key: u64, // module << 32 | span start
    pub(package) i: u32, // index in the recorded sequence (the engine's fold_errs, the refusals)
}

const fn fold_ref_cmp(a: &FoldRef, b: &FoldRef) i32 {
    if a.key != b.key {
        return if a.key < b.key {
            -1;
        } else {
            1;
        };
    }
    return a.i as i32 - b.i as i32;
}

// Promoted fold failures (proven UB, failed mandatory `const fn` folds) recorded by the evaluator:
// errors against the owning module; only the outermost record of nested failures is reported.
fn report_fold_errs(p: &mut loader::Package) {
    let cirp = p.cir as *mut iri::Interp;
    if cirp == null {
        return;
    }
    let fe = unsafe &(*cirp).fold_errs;
    // A node can record more than once across passes: the first record of each node stays.
    let mut seen = Set::<u64>::new();
    let mut refs = Vector::<FoldRef>::new();
    for i in 0..fe.len() {
        let e = fe.at(i);
        let nk = e.m as u64 << 32 | e.id as u64;
        if !seen.contains(&nk) {
            seen.insert(nk);
            refs.push(FoldRef { key: e.m as u64 << 32 | e.span.start as u64, i: i as u32 });
        }
    }
    // Canonical report order (module, then source position): recording order is scheduling order
    // under the parallel stages, and diagnostics must not depend on it. The index breaks ties as
    // the recording order did.
    refs.sort_by(fold_ref_cmp);
    // A record whose span another record of its module strictly contains is inner. In (module,
    // start) order the containing candidates are the module's records of an earlier start (their
    // largest end reaches this end) and of the same start (their largest end passes this end).
    let mut inner = Vector::<bool>::new();
    inner.resize_default(refs.len());
    let mut prev_end: i64 = -1; // the largest end of the module's earlier starts
    let mut g: usize = 0;
    while g < refs.len() {
        let key = refs[g].key;
        if g != 0 && refs[g - 1].key >> 32 != key >> 32 {
            prev_end = -1;
        }
        let mut h = g;
        let mut group_end: i64 = -1;
        while h < refs.len() && refs[h].key == key {
            let end = fe.at(refs[h].i as usize).span.end as i64;
            if end > group_end {
                group_end = end;
            }
            h += 1;
        }
        for k in g..h {
            let end = fe.at(refs[k].i as usize).span.end as i64;
            inner.set(k, prev_end >= end || group_end > end);
        }
        if group_end > prev_end {
            prev_end = group_end;
        }
        g = h;
    }
    for i in 0..refs.len() {
        let e = fe.at(refs[i].i as usize);
        let sp = e.span;
        if inner[i] {
            continue;
        }
        let mut errs = diag::Errors::new();
        if iri::it_trap_is_ub(e.kind) {
            errs.emit_span(
                dc::EXPRESSION_HAS_UNDEFINED_BEHAVIOR_WHEN_EVALUATED,
                sp,
                format("expression has undefined behavior when evaluated: {}", e.detail.as_str()),
            );
        } else {
            errs.emit_span(
                dc::CONST_FN_CALL_HAS_COMPILE_TIME,
                sp,
                format(
                    "this 'const fn' call has compile-time-known arguments but failed to evaluate: {}",
                    e.detail.as_str(),
                ),
            );
        }
        errs.finalize(p.modules[e.m as usize].source.as_str(), p.modules[e.m as usize].file.as_str());
        errs.log();
        p.ok = false;
    }
}

// One located error per array length an instance folded out of range, or per invalid vector type,
// noting the instantiation and the site that demanded it.
fn report_len_faults(p: &mut loader::Package, fs: &Vector<ig::LenFault>) {
    // A faulty type the user wrote passes into the std instances it reaches: a fault inside std
    // whose text a fault in user code reports is that fault again.
    let mut user = Set::<u64>::new();
    for i in 0..fs.len() {
        if !p.modules[fs.at(i).module as usize].prelude {
            user.insert(fnv(fs.at(i).msg.as_str()));
        }
    }
    for i in 0..fs.len() {
        let f = fs.at(i);
        if p.modules[f.module as usize].prelude && user.contains(&fnv(f.msg.as_str())) {
            continue;
        }
        let mut errs = diag::Errors::new();
        errs.emit_span_note(dc::INVALID_INSTANCE_TYPE, f.span, format("{}", f.msg.as_str()));
        if f.inst.node != NODE_NONE {
            let da = unsafe &*p.module_ast_const(f.inst.module);
            let dn = da.at_const(f.inst.node);
            let nm = if dn.kind == NodeKind::NODE_FUNCTION {
                da.ext_name(f.inst.node);
            } else {
                da.ext_name(f.inst.node);
            };
            let ns = da.at_const(nm).as_data.name.text;
            let name = p.modules[f.inst.module as usize].source.as_str().slice(ns.start as usize, ns.end as usize);
            if f.site.end != 0 {
                let sm = &p.modules[f.site_module as usize];
                let site = diag::render_site(
                    sm.source.as_str(),
                    sm.file.as_str(),
                    f.site.start,
                    f.site.end - f.site.start,
                );
                errs.note(format("in the instantiation of '{}' demanded here\n{}", name, site.as_str()));
            } else {
                errs.note(format("in an instantiation of '{}'", name));
            }
        }
        errs.finalize(p.modules[f.module as usize].source.as_str(), p.modules[f.module as usize].file.as_str());
        errs.log();
        p.ok = false;
    }
}

// One located error per refused body of the kind `depth` selects, in (module, source position)
// order: recording order is scheduling order under the parallel emission, and a body refused once
// per instance reports once. A depth refusal (nesting past the instantiation depth bound) is a user
// error; any other is internal. True when any was reported.
fn report_refusals(p: &loader::Package, rs: &mut Vector<cbe::Refusal>, depth: bool) bool {
    sort_refusals(rs);
    let mut any = false;
    for i in 0..rs.len() {
        let r = rs[i];
        if r.why == cbe::inst_depth_why() != depth || i > 0 && rs[i - 1].m == r.m && rs[i - 1].start == r.start && rs[i - 1].why == r.why {
            continue;
        }
        any = true;
        let msg = if depth {
            format("{}", r.why);
        } else {
            format("internal: the C backend cannot emit this body ({})", r.why);
        };
        let code = if depth {
            dc::INSTANCE_DEPTH_LIMIT;
        } else {
            dc::BACKEND_REFUSAL;
        };
        let mut errs = diag::Errors::new();
        errs.emit(code, r.start, r.end - r.start, msg);
        errs.finalize(p.modules[r.m as usize].source.as_str(), p.modules[r.m as usize].file.as_str());
        errs.log();
    }
    return any;
}

// (module, source position) order: recording order is scheduling order under the parallel emission.
// Records at one position keep their recording order.
fn sort_refusals(rs: &mut Vector<cbe::Refusal>) {
    let mut refs = Vector::<FoldRef>::new();
    refs.reserve(rs.len());
    for i in 0..rs.len() {
        refs.push(FoldRef { key: rs[i].m as u64 << 32 | rs[i].start as u64, i: i as u32 });
    }
    refs.sort_by(fold_ref_cmp);
    let mut out = Vector::<cbe::Refusal>::new();
    out.reserve(rs.len());
    for i in 0..refs.len() {
        out.push(rs[refs[i].i as usize]);
    }
    *rs = out;
}

// Global-phase compilation of a loaded package into a `<root>/build/` tree.

// --lint: unused non-pub items (functions/structs/unions/enums/interfaces/type aliases). Reachability v2:
// entries are top-level items + extend members (disjoint spans) + extend headers, whose edges reach
// interfaces only, so `extend Foo` alone is not a use of Foo. An item is live iff a root reaches it through the
// resolution graph, so dead cycles and dead-only callers are caught. Roots = everything exempt from
// reporting: `pub` (spc export layer), @export/@used/@emit_macro/extern (C export layer), @test*,
// main, bodyless fns, `extend X as Iface` conformance members, and every module outside the reported set
// (per-file `lint` invocations treat other modules as live; the full-build lint reports every module
// outside the std and ffi trees, so cross-module dead cycles are caught there).
struct LintEnt {
    pub(package) start: u32,
    pub(package) end: u32,
    pub(package) node: NodeId,
    pub(package) root: bool,
}

const LINT_NONE: u32 = 0xFFFFFFFF; // an item outside the entries
const LINT_IFACE: u32 = 0x80000000; // the item is an interface

const fn lint_ent_cmp(a: &LintEnt, b: &LintEnt) i32 {
    if a.start < b.start {
        return -1;
    }
    if a.start > b.start {
        return 1;
    }
    return 0;
}

// Publish module `m`'s lint findings: copy its fixes, tagged with `m`, into `fixes` when that is
// set, count the warnings, and log them when there is no fix list.
fn lint_flush(p: &mut loader::Package, m: usize, errs: &mut diag::Errors, fixes: *mut Vector<diag::LintFix>) {
    if fixes != null {
        for k in 0..errs.fixes.len() {
            let mut f = errs.fixes[k];
            f.module = m as u32;
            unsafe (*fixes).push(f);
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

// The bit of attribute kind `k` in an `attr_any` mask.
const fn attr_bit(k: AttrKind) u64 {
    return 1u64 << k as u64;
}

// True when `owner` carries an attribute whose kind bit is in `mask`: one scan of the attribute
// table for several kinds.
const fn attr_any(a: *const Ast, owner: NodeId, mask: u64) bool {
    for i in 0..unsafe (*a).attrs.len() {
        let at = unsafe (*a).attrs.at(i);
        if at.owner == owner && (1u64 << at.kind as u64 & mask) != 0 {
            return true;
        }
    }
    return false;
}

// Innermost entry containing byte `pos`, or -1 (extend headers, imports, inter-item trivia).
const fn lint_owner(ents: &Vector<LintEnt>, pos: u32) i64 {
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
// `lint` sharing one package), else `only_mod` (single-file lint), else every module outside the std
// and ffi trees (check.sh lints those).
const fn lint_reported(p: &loader::Package, m: usize, only_mod: i32) bool {
    if p.lint_set.len() != 0 {
        return p.lint_set[m];
    }
    if only_mod >= 0 {
        return m == only_mod as usize;
    }
    return !p.modules[m].prelude && !in_std_tree(p, m);
}

// Whether module `m` is read from the std or ffi tree. Nested std modules and ffi modules do not carry
// the prelude flag, so the file location is the reliable signal.
const fn in_std_tree(p: &loader::Package, m: usize) bool {
    let f = p.modules[m].file.as_str();
    if f.starts_with("std/") || f.starts_with("ffi/") || f.starts_with("./std/") || f.starts_with("./ffi/") {
        return true;
    }
    let sr = p.std_root.as_str();
    if sr.len() != 0 && f.len() > sr.len() + 5 && f.starts_with(sr) {
        let rest = f.slice(sr.len() + 1, f.len());
        return rest.starts_with("std/") || rest.starts_with("ffi/");
    }
    return false;
}

fn lint_build_entries(p: &loader::Package, m: usize, only_mod: i32, ents: &mut Vector<LintEnt>) {
    let a = p.module_ast_const(m as ModuleId);
    // Items of a module reported this run are candidates; everything else roots the graph.
    let reported = lint_reported(p, m, only_mod);
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        let it = unsafe (*a).at_const(iid);
        if it.kind == NodeKind::NODE_IMPORT {
            continue;
        }
        if it.kind == NodeKind::NODE_EXTEND {
            let in_iface = unsafe (*a).ext(iid).extend_def.interface_type != NODE_NONE;
            // The header (target, interface, parameter bounds): a conformance uses its interface and
            // the interfaces of its bounds, never reported itself.
            ents.push(LintEnt { start: it.span.start, end: it.span.start + 1, node: iid, root: in_iface });
            let ms = unsafe (*a).ext(iid).extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe (*a).list(ms)[j as usize];
                let msp = unsafe (*a).at_const(mid).span;
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
        // The program entry `main` is never reported, always a root.
        if !root && it.kind == NodeKind::NODE_FUNCTION && p.is_entry(m as ModuleId, iid) {
            root = true;
        }
        ents.push(LintEnt { start: it.span.start, end: it.span.end, node: iid, root: root });
    }
    ents.sort_by(lint_ent_cmp);
}

// Whether the binary-project pub lint applies to module `m`: never to the std/ffi trees, which are
// libraries whose `pub` is API for downstream programs, even when they sit inside the workspace.
const fn lint_pub_applies(p: &loader::Package, m: usize) bool {
    return p.lint_pub && !p.modules[m].prelude && !in_std_tree(p, m);
}

fn lint_item_candidate(a: *const Ast, iid: NodeId, in_iface_extend: bool, pub_too: bool) bool {
    let it = unsafe (*a).at_const(iid);
    // Everything inside a conformance is required BY the conformance: a method implements one of its
    // methods, a `type X = ..` binds one of its associated types. Neither is dead for want of a caller.
    if in_iface_extend {
        return false;
    }
    let keep = attr_bit(AttrKind::ATTR_EXPORT) | attr_bit(AttrKind::ATTR_USED);
    if it.kind == NodeKind::NODE_FUNCTION {
        let f = unsafe (*a).ext(iid).function;
        if vis_exported(f.vis) && !pub_too || f.is_extern() || f.body == NODE_NONE {
            return false;
        }
        return !attr_any(
            a,
            iid,
            keep | attr_bit(AttrKind::ATTR_TEST) | attr_bit(AttrKind::ATTR_TEST_INIT) | attr_bit(
                AttrKind::ATTR_TEST_FREE,
            ) | attr_bit(AttrKind::ATTR_BENCH) | attr_bit(AttrKind::ATTR_SIMD_IMPL),
        );
    }
    if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
        return !vis_exported(unsafe (*a).ext(iid).aggregate.vis) && !attr_any(
            a,
            iid,
            keep | attr_bit(AttrKind::ATTR_EMIT_MACRO),
        );
    }
    if it.kind == NodeKind::NODE_INTERFACE {
        return !vis_exported(unsafe (*a).ext(iid).interface_def.vis) && !attr_any(a, iid, keep);
    }
    if it.kind == NodeKind::NODE_TYPE_ALIAS {
        return !vis_exported(it.as_data.type_alias.vis) && !attr_any(a, iid, keep);
    }
    return false;
}

// The name node of a candidate item of the unused-item lint (`lint_item_candidate`), NODE_NONE for
// any other kind.
const fn lint_item_name(a: *const Ast, iid: NodeId) NodeId {
    let it = unsafe (*a).at_const(iid);
    if it.kind == NodeKind::NODE_FUNCTION {
        return unsafe (*a).ext_name(iid);
    }
    if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
        return unsafe (*a).ext_name(iid);
    }
    if it.kind == NodeKind::NODE_INTERFACE {
        return unsafe (*a).ext_name(iid);
    }
    if it.kind == NodeKind::NODE_TYPE_ALIAS {
        return it.as_data.type_alias.name;
    }
    return NODE_NONE;
}

// The sorted distinct name hashes of every module's code the platform filter removed (`Ast.bc_names`).
fn bc_removed_names(p: &loader::Package) Vector<u64> {
    let mut all = Vector::<u64>::new();
    for m in 0..p.modules.len() {
        let ns = &p.modules[m].ast.bc_names;
        for k in 0..ns.len() {
            all.push(ns[k]);
        }
    }
    all.sort();
    all.dedup();
    return all;
}

fn lint_report_item(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: ModuleId, iid: NodeId) {
    let it = unsafe (*a).at_const(iid);
    // A `@reflect`-tagged declaration is REACHED at startup: its exported descriptor registers
    // itself, and the metadata is the point even when no code names the type.
    if it.kind == NodeKind::NODE_STRUCT || it.kind == NodeKind::NODE_ENUM {
        let nmet = (unsafe (*a).metas).len();
        for k in 0..nmet {
            if (unsafe (*a).metas).at(k).owner == iid {
                return;
            }
        }
    }
    let src = p.modules[m as usize].source.as_str();
    let what = if it.kind == NodeKind::NODE_FUNCTION {
        "function";
    } else if it.kind == NodeKind::NODE_STRUCT && unsafe (*a).ext(iid).aggregate.is_union {
        "union";
    } else if it.kind == NodeKind::NODE_STRUCT {
        "struct";
    } else if it.kind == NodeKind::NODE_ENUM {
        "enum";
    } else if it.kind == NodeKind::NODE_INTERFACE {
        "interface";
    } else {
        "type alias";
    };
    let nid = lint_item_name(a, iid);
    let nsp = unsafe (*a).at_const(nid).as_data.name.text;
    if it.kind == NodeKind::NODE_FUNCTION && p.is_entry(m, iid) {
        return;
    }
    if it.kind == NodeKind::NODE_FUNCTION && vis_exported(unsafe (*a).ext(iid).function.vis) {
        errs.warn_span(
            dc::UNUSED_PUBLIC_FUNCTION_NOTHING_BINARY_REACHES,
            nsp,
            format(
                "unused public function '{}': nothing in this binary reaches it",
                diag::span_str(src, nsp.start, nsp.end),
            ),
        );
        return;
    }
    errs.warn_span(dc::UNUSED, nsp, format("unused {} '{}'", what, diag::span_str(src, nsp.start, nsp.end)));
}

// The entry of item `iid`: entries may share a start (the extends one `@derive` writes), so the scan
// from the first entry at the item's start checks the node.
fn lint_entry(a: *const Ast, ents: &Vector<LintEnt>, iid: NodeId) usize {
    let start = unsafe (*a).at_const(iid).span.start;
    let mut lo: usize = 0;
    let mut hi = ents.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if ents[mid].start < start {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    while ents[lo].node != iid {
        lo += 1;
    }
    return lo;
}

/// `sink` null: the findings log (and count) per module; else module `m`'s warnings go to
/// `sink[m]`, unfinalized (the language server publishes them itself).
pub(package) fn lint_unused_items(p: &mut loader::Package, only_mod: i32, sink: *mut Vector<diag::Errors>) {
    let nm = p.modules.len();
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
    // Code the platform filter removed may hold the only use of an item: an item its text names is used.
    let removed = bc_removed_names(p);
    let mut ents = Vector::<Vector<LintEnt>>::new();
    for m in 0..nm {
        let mut e = Vector::<LintEnt>::new();
        if p.modules[m].has_ast && (!p.modules[m].prelude || inc_prelude) {
            lint_build_entries(p, m, only_mod, &mut e);
            if removed.len() != 0 {
                let a = p.module_ast_const(m as ModuleId);
                let src = p.modules[m].source.as_str();
                for k in 0..e.len() {
                    let nid = lint_item_name(a, e[k].node);
                    if !e[k].root && nid != NODE_NONE {
                        let nsp = unsafe (*a).at_const(nid).as_data.name.text;
                        if removed.binary_search(&fnv(src.slice(nsp.start as usize, nsp.end as usize))).is_ok() {
                            e.index_mut(k).root = true;
                        }
                    }
                }
            }
        }
        ents.push(e);
    }
    // One reachable flag per entry: entry `k` of module `m` is `ebase[m] + k`.
    let mut ebase = Vector::<u32>::with_capacity(nm);
    let mut ne: u32 = 0;
    for m in 0..nm {
        ebase.push(ne);
        ne += ents[m].len() as u32;
    }
    assert(ne < LINT_IFACE, "entry ids leave the interface bit free");
    let mut used = Vector::<bool>::new();
    used.resize_default(ne as usize);
    // Each entry enters the queue once, when it is first reached.
    let mut queue = Vector::<u32>::with_capacity(ne as usize);
    for m in 0..nm {
        for k in 0..ents[m].len() {
            if ents[m][k].root {
                used.set(ebase[m] as usize + k, true);
                queue.push(ebase[m] + k as u32);
            }
        }
    }
    // The item index's dependency edges stand in for the resolution scan: one edge per (owner item,
    // target item), the owner the entry `lint_owner` attributes the item's node to, without the
    // releasable body syntax. `iown`: each item's owner entry, LINT_NONE outside the entries, with
    // LINT_IFACE when the item is an interface (the one target an extend header uses).
    assert(p.sched.final_edges, "the post-typecheck item edges precede the unused-item lint");
    let ni = p.idx.items.len();
    let mut iown = Vector::<u32>::with_capacity(ni);
    for it in 0..ni {
        let tm = p.idx.items.at(it);
        let dm = tm.module as usize;
        let mut o = LINT_NONE;
        if dm < nm && ents[dm].len() != 0 {
            let nd = unsafe (*p.module_ast_const(tm.module)).at_const(tm.node);
            let di = lint_owner(ents.at(dm), nd.span.start);
            if di >= 0 {
                o = ebase[dm] + di as u32 | pick(nd.kind == NodeKind::NODE_INTERFACE, LINT_IFACE, 0u32);
            }
        }
        iown.push(o);
    }
    let mut edges = Vector::<u64>::new();
    for m in 0..nm {
        if ents[m].len() == 0 {
            continue;
        }
        let a = p.module_ast_const(m as ModuleId);
        let i0 = p.idx.mod_items[m] as usize;
        let i1 = p.idx.mod_items[m + 1] as usize;
        for it in i0..i1 {
            if iown[it] == LINT_NONE {
                continue;
            }
            let ss = iown[it] & ~LINT_IFACE;
            let header = unsafe (*a).at_const(ents[m][(ss - ebase[m]) as usize].node).kind == NodeKind::NODE_EXTEND;
            for e in p.sched.fin_off[it] as usize..p.sched.fin_off[it + 1] as usize {
                let d = iown[p.sched.fin_edges[e] as usize];
                // An extend's target is not used by being extended.
                if d == LINT_NONE || header && (d & LINT_IFACE) == 0 {
                    continue;
                }
                let ds = d & ~LINT_IFACE;
                if ss != ds {
                    edges.push(ss as u64 << 32 | ds as u64);
                }
            }
        }
        // `a * b` resolves the method by NAME, so the resolution table holds no edge to it. The method
        // references the type checker recorded do, and they carry the body each one sits in.
        let mrefs = unsafe (*a).method_refs_live();
        for i in 0..mrefs.len() {
            let r = *mrefs.at(i);
            let dm = r.callee.module as usize;
            if r.callee.node == NODE_NONE || dm >= nm || ents[dm].len() == 0 {
                continue;
            }
            let ta = p.module_ast_const(r.callee.module);
            let di = lint_owner(ents.at(dm), unsafe (*ta).at_const(r.callee.node).span.start);
            if di < 0 {
                continue;
            }
            let ds = ebase[dm] + di as u32;
            if r.owner == NODE_NONE {
                if !used[ds as usize] {
                    used.set(ds as usize, true);
                    queue.push(ds);
                }
                continue;
            }
            let si2 = lint_owner(ents.at(m), unsafe (*a).at_const(r.owner).span.start);
            if si2 < 0 {
                continue;
            }
            let ss = ebase[m] + si2 as u32;
            if ss != ds {
                edges.push(ss as u64 << 32 | ds as u64);
            }
        }
    }
    // The edges bucketed by source (a counting sort): entry `s` reaches `adj[off[s]..off[s + 1]]`.
    let mut off = Vector::<u32>::new();
    off.resize_default(ne as usize + 1);
    for i in 0..edges.len() {
        let s = (edges[i] >> 32) as usize;
        off.set(s, off[s] + 1);
    }
    for s in 1..ne as usize + 1 {
        off.set(s, off[s] + off[s - 1]);
    }
    let mut adj = Vector::<u32>::new();
    adj.resize_default(edges.len());
    for i in 0..edges.len() {
        let s = (edges[i] >> 32) as usize;
        off.set(s, off[s] - 1);
        adj.set(off[s] as usize, edges[i] as u32);
    }
    let mut qi: usize = 0;
    while qi < queue.len() {
        let s = queue[qi] as usize;
        qi = qi + 1;
        for e in off[s] as usize..off[s + 1] as usize {
            let d = adj[e] as usize;
            if !used[d] {
                used.set(d, true);
                queue.push(d as u32);
            }
        }
    }
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = p.module_ast_const(m as ModuleId);
        let es = ents.at(m);
        let eb = ebase[m] as usize;
        let pa = lint_pub_applies(p, m);
        let mut errs = diag::Errors::new();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND {
                let in_iface = unsafe (*a).ext(iid).extend_def.interface_type != NODE_NONE;
                let ms = unsafe (*a).ext(iid).extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*a).list(ms)[j as usize];
                    if lint_item_candidate(a, mid, in_iface, pa) && !used[eb + lint_entry(a, es, mid)] {
                        lint_report_item(p, &mut errs, a, m as ModuleId, mid);
                    }
                }
            } else if lint_item_candidate(a, iid, false, pa) && !used[eb + lint_entry(a, es, iid)] {
                lint_report_item(p, &mut errs, a, m as ModuleId, iid);
            }
        }
        if sink != null {
            unsafe (*sink).index_mut(m).append(&mut errs);
        } else {
            lint_flush(p, m, &mut errs, null);
        }
    }
}

// Is `fnode` a test-family item (@test/@test_init/@test_free)? Skipped entirely outside --test.
const fn is_test_item(a: *const Ast, fnode: NodeId) bool {
    return attr_any(
        a,
        fnode,
        attr_bit(AttrKind::ATTR_TEST) | attr_bit(AttrKind::ATTR_TEST_INIT) | attr_bit(AttrKind::ATTR_TEST_FREE),
    );
}

fn ap_check_fn(errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId, cev: *mut iri::Interp) {
    if unsafe (*a).at_const(fnode).kind != NodeKind::NODE_FUNCTION || is_test_item(a, fnode) {
        return;
    }
    let sp = unsafe (*cev).lint_body(m as ModuleId, fnode);
    if sp.end > sp.start {
        if iri::it_trap_is_ub(unsafe (*cev).trap_kind_get()) {
            errs.emit_span(
                dc::STATEMENT_UNDEFINED_BEHAVIOR_WHEN_EXECUTED,
                sp,
                format("this statement is undefined behavior when executed: {}", unsafe (*cev).trap_detail()),
            );
        } else {
            errs.emit_span(
                dc::STATEMENT_ALWAYS_PANICS_RUNTIME,
                sp,
                format("this statement always panics at runtime: {}", unsafe (*cev).trap_detail()),
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
pub(package) fn check_always_panics_module(p: &mut loader::Package, m: usize, errs: &mut diag::Errors) {
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
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ms = unsafe (*a).ext(iid).extend_def.items;
            for j in 0..ms.len {
                ap_check_fn(errs, a, m, unsafe (*a).list(ms)[j as usize], cev);
            }
        } else {
            ap_check_fn(errs, a, m, iid, cev);
        }
    }
}

// --lint: functions the deep (all-paths) CTFE scan proves always evaluable, which pass the def-site
// check as `const fn`. The fix (insert `const ` before the `fn` keyword, which lands AFTER any
// `pub`/`unsafe`, the canonical order) applies only under `--fix`.
// Conformance members are skipped (the interface fixes the signature), as are @test fns, `main` and
// `@no_const` fns: a panic the always-panics check proves through a `const fn` frame is an error, so a
// function whose every call may panic (std's `panic`) takes the tag and is never suggested.
fn cs_check_fn(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId, in_iface: bool) {
    if unsafe (*a).at_const(fnode).kind != NodeKind::NODE_FUNCTION || in_iface || is_test_item(a, fnode) || attr_any(
        a,
        fnode,
        attr_bit(AttrKind::ATTR_NO_CONST),
    ) {
        return;
    }
    let f = unsafe (*a).ext(fnode).function;
    // A build-constant site this build decided removed code another build runs, which may call what a
    // constant cannot (an extern under LOCKDEP): such a function gets no suggestion.
    if f.is_const() || f.is_extern() || f.body == NODE_NONE || unsafe (*a).bc_cut_at(
        fnode,
        unsafe (*a).at_const(fnode).span,
    ) {
        return;
    }
    let src = p.modules[m].source.as_str();
    let nsp = unsafe (*a).at_const(f.name).as_data.name.text;
    if p.is_entry(m as ModuleId, fnode) {
        return;
    }
    let cev = p.cir as *mut iri::Interp;
    if unsafe (*cev).fn_const_suggest(m as ModuleId, fnode) {
        errs.warn_span(
            dc::FUNCTION_CAN_DECLARED_CONST_FN,
            nsp,
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
        if !p.modules[m].has_ast || !lint_reported(p, m, only_mod) {
            continue;
        }
        let a = p.module_ast_const(m as ModuleId);
        let mut errs = diag::Errors::new();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
                let in_iface = unsafe (*a).ext(iid).extend_def.interface_type != NODE_NONE;
                let ms = unsafe (*a).ext(iid).extend_def.items;
                for j in 0..ms.len {
                    cs_check_fn(p, &mut errs, a, m, unsafe (*a).list(ms)[j as usize], in_iface);
                }
            } else {
                cs_check_fn(p, &mut errs, a, m, iid, false);
            }
        }
        lint_flush(p, m, &mut errs, fixes);
    }
}

// --lint: unused imports. An import is removable when neither its target module nor anything in the
// target's transitive closure defines a symbol this file resolves to (own-module hits are excluded:
// legal import cycles would otherwise self-justify). Modules whose closure carries link-time side
// effects (@link) or extends a foreign type (methods/conformances reachable without a
// resolution edge) are exempt.
// A module with @platform-, @arch- or @when-gated items is exempt from cross-item unused lints (imports,
// members): the dropped items' uses are invisible under the current target, so a per-target verdict
// would contradict another target's. Code the early prune removed exempts only the names its text
// spells.
const fn module_platform_gated(a: *const Ast) bool {
    for i in 0..unsafe (*a).attrs.len() {
        let k = unsafe (*a).attrs.at(i).kind;
        if k == AttrKind::ATTR_PLATFORM as u8 || k == AttrKind::ATTR_ARCH as u8 || k == AttrKind::ATTR_WHEN as u8 {
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
    for i in 0..unsafe (*a).attrs.len() {
        let k = unsafe (*a).attrs.at(i).kind;
        if k == AttrKind::ATTR_C_LINK as u8 {
            return true;
        }
    }
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
            let d = unsafe (*a).resolution_def(unsafe (*a).ext(iid).extend_def.target_type);
            let tt = unsafe (*a).type_of(unsafe (*a).ext(iid).extend_def.target_type);
            if d.node == NODE_NONE || d.module != mid || ext_blanket(unsafe &*a, tt, unsafe &*a, mid, iid) >= 0 {
                // Extends a foreign (or unresolved) type, or every type a generic extend's bounds admit.
                return true;
            }
        }
    }
    return false;
}

// Whether code the platform filter removed from module `a` (source `src`) may use import `iid` through
// module `mid` (the import's target or a module of its closure): a glob import's names are unknown, a
// named one's leading name (the alias, or the module's last path segment) is spelled.
fn import_removed_use(p: &loader::Package, a: *const Ast, src: str, iid: NodeId, mid: ModuleId) bool {
    if unsafe (*a).bc_names.len() == 0 {
        return false;
    }
    let im = unsafe (*a).at_const(iid).as_data.import_decl;
    if im.glob {
        return true;
    }
    if im.alias != NODE_NONE {
        let asp = unsafe (*a).at_const(im.alias).as_data.name.text;
        if unsafe (*a).bc_removed_name(src.slice(asp.start as usize, asp.end as usize)) {
            return true;
        }
    }
    let path = p.modules[mid as usize].path.as_str();
    let mut st = path.len();
    while st > 0 && path[st - 1] != b':' {
        st -= 1;
    }
    return unsafe (*a).bc_removed_name(path.slice(st, path.len()));
}

fn lint_unused_imports(p: &mut loader::Package, only_mod: i32, fixes: *mut Vector<diag::LintFix>) {
    let nm = p.modules.len();
    for m in 0..nm {
        if !p.modules[m].has_ast || p.modules[m].prelude || !lint_reported(p, m, only_mod) {
            continue;
        }
        let mut unused = Vector::<NodeId>::new();
        unused_imports(p, m, &mut unused);
        let a = p.module_ast_const(m as ModuleId);
        let src = p.modules[m].source.as_str();
        let mut errs = diag::Errors::new();
        for k in 0..unused.len() {
            let iid = unused[k];
            let path = loader::join_parts(unsafe &*a, src, unsafe (*a).at_const(iid).as_data.import_decl.path, "::");
            let sp = unsafe (*a).at_const(iid).span;
            errs.warn_span(dc::UNUSED_IMPORT, sp, format("unused import '{}'", path.as_str()));
            let mut fe = sp.end;
            if fe as usize < src.len() && src[fe as usize] == b'\n' {
                fe = fe + 1;
            }
            errs.fix(sp.start, fe, 0);
        }
        lint_flush(p, m, &mut errs, fixes);
    }
}

/// The import declarations of module `m` that it uses nothing of: no name it resolves comes from the imported
/// module or its import closure, and the module has no side effects an import brings. Reads the module's
/// resolutions, its bodies' included; a module gated out for the target, or a glob import of a module that
/// another module imports (it re-exports), reports none.
pub(package) fn unused_imports(p: &mut loader::Package, m: usize, out: &mut Vector<NodeId>) {
    let nm = p.modules.len();
    p.ensure_index();
    let mut imported = Vector::<bool>::new();
    imported.resize_default(nm);
    for k in 0..p.idx.imports.len() {
        imported.set(p.idx.imports[k] as usize, true);
    }
    let a = p.module_ast_const(m as ModuleId);
    if module_platform_gated(a) {
        return;
    }
    let mut usedm = Vector::<bool>::new();
    usedm.resize_default(nm);
    for i in 0..unsafe (*a).nnodes() {
        let d = unsafe (*a).resolution_def(unsafe (*a).nth_id(i));
        if d.node != NODE_NONE && d.module as usize < nm && d.module as usize != m {
            usedm.set(d.module as usize, true);
        }
    }
    let src = p.modules[m].source.as_str();
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        if unsafe (*a).at_const(iid).kind != NodeKind::NODE_IMPORT {
            continue;
        }
        // A glob import re-exports its module's names (`m::x` reaches them): only a module nothing imports
        // can hold an unused one.
        if unsafe (*a).at_const(iid).as_data.import_decl.glob && imported[m] {
            continue;
        }
        let path = loader::join_parts(unsafe &*a, src, unsafe (*a).at_const(iid).as_data.import_decl.path, "::");
        let mid = p.find_in(m as ModuleId, path.as_str());
        if mid < 0 || mid as usize == m {
            continue;
        }
        let mut used = usedm[mid as usize] || import_side_effects(p, mid as ModuleId) || import_removed_use(
            p,
            a,
            src,
            iid,
            mid as ModuleId,
        );
        if !used {
            let clo = p.import_closure(mid as ModuleId);
            for c in 0..clo.len() {
                let cm = clo[c];
                if cm as usize != m && (usedm[cm as usize] || import_side_effects(p, cm) || import_removed_use(
                    p,
                    a,
                    src,
                    iid,
                    cm,
                )) {
                    used = true;
                    break;
                }
            }
        }
        if !used {
            out.push(iid);
        }
    }
}

// --lint: an expression statement calling a provably pure function (deep FX_YES, value-only params,
// non-generic) whose results are dropped computes nothing observable: dead code. The trailing
// statement of every block is exempt (it may be the block's value in expression position).
fn dp_check_stmt(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, sid: NodeId) {
    if unsafe (*a).at_const(sid).kind != NodeKind::NODE_EXPRESSION_STATEMENT {
        return;
    }
    let mut v = unsafe (*a).at_const(sid).as_data.single.value;
    while unsafe (*a).at_const(v).kind == NodeKind::NODE_UNARY && (unsafe (*a).at_const(v).as_data.unary.op == TokenType::Move || unsafe (*a).at_const(
        v,
    ).as_data.unary.op == TokenType::Unsafe) {
        v = unsafe (*a).at_const(v).as_data.unary.operand;
    }
    if unsafe (*a).at_const(v).kind != NodeKind::NODE_CALL {
        return;
    }
    let mut callee = unsafe (*a).at_const(v).as_data.call.callee;
    if unsafe (*a).at_const(callee).kind == NodeKind::NODE_GENERIC_SPECIALIZATION {
        callee = unsafe (*a).at_const(callee).as_data.specialization.expression;
    }
    let ck = unsafe (*a).at_const(callee).kind;
    if ck != NodeKind::NODE_IDENTIFIER && !(ck == NodeKind::NODE_MEMBER && unsafe (*a).at_const(callee).as_data.member.path) {
        return;
    }
    let mut fd = unsafe (*a).resolution_def(callee);
    if fd.node == NODE_NONE && ck == NodeKind::NODE_MEMBER {
        fd = unsafe (*a).resolution_def(unsafe (*a).at_const(callee).as_data.member.member);
    }
    if fd.node == NODE_NONE && ck == NodeKind::NODE_IDENTIFIER {
        fd = DefId { module: m as ModuleId, node: unsafe (*a).resolution(callee) };
    }
    if fd.node == NODE_NONE || fd.module as usize >= p.modules.len() || !p.modules[fd.module as usize].has_ast {
        return;
    }
    let fa = p.module_ast_const(fd.module);
    if unsafe (*fa).at_const(fd.node).kind != NodeKind::NODE_FUNCTION {
        return;
    }
    let f = unsafe (*fa).ext(fd.node).function;
    if f.is_extern() || f.body == NODE_NONE || f.returns.len == 0 || f.generics.len != 0 {
        return;
    }
    for i in 0..f.params.len {
        let pid = unsafe (*fa).list(f.params)[i as usize];
        if unsafe (*fa).at_const(pid).kind != NodeKind::NODE_PARAMETER {
            return;
        }
        let tk = unsafe (*fa).at_const(unsafe (*fa).at_const(pid).as_data.parameter.ty).kind;
        if tk == NodeKind::NODE_POINTER_TYPE || tk == NodeKind::NODE_REFERENCE_TYPE || tk == NodeKind::NODE_SLICE_TYPE || tk == NodeKind::NODE_DYN_TYPE || tk == NodeKind::NODE_FUNCTION_TYPE {
            // A reference-carrying param could observe or mutate caller state.
            return;
        }
    }
    let cev = p.cir as *mut iri::Interp;
    if !unsafe (*cev).fn_const_suggest(fd.module, fd.node) {
        return;
    }
    let csp = unsafe (*a).at_const(callee).span;
    let src = p.modules[m].source.as_str();
    let ssp = unsafe (*a).at_const(sid).span;
    errs.warn_span(
        dc::UNUSED_RESULT_PURE_FUNCTION_CALL_HAS,
        ssp,
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
        let n = unsafe (*a).nnodes();
        for k in 1..n {
            let i = unsafe (*a).nth_id(k);
            if unsafe (*a).at_const(i).kind == NodeKind::NODE_BLOCK {
                let stmts = unsafe (*a).at_const(i).as_data.block.statements;
                if stmts.len > 1 {
                    for j in 0..stmts.len - 1 {
                        dp_check_stmt(p, &mut errs, a, m, unsafe (*a).list(stmts)[j as usize]);
                    }
                }
            }
        }
        lint_flush(p, m, &mut errs, null);
    }
}

// --lint: private struct fields and tagged-enum variants no resolution anywhere targets. Fields of
// pub/attributed/union/tuple structs are exempt (FFI layout, positional access); plain enums are
// exempt entirely (int casts materialize variants without naming them).
fn lint_unused_members(p: &mut loader::Package, only_mod: i32) {
    let nm = p.modules.len();
    let removed = bc_removed_names(p);
    let mut starts = Vector::<usize>::new();
    let mut total: usize = 0;
    for m in 0..nm {
        starts.push(total);
        if p.modules[m].has_ast {
            total = total + p.modules[m].ast.nnodes();
        }
    }
    let mut used = Vector::<bool>::new();
    used.resize_default(total);
    let mut read = Vector::<bool>::new();
    read.resize_default(total);
    for m in 0..nm {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = p.module_ast_const(m as ModuleId);
        // Struct-literal initializer names resolve to the field decl but only WRITE it: exclude
        // them from the read set (fields warn on never-READ, Rust semantics).
        let an = unsafe (*a).nnodes();
        let mut init_src = Vector::<bool>::new();
        init_src.resize_default(an);
        for k in 1..an {
            let kid = unsafe (*a).nth_id(k);
            if unsafe (*a).at_const(kid).kind == NodeKind::NODE_FIELD_INITIALIZER {
                let fnn = unsafe (*a).at_const(kid).as_data.field_initializer.name;
                if unsafe (*a).valid(fnn) {
                    init_src.set(unsafe (*a).dense(fnn), true);
                }
            }
        }
        for k in 0..an {
            let d = unsafe (*a).resolution_def(unsafe (*a).nth_id(k));
            if d.node != NODE_NONE && d.module as usize < nm && p.modules[d.module as usize].has_ast && p.modules[d.module as usize].ast.valid(
                d.node,
            ) {
                let slot = starts[d.module as usize] + p.modules[d.module as usize].ast.dense(d.node);
                used.set(slot, true);
                if !init_src[k] {
                    read.set(slot, true);
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
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind != NodeKind::NODE_STRUCT && it.kind != NodeKind::NODE_ENUM {
                continue;
            }
            if vis_exported(unsafe (*a).ext(iid).aggregate.vis) || unsafe (*a).ext(iid).aggregate.is_union {
                continue;
            }
            let keep = attr_bit(AttrKind::ATTR_EXPORT) | attr_bit(AttrKind::ATTR_USED) | attr_bit(
                AttrKind::ATTR_EMIT_MACRO,
            );
            if attr_any(a, iid, keep | attr_bit(AttrKind::ATTR_PACKED) | attr_bit(AttrKind::ATTR_ALIGN)) {
                continue;
            }
            if it.kind == NodeKind::NODE_ENUM && !unsafe (*a).enum_has_payload(iid) {
                continue;
            }
            let ms = unsafe (*a).ext(iid).aggregate.members;
            for j in 0..ms.len {
                let mid2 = unsafe (*a).list(ms)[j as usize];
                let mn = unsafe (*a).at_const(mid2);
                let mut nsp = tok::Span::empty();
                if it.kind == NodeKind::NODE_STRUCT {
                    if mn.kind != NodeKind::NODE_FIELD || vis_exported(mn.as_data.field.vis) {
                        continue;
                    }
                    nsp = unsafe (*a).at_const(mn.as_data.field.name).as_data.name.text;
                } else {
                    if mn.kind != NodeKind::NODE_VARIANT {
                        continue;
                    }
                    nsp = unsafe (*a).at_const(mn.as_data.variant.name).as_data.name.text;
                }
                let hit = if it.kind == NodeKind::NODE_STRUCT {
                    read[starts[m] + mid2 as usize];
                } else {
                    used[starts[m] + mid2 as usize];
                };
                // Code the platform filter removed may hold the only use.
                if nsp.end <= nsp.start || src[nsp.start as usize] == b'_' || hit || removed.binary_search(
                    &fnv(src.slice(nsp.start as usize, nsp.end as usize)),
                ).is_ok() {
                    continue;
                }
                if it.kind == NodeKind::NODE_STRUCT {
                    errs.warn_span(
                        dc::FIELD_NEVER_READ,
                        nsp,
                        format("field '{}' is never read", diag::span_str(src, nsp.start, nsp.end)),
                    );
                } else {
                    errs.warn_span(
                        dc::UNUSED_VARIANT,
                        nsp,
                        format("unused variant '{}'", diag::span_str(src, nsp.start, nsp.end)),
                    );
                }
            }
        }
        lint_flush(p, m, &mut errs, null);
    }
}

// ---- The always-panics stage ----------------------------------------------------------------
// The borrow stage's jobs (one per linted module) over the function and method items, after
// every item is IrReady: a scan is a query, so a parallel job runs a private engine (leased
// from a pool, its memos kept across the jobs it serves; budgets copy from the master so traps
// classify identically) and the serial path the master engine. Diagnostics publish per item in
// item order.

struct ApStage {
    pub(package) p: *mut loader::Package,
    pub(package) jobs: *const Vector<BcJob>,
    pub(package) outs: *mut Option<Box<diag::Errors>>, // per item
    pub(package) engines: *mut Vector<Box<iri::Interp>>, // idle private engines, under `elock`
    pub(package) unleased: *mut usize, // jobs that have not taken an engine yet, under `elock`
    pub(package) elock: *mut i32,
    pub(package) ran0: *const Set<u64>, // the master's `ran0` as the stage starts, which the master grows during it
}

fn ap_engine_take(st: &ApStage) Box<iri::Interp> {
    unsafe sc_runtime::sc_rt_spin_lock(st.elock);
    assert(unsafe *st.unleased != 0, "each always-panics job takes one engine");
    unsafe *st.unleased -= 1;
    switch (unsafe &mut *st.engines).pop() {
        Some(e) => {
            unsafe sc_runtime::sc_rt_spin_unlock(st.elock);
            return e;
        },
        _ => {},
    };
    unsafe sc_runtime::sc_rt_spin_unlock(st.elock);
    let mut cev = iri::interp_new(st.p);
    let master = (unsafe (&*st.p).cir) as *mut iri::Interp;
    cev.all_typed = true;
    cev.max_steps = unsafe (&*master).max_steps;
    cev.max_slots = unsafe (&*master).max_slots;
    cev.keep_view = unsafe (&*master).keep_view;
    cev.record_folds = unsafe (&*master).record_folds;
    for k in unsafe (*st.ran0).iter() {
        cev.ran0.insert(*k);
    }
    return Box::new(cev);
}

// An engine returned after every job has taken one has no next job: its counters and fold failures
// join the master's and it is freed at once.
fn ap_engine_give(st: &ApStage, e: Box<iri::Interp>) {
    unsafe sc_runtime::sc_rt_spin_lock(st.elock);
    if unsafe *st.unleased != 0 {
        (unsafe &mut *st.engines).push(e);
        unsafe sc_runtime::sc_rt_spin_unlock(st.elock);
        return;
    }
    unsafe sc_runtime::sc_rt_spin_unlock(st.elock);
    unsafe (*((unsafe (&*st.p).cir) as *mut iri::Interp)).st_absorb(e.get());
}

fn ap_job(ctx: *mut void, j: u32) {
    let st = unsafe &*(ctx as *const ApStage);
    let p = unsafe &mut *st.p;
    let job = *(unsafe &*st.jobs).at(j as usize);
    let m = job.m as usize;
    let a = p.module_ast_const(m as ModuleId);
    let serial = p.jobs == 1;
    let mut own = Vector::<Box<iri::Interp>>::new();
    let cev: *mut iri::Interp = if serial {
        p.cir as *mut iri::Interp;
    } else {
        own.push(ap_engine_take(st));
        own.index_mut(0).as_ptr() as *mut iri::Interp;
    };
    for k in job.lo as usize..job.hi as usize {
        let it = p.sched.by_node[k] as usize;
        let meta = *p.idx.items.at(it);
        if meta.kind != loader::ItemKind::IK_FUNCTION as u8 && meta.kind != loader::ItemKind::IK_METHOD as u8 {
            continue;
        }
        let tp9 = if p.icost_on {
            std::parallel::platform::now_ns();
        } else {
            0u64;
        };
        let mut errs = diag::Errors::new();
        ap_check_fn(&mut errs, a, m, meta.node, cev);
        if p.icost_on {
            gitems::mod_cost(p, m, 1, std::parallel::platform::now_ns() - tp9);
        }
        if errs.errors.len() != 0 {
            *unsafe &mut *(st.outs + it) = Option::<Box<diag::Errors>>::Some(Box::new(errs));
        }
    }
    if !serial {
        switch own.pop() {
            Some(e) => {
                ap_engine_give(st, e);
            },
            _ => {},
        };
    }
}

// Unbounded recursion (`ir::recursion`) in the modules `lint_reported` selects; false when reported.
fn check_recursion(p: &loader::Package, keep: &irl::Keep, only_mod: i32) bool {
    let mut reported = Vector::<bool>::with_capacity(p.modules.len());
    for m in 0..p.modules.len() {
        reported.push(lint_reported(p, m, only_mod));
    }
    return recur::check_kept(p, keep, &reported);
}

/// Always-panics check (the `unconditional_panic` analog, an ERROR like the raw-array
/// provable-OOB gate: the same proof one tier up). A driver stage after every item is IrReady:
/// the scan interprets cross-module `const fn` bodies, whose bodies only exist once their
/// items are analyzed. @test fns are exempt (panicking on purpose is a feature there), as are
/// explicit `panic(..)` calls (only a panic reached THROUGH a `const fn` frame classifies; see
/// Interp::lint_body). `only_mod` restricts the scan to one module (the lint of one file).
fn check_always_panics(p: &mut loader::Package, only_mod: i32) {
    if p.cir == null {
        return;
    }
    let n = p.modules.len();
    let mut jobs = Vector::<BcJob>::new();
    bc_jobs(p, &mut jobs);
    let mut w: usize = 0;
    for j in 0..jobs.len() {
        if lint_reported(p, jobs[j].m as usize, only_mod) {
            jobs.set(w, jobs[j]);
            w += 1;
        }
    }
    jobs.truncate(w);
    let ni = p.idx.items.len();
    let mut outs = Vector::<Option<Box<diag::Errors>>>::with_capacity(ni);
    for _ in 0..ni {
        outs.push(Option::<Box<diag::Errors>>::None);
    }
    let par = p.jobs != 1 && n > 1;
    let cirp = p.cir as *mut iri::Interp;
    if par {
        // Fold failures recorded through the master's lowering callbacks land behind its lock
        // and dedup canonically in report_fold_errs.
        set_stage_locks(p, true);
    }
    let mut engines = Vector::<Box<iri::Interp>>::new();
    let mut unleased = jobs.len();
    let mut elock: i32 = 0;
    let mut ran0 = Set::<u64>::new();
    if par {
        for k in unsafe (*cirp).ran0.iter() {
            ran0.insert(*k);
        }
    }
    let mut st = ApStage {
        p: p,
        jobs: &jobs,
        outs: outs.index_mut(0),
        engines: &mut engines,
        unleased: &mut unleased,
        elock: &mut elock,
        ran0: &ran0,
    };
    // A probe is speculative: the types it touches are no use by the program, which emission reads
    // from the modules' `used` records.
    let mut marks = Vector::<u64>::with_capacity(n);
    for m in 0..n {
        marks.push(p.modules[m].ast.used_mark());
    }
    let mut g = sch::Jobs::independent(jobs.len());
    sch::run_jobs(&mut g, p.jobs, ap_job, &mut st, null);
    if par {
        set_stage_locks(p, false);
    }
    for m in 0..n {
        p.modules[m].ast.used_rollback(marks[m]);
    }
    for i in 0..engines.len() {
        unsafe (*cirp).st_absorb(engines.at(i).get());
    }
    for m in 0..n {
        let mut errs = diag::Errors::new();
        for it in p.idx.mod_items[m] as usize..p.idx.mod_items[m + 1] as usize {
            append_errs(&mut errs, outs.index_mut(it));
        }
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
pub(package) fn lint_package(
    p: &mut loader::Package,
    target: i32,
    lint_mod: usize,
    fixes: *mut Vector<diag::LintFix>,
    ftexts: *mut Vector<String>,
    suggest_const: bool,
) i32 {
    defer {
        if p.jobs != 1 {
            prt::shutdown(); // early-error net, same as run_package
        }
    }
    p.platform_filter(target);
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
    gitems::build_serial(p);
    {
        let mut want = Vector::<bool>::with_capacity(n);
        for i in 0..n {
            want.push(lint_reported(p, i, lint_mod as i32));
        }
        // Fixes are collected only for the selected modules: the others lint nothing.
        p.ok = typecheck_stage(p, &want, fixes, ftexts) && p.ok;
    }
    if p.ok {
        check_package_wide(p, n);
    }
    if !p.ok {
        return 1;
    }
    let mut wms = Vector::<facts::FactsWatermark>::new();
    facts_snapshot(p, &mut wms);
    // Kept so the report-only passes execute the checked bodies instead of lowering their own.
    let mut lkeep = irl::Keep::new();
    p.ok = borrowck_all(p, &mut lkeep) && p.ok;
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
    let cirk = p.cir as *mut iri::Interp;
    // Report-only passes: skipped while `--fix` iterates (they yield no fixes and would print
    // duplicates). The const suggestion is the exception: opt-in (`--const`, warning every
    // eligible function at once would swamp default lints), and under `--fix` it contributes its
    // `const `-insertion fixes instead of printing.
    if fixes == null {
        lint_unused_items(p, lint_mod as i32, null);
        let cirp0 = p.cir as *mut iri::Interp;
        if cirp0 != null {
            unsafe (*cirp0).all_typed = true;
        }
        check_always_panics(p, lint_mod as i32);
        p.ok = check_recursion(p, &lkeep, lint_mod as i32) && p.ok;
        lint_discarded_results(p, lint_mod as i32);
        lint_unused_members(p, lint_mod as i32);
    }
    lint_unused_imports(p, lint_mod as i32, fixes);
    lint_feature_unsafe(p, lint_mod as i32, fixes);
    if suggest_const {
        lint_const_suggest(p, lint_mod as i32, fixes);
    }
    if cirk != null {
        unsafe (*cirk).keep_view_clear();
    }
    if !p.ok || p.lint_warnings != 0 {
        return 1;
    }
    return 0;
}

/// Per-file completion callback for the streaming build: the engine starts compiling a finished TU
/// while later ones are still being emitted. `kind` 0 = header (or a unit compiled only through a
/// pack), 1 = C source, 2 = the shared `__sc_fwd.h` of a tree whose units compile through its
/// precompiled header, 3 = a native object the link takes as it is. Paths are full paths under the package's gen_root, the one tree the
/// C compiler reads. Notifications for one build arrive from a single thread.
pub(package) struct EmitSink {
    pub(package) ctx: *mut void,
    /// (ctx, path, body, kind, changed): `body` is the file's text, or empty when the sink reads the
    /// file; `changed` is set when this build rewrote the file (an unchanged one keeps its mtime).
    pub(package) notify: fn(*mut void, str, str, i32, bool) void,
}

fn sink_notify(sink: *mut EmitSink, pr: &mut prb::Probe, path: str, body: str, kind: i32, changed: bool) {
    if sink != null {
        let m9 = pr.start();
        let f = unsafe (*sink).notify;
        f(unsafe (*sink).ctx, path, body, kind, changed);
        pr.stop(prb::P_SYNC, m9);
    }
}

// Publish `body` as output `path` (`publish_file`), then tell `sink` (`kind`, and whether the content
// changed). False, after a message, when the file cannot be written; the sink then hears nothing.
fn publish_out(sink: *mut EmitSink, pr: &mut prb::Probe, path: &mut String, body: str, kind: i32) bool {
    let rc = publish_file(path.as_str(), body);
    if rc < 0 {
        unsafe stdio::perror(path.cstr());
        return false;
    }
    sink_notify(sink, pr, path.as_str(), body, kind, rc == 1);
    return true;
}

/// The fewest headers the write stage publishes on worker threads, and the most workers it takes: file
/// creation in one directory scales to about this many threads (2x over one on APFS).
const PUB_PAR_MIN: usize = 64;
const PUB_WORKERS: usize = 4;

// One worker's share of a header batch: files `lo..hi`, each `publish_file` of path `path[i]` with the
// `len[i]` bytes at `text[i]`, its result into `rc[i]`.
struct PubTask {
    pub(package) path: *const String,
    pub(package) text: *const usize,
    pub(package) len: *const usize,
    pub(package) rc: *mut i32,
    pub(package) lo: u64,
    pub(package) hi: u64,
}

// Tasks only read their files' texts and write disjoint result slots.
unsafe extend PubTask as Send {}

fn pub_range(t: PubTask) {
    for i in t.lo as usize..t.hi as usize {
        let body = unsafe str::from_raw(t.text[i] as *const u8, t.len[i]);
        unsafe t.rc[i] = publish_file(unsafe t.path[i].as_str(), body);
    }
}

// Publish `paths[i]` with the `lens[i]` bytes at `texts[i]` on up to PUB_WORKERS workers (one when
// `jobs` is 1 or the batch is small), each result into `rc[i]` (`publish_file`). The files are
// independent, so the order of the writes never shows in the tree; the caller reports them in order.
fn publish_batch(paths: &Vector<String>, texts: &Vector<usize>, lens: &Vector<usize>, rc: &mut Vector<i32>, jobs: u32) {
    let n = paths.len();
    rc.resize_default(n);
    let nw = if jobs == 1 || n < PUB_PAR_MIN {
        1;
    } else {
        PUB_WORKERS.min(jobs as usize);
    };
    let t0 = PubTask {
        path: paths.as_ptr(),
        text: texts.as_ptr(),
        len: lens.as_ptr(),
        rc: rc.index_mut(0),
        lo: 0,
        hi: n as u64,
    };
    if nw == 1 {
        pub_range(t0);
        return;
    }
    let wg = psync::WaitGroup::new();
    for w in 0..nw {
        let mut t = t0;
        t.lo = (n * w / nw) as u64;
        t.hi = (n * (w + 1) / nw) as u64;
        wg.add(1);
        let wgc = wg.clone();
        launch || {
            pub_range(t);
            wgc.done();
        };
    }
    wg.wait_masked();
    // The pool is released before the sources stream into compiler processes, as after the emission.
    prt::shutdown();
}

/// Compile a loaded package into the <gen_root> C tree: full per-module pipeline, instance propagation,
/// then codegen of the live modules (headers first, then sources across `jobs` forked workers),
/// pruning stale outputs afterwards. A non-empty `out_bin` also links the program there (`build`);
/// `topts.enabled` synthesizes the test runner and, without a `sink`, links and runs it too
/// (`native_link_and_run`). `sink` (may be null) hears about every finished output file; the build engine
/// then owns the runner's link and launch. `jobs` 0 means the online core count. Returns the process exit
/// code (0 = success).
// Print the time since `*t0` as stage `label` when `on`, and restart the clock at now.
fn stage_ms(on: bool, t0: &mut i64, label: str) {
    if on {
        let t = ticks_ms();
        eprint("{}: {} ms\n", label, t - *t0);
        *t0 = t;
    }
}

/// Manifest builds point `p.gen_root` into their out-dir; a bare invocation defaults it next to the
/// sources, one tree per profile (PROFILE makes the emitted C depend on it).
pub(package) fn default_gen_root(p: &mut loader::Package) {
    if p.gen_root.len() == 0 {
        let mut g = String::from_str(p.root_dir.as_str());
        g.push_str("/build/");
        g.push_str(p.profile_name());
        g.push_str("/raw");
        p.gen_root = g;
    }
}

// Resolve the modules from `root_module` on (the prelude stage resolved the ones before it) and build
// the item schedule over every module; then mark the structs and enums of those modules that C code reads
// (`mark_c_shaped`), before any layout query.
fn resolve_stage(p: &mut loader::Package, lint: bool) {
    let n = p.modules.len();
    if p.jobs != 1 && n > 1 {
        resolve_all_par(p, lint);
    } else {
        for i in p.root_module as usize..n {
            let ok = resolve_module(p, i, lint && lint_reported(p, i, -1), null);
            p.ok = ok && p.ok;
        }
        gitems::build_serial(p);
    }
    mark_c_shaped(p, p.root_module as usize);
}

// Mark in `Package.c_shaped` every struct and enum of modules `from..` that the signature of an extern
// function or an `@export` function of those modules reaches by value or through a pointer, a reference,
// a slice, an array, a function type or a generic argument: C code reads their fields, so they keep the
// declared order. A prelude type stays as the prelude stage laid it out (its image holds its marks).
fn mark_c_shaped(p: &mut loader::Package, from: usize) {
    let n = p.modules.len();
    let mut work = Vector::<DefId>::new(); // type nodes to visit, as (module, node)
    for m in from..n {
        if !p.modules[m].has_ast {
            continue;
        }
        let a = unsafe &*p.module_ast_const(m as ModuleId);
        let its = a.at_const(a.root).as_data.program.items;
        for i in 0..its.len {
            let it = unsafe a.list(its)[i as usize];
            let k = a.at_const(it).kind;
            if k == NodeKind::NODE_EXTERN_BLOCK {
                let fs = a.at_const(it).as_data.extern_block.items;
                for j in 0..fs.len {
                    c_sig(a, m as ModuleId, unsafe a.list(fs)[j as usize], true, &mut work);
                }
            } else if k == NodeKind::NODE_FUNCTION {
                c_sig(a, m as ModuleId, it, false, &mut work);
            }
        }
    }
    c_walk(p, from, &mut work, null);
}

// Walk the type nodes in `work` (from module `from` on) to the structs and enums they reach, by value or
// through a pointer, a reference, a slice, an array, a function type, a tuple, an alias or a generic
// argument, with the types of their fields and payloads: each joins `Package.c_shaped` (and `added`
// unless null). Each step visits one type node; a declaration enters the set once, so the walk is
// bounded by the type nodes of the marked declarations.
fn c_walk(p: &mut loader::Package, from: usize, work: &mut Vector<DefId>, added: *mut Vector<u64>) {
    let n = p.modules.len();
    while let Some(d) = work.pop() {
        let a = unsafe &*p.module_ast_const(d.module);
        let t = a.at_const(d.node);
        let k = t.kind;
        if k == NodeKind::NODE_POINTER_TYPE || k == NodeKind::NODE_REFERENCE_TYPE || k == NodeKind::NODE_SLICE_TYPE {
            work.push(DefId { module: d.module, node: t.as_data.indirect_type.ty });
        } else if k == NodeKind::NODE_ARRAY_TYPE {
            work.push(DefId { module: d.module, node: t.as_data.array_type.element });
        } else if k == NodeKind::NODE_FUNCTION_TYPE {
            c_types(d.module, a, t.as_data.function_type.params, work);
            c_types(d.module, a, t.as_data.function_type.returns, work);
        } else if k == NodeKind::NODE_TUPLE_TYPE {
            c_types(d.module, a, t.as_data.array_literal.elements, work);
        } else if k == NodeKind::NODE_TYPE_PATH {
            c_types(d.module, a, t.as_data.type_path.args, work);
            let mut r = a.resolution_def(d.node);
            if r.node == NODE_NONE {
                continue;
            }
            if r.module as usize >= n || !p.modules[r.module as usize].has_ast {
                r.module = d.module;
            }
            let ra = unsafe &*p.module_ast_const(r.module);
            if ra.at_const(r.node).kind == NodeKind::NODE_TYPE_ALIAS {
                work.push(DefId { module: r.module, node: ra.at_const(r.node).as_data.type_alias.ty });
                continue;
            }
            c_decl(p, from, r, work, added);
        }
    }
}

// Add to `Package.c_shaped` the declarations of modules `root_module..` that an `extern "C"` call's untyped
// pointer argument reaches (`Package.c_reads`), with the types of their fields and payloads: C may read
// the value through that pointer. A declaration whose reordered layout a compile-time evaluation of the typecheck already
// used (`layout::Svc::resized`, `offsets`) cannot take its declared order any more: an error asks for
// `@ordered`. False after an error.
fn mark_c_reads(p: &mut loader::Package) bool {
    let mut keys = replace(&mut p.c_reads, Vector::<u64>::new());
    // Sorted: the errors come in one order whatever the schedule of the typecheck.
    keys.sort_stable_in_place();
    let from = p.root_module as usize;
    let mut work = Vector::<DefId>::new();
    let mut added = Vector::<u64>::new();
    for k in 0..keys.len() {
        c_decl(
            p,
            from,
            DefId { module: (keys[k] >> 32) as ModuleId, node: (keys[k] & 0xFFFFFFFFu64) as NodeId },
            &mut work,
            &mut added,
        );
        c_walk(p, from, &mut work, &mut added);
    }
    let e = p.cir as *const iri::Interp;
    if e == null {
        return true;
    }
    let mut ok = true;
    for k in 0..added.len() {
        let m = (added[k] >> 32) as usize;
        let a = &p.modules[m].ast;
        let d = a.at_const((added[k] & 0xFFFFFFFFu64) as NodeId);
        // What the typecheck read of the reordered layout: the size (the order changed it), an offset, or
        // for an enum any of its payload layouts.
        let sv = unsafe &(*e).lsvc;
        let used = sv.resized.contains(&added[k]) || sv.moved.contains(&added[k]) && (sv.offsets.contains(&added[k]) || d.kind == NodeKind::NODE_ENUM);
        if !used {
            continue;
        }
        let nm = a.at_const(a.ext((added[k] & 0xFFFFFFFFu64) as NodeId).aggregate.name);
        let mut errs = diag::Errors::new();
        errs.emit_span(
            dc::REACHES_C_UNTYPED_POINTER_TAG_ORDERED,
            nm.span,
            format(
                "'{}' reaches C through an untyped pointer argument, so its fields keep their declared order, but a compile-time evaluation already used its reordered layout: tag it '@ordered'",
                p.modules[m].source.as_str().slice(
                    nm.as_data.name.text.start as usize,
                    nm.as_data.name.text.end as usize,
                ),
            ),
        );
        errs.finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
        errs.log();
        ok = false;
    }
    return ok;
}

// Declaration `r` into `Package.c_shaped` (and `added` unless null) when it is a struct or enum of module
// `from` on not there yet, and the type nodes of its fields and payloads into `work`.
fn c_decl(p: &mut loader::Package, from: usize, r: DefId, work: &mut Vector<DefId>, added: *mut Vector<u64>) {
    let ra = unsafe &*p.module_ast_const(r.module);
    let rk = ra.at_const(r.node).kind;
    let key = r.module as u64 << 32 | r.node as u64;
    if rk != NodeKind::NODE_STRUCT && rk != NodeKind::NODE_ENUM || r.module as usize < from || p.c_shaped.contains(&key) {
        return;
    }
    p.c_shaped.insert(key);
    if added != null {
        unsafe (*added).push(key);
    }
    let agg = ra.ext(r.node).aggregate;
    for i in 0..agg.members.len {
        let mid = unsafe ra.list(agg.members)[i as usize];
        let mk = ra.at_const(mid).kind;
        if mk == NodeKind::NODE_FIELD {
            work.push(DefId { module: r.module, node: ra.at_const(mid).as_data.field.ty });
        } else if mk == NodeKind::NODE_VARIANT {
            let pl = ra.at_const(mid).as_data.variant.payload;
            for j in 0..pl.len {
                let pid = unsafe ra.list(pl)[j as usize];
                work.push(
                    DefId {
                        module: r.module,
                        node: if ra.at_const(pid).kind == NodeKind::NODE_FIELD {
                            ra.at_const(pid).as_data.field.ty;
                        } else {
                            pid;
                        },
                    },
                );
            }
        } else if agg.is_tuple {
            work.push(DefId { module: r.module, node: mid });
        }
    }
}

// The parameter and result type nodes of function `f` (module `m`) into `work` when C calls or is called
// through it: a function of an extern block (`ext`) or an `@export` one.
fn c_sig(a: &Ast, m: ModuleId, f: NodeId, ext: bool, work: &mut Vector<DefId>) {
    if a.at_const(f).kind != NodeKind::NODE_FUNCTION || !ext && a.attr_of(f, AttrKind::ATTR_EXPORT) == null {
        return;
    }
    let fd = a.ext(f).function;
    for i in 0..fd.params.len {
        let pid = unsafe a.list(fd.params)[i as usize];
        if a.at_const(pid).kind == NodeKind::NODE_PARAMETER {
            work.push(DefId { module: m, node: a.at_const(pid).as_data.parameter.ty });
        }
    }
    c_types(m, a, fd.returns, work);
}

// The type nodes of `list` (module `m`) into `work`.
fn c_types(m: ModuleId, a: &Ast, list: NodeList, work: &mut Vector<DefId>) {
    for i in 0..list.len {
        work.push(DefId { module: m, node: unsafe a.list(list)[i as usize] });
    }
}

/// The prelude stage of a build: the std prelude of `p`'s settings loaded from `std_dir` and analyzed up
/// to the prelude gate in a package of its own, whose image `p` then loads (`driver::prelude_image`); or
/// the stored image of an earlier build with these settings and std files. While the prelude checks,
/// the closure of `root_file` (the module `load_user` loads next) reads and parses in tasks
/// (`Package::spec_user`). `p` holds no module yet and `e` is its engine, which takes the prelude's
/// deferred checks. `jobs` is the requested worker count, `steps` and `mem` the evaluation budgets of
/// `e`, `cache` the build's cache root (`objcache::object_cache_dir`; empty: no image is kept). False,
/// with the errors logged, when the prelude does not check.
pub(package) fn prelude_stage(
    p: &mut loader::Package,
    e: &mut iri::Interp,
    std_dir: str,
    root_file: str,
    target: i32,
    jobs: u32,
    steps: u32,
    mem: u64,
    cache: str,
) bool {
    let key = pimg::key(p, std_dir, target, steps, mem);
    let cid = pimg::cache_id(cache); // 0: no object cache, or an unreadable compiler: no image is kept
    if cid != 0 {
        let mut at: usize = 0;
        switch pimg::read(cache, key, cid, &mut at) {
            Some(b) => {
                // A stored image a reader rejects leaves a partial state: load into a copy.
                let mut t = p.settings_copy();
                if pimg::load(&mut t, e, b.as_str().slice(at, b.len())) {
                    *p = t;
                    p.bind_types();
                    return true;
                }
                e.pending.clear();
                e.pending_consts.clear();
                e.pending_strict.clear();
                e.inst_asserts.clear();
            },
            None => {},
        };
    }
    let mut img = String::new();
    let mut spec = loader::UserSpec::new();
    {
        let mut q = p.settings_copy();
        // The prelude's imports resolve under the std root alone: the image does not depend on the
        // project.
        q.root_dir = q.std_root.clone();
        q.alt_root = String::new();
        // The std listing the image records, taken before the load lists it.
        let std_id = if cid != 0 {
            pimg::dir_id(std_dir);
        } else {
            0 as u64;
        };
        q.load_prelude_stage(std_dir, q.bootstrap, target);
        if !q.ok {
            p.ok = false;
            return false;
        }
        spec = p.spec_user(&q, root_file, target);
        q.jobs = jobs;
        let mut qe = iri::interp_master((&mut q) as *mut loader::Package, steps, mem);
        q.cir = &mut qe;
        if !check_prelude(&mut q, target) {
            spec.join();
            p.ok = false;
            return false;
        }
        img = pimg::save(&q, &qe);
        if cid != 0 && q.lint_warnings == 0 {
            pimg::write(cache, key, cid, &q, std_dir, std_id, &img);
        }
    }
    let mut t = p.settings_copy();
    let ok = pimg::load(&mut t, e, img.as_str());
    if !ok {
        panic("the prelude image did not load back");
    }
    *p = t;
    p.bind_types();
    p.adopt_user(spec);
    return true;
}

// The prelude stage's analysis over `q`, which holds the prelude alone: resolution, then the type check
// of every item, the prelude gate's publication among it (`typecheck_stage`). Its raw edges and its
// items' schedule state go to `q.carry`.
fn check_prelude(q: &mut loader::Package, target: i32) bool {
    if q.modules.len() == 0 {
        return true; // no std tree: nothing to check
    }
    q.carry.keep = true;
    q.platform_filter(target);
    resolve_stage(q, false);
    if !q.ok {
        return false;
    }
    let mut want = Vector::<bool>::new();
    want.resize_default(q.modules.len());
    q.ok = typecheck_stage(q, &want, null, null) && q.ok;
    if !q.ok {
        return false;
    }
    let c = &mut q.carry;
    c.keep = false;
    c.items = q.idx.items.len() as u32;
    for i in 0..q.idx.items.len() {
        c.state.push(q.sched.state[i]);
        c.ret_attr.push(q.sched.ret_attr[i]);
    }
    let mut it = q.sched.dyn_edges.iter();
    loop {
        switch it.next() {
            Some(d) => {
                c.dyn_edges.insert(*d);
            },
            None => {
                break;
            },
        };
    }
    return true;
}

pub(package) fn run_package(
    p: &mut loader::Package,
    topts: *const TestOpts,
    out_bin: str,
    target: i32,
    lint: bool,
    sink: *mut EmitSink,
) i32 {
    // Safety net for every early-error return: parallel loading may have started the pool, and
    // the leak gate (and any later fork) needs it gone; shutdown is idempotent.
    defer {
        if p.jobs != 1 {
            prt::shutdown();
        }
    }
    let tstat = stdlib::getenv("SC_CEMIT_STATS") != null;
    let mut tp0 = ticks_ms();
    // Only a link takes the native objects (a build system's, a script's or the test runner's): an
    // emission alone writes C. Every link is native: a target without a native backend has none.
    let links = sink != null || out_bin.len() != 0 || topts != null && unsafe (*topts).enabled;
    if links && !nat::supported(target, p.arch) {
        eprintln(
            "super-c: no native backend for {} on {}: `--emit-c` writes the program's C",
            tgt::os(target).name,
            tgt::isa(p.arch).name,
        );
        return 1;
    }
    p.native = links;
    let so = stdlib::get_env("SC_LIR_OPT");
    p.lir_opt = if so.is_some() {
        so.unwrap().as_str() == "1";
    } else {
        p.opt > 0;
    };
    p.cg = bman::cg_effective(p.opt, p.cg_on, p.cg_off);
    syntax_stats_report(p, "parse");
    p.platform_filter(target);
    // No module parses after the load: the token recycling buffer has no next user.
    p.tok_scratch = Vector::<tok::Token>::new();
    // The prelude stage's index holds its modules: append the rest, as filtered.
    p.index_append();
    let n = p.modules.len();
    // The per-item cost records are serial-only (the frontiers' tasks would race on them); the
    // report and its final graph print for any worker count (the digest gate reads them).
    let istats = stdlib::getenv("SC_ITEM_STATS") != null;
    p.icost_on = istats && p.jobs == 1;
    resolve_stage(p, lint);
    if !p.ok {
        return 1;
    }
    bst::mark(bst::B_RESOLVE);
    syntax_stats_report(p, "resolve");
    stage_ms(tstat, &mut tp0, "phase resolve");
    {
        let mut want = Vector::<bool>::with_capacity(n);
        for i in 0..n {
            want.push(lint && lint_reported(p, i, -1));
        }
        p.ok = typecheck_stage(p, &want, null, null) && p.ok;
    }
    if p.ok {
        let td0 = ticks_ms();
        check_package_wide(p, n);
        if tstat {
            eprint("typecheck-stage conformances+obligations: {} ms\n", ticks_ms() - td0);
        }
    }
    if !p.ok {
        return 1;
    }
    bst::mark(bst::B_TYPECHECK);
    syntax_stats_report(p, "typecheck");
    ts_phase("typecheck");
    if p.icost_on && p.cir != null {
        let ce9 = p.cir as *mut iri::Interp;
        eprint(
            "item-stats evaluation: {} bodies lowered from syntax during typecheck, {} refusals\n",
            unsafe (*ce9).st_fresh,
            unsafe (*ce9).body_miss_n,
        );
    }
    stage_ms(tstat, &mut tp0, "phase typecheck");
    let mut co = CemitOut::new(n);
    let mut wms = Vector::<facts::FactsWatermark>::new();
    facts_snapshot(p, &mut wms);
    // The backend consumes borrowck's lowerings (irkeep), so the evaluator must reach its final
    // state BEFORE the first body lowers: every module is typed here, and the folds lowering runs
    // (build conditions, repeat counts, range bounds) must behave exactly as they would under the
    // backend's own lowering.
    {
        let cirp1 = p.cir as *mut iri::Interp;
        if cirp1 != null {
            unsafe (*cirp1).all_typed = true;
            unsafe (*cirp1).record_folds = true;
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
    bst::mark(bst::B_BORROWCK);
    syntax_stats_report(p, "borrowck");
    ts_phase("borrowck");
    stage_ms(tstat, &mut tp0, "phase borrowck");
    if tstat {
        let ce9 = p.cir as *mut iri::Interp;
        if ce9 != null {
            eprint(
                "interp bodies after borrowck: {} lookups, {} kept hits, {} fresh lowerings ({} generic instances, {} not kept)\n",
                unsafe (*ce9).st_lookups,
                unsafe (*ce9).st_kept_hits,
                unsafe (*ce9).st_fresh,
                unsafe (*ce9).st_fresh_generic,
                unsafe (*ce9).st_fresh_miss,
            );
        }
    }
    if facts_verify(p, &wms, "borrowck") != 0 {
        return 1;
    }
    layout_pass(p);
    stage_ms(tstat, &mut tp0, "phase verify+layout");
    if lint {
        lint_unused_items(p, -1, null);
        lint_feature_unsafe(p, -1, null);
        stage_ms(tstat, &mut tp0, "phase lint");
    }
    // The unused-item lint was the last reader of `method_refs`, and no batch stage after the type
    // check re-resolves (the reader of `seeds`).
    for m in 0..n {
        if p.modules[m].has_ast {
            p.modules[m].ast.release_checked_tables();
        }
    }
    // An ERROR on every build, over the user modules, like the always-panics check.
    p.ok = check_recursion(p, &irkeep, -1) && p.ok;
    stage_ms(tstat, &mut tp0, "phase recursion");
    // The static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let cirf = p.cir as *mut iri::Interp;
    if cirf != null {
        let pv = p as *mut loader::Package;
        unsafe (*cirf).all_typed = true;
        // The always-panics probes and the deferred flush below are the last readers of the callees
        // they lower and the objects they build: `release_pass` frees them after the flush, and
        // the constant pass before emission lowers again the few it needs.
        let bm = unsafe (*cirf).body_mark();
        // An ERROR, not a lint: it runs on every build (user modules; std is gated by check.sh's
        // explicit std lint invocations).
        check_always_panics(p, -1);
        stage_ms(tstat, &mut tp0, "phase panics");
        if tstat {
            eprint(
                "interp bodies: {} lookups, {} kept hits, {} fresh lowerings ({} generic instances, {} not kept), {} boxes retained by the master engine\n",
                unsafe (*cirf).st_lookups,
                unsafe (*cirf).st_kept_hits,
                unsafe (*cirf).st_fresh,
                unsafe (*cirf).st_fresh_generic,
                unsafe (*cirf).st_fresh_miss,
                unsafe (*cirf).bodies.len(),
            );
        }
        unsafe (*cirf).flush_asserts(flush_assert_err, pv);
        flush_inst_asserts(p);
        unsafe (*cirf).flush_consts(flush_const_err, pv);
        unsafe (*cirf).release_pass(bm);
    }
    if !p.ok {
        return 1;
    }
    bst::mark(bst::B_CHECKS);
    ts_phase("checks");
    stage_ms(tstat, &mut tp0, "phase lint+panics");
    let testing = topts != null && unsafe (*topts).enabled;
    let mut plan = TestPlan::new(n);
    if testing {
        test_plan_build(p, &mut plan);
        if !plan.ok {
            return 1;
        }
    }

    default_gen_root(p);
    // A tree that did not exist before this build holds no orphan to prune afterwards.
    let gr9 = String::from_str(p.gen_root.as_str());
    let fresh_tree = !is_dir(gr9.as_str());
    let rt9 = write_super_rt(gr9.as_str());
    let mut err = rt9 < 0;
    let root = gr9.as_str();
    let mut keep = Vector::<String>::new();
    keep.push(build_out_path(root, "super_rt", ".h"));
    if !err {
        sink_notify(sink, &mut co.pr, keep.at(0).as_str(), "", 0, rt9 != 0);
    }
    // `@link` flags feed `build/<profile>/raw/__ldflags` for the link line.
    ext_c_collect(p, &mut err, target);
    stage_ms(tstat, &mut tp0, "phase rt+ext");
    let live = compute_emit_live(p);
    stage_ms(tstat, &mut tp0, "phase live");
    let mut order = Vector::<ModuleId>::new();
    p.emit_order(&mut order);
    syntax_stats_report(p, "prepare");
    // Emission materializes value constants through the evaluator, whose callees come from the
    // kept bodies: evaluate every constant now, with the view still open and every kept hit
    // copied into the evaluator's own boxes (`copy_kept`), then close the view before the
    // emitter takes the kept bodies. The released body syntax cannot lower a callee again. A
    // constant whose initializer evaluated whole before the view opened (`Interp.whole`) reaches
    // only the evaluator's own boxes, and runs only at emission.
    {
        let cirp = p.cir as *mut iri::Interp;
        if cirp != null {
            // The memos would answer a scalar without running its callees; the emission engine
            // starts without them and runs everything, so this pass must too.
            unsafe (*cirp).call_memo.clear();
            unsafe (*cirp).item_memo.clear();
            unsafe (*cirp).ememo.clear();
            unsafe (*cirp).copy_kept = true;
            for m in 0..n {
                if !p.modules[m].has_ast {
                    continue;
                }
                let a = unsafe &*p.module_ast_const(m as ModuleId);
                for i in 0..a.nodes.len() {
                    let nd = a.at_const(i as NodeId);
                    if nd.kind != NodeKind::NODE_CONST || nd.as_data.const_def.is_extern {
                        continue;
                    }
                    let v = nd.as_data.const_def.value;
                    if v != NODE_NONE && !unsafe (*cirp).whole.contains(&(m as u64 << 32 | v as u64)) {
                        let _ = unsafe (*cirp).eval_const_in(m as ModuleId, i as NodeId);
                    }
                }
            }
            unsafe (*cirp).copy_kept = false;
            unsafe (*cirp).keep_view_clear();
        }
    }
    if istats {
        gitems::finalize(p); // the measurement's final graph reads body syntax
    }
    bst::mark(bst::B_PREPARE);
    ts_phase("prepare");
    // The whole-package Core-IR emission runs BEFORE the live-module list: it seeds every module
    // unconditionally, so any module with a non-empty TU must be written even when the reference
    // scan finds no direct use (prelude bodies the instance TU calls into).
    {
        let cirg = p.cir as *mut iri::Interp;
        if cirg != null {
            // The seed/instance lowering folds its constant contexts.
            unsafe (*cirg).record_folds = true;
        }
    }
    stage_ms(tstat, &mut tp0, "phase mid");
    if cbe::native_on(p) {
        native_header_facts(p);
        stage_ms(tstat, &mut tp0, "phase native facts");
    }
    if cbe::native_on(p) || cbe::lir_requested(p) {
        lir_lines(p);
    }
    // The installed hooks' stage before the emission (`build_system::ext`): an error leaves the tree as it is.
    if !ext::run_stage(ext::STAGE_BEFORE_EMISSION, p, null) {
        return 1;
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
    // A depth refusal leaves its instance unemitted: the located error explains the skip.
    let deep = report_refusals(p, &mut co.refused, true);
    if deep {
        err = true;
    }
    if co.skips != 0 && !co.len_faults {
        let _ = report_refusals(p, &mut co.refused, false);
        if !deep {
            eprint("error: internal: the backend refused {} emissions\n", co.skips);
            if p.bootstrap {
                // `bc_lower_err` lets such a body go unchecked; it cannot lower for the emission.
                eprint(
                    "  = note: under --bootstrap-tags, a body that calls an intrinsic this compiler does not know cannot be emitted\n",
                );
            }
        }
        err = true;
    }
    // The evaluator check (`SC_LIR_EVAL`) of a test build ran in the emission: nothing is written, compiled
    // or run.
    if testing && stdlib::getenv("SC_LIR") != null && stdlib::getenv("SC_LIR_EVAL") != null {
        return pick(err, 1, 0);
    }
    // A failed emission leaves instances out: the C compiler must not see the units that call them.
    let osink = if !err {
        sink;
    } else {
        null;
    };
    // With a sink, the tree is the one a build compiles incrementally: a failed emission leaves its
    // files as the last successful one wrote them, so no unchanged-looking file carries this build's
    // mtime.
    let wtree = !err || sink == null;
    // Transitive TU pruning: keep scan-live modules, then everything a KEPT TU (or the always-
    // written instance TU) spells symbols from; dead prelude chains drop out entirely.
    // The edges come grouped by source in ascending order (modules, then 65534 as row n): row s
    // is `co.edges[eoff[s]..eoff[s + 1]]`. A module enters the stack once, when it is kept.
    let mut keep_mod = live;
    // A module-level `asm` defines symbols that only C names: its unit stays whenever it loads.
    for m9 in 0..n {
        if module_has_asm(p, m9) {
            keep_mod.set(m9, true);
        }
    }
    let mut eoff = Vector::<u32>::new();
    eoff.resize_default(n + 2);
    for e9 in 0..co.edges.len() {
        let src9 = ((co.edges[e9] >> 32) as usize).min(n);
        assert(e9 == 0 || ((co.edges[e9 - 1] >> 32) as usize).min(n) <= src9, "cross-TU edges are grouped by source");
        eoff.set(src9 + 1, eoff[src9 + 1] + 1);
    }
    for s9 in 0..n + 1 {
        eoff.set(s9 + 1, eoff[s9 + 1] + eoff[s9]);
    }
    let mut stack9 = Vector::<usize>::with_capacity(n + 1);
    stack9.push(n);
    for m9 in 0..n {
        if *keep_mod.at(m9) {
            stack9.push(m9);
        }
    }
    while let Some(s9) = stack9.pop() {
        for e9 in eoff[s9] as usize..eoff[s9 + 1] as usize {
            let dst9 = (co.edges[e9] & 0xFFFFFFFFu64) as usize;
            if dst9 < n && !*keep_mod.at(dst9) && co.tu_heads.at(dst9).len() != 0 {
                keep_mod.set(dst9, true);
                stack9.push(dst9);
            }
        }
    }
    let mut lm = Vector::<ModuleId>::new();
    for oi in 0..n {
        let mi = order[oi];
        if co.tu_heads.at(mi as usize).len() == 0 {
            continue;
        }
        if !*keep_mod.at(mi as usize) {
            continue;
        }
        lm.push(mi);
    }
    // Largest first: the streaming C compile starts each unit as its file lands, so the units
    // that bound the critical path go out before the small ones (emit order breaks ties).
    let mut tsz = Vector::<u64>::with_capacity(n);
    let mut isz = Vector::<u64>::with_capacity(n);
    for q in 0..n {
        tsz.push(co.tus.at(q).len() as u64);
        let mut b9: u64 = 0;
        for k in 0..co.inst_chunks.at(q).len() {
            let i = co.inst_chunks.at(q)[k] as usize;
            b9 += co.ck_end[i] - co.ck_off[i];
        }
        isz.push(b9);
    }
    sort_big_first(&mut lm, &tsz);
    let mut iq = Vector::<ModuleId>::new();
    for q in 0..n {
        if co.inst_heads.at(q).len() != 0 {
            iq.push(q as ModuleId);
        }
    }
    sort_big_first(&mut iq, &isz);
    // A native build compiles its modules into objects.
    let mut nat_objs = Vector::<NatObj>::new();
    let mut nat_mod = Vector::<bool>::new(); // per module, native
    let mut nat_rec = Map::<String, u64>::new();
    let nat_rp = build_out_path(root, NAT_RECORD, "");
    // Every module compiled natively: the registry is a native object too, and no C object links.
    let mut nat_all = false;
    if co.lir.is_some() && !err {
        // The record of the objects an earlier build left, for the modules the emission cache replayed.
        if co.tuc_keys.len() != 0 {
            nat_rec = nat_record(nat_rp.as_str());
        }
        if let Some(l) = &co.lir {
            if !native_plan(p, l, &lm, &iq, root, &co.tuc_hit, &nat_rec, &mut nat_mod, &mut nat_objs) {
                return 1;
            }
        }
        let isnat = &nat_mod;
        let mut lm2 = Vector::<ModuleId>::new();
        for k in 0..lm.len() {
            if !isnat[lm[k] as usize] {
                lm2.push(lm[k]);
            }
        }
        lm = lm2;
        let mut iq2 = Vector::<ModuleId>::new();
        for k in 0..iq.len() {
            if !isnat[iq[k] as usize] {
                iq2.push(iq[k]);
            }
        }
        iq = iq2;
        nat_all = lm.len() == 0 && iq.len() == 0;
        co.lir = Option::<Box<lw::Lower>>::None;
    }
    let tw0 = ticks_ms();
    let pub9 = co.pr.start();
    // A small program compiles as one unit (`__sc_unity.c` includes its module, instance and registry
    // units): one compiler process, the shared headers parsed once. A larger one compiles its small
    // units in packs (`pack_plan`). The members of a pack are no compile units of their own.
    let mut csize = co.registry_c.len() + co.inst_c.len();
    for k in 0..lm.len() {
        csize += co.tus.at(lm[k] as usize).len();
    }
    // SC_UNITY_MAX overrides the limit (0: every unit alone).
    let mut umax = UNITY_MAX as u64;
    let ue = stdlib::get_env("SC_UNITY_MAX");
    if ue.is_some() {
        umax = ue.unwrap().as_str().parse_u64().unwrap_or(umax);
    }
    let unity = csize as u64 <= umax && lm.len() + iq.len() + (co.registry_c.len() != 0) as usize > 1;
    let mut tu_pk = Vector::<u32>::new();
    let mut in_pk = Vector::<u32>::new();
    let mut reg_pk: u32 = 0;
    let npk = pack_plan(
        p,
        &co,
        &lm,
        &iq,
        &tsz,
        &isz,
        unity,
        umax == 0,
        packs_read(root),
        &mut tu_pk,
        &mut in_pk,
        &mut reg_pk,
    );
    // Every header lands before any source (the streaming C compile starts per source file),
    // then module TU shards in emit order, instance shards by owner, the registry TU, the packs. Each
    // file streams out piecewise and is hashed on the way for the manifest.
    let mut man = String::new();
    man.push_str("super-c-manifest\t1\nshard-policy\t1\n");
    let mut shard_meta = shard_meta_text(p, &co);
    {
        // One `shards` line per module with more than one shard: the effective counts, whether the
        // manifest named them or the size policy chose them.
        let sm = shard_meta.as_str();
        let mut i: usize = 0;
        while i < sm.len() {
            let mut e = i;
            while e < sm.len() && sm.byte_at(e) != 10 {
                e += 1;
            }
            if i != 0 {
                man.push_str("shards\t");
                man.push_str(sm.slice(i, e));
                man.push_str("\n");
            }
            i = e + 1;
        }
    }
    if !unity && npk != 0 {
        shard_meta.format_into("packs\t{}\n", npk);
    }
    // The units that include `__sc_fwd.h` (each shard that compiles alone, each pack): from PCH_UNITS of
    // them on, the build compiles the header once, precompiled, and every unit loads it. `__sc_shards`
    // records it for a build that plans the tree without the emission (`pch`).
    let mut fwd_units = npk as usize + (co.registry_c.len() != 0 && reg_pk == 0) as usize;
    for k in 0..lm.len() {
        fwd_units += pick(tu_pk[lm[k] as usize] == 0, co.tu_heads.at(lm[k] as usize).len(), 0);
    }
    for k in 0..iq.len() {
        fwd_units += pick(in_pk[iq[k] as usize] == 0, co.inst_heads.at(iq[k] as usize).len(), 0);
    }
    let pch = !unity && fwd_units >= PCH_UNITS;
    if pch {
        shard_meta.push_str("pch\t1\n");
    }
    man.format_into("cfg\t{}\t{}\t{}\n", target, p.opt, p.debug_info as u32);
    let mut members = Vector::<String>::new(); // the units the packs compile
    if wtree {
        // The headers in manifest order: path, text (pointer and length), owner module.
        let mut hps = Vector::<String>::new();
        let mut hts = Vector::<usize>::new();
        let mut hls = Vector::<usize>::new();
        let mut hos = Vector::<u32>::new();
        hps.push(build_out_path(root, "__sc_fwd", ".h"));
        hts.push(co.fwd_h.as_str().ptr() as usize);
        hls.push(co.fwd_h.len());
        hos.push(0xFFFF);
        for d in 0..co.defs_h.len() {
            if co.defs_h.at(d).len() == 0 {
                continue; // an entry's definition no unit calls
            }
            let mut hp = String::from_str(root);
            hp.push_str("/__sc_t/");
            hp.push_string(co.defs_stem.at(d));
            hp.push_str(".h");
            hps.push(hp);
            hts.push(co.defs_h.at(d).as_str().ptr() as usize);
            hls.push(co.defs_h.at(d).len());
            hos.push(co.defs_own[d]);
        }
        for m in 0..n {
            if co.protos_h.at(m).len() == 0 {
                continue;
            }
            hps.push(build_out_path(root, p.modules[m].path.as_str(), ".h"));
            hts.push(co.protos_h.at(m).as_str().ptr() as usize);
            hls.push(co.protos_h.at(m).len());
            hos.push(m as u32);
        }
        let mut hrc = Vector::<i32>::new();
        publish_batch(&hps, &hts, &hls, &mut hrc, p.jobs);
        for i in 0..hps.len() {
            // The texts live in `co` until the write stage ends.
            let ht = unsafe str::from_raw(hts[i] as *const u8, hls[i]);
            let mut hp = replace(hps.index_mut(i), String::new());
            // A failure again on this thread: the message gets its own error.
            let rc = if hrc[i] < 0 {
                publish_file(hp.as_str(), ht);
            } else {
                hrc[i];
            };
            if rc < 0 {
                unsafe stdio::perror(hp.cstr());
                err = true;
                continue;
            }
            man_line(&mut man, "h", root, hp.as_str(), out_hash(ht), hos[i], 0, ht, "");
            // The first header is `__sc_fwd.h`: a tree of separate units compiles it once, precompiled.
            sink_notify(osink, &mut co.pr, hp.as_str(), ht, pick(pch && i == 0, 2, 0), rc == 1);
            keep.push(hp);
        }
        let mut sg = ShardGroups::new();
        // Every shard's text, one at a time: the buffer is reused, so it grows to the largest shard.
        let mut sbody = String::new();
        let mut packs = Vector::<String>::new(); // per pack: its include lines
        for _k in 0..npk {
            packs.push(String::new());
        }
        for k in 0..lm.len() {
            let t = lm[k] as usize;
            let nsh = co.tu_heads.at(t).len();
            sg.fill(&co.ck_shard, co.tu_chunks.at(t), nsh);
            for x in 0..nsh {
                let mut stem = String::from_str(p.modules[t].path.as_str());
                if x != 0 {
                    stem.push_str("__p");
                    stem.push_u64(x as u64);
                }
                let tail = if x == 0 {
                    co.tu_tail.at(t).as_str();
                } else {
                    "";
                };
                if !shard_text(&co, t, x as u8, false, tail, &sg, &mut sbody) {
                    continue;
                }
                let mut cp = build_out_path(root, stem.as_str(), ".c");
                if publish_out(osink, &mut co.pr, &mut cp, sbody.as_str(), pick(tu_pk[t] != 0, 0, 1)) {
                    man_line(
                        &mut man,
                        "c",
                        root,
                        cp.as_str(),
                        out_hash(sbody.as_str()),
                        t as u32,
                        x as u32,
                        co.tu_incs.at(t).as_str(),
                        "",
                    );
                    pack_join(&mut packs, &mut members, root, &cp, tu_pk[t]);
                    keep.push(cp);
                } else {
                    err = true;
                }
            }
        }
        for qi in 0..iq.len() {
            let q = iq[qi] as usize;
            let nsh = co.inst_heads.at(q).len();
            sg.fill(&co.ck_shard, co.inst_chunks.at(q), nsh);
            for x in 0..nsh {
                let mut stem = String::from_str(p.modules[q].path.as_str());
                stem.push_str("__inst");
                if x != 0 {
                    stem.push_str("__p");
                    stem.push_u64(x as u64);
                }
                if !shard_text(&co, q, x as u8, true, "", &sg, &mut sbody) {
                    continue;
                }
                let mut cp = build_out_path(root, stem.as_str(), ".c");
                if publish_out(osink, &mut co.pr, &mut cp, sbody.as_str(), pick(in_pk[q] != 0, 0, 1)) {
                    man_line(
                        &mut man,
                        "i",
                        root,
                        cp.as_str(),
                        out_hash(sbody.as_str()),
                        q as u32,
                        x as u32,
                        co.inst_incs.at(q).as_str(),
                        "",
                    );
                    pack_join(&mut packs, &mut members, root, &cp, in_pk[q]);
                    keep.push(cp);
                } else {
                    err = true;
                }
            }
        }
        if co.registry_c.len() != 0 {
            let mut rp = build_out_path(root, "__sc_registry", ".c");
            if publish_out(osink, &mut co.pr, &mut rp, co.registry_c.as_str(), pick(reg_pk != 0, 0, 1)) {
                man_line(
                    &mut man,
                    "r",
                    root,
                    rp.as_str(),
                    out_hash(co.registry_c.as_str()),
                    0xFFFF,
                    0,
                    co.registry_c.as_str(),
                    co.reg_inputs.as_str(),
                );
                pack_join(&mut packs, &mut members, root, &rp, reg_pk);
                keep.push(rp);
            } else {
                err = true;
            }
        }
        for k in 0..npk as usize {
            let mut up = if unity {
                build_out_path(root, "__sc_unity", ".c");
            } else {
                build_out_path(root, format("__sc_pack{}", k).as_str(), ".c");
            };
            let mut ut = String::from_str(
                if unity {
                    "/* every unit of this program in one compile -- generated, do not edit */\n";
                } else {
                    "/* units of this program compiled as one: generated, do not edit */\n";
                },
            );
            ut.push_string(packs.at(k));
            if publish_out(osink, &mut co.pr, &mut up, ut.as_str(), 1) {
                man_line(&mut man, "u", root, up.as_str(), out_hash(ut.as_str()), 0xFFFF, 0, ut.as_str(), "");
                keep.push(up);
            } else {
                err = true;
            }
        }
    }
    // The native objects, beside the C units they replace: per module its own items' and the rest; the
    // record of the own objects, with their keys, when the emission cache is on.
    let mut nat_paths = Vector::<String>::new();
    let mut rec_txt = String::new();
    if wtree {
        for k in 0..nat_objs.len() {
            let ob = nat_objs.at(k);
            let mp = p.modules[ob.m as usize].path.as_str();
            let mut op = build_out_path(
                root,
                mp,
                if ob.own {
                    ".o";
                } else {
                    "__inst.o";
                },
            );
            let body = if ob.old.len() != 0 {
                ob.old.as_str();
            } else {
                unsafe str::from_raw(ob.bytes.as_ptr(), ob.bytes.len());
            };
            if publish_out(osink, &mut co.pr, &mut op, body, 3) {
                nat_paths.push(op.clone());
                keep.push(op);
            } else {
                err = true;
            }
        }
        if nat_all && !err {
            let mut bytes = Vector::<u8>::new();
            let mut op = build_out_path(root, NAT_REGISTRY, ".o");
            if native_registry(p, &co.zst, co.reg_inputs.as_str(), &mut bytes) && publish_out(
                osink,
                &mut co.pr,
                &mut op,
                unsafe str::from_raw(bytes.as_ptr(), bytes.len()),
                3,
            ) {
                nat_paths.push(op.clone());
                keep.push(op);
            } else {
                err = true;
            }
        }
        // Every module, with whether it has an own object.
        if co.tuc_keys.len() != 0 && nat_mod.len() != 0 {
            let mut has = Vector::<bool>::new();
            has.resize_default(p.modules.len());
            for k in 0..nat_objs.len() {
                if nat_objs.at(k).own {
                    has.set(nat_objs.at(k).m as usize, true);
                }
            }
            for m in 0..p.modules.len() {
                let fl = if has[m] {
                    NAT_OBJ;
                } else {
                    0;
                };
                rec_txt.format_into("{} {}\n", nat_key(p, &co.tuc_keys, m) & ~3u64 | fl, p.modules[m].path.as_str());
            }
        }
        if !err && rec_txt.len() != 0 {
            if write_file_atomic(nat_rp.as_str(), rec_txt.as_str()) {
                keep.push(nat_rp.clone());
            }
        } else {
            let _ = fs::unlink(nat_rp.as_str());
        }
    }
    if stdlib::getenv("SC_CEMIT_STATS") != null {
        eprint("cemit-stage write: {} ms\n", ticks_ms() - tw0);
        co.pr.stop(prb::P_PUBLISH, pub9);
        let mut rep9 = String::new();
        co.pr.report(&mut rep9);
        rep9.eprint();
    }
    // Publish the per-TU cache only after a fully successful emission; keep[] shields it from pruning.
    // Atomic: the reader checks only bounds, so a torn image would replay sections of corrupt content.
    if !err && co.skips == 0 && co.tuc_path.len() != 0 {
        if write_file_atomic(co.tuc_path.as_str(), co.tuc_img.as_str()) {
            keep.push(String::from_str(co.tuc_path.as_str()));
        }
    }
    if !err {
        manifest_publish(root, &man, &mut keep);
        let smp = build_out_path(root, "__sc_shards", "");
        if write_file(smp.as_str(), shard_meta.as_str()) {
            keep.push(smp);
        }
    }
    if !err && !p.native && root.len() != 0 && !c_build_files(p, root, &members, &mut keep, target) {
        err = true;
    }
    // Drop outputs of an earlier build that this program does not emit, so the tree matches the current
    // sources.
    if root.len() != 0 && !fresh_tree && wtree {
        prune_orphans(root, &keep);
    }
    // Every file is on disk: the link and the run below read the tree. Of the output only its probe is
    // read again (the test runner's notice).
    let mut opr = replace(&mut co.pr, prb::Probe::new(false, false));
    co = CemitOut::new(0);
    syntax_stats_report(p, "emit");
    let mut rc: i32 = err as i32;
    if out_bin.len() != 0 {
        if !err {
            rc = native_link_and_run(p, null, &nat_paths, out_bin, target);
        }
    } else if testing && !err {
        if plan.cases.len() == 0 {
            unsafe stdio::fputs("super-c: no '@test' functions found\n".ptr() as *const char, stdio::stderr());
            rc = 1;
        } else {
            // The runner's entry is an object too.
            let mut op = build_out_path(root, "__test_main", ".o");
            let mut bytes = Vector::<u8>::new();
            if native_test_main(p, &plan, &mut bytes) && publish_out(
                sink,
                &mut opr,
                &mut op,
                unsafe str::from_raw(bytes.as_ptr(), bytes.len()),
                3,
            ) {
                nat_paths.push(op.clone());
                keep.push(op);
                if sink == null {
                    rc = native_link_and_run(p, topts, &nat_paths, "", target);
                }
            } else {
                rc = 1;
            }
        }
    }
    // `keep` names every file the tree holds: its `.c` files are the emit stamp's unit count.
    p.c_files = 0;
    for i in 0..keep.len() {
        p.c_files += keep.at(i).as_str().ends_with(".c") as u64;
    }
    if istats {
        gitems::report(p, ITEM_TASK_NS);
    }
    // Report-only: emission must have read the semantic tables frozen (intern-pool growth is the one
    // sanctioned mutation; see ast::facts).
    let _ = facts_verify(p, &wms, "codegen");
    return rc;
}

// The object of the test runner's entry of `plan` (`test_main_lir`) for the build's target, into
// `out`; false, after a message, when it does not compile.
fn native_test_main(p: &loader::Package, plan: &TestPlan, out: &mut Vector<u8>) bool {
    let mut text = String::new();
    test_main_lir(p, plan, lay::target_for(p.arch).ptr as u32, &mut text);
    let mut err = String::new();
    let mut ok = false;
    switch lparse::parse(text.as_str(), &mut err) {
        Some(pk) => {
            let mut fs = Vector::<u32>::new();
            let mut ds = Vector::<u32>::new();
            for i in 0..pk.syms.len() {
                if pk.syms[i].def != lir_ir::NONE {
                    if pk.syms[i].kind == lir_ir::SK_FUNC {
                        fs.push(i as u32);
                    } else {
                        ds.push(i as u32);
                    }
                }
            }
            ok = nat::object(&pk, p.build_target, p.arch, fs[0..fs.len()], ds[0..ds.len()], "", out, &mut err);
        },
        None => {},
    };
    if !ok {
        eprintln("super-c: the test runner's entry does not compile natively: {}", err.as_str());
    }
    return ok;
}

/// The native registry object's name in the tree: a build that links it links no C registry object.
pub(package) const NAT_REGISTRY: str = "__sc_registry_n";

// The registry of a build whose modules are all native, as an object of the target: the ZST sentinels
// of alignments `zst`, and with reflection roots `roots` (space-separated, sorted) their table and the
// constructor that registers it, as the C registry has them.
fn native_registry(p: &loader::Package, zst: &Vector<u64>, roots: str, out: &mut Vector<u8>) bool {
    let ptr = lay::target_for(p.arch).ptr as u32;
    let int = if ptr == 4 {
        "i32";
    } else {
        "i64";
    };
    let al: u32 = if ptr == 4 {
        2;
    } else {
        3;
    };
    let mut t = String::new();
    t.format_into("lir ptr {}\n", ptr);
    for i in 0..zst.len() {
        t.format_into("sym @__sc_zst_{} data global\n", zst[i]);
    }
    let mut names = Vector::<str>::new();
    let mut a: usize = 0;
    for i in 0..roots.len() + 1 {
        if i == roots.len() || roots.byte_at(i) == b' ' {
            if i > a {
                names.push(roots.slice(a, i));
            }
            a = i + 1;
        }
    }
    if names.len() != 0 {
        let f = tgt::obj_of(p.build_target).name;
        let sec = if f == "macho" {
            "__DATA,__mod_init_func,mod_init_funcs";
        } else if f == "coff" {
            ".CRT$XCU";
        } else {
            ".init_array";
        };
        for i in 0..names.len() {
            t.format_into("sym @{} data global ext\n", names[i]);
        }
        t.push_str("sym @__sc_reflect_register fn global ext\nsym @__sc_reflect_roots data local\n");
        t.format_into("sym @__sc_reflect_init fn local\nsym @__sc_reflect_ctor data local used section \"{}\"\n", sec);
        t.push_str("fn @__sc_reflect_init\n  sig () -> void\nb0:\n  v0 = symaddr @__sc_reflect_roots\n");
        t.format_into("  v1 = iconst.{} {}\n", int, names.len());
        t.format_into("  call @__sc_reflect_register(v0, v1) : (ptr, {}) -> void\n  ret\n", int);
        t.format_into("data @__sc_reflect_roots size {} align {} ro", names.len() as u32 * ptr, al);
        for i in 0..names.len() {
            t.format_into(" reloc {} @{}", i as u32 * ptr, names[i]);
        }
        t.format_into("\ndata @__sc_reflect_ctor size {} align {} reloc 0 @__sc_reflect_init\n", ptr, al);
    }
    // Windows has no C library start code that sets the stack canaries' value (`-fstack-protector`): a
    // constructor of no canary of its own fills `__stack_chk_guard` (the runtime's, `std::rt::builtins`)
    // from `rand_s`, its low byte 0 so a string copy cannot write it. The entry calls the constructors
    // one by one, so no function that keeps a canary is running when the value changes.
    if tgt::obj_of(p.build_target).name == "coff" && (p.cg & (bman::CG_PROTECT | bman::CG_PROTECT_STRONG | bman::CG_PROTECT_ALL)) != 0 {
        t.push_str("sym @__stack_chk_guard data global ext\nsym @rand_s fn global ext\nsym @abort fn global ext\n");
        t.push_str("sym @__sc_ssp_init fn local\nsym @__sc_ssp_ctor data local used section \".CRT$XCU\"\n");
        t.push_str(
            "fn @__sc_ssp_init\n  sig () -> void\nb0:\n  v0 = symaddr @__stack_chk_guard\n  v1 = call.i32 @rand_s(v0) : (ptr) -> i32\n",
        );
        t.push_str(
            "  v2 = symaddr @__stack_chk_guard+4\n  v3 = call.i32 @rand_s(v2) : (ptr) -> i32\n  v4 = or.i32 v1, v3\n",
        );
        t.push_str("  v5 = iconst.i32 0\n  v6 = icmp.ne v4, v5\n  br v6, b2, b1\nb1:\n  v7 = load.i64 v0 align 3\n");
        t.push_str("  v8 = iconst.i64 -256\n  v9 = and.i64 v7, v8\n  store v9, v0 align 3\n  ret\nb2:\n");
        t.push_str(
            "  call @abort() : () -> void\n  unreachable\ndata @__sc_ssp_ctor size 8 align 3 reloc 0 @__sc_ssp_init\n",
        );
    }
    for i in 0..zst.len() {
        let mut lg: u32 = 0;
        while 1u64 << lg as u64 < zst[i] {
            lg += 1;
        }
        t.format_into("data @__sc_zst_{} size 1 align {}\n", zst[i], lg);
    }
    let mut err = String::new();
    let mut ok = false;
    switch lparse::parse(t.as_str(), &mut err) {
        Some(pk) => {
            let mut fs = Vector::<u32>::new();
            let mut ds = Vector::<u32>::new();
            for i in 0..pk.syms.len() {
                if pk.syms[i].def != lir_ir::NONE {
                    if pk.syms[i].kind == lir_ir::SK_FUNC {
                        fs.push(i as u32);
                    } else {
                        ds.push(i as u32);
                    }
                }
            }
            ok = nat::object(&pk, p.build_target, p.arch, fs[0..fs.len()], ds[0..ds.len()], "", out, &mut err);
        },
        None => {},
    };
    if !ok {
        eprintln("super-c: the registry does not compile natively: {}", err.as_str());
    }
    return ok;
}

/// The measured cost of one runtime task (launch, run, join; 0.7 to 1.0 us over 20k empty tasks
/// on the reference machine), charged per scheduled job by the item-schedule prediction.
const ITEM_TASK_NS: u64 = 1000;
