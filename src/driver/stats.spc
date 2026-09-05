// Build statistics for one engine build: a monotonic timestamp at every phase boundary, memory
// samples at the five reporting boundaries, and the span of the streamed C compile, published as
// one JSON object when SC_BUILD_STATS names a sink ("-" is stderr; anything else is a file the
// object is appended to as one line). SC_BUILD_MEM additionally turns the runtime allocation
// tracker on for the build, so the samples carry requested bytes, allocation counts, retained
// bytes and the survivors of every earlier phase; without it those fields stay zero. With neither
// variable set every entry point returns on a null pointer and the build pays nothing.
import stdio;
import stdlib;
import driver_shim as shim;
import std::parallel::platform as platform;

// Allocation statistics of the generated runtime (super_rt.c, see driver::rt_c).
extern "C" {
    fn sc_lk_stats_enable() void;
    fn sc_lk_epoch_set(e: u32) void;
    fn sc_lk_stats(out: *mut u64) void;
}

/// Phase boundaries in pipeline order: phase `k` runs from boundary `k - 1` to boundary `k`, so
/// the phases partition the build and their sum is the total by construction.
pub const B_START: usize = 0;
pub const B_STAMP: usize = 1; // emit-stamp check
pub const B_LOAD: usize = 2; // load, lex, parse
pub const B_RESOLVE: usize = 3;
pub const B_TYPECHECK: usize = 4; // typecheck and deferred signature work
pub const B_BORROWCK: usize = 5; // Core IR lowering and borrow analysis
pub const B_CHECKS: usize = 6; // layout, facts verification, always-panics, deferred asserts
pub const B_PREPARE: usize = 7; // runtime and external C wrappers, live set, emit order
pub const B_PLAN: usize = 8; // instance discovery and C planning
pub const B_RENDER: usize = 9; // C rendering
pub const B_PUBLISH: usize = 10; // files written, per-TU cache, orphan prune
pub const B_SYNC: usize = 11; // gen tree sync and stamp write
pub const B_COMPILE: usize = 12; // external C compilation drained
pub const B_LINK: usize = 13;
pub const B_COUNT: usize = 14;

// Memory boundaries, as indexes into the samples: frontend, borrow analysis, C plan, C output
// published, build complete. Epoch `k` covers the allocations made before memory boundary `k`.
const MEM_N: usize = 5;
const EPOCHS: usize = 8; // SC_LK_EPOCHS in the runtime
const STATS_WORDS: usize = 18; // the sc_lk_stats record: 2 + 2 * EPOCHS
const LIVE_N: usize = 80; // MEM_N * EPOCHS * 2
static_assert(STATS_WORDS == 2 + 2 * EPOCHS, "the sc_lk_stats record is two counters plus a pair per epoch");
static_assert(LIVE_N == MEM_N * EPOCHS * 2, "one (count, bytes) pair per boundary and epoch");

pub struct BuildStats {
    pub t: Array<u64, B_COUNT>, // ns; 0 = boundary not reached
    pub mem_on: bool,
    pub rss: Array<i64, MEM_N>,
    pub alloc_n: Array<u64, MEM_N>,
    pub alloc_bytes: Array<u64, MEM_N>,
    pub live: Array<u64, LIVE_N>, // per boundary, per epoch: count, bytes
    pub cc_first_ns: u64,
    pub cc_last_ns: u64,
    pub cc_busy_ns: u64,
    pub cc_jobs: u64,
    pub cc_version: String,
    pub ccache: bool,
    pub skip_emit: bool,
    pub jobs: u32,
    pub total_c: usize,
    pub stale_n: usize,
    pub linked: bool,
    pub rc: i32,
    pub profile: String,
    pub bin: String,
}

static mut G_STATS: *mut BuildStats = null;
static mut G_ARMED: bool = false;

