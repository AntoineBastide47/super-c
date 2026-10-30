// Self-hosted benchmarks: how long the compiler takes on the WHOLE super-c compiler, phase by phase.
// `self_transpile`: each round runs the transpile step of an emission (`bsys::root_transpile` with no
// link: emit-stamp check, load, resolve, typecheck, borrowck, checks, prepare, plan, render and publish of
// src/main.spc's closure into a fresh scratch tree, serial), which writes the program's C (`--emit-c`).
// `self_compile`: each round runs a whole native build through the real engine (`bsys::manifest_build`,
// every cache off, a fresh scratch tree), COMPILE_ITERS rounds with one job, then COMPILE_ITERS with one
// job per core, each reported in its own table: the same front end, then the backend's phases, LIR
// lowering, LIR optimization, native code generation, publication, sync and the own linker's link.
// Both sample CPU time, cycles and allocations at the build's own phase boundaries through
// `bst::set_hook` (the backend's sub-boundaries through `bst::mark_sub`), so the lanes time the build's
// own phases. A benchmark runs the code a build runs only when built alone (`super-c bench
// --filter=self_transpile`): the coroutine and cancellation reachability is package-wide, and a benchmark
// that cancels tasks puts cancellation ticks and probes into the compiler code of the whole binary. A
// lexer-only pass over the same sources follows each round, outside the total.
// Both sample wall time too, which the throughput and the shares use. After `self_transpile`'s rounds,
// one cold build of the compiler runs through the real build engine on every core and its phase record is
// reported; a build or link failure there fails the benchmark.
import module::loader as loader;
import lexer::lexer as lexer;
import driver::emit as demit;
import driver::stats as bst;
import build_system::build as bsys;
import build_system::manifest as mf;
import std::testing::bench_sys as sys;
import std::testing::bench as bench;
import driver_shim as dshim;
import std::platform::env as penv;
import std::platform::fs;
import std::parallel::platform as platform;
import stdio;
import stdlib;
import time;

const ROOT: str = "src/main.spc";
const STD_DIR: str = "std";
// The profile every round and the real build use: the shipping one, whose LIR optimizer runs.
const BUILD_PROFILE: str = "release";
const ITERS: i32 = 100;
const COMPILE_ITERS: i32 = 25; // per job count

// The phases a lane can have, the boundaries it samples and the hook's boundary indexes: past the build's
// B_COUNT boundaries, the backend's two sub-boundaries.
const PH_MAX: usize = 15;
const NB_MAX: usize = 16;
const HOOK_N: usize = 16;
static_assert(HOOK_N == bst::S_GENERATED + 1, "a slot per build boundary and sub-boundary");

