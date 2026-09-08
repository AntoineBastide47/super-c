// Build-system paths beyond a plain binary: `super-c test` over a manifest with a tests/ directory
// (the manifest test driver), and `[lib]` static and shared library builds (the library-artifact
// naming and link path). All use native subcommands, so they run on every lane.
import tests::cli_harness as cli;

const E: str = "SC_NO_EMIT_CACHE";

@test
fn manifest_test_runs_the_tests_directory() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/util.spc", "pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n");
    p.mkfile("src/main.spc", "import util;\n\nfn main() i32 {\n    return util::add(2, 3) - 5;\n}\n");
    p.mkfile("tests/t.spc", "import util;\n\n@test\nfn adds() {\n    assert_eq(util::add(2, 3), 5);\n}\n");
    let root = str::from_cstr(p.rootp());
    // `super-c test` builds the tests/ tree against the src closure and runs it.
    let r = cli::superc_env_in(root, E, "1", "test --quiet");
    assert(r.ok(), "the manifest test run succeeds");
    assert(r.out_has("passed"), "the tally is printed");
}

@test
fn static_library_build() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "[lib]\nname = \"mylib\"\nroot = \"src/lib.spc\"\ntype = [\"static\"]\n");
    p.mkfile("src/lib.spc", "pub fn util() i32 {\n    return 42;\n}\n");
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "a static library builds");
}

@test
fn shared_library_build() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "[lib]\nname = \"mylib\"\nroot = \"src/lib.spc\"\ntype = [\"shared\"]\n");
    p.mkfile("src/lib.spc", "pub fn util() i32 {\n    return 42;\n}\n");
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "a shared library builds");
}

@test
fn static_and_shared_library_build() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "[lib]\nname = \"mylib\"\nroot = \"src/lib.spc\"\ntype = [\"static\", \"shared\"]\n");
    p.mkfile("src/lib.spc", "pub fn util() i32 {\n    return 42;\n}\n");
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "both library artifacts build");
}

// A failing C compile fails the build with the child's exit status, a bounded replay of its output, and
// the path of the kept log; a later successful compile of the same unit removes the log.
@test
fn failed_c_compile_reports_status_and_keeps_the_log() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/bad.h", "int bad_value(void);\n");
    // A missing semicolon: every C compiler rejects it (a bare `return` in a non-void function is
    // only a warning under gcc).
    p.mkfile("src/bad.c", "#include \"bad.h\"\nint bad_value(void) { return 0 }\n");
    p.mkfile(
        "src/main.spc",
        "extern \"C\" \"bad.h\" {\n    fn bad_value() i32;\n}\nfn main() i32 {\n    return unsafe bad_value();\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "build");
    assert(r.exit != 0, "the build fails");
    assert(
        r.out_shows("build: C compile failed (exit 1); output kept at "),
        "the exit status and the log path are reported",
    );
    assert(r.out_shows("_bad.o.log"), "the log is the unit's own");
    assert(r.out_shows("error:"), "the compiler's diagnostic is replayed");
    p.mkfile("src/bad.c", "#include \"bad.h\"\nint bad_value(void) { return 0; }\n");
    let ok = cli::superc_env_in(root, E, "1", "build");
    assert(ok.ok(), "the corrected unit builds");
    let mut obj = String::from_str(root);
    obj.push_str("/build/dev/obj");
    assert_eq(cli::dir_count_suffix(obj.as_str(), "_bad.o.log"), 0);
}

// An edit that lands in the same second as the previous compile of its unit still recompiles it:
// mtimes have second granularity, so the engine tracks what the emit sync rewrote in this build.
@test
fn same_second_edit_recompiles() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 3;\n}\n");
    let root = str::from_cstr(p.rootp());
    let first = cli::superc_env_in(root, E, "1", "run");
    assert_eq(first.exit, 3);
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 4;\n}\n");
    let second = cli::superc_env_in(root, E, "1", "run");
    assert_eq(second.exit, 4);
}

// The compiler decides a module's shard count from its emitted size (about one shard per 256 KiB
// of C), records the counts in `__sc_shards` beside the manifest, keeps them across rebuilds,
// and lets a `[shards]` entry in build.toml override them.
@test
fn shard_counts_follow_emitted_size() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    // 1,500 small functions render to several hundred KiB of C: more than one shard.
    let mut src = String::new();
    for i in 0..1500 {
        src.push_str("fn f");
        src.push_u64(i as u64);
        src.push_str("(a: i32) i32 {\n    let mut s = a;\n");
        for k in 0..6 {
            src.push_str("    s = s * 3 + ");
            src.push_u64((i * 7 + k) as u64);
            src.push_str(";\n    if s > 1000000 {\n        s = s - 1000000;\n    }\n");
        }
        src.push_str("    return s;\n}\n");
    }
    src.push_str("fn main() i32 {\n    return f0(1) + f1499(2) - f0(1) - f1499(2);\n}\n");
    p.mkfile("src/main.spc", src.as_str());
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "build");
    assert(r.ok(), "the build succeeds");
    let mut sp = String::from_str(root);
    sp.push_str("/build/dev/gen/__sc_shards");
    let meta = cli::read_text(sp.as_str());
    assert(meta.as_str().starts_with("super-c-shards\t1\n"), "the shard file carries its version");
    assert(meta.as_str().contains("\nmain\t"), "the large module has more than one shard");
    let mut p1 = String::from_str(root);
    p1.push_str("/build/dev/gen/main__p1.c");
    assert(cli::read_text(p1.as_str()).len() > 0, "the second shard was written");
    let again = cli::superc_env_in(root, E, "1", "build");
    assert(again.ok(), "the rebuild succeeds");
    assert(cli::read_text(sp.as_str()).equals(&meta), "a rebuild keeps the counts");
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n[shards]\n\"main\" = 1\n");
    let over = cli::superc_env_in(root, E, "1", "build");
    assert(over.ok(), "the override builds");
    assert(!cli::read_text(sp.as_str()).as_str().contains("\nmain\t"), "the manifest's count wins");
    assert(cli::read_text(p1.as_str()).len() == 0, "and the second shard is gone");
}
