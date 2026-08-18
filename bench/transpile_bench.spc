// Self-hosted benchmark: how long does the compiler take to transpile the WHOLE super-c compiler to C?
// The corpus is the compiler itself -- package_load(selfhost/main.spc) pulls in every module main.spc
// transitively imports (the entire lexer/ast/parser/resolver/typechecker/consteval/codegen/loader stack,
// plus the std prelude + ffi bindings it uses). Each iteration runs the real transpile pipeline in process
// -- parse (lex+parse every module, via the loader) -> resolve-all -> typecheck-all (+ deferred asserts)
// -> borrowck-all -> emit the whole package to C through the streaming backend (shared headers + every TU +
// the instance TU, written to a real file) -- and times each phase with CPU time. It mirrors main.spc's
// run_package (minus the C link step). Emission writes through a FILE exactly as a build does. The benchmark
// binary IS the self-hosted compiler, so `make bench` measures the compiler transpiling its own source.
import module::loader as loader;
import lexer::lexer as lexer;
import resolver::resolver as res;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import consteval::consteval as ce;
import driver::emit as demit;
import driver::test as dtest;
import driver::util as dutil;
import ast::ast as *;
import bench::bench_shim as shim;
import std::testing::bench as bench;
import driver_shim as dshim;
import math;
import stdio;
import stdlib;
import string as cstring;
import time;

// tmpfile(): an anonymous auto-removed stream -- the file-lane sink codegen emits into. Rides in
// <stdio.h>, always in super_rt. POSIX-only call sites (mingw's tmpfile() lands in the drive root
// and fails unprivileged; Windows uses a %TEMP% file instead).
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

const ROOT: str = "src/main.spc";
const STD_DIR: str = "std";
const WARMUP: i32 = 1;
const ITERS: i32 = 100;
// The cc phase runs as a child process and compiles the whole emitted package -- orders of magnitude
// slower than an in-process transpile, so it gets its own small iteration count.
const CC_ITERS: i32 = 3;

// The codegen sink: a real file, on every platform. Codegen writes through a FILE, and this benchmark
// exists to report what codegen costs -- so the sink is the one codegen actually uses in a build rather
// than an in-memory stream that would measure lowering with the writes taken out. POSIX gets an anonymous
// auto-removed stream; mingw's tmpfile() lands in the drive root and fails unprivileged, so Windows names
// a file under %TEMP% and removes it itself.
@platform(!windows)
fn sink_open() *mut stdio::FILE {
    return unsafe tmpfile();
}

@platform(!windows)
fn sink_close(f: *mut stdio::FILE) usize {
    unsafe stdio::fflush(f);
    let t = unsafe stdio::ftell(f);
    unsafe stdio::fclose(f);
    if t > 0 {
        return t as usize;
    }
    return 0;
}

@platform(windows)
fn sink_path(buf: *mut char, cap: usize) *const char {
    let mut dir = stdlib::getenv("TEMP");
    if dir == null {
        dir = ".".ptr() as *const char;
    }
    unsafe stdio::snprintf(buf, cap, "%s\\sc_bench_sink.tmp".ptr() as *const char, dir);
    return buf;
}

@platform(windows)
fn sink_open() *mut stdio::FILE {
    let mut buf = Array::<char, 4096>::new();
    let p = sink_path(&mut buf[0], 4096);
    return stdio::fopen(str::from_raw(p as *const u8, unsafe cstring::strlen(p)), "wb");
}

@platform(windows)
fn sink_close(f: *mut stdio::FILE) usize {
    unsafe stdio::fflush(f);
    let t = unsafe stdio::ftell(f);
    unsafe stdio::fclose(f);
    let mut buf = Array::<char, 4096>::new();
    unsafe stdio::remove(sink_path(&mut buf[0], 4096));
    if t > 0 {
        return t as usize;
    }
    return 0;
}

