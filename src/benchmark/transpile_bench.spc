// Self-hosted benchmark: how long does the compiler take to transpile the WHOLE super-c compiler to C?
// The corpus is the compiler itself -- package_load(selfhost/main.spc) pulls in every module main.spc
// transitively imports (the entire lexer/ast/parser/resolver/typechecker/consteval/codegen/loader stack,
// plus the std prelude + ffi bindings it uses). Each iteration runs the real transpile pipeline in process
// -- parse (lex+parse every module, via the loader) -> resolve-all -> typecheck-all (+ deferred asserts)
// -> propagate instances -> codegen-all (emit every module's header + .c to a null sink) -- and times each
// phase with CPU time. It mirrors main.spc's run_package (minus file I/O / the C link step). The benchmark
// binary IS the self-hosted compiler, so `make bench` measures the compiler transpiling its own source.
import module::loader as loader;
import lexer::lexer as lexer;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import codegen::codegen as cg;
import consteval::consteval as ce;
import ast::ast as *;
import stdio;
import stdlib;
import string as cstring;
import time;

// tmpfile(): an anonymous auto-removed stream -- the null sink codegen emits into (measures lowering
// throughput, not disk I/O). Rides in <stdio.h>, always in super_rt.
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

const ROOT: str = "src/main.spc";
const STD_DIR: str = "std";
const WARMUP: i32 = 1;
const ITERS: i32 = 8;

pub struct Timing {
    pub lex: f64,
    pub parse: f64,
    pub resolve: f64,
    pub typecheck: f64,
    pub codegen: f64,
    pub src_bytes: usize,
    pub src_lines: usize,
    pub out_bytes: usize,
    pub modules: usize,
}

// Deferred-assert sink: a clean self-transpile produces none, so this is never actually called; it just
// satisfies flush_asserts' callback signature.
fn ignore_assert(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) void {}

// Resolve module `i` in place (mirrors main.spc's resolve_module, without diagnostics logging).
fn resolve_one(p: &mut loader::Package, i: usize) void {
    let pkg = (&*p) as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut r = res::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut r.ast) as *mut Ast;
    r.resolve();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let back = r.take_ast();
    p.modules[i].ast = back;
}

// Type-check module `i` in place (mirrors main.spc's typecheck_module).
fn typecheck_one(p: &mut loader::Package, i: usize) void {
    let pkg = (&mut *p) as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut t.ast) as *mut Ast;
    t.check();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let back = t.take_ast();
    t.free();
    p.modules[i].ast = back;
}

// One full transpile of the compiler, timed per phase.
fn transpile_once() Timing {
    let mut r = Timing {
        lex: 0.0,
        parse: 0.0,
        resolve: 0.0,
        typecheck: 0.0,
        codegen: 0.0,
        src_bytes: 0,
        src_lines: 0,
        out_bytes: 0,
        modules: 0,
    };

    let a0 = time::cpu_seconds();
    let mut p = loader::package_load(ROOT.ptr() as *const char, STD_DIR.ptr() as *const char, false);
    let a1 = time::cpu_seconds();

    let n = p.modules.len();
    r.modules = n;
    let mut i: usize = 0;
    while i < n {
        r.src_bytes = r.src_bytes + p.modules[i].source.len();
        i = i + 1;
    }

    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = (&mut ceval) as *mut void;

    i = 0;
    while i < n {
        resolve_one(&mut p, i);
        i = i + 1;
    }
    let a2 = time::cpu_seconds();

    i = 0;
    while i < n {
        typecheck_one(&mut p, i);
        i = i + 1;
    }
    ceval.flush_asserts(ignore_assert, null);
    let a3 = time::cpu_seconds();

    loader::package_propagate_instances(&mut p);
    let f = unsafe tmpfile();
    i = 0;
    while i < n {
        let ma = (&mut p.modules[i].ast) as *mut Ast;
        let src = p.modules[i].source.as_str().ptr() as *const char;
        let slen = p.modules[i].source.len();
        let pkg2 = (&mut p) as *mut loader::Package; // consumed on use -> fresh cast per Codegen::new
        let mut c = cg::Codegen::new(ma, str::from_raw(src as *const u8, slen), pkg2);
        c.set_multifile(true);
        c.codegen_emit_header(f);
        c.codegen_emit(f);
        c.free();
        i = i + 1;
    }
    unsafe stdio::fflush(f);
    let sz = unsafe stdio::ftell(f);
    if sz > 0 {
        r.out_bytes = sz as usize;
    }
    unsafe stdio::fclose(f);
    let a4 = time::cpu_seconds();

    // Lex-only pass LAST so it can't perturb the pipeline phase timings: re-lex every module source to isolate
    // pure lexer throughput. Lexing is folded into `parse` (package_load -> scan_tokens), so it is NOT added to
    // the total -- it is the lexer's share OF parse.
    let lx0 = time::cpu_seconds();
    i = 0;
    while i < n {
        let mut lx = lexer::Lexer::new(&mut p.modules[i].source);
        lx.scan_tokens();
        lx.free();
        i = i + 1;
    }
    r.lex = time::cpu_seconds() - lx0;

    // Count source lines (untimed -- a constant of the corpus) for a lines/sec figure.
    i = 0;
    while i < n {
        let src = p.modules[i].source.as_str().ptr() as *const char;
        let len = p.modules[i].source.len();
        let mut j: usize = 0;
        while j < len {
            if unsafe src[j] as u8 == b'\n' {
                r.src_lines = r.src_lines + 1;
            }
            j = j + 1;
        }
        i = i + 1;
    }

    r.parse = a1 - a0;
    r.resolve = a2 - a1;
    r.typecheck = a3 - a2;
    r.codegen = a4 - a3;
    return r;
}

