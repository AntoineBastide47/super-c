// In-process compile driver for the self-hosted test suite -- the analog of tests/test_harness.h's
// `sc_compile`. Given a source STRING it runs the real selfhost pipeline (lexer -> parser -> resolver ->
// typechecker) against a freshly-loaded std prelude and reports the user module's error count + first
// message, so resolver/typechecker/errors/borrow tests can assert accept-vs-reject and diagnostics.
//
// The prelude is found at "std" relative to the CWD (the repo root, where `make selfhost-test` runs),
// matching tests/test_harness.h's default SUPERC_STD_DIR. The snippet is loaded from memory via
// loader::package_from_source as the LAST module (after the prelude, module id past it -- exactly like
// the C harness's sc_compile layout, so module-order-sensitive checks reproduce the C verdicts).
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
import driver_shim as shim;
import tests::cli_harness as cli;

import stdio;
import stdlib;
import string as cstring;

// `tmpfile` (an anonymous, auto-removed temp stream) is declared in <stdio.h>, which super_rt always
// includes -- so a bare extern binding resolves without needing a header string.
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

pub const STAGE_PARSE: i32 = 0;
pub const STAGE_RESOLVE: i32 = 1;
pub const STAGE_TYPECHECK: i32 = 2;

// A stage result: how many errors the USER module produced, at which stage, and the first message text
// (copied out before the compiler frees it). `ok()` is the accept/reject verdict the oracle asserts on.
pub struct Compiled {
    pub errors: usize,
    pub stage: i32,
    pub first: [char; 512],
}

