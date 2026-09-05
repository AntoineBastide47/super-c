// Self-hosted benchmark: how long does the compiler take to transpile the WHOLE super-c compiler to C?
// The corpus is the compiler itself: package_load(selfhost/main.spc) pulls in every module main.spc
// transitively imports (the entire lexer/ast/parser/resolver/typechecker/const-eval/codegen/loader stack,
// plus the std prelude + ffi bindings it uses). Each iteration runs the real transpile pipeline in process
// parse (lex+parse every module, via the loader) -> resolve-all -> typecheck-all (+ deferred asserts)
// -> borrowck-all -> emit the whole package to C through the streaming backend (shared headers + every TU +
// the instance TU, written to a real file), and times each phase with CPU time. It mirrors main.spc's
// run_package (minus the C link step). Emission writes through a FILE exactly as a build does. The benchmark
// binary IS the self-hosted compiler, so `super-c bench` measures the compiler transpiling its own source.
// After the rounds, one cold build of the compiler runs through the real build engine (the same sources,
// flags, streamed C compile and link a `super-c build` runs) and its phase record is reported; a C compiler
// or linker failure there fails the benchmark.
import module::loader as loader;
import lexer::lexer as lexer;
import resolver::resolver as res;
import hir::lower as hirl;
import typechecker::typechecker as tc;
import borrowck::borrowck as bck;
import ir::lower as irl;
import ir::interp as iri;
import driver::emit as demit;
import driver::stats as bst;
import driver::test as dtest;
import build_system::build as bsys;
import build_system::manifest as mf;
import ast::ast as *;
import bench::bench_shim as shim;
import std::testing::bench as bench;
import driver_shim as dshim;
import stdio;
import stdlib;
import string as cstring;
import time;

// tmpfile(): an anonymous auto-removed stream; the file-lane sink codegen emits into. Rides in
// <stdio.h>, always in super_rt. POSIX-only call sites (mingw's tmpfile() lands in the drive root
// and fails unprivileged; Windows uses a %TEMP% file instead).
extern "C" {
    fn tmpfile() *mut stdio::FILE;
}

const ROOT: str = "src/main.spc";
const STD_DIR: str = "std";
const ITERS: i32 = 100;

// The codegen sink: a real file, on every platform. Codegen writes through a FILE, and this benchmark
// exists to report what codegen costs, so the sink is the one codegen uses in a build rather
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

/// Per-stage wall times of one self-transpile, in milliseconds.
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

// Resolve module `i` in place (mirrors main.spc's resolve_module, without diagnostics logging).
fn resolve_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let aptr = (&mut m.ast) as *mut Ast;
    let mut r = res::Resolver::new(unsafe &mut *aptr, str::from_raw(src as *const u8, len), pkg);
    r.resolve();
    hirl::lower_module(p, i);
}