pub struct Timing {
    pub lex: f64,
    pub parse: f64,
    pub resolve: f64,
    pub typecheck: f64,
    pub borrowck: f64,
    pub codegen: f64,
    pub src_bytes: usize,
    pub src_lines: usize,
    pub out_bytes: usize,
    pub modules: usize,
    pub tokens: usize,
    pub nodes: usize,
    pub decls: usize,
    pub cyc_lex: i64,
    pub cyc_parse: i64,
    pub cyc_resolve: i64,
    pub cyc_typecheck: i64,
    pub cyc_borrowck: i64,
    pub cyc_codegen: i64,
    pub alc_lex: i64,
    pub alc_parse: i64,
    pub alc_resolve: i64,
    pub alc_typecheck: i64,
    pub alc_borrowck: i64,
    pub alc_codegen: i64,
    pub byt_lex: i64,
    pub byt_parse: i64,
    pub byt_resolve: i64,
    pub byt_typecheck: i64,
    pub byt_borrowck: i64,
    pub byt_codegen: i64,
    pub heap_bytes: i64,
}

// Deferred-assert sink: a clean self-transpile produces none, so this is never actually called; it just
// satisfies flush_asserts' callback signature.
const fn ignore_assert(_ctx: *mut void, _m: ModuleId, _cond: NodeId, _msg: *const char) {}

// Resolve module `i` in place (mirrors main.spc's resolve_module, without diagnostics logging).
fn resolve_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut r = res::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.set_override(i as ModuleId, &mut r.ast);
    r.resolve();
    p.clear_override(i as ModuleId);
    let back = r.take_ast();
    p.modules[i].ast = back;
}

// Type-check module `i` in place (mirrors main.spc's typecheck_module).
fn typecheck_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = replace(&mut m.ast, Ast::new(0));
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.set_override(i as ModuleId, t.ast.get());
    t.check();
    p.clear_override(i as ModuleId);
    let back = t.take_ast();
    p.modules[i].ast = back;
}

// Overwrite `dir/base` with `s` (the emitted C is ASCII, so a byte copy is exact).
fn write_c(dir: str, base: str, s: str) {
    let mut path = String::from_str(dir);
    path.push_str("/");
    path.push_str(base);
    let f = stdio::fopen(path.as_str(), "wb");
    if f != null {
        unsafe stdio::fwrite(s.ptr(), 1, s.len(), f);
        unsafe stdio::fclose(f);
    }
}

// Transpile the compiler once and write the emitted package into `dir` for the cc phase to compile.
// Files land FLAT -- every TU beside the two shared headers -- mirroring the SC_CEMIT_TU lane, so each
// TU's `#include "__sc_types.h"` resolves in place. Fills `names` with the .c basenames (super_rt first)
// and returns the total emitted C size in bytes.
fn emit_package_to_dir(dir: str, names: &mut Vector<String>) usize {
    let mut p = loader::package_load(ROOT, STD_DIR.ptr() as *const char, false, unsafe dshim::sc_host_platform());
    let n = p.modules.len();
    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;
    let mut i: usize = 0;
    while i < n {
        resolve_one(&mut p, i);
        i = i + 1;
    }
    i = 0;
    while i < n {
        typecheck_one(&mut p, i);
        i = i + 1;
    }
    ceval.flush_asserts(ignore_assert, null);
    let _ = demit::borrowck_all(&mut p);

    let tplan = dtest::TestPlan::new(n);
    let mut o = demit::CemitOut::new(n);
    demit::cemit_package(&mut p, false, &tplan, null, &mut o);

    dutil::write_super_rt(dir);
    write_c(dir, "__sc_types.h", o.types_h.as_str());
    write_c(dir, "__sc_protos.h", o.protos_h.as_str());
    names.push(String::from_str("super_rt.c"));
    let mut bytes: usize = 0;
    for t in 0..n + 1 {
        let is_inst = t == n;
        let src9 = if is_inst {
            o.inst_c.as_str();
        } else {
            o.tus.at(t).as_str();
        };
        if src9.len() == 0 {
            continue;
        }
        bytes = bytes + src9.len();
        let mut base = String::new();
        if is_inst {
            base.push_str("__sc_inst");
        } else {
            let mp = p.modules[t].path.as_str();
            for k in 0..mp.len() {
                let c2 = mp.byte_at(k);
                let okc = c2 >= b'a' && c2 <= b'z' || c2 >= b'A' && c2 <= b'Z' || c2 >= b'0' && c2 <= b'9';
                base.push_byte(
                    if okc {
                        c2;
                    } else {
                        b'_';
                    },
                );
            }
        }
        base.push_str(".c");
        let mut body = String::from_str("#include \"__sc_types.h\"\n#include \"__sc_protos.h\"\n");
        body.push_str(src9);
        write_c(dir, base.as_str(), body.as_str());
        names.push(base);
    }
    return bytes;
}

