// In-process compiler tests load source snippets through loader::package_from_source.
// Run from the repository root so the prelude resolves at std/.
import lexer::lexer as lex;
import lexer::token as *;
import ast::ast as *;
import ast::parser as par;
import resolver::resolver as res;
import hir::lower as hirl;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import driver::emit as demit;
import driver::test as dtest;
import module::loader as loader;
import ir::interp as iri;
import graph::items as gitems;
import ir::lower as irl;
import borrowck::facts as bfx;
import borrowck::flow_ir as bfi;
import driver_shim as shim;
import std::platform::fs;
import std::platform::process;
import tests::cli_harness as cli;
import driver::util as dutil;

import stdio;
import stdlib;
import string as cstring;
import errno;
import unistd;

// `tmpfile` (an anonymous, auto-removed temp stream) is declared in <stdio.h>, which super_rt always
// includes, so a bare extern binding resolves without needing a header string.
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

/// Pipeline stages `compile` can stop after (`STAGE_TYPECHECK` includes the borrow check). A failing
/// compile reports `STAGE_BORROWCK` when only the borrow check failed.
pub(package) const STAGE_PARSE: i32 = 0;
pub(package) const STAGE_RESOLVE: i32 = 1;
pub(package) const STAGE_TYPECHECK: i32 = 2;
pub(package) const STAGE_BORROWCK: i32 = 3;

// A stage result: how many errors the USER module produced, at which stage, and the first message text
// (copied out before the compiler frees it). `ok()` is the accept/reject verdict the oracle asserts on.
/// Outcome of an in-process compile: error count and the first message.
pub(package) struct Compiled {
    pub(package) errors: usize,
    pub(package) stage: i32,
    pub(package) first: [char; 512],
}

extend Compiled {
    /// True when no error was reported.
    pub(package) const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    // Whether the first error message contains `needle` (matched as a substring).
    /// True when the first diagnostic contains `needle`.
    pub(package) fn msg_has(self: &Self, needle: str) bool {
        return cli::contains_str(&self.first[0], needle);
    }
}

// Copy at most 511 bytes of `s` into dst[512], NUL-terminated (dst is pre-zeroed by the caller).
const fn copy_msg(dst: *mut char, s: &String) {
    let n = s.len();
    let k = if n < 511 {
        n;
    } else {
        511 as usize;
    };
    if k > 0 {
        unsafe cstring::memcpy(dst, s.as_ptr(), k);
    }
    unsafe dst[k] = 0 as char;
}

/// `compile` of `src` as a module of the standard library (path `std::harness`, a file under the std
/// root) for instruction set `arch` (loader arch codes, -1 for the host's): the std-only attributes
/// apply, and the backend table's diagnostics (`build_simd_table`) count as the module's.
pub(package) fn compile_std(src: str, arch: i32, stop: i32) Compiled {
    return compile_in(src, stop, true, arch, false);
}

/// `compile_std` for the host's instruction set as a `--bootstrap-tags` build sees it.
pub(package) fn compile_std_bootstrap(src: str, stop: i32) Compiled {
    return compile_in(src, stop, true, -1, true);
}

// Run `src` through the pipeline up to `stop`, reporting the user module (index 0) diagnostics.
/// Compile `src` in process through stage `stop` (STAGE_*), collecting diagnostics.
pub(package) fn compile(src: str, stop: i32) Compiled {
    return compile_in(src, stop, false, -1, false);
}

fn compile_in(src: str, stop: i32, as_std: bool, arch: i32, bootstrap: bool) Compiled {
    let mut r = Compiled {};

    // Parse stage: lex + parse standalone (no package needed to see syntax errors). The lexer pads its
    // source, so give it an owned String copy of `src`.
    let mut s = String::from_str(src);
    let mut lx = lex::Lexer::new(&mut s, "");
    lx.scan_tokens();
    if lx.has_errors() {
        r.errors = lx.errors.errors.len();
        r.stage = STAGE_PARSE;
        if r.errors > 0 {
            copy_msg(&mut r.first[0], lx.errors.rendered_errors.at(0));
        }
        return r;
    }
    let vectors = lx.vectors;
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, s.as_str(), "");
    ps.build_ast();
    if ps.has_errors() {
        r.errors = ps.errors.errors.len();
        r.stage = STAGE_PARSE;
        if r.errors > 0 {
            copy_msg(&mut r.first[0], ps.errors.rendered_errors.at(0));
        }
        return r;
    }
    if stop == STAGE_PARSE {
        return r;
    }
    let k = snap_index(vectors, arch, bootstrap);
    if k >= 0 {
        let out = snap_run(k as usize, src, stop, as_std, false, false);
        unsafe cstring::memcpy((&mut r) as *mut Compiled, out.as_ptr(), sizeof(Compiled));
        return r;
    }

    // Semantic stages need the prelude: load the snippet as module 0 alongside std, exactly like the CLI.
    let mut p = loader::package_from_source_arch(
        src,
        "std",
        unsafe shim::sc_host_platform(),
        if arch >= 0 {
            arch;
        } else {
            unsafe shim::sc_host_arch();
        },
    );
    p.bootstrap = bootstrap;
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;
    check_from(&mut p, 0, stop, as_std, &mut r);
    return r;
}

// The semantic stages of `compile` over a package whose last module is the snippet. The modules
// before `from` are resolved and type-checked already (a snapshot's prelude); borrowck runs over
// every module, after the one type publication.
fn check_from(p: &mut loader::Package, from: usize, stop: i32, as_std: bool, r: &mut Compiled) {
    let n = p.modules.len();
    let uidx = n - 1; // the user module is loaded last, after the prelude
    if as_std {
        p.modules[uidx].path = String::from_str("std::harness");
        p.modules[uidx].file = loader::join2(p.std_root.as_str(), "std/harness.spc");
    }
    // Resolve every module (prelude first, user last); snapshot the user module's diagnostics.
    for i in from..n {
        h_resolve(p, i, uidx, r);
    }
    if r.errors != 0 || stop == STAGE_RESOLVE {
        if r.errors != 0 {
            r.stage = STAGE_RESOLVE;
        }
        return;
    }
    // Typecheck every module; snapshot the user module's diagnostics. Borrowck follows as its own
    // pass over the fully typed package, exactly like the driver.
    reopen_items(p, from);
    for i in from..n {
        h_typecheck(p, i, uidx, r);
    }
    if r.errors == 0 && as_std {
        let te = demit::build_simd_table(p, n);
        if te.len() != 0 {
            r.errors = 1;
            copy_msg(&mut r.first[0], &te);
        }
    }
    if r.errors != 0 {
        r.stage = STAGE_TYPECHECK;
        return;
    }
    demit::publish_checkpoint(p, null);
    for i in 0..n {
        h_borrowck(p, i, uidx, r, null);
    }
    if r.errors != 0 {
        r.stage = STAGE_BORROWCK;
    }
}

// Lex + parse a source standalone (no package/prelude) and hand back the AST for shape inspection.
// `errors` > 0 means the snippet failed to lex or parse. RAII frees the AST with the result.
/// A parsed module kept alive for AST inspection (formatter path when trivia is kept).
pub(package) struct ParsedAst {
    pub(package) errors: usize,
    pub(package) ast: Ast,
}

extend ParsedAst as Free {
    pub fn free(self: &mut ParsedAst) {
        self.ast.free();
    }
}

pub(package) fn parse_ast(src: str) ParsedAst {
    return parse_ast_opt(src, true);
}

// The formatter's parse: `@derive` stays attribute trivia (no synthesized extends), exactly as
// format_source parses.
/// Parse `src` keeping comment tokens, as the formatter does.
pub(package) fn parse_ast_for_fmt(src: str) ParsedAst {
    return parse_ast_opt(src, false);
}

fn parse_ast_opt(src: str, expand_derive: bool) ParsedAst {
    let mut r = ParsedAst { errors: 0, ast: Ast::new(0) };
    let mut s = String::from_str(src);
    let mut lx = lex::Lexer::new(&mut s, "");
    lx.scan_tokens();
    if lx.has_errors() {
        r.errors = lx.errors.errors.len();
        return r;
    }
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, s.as_str(), "");
    ps.expand_derive = expand_derive;
    ps.build_ast();
    if ps.has_errors() {
        r.errors = ps.errors.errors.len();
    }
    r.ast = ps.take_ast();
    return r;
}

// True if `src` fails to lex or parse (the parse-stage rejection oracle).
/// True when parsing `src` reports an error.
pub(package) fn parse_has_error(src: str) bool {
    let mut s = String::from_str(src);
    let mut lx = lex::Lexer::new(&mut s, "");
    lx.scan_tokens();
    if lx.has_errors() {
        return true;
    }
    let toks = lx.take_tokens();
    let mut ps = par::Parser::new(toks, s.as_str(), "");
    ps.build_ast();
    let e = ps.has_errors();
    return e;
}

// A stage result that also hands back the user module's (resolved/typed) AST for target inspection
// (RAII frees it with the result); span text is looked up against the caller's own source literal,
// which outlives this call.
/// A typechecked module kept alive for AST inspection.
pub(package) struct CompiledAst {
    pub(package) errors: usize,
    pub(package) stage: i32,
    pub(package) ast: Ast,
    pub(package) pkg: loader::Package, // `ast` reads its types through the package table: the package outlives it
}