/// Collect the next build's statistics even when SC_BUILD_STATS is unset (the in-process benchmark
/// reads them back through `last`).
pub fn arm() {
    unsafe G_ARMED = true;
}

/// The statistics of the build in progress, or of the last finished one; null when collection is off.
pub fn last() *mut BuildStats {
    return unsafe G_STATS;
}

/// Drop the retained record. `finish` does this itself unless `arm` asked for the record to stay.
pub fn release() {
    let g = unsafe G_STATS;
    if g == null {
        return;
    }
    unsafe G_STATS = null;
    g.free();
    let mut ga = Global {};
    unsafe ga.dealloc(g, sizeof(BuildStats), alignof(BuildStats));
}

/// Start collecting for a build when SC_BUILD_STATS is set or `arm` was called; SC_BUILD_MEM turns
/// the allocation tracker on. Called once per engine build, before any phase work.
pub fn begin() {
    release();
    if stdlib::getenv("SC_BUILD_STATS") == null && !unsafe G_ARMED {
        return;
    }
    let mem = stdlib::getenv("SC_BUILD_MEM") != null;
    let mut ga = Global {};
    let g = (unsafe ga.alloc(sizeof(BuildStats), alignof(BuildStats))) as *mut BuildStats;
    unsafe g[0] = BuildStats {
        t: Array::<u64, B_COUNT>::new(),
        mem_on: mem,
        rss: Array::<i64, MEM_N>::new(),
        alloc_n: Array::<u64, MEM_N>::new(),
        alloc_bytes: Array::<u64, MEM_N>::new(),
        live: Array::<u64, LIVE_N>::new(),
        cc_first_ns: 0,
        cc_last_ns: 0,
        cc_busy_ns: 0,
        cc_jobs: 0,
        cc_version: String::new(),
        ccache: false,
        skip_emit: false,
        jobs: 0,
        total_c: 0,
        stale_n: 0,
        linked: false,
        rc: 0,
        profile: String::new(),
        bin: String::new(),
    };
    unsafe G_STATS = g;
    if mem {
        unsafe sc_lk_stats_enable();
        unsafe sc_lk_epoch_set(0);
    }
}

// The memory boundary a phase boundary reports at, or MEM_N for the others.
const fn mem_index(b: usize) usize {
    if b == B_TYPECHECK {
        return 0;
    }
    if b == B_BORROWCK {
        return 1;
    }
    if b == B_PLAN {
        return 2;
    }
    if b == B_PUBLISH {
        return 3;
    }
    if b == B_LINK {
        return 4;
    }
    return MEM_N;
}

/// Record that boundary `b` was reached now. Every boundary before it that was never reached
/// (a skipped emission) is stamped with the same instant, so the phases stay a partition.
pub fn mark(b: usize) {
    let g = unsafe G_STATS;
    if g == null {
        return;
    }
    assert(b < B_COUNT);
    let now = platform::now_ns();
    for i in 0..b + 1 {
        if unsafe g.t[i] == 0 {
            unsafe g.t[i] = now;
            let k = mem_index(i);
            if k < MEM_N {
                unsafe g.rss[k] = unsafe shim::sc_peak_rss();
                if unsafe g.mem_on {
                    sample(g, k);
                    unsafe sc_lk_epoch_set(k as u32 + 1);
                }
            }
        }
    }
}

// The tracker's sample at boundary k: cumulative counters and the live-by-epoch table.
fn sample(g: *mut BuildStats, k: usize) {
    let mut w = Array::<u64, STATS_WORDS>::new();
    unsafe sc_lk_stats(&mut w[0]);
    unsafe g.alloc_n[k] = w[0];
    unsafe g.alloc_bytes[k] = w[1];
    for e in 0..EPOCHS {
        unsafe g.live[(k * EPOCHS + e) * 2] = w[2 + 2 * e];
        unsafe g.live[(k * EPOCHS + e) * 2 + 1] = w[3 + 2 * e];
    }
}