// Type-check module `i` in place (mirrors main.spc's typecheck_module).
fn typecheck_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut t = tc::TypeChecker::new(&mut m.ast, str::from_raw(src as *const u8, len), pkg);
    t.check();
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
    let mut p = loader::package_load(ROOT, STD_DIR, false, unsafe dshim::sc_host_platform());
    let a1 = time::cpu_seconds();
    let c1 = unsafe shim::sc_cpu_cycles();
    let h1 = unsafe shim::sc_alloc_count();
    let y1 = unsafe shim::sc_alloc_bytes();

    let n = p.modules.len();
    r.modules = n;
    let mut i: usize = 0;
    // Corpus stats: bytes, node pools, top-level decls (all fixed once parsed; mono adds instance
    // records, not nodes, so the pool size is stable through resolve/typecheck).
    while i < n {
        let a = &p.modules[i].ast;
        r.src_bytes = r.src_bytes + p.modules[i].source.len();
        r.nodes = r.nodes + a.nodes.len();
        r.decls = r.decls + a.at_const(a.root).as_data.program.items.len as usize;
        i = i + 1;
    }

    let pkg = (&mut p) as *mut loader::Package;
    let mut cirv = iri::interp_new(pkg);
    p.cir = &mut cirv;
    // The bench is the SERIAL perf gate; parallel stages are timed by the driver.
    p.jobs = 1;

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
    cirv.all_typed = true;
    cirv.record_folds = true;
    let a3 = time::cpu_seconds();
    let c3 = unsafe shim::sc_cpu_cycles();
    let h3 = unsafe shim::sc_alloc_count();
    let y3 = unsafe shim::sc_alloc_bytes();

    let mut irkeep = irl::Keep::new();
    let _ = demit::borrowck_all(&mut p, &mut irkeep); // the real stage, so the lane measures what ships
    let a3b = time::cpu_seconds();
    let c3b = unsafe shim::sc_cpu_cycles();
    let h3b = unsafe shim::sc_alloc_count();
    let y3b = unsafe shim::sc_alloc_bytes();

    let f = sink_open();
    {
        let tplan = dtest::TestPlan::new(n);
        let mut o = demit::CemitOut::new(n);
        demit::cemit_package(&mut p, false, &tplan, null, -1, &mut o, &mut irkeep);
        // Write the whole package to the sink FILE exactly as a build does, so out_bytes is real.
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
    // the total: it is the lexer's share OF parse.
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

    // Count source lines (untimed: a constant of the corpus) for a lines/sec figure.
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

// This one keeps its own report: a per-phase table (lex/parse/resolve/typecheck/borrowck/codegen with MB/s
// and allocations) is the point of it, and no generic timing loop can produce that. The Bencher still
// drives the rounds and keeps the wall-time distribution of every round; the table sums the in-process
// counters of the same rounds. Any failure (a corpus that does not load, a real build whose C compiler
// or linker fails) is reported to the runner, so the run exits nonzero.
@bench(log_results = false)
/// Benchmark lane: the compiler transpiles its own source, ITERS timed rounds, then one real cold build.
pub fn self_transpile(b: &mut bench::Bencher) {
    // The corpus probe below is the warm-up; every round the Bencher runs is a sample.
    b.set_rounds(ITERS);
    b.set_warmup(0);
    if !run_report(b) {
        bench::fail("self_transpile");
    }
}

// Sums of one phase over every round, converted to per-round averages by `avg`.
struct PhaseSum {
    pub secs: f64,
    pub cyc: i64,
    pub alc: i64,
    pub byt: i64,
}

// The report's per-phase row: averages over ITERS rounds.
struct PhaseAvg {
    pub ms: f64,
    pub mcyc: f64,
    pub kalloc: f64,
    pub mib: f64,
}

fn phase_sum_new() PhaseSum {
    return PhaseSum { secs: 0.0, cyc: 0, alc: 0, byt: 0 };
}

fn phase_add(s: &mut PhaseSum, secs: f64, cyc: i64, alc: i64, byt: i64) {
    s.secs = s.secs + secs;
    s.cyc = s.cyc + cyc;
    s.alc = s.alc + alc;
    s.byt = s.byt + byt;
}

fn avg(s: &PhaseSum, rounds: f64) PhaseAvg {
    return PhaseAvg {
        ms: s.secs / rounds * 1000.0,
        mcyc: s.cyc as f64 / rounds / 1e6,
        kalloc: s.alc as f64 / rounds / 1e3,
        mib: s.byt as f64 / rounds / 1048576.0,
    };
}

// One table row. `share` is the phase's share of the total in percent, or negative for "(of parse)".
fn print_row(name: str, a: &PhaseAvg, src_bytes: f64, lines: f64, share: f64) {
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f".ptr() as *const char,
        name.ptr() as *const char,
        a.ms,
        src_bytes / a.ms / 1000.0,
        lines / a.ms,
        a.mcyc,
        a.kalloc,
        a.mib,
    );
    if share < 0.0 {
        unsafe stdio::printf("   (of parse)\n".ptr() as *const char);
    } else {
        unsafe stdio::printf(" %7.1f%%\n".ptr() as *const char, share);
    }
}