// One full transpile of the compiler, timed per phase.
fn transpile_once() Timing {
    let mut r = Timing {
        lex: 0.0,
        parse: 0.0,
        resolve: 0.0,
        typecheck: 0.0,
        borrowck: 0.0,
        codegen: 0.0,
        src_bytes: 0,
        src_lines: 0,
        out_bytes: 0,
        modules: 0,
        tokens: 0,
        nodes: 0,
        decls: 0,
        cyc_lex: 0,
        cyc_parse: 0,
        cyc_resolve: 0,
        cyc_typecheck: 0,
        cyc_borrowck: 0,
        cyc_codegen: 0,
        alc_lex: 0,
        alc_parse: 0,
        alc_resolve: 0,
        alc_typecheck: 0,
        alc_borrowck: 0,
        alc_codegen: 0,
        byt_lex: 0,
        byt_parse: 0,
        byt_resolve: 0,
        byt_typecheck: 0,
        byt_borrowck: 0,
        byt_codegen: 0,
        heap_bytes: 0,
    };

    let a0 = time::cpu_seconds();
    let c0 = unsafe shim::sc_cpu_cycles();
    let h0 = unsafe shim::sc_alloc_count();
    let y0 = unsafe shim::sc_alloc_bytes();
    let mut p = loader::package_load(ROOT, STD_DIR.ptr() as *const char, false, unsafe dshim::sc_host_platform());
    let a1 = time::cpu_seconds();
    let c1 = unsafe shim::sc_cpu_cycles();
    let h1 = unsafe shim::sc_alloc_count();
    let y1 = unsafe shim::sc_alloc_bytes();

    let n = p.modules.len();
    r.modules = n;
    let mut i: usize = 0;
    // Corpus stats: bytes, node pools, top-level decls (all fixed once parsed -- mono adds instance
    // records, not nodes, so the pool size is stable through resolve/typecheck).
    while i < n {
        let a = &p.modules[i].ast;
        r.src_bytes = r.src_bytes + p.modules[i].source.len();
        r.nodes = r.nodes + a.nodes.len();
        r.decls = r.decls + a.at_const(a.root).as_data.program.items.len as usize;
        i = i + 1;
    }

    let pkg = (&mut p) as *mut loader::Package;
    let mut ceval = ce::ConstEval::new(pkg, 0, 0);
    p.ceval = &mut ceval;

    i = 0;
    while i < n {
        resolve_one(&mut p, i);
        i = i + 1;
    }
    let a2 = time::cpu_seconds();
    let c2 = unsafe shim::sc_cpu_cycles();
    let h2 = unsafe shim::sc_alloc_count();
    let y2 = unsafe shim::sc_alloc_bytes();

    i = 0;
    while i < n {
        typecheck_one(&mut p, i);
        i = i + 1;
    }
    ceval.flush_asserts(ignore_assert, null);
    let a3 = time::cpu_seconds();
    let c3 = unsafe shim::sc_cpu_cycles();
    let h3 = unsafe shim::sc_alloc_count();
    let y3 = unsafe shim::sc_alloc_bytes();

    let _ = demit::borrowck_all(&mut p); // the real stage, so the lane measures what ships
    let a3b = time::cpu_seconds();
    let c3b = unsafe shim::sc_cpu_cycles();
    let h3b = unsafe shim::sc_alloc_count();
    let y3b = unsafe shim::sc_alloc_bytes();

    let f = sink_open();
    {
        let tplan = dtest::TestPlan::new(n);
        let mut o = demit::CemitOut::new(n);
        demit::cemit_package(&mut p, false, &tplan, null, &mut o);
        // write the whole package to the sink FILE exactly as a build does, so out_bytes is real
        unsafe stdio::fwrite(o.types_h.as_ptr(), 1, o.types_h.len(), f);
        unsafe stdio::fwrite(o.protos_h.as_ptr(), 1, o.protos_h.len(), f);
        for m in 0..n {
            let tu = o.tus.at(m);
            unsafe stdio::fwrite(tu.as_ptr(), 1, tu.len(), f);
        }
        unsafe stdio::fwrite(o.inst_c.as_ptr(), 1, o.inst_c.len(), f);
    }
    r.out_bytes = sink_close(f);
    let a4 = time::cpu_seconds();
    let c4 = unsafe shim::sc_cpu_cycles();
    let h4 = unsafe shim::sc_alloc_count();
    let y4 = unsafe shim::sc_alloc_bytes();

    // Lex-only pass LAST so it can't perturb the pipeline phase timings: re-lex every module source to isolate
    // pure lexer throughput. Lexing is folded into `parse` (package_load -> scan_tokens), so it is NOT added to
    // the total -- it is the lexer's share OF parse.
    let lx0 = time::cpu_seconds();
    let cl0 = unsafe shim::sc_cpu_cycles();
    let hl0 = unsafe shim::sc_alloc_count();
    let yl0 = unsafe shim::sc_alloc_bytes();
    i = 0;
    while i < n {
        let mut lx = lexer::Lexer::new(&mut p.modules[i].source, "");
        lx.scan_tokens();
        r.tokens = r.tokens + lx.tokens.len();
        i = i + 1;
    }
    r.lex = time::cpu_seconds() - lx0;
    r.cyc_lex = unsafe shim::sc_cpu_cycles() - cl0;
    r.alc_lex = unsafe shim::sc_alloc_count() - hl0;
    r.byt_lex = unsafe shim::sc_alloc_bytes() - yl0;

    // Count source lines (untimed -- a constant of the corpus) for a lines/sec figure.
    i = 0;
    while i < n {
        let src = p.modules[i].source.as_str().ptr() as *const char;
        let len = p.modules[i].source.len();
        let mut j: usize = 0;
        while j < len {
            if (unsafe src[j]) as u8 == b'\n' {
                r.src_lines = r.src_lines + 1;
            }
            j = j + 1;
        }
        i = i + 1;
    }

    r.parse = a1 - a0;
    r.resolve = a2 - a1;
    r.typecheck = a3 - a2;
    r.borrowck = a3b - a3;
    r.codegen = a4 - a3b;
    r.cyc_parse = c1 - c0;
    r.cyc_resolve = c2 - c1;
    r.cyc_typecheck = c3 - c2;
    r.cyc_borrowck = c3b - c3;
    r.cyc_codegen = c4 - c3b;
    r.alc_parse = h1 - h0;
    r.alc_resolve = h2 - h1;
    r.alc_typecheck = h3 - h2;
    r.alc_borrowck = h3b - h3;
    r.alc_codegen = h4 - h3b;
    r.byt_parse = y1 - y0;
    r.byt_resolve = y2 - y1;
    r.byt_typecheck = y3 - y2;
    r.byt_borrowck = y3b - y3;
    r.byt_codegen = y4 - y3b;
    r.heap_bytes = y4 - y0;
    return r;
}

