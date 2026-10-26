// build.toml schema: maps parsed TOML items onto the Build manifest, applies defaults (built-in
// debug/release/bench/test profiles), and validates. Unknown sections/keys are hard errors so typos
// never silently no-op.
import driver_shim as shim;
import build_system::toml as toml;
import module::loader as loader;
import utils::errors as diag;
import driver::util as dutil;
import ir::cpu_features as cf;
import utils::diag_codes as dc;

/// One [profile.NAME]: per-profile ldflags appended after the manifest-level ones; `strip` links without
/// local symbols and debug information; `opt` is the `opt-level` (whether `lir::opt` runs), `debug`
/// whether the objects carry debug information; `link_args` reach the linker after the profile's
/// ldflags (`-Wl,<arg>` each).
pub(package) struct Profile<'a> {
    pub(package) name: str<'a>,
    pub(package) ldflags: Vector<String>,
    pub(package) link_args: Vector<String>,
    pub(package) strip: bool,
    pub(package) opt: i32,
    pub(package) debug: bool,
    /// `lockdep`: the runtime's lock-order checks are compiled in (the build constant LOCKDEP); SC_LOCK_ORDER
    /// switches their reports on.
    pub(package) lockdep: bool,
    /// `overflow-checks`: 1 traps integer overflow, 0 wraps it, -1 follows `opt`.
    pub(package) overflow_checks: i32,
    /// `target-features`: the CPU features to enable; set (`has_features`), it replaces the build's list.
    pub(package) target_features: Vector<String>,
    pub(package) has_features: bool,
}

/// `opt-level` values: 0 to 3, OPT_S and OPT_Z (`"s"`, `"z"`); OPT_NONE when the profile names none.
pub(package) const OPT_NONE: i32 = -1;
pub(package) const OPT_S: i32 = 4;
pub(package) const OPT_Z: i32 = 5;

/// One extra binary target: `[bin.NAME] root = "..."` (the top-level `bin`/`root` pair is the
/// primary binary). `super-c build` builds every target; `--bin=NAME` selects one.
pub(package) struct BinTarget {
    pub(package) name: String,
    pub(package) root: String,
}

/// One `[step.NAME]`: a process every build of the project runs before it compiles, in declaration order,
/// without a shell (`argv`), in the project directory, with only the environment variables `env` names. It
/// reads the project files `inputs` and writes the project files `outputs`. With `cache` (the default) it runs
/// again only when its configuration, an input, an output or its program changed (`build::run_steps`).
pub(package) struct Step {
    pub(package) name: String,
    pub(package) argv: Vector<String>,
    pub(package) inputs: Vector<String>,
    pub(package) outputs: Vector<String>,
    pub(package) env: Vector<String>,
    pub(package) cache: bool,
}

/// One [command.NAME] for `super-c command <name>`: shell lines executed in order, stopping at the
/// first failure. Built-in subcommand names are reserved: a command can never shadow one.
pub(package) struct Command<'a> {
    pub(package) name: str<'a>,
    pub(package) run: Vector<String>,
    pub(package) needs_build: bool, // needs-build = true: run a manifest build before the lines
    pub(package) env_k: Vector<String>, // parallel with env_v: set in the environment every line inherits
    pub(package) env_v: Vector<String>,
}

