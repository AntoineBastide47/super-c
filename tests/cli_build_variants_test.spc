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
