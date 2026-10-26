// The build API: plans that write and run nothing, steps with tracked inputs, hooks at every stage, a custom
// backend as a hook, no-op builds that start no process, and cache keys that change with a step or a hook.
import api::build as bld;
import api::backend as be;
import api::lir as alir;
import api::errors as *;
import tests::cli_harness as cli;
import std::platform::fs;
import std::platform::process;

// The step's program: writes into file `args[2]` a module whose `n()` is the size of file `args[1]`.
const GEN: str = M"(import std::platform::fs;

fn main(args: Vector<str>) i32 {
    if args.len() != 3 {
        return 2;
    }
    let n = switch fs::stat(args[1]) {
        Ok(m) => m.size,
        Err(_) => {
            return 3;
        },
    };
    let text = format("pub fn n() i32 {{\n    return {};\n}}\n", n);
    let opts = fs::OpenOptions { read: false, write: true, append: false, truncate: true, create: true, create_new: false, mode: 0o644 };
    let mut f = switch fs::open(args[2], opts) {
        Ok(f) => f,
        Err(_) => {
            return 4;
        },
    };
    let bytes = unsafe Slice::<u8> { ptr: text.as_str().ptr(), len: text.len() };
    if f.write_all(bytes).is_err() {
        return 5;
    }
    return 0;
}
)";

const MAIN: str = M"(import gen;
import util;

fn main() i32 {
    return util::twice(gen::n()) - 10;
}
)";

const UTIL: str = M"(pub fn twice(x: i32) i32 {
    return x + x;
}
)";

const PLAIN_MAIN: str = M"(import util;

fn main() i32 {
    return util::twice(2) - 4;
}
)";

// The step tool's file name.
fn gen_exe() str<'static> {
    return if PLATFORM == Platform::Windows {
        "tools/gen.exe";
    } else {
        "tools/gen";
    };
}

// The manifest of a project whose step `gen` makes `src/gen.spc` from `data.txt`, `extra` appended.
fn step_manifest(argv_extra: str, inputs_extra: str) String {
    return format(
        "bin = \"app\"\nroot = \"src/main.spc\"\n\n[step.gen]\nargv = [\"{}\", \"data.txt\", \"src/gen.spc\"{}]\ninputs = [\"{}\", \"data.txt\"{}]\noutputs = [\"src/gen.spc\"]\n",
        gen_exe(),
        argv_extra,
        gen_exe(),
        inputs_extra,
    );
}

struct Fx {
    pub proj: cli::Proj,
    pub std_dir: String,
}

// A project with the step tool built, entered as the working directory.
@test_init
fn fx() Fx {
    let cwd = process::current_dir().unwrap();
    let proj = cli::proj_new();
    proj.mkfile("tools/gen.spc", GEN);
    let r = cli::superc_in(proj.dir(), format("build tools/gen.spc -o {}", gen_exe()).as_str());
    if !r.ok() {
        r.show();
    }
    assert(r.ok(), "the step tool builds");
    proj.mkfile("src/main.spc", MAIN);
    proj.mkfile("src/util.spc", UTIL);
    proj.mkfile("data.txt", "hello");
    proj.mkfile("build.toml", step_manifest("", "").as_str());
    assert(process::set_current_dir(proj.dir()).is_ok(), "the project is the working directory");
    return Fx { proj: proj, std_dir: format("{}/std", cwd.as_str()) };
}

fn build(fx: &Fx) Result<bld::Report, ApiError> {
    let req = bld::Request { profile: String::new(), std_dir: fx.std_dir.clone(), jobs: 1 };
    return bld::build(&req);
}

fn plan(fx: &Fx) Result<bld::Plan, ApiError> {
    let req = bld::Request { profile: String::new(), std_dir: fx.std_dir.clone(), jobs: 1 };
    return bld::plan(&req);
}

// The exit status of the built program.
fn run_app(fx: &Fx) i32 {
    let mut cmd = format("\"{}/build/debug/app\"", fx.proj.dir());
    let mut op = format("{}/.runout", fx.proj.dir());
    return cli::exec_env(cmd.cstr(), op.cstr(), "").exit;
}

fn exists(path: str) bool {
    return fs::stat(path).is_ok();
}

