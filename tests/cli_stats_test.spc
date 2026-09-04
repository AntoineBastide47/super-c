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