pub(package) fn compile_ast(src: str, stop: i32) CompiledAst {
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    if !p.ok {
        return CompiledAst { errors: 1, stage: STAGE_PARSE, ast: Ast::new(0), pkg: p };
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;
    let n = p.modules.len();
    let uidx = n - 1;
    let mut rr = Compiled {};
    for i in 0..n {
        h_resolve(&mut p, i, uidx, &mut rr);
    }
    if rr.errors == 0 && stop != STAGE_RESOLVE {
        for i in 0..n {
            h_typecheck(&mut p, i, uidx, &mut rr);
        }
    }
    // Detach the user module's AST for inspection beside the package that holds its types.
    p.cir = null;
    let ast = replace(&mut p.modules[uidx].ast, Ast::new(0));
    return CompiledAst { errors: rr.errors, stage: stop, ast: ast, pkg: p };
}

// Inspection helpers over a returned AST (mirror tests/test_harness.h's th_* / ast_resolution).
// The n-th node (0-based) of the given kind, in creation order; NODE_NONE if fewer than n+1 exist.
/// The `nth` (0-based) node of `kind` in arena order, or NODE_NONE.
pub(package) fn nth_kind(a: &Ast, kind: NodeKind, nth: usize) NodeId {
    let mut seen: usize = 0;
    let mut k: usize = 1;
    while k < a.nnodes() {
        let id = a.nth_id(k);
        if a.at_const(id).kind == kind {
            if seen == nth {
                return id;
            }
            seen = seen + 1;
        }
        k = k + 1;
    }
    return NODE_NONE;
}

// True if node `id` is a NODE_IDENTIFIER whose source text equals `name` (a NUL-terminated cstring).
/// True when identifier node `id` spells `name`.
pub(package) fn ident_is(a: &Ast, src: *const char, id: NodeId, name: *const char) bool {
    let nd = a.at_const(id);
    if nd.kind != NodeKind::NODE_IDENTIFIER {
        return false;
    }
    let s = nd.as_data.name.text.start;
    let e = nd.as_data.name.text.end;
    let l = unsafe cstring::strlen(name);
    if (e - s) as usize != l {
        return false;
    }
    return unsafe cstring::memcmp(src + s as usize, name, l) == 0;
}

// Read a whole stream into a fresh NUL-terminated heap buffer (caller frees). Seeks to the end for the
// length first, so it works both for a freshly written temp stream and a freshly-opened file (position 0).
fn read_stream(f: *mut stdio::FILE) *mut char {
    unsafe stdio::fflush(f);
    let _ = unsafe stdio::fseek(f, 0, stdio::SEEK_END);
    let sz = unsafe stdio::ftell(f);
    if sz < 0 {
        return null;
    }
    unsafe stdio::rewind(f);
    let buf = (unsafe stdlib::malloc(sz as usize + 1)) as *mut char;
    if buf == null {
        return null;
    }
    let got = unsafe stdio::fread(buf, 1, sz as usize, f);
    unsafe buf[got] = 0 as char;
    return buf;
}

// The generated C for the user snippet (module 0's header + .c concatenated), for substring inspection:
// the analog of tests/test_harness.h's sc_codegen. `code` is owned (call `.free()`).
/// Outcome of emitting C in process: error count and the generated text.
pub(package) struct CompiledC {
    pub(package) errors: usize,
    pub(package) code: *mut char,
}

extend CompiledC {
    pub(package) const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    /// True when the emitted C contains `needle`.
    pub(package) fn code_has(self: &Self, needle: str) bool {
        if self.code == null {
            return false;
        }
        return cli::contains_str(self.code, needle);
    }
}
extend CompiledC as Free {
    pub fn free(self: &mut Self) {
        if self.code != null {
            unsafe stdlib::free(self.code);
            self.code = null;
        }
    }
}

// Run the full pipeline and emit the snippet's C: the shared headers, the snippet's own translation unit
// and the instance code, without the prelude's translation units: a needle cannot match a prelude
// function body. On any pre-codegen error, `errors` is set and `code` is null; codegen-stage
// diagnostics also set `errors` but the (partial) code is still returned.
pub(package) fn compile_c(src: str) CompiledC {
    return compile_c_of(src, false, unsafe shim::sc_host_arch());
}
/// The text of the C function that `def` opens in `code`, to its closing brace at a line start.
pub(package) fn c_fn<'a>(code: str<'a>, def: str) str<'a> {
    let at = code.find(def);
    assert(at >= 0, "the function is defined");
    let rest = code.slice(at as usize, code.len());
    let end = rest.find("\n}\n");
    assert(end >= 0, "the definition ends");
    return rest.slice(def.len(), end as usize);
}
/// Only the user snippet's own translation unit (needle absence must not trip on std code).
pub(package) fn compile_c_user(src: str) CompiledC {
    return compile_c_of(src, true, unsafe shim::sc_host_arch());
}
/// `compile_c` for instruction set `arch` (0 x86_64, 1 aarch64): the C a build for it emits, on any host.
pub(package) fn compile_c_arch(src: str, arch: i32) CompiledC {
    return compile_c_of(src, false, arch);
}
fn compile_c_of(src: str, user_only: bool, arch: i32) CompiledC {
    let mut out = CompiledC { errors: 0, code: null };
    let mut code = String::new();
    let k = snap_index(loader::source_names_vectors(src), arch, false);
    if k >= 0 {
        let bytes = snap_run(k as usize, src, STAGE_BORROWCK, false, true, user_only);
        let s = bytes.as_str();
        unsafe cstring::memcpy((&mut out.errors) as *mut usize, s.ptr(), sizeof(usize));
        code.push_str(s.slice(sizeof(usize), s.len()));
    } else {
        let mut p = loader::package_from_source_arch(src, "std", unsafe shim::sc_host_platform(), arch);
        let pkg = (&mut p) as *mut loader::Package;
        let mut cirv = iri::interp_new(pkg);
        p.cir = &mut cirv;
        out.errors = emit_from(&mut p, 0, user_only, &mut code);
    }
    if out.errors != 0 {
        return out;
    }
    let buf = (unsafe stdlib::malloc(code.len() + 1)) as *mut char;
    if buf == null {
        out.errors = 1;
        return out;
    }
    unsafe cstring::memcpy(buf, code.as_ptr(), code.len());
    unsafe buf[code.len()] = 0 as char;
    out.code = buf;
    return out;
}

// The stages of `compile_c` over a package whose last module is the snippet, as `check_from` runs
// them, then the emission: the snippet's C into `code`. The error count; `code` is set only at 0.
fn emit_from(p: &mut loader::Package, from: usize, user_only: bool, code: &mut String) usize {
    if !p.ok {
        return 1;
    }
    let n = p.modules.len();
    let uidx = n - 1;
    let mut rr = Compiled {};
    for i in from..n {
        h_resolve(p, i, uidx, &mut rr);
    }
    if rr.errors == 0 {
        reopen_items(p, from);
        for i in from..n {
            h_typecheck(p, i, uidx, &mut rr);
        }
    }
    if rr.errors != 0 {
        return rr.errors;
    }
    // The backend table, built after the type check as the driver builds it: the planner calls its entries.
    demit::check_feature_calls(p, n);
    if demit::build_simd_table(p, n).len() != 0 || !p.ok {
        return 1;
    }
    let mut keep = irl::Keep::new();
    demit::publish_checkpoint(p, &mut keep);
    for i in 0..n {
        h_borrowck(p, i, uidx, &mut rr, &mut keep);
    }
    if rr.errors != 0 {
        return rr.errors;
    }
    // Whole-package emission through the production backend; the text keeps the shared headers (`str`,
    // monomorphized Slice/Box, ...) and the instance code.
    let tplan = dtest::TestPlan::new(n);
    let mut o = demit::CemitOut::new(n);
    demit::cemit_package(p, false, &tplan, null, -1, &mut o, &mut keep);
    if o.skips != 0 {
        return o.skips as usize;
    }
    if !user_only {
        code.push_string(&o.fwd_h);
        // The unit's includes and its declarations of the prototypes that need a definition header.
        code.push_string(o.tu_incs.at(uidx));
        for d in 0..o.defs_h.len() {
            code.push_string(o.defs_h.at(d));
        }
        for t in 0..n {
            code.push_string(o.protos_h.at(t));
        }
    }
    // A TU is its part heads, the shared body buffer, then the tail; the file writer interleaves
    // them per part, the needle search only needs every byte present.
    for x in 0..o.tu_heads.at(uidx).len() {
        code.push_string(o.tu_heads.at(uidx).at(x));
    }
    code.push_string(o.tus.at(uidx));
    code.push_string(o.tu_tail.at(uidx));
    if !user_only {
        for q in 0..n {
            for x in 0..o.inst_heads.at(q).len() {
                code.push_string(o.inst_heads.at(q).at(x));
            }
        }
        code.push_string(&o.inst_c);
        code.push_string(&o.registry_c);
    }
    return 0;
}

static mut R_SEQ: u64 = 0;