/// The validated build.toml. `bin` is where the project's binary is INSTALLED: each profile links its own
/// copy under `<out_dir>/<profile>/`, and only `build`/`release` (never `test` or `run`) copy one onto that
/// name, so a profile can never quietly stand in for another's artifact.
/// Ownership: `toml` keeps the parsed items alive; Profile/Command `name` views borrow into their
/// section strings.
pub(package) struct Manifest<'a> {
    /// Instruction set `@arch` gates against (a `target::table::ISAS` index), -1 unknown. Defaults to the
    /// host; the driver overwrites it for `--arch=`.
    pub(package) arch: i32,
    /// Platform (a `target::table::OSES` index) the build is for: the host, or `--target=`. Its cross
    /// toolchain, baseline CPU features and their C flag depend on it.
    pub(package) target: i32,
    pub(package) toml: Vector<toml::TomlItem>,
    pub(package) bin: String,
    pub(package) root: String,
    pub(package) out_dir: String,
    pub(package) test_dir: String, // where `super-c test` discovers the suite (default "tests")
    pub(package) bench_dir: String, // where `super-c bench` discovers '@bench' functions (default "bench")
    pub(package) ldflags: Vector<String>,
    pub(package) ldlibs: Vector<String>,
    pub(package) jobs: u32,
    pub(package) ce_steps: u32, // const-eval step budget; 0 = the engine default (~2M); CLI --const-eval-steps overrides
    pub(package) ce_mem: u64, // const-eval memory budget in bytes; 0 = the engine default; CLI --const-eval-memory overrides
    pub(package) std_internals: bool, // `std_internals`: the project names std's `pub(package)` items (unstable internals)
    pub(package) default_profile: String,
    pub(package) profiles: Vector<Profile<'a>>,
    pub(package) commands: Vector<Command<'a>>,
    pub(package) bins: Vector<BinTarget>, // extra [bin.NAME] targets (the top-level bin/root pair is first-class)
    pub(package) lib_name: String, // [lib] name; empty = no library target
    pub(package) lib_root: String, // [lib] root (default src/lib.spc)
    pub(package) lib_static: bool, // [lib] type contains "static" (the default when [lib] is present)
    pub(package) lib_shared: bool, // [lib] type contains "shared"
    /// [lib] exports = "c": the shared library exports its `@export` symbols alone, its C ABI; "all" (the
    /// default) exports every global symbol.
    pub(package) lib_exports_c: bool,
    pub(package) shards: Vector<loader::ShardRule>, // [shards] and [instance-shards]: per-module counts
    pub(package) target_features: Vector<String>, // `target-features`: the CPU features to enable (`--target-feature` names)
    pub(package) target_cpu: String, // `target-cpu`: an x86-64 level applied before `target-features` (`--target-cpu`)
    pub(package) simd_width: u32, // `simd-width`: 512 lets the vector planner use 512-bit entries on AVX-512; 0 = 256
    pub(package) simd_dispatch: String, // `simd-dispatch`: `off`, or the x86-64 levels run-time copies are made for; empty = x86-64-v3 (off at opt-level 0 or 1)
    /// `[tools] analyzers`: the project's analyzer modules (project-relative `.spc` files), each with a
    /// `pub fn analyzers() Vector<Box<dyn Analyzer>>`; `lint` builds them into a compiler and runs them.
    pub(package) tools: Vector<String>,
    /// `[tools] compiler`: the vendored compiler the tools build with (default `vendor/superc`).
    pub(package) tools_compiler: String,
    /// `[tools] hooks`: the project's build hook modules, each with a `pub fn hooks() Vector<Box<dyn Hook>>`
    /// (`api::build`); `build` and `run` build them into a compiler and build through it.
    pub(package) hooks: Vector<String>,
    /// The `[step.NAME]` sections, in declaration order.
    pub(package) steps: Vector<Step>,
    /// `lint-exclude`: project directories the whole-project lint skips (projects that build only once a
    /// client vendors their dependencies, such as documentation examples).
    pub(package) lint_exclude: Vector<String>,
    /// `str_id` of the text `load` read, and the file's mtime from the stat before the read (as
    /// `loader::read_file_mt` gives them): the emit stamp's record of the manifest. Both 0 for a manifest
    /// not read from a file.
    pub(package) src_id: u64,
    pub(package) mtime: i64,
}

// Bootstrap constraint: the release compiler dispatches a generic `Free` call to a named `free`
// symbol, and a synthesized destructor has none.
extend Manifest as Free {
    pub fn free(self: &mut Self) {
        self.toml.free();
        self.bin.free();
        self.root.free();
        self.out_dir.free();
        self.test_dir.free();
        self.bench_dir.free();
        self.ldflags.free();
        self.ldlibs.free();
        self.default_profile.free();
        self.profiles.free();
        self.commands.free();
        self.bins.free();
        self.lib_name.free();
        self.lib_root.free();
        self.shards.free();
        self.target_features.free();
        self.target_cpu.free();
        self.simd_dispatch.free();
        self.tools.free();
        self.tools_compiler.free();
        self.hooks.free();
        self.steps.free();
        self.lint_exclude.free();
    }
}

extend Profile {
    fn new(name: str) Self {
        return Profile {
            name: name,
            ldflags: Vector::<String>::new(),
            link_args: Vector::<String>::new(),
            strip: false,
            opt: OPT_NONE,
            debug: false,
            lockdep: false,
            overflow_checks: -1,
            target_features: Vector::<String>::new(),
            has_features: false,
        };
    }

    /// Whether integer overflow wraps instead of trapping: `overflow-checks = false`, or without the key
    /// an `opt-level` of 2, 3, "s" or "z".
    pub(package) const fn arith_wraps(self: &Self) bool {
        if self.overflow_checks >= 0 {
            return self.overflow_checks == 0;
        }
        return self.opt >= 2;
    }
}

