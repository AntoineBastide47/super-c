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