// The captured result of compiling+running a snippet: whether it built, its exit code, and stdout+stderr.
/// Outcome of compiling and running a snippet: whether it built, its exit code, and captured output.
pub(package) struct RunResult {
    pub(package) built: bool,
    pub(package) exit: i32,
    pub(package) out: *mut char,
}

extend RunResult {}
extend RunResult as Free {
    pub fn free(self: &mut Self) {
        if self.out != null {
            unsafe stdlib::free(self.out);
            self.out = null;
        }
    }
}

// Read a whole file into a fresh NUL-terminated buffer (caller frees); null if it cannot be opened.
fn slurp(path: *const char) *mut char {
    let f = stdio::fopen(unsafe str::from_cstr(path), "rb");
    if f == null {
        return null;
    }
    let buf = read_stream(f);
    unsafe stdio::fclose(f);
    return buf;
}

fn rm_dir(dir: str) {
    let _ = fs::remove_all(dir);
}

/// Build `src` as a program and run it, capturing stdout.
pub(package) fn compile_and_run(src: str) RunResult {
    return compile_and_run_env(src, "");
}

// As compile_and_run, but with `env` ("VAR=v " assignments, trailing space) prefixed to the run command.
/// `compile_and_run` with `env` (space-separated NAME=VALUE) applied to the program.
pub(package) fn compile_and_run_env(src: str, env: str) RunResult {
    return compile_and_run_in(src, false, env);
}

/// `compile_and_run` through the C backend: the C emitter's own behavior, the C tree `--emit-c` writes
/// built by the comparison job's C compiler (`cli::has_cc` first).
pub(package) fn compile_and_run_c(src: str) RunResult {
    return compile_and_run_in(src, true, "");
}

// `compile_and_run`, through the C backend when `c`, with `env` applied to the program.
fn compile_and_run_in(src: str, c: bool, env: str) RunResult {
    let mut r = RunResult { built: false, exit: -1, out: null };
    let dir = scratch_dir();
    if dir.len() == 0 {
        return r;
    }
    let d = dir.as_str();
    if !write_text(format("{}/main.spc", d).as_str(), src) {
        rm_dir(d);
        return r;
    }
    let bin = prog_path(d);
    if !build_script(d, bin.as_str(), c) {
        rm_dir(d);
        return r;
    } // did not build
    r.built = true;
    let mut run = prog_cmd(d, bin.as_str(), "");
    let mut outp = format("{}/out", d);
    r.exit = cli::run_with(run.cstr(), null, outp.cstr(), null, env);
    r.out = slurp(outp.cstr());
    rm_dir(d);
    return r;
}

// A fresh scratch directory under the system temp directory; empty when it cannot be made.
// Process-local: one forked process per test, and the name carries the pid, the sequence and the clock.
fn scratch_dir() String {
    unsafe R_SEQ = unsafe R_SEQ + 1;
    let dir = format(
        "{}/scr_{}_{}_{}",
        cli::tmp_dir().as_str(),
        process::pid().unwrap_or(1),
        unsafe R_SEQ,
        dutil::ticks_ms() as u64,
    );
    rm_dir(dir.as_str()); // a directory an aborted test left under a reused pid
    if fs::mkdir_all(dir.as_str()).is_err() {
        return String::new();
    }
    return dir;
}

// Write `text` to `path`, in binary mode: no Windows CRLF in emitted .spc sources. False when the file
// cannot be opened.
fn write_text(path: str, text: str) bool {
    let wf = stdio::fopen(path, "wb");
    if wf == null {
        return false;
    }
    if text.len() > 0 {
        let _ = unsafe stdio::fwrite(text.ptr(), 1, text.len(), wf);
    }
    unsafe stdio::fclose(wf);
    return true;
}

// The path of the program built in scratch directory `d`: a wasm32 module on the target lane.
fn prog_path(d: str) String {
    if target_lane() {
        return format("{}/prog.wasm", d);
    }
    return format("{}/prog{}", d, unsafe str::from_cstr(cli::binext()));
}

// The command that runs program `bin` of scratch directory `d` with `args`: under wasmtime on the target
// lane, with the environment and `d`.
fn prog_cmd(d: str, bin: str, args: str) String {
    if target_lane() {
        return format("wasmtime run -S inherit-env --dir=\"{}\" \"{}\" {}", d, bin, args);
    }
    return format("\"{}\" {}", bin, args);
}

// Build `<dir>/main.spc` as a script into `bin` with the compiler under test (for wasm32 on the target
// lane), through its C tree and the C compiler when `c`; whether it built.
fn build_script(dir: str, bin: str, c: bool) bool {
    let mut cmd = format(
        "\"{}\" build{} \"{}/main.spc\"",
        cli::superc_path(),
        if target_lane() {
            " --target=wasm";
        } else {
            "";
        },
        dir,
    );
    if !c {
        cmd.format_into(" -o \"{}\"", bin);
        return cli::run_with(cmd.cstr(), null, null, null, "") == 0;
    }
    // Not `<dir>/out`: the run writes its output there.
    cmd.format_into(" --emit-c \"--out-dir={}/build\"", dir);
    return cli::run_with(cmd.cstr(), null, null, null, "") == 0 && cli::cc_tree_link(
        format("{}/build/debug/raw", dir).as_str(),
        bin,
        "",
        format("{}/.cc", dir).as_str(),
    ) == 0;
}

// Build+run `src` and require it to terminate with exit code `code` (the analog of tests/codegen_run's
// `sc_run_program(name, src, code, "")`: the program signals its result via `exit(code)`).
/// Assert that `src` builds and exits with `code`, naming `label` on failure.
pub(package) fn expect_exit(label: str, src: str, code: i32) {
    let r = compile_and_run(src);
    assert(r.built, label);
    if r.exit != code {
        eprintln("{}: exit {}, expected {}", label, r.exit, code);
    }
    assert(r.exit == code, label);
}

/// Assert that `src` builds and its run fails with output (stdout and stderr) holding `msg`.
pub(package) fn expect_trap(label: str, src: str, msg: str) {
    let r = compile_and_run(src);
    assert(r.built, label);
    let ok = r.exit != 0 && cli::contains_str(r.out, msg);
    if !ok {
        eprintln("{}: exit {}: {}", label, r.exit, unsafe str::from_cstr(r.out));
    }
    assert(ok, label);
}

/// Exit-code and trap cases built as one program. `run` gives each case's source its own module `c<k>`
/// of a scratch program, with its `fn main()` or `fn main(NAME: Vector<str>)` renamed `case_main` and
/// made public, builds the program once, and runs it once per case with the argument `k`; a case
/// whose `main` takes the arguments gets them without `k`, as a run of its own program does. A case
/// with another `main`, and every case of a program that does not build (two cases whose C
/// declarations clash, a case that does not compile), builds alone through `expect_exit` or
/// `expect_trap`, so a failure still names its case.
pub(package) struct ExitBatch {
    labels: Vector<String>,
    srcs: Vector<String>,
    codes: Vector<i32>,
    traps: Vector<String>,
}

// The `main` of case program `s`: the offset of its `fn main(`, the offset of the `)` that ends its
// parameters, and whether it takes the arguments (`NAME: Vector<str>`). The offset is -1 when `s` has
// no `main` of these two forms, or more than one `fn main(`.
const fn case_main_of(s: str) (isize, usize, bool) {
    let at = s.find("fn main(");
    if at < 0 {
        return -1, 0, false;
    }
    let open = at as usize + 8;
    let rest = s.slice(open, s.len());
    let close = rest.find(")");
    if close < 0 || rest.find("fn main(") >= 0 {
        return -1, 0, false;
    }
    let params = rest.slice(0, close as usize);
    if params.len() == 0 {
        return at, open + close as usize, false;
    }
    let colon = params.find(": Vector<str>");
    if colon <= 0 || colon as usize + 13 != params.len() {
        return -1, 0, false;
    }
    for i in 0..colon as usize {
        let c = params.byte_at(i);
        if !(c == b'_' || c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9') {
            return -1, 0, false;
        }
    }
    return at, open + close as usize, true;
}