/// A manifest holding nothing but the built-in profiles, for a build with no `build.toml` to read them
/// from: `super-c release foo.spc` compiles and links in one command and still has to honour the profile
/// it was asked for. Free it like any other manifest.
pub(package) fn builtins_only<'a>() Manifest<'a> {
    let mut m = Manifest::new();
    m.add_builtin_profiles();
    return m;
}

/// Whether `path` names a file inside the project: relative, without a `..` segment, not empty.
pub(package) fn project_path(path: str) bool {
    if path.len() == 0 || path.byte_at(0) == b'/' || path.byte_at(0) == b'\\' || path.find(":") >= 0 {
        return false;
    }
    for seg in path.split("/") {
        if seg == ".." {
            return false;
        }
    }
    return true;
}

// Validate the `[step.NAME]` sections: an argv and an output each; project paths; environment variable
// names; no file written by two steps; no step reading a file that it or a later step writes.
fn check_steps(steps: &Vector<Step>, errs: &mut diag::Errors) {
    for i in 0..steps.len() {
        let st = &steps[i];
        let nm = st.name.as_str();
        if st.argv.len() == 0 || st.argv[0].len() == 0 {
            errs.emit(dc::MANIFEST_ERROR, 0, 1, format("[step.{}] needs an 'argv' that names its program", nm));
        }
        if st.outputs.len() == 0 {
            errs.emit(dc::MANIFEST_ERROR, 0, 1, format("[step.{}] needs 'outputs': the files it writes", nm));
        }
        for k in 0..st.inputs.len() + st.outputs.len() {
            let f = if k < st.inputs.len() {
                st.inputs[k].as_str();
            } else {
                st.outputs[k - st.inputs.len()].as_str();
            };
            if !project_path(f) {
                errs.emit(dc::MANIFEST_ERROR, 0, 1, format("[step.{}]: '{}' is not a path inside the project", nm, f));
            }
        }
        for k in 0..st.env.len() {
            let e = st.env[k].as_str();
            if e.len() == 0 || e.find("=") >= 0 {
                errs.emit(
                    dc::MANIFEST_ERROR,
                    0,
                    1,
                    format("[step.{}]: '{}' is not an environment variable name", nm, e),
                );
            }
        }
        for k in 0..st.outputs.len() {
            let o = st.outputs[k].as_str();
            for j in 0..steps.len() {
                if j < i && steps[j].outputs.contains(&st.outputs[k]) {
                    errs.emit(
                        dc::MANIFEST_ERROR,
                        0,
                        1,
                        format("[step.{}] and [step.{}] both write '{}'", steps[j].name.as_str(), nm, o),
                    );
                }
                if j <= i && steps[j].inputs.contains(&st.outputs[k]) {
                    errs.emit(
                        dc::MANIFEST_ERROR,
                        0,
                        1,
                        format(
                            "[step.{}] reads '{}', which [step.{}] writes: a step reads only what earlier steps write",
                            steps[j].name.as_str(),
                            o,
                            nm,
                        ),
                    );
                }
            }
        }
    }
}

// The array replaces `dst` (a built-in profile's flags when the section names one).
fn take_arr(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut Vector<String>) {
    if it.val.kind != toml::TV_ARR {
        errs.emit(
            dc::EXPECTS_ARRAY_STRINGS,
            it.at,
            it.key.len() as u32,
            format("'{}' expects an array of strings", it.key.as_str()),
        );
        return;
    }
    dst.clear();
    for i in 0..it.val.arr.len() {
        dst.push(it.val.arr.at(i).clone());
    }
}

