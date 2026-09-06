// The compiler's diagnostic-counter env switches print to stderr during a build: SC_BCE_STATS (per-owner
// bounds-check tallies), SC_INLINE_STATS (inliner decisions), and SC_CEMIT_STATS (per-stage timings).
// A program with a bounds-checked loop and an inlinable helper exercises all three.
import tests::cli_harness as cli;

const PROG: str = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..32 {\n        v.push(i);\n    }\n    let mut t = 0;\n    for i in 0..v.len() {\n        t = add(t, v[i]);\n    }\n    return t - 496;\n}\n";

fn built_with(key: str) cli::CliResult {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = str::from_cstr(p.rootp());
    return cli::superc_env_in(root, key, "1", "build");
}

@test
fn bce_stats_prints_a_per_owner_line() {
    let r = built_with("SC_BCE_STATS");
    assert(r.ok(), "the build succeeds");
    assert(r.out_has("bce total"), "the bounds-check stats line is printed");
}

@test
fn inline_stats_prints_decisions() {
    let r = built_with("SC_INLINE_STATS");
    assert(r.ok(), "the build succeeds");
    assert(r.out_has("inline considered"), "the inliner stats line is printed");
}

@test
fn cemit_stats_prints_stage_timings() {
    let r = built_with("SC_CEMIT_STATS");
    assert(r.ok(), "the build succeeds");
    assert(r.out_has("cemit-stage write:"), "a cemit stage timing is printed");
}

// SC_BUILD_STATS names a sink for one JSON object per engine build: every phase of the partition, the
// streamed C compile span, and the cache switches. "-" is stderr, which the harness captures.
@test
fn build_stats_prints_one_json_record() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "-", "build");
    assert(r.ok(), "the build succeeds");
    assert(r.out_shows("{\"v\":1,\"ok\":true,\"profile\":\"dev\""), "the record opens with its version and outcome");
    assert(r.out_has("\"ms\":{\"stamp\":"), "the phase partition starts at the stamp check");
    assert(r.out_has(",\"link\":"), "and ends at the link");
    assert(r.out_has(",\"total\":"), "the total is reported");
    assert(r.out_has("\"cc\":{\"jobs\":"), "the streamed C compile is reported apart from the partition");
    assert(r.out_has("\"mem\":{\"on\":false"), "memory tracking is off without SC_BUILD_MEM");
    assert(r.out_has("\"emit_cache\":true"), "the cache switches are recorded");
}

// SC_BUILD_MEM turns the runtime allocation tracker on for the build: the record then carries the
// allocation calls, requested bytes, live bytes and the per-phase survivors at every memory boundary.
@test
fn build_mem_records_allocation_counters() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = str::from_cstr(p.rootp());
    // The child environment is a space-separated NAME=VALUE list, so the value carries the second switch.
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "- SC_BUILD_MEM=1", "build");
    assert(r.ok(), "the build succeeds");
    if r.out_shows("\"mem\":{\"on\":false") {
        // A compiler built by a bootstrap whose runtime predates the tracker's counters has no
        // allocation columns to record (CI tests that binary before it rebuilds itself).
        return;
    }
    assert(r.out_shows("\"mem\":{\"on\":true"), "memory tracking is on");
    assert(r.out_has("{\"at\":\"frontend\",\"rss_mib\":"), "the frontend boundary is sampled");
    assert(r.out_has("{\"at\":\"build\",\"rss_mib\":"), "and the build-complete boundary");
    assert(!r.out_has("\"alloc_n\":0,"), "every boundary saw allocation calls");
    assert(
        r.out_has("\"survivors\":[{\"from\":\"frontend\""),
        "survivors are attributed to the phase that allocated them",
    );
}