extend ExitBatch {
    pub(package) fn new() ExitBatch {
        return ExitBatch {
            labels: Vector::<String>::new(),
            srcs: Vector::<String>::new(),
            codes: Vector::<i32>::new(),
            traps: Vector::<String>::new(),
        };
    }

    /// Add the case `label`: `src` must build and exit with `code`.
    pub(package) fn add(self: &mut Self, label: str, src: str, code: i32) {
        self.labels.push(String::from_str(label));
        self.srcs.push(String::from_str(src));
        self.codes.push(code);
        self.traps.push(String::new());
    }

    /// Add the case `label`: `src` must build and its run must fail with output holding `msg`.
    pub(package) fn add_trap(self: &mut Self, label: str, src: str, msg: str) {
        self.labels.push(String::from_str(label));
        self.srcs.push(String::from_str(src));
        self.codes.push(0);
        self.traps.push(String::from_str(msg));
    }

    // Case `k` built as its own program.
    fn alone(self: &Self, k: usize) {
        if self.traps[k].len() == 0 {
            expect_exit(self.labels[k].as_str(), self.srcs[k].as_str(), self.codes[k]);
        } else {
            expect_trap(self.labels[k].as_str(), self.srcs[k].as_str(), self.traps[k].as_str());
        }
    }

    /// Build the cases and check each one's exit code or trap.
    pub(package) fn run(self: &Self) {
        let mut root = String::new();
        let mut batched = Vector::<usize>::new();
        for k in 0..self.srcs.len() {
            let (at, _, _) = case_main_of(self.srcs[k].as_str());
            if at < 0 {
                self.alone(k);
            } else {
                batched.push(k);
            }
        }
        if batched.len() <= 1 {
            // One case gains nothing from a batch: it builds as its own program.
            for i in 0..batched.len() {
                self.alone(batched[i]);
            }
            return;
        }
        let dir = scratch_dir();
        assert(dir.len() != 0, "harness: no scratch directory for the batch");
        let d = dir.as_str();
        // The argument vector is gone before a case without arguments runs: a case may end the process
        // with `exit`, and the leak check would count a vector still held.
        let mut body = String::from_str(
            "fn case_index(args: &Vector<str>) i64 {\n    return args.at(1).parse_i64().unwrap();\n}\n\n// The arguments without the case index: those of a run of the case's own program.\nfn case_args(args: Vector<str>) Vector<str> {\n    let mut a = args;\n    let _ = a.pop();\n    return a;\n}\n\nfn case_end(_args: Vector<str>) {}\n\nfn main(args: Vector<str>) i32 {\n    let k = case_index(&args);\n    let a = case_args(args);\n",
        );
        for i in 0..batched.len() {
            let s = self.srcs[batched[i]].as_str();
            let (at, close, takes) = case_main_of(s);
            let mut m = String::from_str(s.slice(0, at as usize));
            if !m.as_str().ends_with("pub ") {
                m.push_str("pub ");
            }
            m.push_str("fn case_main(");
            m.push_str(s.slice(at as usize + 8, s.len()));
            assert(write_text(format("{}/c{}.spc", d, i).as_str(), m.as_str()), "harness: cannot write a batch case");
            root.format_into("import c{};\n", i);
            let args = if takes {
                "a";
            } else {
                "";
            };
            body.format_into("    if k == {} {{\n", i);
            if !takes {
                body.push_str("        case_end(a);\n");
            }
            // A `main` without a return type ends the process with 0 when it returns.
            let rest = s.slice(close + 1, s.len());
            let mut e: usize = 0;
            while e < rest.len() && rest.byte_at(e) == b' ' {
                e += 1;
            }
            if e < rest.len() && rest.byte_at(e) == b'{' {
                body.format_into("        c{}::case_main({});\n        return 0;\n    }}\n", i, args);
            } else {
                body.format_into("        return c{}::case_main({});\n    }}\n", i, args);
            }
        }
        body.push_str("    return 255;\n}\n");
        root.push_string(&body);
        assert(write_text(format("{}/main.spc", d).as_str(), root.as_str()), "harness: cannot write the batch root");
        let bin = prog_path(d);
        if !build_script(d, bin.as_str(), false) {
            rm_dir(dir.as_str());
            for i in 0..batched.len() {
                self.alone(batched[i]);
            }
            return;
        }
        let mut outp = format("{}/out", d);
        let mut exits = Vector::<i32>::new();
        let mut outs = Vector::<String>::new();
        for i in 0..batched.len() {
            let mut run = prog_cmd(d, bin.as_str(), format("{}", i).as_str());
            exits.push(cli::run_with(run.cstr(), null, outp.cstr(), null, ""));
            outs.push(cli::read_text(outp.as_str()));
        }
        rm_dir(dir.as_str());
        for i in 0..batched.len() {
            let k = batched[i];
            let msg = self.traps[k].as_str();
            let ok = if msg.len() == 0 {
                exits[i] == self.codes[k];
            } else {
                exits[i] != 0 && outs[i].contains(msg);
            };
            if !ok && msg.len() == 0 {
                eprintln(
                    "{}: exit {}, expected {}: {}",
                    self.labels[k].as_str(),
                    exits[i],
                    self.codes[k],
                    outs[i].as_str(),
                );
            } else if !ok {
                eprintln(
                    "{}: exit {}, expected a trap with '{}': {}",
                    self.labels[k].as_str(),
                    exits[i],
                    msg,
                    outs[i].as_str(),
                );
            }
            assert(ok, self.labels[k].as_str());
        }
    }
}

// Require the snippet to compile cleanly AND its generated C to contain `needle`.
/// Assert that `src` emits C containing `needle`.
pub(package) fn expect_c(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(c.code_has(needle), label);
}
// Require the snippet to compile cleanly AND its generated C to NOT contain `needle`.
/// Assert that `src` emits C not containing `needle`.
pub(package) fn expect_c_absent(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(!c.code_has(needle), label);
}

// expect_ok / expect_err: the accept-vs-reject oracle for semantic tests.
/// Assert that `src` typechecks without errors.
pub(package) fn expect_ok(label: str, src: str) {
    let c = compile(src, STAGE_TYPECHECK);
    assert(c.ok(), label);
}
/// Assert that `src` resolves without errors.
pub(package) fn expect_resolve_ok(label: str, src: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(c.ok(), label);
}
// Reject at the given stage AND require the first message to contain `needle`.
/// Assert that typechecking `src` reports an error containing `needle`.
pub(package) fn expect_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_TYPECHECK);
    if !c.msg_has(needle) {
        eprintln("{}: the first error is: {}", label, str::from_cbuf(c.first));
    }
    assert(!c.ok(), label);
    assert(c.msg_has(needle), label);
}
/// Assert that resolving `src` reports an error containing `needle`.
pub(package) fn expect_resolve_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_RESOLVE);
    if !c.msg_has(needle) {
        eprintln("{}: the first error is: {}", label, str::from_cbuf(c.first));
    }
    assert(!c.ok(), label);
    assert(c.msg_has(needle), label);
}

// Differential oracles: one source under two option lists, a constant against its run-time twin, and
// the assembly of one function. Each program is the root of a scratch manifest project built by the
// compiler under test. On the wasm lane the build runs its transpile step in the wasm compiler
// (`--transpiler`), so the guest does the constant evaluation.

/// The build of one differential program: its scratch project, whether it built, the build output,
/// and whether it is a wasm32 module (run under wasmtime).
pub(package) struct DiffBuild {
    pub(package) proj: cli::Proj,
    pub(package) built: bool,
    pub(package) diag: String,
    pub(package) wasm: bool,
}

// The vector conformance lane, `SC_SIMD_LANE=wasm` (a wasi-sdk in WASI_SDK_PATH, wasmtime on the
// PATH): every differential program builds for wasm32 with `+simd128` and runs under wasmtime, and
// `expect_run` also builds it without the feature and requires the same results. -1 until read; the
// runner forks one process per test, so the cache is never shared.
static mut SIMD_LANE: i32 = -1;

// The target lane, `SC_TEST_TARGET=wasm` (wasmtime on the PATH): the vector lane over the whole suite,
// so every program the harness builds (`compile_and_run` too) is a wasm32 module run under wasmtime.
// -1 until read.
static mut TARGET_LANE: i32 = -1;

/// Whether the target lane is on (`SC_TEST_TARGET=wasm`).
pub(package) fn target_lane() bool {
    if unsafe TARGET_LANE < 0 {
        let e = stdlib::getenv("SC_TEST_TARGET");
        unsafe TARGET_LANE = (e != null && unsafe str::from_cstr(e) == "wasm") as i32;
    }
    return unsafe TARGET_LANE == 1;
}

/// Whether the vector conformance lane is on (`SC_SIMD_LANE=wasm`, or the target lane).
pub(package) fn simd_lane() bool {
    if unsafe SIMD_LANE < 0 {
        let e = stdlib::getenv("SC_SIMD_LANE");
        unsafe SIMD_LANE = (e != null && unsafe str::from_cstr(e) == "wasm" || target_lane()) as i32;
    }
    return unsafe SIMD_LANE == 1;
}

/// One run of a differential program: exit code, stdout and stderr.
pub(package) struct DiffRun {
    pub(package) exit: i32,
    pub(package) out: String,
    pub(package) err: String,
}

/// Build `src` as main.spc of a scratch project. An option of the form NAME=VALUE sets that
/// environment variable for the build (`SC_BCE=0`); any other option is one build flag. With `--emit-c`
/// the build writes the C tree only (`c_link` builds it).
pub(package) fn diff_build(src: str, opts: []str) DiffBuild {
    let p = diff_proj();
    p.mkfile("main.spc", src);
    return diff_build_in(p, opts);
}

/// The scratch project of `diff_build` without its sources (`diff_build_in` writes its build.toml).
pub(package) fn diff_proj() cli::Proj {
    return cli::proj_new();
}