fn json_phase(js: &mut String, name: str, a: &PhaseAvg) {
    js.push_str(",\"");
    js.push_str(name);
    js.push_str("\":{\"ms\":");
    js.push_f64_prec(a.ms, 3);
    js.push_str(",\"mcyc\":");
    js.push_f64_prec(a.mcyc, 2);
    js.push_str(",\"kalloc\":");
    js.push_f64_prec(a.kalloc, 2);
    js.push_str(",\"mib\":");
    js.push_f64_prec(a.mib, 3);
    js.push_byte(b'}');
}

// A distribution as JSON; `scale` converts the samples' unit to the reported one.
fn json_dist(js: &mut String, name: str, sm: &bench::Summary, scale: f64) {
    js.push_str(",\"");
    js.push_str(name);
    js.push_str("\":{\"min\":");
    js.push_f64_prec(sm.min * scale, 3);
    js.push_str(",\"median\":");
    js.push_f64_prec(sm.median * scale, 3);
    js.push_str(",\"p95\":");
    js.push_f64_prec(sm.p95 * scale, 3);
    js.push_str(",\"mean\":");
    js.push_f64_prec(sm.mean * scale, 3);
    js.push_str(",\"sd\":");
    js.push_f64_prec(sm.sd * scale, 3);
    js.push_byte(b'}');
}

fn json_str(js: &mut String, s: str) {
    js.push_byte(b'"');
    for i in 0..s.len() {
        let c = s[i];
        if c == b'"' || c == b'\\' {
            js.push_byte(b'\\');
        }
        js.push_byte(c);
    }
    js.push_byte(b'"');
}

fn set_env(name: str, value: str) {
    let mut n = String::from_str(name);
    let mut v = String::from_str(value);
    let _ = unsafe dshim::sc_setenv(n.cstr(), v.cstr());
}

// Milliseconds between two boundaries of a build record.
fn build_ms(g: &bst::BuildStats, from: usize, to: usize) f64 {
    return (g.t[to] - g.t[from]) as f64 / 1000000.0;
}

