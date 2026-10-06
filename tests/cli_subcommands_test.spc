// The project-lifecycle subcommands: `new` and `init` scaffold, `run` builds and executes the primary
// binary, `command` runs a build.toml [command.NAME], and `clean` drops the build outputs. Driven from
// inside scratch directories.
import tests::cli_harness as cli;
import build_system::build as bsys;
import stdio;
import driver_shim as shim;

const E: str = "SC_NO_EMIT_CACHE";

@test
fn new_scaffolds_and_runs() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    // `new myapp` creates myapp/ with build.toml + src/main.spc.
    let n = cli::superc_env_in(root, E, "1", "new myapp");
    assert(n.ok(), "new succeeds");
    let mut app = String::from_str(root);
    app.push_str("/myapp");
    // The scaffolded project builds and runs, printing its greeting.
    let r = cli::superc_env_in(app.as_str(), E, "1", "run");
    assert(r.ok(), "the scaffolded project runs");
    assert(r.out_has("Hello from myapp!"), "the scaffold's main runs");
}

@test
fn new_rejects_an_existing_directory() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "new dup").ok(), "first new succeeds");
    // A second `new` with the same name refuses rather than overwrite.
    let r = cli::superc_env_in(root, E, "1", "new dup");
    assert_eq(r.exit, 1);
    assert(r.out_has("already exists"), "the collision is reported");
}

@test
fn init_scaffolds_in_place() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "init");
    assert(r.ok(), "init scaffolds the current directory");
    // The scaffolded project runs from its own root.
    let run = cli::superc_env_in(root, E, "1", "run");
    assert(run.ok(), "the initialized project runs");
    assert(run.out_has("Hello from"), "greeting printed");
}

@test
fn run_reports_the_program_exit_code() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 7;\n}\n");
    let root = str::from_cstr(p.rootp());
    // `run` returns the program's own exit code.
    let r = cli::superc_env_in(root, E, "1", "run");
    assert_eq(r.exit, 7);
}

@test
fn command_runs_a_manifest_command() {
    // A manifest command is a shell line: POSIX runs it through `/bin/sh -c` (so `echo` works),
    // while Windows spawns it with CreateProcess directly (no shell builtins) and the wasm guest has
    // no subprocesses at all. The portable coverage of manifest_run is the POSIX lane.
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"src/main.spc\"\n[command.greet]\nrun = [\"echo manifest-command-ran\"]\n",
    );
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "command greet");
    assert(r.ok(), "the command runs");
    assert(r.out_has("manifest-command-ran"), "the command's shell line executed");
}

@test
fn clean_removes_build_outputs() {
    // The wasm guest has no stable cwd or subprocesses; this drives a working-directory-
    // dependent guest command, so it runs on native and Windows only.
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "build first");
    let mut bdir = String::from_str(root);
    bdir.push_str("/build");
    assert(cli::dir_count_suffix(bdir.as_str(), "") >= 0, "build dir exists");
    // clean drops the outputs; a rebuild afterwards still works.
    assert(cli::superc_env_in(root, E, "1", "clean").ok(), "clean succeeds");
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "rebuild after clean works");
}

// `clean` removes the out-dir and the tree a bare build emits beside the sources; a directory the user
// named `build` that holds anything else stays.
@test
fn clean_keeps_a_user_build_directory() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\nout-dir = \"out\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    p.mkfile("build/keep.txt", "mine\n");
    p.mkfile("src/build/dev/raw/super_rt.h", "stale\n");
    p.mkfile("src/build/release/raw/main.c", "stale\n");
    p.mkfile("src/build/release/raw/super_rt.h", "stale\n");
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "build").ok(), "build first");
    assert(cli::superc_env_in(root, E, "1", "clean").ok(), "clean succeeds");
    let mut keep = String::from_str(root);
    keep.push_str("/build");
    assert_eq(cli::dir_count_suffix(keep.as_str(), "keep.txt"), 1);
    let mut out = String::from_str(root);
    out.push_str("/out");
    assert_eq(cli::dir_count_suffix(out.as_str(), ""), 0);
    let mut src = String::from_str(root);
    src.push_str("/src");
    assert_eq(cli::dir_count_suffix(src.as_str(), "build"), 0);
}

// Deleting a tree never follows a symlink out of it: the link goes, its target stays.
@test
fn rm_rf_does_not_follow_symlinks() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("outside/keep.txt", "mine\n");
    p.mkfile("tree/file.txt", "x\n");
    let root = str::from_cstr(p.rootp());
    let mut ln = String::new();
    ln.format_into("ln -s \"{}/outside\" \"{}/tree/link\"", root, root);
    assert_eq(cli::run_quiet(ln.cstr()), 0);
    let mut tree = String::from_str(root);
    tree.push_str("/tree");
    bsys::rm_rf(tree.as_str());
    assert_eq(cli::dir_count_suffix(tree.as_str(), ""), 0);
    let mut outside = String::from_str(root);
    outside.push_str("/outside");
    assert_eq(cli::dir_count_suffix(outside.as_str(), "keep.txt"), 1);
}

