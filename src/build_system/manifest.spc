// build.toml schema: maps parsed TOML items onto the Build manifest, applies defaults (built-in
// debug/release/bench/test profiles), and validates. Unknown sections/keys are hard errors so typos
// never silently no-op.
import driver_shim as shim;
import build_system::toml as toml;
import module::loader as loader;
import utils::errors as diag;
import driver::util as dutil;
import ir::cpu_features as cf;

/// One [profile.NAME]: per-profile ldflags appended after the manifest-level ones; `strip` links without
/// local symbols and debug information; `opt` is the `opt-level` (whether `lir::opt` runs), `debug`
/// whether the objects carry debug information; `link_args` reach the linker after the profile's
/// ldflags (`-Wl,<arg>` each).
pub struct Profile<'a> {
    pub name: str<'a>,
    pub ldflags: Vector<String>,
    pub link_args: Vector<String>,
    pub strip: bool,
    pub opt: i32,
    pub debug: bool,
    /// `lockdep`: the runtime's lock-order checks are compiled in (the build constant LOCKDEP); SC_LOCK_ORDER
    /// switches their reports on.
    pub lockdep: bool,
    /// `overflow-checks`: 1 traps integer overflow, 0 wraps it, -1 follows `opt`.
    pub overflow_checks: i32,
    /// `target-features`: the CPU features to enable; set (`has_features`), it replaces the build's list.
    pub target_features: Vector<String>,
    pub has_features: bool,
    /// The code-generation flags (`CG_*`) the profile turns on and off; the rest follow `opt`.
    pub cg_on: u64,
    pub cg_off: u64,
}

/// The C dialect and POSIX level the extern blocks' headers are read under (`--emit-c`'s units too).
pub const DEFAULT_CSTD: str<'static> = "-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700";

/// `opt-level` values: 0 to 3, OPT_S and OPT_Z (`"s"`, `"z"`); OPT_NONE when the profile names none.
pub const OPT_NONE: i32 = -1;
pub const OPT_S: i32 = 4;
pub const OPT_Z: i32 = 5;

/// The code-generation flags (GCC's and clang's `-f<name>` and `-fno-<name>`, and a profile's `<name> =
/// true|false`): bits of the set a build runs with (`cg_effective`).
/// Omit the frame pointer: functions address their frames through the stack pointer.
pub const CG_OMIT_FRAME_POINTER: u64 = 1;
/// Inline calls (`-fno-inline`: none).
pub const CG_INLINE: u64 = 2;
/// Inline calls past the ones that shrink the code (`-finline-functions`).
pub const CG_INLINE_FUNCTIONS: u64 = 4;