/// `diff_build` of the project `p` of `diff_proj`, its sources written: its `build.toml` (root
/// `main.spc`) is written here, from `opts`.
pub(package) fn diff_build_in(p: cli::Proj, opts: []str) DiffBuild {
    let mut wasm = simd_lane();
    for o in opts {
        wasm = wasm || o == "--target=wasm";
    }
    p.mkfile("build.toml", "bin = \"prog\"\nroot = \"main.spc\"\n");
    let mut c = false;
    for o in opts {
        c = c || o == "--emit-c";
    }
    let exe = cli::superc_path(); // resolved before the chdir below
    let mut cmd = String::new();
    cmd.format_into("\"{}\" build", exe);
    let mut env = String::new();
    if simd_lane() {
        cmd.push_str(" --target=wasm --target-feature=+simd128");
    }
    // `SC_SIMD_FEATURES`: more CPU features for every differential build (a conformance run with
    // `+dotprod,+i8mm,+rdm`, or an x86-64 level).
    let more = stdlib::getenv("SC_SIMD_FEATURES");
    if more != null && unsafe *more != 0 as char {
        cmd.format_into(" --target-feature={}", unsafe str::from_cstr(more));
    }
    // `SC_SIMD_WIDTH`: the preferred width on AVX-512 (`--simd-width`), 512 for the 512-bit entries.
    let width = stdlib::getenv("SC_SIMD_WIDTH");
    if width != null && unsafe *width != 0 as char {
        cmd.format_into(" --simd-width={}", unsafe str::from_cstr(width));
    }
    for o in opts {
        if o.starts_with("-") {
            cmd.format_into(" \"{}\"", o);
        } else {
            if env.len() != 0 {
                env.push_byte(b' ');
            }
            env.push_str(o);
        }
    }
    if cli::on_wasm() {
        cmd.format_into(" \"--transpiler={}\"", exe);
    }
    if !c {
        cmd.format_into(" -o prog{}", unsafe str::from_cstr(cli::binext()));
    }
    let mut outp = String::new();
    outp.format_into("{}/.build", p.dir());
    // The engine reads build.toml from its working directory.
    let mut rc = -1;
    if process::set_current_dir(p.dir()).is_ok() {
        rc = cli::run_with(cmd.cstr(), null, outp.cstr(), null, env.as_str());
    }
    return DiffBuild { proj: p, built: rc == 0, diag: cli::read_text(outp.as_str()), wasm: wasm };
}

/// Assert that the build of `src` fails with a diagnostic containing `needle`, before its C compile.
pub(package) fn expect_build_err(label: str, src: str, needle: str) {
    let b = diff_build(src, []);
    let ok = !b.built && b.diag.contains(needle) && !b.diag.contains("C compile failed") && !b.diag.contains("internal");
    if !ok {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(ok, label);
}

/// `expect_build_err` for every case of `b` (see `cli::Batch`), each program the root of a
/// `diff_proj` project.
pub(package) fn expect_build_errs(mut b: cli::Batch) {
    assert(b.file.eq_str("main.spc"), "a case alone is the project's root");
    b.forbid("C compile failed");
    b.forbid("internal");
    while b.next() {
        let p = diff_proj();
        let _ = b.write(&p, "main.spc");
        let r = diff_build_in(p, []);
        b.take(
            if r.built {
                0;
            } else {
                1;
            },
            r.diag.as_str(),
        );
    }
}

/// Assert that `src` builds and its run with argument `arg` traps with `msg` on stderr, or exits 0
/// when `msg` is empty.
pub(package) fn expect_run(label: str, src: str, arg: str, msg: str) {
    expect_runs(label, src, [arg], [msg]);
}

/// `expect_run` of `src` for each argument `args[i]` with trap text `msgs[i]`, from one build per
/// option set: the runs differ only in their argument.
pub(package) fn expect_runs(label: str, src: str, args: []str, msgs: []str) {
    let b = diff_build(src, []);
    if !b.built {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(b.built, label);
    // The runs of `b` come first: the scalar build moves the working directory into its own scratch
    // directory, which it removes when it drops.
    for i in 0..args.len() {
        let r = diff_run(&b, args[i]);
        let msg = msgs[i];
        let ok = if msg.len() == 0 {
            r.exit == 0;
        } else {
            r.exit != 0 && r.err.contains(msg);
        };
        if !ok {
            eprintln("{} (argument {}): exit {}: {}{}", label, args[i], r.exit, r.out.as_str(), r.err.as_str());
        }
        assert(ok, label);
    }
    // The scalar lowering and the hardware entries give the same results: in the lane without the
    // wasm feature, on an aarch64 host (Neon in every build) with the planner off.
    let neon = !simd_lane() && unsafe shim::sc_host_arch() == 1;
    if simd_lane() || neon {
        let scalar: [str; 1] = if neon {
            ["SC_SIMD_SCALAR=1"];
        } else {
            ["--target-feature=-simd128"];
        };
        let a = diff_build(src, scalar);
        let d = if a.built {
            same_runs(&a, &b, args);
        } else {
            format("the program does not build with options A:\n{}", a.diag.as_str());
        };
        if d.len() != 0 {
            eprintln("{}: scalar and vector entries: {}", label, d.as_str());
        }
        assert(d.len() == 0, label);
    }
}

/// Run the program `b` built with `args` (a command-line fragment) and capture its output.
pub(package) fn diff_run(b: &DiffBuild, args: str) DiffRun {
    let root = b.proj.dir();
    let mut cmd = String::new();
    if b.wasm {
        // Relaxed SIMD runs deterministically: a result never depends on the host.
        cmd.format_into("wasmtime run -W relaxed-simd-deterministic=y --dir=\"{}\" \"{}/prog\" {}", root, root, args);
    } else {
        cmd.format_into("\"{}/prog{}\" {}", root, unsafe str::from_cstr(cli::binext()), args);
    }
    let mut outp = String::new();
    outp.format_into("{}/.out", root);
    let mut errp = String::new();
    errp.format_into("{}/.err", root);
    let exit = cli::run_with(cmd.cstr(), null, outp.cstr(), errp.cstr(), "");
    return DiffRun { exit: exit, out: cli::read_text(outp.as_str()), err: cli::read_text(errp.as_str()) };
}

/// The trap lines of a run's stderr: the runtime's `super-c: ...` and std's `panic: ...` messages.
/// Backtraces and other diagnostics are not part of the trap text.
pub(package) fn trap_text(err: str) String {
    let mut t = String::new();
    for line in err.lines() {
        if line.starts_with("super-c: ") || line.starts_with("panic: ") {
            t.push_str(line);
            t.push_byte(b'\n');
        }
    }
    return t;
}

/// Build `src` under `opts_a` and under `opts_b`, run both once per entry of `runs` (each entry is the
/// command-line arguments of one run), and describe the first difference in exit code, stdout or trap
/// text. Empty when every run agrees. A build failure is a difference.
pub(package) fn same_output(src: str, opts_a: []str, opts_b: []str, runs: []str) String {
    let mut r = String::new();
    let a = diff_build(src, opts_a);
    if !a.built {
        r.format_into("the program does not build with options A:\n{}", a.diag.as_str());
        return r;
    }
    let b = diff_build(src, opts_b);
    if !b.built {
        r.format_into("the program does not build with options B:\n{}", b.diag.as_str());
        return r;
    }
    return same_runs(&a, &b, runs);
}

/// `same_output` over two builds the caller made (both built): run each once per entry of `runs`
/// and describe the first difference, empty when none.
pub(package) fn same_runs(a: &DiffBuild, b: &DiffBuild, runs: []str) String {
    let mut r = String::new();
    for args in runs {
        let ra = diff_run(a, args);
        let rb = diff_run(b, args);
        let ta = trap_text(ra.err.as_str());
        let tb = trap_text(rb.err.as_str());
        if ra.exit != rb.exit || !ra.out.equals(&rb.out) || !ta.equals(&tb) {
            r.format_into(
                "run '{}' differs\nA: exit {}, stdout:\n{}A trap: {}\nB: exit {}, stdout:\n{}B trap: {}\n",
                args,
                ra.exit,
                ra.out.as_str(),
                ta.as_str(),
                rb.exit,
                rb.out.as_str(),
                tb.as_str(),
            );
            return r;
        }
    }
    return r;
}

/// Assert that `src` gives the same exit code, stdout and trap text built with `opts_a` and with
/// `opts_b` (see `diff_build` for the option forms).
pub(package) fn expect_same_output(label: str, src: str, opts_a: []str, opts_b: []str) {
    let d = same_output(src, opts_a, opts_b, [""]);
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

/// The trap class a compile-time error names for a trap ("arithmetic overflow", "division by zero",
/// "shift out of range"), or the text from `lane <i>: ` of a vector operation's trap, the same at run
/// time; empty for any other error.
pub(package) const fn const_trap_class<'a>(msg: str<'a>) str<'a> {
    let lane = msg.find("lane ");
    if lane >= 0 && lane as usize + 5 < msg.len() && msg.byte_at(lane as usize + 5) >= b'0' && msg.byte_at(
        lane as usize + 5,
    ) <= b'9' {
        let t = msg.slice(lane as usize, msg.len());
        let stack = t.find(" (call stack");
        if stack >= 0 {
            return t.slice(0, stack as usize);
        }
        return t.trim();
    }
    if msg.contains("arithmetic overflow") {
        return "arithmetic overflow";
    }
    if msg.contains("division by zero") {
        return "division by zero";
    }
    if msg.contains("shift out of range") {
        return "shift out of range";
    }
    if msg.contains("index out of bounds") {
        return "index out of bounds";
    }
    return "";
}

/// The trap class of a run-time trap message (`rt_h.spc` arithmetic and index helpers), in the words a constant
/// reports for the same trap, or the text from `lane <i>: ` of a vector operation's trap; empty for any
/// other trap.
pub(package) const fn runtime_trap_class<'a>(trap: str<'a>) str<'a> {
    let lane = trap.find("lane ");
    if lane >= 0 && lane as usize + 5 < trap.len() && trap.byte_at(lane as usize + 5) >= b'0' && trap.byte_at(
        lane as usize + 5,
    ) <= b'9' {
        return trap.slice(lane as usize, trap.len()).trim();
    }
    if trap.contains("attempt to shift") {
        return "shift out of range";
    }
    if trap.contains("attempt to divide by zero") || trap.contains("with a divisor of zero") {
        return "division by zero";
    }
    if trap.contains("with overflow") {
        return "arithmetic overflow";
    }
    if trap.contains("index out of bounds") {
        return "index out of bounds";
    }
    return "";
}

