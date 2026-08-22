// The LSP's codegen-free diagnostics pass: build the package (editor-buffer overlays applied), resolve
// and typecheck every module, and harvest every diagnostic as a (module, span, severity, message)
// record instead of printing it. Mirrors driver::emit's lint_package recipe exactly -- including its
// phase gate (no typechecking while any module has a resolve error), so the LSP shows the same error
// sets as the CLI.
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import ast::parser as par;
import lexer::lexer as lex;
import lexer::token as ltok;
import resolver::resolver as resolver;
import hir::lower as hirl;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import utils::errors as diag;
import driver::emit as emit;

/// One harvested diagnostic: the cross-pass record the server publishes and codeAction later reads
/// (the fix fields carry the machine-applicable quick fix, if any).
pub struct DiagRec {
    pub module: u32,
    pub start: u32, // byte span into the module's source
    pub len: u32,
    pub severity: u8, // LSP DiagnosticSeverity: 1 = error, 2 = warning
    pub msg: String,
    // machine-applicable fix: -1 = none, else a LintFix kind (0 delete [fix_start, fix_end),
    // 1 insert '_', 2 insert 'const ', 3 insert `fix_text`, 4 replace [fix_start, fix_end) with
    // `fix_text`) surfaced as an LSP quick fix
    pub fix_kind: i32,
    pub fix_start: u32,
    pub fix_end: u32,
    pub fix_text: String, // kind-3/4 payload (generated / replacement text); empty otherwise
}

extend DiagRec as Free {
    pub fn free(self: &mut Self) {
        self.msg.free();
        self.fix_text.free();
    }
}

// The editor-facing message for one structured record: the message's first line plus one "= note:"
// line per attached note (its first line, trailing whitespace trimmed -- notes carry fix hints worth
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

// Append every error/warning record in `e` as a DiagRec against module `m` (the records carry their
// spans and note chains directly; nothing is parsed back out of rendered text).
fn drain_errors(e: &diag::Errors, m: u32, diags: &mut Vector<DiagRec>) {
    for k in 0..e.errors.len() {
        let mut fk: i32 = -1;
        let mut fs: u32 = 0;
        let mut ftx = String::new();
        for j in 0..e.fixes.len() {
            let f = *e.fixes.at(j);
            if f.warn == (0x80000000 | k as u32) {
                fk = f.kind;
                fs = f.start;
                if f.text != 0xFFFFFFFF && f.text as usize < e.fix_texts.len() {
                    ftx = e.fix_texts.at(f.text as usize).clone();
                }
                break;
            }
        }
        let d = e.errors.at(k);
        diags.push(
            DiagRec {
                module: m,
                start: d.start,
                len: d.len,
                severity: 1,
                msg: rec_msg(e, d),
                fix_kind: fk,
                fix_start: fs,
                fix_end: 0,
                fix_text: ftx,
            },
        );
    }
    for k in 0..e.warns.len() {
        let mut fk: i32 = -1;
        let mut fs: u32 = 0;
        let mut fe: u32 = 0;
        let mut ftx = String::new();
        for j in 0..e.fixes.len() {
            let f = *e.fixes.at(j);
            if f.warn == k as u32 {
                fk = f.kind;
                fs = f.start;
                fe = f.end;
                if f.text != 0xFFFFFFFF && f.text as usize < e.fix_texts.len() {
                    ftx = e.fix_texts.at(f.text as usize).clone();
                }
                break; // one quick fix per warning
            }
        }
        let d = e.warns.at(k);
        diags.push(
            DiagRec {
                module: m,
                start: d.start,
                len: d.len,
                severity: 2,
                msg: rec_msg(e, d),
                fix_kind: fk,
                fix_start: fs,
                fix_end: fe,
                fix_text: ftx,
            },
        );
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
        drain_errors(&lx.errors, i as u32, diags);
        return;
    }
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, vsrc.as_str(), m.file.as_str());
    ps.build_ast();
    drain_errors(&ps.errors, i as u32, diags);
}