// The flags by name.
const CG_NAMES: [(str<'static>, u64); 3] = [
    ("omit-frame-pointer", CG_OMIT_FRAME_POINTER),
    ("inline", CG_INLINE),
    ("inline-functions", CG_INLINE_FUNCTIONS),
];

// The bit flag `name` names: 0 for none.
fn cg_bit(name: str) u64 {
    let names: [](str, u64) = CG_NAMES;
    for k in 0..names.len() {
        if names[k].0 == name {
            return names[k].1;
        }
    }
    return 0;
}

// Bits `b` into `on` (`set`) or `off`, out of the other.
fn cg_put(b: u64, set: bool, on: &mut u64, off: &mut u64) {
    if set {
        *on |= b;
        *off &= ~b;
    } else {
        *off |= b;
        *on &= ~b;
    }
}

/// Command-line flag `arg` (`-f<name>`, `-fno-<name>`) into `on` or `off`: false when it names no flag.
pub fn cg_flag(arg: str, on: &mut u64, off: &mut u64) bool {
    let neg = arg.starts_with("-fno-");
    if !neg && !arg.starts_with("-f") {
        return false;
    }
    let b = cg_bit(
        arg.slice(
            if neg {
                5;
            } else {
                2;
            },
            arg.len(),
        ),
    );
    if b != 0 {
        cg_put(b, !neg, on, off);
    }
    return b != 0;
}

/// Command-line flag `arg` (`-O0` to `-O3`, `-Os`, `-Oz`) as an `opt-level`: OPT_NONE when it is none.
pub fn opt_flag(arg: str) i32 {
    if arg.len() != 3 || !arg.starts_with("-O") {
        return OPT_NONE;
    }
    let c = arg[2];
    if c >= b'0' && c <= b'3' {
        return c - b'0';
    }
    return if c == b's' {
        OPT_S;
    } else if c == b'z' {
        OPT_Z;
    } else {
        OPT_NONE;
    };
}

/// The flags of `on` and `off` as command-line flags (`opt`: `-O<level>` first, unless OPT_NONE), each
/// after a space.
pub fn cg_spell(opt: i32, on: u64, off: u64, out: &mut String) {
    if opt == OPT_S {
        out.push_str(" -Os");
    } else if opt == OPT_Z {
        out.push_str(" -Oz");
    } else if opt != OPT_NONE {
        out.format_into(" -O{}", opt);
    }
    let names: [](str, u64) = CG_NAMES;
    for k in 0..names.len() {
        if (on & names[k].1) != 0 {
            out.format_into(" -f{}", names[k].0);
        } else if (off & names[k].1) != 0 {
            out.format_into(" -fno-{}", names[k].0);
        }
    }
}

/// The flags a build at `opt-level` `opt` runs with: the level's defaults, then `on` set and `off`
/// cleared. At every level but 0 the frame pointer goes (on arm64 from leaf functions only, as Apple's
/// ABI allows) and calls inline; past the ones that shrink the code at 2, 3 and "s".
pub const fn cg_effective(opt: i32, on: u64, off: u64) u64 {
    let mut f: u64 = 0;
    if opt > 0 {
        f |= CG_OMIT_FRAME_POINTER | CG_INLINE;
    }
    if opt >= 2 && opt != OPT_Z {
        f |= CG_INLINE_FUNCTIONS;
    }
    return (f | on) & ~off;
}

/// One extra binary target: `[bin.NAME] root = "..."` (the top-level `bin`/`root` pair is the
/// primary binary). `super-c build` builds every target; `--bin=NAME` selects one.
pub struct BinTarget {
    pub name: String,
    pub root: String,
}

/// One [command.NAME] for `super-c command <name>`: shell lines executed in order, stopping at the
/// first failure. Built-in subcommand names are reserved: a command can never shadow one.
pub struct Command<'a> {
    pub name: str<'a>,
    pub run: Vector<String>,
    pub needs_build: bool, // needs-build = true: run a manifest build before the lines
    pub env_k: Vector<String>, // parallel with env_v: set in the environment every line inherits
    pub env_v: Vector<String>,
}

