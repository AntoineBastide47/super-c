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
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import codegen::codegen as cg;
import module::loader as loader;
import consteval::consteval as ce;
import driver_shim as shim;

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
    pub fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    // Whether the first error message contains `needle` (matched as a substring).
    pub fn msg_has(self: &Self, needle: str) bool {
        return unsafe cstring::strstr(&self.first[0], needle.ptr() as *const char) != null;
    }
}

// Copy at most 511 bytes of `s` into dst[512], NUL-terminated (dst is pre-zeroed by the caller).
fn copy_msg(dst: *mut char, s: &String) {
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
            copy_msg(&mut r.first[0], lx.errors.errors.at(0));
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
            copy_msg(&mut r.first[0], ps.errors.errors.at(0));
        }
        return r;
    }
    if stop == STAGE_PARSE {
        return r;
    }

    // Semantic stages need the prelude: load the snippet as module 0 alongside std, exactly like the CLI.
    let mut p = loader::package_from_source(src.ptr() as *const char, src.len(), "std".ptr() as *const char);
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;

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
    // Typecheck every module; snapshot the user module's diagnostics.
    for i in 0..n {
        h_typecheck(&mut p, i, uidx, &mut r);
    }
    if r.errors != 0 {
        r.stage = STAGE_TYPECHECK;
    }
    return r;
}

// Lex + parse a source standalone (no package/prelude) and hand back the AST for shape inspection.
// `errors` > 0 means the snippet failed to lex or parse. The AST is owned by the caller (`.free()`).
pub struct ParsedAst {
    pub errors: usize,
    pub ast: Ast,
}

