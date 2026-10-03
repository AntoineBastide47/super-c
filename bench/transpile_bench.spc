// Self-hosted benchmark: how long does the compiler take to transpile the WHOLE super-c compiler to C?
// Each round runs the transpile step a `super-c build` runs (`bsys::root_transpile`, the engine's own
// function: emit-stamp check, load, resolve, typecheck, borrowck, checks, prepare, plan, render and
// publish of src/main.spc's closure into a fresh scratch tree, serial) and samples CPU time, cycles and
// allocations at the build's own phase boundaries through `bst::set_hook`, so the lane cannot drift from
// what a build does. A lexer-only pass over the same sources follows each round, outside the total.
// After the rounds, one cold build of the compiler runs through the real build engine (the same sources,
// flags, streamed C compile and link a `super-c build` runs) and its phase record is reported; a C
// compiler or linker failure there fails the benchmark.
import module::loader as loader;
import lexer::lexer as lexer;
import driver::emit as demit;
import driver::stats as bst;
import build_system::build as bsys;
import build_system::manifest as mf;
import std::testing::bench_sys as sys;
import std::testing::bench as bench;
import driver_shim as dshim;
import stdio;
import stdlib;
import time;

const ROOT: str = "src/main.spc";
const STD_DIR: str = "std";
const BUILD_PROFILE: str = "dev";
const ITERS: i32 = 100;

// The phases of a round: the build's boundaries B_START..B_PUBLISH, phase k running from boundary k to
// boundary k + 1. B_LOAD ends `parse` (load, lex and parse every module).
const PH_N: usize = 10;
const NB: usize = 11;
static_assert(bst::B_PUBLISH == PH_N && NB == PH_N + 1, "one phase per boundary from B_STAMP to B_PUBLISH");
const PH_NAMES: [str<'static>; 10] = [
    "stamp",
    "parse",
    "resolve",
    "typecheck",
    "borrowck",
    "checks",
    "prepare",
    "plan",
    "render",
    "publish",
];
// The emission's phases: plan, render, publish.
const PH_EMIT: usize = 7;

// The in-process counters at every boundary of one round; bit b of `seen` = boundary b was sampled.
struct Marks {
    pub secs: Array<f64, NB>,
    pub cyc: Array<i64, NB>,
    pub alc: Array<i64, NB>,
    pub byt: Array<i64, NB>,
    pub seen: u32,
}

fn sample(mk: &mut Marks, b: usize) {
    mk.secs[b] = time::cpu_seconds();
    mk.cyc[b] = unsafe sys::sc_bs_cycles();
    mk.alc[b] = unsafe sys::sc_bs_alloc_calls();
    mk.byt[b] = unsafe sys::sc_bs_alloc_bytes();
    mk.seen = mk.seen | 1u32 << b as u32;
}

// The phase hook: the build's boundaries past B_PUBLISH (sync, compile, link) never run in a round.
fn on_mark(ctx: *mut void, b: usize) {
    if b < NB {
        sample(unsafe &mut *(ctx as *mut Marks), b);
    }
}

// The warm-up round's sink: the bytes of every C file the emission writes, headers and sources.
fn count_bytes(ctx: *mut void, path: str, _kind: i32) {
    let f = stdio::fopen(path, "rb");
    if f == null {
        return;
    }
    let _ = unsafe stdio::fseek(f, 0, stdio::SEEK_END);
    let n = unsafe stdio::ftell(f);
    unsafe stdio::fclose(f);
    if n > 0 {
        let total = ctx as *mut usize;
        unsafe total[0] = unsafe total[0] + n as usize;
    }
}