/// The validated build.toml. `bin` is where the project's binary is INSTALLED: each profile links its own
/// copy under `<out_dir>/<profile>/`, and only `build`/`release` (never `test` or `run`) copy one onto that
/// name, so a profile can never quietly stand in for another's artifact.
/// Ownership: `toml` keeps the parsed items alive; Profile/Command `name` views borrow into their
/// section strings.
pub struct Manifest<'a> {
    /// Instruction set `@arch` gates against (a `target::table::ISAS` index), -1 unknown. Defaults to the
    /// host; the driver overwrites it for `--arch=`.
    pub arch: i32,
    /// Platform (a `target::table::OSES` index) the build is for: the host, or `--target=`. Its cross
    /// toolchain, baseline CPU features and their C flag depend on it.
    pub target: i32,
    pub toml: Vector<toml::TomlItem>,
    pub bin: String,
    pub root: String,
    pub out_dir: String,
    pub test_dir: String, // where `super-c test` discovers the suite (default "tests")
    pub bench_dir: String, // where `super-c bench` discovers '@bench' functions (default "bench")
    pub ldflags: Vector<String>,
    pub ldlibs: Vector<String>,
    pub jobs: u32,
    pub ce_steps: u32, // const-eval step budget; 0 = the engine default (~2M); CLI --const-eval-steps overrides
    pub ce_mem: u64, // const-eval memory budget in bytes; 0 = the engine default; CLI --const-eval-memory overrides
    pub std_internals: bool, // `std_internals`: the project names std's `pub(package)` items (unstable internals)
    pub default_profile: String,
    pub profiles: Vector<Profile<'a>>,
    pub commands: Vector<Command<'a>>,
    pub bins: Vector<BinTarget>, // extra [bin.NAME] targets (the top-level bin/root pair is first-class)
    pub lib_name: String, // [lib] name; empty = no library target
    pub lib_root: String, // [lib] root (default src/lib.spc)
    pub lib_static: bool, // [lib] type contains "static" (the default when [lib] is present)
    pub lib_shared: bool, // [lib] type contains "shared"
    pub shards: Vector<loader::ShardRule>, // [shards] and [instance-shards]: per-module counts
    pub target_features: Vector<String>, // `target-features`: the CPU features to enable (`--target-feature` names)
    pub target_cpu: String, // `target-cpu`: an x86-64 level applied before `target-features` (`--target-cpu`)
    pub simd_width: u32, // `simd-width`: 512 lets the vector planner use 512-bit entries on AVX-512; 0 = 256
    pub simd_dispatch: String, // `simd-dispatch`: `off`, or the x86-64 levels run-time copies are made for; empty = x86-64-v3 (off at opt-level 0 or 1)
    /// `str_id` of the text `load` read, and the file's mtime from the stat before the read (as
    /// `loader::read_file_mt` gives them): the emit stamp's record of the manifest. Both 0 for a manifest
    /// not read from a file.
    pub src_id: u64,
    pub mtime: i64,
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
            cg_on: 0,
            cg_off: 0,
        };
    }

    /// Whether integer overflow wraps instead of trapping (`wraps`).
    pub const fn arith_wraps(self: &Self) bool {
        return wraps(self.overflow_checks, self.opt);
    }
}

/// Whether integer overflow wraps instead of trapping: `overflow-checks` (`checks`) false, or without the
/// key (-1) an `opt-level` (`opt`) of 2, 3, "s" or "z".
pub const fn wraps(checks: i32, opt: i32) bool {
    if checks >= 0 {
        return checks == 0;
    }
    return opt >= 2;
}

/// A manifest holding nothing but the built-in profiles, for a build with no `build.toml` to read them
/// from: `super-c release foo.spc` compiles and links in one command and still has to honour the profile
/// it was asked for. Free it like any other manifest.
pub fn builtins_only<'a>() Manifest<'a> {
    let mut m = Manifest::new();
    m.add_builtin_profiles();
    return m;
}

// The array replaces `dst` (a built-in profile's flags when the section names one).
fn take_arr(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut Vector<String>) {
    if it.val.kind != toml::TV_ARR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects an array of strings", it.key.as_str()));
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
        errs.emit(0, 1, format("'{}' must be a plain workspace-relative directory, got '{}'", key, s));
    }
}

const COMMANDS: [str<'static>; 14] = [
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
];

/// The position of subcommand `name` in `Mode` declaration order after MODE_DEFAULT (main dispatches
/// position k to Mode k + 1); -1 when `name` is no subcommand. The names are reserved, so a
/// `[command.NAME]` can never shadow one.
pub const fn subcommand_index(name: str) i32 {
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
        errs.emit(at, len, msg);
    }
}

fn set_str(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut String) {
    if it.val.kind != toml::TV_STR {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects a string", it.key.as_str()));
        return;
    }
    *dst = it.val.s.clone();
}

fn set_u32(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut u32) {
    if it.val.kind != toml::TV_INT || it.val.i < 0 || it.val.i > 4294967295 {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects a non-negative integer", it.key.as_str()));
        return;
    }
    *dst = it.val.i as u32;
}

