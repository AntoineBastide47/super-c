// `super-c fmt` and `super-c lint` with no path argument: the whole-project sweep. project_paths reads
// build.toml, skips the out-dir, and hands every top-level directory and .spc file to the formatter or
// linter. Also covers `lint <dir>` recursion, `build <dir>`, `--bin` with `-o`, the strip of a
// cross-linked release, a macOS build for the other instruction set, the probe record's key, and the std
// tree `SC_STD_DIR` names. Driven from inside a scratch project.
import stdlib;
import tests::cli_harness as cli;
import module::loader as loader;
import driver_shim as shim;

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
fn whole_project_fmt_check_flags_an_unformatted_file() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = project(false);
    let root = p.dir();
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
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(r.ok() && !r.out_has("warning"), "a clean project lints without warnings");
    // The sweep reaches a file nothing imports.
    p.mkfile("lib/b.spc", "pub fn g() i32 {\n    let unused = 1;\n    return 0;\n}\n");
    let w = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(w.exit != 0 && w.out_shows("unused variable 'unused'") && w.out_shows("b.spc"), "the sweep lints every file");
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
    p.mkfile("src/extra/util.spc", "pub fn u() i32 {\n    let unused = 1;\n    return 0;\n}\n");
    let root = p.dir();
    // Run from the project root so imports resolve against it; `lint src` recurses the directory and
    // reaches the nested file's warning.
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint src");
    assert(
        r.exit != 0 && r.out_shows("unused variable 'unused'") && r.out_shows("util.spc"),
        "the nested file is linted",
    );
}

@test
fn a_listed_file_keeps_its_pub_items_live() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    // A listed file loads without the modules that import it: its pub items, and what they call,
    // are live. The whole-project lint loads every caller and reports the pub item none reaches.
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "import extra::util;\n\nfn main() i32 {\n    return extra::util::u();\n}\n");
    p.mkfile(
        "src/extra/util.spc",
        "fn half() i32 {\n    return 0;\n}\n\npub fn u() i32 {\n    return half();\n}\n\npub fn dead() i32 {\n    return 1;\n}\n",
    );
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint src/extra/util.spc");
    assert(r.ok() && !r.out_has("warning"), "the listed file's pub items and their callees are live");
    let w = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(w.exit != 0 && w.out_shows("unused public function 'dead'"), "the whole project reports the dead pub item");
    assert(!w.out_has("'u'") && !w.out_has("'half'"), "and only it");
}

@test
fn whole_project_lint_roots_a_nested_project_at_its_manifest() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = project(true);
    // A nested project imports its sibling module by its own root, not the outer project's.
    p.mkfile("tools/t/build.toml", "bin = \"t\"\nroot = \"main.spc\"\n");
    p.mkfile("tools/t/main.spc", "import util;\n\nfn main() i32 {\n    return util::u();\n}\n");
    p.mkfile("tools/t/util.spc", "pub fn u() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(r.ok() && !r.out_has("cannot open module"), "the nested project resolves its own imports");
    p.mkfile("tools/t/util.spc", "pub fn u() i32 {\n    let unused = 1;\n    return 0;\n}\n");
    let w = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(w.exit != 0 && w.out_shows("unused variable 'unused'"), "the nested project is linted");
    // `lint-exclude` skips a directory, the nested projects in it included.
    let toml = cli::read_text(format("{}/build.toml", root).as_str());
    p.mkfile("build.toml", format("lint-exclude = [\"tools\"]\n{}", toml.as_str()).as_str());
    let x = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(x.ok() && !x.out_has("unused variable"), "the excluded directory is not linted");
}

@test
fn lint_without_src_roots_a_nested_project_at_its_manifest() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    // A project without `src/`: each top-level directory lints rooted at itself, except a project of
    // its own below it, which lints from its own directory, as its build resolves it.
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile("tools/t/build.toml", "bin = \"t\"\nroot = \"main.spc\"\n");
    p.mkfile("tools/t/main.spc", "import util;\n\nfn main() i32 {\n    return util::u();\n}\n");
    p.mkfile("tools/t/util.spc", "pub fn u() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the lint passes");
    assert(!r.out_has("cannot open module"), "the nested project resolves its own imports");
    p.mkfile("tools/t/util.spc", "pub fn u() i32 {\n    let unused = 1;\n    return 0;\n}\n");
    let w = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "lint");
    assert(w.exit != 0, "the lint fails on the nested project's warning");
    assert(w.out_shows("unused variable 'unused'"), "the nested project is linted");
}