// This one keeps its own report: a per-phase table (lex/parse/resolve/typecheck/codegen with MB/s and
// allocations) is the point of it, and no generic timing loop can produce that -- so it opts out of the
// runner's one-line summary, which would only restate a single round's wall time. It still runs under the
// Bencher, so it appears in the same listing as every other benchmark.
@bench(log_results = false)
pub fn self_transpile(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        let _ = run_report();
    }
}

fn run_report() i32 {
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
        "  %zu modules, %zu decls, %zu lines, %zu tokens, %.1f KiB source -> %.1f KiB C\n".ptr() as *const char,
        warm.modules,
        warm.decls,
        warm.src_lines,
        warm.tokens,
        warm.src_bytes as f64 / 1024.0,
        warm.out_bytes as f64 / 1024.0,
    );
    let mut cpu = Array::<char, 256>::new();
    if unsafe shim::sc_cpu_model(&mut cpu[0], 256) != 0 {
        unsafe stdio::snprintf(&mut cpu[0], 256, "%s".ptr() as *const char, "unknown CPU".ptr() as *const char);
    }
    unsafe stdio::printf(
        "  %zu AST nodes;  %s;  single-threaded, %d iterations\n\n".ptr() as *const char,
        warm.nodes,
        (&cpu[0]) as *const char,
        ITERS,
    );

    let mut sp: f64 = 0.0;
    let mut sr: f64 = 0.0;
    let mut st: f64 = 0.0;
    let mut sl: f64 = 0.0;
    let mut sc_f: f64 = 0.0;
    let mut scy_l: i64 = 0;
    let mut scy_p: i64 = 0;
    let mut scy_r: i64 = 0;
    let mut scy_t: i64 = 0;
    let mut scy_cf: i64 = 0;
    let mut sal_l: i64 = 0;
    let mut sal_p: i64 = 0;
    let mut sal_r: i64 = 0;
    let mut sal_t: i64 = 0;
    let mut sal_cf: i64 = 0;
    let mut sb: f64 = 0.0;
    let mut scy_b: i64 = 0;
    let mut sal_b: i64 = 0;
    let mut sby_l: i64 = 0;
    let mut sby_p: i64 = 0;
    let mut sby_r: i64 = 0;
    let mut sby_t: i64 = 0;
    let mut sby_b: i64 = 0;
    let mut sby_cf: i64 = 0;
    let mut sheap: i64 = 0;
    let mut totals = Vector::<f64>::with_capacity(ITERS as usize);
    let mut k: i32 = 0;
    while k < ITERS {
        let t = transpile_once();
        sp = sp + t.parse;
        sr = sr + t.resolve;
        st = st + t.typecheck;
        sb = sb + t.borrowck;
        sl = sl + t.lex;
        scy_l = scy_l + t.cyc_lex;
        scy_p = scy_p + t.cyc_parse;
        scy_r = scy_r + t.cyc_resolve;
        scy_t = scy_t + t.cyc_typecheck;
        scy_b = scy_b + t.cyc_borrowck;
        sal_l = sal_l + t.alc_lex;
        sal_p = sal_p + t.alc_parse;
        sal_r = sal_r + t.alc_resolve;
        sal_t = sal_t + t.alc_typecheck;
        sal_b = sal_b + t.alc_borrowck;
        sby_l = sby_l + t.byt_lex;
        sby_p = sby_p + t.byt_parse;
        sby_r = sby_r + t.byt_resolve;
        sby_t = sby_t + t.byt_typecheck;
        sby_b = sby_b + t.byt_borrowck;
        sheap = sheap + t.heap_bytes;
        let total = t.parse + t.resolve + t.typecheck + t.borrowck + t.codegen;
        sc_f = sc_f + t.codegen;
        scy_cf = scy_cf + t.cyc_codegen;
        sal_cf = sal_cf + t.alc_codegen;
        sby_cf = sby_cf + t.byt_codegen;
        totals.push(total);
        k = k + 1;
    }
    let fi = ITERS as f64;
    let ac = sc_f / fi * 1000.0;
    let ap = sp / fi * 1000.0;
    let ar = sr / fi * 1000.0;
    let at = st / fi * 1000.0;
    let ab = sb / fi * 1000.0;
    let al = sl / fi * 1000.0;
    let avg_total = ap + ar + at + ab + ac;
    let srcf = warm.src_bytes as f64; // source MB/s for an avg-ms figure = srcf / ms / 1000
    let linesf = warm.src_lines as f64; // lines/sec in thousands (kloc/s) for an avg-ms figure = linesf / ms
    // Per-phase CPU cycles at the same boundaries as the ms timings;
    // all-zero when this box has no cycle source. Effective clock: Mcyc/ms == GHz (counted only
    // while on-core, so P/E scheduling shows up here).
    let ml = scy_l as f64 / fi / 1e6;
    let mp = scy_p as f64 / fi / 1e6;
    let mr = scy_r as f64 / fi / 1e6;
    let mt = scy_t as f64 / fi / 1e6;
    let mb = scy_b as f64 / fi / 1e6;
    let mc = scy_cf as f64 / fi / 1e6;
    let mtot = mp + mr + mt + mb + mc;
    // Heap allocations (malloc/calloc/realloc calls by the compiler's own code) per iteration, in
    // thousands. All-zero when the shim has no counting on this platform.
    let kal = sal_l as f64 / fi / 1e3;
    let kap = sal_p as f64 / fi / 1e3;
    let kar = sal_r as f64 / fi / 1e3;
    let kat = sal_t as f64 / fi / 1e3;
    let kab = sal_b as f64 / fi / 1e3;
    let kac = sal_cf as f64 / fi / 1e3;
    let katot = kap + kar + kat + kab + kac;
    // Bytes requested from the allocator per phase, per iteration, in MiB.
    let mbl = sby_l as f64 / fi / 1048576.0;
    let mbp = sby_p as f64 / fi / 1048576.0;
    let mbr = sby_r as f64 / fi / 1048576.0;
    let mbt = sby_t as f64 / fi / 1048576.0;
    let mbb = sby_b as f64 / fi / 1048576.0;
    let mbc = sby_cf as f64 / fi / 1048576.0;
    let mbtot = mbp + mbr + mbt + mbb + mbc;

    unsafe stdio::printf(
        "  %-11s %9s %9s %9s %9s %9s %9s %8s\n".ptr() as *const char,
        "phase".ptr() as *const char,
        "avg ms".ptr() as *const char,
        "MB/s".ptr() as *const char,
        "kloc/s".ptr() as *const char,
        "Mcyc".ptr() as *const char,
        "Kalloc".ptr() as *const char,
        "MiB".ptr() as *const char,
        "share".ptr() as *const char,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f   (of parse)\n".ptr() as *const char,
        "lex".ptr() as *const char,
        al,
        srcf / al / 1000.0,
        linesf / al,
        ml,
        kal,
        mbl,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f %7.1f%%\n".ptr() as *const char,
        "parse".ptr() as *const char,
        ap,
        srcf / ap / 1000.0,
        linesf / ap,
        mp,
        kap,
        mbp,
        ap / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f %7.1f%%\n".ptr() as *const char,
        "resolve".ptr() as *const char,
        ar,
        srcf / ar / 1000.0,
        linesf / ar,
        mr,
        kar,
        mbr,
        ar / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f %7.1f%%\n".ptr() as *const char,
        "typecheck".ptr() as *const char,
        at,
        srcf / at / 1000.0,
        linesf / at,
        mt,
        kat,
        mbt,
        at / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f %7.1f%%\n".ptr() as *const char,
        "borrowck".ptr() as *const char,
        ab,
        srcf / ab / 1000.0,
        linesf / ab,
        mb,
        kab,
        mbb,
        ab / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f %7.1f%%\n".ptr() as *const char,
        "codegen".ptr() as *const char,
        ac,
        srcf / ac / 1000.0,
        linesf / ac,
        mc,
        kac,
        mbc,
        ac / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f   (%.2f GHz)\n\n".ptr() as *const char,
        "total".ptr() as *const char,
        avg_total,
        srcf / avg_total / 1000.0,
        linesf / avg_total,
        mtot,
        katot,
        mbtot,
        mtot / avg_total,
    );

    // The best end-to-end run, scanned rather than indexed: nothing sorts `totals`.
    let mut best = totals[0];
    for i in 1..totals.len() {
        if totals[i] < best {
            best = totals[i];
        }
    }
    unsafe stdio::printf(
        "  codegen emits %.1f KiB C at %.1f MB/s;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
        warm.out_bytes as f64 / 1024.0,
        warm.out_bytes as f64 / ac / 1000.0,
        srcf / best / 1e6,
    );
    let rss = unsafe shim::sc_peak_rss();
    unsafe stdio::printf(
        "  heap: %.1f MiB requested per iteration;  peak RSS %.1f MiB\n".ptr() as *const char,
        sheap as f64 / fi / (1024.0 * 1024.0),
        rss as f64 / (1024.0 * 1024.0),
    );

    // The cc phase, on its own AFTER emit and never folded into codegen: emit the package to a scratch tree
    // once, then compile it with the C compiler. cc is a child process, so it is timed on the monotonic wall
    // clock (a child's CPU time never lands in this process's getrusage) rather than cpu_seconds like the
    // in-process phases. Compile-only (`-c`): pure C-front-end/codegen cost, no link and no missing @c.source
    // symbols to satisfy.
    let mut ccdir = String::from_str(str::from_cstr(unsafe dshim::sc_tmpdir()));
    ccdir.push_str("/sc_bench_cc");
    let _ = unsafe dshim::sc_rm_rf(ccdir.cstr());
    let _ = unsafe dshim::sc_mkdir_p(ccdir.cstr());
    let mut names = Vector::<String>::new();
    let cbytes = emit_package_to_dir(ccdir.as_str(), &mut names);
    let mut cmd = String::new();
    if unsafe dshim::sc_host_platform() == 0 {
        cmd.push_str("cd /d \"");
    } else {
        cmd.push_str("cd \"");
    }
    cmd.push_str(ccdir.as_str());
    cmd.push_str("\" && cc -std=c11 -D_POSIX_C_SOURCE=200809L -c");
    for i in 0..names.len() {
        cmd.push_str(" ");
        cmd.push_string(names.at(i));
    }
    let mut scc: i64 = 0;
    let mut crc: i32 = 0;
    let mut kk: i32 = 0;
    while kk < CC_ITERS {
        let t0 = unsafe dshim::sc_ticks_ms();
        crc = unsafe dshim::sc_run(cmd.cstr(), null, null, null, null);
        scc = scc + (unsafe dshim::sc_ticks_ms() - t0);
        kk = kk + 1;
    }
    let _ = unsafe dshim::sc_rm_rf(ccdir.cstr());
    let acc = scc as f64 / CC_ITERS as f64;
    if crc != 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "  cc: compile FAILED (rc %d) -- timing below is unreliable\n".ptr() as *const char,
            crc,
        );
    }
    unsafe stdio::printf(
        "  cc (compile-only): %.1f ms avg over %d;  %zu C files, %.1f KiB C -> objects, %.1f MB/s\n".ptr() as *const char,
        acc,
        CC_ITERS,
        names.len(),
        cbytes as f64 / 1024.0,
        cbytes as f64 / acc / 1000.0,
    );
    return 0;
}
