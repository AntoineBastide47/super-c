// Self-hosted benchmark: how long does the compiler take to transpile the WHOLE super-c compiler to C?
// The corpus is the compiler itself -- package_load(selfhost/main.spc) pulls in every module main.spc
// transitively imports (the entire lexer/ast/parser/resolver/typechecker/consteval/codegen/loader stack,
// plus the std prelude + ffi bindings it uses). Each iteration runs the real transpile pipeline in process
// -- parse (lex+parse every module, via the loader) -> resolve-all -> typecheck-all (+ deferred asserts)
// -> propagate instances -> codegen-all (emit every module's header + .c to a null sink) -- and times each
// phase with CPU time. It mirrors main.spc's run_package (minus file I/O / the C link step). The benchmark
// binary IS the self-hosted compiler, so `make bench` measures the compiler transpiling its own source.
import module::loader as loader;
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

const ROOT: str = "selfhost/main.spc";
const STD_DIR: str = "std";
const WARMUP: i32 = 1;
const ITERS: i32 = 8;

pub struct Timing {
    pub parse: f64,
    pub resolve: f64,
    pub typecheck: f64,
    pub codegen: f64,
    pub src_bytes: usize,
    pub out_bytes: usize,
    pub modules: usize,
}

// Deferred-assert sink: a clean self-transpile produces none, so this is never actually called; it just
// satisfies flush_asserts' callback signature.
fn ignore_assert(ctx: *mut void, m: ModuleId, cond: NodeId, msg: *const char) void { }

// Resolve module `i` in place (mirrors main.spc's resolve_module, without diagnostics logging).
fn resolve_one(p: &mut loader::Package, i: usize) void {
    let pkg = (&*p) as *const loader::Package;
    let m = p.modules.index_mut(i);
    let src = m.source;
    let len = m.source_len;
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut r = res::Resolver::new(a, src, len, pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut r.ast) as *mut Ast;
    r.resolve();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let back = r.take_ast();
    r.free();
    p.modules.index_mut(i).ast = back;
}

// Type-check module `i` in place (mirrors main.spc's typecheck_module).
fn typecheck_one(p: &mut loader::Package, i: usize) void {
    let pkg = (&mut *p) as *mut loader::Package;
    let m = p.modules.index_mut(i);
    let src = m.source;
    let len = m.source_len;
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, src, len, pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = (&mut t.ast) as *mut Ast;
    t.check();
    p.override_mod = 0xFFFF as ModuleId;
    p.override_ast = null;
    let back = t.take_ast();
    t.free();
    p.modules.index_mut(i).ast = back;
}

// One full transpile of the compiler, timed per phase.
fn transpile_once() Timing {
    let mut r = Timing { parse: 0.0, resolve: 0.0, typecheck: 0.0, codegen: 0.0, src_bytes: 0, out_bytes: 0, modules: 0 };

    let a0 = time::cpu_seconds();
    let mut p = loader::package_load(ROOT.ptr() as *const char, STD_DIR.ptr() as *const char);
    let a1 = time::cpu_seconds();

    let n = p.modules.len();
    r.modules = n;
    let mut i: usize = 0;
    while i < n { r.src_bytes = r.src_bytes + p.modules.at(i).source_len; i = i + 1; }

    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = (&mut ceval) as *mut void;

    i = 0;
    while i < n { resolve_one(&mut p, i); i = i + 1; }
    let a2 = time::cpu_seconds();

    i = 0;
    while i < n { typecheck_one(&mut p, i); i = i + 1; }
    ceval.flush_asserts(ignore_assert, null);
    let a3 = time::cpu_seconds();

    loader::package_propagate_instances(&mut p);
    let f = unsafe tmpfile();
    i = 0;
    while i < n {
        let ma = (&mut p.modules.index_mut(i).ast) as *mut Ast;
        let src = p.modules.at(i).source;
        let slen = p.modules.at(i).source_len;
        let pkg2 = (&mut p) as *mut loader::Package; // consumed on use -> fresh cast per Codegen::new
        let mut c = cg::Codegen::new(ma, src, slen, pkg2);
        c.set_multifile(true);
        c.codegen_emit_header(f);
        c.codegen_emit(f);
        c.free();
        i = i + 1;
    }
    unsafe stdio::fflush(f);
    let sz = unsafe stdio::ftell(f);
    if sz > 0 { r.out_bytes = sz as usize; }
    unsafe stdio::fclose(f);
    let a4 = time::cpu_seconds();

    ceval.free();
    p.free();

    r.parse = a1 - a0;
    r.resolve = a2 - a1;
    r.typecheck = a3 - a2;
    r.codegen = a4 - a3;
    return r;
}

pub fn run() i32 {
    let warm = transpile_once(); // warm caches + report corpus size
    if warm.modules == 0 || warm.out_bytes == 0 {
        unsafe stdio::fprintf(stdio::stderr(), "transpile-bench: failed to transpile %s (run from the repo root)\n".ptr() as *const char, ROOT.ptr() as *const char);
        return 1;
    }
    unsafe stdio::printf("transpiling the super-c compiler: %s\n".ptr() as *const char, ROOT.ptr() as *const char);
    unsafe stdio::printf("  %zu modules, %.1f KiB source -> %.1f KiB C   (%d iterations)\n\n".ptr() as *const char,
        warm.modules, (warm.src_bytes as f64) / 1024.0, (warm.out_bytes as f64) / 1024.0, ITERS);

    let mut sp: f64 = 0.0;
    let mut sr: f64 = 0.0;
    let mut st: f64 = 0.0;
    let mut sc: f64 = 0.0;
    let mut best: f64 = 1.0e30;
    let mut k: i32 = 0;
    while k < ITERS {
        let t = transpile_once();
        sp = sp + t.parse;
        sr = sr + t.resolve;
        st = st + t.typecheck;
        sc = sc + t.codegen;
        let total = t.parse + t.resolve + t.typecheck + t.codegen;
        if total < best { best = total; }
        k = k + 1;
    }
    let fi = ITERS as f64;
    let ap = sp / fi * 1000.0;
    let ar = sr / fi * 1000.0;
    let at = st / fi * 1000.0;
    let ac = sc / fi * 1000.0;
    let avg_total = ap + ar + at + ac;

    unsafe stdio::printf("  %-12s %10s\n".ptr() as *const char, "phase".ptr() as *const char, "avg ms".ptr() as *const char);
    unsafe stdio::printf("  %-12s %10.2f  (%4.1f%%)\n".ptr() as *const char, "parse".ptr() as *const char, ap, ap / avg_total * 100.0);
    unsafe stdio::printf("  %-12s %10.2f  (%4.1f%%)\n".ptr() as *const char, "resolve".ptr() as *const char, ar, ar / avg_total * 100.0);
    unsafe stdio::printf("  %-12s %10.2f  (%4.1f%%)\n".ptr() as *const char, "typecheck".ptr() as *const char, at, at / avg_total * 100.0);
    unsafe stdio::printf("  %-12s %10.2f  (%4.1f%%)\n".ptr() as *const char, "codegen".ptr() as *const char, ac, ac / avg_total * 100.0);
    unsafe stdio::printf("  %-12s %10.2f  (best %.2f ms)\n\n".ptr() as *const char, "total".ptr() as *const char, avg_total, best * 1000.0);

    let mbps = (warm.src_bytes as f64) / (best) / 1e6;
    unsafe stdio::printf("  throughput: %.2f MB/s source  (%.1f KiB compiler in %.2f ms)\n".ptr() as *const char,
        mbps, (warm.src_bytes as f64) / 1024.0, best * 1000.0);
    return 0;
}
