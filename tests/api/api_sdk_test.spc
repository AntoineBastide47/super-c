// The SDK's documented examples (`docs/compiler-api/examples`) build against a vendored copy of this
// compiler, as a client builds them, and run.
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;

const SAMPLE: str = M"(fn twice(x: i32) i32 {
    return x + x;
}

fn main() i32 {
    let b: bool = 3;
    return twice(2) - 4;
}
)";

// A project holding example `name` and the vendored compiler; built, its binary's path, and the std directory.
fn example(name: str) (cli::Proj, String, String) {
    let std_dir = format("{}/std", process::current_dir().unwrap().as_str());
    let proj = cli::proj_new();
    cli::copy_tree("src", format("{}/vendor/superc/src", proj.dir()).as_str());
    assert(proj.copyfile("vendor/superc/build.toml", "build.toml"), "the manifest copies");
    let dir = format("docs/compiler-api/examples/{}", name);
    assert(proj.copyfile("build.toml", format("{}/build.toml", dir.as_str()).as_str()), "the example's manifest");
    assert(proj.copyfile("main.spc", format("{}/main.spc", dir.as_str()).as_str()), "the example's source");
    let r = cli::superc_env_in(proj.dir(), "SC_NONE", "", "build");
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), name);
    let exe = if PLATFORM == Platform::Windows {
        format("{}/build/debug/{}.exe", proj.dir(), name);
    } else {
        format("{}/build/debug/{}", proj.dir(), name);
    };
    return proj, exe, std_dir;
}

@test(timeout = 900)
fn the_diagnostics_example_reports_an_error() {
    let (proj, exe, std_dir) = example("diagnostics");
    proj.mkfile("sample/build.toml", "bin = \"sample\"\nroot = \"main.spc\"\n");
    proj.mkfile("sample/main.spc", SAMPLE);
    let r = cli::exe_env_in(exe.as_str(), proj.dir(), "SC_NONE", "", format("sample \"{}\"", std_dir.as_str()).as_str());
    assert_eq(r.exit, 1);
    assert(r.out_has("main.spc:") && r.out_has(": error ["), "a located error with its code");
}

@test(timeout = 900)
fn the_rename_example_prints_the_edits() {
    let (proj, exe, std_dir) = example("rename");
    proj.mkfile("sample.spc", SAMPLE);
    let r = cli::exe_env_in(
        exe.as_str(),
        proj.dir(),
        "SC_NONE",
        "",
        format("sample.spc 3 double \"{}\"", std_dir.as_str()).as_str(),
    );
    assert_eq(r.exit, 0);
    assert(r.out_has("sample.spc:3-8: double") && r.out_has(": double"), "the declaration and its call");
}

@test(timeout = 900)
fn the_lir_example_evaluates_and_compiles() {
    let (proj, exe, std_dir) = example("lir");
    let r = cli::exe_env_in(exe.as_str(), proj.dir(), "SC_NONE", "", "");
    assert_eq(r.exit, 0);
    assert(r.out_has("add3(4, 5) = 12") && r.out_has("object: "), "the result and the object");
}

@test(timeout = 900)
fn the_build_hook_example_builds_with_its_hook() {
    let (proj, exe, std_dir) = example("build-hook");
    proj.mkfile("sample/build.toml", "bin = \"sample\"\nroot = \"main.spc\"\n");
    proj.mkfile("sample/main.spc", "import util;\n\nfn main() i32 {\n    return util::zero();\n}\n");
    proj.mkfile("sample/util.spc", "pub fn zero() i32 {\n    return 0;\n}\n");
    let sample = format("{}/sample", proj.dir());
    let r = cli::exe_env_in(exe.as_str(), sample.as_str(), "SC_NONE", "", format("\"{}\"", std_dir.as_str()).as_str());
    if r.exit != 0 {
        r.show();
    }
    assert_eq(r.exit, 0);
    assert(r.out_has("plans build/debug/sample") && r.out_has("linked true"), "the plan and the build");
    let list = cli::read_text(format("{}/build/debug/hooks/example.modules/modules.txt", sample.as_str()).as_str());
    assert(list.as_str().contains("main\n") && list.as_str().contains("util\n"), list.as_str());
    assert(
        fs::stat(format("{}/build/debug/sample", sample.as_str()).as_str()).is_ok() || PLATFORM == Platform::Windows,
        "the binary",
    );
}
