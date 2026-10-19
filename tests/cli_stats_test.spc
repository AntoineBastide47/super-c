// The compiler's diagnostic-counter env switches print to stderr during a build: SC_BCE_STATS (per-owner
// bounds-check tallies), SC_INLINE_STATS (inliner decisions), and SC_CEMIT_STATS (per-stage timings).
// A program with a bounds-checked loop and an inlinable helper exercises all three.
import tests::cli_harness as cli;

const PROG: str = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    for i in 0..32 {\n        v.push(i);\n    }\n    let mut t = 0;\n    for i in 0..v.len() {\n        t = add(t, v[i]);\n    }\n    return t - 496;\n}\n";

// A void callee has no return slot while its call keeps one void destination: the inliner accepts
// that shape, so `main`'s one call splices in.
@test
fn inline_splices_a_void_callee() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "fn bump(p: &mut i32) {\n    *p = *p + 1;\n}\nfn main() i32 {\n    let mut x = 1;\n    bump(&mut x);\n    return x - 2;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_INLINE_STATS", "1", "build");
    assert(r.ok(), "the build succeeds");
    assert(r.out_has("inline considered 1 inlined 1 "), "the void call is inlined");
}

// One build with every report switch on. SC_BUILD_STATS names a sink for one JSON object per engine build:
// every phase of the partition, the streamed C compile span, and the cache switches ("-" is stderr, which
// the harness captures). SC_BCE_STATS, SC_INLINE_STATS and SC_CEMIT_STATS print their own lines.
@test
fn stats_switches_report_in_one_build() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "- SC_BCE_STATS=1 SC_INLINE_STATS=1 SC_CEMIT_STATS=1", "build");
    assert(r.ok(), "the build succeeds");
    assert(r.out_has("bce total"), "the bounds-check stats line is printed");
    assert(r.out_has("inline considered"), "the inliner stats line is printed");
    assert(r.out_has("cemit-stage write:"), "a cemit stage timing is printed");
    assert(r.out_shows("{\"v\":1,\"ok\":true,\"profile\":\"debug\""), "the record opens with its version and outcome");
    assert(r.out_has("\"ms\":{\"stamp\":"), "the phase partition starts at the stamp check");
    assert(r.out_has(",\"link\":"), "and ends at the link");
    assert(r.out_has(",\"total\":"), "the total is reported");
    assert(r.out_has("\"cc\":{\"jobs\":"), "the streamed C compile is reported apart from the partition");
    assert(r.out_has("\"mem\":{\"on\":false"), "memory tracking is off without SC_BUILD_MEM");
    assert(r.out_has("\"emit_cache\":true"), "the cache switches are recorded");
    assert(r.out_has("\"lto\":\"flags\",\"lto_reason\":\"\""), "the debug profile leaves LTO to its flag arrays");
}

// SC_BUILD_MEM turns the runtime allocation tracker on for the build: the record then carries the
// allocation calls, requested bytes, live bytes and the per-phase survivors at every memory boundary.
@test
fn build_mem_records_allocation_counters() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", PROG);
    let root = p.dir();
    // The child environment is a space-separated NAME=VALUE list, so the value carries the second switch.
    let r = cli::superc_env_in(root, "SC_BUILD_STATS", "- SC_BUILD_MEM=1", "build");
    assert(r.ok(), "the build succeeds");
    assert(r.out_shows("\"mem\":{\"on\":true"), "memory tracking is on");
    assert(r.out_has("{\"at\":\"frontend\",\"rss_mib\":"), "the frontend boundary is sampled");
    assert(r.out_has("{\"at\":\"build\",\"rss_mib\":"), "and the build-complete boundary");
    assert(!r.out_has("\"alloc_n\":0,"), "every boundary saw allocation calls");
    assert(
        r.out_has("\"survivors\":[{\"from\":\"frontend\""),
        "survivors are attributed to the phase that allocated them",
    );
}

// A method whose signature computes a width (`V<{N + 1}>`) gives a speculative instance no new width:
// the instance graph would otherwise chain V<3>, V<4>, ... until its walk budget stops it. The called
// width is still defined.
@test
fn computed_width_signature_does_not_chain() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile(
        "src/main.spc",
        "struct V<const N: usize> {\n    pub e: [i32; N],\n}\nextend<const N: usize> V<N> {\n    fn grow(self: V<N>, s: i32) V<{N + 1}> {\n        let mut r = V::<{N + 1}> { e: [s; N + 1] };\n        for i in 0..N {\n            unsafe {\n                r.e[i] = self.e[i];\n            }\n        }\n        return r;\n    }\n}\nfn main() i32 {\n    let v = V::<2> { e: [1, 2] };\n    let w = v.grow(3);\n    return w.e[0] + w.e[1] + w.e[2] - 6;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "run");
    assert(r.ok(), "the program builds and returns 0");
    assert(r.out_has("cemit-stage collect:"), "the collect line is printed");
    assert(!r.out_has("budget exhausted"), "the instance graph closes within its budget");
}
