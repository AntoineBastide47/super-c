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
import ir::lower as irl;
import borrowck::facts as bfx;
import borrowck::flow_ir as bfi;
import driver_shim as shim;
import lsp::json as json;
import tests::cli_harness as cli;

import stdio;
import stdlib;
import string as cstring;

// `tmpfile` (an anonymous, auto-removed temp stream) is declared in <stdio.h>, which super_rt always
// includes, so a bare extern binding resolves without needing a header string.
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

/// Pipeline stages `compile` can stop after.
pub const STAGE_PARSE: i32 = 0;
pub const STAGE_RESOLVE: i32 = 1;
pub const STAGE_TYPECHECK: i32 = 2;

// A stage result: how many errors the USER module produced, at which stage, and the first message text
// (copied out before the compiler frees it). `ok()` is the accept/reject verdict the oracle asserts on.
/// Outcome of an in-process compile: error count and the first message.
pub struct Compiled {
    pub errors: usize,
    pub stage: i32,
    pub first: [char; 512],
}

extend Compiled {
    /// True when no error was reported.
    pub const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    // Whether the first error message contains `needle` (matched as a substring).
    /// True when the first diagnostic contains `needle`.
    pub fn msg_has(self: &Self, needle: str) bool {
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
pub fn compile_std(src: str, arch: i32, stop: i32) Compiled {
    return compile_in(src, stop, true, arch);
}

// Run `src` through the pipeline up to `stop`, reporting the user module (index 0) diagnostics.
/// Compile `src` in process through stage `stop` (STAGE_*), collecting diagnostics.
pub fn compile(src: str, stop: i32) Compiled {
    return compile_in(src, stop, false, -1);
}

fn compile_in(src: str, stop: i32, as_std: bool, arch: i32) Compiled {
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
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;

    let n = p.modules.len();
    let uidx = n - 1; // the user module is loaded last, after the prelude
    if as_std {
        p.modules[uidx].path = String::from_str("std::harness");
        p.modules[uidx].file = loader::join2(p.std_root.as_str(), "std/harness.spc");
    }
    // Resolve every module (prelude first, user last); snapshot the user module's diagnostics.
    for i in 0..n {
        h_resolve(&mut p, i, uidx, &mut r);
    }
    if r.errors != 0 || stop == STAGE_RESOLVE {
        if r.errors != 0 {
            r.stage = STAGE_RESOLVE;
        }
        return r;
    }
    // Typecheck every module; snapshot the user module's diagnostics. Borrowck follows as its own
    // pass over the fully typed package, exactly like the driver.
    for i in 0..n {
        h_typecheck(&mut p, i, uidx, &mut r);
    }
    if r.errors == 0 && as_std {
        let te = demit::build_simd_table(&mut p, n);
        if te.len() != 0 {
            r.errors = 1;
            copy_msg(&mut r.first[0], &te);
        }
    }
    if r.errors == 0 {
        demit::publish_checkpoint(&mut p, null);
        for i in 0..n {
            h_borrowck(&mut p, i, uidx, &mut r, null);
        }
    }
    if r.errors != 0 {
        r.stage = STAGE_TYPECHECK;
    }
    return r;
}

// Lex + parse a source standalone (no package/prelude) and hand back the AST for shape inspection.
// `errors` > 0 means the snippet failed to lex or parse. RAII frees the AST with the result.
/// A parsed module kept alive for AST inspection (formatter path when trivia is kept).
pub struct ParsedAst {
    pub errors: usize,
    pub ast: Ast,
}

extend ParsedAst as Free {
    pub fn free(self: &mut ParsedAst) {
        self.ast.free();
    }
}

pub fn parse_ast(src: str) ParsedAst {
    return parse_ast_opt(src, true);
}

// The formatter's parse: `@derive` stays attribute trivia (no synthesized extends), exactly as
// format_source parses.
/// Parse `src` keeping comment tokens, as the formatter does.
pub fn parse_ast_for_fmt(src: str) ParsedAst {
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
pub fn parse_has_error(src: str) bool {
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
pub struct CompiledAst {
    pub errors: usize,
    pub stage: i32,
    pub ast: Ast,
    pub pkg: loader::Package, // `ast` reads its types through the package table: the package outlives it
}

pub fn compile_ast(src: str, stop: i32) CompiledAst {
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
pub fn nth_kind(a: &Ast, kind: NodeKind, nth: usize) NodeId {
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
pub fn ident_is(a: &Ast, src: *const char, id: NodeId, name: *const char) bool {
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
pub struct CompiledC {
    pub errors: usize,
    pub code: *mut char,
}

extend CompiledC {
    pub const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    /// True when the emitted C contains `needle`.
    pub fn code_has(self: &Self, needle: str) bool {
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

// Run the full pipeline and emit module 0 to a string. On any pre-codegen error, `errors` is set and
// `code` is null; codegen-stage diagnostics also set `errors` but the (partial) code is still returned.
pub fn compile_c(src: str) CompiledC {
    return compile_c_of(src, false);
}
/// Only the user snippet's own translation unit (needle absence must not trip on std code).
pub fn compile_c_user(src: str) CompiledC {
    return compile_c_of(src, true);
}
fn compile_c_of(src: str, user_only: bool) CompiledC {
    let mut out = CompiledC { errors: 0, code: null };
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    if !p.ok {
        out.errors = 1;
        return out;
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
    if rr.errors == 0 {
        for i in 0..n {
            h_typecheck(&mut p, i, uidx, &mut rr);
        }
    }
    if rr.errors != 0 {
        out.errors = rr.errors;
        return out;
    }
    let mut keep = irl::Keep::new();
    demit::publish_checkpoint(&mut p, &mut keep);
    for i in 0..n {
        h_borrowck(&mut p, i, uidx, &mut rr, &mut keep);
    }
    if rr.errors != 0 {
        out.errors = rr.errors;
        return out;
    }
    // Whole-package emission through the production backend: every shared header plus every TU,
    // concatenated so prelude definitions (`str`, monomorphized Slice/Box, ...) are inspectable.
    let tplan = dtest::TestPlan::new(n);
    let mut o = demit::CemitOut::new(n);
    demit::cemit_package(&mut p, false, &tplan, null, -1, &mut o, &mut keep);
    if o.skips != 0 {
        out.errors = o.skips as usize;
        return out;
    }
    let mut code = String::new();
    if !user_only {
        code.push_string(&o.fwd_h);
        code.push_string(&o.ext_h);
        for d in 0..o.defs_h.len() {
            code.push_string(o.defs_h.at(d));
        }
        for t in 0..n {
            code.push_string(o.protos_h.at(t));
        }
    }
    // A TU is its part heads, the shared body buffer, then the tail; the file writer interleaves
    // them per part, the needle search only needs every byte present.
    for t in 0..n {
        if user_only && t != uidx {
            continue;
        }
        for x in 0..o.tu_heads.at(t).len() {
            code.push_string(o.tu_heads.at(t).at(x));
        }
        code.push_string(o.tus.at(t));
        code.push_string(o.tu_tail.at(t));
    }
    if !user_only {
        for q in 0..n {
            for x in 0..o.inst_heads.at(q).len() {
                code.push_string(o.inst_heads.at(q).at(x));
            }
        }
        code.push_string(&o.inst_c);
        code.push_string(&o.registry_c);
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

// Path scratch buffers (`{}` zero-fills; no `[v;N]` repeat literal).
struct Path256 {
    pub b: [char; 256],
}
struct Path512 {
    pub b: [char; 512],
}
struct Path1024 {
    pub b: [char; 1024],
}

static mut R_SEQ: u64 = 0;

// The captured result of compiling+running a snippet: whether it built, its exit code, and stdout+stderr.
/// Outcome of compiling and running a snippet: whether it built, its exit code, and captured output.
pub struct RunResult {
    pub built: bool,
    pub exit: i32,
    pub out: *mut char,
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
    let f = stdio::fopen(str::from_cstr(path), "rb");
    if f == null {
        return null;
    }
    let buf = read_stream(f);
    unsafe stdio::fclose(f);
    return buf;
}

fn rm_dir(dir: *const char) {
    let _ = unsafe shim::sc_rm_rf(dir);
}

/// Build `src` as a program and run it, capturing stdout.
pub fn compile_and_run(src: str) RunResult {
    return compile_and_run_env(src, "");
}

// As compile_and_run, but with `env` ("VAR=v " assignments, trailing space) prefixed to the run command.
/// `compile_and_run` with `env` (space-separated NAME=VALUE) applied to the program.
pub fn compile_and_run_env(src: str, env: str) RunResult {
    let mut r = RunResult { built: false, exit: -1, out: null };
    // Process-local: one forked process per test, and the name carries the pid.
    unsafe R_SEQ = unsafe R_SEQ + 1;
    let pid = unsafe shim::sc_getpid();
    let mut dir = Path256 {};
    unsafe stdio::snprintf(
        &mut dir.b[0],
        256,
        "%s/scr_%d_%llu_%llu".ptr() as *const char,
        unsafe shim::sc_tmpdir(),
        pid,
        unsafe R_SEQ,
        (unsafe shim::sc_ticks_ms()) as u64,
    );
    let dirp = (&dir.b[0]) as *const char;
    rm_dir(dirp); // a directory an aborted test left under a reused pid
    if unsafe shim::sc_mkdir_p(dirp) != 0 {
        return r;
    }
    let mut spc = Path512 {};
    unsafe stdio::snprintf(&mut spc.b[0], 512, "%s/main.spc".ptr() as *const char, dirp);
    let wf = stdio::fopen(str::from_cstr(&spc.b[0]), "wb"); // binary: no Windows CRLF in emitted .spc sources
    if wf == null {
        rm_dir(dirp);
        return r;
    }
    if src.len() > 0 {
        let _ = unsafe stdio::fwrite(src.ptr(), 1, src.len(), wf);
    }
    unsafe stdio::fclose(wf);
    let mut cmd = Path1024 {};
    unsafe stdio::snprintf(
        &mut cmd.b[0],
        1024,
        "\"%s\" build %s \"%s/main.spc\" -o \"%s/prog%s\"".ptr() as *const char,
        cli::superc_path().ptr() as *const char,
        cli::cstd_flag(),
        dirp,
        dirp,
        cli::binext(),
    );
    let mut benv = cli::fixture_cache_env(str::from_cstr(dirp));
    let brc = unsafe shim::sc_run(&cmd.b[0], null, null, null, benv.cstr());
    if brc != 0 {
        rm_dir(dirp);
        return r;
    } // did not build
    r.built = true;
    unsafe stdio::snprintf(&mut cmd.b[0], 1024, "\"%s/prog%s\"".ptr() as *const char, dirp, cli::binext());
    let mut outp = Path512 {};
    unsafe stdio::snprintf(&mut outp.b[0], 512, "%s/out".ptr() as *const char, dirp);
    // `env` is a view with no terminator: copy it before it crosses into C.
    let mut envb = Path512 {};
    unsafe stdio::snprintf(&mut envb.b[0], 512, "%.*s".ptr() as *const char, env.len() as i32, env.ptr());
    r.exit = unsafe shim::sc_run(&cmd.b[0], null, &outp.b[0], null, &envb.b[0]);
    let mut op = Path512 {};
    unsafe stdio::snprintf(&mut op.b[0], 512, "%s/out".ptr() as *const char, dirp);
    r.out = slurp(&op.b[0]);
    rm_dir(dirp);
    return r;
}

// Build+run `src` and require it to terminate with exit code `code` (the analog of tests/codegen_run's
// `sc_run_program(name, src, code, "")`: the program signals its result via `exit(code)`).
/// Assert that `src` builds and exits with `code`, naming `label` on failure.
pub fn expect_exit(label: str, src: str, code: i32) {
    let r = compile_and_run(src);
    assert(r.built, label);
    assert_eq(r.exit, code);
}

// Require the snippet to compile cleanly AND its generated C to contain `needle`.
/// Assert that `src` emits C containing `needle`.
pub fn expect_c(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(c.code_has(needle), label);
}
// Require the snippet to compile cleanly AND its generated C to NOT contain `needle`.
/// Assert that `src` emits C not containing `needle`.
pub fn expect_c_absent(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(!c.code_has(needle), label);
}

// expect_ok / expect_err: the accept-vs-reject oracle for semantic tests.
/// Assert that `src` typechecks without errors.
pub fn expect_ok(label: str, src: str) {
    let c = compile(src, STAGE_TYPECHECK);
    assert(c.ok(), label);
}
/// Assert that `src` resolves without errors.
pub fn expect_resolve_ok(label: str, src: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(c.ok(), label);
}
// Reject at the given stage AND require the first message to contain `needle`.
/// Assert that typechecking `src` reports an error containing `needle`.
pub fn expect_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_TYPECHECK);
    if !c.msg_has(needle) {
        eprintln("{}: the first error is: {}", label, str::from_cstr(&c.first[0]));
    }
    assert(!c.ok(), label);
    assert(c.msg_has(needle), label);
}
/// Assert that resolving `src` reports an error containing `needle`.
pub fn expect_resolve_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_RESOLVE);
    if !c.msg_has(needle) {
        eprintln("{}: the first error is: {}", label, str::from_cstr(&c.first[0]));
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
pub struct DiffBuild {
    pub proj: cli::Proj,
    pub built: bool,
    pub diag: String,
    pub wasm: bool,
}

// The vector conformance lane, `SC_SIMD_LANE=wasm` (a wasi-sdk in WASI_SDK_PATH, wasmtime on the
// PATH): every differential program builds for wasm32 with `+simd128` and runs under wasmtime, and
// `expect_run` also builds it without the feature and requires the same results. -1 until read; the
// runner forks one process per test, so the cache is never shared.
static mut SIMD_LANE: i32 = -1;

/// Whether the vector conformance lane is on (`SC_SIMD_LANE=wasm`).
pub fn simd_lane() bool {
    if unsafe SIMD_LANE < 0 {
        let e = stdlib::getenv("SC_SIMD_LANE");
        unsafe SIMD_LANE = (e != null && str::from_cstr(e) == "wasm") as i32;
    }
    return unsafe SIMD_LANE == 1;
}

/// One run of a differential program: exit code, stdout and stderr.
pub struct DiffRun {
    pub exit: i32,
    pub out: String,
    pub err: String,
}

/// Build `src` as main.spc of a scratch project. An option of the form NAME=VALUE sets that
/// environment variable for the build (`SC_BCE=0`); any other option is one build flag. The project
/// defines `--profile=ubsan`, unoptimized with UndefinedBehaviorSanitizer only, for a large program
/// run many times: it compiles in about half the dev profile's time, and ASan's start-up makes each
/// run several times slower.
pub fn diff_build(src: str, opts: []str) DiffBuild {
    let exe = cli::superc_path(); // resolved before the chdir below
    let p = cli::proj_new();
    // wasm32 has no UndefinedBehaviorSanitizer runtime, and a large unoptimized function can pass
    // the engines' limit of locals: the lane's `ubsan` profile optimizes lightly.
    p.mkfile(
        "build.toml",
        if simd_lane() {
            "bin = \"prog\"\nroot = \"main.spc\"\n\n[profile.ubsan]\nopt-level = 1\n";
        } else {
            "bin = \"prog\"\nroot = \"main.spc\"\n\n[profile.ubsan]\nopt-level = 0\ncflags = [\"-fsanitize=undefined\"]\nldflags = [\"-fsanitize=undefined\"]\n";
        },
    );
    p.mkfile("main.spc", src);
    let mut root = String::from_str(str::from_cstr(p.rootp()));
    let mut cmd = String::new();
    cmd.format_into("\"{}\" build", exe);
    let mut env = cli::fixture_cache_env(root.as_str());
    let mut wasm = simd_lane();
    if wasm {
        cmd.push_str(" --target=wasm --target-feature=+simd128");
    }
    for o in opts {
        wasm = wasm || o == "--target=wasm";
        if o.starts_with("-") {
            cmd.format_into(" \"{}\"", o);
        } else {
            env.push_byte(b' ');
            env.push_str(o);
        }
    }
    if cli::on_wasm() {
        cmd.format_into(" \"--transpiler={}\"", exe);
    }
    cmd.format_into(" -o prog{}", str::from_cstr(cli::binext()));
    let mut outp = String::new();
    outp.format_into("{}/.build", root.as_str());
    // The engine reads build.toml from its working directory.
    let mut rc = -1;
    if unsafe shim::sc_chdir(root.cstr()) == 0 {
        rc = unsafe shim::sc_run(cmd.cstr(), null, outp.cstr(), null, env.cstr());
    }
    return DiffBuild { proj: p, built: rc == 0, diag: cli::read_text(outp.as_str()), wasm: wasm };
}

/// Assert that the build of `src` fails with a diagnostic containing `needle`, before its C compile.
pub fn expect_build_err(label: str, src: str, needle: str) {
    let b = diff_build(src, []);
    let ok = !b.built && b.diag.contains(needle) && !b.diag.contains("C compile failed") && !b.diag.contains("internal");
    if !ok {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(ok, label);
}

/// Assert that `src` builds and its run with argument `arg` traps with `msg` on stderr, or exits 0
/// when `msg` is empty; a sanitizer report fails it either way.
pub fn expect_run(label: str, src: str, arg: str, msg: str) {
    if simd_lane() {
        // The scalar lowering and the hardware entries give the same results.
        let d = same_output(src, ["--target-feature=-simd128"], [], [arg]);
        if d.len() != 0 {
            eprintln("{}: scalar and +simd128: {}", label, d.as_str());
        }
        assert(d.len() == 0, label);
    }
    let b = diff_build(src, []);
    if !b.built {
        eprintln("{}: {}", label, b.diag.as_str());
    }
    assert(b.built, label);
    let r = diff_run(&b, arg);
    let ok = !r.err.contains("runtime error:") && !r.err.contains("Sanitizer") && if msg.len() == 0 {
        r.exit == 0;
    } else {
        r.exit != 0 && r.err.contains(msg);
    };
    if !ok {
        eprintln("{}: exit {}: {}{}", label, r.exit, r.out.as_str(), r.err.as_str());
    }
    assert(ok, label);
}

/// Run the program `b` built with `args` (a command-line fragment) and capture its output.
pub fn diff_run(b: &DiffBuild, args: str) DiffRun {
    let root = str::from_cstr(b.proj.rootp());
    let mut cmd = String::new();
    if b.wasm {
        // Relaxed SIMD runs deterministically: a result never depends on the host.
        cmd.format_into("wasmtime run -W relaxed-simd-deterministic=y --dir=\"{}\" \"{}/prog\" {}", root, root, args);
    } else {
        cmd.format_into("\"{}/prog{}\" {}", root, str::from_cstr(cli::binext()), args);
    }
    let mut outp = String::new();
    outp.format_into("{}/.out", root);
    let mut errp = String::new();
    errp.format_into("{}/.err", root);
    let exit = unsafe shim::sc_run(cmd.cstr(), null, outp.cstr(), errp.cstr(), null);
    return DiffRun { exit: exit, out: cli::read_text(outp.as_str()), err: cli::read_text(errp.as_str()) };
}

/// The trap lines of a run's stderr: the runtime's `super-c: ...` and std's `panic: ...` messages.
/// Backtraces and other diagnostics are not part of the trap text.
pub fn trap_text(err: str) String {
    let mut t = String::new();
    for line in err.lines() {
        if line.starts_with("super-c: ") || line.starts_with("panic: ") {
            t.push_str(line);
            t.push_byte(b'\n');
        }
    }
    return t;
}

// A sanitizer finding is a defect on its own, whatever the other side of a comparison printed.
fn sanitizer_report(err: str) bool {
    return err.contains("runtime error:") || err.contains("Sanitizer");
}

/// Build `src` under `opts_a` and under `opts_b`, run both once per entry of `runs` (each entry is the
/// command-line arguments of one run), and describe the first difference in exit code, stdout or trap
/// text. Empty when every run agrees. A build failure or a sanitizer report is a difference.
pub fn same_output(src: str, opts_a: []str, opts_b: []str, runs: []str) String {
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
    for args in runs {
        let ra = diff_run(&a, args);
        let rb = diff_run(&b, args);
        if sanitizer_report(ra.err.as_str()) || sanitizer_report(rb.err.as_str()) {
            r.format_into(
                "run '{}': sanitizer report\nA stderr:\n{}B stderr:\n{}",
                args,
                ra.err.as_str(),
                rb.err.as_str(),
            );
            return r;
        }
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
pub fn expect_same_output(label: str, src: str, opts_a: []str, opts_b: []str) {
    let d = same_output(src, opts_a, opts_b, [""]);
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

/// The trap class a compile-time error names for a trap ("arithmetic overflow", "division by zero",
/// "shift out of range"), or the text from `lane <i>: ` of a vector operation's trap, the same at run
/// time; empty for any other error.
pub fn const_trap_class<'a>(msg: str<'a>) str<'a> {
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

/// The trap class of a run-time trap message (`rt_c.spc` arithmetic and index helpers), in the words a constant
/// reports for the same trap, or the text from `lane <i>: ` of a vector operation's trap; empty for any
/// other trap.
pub fn runtime_trap_class<'a>(trap: str<'a>) str<'a> {
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
    s.push_str("@c.noinline\nconst fn opq<T>(x: T) T {\n    return x;\n}\n");
    // A write to a static is a side effect no constant evaluation performs: the compiler cannot see
    // through `opr`, so the run-time copy computes at run time and its traps are not compile errors.
    s.push_str("static mut PARITY_SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n");
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
        s.format_into("@c.noinline\nfn parity_r{}() {} {{\n    return {};\n}}\n", k, tys[k], rt.as_str());
    }
    s.push_str("fn main(args: Vector<str>) i32 {\n    let k = args.at(1).parse_i64().unwrap();\n");
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
    s.push_str("    return 0;\n}\n");
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
fn parity_value<'a>(out: str<'a>, tag: str) str<'a> {
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
/// `const fn opq`, the run-time copy calls `@c.noinline fn opr`, which the compiler cannot see
/// through. The program defines `opq`, `opr` and names starting with `parity_`, `Parity` and `PARITY_`.
pub fn const_runtime_parity(decls: str, exprs: []str, tys: []str, opts: []str) String {
    assert(exprs.len() == tys.len());
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
    for k in 0..n {
        let mut arg = String::new();
        arg.push_u64(k as u64);
        let run = diff_run(&b, arg.as_str());
        let trap = trap_text(run.err.as_str());
        let mut want = String::new();
        if omit[k] {
            want.format_into("trap: {}", ct.at(k).as_str());
        } else {
            want.format_into("value {}", parity_value(run.out.as_str(), "c"));
        }
        let mut got = String::new();
        if sanitizer_report(run.err.as_str()) {
            got.format_into("sanitizer report:\n{}", run.err.as_str());
        } else if run.exit == 0 {
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

/// The program `const_runtime_parity` builds first, with every constant.
pub fn parity_program(decls: str, exprs: []str, tys: []str) String {
    let mut omit = Vector::<bool>::new();
    for _ in 0..exprs.len() {
        omit.push(false);
    }
    let mut first: usize = 0;
    return parity_source(decls, exprs, tys, &omit, &mut first);
}

/// Assert that `expr` of type `ty` under `decls` has the same value or trap as a constant and at run
/// time (see `const_runtime_parity`).
pub fn expect_const_runtime_parity(label: str, decls: str, expr: str, ty: str) {
    let d = const_runtime_parity(decls, [expr], [ty], []);
    if d.len() != 0 {
        eprintln("{}: {}", label, d.as_str());
    }
    assert(d.len() == 0, label);
}

// True when C file `path` defines `function`: a line naming ` function(` that opens its body.
fn c_defines(path: str, function: str) bool {
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

fn asm_label_is(line: str, function: str) bool {
    return line.starts_with(function) && line.slice(function.len(), line.len()).starts_with(":");
}

/// The instruction mnemonics of `function` in assembly text `text`: the first word of each line from
/// the function's label (`name:` or Mach-O `_name:`) to the end of its body, without directives,
/// labels and comments. Empty when the label is absent.
pub fn asm_mnemonics(text: str, function: str) Vector<String> {
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
            names.push(String::from_str(word));
        }
    }
    return names;
}

/// Build `src` with `opts` (`diff_build` forms), compile the translation unit that defines C function
/// `function` with the build's own C command plus `-S` (without `-c`, `-MMD` and LTO, which would
/// print IR), and check its instruction mnemonics: every `contains` entry is a substring of one, no
/// `absent` entry is a substring of any. Mnemonics only: register names never match. Describes every
/// failed check; empty when all hold.
pub fn asm_check(src: str, opts: []str, function: str, contains: []str, absent: []str) String {
    let mut r = String::new();
    let b = diff_build(src, opts);
    if !b.built {
        r.format_into("the program does not build:\n{}", b.diag.as_str());
        return r;
    }
    let mut prof = "dev";
    for o in opts {
        if o.starts_with("--profile=") {
            prof = o.slice(10, o.len());
        }
    }
    let root = str::from_cstr(b.proj.rootp());
    let mut dbp = String::new();
    dbp.format_into("{}/build/{}/compile_commands.json", root, prof);
    let text = cli::read_text(dbp.as_str());
    let parsed = json::parse(text.as_str());
    if parsed.is_err() {
        r.format_into("cannot read {}", dbp.as_str());
        return r;
    }
    let db = parsed.unwrap();
    let mut cmd = String::new();
    let mut dir = String::new();
    let mut asmp = String::new();
    asmp.format_into("{}/function.s", root);
    for i in 0..db.size() {
        let row = db.at(i);
        let file = row.value_str("file");
        let mut path = String::new();
        if !file.starts_with("/") && !(file.len() > 1 && file.byte_at(1) == b':') {
            path.push_str(row.value_str("directory"));
            path.push_byte(b'/');
        }
        path.push_str(file);
        if !c_defines(path.as_str(), function) {
            continue;
        }
        dir.push_str(row.value_str("directory"));
        let args = row.at_key("arguments");
        let mut skip_next = false;
        for j in 0..args.size() {
            let a = args.at(j).get_str();
            if skip_next {
                skip_next = false;
                continue;
            }
            if a == "-o" {
                skip_next = true;
                continue;
            }
            if a == "-c" || a == "-MMD" || a.starts_with("-flto") {
                continue;
            }
            if cmd.len() != 0 {
                cmd.push_byte(b' ');
            }
            cmd.format_into("\"{}\"", a);
        }
        cmd.format_into(" -S -o \"{}\"", asmp.as_str());
        break;
    }
    if cmd.len() == 0 {
        r.format_into("no translation unit defines '{}'", function);
        return r;
    }
    let mut outp = String::new();
    outp.format_into("{}/.asm", root);
    let mut rc = -1;
    if unsafe shim::sc_chdir(dir.cstr()) == 0 {
        rc = unsafe shim::sc_run(cmd.cstr(), null, outp.cstr(), null, null);
    }
    if rc != 0 {
        r.format_into("'{}' failed:\n{}", cmd.as_str(), cli::read_text(outp.as_str()).as_str());
        return r;
    }
    let names = asm_mnemonics(cli::read_text(asmp.as_str()).as_str(), function);
    if names.len() == 0 {
        r.format_into("no instructions of '{}' in the assembly", function);
        return r;
    }
    for want in contains {
        let mut found = false;
        for i in 0..names.len() {
            found = found || names.at(i).contains(want);
        }
        if !found {
            r.format_into("no instruction of '{}' contains '{}'\n", function, want);
        }
    }
    for bad in absent {
        for i in 0..names.len() {
            if names.at(i).contains(bad) {
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
pub fn expect_asm(label: str, src: str, opts: []str, function: str, contains: []str, absent: []str) {
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
    let mut rr = res::Resolver::new(unsafe &mut *aptr, str::from_raw(src as *const u8, len), pkg);
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
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
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
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
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
