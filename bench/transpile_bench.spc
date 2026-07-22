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
import borrowck::borrowck as bck;
import codegen::codegen as cg;
import consteval::consteval as ce;
import ast::ast as *;
import bench::bench_shim as shim;
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

// open_memstream state: the buf/size pointers handed to sc_memstream_open must stay at stable
// addresses for the stream's whole lifetime (flush/close write back through them) -- statics, not
// locals in a struct that would move.
static mut MEM_BUF: *mut char = null;
static mut MEM_SIZE: usize = 0;

// Codegen sink, two lanes: in-memory (pure lowering, zero I/O) vs a real file (keeps FILE writes in
// the measurement). run() alternates lanes so codegen is reported with and without I/O. Windows has
// no open_memstream, so only the file lane exists there.
@platform(!windows)
fn has_mem_sink() bool {
    return true;
}
@platform(!windows)
fn sink_open(use_mem: bool) *mut stdio::FILE {
    if use_mem {
        return (unsafe shim::sc_memstream_open(&mut MEM_BUF, &mut MEM_SIZE)) as *mut stdio::FILE;
    }
    return unsafe tmpfile();
}
@platform(!windows)
fn sink_close(f: *mut stdio::FILE, use_mem: bool) usize {
    if use_mem {
        unsafe stdio::fclose(f); // final flush updates MEM_SIZE
        let sz = MEM_SIZE;
        unsafe stdlib::free(MEM_BUF);
        MEM_BUF = null;
        return sz;
    }
    unsafe stdio::fflush(f);
    let t = unsafe stdio::ftell(f);
    unsafe stdio::fclose(f);
    if t > 0 {
        return t as usize;
    }
    return 0;
}

@platform(windows)
fn has_mem_sink() bool {
    return false;
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
fn sink_open(_use_mem: bool) *mut stdio::FILE {
    let mut buf = Array::<char, 4096>::new();
    let p = sink_path(&mut buf[0], 4096);
    return stdio::fopen(str::from_raw(p as *const u8, unsafe cstring::strlen(p)), "wb");
}
@platform(windows)
fn sink_close(f: *mut stdio::FILE, _use_mem: bool) usize {
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
    pub propagate: f64,
    pub codegen: f64,
    pub cg_header: f64,
    pub cg_source: f64,
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
    pub cyc_propagate: i64,
    pub cyc_codegen: i64,
    pub alc_lex: i64,
    pub alc_parse: i64,
    pub alc_resolve: i64,
    pub alc_typecheck: i64,
    pub alc_borrowck: i64,
    pub alc_propagate: i64,
    pub alc_codegen: i64,
    pub heap_bytes: i64,
}

// Deferred-assert sink: a clean self-transpile produces none, so this is never actually called; it just
// satisfies flush_asserts' callback signature.
fn ignore_assert(_ctx: *mut void, _m: ModuleId, _cond: NodeId, _msg: *const char) {}

// Resolve module `i` in place (mirrors main.spc's resolve_module, without diagnostics logging).
fn resolve_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut r = res::Resolver::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = &mut r.ast;
    r.resolve();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let back = r.take_ast();
    p.modules[i].ast = back;
}

// Type-check module `i` in place (mirrors main.spc's typecheck_module).
fn typecheck_one(p: &mut loader::Package, i: usize) {
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
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let back = t.take_ast();
    p.modules[i].ast = back;
}

// Borrow-check module `i` in place (mirrors emit.spc's borrowck_module): the pipeline stage after
// typechecking, over the typed AST.
fn borrowck_one(p: &mut loader::Package, i: usize) {
    let pkg = p as *mut loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let a = m.ast;
    m.ast = Ast::new(0);
    let mut t = tc::TypeChecker::new(a, str::from_raw(src as *const u8, len), pkg);
    p.override_mod = i as ModuleId;
    p.override_ast = &mut t.ast;
    t.borrowck();
    p.override_mod = 0xFFFF;
    p.override_ast = null;
    let back = t.take_ast();
    p.modules[i].ast = back;
}