/// One external C compile job ran from `start_ns` to `end_ns`.
pub fn cc_job(start_ns: u64, end_ns: u64) {
    let g = unsafe G_STATS;
    if g == null {
        return;
    }
    assert(end_ns >= start_ns);
    if unsafe g.cc_jobs == 0 || start_ns < unsafe g.cc_first_ns {
        unsafe g.cc_first_ns = start_ns;
    }
    if end_ns > unsafe g.cc_last_ns {
        unsafe g.cc_last_ns = end_ns;
    }
    unsafe g.cc_busy_ns += end_ns - start_ns;
    unsafe g.cc_jobs += 1;
}

/// The build finished with `rc`: publish the record to the SC_BUILD_STATS sink when one is named,
/// then drop it unless `arm` keeps it for `last`.
pub fn finish(rc: i32) {
    let g = unsafe G_STATS;
    if g == null {
        return;
    }
    unsafe g.rc = rc;
    mark(B_LINK);
    let sink = stdlib::getenv("SC_BUILD_STATS");
    if sink != null {
        let mut out = String::with_capacity(2048);
        json(unsafe &*g, &mut out);
        out.push_byte(b'\n');
        let path = str::from_cstr(sink);
        if path == "-" {
            unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), stdio::stderr());
        } else {
            let f = stdio::fopen(path, "ab");
            if f == null {
                eprintln("build: cannot append the build statistics to '{}'", path);
            } else {
                unsafe stdio::fwrite(out.as_str().ptr(), 1, out.len(), f);
                unsafe stdio::fclose(f);
            }
        }
    }
    if !unsafe G_ARMED {
        release();
    }
}