// A convention directory (`test-dir` / `bench-dir`) becomes a module-path prefix of the generated
// roots, so it must stay a plain workspace-relative path: strip a trailing '/', reject absolute
// paths and '..' segments.
fn norm_conv_dir(dir: &mut String, key: str, errs: &mut diag::Errors) {
    while dir.len() > 1 && dir.as_str()[dir.len() - 1] == b'/' {
        dir.truncate(dir.len() - 1);
    }
    let s = dir.as_str();
    let mut bad = s.len() == 0 || s[0] == b'/';
    for i in 0..s.len() {
        if s[i] == b'.' && i + 1 < s.len() && s[i + 1] == b'.' {
            bad = true;
        }
        if s[i] == b'\\' {
            bad = true;
        }
    }
    if bad {
        errs.emit(
            dc::MUST_PLAIN_WORKSPACE_RELATIVE_DIRECTORY_GOT,
            0,
            1,
            format("'{}' must be a plain workspace-relative directory, got '{}'", key, s),
        );
    }
}

const COMMANDS: [str<'static>; 15] = [
    "build",
    "release",
    "fmt",
    "lint",
    "command",
    "run",
    "clean",
    "test",
    "bench",
    "lsp",
    "new",
    "init",
    "vendor",
    "bindgen",
    "tool-server",
];

/// The position of subcommand `name` in `Mode` declaration order after MODE_DEFAULT (main dispatches
/// position k to Mode k + 1); -1 when `name` is no subcommand. The names are reserved, so a
/// `[command.NAME]` can never shadow one.
pub(package) const fn subcommand_index(name: str) i32 {
    let names: []str = COMMANDS;
    for k in 0..names.len() {
        if names[k] == name {
            return k as i32;
        }
    }
    return -1;
}

// A section or key outside this compiler's schema: an error, except under bootstrap (see `load`).
fn unknown(errs: &mut diag::Errors, bootstrap: bool, at: u32, len: u32, msg: String) {
    if !bootstrap {
        errs.emit(dc::MANIFEST_ERROR, at, len, msg);
    }
}

fn set_str(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut String) {
    if it.val.kind != toml::TV_STR {
        errs.emit(dc::EXPECTS_STRING, it.at, it.key.len() as u32, format("'{}' expects a string", it.key.as_str()));
        return;
    }
    *dst = it.val.s.clone();
}

fn set_u32(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut u32) {
    if it.val.kind != toml::TV_INT || it.val.i < 0 || it.val.i > 4294967295 {
        errs.emit(
            dc::EXPECTS_NON_NEGATIVE_INTEGER,
            it.at,
            it.key.len() as u32,
            format("'{}' expects a non-negative integer", it.key.as_str()),
        );
        return;
    }
    *dst = it.val.i as u32;
}

fn set_bool(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut bool) {
    if it.val.kind != toml::TV_BOOL {
        errs.emit(
            dc::EXPECTS_TRUE_FALSE,
            it.at,
            it.key.len() as u32,
            format("'{}' expects true or false", it.key.as_str()),
        );
        return;
    }
    *dst = it.val.b;
}

/// Load and validate <path>, applying defaults (out-dir "build", default-profile
/// "debug", built-in profiles). Prints its own diagnostics; None on any error. `bootstrap` (the
/// --bootstrap-tags build) skips sections and keys this compiler does not know, so a previous release
/// can build a source tree whose manifest already uses additions it predates; the compiler it produces
/// reads the same manifest strictly.
pub(package) fn load(path: str, bootstrap: bool) Option<Manifest> {
    let mut mt: i64 = 0;
    let src_opt = loader::read_file_mt(path, &mut mt);
    if src_opt.is_none() {
        eprintln("build: cannot read '{}'", path);
        return Option::<Manifest>::None;
    }
    let src = src_opt.unwrap();
    let (mo, errs) = parse_check(src.as_str(), path, bootstrap);
    if mo.is_none() {
        return mo;
    }
    let mut m = mo.unwrap();
    m.src_id = dutil::str_id(src.as_str());
    m.mtime = mt;
    return Option::<Manifest>::Some(m);
}