@test
fn build_of_a_directory_builds_its_project() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("app/build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("app/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    // `build <dir>` reads that directory's build.toml; a relative -o stays the caller's.
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "build app -o out-app");
    assert(r.ok(), "the project of the directory builds");
    // Windows names an executable `<o>.exe` (`exe_name`).
    let out = format("{}/out-app{}", root, unsafe str::from_cstr(cli::binext()));
    assert(cli::read_text(out.as_str()).len() > 0, "-o names a path from the caller");
    // A directory given as a file to test is no source file (Linux opens one: it must not be read).
    let s = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "test app");
    assert(s.exit != 0 && s.out_has("cannot open module"), "a directory script is reported, not read");
}

// `--bin=NAME -o PATH` links that [bin.NAME] target at PATH, not the primary binary; `--lib` with -o is
// an error, as -o names one binary.
@test
fn bin_with_output_links_the_named_target() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n\n[bin.tool]\nroot = \"tool.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 3;\n}\n");
    p.mkfile("tool.spc", "fn main() i32 {\n    return 7;\n}\n");
    let root = p.dir();
    let r = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "build --bin=tool -o out-tool");
    assert(r.ok(), "the target builds");
    let mut run = String::new();
    run.format_into("\"{}/out-tool\"", root);
    assert(cli::run_quiet(run.cstr()) == 7, "the binary at -o is the named target's");
    let l = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "build --lib -o out-lib");
    assert(!l.ok() && l.out_has("-o names one binary; --lib builds the library targets"), "--lib with -o");
}

// On macOS, `--arch` of the instruction set the host does not run builds for it: an arm64 executable's
// Mach-O header names its CPU (0x0100000C); x86-64 macOS has no native backend, so its build is an error
// that names `--emit-c`.
@test
fn a_macos_build_for_the_other_arch_targets_it() {
    if PLATFORM != Platform::MacOS {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    if unsafe shim::sc_host_arch() == 1 {
        let r = cli::superc_in(p.dir(), "build --arch=x86_64 -o app");
        assert(
            !r.ok() && r.out_has("no native backend for macos on x86_64: `--emit-c` writes the program's C"),
            "no x86-64 build",
        );
        return;
    }
    let r = cli::superc_in(p.dir(), "build --arch=aarch64 -o app");
    assert(r.ok(), "the build for the other instruction set links");
    let bin = loader::read_file(format("{}/app", p.dir()).as_str()).unwrap();
    let b = bin.as_str();
    assert(b.len() >= 8 && b.byte_at(4) == 0x0Cu8 && b.byte_at(7) == 0x01u8, "its Mach-O CPU type");
}

// `SC_STD_DIR` names the std tree in place of the one beside the compiler: `super-c test` sets it for
// the compiler under test, which `--out-dir` may place outside the project.
@test
fn std_dir_env_names_the_std_tree() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile(
        "main.spc",
        "import std::simd::math as sm;\n\nfn main() i32 {\n    return sm::sin(Simd::<f32, 4>::splat(0.0))[0] as i32;\n}\n",
    );
    let root = p.dir();
    let std_dir = stdlib::get_env("SC_STD_DIR");
    assert(std_dir.is_some(), "the test runner names the project's std tree");
    let ok = cli::superc_env_in(root, "SC_STD_DIR", std_dir.unwrap().as_str(), "build");
    assert(ok.ok(), "the named tree builds the program");
    let mut missing = String::new();
    missing.format_into("{}/missing", root);
    // The emit stamp records the tree: the same out-dir does not reuse the first build.
    let bad = cli::superc_env_in(root, "SC_STD_DIR", missing.as_str(), "build");
    assert(bad.exit == 1, "a missing tree fails the build");
    assert(bad.out_has("cannot find the standard library"), "the build names the missing tree");
}

// A std directory that does not exist is one error that names it, not a failed import per module.
@test
fn a_missing_std_dir_is_one_error() {
    let p = cli::proj_new();
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = p.dir();
    let mut missing = String::new();
    missing.format_into("{}/missing", root);
    let r = cli::superc_env_in(root, "SC_STD_DIR", missing.as_str(), "build main.spc");
    let msg = format(
        "error: cannot find the standard library: '{}' is not a directory\n  = note: std is looked up beside the compiler and in its two parent directories; SC_STD_DIR names another one\n",
        missing.as_str(),
    );
    let out = r.text();
    if r.exit != 1 || out.find(msg.as_str()) < 0 {
        r.show();
    }
    assert(r.exit == 1, "the build exits 1");
    assert(out.find(msg.as_str()) >= 0, "the error names the directory and where std is looked up");
    let first = out.find("cannot find the standard library");
    let rest = out.slice(first as usize + 1, out.len());
    assert(rest.find("cannot find the standard library") < 0, "the error appears once");
    assert(!r.out_has("cannot open module"), "no import reports the missing tree");
}