// One full transpile of the compiler, timed per phase. `use_mem` picks the codegen sink lane.
fn transpile_once(use_mem: bool) Timing {
    let mut r = Timing {
        lex: 0.0,
        parse: 0.0,
        resolve: 0.0,
        typecheck: 0.0,
        borrowck: 0.0,
        propagate: 0.0,
        codegen: 0.0,
        cg_header: 0.0,
        cg_source: 0.0,
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
        cyc_propagate: 0,
        cyc_codegen: 0,
        alc_lex: 0,
        alc_parse: 0,
        alc_resolve: 0,
        alc_typecheck: 0,
        alc_borrowck: 0,
        alc_propagate: 0,
        alc_codegen: 0,
        heap_bytes: 0,
    };

    let a0 = time::cpu_seconds();
    let c0 = unsafe shim::sc_cpu_cycles();
    let h0 = unsafe shim::sc_alloc_count();
    let y0 = unsafe shim::sc_alloc_bytes();
    let mut p = loader::package_load(ROOT, STD_DIR.ptr() as *const char, false);
    let a1 = time::cpu_seconds();
    let c1 = unsafe shim::sc_cpu_cycles();
    let h1 = unsafe shim::sc_alloc_count();

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

    i = 0;
    while i < n {
        typecheck_one(&mut p, i);
        i = i + 1;
    }
    ceval.flush_asserts(ignore_assert, null);
    let a3 = time::cpu_seconds();
    let c3 = unsafe shim::sc_cpu_cycles();
    let h3 = unsafe shim::sc_alloc_count();

    i = 0;
    while i < n {
        borrowck_one(&mut p, i);
        i = i + 1;
    }
    let a3b = time::cpu_seconds();
    let c3b = unsafe shim::sc_cpu_cycles();
    let h3b = unsafe shim::sc_alloc_count();

    loader::package_propagate_instances(&mut p);
    let a3p = time::cpu_seconds();
    let c3p = unsafe shim::sc_cpu_cycles();
    let h3p = unsafe shim::sc_alloc_count();

    let f = sink_open(use_mem);
    i = 0;
    while i < n {
        let ma = (&mut p.modules[i].ast) as *mut Ast;
        let src = p.modules[i].source.as_str().ptr() as *const char;
        let slen = p.modules[i].source.len();
        let pkg2 = (&mut p) as *mut loader::Package; // consumed on use -> fresh cast per Codegen::new
        let mut c = cg::Codegen::new(ma, str::from_raw(src as *const u8, slen), pkg2);
        c.set_multifile(true);
        let th0 = time::cpu_seconds();
        c.codegen_emit_header(f);
        let th1 = time::cpu_seconds();
        c.codegen_emit(f);
        r.cg_header = r.cg_header + (th1 - th0);
        r.cg_source = r.cg_source + (time::cpu_seconds() - th1);
        i = i + 1;
    }
    r.out_bytes = sink_close(f, use_mem);
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
    r.propagate = a3p - a3b;
    r.codegen = a4 - a3p;
    r.cyc_parse = c1 - c0;
    r.cyc_resolve = c2 - c1;
    r.cyc_typecheck = c3 - c2;
    r.cyc_borrowck = c3b - c3;
    r.cyc_propagate = c3p - c3b;
    r.cyc_codegen = c4 - c3p;
    r.alc_parse = h1 - h0;
    r.alc_resolve = h2 - h1;
    r.alc_typecheck = h3 - h2;
    r.alc_borrowck = h3b - h3;
    r.alc_propagate = h3p - h3b;
    r.alc_codegen = h4 - h3p;
    r.heap_bytes = y4 - y0;
    return r;
}

fn sort_f64(v: &mut Vector<f64>) {
    let mut i: usize = 1;
    while i < v.len() {
        let x = v[i];
        let mut j = i;
        while j > 0 && v[j - 1] > x {
            v[j] = v[j - 1];
            j = j - 1;
        }
        v[j] = x;
        i = i + 1;
    }
}

// Sorted-vector distribution line: min/median/mean/p95/stddev in ms. No-op on an empty lane
// (the mem lane on Windows).
fn dist_line(name: str, v: &mut Vector<f64>) {
    let nn = v.len();
    if nn == 0 {
        return;
    }
    sort_f64(v);
    let mut med = v[nn / 2];
    if nn % 2 == 0 {
        med = (v[nn / 2 - 1] + v[nn / 2]) / 2.0;
    }
    let p95 = v[(nn * 95 + 99) / 100 - 1];
    let mut sum: f64 = 0.0;
    let mut q: usize = 0;
    while q < nn {
        sum = sum + v[q];
        q = q + 1;
    }
    let mean = sum / nn as f64;
    let mut var: f64 = 0.0;
    q = 0;
    while q < nn {
        let d = v[q] - mean;
        var = var + d * d;
        q = q + 1;
    }
    let sd = unsafe math::sqrt(var / nn as f64);
    unsafe stdio::printf(
        "  %-18s min %.2f | median %.2f | mean %.2f | p95 %.2f | stddev %.2f ms   (%zu runs)\n".ptr() as *const char,
        name.ptr() as *const char,
        v[0] * 1000.0,
        med * 1000.0,
        mean * 1000.0,
        p95 * 1000.0,
        sd * 1000.0,
        nn,
    );
}