// `new` names the project after the path's last component.
@test
fn new_names_the_project_after_the_last_path_component() {
    let p = cli::proj_new();
    let root = str::from_cstr(p.rootp());
    assert(cli::superc_env_in(root, E, "1", "new apps/demo").ok(), "new succeeds");
    let mut man = String::from_str(root);
    man.push_str("/apps/demo/build.toml");
    let text = cli::read_text(man.as_str());
    assert(text.as_str().contains("bin = \"demo\""), "the binary is named after the last component");
}

// A vendor name is one directory under vendor/: `--force` deletes it, so `..` must never pass.
@test
fn vendor_rejects_a_path_as_name() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("dep/lib.spc", "pub fn one() i32 {\n    return 1;\n}\n");
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "vendor dep .. --force");
    assert_eq(r.exit, 1);
    assert(r.out_has("is not a directory name"), "the name is refused");
    assert_eq(cli::dir_count_suffix(root, "build.toml"), 1);
}

// A `[command]` env value reaches the command verbatim, quotes included.
@test
fn command_env_keeps_quotes() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"src/main.spc\"\n[command.show]\nenv = { V = \"it's\" }\nrun = [\"echo [$V]\"]\n",
    );
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 0;\n}\n");
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "command show");
    assert(r.ok(), "the command runs");
    assert(r.out_has("[it's]"), "the value arrives unchanged");
}

// The emit stamp covers the directories import resolution listed: a new file that shadows an import
// makes the next build transpile again instead of reusing the old tree.
@test
fn emit_stamp_sees_a_new_shadowing_module() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "import lib;\n\nfn main() i32 {\n    return lib::v();\n}\n");
    p.mkfile("src/lib/lib.spc", "pub fn v() i32 {\n    return 3;\n}\n");
    let root = str::from_cstr(p.rootp());
    assert_eq(cli::superc_env_in(root, "SC_STAMP_TEST", "1", "run").exit, 3);
    // `src/lib.spc` is probed before `src/lib/lib.spc`, so it now names the module.
    p.mkfile("src/lib.spc", "pub fn v() i32 {\n    return 5;\n}\n");
    assert_eq(cli::superc_env_in(root, "SC_STAMP_TEST", "1", "run").exit, 5);
}

// The emit stamp keys on the content of the compiler that emitted the tree: the same compiler skips the
// transpile, and a different one at the same path with the same mtime (a reinstall, an extracted archive)
// transpiles again. `phase load` prints only when the build transpiles.
@test
fn emit_stamp_keys_on_the_compiler_content() {
    if cli::on_wasm() || cli::on_windows() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "fn main() i32 {\n    return 3;\n}\n");
    let root = str::from_cstr(p.rootp());
    // tc/super-c: a copy of the compiler under test, with std/ and ffi/ beside it; tc/ref keeps its mtime.
    let mut here = Array::<char, 4096> {};
    let mut dot = String::from_str(".");
    assert(unsafe shim::sc_realpath(dot.cstr(), &mut here[0]) != null, "the working directory resolves");
    let cwd = str::from_cstr(&here[0]);
    p.mkfile("tc/.keep", "");
    let mut exe = String::new();
    exe.format_into("{}/tc/super-c", root);
    let mut cmds = Vector::<String>::new();
    cmds.push(format("cp {} {}", cli::superc_path(), exe.as_str()));
    cmds.push(format("cp -p {} {}/tc/ref", exe.as_str(), root));
    cmds.push(format("ln -s {}/std {}/tc/std", cwd, root));
    cmds.push(format("ln -s {}/ffi {}/tc/ffi", cwd, root));
    for i in 0..cmds.len() {
        assert_eq(cli::run_quiet(cmds.index_mut(i).cstr()), 0);
    }
    let first = cli::exe_env_in(exe.as_str(), root, "SC_CEMIT_STATS", "1", "run");
    assert_eq(first.exit, 3);
    assert(first.out_has("phase load"), "the first build transpiles");
    let same = cli::exe_env_in(exe.as_str(), root, "SC_CEMIT_STATS", "1", "run");
    assert_eq(same.exit, 3);
    assert(!same.out_has("phase load"), "the same compiler skips the transpile");
    // Another compiler at the same path and mtime: appended bytes change the content, not the behavior.
    // The new file is written beside the copy and renamed over it: Linux refuses to open a file for
    // writing while it counts a process as executing it (ETXTBSY).
    let next = format("{}.next", exe.as_str());
    let mut cp = format("cp {} {}", exe.as_str(), next.as_str());
    assert_eq(cli::run_quiet(cp.cstr()), 0);
    let f = stdio::fopen(next.as_str(), "ab");
    assert(f != null, "the new copy opens for append");
    let _ = unsafe stdio::fwrite("x".ptr(), 1, 1, f);
    unsafe stdio::fclose(f);
    let mut mv = format("mv {} {} && touch -r {}/tc/ref {}", next.as_str(), exe.as_str(), root, exe.as_str());
    assert_eq(cli::run_quiet(mv.cstr()), 0);
    let other = cli::exe_env_in(exe.as_str(), root, "SC_CEMIT_STATS", "1", "run");
    assert_eq(other.exit, 3);
    assert(other.out_has("phase load"), "a different compiler transpiles again");
    let again = cli::exe_env_in(exe.as_str(), root, "SC_CEMIT_STATS", "1", "run");
    assert_eq(again.exit, 3);
    assert(!again.out_has("phase load"), "the new compiler's own tree is reused");
}

