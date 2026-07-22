// Global-phase pipeline: live-set pruning, per-module stages, platform filter, run_package.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import consteval::consteval as ce;
import codegen::codegen as cg;
import utils::errors as diag;
import driver::util as *;

import driver::extc as *;
import driver::test as *;

// ---------------------------------------------------------------------------------------------------------
// Dead-module pruning of the emit set: a live module reaches its own decls + everything it references.
// ---------------------------------------------------------------------------------------------------------
fn mark_live(live: *mut bool, n: usize, m: ModuleId) bool {
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
            let nr = unsafe (*a).resolutions.len();
            for r in 0..nr {
                let d = unsafe (*a).resolutions[r];
                if d.node != NODE_NONE && d.module as usize < n && d.module as usize != m && p.builtin_of_decl(
                    d.module,
                    d.node,
                ) < 0 {
                    if mark_live(live, n, d.module) {
                        changed = true;
                    }
                }
            }
            let nt = unsafe (*a).type_pool.len();
            for ti in 0..nt {
                if mark_type_modules(p, m as ModuleId, ti as TypeId, live) {
                    changed = true;
                }
            }
            let ni = unsafe (*a).instances.len();
            for ii in 0..ni {
                let it = unsafe *(*a).instance(ii as u32);
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
            let nmo = unsafe (*a).mono.len();
            for moi in 0..nmo {
                let mu = unsafe (*a).mono[moi];
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
            let nmi = unsafe (*a).method_insts.len();
            for xi in 0..nmi {
                let miu = unsafe (*a).method_insts[xi];
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
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut r = resolver::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    p.override_mod = i as ModuleId;
    p.override_ast = &mut r.ast;
    r.resolve();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let had = r.has_errors();
    if had || fixes == null && r.errors.has_warnings() {
        r.log_errors();
    }
    p.lint_warnings = p.lint_warnings + r.errors.warns.len() as u32;
    if fixes != null {
        for k in 0..r.errors.fixes.len() {
            unsafe (*fixes).push(r.errors.fixes[k]);
        }
    }
    let back = r.take_ast();
    p.modules[i].ast = back;
    return !had;
}

fn typecheck_module(p: &mut loader::Package, i: usize, lint: bool, fixes: *mut Vector<diag::LintFix>) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    t.lint = lint;
    p.override_mod = i as ModuleId;
    p.override_ast = &mut t.ast;
    t.check();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let had = t.has_errors();
    if had || fixes == null && t.errors.has_warnings() {
        t.log_errors();
    }
    p.lint_warnings = p.lint_warnings + t.errors.warns.len() as u32;
    if fixes != null {
        for k in 0..t.errors.fixes.len() {
            unsafe (*fixes).push(t.errors.fixes[k]);
        }
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// Borrow-check module `i`: the pipeline stage after typechecking. A fresh TypeChecker context over
// the typed AST carries the recorded types and resolutions; only the borrow/move/lifetime analyses run.
fn borrowck_module(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = &mut t.ast;
    t.borrowck();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let had = t.has_errors();
    if had {
        t.log_errors();
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// A deferred static_assert that failed once the whole package was typed: render it against the owning module.
fn flush_assert_err(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) {
    let p = ctx as *mut loader::Package;
    let sp = unsafe (*p).modules[m as usize].ast.at_const(cond).span;
    let src = unsafe (*p).modules[m as usize].source.as_str();
    let file = unsafe (*p).modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    if msg != null {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion cannot be evaluated: {}", diag::cstr(msg)));
    } else {
        errs.emit(sp.start, sp.end - sp.start, format("static assertion failed"));
    }
    errs.finalize(src, file);
    errs.log();
    unsafe (*p).ok = false;
}

// A deferred call-bearing const initializer that still cannot be evaluated once the package is typed.
fn flush_const_err(ctx: *mut void, m: ModuleId, decl: NodeId, msg: *const char) {
    let p = ctx as *mut loader::Package;
    let sp = unsafe (*p).modules[m as usize].ast.at_const(decl).span;
    let src = unsafe (*p).modules[m as usize].source.as_str();
    let file = unsafe (*p).modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    errs.emit(sp.start, sp.end - sp.start, format("constant cannot be evaluated at compile time: {}", diag::cstr(msg)));
    errs.finalize(src, file);
    errs.log();
    unsafe (*p).ok = false;
}

type TCases = Array<cg::CgTestCase, 512>;

// ---------------------------------------------------------------------------------------------------------
// Global-phase compilation of a loaded package into a `<root>/build/` tree.
// ---------------------------------------------------------------------------------------------------------
// Drop @platform-gated items that don't match the build target BEFORE resolution, so inactive code is
// parsed-but-never-resolved and two same-named platform variants collapse to the single active one.
// target: 0 windows, 1 macos, 2 linux; Attr.arg is the active-set mask (windows=bit0/macos=bit1/linux=bit2).
pub fn platform_filter(p: &mut loader::Package, target: i32) {
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
            if m.ast.at_const(id).kind != NodeKind::NODE_IMPORT {
                for k in 0..m.ast.attrs.len() {
                    let at = m.ast.attrs.at(k);
                    if at.owner == id && at.kind == AttrKind::ATTR_PLATFORM as u8 {
                        if (at.arg >> target as u32 & 1u32) == 0 {
                            keep = false;
                        }
                        break;
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
    for i in 0..unsafe (*a).attrs.len() {
        let at = unsafe (*a).attrs.at(i);
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

fn lint_ent_cmp(a: &LintEnt, b: &LintEnt) i32 {
    if a.start < b.start {
        return -1;
    }
    if a.start > b.start {
        return 1;
    }
    return 0;
}

fn lint_edge_cmp(a: &u64, b: &u64) i32 {
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

fn lint_build_entries(p: &loader::Package, m: usize, only_mod: i32, ents: &mut Vector<LintEnt>) {
    let a = mod_ast_c(p, m as ModuleId);
    // items of a module reported this run are candidates; everything else roots the graph
    let reported = if only_mod >= 0 {
        m == only_mod as usize;
    } else {
        !p.modules[m].prelude;
    };
    let src = p.modules[m].source.as_str();
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        let it = unsafe (*a).at_const(iid);
        if it.kind == NodeKind::NODE_IMPORT {
            continue;
        }
        if it.kind == NodeKind::NODE_EXTEND {
            let in_iface = it.as_data.extend_def.interface_type != NODE_NONE;
            let ms = it.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe (*a).list(ms)[j as usize];
                let msp = unsafe (*a).at_const(mid).span;
                ents.push(
                    LintEnt {
                        start: msp.start,
                        end: msp.end,
                        node: mid,
                        root: !(reported && lint_item_candidate(a, mid, in_iface)),
                    },
                );
            }
            continue;
        }
        let mut root = !(reported && lint_item_candidate(a, iid, false));
        // `main` in the root module is the program entry: never reported, always a root
        if !root && m == 0 && it.kind == NodeKind::NODE_FUNCTION {
            let nsp = unsafe (*a).at_const(it.as_data.function.name).as_data.name.text;
            if diag::span_str(src, nsp.start, nsp.end) == "main" {
                root = true;
            }
        }
        ents.push(LintEnt { start: it.span.start, end: it.span.end, node: iid, root: root });
    }
    ents.sort_by(lint_ent_cmp);
}

fn lint_item_candidate(a: *const Ast, iid: NodeId, in_iface_extend: bool) bool {
    let it = unsafe (*a).at_const(iid);
    if it.kind == NodeKind::NODE_FUNCTION {
        let f = it.as_data.function;
        if f.is_public || f.is_extern || f.body == NODE_NONE || in_iface_extend {
            return false;
        }
        return !(item_has_attr(a, iid, AttrKind::ATTR_EXPORT) || item_has_attr(a, iid, AttrKind::ATTR_USED) || item_has_attr(
            a,
            iid,
            AttrKind::ATTR_TEST,
        ) || item_has_attr(a, iid, AttrKind::ATTR_TEST_INIT) || item_has_attr(a, iid, AttrKind::ATTR_TEST_FREE));
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
    let it = unsafe (*a).at_const(iid);
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
    let nsp = unsafe (*a).at_const(nid).as_data.name.text;
    if root_mod && it.kind == NodeKind::NODE_FUNCTION && diag::span_str(src, nsp.start, nsp.end) == "main" {
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
    // Prelude modules only participate when the linted module IS prelude (std lint invocation): the
    // prelude never references user code, and std cross-references must count when linting std itself.
    let inc_prelude = only_mod >= 0 && p.modules[only_mod as usize].prelude;
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
        for i in 0..unsafe (*a).resolutions.len() {
            let d = unsafe (*a).resolutions[i];
            if d.node == NODE_NONE || d.module as usize >= nm {
                continue;
            }
            let dm = d.module as usize;
            if ents[dm].len() == 0 {
                continue;
            }
            let si = lint_owner(ents.at(m), unsafe (*a).at_const(i as NodeId).span.start);
            if si < 0 {
                continue;
            }
            let ta = mod_ast_c(p, d.module);
            let di = lint_owner(ents.at(dm), unsafe (*ta).at_const(d.node).span.start);
            if di < 0 {
                continue;
            }
            let ss = (starts[m] + ents[m][si as usize].node as usize) as u64;
            let ds = (starts[dm] + ents[dm][di as usize].node as usize) as u64;
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
        if !p.modules[m].has_ast || only_mod >= 0 && m != only_mod as usize || only_mod < 0 && p.modules[m].prelude {
            continue;
        }
        let a = mod_ast_c(p, m as ModuleId);
        let mut errs = diag::Errors::new();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let iid = unsafe (*a).list(items)[i as usize];
            let it = unsafe (*a).at_const(iid);
            if it.kind == NodeKind::NODE_EXTEND {
                let in_iface = it.as_data.extend_def.interface_type != NODE_NONE;
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*a).list(ms)[j as usize];
                    if lint_item_candidate(a, mid, in_iface) && !used[starts[m] + mid as usize] {
                        lint_report_item(p, &mut errs, a, m as ModuleId, mid, m == 0);
                    }
                }
            } else if lint_item_candidate(a, iid, false) && !used[starts[m] + iid as usize] {
                lint_report_item(p, &mut errs, a, m as ModuleId, iid, m == 0);
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
    for i in 0..unsafe (*a).attrs.len() {
        let at = unsafe (*a).attrs.at(i);
        if at.owner == fnode && (at.kind == AttrKind::ATTR_TEST as u8 || at.kind == AttrKind::ATTR_TEST_INIT as u8 || at.kind == AttrKind::ATTR_TEST_FREE as u8) {
            return true;
        }
    }
    return false;
}

fn ap_check_fn(p: &loader::Package, errs: &mut diag::Errors, a: *const Ast, m: usize, fnode: NodeId) {
    if unsafe (*a).at_const(fnode).kind != NodeKind::NODE_FUNCTION || ap_is_test_fn(a, fnode) {
        return;
    }
    let cev = p.ceval as *mut ce::ConstEval;
    let hit = unsafe (*cev).ce_lint_body(m as ModuleId, fnode);
    if hit != NODE_NONE {
        let sp = unsafe (*a).at_const(hit).span;
        if ce::ce_trap_is_ub(unsafe (*cev).ce_trap_kind_get()) {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement is undefined behavior when executed: {}", unsafe (*cev).ce_trap_detail()),
            );
        } else {
            errs.emit(
                sp.start,
                sp.end - sp.start,
                format("this statement always panics at runtime: {}", unsafe (*cev).ce_trap_detail()),
            );
        }
    }
}

// Always-panics check (the `unconditional_panic` analog, an ERROR like the raw-array provable-OOB
// gate -- the same proof one tier up). A DRIVER phase, after every module has typechecked: the
// sweep interprets cross-module `const fn` bodies, whose types only exist once their module is
// typed -- an inline per-module pass would silently fold nothing (module order). @test fns are
// exempt (panicking on purpose is a feature there), as are explicit `panic(..)` calls (only a
// panic reached THROUGH a `const fn` frame classifies -- see ce_lint_body).
pub fn check_always_panics_module(p: &mut loader::Package, m: usize, errs: &mut diag::Errors) {
    if p.ceval == null || !p.modules[m].has_ast {
        return;
    }
    let a = mod_ast_c(p, m as ModuleId);
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    for i in 0..items.len {
        let iid = unsafe (*a).list(items)[i as usize];
        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
            for j in 0..ms.len {
                ap_check_fn(p, errs, a, m, unsafe (*a).list(ms)[j as usize]);
            }
        } else {
            ap_check_fn(p, errs, a, m, iid);
        }
    }
}

fn check_always_panics(p: &mut loader::Package, only_mod: i32) {
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || only_mod >= 0 && m != only_mod as usize || only_mod < 0 && p.modules[m].prelude {
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

// `super-c lint <root>`: resolve + typecheck the root's module closure with lints enabled for the
// ROOT module only (each listed path is its own invocation, so shared imports don't warn twice),
// then the unused-items pass restricted to the root. No code is emitted. Errors exit 1; warnings
// alone exit 0 (compiler-warning semantics).
pub fn lint_package(p: &mut loader::Package, target: i32, lint_mod: usize, fixes: *mut Vector<diag::LintFix>) i32 {
    platform_filter(p, target);
    let n = p.modules.len();
    for i in 0..n {
        let fx = if i == lint_mod {
            fixes;
        } else {
            null;
        };
        let ok = resolve_module(p, i, i == lint_mod, fx);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    for i in 0..n {
        let fx = if i == lint_mod {
            fixes;
        } else {
            null;
        };
        let ok = typecheck_module(p, i, i == lint_mod, fx);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    for i in 0..n {
        let ok = borrowck_module(p, i);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    // Report-only passes: skipped while `--fix` iterates (they yield no fixes and would print duplicates).
    if fixes == null {
        lint_unused_items(p, lint_mod as i32);
        let ceptr = p.ceval as *mut ce::ConstEval;
        if ceptr != null {
            unsafe (*ceptr).all_typed = true;
        }
        check_always_panics(p, lint_mod as i32);
    }
    if !p.ok || p.lint_warnings != 0 {
        return 1;
    }
    return 0;
}

pub fn run_package(p: &mut loader::Package, topts: *const TestOpts, out_bin: str, target: i32, lint: bool) i32 {
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
        let ok = typecheck_module(p, i, lint && !p.modules[i].prelude, null);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    for i in 0..n {
        let ok = borrowck_module(p, i);
        p.ok = ok && p.ok;
    }
    if !p.ok {
        return 1;
    }
    if lint {
        lint_unused_items(p, -1);
    }
    // static_asserts undecidable in module order re-evaluate now that every module is fully typed.
    let ceptr = p.ceval as *mut ce::ConstEval;
    if ceptr != null {
        let pv = p as *mut loader::Package;
        unsafe (*ceptr).all_typed = true;
        // an ERROR, not a lint: it runs on every build (user modules; std is gated by check.sh's
        // explicit std lint invocations)
        check_always_panics(p, -1);
        unsafe (*ceptr).flush_asserts(flush_assert_err, pv);
        unsafe (*ceptr).flush_consts(flush_const_err, pv);
    }
    if !p.ok {
        return 1;
    }
    loader::package_propagate_instances(p);

    let testing = topts != null && unsafe (*topts).enabled;
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
    let mut err = false;
    // `@c.source` wrapper TUs land in keep[]; `@c.link` flags feed build/__ldflags for the link line.
    ext_c_collect(p, &mut keep, &mut err);
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
    for oi in 0..n {
        let mi = unsafe order[oi];
        if live != null && !unsafe live[mi as usize] {
            continue;
        }
        let m_ast = mod_ast_m(p, mi);
        let src = p.modules[mi as usize].source.as_str().ptr() as *const char;
        let slen = p.modules[mi as usize].source.len();
        let mpath = p.modules[mi as usize].path.as_str();
        let pkg = p as *mut loader::Package;
        let mut c = cg::Codegen::new(m_ast, str::from_raw(src as *const u8, slen), pkg);
        c.set_multifile(true);
        let mut tcases = TCases {}; // must outlive codegen_emit (CgTestInfo keeps a pointer into it)
        if testing {
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
        let hpath = build_out_path(root, mpath, ".h");
        let hout = open_out(hpath.as_str());
        if hout != null {
            c.codegen_emit_header(hout);
            unsafe stdio::fclose(hout);
        }
        keep.push(hpath);
        let mut opath = build_out_path(root, mpath, ".c");
        let out = open_out(opath.as_str());
        if out == null {
            unsafe stdio::perror(opath.cstr());
            err = true;
        } else {
            c.codegen_emit(out);
            unsafe stdio::fclose(out);
            if c.has_errors() {
                c.log_errors();
                err = true;
            }
        }
        keep.push(opath);
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
            rc = test_build_and_run(p, null, &keep, out_bin);
        }
    } else if testing && !err {
        if plan.cases.len() == 0 {
            unsafe stdio::fputs("super-c: no '@test' functions found\n".ptr() as *const char, stdio::stderr());
            rc = 1;
        } else {
            switch write_test_main(p, &plan) {
                Some(runner) => {
                    keep.push(runner);
                    rc = test_build_and_run(p, topts, &keep, "");
                },
                None => {
                    rc = 1;
                },
            };
        }
    }
    return rc;
}
