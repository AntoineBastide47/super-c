// `super-c fmt` and `super-c lint` with no path argument: the whole-project sweep. project_paths reads
// build.toml, skips the out-dir, and hands every top-level directory and .spc file to the formatter or
// linter. Also covers `lint <dir>` recursion, `build <dir>`, `--bin` with `-o`, the strip of a
// cross-linked release, the probe record's key, and the std tree `SC_STD_DIR` names. Driven from inside
// a scratch project.
import stdlib;
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
    // A directory given as a script is no source file (Linux opens one: it must not be read).
    let s = cli::superc_env_in(root, "SC_NO_EMIT_CACHE", "1", "app");
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

// A release cross-linked for another platform's object format strips at link: the host `strip`
// cannot read the binary. A stub C compiler records the link line.
@test
fn a_cross_linked_release_strips_at_link() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "cc.sh",
        "#!/bin/sh\no=\"\"; prev=\"\"\nfor a in \"$@\"; do [ \"$prev\" = -o ] && o=\"$a\"; prev=\"$a\"; done\necho \"$@\" >> cc.log\n[ -n \"$o\" ] && : > \"$o\"\nexit 0\n",
    );
    let root = p.dir();
    let mut cmd = String::new();
    cmd.format_into("chmod +x \"{}/cc.sh\"", root);
    assert(cli::run_quiet(cmd.cstr()) == 0, "chmod");
    // Another platform than the host: Linux from macOS, Windows from Linux.
    let target = if PLATFORM == Platform::Linux {
        "windows";
    } else {
        "linux";
    };
    let mut b = String::new();
    b.format_into("release --target={} --arch=x86_64 --cc={}/cc.sh", target, root);
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1", b.as_str());
    assert(r.ok() && !r.out_has("strip failed"), "the release links without the host strip");
    assert(cli::read_text(format("{}/cc.log", root).as_str()).contains("-Wl,--strip-all"), "the link strips");
}

// The probe record's key holds the C compiler's whole command: its arguments select a target too, so
// a record of `cc.sh` does not answer for `cc.sh --ok`. The stub rejects the AVX2 flag without `--ok`.
@test
fn the_probe_record_keys_on_the_compiler_command() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"main.spc\"\n");
    p.mkfile("main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile(
        "cc.sh",
        "#!/bin/sh\nok=\"\"; avx=\"\"; o=\"\"; prev=\"\"\nfor a in \"$@\"; do [ \"$a\" = --ok ] && ok=1; [ \"$a\" = -mavx2 ] && avx=1; [ \"$prev\" = -o ] && o=\"$a\"; prev=\"$a\"; done\n[ -n \"$avx\" ] && [ -z \"$ok\" ] && exit 1\n[ -n \"$o\" ] && : > \"$o\"\nexit 0\n",
    );
    let root = p.dir();
    let mut cmd = String::new();
    cmd.format_into("chmod +x \"{}/cc.sh\"", root);
    assert(cli::run_quiet(cmd.cstr()) == 0, "chmod");
    let mut a = String::new();
    a.format_into("build --target=linux --arch=x86_64 --target-feature=avx2 --cc={}/cc.sh", root);
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1", a.as_str());
    assert(!r.ok() && r.out_has("rejects"), "the stub rejects the flag");
    let mut b = String::new();
    b.format_into("build --target=linux --arch=x86_64 --target-feature=avx2 \"--cc={}/cc.sh --ok\"", root);
    let r2 = cli::superc_env_in(root, "SC_NO_CACHE", "1", b.as_str());
    assert(r2.ok() && !r2.out_has("rejects"), "another command probes again");
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
    assert(!bad.ok() && bad.out_has("cannot open module 'std::simd::math'"), "a tree without the module fails");
}
