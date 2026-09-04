// `super-c fmt` and `super-c lint` with no path argument: the whole-project sweep. project_paths reads
// build.toml, skips the out-dir, and hands every top-level directory and .spc file to the formatter or
// linter. Also covers `lint <dir>` recursion. Driven from inside a scratch project.
import tests::cli_harness as cli;

const CLEAN_A: str = "pub fn helper(x: i32) i32 {\n    return x + 1;\n}\n";
const CLEAN_MAIN: str = "import lib::a;\n\nfn main() i32 {\n    return lib::a::helper(1) - 2;\n}\n";
const UGLY: str = "pub  fn h(  )i32{return 0;}\n";

fn project(clean: bool) cli::Proj {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", CLEAN_MAIN);
    if clean {
        p.mkfile("lib/a.spc", CLEAN_A);
    } else {
        p.mkfile("lib/a.spc", UGLY);
    }
    return p;
}

@test
fn whole_project_fmt_check_passes_when_canonical() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = project(true);
    let root = str::from_cstr(p.rootp());
    // No path: the sweep formats every source under the project root.
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "fmt --check");
    assert(r.ok(), "a canonical project passes the whole-project check");
}

@test
fn whole_project_fmt_check_flags_an_unformatted_file() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = project(false);
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "fmt --check");
    assert_eq(r.exit, 1);
    assert(r.out_has("a.spc"), "the unformatted file in the sweep is named");
}

@test
fn whole_project_lint_is_clean() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = project(true);
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(r.ok(), "a clean project lints without warnings");
}

@test
fn lint_recurses_a_directory() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "import extra::util;\n\nfn main() i32 {\n    return extra::util::u();\n}\n");
    p.mkfile("src/extra/util.spc", "pub fn u() i32 {\n    return 0;\n}\n");
    let root = str::from_cstr(p.rootp());
    // Run from the project root so imports resolve against it; `lint src` recurses the directory.
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint src");
    // A directory lints every .spc under it; a clean tree exits 0.
    assert(r.ok(), "directory lint succeeds on a clean tree");
}