// `self_transpile`'s phases: the build's boundaries B_STAMP..B_PUBLISH, phase k running from boundary
// B_SETUP + k to B_SETUP + k + 1 (a round has no compile-side setup, so it starts at B_SETUP). B_LOAD ends
// `parse` (load, lex and parse every module).
const PH_T: usize = 10;
static_assert(bst::B_PUBLISH - bst::B_SETUP == PH_T, "one phase per boundary from B_STAMP to B_PUBLISH");
const T_NAMES: [str<'static>; 10] = [
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
// `self_compile`'s phases: every boundary of the build from B_SETUP to B_LINK, `render` split at
// S_LOWERED (`lower`: the declarations and the bodies lowered to LIR; `optimize`: the LIR optimizer) and
// `publish` at S_GENERATED (`codegen`: the native objects; `publish`: the files written).
const PH_C: usize = 15;
const C_NAMES: [str<'static>; 15] = [
    "setup",
    "stamp",
    "parse",
    "resolve",
    "typecheck",
    "borrowck",
    "checks",
    "prepare",
    "plan",
    "lower",
    "optimize",
    "codegen",
    "publish",
    "sync",
    "link",
];
// `self_compile`'s boundary per phase end, in order.
const C_ENDS: [usize; 15] = [
    bst::B_SETUP,
    bst::B_STAMP,
    bst::B_LOAD,
    bst::B_RESOLVE,
    bst::B_TYPECHECK,
    bst::B_BORROWCK,
    bst::B_CHECKS,
    bst::B_PREPARE,
    bst::B_PLAN,
    bst::S_LOWERED,
    bst::B_RENDER,
    bst::S_GENERATED,
    bst::B_PUBLISH,
    bst::B_SYNC,
    bst::B_LINK,
];

// A lane: its name, the boundary that ends each phase (`ends`, the first `n` used; the names `phase_name`
// gives), the first phase of its backend (from it on, its emission or its backend in the report), the
// rounds, and whether a round is a whole native build (else the transpile step).
struct Lane {
    pub name: str<'static>,
    pub ends: Array<usize, PH_MAX>,
    pub n: usize,
    pub back: usize,
    pub rounds: i32,
    pub native: bool,
}

// The in-process counters (wall and CPU seconds, cycles, allocations) at every boundary of one round: index 0 at the round's start, index k + 1 at
// the end of phase k; bit b of `seen` = index b was sampled. `slot[h]` is the index hook boundary h
// samples into, NONE for one the lane does not sample.
struct Marks {
    pub wall: Array<f64, NB_MAX>,
    pub secs: Array<f64, NB_MAX>,
    pub cyc: Array<i64, NB_MAX>,
    pub alc: Array<i64, NB_MAX>,
    pub byt: Array<i64, NB_MAX>,
    pub slot: Array<usize, HOOK_N>,
    pub seen: u32,
}

const NONE: usize = 0xFFFFFFFF;

fn sample(mk: &mut Marks, b: usize) {
    mk.wall[b] = platform::now_ns() as f64 / 1e9;
    mk.secs[b] = time::cpu_seconds();
    mk.cyc[b] = unsafe sys::sc_bs_cycles();
    mk.alc[b] = unsafe sys::sc_bs_alloc_calls();
    mk.byt[b] = unsafe sys::sc_bs_alloc_bytes();
    mk.seen = mk.seen | 1u32 << b as u32;
}

// The phase hook: the boundaries the lane samples (`Marks.slot`).
fn on_mark(ctx: *mut void, b: usize) {
    let mk = unsafe &mut *(ctx as *mut Marks);
    if b < HOOK_N && mk.slot[b] != NONE {
        sample(mk, mk.slot[b]);
    }
}

// The bytes of the files under `dir` whose names end with `ext` (the C a round wrote, its objects).
fn tree_bytes(dir: &mut String, ext: str) usize {
    let opened = fs::read_dir(dir.as_str());
    if opened.is_err() {
        return 0;
    }
    let mut d = opened.unwrap();
    let base = dir.len();
    let mut total: usize = 0;
    // Bounded by the entries of the directory; a read error ends the walk, as the end does.
    while let Some(Ok(e)) = d.next() {
        dir.push_byte(b'/');
        dir.push_str(e.name);
        let st = fs::stat(dir.as_str());
        if st.is_ok() {
            let md = st.unwrap();
            if md.kind == fs::FileKind::Dir {
                total += tree_bytes(dir, ext);
            } else if e.name.ends_with(ext) {
                total += md.size as usize;
            }
        }
        dir.truncate(base);
    }
    return total;
}

// One round, every boundary of `lane` sampled into `mk`: the transpile step into a fresh tree under
// `pdir`, or a whole native build into a fresh `out_dir` (`m`'s), linking `bin`. False when the build
// failed or skipped a boundary.
fn round(lane: &Lane, m: &mf::Manifest, cx: &bsys::BuildCtx, pdir: &mut String, bin: str, mk: &mut Marks) bool {
    if lane.native {
        let _ = fs::remove_all(m.out_dir.as_str());
    } else {
        let _ = fs::remove_all(pdir.as_str());
    }
    mk.seen = 0;
    sample(mk, 0);
    let hook = bst::PhaseHook { ctx: mk as *mut Marks, at: on_mark };
    bst::set_hook(&hook);
    let rc = if lane.native {
        // The record keeps the link's boundary, which the engine stamps when it finishes.
        bst::arm();
        bsys::manifest_build(m, BUILD_PROFILE, bin, "", cx);
    } else {
        bsys::root_transpile(m, BUILD_PROFILE, cx, null);
    };
    bst::set_hook(null);
    bst::release();
    return rc == 0 && mk.seen == (1u32 << (lane.n + 1) as u32) - 1;
}

// Sums of one phase over every round of a mode, converted to per-round averages by `avg`: wall and CPU
// seconds (every thread's), cycles, allocation calls and bytes.
struct PhaseSum {
    pub wall: f64,
    pub secs: f64,
    pub cyc: i64,
    pub alc: i64,
    pub byt: i64,
}

// The report's per-phase row: averages over the rounds.
struct PhaseAvg {
    pub wall: f64,
    pub ms: f64,
    pub mcyc: f64,
    pub kalloc: f64,
    pub mib: f64,
}

const fn phase_sum_new() PhaseSum {
    return PhaseSum { wall: 0.0, secs: 0.0, cyc: 0, alc: 0, byt: 0 };
}

const fn phase_add(s: &mut PhaseSum, wall: f64, secs: f64, cyc: i64, alc: i64, byt: i64) {
    s.wall = s.wall + wall;
    s.secs = s.secs + secs;
    s.cyc = s.cyc + cyc;
    s.alc = s.alc + alc;
    s.byt = s.byt + byt;
}

const fn avg(s: &PhaseSum, rounds: f64) PhaseAvg {
    return PhaseAvg {
        wall: s.wall / rounds * 1000.0,
        ms: s.secs / rounds * 1000.0,
        mcyc: s.cyc as f64 / rounds / 1e6,
        kalloc: s.alc as f64 / rounds / 1e3,
        mib: s.byt as f64 / rounds / 1048576.0,
    };
}

// The rounds of one job count: per phase sums, the lexer-only pass, the heap requested and the per-round
// wall ms, CPU ms and Mcyc of the build.
struct Mode {
    pub jobs: u32,
    pub sums: Vector<PhaseSum>,
    pub lex: PhaseSum,
    pub heap: i64,
    pub wall: Vector<f64>,
    pub cpu: Vector<f64>,
    pub mcyc: Vector<f64>,
}

fn mode_new(jobs: u32, phases: usize, rounds: usize) Mode {
    let mut sums = Vector::<PhaseSum>::with_capacity(phases);
    for _ in 0..phases {
        sums.push(phase_sum_new());
    }
    return Mode {
        jobs: jobs,
        sums: sums,
        lex: phase_sum_new(),
        heap: 0,
        wall: Vector::<f64>::with_capacity(rounds),
        cpu: Vector::<f64>::with_capacity(rounds),
        mcyc: Vector::<f64>::with_capacity(rounds),
    };
}

// One table row. `share` is the phase's share of the total wall time in percent, or negative for "(of
// parse)". Throughput is of wall time; a phase under a millisecond shows none (a dash): its figures
// would overflow their columns and measure nothing.
fn print_row(name: str, a: &PhaseAvg, src_bytes: f64, lines: f64, share: f64) {
    unsafe stdio::printf("  %-11s %9.2f %9.2f".ptr() as *const char, name.ptr() as *const char, a.wall, a.ms);
    if a.wall < 1.0 {
        unsafe stdio::printf(" %9s %9s".ptr() as *const char, "-".ptr() as *const char, "-".ptr() as *const char);
    } else {
        unsafe stdio::printf(" %9.1f %9.1f".ptr() as *const char, src_bytes / a.wall / 1000.0, lines / a.wall);
    }
    unsafe stdio::printf(" %9.0f %9.1f %9.2f".ptr() as *const char, a.mcyc, a.kalloc, a.mib);
    if share < 0.0 {
        unsafe stdio::printf("   (of parse)\n".ptr() as *const char);
    } else {
        unsafe stdio::printf(" %7.1f%%\n".ptr() as *const char, share);
    }
}

fn json_phase(js: &mut String, name: str, a: &PhaseAvg, first: bool) {
    if !first {
        js.push_byte(b',');
    }
    js.push_byte(b'"');
    js.push_str(name);
    js.push_str("\":{\"wall_ms\":");
    js.push_f64_prec(a.wall, 3);
    js.push_str(",\"cpu_ms\":");
    js.push_f64_prec(a.ms, 3);
    js.push_str(",\"mcyc\":");
    js.push_f64_prec(a.mcyc, 2);
    js.push_str(",\"kalloc\":");
    js.push_f64_prec(a.kalloc, 2);
    js.push_str(",\"mib\":");
    js.push_f64_prec(a.mib, 3);
    js.push_byte(b'}');
}

// One distribution line of the report.
fn print_dist(name: str, s: &bench::Summary) {
    unsafe stdio::printf(
        "  %-11s min %8.2f | median %8.2f | p95 %8.2f | sd %7.2f\n".ptr() as *const char,
        name.ptr() as *const char,
        s.min,
        s.median,
        s.p95,
        s.sd,
    );
}

fn set_env(name: str, value: str) {
    let _ = unsafe penv::set(name, value);
}

// Milliseconds between two boundaries of a build record.
const fn build_ms(g: &bst::BuildStats, from: usize, to: usize) f64 {
    return (g.t[to] - g.t[from]) as f64 / 1000000.0;
}

// One cold build of the compiler through the real engine (the same sources, profile flags, native
// objects and link a `super-c build` runs) on every core, from a scratch out-dir with every cache off.
// The engine's own record is appended to `js` and summarized; a failing build or link fails the
// benchmark and the scratch tree stays for inspection.
fn real_build(js: &mut String) bool {
    let mut dir = fs::temp_dir().unwrap_or(String::from_str("."));
    dir.push_str("/sc_bench_build");
    let _ = fs::remove_all(dir.as_str());
    let m0 = mf::load("build.toml", false);
    if m0.is_none() {
        eprintln("bench: cannot load build.toml (run from the repo root)");
        return false;
    }
    let mut m = m0.unwrap();
    m.out_dir = dir.clone();
    // Cold on every axis the engine caches on: no global object cache, no emit stamp; the scratch
    // out-dir starts without a per-TU cache.
    set_env("SC_NO_CACHE", "1");
    set_env("SC_NO_EMIT_CACHE", "1");
    let jobs = bsys::cpu_count();
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
    let rc = bsys::manifest_build(&m, BUILD_PROFILE, bin.as_str(), "", &cx);
    let gp = bst::last();
    if gp == null {
        eprintln("bench: the build produced no statistics record");
        return false;
    }
    let g = unsafe &*gp;
    js.push_str(",\"build\":");
    bst::json(g, js);
    unsafe stdio::printf(
        "  build (%s, jobs=%u, cold): setup %.1f ms | transpile %.1f ms | sync %.1f ms | link %.1f ms | total %.1f ms\n".ptr() as *const char,
        BUILD_PROFILE.ptr() as *const char,
        g.jobs,
        build_ms(g, bst::B_START, bst::B_SETUP),
        build_ms(g, bst::B_SETUP, bst::B_PUBLISH),
        build_ms(g, bst::B_PUBLISH, bst::B_SYNC),
        build_ms(g, bst::B_SYNC, bst::B_LINK),
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
        "    %zu objects, %zu written, emit cache off, peak RSS %.1f MiB\n".ptr() as *const char,
        g.total_c,
        g.stale_n,
        g.rss[4] as f64 / 1048576.0,
    );
    bst::release();
    if rc != 0 {
        eprintln("bench: the real build failed (exit {}); its outputs are kept under {}", rc, dir.as_str());
        return false;
    }
    let _ = fs::remove_all(dir.as_str());
    return true;
}

// Each lane keeps its own report: a per-phase table (with MB/s and allocations) is the point of it, and
// no generic timing loop can produce that. The Bencher still drives the rounds; the tables sum the
// in-process counters of the same rounds. Any failure (a corpus that does not load, a round that fails, a
// real build whose build or link fails) is reported to the runner, so the run exits nonzero.
@bench(log_results = false)
/// Benchmark lane: the compiler transpiles its own source to C, ITERS serial timed rounds, then one real
/// cold build on every core.
pub fn self_transpile(b: &mut bench::Bencher) {
    let mut lane = Lane {
        name: "self_transpile",
        ends: Array::<usize, PH_MAX>::new(),
        n: PH_T,
        back: 7,
        rounds: ITERS,
        native: false,
    };
    for k in 0..PH_T {
        lane.ends[k] = bst::B_SETUP + k + 1;
    }
    run_lane(b, &lane);
}

@bench(log_results = false)
/// Benchmark lane: the compiler builds its own source natively, COMPILE_ITERS timed rounds of a whole
/// cold build (front end, LIR lowering and optimization, code generation, publication and link) with one
/// job, then COMPILE_ITERS with one job per core.
pub fn self_compile(b: &mut bench::Bencher) {
    let mut lane = Lane {
        name: "self_compile",
        ends: Array::<usize, PH_MAX>::new(),
        n: PH_C,
        back: 9,
        rounds: COMPILE_ITERS,
        native: true,
    };
    for k in 0..PH_C {
        lane.ends[k] = unsafe C_ENDS[k];
    }
    // Every round is cold: no global object cache, no emit stamp; its fresh out-dir has no per-TU cache.
    set_env("SC_NO_CACHE", "1");
    set_env("SC_NO_EMIT_CACHE", "1");
    run_lane(b, &lane);
}

// The name of phase `k` of `lane`.
fn phase_name(lane: &Lane, k: usize) str<'static> {
    return if lane.native {
        unsafe C_NAMES[k];
    } else {
        unsafe T_NAMES[k];
    };
}

