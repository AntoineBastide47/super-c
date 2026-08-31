// build.toml schema: maps parsed TOML items onto the Build manifest, applies defaults (built-in
// debug/dev/release/bench profiles), and validates. Unknown sections/keys are hard errors so typos
// never silently no-op.
import stdio;
import driver_shim as shim;
import build_system::toml as toml;
import module::loader as loader;
import utils::errors as diag;

/// One [profile.NAME]: per-profile cflags/ldflags appended after the manifest-level ones; `strip`
/// runs strip on the freshly linked binary.
pub struct Profile<'a> {
    pub name: str<'a>,
    pub cflags: Vector<String>,
    pub ldflags: Vector<String>,
    pub strip: bool,
}

extend Profile as Free {
    pub fn free(self: &mut Self) {
        self.cflags.free();
        self.ldflags.free();
    }
}

/// One extra binary target: `[bin.NAME] root = "..."` (the top-level `bin`/`root` pair is the
/// primary binary). `super-c build` builds every target; `--bin=NAME` selects one.
pub struct BinTarget {
    pub name: String,
    pub root: String,
}

extend BinTarget as Free {
    pub fn free(self: &mut Self) {
        self.name.free();
        self.root.free();
    }
}

/// One [command.NAME] for `super-c command <name>`: shell lines executed in order, stopping at the
/// first failure. Built-in subcommand names are reserved -- a command can never shadow one.
pub struct Command<'a> {
    pub name: str<'a>,
    pub run: Vector<String>,
    pub needs_build: bool, // needs-build = true: run a manifest build before the lines
    pub env_k: Vector<String>, // parallel with env_v: KEY='VALUE' prefixes applied to every line
    pub env_v: Vector<String>,
}

extend Command as Free {
    pub fn free(self: &mut Self) {
        self.run.free();
        self.env_k.free();
        self.env_v.free();
    }
}

/// The validated build.toml. `bin` is where the project's binary is INSTALLED: each profile links its own
/// copy under `<out_dir>/<profile>/`, and only `build`/`release` (never `test` or `run`) copy one onto that
/// name -- so a profile can never quietly stand in for another's artifact.
/// Ownership: `toml` keeps the parsed items alive -- Profile/Command `name` views borrow into their
/// section strings.
pub struct Manifest<'a> {
    /// Instruction set `@arch` gates against: 0 x86_64, 1 aarch64, 2 wasm32, -1 unknown. Defaults to the
    /// host; the driver overwrites it for `--arch=`.
    pub arch: i32,
    /// Cross-compilation toolchain: 0 none (host cc), 1 ios, 2 android, 3 wasm. Set by `--target=`; it
    /// selects the compiler, sysroot and triple, never the platform gate.
    pub sdk: i32,
    pub toml: Vector<toml::TomlItem>,
    pub bin: String,
    pub root: String,
    pub out_dir: String,
    pub test_dir: String, // where `super-c test` discovers the suite (default "tests")
    pub bench_dir: String, // where `super-c bench` discovers '@bench' functions (default "bench")
    pub cc: String,
    pub cstd: String,
    pub cflags: Vector<String>,
    pub ldflags: Vector<String>,
    pub ldlibs: Vector<String>,
    pub jobs: u32,
    pub ce_steps: u32, // const-eval step budget; 0 = the engine default (~2M). CLI --const-eval-steps overrides.
    pub ce_mem: u64, // const-eval memory budget in bytes; 0 = the engine default. CLI --const-eval-memory overrides.
    pub default_profile: String,
    pub profiles: Vector<Profile<'a>>,
    pub commands: Vector<Command<'a>>,
    pub bins: Vector<BinTarget>, // extra [bin.NAME] targets (the top-level bin/root pair is first-class)
    pub lib_name: String, // [lib] name; empty = no library target
    pub lib_root: String, // [lib] root (default src/lib.spc)
    pub lib_static: bool, // [lib] type contains "static" (the default when [lib] is present)
    pub lib_shared: bool, // [lib] type contains "shared"
}

extend Manifest as Free {
    pub fn free(self: &mut Self) {
        self.toml.free();
        self.bin.free();
        self.root.free();
        self.out_dir.free();
        self.test_dir.free();
        self.bench_dir.free();
        self.cc.free();
        self.cstd.free();
        self.cflags.free();
        self.ldflags.free();
        self.ldlibs.free();
        self.default_profile.free();
        self.profiles.free();
        self.commands.free();
        self.bins.free();
        self.lib_name.free();
        self.lib_root.free();
    }
}

extend Profile {
    fn new(name: str) Self {
        return Profile { name: name, cflags: Vector::<String>::new(), ldflags: Vector::<String>::new(), strip: false };
    }
}