extend Compiled {
    pub const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    // Whether the first error message contains `needle` (matched as a substring).
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

// Run `src` through the pipeline up to `stop`, reporting the user module (index 0) diagnostics.
pub fn compile(src: str, stop: i32) Compiled {
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
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;

    let n = p.modules.len();
    let uidx = n - 1; // the user module is loaded last, after the prelude
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
    if r.errors == 0 {
        for i in 0..n {
            h_borrowck(&mut p, i, uidx, &mut r);
        }
    }
    if r.errors != 0 {
        r.stage = STAGE_TYPECHECK;
    }
    return r;
}

// Lex + parse a source standalone (no package/prelude) and hand back the AST for shape inspection.
// `errors` > 0 means the snippet failed to lex or parse. RAII frees the AST with the result.
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
pub struct CompiledAst {
    pub errors: usize,
    pub stage: i32,
    pub ast: Ast,
}

extend CompiledAst as Free {
    pub fn free(self: &mut CompiledAst) {
        self.ast.free();
    }
}

pub fn compile_ast(src: str, stop: i32) CompiledAst {
    let mut out = CompiledAst { errors: 0, stage: stop, ast: Ast::new(0) };
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    if !p.ok {
        out.errors = 1;
        out.stage = STAGE_PARSE;
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
    if rr.errors == 0 && stop != STAGE_RESOLVE {
        for i in 0..n {
            h_typecheck(&mut p, i, uidx, &mut rr);
        }
    }
    out.errors = rr.errors;
    // Detach the user module's AST so package_free leaves it alone; the caller frees it.
    out.ast = replace(&mut p.modules[uidx].ast, Ast::new(0));
    return out;
}

// Inspection helpers over a returned AST (mirror tests/test_harness.h's th_* / ast_resolution).
// The n-th node (0-based) of the given kind, in creation order; NODE_NONE if fewer than n+1 exist.
pub fn nth_kind(a: &Ast, kind: NodeKind, nth: usize) NodeId {
    let mut seen: usize = 0;
    let mut id: NodeId = 1;
    while id as usize < a.nodes.len() {
        if a.at_const(id).kind == kind {
            if seen == nth {
                return id;
            }
            seen = seen + 1;
        }
        id = id + 1;
    }
    return NODE_NONE;
}

// True if node `id` is a NODE_IDENTIFIER whose source text equals `name` (a NUL-terminated cstring).
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
// length first, so it works both for a just-written temp stream and a freshly-opened file (position 0).
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

// The generated C for the user snippet (module 0's header + .c concatenated), for substring inspection --
// the analog of tests/test_harness.h's sc_codegen. `code` is owned (call `.free()`).
pub struct CompiledC {
    pub errors: usize,
    pub code: *mut char,
}

extend CompiledC {
    pub const fn ok(self: &Self) bool {
        return self.errors == 0;
    }
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
    for i in 0..n {
        h_borrowck(&mut p, i, uidx, &mut rr);
    }
    if rr.errors != 0 {
        out.errors = rr.errors;
        return out;
    }
    // Whole-package emission through the production backend: every shared header plus every TU,
    // concatenated so prelude definitions (`str`, monomorphized Slice/Box, ...) are inspectable.
    let tplan = dtest::TestPlan::new(n);
    let mut o = demit::CemitOut::new(n);
    demit::cemit_package(&mut p, false, &tplan, null, -1, &mut o, null);
    if o.skips != 0 {
        out.errors = o.skips as usize;
        return out;
    }
    let mut code = String::new();
    if user_only {
        code.push_string(o.tus.at(uidx));
    } else {
        code.push_string(&o.types_h);
        code.push_string(&o.protos_h);
        for t in 0..n {
            code.push_string(o.tus.at(t));
        }
        code.push_string(&o.inst_c);
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

// ---- compile-and-run: build a snippet into a real program and execute it (for behavior tests) ----------
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

// Build `src` into a standalone program via `super-c build`, run it, and capture stdout+stderr + exit code.
// The compiler is $SUPERC (default "./super-c", matching the CWD=repo-root that `make selfhost-test` uses).
// Each snippet gets its own temp dir (<tmp>/scr_<pid>_<seq>) so build trees never collide -- fork-per-test
// safe. No shell is involved: the process runner binds the output file and applies `env` itself, which is
// what lets these tests run on Windows.
pub fn compile_and_run(src: str) RunResult {
    return compile_and_run_env(src, "");
}

// As compile_and_run, but with `env` ("VAR=v " assignments, trailing space) prefixed to the run command.
pub fn compile_and_run_env(src: str, env: str) RunResult {
    let mut r = RunResult { built: false, exit: -1, out: null };
    unsafe R_SEQ = unsafe R_SEQ + 1; // process-local: one forked process per test, and the name carries the pid
    let pid = unsafe shim::sc_getpid();
    let mut dir = Path256 {};
    unsafe stdio::snprintf(
        &mut dir.b[0],
        256,
        "%s/scr_%d_%llu".ptr() as *const char,
        unsafe shim::sc_tmpdir(),
        pid,
        unsafe R_SEQ,
    );
    let dirp = (&dir.b[0]) as *const char;
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
    let brc = unsafe shim::sc_run(&cmd.b[0], null, null, null, null);
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
// `sc_run_program(name, src, code, "")` -- the program signals its result via `exit(code)`).
pub fn expect_exit(label: str, src: str, code: i32) {
    let r = compile_and_run(src);
    assert(r.built, label);
    assert_eq(r.exit, code);
}

// Require the snippet to compile cleanly AND its generated C to contain `needle`.
pub fn expect_c(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(c.code_has(needle), label);
}
// Require the snippet to compile cleanly AND its generated C to NOT contain `needle`.
pub fn expect_c_absent(label: str, src: str, needle: str) {
    let c = compile_c(src);
    assert(c.ok(), label);
    assert(!c.code_has(needle), label);
}

// expect_ok / expect_err: the accept-vs-reject oracle for semantic tests.
pub fn expect_ok(label: str, src: str) {
    let c = compile(src, STAGE_TYPECHECK);
    assert(c.ok(), label);
}
pub fn expect_resolve_ok(label: str, src: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(c.ok(), label);
}
// Reject at the given stage AND require the first message to contain `needle`.
pub fn expect_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_TYPECHECK);
    assert(!c.ok(), label);
    assert(c.msg_has(needle), label);
}
pub fn expect_resolve_err_msg(label: str, src: str, needle: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(!c.ok(), label);
    assert(c.msg_has(needle), label);
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
            unsafe out.errors = c;
            unsafe copy_msg(&mut out.first[0], rr.errors.rendered_errors.at(0));
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
            unsafe out.errors = c;
            unsafe copy_msg(&mut out.first[0], t.errors.rendered_errors.at(0));
        }
    }
}

// Mirror the driver's borrowck_module: a SEPARATE stage after every module is typed (import cycles
// mean a body's callees can live in a later module, so the checker may only run once all types exist).
fn h_borrowck(p: &mut loader::Package, i: usize, cap: usize, out: *mut Compiled) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.borrowck_solo();
    if i == cap {
        let c = t.errors.errors.len();
        if c > 0 {
            unsafe out.errors = c;
            unsafe copy_msg(&mut out.first[0], t.errors.rendered_errors.at(0));
        }
    }
}