// One round: the transpile step into a fresh tree under `pdir`, every boundary sampled into `mk`. False
// when the transpile failed or skipped a boundary.
fn transpile_round(m: &mf::Manifest, cx: &bsys::BuildCtx, pdir: &mut String, sink: *mut demit::EmitSink, mk: &mut Marks) bool {
    let _ = unsafe dshim::sc_rm_rf(pdir.cstr());
    mk.seen = 0;
    sample(mk, bst::B_START);
    let hook = bst::PhaseHook { ctx: mk as *mut Marks, at: on_mark };
    bst::set_hook(&hook);
    let rc = bsys::root_transpile(m, BUILD_PROFILE, cx, sink);
    bst::set_hook(null);
    return rc == 0 && mk.seen == (1u32 << NB as u32) - 1;
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

const fn phase_sum_new() PhaseSum {
    return PhaseSum { secs: 0.0, cyc: 0, alc: 0, byt: 0 };
}

const fn phase_add(s: &mut PhaseSum, secs: f64, cyc: i64, alc: i64, byt: i64) {
    s.secs = s.secs + secs;
    s.cyc = s.cyc + cyc;
    s.alc = s.alc + alc;
    s.byt = s.byt + byt;
}

const fn avg(s: &PhaseSum, rounds: f64) PhaseAvg {
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

fn set_env(name: str, value: str) {
    let mut n = String::from_str(name);
    let mut v = String::from_str(value);
    let _ = unsafe dshim::sc_setenv(n.cstr(), v.cstr());
}

// Milliseconds between two boundaries of a build record.
const fn build_ms(g: &bst::BuildStats, from: usize, to: usize) f64 {
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
    let m0 = mf::load("build.toml", false);
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
    let cx = bsys::BuildCtx {
        jobs: jobs,
        std_dir: STD_DIR,
        ce_steps: 0,
        ce_mem: 0,
        target: unsafe dshim::sc_host_platform(),
        bootstrap_tags: false,
        lint: true,
        transpiler: "",
    };
    let rc = bsys::manifest_build(&m, BUILD_PROFILE, bin.as_str(), &cx);
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
    // The whole partition, one entry per engine phase (wall ms).
    unsafe stdio::printf("    phases:".ptr() as *const char);
    for k in 1..bst::B_COUNT {
        let nm = unsafe bst::PHASE_NAMES[k - 1];
        unsafe stdio::printf(
            " %.*s %.1f".ptr() as *const char,
            nm.len() as i32,
            nm.ptr() as *const char,
            build_ms(g, k - 1, k),
        );
    }
    unsafe stdio::printf(" ms\n".ptr() as *const char);
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

// This one keeps its own report: a per-phase table (with MB/s and allocations) is the point of it, and no
// generic timing loop can produce that. The Bencher still drives the rounds and keeps the wall-time
// distribution of every round; the table sums the in-process counters of the same rounds. Any failure (a
// corpus that does not load, a round that fails, a real build whose C compiler or linker fails) is
// reported to the runner, so the run exits nonzero.
@bench(log_results = false)
/// Benchmark lane: the compiler transpiles its own source, ITERS timed rounds, then one real cold build.
pub fn self_transpile(b: &mut bench::Bencher) {
    // The warm-up round below is untimed; every round the Bencher runs is a sample. This lane reads the
    // allocation counters at every phase boundary of every round, so accounting stays on throughout and
    // the Bencher runs no diagnostic rounds of its own: the reported figures are instrumented ones, the
    // same protocol the accepted-work ledger measured.
    b.set_rounds(ITERS);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    unsafe sys::sc_bs_alloc_enable(1);
    if !run_report(b) {
        bench::fail("self_transpile");
    }
}

fn run_report(b: &mut bench::Bencher) bool {
    // The corpus, counted once and untimed, and the sources the lexer-only pass scans every round. The
    // package is dropped before the rounds, so their memory figures hold the rounds alone.
    let mut srcs = Vector::<String>::new();
    let mut src_bytes: usize = 0;
    let mut src_lines: usize = 0;
    let mut nodes: usize = 0;
    let mut decls: usize = 0;
    {
        let p = loader::package_load(ROOT, STD_DIR, false, unsafe dshim::sc_host_platform());
        if !p.ok || p.modules.len() == 0 {
            unsafe stdio::fprintf(
                stdio::stderr(),
                "transpile-bench: failed to load %s (run from the repo root)\n".ptr() as *const char,
                ROOT.ptr() as *const char,
            );
            return false;
        }
        for i in 0..p.modules.len() {
            let md = &p.modules[i];
            let s = md.source.as_str();
            src_bytes += s.len();
            for j in 0..s.len() {
                if s[j] == b'\n' {
                    src_lines += 1;
                }
            }
            nodes += md.ast.nodes.len();
            decls += md.ast.at_const(md.ast.root).as_data.program.items.len as usize;
            srcs.push(String::from_str(s));
        }
    }
    let n = srcs.len();

    let m0 = mf::load("build.toml", false);
    if m0.is_none() {
        eprintln("bench: cannot load build.toml (run from the repo root)");
        return false;
    }
    let mut m = m0.unwrap();
    let mut dir = String::from_str(str::from_cstr(unsafe dshim::sc_tmpdir()));
    dir.push_str("/sc_bench_transpile");
    m.out_dir = dir.clone();
    let mut pdir = loader::join2(dir.as_str(), BUILD_PROFILE);
    // The SERIAL perf gate: the parallel stages are measured by the real build below.
    let cx = bsys::BuildCtx {
        jobs: 1,
        std_dir: STD_DIR,
        ce_steps: 0,
        ce_mem: 0,
        target: unsafe dshim::sc_host_platform(),
        bootstrap_tags: false,
        lint: true,
        transpiler: "",
    };
    let mut mk = Marks {
        secs: Array::<f64, NB>::new(),
        cyc: Array::<i64, NB>::new(),
        alc: Array::<i64, NB>::new(),
        byt: Array::<i64, NB>::new(),
        seen: 0,
    };
    // Warm-up: warms the caches and measures the C the emission writes.
    let mut out_bytes: usize = 0;
    let mut wsink = demit::EmitSink { ctx: (&mut out_bytes) as *mut usize, notify: count_bytes };
    if !transpile_round(&m, &cx, &mut pdir, &mut wsink, &mut mk) || out_bytes == 0 {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "transpile-bench: failed to transpile %s (run from the repo root)\n".ptr() as *const char,
            ROOT.ptr() as *const char,
        );
        return false;
    }
    let mut tokens: usize = 0;
    for i in 0..n {
        let mut lx = lexer::Lexer::new(srcs.index_mut(i), "");
        lx.scan_tokens();
        tokens += lx.tokens.len();
    }
    unsafe stdio::printf("\ntranspiling the super-c compiler: %s\n".ptr() as *const char, ROOT.ptr() as *const char);
    unsafe stdio::printf(
        "  %zu modules, %zu decls, %zu lines, %zu tokens, %.1f KiB source -> %.1f KiB C\n".ptr() as *const char,
        n,
        decls,
        src_lines,
        tokens,
        src_bytes as f64 / 1024.0,
        out_bytes as f64 / 1024.0,
    );
    let mut cpu = Array::<char, 256>::new();
    if unsafe sys::sc_bs_cpu_model(&mut cpu[0], 256) != 0 {
        unsafe stdio::snprintf(&mut cpu[0], 256, "%s".ptr() as *const char, "unknown CPU".ptr() as *const char);
    }
    let mut bid = String::from_str(bench::build_id());
    unsafe stdio::printf(
        "  %zu AST nodes;  %s;  build %s;  single-threaded, %d rounds of the build's transpile step (%s profile)\n\n".ptr() as *const char,
        nodes,
        (&cpu[0]) as *const char,
        bid.cstr(),
        ITERS,
        BUILD_PROFILE.ptr() as *const char,
    );

    let mut s_lex = phase_sum_new();
    let mut sums = Vector::<PhaseSum>::with_capacity(PH_N);
    for _ in 0..PH_N {
        sums.push(phase_sum_new());
    }
    let mut heap_bytes: i64 = 0;
    let mut totals_ms = Vector::<f64>::with_capacity(ITERS as usize);
    let mut totals_mcyc = Vector::<f64>::with_capacity(ITERS as usize);
    let mut ok = true;
    while b.running() {
        if !transpile_round(&m, &cx, &mut pdir, null, &mut mk) {
            eprintln("bench: a transpile round failed");
            ok = false;
            continue;
        }
        for k in 0..PH_N {
            phase_add(
                sums.index_mut(k),
                mk.secs[k + 1] - mk.secs[k],
                mk.cyc[k + 1] - mk.cyc[k],
                mk.alc[k + 1] - mk.alc[k],
                mk.byt[k + 1] - mk.byt[k],
            );
        }
        heap_bytes = heap_bytes + mk.byt[PH_N] - mk.byt[0];
        totals_ms.push((mk.secs[PH_N] - mk.secs[0]) * 1000.0);
        totals_mcyc.push((mk.cyc[PH_N] - mk.cyc[0]) as f64 / 1e6);
        // Lexer-only pass LAST so it cannot perturb the pipeline's phases: lexing is folded into `parse`,
        // so this is the lexer's share OF parse and not a term of the total.
        let lx0 = time::cpu_seconds();
        let cl0 = unsafe sys::sc_bs_cycles();
        let hl0 = unsafe sys::sc_bs_alloc_calls();
        let yl0 = unsafe sys::sc_bs_alloc_bytes();
        for i in 0..n {
            let mut lx = lexer::Lexer::new(srcs.index_mut(i), "");
            lx.scan_tokens();
        }
        phase_add(
            &mut s_lex,
            time::cpu_seconds() - lx0,
            unsafe sys::sc_bs_cycles() - cl0,
            unsafe sys::sc_bs_alloc_calls() - hl0,
            unsafe sys::sc_bs_alloc_bytes() - yl0,
        );
    }
    let _ = unsafe dshim::sc_rm_rf(dir.cstr());
    let rounds = totals_ms.len();
    if !ok || rounds != ITERS as usize {
        return false;
    }
    let fi = rounds as f64;
    let a_lex = avg(&s_lex, fi);
    let mut a_ph = Vector::<PhaseAvg>::with_capacity(PH_N);
    let mut tot = phase_sum_new();
    let mut emit = phase_sum_new();
    for k in 0..PH_N {
        a_ph.push(avg(sums.at(k), fi));
        let s = sums.at(k);
        phase_add(&mut tot, s.secs, s.cyc, s.alc, s.byt);
        if k >= PH_EMIT {
            phase_add(&mut emit, s.secs, s.cyc, s.alc, s.byt);
        }
    }
    let a_total = avg(&tot, fi);
    let a_emit = avg(&emit, fi);
    let srcf = src_bytes as f64; // source MB/s for an avg-ms figure = srcf / ms / 1000
    let linesf = src_lines as f64; // lines/sec in thousands (kloc/s) for an avg-ms figure = linesf / ms

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
    for k in 0..PH_N {
        let a = a_ph.at(k);
        print_row(unsafe PH_NAMES[k], a, srcf, linesf, a.ms / a_total.ms * 100.0);
    }
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
        "  emission (plan, render, publish) writes %.1f KiB C at %.1f MB/s;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
        out_bytes as f64 / 1024.0,
        out_bytes as f64 / a_emit.ms / 1000.0,
        srcf / sm_ms.min / 1000.0,
    );
    let rss = unsafe sys::sc_bs_rss_peak();
    unsafe stdio::printf(
        "  heap: %.1f MiB requested per round;  peak RSS %.1f MiB\n\n".ptr() as *const char,
        heap_bytes as f64 / fi / (1024.0 * 1024.0),
        rss as f64 / (1024.0 * 1024.0),
    );

    let mut js = String::with_capacity(4096);
    js.push_str("{\"v\":2,\"build_id\":");
    bench::json_str(&mut js, bid.as_str());
    js.push_str(",\"cpu\":");
    bench::json_str(&mut js, str::from_cstr(&cpu[0]));
    js.push_str(",\"rounds\":");
    js.push_u64(rounds as u64);
    js.push_str(",\"jobs\":1,\"corpus\":{\"modules\":");
    js.push_u64(n as u64);
    js.push_str(",\"decls\":");
    js.push_u64(decls as u64);
    js.push_str(",\"lines\":");
    js.push_u64(src_lines as u64);
    js.push_str(",\"tokens\":");
    js.push_u64(tokens as u64);
    js.push_str(",\"nodes\":");
    js.push_u64(nodes as u64);
    js.push_str(",\"src_bytes\":");
    js.push_u64(src_bytes as u64);
    js.push_str(",\"c_bytes\":");
    js.push_u64(out_bytes as u64);
    js.push_str("},\"phases\":{\"lex\":{\"ms\":");
    js.push_f64_prec(a_lex.ms, 3);
    js.push_str(",\"mcyc\":");
    js.push_f64_prec(a_lex.mcyc, 2);
    js.push_str(",\"kalloc\":");
    js.push_f64_prec(a_lex.kalloc, 2);
    js.push_str(",\"mib\":");
    js.push_f64_prec(a_lex.mib, 3);
    js.push_byte(b'}');
    for k in 0..PH_N {
        json_phase(&mut js, unsafe PH_NAMES[k], a_ph.at(k));
    }
    json_phase(&mut js, "total", &a_total);
    js.push_byte(b'}');
    bench::json_dist(&mut js, "cpu_ms", &sm_ms, 1.0);
    bench::json_dist(&mut js, "mcyc", &sm_cyc, 1.0);
    bench::json_dist(&mut js, "wall_ms", &sm_wall, 1000.0);
    js.push_str(",\"heap_mib\":");
    js.push_f64_prec(heap_bytes as f64 / fi / 1048576.0, 3);
    js.push_str(",\"peak_rss_mib\":");
    js.push_f64_prec(rss as f64 / 1048576.0, 3);

    let built = real_build(&mut js);
    js.push_str(",\"ok\":");
    js.push_str(
        if built {
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
    return built;
}
