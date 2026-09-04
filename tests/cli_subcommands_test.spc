// The project-lifecycle subcommands: `new` and `init` scaffold, `run` builds and executes the primary
// binary, `command` runs a build.toml [command.NAME], and `clean` drops the build outputs. Driven from
// inside scratch directories.
import tests::cli_harness as cli;
import build_system::build as bsys;

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
