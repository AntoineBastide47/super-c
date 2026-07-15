// The LSP's codegen-free diagnostics pass: build the package (editor-buffer overlays applied), resolve
// and typecheck every module, and harvest every diagnostic as a (module, span, severity, message)
// record instead of printing it. Mirrors driver::emit's lint_package recipe exactly -- including its
// phase gate (no typechecking while any module has a resolve error), so the LSP shows the same error
// sets as the CLI.
import module::loader as loader;
import ast::ast as *;
import ast::parser as par;
import lexer::lexer as lex;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import utils::errors as diag;
import driver::emit as emit;

pub struct DiagRec {
    pub module: u32,
    pub start: u32, // byte span into the module's source
    pub len: u32,
    pub severity: u8, // LSP DiagnosticSeverity: 1 = error, 2 = warning
    pub msg: String,
    // machine-applicable fix (lint warnings only): -1 = none, 0 = delete [fix_start, fix_end),
    // 1 = insert '_' before fix_start -- the LintFix kinds, surfaced as LSP quick fixes
    pub fix_kind: i32,
    pub fix_start: u32,
    pub fix_end: u32,
}

extend DiagRec as Free {
    pub fn free(self: &mut Self) {
        self.msg.free();
    }
}

// Reduce a diagnostic to its message: phase entry points finalize their Errors internally, so what we
// hold is the rendered block ("error: <msg>\n--> file:line:col\n | ..."). Take the first line minus the
// severity prefix, then append any "= note:" lines (they carry fix hints worth showing in the editor).
fn block_msg(block: &String) String {
    let s = block.as_str();
    let mut start: usize = 0;
    if s.starts_with("error: ") {
        start = 7;
    } else if s.starts_with("warning: ") {
        start = 9;
    }
    let mut end = start;
    while end < s.len() && s[end] != b'\n' {
        end += 1;
    }
    let mut out = String::from_str(s.slice(start, end));
    let mut i = end;
    while i < s.len() {
        let mut ls = i + 1; // line start after the '\n'
        let mut le = ls;
        while le < s.len() && s[le] != b'\n' {
            le += 1;
        }
        let line = s.slice(ls, le).trim();
        if line.starts_with("= note: ") {
            out.push_byte(b'\n');
            out.push_str(line);
        }
        i = le;
    }
    return out;
}

// Append every error/warning in `e` (post-finalize: spans stay parallel, see Errors::finalize) as a
// DiagRec against module `m`.
fn drain_errors(e: &diag::Errors, m: u32, diags: &mut Vector<DiagRec>) {
    for k in 0..e.errors.len() {
        diags.push(
            DiagRec {
                module: m,
                start: e.starts[k],
                len: e.lens[k],
                severity: 1,
                msg: block_msg(e.errors.at(k)),
                fix_kind: -1,
                fix_start: 0,
                fix_end: 0,
            },
        );
    }
    for k in 0..e.warns.len() {
        let mut fk: i32 = -1;
        let mut fs: u32 = 0;
        let mut fe: u32 = 0;
        for j in 0..e.fixes.len() {
            if e.fixes.at(j).warn == k as u32 {
                fk = e.fixes.at(j).kind;
                fs = e.fixes.at(j).start;
                fe = e.fixes.at(j).end;
                break; // one quick fix per warning
            }
        }
        diags.push(
            DiagRec {
                module: m,
                start: e.warn_starts[k],
                len: e.warn_lens[k],
                severity: 2,
                msg: block_msg(e.warns.at(k)),
                fix_kind: fk,
                fix_start: fs,
                fix_end: fe,
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

// emit::resolve_module with the diagnostics drained instead of logged.
fn lsp_resolve_module(p: &mut loader::Package, i: usize, lint: bool, diags: &mut Vector<DiagRec>) bool {
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
    drain_errors(&r.errors, i as u32, diags);
    let back = r.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// emit::typecheck_module with the diagnostics drained instead of logged.
fn lsp_typecheck_module(p: &mut loader::Package, i: usize, lint: bool, diags: &mut Vector<DiagRec>) bool {
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
    drain_errors(&t.errors, i as u32, diags);
    let back = t.take_ast();
    p.modules[i].ast = back;
    return !had;
}

// Load + resolve + typecheck (NO codegen), harvesting all diagnostics into `diags`. Takes ownership of
// the overlay vectors. The returned Package keeps every module's typed Ast -- the positional features
// (hover/definition/references) query it until the next rebuild. Lints run for non-prelude modules,
// like `super-c build`.
pub fn compile(
    root_file: str,
    root_dir: str,
    alt_dir: str,
    std_dir: *const char,
    target: i32,
    ov_files: Vector<String>,
    ov_texts: Vector<String>,
    diags: &mut Vector<DiagRec>,
) loader::Package {
    let mut p = loader::package_load_overlaid(root_file, root_dir, alt_dir, std_dir, false, ov_files, ov_texts);
    for i in 0..p.modules.len() {
        if !p.modules[i].has_ast {
            harvest_parse_errors(&p, i, diags);
        }
    }
    emit::platform_filter(&mut p, target);
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
    let n = p.modules.len();
    let mut resolved = true;
    for i in 0..n {
        let ok = lsp_resolve_module(&mut p, i, !p.modules[i].prelude, diags);
        resolved = ok && resolved;
    }
    if resolved {
        for i in 0..n {
            lsp_typecheck_module(&mut p, i, !p.modules[i].prelude, diags);
        }
    }
    p.ceval = null; // the stack ConstEval dies here; the Package outlives it
    return p;
}