// The parity program: every case as a constant `PARITY_C<k>` (one line each, from line `first`)
// unless `omit[k]`, and as the run-time function `parity_r<k>`; `prog <k>` prints the constant as
// `c <value>`, then the run-time value as `r <value>`. A float prints its bits, a NaN as `nan`.
fn parity_source(decls: str, exprs: []str, tys: []str, omit: &Vector<bool>, first: &mut usize) String {
    let mut s = String::from_str(decls);
    if s.len() != 0 && !s.ends_with("\n") {
        s.push_byte(b'\n');
    }
    s.push_str("@noinline\nconst fn opq<T>(x: T) T {\n    return x;\n}\n");
    // A write to a static is a side effect no constant evaluation performs: the compiler cannot see
    // through `opr`, so the run-time copy computes at run time and its traps are not compile errors.
    s.push_str("static mut PARITY_SINK: usize = 0;\n@noinline\nfn opr<T>(x: T) T {\n");
    s.push_str("    unsafe PARITY_SINK += 1;\n    return x;\n}\n");
    for t in tys {
        if t == "f64" || t == "f32" {
            s.push_str("union ParityF64 {\n    pub f: f64,\n    pub u: u64,\n}\n");
            s.push_str("union ParityF32 {\n    pub f: f32,\n    pub u: u32,\n}\n");
            s.push_str("fn parity_f64(tag: str, v: f64) {\n    if v.is_nan() {\n        println(\"{} nan\", tag);\n");
            s.push_str("    } else {\n        println(\"{} {}\", tag, ParityF64 { f: v }.u);\n    }\n}\n");
            s.push_str("fn parity_f32(tag: str, v: f32) {\n    if v.is_nan() {\n        println(\"{} nan\", tag);\n");
            s.push_str("    } else {\n        println(\"{} {}\", tag, ParityF32 { f: v }.u);\n    }\n}\n");
            break;
        }
    }
    *first = s.count_byte(b'\n') + 1;
    for k in 0..exprs.len() {
        if omit[k] {
            s.push_str("\n"); // keeps every constant on its line
        } else {
            s.format_into("const PARITY_C{}: {} = {};\n", k, tys[k], exprs[k]);
        }
    }
    for k in 0..exprs.len() {
        let rt = String::from_str(exprs[k]).replace("opq::", "opr::").replace("opq(", "opr(");
        s.format_into("@noinline\nfn parity_r{}() {} {{\n    return {};\n}}\n", k, tys[k], rt.as_str());
    }
    // Argument -1 runs every case in order, each after a line `= k`.
    s.format_into(
        "fn main(args: Vector<str>) i32 {{\n    let a = args.at(1).parse_i64().unwrap();\n    let mut k = if a < 0 {{\n        0;\n    }} else {{\n        a;\n    }};\n    let end = if a < 0 {{\n        {};\n    }} else {{\n        a + 1;\n    }};\n    while k < end {{\n    if a < 0 {{\n        println(\"= {{}}\", k);\n    }}\n",
        exprs.len(),
    );
    for k in 0..exprs.len() {
        s.format_into("    if k == {} {{\n", k);
        let t = tys[k];
        if !omit[k] {
            if t == "f64" || t == "f32" {
                s.format_into("        parity_{}(\"c\", PARITY_C{});\n", t, k);
            } else {
                s.format_into("        println(\"c {{}}\", PARITY_C{});\n", k);
            }
        }
        if t == "f64" || t == "f32" {
            s.format_into("        parity_{}(\"r\", parity_r{}());\n", t, k);
        } else {
            s.format_into("        println(\"r {{}}\", parity_r{}());\n", k);
        }
        s.push_str("    }\n");
    }
    s.push_str("    k += 1;\n    }\n    return 0;\n}\n");
    return s;
}

// Mark every case whose constant failed to evaluate in build output `diag` with the trap class its
// error names; false when an error is not a trap of one constant.
fn parity_attribute(diag: str, first: usize, ct: &mut Vector<String>, omit: &mut Vector<bool>) bool {
    let mut msg = "";
    let mut any = false;
    for line in diag.lines() {
        if line.starts_with("error:") {
            msg = line;
            continue;
        }
        let at = line.find("main.spc:");
        if msg.len() == 0 || at < 0 {
            continue;
        }
        let rest = line.slice(at as usize + 9, line.len());
        let colon = rest.find(":");
        let ln = rest.slice(
            0,
            if colon < 0 {
                rest.len();
            } else {
                colon as usize;
            },
        ).parse_usize();
        let class = const_trap_class(msg);
        msg = "";
        if ln.is_none() || class.len() == 0 {
            return false;
        }
        let l = ln.unwrap();
        if l < first || l - first >= ct.len() {
            return false;
        }
        let k = l - first;
        ct[k] = String::from_str(class);
        omit[k] = true;
        any = true;
    }
    return any;
}

// The value a parity run printed under `tag` ("c" or "r"); empty when it printed none.
const fn parity_value<'a>(out: str<'a>, tag: str) str<'a> {
    for line in out.lines() {
        if line.len() > tag.len() && line.starts_with(tag) && line.byte_at(tag.len()) == b' ' {
            return line.slice(tag.len() + 1, line.len()).trim();
        }
    }
    return "";
}

/// Evaluate each `exprs[k]` of type `tys[k]` once as a constant and once at run time in one program
/// built with `opts` (`diff_build` forms) under `decls`, and describe every case where the value or
/// the trap differs; empty when all agree. A constant that traps is a compile error naming the class
/// of the trap ("arithmetic overflow"); the run time must trap with a message of that class
/// (`runtime_trap_class`). Inputs are written `opq::<T>(v)`: the constant calls the identity
/// `const fn opq`, the run-time copy calls `@noinline fn opr`, which the compiler cannot see
/// through. The program defines `opq`, `opr` and names starting with `parity_`, `Parity` and `PARITY_`.
pub(package) fn const_runtime_parity(decls: str, exprs: []str, tys: []str, opts_in: []str) String {
    assert(exprs.len() == tys.len());
    // On the wasm lane the guest compiler folds the constants, on wasi-libc: the run-time twin is a
    // wasm32 module (run under wasmtime) on the same C library.
    let mut ov = Vector::<str>::new();
    for o in opts_in {
        ov.push(o);
    }
    if cli::on_wasm() && !simd_lane() {
        ov.push("--target=wasm");
    }
    let opts = ov[0..ov.len()];
    let n = exprs.len();
    let mut ct = Vector::<String>::new();
    let mut omit = Vector::<bool>::new();
    for _ in 0..n {
        ct.push(String::new());
        omit.push(false);
    }
    let mut first: usize = 0;
    let mut r = String::new();
    let mut b = diff_build(parity_source(decls, exprs, tys, &omit, &mut first).as_str(), opts);
    if !b.built {
        if !parity_attribute(b.diag.as_str(), first, &mut ct, &mut omit) {
            r.format_into("the parity program does not build:\n{}", b.diag.as_str());
            return r;
        }
        b = diff_build(parity_source(decls, exprs, tys, &omit, &mut first).as_str(), opts);
        if !b.built {
            r.format_into("the parity program without its trapping constants does not build:\n{}", b.diag.as_str());
            return r;
        }
    }
    // One run computes every case, each after a line `= k`; a case after a trap or a crash runs alone,
    // so its trap is its own.
    let all = diff_run(&b, "-1");
    let segs = parity_segments(all.out.as_str());
    for k in 0..n {
        let done = k < segs.len() && (k + 1 < segs.len() || all.exit == 0);
        let run = if done {
            DiffRun { exit: 0, out: segs.at(k).clone(), err: String::new() };
        } else {
            let mut arg = String::new();
            arg.push_u64(k as u64);
            diff_run(&b, arg.as_str());
        };
        let trap = trap_text(run.err.as_str());
        let mut want = String::new();
        if omit[k] {
            want.format_into("trap: {}", ct.at(k).as_str());
        } else {
            want.format_into("value {}", parity_value(run.out.as_str(), "c"));
        }
        let mut got = String::new();
        if run.exit == 0 {
            got.format_into("value {}", parity_value(run.out.as_str(), "r"));
        } else {
            got.format_into("trap: {}", runtime_trap_class(trap.as_str()));
            if runtime_trap_class(trap.as_str()).len() == 0 {
                got.format_into("(exit {}) {}", run.exit, run.err.as_str());
            }
        }
        if !want.equals(&got) {
            r.format_into(
                "case {}: {}: {}\n  const:    {}\n  run time: {}\n",
                k,
                exprs[k],
                tys[k],
                want.as_str(),
                got.as_str(),
            );
        }
    }
    return r;
}