pub fn parse_ast(src: str) ParsedAst {
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

// A stage result that also hands back the user module's (resolved/typed) AST for target inspection.
// The AST is owned by the caller (call `.free()`); span text is looked up against the caller's own
// source literal, which outlives this call.
pub struct CompiledAst {
    pub errors: usize,
    pub stage: i32,
    pub ast: Ast,
}

pub fn compile_ast(src: str, stop: i32) CompiledAst {
    let mut out = CompiledAst { errors: 0, stage: stop, ast: Ast::new(0) };
    let mut p = loader::package_from_source(src.ptr() as *const char, src.len(), "std".ptr() as *const char);
    if !p.ok {
        out.errors = 1;
        out.stage = STAGE_PARSE;
        return out;
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
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
    let a = p.modules[uidx].ast;
    p.modules[uidx].ast = Ast::new(0);
    out.ast = a;
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
    pub fn ok(self: &Self) bool {
        return self.errors == 0;
    }
    pub fn code_has(self: &Self, needle: str) bool {
        if self.code == null {
            return false;
        }
        return unsafe cstring::strstr(self.code, needle.ptr() as *const char) != null;
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
    let mut out = CompiledC { errors: 0, code: null };
    let mut p = loader::package_from_source(src.ptr() as *const char, src.len(), "std".ptr() as *const char);
    if !p.ok {
        out.errors = 1;
        return out;
    }
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
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
    loader::package_propagate_instances(&mut p);
    let f = unsafe tmpfile();
    if f == null {
        out.errors = 1;
        return out;
    }
    // Emit EVERY module's header + .c (like tests/test_harness.h's sc_codegen concatenation), so prelude
    // definitions (`str`, monomorphized Slice/Box, ...) are inspectable, not just the user snippet.
    for mi in 0..n {
        let msrc = p.modules[mi].source.as_str().ptr() as *const char;
        let mslen = p.modules[mi].source.len();
        let ma = (&mut p.modules[mi].ast) as *mut Ast; // codegen borrows the ast in place
        let cgpkg = (&mut p) as *mut loader::Package;
        let mut c = cg::Codegen::new(ma, str::from_raw(msrc as *const u8, mslen), cgpkg);
        c.set_multifile(true);
        c.codegen_emit_header(f);
        c.codegen_emit(f);
        if mi == uidx && c.has_errors() {
            out.errors = c.errors.errors.len();
        }
    }
    out.code = read_stream(f);
    unsafe stdio::fclose(f);
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

extend RunResult {
    pub fn ok(self: &Self) bool {
        return self.built && self.exit == 0;
    }
    pub fn out_has(self: &Self, needle: str) bool {
        if self.out == null {
            return false;
        }
        return unsafe cstring::strstr(self.out, needle.ptr() as *const char) != null;
    }
}
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
    let mut cmd = Path512 {};
    unsafe stdio::snprintf(&mut cmd.b[0], 512, "rm -rf '%s'".ptr() as *const char, dir);
    let _ = stdlib::system(str::from_cstr(&cmd.b[0]));
}

// Build `src` into a standalone program via `super-c build`, run it, and capture stdout+stderr + exit code.
// The compiler is $SUPERC (default "./super-c", matching the CWD=repo-root that `make selfhost-test` uses).
// Each snippet gets its own temp dir (/tmp/scr_<pid>_<seq>) so build trees never collide -- fork-per-test safe.
pub fn compile_and_run(src: str) RunResult {
    let mut r = RunResult { built: false, exit: -1, out: null };
    R_SEQ = R_SEQ + 1;
    let pid = unsafe shim::sc_getpid();
    let mut dir = Path256 {};
    unsafe stdio::snprintf(&mut dir.b[0], 256, "/tmp/scr_%d_%llu".ptr() as *const char, pid, R_SEQ);
    let dirp = (&dir.b[0]) as *const char;
    if unsafe shim::sc_mkdir(dirp) != 0 {
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
    let mut sc = stdlib::getenv("SUPERC");
    if sc == null || unsafe *sc == 0 as char {
        sc = "./super-c".ptr() as *const char;
    }
    let mut cmd = Path1024 {};
    unsafe stdio::snprintf(
        &mut cmd.b[0],
        1024,
        "%s build '%s/main.spc' -o '%s/prog' >/dev/null 2>&1".ptr() as *const char,
        sc,
        dirp,
        dirp,
    );
    let brc = stdlib::system(str::from_cstr(&cmd.b[0]));
    if brc != 0 {
        rm_dir(dirp);
        return r;
    } // did not build
    r.built = true;
    unsafe stdio::snprintf(&mut cmd.b[0], 1024, "'%s/prog' > '%s/out' 2>&1".ptr() as *const char, dirp, dirp);
    let rrc = stdlib::system(str::from_cstr(&cmd.b[0]));
    if unsafe shim::sc_wifexited(rrc) != 0 {
        r.exit = unsafe shim::sc_wexitstatus(rrc);
    }
    let mut op = Path512 {};
    unsafe stdio::snprintf(&mut op.b[0], 512, "%s/out".ptr() as *const char, dirp);
    r.out = slurp(&op.b[0]);
    rm_dir(dirp);
    return r;
}

// Build+run `src` and require it to exit 0 with stdout containing `want`.
pub fn expect_run(label: str, src: str, want: str) {
    let r = compile_and_run(src);
    assert(r.ok(), label);
    assert(r.out_has(want), label);
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
pub fn expect_err(label: str, src: str) {
    let c = compile(src, STAGE_TYPECHECK);
    assert(!c.ok(), label);
}
pub fn expect_resolve_ok(label: str, src: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(c.ok(), label);
}
pub fn expect_resolve_err(label: str, src: str) {
    let c = compile(src, STAGE_RESOLVE);
    assert(!c.ok(), label);
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
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut rr = res::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = &mut rr.ast;
    rr.resolve();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    if i == cap {
        let c = rr.errors.errors.len();
        if c > 0 {
            unsafe out.errors = c;
            unsafe copy_msg(&mut out.first[0], rr.errors.errors.at(0));
        }
    }
    let back = rr.take_ast();
    p.modules[i].ast = back;
}

// Mirror main.spc's typecheck_module, capturing the user module's diagnostics.
fn h_typecheck(p: &mut loader::Package, i: usize, cap: usize, out: *mut Compiled) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = &mut t.ast;
    t.check();
    if !t.has_errors() {
        t.borrowck();
    }
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    if i == cap {
        let c = t.errors.errors.len();
        if c > 0 {
            unsafe out.errors = c;
            unsafe copy_msg(&mut out.first[0], t.errors.errors.at(0));
        }
    }
    let back = t.take_ast();
    p.modules[i].ast = back;
}