pub fn run() i32 {
    let warm = transpile_once(has_mem_sink()); // warm caches + report corpus size
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
    let mut sg: f64 = 0.0;
    let mut sc_m: f64 = 0.0;
    let mut sc_f: f64 = 0.0;
    let mut sch: f64 = 0.0;
    let mut scs: f64 = 0.0;
    let mut scy_l: i64 = 0;
    let mut scy_p: i64 = 0;
    let mut scy_r: i64 = 0;
    let mut scy_t: i64 = 0;
    let mut scy_g: i64 = 0;
    let mut scy_cm: i64 = 0;
    let mut scy_cf: i64 = 0;
    let mut sal_l: i64 = 0;
    let mut sal_p: i64 = 0;
    let mut sal_r: i64 = 0;
    let mut sal_t: i64 = 0;
    let mut sal_g: i64 = 0;
    let mut sal_cm: i64 = 0;
    let mut sal_cf: i64 = 0;
    let mut sb: f64 = 0.0;
    let mut scy_b: i64 = 0;
    let mut sal_b: i64 = 0;
    let mut sheap: i64 = 0;
    let mut totals_m = Vector::<f64>::with_capacity(ITERS as usize);
    let mut totals_f = Vector::<f64>::with_capacity(ITERS as usize);
    let mut k: i32 = 0;
    while k < ITERS {
        let use_mem = has_mem_sink() && k % 2 == 0;
        let t = transpile_once(use_mem);
        sp = sp + t.parse;
        sr = sr + t.resolve;
        st = st + t.typecheck;
        sb = sb + t.borrowck;
        sl = sl + t.lex;
        sg = sg + t.propagate;
        scy_l = scy_l + t.cyc_lex;
        scy_p = scy_p + t.cyc_parse;
        scy_r = scy_r + t.cyc_resolve;
        scy_t = scy_t + t.cyc_typecheck;
        scy_b = scy_b + t.cyc_borrowck;
        scy_g = scy_g + t.cyc_propagate;
        sal_l = sal_l + t.alc_lex;
        sal_p = sal_p + t.alc_parse;
        sal_r = sal_r + t.alc_resolve;
        sal_t = sal_t + t.alc_typecheck;
        sal_b = sal_b + t.alc_borrowck;
        sal_g = sal_g + t.alc_propagate;
        sheap = sheap + t.heap_bytes;
        let total = t.parse + t.resolve + t.typecheck + t.borrowck + t.propagate + t.codegen;
        if use_mem {
            sc_m = sc_m + t.codegen;
            scy_cm = scy_cm + t.cyc_codegen;
            sal_cm = sal_cm + t.alc_codegen;
            totals_m.push(total);
        } else {
            sc_f = sc_f + t.codegen;
            scy_cf = scy_cf + t.cyc_codegen;
            sal_cf = sal_cf + t.alc_codegen;
            totals_f.push(total);
        }
        // header/source split tracks the primary lane (mem when it exists, file otherwise)
        if use_mem || !has_mem_sink() {
            sch = sch + t.cg_header;
            scs = scs + t.cg_source;
        }
        k = k + 1;
    }
    let fi = ITERS as f64;
    let cm = totals_m.len();
    let cf = totals_f.len();
    // Primary codegen figure = the pure-lowering (mem) lane when it exists; the file lane otherwise.
    let mut acf: f64 = 0.0;
    if cf > 0 {
        acf = sc_f / cf as f64 * 1000.0;
    }
    let mut ac = acf;
    if cm > 0 {
        ac = sc_m / cm as f64 * 1000.0;
    }
    let ap = sp / fi * 1000.0;
    let ar = sr / fi * 1000.0;
    let at = st / fi * 1000.0;
    let ab = sb / fi * 1000.0;
    let al = sl / fi * 1000.0;
    let ag = sg / fi * 1000.0;
    let avg_total = ap + ar + at + ab + ag + ac;
    // primary-lane count for the header/source split accumulators
    let mut cp = cf;
    if cm > 0 {
        cp = cm;
    }
    let ach = sch / cp as f64 * 1000.0;
    let acs = scs / cp as f64 * 1000.0;
    let srcf = warm.src_bytes as f64; // source MB/s for an avg-ms figure = srcf / ms / 1000
    let linesf = warm.src_lines as f64; // lines/sec in thousands (kloc/s) for an avg-ms figure = linesf / ms
    // Per-phase CPU cycles at the same boundaries as the ms timings (codegen = primary lane);
    // all-zero when this box has no cycle source. Effective clock: Mcyc/ms == GHz (counted only
    // while on-core, so P/E scheduling shows up here).
    let ml = scy_l as f64 / fi / 1e6;
    let mp = scy_p as f64 / fi / 1e6;
    let mr = scy_r as f64 / fi / 1e6;
    let mt = scy_t as f64 / fi / 1e6;
    let mb = scy_b as f64 / fi / 1e6;
    let mg = scy_g as f64 / fi / 1e6;
    let mut mc: f64 = 0.0;
    if cm > 0 {
        mc = scy_cm as f64 / cm as f64 / 1e6;
    } else if cf > 0 {
        mc = scy_cf as f64 / cf as f64 / 1e6;
    }
    let mtot = mp + mr + mt + mb + mg + mc;
    // Heap allocations (malloc/calloc/realloc calls by the compiler's own code) per iteration, in
    // thousands; codegen = primary lane. All-zero when the shim has no counting on this platform.
    let kal = sal_l as f64 / fi / 1e3;
    let kap = sal_p as f64 / fi / 1e3;
    let kar = sal_r as f64 / fi / 1e3;
    let kat = sal_t as f64 / fi / 1e3;
    let kab = sal_b as f64 / fi / 1e3;
    let kag = sal_g as f64 / fi / 1e3;
    let mut kac: f64 = 0.0;
    if cm > 0 {
        kac = sal_cm as f64 / cm as f64 / 1e3;
    } else if cf > 0 {
        kac = sal_cf as f64 / cf as f64 / 1e3;
    }
    let katot = kap + kar + kat + kag + kac;

    unsafe stdio::printf(
        "  %-11s %9s %9s %9s %9s %9s %8s\n".ptr() as *const char,
        "phase".ptr() as *const char,
        "avg ms".ptr() as *const char,
        "MB/s".ptr() as *const char,
        "kloc/s".ptr() as *const char,
        "Mcyc".ptr() as *const char,
        "Kalloc".ptr() as *const char,
        "share".ptr() as *const char,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f   (of parse)\n".ptr() as *const char,
        "lex".ptr() as *const char,
        al,
        srcf / al / 1000.0,
        linesf / al,
        ml,
        kal,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "parse".ptr() as *const char,
        ap,
        srcf / ap / 1000.0,
        linesf / ap,
        mp,
        kap,
        ap / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "resolve".ptr() as *const char,
        ar,
        srcf / ar / 1000.0,
        linesf / ar,
        mr,
        kar,
        ar / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "typecheck".ptr() as *const char,
        at,
        srcf / at / 1000.0,
        linesf / at,
        mt,
        kat,
        at / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "borrowck".ptr() as *const char,
        ab,
        srcf / ab / 1000.0,
        linesf / ab,
        mb,
        kab,
        ab / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "propagate".ptr() as *const char,
        ag,
        srcf / ag / 1000.0,
        linesf / ag,
        mg,
        kag,
        ag / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f %7.1f%%\n".ptr() as *const char,
        "codegen".ptr() as *const char,
        ac,
        srcf / ac / 1000.0,
        linesf / ac,
        mc,
        kac,
        ac / avg_total * 100.0,
    );
    unsafe stdio::printf(
        "  %-11s %9.2f %9.1f %9.1f %9.0f %9.1f   (%.2f GHz)\n\n".ptr() as *const char,
        "total".ptr() as *const char,
        avg_total,
        srcf / avg_total / 1000.0,
        linesf / avg_total,
        mtot,
        katot,
        mtot / avg_total,
    );

    if cm > 0 && cf > 0 {
        unsafe stdio::printf(
            "  codegen sink: in-memory %.2f ms vs file %.2f ms  (file I/O overhead %+.1f%%)\n".ptr() as *const char,
            ac,
            acf,
            (acf - ac) / ac * 100.0,
        );
    }
    unsafe stdio::printf(
        "  codegen split: headers %.2f ms + sources %.2f ms  (primary lane)\n".ptr() as *const char,
        ach,
        acs,
    );
    dist_line("total (mem sink)", &mut totals_m);
    dist_line("total (file sink)", &mut totals_f);
    // dist_line sorts its lane, so each vector's front is now that lane's minimum.
    let mut best: f64 = 0.0;
    if cm > 0 {
        best = totals_m[0];
    } else {
        best = totals_f[0];
    }
    let tokf = warm.tokens as f64;
    unsafe stdio::printf(
        "  token throughput: lex %.1f Mtok/s, parse %.1f Mtok/s\n".ptr() as *const char,
        tokf / al / 1000.0,
        tokf / ap / 1000.0,
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
    let rss = unsafe shim::sc_peak_rss();
    unsafe stdio::printf(
        "  heap: %.1f MiB requested per iteration;  peak RSS %.1f MiB\n".ptr() as *const char,
        sheap as f64 / fi / (1024.0 * 1024.0),
        rss as f64 / (1024.0 * 1024.0),
    );
    return 0;
}