// The output of a run of every case (`-1`) per case: the lines after each `= k`.
fn parity_segments(out: str) Vector<String> {
    let mut segs = Vector::<String>::new();
    for line in out.lines() {
        if line.starts_with("= ") {
            segs.push(String::new());
        } else if segs.len() != 0 {
            let last = segs.len() - 1;
            segs.index_mut(last).push_str(line);
            segs.index_mut(last).push_byte(b'\n');
        }
    }
    return segs;
}

/// The program `const_runtime_parity` builds first, with every constant.
pub(package) fn parity_program(decls: str, exprs: []str, tys: []str) String {
    let mut omit = Vector::<bool>::new();
    for _ in 0..exprs.len() {
        omit.push(false);
    }
    let mut first: usize = 0;
    return parity_source(decls, exprs, tys, &omit, &mut first);
}

// True when C file `path` defines `function`: a line naming ` function(` that opens its body.
fn c_defines(path: str, function: str) bool {
    // A small program's `__sc_unity.c` defines what the units it includes define.
    if path.ends_with("/__sc_unity.c") {
        let dir = loader::dirname_of(path);
        let mut ms = Set::<String>::new();
        dutil::unity_members(dir, &mut ms);
        for m in ms.iter() {
            if c_defines(loader::join2(dir, m.as_str()).as_str(), function) {
                return true;
            }
        }
        return false;
    }
    let text = cli::read_text(path);
    let mut head = String::from_str(" ");
    head.push_str(function);
    head.push_str("(");
    for line in text.as_str().lines() {
        if line.contains(head.as_str()) && line.trim().ends_with("{") {
            return true;
        }
    }
    return false;
}

const fn asm_label_is(line: str, function: str) bool {
    return line.starts_with(function) && line.slice(function.len(), line.len()).starts_with(":");
}

/// The instruction mnemonics of `function` in assembly text `text`: the first word of each line from
/// the function's label (`name:` or Mach-O `_name:`) to the end of its body, without directives,
/// labels and comments. Empty when the label is absent.
pub(package) fn asm_mnemonics(text: str, function: str) Vector<String> {
    return asm_instructions(text, function, false);
}

/// `asm_mnemonics`, or with `whole` each instruction's whole text, its operands included.
pub(package) fn asm_instructions(text: str, function: str, whole: bool) Vector<String> {
    let mut names = Vector::<String>::new();
    let mut inside = false;
    for raw in text.lines() {
        let line = raw.trim();
        if !inside {
            inside = asm_label_is(line, function) || line.starts_with("_") && asm_label_is(
                line.slice(1, line.len()),
                function,
            );
            continue;
        }
        if line.starts_with(".cfi_endproc") || line.starts_with(".seh_endproc") || line.starts_with("end_function") || line.starts_with(
            ".Lfunc_end",
        ) || line.starts_with("Lfunc_end") || line.starts_with(".size") {
            break;
        }
        if line.len() == 0 || line.starts_with(".") || line.starts_with(";") || line.starts_with("#") || line.starts_with(
            "//",
        ) || line.starts_with("@") {
            continue;
        }
        let mut w: usize = 0;
        while w < line.len() && line.byte_at(w) != b' ' && line.byte_at(w) != b'\t' {
            w += 1;
        }
        let word = line.slice(0, w);
        if !word.ends_with(":") {
            names.push(
                String::from_str(
                    if whole {
                        line;
                    } else {
                        word;
                    },
                ),
            );
        }
    }
    return names;
}

/// Build the C tree of `src` with `opts` (`diff_build` forms, `--emit-c` added), compile the translation
/// unit that defines C function `function` with the tree's flags plus `-S` (`asm_text`), and check its
/// instruction mnemonics: every `contains` entry is a substring of one, no `absent` entry is a substring
/// of any (`=name`: equal to any; `%reg`: a substring of an instruction's operands, AT&T syntax).
/// Describes every failed check; empty when all hold. Needs the comparison job's C compiler.
pub(package) fn asm_check(src: str, opts: []str, function: str, contains: []str, absent: []str) String {
    let mut all = Vector::<str>::new();
    for o in opts {
        all.push(o);
    }
    all.push("--emit-c");
    let b = diff_build(src, all[0..all.len()]);
    if !b.built {
        return format("the program does not build:\n{}", b.diag.as_str());
    }
    let mut code = String::new();
    let r = asm_text(&b, opts, function, &mut code);
    if r.len() != 0 {
        return r;
    }
    return asm_match(code.as_str(), function, contains, absent);
}

/// The assembly of the translation unit of the C tree of build `b` (built with `opts` and `--emit-c`)
/// that defines C function `function`, into `out`: the tree's `__cflags` plus `-S`. Returns the failure,
/// empty on success. One unit's text serves every function it defines (`asm_match`).
pub(package) fn asm_text(b: &DiffBuild, opts: []str, function: str, out: &mut String) String {
    let mut r = String::new();
    let mut prof = "debug";
    for o in opts {
        if o.starts_with("--profile=") {
            prof = o.slice(10, o.len());
        }
    }
    let root = b.proj.dir();
    let raw = format("{}/build/{}/raw", root, prof);
    let mut unit = String::new();
    for u in cli::read_text(format("{}/__units", raw.as_str()).as_str()).as_str().lines() {
        if c_defines(format("{}/{}", raw.as_str(), u).as_str(), function) {
            unit = format("{}/{}", raw.as_str(), u);
            break;
        }
    }
    if unit.len() == 0 {
        r.format_into("no translation unit defines '{}'", function);
        return r;
    }
    let asmp = format("{}/function.s", root);
    let mut cmd = format(
        "\"{}\" {} -S \"{}\" -o \"{}\"",
        unsafe str::from_cstr(cli::cc_name()),
        cli::read_text(format("{}/__cflags", raw.as_str()).as_str()).as_str().trim(),
        unit.as_str(),
        asmp.as_str(),
    );
    let mut outp = format("{}/.asm", root);
    let rc = cli::run_with(cmd.cstr(), null, outp.cstr(), null, "");
    if rc != 0 {
        r.format_into("'{}' failed:\n{}", cmd.as_str(), cli::read_text(outp.as_str()).as_str());
        return r;
    }
    *out = cli::read_text(asmp.as_str());
    return r;
}

/// The mnemonic checks of `asm_check` on `function` in assembly text `code`. Describes every failed
/// check; empty when all hold.
pub(package) fn asm_match(code: str, function: str, contains: []str, absent: []str) String {
    let mut r = String::new();
    let names = asm_mnemonics(code, function);
    // An entry that starts with `%` matches a register operand (`%ymm`), in AT&T syntax; `a|b` is met by
    // either (C compilers pick among equivalent instructions: `uminv`, or `mvn` then `umaxv`).
    let whole = asm_instructions(code, function, true);
    if names.len() == 0 {
        r.format_into("no instructions of '{}' in the assembly", function);
        return r;
    }
    for want in contains {
        let mut found = false;
        for i in 0..names.len() {
            let hay = if want.starts_with("%") {
                whole.at(i);
            } else {
                names.at(i);
            };
            for alt in want.split("|") {
                found = found || hay.contains(alt);
            }
        }
        if !found {
            r.format_into("no instruction of '{}' contains '{}'\n", function, want);
        }
    }
    for bad in absent {
        for i in 0..names.len() {
            // `=name`: that mnemonic exactly (`=bl`, a call, is not `tbl`).
            let hit = if bad.starts_with("=") {
                names.at(i).as_str() == bad.slice(1, bad.len());
            } else {
                bad.starts_with("%") && whole.at(i).contains(bad) || !bad.starts_with("%") && names.at(i).contains(bad);
            };
            if hit {
                r.format_into("instruction '{}' of '{}' contains '{}'\n", names.at(i).as_str(), function, bad);
                break;
            }
        }
    }
    if r.len() != 0 {
        r.push_str("mnemonics:");
        for i in 0..names.len() {
            r.push_byte(b' ');
            r.push_string(names.at(i));
        }
        r.push_byte(b'\n');
    }
    return r;
}

/// Assert the instruction checks of `asm_check` on `function` of `src` built with `opts`.
pub(package) fn expect_asm(label: str, src: str, opts: []str, function: str, contains: []str, absent: []str) {
    let mut wasm = false;
    for o in opts {
        wasm = wasm || o == "--target=wasm";
    }
    if simd_lane() && !wasm {
        return; // the lane builds every program for wasm32: a host instruction check does not apply
    }
    let d = asm_check(src, opts, function, contains, absent);
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

// Mirror main.spc's resolve_module, capturing module `i`'s diagnostics when it is the user module (cap).
fn h_resolve(p: &mut loader::Package, i: usize, cap: usize, out: *mut Compiled) {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let aptr = (&mut m.ast) as *mut Ast;
    let mut rr = res::Resolver::new(unsafe &mut *aptr, unsafe str::from_raw(src as *const u8, len), pkg);
    rr.resolve();
    if i == cap {
        let c = rr.errors.errors.len();
        if c > 0 {
            unsafe (*out).errors = c;
            unsafe copy_msg(&mut (*out).first[0], rr.errors.rendered_errors.at(0));
        }
    }
    hirl::lower_module(p, i);
}

// Mirror main.spc's typecheck_module, capturing the user module's diagnostics.
fn h_typecheck(p: &mut loader::Package, i: usize, cap: usize, out: *mut Compiled) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    t.check();
    if i == cap {
        let c = t.errors.errors.len();
        if c > 0 {
            unsafe (*out).errors = c;
            unsafe copy_msg(&mut (*out).first[0], t.errors.rendered_errors.at(0));
        }
    }
}