type CanonBuf = Array<char, 4096>;

fn canon_path(path: str) String {
    let mut pb = String::from_str(path);
    let mut rb = CanonBuf {};
    if unsafe shim::sc_realpath(pb.cstr(), &mut rb[0]) != null {
        return String::from_cstr(&rb[0]);
    }
    return pb;
}

// Lints run for non-prelude modules (like `super-c build`), for the package's root file when it IS a
// prelude module (the `super-c lint <std file>` recipe), and -- when `lint_dir` is non-empty (the
// manifest root's build passes the canonical workspace root) -- for every prelude module under that
// directory, so a repo carrying its own std/ lints it like `super-c lint std`. Gating on the root
// file rather than "any open doc" keeps each file's lint warnings owned by exactly one root.
fn lsp_lint_wanted(p: &mut loader::Package, i: usize, root_file: str, lint_dir: str) bool {
    // batch build: the mask names the member files; everything else (their closures, the prelude)
    // is someone else's to lint
    if p.lint_set.len() != 0 {
        return p.lint_set[i];
    }
    if !p.modules[i].prelude {
        return true;
    }
    let mut rf = String::from_str(root_file);
    if unsafe shim::sc_same_file(p.modules[i].file.cstr(), rf.cstr()) == 1 {
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
    let mut r = resolver::Resolver::new(unsafe &mut *aptr, str::from_raw(src as *const u8, len), pkg);
    r.lint = lint;
    r.resolve();
    let had = r.has_errors();
    drain_errors(&r.errors, i as u32, diags);
    hirl::lower_module(p, i);
    return !had;
}

// emit::typecheck_module with the diagnostics drained instead of logged.
fn lsp_typecheck_module(p: &mut loader::Package, i: usize, lint: bool, diags: &mut Vector<DiagRec>) bool {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.lint = lint;
    t.check();
    let had = t.has_errors();
    drain_errors(&t.errors, i as u32, diags);
    return !had;
}

/// Load + resolve + typecheck (NO codegen), harvesting all diagnostics into `diags`. Takes ownership of
/// the overlay vectors. The returned Package keeps every module's typed Ast -- the positional features
/// (hover/definition/references) query it until the next rebuild. Lint gating: see lsp_lint_wanted;
/// `lint_dir` is the canonical workspace root when this build is the manifest root's, else "".
pub fn compile(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: *const char,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    lint_dir: str,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    let mut p = loader::package_load_overlaid(
        root_file,
        root_dir,
        alt_dir,
        std_dir,
        false,
        unsafe shim::sc_host_platform(),
        ov_files,
        ov_texts,
    );
    run_pipeline(&mut p, target, root_file, lint_dir, diags);
    return p;
}

/// The LSP's workspace batch: like `super-c lint`'s one-package recipe -- the prelude loads first,
/// every listed file joins the shared closure once, and `lint_set` marks the members so lints (and
/// the always-panics pass) report exactly them. ONE resident package replaces the per-file sweep
/// packages, which is what held a full prelude + closure copy per workspace file.
pub fn compile_batch(
    files: &Vector<String>,
    root_dir: str,
    alt_dir: str,
    std_dir: *const char,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    let mut p = loader::package_load_prelude(
        root_dir,
        alt_dir,
        std_dir,
        unsafe shim::sc_host_platform(),
        ov_files,
        ov_texts,
    );
    let mut mids = Vector::<i32>::new();
    for k in 0..files.len() {
        let mut fc = String::from_str(files.at(k).as_str());
        let mut mid: i32 = -1;
        for m in 0..p.modules.len() {
            if p.modules[m].has_ast && unsafe shim::sc_same_file(fc.cstr(), p.modules[m].file.cstr()) == 1 {
                mid = m as i32;
                break;
            }
        }
        if mid < 0 {
            let mp = loader::batch_mod_path(files.at(k).as_str(), root_dir, alt_dir);
            mid = p.load_module(mp.as_str(), files.at(k).as_str(), false, unsafe shim::sc_host_platform());
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
    run_pipeline(&mut p, target, "", "", diags);
    return p;
}

// ---------------------------------------------------------------------------------------------------------
// Incremental re-analysis: the LSP's query layer. A previously compiled package is updated in place
// against the CURRENT overlays; only the edit's reach re-runs. Module granularity: a changed module
// re-parses (fresh node ids), so it AND every module whose import closure contains it re-resolve and
// re-typecheck; everything else keeps its analysis and diagnostics verbatim (per-module type pools
// reference other modules only by decl node id, so an analysis is stale exactly when a closure member
// reparsed). Body granularity: an edit strictly inside one plain fn body reparses just that body into
// the SAME arena (every old node id survives, importers stay valid), and only that module re-analyzes.
// Anything outside the incremental domain returns false and the caller falls back to a full compile.
// ---------------------------------------------------------------------------------------------------------

/// Outcome counters for one incremental round: the exit-gate observables (what re-ran and why).
pub struct RecompileStats {
    pub reparsed: u32, // changed modules (fully reparsed or body-spliced)
    pub analyzed: u32, // modules re-resolved + re-typechecked (the affected closure)
    pub body_only: u32, // changed modules that took the body-splice path (node ids stable)
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

// The overlay text for module `i`'s file, or None. Docs are few, so the per-module path compare
// (realpath-backed) stays cheap.
fn overlay_for(p: &loader::Package, i: usize, ov_files: &Vector<String>) Option<usize> {
    for k in 0..ov_files.len() {
        let mut fc = String::from_str(ov_files.at(k).as_str());
        let mut mf = String::from_str(p.modules.at(i).file.as_str());
        let same = unsafe shim::sc_same_file(fc.cstr(), mf.cstr()) == 1;
        if same {
            return Option::<usize>::Some(k);
        }
    }
    return Option::<usize>::None;
}

// Shift every source offset >= `from` by `delta` across the OLD prefix of the arena (the freshly
// appended splice nodes already carry new-source offsets) plus the old attr/meta span tables.
fn shift_spans(a: &mut Ast, old_nodes: usize, old_attrs: usize, old_metas: usize, from: u32, delta: i64) {
    for i in 0..old_nodes {
        let n = a.at(i as NodeId);
        if n.span.start >= from {
            n.span.start = (n.span.start as i64 + delta) as u32;
        }
        if n.span.end >= from {
            n.span.end = (n.span.end as i64 + delta) as u32;
        }
        // literal/name payload spans ride the same source: shift the union arms that carry one
        if n.kind == NodeKind::NODE_IDENTIFIER || n.kind == NodeKind::NODE_LIFETIME {
            if n.as_data.name.text.start >= from {
                n.as_data.name.text.start = (n.as_data.name.text.start as i64 + delta) as u32;
                n.as_data.name.text.end = (n.as_data.name.text.end as i64 + delta) as u32;
            }
        } else if n.kind == NodeKind::NODE_LITERAL {
            if n.as_data.literal.raw.start >= from {
                n.as_data.literal.raw.start = (n.as_data.literal.raw.start as i64 + delta) as u32;
                n.as_data.literal.raw.end = (n.as_data.literal.raw.end as i64 + delta) as u32;
            }
        } else if n.kind == NodeKind::NODE_WHILE {
            if n.as_data.while_stmt.label.start >= from {
                n.as_data.while_stmt.label.start = (n.as_data.while_stmt.label.start as i64 + delta) as u32;
                n.as_data.while_stmt.label.end = (n.as_data.while_stmt.label.end as i64 + delta) as u32;
            }
        } else if n.kind == NodeKind::NODE_FOR || n.kind == NodeKind::NODE_INLINE_FOR || n.kind == NodeKind::NODE_PARALLEL_FOR {
            if n.as_data.for_stmt.label.start >= from {
                n.as_data.for_stmt.label.start = (n.as_data.for_stmt.label.start as i64 + delta) as u32;
                n.as_data.for_stmt.label.end = (n.as_data.for_stmt.label.end as i64 + delta) as u32;
            }
        } else if n.kind == NodeKind::NODE_BREAK || n.kind == NodeKind::NODE_CONTINUE {
            if n.as_data.flow.label.start >= from {
                n.as_data.flow.label.start = (n.as_data.flow.label.start as i64 + delta) as u32;
                n.as_data.flow.label.end = (n.as_data.flow.label.end as i64 + delta) as u32;
            }
        }
    }
    for i in 0..old_attrs {
        let at = &mut a.attrs[i];
        if at.str_span.start >= from {
            at.str_span.start = (at.str_span.start as i64 + delta) as u32;
            at.str_span.end = (at.str_span.end as i64 + delta) as u32;
        }
    }
    for i in 0..old_metas {
        let mt = &mut a.metas[i];
        if mt.key.start >= from {
            mt.key.start = (mt.key.start as i64 + delta) as u32;
            mt.key.end = (mt.key.end as i64 + delta) as u32;
        }
        if mt.vspan.start >= from {
            mt.vspan.start = (mt.vspan.start as i64 + delta) as u32;
            mt.vspan.end = (mt.vspan.end as i64 + delta) as u32;
        }
    }
}

// The one plain function whose body block strictly encloses the byte window [ws, we) of the OLD
// source, or NODE_NONE. Excluded (return NODE_NONE): `const fn` (bodies are cross-module semantics
// through CTFE) and interface default methods (bodies re-check per foreign conformer).
fn splice_candidate(a: &Ast, ws: u32, we: u32) NodeId {
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
        let fd = n.as_data.function;
        if fd.body == NODE_NONE || fd.is_const {
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
/// state was broken): the caller MUST fall back to a full compile -- the package may be part-updated.
/// True: `p` and `diags` (previous round's records in, merged records out) are current.
pub fn recompile(
    p: &mut loader::Package,
    target: i32,
    root_file: str,
    lint_dir: str,
    ov_files: &Vector<String>,
    ov_texts: &Vector<String>,
    diags: &mut Vector<DiagRec>,
    st: &mut RecompileStats,
) bool {
    let n = p.modules.len();
    // A resolve-gated baseline (run_pipeline typechecks NOTHING while any module has a resolve
    // error) holds no semantic state to extend: an empty per-node type table on a parsed module
    // marks it. Hand such rounds to the full path.
    for i in 0..n {
        if p.modules[i].has_ast && p.modules[i].ast.nodes.len() > 1 && p.modules[i].ast.types.len() == 0 {
            return false;
        }
    }
    // 1) the changed set: modules whose overlay text differs from the analyzed source
    let mut changed = Vector::<usize>::new();
    for i in 0..n {
        switch overlay_for(p, i, ov_files) {
            Some(k) => {
                if ov_texts.at(k).as_str() != p.modules[i].source.as_str() {
                    changed.push(i);
                }
            },
            None => {},
        };
    }
    if changed.len() == 0 {
        return true; // no semantic work: the retained analysis and diagnostics stand
    }
    let mut body_sliced = Vector::<bool>::new();
    for _ in 0..changed.len() {
        body_sliced.push(false);
    }
    // 2) guards + reparse each changed module
    for c in 0..changed.len() {
        let i = changed[c];
        if p.modules[i].prelude || !p.modules[i].has_ast {
            return false; // prelude reaches everything implicitly; a broken prior state has no baseline
        }
        let k = overlay_for(p, i, ov_files).unwrap();
        let file = p.modules[i].file.clone();
        let mut ns = String::from_str(ov_texts.at(k).as_str());
        let mut lx = lex::Lexer::new(&mut ns, file.as_str());
        lx.scan_tokens();
        if lx.has_errors() {
            return false;
        }
        let toks = lx.take_tokens();
        // body-splice probe: common prefix/suffix window strictly inside one plain fn body
        let mut ws: u32 = 0;
        let mut we: u32 = 0;
        let mut delta: i64 = 0;
        {
            let os = p.modules[i].source.as_str();
            let nv = ns.as_str();
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
        let cand = splice_candidate(&p.modules[i].ast, ws, we);
        let mut spliced = false;
        if cand != NODE_NONE {
            spliced = try_body_splice(p, i, cand, toks, ns, file.as_str(), we, delta);
        } else {
            ns.free();
            toks.free();
        }
        if spliced {
            body_sliced.set(c, true);
            st.body_only += 1;
        } else {
            // full module reparse (fresh lex: the splice attempt consumed the first stream). Fresh
            // ids, so the import surface must be unchanged or the loader's closure caches (and every
            // importer's decl references) would be wrong.
            let mut ns9 = String::from_str(ov_texts.at(k).as_str());
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
            let old = replace(&mut p.modules[i].ast, na);
            old.free();
            p.modules[i].ast.module = i as ModuleId;
            p.modules[i].source = ns9;
            emit::platform_filter_module(p, i, target);
        }
        st.reparsed += 1;
    }
    // 3) decl spans (and for full reparses, decl ids) changed: rebuild the package index. The
    // import-closure caches survive -- the guard above proved the edges identical.
    p.build_index();
    // 4) the affected closure: changed modules, plus every module that can reach one through imports
    let mut aff = Vector::<bool>::new();
    for _ in 0..n {
        aff.push(false);
    }
    for c in 0..changed.len() {
        aff.set(changed[c], true);
    }
    for m in 0..n {
        if aff[m] {
            continue;
        }
        let clo = unsafe &*p.module_closure(m as ModuleId);
        let mut hit = false;
        for j in 0..clo.len() {
            for c in 0..changed.len() {
                // a body-spliced module's interface (decl ids, signatures, const bodies) is
                // untouched, so reaching it does not stale the reacher
                if !body_sliced[c] && clo[j] as usize == changed[c] {
                    hit = true;
                }
            }
        }
        if hit {
            aff.set(m, true);
        }
    }
    // 5) re-run the pipeline over the affected set only, mirroring run_pipeline's phase order
    let pkg = p as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
    let mut nd = Vector::<DiagRec>::new();
    for i in 0..n {
        if !aff[i] {
            continue;
        }
        let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
        if !lsp_resolve_module(p, i, lw, &mut nd) {
            // run_pipeline gates ALL typechecking on every module resolving; mirroring that
            // incrementally would wipe retained analyses, so hand the round to the full path
            p.ceval = null;
            nd.free();
            return false;
        }
        st.analyzed += 1;
    }
    for i in 0..n {
        if !aff[i] {
            continue;
        }
        let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
        lsp_typecheck_module(p, i, lw, &mut nd);
    }
    ceval.all_typed = true;
    for i in 0..n {
        if !aff[i] {
            continue;
        }
        if lsp_lint_wanted(p, i, root_file, lint_dir) {
            let mut errs = diag::Errors::new();
            emit::check_always_panics_module(p, i, &mut errs);
            if errs.errors.len() != 0 {
                errs.finalize(p.modules[i].source.as_str(), p.modules[i].file.as_str());
                drain_errors(&errs, i as u32, &mut nd);
            }
        }
    }
    p.ceval = null;
    // 6) merge: keep unaffected modules' records, replace the affected ones'
    let mut merged = Vector::<DiagRec>::new();
    while diags.len() > 0 {
        let d = diags.remove(diags.len() - 1).unwrap();
        if d.module as usize < n && !aff[d.module as usize] {
            merged.push(d);
        } else {
            let dd = d;
            dd.free();
        }
    }
    while merged.len() > 0 {
        diags.push(merged.remove(merged.len() - 1).unwrap());
    }
    while nd.len() > 0 {
        let d = nd.remove(0).unwrap();
        diags.push(d);
    }
    return true;
}

// Parse the new body region into the module's EXISTING arena (token stream over the new source) and
// patch the surrounding state: fn body pointer, span shifts past the edit, replaced source. False =
// the body did not parse cleanly or did not consume exactly the edited region (brace structure
// changed); the arena is untouched enough for the caller to fall back to a full reparse of the
// module (node additions past the old length are orphans no analysis references yet).
fn try_body_splice(
    p: &mut loader::Package,
    i: usize,
    fnid: NodeId,
    toks: Vector<ltok::Token>,
    ns: String,
    file: str,
    we_old: u32,
    delta: i64,
) bool {
    let bodyid = p.modules[i].ast.at_const(fnid).as_data.function.body;
    let bspan = p.modules[i].ast.at_const(bodyid).span;
    // the body's '{' sits in the UNchanged prefix, so its offset is the same in both sources
    let mut at: i64 = -1;
    for t in 0..toks.len() {
        if toks.at(t).start() == bspan.start {
            at = t as i64;
            break;
        }
        if toks.at(t).start() > bspan.start {
            break;
        }
    }
    if at < 0 {
        return false;
    }
    let old_nodes = p.modules[i].ast.nodes.len();
    let old_attrs = p.modules[i].ast.attrs.len();
    let old_metas = p.modules[i].ast.metas.len();
    let ns2 = ns;
    let mut ps = par::Parser::new(toks, ns2.as_str(), file);
    let fresh = replace(&mut ps.ast, replace(&mut p.modules[i].ast, Ast::new(0)));
    fresh.free();
    let nb = ps.reparse_fn_body(at as usize, fnid);
    let bad = ps.has_errors() || nb == NODE_NONE;
    let want_end = (bspan.end as i64 + delta) as u32;
    let arena_back = ps.take_ast();
    let hold = replace(&mut p.modules[i].ast, arena_back);
    hold.free();
    if bad || p.modules[i].ast.at_const(nb).span.end != want_end {
        return false; // orphaned appends only; the caller full-reparses this module
    }
    let a = &mut p.modules[i].ast;
    shift_spans(a, old_nodes, old_attrs, old_metas, we_old, delta);
    a.at(fnid).as_data.function.body = nb;
    p.modules[i].source = ns2;
    return true;
}

// The shared codegen-free pipeline over a loaded package: harvest parse failures, platform-filter,
// resolve + typecheck every module (lints gated per module), then the always-panics phase.
fn run_pipeline(p: &mut loader::Package, target: i32, root_file: str, lint_dir: str, diags: &mut Vector<DiagRec>) {
    for i in 0..p.modules.len() {
        if !p.modules[i].has_ast {
            harvest_parse_errors(p, i, diags);
        }
    }
    emit::platform_filter(p, target);
    let pkg = p as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
    let n = p.modules.len();
    let mut resolved = true;
    for i in 0..n {
        let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
        let ok = lsp_resolve_module(p, i, lw, diags);
        resolved = ok && resolved;
    }
    if resolved {
        for i in 0..n {
            let lw = lsp_lint_wanted(p, i, root_file, lint_dir);
            lsp_typecheck_module(p, i, lw, diags);
        }
        // driver-parity post-typecheck phase: the always-panics check (an error) interprets
        // cross-module `const fn` bodies, so it only runs once every module is typed
        ceval.all_typed = true;
        for i in 0..n {
            if lsp_lint_wanted(p, i, root_file, lint_dir) {
                let mut errs = diag::Errors::new();
                emit::check_always_panics_module(p, i, &mut errs);
                if errs.errors.len() != 0 {
                    errs.finalize(p.modules[i].source.as_str(), p.modules[i].file.as_str());
                    drain_errors(&errs, i as u32, diags);
                }
            }
        }
    }
    p.ceval = null; // the stack ConstEval dies here; the Package outlives it
}
