// The LSP's codegen-free diagnostics pass: build the package (editor-buffer overlays applied), resolve
// and typecheck every module, and harvest every diagnostic as a (module, span, severity, message)
// record instead of printing it. Mirrors driver::emit's lint_package recipe with a PER-MODULE gate:
// a module typechecks once its own import closure resolves, so one broken module cannot suppress
// another module's semantic diagnostics. The borrow check runs after the analysis, as its own round
// (`borrowck_pending`): the server publishes the analysis first, and a new edit abandons the round.
import driver_shim as shim;
import std::platform::fs;
import std::platform::path;
import module::loader as loader;
import ast::ast as *;
import ast::parser as par;
import lexer::lexer as lex;
import resolver::resolver as resolver;
import hir::lower as hirl;
import target::table as tgt;
import typechecker::typechecker as tc;
import borrowck::facts as bfx;
import borrowck::flow_ir as bfi;
import ir::lower as irl;
import ir::core as core;
import ir::recursion as recur;
import ir::interp as iri;
import ir::cpu_features as cf;
import utils::errors as diag;
import driver::emit as emit;
import driver::tuc as tuc;
import driver::util as dutil;
import graph::items as gitems;
import build_system::manifest as bman;
import build_system::build as bsys;
import stdio;
import stdlib;
import utils::diag_codes as dc;

/// The pass that produced a record (`DiagRec.phase`): each phase replaces its own records.
pub(package) const PH_ANALYSIS: u8 = 0; // parse, resolve, typecheck, feature checks, always-panics, deferred constants
pub(package) const PH_BORROW: u8 = 1; // the borrow check (`borrowck_pending`)
pub(package) const PH_UNUSED: u8 = 2; // the package-wide unused-item lint (`lsp_unused_items`)
pub(package) const PH_RECUR: u8 = 3; // the package-wide unbounded-recursion check (`recur_check`)

/// One harvested diagnostic: the cross-pass record the server publishes and codeAction later reads
/// (the fix fields carry the machine-applicable quick fix, if any).
pub(package) struct DiagRec {
    pub(package) code: u16, // `utils::diag_codes`
    pub(package) module: u32,
    pub(package) start: u32, // byte span into the module's source
    pub(package) len: u32,
    pub(package) severity: u8, // LSP DiagnosticSeverity: 1 = error, 2 = warning
    pub(package) phase: u8, // PH_*
    pub(package) msg: String,
    // machine-applicable fix: -1 = none, else a LintFix kind (0 delete [fix_start, fix_end),
    // 1 insert '_', 2 insert 'const ', 4 replace [fix_start, fix_end) with `fix_text`) surfaced as
    // an LSP quick fix.
    pub(package) fix_kind: i32,
    pub(package) fix_start: u32,
    pub(package) fix_end: u32,
    pub(package) fix_text: String, // kind-4 payload (replacement text); empty otherwise
}

// The editor-facing message for one structured record: the message's first line plus one "= note:"
// line per attached note (its first line, trailing whitespace trimmed: notes carry fix hints worth
// showing in the editor; a note's continuation lines are location blocks the editor renders itself).
fn rec_msg(e: &diag::Errors, d: &diag::Diagnostic) String {
    let s = d.msg.as_str();
    let mut end: usize = 0;
    while end < s.len() && s[end] != b'\n' {
        end += 1;
    }
    let mut out = String::from_str(s.slice(0, end));
    let mut n = d.note_head;
    while n != diag::NOTE_NONE {
        let t = e.note_pool.at(n as usize).text.as_str();
        let mut le: usize = 0;
        while le < t.len() && t[le] != b'\n' {
            le += 1;
        }
        while le > 0 && (t[le - 1] == b' ' || t[le - 1] == b'\t') {
            le -= 1;
        }
        if le > 0 {
            out.push_byte(b'\n');
            out.push_str("= note: ");
            out.push_str(t.slice(0, le));
        }
        n = e.note_pool.at(n as usize).next;
    }
    return out;
}

// Append every error/warning record in `e` as a DiagRec of pass `phase` against module `m` (the
// records carry their spans and note chains directly; nothing is parsed back out of rendered text).
// Fixes attach to warnings only (`Errors::fix` and `fix_replace` index `warns`); the first fix of a
// warning wins.
fn drain_errors(e: &diag::Errors, m: u32, phase: u8, diags: &mut Vector<DiagRec>) {
    let mut wfix = Vector::<u32>::new();
    wfix.reserve(e.warns.len());
    for _ in 0..e.warns.len() {
        wfix.push(0xFFFFFFFF);
    }
    for j in 0..e.fixes.len() {
        let w = e.fixes.at(j).warn as usize;
        if w < wfix.len() && wfix[w] == 0xFFFFFFFF {
            wfix.set(w, j as u32);
        }
    }
    for severity in 1u8..3u8 {
        let records = if severity == 1 {
            &e.errors;
        } else {
            &e.warns;
        };
        for k in 0..records.len() {
            let mut fk: i32 = -1;
            let mut fs: u32 = 0;
            let mut fe: u32 = 0;
            let mut ftx = String::new();
            if severity == 2 && wfix[k] != 0xFFFFFFFF {
                let f = *e.fixes.at(wfix[k] as usize);
                fk = f.kind;
                fs = f.start;
                fe = f.end;
                if f.text != 0xFFFFFFFF && f.text as usize < e.fix_texts.len() {
                    ftx = e.fix_texts.at(f.text as usize).clone();
                }
            }
            let d = records.at(k);
            diags.push(
                DiagRec {
                    code: d.code,
                    module: m,
                    start: d.start,
                    len: d.len,
                    severity: severity,
                    phase: phase,
                    msg: rec_msg(e, d),
                    fix_kind: fk,
                    fix_start: fs,
                    fix_end: fe,
                    fix_text: ftx,
                },
            );
        }
    }
}

// A module that failed to lex/parse dropped its diagnostics on stderr (loader::parse_source); re-run
// the lexer + parser over its held source (cheap: only broken files) and harvest them.
fn harvest_parse_errors(p: &loader::Package, i: usize, diags: &mut Vector<DiagRec>) {
    let m = p.modules.at(i);
    let mut vsrc = m.source.clone();
    let mut lx = lex::Lexer::new(&mut vsrc, m.file.as_str());
    lx.scan_tokens();
    if lx.has_errors() {
        drain_errors(&lx.errors, i as u32, PH_ANALYSIS, diags);
        return;
    }
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, vsrc.as_str(), m.file.as_str());
    ps.build_ast();
    drain_errors(&ps.errors, i as u32, PH_ANALYSIS, diags);
}

// The load errors of module `i` (`loader::LoadError`) as diagnostics at the import they concern: an import
// that does not read, a project file a std module shadows.
fn load_diags(p: &loader::Package, i: usize, diags: &mut Vector<DiagRec>) {
    for k in 0..p.load_errors.len() {
        let e = &p.load_errors[k];
        if e.module != i as i32 {
            continue;
        }
        let src = p.modules[i].source.as_str();
        let mut start: u32 = 0;
        let mut end: u32 = 0;
        if e.off != loader::IMPORT_OFF_NONE && e.off as usize < src.len() {
            start = e.off;
            end = start;
            while end as usize < src.len() && src.byte_at(end as usize) != b';' && src.byte_at(end as usize) != b'\n' {
                end += 1;
            }
        }
        diags.push(
            DiagRec {
                code: dc::CANNOT_OPEN_MODULE,
                module: i as u32,
                start: start,
                len: end - start,
                severity: 1,
                phase: PH_ANALYSIS,
                msg: e.msg.clone(),
                fix_kind: -1,
            },
        );
    }
}

/// Canonicalize `path` via realpath; a file not on disk yet keeps the given form.
pub(package) fn canon_path(path: str) String {
    return fs::realpath(path).unwrap_or(String::from_str(path));
}

// The build settings the analysis reads, as the build of the project at `dir` reads them
// (`lsp_build_settings`).
struct BuildSettings {
    pub(package) arch: i32,
    pub(package) features: cf::CpuFeatureSet,
    pub(package) profiles: Vector<String>,
    pub(package) ce_steps: u32,
    pub(package) ce_mem: u64,
    pub(package) std_internals: bool,
}

// The nearest `build.toml` at or above `dir` (the manifest discovery of a manifest command) gives
// the profile names a PROFILE comparison may name (`Package.profiles`), the constant engine budgets
// (`Package.ce_steps`, `ce_mem`) and the CPU level and features, at the analysis's profile (`debug`,
// the profile of a package that names none), as `super-c build` takes them; without one (or one
// that does not load), the built-in profiles, the engine defaults and the target's baseline, as a
// script build takes them. The instruction set is the target's (`target_arch`).
fn lsp_build_settings(dir: str, target: i32) BuildSettings {
    let arch = target_arch(target);
    let abs = path::is_absolute(dir);
    let mut d = String::from_str(dir);
    // A path has fewer components than this; each step drops one.
    for _ in 0..256 {
        let mut mp = String::from_str(d.as_str());
        mp.push_str("/build.toml");
        let f = stdio::fopen(mp.as_str(), "rb");
        if f != null {
            unsafe stdio::fclose(f);
            if let Some(m) = bman::load(mp.as_str(), false) {
                let mut mm = m;
                mm.arch = arch;
                mm.target = target;
                return BuildSettings {
                    arch: arch,
                    features: bsys::features_for(&mm, "debug", ""),
                    profiles: bsys::profile_names(&mm),
                    ce_steps: mm.ce_steps,
                    ce_mem: mm.ce_mem,
                    std_internals: mm.std_internals,
                };
            }
            break;
        }
        let up = String::from_str(loader::dirname_of(d.as_str()));
        // An absolute walk ends at its root: above a Windows drive (`C:`), `dirname_of` gives `.`, the
        // working directory.
        if up.len() == 0 || up.len() >= d.len() || abs && up.as_str() == "." {
            break;
        }
        d = up;
    }
    let bi = bman::builtins_only();
    return BuildSettings {
        arch: arch,
        features: cf::close(tgt::baseline(target, arch)),
        profiles: bsys::profile_names(&bi),
    };
}

// Load with the instruction set and CPU features of `bs`, set before the load as the driver sets
// them (`loader::set_load_target`).
fn lsp_load_target(bs: &BuildSettings) {
    loader::set_load_target(bs.arch, bs.features);
}

// The rest of `bs` on the loaded package `p`.
fn lsp_apply_settings(p: &mut loader::Package, mut bs: BuildSettings) {
    p.profiles = replace(&mut bs.profiles, Vector::<String>::new());
    p.ce_steps = bs.ce_steps;
    p.ce_mem = bs.ce_mem;
    p.std_internals = bs.std_internals;
}