// Mirror the driver's borrowck_module: a SEPARATE stage after every module is typed (import cycles
// mean a body's callees can live in a later module, so the checker may only run once all types exist).
// `keep` (null = discard) receives the module's lowerings, as the driver's borrow frontier keeps
// them for emission.
fn h_borrowck(p: &mut loader::Package, i: usize, cap: usize, out: *mut Compiled, keep: *mut irl::Keep) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, unsafe str::from_raw(src as *const u8, len), pkg);
    let mut ow = bfx::Owner::new(pkg);
    let mut ctx = bfi::BorrowCtx::new();
    ctx.keep = keep;
    t.borrowck(&mut ow, &mut ctx);
    if i == cap {
        let c = t.errors.errors.len();
        if c > 0 {
            unsafe (*out).errors = c;
            unsafe copy_msg(&mut (*out).first[0], t.errors.rendered_errors.at(0));
        }
    }
}

// Prelude snapshots. Each in-process compile used to load, resolve and type-check the whole std
// prelude before the snippet: the same work every time. The runner's parent does it once (the global
// fixture below), and each compile forks from it and runs only the rest: the snippet's resolve and
// type check, then the borrow check and the emission over every module after the one type
// publication, so every type id stays what the full pipeline gives. Windows has no fork: there each
// compile runs the full pipeline.

/// A host prelude package, resolved and type-checked, and the constant engine bound to it. Each
/// points at the other, so a snapshot stays where it was built.
pub(package) struct Snap {
    pub(package) p: loader::Package,
    pub(package) cir: iri::Interp,
}

/// The suite's global environment: the snapshots, by whether the snippet names a vector (index 1:
/// the prelude with the vector backend).
pub(package) struct HarnessEnv {
    pub(package) snaps: Vector<Box<Snap>>,
}

/// The snapshots of the global environment, where a compile reaches them: null where none was built.
static mut SNAPS: [*mut Snap; 2] = [null, null];

@test_init(global)
fn harness_env() HarnessEnv {
    let mut env = HarnessEnv { snaps: Vector::<Box<Snap>>::new() };
    if PLATFORM == Platform::Windows {
        return env;
    }
    for k in 0..2 {
        let mut b = Box::<Snap>::new(
            Snap {
                p: loader::prelude_package_arch(
                    "std",
                    unsafe shim::sc_host_platform(),
                    unsafe shim::sc_host_arch(),
                    k == 1,
                ),
                cir: iri::interp_new(null),
            },
        );
        let s = b.deref_mut() as *mut Snap;
        // The engine binds to the package where it now lives; the placeholder it replaces is dropped.
        let _ = replace(unsafe &mut (*s).cir, iri::interp_new(unsafe &(*s).p));
        unsafe {
            (*s).p.cir = &mut (*s).cir;
        }
        let n = unsafe (*s).p.modules.len();
        let mut rr = Compiled {};
        for i in 0..n {
            h_resolve(unsafe &mut (*s).p, i, n, &mut rr);
        }
        for i in 0..n {
            h_typecheck(unsafe &mut (*s).p, i, n, &mut rr);
        }
        unsafe SNAPS[k] = s;
        env.snaps.push(b);
    }
    return env;
}

// A snapshot's item index covers the prelude alone (its first type check opened it): open it again
// over every module, the `from` prelude modules' items checked, as the language server reopens it
// after a module joins. No-op on the full pipeline (`from` 0), whose first type check opens it.
fn reopen_items(p: &mut loader::Package, from: usize) {
    if from == 0 {
        return;
    }
    gitems::open(p);
    for m in 0..from {
        p.set_module_states(m, loader::IS_CHECKED);
    }
}

// The snapshot a compile can fork from, or -1: none was built (Windows), or the compile needs another
// prelude (another instruction set, `--bootstrap-tags`).
fn snap_index(vectors: bool, arch: i32, bootstrap: bool) i64 {
    let k: usize = if vectors {
        1;
    } else {
        0;
    };
    if bootstrap || arch >= 0 && arch != unsafe shim::sc_host_arch() || unsafe SNAPS[k] == null {
        return -1;
    }
    return k as i64;
}

@platform(macos | linux)
extern "C" "sys/wait.h" {
    fn waitpid(pid: i32, status: *mut i32, options: i32) i32;
}

@platform(macos | linux)
extern "C" "errno.h" {
    const EINTR: i32;
}

// The leak tracker of the generated runtime: a forked compile forgets the allocations of the test that
// forked it, and reports its own before it exits.
extern "C" {
    fn sc_lk_fork_child_reset();
    fn sc_lk_report_now();
}

// Run one compile of `src` on snapshot `k` in a forked process: it adds the snippet to its copy of the
// snapshot, runs the stages (`emit`: `emit_from`, else `check_from`), writes the result to a pipe and
// exits, so the snapshot stays as built for the next compile. A compile that ends its process another
// way (a panic, a signal, the leak report's exit code) ends this process the same way.
@platform(macos | linux)
fn snap_run(k: usize, src: str, stop: i32, as_std: bool, emit: bool, user_only: bool) String {
    let mut fds: [i32; 2] = [0, 0];
    if unsafe unistd::pipe(&mut fds[0]) != 0 {
        panic("harness: pipe failed");
    }
    unsafe stdio::fflush(null); // the child must not write this process's buffered output again
    let pid = unsafe unistd::fork();
    if pid < 0 {
        panic("harness: fork failed");
    }
    if pid == 0 {
        unsafe sc_lk_fork_child_reset();
        let _ = unsafe unistd::close(fds[0]);
        snap_child(k, src, stop, as_std, emit, user_only, fds[1]);
        unsafe stdio::fflush(null);
        unsafe sc_lk_report_now();
        unsafe stdlib::exit_now(0);
    }
    let _ = unsafe unistd::close(fds[1]);
    let mut out = String::new();
    let mut buf: [u8; 65536] = [0; 65536];
    loop {
        let got = unsafe unistd::read(fds[0], &mut buf[0], 65536);
        if got > 0 {
            out.push_str(unsafe str::from_raw(&buf[0], got as usize));
        } else if got == 0 || errno::errno() != EINTR {
            break;
        }
    }
    let _ = unsafe unistd::close(fds[0]);
    let mut st: i32 = 0;
    while unsafe waitpid(pid, &mut st, 0) < 0 {
        if errno::errno() != EINTR {
            panic("harness: waitpid failed");
        }
    }
    // The wait status as macOS and Linux both encode it: the terminating signal in the low 7 bits
    // (0: the process exited), the exit code in the next 8.
    let sig = st & 0x7f;
    let code = st >> 8 & 0xff;
    if sig == 6 {
        stdlib::abort();
    }
    if sig != 0 {
        eprintln("harness: the forked compile ended by signal {}", sig);
        unsafe stdlib::exit_now(128 + sig);
    }
    if code != 0 {
        unsafe stdlib::exit_now(code);
    }
    return out;
}

@platform(windows | wasm | ios | android)
fn snap_run(_: usize, _: str, _: i32, _: bool, _: bool, _: bool) String {
    panic("harness: no prelude snapshot without fork");
}

// The forked side of `snap_run`: the compile, its result written to `fd`, then the snapshot copy
// freed, so the leak report that follows sees this compile's allocations alone.
@platform(macos | linux)
fn snap_child(k: usize, src: str, stop: i32, as_std: bool, emit: bool, user_only: bool, fd: i32) {
    let s = unsafe SNAPS[k];
    let from = unsafe (*s).p.modules.len();
    unsafe (*s).p.add_source_module(src, unsafe shim::sc_host_platform());
    let mut out = String::new();
    if emit {
        let mut code = String::new();
        let errors = emit_from(unsafe &mut (*s).p, from, user_only, &mut code);
        out.push_str(unsafe str::from_raw(((&errors) as *const usize) as *const u8, sizeof(usize)));
        out.push_string(&code);
    } else {
        let mut r = Compiled {};
        check_from(unsafe &mut (*s).p, from, stop, as_std, &mut r);
        out.push_str(unsafe str::from_raw(((&r) as *const Compiled) as *const u8, sizeof(Compiled)));
    }
    let mut at: usize = 0;
    while at < out.len() {
        let put = unsafe unistd::write(fd, out.as_ptr() + at, out.len() - at);
        if put < 0 && errno::errno() != EINTR {
            panic("harness: write to the compile pipe failed");
        }
        if put > 0 {
            at = at + put as usize;
        }
    }
    let _ = unsafe unistd::close(fd);
    let _snap = unsafe *s;
}