// The C phase: one cold build of the compiler through the real engine (the same sources, profile flags,
// streamed compile and link a `super-c build` runs), from a scratch out-dir with every cache off. The
// engine's own record is appended to `js` and summarized; a failing compiler, C compiler or linker fails
// the benchmark and the scratch tree stays for inspection.
fn real_build(js: &mut String) bool {
    let mut dir = String::from_str(str::from_cstr(unsafe dshim::sc_tmpdir()));
    dir.push_str("/sc_bench_build");
    let _ = unsafe dshim::sc_rm_rf(dir.cstr());
    let m0 = mf::load("build.toml");
    if m0.is_none() {
        eprintln("bench: cannot load build.toml (run from the repo root)");
        return false;
    }
    let mut m = m0.unwrap();
    m.out_dir = dir.clone();
    // Cold on every axis the engine caches on: no global object cache, no emit stamp, no ccache; the
    // scratch out-dir starts without a per-TU cache.
    set_env("SC_NO_CACHE", "1");
    set_env("SC_NO_EMIT_CACHE", "1");
    set_env("CCACHE_DISABLE", "1");
    let jobs = (unsafe dshim::sc_ncpu()) as u32;
    let mut bin = dir.clone();
    bin.push_str("/super-c");
    bst::arm();
    let rc = bsys::manifest_build(
        &m,
        "dev",
        bin.as_str(),
        jobs,
        STD_DIR,
        0,
        0,
        unsafe dshim::sc_host_platform(),
        false,
        true,
    );
    let gp = bst::last();
    if gp == null {
        eprintln("bench: the build produced no statistics record");
        return false;
    }
    let g = unsafe &*gp;
    js.push_str(",\"build\":");
    bst::json(g, js);
    let overlap_ms = bst::cc_overlap_ns(g) as f64 / 1000000.0;
    unsafe stdio::printf(
        "  build (dev, jobs=%u, cold): transpile %.1f ms | sync %.1f ms | compile %.1f ms after emit (streamed span %.1f ms, busy %.1f ms, overlap %.1f ms) | link %.1f ms | total %.1f ms\n".ptr() as *const char,
        g.jobs,
        build_ms(g, bst::B_START, bst::B_PUBLISH),
        build_ms(g, bst::B_PUBLISH, bst::B_SYNC),
        build_ms(g, bst::B_SYNC, bst::B_COMPILE),
        (g.cc_last_ns - g.cc_first_ns) as f64 / 1000000.0,
        g.cc_busy_ns as f64 / 1000000.0,
        overlap_ms,
        build_ms(g, bst::B_COMPILE, bst::B_LINK),
        build_ms(g, bst::B_START, bst::B_LINK),
    );
    unsafe stdio::printf(
        "    %zu C units, %zu compiled, %.*s, ccache wrapper %s (CCACHE_DISABLE=1), object cache off, emit cache off, peak RSS %.1f MiB\n".ptr() as *const char,
        g.total_c,
        g.stale_n,
        g.cc_version.len() as i32,
        g.cc_version.as_str().ptr() as *const char,
        if g.ccache {
            "present".ptr() as *const char;
        } else {
            "absent".ptr() as *const char;
        },
        g.rss[4] as f64 / 1048576.0,
    );
    bst::release();
    if rc != 0 {
        eprintln("bench: the real build failed (exit {}); its outputs are kept under {}", rc, dir.as_str());
        return false;
    }
    let _ = unsafe dshim::sc_rm_rf(dir.cstr());
    return true;
}