// A plan reads the manifest, the profile, the target, the steps and the package graph, and starts no step.
@test(timeout = 300)
fn a_plan_writes_and_runs_nothing(fx: &mut Fx) {
    fx.proj.mkfile("src/gen.spc", "pub fn n() i32 {\n    return 5;\n}\n");
    let p = plan(fx).unwrap();
    assert_eq(p.profile.name.as_str(), "debug");
    assert(p.os.len() != 0 && p.isa.len() != 0, "the host target");
    assert_eq(p.artifacts.len(), 1usize);
    assert(p.artifacts[0].as_str().contains("build/debug/app"), p.artifacts[0].as_str());
    assert_eq(p.steps.len(), 1usize);
    assert(p.steps[0].name.as_str() == "gen" && !p.steps[0].current, "the step has not run");
    let mut paths = Vector::<String>::new();
    let mut main_imports: usize = 0;
    for i in 0..p.modules.len() {
        if !p.modules[i].prelude {
            paths.push(p.modules[i].path.clone());
        }
        if p.modules[i].path.as_str() == "main" {
            main_imports = p.modules[i].imports.len();
        }
    }
    paths.sort();
    let gen = String::from_str("gen");
    let util = String::from_str("util");
    assert(paths.contains(&gen) && paths.contains(&util), "the package graph");
    assert(main_imports >= 2, "main imports gen and util");
    assert(!exists("build"), "a plan writes no build tree");
    assert(build(fx).unwrap().ok, "the build succeeds");
    let again = plan(fx).unwrap();
    assert(again.steps[0].current, "the plan sees the step current after the build");
}

// A step runs before the compile and again only when an input changes; a build that changes nothing starts
// no process and links nothing.
@test(timeout = 300)
fn steps_run_when_their_inputs_change(fx: &mut Fx) {
    let r1 = build(fx).unwrap();
    assert(r1.ok, "the first build succeeds");
    assert_eq(r1.targets.len(), 1usize);
    let t1 = &r1.targets[0];
    assert(t1.steps_run.len() == 1 && t1.steps_run[0].as_str() == "gen", "the step ran");
    assert(t1.emitted && t1.linked && t1.link.len() != 0, "the first build emits and links");
    assert(t1.units.len() != 0 && r1.processes != 0, "units and processes");
    for i in 0..t1.units.len() {
        let u = &t1.units[i];
        assert(u.compiled && u.object.as_str().ends_with(".o"), "the first build writes every object");
    }
    assert_eq(run_app(fx), 0);
    let r2 = build(fx).unwrap();
    let t2 = &r2.targets[0];
    assert(r2.ok && t2.steps_run.len() == 0, "the step is current");
    assert(!t2.emitted && !t2.linked && t2.link.len() == 0, "a no-op build emits and links nothing");
    assert_eq(r2.processes, 0u32);
    fx.proj.mkfile("data.txt", "hello, world");
    let r3 = build(fx).unwrap();
    assert(r3.ok && r3.targets[0].steps_run.len() == 1, "a changed input runs the step");
    assert(r3.targets[0].linked, "the new module relinks");
    // A changed step configuration changes the emit stamp and the per-TU cache key: the emission runs again.
    fx.proj.mkfile("build.toml", step_manifest(", \"--\"", "").as_str());
    let r4 = build(fx).unwrap();
    assert(!r4.ok, "the step tool rejects a fourth argument");
    let mut toml = step_manifest("", "");
    toml.push_str("env = [\"SC_NONE\"]\n");
    fx.proj.mkfile("build.toml", toml.as_str());
    let r5 = build(fx).unwrap();
    assert(r5.ok && r5.targets[0].emitted, "a changed step re-emits");
}

// A step must declare the project files it reads, its inputs must exist, and it must write its outputs.
@test(timeout = 300)
fn steps_declare_what_they_read_and_write(fx: &mut Fx) {
    fx.proj.mkfile("other.txt", "x");
    fx.proj.mkfile(
        "build.toml",
        format(
            "bin = \"app\"\nroot = \"src/main.spc\"\n\n[step.gen]\nargv = [\"{}\", \"other.txt\", \"src/gen.spc\"]\ninputs = [\"{}\"]\noutputs = [\"src/gen.spc\"]\n",
            gen_exe(),
            gen_exe(),
        ).as_str(),
    );
    let r = build(fx).unwrap();
    assert(!r.ok && r.processes == 0, "an undeclared input stops the build before the step runs");
    fx.proj.mkfile("build.toml", step_manifest("", ", \"missing.txt\"").as_str());
    assert(!build(fx).unwrap().ok, "a missing input stops the build");
    fx.proj.mkfile(
        "build.toml",
        format(
            "bin = \"app\"\nroot = \"src/main.spc\"\n\n[step.gen]\nargv = [\"{}\", \"data.txt\", \"src/gen.spc\"]\ninputs = [\"{}\", \"data.txt\"]\noutputs = [\"src/gen.spc\", \"src/never.spc\"]\n",
            gen_exe(),
            gen_exe(),
        ).as_str(),
    );
    assert(!build(fx).unwrap().ok, "an output the step does not write fails the build");
    fx.proj.mkfile(
        "build.toml",
        "bin = \"app\"\nroot = \"src/main.spc\"\n\n[step.a]\nargv = [\"x\"]\ninputs = [\"b.txt\"]\noutputs = [\"a.txt\"]\n\n[step.b]\nargv = [\"x\"]\noutputs = [\"b.txt\"]\n",
    );
    assert(build(fx).is_err(), "a step that reads a later step's output is a manifest error");
}