fn push_flags(dst: &mut Vector<String>, flags: str) {
    // split a flag string on spaces so built-in profiles can be written as one literal
    let mut i: usize = 0;
    let n = flags.len();
    while i < n {
        while i < n && flags[i] == b' ' {
            i = i + 1;
        }
        let s = i;
        while i < n && flags[i] != b' ' {
            i = i + 1;
        }
        if i > s {
            dst.push(String::from_str(flags.slice(s, i)));
        }
    }
}

/// A manifest holding nothing but the built-in profiles, for a build with no `build.toml` to read them
/// from -- `super-c release foo.spc` compiles and links in one command and still has to honour the profile
/// it was asked for. Free it like any other manifest.
pub fn builtins_only<'a>() Manifest<'a> {
    let mut m = Manifest::new();
    m.add_builtin_profiles();
    return m;
}

fn take_arr(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut Vector<String>) {
    if it.val.kind != toml::TV_ARR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects an array of strings", it.key.as_str()));
        return;
    }
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
        errs.emit(0, 1, format("'{}' must be a plain workspace-relative directory, got '{}'", key, s));
    }
}

// The `super-c` subcommand names: reserved, so a `[command.NAME]` can never shadow one.
const fn is_builtin_command(name: str) bool {
    return name == "build" || name == "release" || name == "fmt" || name == "lint" || name == "run" || name == "command" || name == "clean" || name == "test" || name == "bench" || name == "lsp" || name == "new" || name == "init";
}

fn set_str(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut String) {
    if it.val.kind != toml::TV_STR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects a string", it.key.as_str()));
        return;
    }
    *dst = it.val.s.clone();
}

fn set_bool(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut bool) {
    if it.val.kind != toml::TV_BOOL {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects true or false", it.key.as_str()));
        return;
    }
    *dst = it.val.b;
}

/// Load and validate <path>, applying defaults (out-dir "build", cstd c11+POSIX, default-profile
/// "dev", built-in profiles). Prints its own diagnostics; None on any error.
pub fn load(path: str) Option<Manifest> {
    let src_opt = loader::read_file(path);
    if src_opt.is_none() {
        eprintln("build: cannot read '{}'", path);
        return Option::<Manifest>::None;
    }
    let src = src_opt.unwrap();
    let (m, errs) = parse_check(src.as_str(), path);
    return m;
}