// The job counts `lane` runs its rounds with, in order: one, and for a native build one per core too.
const fn modes_of(lane: &Lane) usize {
    return if lane.native {
        2;
    } else {
        1;
    };
}

fn run_lane(b: &mut bench::Bencher, lane: &Lane) {
    // The warm-up round below is untimed; every round the Bencher runs is a sample. The lane reads the
    // allocation counters at every phase boundary of every round, so accounting stays on throughout and
    // the Bencher runs no diagnostic rounds of its own: the reported figures are instrumented ones, the
    // same protocol the accepted-work ledger measured.
    b.set_rounds(lane.rounds * modes_of(lane) as i32);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    unsafe sys::sc_bs_alloc_enable(1);
    if !run_report(b, lane) {
        bench::fail(lane.name);
    }
}

fn run_report(b: &mut bench::Bencher, lane: &Lane) bool {
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
    let nph = lane.n;
    let per = lane.rounds as usize;

    let m0 = mf::load("build.toml", false);
    if m0.is_none() {
        eprintln("bench: cannot load build.toml (run from the repo root)");
        return false;
    }
    let mut m = m0.unwrap();
    let mut dir = fs::temp_dir().unwrap_or(String::from_str("."));
    dir.push_str(
        if lane.native {
            "/sc_bench_compile";
        } else {
            "/sc_bench_transpile";
        },
    );
    m.out_dir = dir.clone();
    let mut pdir = loader::join2(dir.as_str(), BUILD_PROFILE);
    let mut bin = dir.clone();
    bin.push_str("/super-c");
    let mut modes = Vector::<Mode>::with_capacity(modes_of(lane));
    modes.push(mode_new(1, nph, per));
    if modes_of(lane) == 2 {
        modes.push(mode_new(bsys::cpu_count(), nph, per));
    }
    let mut cx = bsys::BuildCtx {
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
        wall: Array::<f64, NB_MAX>::new(),
        secs: Array::<f64, NB_MAX>::new(),
        cyc: Array::<i64, NB_MAX>::new(),
        alc: Array::<i64, NB_MAX>::new(),
        byt: Array::<i64, NB_MAX>::new(),
        slot: Array::<usize, HOOK_N>::new(),
        seen: 0,
    };
    for h in 0..HOOK_N {
        mk.slot[h] = NONE;
    }
    for k in 0..nph {
        mk.slot[lane.ends[k]] = k + 1;
    }
    // Warm-up: warms the caches and measures what a round writes: the C, or the objects and the binary.
    if !round(lane, &m, &cx, &mut pdir, bin.as_str(), &mut mk) {
        unsafe stdio::fprintf(
            stdio::stderr(),
            "transpile-bench: failed to build %s (run from the repo root)\n".ptr() as *const char,
            ROOT.ptr() as *const char,
        );
        return false;
    }
    let mut out_bytes: usize = 0;
    let mut bin_bytes: usize = 0;
    if lane.native {
        out_bytes = tree_bytes(&mut dir, ".o");
        bin_bytes = fs::stat(bin.as_str()).map(
            fn(md: fs::Metadata) usize {
                return md.size as usize;
            },
        ).unwrap_or(0);
    } else {
        out_bytes = tree_bytes(&mut pdir, ".c") + tree_bytes(&mut pdir, ".h");
    }
    if out_bytes == 0 {
        eprintln("bench: the warm-up round wrote nothing under {}", dir.as_str());
        return false;
    }
    let mut tokens: usize = 0;
    for i in 0..n {
        let mut lx = lexer::Lexer::new(srcs.index_mut(i), "");
        lx.scan_tokens();
        tokens += lx.tokens.len();
    }
    if lane.native {
        unsafe stdio::printf("\ncompiling the super-c compiler: %s\n".ptr() as *const char, ROOT.ptr() as *const char);
        unsafe stdio::printf(
            "  %zu modules, %zu decls, %zu lines, %zu tokens, %.1f KiB source -> %.1f KiB objects, %.1f KiB binary\n".ptr() as *const char,
            n,
            decls,
            src_lines,
            tokens,
            src_bytes as f64 / 1024.0,
            out_bytes as f64 / 1024.0,
            bin_bytes as f64 / 1024.0,
        );
    } else {
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
    }
    let mut cpu = Array::<char, 256>::new();
    if unsafe sys::sc_bs_cpu_model(&mut cpu[0], 256) != 0 {
        unsafe stdio::snprintf(&mut cpu[0], 256, "%s".ptr() as *const char, "unknown CPU".ptr() as *const char);
    }
    let mut bid = String::from_str(bench::build_id());
    unsafe stdio::printf(
        "  %zu AST nodes;  %s;  build %s;  %d rounds per job count of %s (%s profile)\n".ptr() as *const char,
        nodes,
        (&cpu[0]) as *const char,
        bid.cstr(),
        lane.rounds,
        if lane.native {
            "a whole native build, cold".ptr();
        } else {
            "the build's transpile step".ptr();
        } as *const char,
        BUILD_PROFILE.ptr() as *const char,
    );

    let mut ok = true;
    let mut r: usize = 0;
    while b.running() {
        let md = modes.index_mut(r / per);
        r += 1;
        cx.jobs = md.jobs;
        if !round(lane, &m, &cx, &mut pdir, bin.as_str(), &mut mk) {
            eprintln("bench: a round failed");
            ok = false;
            continue;
        }
        for k in 0..nph {
            phase_add(
                md.sums.index_mut(k),
                mk.wall[k + 1] - mk.wall[k],
                mk.secs[k + 1] - mk.secs[k],
                mk.cyc[k + 1] - mk.cyc[k],
                mk.alc[k + 1] - mk.alc[k],
                mk.byt[k + 1] - mk.byt[k],
            );
        }
        md.heap = md.heap + mk.byt[nph] - mk.byt[0];
        md.wall.push((mk.wall[nph] - mk.wall[0]) * 1000.0);
        md.cpu.push((mk.secs[nph] - mk.secs[0]) * 1000.0);
        md.mcyc.push((mk.cyc[nph] - mk.cyc[0]) as f64 / 1e6);
        // Lexer-only pass LAST so it cannot perturb the pipeline's phases: lexing is folded into `parse`,
        // so this is the lexer's share OF parse and not a term of the total.
        let lw0 = platform::now_ns();
        let lx0 = time::cpu_seconds();
        let cl0 = unsafe sys::sc_bs_cycles();
        let hl0 = unsafe sys::sc_bs_alloc_calls();
        let yl0 = unsafe sys::sc_bs_alloc_bytes();
        for i in 0..n {
            let mut lx = lexer::Lexer::new(srcs.index_mut(i), "");
            lx.scan_tokens();
        }
        phase_add(
            &mut md.lex,
            (platform::now_ns() - lw0) as f64 / 1e9,
            time::cpu_seconds() - lx0,
            unsafe sys::sc_bs_cycles() - cl0,
            unsafe sys::sc_bs_alloc_calls() - hl0,
            unsafe sys::sc_bs_alloc_bytes() - yl0,
        );
    }
    let _ = fs::remove_all(dir.as_str());
    if !ok {
        return false;
    }
    let srcf = src_bytes as f64;
    let linesf = src_lines as f64;
    let mut js = String::with_capacity(8192);
    js.push_str("{\"v\":3,\"lane\":");
    bench::json_str(&mut js, lane.name);
    js.push_str(",\"build_id\":");
    bench::json_str(&mut js, bid.as_str());
    js.push_str(",\"cpu\":");
    bench::json_str(&mut js, str::from_cbuf(cpu.as_slice()));
    js.push_str(",\"profile\":");
    bench::json_str(&mut js, BUILD_PROFILE);
    js.push_str(",\"corpus\":{\"modules\":");
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
    js.push_str(
        if lane.native {
            ",\"obj_bytes\":";
        } else {
            ",\"c_bytes\":";
        },
    );
    js.push_u64(out_bytes as u64);
    if lane.native {
        js.push_str(",\"bin_bytes\":");
        js.push_u64(bin_bytes as u64);
    }
    js.push_str("},\"modes\":[");
    for q in 0..modes.len() {
        if modes.at(q).wall.len() != per {
            return false;
        }
        if q != 0 {
            js.push_byte(b',');
        }
        report_mode(lane, modes.index_mut(q), srcf, linesf, out_bytes, &mut js);
    }
    js.push_byte(b']');
    let rss = unsafe sys::sc_bs_rss_peak();
    js.push_str(",\"peak_rss_mib\":");
    js.push_f64_prec(rss as f64 / 1048576.0, 3);
    if modes.len() == 1 {
        // One job count: the Bencher's wall clock and memory of the same rounds (the lexer-only pass
        // included).
        b.report();
    } else {
        unsafe stdio::printf("  peak RSS %.1f MiB\n".ptr() as *const char, rss as f64 / (1024.0 * 1024.0));
    }

    // A native lane's parallel rounds are cold builds on every core: no further real build.
    let mut built = true;
    if !lane.native {
        unsafe stdio::printf("\n".ptr() as *const char);
        built = real_build(&mut js);
    }
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
        let path = unsafe str::from_cstr(outp);
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

// The table and distributions of mode `md`'s rounds, and its JSON object into `js`.
fn report_mode(lane: &Lane, md: &mut Mode, srcf: f64, linesf: f64, out_bytes: usize, js: &mut String) {
    let nph = lane.n;
    let fi = md.wall.len() as f64;
    let a_lex = avg(&md.lex, fi);
    let mut a_ph = Vector::<PhaseAvg>::with_capacity(nph);
    let mut tot = phase_sum_new();
    let mut back = phase_sum_new();
    for k in 0..nph {
        let s = md.sums.at(k);
        a_ph.push(avg(s, fi));
        phase_add(&mut tot, s.wall, s.secs, s.cyc, s.alc, s.byt);
        if k >= lane.back {
            phase_add(&mut back, s.wall, s.secs, s.cyc, s.alc, s.byt);
        }
    }
    let a_total = avg(&tot, fi);
    let a_back = avg(&back, fi);

    // Per phase: wall ms, CPU ms of every thread, and CPU cycles at the same boundaries; cycles are
    // all-zero when this box has no cycle source. Effective clock: Mcyc per CPU ms == GHz (counted only
    // while on-core, so P/E scheduling shows up here); CPU ms per wall ms is the cores in use. Kalloc
    // counts malloc/calloc/realloc calls by the compiler's own code (all-zero when the shim has no
    // counting on this platform); MiB is the bytes those calls requested.
    unsafe stdio::printf("\n  jobs=%u, %zu rounds\n".ptr() as *const char, md.jobs, md.wall.len());
    unsafe stdio::printf(
        "  %-11s %9s %9s %9s %9s %9s %9s %9s %8s\n".ptr() as *const char,
        "phase".ptr() as *const char,
        "wall ms".ptr() as *const char,
        "cpu ms".ptr() as *const char,
        "MB/s".ptr() as *const char,
        "kloc/s".ptr() as *const char,
        "Mcyc".ptr() as *const char,
        "Kalloc".ptr() as *const char,
        "MiB".ptr() as *const char,
        "share".ptr() as *const char,
    );
    print_row("lex", &a_lex, srcf, linesf, -1.0);
    for k in 0..nph {
        let a = a_ph.at(k);
        print_row(phase_name(lane, k), a, srcf, linesf, a.wall / a_total.wall * 100.0);
    }
    unsafe stdio::printf(
        "  %-11s %9.2f %9.2f %9.1f %9.1f %9.0f %9.1f %9.2f   (%.2f GHz, %.1f cores)\n\n".ptr() as *const char,
        "total".ptr() as *const char,
        a_total.wall,
        a_total.ms,
        srcf / a_total.wall / 1000.0,
        linesf / a_total.wall,
        a_total.mcyc,
        a_total.kalloc,
        a_total.mib,
        a_total.mcyc / a_total.ms,
        a_total.ms / a_total.wall,
    );

    // The distributions over the rounds. A wide spread means the box was not quiet.
    let sm_wall = bench::summarize(&mut md.wall);
    let sm_ms = bench::summarize(&mut md.cpu);
    let sm_cyc = bench::summarize(&mut md.mcyc);
    print_dist("wall ms", &sm_wall);
    print_dist("cpu ms", &sm_ms);
    print_dist("Mcyc", &sm_cyc);
    if lane.native {
        unsafe stdio::printf(
            "  backend (lower, optimize, codegen, publish, sync, link) %.2f ms, %.1f%% of the build;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
            a_back.wall,
            a_back.wall / a_total.wall * 100.0,
            srcf / sm_wall.min / 1000.0,
        );
    } else {
        unsafe stdio::printf(
            "  emission (plan, render, publish) writes %.1f KiB C at %.1f MB/s;  best end-to-end %.2f MB/s source\n".ptr() as *const char,
            out_bytes as f64 / 1024.0,
            out_bytes as f64 / a_back.wall / 1000.0,
            srcf / sm_wall.min / 1000.0,
        );
    }
    unsafe stdio::printf(
        "  heap: %.1f MiB requested per round\n".ptr() as *const char,
        md.heap as f64 / fi / (1024.0 * 1024.0),
    );

    js.push_str("{\"jobs\":");
    js.push_u64(md.jobs);
    js.push_str(",\"rounds\":");
    js.push_u64(fi as u64);
    js.push_str(",\"phases\":{");
    json_phase(js, "lex", &a_lex, true);
    for k in 0..nph {
        json_phase(js, phase_name(lane, k), a_ph.at(k), false);
    }
    json_phase(js, "total", &a_total, false);
    js.push_byte(b'}');
    bench::json_dist(js, "wall_ms", &sm_wall, 1.0);
    bench::json_dist(js, "cpu_ms", &sm_ms, 1.0);
    bench::json_dist(js, "mcyc", &sm_cyc, 1.0);
    js.push_str(",\"heap_mib\":");
    js.push_f64_prec(md.heap as f64 / fi / 1048576.0, 3);
    js.push_byte(b'}');
}