// A hook that logs each stage, lists the project's modules and the LIR functions (`+`: the user's `main` is
// one), and fails on request.
struct Probe {
    pub log: *mut String,
    pub config: String,
    pub version: u32,
    pub ir: bool,
    pub fail: bool,
}

extend Probe as bld::Hook {
    pub fn id(self: &Self) str {
        return "test.probe";
    }

    pub fn version(self: &Self) u32 {
        return self.version;
    }

    pub fn config(self: &Self) str {
        return self.config.as_str();
    }

    pub fn reads_ir(self: &Self) bool {
        return self.ir;
    }

    pub fn before_analysis(self: &mut Self, b: &bld::BuildInfo, out: &mut bld::HookOutput) Result<Unit, ApiError> {
        unsafe (*self.log).push_str("A;");
        assert_eq(b.profile.as_str(), "debug");
        out.warning("probing");
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    pub fn before_emission(
        self: &mut Self,
        b: &bld::BuildInfo,
        modules: Slice<bld::ModuleInfo>,
        out: &mut bld::HookOutput,
    ) Result<Unit, ApiError> {
        let mut list = String::new();
        let mut n = 0;
        for i in 0..modules.len() {
            if !modules[i].prelude && !modules[i].path.as_str().starts_with("std::") {
                list.format_into("{}\n", modules[i].path.as_str());
                n += 1;
            }
        }
        unsafe (*self.log).format_into("E{};", n);
        out.artifact("modules.txt", bytes(list.as_str()));
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    pub fn after_ir(self: &mut Self, b: &bld::BuildInfo, prog: &alir::Program, out: &mut bld::HookOutput) Result<
        Unit,
        ApiError
    > {
        let fs = prog.functions();
        let mut user_main = false;
        for i in 0..fs.len() {
            user_main = user_main || fs[i].as_str() == "__sc_user_main";
        }
        let mark = if user_main {
            "+";
        } else {
            "-";
        };
        unsafe (*self.log).format_into("I{}{};", fs.len(), mark);
        return Result::<Unit, ApiError>::Ok(Unit {});
    }

    pub fn after_artifacts(self: &mut Self, b: &bld::BuildInfo, artifacts: Slice<String>, out: &mut bld::HookOutput) Result<
        Unit,
        ApiError
    > {
        unsafe (*self.log).format_into("L{};", artifacts.len());
        if self.fail {
            out.error("the probe fails");
        }
        return Result::<Unit, ApiError>::Ok(Unit {});
    }
}

fn bytes(s: str) Vector<u8> {
    let mut v = Vector::<u8>::with_capacity(s.len());
    for i in 0..s.len() {
        v.push(s.byte_at(i));
    }
    return v;
}

// The probe; its configuration is the project directory, so no other test's build shares its cache keys.
fn probe(log: &mut String, version: u32, ir: bool, fail: bool) Vector<Box<dyn bld::Hook>> {
    let mut v = Vector::<Box<dyn bld::Hook>>::new();
    let dir = process::current_dir().unwrap();
    v.push(Box::new(Probe { log: log, config: dir, version: version, ir: ir, fail: fail }));
    return v;
}

// Bytes 8 to 16 of the per-TU cache image: the key a record must match to replay.
fn tuc_key() u64 {
    let mut f = fs::open(
        "build/debug/raw/.tu_cache",
        fs::OpenOptions {
            read: true,
            write: false,
            append: false,
            truncate: false,
            create: false,
            create_new: false,
            mode: 0,
        },
    ).unwrap();
    let mut buf = Vector::<u8>::new();
    buf.resize_default(16);
    let n = f.read(buf.as_mut_slice()).unwrap();
    assert_eq(n, 16usize);
    let mut k: u64 = 0;
    for i in 0..8usize {
        k |= buf[8 + i] as u64 << (8 * i) as u64;
    }
    return k;
}

// Hooks run at the four stages in build order, see the package graph and every LIR function, and write
// their artifacts; a build whose tree is current runs only the stages around the analysis.
@test(timeout = 300)
fn hooks_run_at_every_stage(fx: &mut Fx) {
    fx.proj.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    fx.proj.mkfile("src/main.spc", PLAIN_MAIN);
    let mut log = String::new();
    let mut hooks = probe(&mut log, 1, true, false);
    hooks.push(Box::new(bld::BackendHook::new("test.native", Box::new(be::NativeBackend {}))));
    let inst = bld::install(hooks).unwrap();
    assert(bld::install(Vector::<Box<dyn bld::Hook>>::new()).is_err(), "one installation at a time");
    let p = plan(fx).unwrap();
    assert(p.hooks.len() == 2 && p.hooks[0].as_str() == "test.native", "the installed hooks, by id");
    let r = build(fx).unwrap();
    assert(r.ok, "the build succeeds: a warning does not fail it");
    assert(r.diagnostics.len() == 1 && r.diagnostics[0].severity == bld::SEV_WARNING, "the hook's warning");
    assert(log.as_str().starts_with("A;E2;I") && log.as_str().ends_with("+;L1;"), log.as_str());
    let mods = cli::read_text("build/debug/hooks/test.probe/modules.txt");
    assert_eq(mods.as_str(), "main\nutil\n");
    assert_eq(r.hook_artifacts.len(), 2usize);
    let n = be::NativeBackend {};
    if n.supports(p.os.as_str(), p.isa.as_str()) {
        assert(exists("build/debug/hooks/test.native/program.o"), "the backend's object");
    }
    // A body edit: the IR hook still sees every function, the unchanged module's included.
    let first = log.clone();
    log.clear();
    fx.proj.mkfile("src/util.spc", "pub fn twice(x: i32) i32 {\n    return 2 * x;\n}\n");
    assert(build(fx).unwrap().ok, "the rebuild succeeds");
    assert_eq(log.as_str(), first.as_str());
    log.clear();
    let quiet = build(fx).unwrap();
    assert_eq(log.as_str(), "A;L1;");
    assert_eq(quiet.processes, 0u32);
    drop_installed(inst);
}

fn drop_installed(_i: bld::Installed) {}

// A hook's error fails the build, and its diagnostics reach the report.
@test(timeout = 300)
fn a_hook_error_fails_the_build(fx: &mut Fx) {
    fx.proj.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    fx.proj.mkfile("src/main.spc", PLAIN_MAIN);
    let mut log = String::new();
    let inst = bld::install(probe(&mut log, 1, false, true)).unwrap();
    let r = build(fx).unwrap();
    assert(!r.ok, "the build fails");
    assert_eq(r.diagnostics.len(), 2usize);
    let e = &r.diagnostics[1];
    assert(
        e.hook.as_str() == "test.probe" && e.severity == bld::SEV_ERROR && e.message.as_str() == "the probe fails",
        "the error",
    );
    drop_installed(inst);
}

// A hook's version is part of every cache key: the per-TU cache image and the emit stamp. Builds under another
// version emit again.
@test(timeout = 300)
fn a_changed_hook_misses_every_cache(fx: &mut Fx) {
    fx.proj.mkfile("build.toml", "bin = \"app\"\nroot = \"src/main.spc\"\n");
    fx.proj.mkfile("src/main.spc", PLAIN_MAIN);
    let mut log = String::new();
    let none = build(fx).unwrap();
    assert(none.ok, "a build without hooks");
    let k0 = tuc_key();
    let i1 = bld::install(probe(&mut log, 1, false, false)).unwrap();
    let r1 = build(fx).unwrap();
    let k1 = tuc_key();
    drop_installed(i1);
    let i2 = bld::install(probe(&mut log, 2, false, false)).unwrap();
    let r2 = build(fx).unwrap();
    let k2 = tuc_key();
    drop_installed(i2);
    let i3 = bld::install(probe(&mut log, 1, false, false)).unwrap();
    let r3 = build(fx).unwrap();
    drop_installed(i3);
    assert(r1.ok && r2.ok && r3.ok, "the builds succeed");
    assert(k0 != k1 && k1 != k2 && k0 != k2, "the per-TU cache key follows the hooks");
    let rs: [&bld::Report; 3] = [&r1, &r2, &r3];
    for k in 0..3 {
        assert(unsafe rs[k].targets[0].emitted, "another hook version emits again");
    }
}