// A constant engine with the budgets of the build the analysis stands for. A round's engine
// records no dynamic item edges: the package index it would record into is rebuilt every round.
fn lsp_engine(p: &mut loader::Package) iri::Interp {
    let steps = p.ce_steps;
    let mem = p.ce_mem;
    let mut e = iri::interp_master(p as *mut loader::Package, steps, mem);
    e.dyn_rec = false;
    return e;
}

// Lints run for non-prelude modules other than the runtime (like `super-c build`), for the package's
// root file when it IS a prelude module (the `super-c lint <std file>` recipe), and: when `lint_dir` is
// non-empty (the manifest root's build passes the canonical workspace root): for every prelude module
// under that directory, so a repo carrying its own std/ lints it like `super-c lint std`. Gating on the
// root file rather than "any open doc" keeps each file's lint warnings owned by exactly one root.
fn lsp_lint_wanted(p: &mut loader::Package, i: usize, root_file: str, lint_dir: str) bool {
    // Batch build: the mask names the member files; everything else (their closures, the prelude)
    // is someone else's to lint.
    if p.lint_set.len() != 0 {
        return p.lint_set[i];
    }
    if !p.modules[i].prelude && !p.is_rt(i as i32) {
        return true;
    }
    if dutil::same_file(p.modules[i].file.as_str(), root_file) {
        return true;
    }
    if lint_dir.len() == 0 {
        return false;
    }
    let cf = canon_path(p.modules[i].file.as_str());
    return cf.len() > lint_dir.len() && cf.as_str().slice(0, lint_dir.len()) == lint_dir && cf.as_str()[lint_dir.len()] == b'/';
}

// emit::resolve_module with the diagnostics drained instead of logged.
fn lsp_resolve_module(p: &mut loader::Package, i: usize, lint: bool, diags: &mut Vector<DiagRec>) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let aptr = (&mut m.ast) as *mut Ast;
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, unsafe str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    r.resolve();
    let had = r.has_errors();
    drain_errors(&r.errors, i as u32, PH_ANALYSIS, diags);
    hirl::lower_module(p, i);
    return !had;
}

// Typecheck module `i` and drain its diagnostics into `diags` instead of logging them. The
// result-attributability verdicts of its functions are recorded while its bodies are live: the
// borrow check of a caller reads them after the module released its bodies.
fn lsp_typecheck_module(p: &mut loader::Package, i: usize, lint: bool, diags: &mut Vector<DiagRec>) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    t.lint = lint;
    t.check();
    t.bc_record_ret_attr();
    let had = t.has_errors();
    drain_errors(&t.errors, i as u32, PH_ANALYSIS, diags);
    return !had;
}

// Record module `i`'s post-typecheck item edges (`Package.item_edges`) from its resolution tables,
// keyed by declaration nodes.
fn record_item_edges(p: &mut loader::Package, i: usize, sps: &Vector<gitems::Spans>) {
    let mut ev = Vector::<u64>::new();
    gitems::module_edges(p, i, sps, &mut ev);
    let mut v = Vector::<loader::RefEdge>::with_capacity(ev.len());
    for k in 0..ev.len() {
        let o = p.idx().items.at((ev[k] >> 32) as usize);
        let t = p.idx().items.at((ev[k] & 0xFFFFFFFFu64) as usize);
        v.push(loader::RefEdge { key: t.module as u64 << 32 | t.node as u64, owner: o.node });
    }
    while p.item_edges.len() <= i {
        p.item_edges.push(Vector::<loader::RefEdge>::new());
    }
    p.item_edges.set(i, v);
}

/// Load + resolve + typecheck (NO codegen), harvesting all diagnostics into `diags`. Takes ownership of
/// the overlay vectors. The returned Package keeps every module's typed Ast: the positional features
/// (hover/definition/references) query it until the next rebuild. Lint gating: see lsp_lint_wanted;
/// `lint_dir` is the canonical workspace root when this build is the manifest root's, else "".
pub(package) fn compile(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    lint_dir: str,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    return compile_keeping(root_file, root_dir, alt_dir, std_dir, target, ov_files, ov_texts, lint_dir, false, diags);
}

/// `compile`; with `keep_bodies` the package keeps the body syntax of every module outside std and `ffi/`
/// (`Package.keep_bodies`), not only its overlays'.
pub(package) fn compile_keeping(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    lint_dir: str,
    keep_bodies: bool,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    let t0 = dutil::ticks_ms();
    let bs = lsp_build_settings(
        if lint_dir.len() != 0 {
            lint_dir;
        } else {
            root_dir;
        },
        target,
    );
    lsp_load_target(&bs);
    let mut p = loader::package_load_overlaid(root_file, root_dir, alt_dir, std_dir, false, target, ov_files, ov_texts);
    p.keep_bodies = keep_bodies;
    lsp_apply_settings(&mut p, bs);
    let st = run_pipeline(&mut p, target, root_file, lint_dir, diags);
    stats_line(&p, "compile", t0, &st);
    return p;
}

/// The LSP's workspace batch: like `super-c lint`'s one-package recipe; the prelude loads first,
/// every listed file joins the shared closure once, and `lint_set` marks the members so lints (and
/// the always-panics pass) report exactly them. ONE resident package replaces the per-file sweep
/// packages, which is what held a full prelude + closure copy per workspace file.
pub(package) fn compile_batch(
    files: &Vector<String>,
    root_dir: str,
    alt_dir: str,
    std_dir: str,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    let t0 = dutil::ticks_ms();
    let bs = lsp_build_settings(root_dir, target);
    lsp_load_target(&bs);
    let mut p = loader::package_load_prelude(root_dir, alt_dir, std_dir, target, ov_files, ov_texts);
    let mut mids = Vector::<i32>::new();
    for k in 0..files.len() {
        let fc = files.at(k).as_str();
        let mut mid: i32 = -1;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && dutil::same_file(fc, p.modules[m].file.as_str()) {
                mid = m as i32;
                break;
            }
        }
        if mid < 0 {
            let mp = loader::batch_mod_path(files.at(k).as_str(), root_dir, alt_dir);
            mid = p.load_module(mp.as_str(), files.at(k).as_str(), false, target);
        }
        mids.push(mid);
    }
    let mut set = Vector::<bool>::new();
    for m in 0..p.modules.len() {
        set.push(false);
    }
    for k in 0..mids.len() {
        if mids[k] >= 0 {
            set.set(mids[k] as usize, true);
        }
    }
    p.lint_set = set;
    lsp_apply_settings(&mut p, bs);
    let st = run_pipeline(&mut p, target, "", "", diags);
    stats_line(&p, "batch", t0, &st);
    return p;
}

// Incremental re-analysis: the LSP's query layer. An already compiled package is updated in place
// against the CURRENT overlays; only the edit's reach re-runs. Module granularity: a changed module
// re-parses (fresh node ids), so it AND every module whose import closure contains it re-resolve and
// re-typecheck; everything else keeps its analysis and diagnostics verbatim (per-module type pools
// reference other modules only by decl node id, so an analysis is stale exactly when a closure member
// reparsed). Item granularity: a reparse that keeps the module-arena shape keeps every declaration
// id, so only the importers that name a touched item re-analyze; an edit strictly inside one plain
// fn body reaches only the compile-time readers of that body. The changed module always parses
// whole, so every round leaves the state a fresh analysis of the same buffers leaves. Anything
// outside the incremental domain returns false and the caller falls back to a full compile.
// Body ownership: a module without an editor buffer keeps only its module arena between rounds
// (`release_closed`); a round parses a released module's bodies back when its document opens,
// when it must re-analyze, or when the constant engine demands a body of it (`typecheck_set`).

/// Outcome counters for one incremental round: the exit-gate observables (what re-ran and why).
pub(package) struct RecompileStats {
    pub(package) reparsed: u32, // changed modules (each reparses whole)
    pub(package) analyzed: u32, // modules re-resolved + re-typechecked (the affected closure)
    pub(package) body_only: u32, // changed modules whose edit changed one plain fn body alone (declaration ids stable)
    pub(package) bodies_back: u32, // modules whose released body syntax the round parsed back
    pub(package) passes: u32, // extra typecheck passes after the engine demanded a released body
    pub(package) kept: u32, // importers of a reparsed module whose analysis stood (no touched reference)
}

// One module's import-decl surface, rendered to comparable bytes: path segment texts, alias text,
// glob flag. Two surfaces equal <=> the loader would build the same closure edges.
fn import_surface(a: &Ast, src: str, out: &mut String) {
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let id = unsafe a.list(items)[i as usize];
        let n = a.at_const(id);
        if n.kind != NodeKind::NODE_IMPORT {
            continue;
        }
        let im = n.as_data.import_decl;
        for k in 0..im.path.len {
            let sp = a.at_const(unsafe a.list(im.path)[k as usize]).as_data.name.text;
            out.push_str(src.slice(sp.start as usize, sp.end as usize));
            out.push_byte(b':');
        }
        if im.alias != NODE_NONE {
            let sp = a.at_const(im.alias).as_data.name.text;
            out.push_byte(b'=');
            out.push_str(src.slice(sp.start as usize, sp.end as usize));
        }
        if im.glob {
            out.push_byte(b'*');
        }
        out.push_byte(b';');
    }
}

// True when two parses of a module have the same module-arena tree (the node count, the kind at
// every id, the child lists): every id then names the same declaration, so an importer's
// resolutions into the module stay valid across the reparse.
fn same_shape(a: &Ast, b: &Ast) bool {
    if a.nodes.len() != b.nodes.len() || a.children.len() != b.children.len() {
        return false;
    }
    for i in 0..a.nodes.len() {
        if a.nodes.at(i).kind != b.nodes.at(i).kind {
            return false;
        }
    }
    for i in 0..a.children.len() {
        if *a.children.at(i) != *b.children.at(i) {
            return false;
        }
    }
    return true;
}

const SLOT_NONE: u32 = 0xFFFFFFFF;

// True when the item at `by_node` position `k` is a function with a body in the body arena.
const fn slot_has_body(p: &loader::Package, m: usize, k: usize) bool {
    let nd = p.modules[m].ast.at_const(slot_node(p, k as u32));
    return nd.kind == NodeKind::NODE_FUNCTION && Ast::in_body(
        p.modules[m].ast.ext(slot_node(p, k as u32)).function.body,
    );
}