/// Parse and VALIDATE a manifest, returning the diagnostics alongside it. A non-empty `file` renders and
/// logs them (what the build wants); an empty one leaves them raw with their spans, for a caller that
/// formats its own (the language server). The manifest is None when the file is unusable.
pub fn parse_check<'a>(src: str, file: str) (Option<Manifest<'a>>, diag::Errors) {
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
    let items = items_opt.unwrap();
    let mut rejected = Vector::<String>::new(); // [command.<builtin>] sections already reported
    let mut saw_lib = false;
    for x in 0..items.len() {
        let it = items.at(x);
        let sec = it.section.as_str();
        let key = it.key.as_str();
        if key.len() == 0 {
            // a bare section header: only its presence matters (and only [lib] cares)
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
            } else if key == "cc" {
                set_str(it, &mut errs, &mut m.cc);
            } else if key == "cstd" {
                set_str(it, &mut errs, &mut m.cstd);
            } else if key == "cflags" {
                take_arr(it, &mut errs, &mut m.cflags);
            } else if key == "ldflags" {
                take_arr(it, &mut errs, &mut m.ldflags);
            } else if key == "ldlibs" {
                take_arr(it, &mut errs, &mut m.ldlibs);
            } else if key == "jobs" {
                if it.val.kind != toml::TV_INT || it.val.i < 0 {
                    errs.emit(it.at, 4, format("'jobs' expects a non-negative integer"));
                } else {
                    m.jobs = it.val.i as u32;
                }
            } else if key == "const-eval-steps" {
                // 0 = engine default; a `--const-eval-steps` CLI flag overrides this at build time.
                if it.val.kind != toml::TV_INT || it.val.i < 0 || it.val.i > 4294967295 {
                    errs.emit(it.at, key.len() as u32, format("'const-eval-steps' expects a non-negative integer"));
                } else {
                    m.ce_steps = it.val.i as u32;
                }
            } else if key == "const-eval-memory" {
                // bytes; 0 = engine default; a `--const-eval-memory` CLI flag overrides this.
                if it.val.kind != toml::TV_INT || it.val.i < 0 {
                    errs.emit(
                        it.at,
                        key.len() as u32,
                        format("'const-eval-memory' expects a non-negative integer (bytes)"),
                    );
                } else {
                    m.ce_mem = it.val.i as u64;
                }
            } else if key == "default-profile" {
                set_str(it, &mut errs, &mut m.default_profile);
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown key '{}'", key));
            }
        } else if sec.starts_with("profile.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            let mut pi = m.profile_index(name);
            if pi < 0 {
                m.profiles.push(Profile::new(name));
                pi = m.profiles.len() as i64 - 1;
            }
            let p = &mut m.profiles[pi as usize];
            if key == "cflags" {
                take_arr(it, &mut errs, &mut p.cflags);
            } else if key == "ldflags" {
                take_arr(it, &mut errs, &mut p.ldflags);
            } else if key == "strip" {
                set_bool(it, &mut errs, &mut p.strip);
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown profile key '{}'", key));
            }
        } else if sec.starts_with("command.") && sec.len() > 8 {
            let name = sec.slice(8, sec.len());
            // A built-in subcommand cannot be overridden: a `[command.build]` that shadows `build`
            // makes every invocation mean something else per project. Custom names only.
            if is_builtin_command(name) {
                let mut seen = false;
                for r in 0..rejected.len() {
                    if rejected.at(r).as_str() == name {
                        seen = true;
                    }
                }
                if !seen {
                    rejected.push(String::from_str(name));
                    errs.emit(
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
                    errs.emit(it.at, 3, format("'env' expects an inline table of strings"));
                } else {
                    for e in 0..it.val.tbl.len() {
                        c.env_k.push(it.val.tbl.at(e).k.clone());
                        c.env_v.push(it.val.tbl.at(e).v.clone());
                    }
                }
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown command key '{}'", key));
            }
        } else if sec == "lib" {
            saw_lib = true;
            if key == "name" {
                set_str(it, &mut errs, &mut m.lib_name);
            } else if key == "root" {
                set_str(it, &mut errs, &mut m.lib_root);
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
                        errs.emit(it.at, 4, format("unknown library type '{}' (static | shared)", kind));
                    }
                }
            } else {
                errs.emit(it.at, key.len() as u32, format("unknown [lib] key '{}'", key));
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
                errs.emit(it.at, key.len() as u32, format("unknown [bin.{}] key '{}'", name, key));
            }
        } else {
            errs.emit(it.at, key.len() as u32, format("unknown section '{}'", sec));
        }
    }
    // the name views above point into the items' section Strings: the Manifest takes ownership
    m.toml = items;
    // defaults + validation
    if m.out_dir.len() == 0 {
        m.out_dir.push_str("build");
    }
    if m.test_dir.len() == 0 {
        m.test_dir.push_str("tests");
    }
    if m.bench_dir.len() == 0 {
        m.bench_dir.push_str("bench");
    }
    norm_conv_dir(&mut m.test_dir, "test-dir", &mut errs);
    norm_conv_dir(&mut m.bench_dir, "bench-dir", &mut errs);
    if m.cstd.len() == 0 {
        m.cstd.push_str("-std=c11 -D_POSIX_C_SOURCE=200809L");
    }
    if m.default_profile.len() == 0 {
        m.default_profile.push_str("dev");
    }
    m.add_builtin_profiles();
    // [lib] defaults: root src/lib.spc, name after the primary binary, static unless told otherwise
    if saw_lib {
        if m.lib_root.len() == 0 {
            m.lib_root.push_str("src/lib.spc");
        }
        if m.lib_name.len() == 0 {
            if m.bin.len() != 0 {
                m.lib_name.push_string(&m.bin);
            } else {
                errs.emit(0, 1, format("[lib] needs a 'name' when the manifest declares no 'bin'"));
            }
        }
        if !m.lib_static && !m.lib_shared {
            m.lib_static = true;
        }
    }
    // a library-only project needs no primary binary; its lib root anchors the source tree
    if m.root.len() == 0 && saw_lib {
        m.root.push_string(&m.lib_root);
    }
    if m.bin.len() == 0 && !saw_lib {
        errs.emit(0, 1, format("missing required key 'bin' (or a [lib] section)"));
    }
    if m.root.len() == 0 {
        errs.emit(0, 1, format("missing required key 'root'"));
    }
    for i in 0..m.bins.len() {
        if m.bins.at(i).root.len() == 0 {
            errs.emit(0, 1, format("[bin.{}] needs a 'root'", m.bins.at(i).name.as_str()));
        }
        if m.bins.at(i).name.as_str() == m.bin.as_str() {
            errs.emit(0, 1, format("[bin.{}] collides with the manifest's primary 'bin'", m.bins.at(i).name.as_str()));
        }
    }
    if m.profile_index(m.default_profile.as_str()) < 0 {
        errs.emit(0, 1, format("default-profile '{}' is not defined", m.default_profile.as_str()));
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
            sdk: 0,
            toml: Vector::<toml::TomlItem>::new(),
            bin: String::new(),
            root: String::new(),
            out_dir: String::new(),
            test_dir: String::new(),
            bench_dir: String::new(),
            cc: String::new(),
            cstd: String::new(),
            cflags: Vector::<String>::new(),
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
        };
    }

    /// Index of the profile named `name`, or -1 when absent.
    pub fn profile_index(self: &Self, name: str) i64 {
        for i in 0..self.profiles.len() {
            if self.profiles.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    /// Index of the command named `name`, or -1 when absent.
    pub fn command_index(self: &Self, name: str) i64 {
        for i in 0..self.commands.len() {
            if self.commands.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    // The Makefile's profiles, available out of the box; a [profile.NAME] section with the same name
    // starts from empty flags instead (full override, no merging surprises).
    fn add_builtin_profiles(self: &mut Self) {
        if self.profile_index("debug") < 0 {
            let mut p = Profile::new("debug");
            push_flags(
                &mut p.cflags,
                "-g -O0  -fsanitize=address -fsanitize=undefined -fsanitize-recover=address -fsanitize-address-use-after-scope -fno-omit-frame-pointer",
            );
            push_flags(&mut p.ldflags, "-fsanitize=address -fsanitize=undefined");
            self.profiles.push(p);
        }
        if self.profile_index("dev") < 0 {
            let mut p = Profile::new("dev");
            push_flags(
                &mut p.cflags,
                "-g -O1 -fsanitize=address -fsanitize=undefined -fsanitize-recover=address -fsanitize-address-use-after-scope -fno-omit-frame-pointer",
            );
            push_flags(&mut p.ldflags, "-fsanitize=address -fsanitize=undefined");
            self.profiles.push(p);
        }
        if self.profile_index("release") < 0 {
            let mut p = Profile::new("release");
            push_flags(
                &mut p.cflags,
                "-O3 -DNDEBUG -finline-functions -fomit-frame-pointer -ffunction-sections -fdata-sections -flto=auto -fPIE",
            );
            push_flags(&mut p.ldflags, "-flto=auto -Wl,-O2");
            p.strip = true;
            self.profiles.push(p);
        }
        if self.profile_index("bench") < 0 {
            let mut p = Profile::new("bench");
            // Optimization parity with `release` (-O3 -DNDEBUG): the bench should measure the compiler
            // users actually run. -g and frame pointers stay so samply profiles remain readable.
            push_flags(&mut p.cflags, "-O3 -DNDEBUG -g -fno-omit-frame-pointer -flto=auto");
            // Profile-guided optimization when local training data exists (build with --profile=pgogen,
            // run a self-transpile under LLVM_PROFILE_FILE, merge with llvm-profdata). Clang hard-errors
            // on a missing profile file, so the flag only appears when the file is present.
            let pf = stdio::fopen("build/pgo.profdata", "rb");
            if pf != null {
                let _ = unsafe stdio::fclose(pf);
                push_flags(
                    &mut p.cflags,
                    "-fprofile-use=build/pgo.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date -Wno-backend-plugin",
                );
            }
            push_flags(&mut p.ldflags, "-flto=auto");
            self.profiles.push(p);
        }
        // PGO training build: instrument, run a representative workload (a self-transpile) under
        // LLVM_PROFILE_FILE, merge the raw profiles with llvm-profdata into build/pgo.profdata, and the
        // bench profile above picks it up on its next build.
        if self.profile_index("pgogen") < 0 {
            let mut p = Profile::new("pgogen");
            push_flags(&mut p.cflags, "-O2 -fprofile-generate -flto=auto");
            push_flags(&mut p.ldflags, "-fprofile-generate -flto=auto");
            self.profiles.push(p);
        }
        // ThreadSanitizer. Its own profile and NEVER part of `release`: TSan costs 5-15x runtime and several
        // times the memory, and it needs its runtime linked in. No LTO -- it defeats the instrumentation the
        // tool relies on. This is also what turns on the coroutine fiber annotations in `ffi/sc_rt.c`, without
        // which every coroutine that migrates between workers reports as a race against itself.
        //
        // `-fno-inline` is not tidiness, it is what makes a report TRUE. At plain -O1 this reports one race per
        // run, on a closure's exit path, and the SAME source is clean at -O0 and clean at `-O1 -fno-inline` --
        // across five runs each. Inlining changes no memory operation and no lock, so a report that appears and
        // disappears with it is attribution, not a race: the allocation it blames is inlined into `worker_main`
        // from a callee, and the write it blames is inlined into a wrapper from the closure body. Losing the
        // inlining is the price of a report worth acting on.
        if self.profile_index("race") < 0 {
            let mut p = Profile::new("race");
            push_flags(&mut p.cflags, "-O1 -fno-inline -g -fsanitize=thread -fno-omit-frame-pointer -DSC_LOCKDEP");
            push_flags(&mut p.ldflags, "-fsanitize=thread");
            self.profiles.push(p);
        }
    }
}