/// Parse and VALIDATE a manifest, returning the diagnostics alongside it. A non-empty `file` renders and
/// logs them (what the build wants); an empty one leaves them raw with their spans, for a caller that
/// formats its own (the language server). The manifest is None when the file is unusable.
pub(package) fn parse_check<'a>(src: str, file: str, bootstrap: bool) (Option<Manifest<'a>>, diag::Errors) {
    let mut errs = diag::Errors::new();
    let items_opt = toml::parse_into(src, &mut errs);
    if items_opt.is_none() {
        if file.len() != 0 {
            errs.finalize(src, file);
            errs.log();
        }
        return Option::<Manifest>::None, errs;
    }

    let mut m = Manifest::new();
    // Built-ins first, so a [profile.NAME] section naming one overrides only the keys it sets.
    m.add_builtin_profiles();
    let items = items_opt.unwrap();
    let mut rejected = Vector::<String>::new(); // [command.<builtin>] sections already reported
    let mut saw_lib = false;
    for x in 0..items.len() {
        let it = items.at(x);
        let sec = it.section.as_str();
        let key = it.key.as_str();
        if key.len() == 0 {
            // A bare section header: only its presence matters (and only [lib] cares).
            if sec == "lib" {
                saw_lib = true;
            }
            continue;
        }
        if sec == "" {
            if key == "bin" {
                set_str(it, &mut errs, &mut m.bin);
            } else if key == "root" {
                set_str(it, &mut errs, &mut m.root);
            } else if key == "out-dir" {
                set_str(it, &mut errs, &mut m.out_dir);
            } else if key == "test-dir" {
                set_str(it, &mut errs, &mut m.test_dir);
            } else if key == "bench-dir" {
                set_str(it, &mut errs, &mut m.bench_dir);
            } else if key == "ldflags" {
                take_arr(it, &mut errs, &mut m.ldflags);
            } else if key == "ldlibs" {
                take_arr(it, &mut errs, &mut m.ldlibs);
            } else if key == "jobs" {
                set_u32(it, &mut errs, &mut m.jobs);
            } else if key == "const-eval-steps" {
                // 0 = engine default; a `--const-eval-steps` CLI flag overrides this at build time.
                set_u32(it, &mut errs, &mut m.ce_steps);
            } else if key == "const-eval-memory" {
                // bytes; 0 = engine default; a `--const-eval-memory` CLI flag overrides this.
                if it.val.kind != toml::TV_INT || it.val.i < 0 {
                    errs.emit(
                        dc::CONST_EVAL_MEMORY_EXPECTS_NON_NEGATIVE,
                        it.at,
                        key.len() as u32,
                        format("'const-eval-memory' expects a non-negative integer (bytes)"),
                    );
                } else {
                    m.ce_mem = it.val.i as u64;
                }
            } else if key == "std_internals" {
                set_bool(it, &mut errs, &mut m.std_internals);
            } else if key == "lint-exclude" {
                take_arr(it, &mut errs, &mut m.lint_exclude);
                for k in 0..m.lint_exclude.len() {
                    let d = m.lint_exclude[k].as_str();
                    if !project_path(d) {
                        errs.emit(
                            dc::MANIFEST_ERROR,
                            it.at,
                            key.len() as u32,
                            format("'lint-exclude': '{}' is not a path inside the project", d),
                        );
                    }
                }
            } else if key == "default-profile" {
                set_str(it, &mut errs, &mut m.default_profile);
            } else if key == "target-features" {
                take_arr(it, &mut errs, &mut m.target_features);
            } else if key == "target-cpu" {
                set_str(it, &mut errs, &mut m.target_cpu);
            } else if key == "simd-width" {
                set_u32(it, &mut errs, &mut m.simd_width);
                if m.simd_width != 256 && m.simd_width != 512 {
                    errs.emit(
                        dc::SIMD_WIDTH_EXPECTS_256_512,
                        it.at,
                        key.len() as u32,
                        format("'simd-width' expects 256 or 512"),
                    );
                }
            } else if key == "simd-dispatch" {
                set_str(it, &mut errs, &mut m.simd_dispatch);
                let mut e9 = String::new();
                if !cf::dispatch_ok(m.simd_dispatch.as_str(), &mut e9) {
                    errs.emit(dc::MANIFEST_ERROR, it.at, key.len() as u32, e9);
                }
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown key '{}'", key));
            }
        } else if sec.starts_with("profile.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            let mut pi = m.profile_index(name);
            if pi < 0 {
                m.profiles.push(Profile::new(name));
                pi = m.profiles.len() as i64 - 1;
            }
            let p = &mut m.profiles[pi as usize];
            if key == "ldflags" {
                take_arr(it, &mut errs, &mut p.ldflags);
            } else if key == "link-args" {
                take_arr(it, &mut errs, &mut p.link_args);
            } else if key == "opt-level" {
                // Cargo's spelling: an integer 0 to 3, or "s" / "z" (the digits quoted are taken too).
                let mut lvl: i32 = -1;
                if it.val.kind == toml::TV_INT && it.val.i >= 0 && it.val.i <= 3 {
                    lvl = it.val.i as i32;
                } else if it.val.kind == toml::TV_STR {
                    let v = it.val.s.as_str();
                    if v.len() == 1 && v[0] >= b'0' && v[0] <= b'3' {
                        lvl = v[0] - b'0';
                    } else if v == "s" {
                        lvl = OPT_S;
                    } else if v == "z" {
                        lvl = OPT_Z;
                    }
                }
                if lvl < 0 {
                    errs.emit(
                        dc::OPT_LEVEL_EXPECTS_0_1_2,
                        it.at,
                        key.len() as u32,
                        format("'opt-level' expects 0, 1, 2, 3, \"s\" or \"z\""),
                    );
                } else {
                    p.opt = lvl;
                }
            } else if key == "strip" {
                set_bool(it, &mut errs, &mut p.strip);
            } else if key == "debug" {
                set_bool(it, &mut errs, &mut p.debug);
            } else if key == "lockdep" {
                set_bool(it, &mut errs, &mut p.lockdep);
            } else if key == "target-features" {
                take_arr(it, &mut errs, &mut p.target_features);
                p.has_features = true;
            } else if key == "overflow-checks" {
                let mut on = false;
                set_bool(it, &mut errs, &mut on);
                p.overflow_checks = on as i32;
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown profile key '{}'", key));
            }
        } else if sec.starts_with("command.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            // A built-in subcommand cannot be overridden: a `[command.build]` that shadows `build`
            // makes every invocation mean something else per project. Custom names only.
            if subcommand_index(name) >= 0 {
                let mut seen = false;
                for r in 0..rejected.len() {
                    if rejected.at(r).as_str() == name {
                        seen = true;
                    }
                }
                if !seen {
                    rejected.push(String::from_str(name));
                    errs.emit(
                        dc::BUILT_SUBCOMMAND_CANNOT_OVERRIDDEN_PICK_ANOTHER,
                        it.at,
                        sec.len() as u32,
                        format(
                            "'{}' is a built-in subcommand and cannot be overridden; pick another command name",
                            name,
                        ),
                    );
                }
                continue;
            }
            let mut ci = m.command_index(name);
            if ci < 0 {
                m.commands.push(
                    Command {
                        name: name,
                        run: Vector::<String>::new(),
                        needs_build: false,
                        env_k: Vector::<String>::new(),
                        env_v: Vector::<String>::new(),
                    },
                );
                ci = m.commands.len() as i64 - 1;
            }
            let c = &mut m.commands[ci as usize];
            if key == "run" {
                take_arr(it, &mut errs, &mut c.run);
            } else if key == "needs-build" {
                set_bool(it, &mut errs, &mut c.needs_build);
            } else if key == "env" {
                if it.val.kind != toml::TV_TBL {
                    errs.emit(
                        dc::ENV_EXPECTS_INLINE_TABLE_STRINGS,
                        it.at,
                        3,
                        format("'env' expects an inline table of strings"),
                    );
                } else {
                    for e in 0..it.val.tbl.len() {
                        c.env_k.push(it.val.tbl.at(e).k.clone());
                        c.env_v.push(it.val.tbl.at(e).v.clone());
                    }
                }
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown command key '{}'", key));
            }
        } else if sec == "shards" || sec == "instance-shards" {
            if it.val.kind != toml::TV_INT || it.val.i < 1 || it.val.i > 255 {
                errs.emit(
                    dc::EXPECTS_COUNT_1_255,
                    it.at,
                    key.len() as u32,
                    format("'[{}]' expects a count from 1 to 255", sec),
                );
            } else {
                let mut ri = m.shards.len();
                for i in 0..m.shards.len() {
                    if m.shards.at(i).module.as_str() == key {
                        ri = i;
                    }
                }
                if ri == m.shards.len() {
                    m.shards.push(loader::ShardRule { module: String::from_str(key), tus: 1, insts: 1 });
                }
                if sec == "shards" {
                    m.shards.index_mut(ri).tus = it.val.i as u32;
                } else {
                    m.shards.index_mut(ri).insts = it.val.i as u32;
                }
            }
        } else if sec == "lib" {
            saw_lib = true;
            if key == "name" {
                set_str(it, &mut errs, &mut m.lib_name);
            } else if key == "root" {
                set_str(it, &mut errs, &mut m.lib_root);
            } else if key == "exports" {
                let mut e = String::new();
                set_str(it, &mut errs, &mut e);
                if e.as_str() == "c" {
                    m.lib_exports_c = true;
                } else if e.as_str() != "all" {
                    errs.emit(
                        dc::MANIFEST_ERROR,
                        it.at,
                        key.len() as u32,
                        format("[lib] exports takes \"all\" or \"c\", got '{}'", e.as_str()),
                    );
                }
            } else if key == "type" {
                let mut kinds = Vector::<String>::new();
                take_arr(it, &mut errs, &mut kinds);
                for k in 0..kinds.len() {
                    let kind = kinds.at(k).as_str();
                    if kind == "static" {
                        m.lib_static = true;
                    } else if kind == "shared" {
                        m.lib_shared = true;
                    } else {
                        errs.emit(
                            dc::UNKNOWN_LIBRARY_TYPE_STATIC_SHARED,
                            it.at,
                            4,
                            format("unknown library type '{}' (static | shared)", kind),
                        );
                    }
                }
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown [lib] key '{}'", key));
            }
        } else if sec == "tools" {
            if key == "analyzers" {
                take_arr(it, &mut errs, &mut m.tools);
            } else if key == "compiler" {
                set_str(it, &mut errs, &mut m.tools_compiler);
            } else if key == "hooks" {
                take_arr(it, &mut errs, &mut m.hooks);
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown [tools] key '{}'", key));
            }
        } else if sec.starts_with("step.") && sec.len() > 5 {
            let name = sec.slice(5, sec.len());
            let mut si = m.steps.len();
            for i in 0..m.steps.len() {
                if m.steps[i].name.as_str() == name {
                    si = i;
                }
            }
            if si == m.steps.len() {
                m.steps.push(
                    Step {
                        name: String::from_str(name),
                        argv: Vector::<String>::new(),
                        inputs: Vector::<String>::new(),
                        outputs: Vector::<String>::new(),
                        env: Vector::<String>::new(),
                        cache: true,
                    },
                );
            }
            let st = &mut m.steps[si];
            if key == "argv" {
                take_arr(it, &mut errs, &mut st.argv);
            } else if key == "inputs" {
                take_arr(it, &mut errs, &mut st.inputs);
            } else if key == "outputs" {
                take_arr(it, &mut errs, &mut st.outputs);
            } else if key == "env" {
                take_arr(it, &mut errs, &mut st.env);
            } else if key == "cache" {
                set_bool(it, &mut errs, &mut st.cache);
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown [step.{}] key '{}'", name, key));
            }
        } else if sec.starts_with("bin.") && sec.len() > 4 {
            let name = sec.slice(4, sec.len());
            let mut bi: i64 = -1;
            for i in 0..m.bins.len() {
                if m.bins.at(i).name.as_str() == name {
                    bi = i as i64;
                }
            }
            if bi < 0 {
                m.bins.push(BinTarget { name: String::from_str(name), root: String::new() });
                bi = m.bins.len() as i64 - 1;
            }
            if key == "root" {
                set_str(it, &mut errs, &mut m.bins[bi as usize].root);
            } else {
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown [bin.{}] key '{}'", name, key));
            }
        } else {
            unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown section '{}'", sec));
        }
    }
    // The name views above point into the items' section Strings: the Manifest takes ownership.
    m.toml = items;
    // Defaults + validation.
    if m.out_dir.len() == 0 {
        m.out_dir.push_str("build");
    }
    if m.tools_compiler.len() == 0 {
        m.tools_compiler.push_str("vendor/superc");
    }
    if m.test_dir.len() == 0 {
        m.test_dir.push_str("tests");
    }
    if m.bench_dir.len() == 0 {
        m.bench_dir.push_str("bench");
    }
    norm_conv_dir(&mut m.test_dir, "test-dir", &mut errs);
    norm_conv_dir(&mut m.bench_dir, "bench-dir", &mut errs);
    if m.default_profile.len() == 0 {
        m.default_profile.push_str("debug");
    }
    // [lib] defaults: root src/lib.spc, name after the primary binary, static unless told otherwise.
    if saw_lib {
        if m.lib_root.len() == 0 {
            m.lib_root.push_str("src/lib.spc");
        }
        if m.lib_name.len() == 0 {
            if m.bin.len() != 0 {
                m.lib_name.push_string(&m.bin);
            } else {
                errs.emit(
                    dc::LIB_NEEDS_NAME_WHEN_MANIFEST_DECLARES,
                    0,
                    1,
                    format("[lib] needs a 'name' when the manifest declares no 'bin'"),
                );
            }
        }
        if !m.lib_static && !m.lib_shared {
            m.lib_static = true;
        }
    }
    // A library-only project needs no primary binary; its lib root anchors the source tree.
    if m.root.len() == 0 && saw_lib {
        m.root.push_string(&m.lib_root);
    }
    if m.bin.len() == 0 && !saw_lib {
        errs.emit(
            dc::MISSING_REQUIRED_KEY_BIN_LIB_SECTION,
            0,
            1,
            format("missing required key 'bin' (or a [lib] section)"),
        );
    }
    if m.root.len() == 0 {
        errs.emit(dc::MISSING_REQUIRED_KEY_ROOT, 0, 1, format("missing required key 'root'"));
    }
    for i in 0..m.bins.len() {
        if m.bins.at(i).root.len() == 0 {
            errs.emit(dc::BIN_NEEDS_ROOT, 0, 1, format("[bin.{}] needs a 'root'", m.bins.at(i).name.as_str()));
        }
        if m.bins.at(i).name.as_str() == m.bin.as_str() {
            errs.emit(
                dc::BIN_COLLIDES_MANIFEST_S_PRIMARY_BIN,
                0,
                1,
                format("[bin.{}] collides with the manifest's primary 'bin'", m.bins.at(i).name.as_str()),
            );
        }
    }
    check_steps(&m.steps, &mut errs);
    if m.profile_index(m.default_profile.as_str()) < 0 {
        errs.emit(
            dc::DEFAULT_PROFILE_NOT_DEFINED,
            0,
            1,
            format("default-profile '{}' is not defined", m.default_profile.as_str()),
        );
    }
    if errs.has_errors() {
        if file.len() != 0 {
            errs.finalize(src, file);
            errs.log();
        }
        return Option::<Manifest>::None, errs;
    }
    return Option::<Manifest>::Some(m), errs;
}