// `--transpiler` runs the transpile step through another command (here the compiler under test itself)
// and the engine compiles and links its tree: the program runs, the tree equals the one the engine's own
// frontend writes, and the emit stamp keys on the transpiler, so an unchanged build skips the transpile
// and a switch between transpilers transpiles again. A failing transpiler fails the build with its
// diagnostics. `phase load` prints only when the build transpiles.
@test
fn external_transpiler_builds_and_keys_the_emit_stamp() {
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/main.spc", "import lib;\n\nfn main() i32 {\n    return lib::v();\n}\n");
    p.mkfile("src/lib.spc", "pub fn v() i32 {\n    return 3;\n}\n");
    let root = str::from_cstr(p.rootp());
    let ext = format("build --out-dir=ext \"--transpiler={}\" -o app", cli::superc_path());
    let first = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", ext.as_str());
    assert(first.ok(), "the build through the transpiler succeeds");
    assert(first.out_has("phase load"), "the first build transpiles");
    let app = format("{}/app{}", root, str::from_cstr(cli::binext()));
    assert_eq(cli::exe_env_in(app.as_str(), root, E, "1", "").exit, 3);
    let same = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", ext.as_str());
    assert(same.ok() && !same.out_has("phase load"), "the same transpiler skips the transpile");
    // The engine's own frontend emits the same tree, and it is another emitter for the stamp.
    assert(cli::superc_env_in(root, E, "1", "build --out-dir=int -o app").ok(), "the frontend build");
    let own = cli::read_text(format("{}/int/dev/raw/lib.c", root).as_str());
    assert(own.len() != 0, "the frontend wrote the tree");
    assert(own.as_str() == cli::read_text(format("{}/ext/dev/raw/lib.c", root).as_str()).as_str(), "same tree");
    let back = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", "build --out-dir=ext -o app");
    assert(back.ok() && back.out_has("phase load"), "the frontend does not reuse the transpiler's tree");
    let again = cli::superc_env_in(root, "SC_CEMIT_STATS", "1", ext.as_str());
    assert(again.ok() && again.out_has("phase load"), "the transpiler does not reuse the frontend's tree");
    // A transpiler error fails the build and shows the transpiler's diagnostics.
    p.mkfile("src/lib.spc", "pub fn v() i32 {\n    return missing;\n}\n");
    let bad = cli::superc_env_in(root, E, "1", ext.as_str());
    assert(!bad.ok(), "a failing transpiler fails the build");
    assert(bad.out_has("cannot find value 'missing'"), "the transpiler's diagnostic reaches the output");
    assert(bad.out_has("build: transpiler failed"), "the engine names the failed step");
}

// A dependency path with a space is escaped as `\ ` in the compiler's .d file; read as written, an
// unchanged object stays fresh instead of recompiling on every build.
@test
fn escaped_space_dependency_keeps_the_object_fresh() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    p.mkfile("src/my dir/native.h", "static inline int native_one(void) { return 7; }\n");
    p.mkfile(
        "src/main.spc",
        "extern \"C\" \"my dir/native.h\" {\n    fn native_one() i32;\n}\n\nfn main() i32 {\n    return unsafe native_one();\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    // Without the object cache, so every stale unit really compiles and is counted.
    assert(cli::superc_env_in(root, "SC_NO_CACHE", "1", "build").ok(), "first build");
    let r = cli::superc_env_in(root, "SC_NO_CACHE", "1 SC_TIMINGS=1", "build");
    assert(r.ok(), "second build");
    assert(r.out_has("(0/2 stale"), "no unit is stale after an unchanged build");
}

// A manifest's own profile is a name PROFILE may be compared with, and its generated C lands in that
// profile's directory.
@test
fn manifest_profile_is_a_build_constant() {
    if cli::on_wasm() {
        return;
    }
    let p = cli::proj_new();
    p.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"src/main.spc\"\nout-dir = \"out\"\n\n[profile.fast]\nopt-level = 1\n",
    );
    p.mkfile(
        "src/main.spc",
        "fn main() i32 {\n    if PROFILE == \"fast\" {\n        return 0;\n    }\n    return 1;\n}\n",
    );
    let root = str::from_cstr(p.rootp());
    let r = cli::superc_env_in(root, E, "1", "run --profile=fast");
    assert(r.ok(), "the fast profile takes the fast branch");
    let mut raw = String::from_str(root);
    raw.push_str("/out/fast/raw");
    assert_eq(cli::dir_count_suffix(raw.as_str(), "main.c"), 1);
    assert_eq(cli::superc_env_in(root, E, "1", "run").exit, 1);
}