pub fn run() i32 {
    let warm = transpile_once(); // warm caches + report corpus size
    if warm.modules == 0 || warm.out_bytes == 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "transpile-bench: failed to transpile %s (run from the repo root)\n".ptr() as *const char,
            ROOT.ptr() as *const char,
        );
        return 1;
    }
    unsafe stdio::printf("transpiling the super-c compiler: %s\n".ptr() as *const char, ROOT.ptr() as *const char);
    unsafe stdio::printf(
        "  %zu modules, %zu lines, %.1f KiB source -> %.1f KiB C   (%d iterations)\n\n".ptr() as *const char,
        warm.modules,
        warm.src_lines,
        warm.src_bytes as f64 / 1024.0,
        warm.out_bytes as f64 / 1024.0,
        ITERS,
    );

    let mut sp: f64 = 0.0;
    let mut sr: f64 = 0.0;
    let mut st: f64 = 0.0;
    let mut sc: f64 = 0.0;
    let mut sl: f64 = 0.0;
    let mut best: f64 = 1.0e30;
    let mut k: i32 = 0;
    while k < ITERS {
        let t = transpile_once();
        sp = sp + t.parse;
        sr = sr + t.resolve;
        st = st + t.typecheck;
        sc = sc + t.codegen;
        sl = sl + t.lex;
        let total = t.parse + t.resolve + t.typecheck + t.codegen;
        if total < best {
            best = total;
        }
        k = k + 1;
    }
    let fi = ITERS as f64;
    let ap = sp / fi * 1000.0;
    let ar = sr / fi * 1000.0;
    let at = st / fi * 1000.0;
    let ac = sc / fi * 1000.0;
    let al = sl / fi * 1000.0;
    let avg_total = ap + ar + at + ac;
    let srcf = warm.src_bytes as f64; // source MB/s for an avg-ms figure = srcf / ms / 1000
    let linesf = warm.src_lines as f64; // lines/sec in thousands (kloc/s) for an avg-ms figure = linesf / ms

    unsafe stdio::printf(
        "  %-11s %9s %9s %9s %8s\n".ptr() as *const char,
        "phase".ptr() as *const char,
        "avg ms".ptr() as *const char,
        "MB/s".ptr() as *const char,
        "kloc/s".ptr() as *const char,
        "share".ptr() as *const char,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f   (of parse)\n".ptr() as *const char,
        "lex".ptr() as *const char,
        al,
        srcf / al / 1000.0,
        linesf / al,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %7.1f%%\n".ptr() as *const char,
        "parse".ptr() as *const char,
        ap,
        srcf / ap / 1000.0,
        linesf / ap,
        ap / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %7.1f%%\n".ptr() as *const char,
        "resolve".ptr() as *const char,
        ar,
        srcf / ar / 1000.0,
        linesf / ar,
        ar / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %7.1f%%\n".ptr() as *const char,
        "typecheck".ptr() as *const char,
        at,
        srcf / at / 1000.0,
        linesf / at,
        at / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %7.1f%%\n".ptr() as *const char,
        "codegen".ptr() as *const char,
        ac,
        srcf / ac / 1000.0,
        linesf / ac,
        ac / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f   (best %.2f ms)\n\n".ptr() as *const char,
        "total".ptr() as *const char,
        avg_total,
        srcf / avg_total / 1000.0,
        linesf / avg_total,
        best * 1000.0,
    );

    unsafe stdio::printf(
        "  codegen emits %.1f KiB C at %.1f MB/s;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
        warm.out_bytes as f64 / 1024.0,
        warm.out_bytes as f64 / ac / 1000.0,
        srcf / best / 1e6,
    );
    unsafe stdio::printf(
        "%s".ptr() as *const char,
        "  * per-phase MB/s & kloc/s are that stage ALONE (whole corpus / its own time). Phases run\n".ptr() as *const char,
    );
    unsafe stdio::printf(
        "%s".ptr() as *const char,
        "    in series, so total time = sum of phases and total rate is below EVERY stage's rate.\n".ptr() as *const char,
    );
    return 0;
}