extend Manifest {
    fn new<'a>() Manifest<'a> {
        return Manifest {
            arch: unsafe shim::sc_host_arch(),
            target: unsafe shim::sc_host_platform(),
            toml: Vector::<toml::TomlItem>::new(),
            bin: String::new(),
            root: String::new(),
            out_dir: String::new(),
            test_dir: String::new(),
            bench_dir: String::new(),
            ldflags: Vector::<String>::new(),
            ldlibs: Vector::<String>::new(),
            jobs: 0,
            ce_steps: 0,
            ce_mem: 0,
            default_profile: String::new(),
            profiles: Vector::<Profile>::new(),
            commands: Vector::<Command>::new(),
            bins: Vector::<BinTarget>::new(),
            lib_name: String::new(),
            lib_root: String::new(),
            lib_static: false,
            lib_shared: false,
            shards: Vector::<loader::ShardRule>::new(),
            target_features: Vector::<String>::new(),
            target_cpu: String::new(),
            simd_width: 0,
            simd_dispatch: String::new(),
            src_id: 0,
            mtime: 0,
        };
    }

    /// Index of the profile named `name`, or -1 when absent.
    pub(package) const fn profile_index(self: &Self, name: str) i64 {
        for i in 0..self.profiles.len() {
            if self.profiles.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    /// Index of the command named `name`, or -1 when absent.
    pub(package) const fn command_index(self: &Self, name: str) i64 {
        for i in 0..self.commands.len() {
            if self.commands.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    // The profiles available out of the box. A [profile.NAME] section with the same name starts from
    // these values: a key it sets replaces the built-in's, the rest stay.
    fn add_builtin_profiles(self: &mut Self) {
        // The default: unoptimized, with debug information.
        {
            let mut p = Profile::new("debug");
            p.opt = 0;
            p.debug = true;
            self.profiles.push(p);
        }
        {
            let mut p = Profile::new("release");
            p.strip = true;
            p.opt = 3;
            self.profiles.push(p);
        }
        {
            // Optimization parity with `release`: the bench should measure the compiler users run. The
            // debug information stays so profiles remain readable.
            let mut p = Profile::new("bench");
            p.opt = 3;
            p.debug = true;
            self.profiles.push(p);
        }
        {
            // The `super-c test` runner, and the compiler under test when no `--profile` is given. The
            // harness drives thousands of compiles, which an optimized build runs cheaper.
            let mut p = Profile::new("test");
            p.opt = 1;
            self.profiles.push(p);
        }
    }
}