fn run_report(b: &mut bench::Bencher) bool {
    let warm = transpile_once(); // warm caches + report corpus size
    if warm.modules == 0 || warm.out_bytes == 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "transpile-bench: failed to transpile %s (run from the repo root)\n".ptr() as *const char,
            ROOT.ptr() as *const char,
        );
        return false;
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
    let mut bid = String::from_str(bench::build_id());
    unsafe stdio::printf(
        "  %zu AST nodes;  %s;  build %s;  single-threaded, %d rounds\n\n".ptr() as *const char,
        warm.nodes,
        (&cpu[0]) as *const char,
        bid.cstr(),
        ITERS,
    );

    let mut s_lex = phase_sum_new();
    let mut s_parse = phase_sum_new();
    let mut s_resolve = phase_sum_new();
    let mut s_tc = phase_sum_new();
    let mut s_bck = phase_sum_new();
    let mut s_cg = phase_sum_new();
    let mut heap_bytes: i64 = 0;
    let mut totals_ms = Vector::<f64>::with_capacity(ITERS as usize);
    let mut totals_mcyc = Vector::<f64>::with_capacity(ITERS as usize);
    while b.running() {
        let t = transpile_once();
        phase_add(&mut s_lex, t.lex, t.cyc_lex, t.alc_lex, t.byt_lex);
        phase_add(&mut s_parse, t.parse, t.cyc_parse, t.alc_parse, t.byt_parse);
        phase_add(&mut s_resolve, t.resolve, t.cyc_resolve, t.alc_resolve, t.byt_resolve);
        phase_add(&mut s_tc, t.typecheck, t.cyc_typecheck, t.alc_typecheck, t.byt_typecheck);
        phase_add(&mut s_bck, t.borrowck, t.cyc_borrowck, t.alc_borrowck, t.byt_borrowck);
        phase_add(&mut s_cg, t.codegen, t.cyc_codegen, t.alc_codegen, t.byt_codegen);
        heap_bytes = heap_bytes + t.heap_bytes;
        totals_ms.push((t.parse + t.resolve + t.typecheck + t.borrowck + t.codegen) * 1000.0);
        totals_mcyc.push((t.cyc_parse + t.cyc_resolve + t.cyc_typecheck + t.cyc_borrowck + t.cyc_codegen) as f64 / 1e6);
    }
    let rounds = totals_ms.len();
    assert(rounds == ITERS as usize);
    let fi = rounds as f64;
    let a_lex = avg(&s_lex, fi);
    let a_parse = avg(&s_parse, fi);
    let a_resolve = avg(&s_resolve, fi);
    let a_tc = avg(&s_tc, fi);
    let a_bck = avg(&s_bck, fi);
    let a_cg = avg(&s_cg, fi);
    // Lexing is the lexer's share OF parse (package_load scans while it parses), so it is not a term.
    let a_total = PhaseAvg {
        ms: a_parse.ms + a_resolve.ms + a_tc.ms + a_bck.ms + a_cg.ms,
        mcyc: a_parse.mcyc + a_resolve.mcyc + a_tc.mcyc + a_bck.mcyc + a_cg.mcyc,
        kalloc: a_parse.kalloc + a_resolve.kalloc + a_tc.kalloc + a_bck.kalloc + a_cg.kalloc,
        mib: a_parse.mib + a_resolve.mib + a_tc.mib + a_bck.mib + a_cg.mib,
    };
    let srcf = warm.src_bytes as f64; // source MB/s for an avg-ms figure = srcf / ms / 1000
    let linesf = warm.src_lines as f64; // lines/sec in thousands (kloc/s) for an avg-ms figure = linesf / ms

    // Per-phase CPU cycles at the same boundaries as the ms timings; all-zero when this box has no
    // cycle source. Effective clock: Mcyc/ms == GHz (counted only while on-core, so P/E scheduling
    // shows up here). Kalloc counts malloc/calloc/realloc calls by the compiler's own code (all-zero
    // when the shim has no counting on this platform); MiB is the bytes those calls requested.
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
    print_row("lex", &a_lex, srcf, linesf, -1.0);
    print_row("parse", &a_parse, srcf, linesf, a_parse.ms / a_total.ms * 100.0);
    print_row("resolve", &a_resolve, srcf, linesf, a_resolve.ms / a_total.ms * 100.0);
    print_row("typecheck", &a_tc, srcf, linesf, a_tc.ms / a_total.ms * 100.0);
    print_row("borrowck", &a_bck, srcf, linesf, a_bck.ms / a_total.ms * 100.0);
    print_row("codegen", &a_cg, srcf, linesf, a_cg.ms / a_total.ms * 100.0);
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f   (%.2f GHz)\n\n".ptr() as *const char,
        "total".ptr() as *const char,
        a_total.ms,
        srcf / a_total.ms / 1000.0,
        linesf / a_total.ms,
        a_total.mcyc,
        a_total.kalloc,
        a_total.mib,
        a_total.mcyc / a_total.ms,
    );

    // The distributions over the rounds: CPU ms and cycles of the pipeline, and the Bencher's wall
    // clock of the same rounds (its line, below). A wide spread means the box was not quiet.
    let sm_ms = bench::summarize(&mut totals_ms);
    let sm_cyc = bench::summarize(&mut totals_mcyc);
    unsafe stdio::printf(
        "  cpu ms      min %8.2f | median %8.2f | p95 %8.2f | sd %7.2f\n".ptr() as *const char,
        sm_ms.min,
        sm_ms.median,
        sm_ms.p95,
        sm_ms.sd,
    );
    unsafe stdio::printf(
        "  Mcyc        min %8.1f | median %8.1f | p95 %8.1f | sd %7.1f\n".ptr() as *const char,
        sm_cyc.min,
        sm_cyc.median,
        sm_cyc.p95,
        sm_cyc.sd,
    );
    b.report();
    let mut wall = Vector::<f64>::with_capacity(rounds);
    let ws = b.samples();
    for i in 0..ws.len() {
        wall.push(ws[i]);
    }
    let sm_wall = bench::summarize(&mut wall);
    unsafe stdio::printf(
        "  codegen emits %.1f KiB C at %.1f MB/s;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
        warm.out_bytes as f64 / 1024.0,
        warm.out_bytes as f64 / a_cg.ms / 1000.0,
        srcf / sm_ms.min / 1000.0,
    );
    let rss = unsafe dshim::sc_peak_rss();
    unsafe stdio::printf(
        "  heap: %.1f MiB requested per round;  peak RSS %.1f MiB\n\n".ptr() as *const char,
        heap_bytes as f64 / fi / (1024.0 * 1024.0),
        rss as f64 / (1024.0 * 1024.0),
    );

    let mut js = String::with_capacity(4096);
    js.push_str("{\"v\":1,\"build_id\":");
    json_str(&mut js, bid.as_str());
    js.push_str(",\"cpu\":");
    json_str(&mut js, str::from_cstr(&cpu[0]));
    js.push_str(",\"rounds\":");
    js.push_u64(rounds as u64);
    js.push_str(",\"jobs\":1,\"corpus\":{\"modules\":");
    js.push_u64(warm.modules as u64);
    js.push_str(",\"decls\":");
    js.push_u64(warm.decls as u64);
    js.push_str(",\"lines\":");
    js.push_u64(warm.src_lines as u64);
    js.push_str(",\"tokens\":");
    js.push_u64(warm.tokens as u64);
    js.push_str(",\"nodes\":");
    js.push_u64(warm.nodes as u64);
    js.push_str(",\"src_bytes\":");
    js.push_u64(warm.src_bytes as u64);
    js.push_str(",\"c_bytes\":");
    js.push_u64(warm.out_bytes as u64);
    js.push_str("},\"phases\":{\"lex\":{\"ms\":");
    js.push_f64_prec(a_lex.ms, 3);
    js.push_str(",\"mcyc\":");
    js.push_f64_prec(a_lex.mcyc, 2);
    js.push_str(",\"kalloc\":");
    js.push_f64_prec(a_lex.kalloc, 2);
    js.push_str(",\"mib\":");
    js.push_f64_prec(a_lex.mib, 3);
    js.push_byte(b'}');
    json_phase(&mut js, "parse", &a_parse);
    json_phase(&mut js, "resolve", &a_resolve);
    json_phase(&mut js, "typecheck", &a_tc);
    json_phase(&mut js, "borrowck", &a_bck);
    json_phase(&mut js, "codegen", &a_cg);
    json_phase(&mut js, "total", &a_total);
    js.push_byte(b'}');
    json_dist(&mut js, "cpu_ms", &sm_ms, 1.0);
    json_dist(&mut js, "mcyc", &sm_cyc, 1.0);
    json_dist(&mut js, "wall_ms", &sm_wall, 1000.0);
    js.push_str(",\"heap_mib\":");
    js.push_f64_prec(heap_bytes as f64 / fi / 1048576.0, 3);
    js.push_str(",\"peak_rss_mib\":");
    js.push_f64_prec(rss as f64 / 1048576.0, 3);

    let ok = real_build(&mut js);
    js.push_str(",\"ok\":");
    js.push_str(
        if ok {
            "true";
        } else {
            "false";
        },
    );
    js.push_str("}\n");
    let outp = stdlib::getenv("SC_BENCH_OUT");
    if outp != null {
        let path = str::from_cstr(outp);
        let f = stdio::fopen(path, "wb");
        if f == null {
            eprintln("bench: cannot write '{}'", path);
            return false;
        }
        unsafe stdio::fwrite(js.as_str().ptr(), 1, js.len(), f);
        unsafe stdio::fclose(f);
        unsafe stdio::printf("  record: %.*s\n".ptr() as *const char, path.len() as i32, path.ptr() as *const char);
    }
    return ok;
}