fn set_bool(it: &toml::TomlItem, errs: &mut diag::Errors, dst: &mut bool) {
    if it.val.kind != toml::TV_BOOL {
        errs.emit(it.at, it.key.len() as u32, format("'{}' expects true or false", it.key.as_str()));
        return;
    }
    *dst = it.val.b;
}

/// Load and validate <path>, applying defaults (out-dir "build", default-profile
/// "debug", built-in profiles). Prints its own diagnostics; None on any error. `bootstrap` (the
/// --bootstrap-tags build) skips sections and keys this compiler does not know, so a previous release
/// can build a source tree whose manifest already uses additions it predates; the compiler it produces
/// reads the same manifest strictly.
pub fn load(path: str, bootstrap: bool) Option<Manifest> {
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
pub fn parse_check<'a>(src: str, file: str, bootstrap: bool) (Option<Manifest<'a>>, diag::Errors) {
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
                        it.at,
                        key.len() as u32,
                        format("'const-eval-memory' expects a non-negative integer (bytes)"),
                    );
                } else {
                    m.ce_mem = it.val.i as u64;
                }
            } else if key == "std_internals" {
                set_bool(it, &mut errs, &mut m.std_internals);
            } else if key == "default-profile" {
                set_str(it, &mut errs, &mut m.default_profile);
            } else if key == "target-features" {
                take_arr(it, &mut errs, &mut m.target_features);
            } else if key == "target-cpu" {
                set_str(it, &mut errs, &mut m.target_cpu);
            } else if key == "simd-width" {
                set_u32(it, &mut errs, &mut m.simd_width);
                if m.simd_width != 256 && m.simd_width != 512 {
                    errs.emit(it.at, key.len() as u32, format("'simd-width' expects 256 or 512"));
                }
            } else if key == "simd-dispatch" {
                set_str(it, &mut errs, &mut m.simd_dispatch);
                let mut e9 = String::new();
                if !cf::dispatch_ok(m.simd_dispatch.as_str(), &mut e9) {
                    errs.emit(it.at, key.len() as u32, e9);
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
                    errs.emit(it.at, key.len() as u32, format("'opt-level' expects 0, 1, 2, 3, \"s\" or \"z\""));
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
            } else if cg_bit(key) != 0 {
                let mut on = false;
                set_bool(it, &mut errs, &mut on);
                cg_put(cg_bit(key), on, &mut p.cg_on, &mut p.cg_off);
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
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown command key '{}'", key));
            }
        } else if sec == "shards" || sec == "instance-shards" {
            if it.val.kind != toml::TV_INT || it.val.i < 1 || it.val.i > 255 {
                errs.emit(it.at, key.len() as u32, format("'[{}]' expects a count from 1 to 255", sec));
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
                unknown(&mut errs, bootstrap, it.at, key.len() as u32, format("unknown [lib] key '{}'", key));
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
                errs.emit(0, 1, format("[lib] needs a 'name' when the manifest declares no 'bin'"));
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
    pub const fn profile_index(self: &Self, name: str) i64 {
        for i in 0..self.profiles.len() {
            if self.profiles.at(i).name == name {
                return i as i64;
            }
        }
        return -1;
    }

    /// The command line's `-O<level>` (`opt`; OPT_NONE: none) and `-f` flags (`on`, `off`) over every
    /// profile: whichever the build selects runs with them.
    pub fn override_profiles(self: &mut Self, opt: i32, on: u64, off: u64) {
        for i in 0..self.profiles.len() {
            let p = &mut self.profiles[i];
            if opt != OPT_NONE {
                p.opt = opt;
            }
            p.cg_on = p.cg_on & ~off | on;
            p.cg_off = p.cg_off & ~on | off;
        }
    }

    /// Index of the command named `name`, or -1 when absent.
    pub const fn command_index(self: &Self, name: str) i64 {
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