const PHASE_NAMES: [str<'static>; 13] = [
    "stamp",
    "load",
    "resolve",
    "typecheck",
    "borrowck",
    "checks",
    "prepare",
    "plan",
    "render",
    "publish",
    "sync",
    "compile",
    "link",
];
static_assert(B_COUNT == 14, "one phase name per boundary after the start");
const MEM_NAMES: [str<'static>; 5] = ["frontend", "borrowck", "plan", "publish", "build"];
static_assert(MEM_N == 5, "one name per memory boundary");

fn push_ms(out: &mut String, ns: u64) {
    out.push_f64_prec(ns as f64 / 1000000.0, 3);
}

fn push_mib(out: &mut String, bytes: u64) {
    out.push_f64_prec(bytes as f64 / 1048576.0, 3);
}

fn push_json_str(out: &mut String, s: str) {
    out.push_byte(b'"');
    for i in 0..s.len() {
        let c = s[i];
        if c == b'"' || c == b'\\' {
            out.push_byte(b'\\');
            out.push_byte(c);
        } else if c < 32 {
            out.push_byte(b' ');
        } else {
            out.push_byte(c);
        }
    }
    out.push_byte(b'"');
}

fn push_bool(out: &mut String, v: bool) {
    if v {
        out.push_str("true");
    } else {
        out.push_str("false");
    }
}

/// The part of the streamed C compile that ran while emission was still in progress.
pub fn cc_overlap_ns(g: &BuildStats) u64 {
    let pub_ns = g.t[B_PUBLISH];
    if g.cc_jobs == 0 || g.cc_first_ns >= pub_ns {
        return 0;
    }
    if g.cc_last_ns < pub_ns {
        return g.cc_last_ns - g.cc_first_ns;
    }
    return pub_ns - g.cc_first_ns;
}

/// The record as one JSON object (no trailing newline). Every "ms" entry is a phase of the
/// partition and `total` is their sum; the streamed C compile that overlapped emission is reported
/// under `cc` and is never part of `total`.
pub fn json(g: &BuildStats, out: &mut String) {
    out.push_str("{\"v\":1,\"ok\":");
    push_bool(out, g.rc == 0);
    out.push_str(",\"profile\":");
    push_json_str(out, g.profile.as_str());
    out.push_str(",\"bin\":");
    push_json_str(out, g.bin.as_str());
    out.push_str(",\"jobs\":");
    out.push_u64(g.jobs);
    out.push_str(",\"skip_emit\":");
    push_bool(out, g.skip_emit);
    out.push_str(",\"units\":");
    out.push_u64(g.total_c as u64);
    out.push_str(",\"stale\":");
    out.push_u64(g.stale_n as u64);
    out.push_str(",\"linked\":");
    push_bool(out, g.linked);
    out.push_str(",\"cc_version\":");
    push_json_str(out, g.cc_version.as_str());
    out.push_str(",\"ccache\":");
    push_bool(out, g.ccache);
    out.push_str(",\"ccache_disabled\":");
    push_bool(out, stdlib::getenv("CCACHE_DISABLE") != null);
    out.push_str(",\"emit_cache\":");
    push_bool(out, stdlib::getenv("SC_NO_EMIT_CACHE") == null);
    out.push_str(",\"object_cache\":");
    push_bool(out, stdlib::getenv("SC_NO_CACHE") == null);
    out.push_str(",\"tu_cache\":");
    push_bool(out, stdlib::getenv("SC_NO_TU_CACHE") == null);
    out.push_str(",\"ms\":{");
    for k in 1..B_COUNT {
        if k != 1 {
            out.push_byte(b',');
        }
        push_json_str(out, unsafe PHASE_NAMES[k - 1]);
        out.push_byte(b':');
        push_ms(out, g.t[k] - g.t[k - 1]);
    }
    out.push_str(",\"total\":");
    push_ms(out, g.t[B_LINK] - g.t[B_START]);
    out.push_str("},\"cc\":{\"jobs\":");
    out.push_u64(g.cc_jobs);
    out.push_str(",\"span_ms\":");
    push_ms(out, g.cc_last_ns - g.cc_first_ns);
    out.push_str(",\"busy_ms\":");
    push_ms(out, g.cc_busy_ns);
    out.push_str(",\"overlap_ms\":");
    push_ms(out, cc_overlap_ns(g));
    out.push_str("},\"mem\":{\"on\":");
    push_bool(out, g.mem_on);
    out.push_str(",\"boundaries\":[");
    for k in 0..MEM_N {
        if k != 0 {
            out.push_byte(b',');
        }
        out.push_byte(b'{');
        out.push_str("\"at\":");
        push_json_str(out, unsafe MEM_NAMES[k]);
        out.push_str(",\"rss_mib\":");
        push_mib(out, g.rss[k] as u64);
        out.push_str(",\"alloc_n\":");
        out.push_u64(g.alloc_n[k]);
        out.push_str(",\"alloc_mib\":");
        push_mib(out, g.alloc_bytes[k]);
        let mut live_n: u64 = 0;
        let mut live_b: u64 = 0;
        for e in 0..EPOCHS {
            live_n += g.live[(k * EPOCHS + e) * 2];
            live_b += g.live[(k * EPOCHS + e) * 2 + 1];
        }
        out.push_str(",\"live_n\":");
        out.push_u64(live_n);
        out.push_str(",\"live_mib\":");
        push_mib(out, live_b);
        // Survivors by origin: entry e is what epoch e (the phase ending at memory boundary e)
        // allocated and still holds here; e == k is the phase that just ended.
        out.push_str(",\"survivors\":[");
        for e in 0..k + 1 {
            if e != 0 {
                out.push_byte(b',');
            }
            out.push_str("{\"from\":");
            push_json_str(out, unsafe MEM_NAMES[e]);
            out.push_str(",\"n\":");
            out.push_u64(g.live[(k * EPOCHS + e) * 2]);
            out.push_str(",\"mib\":");
            push_mib(out, g.live[(k * EPOCHS + e) * 2 + 1]);
            out.push_byte(b'}');
        }
        out.push_str("]}");
    }
    out.push_str("]}}");
}