// The `by_node` position of the item whose own ranges hold `node` of module `m` (the owner
// search of `graph::items`: a module-arena node belongs to the first item at or after it in
// node order, a body node to the function whose body run holds it), or SLOT_NONE past every
// range (a desugar appended later).
fn slot_of(p: &loader::Package, m: usize, node: NodeId) u32 {
    let mut lo = p.idx().mod_items[m] as usize;
    let end = p.idx().mod_items[m + 1] as usize;
    let mut hi = end;
    if Ast::in_body(node) {
        let b = node & NODE_BODY_MASK;
        while lo < hi {
            let mid = (lo + hi) / 2;
            if p.sched.body_hi[mid] < b {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // `body_hi` is the largest body block id so far: an item without a body repeats the
        // one before it (and the first items repeat 0, the first body's own block id), so the
        // owner is the first position at or past the search that owns a body.
        while lo < end && !slot_has_body(p, m, lo) {
            lo += 1;
        }
    } else {
        while lo < hi {
            let mid = (lo + hi) / 2;
            if p.idx().items.at(p.sched.by_node[mid] as usize).node < node {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
    }
    if lo >= end {
        return SLOT_NONE;
    }
    return lo as u32;
}

// The declaration node at `by_node` position `k`.
const fn slot_node(p: &loader::Package, k: u32) NodeId {
    return p.idx().items.at(p.sched.by_node[k as usize] as usize).node;
}

// The module-arena node range (lo, hi] of the item at position `k` of module `m`, pushed as
// (lo + 1, hi): the nodes after the previous item's declaration up to its own.
fn push_slot_range(p: &loader::Package, m: usize, k: u32, out: &mut Vector<u32>) {
    let lo = if k as usize > p.idx().mod_items[m] as usize {
        slot_node(p, k - 1) + 1;
    } else {
        0u32;
    };
    out.push(lo);
    out.push(slot_node(p, k));
}

const fn ref_edge_cmp(a: &loader::RefEdge, b: &loader::RefEdge) i32 {
    if a.key != b.key {
        return a.key.cmp(&b.key);
    }
    return a.owner.cmp(&b.owner);
}

// Record module `i`'s references (`Package.def_refs`) from its resolution tables once a round's
// analysis of it is complete: one edge per (item, declaration of another item) pair, the
// module's own items included, so the record answers for the module while its bodies are
// released. A node past every item's ranges records a module-wide owner.
fn record_refs(p: &mut loader::Package, i: usize) {
    let mut v = Vector::<loader::RefEdge>::new();
    {
        let a = &p.modules[i].ast;
        let nb = a.nodes.len();
        let nn = a.nnodes();
        // The owner of a run of nodes repeats: re-searched only past the current slot's range.
        let mut cur: u32 = SLOT_NONE;
        let mut cur_lo: u32 = 0;
        let mut cur_hi: u32 = 0;
        let mut cur_body = false;
        let mut last_key: u64 = 0;
        let mut last_owner: u32 = 0;
        for k in 0..nn {
            let n = Ast::nth_id_n(nb, k);
            let d = a.resolution_def(n);
            if d.node == NODE_NONE || d.module as usize == i && Ast::in_body(d.node) {
                continue;
            }
            let body = Ast::in_body(n);
            let nv = n & NODE_BODY_MASK;
            if cur == SLOT_NONE || body != cur_body || nv <= cur_lo || nv > cur_hi {
                cur = slot_of(p, i, n);
                cur_body = body;
                if cur != SLOT_NONE {
                    let first = cur as usize == p.idx().mod_items[i] as usize;
                    if body {
                        cur_lo = if first {
                            0u32;
                        } else {
                            p.sched.body_hi[cur as usize - 1];
                        };
                        cur_hi = p.sched.body_hi[cur as usize];
                    } else {
                        cur_lo = if first {
                            0u32;
                        } else {
                            slot_node(p, cur - 1);
                        };
                        cur_hi = slot_node(p, cur);
                    }
                }
            }
            let mut owner = if cur == SLOT_NONE {
                loader::REF_MODULE_WIDE;
            } else {
                slot_node(p, cur);
            };
            if body {
                owner |= loader::REF_BODY_EDGE;
            }
            if d.module as usize == i && cur != SLOT_NONE && slot_of(p, i, d.node) == cur {
                continue;
            }
            let key = d.module as u64 << 32 | d.node as u64;
            if key != last_key || owner != last_owner {
                v.push(loader::RefEdge { key: key, owner: owner });
                last_key = key;
                last_owner = owner;
            }
        }
    }
    v.sort_by(|x: &loader::RefEdge, y: &loader::RefEdge| ref_edge_cmp(x, y));
    let mut w: usize = 0;
    for k in 0..v.len() {
        if w == 0 || v[k].key != v[w - 1].key || v[k].owner != v[w - 1].owner {
            v.set(w, v[k]);
            w += 1;
        }
    }
    v.truncate(w);
    while p.def_refs.len() <= i {
        p.def_refs.push(Vector::<loader::RefEdge>::new());
    }
    p.def_refs.set(i, v);
}

// The first recorded edge of module `m` whose key is at least `want`.
const fn ref_lower_bound(v: &Vector<loader::RefEdge>, want: u64) usize {
    let mut a: usize = 0;
    let mut b: usize = v.len();
    while a < b {
        let mid = (a + b) / 2;
        if v.at(mid).key < want {
            a = mid + 1;
        } else {
            b = mid;
        }
    }
    return a;
}

/// True when module `m`'s recorded references name a declaration of module `dm` with a node in
/// [lo, hi] (a binary search over the sorted record; false for an unrecorded module).
pub(package) const fn refers(p: &loader::Package, m: usize, dm: u32, lo: u32, hi: u32) bool {
    if m >= p.def_refs.len() {
        return false;
    }
    let v = p.def_refs.at(m);
    let a = ref_lower_bound(v, dm as u64 << 32 | lo as u64);
    return a < v.len() && v.at(a).key <= (dm as u64 << 32 | hi as u64);
}

// The owners (item declaration nodes, or REF_MODULE_WIDE) of module `m`'s recorded references
// to declarations of module `dm` with nodes in [lo, hi], appended to `out`.
fn ref_owners(p: &loader::Package, m: usize, dm: u32, lo: u32, hi: u32, out: &mut Vector<u32>) {
    if m >= p.def_refs.len() {
        return;
    }
    let v = p.def_refs.at(m);
    let top = dm as u64 << 32 | hi as u64;
    let mut a = ref_lower_bound(v, dm as u64 << 32 | lo as u64);
    while a < v.len() && v.at(a).key <= top {
        out.push(v.at(a).owner);
        a += 1;
    }
}

// The items of module `i` an edit of [ws, we] (bytes of its current source) touched, as
// `by_node` positions: each item owns the bytes from the end of the item before it in source
// order (attributes and comments precede a declaration) to its own end, an extend the bytes
// before its first member and after its last, the last item the tail of the source. True when
// the edit touched an extend's own bytes (its target, interface, generics or braces): the
// conformance it declares reaches modules that never name it.
fn touched_items(p: &loader::Package, i: usize, ws: u32, we: u32, out: &mut Vector<u32>) bool {
    let a = &p.modules[i].ast;
    let i0 = p.idx().mod_items[i] as usize;
    let i1 = p.idx().mod_items[i + 1] as usize;
    // Items by source start; a member follows its extend's start.
    let mut order = Vector::<u64>::new();
    for k in i0..i1 {
        let it = p.idx().items.at(p.sched.by_node[k] as usize);
        order.push(a.at_const(it.node).span.start as u64 << 32 | (k - i0) as u64);
    }
    order.sort();
    let mut header = false;
    let mut prev_end: u32 = 0;
    let mut open_ext: u32 = SLOT_NONE; // the extend whose members are being walked
    let mut open_end: u32 = 0;
    for q in 0..order.len() {
        let k = (order[q] & 0xFFFFFFFFu64) as u32 + i0 as u32;
        let it = p.idx().items.at(p.sched.by_node[k as usize] as usize);
        let sp = a.at_const(it.node).span;
        if open_ext != SLOT_NONE && it.owner == loader::ITEM_NONE {
            // Past the last member: the extend's closing bytes.
            if ws <= open_end && we >= prev_end {
                header = true;
                out.push(open_ext);
            }
            prev_end = open_end;
            open_ext = SLOT_NONE;
        }
        let last = q + 1 == order.len();
        let mut end = sp.end;
        if it.kind == loader::ItemKind::IK_EXTEND as u8 {
            // The header runs to the first member's start.
            let mut first: u32 = sp.end;
            for j in i0..i1 {
                let mem = p.idx().items.at(j);
                if mem.owner == p.sched.by_node[k as usize] {
                    let ms = a.at_const(mem.node).span.start;
                    if ms < first {
                        first = ms;
                    }
                }
            }
            if first < sp.end {
                open_ext = k;
                open_end = sp.end;
                end = first;
            }
        }
        let ext_end = if last && open_ext == SLOT_NONE {
            0xFFFFFFFFu32;
        } else {
            end;
        };
        if ws <= ext_end && we >= prev_end {
            out.push(k);
            if it.kind == loader::ItemKind::IK_EXTEND as u8 {
                header = true;
            }
        }
        if end > prev_end {
            prev_end = end;
        }
    }
    if open_ext != SLOT_NONE && we >= prev_end {
        header = true;
        out.push(open_ext);
    }
    return header;
}

const ST_NONE: u8 = 0;
const ST_BODY: u8 = 1; // the item's body meaning may have changed; its signature stands
const ST_FULL: u8 = 2; // its declaration changed: everything that names it is stale

// True when the item at position `k` of module `m` is a function or method that is not
// `const fn`: only its body reads it, so a change of its body alone reaches no caller, and
// only a signature or a compile-time evaluation reads anything else.
const fn plain_fn(p: &loader::Package, m: usize, k: u32) bool {
    let it = p.idx().items.at(p.sched.by_node[k as usize] as usize);
    if it.kind != loader::ItemKind::IK_FUNCTION as u8 && it.kind != loader::ItemKind::IK_METHOD as u8 {
        return false;
    }
    let nd = p.modules[m].ast.at_const(it.node);
    return nd.kind == NodeKind::NODE_FUNCTION && !p.modules[m].ast.ext(it.node).function.is_const();
}

// Item-level invalidation over the recorded references. The items an edit touched start
// `ST_FULL` (`seeds`), a plain function whose body alone the edit changed `ST_BODY` (`bseeds`).
// A full item reaches every item naming it: a plain function naming it from its
// body becomes `ST_BODY` (its calls mean something else now, its signature stands); anything
// else (a signature or type spelling it, a constant, a `const fn`, an enum, an interface, a
// struct) becomes full. A body-state item reaches only the readers of its body: the
// compile-time evaluators (a constant, a `const fn`) and the items naming it outside a
// releasable body (a generic or `const fn` body), which become full or body in turn; a plain
// function calling it stands. Every module holding a reached item is marked in `aff`. A
// state only rises, so the walk is bounded by twice the item count.
fn propagate_touched(
    p: &loader::Package,
    seeds: &Vector<Vector<u32>>,
    bseeds: &Vector<Vector<u32>>,
    aff: &mut Vector<bool>,
) {
    let n = p.modules.len();
    let mut state = Vector::<u8>::new();
    state.resize_default(p.idx().items.len());
    // Per module: (lo, hi, state) triples not yet propagated.
    let mut pend = Vector::<Vector<u32>>::new();
    let mut queued = Vector::<bool>::new();
    queued.resize_default(n);
    let mut work = Vector::<usize>::new();
    for m in 0..n {
        pend.push(Vector::<u32>::new());
        for q in 0..seeds.at(m).len() {
            let k = seeds.at(m)[q];
            if state[k as usize] != ST_FULL {
                state.set(k as usize, ST_FULL);
                push_slot_range(p, m, k, &mut pend[m]);
                pend[m].push(ST_FULL);
            }
        }
        for q in 0..bseeds.at(m).len() {
            let k = bseeds.at(m)[q];
            if state[k as usize] == ST_NONE {
                state.set(k as usize, ST_BODY);
                push_slot_range(p, m, k, &mut pend[m]);
                pend[m].push(ST_BODY);
            }
        }
        if pend[m].len() != 0 {
            aff.set(m, true);
            queued.set(m, true);
            work.push(m);
        }
    }
    let mut owners = Vector::<u32>::new();
    let mut steps: usize = 0;
    while work.len() != 0 {
        steps += 1;
        assert(steps <= 2 * p.idx().items.len() + n, "every module is queued once per state rise");
        let x = work.remove(work.len() - 1).unwrap();
        queued.set(x, false);
        let rg = replace(&mut pend[x], Vector::<u32>::new());
        for m in 0..n {
            if m >= p.def_refs.len() {
                continue;
            }
            let mut q: usize = 0;
            while q + 2 < rg.len() {
                let xs = rg[q + 2] as u8;
                owners.clear();
                ref_owners(p, m, x as u32, rg[q], rg[q + 1], &mut owners);
                q += 3;
                for o in 0..owners.len() {
                    let ow = owners[o];
                    let in_body = (ow & loader::REF_BODY_EDGE) != 0;
                    let node = ow & loader::REF_MODULE_WIDE; // the node bits
                    let mut k0 = p.idx().mod_items[m];
                    let mut k1 = p.idx().mod_items[m + 1];
                    if node != loader::REF_MODULE_WIDE {
                        k0 = slot_of(p, m, node);
                        k1 = k0 + 1;
                    }
                    for k in k0..k1 {
                        let plain = plain_fn(p, m, k);
                        let mut ns = ST_FULL;
                        if plain && in_body {
                            ns = if xs == ST_FULL {
                                ST_BODY;
                            } else {
                                ST_NONE;
                            };
                        } else if plain && xs != ST_FULL {
                            ns = ST_BODY;
                        }
                        if ns <= state[k as usize] {
                            continue;
                        }
                        state.set(k as usize, ns);
                        push_slot_range(p, m, k, &mut pend[m]);
                        pend[m].push(ns);
                    }
                }
            }
            if pend[m].len() != 0 {
                aff.set(m, true);
                if !queued[m] {
                    queued.set(m, true);
                    work.push(m);
                }
            }
        }
    }
}

// The overlay slot of every module's file (-1 = none). Docs are few, so the per-(module, doc) file
// identity compare stays cheap; the C strings are built once per round.
fn overlay_slots(p: &loader::Package, ov_files: &Vector<str>) Vector<i64> {
    let mut fcs = Vector::<String>::new();
    fcs.reserve(ov_files.len());
    for k in 0..ov_files.len() {
        fcs.push(String::from_str(ov_files[k]));
    }
    let mut out = Vector::<i64>::new();
    out.reserve(p.modules.len());
    for i in 0..p.modules.len() {
        let mut slot: i64 = -1;
        let mf = p.modules.at(i).file.as_str();
        for k in 0..fcs.len() {
            if dutil::same_file(fcs[k].as_str(), mf) {
                slot = k as i64;
                break;
            }
        }
        out.push(slot);
    }
    return out;
}

// A fresh, platform-filtered parse of module `i`'s analyzed source: the module arena its last
// analysis started from (the analysis appends desugars to it).
fn pristine_parse(p: &mut loader::Package, i: usize, target: i32) Ast {
    let file = p.modules[i].file.clone();
    let mut src = p.modules[i].source.clone();
    let mut lx = lex::Lexer::new(&mut src, file.as_str());
    lx.scan_tokens();
    assert(!lx.has_errors(), "an analyzed module lexes again");
    let mut ps = par::Parser::new(lx.take_tokens(), src.as_str(), file.as_str());
    ps.build_ast();
    assert(!ps.has_errors(), "an analyzed module parses again");
    let mut na = ps.take_ast();
    na.module = i as ModuleId;
    let own = replace(&mut p.modules[i].ast, na);
    p.platform_filter_module(i, target);
    return replace(&mut p.modules[i].ast, own);
}

// The one plain function whose body block strictly encloses the byte window [ws, we) of the OLD
// source, or NODE_NONE: an edit there changes what only that body means. Excluded (return
// NODE_NONE): `const fn` (bodies are cross-module semantics through CTFE) and interface default
// methods (bodies re-check per foreign conformer).
fn body_candidate(a: &Ast, ws: u32, we: u32) NodeId {
    let items = a.at_const(a.root).as_data.program.items;
    for i in 0..items.len {
        let it = unsafe a.list(items)[i as usize];
        let n = a.at_const(it);
        if n.kind == NodeKind::NODE_INTERFACE {
            let sp = n.span;
            if sp.start <= ws && we <= sp.end {
                return NODE_NONE;
            }
        }
    }
    for id in 1..a.nodes.len() {
        let n = a.at_const(id as NodeId);
        if n.kind != NodeKind::NODE_FUNCTION {
            continue;
        }
        let fd = a.ext(id as NodeId).function;
        if fd.body == NODE_NONE || fd.is_const() {
            continue;
        }
        let bs = a.at_const(fd.body).span;
        if bs.start < ws && we < bs.end {
            return id as NodeId;
        }
    }
    return NODE_NONE;
}

/// Incrementally re-analyze `p` against the current overlays. False = outside the incremental domain
/// (import surface changed, a prelude module changed, a parse or resolve error appeared, the previous
/// state was broken): the caller MUST fall back to a full compile; the package may be part-updated.
/// True: `p` and `diags` (previous round's records in, merged records out) are current. The overlays
/// are borrowed views (index-aligned file paths and texts): a round copies no document text.
pub(package) fn recompile(
    p: &mut loader::Package,
    target: i32,
    root_file: str,
    lint_dir: str,
    ov_files: &Vector<str>,
    ov_texts: &Vector<str>,
    diags: &mut Vector<DiagRec>,
    st: &mut RecompileStats,
) bool {
    let t0 = dutil::ticks_ms();
    let n = p.modules.len();
    // A resolve-gated baseline (run_pipeline typechecks NOTHING while any module has a resolve
    // error) holds no semantic state to extend: an empty per-node type table on a parsed module
    // marks it. Hand such rounds to the full path.
    for i in 0..n {
        if p.modules[i].has_ast && p.modules[i].ast.nodes.len() > 1 && p.modules[i].ast.types.len() == 0 {
            return false;
        }
    }
    // The overlay slot per module, looked up once per round (a file identity compare per document).
    let ovk = overlay_slots(p, ov_files);
    // The result-attributability verdicts the last analyses recorded: the rebuilt item index
    // starts unrecorded, and a released module cannot scan its bodies again.
    let mut ra_keys = Vector::<u64>::new();
    let mut ra_vals = Vector::<i32>::new();
    save_ret_attr(p, &mut ra_keys, &mut ra_vals);
    // Documents opened since their module's bodies were released: the bodies come back (ids
    // stable, so importers keep their analyses) and the module re-analyzes.
    let mut opened = Vector::<usize>::new();
    for i in 0..n {
        if ovk[i] >= 0 && p.modules[i].has_ast && p.modules[i].ast.b.released {
            reparse_bodies(p, i);
            st.bodies_back += 1;
            opened.push(i);
        }
    }
    // 1) the changed set: modules whose overlay text differs from the analyzed source.
    let mut changed = Vector::<usize>::new();
    for i in 0..n {
        if ovk[i] >= 0 && ov_texts[ovk[i] as usize] != p.modules[i].source.as_str() {
            changed.push(i);
        }
    }
    if changed.len() == 0 && opened.len() == 0 {
        // No semantic work: the retained analysis and diagnostics stand.
        release_closed(p, &ovk);
        return true;
    }
    // Per changed module: the edit lay strictly inside one plain function's body and the reparse
    // kept the module-arena shape (`body_fn` names that function), or the reparse kept the shape
    // (`shaped`, with the edit window in the new source's bytes).
    let mut body_sliced = Vector::<bool>::new();
    let mut body_fn = Vector::<NodeId>::new();
    let mut shaped = Vector::<bool>::new();
    let mut win_s = Vector::<u32>::new();
    let mut win_e = Vector::<u32>::new();
    for _ in 0..changed.len() {
        body_sliced.push(false);
        body_fn.push(NODE_NONE);
        shaped.push(false);
        win_s.push(0);
        win_e.push(0);
    }
    // 2) Guards + reparse each changed module. The module always parses whole: its arenas are then
    // a fresh parse's, so the analysis that follows leaves the state a fresh analysis leaves. Fresh
    // ids: the import surface must be unchanged or the loader's closure caches (and every
    // importer's decl references) would be wrong, and an importer keeps its analysis only when the
    // module-arena shape is the one its references name (`same_shape` against a fresh parse of the
    // old source: the analysis appends desugars to the module arena).
    for c in 0..changed.len() {
        let i = changed[c];
        if p.modules[i].prelude || !p.modules[i].has_ast {
            // Prelude reaches everything implicitly; a broken prior state has no baseline.
            return false;
        }
        let k = ovk[i] as usize;
        let file = p.modules[i].file.clone();
        // The edit window: the bytes between the common prefix and suffix, in the old source.
        let mut ws: u32 = 0;
        let mut we: u32 = 0;
        let mut delta: i64 = 0;
        {
            let os = p.modules[i].source.as_str();
            let nv = ov_texts[k];
            let mut p0: usize = 0;
            let maxp = if os.len() < nv.len() {
                os.len();
            } else {
                nv.len();
            };
            while p0 < maxp && os[p0] == nv[p0] {
                p0 += 1;
            }
            let mut s0: usize = 0;
            while s0 < maxp - p0 && os[os.len() - 1 - s0] == nv[nv.len() - 1 - s0] {
                s0 += 1;
            }
            ws = p0 as u32;
            we = (os.len() - s0) as u32;
            delta = nv.len() as i64 - os.len() as i64;
        }
        let cand = body_candidate(&p.modules[i].ast, ws, we);
        let mut ns9 = String::from_str(ov_texts[k]);
        let mut lx9 = lex::Lexer::new(&mut ns9, file.as_str());
        lx9.scan_tokens();
        if lx9.has_errors() {
            return false;
        }
        let mut ps = par::Parser::new(lx9.take_tokens(), ns9.as_str(), file.as_str());
        ps.build_ast();
        if ps.has_errors() {
            return false;
        }
        let na = ps.take_ast();
        let mut osur = String::new();
        let mut nsur = String::new();
        import_surface(&p.modules[i].ast, p.modules[i].source.as_str(), &mut osur);
        import_surface(&na, ns9.as_str(), &mut nsur);
        if osur.as_str() != nsur.as_str() {
            return false;
        }
        let oldp = pristine_parse(p, i, target);
        let _ = replace(&mut p.modules[i].ast, na);
        p.modules[i].ast.module = i as ModuleId;
        p.modules[i].src_id = dutil::str_id(ns9.as_str());
        p.modules[i].mtime = 0;
        p.modules[i].source = ns9;
        p.platform_filter_module(i, target);
        if same_shape(&oldp, &p.modules[i].ast) {
            if cand != NODE_NONE {
                body_sliced.set(c, true);
                body_fn.set(c, cand);
                st.body_only += 1;
            } else {
                shaped.set(c, true);
                win_s.set(c, ws);
                win_e.set(c, (we as i64 + delta) as u32);
            }
        }
        st.reparsed += 1;
    }
    // 3) decl spans (and for full reparses, decl ids) changed: rebuild the package index and the
    // item index over it (the owner lookup the touched-item walk and the records read). The
    // import-closure caches survive: the guard above proved the edges identical.
    p.build_index();
    gitems::open(p);
    // A full reparse that changed the module-arena shape gave its declarations fresh ids: its old
    // verdicts name other declarations. Its analysis records them again.
    let mut fresh_ids = Vector::<bool>::new();
    fresh_ids.resize_default(n);
    for c in 0..changed.len() {
        if !body_sliced[c] && !shaped[c] {
            fresh_ids.set(changed[c], true);
        }
    }
    for k in 0..ra_keys.len() {
        let m = (ra_keys[k] >> 32) as usize;
        if !fresh_ids[m] {
            p.set_item_ret_attr(m as ModuleId, (ra_keys[k] & 0xFFFFFFFFu64) as NodeId, ra_vals[k] != 0);
        }
    }
    // 4) the affected closure: the changed modules, plus the modules that reach one through
    // imports and whose analysis it stales. A body-only edit leaves the module's interface (decl
    // ids, signatures, const bodies): only the compile-time readers of the body re-analyze
    // (`propagate_touched` from a body-state seed). A same-shape reparse keeps every id: the
    // items the edit touched invalidate the items that name them, transitively
    // (`propagate_touched`), and a reacher whose last analysis reported an error (an unresolved
    // name the edit may define) re-analyzes; an edit of an extend's own bytes, or a reparse with
    // fresh ids, stales every reacher.
    let mut erring = Vector::<bool>::new();
    erring.resize_default(n);
    for k in 0..diags.len() {
        let d = diags.at(k);
        if d.severity == 1 && d.module as usize < n {
            erring.set(d.module as usize, true);
        }
    }
    let mut aff = Vector::<bool>::new();
    for _ in 0..n {
        aff.push(false);
    }
    for k in 0..opened.len() {
        aff.set(opened[k], true);
    }
    let mut seeds = Vector::<Vector<u32>>::new();
    let mut bseeds = Vector::<Vector<u32>>::new();
    for _ in 0..n {
        seeds.push(Vector::<u32>::new());
        bseeds.push(Vector::<u32>::new());
    }
    let mut wide = Vector::<bool>::new(); // changed modules every reacher re-analyzes for
    for c in 0..changed.len() {
        aff.set(changed[c], true);
        let mut w = !body_sliced[c] && !shaped[c];
        if shaped[c] && touched_items(p, changed[c], win_s[c], win_e[c], &mut seeds[changed[c]]) {
            w = true;
        }
        if body_sliced[c] {
            // Only the function's body changed meaning: it reaches the compile-time readers of
            // that body alone.
            let k = slot_of(p, changed[c], body_fn[c]);
            if k != SLOT_NONE && slot_node(p, k) == body_fn[c] {
                bseeds[changed[c]].push(k);
            } else {
                w = true;
            }
        }
        wide.push(w);
    }
    let mut kept = Vector::<bool>::new();
    kept.resize_default(n);
    for m in 0..n {
        if aff[m] {
            continue;
        }
        let clo = unsafe &*p.module_closure(m as ModuleId);
        let mut hit = false;
        for j in 0..clo.len() {
            for c in 0..changed.len() {
                if clo[j] as usize != changed[c] || body_sliced[c] {
                    continue;
                }
                if wide[c] || erring[m] {
                    hit = true;
                } else {
                    kept.set(m, true);
                }
            }
        }
        if hit {
            aff.set(m, true);
        }
    }
    propagate_touched(p, &seeds, &bseeds, &mut aff);
    for m in 0..n {
        if kept[m] && !aff[m] {
            st.kept += 1;
        }
    }
    // 5) re-run the pipeline over the affected set only, mirroring run_pipeline's phase order. A
    // closed importer's released bodies come back for its re-analysis (and go again below).
    for m in 0..n {
        if aff[m] && p.modules[m].has_ast && p.modules[m].ast.b.released {
            reparse_bodies(p, m);
            st.bodies_back += 1;
        }
    }
    let mut nd = Vector::<DiagRec>::new();
    for i in 0..n {
        if !aff[i] {
            continue;
        }
        let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
        if !lsp_resolve_module(p, i, lw, &mut nd) {
            // A resolve failure invalidates this module's retained analyses and its importers';
            // rather than track that incrementally, hand the round to the full path.
            return false;
        }
        st.analyzed += 1;
    }
    // Every module outside the set keeps its analysis, so its items are Checked (the baseline
    // guard above proved every module typed); the passes reset the set's own.
    for m in 0..n {
        if !aff[m] {
            p.set_module_states(m, loader::IS_CHECKED);
        }
    }
    typecheck_set(p, &mut aff, true, true, root_file, lint_dir, &mut nd, st);
    if loader::poll_stop() {
        return false;
    }
    rescan_reach(p, &aff);
    // Every module the passes analyzed owes its borrow check again.
    while p.bc_pending.len() < n {
        p.bc_pending.push(false);
    }
    for m in 0..n {
        if aff[m] && p.modules[m].has_ast && lsp_lint_wanted(p, m, root_file, lint_dir) {
            p.bc_pending.set(m, true);
        }
    }
    // A body edit leaves every signature, but it can change a function's result attributability,
    // which the borrow check of each caller reads: a module that names such a function from
    // outside the affected set owes its borrow check too (its analysis stands).
    let mut rebc = Vector::<bool>::new();
    rebc.resize_default(n);
    for k in 0..ra_keys.len() {
        let x = (ra_keys[k] >> 32) as usize;
        let node = (ra_keys[k] & 0xFFFFFFFFu64) as NodeId;
        if fresh_ids[x] || p.item_ret_attr(x as ModuleId, node) == ra_vals[k] {
            continue;
        }
        for q in 0..n {
            if aff[q] || rebc[q] || !p.modules[q].has_ast || !lsp_lint_wanted(p, q, root_file, lint_dir) || !refers(
                p,
                q,
                x as u32,
                node,
                node,
            ) {
                continue;
            }
            if p.modules[q].ast.b.released {
                ensure_bodies(p, q);
                st.bodies_back += 1;
            }
            rebc.set(q, true);
            p.bc_pending.set(q, true);
        }
    }
    reach_settle(p, root_file, lint_dir, st);
    if loader::poll_stop() {
        return false;
    }
    // 6) merge: keep unaffected modules' records, replace the affected ones' (the set now holds
    // every module the passes analyzed).
    let affr = &aff;
    diags.retain(|d: &DiagRec| d.module as usize < n && !affr[d.module as usize]);
    for i in 0..n {
        if aff[i] {
            load_diags(p, i, diags);
        }
    }
    let rebr = &rebc;
    diags.retain(|d: &DiagRec| !rebr[d.module as usize] || d.phase != PH_BORROW);
    diags.reserve(nd.len());
    nd.reverse();
    loop {
        switch nd.pop() {
            Some(d) => {
                diags.push(d);
            },
            _ => {
                break;
            },
        };
    }
    lsp_unused_items(p, root_file, lint_dir, diags);
    release_closed(p, &ovk);
    stats_line(p, "round", t0, st);
    return true;
}

// The shared codegen-free pipeline over a loaded package: harvest parse failures, platform-filter,
// resolve + typecheck every module (lints gated per module), then the always-panics phase, the
// deferred constants and the unused-item lint, then release the bodies of every module without an
// editor buffer that owes no borrow check.
fn run_pipeline(p: &mut loader::Package, target: i32, root_file: str, lint_dir: str, diags: &mut Vector<DiagRec>) RecompileStats {
    let mut st = RecompileStats {};
    for i in 0..p.modules.len() {
        if !p.modules[i].has_ast {
            harvest_parse_errors(p, i, diags);
        }
        load_diags(p, i, diags);
    }
    p.platform_filter(target);
    let n = p.modules.len();
    let mut res_ok = Vector::<bool>::new();
    let mut all_ok = true;
    for i in 0..n {
        if loader::poll_stop() {
            return st;
        }
        let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
        let ok = lsp_resolve_module(p, i, lw, diags);
        res_ok.push(ok);
        all_ok = ok && all_ok;
    }
    // The readiness states and the (module, node) lookup only: the server has no consumer of the
    // dependency ranges, so it does not pay for their scan.
    gitems::open(p);
    // Per-module gate, not one package-wide Boolean: module `i` typechecks when its own import
    // closure resolved cleanly, so one broken file does not suppress every other file's semantic
    // diagnostics. The cross-module always-panics phase still needs the whole package typed.
    let mut set = Vector::<bool>::new();
    set.resize_default(n);
    for i in 0..n {
        let mut gate = res_ok[i];
        if gate && !all_ok {
            let clo = unsafe &*p.module_closure(i as ModuleId);
            for j in 0..clo.len() {
                if !res_ok[clo[j] as usize] {
                    gate = false;
                }
            }
        }
        set.set(i, gate);
        if !gate && p.modules[i].has_ast {
            record_refs(p, i);
        }
    }
    typecheck_set(p, &mut set, all_ok, true, root_file, lint_dir, diags, &mut st);
    if loader::poll_stop() {
        return st;
    }
    rescan_reach(p, &set);
    // Every analyzed module whose diagnostics this root reports owes its borrow check, and the
    // recursion check reports the modules whose diagnostics this root reports.
    p.bc_pending = Vector::<bool>::new();
    p.bc_pending.resize_default(n);
    p.recur.reported = Vector::<bool>::with_capacity(n);
    p.recur.mods = Vector::<recur::Sums>::with_capacity(n);
    for i in 0..n {
        let wanted = p.modules[i].has_ast && lsp_lint_wanted(p, i, root_file, lint_dir);
        if set[i] && wanted {
            p.bc_pending.set(i, true);
        }
        p.recur.reported.push(wanted);
        p.recur.mods.push(recur::Sums::new());
    }
    reach_settle(p, root_file, lint_dir, &mut st);
    if loader::poll_stop() {
        return st;
    }
    lsp_unused_items(p, root_file, lint_dir, diags);
    // The views end before the release claims the package: a vector of borrows counts as used when
    // it is destroyed.
    let mut ovk = Vector::<i64>::new();
    {
        let mut views = Vector::<str>::new();
        for k in 0..p.overlay_files.len() {
            views.push(p.overlay_files[k].as_str());
        }
        ovk = overlay_slots(p, &views);
    }
    release_closed(p, &ovk);
    return st;
}

// Typecheck the members of `set` (each after the members of its import closure, so a fold finds
// its callee typed) and, when `panics` is set, run the always-panics phase and the deferred
// static_asserts and constants over them; the records go to `nd`. `lint` gates the lints alone:
// the feature errors and the always-panics check are errors and run without it. The constant
// engine refuses a body it cannot read and records the module
// (`Interp.body_missing`): a released module is parsed back and held, and the next pass analyzes
// it with every member whose analysis met a refusal (their records replaced). A refusal of a
// member typed later in the same pass (an import cycle, a sibling checked later) stays a refusal,
// as in a batch build. Each extra pass parses at least one module back, so the passes are
// bounded by the module count; `set` grows by the modules parsed back.
fn typecheck_set(
    p: &mut loader::Package,
    set: &mut Vector<bool>,
    panics: bool,
    lint: bool,
    root_file: str,
    lint_dir: str,
    nd: &mut Vector<DiagRec>,
    st: &mut RecompileStats,
) {
    let n = p.modules.len();
    let pkg = p as *mut loader::Package;
    let mut order = dep_order(p, set);
    // The declaration spans the item-edge record reads; no pass adds or moves an item.
    let sps = gitems::spans_all(p);
    let lint_prelude = unused_prelude(p, root_file, lint_dir);
    for pass in 0..n + 1 {
        // Fresh readiness for the pass: the engine interprets a member's bodies only once this
        // pass has checked them (a parsed-back arena has no types before that).
        for k in 0..order.len() {
            p.reset_module_states(order[k]);
        }
        let mut cirv = lsp_engine(p);
        p.cir = &mut cirv;
        let mut again = Vector::<bool>::new();
        again.resize_default(n);
        // A module with a type error skips the always-panics phase, as the driver's build does: a
        // constant trap the checker reported would be reported again at its statement.
        let mut tc_bad = Vector::<bool>::new();
        tc_bad.resize_default(n);
        for k in 0..order.len() {
            if loader::poll_stop() {
                // An API request stopped the analysis: the package is dropped.
                p.cir = null;
                return;
            }
            let i = order[k];
            let lw = lint && lsp_lint_wanted(p, i, root_file, lint_dir);
            if pass != 0 {
                // The member runs again: its records are replaced whole, so resolve runs too.
                drop_records(nd, i);
                if !lsp_resolve_module(p, i, lw, nd) {
                    continue;
                }
            }
            let miss0 = cirv.body_miss_n;
            tc_bad.set(i, !lsp_typecheck_module(p, i, lw, nd));
            record_refs(p, i);
            if !p.modules[i].prelude || lint_prelude {
                record_item_edges(p, i, &sps);
            }
            if cirv.body_miss_n != miss0 {
                again.set(i, true);
            }
        }
        // Driver-parity: the uses of functions that need CPU features, decided once every module is
        // typed, and (a lint) the `unsafe` only such a use needed.
        for k in 0..order.len() {
            if loader::poll_stop() {
                p.cir = null;
                return;
            }
            let i = order[k];
            if !tc_bad[i] && lsp_lint_wanted(p, i, root_file, lint_dir) {
                let mut errs = diag::Errors::new();
                emit::feature_errors(p, i, &mut errs);
                if lint {
                    emit::feature_lints(p, i, &mut errs);
                }
                if errs.errors.len() != 0 || errs.warns.len() != 0 {
                    errs.finalize(p.modules[i].source.as_str(), p.modules[i].file.as_str());
                    drain_errors(&errs, i as u32, PH_ANALYSIS, nd);
                }
            }
        }
        if panics {
            // Driver-parity post-typecheck phase: the always-panics check (an error) interprets
            // cross-module `const fn` bodies, so it only runs once every module is typed.
            cirv.all_typed = true;
            for k in 0..order.len() {
                if loader::poll_stop() {
                    p.cir = null;
                    return;
                }
                let i = order[k];
                if !tc_bad[i] && lsp_lint_wanted(p, i, root_file, lint_dir) {
                    let miss0 = cirv.body_miss_n;
                    let mut errs = diag::Errors::new();
                    emit::check_always_panics_module(p, i, &mut errs);
                    if errs.errors.len() != 0 {
                        errs.finalize(p.modules[i].source.as_str(), p.modules[i].file.as_str());
                        drain_errors(&errs, i as u32, PH_ANALYSIS, nd);
                    }
                    if cirv.body_miss_n != miss0 {
                        again.set(i, true);
                    }
                }
            }
            // The static_asserts and constants the members deferred (undecidable in module
            // order) evaluate now that every module is typed. A refusal reruns every module
            // that deferred one: the flush does not say whose evaluation met it.
            let mut deferred = Vector::<bool>::new();
            deferred.resize_default(n);
            for k in 0..cirv.pending.len() {
                deferred.set(cirv.pending_module(k) as usize, true);
            }
            for k in 0..cirv.pending_consts.len() {
                deferred.set((cirv.pending_consts[k] >> 32) as usize, true);
            }
            let miss0 = cirv.body_miss_n;
            let mut fx = FlushCtx { p: pkg, nd: nd };
            let fxp = ((&mut fx) as *mut FlushCtx) as *mut void;
            cirv.flush_asserts(lsp_flush_assert, fxp);
            cirv.flush_consts(lsp_flush_const, fxp);
            if cirv.body_miss_n != miss0 {
                for m in 0..n {
                    if deferred[m] {
                        again.set(m, true);
                    }
                }
            }
        }
        p.cir = null;
        let mut back = false;
        for m in 0..cirv.body_missing.len() {
            if cirv.body_missing[m] && p.modules[m].has_ast && p.modules[m].ast.b.released {
                reparse_bodies(p, m);
                hold_bodies(p, m);
                st.bodies_back += 1;
                set.set(m, true);
                again.set(m, true);
                back = true;
            }
        }
        if !back {
            return;
        }
        st.passes += 1;
        order = dep_order(p, &again);
    }
}

// Drop module `i`'s records from `nd`: a module analyzed again replaces them whole.
fn drop_records(nd: &mut Vector<DiagRec>, i: usize) {
    nd.retain(|d: &DiagRec| d.module as usize != i);
}

// Drop module `i`'s records of pass `phase`; true when there was one.
fn drop_phase(nd: &mut Vector<DiagRec>, i: usize, phase: u8) bool {
    let before = nd.len();
    nd.retain(|d: &DiagRec| d.module as usize != i || d.phase != phase);
    return nd.len() != before;
}

// The engine's flush callbacks (`Interp::flush_asserts`, `flush_consts`) record the driver's
// messages (`emit::flush_assert_text`, `flush_const_text`) at the failing node.
struct FlushCtx {
    pub(package) p: *const loader::Package,
    pub(package) nd: *mut Vector<DiagRec>,
}

fn lsp_flush_assert(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) {
    flush_rec(ctx, dc::STATIC_ASSERTION_FAILED, m, cond, emit::flush_assert_text(msg));
}

fn lsp_flush_const(ctx: *mut void, m: ModuleId, decl: NodeId, msg: *const char) {
    flush_rec(ctx, dc::CONST_EVAL_FAILED, m, decl, emit::flush_const_text(msg));
}

fn flush_rec(ctx: *mut void, code: u16, m: ModuleId, id: NodeId, msg: String) {
    let fx = unsafe &*(ctx as *const FlushCtx);
    let mm = unsafe &(*fx.p).modules[m as usize];
    let mut errs = diag::Errors::new();
    errs.emit_span(code, mm.ast.at_const(id).span, msg);
    errs.finalize(mm.source.as_str(), mm.file.as_str());
    drain_errors(&errs, m, PH_ANALYSIS, unsafe &mut *fx.nd);
}

// The members of `set` as the driver's typecheck orders them: the prelude modules first (`tc_order`:
// every other module reads the prelude as typed), each after the members of its import closure (a
// cycle keeps index order), and the modules without items last (the driver checks their top-level
// nodes once every item is typed; no module reads them).
fn dep_order(p: &mut loader::Package, set: &Vector<bool>) Vector<usize> {
    let n = p.modules.len();
    let mut seen = Vector::<bool>::new();
    seen.resize_default(n);
    let mut out = Vector::<usize>::new();
    for pass in 0..2 {
        for i in 0..n {
            if set[i] && !seen[i] && p.modules[i].prelude == (pass == 0) && has_items(p, i) {
                dep_visit(p, set, &mut seen, &mut out, i);
            }
        }
    }
    for i in 0..n {
        if set[i] && !seen[i] {
            out.push(i);
        }
    }
    return out;
}

const fn has_items(p: &loader::Package, i: usize) bool {
    return p.idx().mod_items[i] != p.idx().mod_items[i + 1];
}

fn dep_visit(p: &mut loader::Package, set: &Vector<bool>, seen: &mut Vector<bool>, out: &mut Vector<usize>, i: usize) {
    seen.set(i, true);
    // The closure list is re-read per step: building another module's closure may move it.
    for j in 0..p.modules.len() {
        let clo = unsafe &*p.module_closure(i as ModuleId);
        if j >= clo.len() {
            break;
        }
        let c = clo[j] as usize;
        if set[c] && !seen[c] && has_items(p, c) {
            dep_visit(p, set, seen, out, c);
        }
    }
    out.push(i);
}

// Parse module `i`'s source again and take that parse's body arena. The parser is a function of
// the source alone, so the arena is byte-identical to the one the release freed: every body id,
// every fn node's body field and every parse-time side table entry (attributes, lifetimes) is
// valid again, and the early prune rewrites the body sites as it did before. The arena's per-node
// analysis tables are empty until the module resolves and typechecks again.
fn reparse_bodies(p: &mut loader::Package, i: usize) {
    let file = p.modules[i].file.clone();
    let mut lx = lex::Lexer::new(&mut p.modules[i].source, file.as_str());
    lx.scan_tokens();
    assert(!lx.has_errors(), "a parsed module lexes again");
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, p.modules[i].source.as_str(), file.as_str());
    ps.build_ast();
    assert(!ps.has_errors(), "a parsed module parses again");
    let mut na = ps.take_ast();
    let _ = replace(&mut p.modules[i].ast.b, replace(&mut na.b, BodyArena::new()));
    p.prune_build_sites(i);
}

// Keep module `m`'s bodies live across rounds: the engine demanded them once.
fn hold_bodies(p: &mut loader::Package, m: usize) {
    while p.body_hold.len() <= m {
        p.body_hold.push(false);
    }
    p.body_hold.set(m, true);
}

// Free the body syntax of every module without an editor buffer (`ovk[i] < 0`) that the engine
// has not demanded (`Package.body_hold`) and that owes no borrow check (`Package.bc_pending`):
// the positional features read only open documents' bodies, and the cross-file features parse a
// closed module's back on demand (`ensure_bodies`).
fn release_closed(p: &mut loader::Package, ovk: &Vector<i64>) {
    for i in 0..p.modules.len() {
        let held = kept(p, i) || i < p.bc_pending.len() && p.bc_pending[i];
        if ovk[i] < 0 && p.modules[i].has_ast && !p.modules[i].ast.b.released && !held {
            p.modules[i].ast.release_bodies();
        }
    }
}

// Whether module `m` keeps its body syntax between rounds without a document: the constant engine demanded
// one of its bodies (`Package.body_hold`), or the package keeps every module's outside std and `ffi/`
// (`Package.keep_bodies`).
fn kept(p: &loader::Package, m: usize) bool {
    return m < p.body_hold.len() && p.body_hold[m] || p.keep_bodies && p.modules[m].pkg != loader::PKG_STD && p.modules[m].pkg != loader::PKG_FFI;
}

/// Parse back the bodies a reference scan for `d` reads: the defining module's and every module whose
/// recorded references name `d` (`Package.def_refs`); the other modules' references, if any, sit in their
/// retained module arenas.
pub(package) fn hydrate_refs(p: &mut loader::Package, d: DefId) {
    ensure_bodies(p, d.module as usize);
    for m in 0..p.modules.len() {
        if m != d.module as usize && refers(p, m, d.module, d.node, d.node) {
            ensure_bodies(p, m);
        }
    }
}

/// Parse back and re-analyze module `i`'s released bodies for a feature that reads closed
/// documents' bodies (references, call hierarchy). The next analysis round releases them again.
pub(package) fn ensure_bodies(p: &mut loader::Package, i: usize) {
    if !p.modules[i].has_ast || !p.modules[i].ast.b.released {
        return;
    }
    reparse_bodies(p, i);
    // The records are discarded: the retained ones came from the same source and imports.
    let typed = p.modules[i].ast.types.len() != 0;
    let mut nd = Vector::<DiagRec>::new();
    let mut st = RecompileStats {};
    if lsp_resolve_module(p, i, false, &mut nd) && typed {
        let mut set = Vector::<bool>::new();
        set.resize_default(p.modules.len());
        set.set(i, true);
        typecheck_set(p, &mut set, false, false, "", "", &mut nd, &mut st);
    }
}

// The recorded result-attributability verdicts (`ItemSched.ret_attr`, 0 or 1) as
// (`module << 32 | node`, verdict) pairs.
fn save_ret_attr(p: &loader::Package, keys: &mut Vector<u64>, vals: &mut Vector<i32>) {
    if !p.sched.built {
        return;
    }
    for it in 0..p.idx().items.len() {
        let meta = p.idx().items.at(it);
        let v = p.item_ret_attr(meta.module, meta.node);
        if v == 0 || v == 1 {
            keys.push(meta.module as u64 << 32 | meta.node as u64);
            vals.push(v);
        }
    }
}

// The package-wide unused-item lint (`emit::lint_unused_items`) over the recorded item edges: its
// records (`PH_UNUSED`) are replaced every round, since an edit in one module can leave an item of
// another unused. As in the driver, a package with an analysis error gets no verdict: an
// unresolved reference would make its target look unused. The reported set is the root's
// (`lsp_lint_wanted`); a prelude module in it (an open std file, a workspace's own std) lints the
// way `super-c lint` lints std, through the batch mask.
fn lsp_unused_items(p: &mut loader::Package, root_file: str, lint_dir: str, diags: &mut Vector<DiagRec>) {
    diags.retain(|d: &DiagRec| d.phase != PH_UNUSED);
    let n = p.modules.len();
    for k in 0..diags.len() {
        if diags.at(k).severity == 1 && diags.at(k).phase == PH_ANALYSIS {
            return;
        }
    }
    let prelude = unused_prelude(p, root_file, lint_dir);
    for m in 0..n {
        if p.modules[m].has_ast && (!p.modules[m].prelude || prelude) && (p.modules[m].ast.types.len() == 0 || m >= p.item_edges.len()) {
            return;
        }
    }
    build_final_edges(p);
    let mut wanted = Vector::<bool>::with_capacity(n);
    for m in 0..n {
        wanted.push(lsp_lint_wanted(p, m, root_file, lint_dir));
    }
    let mut sink = Vector::<diag::Errors>::with_capacity(n);
    for _ in 0..n {
        sink.push(diag::Errors::new());
    }
    let sp = (&mut sink) as *mut Vector<diag::Errors>;
    if p.lint_set.len() != 0 || !prelude {
        emit::lint_unused_items(p, -1, sp);
    } else {
        let own = replace(&mut p.lint_set, wanted);
        emit::lint_unused_items(p, -1, sp);
        p.lint_set = own;
    }
    for m in 0..n {
        if sink[m].has_warnings() {
            sink.index_mut(m).finalize(p.modules[m].source.as_str(), p.modules[m].file.as_str());
            drain_errors(sink.at(m), m as u32, PH_UNUSED, diags);
        }
    }
}

// True when the root's unused-item lint reports a prelude module (an open std file, a workspace's
// own std): the prelude modules then take part in its reachability graph, and their item edges
// are recorded too.
fn unused_prelude(p: &mut loader::Package, root_file: str, lint_dir: str) bool {
    for m in 0..p.modules.len() {
        if p.modules[m].prelude && lsp_lint_wanted(p, m, root_file, lint_dir) {
            return true;
        }
    }
    return false;
}

// The item index's post-typecheck edges (`gitems::build_final`) from every module's recorded
// item edges, mapped onto the current item ids.
fn build_final_edges(p: &mut loader::Package) {
    let mut ev = Vector::<u64>::new();
    for m in 0..p.modules.len().min(p.item_edges.len()) {
        let es = p.item_edges.at(m);
        for k in 0..es.len() {
            let e = es.at(k);
            let o = p.item_of(m as ModuleId, e.owner);
            let t = p.item_of((e.key >> 32) as ModuleId, (e.key & 0xFFFFFFFFu64) as NodeId);
            assert(o != loader::ITEM_NONE && t != loader::ITEM_NONE, "a recorded item edge names two items");
            ev.push(o as u64 << 32 | t as u64);
        }
    }
    gitems::build_final(p, &ev);
}

/// Lower function `d` (a function or a method) as its module's borrow check does: lowered, borrow-checked and
/// drop-elaborated, into `out`, with the move marks the check reads (`CoreBody.user_moves`); the check's
/// diagnostics are dropped. False when it does not lower: no body, or a module whose analysis left no types.
pub(package) fn lower_item(p: &mut loader::Package, d: DefId, out: &mut core::CoreBody) bool {
    let m = d.module as usize;
    if m >= p.modules.len() || !p.modules[m].has_ast || p.modules[m].ast.types.len() == 0 {
        return false;
    }
    ensure_bodies(p, m);
    let pkg = p as *mut loader::Package;
    let mut ow = bfx::Owner::new(pkg);
    let mut ctx = bfi::BorrowCtx::new();
    reach_for(p, m);
    let mut cirv = lsp_engine(p);
    cirv.all_typed = true;
    p.cir = &mut cirv;
    {
        let mm = &mut p.modules[m];
        let src = mm.source.as_str().ptr() as *const char;
        let len = mm.source.len();
        let mut t = tc::TypeChecker::new(&mut mm.ast, unsafe str::from_raw(src as *const u8, len), pkg);
        let mut bodies = Vector::<irl::Lowerer>::new();
        t.bc_item(d.node, &mut ow, &mut ctx, &mut bodies);
    }
    p.cir = null;
    reach_off(p);
    // The check recycles its spent lowerings whole: the function's is among them.
    for i in 0..ctx.lower_pool.len() {
        let b = &ctx.lower_pool[i].body;
        if b.owner.module == d.module && b.owner.node == d.node {
            *out = replace(&mut ctx.lower_pool.index_mut(i).body, core::CoreBody::new(d, d.module));
            return true;
        }
    }
    return false;
}

/// The outcome of one borrow round (`borrowck_pending`).
pub(package) struct BcRound {
    pub(package) canceled: bool, // `stop` ended the round; the checks it did not finish stay owed
    pub(package) changed: bool, // some module's borrow records changed
    pub(package) checked: bool, // some module's check finished
}

// True when module `m` can be borrow checked: it and every module of its import closure are typed
// and reported no analysis error (`err`), as the driver borrow checks only a package that typed.
fn bc_ready(p: &mut loader::Package, m: usize, err: &Vector<bool>) bool {
    if err[m] {
        return false;
    }
    let clo = unsafe &*p.module_closure(m as ModuleId);
    for j in 0..clo.len() {
        let c = clo[j] as usize;
        if err[c] || p.modules[c].has_ast && p.modules[c].ast.types.len() == 0 {
            return false;
        }
    }
    return true;
}

// The borrow check of module `m`, item by item, with its body syntax kept. `stop(sctx, false)` is
// polled before each item: None when it asked to stop (the partial records are dropped).
fn bc_module(
    p: &mut loader::Package,
    m: usize,
    ow: &mut bfx::Owner,
    ctx: &mut bfi::BorrowCtx,
    stop: fn(*mut void, bool) bool,
    sctx: *mut void,
) Option<diag::Errors> {
    let pkg = p as *mut loader::Package;
    let mut items = Vector::<NodeId>::new();
    {
        let a = &p.modules[m].ast;
        let pl = a.at_const(a.root).as_data.program.items;
        for i in 0..pl.len {
            items.push(unsafe a.list(pl)[i as usize]);
        }
    }
    let mm = &mut p.modules[m];
    let src = mm.source.as_str().ptr() as *const char;
    let len = mm.source.len();
    let file = mm.file.clone();
    let mut t = tc::TypeChecker::new(&mut mm.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    let mut bodies = Vector::<irl::Lowerer>::new();
    for k in 0..items.len() {
        if stop(sctx, false) {
            return Option::<diag::Errors>::None;
        }
        t.bc_item(items[k], ow, ctx, &mut bodies);
    }
    t.errors.finalize(unsafe str::from_raw(src as *const u8, len), file.as_str());
    return Option::<diag::Errors>::Some(replace(&mut t.errors, diag::Errors::new()));
}

// Parse back and analyze again every released module the engine refused a body of; true when one
// came back (it stays held, as a demand during the analysis holds it).
fn parse_back_demanded(p: &mut loader::Package, cirv: &iri::Interp) bool {
    let mut back = false;
    for m in 0..cirv.body_missing.len() {
        if cirv.body_missing[m] && m < p.modules.len() && p.modules[m].has_ast && p.modules[m].ast.b.released {
            ensure_bodies(p, m);
            hold_bodies(p, m);
            back = true;
        }
    }
    return back;
}

/// Run the borrow checks the analyses owe (`Package.bc_pending`), in module order, keeping every
/// body syntax arena (the positional features read the open documents' bodies). A module whose
/// own analysis reported an error owes nothing until it is analyzed again; any other runs once its
/// import closure typed without an error (`bc_ready`) and waits until then; its records (`PH_BORROW`)
/// replace its previous ones in `diags`, its function summaries (`Package.recur`) replace its
/// previous ones, and a closed module (`ov_files` names the open documents) releases its bodies
/// after its check. A round that is not stopped ends with the recursion check (`recur_check`) when a
/// summary changed since it last ran. `stop(sctx, between)` ends the round when true, polled
/// with `between` false before every item (the module in progress keeps its pending mark and its
/// previous records) and with `between` true before every module after the round's first finished
/// check: a stop there waits for the module in progress, and every round that no item poll stops
/// finishes at least one check, so the owed checks end within their count of rounds. The
/// lowering adds no cancellation edges (`Package.cancel_state` stays uncomputed): such an edge
/// is an early return after a call, and the borrow check reports nothing on one; a module with a
/// `@tail_recurse` function is the exception (`reach_for`).
pub(package) fn borrowck_pending(
    p: &mut loader::Package,
    diags: &mut Vector<DiagRec>,
    ov_files: &Vector<str>,
    stop: fn(*mut void, bool) bool,
    sctx: *mut void,
) BcRound {
    let mut out = BcRound { canceled: false, changed: false, checked: false };
    let n = p.modules.len();
    let mut any = p.recur.stale;
    for m in 0..p.bc_pending.len().min(n) {
        any = any || p.bc_pending[m];
    }
    if !any {
        return out;
    }
    let err = analysis_errors(p, diags);
    let ovk = overlay_slots(p, ov_files);
    let pkg = p as *mut loader::Package;
    let mut ow = bfx::Owner::new(pkg);
    let mut ctx = bfi::BorrowCtx::new();
    // The summaries of the module in progress; the reported mask stays as it is during the round.
    let mut sz = recur::Summarizer::new(&p.recur.reported);
    ctx.recur = &mut sz;
    for m in 0..p.bc_pending.len().min(n) {
        if !p.bc_pending[m] {
            continue;
        }
        if out.checked && stop(sctx, true) {
            out.canceled = true;
            reach_off(p);
            return out;
        }
        if err[m] {
            // The module's own analysis failed: no borrow check is owed until it is analyzed
            // again, which owes a new one.
            let _ = drop_phase(diags, m, PH_BORROW);
            p.bc_pending.set(m, false);
            p.recur.mods.set(m, recur::Sums::new());
            p.recur.stale = true;
            if ovk[m] < 0 && !kept(p, m) && !p.modules[m].ast.b.released {
                p.modules[m].ast.release_bodies();
            }
            continue;
        }
        if !bc_ready(p, m, &err) {
            continue;
        }
        reach_for(p, m);
        // An engine demand for a released body parses it back and checks the module again; each
        // retry brings back at least one module.
        let mut res = Option::<diag::Errors>::None;
        for _ in 0..n + 1 {
            let mut cirv = lsp_engine(p);
            cirv.all_typed = true;
            p.cir = &mut cirv;
            let _ = sz.take();
            let r = bc_module(p, m, &mut ow, &mut ctx, stop, sctx);
            p.cir = null;
            if r.is_none() {
                out.canceled = true;
                reach_off(p);
                return out;
            }
            if !parse_back_demanded(p, &cirv) {
                res = r;
                break;
            }
        }
        assert(res.is_some(), "a borrow check ends once no released body is demanded");
        let errs = res.unwrap();
        let had = drop_phase(diags, m, PH_BORROW);
        out.changed = out.changed || had || errs.has_errors() || errs.has_warnings();
        drain_errors(&errs, m as u32, PH_BORROW, diags);
        p.bc_pending.set(m, false);
        p.recur.mods.set(m, sz.take());
        p.recur.stale = true;
        out.checked = true;
        if ovk[m] < 0 && !kept(p, m) && !p.modules[m].ast.b.released {
            p.modules[m].ast.release_bodies();
        }
    }
    reach_off(p);
    if p.recur.stale {
        out.changed = recur_check(p, diags) || out.changed;
    }
    return out;
}

// Does module `m` declare a `@tail_recurse` function while the coroutine runtime is loaded? Its borrow
// check lowers with the build's cancellation checks (`reach_for`): a check after a self call is one of
// its errors (`it can accept a task cancellation`), and no other record depends on the checks.
fn reach_reads(p: &loader::Package, m: usize) bool {
    let a = &p.modules.at(m).ast;
    for k in 0..a.attrs.len() {
        if a.attrs.at(k).kind == AttrKind::ATTR_TAIL_RECURSE as u8 {
            return p.find("std::parallel::runtime") >= 0;
        }
    }
    return false;
}

// Lower module `m` with the reachability the last solve left (`reach_settle`) when it reads it,
// else without.
fn reach_for(p: &mut loader::Package, m: usize) {
    if !reach_reads(p, m) {
        reach_off(p);
        return;
    }
    assert(!p.reach_stale, "every analysis round settles the reachability a borrow check reads");
    p.co_state = 1;
    p.cancel_state = 1;
}

// After an analysis round changed a reachability scan, while a module the root borrow checks reads
// the reachability (`reach_reads`): solve it over the retained scans, and when the answer changed
// (`tuc::reach_fold`) every such module owes its borrow check again, with its bodies live.
fn reach_settle(p: &mut loader::Package, root_file: str, lint_dir: str, st: &mut RecompileStats) {
    if !p.reach_stale {
        return;
    }
    let n = p.modules.len();
    let mut readers = Vector::<usize>::new();
    for m in 0..n {
        if p.modules[m].has_ast && reach_reads(p, m) && lsp_lint_wanted(p, m, root_file, lint_dir) {
            readers.push(m);
        }
    }
    if readers.len() == 0 {
        return; // solved once a reader appears: its own analysis marks the scans changed
    }
    let scans = replace(&mut p.reach_scans, Vector::<loader::ReachScan>::new());
    p.reach_solve(&scans);
    p.reach_scans = scans;
    p.reach_stale = false;
    let key = tuc::reach_fold(0, p);
    reach_off(p);
    if key == p.reach_key {
        return;
    }
    p.reach_key = key;
    while p.bc_pending.len() < n {
        p.bc_pending.push(false);
    }
    for i in 0..readers.len() {
        let m = readers[i];
        if p.bc_pending[m] {
            continue;
        }
        if p.modules[m].ast.b.released {
            ensure_bodies(p, m);
            st.bodies_back += 1;
        }
        p.bc_pending.set(m, true);
    }
}

// Lower without the reachability: no cancellation check, a preemption tick in every loop (an
// analysis outside the borrow round sees what the build's type check sees).
const fn reach_off(p: &mut loader::Package) {
    p.co_state = 0;
    p.cancel_state = 0;
}

// The reachability scans (`Package::co_scan`) of the modules `set` marks, analyzed now with their
// bodies live; every other module keeps its scan. A stopped API request leaves the scans incomplete.
fn rescan_reach(p: &mut loader::Package, set: &Vector<bool>) {
    let n = p.modules.len();
    while p.reach_scans.len() < n {
        p.reach_scans.push(loader::ReachScan::new());
    }
    let cx = p.reach_ctx();
    if !cx.rt {
        return;
    }
    for m in 0..n {
        if loader::poll_stop() {
            return;
        }
        if set[m] {
            let sc = p.co_scan(m, &cx);
            p.reach_scans.set(m, sc);
            p.reach_stale = true;
        }
    }
}

// The unbounded-recursion check (`ir::recursion`) over the summaries of every reported module that
// owes no borrow check (a module that owes one has a stale summary or none): its records
// (`PH_RECUR`) replace the previous ones. True when there were records before or after.
fn recur_check(p: &mut loader::Package, diags: &mut Vector<DiagRec>) bool {
    let n = p.modules.len();
    let mut on = Vector::<bool>::with_capacity(n);
    for m in 0..n {
        on.push(p.recur.reported[m] && !(m < p.bc_pending.len() && p.bc_pending[m]));
    }
    let reps = recur::check(p, &p.recur.mods, &on);
    p.recur.stale = false;
    let before = diags.len();
    diags.retain(|d: &DiagRec| d.phase != PH_RECUR);
    let had = diags.len() != before;
    for i in 0..reps.len() {
        drain_errors(&reps.at(i).errs, reps.at(i).module, PH_RECUR, diags);
    }
    return had || reps.len() != 0;
}

/// True when the borrow round has a runnable check left: a borrow check, or the recursion check.
pub(package) fn borrowck_runnable(p: &mut loader::Package, diags: &Vector<DiagRec>) bool {
    if p.recur.stale {
        return true;
    }
    let err = analysis_errors(p, diags);
    for m in 0..p.bc_pending.len().min(p.modules.len()) {
        if p.bc_pending[m] && (err[m] || bc_ready(p, m, &err)) {
            return true;
        }
    }
    return false;
}

// Per module: its analysis reported an error.
fn analysis_errors(p: &loader::Package, diags: &Vector<DiagRec>) Vector<bool> {
    let n = p.modules.len();
    let mut err = Vector::<bool>::new();
    err.resize_default(n);
    for k in 0..diags.len() {
        let d = diags.at(k);
        if d.severity == 1 && d.phase == PH_ANALYSIS && d.module as usize < n {
            err.set(d.module as usize, true);
        }
    }
    return err;
}

// The instruction set the driver builds for `target` without `--arch`: the system's usual one, else the
// host's.
const fn target_arch(target: i32) i32 {
    let d = tgt::os(target).isa_default;
    if d >= 0 {
        return d;
    }
    return unsafe shim::sc_host_arch();
}

// SC_LSP_STATS=1: one line per analysis round on stderr: the module counts by body ownership,
// the retained bytes, the round's time and its parse-back work.
fn stats_line(p: &loader::Package, what: str, t0: i64, st: &RecompileStats) {
    if stdlib::getenv("SC_LSP_STATS") == null {
        return;
    }
    let mut released: usize = 0;
    let mut held: usize = 0;
    for i in 0..p.modules.len() {
        if p.modules[i].has_ast && p.modules[i].ast.b.released {
            released += 1;
        }
        if i < p.body_hold.len() && p.body_hold[i] {
            held += 1;
        }
    }
    eprintln(
        "lsp {}: {} modules, {} released, {} held, {} KiB retained, {} ms, {} parsed back, {} extra passes",
        what,
        p.modules.len(),
        released,
        held,
        p.retained_bytes() / 1024,
        dutil::ticks_ms() - t0,
        st.bodies_back,
        st.passes,
    );
}
